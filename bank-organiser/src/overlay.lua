-- overlay.lua
-- Draws the guide on top of the real bank window, always in the same three
-- colours so they mean the same thing on every step:
--   green  - pick this up: every item (or the tab) to drag now, numbered in
--            the order to drag them when there are several
--   yellow - drop it here: the tab, "+" button or item to drop it on
--   blue   - click this (e.g. the all-items tab)
-- Each comes with a small tag ("Drag", "Drop here", "Click"), and when there's
-- a single thing to drag, a moving dotted trail runs from it to where it goes.
-- Also:
--   * a banner across the bank's title bar saying what to do now
--   * a numbered badge on each tab icon (green = tidy, amber = needs work,
--     grey = locked), matching the list in the plugin window
--   * a hint when highlighted items are scrolled out of view
--   * a tip above the bank item under the cursor saying where it belongs
--   * badges on backpack items with the tab they belong in
--   * a short message in the banner after each drag ("Rune platebody is in Melee")
--
-- Everything is drawn on the layer the game provides for plugins, at the bank
-- components' screen positions, and is click-through so it never gets in the
-- way of dragging. Positions are refreshed when the bank scrolls or changes.

local util = require("src/util")
local bankui = require("src/bankui")
local widgets = require("src/ui/widgets")

local overlay = {}

local COLOUR_DRAG = 0x40F060    -- green: pick this up
local COLOUR_DROP = 0xFFE040    -- yellow: drop it here
local COLOUR_CLICK = 0x50B0FF   -- blue: click this
local COLOUR_TAG_TEXT = 0x101010
local MAX_HIGHLIGHTS = 150      -- enough for every slot visible at once
local BADGE = 18                -- badge size
local DOT = 6                   -- trail dot size
local DOT_GAP = 16              -- distance between trail dots
local MAX_DOTS = 40

overlay.BADGE_TIDY = 0x2E8B3E
overlay.BADGE_WORK = 0xB07010
overlay.BADGE_LOCKED = 0x606060

local parts = nil       -- fixed components, created on first use
local pool = {}         -- highlight rectangles, reused
local badgePool = {}    -- { back, label } per badge, reused
local packPool = {}     -- { back, label } per backpack badge, reused
local tagPool = {}      -- { back, label } per tag, reused
local dots = {}         -- trail dots, reused
local dotsShown = 0
local spec = nil        -- what to show, see overlay.show
local flash = nil       -- { text, colour, untilTick }: a short message in the banner
local hover = nil       -- { slot, text }: a tip above the bank item under the cursor
local backpack = {}     -- { { slot, id, text } }: badges on backpack items
local ticks = 0
local lastScroll = nil  -- bank scroll position when last laid out
local needsLayout = true

local function pluginLayer()
    local ok, layer = pcall(function()
        return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
    end)
    return ok and layer or nil
end

local function newRect(layer, rgb, alpha, filled)
    local r = widgets.rect(layer, rgb, alpha, filled)
    if not filled then r.outlineThickness = 3 end
    r.clickthrough = true
    r.hidden = true
    return r
end

local function newText(layer, colour, heading)
    local t = widgets.text(layer, "", { colour = colour, align = "centre", heading = heading })
    t.clickthrough = true
    t.hidden = true
    return t
end

-- Creates the fixed overlay components (once) on the plugin layer.
local function ensureParts()
    if parts and pcall(function() return parts.dropBox.visible end) then
        return parts
    end
    local layer = pluginLayer()
    if not layer then return nil end
    pool, badgePool, packPool, tagPool, dots = {}, {}, {}, {}, {}
    dotsShown = 0
    parts = {
        layer = layer,
        dragTabFill = newRect(layer, COLOUR_DRAG, 0.4, true),
        dropFill = newRect(layer, COLOUR_DROP, 0.25, true),
        dropBox = newRect(layer, COLOUR_DROP, 1.0, false),
        clickBox = newRect(layer, COLOUR_CLICK, 1.0, false),
        hintBack = newRect(layer, 0x14100C, 0.85, true),
        hint = newText(layer, 0xFFFFFF),
        bannerBack = newRect(layer, 0x14100C, 0.92, true),
        banner = newText(layer, widgets.COLOUR_HEADING, true),
        tipBack = newRect(layer, 0x14100C, 0.92, true),
        tip = newText(layer, 0xFFFFFF),
    }
    return parts
end

-- Returns highlight number i ({ box, label }), creating it if needed.
local function highlight(i)
    if not pool[i] then
        pool[i] = { box = newRect(parts.layer, COLOUR_DRAG, 0.35, true), label = newText(parts.layer, 0xFFFFFF) }
    end
    return pool[i]
end

