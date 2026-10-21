-- overlay.lua
-- Draws the guide on top of the real bank window:
--   * a banner across the bank's title bar saying what to do now
--   * a numbered badge on each tab icon (green = tidy, amber = needs work,
--     grey = locked), matching the list in the plugin window
--   * a green glow on every item to move now
--   * a big green box on the tab to drop them on (or on "+" for a new tab)
--   * a blue box on a tab to click first (e.g. the all-items tab)
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

local COLOUR_ITEM = 0x40F060    -- green: move this
local COLOUR_TARGET = 0x40F060  -- green: drop here
local COLOUR_OPEN = 0x50B0FF    -- blue: click this first
local MAX_HIGHLIGHTS = 150      -- enough for every slot visible at once
local BADGE = 18                -- badge size

overlay.BADGE_TIDY = 0x2E8B3E
overlay.BADGE_WORK = 0xB07010
overlay.BADGE_LOCKED = 0x606060

local parts = nil       -- fixed components, created on first use
local pool = {}         -- highlight rectangles, reused
local badgePool = {}    -- { back, label } per badge, reused
local packPool = {}     -- { back, label } per backpack badge, reused
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
    if parts and pcall(function() return parts.targetBox.visible end) then
        return parts
    end
    local layer = pluginLayer()
    if not layer then return nil end
    pool, badgePool, packPool = {}, {}, {}
    parts = {
        layer = layer,
        targetFill = newRect(layer, COLOUR_TARGET, 0.3, true),
        targetBox = newRect(layer, COLOUR_TARGET, 1.0, false),
        openBox = newRect(layer, COLOUR_OPEN, 1.0, false),
        swapBox = newRect(layer, COLOUR_OPEN, 1.0, false),
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
        pool[i] = { box = newRect(parts.layer, COLOUR_ITEM, 0.35, true), label = newText(parts.layer, 0xFFFFFF) }
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

local function hideAll()
    if not parts then return end
    pcall(function()
        for _, key in ipairs({ "targetFill", "targetBox", "openBox", "swapBox", "hintBack", "hint", "bannerBack",
            "banner", "tipBack", "tip" }) do
            parts[key].hidden = true
        end
        for _, h in ipairs(pool) do
            h.box.hidden = true
            h.label.hidden = true
        end
        for _, list in ipairs({ badgePool, packPool }) do
            for _, b in ipairs(list) do
                b.back.hidden = true
                b.label.hidden = true
            end
        end
    end)
end

-- Returns backpack badge number i, creating it if needed.
local function packBadge(i)
    if not packPool[i] then
        packPool[i] = { back = newRect(parts.layer, overlay.BADGE_TIDY, 0.95, true), label = newText(parts.layer, 0xFFFFFF) }
    end
    return packPool[i]
end

function overlay.hide()
    spec = nil
    hideAll()
end

-- Sets what to show. All fields optional:
--   items   - { { slot, id, label } } bank items to highlight in green, each
--             with an optional number to show on it (the order to drag them)
--   target  - tab icon (or "+") component to drop them on
--   swapTo  - { slot, id }: a bank item to box in blue (drop the green item on it)
--   openTab - tab icon component to click first (blue)
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

    if spec.openTab then
        local r = bankui.rect(spec.openTab)
        if r then place(p.openBox, r, origin, 3) end
    end
    if spec.target then
        local r = bankui.rect(spec.target)
        if r then
            place(p.targetFill, r, origin, 3)
            place(p.targetBox, r, origin, 3)
        end
    end

    -- Items scrolled (even partly) out of the grid are counted, not drawn;
    -- partly hidden ones get a box cut to the visible part. A slot that isn't
    -- showing the expected item (the bank changed a moment ago) is skipped.
    local geo = bankui.geometry()
    local view = geo and geo.view
    local shown, above, below = 0, 0, 0
    for _, item in ipairs(spec.items or {}) do
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
                end
            end
        end
    end
    if view and spec.swapTo and bankui.slotShowsItem(spec.swapTo.slot, spec.swapTo.id) then
        local r = bankui.slotRect(spec.swapTo.slot, geo)
        if r and r.y + r.h > view.y and r.y < view.y + view.h then place(p.swapBox, r, origin, 2) end
    end

    if view and (above > 0 or below > 0) then
        local text = below > 0 and string.format("%d more green items below - scroll down", below)
            or string.format("%d more green items above - scroll up", above)
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
-- changes (and every half second anyway), and makes the target pulse.
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
        p.targetBox.alpha = pulse
        p.openBox.alpha = pulse
        p.swapBox.alpha = pulse
    end)
end

return overlay
