-- run_tests.lua
-- Tests for the parts of the plugin that don't need the game client:
-- classification, plans, tidying, sorting and settings. Most tests use real
-- item data recorded from the game (tests/fixtures/sample_items.lua). Tests on
-- a whole real bank run when the private tests/fixtures/real_bank.lua is
-- present (it isn't in the public repository). Run from the
-- plugin folder with Lua 5.4:
--
--     lua tests/run_tests.lua
--
-- This folder is for development only and doesn't need to be uploaded.

package.path = "./?.lua;" .. package.path

-- Minimal stand-ins for the game API used by the files under test.
local store = {}
PersistentDB = {
    GetStructuredData = function(_, key) return store[key] end,
    SetStructuredData = function(_, key, value) store[key] = value; return true end,
    Clear = function()
        for key in pairs(store) do store[key] = nil end
        return true
    end,
}
log = function(...) print("[log]", ...) end

local bank = require("src/bank")
local classifier = require("src/classifier")
local categories = require("src/categories")
local guide = require("src/guide")
local sorter = require("src/sorter")
local settings = require("src/settings")
local presets = require("src/presets")

local passed, failed = 0, 0
local function check(name, condition, detail)
    if condition then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. name .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

-- Real items by name, and (if present) a whole recorded bank.
local rawByName = {}
for _, raw in ipairs(dofile("tests/fixtures/sample_items.lua")) do rawByName[raw.name] = raw end
local hasRealBank, fixture = pcall(dofile, "tests/fixtures/real_bank.lua")
if not hasRealBank then
    fixture = nil
    print("Note: tests/fixtures/real_bank.lua not found, so the whole-bank tests are skipped.")
end
local function real(name, slot)
    local raw = rawByName[name]
    assert(raw, "no item called " .. name .. " in tests/fixtures/sample_items.lua")
    return bank.describe(raw, 1, slot or 1)
end
-- A bank made of the named items, in slot order.
local function bankOf(names)
    local items = {}
    for i, name in ipairs(names) do items[i] = real(name, i) end
    return items
end
local function classify(name) return classifier.classify(real(name), {}) end

-- Classifier ------------------------------------------------------------------
local expected = {
    ["Rune platebody + 3"] = "melee", ["Dragon scimitar"] = "melee", ["Black helm"] = "melee",
    ["Elder shortbow"] = "ranged", ["Adamant arrow"] = "ammo", ["Staff of air"] = "magic",
    ["Mystic orb"] = "magic", ["Deathstorm drape"] = "necromancy", ["Fire rune"] = "runes",
    ["Ring of duelling (5)"] = "teleports", ["Ring of life"] = "jewellery", ["Swordfish"] = "food",
    ["Prayer potion (4)"] = "potions", ["Grimy avantoe"] = "herblore", ["Strawberry seed"] = "farming",
    ["Compost"] = "farming", ["Maple logs"] = "woodcutting", ["Iron ore"] = "mining", ["Raw shark"] = "fishing",
    ["Uncut emerald"] = "crafting", ["Pure essence"] = "runecrafting", ["Small pouch"] = "runecrafting",
    ["Big bones"] = "prayer", ["Blue charm"] = "summoning", ["Sparkling energy"] = "divination",
    ["Archaeology journal"] = "archaeology", ["Ancient timepiece (damaged)"] = "archaeology",
    ["Sealed clue scroll (easy)"] = "clues", ["Acrobat pants"] = "cosmetic", ["A key"] = "quest",
    ["Strange rock (Mining)"] = "currency", ["Tinderbox"] = "tools", ["Hammer"] = "tools",
    ["Red hot sauce"] = "quest", ["Rotten food"] = "misc", ["Impious urn (unfired)"] = "prayer",
    ["Mind helmet"] = "magic", ["Crown of Loyalty I"] = "cosmetic", ["Easter carrot"] = "cosmetic",
    ["Diviner's robe"] = "cosmetic",
}
for name, category in pairs(expected) do
    check(name .. " is " .. category, classify(name) == category, classify(name))
end
check("custom rule wins", classifier.classify(real("Dragon scimitar"),
    { customRules = { { pattern = "dragon", category = "cosmetic" } } }) == "cosmetic")
check("custom rule is literal text", classifier.classify(real("Prayer potion (4)"),
    { customRules = { { pattern = "(4)", category = "misc" } } }) == "misc")

-- Almost everything in a real bank gets a proper category.
if fixture then
    local miscCount = 0
    for _, raw in ipairs(fixture) do
        local category = classifier.classify(bank.describe(raw, 1, 1), {})
        check("category exists for " .. raw.name, categories.byId[category] ~= nil, category)
        if category == "misc" then miscCount = miscCount + 1 end
    end
    check("under 2% of a real bank is miscellaneous", miscCount / #fixture < 0.02, miscCount)
end

-- Plan styles -------------------------------------------------------------------
for _, preset in ipairs(presets.BUILT_IN) do
    local seen = {}
    for _, group in ipairs(preset.groups) do
        for _, categoryId in ipairs(group.categories) do
            check("style " .. preset.id .. " uses real category " .. categoryId, categories.byId[categoryId] ~= nil)
            check("style " .. preset.id .. " lists " .. categoryId .. " once", not seen[categoryId])
            seen[categoryId] = true
        end
    end
    for _, categoryId in ipairs(categories.DEFAULT_ORDER) do
        check("style " .. preset.id .. " places " .. categoryId, seen[categoryId])
    end
    check("style " .. preset.id .. " ends with Everything else", preset.groups[#preset.groups].label == "Everything else")
    check("style " .. preset.id .. " fits the game's 14 tabs", #preset.groups <= 14)
end
for _, categoryId in ipairs(categories.DEFAULT_ORDER) do
    check("category " .. categoryId .. " has a label", categories.byId[categoryId] ~= nil)
end

-- Tab ranges --------------------------------------------------------------------
local five = bankOf({ "Logs", "Willow logs", "Trout", "Salmon", "Tuna" })
local ranges = guide.rangesFromSizes(five, { { size = 2, display = 2, iconItemId = five[1].id },
    { size = 2, display = 1, iconItemId = five[3].id } })
check("two tabs", #ranges == 2)
check("first stored tab", ranges[1].first == 1 and ranges[1].last == 2 and ranges[1].display == 2)
check("second stored tab", ranges[2].first == 3 and ranges[2].last == 4 and ranges[2].display == 1)
check("items after the tabs aren't in one", guide.tabOf(ranges, 5) == nil and guide.tabOf(ranges, 3) == 2)

-- Simulated player --------------------------------------------------------------
-- Lays a bank out as the game stores it (tabs in stored order, items not in a
-- tab last) and follows the plugin: drag every highlighted item, in number
-- order, onto the highlighted tab (or "+"), then do every swap it asks for.
-- A dragged item goes to the end of its new tab; empty tabs vanish.
--   entries - { { raw, tab (stored tab number or 0), order } }
local function simulate(entries, tabDisplay, data, mode, lockedIcons)
    local planFn = mode == "tidy" and guide.planTidy or guide.planTabs
    local tabCount = 0
    for t in pairs(tabDisplay) do tabCount = math.max(tabCount, t) end
    local counter, drags, swaps, tabMoves, iconSwaps = 100000, 0, 0, 0, 0
    for _ = 1, 5000 do
        table.sort(entries, function(a, b)
            local ta, tb = a.tab == 0 and math.huge or a.tab, b.tab == 0 and math.huge or b.tab
            if ta ~= tb then return ta < tb end
            return a.order < b.order
        end)
        local items, sizes, firstItem = {}, {}, {}
        for i, e in ipairs(entries) do
            e.item = bank.describe(e.raw, 1, i)
            items[i] = e.item
            if e.tab > 0 then
                sizes[e.tab] = (sizes[e.tab] or 0) + 1
                firstItem[e.tab] = firstItem[e.tab] or e.item
            end
        end
        local present = {}
        for t = 1, tabCount do if sizes[t] then table.insert(present, t) end end
        local byDisplay = { table.unpack(present) }
        table.sort(byDisplay, function(a, b) return tabDisplay[a] < tabDisplay[b] end)
        local position = {}
        for i, t in ipairs(byDisplay) do position[t] = i end
        local tabs = {}
        for _, t in ipairs(present) do
            table.insert(tabs, { size = sizes[t], display = position[t], iconItemId = firstItem[t].id, real = t })
        end
        local r = guide.rangesFromSizes(items, tabs)
        local locked = {}
        for k, range in ipairs(r) do
            if lockedIcons and lockedIcons[range.iconItemId] then locked[k] = true end
        end
        local plan = planFn(items, r, data, locked)
        local entryOf = {}
        for _, e in ipairs(entries) do entryOf[e.item] = e end
        -- A tab whose icon item is in it but not first is fixed before anything else.
        local iconFix = guide.iconStep(items, r, plan, locked, {})
        local step = not iconFix and guide.currentStep(plan)
        if iconFix then
            local a, b = entryOf[iconFix.from], entryOf[iconFix.to]
            a.order, b.order = b.order, a.order
            iconSwaps = iconSwaps + 1
        elseif step then
            local target
            if step.bankTab then
                target = tabs[step.bankTab].real
            else
                tabCount = tabCount + 1
                target, tabDisplay[tabCount] = tabCount, 1000 + tabCount
            end
            local ordered = sorter.sorted(step.toMove, function(it) return guide.categoryOf(it, data) end,
                step.categories)
            for _, it in ipairs(ordered) do
                counter, drags = counter + 1, drags + 1
                entryOf[it].tab, entryOf[it].order = target, counter
            end
        else
            -- Tab order first (drag one tab icon onto another: they swap places),
            -- then sorting inside tabs.
            local o = data.values.orderTabs and plan.toMoveTotal == 0 and guide.orderStep(r, plan)
            if o then
                local a, b = tabs[o.from].real, tabs[o.to].real
                tabDisplay[a], tabDisplay[b] = tabDisplay[b], tabDisplay[a]
                tabMoves = tabMoves + 1
            else
                -- With sorting off, Organise still puts each tab's icon first.
                local doSort = plan.toMoveTotal == 0 and (data.values.sortInside or mode ~= "tidy")
                local s = doSort and guide.sortStep(items, r, plan, data, locked, {}, nil, not data.values.sortInside)
                if not s then
                    return { drags = drags, swaps = swaps, tabMoves = tabMoves, iconSwaps = iconSwaps, plan = plan,
                        entries = entries, ranges = r }
                end
                local a, b = entryOf[s.from], entryOf[s.to]
                a.order, b.order = b.order, a.order
                swaps = swaps + 1
            end
        end
    end
    return nil
end

-- The real bank as recorded: 7 tabs (stored sizes, and where each sits in
-- the tab bar), then 856 items not in any tab.
local REAL_SIZES = { 18, 14, 9, 30, 22, 7, 30 }
local REAL_DISPLAY = { 1, 4, 3, 2, 5, 6, 7 }
local function realEntries()
    local entries, first = {}, 1
    local tabOfIndex = {}
    for t, size in ipairs(REAL_SIZES) do
        for i = first, first + size - 1 do tabOfIndex[i] = t end
        first = first + size
    end
    for i, raw in ipairs(fixture) do
        table.insert(entries, { raw = raw, tab = tabOfIndex[i] or 0, order = i })
    end
    local display = {}
    for t, d in ipairs(REAL_DISPLAY) do display[t] = d end
    return entries, display
end

-- Organise my bank, on the real bank ------------------------------------------
guide.clearCache()
if fixture then
    local data = settings.defaults()
    local entries, display = realEntries()
    local items = {}
    table.sort(entries, function(a, b) return a.order < b.order end)
    for i, e in ipairs(entries) do items[i] = bank.describe(e.raw, 1, i) end
    local tabs, first = {}, 1
    for t, size in ipairs(REAL_SIZES) do
        tabs[t] = { size = size, display = display[t], iconItemId = items[first].id }
        first = first + size
    end
    local realRanges = guide.rangesFromSizes(items, tabs)
    local plan = guide.planTabs(items, realRanges, data, {})
    check("recommended plan uses 14 tabs", #plan.tabs == 14, #plan.tabs)
    check("items not in a tab are counted", plan.unsorted and plan.unsorted.size == 856, plan.unsorted and plan.unsorted.size)
    local byLabel = {}
    for _, tab in ipairs(plan.tabs) do byLabel[tab.label] = tab end
    check("the rune armour tab becomes Melee", byLabel["Melee"].bankTab and realRanges[byLabel["Melee"].bankTab].display == 1)
    check("the H.A.M. tab becomes Cosmetics", byLabel["Cosmetics & outfits"].bankTab == 7)
    check("new tabs needed", plan.newTabs == 7, plan.newTabs)
    check("no existing tab is emptied", #plan.removedTabs == 0, #plan.removedTabs)
    local reusedDisplays = {}
    for _, row in pairs(plan.report) do
        if row.reused then table.insert(reusedDisplays, row.display) end
    end
    table.sort(reusedDisplays)
    check("tabs nothing matched are reused", table.concat(reusedDisplays, ",") == "3,6", table.concat(reusedDisplays, ","))
    check("the first reused tab takes the first planned tab without one",
        byLabel["Teleports & tools"].bankTab and realRanges[byLabel["Teleports & tools"].bankTab].display == 3)
    check("every misplaced item is listed once", plan.toMoveTotal == 927, plan.toMoveTotal)
    check("report has every tab", #plan.report == 7)
    check("tab order known for kept tabs", plan.tabCategories[byLabel["Melee"].bankTab][1] == "melee")

    -- Where each item goes, for hover tips and feedback.
    local function idOf(name)
        for _, it in ipairs(items) do if it.name == name then return it.id end end
    end
    local scim = plan.destination[idOf("Dragon scimitar")]
    check("an item already in place is done", scim and scim.done and scim.label == "Melee")
    local clue = plan.destination[idOf("Sealed clue scroll (easy)")]
    check("an unsorted item has a destination", clue and not clue.done and clue.label == "Quest items & clues",
        clue and clue.label)
    local packItem = real("Swordfish")
    local packTab = plan.tabFor(packItem)
    check("any item (e.g. in the backpack) has a planned tab", packTab and packTab.label == "Food & potions"
        and realRanges[packTab.bankTab].display == 2, packTab and packTab.label)

    -- Small tabs fold into their family; the tab limit is respected.
    local small = settings.defaults()
    small.values.minTabSize = 20
    local folded = guide.planTabs(items, realRanges, small, {})
    local labels = {}
    for _, tab in ipairs(folded.tabs) do labels[tab.label] = tab end
    check("a small tab folds away", labels["Necromancy"] == nil)
    local necroHome = nil
    for _, tab in ipairs(folded.tabs) do
        for _, c in ipairs(tab.categories) do if c == "necromancy" then necroHome = tab end end
    end
    check("Necromancy joins the biggest combat tab", necroHome and necroHome.label == "Melee",
        necroHome and necroHome.label)
    local limited = settings.defaults()
    limited.values.maxTabs = 6
    check("tab limit respected", #guide.planTabs(items, realRanges, limited, {}).tabs <= 6)

    -- Each planned tab's icon shows what it holds.
    check("Melee's icon is a weapon", byLabel["Melee"].icon and byLabel["Melee"].icon.catName:find("^WEAPON_"),
        byLabel["Melee"].icon and byLabel["Melee"].icon.name)
    check("Teleports & tools' icon is a teleport", byLabel["Teleports & tools"].icon
        and guide.categoryOf(byLabel["Teleports & tools"].icon, data) == "teleports",
        byLabel["Teleports & tools"].icon and byLabel["Teleports & tools"].icon.name)
    check("Food & potions' icon is food", byLabel["Food & potions"].icon
        and guide.categoryOf(byLabel["Food & potions"].icon, data) == "food")
    check("kept tabs know their planned icon", plan.tabIcon[byLabel["Melee"].bankTab] == byLabel["Melee"].icon)
    local newTab = byLabel["Magic"]
    local firstDrag = sorter.sorted(newTab.toMove, function(it) return guide.categoryOf(it, data) end,
        newTab.categories, newTab.icon)[1]
    check("a new tab's icon is dragged first", firstDrag == newTab.icon)

    -- An item rule beats the item's category.
    local ruled = settings.defaults()
    ruled.plan[1].items = { "dragon" }
    local ruledPlan = guide.planTabs(items, realRanges, ruled, {})
    local ruledMoves = {}
    for _, tab in ipairs(ruledPlan.tabs) do
        for _, it in ipairs(tab.toMove) do ruledMoves[it.name] = tab.label end
    end
    check("item rule sends matching items to its tab", ruledMoves["Dragon scimitar"] == "Teleports & tools"
        and ruledMoves["Dragon sq shield"] == "Teleports & tools", ruledMoves["Dragon scimitar"])
    check("item rule leaves other items alone", ruledMoves["Rune platebody"] == nil)

    local lockedPlan = guide.planTabs(items, realRanges, data, { [1] = true })
    local movesOut = false
    for _, tab in ipairs(lockedPlan.tabs) do
        check("no planned tab takes a locked tab", tab.bankTab ~= 1)
        for _, it in ipairs(tab.toMove) do
            if guide.tabOf(realRanges, it.slot) == 1 then movesOut = true end
        end
    end
    check("nothing moves out of a locked tab", not movesOut)
    check("locked tab reported, not emptied", lockedPlan.report[1].locked and not lockedPlan.report[1].emptied)
end

-- Following the plugin on the real bank sorts it completely.
if fixture then
    local data = settings.defaults()
    local entries, display = realEntries()
    local result = simulate(entries, display, data, "fresh")
    check("organising finishes", result ~= nil)
    if result then
        check("one drag per misplaced item", result.drags == 927, result.drags)
        check("sorting inside tabs finishes", result.swaps > 0 and result.swaps < 986, result.swaps)
        check("nothing left outside a tab", result.plan.unsorted == nil)
        check("all done", result.plan.toMoveTotal == 0 and #result.ranges == 14, #result.ranges)
        -- Spot-check the finished layout: every item is in its planned tab.
        local misplaced = 0
        for _, tab in ipairs(result.plan.tabs) do misplaced = misplaced + #tab.toMove end
        check("every item in its planned tab", misplaced == 0)
        -- The tab bar ends up in the plan's order.
        local lastDisplay, inOrder = 0, true
        for _, tab in ipairs(result.plan.tabs) do
            local display = result.ranges[tab.bankTab].display
            if display < lastDisplay then inOrder = false end
            lastDisplay = display
        end
        check("tabs end up in the plan's order", inOrder)
        -- Every tab ends up with its planned icon as its first item.
        local itemAt = {}
        for _, e in ipairs(result.entries) do itemAt[e.item.slot] = e.item end
        local iconsRight = true
        for _, tab in ipairs(result.plan.tabs) do
            local first = itemAt[result.ranges[tab.bankTab].first]
            if not tab.icon or first ~= tab.icon and first.id ~= tab.icon.id then iconsRight = false end
        end
        check("every tab's first item is its planned icon", iconsRight)
        check("putting the tabs in order takes a few drags", result.tabMoves > 0 and result.tabMoves < 14,
            result.tabMoves)
        check("icon fixes are one swap per tab at most", result.iconSwaps <= 14, result.iconSwaps)
    end
    local noSort = settings.defaults()
    noSort.values.sortInside = false
    local entries2, display2 = realEntries()
    local quick = simulate(entries2, display2, noSort, "fresh")
    local quickSwaps = quick and (quick.swaps + quick.iconSwaps)
    check("with sorting off, only the icons are put first", quick and quickSwaps > 0 and quickSwaps <= 14, quickSwaps)
    check("icons are fixed before anything moves", quick and quick.iconSwaps > 0, quick and quick.iconSwaps)
end

-- Just tidy my tabs -------------------------------------------------------------
guide.clearCache()
local tidyNames = {
    -- tab 1: gear, plus a fish and some logs
    "Rune platebody + 3", "Rune platelegs + 3", "Rune full helm + 3", "Dragon sq shield", "Dragon scimitar",
    "Ring of life", "Swordfish", "Maple logs",
    -- tab 2: food, a potion, an armour straggler and something unknown
    "Trout", "Salmon", "Tuna", "Bass", "Prayer potion (4)", "Rune platebody", "Rotten food",
    -- tab 3: logs, plus a herb with no herb tab to go to
    "Logs", "Willow logs", "Teak logs", "Mahogany logs", "Grimy avantoe",
    -- tab 4: a magic tab
    "Mystic wand", "Mystic orb", "Staff of air", "Wizard wand",
    -- tab 5: a boss tab - more food than tab 2, but locked
    "Cake", "Chocolate cake", "Lava eel", "Cooked chompy", "Kebab", "Super restore (4)",
    -- not in a tab
    "Super restore (3)", "Black scimitar",
}
local tidyBank = bankOf(tidyNames)
local function tidyRanges(items)
    return guide.rangesFromSizes(items, {
        { size = 8, display = 1, iconItemId = items[1].id }, { size = 7, display = 2, iconItemId = items[9].id },
        { size = 5, display = 3, iconItemId = items[16].id }, { size = 4, display = 4, iconItemId = items[21].id },
        { size = 6, display = 5, iconItemId = items[25].id } })
end
local tbRanges = tidyRanges(tidyBank)
local tidyData = settings.defaults()
local tidy = guide.planTidy(tidyBank, tbRanges, tidyData, { [5] = true })
local destination = {}
for _, step in ipairs(tidy.tabs) do
    for _, it in ipairs(step.toMove) do destination[it.name] = step.bankTab end
end
check("tidy: the fish goes to the food tab, not the locked one", destination["Swordfish"] == 2, destination["Swordfish"])
check("tidy: logs go to the logs tab", destination["Maple logs"] == 3)
check("tidy: armour straggler goes to the gear tab", destination["Rune platebody"] == 1)
check("tidy: a ring stays with the gear", destination["Ring of life"] == nil)
check("tidy: a potion stays with the food", destination["Prayer potion (4)"] == nil)
check("tidy: unknown items never move", destination["Rotten food"] == nil)
check("tidy: items with nowhere better stay", destination["Grimy avantoe"] == nil)
check("tidy: items not in a tab go where they belong", destination["Black scimitar"] == 1
    and destination["Super restore (3)"] == 2, destination["Black scimitar"])
check("tidy: only the stragglers move", tidy.toMoveTotal == 5, tidy.toMoveTotal)
check("tidy: steps have keys", tidy.tabs[1].key == "tab:" .. tidyBank[1].id)
check("picking a step works on it first", guide.currentStep(tidy, {}, tidy.tabs[3].key) == tidy.tabs[3])
check("a picked step that was skipped still comes first",
    guide.currentStep(tidy, { [tidy.tabs[3].key] = true }, tidy.tabs[3].key) == tidy.tabs[3])
check("without a pick, steps go in order", guide.currentStep(tidy, {}, "nothing") == tidy.tabs[1])
check("tidy: report has every tab", #tidy.report == 5)
check("tidy: report counts items not in a tab", tidy.unsorted and tidy.unsorted.size == 2)
check("tidy: tab 1 is named after its gear", tidy.report[1].name == "Melee gear", tidy.report[1].name)
check("tidy: tab 2 is named Food", tidy.report[2].name == "Food", tidy.report[2].name)
check("tidy: tab 3 is named after logs", tidy.report[3].name == "Logs & fletching", tidy.report[3].name)
check("tidy: report counts strays and incoming", tidy.report[1].strays == 2 and tidy.report[1].incoming == 2,
    tidy.report[1].strays .. "/" .. tidy.report[1].incoming)
check("tidy: locked tab reported", tidy.report[5].locked and tidy.report[5].strays == 0)

local unlocked = guide.planTidy(tidyBank, tbRanges, tidyData, {})
local unlockedFish = nil
for _, step in ipairs(unlocked.tabs) do
    for _, it in ipairs(step.toMove) do
        if it.name == "Swordfish" then unlockedFish = step.bankTab end
    end
end
check("tidy: unlocked, the fish goes to the biggest food tab", unlockedFish == 5, unlockedFish)

-- With one tab open: what should leave it, one destination at a time.
local dest, here, totalOut = guide.tabOutgoing(tidy, tbRanges, 1)
check("an open tab's strays are found", totalOut == 2, totalOut)
check("the first destination comes first", dest and dest.bankTab == 2 and #here == 1 and here[1].name == "Swordfish",
    dest and dest.bankTab)
local none, noItems, noneOut = guide.tabOutgoing(tidy, tbRanges, 4)
check("a tidy tab has nothing to move out", none == nil and noItems == nil and noneOut == 0)

-- A tab's first item is its icon, so it never moves.
local iconBank = bankOf({ "Swordfish", "Rune platebody + 3", "Rune platelegs + 3", "Rune full helm + 3",
    "Trout", "Salmon", "Tuna" })
local iconRanges = guide.rangesFromSizes(iconBank, { { size = 4, display = 1 }, { size = 3, display = 2 } })
check("tidy: a tab's icon item stays", guide.planTidy(iconBank, iconRanges, tidyData).toMoveTotal == 0)

-- Tab icons come first: a planned icon that's in its tab but not at the front
-- is a single swap with the tab's first item.
local iconTabs = guide.rangesFromSizes(iconBank, { { size = 4, display = 2, iconItemId = iconBank[1].id },
    { size = 3, display = 1, iconItemId = iconBank[5].id } })
local helmFirst = { tabIcon = { [1] = iconBank[4] } }
local fix = guide.iconStep(iconBank, iconTabs, helmFirst)
check("an icon not at the front is swapped to the front", fix and fix.bankTab == 1 and fix.from == iconBank[4]
    and fix.to == iconBank[1] and fix.swapsLeft == 1 and fix.swapsTotal == 1, fix and fix.bankTab)
check("an icon step has its own key", fix and fix.key == "icon:" .. iconBank[1].id, fix and fix.key)
local bothTabs = { tabIcon = { [1] = iconBank[4], [2] = iconBank[7] } }
local firstFix = guide.iconStep(iconBank, iconTabs, bothTabs)
check("icons are fixed in tab bar order", firstFix and firstFix.bankTab == 2 and firstFix.swapsTotal == 2,
    firstFix and firstFix.bankTab)
check("only the open tab's icon when asked", guide.iconStep(iconBank, iconTabs, bothTabs, {}, {}, 1).bankTab == 1)
check("a locked tab's icon is left", guide.iconStep(iconBank, iconTabs, bothTabs, { [2] = true }).bankTab == 1)
check("a skipped icon fix waits", guide.iconStep(iconBank, iconTabs, bothTabs, {}, { ["icon:" .. iconBank[5].id] = true })
    .bankTab == 1)
check("an icon already at the front needs nothing",
    guide.iconStep(iconBank, iconTabs, { tabIcon = { [1] = iconBank[1], [2] = iconBank[5] } }) == nil)
check("an icon still in another tab waits for the move", guide.iconStep(iconBank, iconTabs,
    { tabIcon = { [1] = iconBank[6] } }) == nil)
check("no planned icons, no icon steps", guide.iconStep(iconBank, iconTabs, { tabs = {} }) == nil)

-- Every strictness level finishes and respects the lock.
for _, level in ipairs({ "relaxed", "normal", "strict" }) do
    local data = settings.defaults()
    data.values.strictness = level
    data.values.sortInside = false
    local entries, display, sizes = {}, {}, { 8, 7, 5, 4, 6 }
    local index = 0
    for t, size in ipairs(sizes) do
        display[t] = t
        for _ = 1, size do
            index = index + 1
            table.insert(entries, { raw = rawByName[tidyNames[index]], tab = t, order = index })
        end
    end
    for i = index + 1, #tidyNames do table.insert(entries, { raw = rawByName[tidyNames[i]], tab = 0, order = i }) end
    local result = simulate(entries, display, data, "tidy", { [rawByName["Cake"].id] = true })
    check("tidy finishes: " .. level, result ~= nil and result.plan.toMoveTotal == 0)
    check("tidy keeps the drags low: " .. level, result and result.drags <= 8, result and result.drags)
end

-- Sorting inside a tab -----------------------------------------------------------
local function names(list)
    local out = {}
    for i, it in ipairs(list) do out[i] = it.name end
    return table.concat(out, ", ")
end
local function catOf(it) return guide.categoryOf(it, tidyData) end
local runes = sorter.sorted(bankOf({ "Blood rune", "Fire rune", "Astral rune", "Earth rune", "Nature rune",
    "Body rune", "Cosmic rune" }), catOf)
check("runes in the usual order", names(runes) == "Earth rune, Fire rune, Body rune, Cosmic rune, Astral rune, "
    .. "Nature rune, Blood rune", names(runes))
local potions = sorter.sorted(bankOf({ "Prayer potion (1)", "Super restore (3)", "Prayer potion (4)",
    "Super restore (4)" }), catOf)
check("potions by name, most doses first", names(potions) == "Prayer potion (4), Prayer potion (1), "
    .. "Super restore (4), Super restore (3)", names(potions))
local gearOrder = sorter.sorted(bankOf({ "Rune platebody + 3", "Black platelegs", "Black helm", "Black scimitar",
    "Black platebody", "Black boots" }), catOf)
check("gear by tier, sets in slot order", names(gearOrder) == "Black scimitar, Black helm, Black platebody, "
    .. "Black platelegs, Black boots, Rune platebody + 3", names(gearOrder))
local mixed = sorter.sorted(bankOf({ "Mystic wand", "Fire rune", "Staff of air" }), catOf, { "magic", "runes" })
check("categories in the plan's order", mixed[3].name == "Fire rune")
local upgrades = sorter.sorted(bankOf({ "Rune platebody + 3", "Rune full helm + 3", "Rune platebody" }), catOf)
check("smithing upgrades sort as their own set", names(upgrades) == "Rune platebody, Rune full helm + 3, "
    .. "Rune platebody + 3", names(upgrades))

local shuffled = bankOf({ "Black boots", "Black helm", "Black scimitar", "Black platebody" })
local desired = sorter.sorted(shuffled, catOf)
check("swaps needed (the helm is already in place)", sorter.swapsNeeded(shuffled, desired) == 2, sorter.swapsNeeded(shuffled, desired))
check("no swaps when sorted", sorter.swapsNeeded(desired, desired) == 0)

-- sortStep picks a swap that puts the right item in the first wrong place.
local sortRanges = guide.rangesFromSizes(shuffled, { { size = 4, display = 1 } })
local sortPlan = guide.planTidy(shuffled, sortRanges, tidyData)
local s = guide.sortStep(shuffled, sortRanges, sortPlan, tidyData, {}, {})
check("sort step found", s ~= nil and s.swapsLeft == 2)
check("sort step moves the first item into place", s and s.from.name == "Black scimitar" and s.to.name == "Black boots")
check("locked tabs aren't sorted", guide.sortStep(shuffled, sortRanges, sortPlan, tidyData, { [1] = true }, {}) == nil)
check("skipped tabs aren't sorted", s and guide.sortStep(shuffled, sortRanges, sortPlan, tidyData, {},
    { [s.key] = true }) == nil)
check("sort steps have the shared key", s and s.key == guide.sortKey(sortRanges[1], 1))

-- Picking a tab to sort first.
local twoTabs = bankOf({ "Black boots", "Black helm", "Fire rune", "Earth rune" })
local twoRanges = guide.rangesFromSizes(twoTabs, { { size = 2, display = 1, iconItemId = twoTabs[1].id },
    { size = 2, display = 2, iconItemId = twoTabs[3].id } })
local twoPlan = guide.planTidy(twoTabs, twoRanges, tidyData)
local firstSort = guide.sortStep(twoTabs, twoRanges, twoPlan, tidyData, {}, {})
check("tabs are sorted in tab bar order", firstSort and firstSort.bankTab == 1)
local picked = guide.sortStep(twoTabs, twoRanges, twoPlan, tidyData, {}, {}, guide.sortKey(twoRanges[2], 2))
check("a picked tab is sorted first", picked and picked.bankTab == 2)
check("tidy mode leaves the tab order alone", guide.orderStep(twoRanges, twoPlan) == nil)

-- Icons come from whatever each player owns.
local function iconOf(names, order)
    local icon = sorter.iconFor(bankOf(names), catOf, order)
    return icon and icon.name
end
check("a beginner's melee icon is their weapon", iconOf({ "Bronze full helm", "Bronze dagger", "Bronze chainbody" },
    { "melee" }) == "Bronze dagger")
check("the best weapon wins", iconOf({ "Bronze dagger", "Rune platebody + 3", "Dragon scimitar" }, { "melee" })
    == "Dragon scimitar")
check("gear with no weapon uses other gear", iconOf({ "Robust memento", "Deathstorm drape" }, { "necromancy" })
    == "Deathstorm drape")
check("a mixed tab uses its clearest kind of item", iconOf({ "A key", "Black platelegs (h1)", "Clue scroll (easy)" },
    { "quest", "clues" }) == "Clue scroll (easy)")
check("a magic tab shows a staff, not a rune", iconOf({ "Fire rune", "Nature rune", "Staff of air" },
    { "magic", "runes" }) == "Staff of air")
check("outfits beat leftovers for cosmetics", iconOf({ "Gas mask", "Desert shirt" }, { "cosmetic" }) == "Desert shirt")
check("logs beat fletching supplies", iconOf({ "Onyx bolt tips", "Maple logs", "Logs" }, { "woodcutting" })
    == "Maple logs")
check("an empty tab has no icon", sorter.iconFor({}, catOf, { "melee" }) == nil)

-- Settings ----------------------------------------------------------------------
settings.load("Tester")
check("default mode organises", settings.get("mode") == "fresh" and settings.get("maxTabs") == 14)
check("default plan is Recommended", settings.data.activePreset == "recommended" and #settings.data.plan == 14)
check("sorting inside tabs is on", settings.get("sortInside") == true)
settings.applyPreset("simple")
check("applying a style replaces the plan", #settings.data.plan == 4 and settings.data.activePreset == "simple")
local foodTab = settings.tabOfCategory("food")
settings.moveCategory("food", 1)
check("moving a category", settings.tabOfCategory("food") == 1 and foodTab ~= 1)
check("moving marks the plan custom", settings.data.activePreset == "custom")
check("custom shows in the style picker", presets.choices("custom")[1][1] == "custom")
check("no Custom choice for a real style", presets.choices("recommended")[1][1] == "recommended")
local count = 0
for _, group in ipairs(settings.data.plan) do
    for _, c in ipairs(group.categories) do if c == "food" then count = count + 1 end end
end
check("a category is only in one tab", count == 1, count)
check("saved per character", store["settings:Tester"] ~= nil)

-- Saves from older versions get the new plan and mode, keeping locks and rules.
store["settings:Old"] = { values = { mode = "tidy", maxTabs = 8, strictness = "strict" },
    plan = { { label = "Gear", categories = { "weapons", "armour" } } }, lockedTabs = { ["123"] = true },
    customRules = { { pattern = "x", category = "misc" } } }
settings.load("Old")
check("old save: mode becomes organise", settings.get("mode") == "fresh")
check("old save: 14 tabs", settings.get("maxTabs") == 14)
check("old save: recommended plan", #settings.data.plan == 14 and settings.data.activePreset == "recommended")
check("old save: keeps other settings", settings.get("strictness") == "strict")
check("old save: keeps locks and rules", settings.isTabLocked(123) and #settings.data.customRules == 1)
check("old save: marked current", settings.data.version == settings.VERSION)

store["settings:Odd"] = { version = settings.VERSION, values = { mode = "chaos", strictness = 3, maxTabs = 99 },
    lockedTabs = "nope" }
settings.load("Odd")
check("repair fixes an unknown mode", settings.get("mode") == "fresh" and settings.get("strictness") == "normal")
check("repair fixes an out-of-range number", settings.get("maxTabs") == 14)
check("repair fixes locks", type(settings.data.lockedTabs) == "table")

-- Editing the plan's tabs.
settings.load("Editor")
local tabCount = #settings.data.plan
settings.renameTab(2, "  Swords  ")
check("rename a tab", settings.data.plan[2].label == "Swords" and settings.data.activePreset == "custom")
settings.renameTab(2, "   ")
check("blank names are ignored", settings.data.plan[2].label == "Swords")
local added = settings.addTab("Slayer")
check("a new tab goes before the last", added == tabCount and settings.data.plan[added].label == "Slayer"
    and settings.data.plan[#settings.data.plan].label == "Everything else")
check("a new tab starts empty", #settings.data.plan[added].categories == 0)
check("moving a tab up", settings.moveTab(added, -1) == added - 1 and settings.data.plan[added - 1].label == "Slayer")
check("the last tab can't move", settings.moveTab(#settings.data.plan, -1) == #settings.data.plan)
check("nothing moves below the last tab", settings.moveTab(#settings.data.plan - 1, 1) == #settings.data.plan - 1)
local slayer = added - 1
settings.moveCategory("food", slayer)
settings.addItemRule(slayer, "  Enchanted GEM ")
check("item rules are saved in lower case", settings.data.plan[slayer].items[1] == "enchanted gem")
settings.addItemRule(slayer, "enchanted gem")
check("duplicate item rules are ignored", #settings.data.plan[slayer].items == 1)
settings.removeTab(slayer)
check("deleting a tab sends its categories to the last tab", settings.tabOfCategory("food") == #settings.data.plan)
check("deleting a tab", #settings.data.plan == tabCount)
settings.removeTab(#settings.data.plan)
check("the last tab can't be deleted", #settings.data.plan == tabCount)
settings.removeCategory("melee")
check("removing a category sends it to the last tab", settings.tabOfCategory("melee") == #settings.data.plan)
settings.addItemRule(1, "rope")
settings.removeItemRule(1, 1)
check("removing an item rule", #settings.data.plan[1].items == 0)
store["settings:Broken"] = { version = settings.VERSION, values = {}, plan = { { label = 5 }, "junk" } }
settings.load("Broken")
check("repair fixes broken tabs", settings.data.plan[1].label == "Tab 1" and type(settings.data.plan[2].categories) == "table")

settings.load("Locker")
settings.setTabLocked(4587, true)
check("locking a tab", settings.isTabLocked(4587) and not settings.isTabLocked(1))
check("locks are saved", store["settings:Locker"].lockedTabs["4587"] == true)
settings.setTabLocked(4587, false)
check("unlocking a tab", not settings.isTabLocked(4587))

settings.set("perCharacter", false)
check("shared settings written", store["settings"] ~= nil and store["meta"].perCharacter == false)

check("hover tips and backpack badges are on by default", settings.get("hoverTips") and settings.get("depositHelp"))
local heard = false
settings.onChange(function(key) if key == "all" then heard = true end end)
settings.setTabLocked(99, true)
settings.deleteAll("Tester")
local left = 0
for _ in pairs(store) do left = left + 1 end
check("deleting saved data clears everything", left == 0, left)
check("after deleting, settings are back to defaults", not settings.isTabLocked(99)
    and settings.data.activePreset == "recommended")
check("deleting tells the plugin to start over", heard)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
