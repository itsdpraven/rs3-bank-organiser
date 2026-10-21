-- run_e2e.lua
-- End-to-end tests: the whole plugin running against a stand-in for the game
-- client (fake_client.lua), with a simulated player (player.lua) doing every
-- drag and click the plugin shows on the bank, through to "All done". Each
-- scenario loads the plugin fresh. Run from the plugin folder with Lua 5.4:
--
--     lua tests/e2e/run_e2e.lua            every scenario
--     lua tests/e2e/run_e2e.lua tidy       scenarios whose name contains "tidy"
--     lua tests/e2e/run_e2e.lua --fuzz 200 every scenario, with 200 random banks
--
-- Whole-bank scenarios use the private tests/fixtures/real_bank.lua when
-- it's there. Development only.

package.path = "./?.lua;" .. package.path
local say = print -- the fake client takes over print() for the plugin

local fake = require("tests/e2e/fake_client")
local player = require("tests/e2e/player")

local PLUGIN = "."
local filter, fuzzCount = nil, 60
do
    local i = 1
    while arg[i] do
        if arg[i] == "--fuzz" then fuzzCount = tonumber(arg[i + 1]) or fuzzCount; i = i + 1
        else filter = arg[i] end
        i = i + 1
    end
end

local sample = dofile("tests/fixtures/sample_items.lua")
local hasReal, realBank = pcall(dofile, "tests/fixtures/real_bank.lua")
if not hasReal then realBank = nil end
local byName = {}
for _, raw in ipairs(sample) do byName[raw.name] = raw end

-- Helpers ---------------------------------------------------------------------------

-- Bank entries from raw items: `tabs` gives each tab's size in made order;
-- the rest aren't in a tab.
local function entriesOf(raws, tabs)
    local entries, i = {}, 0
    for t, size in ipairs(tabs or {}) do
        for _ = 1, size do
            i = i + 1
            if raws[i] then table.insert(entries, { raw = raws[i], tab = t }) end
        end
    end
    for k = i + 1, #raws do table.insert(entries, { raw = raws[k], tab = 0 }) end
    return entries
end

-- A fresh client with the plugin loaded and the bank open.
local function start(options)
    local client = fake.new(options)
    client:loadPlugin(PLUGIN)
    client:tick(12)
    return client, {
        panel = package.loaded["src/ui/panel"],
        settings = package.loaded["src/settings"],
        guide = package.loaded["src/guide"],
        bank = package.loaded["src/bank"],
        overlay = package.loaded["src/overlay"],
    }
end

-- Every live component under the plugin window.
local function windowParts(client)
    return fake.descendants(client.panelRoot)
end

-- Presses the window's button labelled `label`. Returns false if there isn't one.
local function press(client, label)
    for _, c in ipairs(windowParts(client)) do
        if c.kind == "Button" and c.label == label then
            fake.fire(c, "ONBUTTONPRESSED")
            client:tick(3)
            return true
        end
    end
    return false
end

-- Picks `choice` (its label) in the picker on the row labelled `rowLabel`.
local function pick(client, rowLabel, choice, root)
    root = root or client.panelRoot
    local containers = fake.descendants(root)
    table.insert(containers, 1, root)
    for _, row in ipairs(containers) do
        -- The label, and the picker beside it (on its own row, or level with it).
        local label, carousel = nil, nil
        for _, child in ipairs(row.children) do
            if child.kind == "Text" and child.content == rowLabel then label = child end
        end
        for _, child in ipairs(row.children) do
            if child.kind == "Carousel" and label and (rawget(child, "py") or 0) == (rawget(label, "py") or 0) then
                carousel = child
            end
        end
        if label and carousel then
            for _, entry in ipairs(carousel.entries or {}) do
                if entry.label == choice then
                    fake.fire(carousel, "ONSELECTIONCHANGED", entry.id, 1)
                    client:tick(3)
                    return true
                end
            end
            return false
        end
    end
    return false
end

-- Types into the first text box in the window and presses Enter.
local function typeText(client, text)
    for _, c in ipairs(windowParts(client)) do
        if c.kind == "InputField" then
            fake.fire(c, "ONCONTENTCHANGED", ui.InputFieldActionResult.SUBMIT, text)
            client:tick(3)
            return true
        end
    end
    return false
