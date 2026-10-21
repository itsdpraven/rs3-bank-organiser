-- Bank Organiser
-- Sorts your bank into sensible tabs, then puts each tab in order.
--   Organise my bank - follows a plan (by default 14 tabs: teleports and
--                      tools, a tab per combat style, food and potions,
--                      skills, quest items, cosmetics...), which you can
--                      adjust, creating tabs where needed.
--   Just tidy my tabs - keeps your tabs and moves only the items that
--                      clearly belong in another of them.
-- It works one tab at a time: every item to move glows green on your bank,
-- numbered in the order to drag them, the tab to drop them on is boxed in
-- yellow (or the "+" button, to start a new tab), and a banner on the bank
-- says what to do. Then it sorts each tab: drag the green item onto the
-- yellow one to swap them. Green is always "drag", yellow "drop here" and
-- blue "click". You drag; the plugin keeps count. Tabs can be locked so
-- they're left alone.
-- The plugin never moves items itself - plugins aren't allowed to act for you.
--
-- File overview:
--   src/bank.lua        reads the bank and each item's game data
--   src/bankui.lua      finds the tabs, slots and tab icons on screen
--   src/classifier.lua  + src/categories.lua: which category each item is
--   src/presets.lua     plan styles (which categories share a tab)
--   src/guide.lua       works out what to move, and the next swap to sort a tab
--   src/sorter.lua      the order items go in inside a tab
--   src/settings.lua    the player's settings, tab locks and plan
--   src/overlay.lua     draws the highlights, badges and banner on the bank
--   src/ui/...          the plugin window

local util = require("src/util")
local settings = require("src/settings")
local bank = require("src/bank")
local bankui = require("src/bankui")
local guide = require("src/guide")
local sorter = require("src/sorter")
local overlay = require("src/overlay")
local panel = require("src/ui/panel")
local settingsLayer = require("src/ui/settings_layer")

local COLOUR_RIGHT = 0x70E070   -- feedback: the item went to the right tab
local COLOUR_WRONG = 0xFF9060   -- feedback: it didn't
local GAME_STATE_GAME = 30      -- GameState.GAME: logged in and playing
pcall(function() GAME_STATE_GAME = GameState.GAME end)

local state = {
    characterName = nil, -- logged-in character, once known
    dirty = true,        -- bank or settings changed: work out what's next
    paused = false,
    ranges = {},         -- the bank's tabs (see guide.rangesFromSizes)
    viewKey = "",        -- which bank tabs are on screen, to notice tab switches
    skipped = {},        -- keys of steps skipped this session
    startTotal = 0,      -- most items seen still to move, for the progress bar
    sortStartTotal = 0,  -- most swaps seen still to make
    current = nil,       -- key of the step being worked on
    plan = nil,          -- the latest plan, while the bank is open
    misplaced = nil,     -- item IDs still to move at the last refresh (for feedback)
    present = nil,       -- item IDs in the bank at the last refresh
    hover = nil,         -- { slot, id } of the bank item under the cursor
    pick = nil,          -- { tab, id, ticks } while picking an item for a tab's rules
    languageNote = nil,  -- a warning when the game isn't in English
    ticks = 0,
}

-- Returns the logged-in character's display name, or nil if not available yet.
local function currentCharacterName()
    local ok, name = pcall(function()
        local me = PlayerList.Self()
        return me and me.displayName
    end)
    if ok and type(name) == "string" and name ~= "" then
        return name
    end
    return nil
end

-- Which bank tabs are on screen, e.g. "0100000" when tab 2 is open.
local function viewKey()
    local key = {}
    for k, range in ipairs(state.ranges) do
        key[k] = bankui.isSlotShown(range.first) and "1" or "0"
    end
    return table.concat(key)
end

local function plural(n, word)
    return string.format("%d %s%s", n, word, n == 1 and "" or "s")
end

