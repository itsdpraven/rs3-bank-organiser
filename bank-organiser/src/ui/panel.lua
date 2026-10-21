-- panel.lua
-- The plugin window. Three views:
--
--   Main                               Edit plan                    Edit tab
--   Bank Organiser                     [Back]  Edit plan            [Back]  Tab 3: Ranged
--   [ what to do now ]                 Mode   < Organise my bank >  Name [Ranged    ] [Rename]
--   [=====progress=====]               Style  < Recommended >       [Move up][Move down][Delete]
--   Step 1 of 3: 5 to move here        Your tabs                    Holds
--   1. Melee (51)            [Lock]    1. Teleports & tools [Edit]  Ranged gear (12)   [Remove]
--      92% tidy, 2 to move out         2. Melee             [Edit]  Add < Food (tab 7) >
--   [Pause][Skip for now][Edit plan]   [Add a tab]   ...            Items by name
--                                                                   "dragon"           [Remove]
--                                                                   [          ]       [Add]
--
-- The real guidance is drawn on the bank itself (overlay.lua); this window
-- says what's happening, lists every tab, and lets the player lock tabs and
-- adjust how the plugin decides. A fourth view, Q&A (the button at the top
-- right), answers the questions players ask most.

local util = require("src/util")
local widgets = require("src/ui/widgets")
local presets = require("src/presets")
local categories = require("src/categories")

local panel = {}


-- Sizes come from the font (see widgets.lua), so everything scales together.
local LINE = widgets.LINE         -- one line of text
local ROW = widgets.ROW           -- a button or picker
local TAB_ROW = 2 * LINE + 2      -- a title with a detail line under it
local GAP = widgets.PAD
local BUTTON_W = 54               -- small buttons beside a row (Lock, Edit, Remove)
local ICON_W = 34                 -- an item picture at the start of a tab row
local COLOUR_LOCKED = 0x909090

panel.view = "main"
panel.parts = nil
panel.status = { message = "Open your bank to start.", detail = "", ratio = 0 }
panel.rows = {}

-- Main view ----------------------------------------------------------------

-- One tab: name and size, a line about how tidy it is, and a Lock button.
local function tabRow(viewport, row)
    local holder = ui.Layer.new(viewport)
    local colour = widgets.COLOUR_TEXT
    if row.state == "done" then colour = widgets.COLOUR_GOOD end
    if row.state == "current" then colour = widgets.COLOUR_HEADING end
    if row.state == "locked" then colour = COLOUR_LOCKED end
    local right = row.lockId and (BUTTON_W + GAP) or 0

    -- The tab's planned icon on the left (else its current one, its first item).
    local left = 0
    local iconId = row.iconId or row.lockId
    local icon = iconId and widgets.itemIcon(holder, iconId)
    if icon then
        icon:SetSize(ICON_W, TAB_ROW - 2)
        left = ICON_W + GAP
    end
    local title = widgets.text(holder, row.title, { colour = colour })
    title:SetPos(left, 0)
    title:SetSize(-(right + left), LINE, 1.0, 0.0)
    local detail = widgets.text(holder, row.detail or "", { colour = widgets.COLOUR_MUTED })
    detail:SetPos(left + 10, LINE)
    detail:SetSize(-(right + left + 10), LINE, 1.0, 0.0)

    -- Clicking a tab works on it next (even one that was skipped).
    if row.stepKey then
        local stepKey = row.stepKey
        for _, part in ipairs({ title, detail }) do
            part:Subscribe(ui.Hook.ONCLICK, function() util.try("pick tab", panel.ctx.focus, stepKey) end)
        end
    end

    if row.lockId then
        local lockId = row.lockId
        local button = widgets.button(holder, row.locked and "Unlock" or "Lock",
            function() panel.ctx.toggleLock(lockId) end)
        button:SetPos(-BUTTON_W, math.floor((TAB_ROW - ROW) / 2), 1.0, 0.0)
        button:SetSize(BUTTON_W, ROW)
    end
    return holder
end

local function fillTabList(p)
    p.area.clear()
    for _, row in ipairs(panel.rows) do
        p.area.add(tabRow(p.area.viewport, row), TAB_ROW, 2)
    end
    p.area.layout()
end

