-- bankui.lua
-- Knows where things are inside the game's bank window, so the plugin can
-- draw highlights on top of it. Found by probing the live client:
--
--   Interface 517 is the bank window.
--   Component 0 is the whole window, title bar included.
--   Component 15 holds the backpack shown beside the bank (child N-1 is slot N).
--   Component 201 holds one child per bank slot: child N-1 (dynamic ID) is
--     bank slot N. Children of the open tab are visible; others are hidden.
--     201 is as tall as the whole bank; its parent (199) does the scrolling.
--   Component 170 holds the tab bar icons. Each real tab's icon shows the
--     first item in that tab. The "+" (new tab) button comes after them and
--     has no item. Dropping an item on a tab icon moves it into that tab;
--     dropping it on "+" starts a new tab.
--   The bank stores tabs in the order they were made, which isn't always
--     the tab bar order (tabs can be dragged around), and items not in a tab
--     come last. Player variables BANK_TAB2..BANK_TAB15 hold each stored
--     tab's size. In the all-items view each tab also starts a new section,
--     which shows in the slots' positions - used if the variables can't be read.
--
-- If a game update moves these, isOpen() returns false and the plugin shows
-- a message instead of drawing in the wrong place.

local bankui = {}

local BANK_INTERFACE = 517
local WINDOW = 0          -- the whole bank window
local BACKPACK = 15       -- the backpack shown beside the bank
local SLOT_CONTAINER = 201
local TAB_BAR = 170
local ALL_ITEMS_TAB = 165 -- the infinity icon left of the tab bar

local function try(fn)
    local ok, result = pcall(fn)
    if ok then return result end
    return nil
end

-- The component that holds every bank slot, or nil if the bank isn't open.
function bankui.slotContainer()
    return try(function() return ui.Interfaces:GetComponent(BANK_INTERFACE, SLOT_CONTAINER) end)
end

-- True while the bank window is open and laid out as expected.
function bankui.isOpen()
    local container = bankui.slotContainer()
    return container ~= nil and try(function() return container.visibleGlobal end) == true
end

-- The component drawing bank slot `slot` (1-based).
function bankui.slotComponent(slot)
    return try(function() return ui.Interfaces:GetComponent(BANK_INTERFACE, SLOT_CONTAINER, 0, slot - 1) end)
end

-- Is this slot's item shown in the current tab view?
function bankui.isSlotShown(slot)
    local c = bankui.slotComponent(slot)
    return c ~= nil and try(function() return c.visibleGlobal end) == true
end

-- Reads the tab bar. Returns:
--   tabs      - array of { iconItemId = id, component = c }, one per real tab in order
--   addButton - the "+" (new tab) component: the visible icon with no item, or nil
--               if the bank already has the most tabs it allows
function bankui.readTabIcons()
    local tabs, addButton = {}, nil
    local bar = try(function() return ui.Interfaces:GetComponent(BANK_INTERFACE, TAB_BAR) end)
    if not bar then return tabs, nil end
    try(function()
        bar:IterateDynamicComponents(function(child)
            local itemId = try(function() return child.associatedObjectID end)
            local shown = try(function() return child.visibleGlobal end)
            if shown and type(itemId) == "number" and itemId >= 0 then
                table.insert(tabs, { iconItemId = itemId, component = child })
            elseif shown and not addButton then
                addButton = child
            end
            return false -- keep going
        end)
    end)
    return tabs, addButton
end

-- Stored tab sizes from the player variables, or nil if they can't be read.
local function sizesFromVars(tabCount, itemCount)
    local sizes, total = {}, 0
    for k = 1, tabCount do
        local value = try(function() return var.VarPlayer["BANK_TAB" .. (k + 1)].value end)
        if type(value) ~= "number" or value <= 0 then return nil end
        sizes[k] = value
        total = total + value
    end
    if total > itemCount then return nil end
    return sizes
end