-- One row per bank tab in tab bar order, then items not in a tab, then
-- planned new tabs, for the window's list.
local function tabRows(plan, step, sortStep)
    -- Each bank tab's step key: its move step if items still go in, else its
    -- sort step (clicking a row works on that tab next).
    local skippedTabs, stepKeyOf = {}, {}
    for _, tab in ipairs(plan.tabs) do
        if tab.bankTab and #tab.toMove > 0 then stepKeyOf[tab.bankTab] = tab.key end
    end
    for t, range in ipairs(state.ranges) do
        stepKeyOf[t] = stepKeyOf[t] or guide.sortKey(range, t)
        if state.skipped[stepKeyOf[t]] then skippedTabs[t] = true end
    end
    local report = {}
    for _, r in pairs(plan.report) do table.insert(report, r) end
    table.sort(report, function(a, b) return a.display < b.display end)

    local rows = {}
    if state.languageNote then
        table.insert(rows, { title = "Note", detail = state.languageNote, state = "locked" })
    end
    for _, r in ipairs(report) do
        local stateName, detail = "todo", nil
        if r.locked then
            stateName, detail = "locked", "Locked: left alone"
        elseif r.emptied then
            detail = "Not in the plan: everything moves out"
        else
            detail = r.reused and "Reused" or string.format("%d%% tidy", math.floor(r.tidy * 100 + 0.5))
            if r.strays > 0 then detail = detail .. ", " .. r.strays .. " to move out" end
            if r.incoming > 0 then detail = detail .. ", " .. r.incoming .. " to come in" end
            if r.strays == 0 and r.incoming == 0 then stateName = "done" end
            if skippedTabs[r.bankTab] then detail = detail .. " (skipped)" end
        end
        if (step and step.bankTab == r.bankTab) or (sortStep and sortStep.bankTab == r.bankTab) then
            stateName = "current"
        end
        table.insert(rows, {
            title = string.format("%d. %s (%d)", r.display, r.name, r.size),
            detail = detail, state = stateName,
            lockId = state.ranges[r.bankTab].iconItemId, locked = r.locked,
            iconId = plan.tabIcon and plan.tabIcon[r.bankTab] and plan.tabIcon[r.bankTab].id,
            stepKey = not r.locked and stepKeyOf[r.bankTab] or nil,
        })
    end
    if plan.unsorted then
        table.insert(rows, {
            title = string.format("Not in a tab (%d)", plan.unsorted.size),
            detail = plan.unsorted.strays > 0 and (plan.unsorted.strays .. " to put in tabs") or "Nothing to move",
            state = plan.unsorted.strays > 0 and "todo" or "done",
        })
    end
    for _, tab in ipairs(plan.tabs) do
        if not tab.bankTab then
            table.insert(rows, {
                title = "New tab: " .. tab.label,
                detail = plural(#tab.toMove, "item") .. " to move in"
                    .. (state.skipped[tab.key] and " (skipped)" or ""),
                state = (step == tab) and "current" or "todo",
                iconId = tab.icon and tab.icon.id,
                stepKey = tab.key,
            })
        end
    end
    return rows
end

-- A numbered badge for each tab icon, coloured by how tidy the tab is.
local function tabBadges(plan)
    local badges = {}
    for t, r in pairs(plan.report) do
        local component = state.ranges[t].component
        if component then
            local colour = overlay.BADGE_WORK
            if r.locked then
                colour = overlay.BADGE_LOCKED
            elseif r.strays == 0 and r.incoming == 0 and not r.emptied then
                colour = overlay.BADGE_TIDY
            end
            table.insert(badges, { component = component, text = tostring(r.display), colour = colour })
        end
    end
    return badges
end

-- Shows a message and hides everything on the bank.
local function idle(message, detail, rows)
    overlay.hide()
    state.current = nil
    panel.update({ message = message, detail = detail or "", ratio = 0 }, rows)
end

-- Where an item belongs, in a few words, e.g. "Goes in tab 3: Magic".
local function destinationText(itemId)
    local plan = state.plan
    if not plan then return nil end
    local d = plan.destination[itemId]
    if plan.mode == "tidy" then
        if not d then return "Stays where it is" end
        local range = state.ranges[d.bankTab]
        return range and string.format("Belongs in tab %d (%s)", range.display, plan.report[d.bankTab].name)
    end
    if not d then return "In a locked tab" end
    if d.done then return "In the right tab: " .. d.label end
    if d.bankTab and state.ranges[d.bankTab] then
        return string.format("Goes in tab %d: %s", state.ranges[d.bankTab].display, d.label)
    end
    return "Goes in a new tab: " .. d.label
end

-- After each drag (or deposit), says in the banner whether the item went to
-- the right place, by comparing which items still need to move with the last
-- refresh. Big changes (the bank opening, the plan changing) aren't drags,
-- so they're not commented on.
local function giveFeedback(plan, items, step)
    local present, nameOf, misplaced, where, icons = {}, {}, {}, {}, {}
    for _, item in ipairs(items) do
        present[item.id], nameOf[item.id] = true, item.name
    end
    for id, d in pairs(plan.destination) do
        if not d.done then misplaced[id] = true end
    end
    -- Which tab each misplaced item is in, by the tab's icon (0: not in a tab).
    for _, range in ipairs(state.ranges) do icons[range.iconItemId] = true end
    for _, item in ipairs(items) do
        if misplaced[item.id] then
            local t = guide.tabOf(state.ranges, item.slot)
            where[item.id] = t and state.ranges[t].iconItemId or 0
        end
    end
    local before, wasPresent, whereBefore, iconsBefore = state.misplaced, state.present, state.where, state.icons
    state.misplaced, state.present, state.where, state.icons = misplaced, present, where, icons
    if not before then return end

    local placed, wrong = {}, {}
    for id in pairs(before) do
        if present[id] and not misplaced[id] then table.insert(placed, id) end
    end
    for id in pairs(misplaced) do
        local from, to = whereBefore[id], where[id]
        if not before[id] then
            table.insert(wrong, id)
        elseif from ~= to and to ~= 0 and iconsBefore[to] and (from == 0 or icons[from]) then
            -- Still in the wrong place, but in another tab: it was dropped in
            -- the wrong one. (Only when both tabs are known before and after:
            -- a tab's icon changes when its first item moves.)
            table.insert(wrong, id)
        end
    end
    if #placed + #wrong == 0 or #placed + #wrong > 3 then return end
    if #wrong > 0 then
        local id = wrong[1]
        local verb = wasPresent[id] and "doesn't go there" or "deposited"
        overlay.flash(string.format("%s %s. %s", nameOf[id], verb, destinationText(id) or ""), COLOUR_WRONG, 4)
    elseif #placed == 1 then
        local left = step and #step.toMove or 0
        overlay.flash(string.format("%s is in the right tab%s", nameOf[placed[1]],
            left > 0 and string.format(" - %d to go", left) or ""), COLOUR_RIGHT, 2.5)
    else
        overlay.flash(#placed .. " items are in the right tab", COLOUR_RIGHT, 2.5)
    end
end

-- Badges for the backpack beside the bank: which tab each item belongs in
-- ("+" for a tab still to be made), to help deposit into the right tab.
local function backpackBadges(plan)
    local list = {}
    local ok, inv = pcall(function() return Inventory.Find(config.Inv.INV) end)
    if not ok or not inv or not inv.isValid then return list end
    local slots = inv:GetSlots() or {}
    for slot = 1, inv.slotCount do
        local s = slots[slot]
        if s and s.obj and s.obj.id and s.obj.id >= 0 then
            local item = bank.describe(bank.rawFromObj(s.obj), s.count or 1, 0)
            local tab = plan.tabFor(item)
            local range = tab and tab.bankTab and state.ranges[tab.bankTab]
            if tab then
                table.insert(list, { slot = slot, id = s.obj.id, text = range and tostring(range.display) or "+" })
            end
        end
    end
    return list
end

-- True when every tab, and the items not in a tab, are on screen (the
-- all-items view), so any item can be highlighted.
local function seesWholeBank(items)
    for _, range in ipairs(state.ranges) do
        if not bankui.isSlotShown(range.first) then return false end
    end
    local lastTab = state.ranges[#state.ranges]
    local lastItem = items[#items]
    if lastItem and lastTab and lastItem.slot > lastTab.last and not bankui.isSlotShown(lastTab.last + 1) then
        return false
    end
    return true
end

local function askForAllItems(badges, rows, ratio)
    overlay.show({ openTab = bankui.allItemsTab(), badges = badges,
        banner = "Click the all-items tab (blue box) to see your whole bank" })
    panel.update({ message = "Click the all-items tab (blue box) so you can see everything.",
        detail = "It's the first icon on the left of your tabs.", ratio = ratio or 0 }, rows)
end

-- Guidance for moving items into the right tab (step from guide.currentStep).
local function showMoveStep(plan, step, stepIndex, addButton, badges, rows, ratio)
    local target = step.bankTab and state.ranges[step.bankTab].component or (not step.bankTab and addButton)
    if not target then
        idle(step.bankTab and "Can't find that tab's icon. Try closing and reopening your bank."
            or "Your bank can't take another tab. Lower \"Most tabs\" under Edit plan.", "", rows)
        return
    end

    -- Numbered in the order they belong in the tab, so dragging them in
    -- order leaves the tab sorted.
    local ordered = sorter.sorted(step.toMove, function(item) return guide.categoryOf(item, settings.data) end,
        step.categories, step.icon)
    local highlights = {}
    for i, item in ipairs(ordered) do
        table.insert(highlights, { slot = item.slot, id = item.id, label = tostring(i) })
    end
    local n = #step.toMove
    local banner, message
    if step.bankTab then
        local range = state.ranges[step.bankTab]
        local name = plan.report[step.bankTab].name
        banner = string.format("Drag the %s onto tab %d (%s), in number order", plural(n, "green item"),
            range.display, name)
        message = string.format("Drag each green item onto the yellow tab: tab %d, your %s tab. "
            .. "Going in number order keeps the tab sorted.", range.display, name)
    else
        local iconName = step.icon and step.icon.name or "green item 1"
        banner = string.format("New %s tab: drag item 1 (%s) onto the yellow +", step.label, iconName)
        message = string.format("Start your %s tab: drag green item 1 (%s) onto the yellow + so it becomes the "
            .. "tab's icon, then the rest onto the new tab in number order.", step.label, iconName)
    end
    overlay.show({ items = highlights, target = target, badges = badges, banner = banner })
    panel.update({
        message = message,
        detail = string.format("Step %d of %d: %d to move here, %d in total", stepIndex, #plan.tabs, n,
            plan.toMoveTotal),
        ratio = ratio, canSkip = true,
    }, rows)
end

-- Guidance for moving one tab into its place in the tab bar (step from
-- guide.orderStep): drag the green tab onto the yellow one.
local function showOrderStep(plan, step, badges, rows)
    local from, to = state.ranges[step.from], state.ranges[step.to]
    local name = plan.report[step.from].name
    -- Further apart than the tab bar shows at once (both must be on screen):
    -- drop it on a tab part of the way; the same step comes back from there.
    local fit, hop = bankui.tabsInView(), false
    if fit and fit >= 3 and math.abs(from.display - to.display) > fit - 2 then
        local wanted = from.display + (to.display < from.display and -1 or 1) * (fit - 2)
        for _, range in ipairs(state.ranges) do
            if range.display == wanted then to, hop = range, true end
        end
    end
    overlay.show({ dragTab = from.component, target = to.component, badges = badges,
        banner = string.format("Tab order: drag tab %d (%s) onto tab %d%s (%s left)", from.display, name, to.display,
            hop and ", part of the way" or "", plural(step.movesLeft, "move")) })
    panel.update({
        message = hop and string.format("Tab %d (%s) goes further along than your tab bar shows at once, so take it "
            .. "part of the way: drag it (green) onto tab %d (yellow).", from.display, name, to.display)
            or string.format("Everything is in the right tab. Now put the tabs in order: drag tab %d (%s, green) "
            .. "onto tab %d (yellow).", from.display, name, to.display),
        detail = string.format("%s left to put the tabs in order", plural(step.movesLeft, "move")),
        ratio = 1, canSkip = true,
    }, rows)
end

-- Guidance for one swap that puts a tab in order (step from guide.sortStep).
local function showSortStep(plan, step, badges, rows)
    state.sortStartTotal = math.max(state.sortStartTotal, step.swapsTotal)
    local ratio = state.sortStartTotal > 0 and (1 - step.swapsTotal / state.sortStartTotal) or 1
    local range = state.ranges[step.bankTab]
    local name = plan.report[step.bankTab].name
    local isIcon = plan.tabIcon and plan.tabIcon[step.bankTab] == step.from
    local iconsOnly = step.key:find("^icon:") ~= nil
    -- Too far apart to drag in one go (both must be on screen): part of the way.
    local itemAt = {}
    for _, item in ipairs(bank.snapshot and bank.snapshot.items or {}) do itemAt[item.slot] = item end
    step = guide.withinReach(step, range, itemAt, bankui.gridShape(range.first, range.last))
    local banner, message
    if step.hop then
        banner = string.format("Tab %d: drag the green item onto the yellow one (part of the way)", range.display)
        message = string.format("%s goes further up tab %d (%s) than fits on screen, so take it part of the way: "
            .. "drag it (green) onto the yellow %s.", step.from.name, range.display, name, step.to.name)
    elseif isIcon then
        banner = string.format("Tab %d's icon: drag %s (green) onto the first item (yellow)", range.display,
            step.from.name)
        message = string.format("Make %s the icon of tab %d (%s): drag it (green) onto the yellow %s, the "
            .. "tab's first item, to swap them.", step.from.name, range.display, name, step.to.name)
    else
        banner = string.format("Sorting tab %d: drag the green item onto the yellow one (%s left)", range.display,
            plural(step.swapsLeft, "swap"))
        message = string.format("Now putting tab %d (%s) in order: drag the green %s onto the yellow %s to swap them.",
            range.display, name, step.from.name, step.to.name)
    end
    overlay.show({ items = { { slot = step.from.slot, id = step.from.id } },
        swapTo = { slot = step.to.slot, id = step.to.id }, badges = badges, banner = banner })
    panel.update({
        message = message,
        detail = iconsOnly and string.format("%s to fix first", plural(step.swapsTotal, "tab icon"))
            or string.format("%s left in this tab, %d in all", plural(step.swapsLeft, "swap"), step.swapsTotal),
        ratio = ratio, canSkip = true,
    }, rows)
end

-- The bank tab the player has open on its own, or nil in the all-items view.
local function openTab(items)
    local shown = nil
    for t, range in ipairs(state.ranges) do
        if bankui.isSlotShown(range.first) then
            if shown then return nil end
            shown = t
        end
    end
    if not shown then return nil end
    -- With a single tab, tell it apart from the all-items view by whether the
    -- items not in any tab are on show.
    if #state.ranges == 1 then
        local lastTab, lastItem = state.ranges[1], items[#items]
        if not (lastItem and lastItem.slot > lastTab.last) or bankui.isSlotShown(lastTab.last + 1) then return nil end
    end
    return shown
end

-- One tab is open on its own: first move out what belongs elsewhere (one
-- destination at a time), then put the tab in order, its icon first.
local function showTabFocus(plan, items, t, locked, addButton, badges, rows)
    local range = state.ranges[t]
    local name = plan.report[t].name
    if locked[t] then
        local message = string.format("Tab %d (%s) is locked, so it's left as it is.", range.display, name)
        overlay.show({ badges = badges, banner = message })
        panel.update({ message = message, detail = "Unlock it in the list to organise it.", ratio = 1 }, rows)
        return
    end

    -- First make the planned icon the tab's first item, if it's in the tab.
    local iconFix = guide.iconStep(items, state.ranges, plan, locked, {}, t)
    if iconFix then
        showSortStep(plan, iconFix, badges, rows)
        return
    end

    local dest, here, totalOut = guide.tabOutgoing(plan, state.ranges, t, addButton == nil)
    if dest then
        local target = dest.bankTab and state.ranges[dest.bankTab].component or addButton
        if not target then
            idle("Your bank can't take another tab. Lower \"Most tabs\" under Edit plan.", "", rows)
            return
        end
        local ordered = sorter.sorted(here, function(item) return guide.categoryOf(item, settings.data) end,
            dest.categories, dest.icon)
        local highlights = {}
        for i, item in ipairs(ordered) do
            table.insert(highlights, { slot = item.slot, id = item.id, label = tostring(i) })
        end
        local where = dest.bankTab
            and string.format("tab %d (%s)", state.ranges[dest.bankTab].display, plan.report[dest.bankTab].name)
            or string.format("a new %s tab (the yellow +)", dest.label)
        overlay.show({ items = highlights, target = target, badges = badges,
            banner = string.format("Tab %d: drag the %s onto %s", range.display, plural(#here, "green item"), where) })
        panel.update({
            message = string.format("Tidying tab %d (%s). The green items belong in %s: drag them onto the yellow "
                .. "box, in number order.", range.display, name, where),
            detail = string.format("%s to move out of this tab", plural(totalOut, "item")),
            ratio = 0,
        }, rows)
        return
    end

    -- Nothing to move out: put the tab in order (with sorting off, just its icon).
    local s = guide.sortStep(items, state.ranges, plan, settings.data, locked, {}, guide.sortKey(range, t),
        not settings.get("sortInside"))
    if s and s.bankTab == t then
        showSortStep(plan, s, badges, rows)
        return
    end
    local message = string.format("Tab %d (%s) is organised.", range.display, name)
    local incoming = plan.report[t].incoming
    overlay.show({ badges = badges, banner = message })
    panel.update({
        message = message,
        detail = incoming > 0 and string.format("%s for it are in other tabs: open them, or the all-items tab.",
            plural(incoming, "more item")) or "Open another tab, or the all-items tab for the whole plan.",
        ratio = 1,
    }, rows)
end

-- Works out what to do next from the latest bank contents and shows it.
local function refresh()
    state.dirty = false
    if not bankui.isOpen() then
        state.plan, state.misplaced = nil, nil
        idle("Open your bank to start.")
        return
    end
    if not bank.read() then
        idle("Waiting for your bank to load...")
        state.dirty = true
        return
    end

    local items = bank.snapshot.items
    local tabs, addButton = bankui.readTabs(items)
    if not tabs then
        state.ranges = {}
        askForAllItems({}, {}, 0)
        return
    end
    state.ranges = guide.rangesFromSizes(items, tabs)
    state.viewKey = viewKey()
    local locked = {}
    for k, range in ipairs(state.ranges) do
        if settings.isTabLocked(range.iconItemId) then locked[k] = true end
    end

    local fresh = settings.get("mode") == "fresh"
    local plan = fresh and guide.planTabs(items, state.ranges, settings.data, locked)
        or guide.planTidy(items, state.ranges, settings.data, locked)
    state.startTotal = math.max(state.startTotal, plan.toMoveTotal)
    local ratio = state.startTotal > 0 and (1 - plan.toMoveTotal / state.startTotal) or 1
    -- First, tabs whose planned icon is in them but not first: one swap each.
    local iconFix = guide.iconStep(items, state.ranges, plan, locked, state.skipped)
    -- Skipping means "later": once only skipped tabs are left, they come back.
    local step, stepIndex = nil, nil
    if not iconFix then
        local full = addButton == nil
        step, stepIndex = guide.currentStep(plan, state.skipped, state.focus, full)
        if not step and plan.toMoveTotal > 0 and next(state.skipped) then
            state.skipped = {}
            step, stepIndex = guide.currentStep(plan, state.skipped, state.focus, full)
        end
    end
    -- Once every item is in the right tab: put the tabs in the plan's order,
    -- then put each tab in order.
    local orderStep, sortStep = nil, nil
    local function finishingSteps()
        if fresh and settings.get("orderTabs") and not state.skipped.order then
            orderStep = guide.orderStep(state.ranges, plan)
        end
        if not orderStep and (settings.get("sortInside") or fresh) then
            -- With sorting off, only each tab's planned icon is put first.
            sortStep = guide.sortStep(items, state.ranges, plan, settings.data, locked, state.skipped, state.focus,
                not settings.get("sortInside"))
        end
    end
    if not iconFix and not step and plan.toMoveTotal == 0 then
        finishingSteps()
        if not orderStep and not sortStep and next(state.skipped) then
            state.skipped = {}
            finishingSteps()
        end
    end
    local activeStep = iconFix or step or orderStep or sortStep
    state.current = activeStep and activeStep.key
    local rows = tabRows(plan, step, iconFix or sortStep or (orderStep and { bankTab = orderStep.from }))
    local badges = tabBadges(plan)
    state.plan = plan
    giveFeedback(plan, items, step)
    overlay.setBackpack(settings.get("depositHelp") and backpackBadges(plan) or {})

    if state.paused then
        idle("Paused. Press Resume to carry on.", "", rows)
        return
    end
    -- A single tab open: work on that tab (if the player wants that).
    local open = settings.get("tabFocus") and openTab(items)
    if open then
        showTabFocus(plan, items, open, locked, addButton, badges, tabRows(plan, nil, { bankTab = open }))
        return
    end
    if not activeStep then
        local message, detail = nil, ""
        if plan.toMoveTotal > 0 then
            message = "Done, apart from the tabs you skipped."
        elseif fresh then
            message = string.format("All done! Your bank is organised into %d tabs.", #plan.tabs)
            detail = "To use a different icon, right-click a tab and choose Customise."
        else
            message = "All tidy! Nothing is out of place."
        end
        overlay.show({ badges = badges, banner = message })
        panel.update({ message = message, detail = detail, ratio = 1 }, rows)
        return
    end
    if orderStep then
        showOrderStep(plan, orderStep, badges, rows)
        return
    end
    if not seesWholeBank(items) then
        askForAllItems(badges, rows, ratio)
        return
    end
    if step then
        showMoveStep(plan, step, stepIndex, addButton, badges, rows, ratio)
    else
        showSortStep(plan, iconFix or sortStep, badges, rows)
    end
end

-- Actions for the window's buttons.
local ctx = {
    settings = settings,
    isPaused = function() return state.paused end,
    togglePause = function()
        state.paused = not state.paused
        state.dirty = true
    end,
    -- Leaves the current tab for later (it comes back when the rest are done).
    skip = function()
        if state.current then
            state.skipped[state.current] = true
            if state.focus == state.current then state.focus = nil end
            state.dirty = true
        end
    end,
    -- Works on the tab with this step key next (clicked in the tab list).
    focus = function(stepKey)
        state.skipped[stepKey] = nil
        state.focus = stepKey
        state.dirty = true
    end,
    toggleLock = function(iconItemId)
        settings.setTabLocked(iconItemId, not settings.isTabLocked(iconItemId))
    end,
    -- How many items of each category the bank holds (for the tab editor).
    categoryCounts = function()
        local counts = {}
        for _, item in ipairs(bank.snapshot and bank.snapshot.items or {}) do
            local category = guide.categoryOf(item, settings.data)
            counts[category] = (counts[category] or 0) + 1
        end
        return counts
    end,
    -- Picking an item for a tab's rules by pointing at it in the bank.
    startPick = function(tabIndex) state.pick = { tab = tabIndex, ticks = 0 } end,
    cancelPick = function() state.pick = nil end,
    isPicking = function() return state.pick ~= nil end,
    -- Deletes everything the plugin has saved, on every character.
    deleteData = function()
        settings.deleteAll(state.characterName)
        state.paused = false
    end,
    -- Names of bank items whose name contains `text`.
    matchItems = function(text)
        local names = {}
        for _, item in ipairs(bank.snapshot and bank.snapshot.items or {}) do
            if item.lname:find(text:lower(), 1, true) then table.insert(names, item.name) end
        end
        return names
    end,
}

-- Changes take effect on the next tick (never inside a click handler).
settings.onChange(function()
    state.dirty = true
    state.startTotal = 0
    state.sortStartTotal = 0
    state.skipped = {}
    guide.clearCache()
end)

-- Bank events --------------------------------------------------------------

local function isBackpack(invConfig)
    local ok, same = pcall(function() return invConfig.id == config.Inv.INV.id end)
    return ok and same
end

local function onBankChange(event)
    -- The backpack matters too while banking (its badges).
    if bank.isBankInv(event.inv) or (state.plan and isBackpack(event.inv)) then state.dirty = true end
end
Event.InventoryAdded.Subscribe("bankOrganiserAdded", onBankChange)
Event.InventoryUpdated.Subscribe("bankOrganiserUpdated", onBankChange)
Event.InventoryRemoved.Subscribe("bankOrganiserRemoved", function(event)
    if bank.isBankInv(event.inv) then idle("Open your bank to start.") end
end)

-- Bank settings (tab sizes, the open tab...) arrive as player variables.
Event.VarTransmit.Subscribe("bankOrganiserVars", function(event)
    util.try("var", function()
        local name = event.var.configName
        if type(name) == "string" and name:find("^BANK") then state.dirty = true end
    end)
end)

-- Logging out, hopping worlds or loading: clear everything until back in game.
Event.GameStateChanged.Subscribe("bankOrganiserGameState", function(event)
    util.try("game state", function()
        if event.newState ~= GAME_STATE_GAME then
            overlay.hide()
            state.plan, state.misplaced, state.hover, state.pick = nil, nil, nil, nil
        end
        state.dirty = true
    end)
end)

Event.WindowSizeChanged.Subscribe("bankOrganiserWindow", function()
    overlay.relayout()
end)

-- The bank item under the cursor: the game's top menu entry (the one a click
-- would use) says which component it's for. Only read, never changed.
Event.MiniMenuReady.Subscribe("bankOrganiserHover", function(event)
    util.try("hover", function()
        if not state.plan then
            state.hover = nil
            return
        end
        local entries = event.miniMenu.entries
        local top = entries and entries[#entries]
        local data = top and top.componentData
        local component = data and data.component
        local slot = component and bankui.slotOfComponent(component)
        local itemId = nil
        if slot then
            itemId = data.objConfig and data.objConfig.id or component.associatedObjectID
        end
        state.hover = (itemId and itemId >= 0) and { slot = slot, id = itemId } or nil
    end)
end)

-- Adds the picked item's name as a rule for the tab being edited.
local function finishPick(itemId)
    local tabIndex = state.pick.tab
    state.pick = nil
    for _, item in ipairs(bank.snapshot and bank.snapshot.items or {}) do
        if item.id == itemId then
            settings.addItemRule(tabIndex, item.name)
            overlay.flash("Added \"" .. item.name .. "\" to the tab", COLOUR_RIGHT, 3)
            break
        end
    end
    if panel.view == "tab" then panel.pendingView = "tab" end
end

-- The tip above the hovered bank item, and picking items by pointing at them
-- (keep the cursor on one item for a second).
local function updateHover()
    local h = state.hover
    if not (h and state.plan) then
        overlay.setHover(nil)
        return
    end
    if state.pick then
        if state.pick.id == h.id then
            state.pick.ticks = state.pick.ticks + 1
        else
            state.pick.id, state.pick.ticks = h.id, 0
        end
        overlay.setHover({ slot = h.slot, text = "Keep pointing to add this item..." })
        if state.pick.ticks >= 50 then finishPick(h.id) end
        return
    end
    overlay.setHover(settings.get("hoverTips") and { slot = h.slot, text = destinationText(h.id) or "" } or nil)
end

-- Once per game tick (0.6s): notice when a character logs in or switches.
Event.ServerLogic.Subscribe("bankOrganiserServerTick", function()
    util.try("character check", function()
        local name = currentCharacterName()
        if name and name ~= state.characterName then
            state.characterName = name
            settings.load(name)
            state.dirty = true
        end
    end)
end)

-- Every client tick (50 a second): keep the guide current and the highlights in place.
Event.Logic.Subscribe("bankOrganiserLogic", function()
    util.try("tick", function()
        state.ticks = state.ticks + 1
        -- Opening the bank or switching tabs doesn't always change the
        -- inventory, so check a few times a second.
        if state.ticks % 10 == 0 then
            local open = bankui.isOpen()
            if open ~= state.wasOpen or (open and viewKey() ~= state.viewKey) then
                state.wasOpen = open
                state.dirty = true
            end
        end
        if state.dirty then refresh() end
        updateHover()
        overlay.tick()
        panel.tick()
    end)
end)

-- Plugin windows -------------------------------------------------------------

Event.ContentLayerReady.Subscribe("bankOrganiserContent", function(event)
    util.try("build window", panel.build, event.component, ctx)
    state.dirty = true
end)

Event.SettingsLayerReady.Subscribe("bankOrganiserSettings", function(event)
    util.try("build settings", settingsLayer.build, event.component, ctx)
end)

-- Tidy up when the plugin is turned off or the game closes. (Settings are
-- saved as soon as they change, so there's nothing to save here.)
-- Must be global, not local, for the game to find it.
function PluginShutdown()
    overlay.hide()
end

-- The classifier reads English item names and options, so say so when the
-- game is set to another language.
local function languageNote()
    local ok, label = pcall(function()
        local option = game.options.Language
        return option:GetLabel(option.setting)
    end)
    if ok and type(label) == "string" and label ~= "" and not label:lower():find("english") then
        return "Sorting is tuned for the English game, so some items may be misplaced in " .. label .. "."
    end
    return nil
end

-- Start-up.
state.characterName = currentCharacterName()
settings.load(state.characterName)
state.languageNote = languageNote()