-- Updates the main view.
--   status = { message, detail, ratio (0..1), canSkip }
--   rows   = { { title, detail, state = "done" | "current" | "todo" | "locked",
--                lockId = the tab's current icon item id (or nil: no Lock button),
--                locked, iconId = the planned icon to show, stepKey = clicking
--                the row works on this step next } ... }
function panel.update(status, rows)
    panel.status = status
    panel.rows = rows or panel.rows
    local p = panel.parts
    if not p then return end
    local ok = pcall(function()
        p.message.content = status.message or ""
        p.detail.content = status.detail or ""
        p.fill:SetSize(0, 4, util.clamp(status.ratio or 0, 0, 1), 0.0)
        p.pause.label = panel.ctx.isPaused() and "Resume" or "Pause"
        p.skip.hidden = not status.canSkip
        fillTabList(p)
    end)
    if not ok then panel.parts = nil end -- the window was closed
end

local function buildMain(root, ctx)
    local p = {}
    local y = GAP

    local title = widgets.text(root, "Bank Organiser", { colour = widgets.COLOUR_HEADING, heading = true })
    title:SetPos(GAP, y)
    title:SetSize(-(3 * GAP + BUTTON_W), LINE + 2, 1.0, 0.0)
    local help = widgets.button(root, "Q&A", function() panel.pendingView = "help" end)
    help:SetPos(-(GAP + BUTTON_W), y - 2, 1.0, 0.0)
    help:SetSize(BUTTON_W, LINE + 4)
    y = y + LINE + 4

    p.message = widgets.text(root, "", { colour = 0xFFFFFF, lines = 3 })
    p.message:SetPos(GAP, y)
    p.message:SetSize(-2 * GAP, 3 * LINE, 1.0, 0.0)
    y = y + 3 * LINE + 2

    local track = widgets.rect(root, 0x000000, 0.5, true)
    track:SetPos(GAP, y)
    track:SetSize(-2 * GAP, 4, 1.0, 0.0)
    local barHolder = ui.Layer.new(root)
    barHolder:SetPos(GAP, y)
    barHolder:SetSize(-2 * GAP, 4, 1.0, 0.0)
    p.fill = widgets.rect(barHolder, widgets.COLOUR_GOOD, 0.9, true)
    p.fill:SetSize(0, 4, 0.0, 0.0)
    y = y + 6

    p.detail = widgets.text(root, "", { colour = widgets.COLOUR_MUTED })
    p.detail:SetPos(GAP, y)
    p.detail:SetSize(-2 * GAP, LINE, 1.0, 0.0)
    y = y + LINE + GAP

    -- Buttons along the bottom; the tab list fills the space in between.
    local function third(index, label, fn)
        local b = widgets.button(root, label, fn)
        b:SetPos(GAP + (index - 1) * 2, -(ROW + GAP), (index - 1) / 3, 1.0)
        b:SetSize(-(GAP * 2 / 3 + 4), ROW, 1 / 3, 0.0)
        return b
    end
    p.pause = third(1, "Pause", function() ctx.togglePause() end)
    p.skip = third(2, "Skip for now", function() ctx.skip() end)
    third(3, "Edit plan", function() panel.pendingView = "plan" end)

    p.area = widgets.scrollArea(root)
    p.area.viewport:SetPos(GAP, y)
    p.area.viewport:SetSize(-2 * GAP, -(y + ROW + 2 * GAP), 1.0, 1.0)

    panel.parts = p
    panel.update(panel.status, panel.rows)
end


-- Editing screens ----------------------------------------------------------------

local MODE_HELP = {
    tidy = "Keeps your tabs. Only moves items that belong in another of your tabs.",
    fresh = "Sorts your whole bank into tabs following a plan style, keeping tabs that already fit.",
}
local STRICTNESS_HELP = {
    relaxed = "Only moves items that are clearly lost.",
    normal = "Moves items that don't fit with the rest of their tab.",
    strict = "Only each tab's main kinds of item stay put.",
}

