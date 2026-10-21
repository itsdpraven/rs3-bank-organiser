-- guide.lua
-- Works out what to move, for either mode (see settings.lua), and then how
-- to put each tab in order.
--
-- The bank is stored tab by tab: tab 1's items first, then tab 2's, and so
-- on, with items not in any tab (shown at the top of the all-items view)
-- last. `ranges` describes the tabs in that stored order; each range also
-- knows its position in the tab bar (`display`), which is what the player
-- sees and what the plugin calls "tab N".
--
-- "Organise my bank" (planTabs) follows the plan:
--   1. Each planned tab (see settings.data.plan) holds some categories.
--      Planned tabs with fewer items than `minTabSize` join the biggest
--      planned tab of the same family (e.g. a small Necromancy tab joins
--      the biggest combat tab), or the last tab ("Everything else"); if
--      there are still more than `maxTabs`, the smallest join too.
--   2. Each planned tab takes over the existing bank tab that already holds
--      most of its items (biggest overlaps first, one each), so as little as
--      possible has to move. Bank tabs left over are reused for planned tabs
--      without one; only after that do planned tabs need a new tab.
--   3. Every item not in its planned tab's bank tab needs moving there,
--      including everything not in a tab yet.
--
-- "Just tidy my tabs" (planTidy) keeps the player's own tabs:
--   1. A category is at home in a tab when it makes up a fair share of the
--      tab (see STRICTNESS) - or its family does.
--   2. An item that isn't at home in its tab, or isn't in a tab at all, goes
--      to the tab holding most of its category, out of the tabs where it's
--      at home. If it's at home nowhere, it stays where it is.
--   3. Unknown items ("misc"), each tab's first item (it's the tab's icon) and
--      everything in a locked tab never move.
--
-- Then sortStep finds the next swap that puts a tab's items in order (see
-- sorter.lua). Everything is worked out again after every change to the
-- bank, so it stays right however the player moves things.
--
-- Pure Lua: takes plain tables (see bank.lua) and never calls the game API.

local classifier = require("src/classifier")
local categories = require("src/categories")
local sorter = require("src/sorter")

local guide = {}

-- How big a share of a tab a category (or family) needs to be at home there:
-- at least `share` of the tab's known items (and 2 or more items), or at
-- least `count` items whatever the share.
guide.STRICTNESS = {
    relaxed = { share = 0.10, count = 6 },
    normal = { share = 0.20, count = 10 },
    strict = { share = 0.35, count = 20 },
}

-- Item ID -> category, so a big bank isn't re-classified on every change.
local categoryCache = {}
function guide.clearCache()
    categoryCache = {}
end

function guide.categoryOf(item, settingsData)
    local category = categoryCache[item.id]
    if not category then
        category = classifier.classify(item, { customRules = settingsData.customRules or {} })
        categoryCache[item.id] = category
    end
    return category
end
local categoryOf = guide.categoryOf

-- Splits the bank into tabs from each tab's size, in stored order.
--   items - bank items sorted by slot
--   tabs  - { { size, display, iconItemId, component } ... } in stored order
-- Returns { { first, last, display, iconItemId, component } ... } (slots,
-- inclusive). Items after the last range aren't in a tab.
function guide.rangesFromSizes(items, tabs)
    local ranges = {}
    local firstSlot = items[1] and items[1].slot or 1
    for k, tab in ipairs(tabs) do
        if tab.size and tab.size > 0 then
            table.insert(ranges, { first = firstSlot, last = firstSlot + tab.size - 1,
                display = tab.display or k, iconItemId = tab.iconItemId, component = tab.component })
            firstSlot = firstSlot + tab.size
        end
    end
    return ranges
end

-- Returns the index of the range containing `slot`, or nil (not in a tab).
function guide.tabOf(ranges, slot)
    for k, range in ipairs(ranges) do
        if slot >= range.first and slot <= range.last then
            return k
        end
    end
    return nil
end