-- Stored tab sizes from where the slots sit in the all-items view: within a
-- tab, items run along each row and wrap to the next; a new tab starts a new
-- section. Returns nil unless every slot is on show.
local function sizesFromLayout(tabCount, firstSlot, itemCount)
    local points = {}
    for i = 1, itemCount do
        local c = bankui.slotComponent(firstSlot + i - 1)
        local p = c and try(function() return c.visibleGlobal and { x = c.xyLocal.x, y = c.xyLocal.y } end)
        if not p then return nil end
        points[i] = p
    end
    -- The usual gap between rows: the smallest step down when a row wraps.
    local rowStep = nil
    for i = 2, itemCount do
        local dy = points[i].y - points[i - 1].y
        if points[i].x < points[i - 1].x and dy > 0 and (not rowStep or dy < rowStep) then rowStep = dy end
    end
    local sizes, start = {}, 1
    for i = 2, itemCount do
        local a, b = points[i - 1], points[i]
        local sameRow = b.y == a.y and b.x > a.x
        local nextRow = rowStep and b.x < a.x and b.y - a.y == rowStep
        if not sameRow and not nextRow then
            table.insert(sizes, i - start)
            start = i
            if #sizes == tabCount then break end
        end
    end
    if #sizes < tabCount then table.insert(sizes, itemCount - start + 1) end
    if #sizes ~= tabCount then return nil end
    return sizes
end