-- Returns badge number i, creating it if needed.
local function badge(i)
    if not badgePool[i] then
        badgePool[i] = { back = newRect(parts.layer, overlay.BADGE_TIDY, 0.95, true), label = newText(parts.layer, 0xFFFFFF) }
    end
    return badgePool[i]
end

-- Returns backpack badge number i, creating it if needed.
local function packBadge(i)
    if not packPool[i] then
        packPool[i] = { back = newRect(parts.layer, overlay.BADGE_TIDY, 0.95, true), label = newText(parts.layer, 0xFFFFFF) }
    end
    return packPool[i]
end

-- Returns tag number i ({ back, label }), creating it if needed.
local function tag(i)
    if not tagPool[i] then
        tagPool[i] = { back = newRect(parts.layer, COLOUR_DROP, 0.95, true), label = newText(parts.layer, COLOUR_TAG_TEXT) }
        pcall(function() tagPool[i].label.isShadowed = false end)
    end
    return tagPool[i]
end

-- Returns trail dot number i, creating it if needed.
local function dot(i)
    if not dots[i] then
        dots[i] = newRect(parts.layer, COLOUR_DROP, 1.0, true)
    end
    return dots[i]
end

local function hideAll()
    if not parts then return end
    pcall(function()
        for _, key in ipairs({ "dragTabFill", "dropFill", "dropBox", "clickBox", "hintBack", "hint", "bannerBack",
            "banner", "tipBack", "tip" }) do
            parts[key].hidden = true
        end
        for _, h in ipairs(pool) do
            h.box.hidden = true
            h.label.hidden = true
        end
        for _, list in ipairs({ badgePool, packPool, tagPool }) do
            for _, b in ipairs(list) do
                b.back.hidden = true
                b.label.hidden = true
            end
        end
        for _, d in ipairs(dots) do d.hidden = true end
        dotsShown = 0
    end)
end

function overlay.hide()
    spec = nil
    hideAll()
end

-- Sets what to show. All fields optional:
--   items   - { { slot, id, label } } bank items to drag (green), each with an
--             optional number to show on it (the order to drag them)
--   dragTab - tab icon component to drag (green)
--   target  - tab icon (or "+") component to drop on (yellow)
--   swapTo  - { slot, id }: a bank item to drop on (yellow)
--   openTab - tab icon component to click (blue)
--   badges  - { { component, text, colour } } badges for tab icons
--   banner  - what to do now, shown across the bank's title bar
function overlay.show(newSpec)
    spec = newSpec
    needsLayout = true
end

-- Shows `text` in the banner for a few seconds (e.g. "Rune platebody is in Melee").
function overlay.flash(text, colour, seconds)
    flash = { text = text, colour = colour or 0xFFFFFF, untilTick = ticks + math.floor((seconds or 3) * 50) }
    needsLayout = true
end

-- Sets the tip shown above the bank item under the cursor: { slot, text } or nil.
function overlay.setHover(newHover)
    local same = (hover == nil and newHover == nil)
        or (hover and newHover and hover.slot == newHover.slot and hover.text == newHover.text)
    if not same then
        hover = newHover
        needsLayout = true
    end
end

-- Sets the badges on backpack items: { { slot, id, text, colour } }.
function overlay.setBackpack(list)
    backpack = list or {}
    needsLayout = true
end

-- Lays everything out again on the next tick (e.g. after the window resized).
function overlay.relayout()
    needsLayout = true
end

local function place(component, r, origin, grow)
    grow = grow or 0
    component:SetPos(math.floor(r.x - origin.x - grow), math.floor(r.y - origin.y - grow))
    component:SetSize(math.floor(r.w + 2 * grow), math.floor(r.h + 2 * grow))
    component.hidden = false
end

local function inflate(r, by)
    return { x = r.x - by, y = r.y - by, w = r.w + 2 * by, h = r.h + 2 * by }
end

local function contains(r, x, y)
    return x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

local function overlaps(a, b)
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

