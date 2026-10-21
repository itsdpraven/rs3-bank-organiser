-- player.lua
-- A simulated player for the end-to-end tests. Like a real player it only
-- goes by what the plugin draws on the bank: it finds the green, yellow and
-- blue boxes on the plugin layer, works out what's under each one on screen,
-- and does that drag or click. So a box drawn in the wrong place shows up as
-- a wrong drag (or no drag at all), not just a wrong number.
--
-- Development only.

local fake = require("tests/e2e/fake_client")

local player = {}

local GREEN, YELLOW, BLUE = 0x40F060, 0xFFE040, 0x50B0FF

local function rectOf(c)
    local p = c.xyGlobal
    return { x = p.x, y = p.y, w = c.width, h = c.height }
end
local function centre(r) return r.x + r.w / 2, r.y + r.h / 2 end
local function sameRect(a, b) return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h end
local function within(inner, outer, slack)
    slack = slack or 0
    return inner.x >= outer.x - slack and inner.y >= outer.y - slack and inner.x + inner.w <= outer.x + outer.w + slack
        and inner.y + inner.h <= outer.y + outer.h + slack
end

-- What the plugin is showing on the bank right now:
--   greens  - { rect, number } items (or a tab) to drag
--   drop    - rect of the yellow "drop here" box
--   click   - rect of the blue "click" box
--   texts   - every text shown (banner, hint, tags, labels)
--   boxes   - every coloured box, for checking where they're drawn
function player.look(client)
    local seen = { greens = {}, texts = {}, boxes = {} }
    local numbers = {}
    for _, c in ipairs(client.pluginLayer.children) do
        if not rawget(c, "destroyed") and not rawget(c, "hidden") then
            local r = rectOf(c)
            if c.kind == "Rectangle" then
                local rgb, alpha = fake.rgb(c.colour), c.colour and c.colour.w or 1
                if rgb == GREEN and c.fill and alpha < 0.9 then
                    table.insert(seen.greens, { rect = r })
                    table.insert(seen.boxes, { colour = "green", rect = r })
                elseif rgb == YELLOW and not c.fill then
                    seen.drop = r
                    table.insert(seen.boxes, { colour = "yellow", rect = r })
                elseif rgb == BLUE and not c.fill then
                    seen.click = r
                    table.insert(seen.boxes, { colour = "blue", rect = r })
                end
            elseif c.kind == "Text" and c.content and c.content ~= "" then
                table.insert(seen.texts, { text = c.content, rect = r })
                if c.content:match("^%d+$") then table.insert(numbers, { n = tonumber(c.content), rect = r }) end
            end
        end
    end
    -- Numbers drawn on green boxes say the order to drag them.
    for _, g in ipairs(seen.greens) do
        for _, num in ipairs(numbers) do
            if sameRect(g.rect, num.rect) then g.number = num.n end
        end
    end
    table.sort(seen.greens, function(a, b) return (a.number or 0) < (b.number or 0) end)
    for _, t in ipairs(seen.texts) do
        -- The hint strip (not the banner, which can name an item like "Clue scroll").
        if t.text:find(" %- scroll %a+$") or t.text:find("^More tabs") then seen.hint = t.text end
    end
    return seen
end

-- Checks everything drawn is where it should be. Returns a list of problems.
function player.checkDrawing(client, seen)
    local problems = {}
    local window = client:windowRect()
    local strip = client:tabStripRect()
    for _, box in ipairs(seen.boxes) do
        local r = box.rect
        if not within(r, window, 4) then
            table.insert(problems, string.format("%s box outside the bank window at %d,%d", box.colour, r.x, r.y))
        end
        -- Anything drawn level with the tab bar must be over a tab that's shown
        -- (inside the visible strip), the all-items tab or an arrow.
        local x, y = centre(r)
        if y >= strip.y and y < strip.y + strip.h then
            local hit = client:hitTest(x, y)
            if not hit then
                table.insert(problems, string.format("%s box over nothing in the tab bar at %d,%d", box.colour, r.x, r.y))
            end
        end
    end
    -- Numbers on green items are all different.
    local numbersSeen = {}
    for _, g in ipairs(seen.greens) do
        if g.number then
            if numbersSeen[g.number] then table.insert(problems, "two green items numbered " .. g.number) end
            numbersSeen[g.number] = true
        end
    end
    return problems
