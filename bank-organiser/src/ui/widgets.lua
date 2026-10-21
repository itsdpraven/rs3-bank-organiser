-- widgets.lua
-- Thin helpers around the game's UI components so the window code stays
-- short and every control looks and behaves the same way.
--
-- Component types confirmed to work in the client: Text, Button, Rectangle
-- and Layer. Every setting is a "picker" (< choice >); text boxes
-- (InputField) are used only for tab names and item names.
-- Callbacks are wrapped in util.try so an error is logged instead of
-- breaking the window.

local util = require("src/util")

local widgets = {}

-- Fonts ---------------------------------------------------------------------
-- The game's UI font is Museo Sans. Only the 15pt size is documented, so the
-- smaller sizes are found by looking through the game's fonts: the body text
-- uses the size nearest 12pt, headings the size nearest 13pt, and both fall
-- back to 15pt if nothing smaller exists.

local function try(fn)
    local ok, result = pcall(fn)
    if ok then return result end
    return nil
end

-- Every Museo Sans font: { id, name, points, bold, baseline }.
local function museoFonts()
    local list = {}
    for fontId = 0, 600 do
        local font = try(function() return config.Font.FromID(fontId) end)
        local name = font and try(function() return font.configName end)
        local points = name and tonumber(name:match("^MUSEO_SANS_(%d+)PT"))
        if points then
            table.insert(list, { id = fontId, name = name, points = points, bold = name:find("BOLD") ~= nil,
                baseline = try(function() return font.baseline end) or points + 3 })
        end
    end
    return list
end

local function nearest(list, points, bold)
    local best = nil
    for _, f in ipairs(list) do
        if f.bold == bold and f.points <= 15 then
            if not best or math.abs(f.points - points) < math.abs(best.points - points)
                or (math.abs(f.points - points) == math.abs(best.points - points) and f.points < best.points) then
                best = f
            end
        end
    end
    return best
end

widgets.FONTS = museoFonts()
local body = nearest(widgets.FONTS, 12, false)
local heading = nearest(widgets.FONTS, 13, true) or nearest(widgets.FONTS, 13, false) or body
widgets.FONT = body and body.id or id.Font.MUSEO_SANS_15PT_REGULAR
widgets.FONT_HEADING = heading and heading.id or widgets.FONT
widgets.FONT_NAME = body and body.name or "MUSEO_SANS_15PT_REGULAR"

-- Sizes, from the body font's line height: LINE fits one line of text,
-- ROW fits a button or picker.
widgets.LINE = (body and body.baseline or 18) + 2
widgets.ROW = widgets.LINE + 6
widgets.PAD = 4                    -- standard gap between elements

widgets.STYLE_BUTTON = util.safeId(id.StyleSheet, { "BUTTON_DEFAULT" }, -1)

-- Use the game's own carousel for pickers (falls back to the plugin's own
-- arrows-and-label picker if it can't be created).
widgets.NATIVE_PICKERS = true

-- An item's picture (from its item ID), or nil if it can't be shown.
function widgets.itemIcon(parent, itemId)
    local ok, sprite = pcall(function()
        local s = ui.Sprite.new(parent)
        local whole = math.tointeger(itemId)
        if not pcall(function() s:SetAssociatedObject(whole) end) then s.associatedObjectID = whole end
        pcall(function() s.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.NEVER end)
        s.clickthrough = true
        return s
    end)
    return ok and sprite or nil
end

widgets.COLOUR_TEXT = 0xE8E0C8     -- warm off-white, like the game's own text
widgets.COLOUR_MUTED = 0xA09880
widgets.COLOUR_HEADING = 0xE8C060  -- gold, like the game's window titles
widgets.COLOUR_GOOD = 0x70D070

-- Positions and sizes a component in one call (absolute interface units).
function widgets.place(component, x, y, w, h)
    component:SetPos(x, y)
    component:SetSize(w, h)
    return component
end