-- What each bank tab holds: per tab { size, known (non-misc items),
-- cat = {category -> n}, fam = {family -> n}, catTheme, famTheme,
-- items = { {item, category, family} } }. Index 0 is the unsorted section.
local function tabStats(items, ranges, settingsData)
    local rule = guide.STRICTNESS[settingsData.values.strictness] or guide.STRICTNESS.normal
    local function isTheme(count, total)
        return (count >= 2 and count / total >= rule.share) or count >= rule.count
    end
    local tabs = {}
    for t = 0, #ranges do
        tabs[t] = { size = 0, known = 0, cat = {}, fam = {}, catTheme = {}, famTheme = {}, items = {} }
    end
    for _, item in ipairs(items) do
        local t = guide.tabOf(ranges, item.slot) or 0
        local c = categoryOf(item, settingsData)
        local f = categories.family(c)
        local tab = tabs[t]
        tab.size = tab.size + 1
        table.insert(tab.items, { item = item, category = c, family = f })
        if c ~= "misc" then
            tab.known = tab.known + 1
            tab.cat[c] = (tab.cat[c] or 0) + 1
            tab.fam[f] = (tab.fam[f] or 0) + 1
        end
    end
    for t = 1, #ranges do
        local tab = tabs[t]
        for c, n in pairs(tab.cat) do tab.catTheme[c] = isTheme(n, tab.known) end
        for f, n in pairs(tab.fam) do tab.famTheme[f] = isTheme(n, tab.known) end
    end
    return tabs
end

-- The biggest theme in a map of counts: id, count (ties go to the lower id).
local function biggest(counts, isTheme)
    local bestId, bestN = nil, 0
    for id, n in pairs(counts) do
        if isTheme[id] and (n > bestN or (n == bestN and id < bestId)) then
            bestId, bestN = id, n
        end
    end
    return bestId, bestN
end

-- A short name for what a tab holds, e.g. "Food", "Gear" or "Runes, Potions".
local function nameOf(tab)
    if tab.size > 0 and tab.known == 0 then return "Miscellaneous" end
    local c1, n1 = biggest(tab.cat, tab.catTheme)
    local f1, m1 = biggest(tab.fam, tab.famTheme)
    if f1 and (not c1 or m1 >= 1.5 * n1) then
        return categories.familyLabel(f1)
    end
    if not c1 then return "Mixed" end
    local others = {}
    for c in pairs(tab.cat) do
        if c ~= c1 then others[c] = tab.cat[c] end
    end
    local c2 = biggest(others, tab.catTheme)
    if c2 then
        return categories.label(c1) .. ", " .. categories.label(c2)
    end
    return categories.label(c1)
end

-- A report row for the items not in any tab, or nil if there are none.
local function unsortedRow(tabs, moving)
    if tabs[0].size == 0 then return nil end
    return { bankTab = nil, display = 0, name = "Not in a tab", size = tabs[0].size, strays = moving,
        incoming = 0, locked = false, emptied = false,
        tidy = (tabs[0].size - moving) / tabs[0].size }
end