-- A screen with a Back button, a title and a scrolling list of rows.
-- Returns helpers for adding rows to it.
local function editorPage(root, titleText, backView)
    local back = widgets.button(root, "Back", function() panel.pendingView = backView end)
    back:SetPos(GAP, 4)
    back:SetSize(56, ROW)
    local title = widgets.text(root, titleText, { colour = widgets.COLOUR_HEADING })
    title:SetPos(GAP + 62, 4)
    title:SetSize(-(2 * GAP + 62), ROW, 1.0, 0.0)

    local area = widgets.scrollArea(root)
    area.viewport:SetPos(GAP, ROW + 10)
    area.viewport:SetSize(-2 * GAP, -(ROW + 10 + GAP), 1.0, 1.0)
    local v = area.viewport
    local page = { area = area, viewport = v }

    function page.heading(text) area.add(widgets.heading(v, text), LINE + 4, 2) end
    function page.help(text) area.add(widgets.text(v, text, { colour = widgets.COLOUR_MUTED, lines = 2 }), 2 * LINE) end

    -- A labelled picker on one row: label on the left, picker on the right.
    function page.pickerRow(labelText, choices, value, onChange)
        local row = ui.Layer.new(v)
        local label = widgets.text(row, labelText)
        label:SetSize(-4, ROW, 0.4, 0.0)
        local picker = widgets.picker(row, choices, value, onChange)
        picker:SetPos(0, 0, 0.4, 0.0)
        picker:SetSize(0, ROW, 0.6, 0.0)
        area.add(row, ROW, 3)
    end

    -- A row of buttons sharing the width: { { label, onPress } ... }.
    function page.buttons(list)
        local row = ui.Layer.new(v)
        for i, entry in ipairs(list) do
            local b = widgets.button(row, entry[1], entry[2])
            b:SetPos((i - 1) * 2, 0, (i - 1) / #list, 0.0)
            b:SetSize(-4, ROW, 1 / #list, 0.0)
        end
        area.add(row, ROW, 3)
    end

    -- Text on the left (a title and an optional muted line under it) and an
    -- optional button on the right.
    function page.itemRow(titleText, detailText, buttonLabel, onPress, colour)
        local height = detailText and TAB_ROW or ROW
        local row = ui.Layer.new(v)
        local right = buttonLabel and (BUTTON_W + GAP) or 0
        local t = widgets.text(row, titleText, { colour = colour })
        t:SetSize(-right, detailText and LINE or ROW, 1.0, 0.0)
        if detailText then
            local d = widgets.text(row, detailText, { colour = widgets.COLOUR_MUTED })
            d:SetPos(10, LINE)
            d:SetSize(-(right + 10), LINE, 1.0, 0.0)
        end
        if buttonLabel then
            local b = widgets.button(row, buttonLabel, onPress)
            b:SetPos(-BUTTON_W, detailText and math.floor((TAB_ROW - ROW) / 2) or 0, 1.0, 0.0)
            b:SetSize(BUTTON_W, ROW)
        end
        area.add(row, height, 2)
    end

    -- A text box with a button beside it. onPress(text) gets what was typed;
    -- pressing Enter does the same.
    function page.inputRow(content, buttonLabel, onPress)
        local typed = content or ""
        local row = ui.Layer.new(v)
        local field = widgets.input(row, typed, function(text, submitted)
            typed = text
            if submitted then onPress(typed) end
        end)
        field:SetSize(-(BUTTON_W + GAP), ROW, 1.0, 0.0)
        local b = widgets.button(row, buttonLabel, function() onPress(typed) end)
        b:SetPos(-BUTTON_W, 0, 1.0, 0.0)
        b:SetSize(BUTTON_W, ROW)
        area.add(row, ROW, 3)
    end

    -- A paragraph that wraps over as many lines as it needs (worked out from
    -- the width, as text can't be measured).
    function page.paragraph(text, colour)
        local width = 0
        pcall(function() width = v.width end)
        if not width or width <= 0 then width = 280 end
        local perLine = math.max(20, math.floor((width - 10) / 6.5))
        local lines = math.max(1, math.ceil(#text / perLine))
        area.add(widgets.text(v, text, { colour = colour, lines = lines }), lines * LINE, 6)
    end

    function page.finish()
        area.add(widgets.text(v, "Scroll with the mouse wheel or swipe.", { colour = widgets.COLOUR_MUTED }), LINE)
        area.layout()
    end
    return page
end

-- What a planned tab holds, on one line, e.g. "Melee gear, Ranged gear".
local function contentsLine(tab)
    local labels = {}
    for _, categoryId in ipairs(tab.categories) do table.insert(labels, categories.label(categoryId)) end
    for _, text in ipairs(tab.items or {}) do table.insert(labels, "\"" .. text .. "\"") end
    return #labels > 0 and table.concat(labels, ", ") or "Nothing yet"
end

local function buildPlanEditor(root, ctx)
    local page = editorPage(root, "Edit plan", "main")
    local settings = ctx.settings

    page.heading("Mode")
    local mode = settings.get("mode")
    page.pickerRow("Mode", settings.byKey.mode.choices, mode, function(value)
        settings.set("mode", value)
        panel.pendingView = "plan" -- redraw with that mode's options
    end)
    page.help(MODE_HELP[mode] or "")

    if mode == "tidy" then
        page.heading("Tidy my tabs")
        local strictness = settings.get("strictness")
        page.pickerRow("How picky", settings.byKey.strictness.choices, strictness, function(value)
            settings.set("strictness", value)
            panel.pendingView = "plan"
        end)
        page.help(STRICTNESS_HELP[strictness] or "")
        page.help("To leave a tab alone, press Lock next to it on the main screen.")
    else
        page.heading("Plan style")
        local active = settings.data.activePreset
        page.pickerRow("Style", presets.choices(active), active, function(presetId)
            settings.applyPreset(presetId)
            panel.pendingView = "plan" -- redraw with the new plan
        end)
        local preset = presets.find(active)
        page.help(preset and preset.description or "Your own version of a style.")

        page.heading("Your tabs")
        for i, tab in ipairs(settings.data.plan) do
            page.itemRow(i .. ". " .. tab.label, contentsLine(tab), "Edit", function()
                panel.editTab = i
                panel.pendingView = "tab"
            end)
        end
        page.buttons({ { "Add a tab", function()
            panel.editTab = settings.addTab("New tab")
            panel.pendingView = "tab"
        end } })
        page.help("Edit a tab to rename it, move it, or choose what goes in it.")

        local function numberChoices(list)
            local out = {}
            for _, n in ipairs(list) do table.insert(out, { n, tostring(n) }) end
            return out
        end
        page.pickerRow("Most tabs", numberChoices({ 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 }), settings.get("maxTabs"),
            function(n) settings.set("maxTabs", n) end)
        page.pickerRow("Smallest tab", numberChoices({ 1, 2, 3, 5, 8, 10, 15, 20, 30 }), settings.get("minTabSize"),
            function(n) settings.set("minTabSize", n) end)
        page.help("A tab with fewer items than this joins a similar tab (or the last one).")
        page.pickerRow("Tab order", { { true, "Plan order" }, { false, "Leave as is" } }, settings.get("orderTabs"),
            function(value) settings.set("orderTabs", value) end)
        page.help("Once everything is in the right tab, helps you drag the tabs into the plan's order.")
    end

    page.heading("Inside each tab")
    page.pickerRow("Sort items", { { true, "Yes" }, { false, "No" } }, settings.get("sortInside"),
        function(value) settings.set("sortInside", value) end)
    page.help("Once everything is in the right tab, puts each tab in order: sets together, best last.")

    page.heading("On the bank")
    page.pickerRow("Open a tab", { { true, "Work on it" }, { false, "Ask for all" } }, settings.get("tabFocus"),
        function(value) settings.set("tabFocus", value) end)
    page.help("Opening one tab tidies just that tab: what belongs elsewhere moves out, then it's put in order.")
    page.pickerRow("Tips on hover", { { true, "Yes" }, { false, "No" } }, settings.get("hoverTips"),
        function(value) settings.set("hoverTips", value) end)
    page.pickerRow("Backpack tabs", { { true, "Yes" }, { false, "No" } }, settings.get("depositHelp"),
        function(value) settings.set("depositHelp", value) end)
    page.help("Point at a bank item to see where it goes; backpack items show the tab they belong in.")

    page.heading("Saving")
    page.pickerRow("Per character", { { true, "Yes" }, { false, "No" } }, settings.get("perCharacter"),
        function(value) settings.set("perCharacter", value) end)
    -- Deleting needs a second press, so it can't happen by accident.
    if panel.confirmDelete then
        page.buttons({
            { "Yes, delete it all", function()
                panel.confirmDelete = false
                ctx.deleteData()
                panel.pendingView = "plan"
            end },
            { "Cancel", function()
                panel.confirmDelete = false
                panel.pendingView = "plan"
            end },
        })
        page.help("This deletes your plan, tab locks and settings for every character on this computer.")
    else
        page.buttons({ { "Delete saved data", function()
            panel.confirmDelete = true
            panel.pendingView = "plan"
        end } })
        page.help("Everything is saved only on this computer. Nothing is sent anywhere.")
    end
    page.finish()
end

-- One planned tab: its name, position, categories and item rules.
local function buildTabEditor(root, ctx)
    local settings = ctx.settings
    local plan = settings.data.plan
    local index = panel.editTab
    local tab = plan[index]
    if not tab then
        panel.pendingView = "plan"
        return
    end
    local isLast = index == #plan
    local page = editorPage(root, "Tab " .. index .. ": " .. tab.label, "plan")
    local function redraw() panel.pendingView = "tab" end

    page.heading("Name")
    page.inputRow(tab.label, "Rename", function(text)
        settings.renameTab(index, text)
        redraw()
    end)
    if isLast then
        page.help("The last tab takes everything not placed in another tab.")
    else
        page.buttons({
            { "Move up", function() panel.editTab = settings.moveTab(index, -1); redraw() end },
            { "Move down", function() panel.editTab = settings.moveTab(index, 1); redraw() end },
            { "Delete", function()
                settings.removeTab(index)
                panel.pendingView = "plan"
            end },
        })
    end

    page.heading("Holds")
    local counts = ctx.categoryCounts()
    for _, categoryId in ipairs(tab.categories) do
        local title = string.format("%s (%d in your bank)", categories.label(categoryId), counts[categoryId] or 0)
        if isLast then
            page.itemRow(title)
        else
            page.itemRow(title, nil, "Remove", function()
                settings.removeCategory(categoryId)
                redraw()
            end)
        end
    end
    if #tab.categories == 0 then page.help("No categories yet: add one below, or add items by name.") end

    -- Every category not already here, with the tab it's in now.
    local choices = {}
    for _, categoryId in ipairs(categories.DEFAULT_ORDER) do
        local current = settings.tabOfCategory(categoryId)
        if current ~= index then
            table.insert(choices, { categoryId, string.format("%s (tab %d)", categories.label(categoryId), current) })
        end
    end
    if #choices > 0 then
        local chosen = choices[1][1]
        page.pickerRow("Add", choices, chosen, function(value) chosen = value end)
        page.buttons({ { "Add this category", function()
            settings.moveCategory(chosen, index)
            redraw()
        end } })
        page.help("Moves the category here from the tab it's in now.")
    end

    page.heading("Items by name")
    for k, text in ipairs(tab.items or {}) do
        local matches = ctx.matchItems(text)
        local detail = #matches == 0 and "Nothing in your bank matches"
            or (#matches .. " in your bank: " .. table.concat(matches, ", ", 1, math.min(3, #matches)))
        page.itemRow("\"" .. text .. "\"", detail, "Remove", function()
            settings.removeItemRule(index, k)
            redraw()
        end)
    end
    page.inputRow("", "Add", function(text)
        settings.addItemRule(index, text)
        redraw()
    end)
    page.help("Any item whose name contains this text goes in this tab, whatever kind of item it is.")
    if ctx.isPicking() then
        page.itemRow("Point at an item in your bank for a second to add it.", nil, "Cancel", function()
            ctx.cancelPick()
            redraw()
        end, widgets.COLOUR_HEADING)
    else
        page.buttons({ { "Pick from bank", function()
            ctx.startPick(index)
            redraw()
        end } })
    end
    page.finish()
end

-- Questions and answers ---------------------------------------------------------
-- Each entry: a question, then its answer as one or more paragraphs.

local QUESTIONS = {
    { "What do the colours mean?", {
        "Green: drag this. Yellow: drop it here. Blue: click this.",
        "Numbers on green items are the order to drag them in. When there's just one thing to drag, a dotted "
            .. "trail runs from it to where it goes." } },
    { "How does it decide where things go?", {
        "Every item gets a kind (melee gear, runes, logs, quest items...) from the game's own item details: its "
            .. "Grand Exchange category, combat style and type. Your plan says which kinds share a tab. Change it "
            .. "under Edit plan, or send items by name to a tab." } },
    { "How is each tab put in order?", {
        "First the tab's icon item, then each kind in the order the plan lists them (Magic: gear, then runes). "
            .. "Within each kind:",
        "Gear: by level, lowest first, each set together: weapon, off-hand, head, body, legs, hands, feet, "
            .. "shield, cape, neck, ring.",
        "Runes: elemental, combination, then the rest, with Necromancy runes last.",
        "Potions: every dose of a potion together, from 4 doses down to 1.",
        "Food: by how much it heals. Herblore: grimy herbs, clean herbs, unfinished potions, then the rest.",
        "Skilling supplies: in the order you use them (logs, then bows; ores, then bars), then by level.",
        "Clues: easy to master. Quest items: by quest. Cosmetics: by outfit." } },
    { "Why drag in number order?", {
        "An item dropped on a tab goes to the end of it. Dragging in number order leaves the tab sorted "
            .. "already, so there's less to do afterwards." } },
    { "What does \"part of the way\" mean?", {
        "In a big tab, the item and where it goes can be further apart than fits on screen, so they can't be "
            .. "dragged in one go. Drop it on the yellow item part of the way; it's asked for again from there." } },
    { "There's no yellow box on my tabs?", {
        "Your tab bar has more tabs than it can show. The plugin says so at the top of your items: click the "
            .. "blue arrow at the end of the tab bar to scroll the tabs." } },
    { "Will it delete my tabs?", {
        "No. It builds on the tabs you have: tabs that fit are kept, tabs that fit nothing are reused, and a "
            .. "new tab is only suggested when needed. A tab only goes when you've moved everything out of it." } },
    { "What does Lock do?", {
        "A locked tab is left exactly as it is: nothing moves in or out and it isn't sorted. Locked tabs still "
            .. "count towards the game's 14 tabs, so the plan uses fewer." } },
    { "What does Skip for now do?", {
        "Leaves the current tab for later. Skipped tabs come back once the rest are done. Click a tab in the "
            .. "list to work on it straight away." } },
    { "Can I tidy just one tab?", {
        "Yes: open that tab on its own. Anything that belongs elsewhere is moved out first, then the tab is put "
            .. "in order. Open the all-items tab to follow the whole plan. (Turn this off under Edit plan: "
            .. "Open a tab.)" } },
    { "Can it move the items for me?", {
        "No. Plugins aren't allowed to act for you, so it shows you what to do and you make every drag." } },
    { "Swap or insert?", {
        "It's made for the bank's swap mode (dropping an item on another swaps them). Insert mode works too, "
            .. "but sorting can take a few more drags." } },
    { "Is anything sent anywhere?", {
        "No. Your plan, settings and locks are saved only on this computer. Delete them any time: Edit plan, "
            .. "then Delete saved data." } },
}

local function buildHelp(root)
    local page = editorPage(root, "Questions & answers", "main")
    for _, entry in ipairs(QUESTIONS) do
        page.heading(entry[1])
        for _, text in ipairs(entry[2]) do page.paragraph(text) end
    end
    page.finish()
end

-- Window lifecycle -------------------------------------------------------------

-- Builds the window. `root` is the empty layer from ContentLayerReady.
function panel.build(root, ctx)
    panel.root, panel.ctx = root, ctx
    panel.parts = nil
    panel.view = "main"
    buildMain(root, ctx)
end

-- Switches view (called from main.lua's tick, never from inside a click
-- handler, so no button is destroyed while its click is being handled).
function panel.tick()
    local view = panel.pendingView
    if not view or not panel.root then return end
    panel.pendingView = nil
    util.try("switch view", function()
        panel.root:DeleteAll()
        panel.parts = nil
        panel.view = view
        if view == "plan" then
            buildPlanEditor(panel.root, panel.ctx)
        elseif view == "tab" then
            buildTabEditor(panel.root, panel.ctx)
        elseif view == "help" then
            buildHelp(panel.root)
        else
            buildMain(panel.root, panel.ctx)
        end
    end)
end

return panel