-- Plain text label.
--   options: colour (0xRRGGBB), align ("left"|"centre"), lines (0 = unlimited),
--            heading (true for the heading font)
function widgets.text(parent, content, options)
    options = options or {}
    local t = ui.Text.new(parent)
    t.font = options.heading and widgets.FONT_HEADING or widgets.FONT
    t.content = content or ""
    t.colour = util.rgbToVector(options.colour or widgets.COLOUR_TEXT)
    t.maxLines = options.lines or 1
    t.isShadowed = true
    t:AlignTo(options.align == "centre" and ui.AlignMode.CENTRE or ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    return t
end

-- Push button. onPress() is called when clicked.
function widgets.button(parent, label, onPress)
    local b = ui.Button.new(parent)
    if widgets.STYLE_BUTTON >= 0 then b.stylesheetID = widgets.STYLE_BUTTON end
    b.label = label
    pcall(function() b.text.font = widgets.FONT end)
    b:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        util.try("button '" .. label .. "'", onPress)
    end)
    return b
end

widgets.STYLE_INPUT = util.safeId(id.StyleSheet, { "INPUT_DEFAULT" }, -1)

-- Text box. onChange(text, submitted) is called as the player types;
-- `submitted` is true when they press Enter.
function widgets.input(parent, content, onChange)
    local field = ui.InputField.new(parent)
    if widgets.STYLE_INPUT >= 0 then field.stylesheetID = widgets.STYLE_INPUT end
    field.content = content or ""
    pcall(function() field.text.font = widgets.FONT end)
    field:Subscribe(ui.Hook.ONCONTENTCHANGED, function(_, reason, newContents)
        util.try("text box", onChange, newContents or "", reason == ui.InputFieldActionResult.SUBMIT)
    end)
    return field
end

-- Solid or outlined rectangle in a 0xRRGGBB colour.
function widgets.rect(parent, rgb, alpha, filled)
    local r = ui.Rectangle.new(parent)
    r.colour = util.rgbToVector(rgb, alpha or 1.0)
    r.fill = (filled ~= false)
    return r
end

-- Section heading: gold text with a thin line underneath.
function widgets.heading(parent, content)
    local holder = ui.Layer.new(parent)
    local t = widgets.text(holder, content, { colour = widgets.COLOUR_HEADING, heading = true })
    t:SetSize(0, widgets.LINE, 1.0, 0.0)
    local line = widgets.rect(holder, widgets.COLOUR_HEADING, 0.35, true)
    line:SetPos(0, widgets.LINE + 1)
    line:SetSize(0, 1, 1.0, 0.0)
    return holder
end

widgets.STYLE_CAROUSEL = util.safeId(id.StyleSheet, { "CAROUSEL_DEFAULT" }, -1)

-- The game's own "< choice >" control (ui.Carousel), or nil if it can't be made.
local function nativePicker(parent, choices, selectedValue, onChange)
    local ok, carousel = pcall(function()
        local c = ui.Carousel.new(parent)
        if widgets.STYLE_CAROUSEL >= 0 then c.stylesheetID = widgets.STYLE_CAROUSEL end
        pcall(function() c.text.font = widgets.FONT end)
        local selected = 1
        for i, choice in ipairs(choices) do
            c:Add(i, choice[2])
            if choice[1] == selectedValue then selected = i end
        end
        if #choices > 0 then c:Select(selected, false) end
        -- Fired for the old entry (status 0) and the new one (status 1).
        c:Subscribe(ui.Hook.ONSELECTIONCHANGED, function(_, entryID, status)
            if status == 1 and choices[entryID] then util.try("picker", onChange, choices[entryID][1]) end
        end)
        return c
    end)
    return ok and carousel or nil
end