-- "Just tidy my tabs": see the top of this file.
--   items, ranges - bank items sorted by slot, and their tab ranges
--   settingsData  - settings.data (values.strictness, customRules)
--   locked        - { [range index] = true } for tabs to leave alone
-- Returns {
--   mode = "tidy",
--   tabs = { { key, label, bankTab, count, toMove = { items } } ... } - one
--          step per tab with items to take in, in tab bar order,
--   report = { { bankTab, display, name, size, tidy (0..1), strays,
--                incoming, locked, emptied } ... } - one per bank tab, plus
--            one for items not in a tab (bankTab = nil),
--   toMoveTotal, newTabs = 0, removedTabs = {},
--   destination = { [item id] = { bankTab } } for items that move,
--   tabFor(item) -> { bankTab } or nil: the tab any item belongs in,
-- }
function guide.planTidy(items, ranges, settingsData, locked)
    locked = locked or {}
    local tabs = tabStats(items, ranges, settingsData)

    -- Where a category's stragglers go: the unlocked tab, of those where the
    -- category is a theme, holding most of it; failing that, the same among
    -- tabs where its family is a theme. False if there's nowhere.
    local homes = {}
    local function homeOf(c, f)
        if homes[c] == nil then
            local best, bestCat, bestFam = false, -1, -1
            for pass = 1, 2 do
                for t = 1, #ranges do
                    local tab = tabs[t]
                    local isHome = (pass == 1 and tab.catTheme[c]) or (pass == 2 and tab.famTheme[f])
                    if not locked[t] and isHome then
                        local a, b = tab.cat[c] or 0, tab.fam[f] or 0
                        if a > bestCat or (a == bestCat and b > bestFam) then
                            best, bestCat, bestFam = t, a, b
                        end
                    end
                end
                if best then break end
            end
            homes[c] = best
        end
        return homes[c]
    end

    local plan = { mode = "tidy", tabs = {}, report = {}, toMoveTotal = 0, newTabs = 0, removedTabs = {} }
    local incoming = {}
    local function send(home, item)
        incoming[home] = incoming[home] or {}
        table.insert(incoming[home], item)
    end
    for t = 1, #ranges do
        local tab = tabs[t]
        local row = { bankTab = t, display = ranges[t].display, name = nameOf(tab), size = tab.size, strays = 0,
            incoming = 0, locked = locked[t] or false, emptied = false }
        if not locked[t] then
            for _, entry in ipairs(tab.items) do
                local c, f = entry.category, entry.family
                local atHome = c == "misc" or entry.item.slot == ranges[t].first
                    or tab.catTheme[c] or tab.famTheme[f]
                local home = not atHome and homeOf(c, f)
                if home then
                    send(home, entry.item)
                    row.strays = row.strays + 1
                end
            end
        end
        row.tidy = tab.size > 0 and (tab.size - row.strays) / tab.size or 1
        plan.report[t] = row
    end
    -- Items not in any tab go wherever their category lives.
    local unsortedMoving = 0
    for _, entry in ipairs(tabs[0].items) do
        local home = entry.category ~= "misc" and homeOf(entry.category, entry.family)
        if home then
            send(home, entry.item)
            unsortedMoving = unsortedMoving + 1
        end
    end
    plan.unsorted = unsortedRow(tabs, unsortedMoving)

    -- Where items go: only the ones that move are listed (the rest stay).
    plan.destination = {}
    for home, list in pairs(incoming) do
        for _, item in ipairs(list) do plan.destination[item.id] = { bankTab = home, done = false } end
    end
    -- The tab any item (e.g. one in the backpack) belongs in, or nil.
    function plan.tabFor(item)
        local c = categoryOf(item, settingsData)
        local home = c ~= "misc" and homeOf(c, categories.family(c))
        return home and { bankTab = home } or nil
    end

    local order = {}
    for t = 1, #ranges do table.insert(order, t) end
    table.sort(order, function(a, b) return ranges[a].display < ranges[b].display end)
    for _, t in ipairs(order) do
        local list = incoming[t]
        if list then
            plan.report[t].incoming = #list
            table.insert(plan.tabs, {
                key = "tab:" .. tostring(ranges[t].iconItemId or t),
                label = "Tab " .. ranges[t].display .. " (" .. plan.report[t].name .. ")",
                bankTab = t, count = tabs[t].size, toMove = list,
            })
            plan.toMoveTotal = plan.toMoveTotal + #list
        end
    end
    return plan
end