-- Works out the bank's tabs. `items` are the bank items in slot order.
-- Returns tabs, addButton, source:
--   tabs      - { { size, display, iconItemId, component } ... } in stored
--               order (pass to guide.rangesFromSizes), or nil if the sizes
--               can't be worked out (open the all-items tab to fix that)
--   addButton - the "+" component, or nil when no more tabs are allowed
--   source    - "vars" or "layout", for the development log
function bankui.readTabs(items)
    local icons, addButton = bankui.readTabIcons()
    if #icons == 0 then return {}, addButton, "none" end
    local firstSlot = items[1] and items[1].slot or 1
    local sizes, source = sizesFromVars(#icons, #items), "vars"
    if not sizes then
        sizes, source = sizesFromLayout(#icons, firstSlot, #items), "layout"
    end
    if not sizes then return nil, addButton, "unknown" end

    -- Match each stored tab to its icon: the icon shows the tab's first item.
    local tabs, used, slot = {}, {}, firstSlot
    local itemAt = {}
    for _, item in ipairs(items) do itemAt[item.slot] = item end
    for k, size in ipairs(sizes) do
        local first = itemAt[slot]
        local tab = { size = size }
        for d, icon in ipairs(icons) do
            if not used[d] and first and icon.iconItemId == first.id then
                tab.display, tab.iconItemId, tab.component = d, icon.iconItemId, icon.component
                used[d] = true
                break
            end
        end
        tabs[k] = tab
        slot = slot + size
    end
    -- Tabs with a custom icon: give them the remaining icons in order.
    for _, tab in ipairs(tabs) do
        if not tab.display then
            for d, icon in ipairs(icons) do
                if not used[d] then
                    tab.display, tab.iconItemId, tab.component = d, icon.iconItemId, icon.component
                    used[d] = true
                    break
                end
            end
        end
    end
    return tabs, addButton, source
end

-- Screen rectangle of a component: x, y, width, height (interface units),
-- or nil if it can't be read.
function bankui.rect(component)
    return try(function()
        local p = component.xyGlobal
        return { x = p.x, y = p.y, w = component.width, h = component.height }
    end)
end

-- Is this slot drawn on screen, and showing the item we think is there?
function bankui.slotShowsItem(slot, itemId)
    local c = bankui.slotComponent(slot)
    return c ~= nil and try(function() return c.visibleGlobal and c.associatedObjectID == itemId end) == true
end

-- The bank slot a component shows (1-based), if it's one of the slot
-- components; nil otherwise.
function bankui.slotOfComponent(component)
    return try(function()
        if component.interfaceID ~= BANK_INTERFACE then return nil end
        local parent = component.parent
        if not parent or parent.staticID ~= SLOT_CONTAINER then return nil end
        return component.dynamicID + 1
    end)
end

-- The backpack shown beside the bank: component 15 has one child per
-- backpack slot (child N-1 is slot N).
function bankui.backpackSlotComponent(slot)
    return try(function() return ui.Interfaces:GetComponent(BANK_INTERFACE, BACKPACK, 0, slot - 1) end)
end

function bankui.backpackShowsItem(slot, itemId)
    local c = bankui.backpackSlotComponent(slot)
    return c ~= nil and try(function() return c.visibleGlobal and c.associatedObjectID == itemId end) == true
end

-- Screen rectangle of the whole bank window (its title bar is along the top).
function bankui.windowRect()
    local window = try(function() return ui.Interfaces:GetComponent(BANK_INTERFACE, WINDOW) end)
    return window and bankui.rect(window) or nil
end

-- The "all items" (infinity) tab icon at the left of the tab bar.
function bankui.allItemsTab()
    return try(function() return ui.Interfaces:GetComponent(BANK_INTERFACE, ALL_ITEMS_TAB) end)
end

-- Scrolling -----------------------------------------------------------------
-- The game reports each component's position as if nothing were scrolled,
-- and the bank grid is scrolled by a component further up (the grid itself is
-- as tall as the whole bank). So to find where an item is actually drawn, the
-- scroll of every component above it is taken off, and the visible area is
-- where all of those components overlap.

-- The slot container and every component above it, container first.
local function ancestry()
    local chain = {}
    local c = bankui.slotContainer()
    while c and #chain < 30 do
        table.insert(chain, c)
        local current = c
        c = try(function() return current.parent end)
    end
    return chain
end

local function intersect(a, b)
    if not a then return b end
    local x, y = math.max(a.x, b.x), math.max(a.y, b.y)
    local right, bottom = math.min(a.x + a.w, b.x + b.w), math.min(a.y + a.h, b.y + b.h)
    return { x = x, y = y, w = math.max(0, right - x), h = math.max(0, bottom - y) }
end

-- Works out the grid's on-screen area and scroll. Returns nil if the bank
-- isn't open, otherwise:
--   view             - the visible part of the item grid {x, y, w, h}
--   scrollX, scrollY - how far bank slots are shifted from their reported spot
-- Pass the result to slotRect().
function bankui.geometry()
    local chain = ancestry()
    if #chain == 0 then return nil end
    local view, offX, offY = nil, 0, 0
    for i = #chain, 1, -1 do -- from the top down
        local c = chain[i]
        local r = bankui.rect(c)
        if r and r.w > 0 and r.h > 0 then
            r.x, r.y = r.x - offX, r.y - offY
            view = intersect(view, r)
        end
        offX = offX + (try(function() return c.scrollX end) or 0)
        offY = offY + (try(function() return c.scrollY end) or 0)
    end
    if not view or view.w <= 0 or view.h <= 0 then return nil end
    return { view = view, scrollX = offX, scrollY = offY }
end

-- How far the item grid is scrolled (changes when the player scrolls).
function bankui.scrollY()
    local geo = bankui.geometry()
    return geo and geo.scrollY or 0
end

-- Screen rectangle where bank slot `slot` is drawn, using bankui.geometry().
-- It may lie outside geo.view when the item is scrolled out of view.
function bankui.slotRect(slot, geo)
    local c = bankui.slotComponent(slot)
    local r = c and bankui.rect(c)
    if r then
        r.x, r.y = r.x - geo.scrollX, r.y - geo.scrollY
    end
    return r
end

-- For the development log: every component from the grid up, with its
-- position, size and scroll.
function bankui.describeAncestry()
    local parts = {}
    for _, c in ipairs(ancestry()) do
        table.insert(parts, try(function()
            local p = c.xyGlobal
            return string.format("%s:%s %d,%d %dx%d s=%s,%s", tostring(c.interfaceID), tostring(c.staticID),
                p.x, p.y, c.width, c.height, tostring(c.scrollX), tostring(c.scrollY))
        end) or "?")
    end
    return table.concat(parts, " < ")
end

return bankui