-- Choice picker: "<  current choice  >". Uses the game's own carousel where
-- possible; otherwise arrows (or a click on the label) step through the
-- choices. `choices` is an array of { value, label }; onChange(value) gets
-- the chosen value.
function widgets.picker(parent, choices, selectedValue, onChange)
    if widgets.NATIVE_PICKERS then
        local native = nativePicker(parent, choices, selectedValue, onChange)
        if native then return native end
    end
    local holder = ui.Layer.new(parent)
    local index = 1
    for i, choice in ipairs(choices) do
        if choice[1] == selectedValue then index = i end
    end

    local background = widgets.rect(holder, 0x000000, 0.35, true)
    background:SetSize(0, 0, 1.0, 1.0)
    local label = widgets.text(holder, "", { align = "centre" })
    label:SetPos(22, 0)
    label:SetSize(-44, 0, 1.0, 1.0)

    local function show()
        label.content = choices[index] and choices[index][2] or ""
    end
    local function step(delta)
        if #choices == 0 then return end
        index = (index - 1 + delta) % #choices + 1
        show()
        util.try("picker", onChange, choices[index][1])
    end

    -- "<" starts a formatting tag in game text, so the escapes <lt> and <gt> are used.
    local back = widgets.button(holder, "<lt>", function() step(-1) end)
    back:SetSize(20, 0, 0.0, 1.0)
    local forward = widgets.button(holder, "<gt>", function() step(1) end)
    forward:SetPos(-20, 0, 1.0, 0.0)
    forward:SetSize(20, 0, 0.0, 1.0)
    label:Subscribe(ui.Hook.ONCLICK, function() step(1) end)

    show()
    return holder
end

-- A vertical stack of rows that scrolls with the mouse wheel or a swipe.
-- Rows outside the visible area are hidden and visible rows re-positioned,
-- which works with any component type. Hidden rows are also moved far off
-- screen, because hiding a Layer doesn't always hide what's inside it.
--   local area = widgets.scrollArea(parent)  -- then position/size area.viewport
--   area.add(component, height)               -- component's parent must be area.viewport
--   area.layout()                             -- after adding rows
function widgets.scrollArea(parent)
    local area = { rows = {}, offset = 0, total = 0 }
    area.viewport = ui.Layer.new(parent)

    local bar = widgets.rect(area.viewport, widgets.COLOUR_HEADING, 0.5, true)
    bar.hidden = true

    -- Removes every row (but keeps the scroll position).
    function area.clear()
        for _, row in ipairs(area.rows) do
            pcall(function() row.component:Destroy() end)
        end
        area.rows, area.total = {}, 0
    end

    function area.add(component, height, gapAfter)
        table.insert(area.rows, { component = component, y = area.total, h = height })
        area.total = area.total + height + (gapAfter or widgets.PAD)
        area.watch(component)
        return component
    end

    function area.layout()
        local viewHeight = area.viewport.height
        if not viewHeight or viewHeight <= 0 then viewHeight = 300 end
        local maxOffset = math.max(0, area.total - viewHeight)
        area.offset = util.clamp(area.offset, 0, maxOffset)
        for _, row in ipairs(area.rows) do
            local top = row.y - area.offset
            local visible = top >= 0 and top + row.h <= viewHeight
            row.component.hidden = not visible
            row.component:SetPos(0, visible and top or -10000)
            row.component:SetSize(-6, row.h, 1.0, 0.0)
        end
        bar.hidden = maxOffset == 0
        if maxOffset > 0 then
            local barHeight = math.max(20, math.floor(viewHeight * viewHeight / area.total))
            bar:SetSize(3, barHeight)
            bar:SetPos(-3, math.floor((viewHeight - barHeight) * area.offset / maxOffset), 1.0, 0.0)
        end
    end

    -- Wheel and swipe events go to the component under the cursor or finger,
    -- so every row listens. A swipe moves the list with the finger.
    local swipeY = nil
    local function swiped(_, _, y)
        if swipeY and y then
            area.offset = area.offset + (swipeY - y)
            area.layout()
        end
        swipeY = y
    end
    function area.watch(component)
        component:Subscribe(ui.Hook.ONSCROLLWHEEL, "scrollArea", function(_, delta)
            area.offset = area.offset + ((delta or 0) > 0 and -2 or 2) * widgets.ROW
            area.layout()
        end)
        pcall(function()
            component:Subscribe(ui.Hook.ONSWIPEVERTICAL, "scrollAreaSwipe", swiped)
            component:Subscribe(ui.Hook.ONSWIPECOMPLETE, "scrollAreaSwipeEnd", function() swipeY = nil end)
        end)
    end
    area.watch(area.viewport)

    return area
end

return widgets