-- "Organise my bank": see the top of this file.
--   items, ranges - bank items sorted by slot, and their tab ranges
--   settingsData  - settings.data (plan, values.maxTabs, values.minTabSize)
--   locked        - { [range index] = true } for tabs to leave alone
-- Returns {
--   mode = "fresh",
--   tabs = { { key, label, count, bankTab = range index or nil (new tab),
--              categories = ordered category ids for the tab,
--              toMove = { items not yet in bankTab } } ... }  (plan order),
--   report = one row per bank tab, as for planTidy (plus `unsorted`),
--   tabCategories = { [range index] = ordered category ids },
--   removedTabs = { range indexes no planned tab uses },
--   newTabs = number of planned tabs that need a new bank tab,
--   toMoveTotal = total items still to move,
--   destination = { [item id] = { bankTab, label, done } } for every item,
--   tabFor(item) -> { bankTab, label } or nil: the planned tab for any item,
-- }
function guide.planTabs(items, ranges, settingsData, locked)
    locked = locked or {}
    local planGroups = settingsData.plan
    local values = settingsData.values
    local last = #planGroups

    local groupOfCategory = {}
    for g, group in ipairs(planGroups) do
        for _, categoryId in ipairs(group.categories) do groupOfCategory[categoryId] = g end
    end
    -- The planned tab for an item: a tab with a rule matching its name, else
    -- the tab holding its category, else the last tab.
    local function groupOf(item)
        for g, group in ipairs(planGroups) do
            for _, text in ipairs(group.items or {}) do
                if text ~= "" and item.lname:find(text, 1, true) then return g end
            end
        end
        return groupOfCategory[categoryOf(item, settingsData)] or last
    end

    -- Which planned tab and bank tab each item is in now (locked tabs aside).
    local placed, counts = {}, {}
    for _, item in ipairs(items) do
        local bankTab = guide.tabOf(ranges, item.slot)
        if not (bankTab and locked[bankTab]) then
            local g = groupOf(item)
            counts[g] = (counts[g] or 0) + 1
            table.insert(placed, { item = item, group = g, bankTab = bankTab })
        end
    end

    -- 1. Fold small planned tabs into a bigger one of the same family (or the
    --    last tab), then fold the smallest until within maxTabs.
    local final = {}
    for g = 1, last do final[g] = g end
    local function sizes()
        local s = {}
        for g = 1, last do
            if (counts[g] or 0) > 0 then s[final[g]] = (s[final[g]] or 0) + counts[g] end
        end
        return s
    end
    local function fold(g, into)
        for h = 1, last do
            if final[h] == g then final[h] = into end
        end
    end
    local minSize = values.minTabSize or 1
    -- The biggest other active planned tab in g's family that's big enough.
    local function familyTarget(g, s, needed)
        local family = planGroups[g].family
        local best, bestSize = nil, -1
        if family then
            for h = 1, last - 1 do
                local size = s[h] or 0
                if h ~= g and final[h] == h and planGroups[h].family == family and size >= needed
                    and size > bestSize then
                    best, bestSize = h, size
                end
            end
        end
        return best or last
    end
    local small = {}
    for g = 1, last - 1 do
        if (counts[g] or 0) > 0 and counts[g] < minSize then table.insert(small, g) end
    end
    table.sort(small, function(a, b) return counts[a] < counts[b] end)
    for _, g in ipairs(small) do
        local s = sizes()
        if final[g] == g and (s[g] or 0) < minSize then fold(g, familyTarget(g, s, minSize)) end
    end
    local maxTabs = values.maxTabs or 14
    while true do
        local s, active, smallest = sizes(), 0, nil
        for g, size in pairs(s) do
            active = active + 1
            if g ~= last and (not smallest or size < s[smallest]) then smallest = g end
        end
        if active <= maxTabs or not smallest then break end
        fold(smallest, familyTarget(smallest, s, 1))
    end
    for _, p in ipairs(placed) do p.group = final[p.group] end
    local groupSizes = sizes()

    -- The categories each planned tab ends up holding, in plan order (its
    -- own first, then those folded into it).
    local categoriesOf = {}
    for g = 1, last do
        if groupSizes[g] then
            local list = {}
            for _, c in ipairs(planGroups[g].categories) do table.insert(list, c) end
            for h = 1, last do
                if h ~= g and final[h] == g then
                    for _, c in ipairs(planGroups[h].categories) do table.insert(list, c) end
                end
            end
            categoriesOf[g] = list
        end
    end

    -- 2. Match planned tabs to bank tabs, biggest overlap first.
    local overlap = {}
    for _, p in ipairs(placed) do
        if p.bankTab then
            local key = p.group .. ":" .. p.bankTab
            overlap[key] = overlap[key] or { group = p.group, bankTab = p.bankTab, count = 0 }
            overlap[key].count = overlap[key].count + 1
        end
    end
    local candidates = {}
    for _, o in pairs(overlap) do table.insert(candidates, o) end
    table.sort(candidates, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        if a.bankTab ~= b.bankTab then return a.bankTab < b.bankTab end
        return a.group < b.group
    end)
    local bankTabOfGroup, groupOfBankTab = {}, {}
    for _, o in ipairs(candidates) do
        if not bankTabOfGroup[o.group] and not groupOfBankTab[o.bankTab] then
            bankTabOfGroup[o.group], groupOfBankTab[o.bankTab] = o.bankTab, o.group
        end
    end
    -- Bank tabs nothing matched are reused for planned tabs that would
    -- otherwise need a new one (in tab bar order), rather than emptied.
    local spare = {}
    for t = 1, #ranges do
        if not groupOfBankTab[t] and not locked[t] then table.insert(spare, t) end
    end
    table.sort(spare, function(a, b) return ranges[a].display < ranges[b].display end)
    local reused = {}
    for g = 1, last do
        if groupSizes[g] and not bankTabOfGroup[g] and #spare > 0 then
            local t = table.remove(spare, 1)
            bankTabOfGroup[g], groupOfBankTab[t], reused[t] = t, g, true
        end
    end

    -- 3. List what has to move, per planned tab.
    local plan = { mode = "fresh", tabs = {}, report = {}, tabCategories = {}, removedTabs = {}, newTabs = 0,
        toMoveTotal = 0 }
    local tabOfGroup = {}
    for g = 1, last do
        if groupSizes[g] then
            local label = planGroups[g].label
            local tab = { key = label, label = label, count = groupSizes[g], bankTab = bankTabOfGroup[g],
                categories = categoriesOf[g], toMove = {} }
            table.insert(plan.tabs, tab)
            tabOfGroup[g] = tab
            if tab.bankTab then
                plan.tabCategories[tab.bankTab] = categoriesOf[g]
            else
                plan.newTabs = plan.newTabs + 1
            end
        end
    end

    -- Each planned tab's icon: the item that best shows what it holds. A
    -- tab's icon is its first item, so it goes first when the tab is made
    -- or sorted.
    local itemsOfGroup = {}
    for _, p in ipairs(placed) do
        itemsOfGroup[p.group] = itemsOfGroup[p.group] or {}
        table.insert(itemsOfGroup[p.group], p.item)
    end
    plan.tabIcon = {}
    for g, tab in pairs(tabOfGroup) do
        tab.icon = sorter.iconFor(itemsOfGroup[g] or {}, function(item) return categoryOf(item, settingsData) end,
            categoriesOf[g])
        if tab.bankTab then plan.tabIcon[tab.bankTab] = tab.icon end
    end

    local strays, unsortedMoving = {}, 0
    plan.destination = {}
    for _, p in ipairs(placed) do
        local tab = tabOfGroup[p.group]
        local done = p.bankTab ~= nil and p.bankTab == tab.bankTab
        plan.destination[p.item.id] = { bankTab = tab.bankTab, label = tab.label, done = done }
        if not done then
            table.insert(tab.toMove, p.item)
            plan.toMoveTotal = plan.toMoveTotal + 1
            if p.bankTab then
                strays[p.bankTab] = (strays[p.bankTab] or 0) + 1
            else
                unsortedMoving = unsortedMoving + 1
            end
        end
    end

    -- 4. One report row per bank tab, plus one for items not in a tab.
    local stats = tabStats(items, ranges, settingsData)
    for t = 1, #ranges do
        local g = groupOfBankTab[t]
        local size = stats[t].size
        local row = { bankTab = t, display = ranges[t].display, size = size, strays = strays[t] or 0, incoming = 0,
            locked = locked[t] or false, emptied = false }
        if g then
            row.name = planGroups[g].label
            row.incoming = #tabOfGroup[g].toMove
            row.reused = reused[t] or false
        else
            row.name = nameOf(stats[t])
            row.emptied = not locked[t]
            if not locked[t] then table.insert(plan.removedTabs, t) end
        end
        row.tidy = size > 0 and (size - row.strays) / size or 1
        plan.report[t] = row
    end
    plan.unsorted = unsortedRow(stats, unsortedMoving)

    -- The planned tab for any item, e.g. one in the backpack: { bankTab, label }
    -- (bankTab nil for a tab still to be made), or nil if no planned tab
    -- would hold it yet.
    function plan.tabFor(item)
        local tab = tabOfGroup[final[groupOf(item)]]
        return tab and { bankTab = tab.bankTab, label = tab.label } or nil
    end
    return plan