-- A small coloured tag with dark text centred above `r` (or below it, if
-- `below` is set or there's no room above `top`), moved further out if it
-- would cover a tag already placed (`placed`, e.g. two neighbouring tabs).
local function placeTag(p, origin, i, text, colour, r, below, top, placed)
    local h = widgets.LINE + 2
    local w = #text * 7 + 14
    local y = r.y - h - 3
    if below or (top and y < top) then below, y = true, r.y + r.h + 3 end
    local box = { x = r.x + r.w / 2 - w / 2, y = y, w = w, h = h }
    for _ = 1, 3 do
        local clash = false
        for _, other in ipairs(placed) do
            if overlaps(box, other) then clash = true end
        end
        if not clash then break end
        box.y = box.y + (below and (h + 2) or -(h + 2))
    end
    table.insert(placed, box)
    local drawn = tag(i)
    drawn.back.colour = util.rgbToVector(colour, 0.95)
    drawn.label.content = text
    place(drawn.back, box, origin)
    place(drawn.label, box, origin)
    pcall(function()
        drawn.back:MoveToFront()
        drawn.label:MoveToFront()
    end)
end

-- A dotted line from the middle of `from` to the middle of `to`, leaving out
-- the parts inside either box. The dots light up in turn towards `to` (see
-- overlay.tick), so it reads as "this goes there".
local function layoutTrail(origin, from, to)
    local x1, y1 = from.x + from.w / 2, from.y + from.h / 2
    local x2, y2 = to.x + to.w / 2, to.y + to.h / 2
    local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
    local steps = math.floor(length / DOT_GAP)
    local skipFrom, skipTo = inflate(from, 2), inflate(to, 2)
    for s = 1, steps - 1 do
        local x = x1 + (x2 - x1) * s / steps
        local y = y1 + (y2 - y1) * s / steps
        if dotsShown < MAX_DOTS and not contains(skipFrom, x, y) and not contains(skipTo, x, y) then
            dotsShown = dotsShown + 1
            place(dot(dotsShown), { x = x - DOT / 2, y = y - DOT / 2, w = DOT, h = DOT }, origin)
        end
    end
end

-- Banner: centred in the bank's title bar, clear of its buttons on the right.
local function layoutBanner(p, origin)
    local window = spec.banner and spec.banner ~= "" and bankui.windowRect()
    if not window then return end
    local width = math.min(window.w - 150, 600)
    local r = { x = window.x + (window.w - width) / 2, y = window.y + 6, w = width, h = 30 }
    place(p.bannerBack, r, origin)
    local flashing = flash and ticks < flash.untilTick
    p.banner.content = flashing and flash.text or spec.banner
    p.banner.colour = util.rgbToVector(flashing and flash.colour or widgets.COLOUR_HEADING)
    place(p.banner, r, origin)
end

-- A small dark tip just above the hovered bank item (below it at the top edge).
local function layoutHover(p, origin, geo)
    if not (hover and geo) then return end
    local r = bankui.slotRect(hover.slot, geo)
    local view = geo.view
    if not r or r.y + r.h <= view.y or r.y >= view.y + view.h then return end
    local h = widgets.LINE + 6
    local w = math.min(math.max(#hover.text * 7 + 16, 80), 320)
    local y = r.y - h - 2
    if y < view.y then y = r.y + r.h + 2 end
    local box = { x = math.max(view.x, math.min(r.x + r.w / 2 - w / 2, view.x + view.w - w)), y = y, w = w, h = h }
    place(p.tipBack, box, origin)
    p.tip.content = hover.text
    place(p.tip, box, origin)
    pcall(function()
        p.tipBack:MoveToFront()
        p.tip:MoveToFront()
    end)
end

-- Badges in the corner of backpack items saying which tab they belong in.
local function layoutBackpack(p, origin)
    for i, entry in ipairs(backpack) do
        local c = bankui.backpackSlotComponent(entry.slot)
        local r = c and bankui.backpackShowsItem(entry.slot, entry.id) and bankui.rect(c)
        if r and r.w > 0 then
            local drawn = packBadge(i)
            local box = { x = r.x + r.w - BADGE + 2, y = r.y + r.h - BADGE + 2, w = BADGE, h = BADGE }
            drawn.back.colour = util.rgbToVector(entry.colour or overlay.BADGE_WORK, 0.95)
            place(drawn.back, box, origin)
            drawn.label.content = entry.text
            place(drawn.label, box, origin)
        end
    end
end

local function layoutBadges(p, origin)
    for i, b in ipairs(spec.badges or {}) do
        local r = bankui.rect(b.component)
        if r and r.w > 0 then
            local drawn = badge(i)
            local box = { x = r.x - 4, y = r.y - 4, w = BADGE, h = BADGE }
            drawn.back.colour = util.rgbToVector(b.colour or overlay.BADGE_TIDY, 0.95)
            place(drawn.back, box, origin)
            drawn.label.content = b.text
            place(drawn.label, box, origin)
        end
    end
end

-- Lays everything out at the bank's current positions.
local function layout(p)
    local origin = p.layer.xyGlobal
    hideAll()
    local tags, placed = 0, {}
    local function addTag(text, colour, r, below, top)
        tags = tags + 1
        placeTag(p, origin, tags, text, colour, r, below, top, placed)
    end

    local geo = bankui.geometry()
    local view = geo and geo.view
    local dragRect, dropRect = nil, nil -- the one thing to drag, and where it goes

    if spec.openTab then
        local r = bankui.rect(spec.openTab)
        if r then
            place(p.clickBox, r, origin, 3)
            addTag("Click", COLOUR_CLICK, inflate(r, 3), true)
        end
    end
    if spec.dragTab then
        local r = bankui.rect(spec.dragTab)
        if r then
            place(p.dragTabFill, r, origin, 2)
            dragRect = r
        end
    end
    if spec.target then
        local r = bankui.rect(spec.target)
        if r then
            place(p.dropFill, r, origin, 3)
            place(p.dropBox, r, origin, 3)
            dropRect = inflate(r, 3)
        end
    end

    -- Items scrolled (even partly) out of the grid are counted, not drawn;
    -- partly hidden ones get a box cut to the visible part. A slot that isn't
    -- showing the expected item (the bank changed a moment ago) is skipped.
    local shown, above, below = 0, 0, 0
    local items = spec.items or {}
    for _, item in ipairs(items) do
        if view and bankui.slotShowsItem(item.slot, item.id) then
            local r = bankui.slotRect(item.slot, geo)
            if r then
                local top = math.max(r.y, view.y)
                local bottom = math.min(r.y + r.h, view.y + view.h)
                if bottom - top < r.h / 3 then
                    if r.y < view.y then above = above + 1 else below = below + 1 end
                elseif shown < MAX_HIGHLIGHTS then
                    shown = shown + 1
                    local h = highlight(shown)
                    local visible = { x = r.x, y = top, w = r.w, h = bottom - top }
                    place(h.box, visible, origin)
                    if item.label then
                        h.label.content = item.label
                        place(h.label, visible, origin)
                    end
                    if #items == 1 then dragRect = visible end
                end
            end
        end
    end
    local dropAbove, dropBelow = false, false
    if view and spec.swapTo and bankui.slotShowsItem(spec.swapTo.slot, spec.swapTo.id) then
        local r = bankui.slotRect(spec.swapTo.slot, geo)
        if r and r.y + r.h > view.y and r.y < view.y + view.h then
            place(p.dropFill, r, origin, 2)
            place(p.dropBox, r, origin, 2)
            dropRect = inflate(r, 2)
        elseif r then
            dropAbove, dropBelow = r.y < view.y, r.y >= view.y
        end
    end

    -- Tags: "Drop here" below a tab (the banner is above the tab bar) and
    -- above an item; "Drag" only when there's one thing to drag (several are
    -- numbered instead).
    if dropRect then
        addTag("Drop here", COLOUR_DROP, dropRect, spec.target ~= nil, view and view.y)
    end
    if dragRect then
        addTag("Drag", COLOUR_DRAG, dragRect, spec.dragTab ~= nil, view and view.y)
        if dropRect then layoutTrail(origin, dragRect, dropRect) end
    end

    if view and (above > 0 or below > 0 or dropAbove or dropBelow) then
        local text = below > 0 and string.format("%d more green items below - scroll down", below)
            or above > 0 and string.format("%d more green items above - scroll up", above)
            or dropBelow and "Yellow drop spot is below - scroll down"
            or "Yellow drop spot is above - scroll up"
        below = (below > 0 or (above == 0 and dropBelow)) and 1 or 0
        p.hint.content = text
        -- A dark strip behind the text so it reads over the items.
        local h = widgets.LINE + 6
        local w = math.min(view.w - 20, 300)
        local r = { x = view.x + (view.w - w) / 2, y = below > 0 and (view.y + view.h - h - 4) or (view.y + 4),
            w = w, h = h }
        place(p.hintBack, r, origin)
        place(p.hint, r, origin)
    end

    layoutBanner(p, origin)
    layoutBadges(p, origin)
    layoutBackpack(p, origin)
    layoutHover(p, origin, geo)
end

-- Called every client tick: re-lays out when the bank scrolls or the plan
-- changes (and every half second anyway), makes the drop and click boxes
-- pulse, and runs a wave of light along the trail towards the drop box.
function overlay.tick()
    if not spec then return end
    if not bankui.isOpen() then
        hideAll()
        needsLayout = true
        return
    end
    local p = ensureParts()
    if not p then return end
    ticks = ticks + 1

    util.try("overlay", function()
        local scroll = bankui.scrollY()
        if flash and ticks == flash.untilTick then needsLayout = true end
        if needsLayout or scroll ~= lastScroll or ticks % 25 == 0 then
            needsLayout = false
            lastScroll = scroll
            layout(p)
        end
        local pulse = 0.55 + 0.45 * math.abs(math.sin(ticks / 10))
        p.dropBox.alpha = pulse
        p.clickBox.alpha = pulse
        for i = 1, dotsShown do
            local wave = math.cos(i * 0.6 - ticks * 0.2)
            dots[i].alpha = 0.25 + 0.75 * math.max(0, wave) ^ 3
        end
    end)
end

return overlay