end

-- Does what the plugin is asking for. Returns a short description of what was
-- done, or nil and the reason if there's nothing it can do.
--   options.wrongDrag - drop the next item on a different tab, once (a mistake)
function player.act(client, seen, options)
    options = options or {}
    if seen.click then
        local hit = client:hitTest(centre(seen.click))
        if not hit then return nil, "blue box over nothing" end
        if hit.kind == "all" then client:openAll() return "opened the all-items tab" end
        if hit.kind == "arrow" then client:clickArrow(hit.side) return "clicked the " .. hit.side .. " tab arrow" end
        if hit.kind == "icon" then client:openTabIcon(hit.index) return "opened tab " .. hit.index end
        return nil, "blue box over a " .. hit.kind
    end
    if seen.drop and #seen.greens > 0 then
        local target = client:hitTest(centre(seen.drop))
        if not target then return nil, "yellow box over nothing" end
        local from = client:hitTest(centre(seen.greens[1].rect))
        if not from then return nil, "green box over nothing" end
        if from.kind == "icon" and target.kind == "icon" then
            if not client:dragIconToIcon(from.index, target.index) then return nil, "tab drag refused" end
            return "dragged tab " .. from.index .. " onto tab " .. target.index
        end
        if from.kind ~= "slot" then return nil, "green box over a " .. from.kind end
        if target.kind == "slot" then
            if not client:dragItemToItem(from.slot, target.slot) then return nil, "swap refused" end
            return "swapped slots " .. from.slot .. " and " .. target.slot
        end
        if target.kind == "icon" then
            local index = target.index
            if options.wrongDrag and not options.wrongDragDone then
                -- Drop it on some other tab instead.
                for i = 1, client.iconCount do
                    if i ~= index and client.iconTab[i] then index = i break end
                end
                options.wrongDragDone = true
            end
            if not client:dragItemToIcon(from.slot, index) then return nil, "drop on icon refused" end
            return "dragged slot " .. from.slot .. " onto icon " .. index .. (index ~= target.index and " (wrong)" or "")
        end
        return nil, "yellow box over a " .. target.kind
    end
    if seen.hint then
        -- One row at a time once half of the pair is on screen, else faster.
        local near = seen.drop ~= nil or #seen.greens > 0
        if seen.hint:find("scroll down") then client:scrollGrid(near and 40 or 120) return "scrolled down" end
        if seen.hint:find("scroll up") then client:scrollGrid(near and -40 or -120) return "scrolled up" end
    end
    return nil, "nothing to do"
end

-- Follows the plugin until it says it's finished. Returns a result table:
--   ok, actions, counts (by kind of action), problems, finalMessage, reason
function player.follow(client, panel, options)
    options = options or {}
    local maxActions = options.maxActions or 5000
    local result = { ok = false, actions = 0, counts = {}, problems = {} }
    local stuck = 0
    for _ = 1, maxActions do
        client:tick(options.ticks or 4)
        local message = panel.status and panel.status.message or ""
        if message:find("^All done") or message:find("^All tidy") or message:find("^Done, apart")
            or (options.untilMessage and message:find(options.untilMessage)) then
            result.ok, result.finalMessage = true, message
            return result
        end
        local seen = player.look(client)
        for _, p in ipairs(player.checkDrawing(client, seen)) do
            if #result.problems < 20 then table.insert(result.problems, p) end
        end
        local did, why = player.act(client, seen, options)
        if not did then
            stuck = stuck + 1
            if stuck > 3 then
                result.reason = string.format("stuck (%s) at: %s | banner/hint: %s", why, message, seen.hint or "-")
                result.finalMessage = message
                return result
            end
        else
            stuck = 0
            result.actions = result.actions + 1
            local kind = did:match("^(%S+)")
            result.counts[kind] = (result.counts[kind] or 0) + 1
            if options.onAction then options.onAction(did, result.actions) end
        end
    end
    result.reason = "too many actions"
    result.finalMessage = panel.status and panel.status.message
    return result
end

return player