end

-- The step to work on now: the one keyed `prefer` if it still has items to
-- move (the player picked it), else the first, in order, with items still to
-- move, skipping keys in `skipped`. Returns the step and its position.
function guide.currentStep(plan, skipped, prefer)
    skipped = skipped or {}
    for i, tab in ipairs(plan.tabs) do
        if prefer and tab.key == prefer and #tab.toMove > 0 then
            return tab, i
        end
    end
    for i, tab in ipairs(plan.tabs) do
        if #tab.toMove > 0 and not skipped[tab.key] then
            return tab, i
        end
    end
    return nil
end

-- Putting the tabs themselves in the plan's order ("Organise my bank" only),
-- once every item is in the right tab. Kept tabs stay where they were and new
-- tabs are added at the end of the tab bar, so without this the bar ends up
-- in a jumble. Tabs not in the plan (locked ones) go after the planned tabs.
-- Returns nil when the order is right, or { key = "order", from = range
-- index of the tab to drag, to = range index of the tab to drop it on,
-- movesLeft }. Dropping a tab on another puts it in that place, whether the
-- bank swaps or inserts.
function guide.orderStep(ranges, plan)
    if plan.mode ~= "fresh" then return nil end
    local current = {}
    for t = 1, #ranges do current[t] = t end
    table.sort(current, function(a, b) return ranges[a].display < ranges[b].display end)
    local desired, used = {}, {}
    for _, tab in ipairs(plan.tabs) do
        if tab.bankTab and not used[tab.bankTab] then
            table.insert(desired, tab.bankTab)
            used[tab.bankTab] = true
        end
    end
    for _, t in ipairs(current) do
        if not used[t] then table.insert(desired, t) end
    end
    for p = 1, #current do
        if current[p] ~= desired[p] then
            return { key = "order", from = desired[p], to = current[p],
                movesLeft = sorter.swapsNeeded(current, desired) }
        end
    end
    return nil