end

-- Every text in the window.
local function windowTexts(client)
    local list = {}
    for _, c in ipairs(windowParts(client)) do
        if c.kind == "Text" and c.content then table.insert(list, c.content) end
    end
    return list
end

local function overlayTexts(client)
    local list = {}
    for _, t in ipairs(player.look(client).texts) do table.insert(list, t.text) end
    return list
end

local function anyMatch(list, pattern)
    for _, text in ipairs(list) do if text:find(pattern) then return text end end
    return nil
end

-- What's in each tab of the fake bank, in order: { [stored tab] = { ids } }.
local function tabContents(client)
    local contents = {}
    for _, e in ipairs(client.entries) do
        if e.tab > 0 then
            contents[e.tab] = contents[e.tab] or {}
            table.insert(contents[e.tab], e.raw.id)
        end
    end
    return contents
end

-- Checks the finished bank with the plugin's own rules, read afresh from the
-- fake bank: nothing to move, tabs in order, every tab sorted, icons first.
local function finishedProblems(client, m)
    local problems = {}
    local items, tabs = {}, {}
    for i, e in ipairs(client.entries) do items[i] = m.bank.describe(e.raw, e.count, i) end
    local order = client:tabsByDisplay()
    local position = {}
    for i, t in ipairs(order) do position[t] = i end
    for t = 1, client:tabCount() do
        local firstId
        for _, e in ipairs(client.entries) do if e.tab == t then firstId = e.raw.id break end end
        table.insert(tabs, { size = client.sizes[t] or 0, display = position[t], iconItemId = firstId })
    end
    local settings = m.settings
    local ranges = m.guide.rangesFromSizes(items, tabs)
    local locked = {}
    for k, range in ipairs(ranges) do
        if settings.isTabLocked(range.iconItemId) then locked[k] = true end
    end
    local fresh = settings.get("mode") == "fresh"
    m.guide.clearCache()
    local plan = fresh and m.guide.planTabs(items, ranges, settings.data, locked)
        or m.guide.planTidy(items, ranges, settings.data, locked)
    if plan.toMoveTotal > 0 then table.insert(problems, plan.toMoveTotal .. " items still to move") end
    if fresh and m.guide.iconStep(items, ranges, plan, locked, {}) then table.insert(problems, "a tab icon isn't first") end
    if fresh and settings.get("orderTabs") and m.guide.orderStep(ranges, plan) then
        table.insert(problems, "tabs not in the plan's order")
    end
    if settings.get("sortInside") or fresh then
        local s = m.guide.sortStep(items, ranges, plan, settings.data, locked, {}, nil, not settings.get("sortInside"))
        if s then table.insert(problems, "tab " .. s.bankTab .. " not sorted") end
    end
    if client:tabCount() > 14 then table.insert(problems, "more than 14 tabs") end
    if fresh and client:tabCount() > settings.get("maxTabs") + #client:tabsByDisplay() - client:tabCount() then
        -- (tabs kept from before can't be removed by the plugin, so only new ones count)
    end
    return problems
end

-- Scenarios ---------------------------------------------------------------------------

local scenarios = {}
local function scenario(name, fn) table.insert(scenarios, { name = name, fn = fn }) end

-- Follows the plugin to the end and checks the result. Returns ok, detail, result.
local function followAndCheck(client, m, options)
    local result = player.follow(client, m.panel, options)
    local problems = {}
    if not result.ok then table.insert(problems, result.reason or "didn't finish") end
    for _, p in ipairs(result.problems) do table.insert(problems, p) end
    if result.ok then
        for _, p in ipairs(finishedProblems(client, m)) do table.insert(problems, p) end
    end
    for _, e in ipairs(client:errors()) do table.insert(problems, e) end
    local counts = {}
    for kind, n in pairs(result.counts) do table.insert(counts, kind .. " " .. n) end
    table.sort(counts)
    local detail = string.format("%d actions (%s)", result.actions, table.concat(counts, ", "))
    if #problems > 0 then return false, detail .. " | " .. table.concat(problems, "; "), result end
    return true, detail, result
end

-- Every sample item, in a random-looking but fixed order, none in a tab.
local function sampleRaws()
    local list = {}
    for i, raw in ipairs(sample) do list[i] = raw end
    -- Interleave so related items start far apart.
    local mixed = {}
    for start = 1, 7 do
        for i = start, #list, 7 do table.insert(mixed, list[i]) end
    end
    return mixed
end

scenario("organise sample bank (all tabs fit)", function()
    local client, m = start({ entries = entriesOf(sampleRaws()), clipWidth = 760 })
    return followAndCheck(client, m)
end)

scenario("organise sample bank (narrow tab bar, arrows needed)", function()
    local client, m = start({ entries = entriesOf(sampleRaws()), clipWidth = 200 })
    local ok, detail, result = followAndCheck(client, m)
    if ok and not (result.counts.clicked and result.counts.clicked > 0) then
        return false, detail .. " | never had to click a tab bar arrow"
    end
    return ok, detail
end)

scenario("bug: '+' scrolled off the tab bar is never boxed in the wrong place", function()
    -- 8 tabs and a "+" in a 369-wide strip, as in the screenshot: "+" is hidden.
    local raws = sampleRaws()
    local client, m = start({ entries = entriesOf(raws, { 6, 6, 6, 6, 6, 6, 6, 6 }), clipWidth = 369 })
    local seen = player.look(client)
    local problems = player.checkDrawing(client, seen)
    local ok, detail = followAndCheck(client, m)
    if #problems > 0 then return false, table.concat(problems, "; ") end
    return ok, detail
end)

scenario("tab order: tabs dropped on tabs insert instead of swapping", function()
    local client, m = start({ entries = entriesOf(sampleRaws(), { 10, 10, 10, 10 }), clipWidth = 760, tabInsert = true })
    return followAndCheck(client, m)
end)

scenario("insert mode: items dropped on items insert instead of swapping", function()
    local client, m = start({ entries = entriesOf(sampleRaws()), clipWidth = 760, insertMode = true })
    return followAndCheck(client, m)
end)

for _, style in ipairs({ "Compact", "Skiller", "Simple", "Recommended" }) do
    scenario("plan style chosen in the window: " .. style, function()
        local client, m = start({ entries = entriesOf(sampleRaws()), clipWidth = 500 })
        if not press(client, "Edit plan") then return false, "no Edit plan button" end
        if style ~= "Recommended" and not pick(client, "Style", style) then return false, "couldn't pick " .. style end
        if not press(client, "Back") then return false, "no Back button" end
        local ok, detail = followAndCheck(client, m)
        local active = m.settings.data.activePreset
        if active ~= style:lower() then return false, "style is " .. tostring(active) end
        return ok, detail
    end)
end

scenario("just tidy my tabs (picked in the window)", function()
    local client, m = start({ entries = entriesOf(sampleRaws(), { 20, 20, 20, 15 }), clipWidth = 500 })
    press(client, "Edit plan")
    if not pick(client, "Mode", "Just tidy my tabs") then return false, "couldn't pick the mode" end
    press(client, "Back")
    local before = client:tabCount()
    local ok, detail = followAndCheck(client, m)
    if client:tabCount() ~= before then return false, "tidy mode changed the number of tabs" end
    return ok, detail
end)

for _, strictness in ipairs({ "Relaxed", "Normal", "Strict" }) do
    scenario("tidy mode, " .. strictness:lower(), function()
        local client, m = start({ entries = entriesOf(sampleRaws(), { 30, 25, 26 }), clipWidth = 500 })
        press(client, "Edit plan")
        pick(client, "Mode", "Just tidy my tabs")
        if not pick(client, "How picky", strictness) then return false, "couldn't pick strictness" end
        press(client, "Back")
        return followAndCheck(client, m)
    end)
end

scenario("a tab locked with its Lock button is left exactly as it was", function()
    local client, m = start({ entries = entriesOf(sampleRaws(), { 12, 12, 12 }), clipWidth = 500 })
    local lockedId = client.icons[2].associatedObjectID -- the second tab in the tab bar
    local lockedTab = client.iconTab[2]
    local before = table.concat(tabContents(client)[lockedTab], ",")
    -- Press the Lock button on that tab's row.
    local pressed = false
    for _, c in ipairs(windowParts(client)) do
        if c.kind == "Button" and c.label == "Lock" then
            -- The row's icon shows the planned icon; match by the row title instead.
            local row = c.parent
            for _, child in ipairs(row.children) do
                if child.kind == "Text" and child.content and child.content:find("^2%. ") then
                    fake.fire(c, "ONBUTTONPRESSED"); pressed = true
                end
            end
        end
    end
    client:tick(3)
    if not pressed then return false, "no Lock button on tab 2's row" end
    if not m.settings.isTabLocked(lockedId) then return false, "the tab didn't lock" end
    local ok, detail = followAndCheck(client, m)
    local afterTab
    for t, ids in pairs(tabContents(client)) do if ids[1] == lockedId then afterTab = table.concat(ids, ",") end end
    if afterTab ~= before then return false, "the locked tab changed" end
    return ok, detail
end)

scenario("sorting inside tabs off, tab order off", function()
    local client, m = start({ entries = entriesOf(sampleRaws(), { 10, 10 }), clipWidth = 500 })
    press(client, "Edit plan")
    if not pick(client, "Sort items", "No") then return false, "no Sort items picker" end
    if not pick(client, "Tab order", "Leave as is") then return false, "no Tab order picker" end
    press(client, "Back")
    local ok, detail, result = followAndCheck(client, m)
    return ok, detail
end)

scenario("most tabs 4, smallest tab 10", function()
    local client, m = start({ entries = entriesOf(sampleRaws()), clipWidth = 500 })
    press(client, "Edit plan")
    if not pick(client, "Most tabs", "4") then return false, "no Most tabs picker" end
    if not pick(client, "Smallest tab", "10") then return false, "no Smallest tab picker" end
    press(client, "Back")
    local ok, detail = followAndCheck(client, m)
    if client:tabCount() > 4 then return false, client:tabCount() .. " tabs, wanted at most 4" end
    return ok, detail
end)

scenario("skip spam: 40 presses of Skip for now, then carry on", function()
    local client, m = start({ entries = entriesOf(sampleRaws(), { 8, 8 }), clipWidth = 500 })
    for _ = 1, 40 do press(client, "Skip for now") end
    return followAndCheck(client, m)
end)

scenario("pause hides the guide, resume brings it back", function()
    local client, m = start({ entries = entriesOf(sampleRaws()), clipWidth = 500 })
    press(client, "Pause")
    local seen = player.look(client)
    if #seen.boxes > 0 then return false, "boxes still shown while paused" end
    if not (m.panel.status.message or ""):find("Paused") then return false, "message: " .. tostring(m.panel.status.message) end
    if not press(client, "Resume") then return false, "no Resume button" end
    return followAndCheck(client, m)
end)

scenario("clicking a planned tab in the list works on it next", function()
    local client, m = start({ entries = entriesOf(sampleRaws()), clipWidth = 500 })
    local target
    for _, c in ipairs(windowParts(client)) do
        if c.kind == "Text" and c.content and c.content:find("^New tab: ") and c.handlers.ONCLICK then target = c end
    end
    if not target then return false, "no clickable new-tab row" end
    local label = target.content:match("^New tab: (.+)$")
    fake.fire(target, "ONCLICK")
    client:tick(4)
    local message = m.panel.status.message or ""
    if not message:find(label, 1, true) then return false, "after clicking " .. label .. ": " .. message end
    return followAndCheck(client, m)
end)

scenario("open one tab at a time: each tab tidied on its own, then the rest", function()
    local client, m = start({ entries = entriesOf(sampleRaws(), { 15, 15, 15, 15 }), clipWidth = 760 })
    local organised = 0
    for _ = 1, 30 do
        local nextIcon
        for i = 1, client.iconCount do
            if client.iconTab[i] then nextIcon = nextIcon or i end
        end
        -- Work through the tabs in tab bar order, one pass.
        local index = (organised % math.max(1, client:tabCount())) + 1
        if not client:openTabIcon(index) then break end
        client:tick(12)
        local result = player.follow(client, m.panel, { untilMessage = "is organised", maxActions = 400 })
        if not result.ok then return false, "tab " .. index .. ": " .. tostring(result.reason) end
        organised = organised + 1
        if organised >= client:tabCount() then break end
    end
    client:openAll()
    local ok, detail = followAndCheck(client, m)
    return ok, organised .. " tabs tidied one at a time, then " .. detail
end)

scenario("a wrong drag is called out and put right", function()
    local client, m = start({ entries = entriesOf(sampleRaws(), { 10, 10, 10 }), clipWidth = 760 })
    local flashed = nil
    local ok, detail = followAndCheck(client, m, { wrongDrag = true, onAction = function(did)
        if did:find("%(wrong%)") then
            client:tick(2)
            flashed = anyMatch(overlayTexts(client), "doesn't go there")
        end
    end })
    if not flashed then return false, "no 'doesn't go there' message after the wrong drag" end
    return ok, detail .. " | said: " .. flashed
end)

scenario("bank closed and reopened part way through", function()
    local client, m = start({ entries = entriesOf(sampleRaws()), clipWidth = 500 })
    player.follow(client, m.panel, { maxActions = 15 })
    client:setOpen(false)
    client:tick(12)
    local seen = player.look(client)
    if #seen.boxes > 0 then return false, "boxes drawn with the bank closed" end
    if not (m.panel.status.message or ""):find("Open your bank") then
        return false, "message with the bank closed: " .. tostring(m.panel.status.message)
    end
    client:setOpen(true)
    client:tick(12)
    return followAndCheck(client, m)
end)

scenario("logging out and back in part way through", function()
    local client, m = start({ entries = entriesOf(sampleRaws()), clipWidth = 500 })
    player.follow(client, m.panel, { maxActions = 10 })
    -- Logging out closes the bank.
    client:fireEvent("GameStateChanged", { newState = 10 })
    client:setOpen(false)
    client:tick(12)
    if #player.look(client).boxes > 0 then return false, "boxes drawn while logged out" end
    client:fireEvent("GameStateChanged", { newState = 30 })
    client:tick(12)
    client:setOpen(true)
    client:tick(12)
    return followAndCheck(client, m)
end)

scenario("pointing at an item says where it goes", function()
    local client, m = start({ entries = entriesOf(sampleRaws()), clipWidth = 500 })
    local checked = 0
    for slot = 1, 20 do
        client:hover(slot)
        client:tick(2)
        local tip = anyMatch(overlayTexts(client), "^Goes in") or anyMatch(overlayTexts(client), "^In the right tab")
            or anyMatch(overlayTexts(client), "^In a locked tab")
        if not tip then return false, "no tip over slot " .. slot end
        checked = checked + 1
    end
    client:hover(nil)
    client:tick(2)
    if anyMatch(overlayTexts(client), "^Goes in") then return false, "tip stayed after moving away" end
    local ok, detail = followAndCheck(client, m)
    return ok, checked .. " tips checked, then " .. detail
end)

scenario("backpack items show the tab they belong in", function()
    local pack = { byName["Swordfish"], byName["Dragon scimitar"], byName["Fire rune"], byName["Maple logs"] }
    local client, m = start({ entries = entriesOf(sampleRaws()), clipWidth = 500, backpack = pack })
    local badges = 0
    for _, t in ipairs(player.look(client).texts) do
        for i = 1, 4 do
            local s = client.packSlots[i].xyGlobal
            if t.rect.x >= s.x and t.rect.x < s.x + 40 and t.rect.y >= s.y and t.rect.y < s.y + 40
                and (t.text:match("^%d+$") or t.text == "+") then badges = badges + 1 end
        end
    end
    if badges ~= 4 then return false, badges .. " of 4 backpack items have a badge" end
    return followAndCheck(client, m)
end)

scenario("pick an item from the bank for a tab's rules", function()
    local client, m = start({ entries = entriesOf(sampleRaws()), clipWidth = 500 })
    press(client, "Edit plan")
    -- The first "Edit" button is tab 1.
    if not press(client, "Edit") then return false, "no Edit button" end
    if not press(client, "Pick from bank") then return false, "no Pick from bank button" end
    local slot = 5
    for _ = 1, 70 do
        client:hover(slot)
        client:tick(1)
    end
    local name = client.entries[slot].raw.name:lower()
    local rules = m.settings.data.plan[1].items or {}
    local found = false
    for _, rule in ipairs(rules) do if rule == name then found = true end end
    if not found then return false, "no rule for " .. name .. " (rules: " .. table.concat(rules, ", ") .. ")" end
    press(client, "Back")
    press(client, "Back")
    client:hover(nil)
    return followAndCheck(client, m)
end)

scenario("every control in the window works without errors", function()
    local client, m = start({ entries = entriesOf(sampleRaws(), { 10, 10 }), clipWidth = 500 })
    local steps = {}
    local function step(name, ok) table.insert(steps, (ok and "" or "FAILED ") .. name) return ok end
    step("Edit plan", press(client, "Edit plan"))
    for _, entry in ipairs({ { "Style", { "Compact", "Skiller", "Simple", "Recommended" } },
        { "Most tabs", { "4", "9", "14" } }, { "Smallest tab", { "1", "30", "5" } },
        { "Tab order", { "Leave as is", "Plan order" } }, { "Sort items", { "No", "Yes" } },
        { "Open a tab", { "Ask for all", "Work on it" } }, { "Tips on hover", { "No", "Yes" } },
        { "Backpack tabs", { "No", "Yes" } }, { "Per character", { "No", "Yes" } } }) do
        for _, choice in ipairs(entry[2]) do step(entry[1] .. " = " .. choice, pick(client, entry[1], choice)) end
    end
    step("Add a tab", press(client, "Add a tab"))
    step("rename", typeText(client, "My new tab"))
    step("Move up", press(client, "Move up"))
    step("Move down", press(client, "Move down"))
    step("Add category", press(client, "Add this category"))
    local categoriesAdded = #m.settings.data.plan[#m.settings.data.plan - 1].categories
    -- The item-name box is the second text box on the tab screen.
    local boxes = {}
    for _, c in ipairs(windowParts(client)) do if c.kind == "InputField" then table.insert(boxes, c) end end
    if boxes[2] then
        fake.fire(boxes[2], "ONCONTENTCHANGED", ui.InputFieldActionResult.SUBMIT, "rune")
        client:tick(3)
    end
    step("item rule shown", anyMatch(windowTexts(client), "\"rune\"") ~= nil)
    step("Remove (rule or category)", press(client, "Remove"))
    step("Delete tab", press(client, "Delete"))
    step("back on Edit plan", anyMatch(windowTexts(client), "^Your tabs") ~= nil)
    step("Mode = tidy", pick(client, "Mode", "Just tidy my tabs"))
    step("How picky = Strict", pick(client, "How picky", "Strict"))
    step("Mode = organise", pick(client, "Mode", "Organise my bank"))
    step("Delete saved data", press(client, "Delete saved data"))
    step("Cancel", press(client, "Cancel"))
    step("Delete saved data again", press(client, "Delete saved data"))
    step("Yes, delete it all", press(client, "Yes, delete it all"))
    local stored = 0
    for _ in pairs(client.store) do stored = stored + 1 end
    step("nothing saved after deleting", stored == 0)
    step("Back", press(client, "Back"))
    step("main view again", anyMatch(windowTexts(client), "^Bank Organiser") ~= nil)
    step("Q&A", press(client, "Q&A"))
    step("Q&A answers shown", anyMatch(windowTexts(client), "^Green: drag this") ~= nil)
    step("Q&A ordering answer", anyMatch(windowTexts(client), "^Gear: by level") ~= nil)
    step("Q&A back", press(client, "Back"))
    -- The Plugin Hub settings screen.
    step("hub: Mode", pick(client, "Mode:", "Just tidy my tabs", client.settingsRoot))
    step("hub mode applied", m.settings.get("mode") == "tidy")
    step("hub: Plan style", pick(client, "Plan style:", "Compact", client.settingsRoot))
    step("hub: Per character", pick(client, "Per character:", "No", client.settingsRoot))
    local failedSteps = {}
    for _, s in ipairs(steps) do if s:find("^FAILED") then table.insert(failedSteps, s) end end
    local errors = client:errors()
    if #failedSteps > 0 or #errors > 0 then
        return false, table.concat(failedSteps, "; ") .. " " .. table.concat(errors, "; ")
    end
    return true, #steps .. " controls used, " .. categoriesAdded .. " categories on the new tab"
end)

scenario("Q&A page: every question can be scrolled to and read", function()
    local client, m = start({ entries = entriesOf(sampleRaws()), clipWidth = 500 })
    if not press(client, "Q&A") then return false, "no Q&A button" end
    -- Scroll down with the mouse wheel, noting each question as it comes into view.
    local seenQuestions, viewport = {}, nil
    for _, c in ipairs(windowParts(client)) do
        if c.handlers.ONSCROLLWHEEL and c.kind == "Layer" and not viewport then viewport = c end
    end
    if not viewport then return false, "nothing to scroll" end
    local questions = 0
    for _ = 1, 80 do
        for _, c in ipairs(windowParts(client)) do
            if c.kind == "Text" and c.content and c.content:find("%?$") and c.parent.visibleGlobal
                and not rawget(c.parent, "hidden") then
                if not seenQuestions[c.content] then questions = questions + 1 end
                seenQuestions[c.content] = true
            end
        end
        fake.fire(viewport, "ONSCROLLWHEEL", -1)
    end
    local total = 0
    for _, c in ipairs(windowParts(client)) do
        if c.kind == "Text" and c.content and c.content:find("%?$") then total = total + 1 end
    end
    if questions < total then return false, string.format("only %d of %d questions came into view", questions, total) end
    -- Every answer has room for its text (about 6.5 units a character).
    for _, c in ipairs(windowParts(client)) do
        if c.kind == "Text" and c.content and #c.content > 60 and c.maxLines and c.maxLines > 0 then
            local width = c.width
            if c.maxLines * width / 6.5 < #c.content * 0.95 then
                return false, "too little room for: " .. c.content:sub(1, 40)
            end
        end
    end
    if not press(client, "Back") then return false, "no Back button" end
    if not anyMatch(windowTexts(client), "^Bank Organiser") then return false, "didn't go back" end
    local errors = client:errors()
    if #errors > 0 then return false, table.concat(errors, "; ") end
    return true, total .. " questions, all reachable"
end)

scenario("settings are kept per character", function()
    local client, m = start({ entries = entriesOf(sampleRaws()), clipWidth = 500, characterName = "Main" })
    press(client, "Edit plan")
    pick(client, "Most tabs", "6")
    client.characterName = "Alt"
    client:tick(31)
    if m.settings.get("maxTabs") ~= 14 then return false, "Alt has Main's setting: " .. m.settings.get("maxTabs") end
    client.characterName = "Main"
    client:tick(31)
    if m.settings.get("maxTabs") ~= 6 then return false, "Main lost its setting: " .. m.settings.get("maxTabs") end
    return true, "Main 6 tabs, Alt 14"
end)

scenario("tab sizes worked out from the layout when the variables can't be read", function()
    local client, m = start({ entries = entriesOf(sampleRaws(), { 12, 9, 14 }), clipWidth = 500, noVars = true })
    return followAndCheck(client, m)
end)

scenario("empty bank", function()
    local client, m = start({ entries = {}, clipWidth = 500 })
    local message = m.panel.status.message or ""
    local errors = client:errors()
    if #errors > 0 then return false, table.concat(errors, "; ") end
    return message ~= "", "says: " .. message
end)

scenario("one item", function()
    local client, m = start({ entries = { { raw = byName["Dragon scimitar"], tab = 0 } }, clipWidth = 500 })
    return followAndCheck(client, m)
end)

scenario("14 tabs already (no + button)", function()
    local raws = sampleRaws()
    local client, m = start({ entries = entriesOf(raws, { 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5 }), clipWidth = 369 })
    return followAndCheck(client, m)
end)

scenario("game not in English: says sorting may be off", function()
    local client, m = start({ entries = entriesOf(sampleRaws()), clipWidth = 500, language = "Deutsch" })
    local note = anyMatch(windowTexts(client), "English game")
    if not note then return false, "no language note in the window" end
    return true, note
end)

if realBank then
    local REAL_SIZES = { 18, 14, 9, 30, 22, 7, 30 }
    local REAL_DISPLAY = { 1, 4, 3, 2, 5, 6, 7 }
    local function realEntries()
        local display = {}
        for t, d in ipairs(REAL_DISPLAY) do display[t] = d end
        return entriesOf(realBank, REAL_SIZES), display
    end
    scenario("whole real bank, as recorded (7 tabs, 856 not in a tab)", function()
        local entries, display = realEntries()
        local client, m = start({ entries = entries, display = display, clipWidth = 369 })
        return followAndCheck(client, m, { maxActions = 6000 })
    end)
    scenario("whole real bank, Compact style, insert mode", function()
        local entries, display = realEntries()
        local client, m = start({ entries = entries, display = display, clipWidth = 369, insertMode = true })
        press(client, "Edit plan")
        pick(client, "Style", "Compact")
        press(client, "Back")
        return followAndCheck(client, m, { maxActions = 6000 })
    end)
    scenario("whole real bank, just tidy my tabs", function()
        local entries, display = realEntries()
        local client, m = start({ entries = entries, display = display, clipWidth = 369 })
        press(client, "Edit plan")
        pick(client, "Mode", "Just tidy my tabs")
        press(client, "Back")
        return followAndCheck(client, m, { maxActions = 6000 })
    end)
end

-- Random banks: random items, tabs, settings, tab bar width and drag modes.
local function fuzzScenario(seed)
    return function()
        math.randomseed(seed)
        local pool = (realBank and seed % 4 == 0) and realBank or sample
        local raws, used = {}, {}
        local n = math.random(math.min(15, #pool), math.min(pool == sample and #pool or 160, #pool))
        while #raws < n do
            local raw = pool[math.random(#pool)]
            if not used[raw.id] then used[raw.id] = true; table.insert(raws, raw) end
        end
        local tabs, left = {}, n
        for _ = 1, math.random(0, 8) do
            local size = math.random(1, math.max(1, math.floor(left / 3)))
            if left - size < 0 then break end
            table.insert(tabs, size)
            left = left - size
        end
        local display = {}
        for t = 1, #tabs do display[t] = math.random() end
        local options = { entries = entriesOf(raws, tabs), display = display, clipWidth = math.random(150, 760),
            insertMode = math.random() < 0.3, tabInsert = math.random() < 0.3 }
        local client, m = start(options)
        local s = m.settings
        local styles = { "recommended", "compact", "skiller", "simple" }
        s.applyPreset(styles[math.random(#styles)])
        s.set("mode", math.random() < 0.7 and "fresh" or "tidy")
        s.set("maxTabs", math.random(4, 14))
        s.set("minTabSize", ({ 1, 2, 3, 5, 8 })[math.random(5)])
        s.set("sortInside", math.random() < 0.7)
        s.set("orderTabs", math.random() < 0.7)
        s.set("strictness", ({ "relaxed", "normal", "strict" })[math.random(3)])
        local lockedBefore
        if #tabs > 1 and math.random() < 0.4 then
            local id = client.icons[1].associatedObjectID
            s.setTabLocked(id, true)
            lockedBefore = { id = id, contents = table.concat(tabContents(client)[client.iconTab[1]], ",") }
        end
        client:tick(4)
        local ok, detail = followAndCheck(client, m, { maxActions = 4000 })
        if ok and lockedBefore then
            local after
            for _, ids in pairs(tabContents(client)) do
                if ids[1] == lockedBefore.id then after = table.concat(ids, ",") end
            end
            if after ~= lockedBefore.contents then ok, detail = false, detail .. " | the locked tab changed" end
        end
        local summary = string.format("%d items, %d tabs, %s/%s, max %d, clip %d%s%s", n, #tabs, s.get("mode"),
            s.data.activePreset, s.get("maxTabs"), options.clipWidth, options.insertMode and ", insert" or "",
            options.tabInsert and ", tab insert" or "")
        return ok, summary .. ": " .. detail
    end
end
for seed = 1, fuzzCount do scenario(string.format("random bank #%d", seed), fuzzScenario(seed)) end

-- Run ---------------------------------------------------------------------------------

local passed, failedList = 0, {}
local started = os.clock()
for _, s in ipairs(scenarios) do
    if not filter or s.name:find(filter, 1, true) then
        local t0 = os.clock()
        local okCall, ok, detail = pcall(s.fn)
        if not okCall then ok, detail = false, "crashed: " .. tostring(ok) end
        local line = string.format("%s %-70s %5.1fs  %s", ok and "ok  " or "FAIL", s.name, os.clock() - t0,
            tostring(detail or ""))
        say(line)
        if ok then passed = passed + 1 else table.insert(failedList, s.name) end
    end
end
say(string.format("\n%d passed, %d failed (%.0fs)", passed, #failedList, os.clock() - started))
for _, name in ipairs(failedList) do say("  failed: " .. name) end
os.exit(#failedList == 0 and 0 or 1)