end

-- The key of the sort step for a tab (used to skip or pick it).
function guide.sortKey(range, index)
    return "sort:" .. tostring(range.iconItemId or index)
end

-- The next swap that puts a tab in order, once nothing needs to change tab.
-- Tabs are done in tab bar order (the one keyed `prefer` first, if the
-- player picked it); locked tabs and skipped keys are left. Each tab's
-- planned icon (plan.tabIcon) goes first; with `iconsOnly` that's all that's
-- done (for players who don't want their tabs sorted).
--   plan - from planTabs or planTidy (tabCategories gives each tab's order)
-- Returns nil when every tab is in order, or {
--   key, bankTab, label, from = item to drag, to = item to drop it on,
--   swapsLeft (this tab), swapsTotal (all tabs) }.
function guide.sortStep(items, ranges, plan, settingsData, locked, skipped, prefer, iconsOnly)
    locked = locked or {}
    skipped = skipped or {}
    local inTab = {}
    for _, item in ipairs(items) do
        local t = guide.tabOf(ranges, item.slot)
        if t then
            inTab[t] = inTab[t] or {}
            table.insert(inTab[t], item)
        end
    end
    local order = {}
    for t = 1, #ranges do table.insert(order, t) end
    table.sort(order, function(a, b)
        local pa, pb = guide.sortKey(ranges[a], a) == prefer, guide.sortKey(ranges[b], b) == prefer
        if pa ~= pb then return pa end
        return ranges[a].display < ranges[b].display
    end)

    local step, total = nil, 0
    local function categoryOfItem(item) return categoryOf(item, settingsData) end
    for _, t in ipairs(order) do
        local key = guide.sortKey(ranges[t], t)
        local current = inTab[t] or {}
        if not locked[t] and not skipped[key] and #current > 1 then
            local icon = plan.tabIcon and plan.tabIcon[t]
            local desired
            if iconsOnly then
                -- Only make the planned icon the tab's first item.
                desired = { table.unpack(current) }
                for i, it in ipairs(desired) do
                    if it == icon and i > 1 then
                        table.remove(desired, i)
                        table.insert(desired, 1, icon)
                        break
                    end
                end
            else
                desired = sorter.sorted(current, categoryOfItem, plan.tabCategories and plan.tabCategories[t], icon)
            end
            local swaps = sorter.swapsNeeded(current, desired)
            total = total + swaps
            if swaps > 0 and not step then
                for p = 1, #current do
                    if current[p] ~= desired[p] then
                        step = { key = key, bankTab = t, from = desired[p], to = current[p], swapsLeft = swaps }
                        break
                    end
                end
            end
        end
    end
    if step then step.swapsTotal = total end
    return step
end

return guide
