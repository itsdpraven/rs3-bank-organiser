-- fake_client.lua
-- A stand-in for the RuneScape client: just enough of the plugin API, and a
-- simulated bank, to run the whole plugin (main.lua and everything in src/)
-- outside the game.
--
-- The bank is held the way the game holds it: tabs in the order they were
-- made, items not in a tab last, and a tab bar order of its own. Moving items
-- changes that model, then the screen (bank slots, tab bar icons, scrolling)
-- is laid out again and the same events the client sends are fired. Screen
-- positions copy what the probe recorded in the live client: positions are
-- reported as if nothing were scrolled, the item grid scrolls in a parent
-- component, and the tab bar is clipped by component 168, which scrolls
-- sideways with arrows (159 left, 162 right) when the tabs don't fit.
--
-- Development only.

local fake = {}

local BANK = 517
local COLUMNS = 10
local PITCH_X, PITCH_Y = 46, 40       -- slot spacing in the item grid
local SLOT_W, SLOT_H = 40, 36
local SECTION_GAP = 14                -- the divider between tabs in the all-items view
local ICON_PITCH = 48                 -- tab bar icon spacing
local MAX_TABS = 14

-- Components ------------------------------------------------------------------
-- One table type for the game's components and the plugin's own. The game's
-- have their position, size and visibility set directly; the plugin's work
-- them out from SetPos/SetSize (including percentages of the parent).

local Component = {}
local meta = {}

local function newComponent(kind, parent, fields)
    local c = setmetatable({ kind = kind, children = {}, handlers = {} }, meta)
    for k, v in pairs(fields or {}) do rawset(c, k, v) end
    if parent then
        rawset(c, "parent", parent)
        table.insert(parent.children, c)
    end
    return c
end

meta.__index = function(c, key)
    local method = Component[key]
    if method then return method end
    if key == "width" or key == "height" then
        local parentSize = c.parent and c.parent[key] or 0
        if key == "width" then return (rawget(c, "sw") or 0) + (rawget(c, "spw") or 0) * parentSize end
        return (rawget(c, "sh") or 0) + (rawget(c, "sph") or 0) * parentSize
    elseif key == "xyGlobal" then
        local p = c.parent and c.parent.xyGlobal or { x = 0, y = 0 }
        local pw = c.parent and c.parent.width or 0
        local ph = c.parent and c.parent.height or 0
        return { x = p.x + (rawget(c, "px") or 0) + (rawget(c, "ppx") or 0) * pw,
                 y = p.y + (rawget(c, "py") or 0) + (rawget(c, "ppy") or 0) * ph }
    elseif key == "visibleGlobal" then
        if rawget(c, "destroyed") or rawget(c, "hidden") then return false end
        return c.parent == nil or c.parent.visibleGlobal
    elseif key == "visible" then
        return not rawget(c, "hidden")
    end
    return nil
end

function Component:SetPos(x, y, ppx, ppy)
    rawset(self, "px", x); rawset(self, "py", y); rawset(self, "ppx", ppx or 0); rawset(self, "ppy", ppy or 0)
end
function Component:SetSize(w, h, spw, sph)
    rawset(self, "sw", w); rawset(self, "sh", h); rawset(self, "spw", spw or 0); rawset(self, "sph", sph or 0)
end
function Component:AlignTo() end
function Component:MoveToFront() end
function Component:Subscribe(hook, idOrFn, fn)
    self.handlers[hook] = fn or idOrFn
end
function Component:Destroy()
    rawset(self, "destroyed", true)
    local parent = rawget(self, "parent")
    if parent then
        for i, child in ipairs(parent.children) do
            if child == self then table.remove(parent.children, i) break end
        end
    end
end
function Component:DeleteAll()
    for i = #self.children, 1, -1 do self.children[i]:Destroy() end
end
function Component:SetAssociatedObject(objId)
    if math.type(objId) ~= "integer" then error("SetAssociatedObject needs a whole number") end
    rawset(self, "associatedObjectID", objId)
end
function Component:IterateDynamicComponents(callback)
    for _, child in ipairs(rawget(self, "dynamic") or {}) do
        if callback(child, child.visibleGlobal) == true then break end
    end
end
-- Carousel
function Component:Add(entryId, label)
    local entries = rawget(self, "entries") or {}
    rawset(self, "entries", entries)
    table.insert(entries, { id = entryId, label = label })
end
function Component:Select(entryId) rawset(self, "selected", entryId) end

-- Fires a component's handler for `hook`, as a click or change would.
function fake.fire(component, hook, ...)
    local fn = component.handlers[hook]
    if not fn then return false end
    fn(component, ...)
    return true
end

-- Every live descendant of `root`, depth first.
function fake.descendants(root, out)
    out = out or {}
    for _, child in ipairs(root.children) do
        if not rawget(child, "destroyed") then
            table.insert(out, child)
            fake.descendants(child, out)
        end
    end
    return out
end

-- Colours: the plugin sets Vector4 colours; this turns them back into 0xRRGGBB.
function fake.rgb(colour)
    if type(colour) ~= "table" then return nil end
    local function byte(v) return math.floor(v * 255 + 0.5) end
    return (byte(colour.x) << 16) | (byte(colour.y) << 8) | byte(colour.z)
end

-- Item data ---------------------------------------------------------------------
-- Turns recorded item data (tests/fixtures) back into ObjType-like objects.

local categoryNames, categoryIds = {}, {}
local function categoryId(name)
    if not name or name == "" then return -1 end
    if not categoryIds[name] then
        table.insert(categoryNames, name)
        categoryIds[name] = #categoryNames
    end
    return categoryIds[name]
end

local function objFromRaw(raw)
    local params = {}
    for name in pairs(raw.params or {}) do table.insert(params, { configName = name }) end
    table.sort(params, function(a, b) return a.configName < b.configName end)
    local quests = {}
    for i = 1, raw.questCount or 0 do quests[i] = { sortName = raw.questName, name = raw.questName } end
    return {
        id = raw.id, name = raw.name, cost = raw.cost or 0, configName = raw.configName,
        isTradeable = raw.tradeable, stackType = raw.stackable and "ALWAYS" or "NEVER",
        interfaceOpNames = raw.ops or {}, category = categoryId(raw.catName), params = params,
        quests = quests,
        GetParamValue = function(_, p) return raw.params[p.configName] end,
    }
end

-- The client --------------------------------------------------------------------

local Client = {}
Client.__index = Client

--   options.entries  - { { raw, tab = stored tab (0 = none), count } } in bank order
--   options.display  - stored tab -> place in the tab bar (default: made order)
--   options.clipWidth  - how wide the tab bar's visible strip is (369 in the probe)
--   options.insertMode - dropping an item on another inserts it there (else swaps)
--   options.tabInsert  - dropping a tab on another inserts it there (else swaps)
--   options.noVars     - the tab size variables can't be read
--   options.language   - the game's language label
--   options.backpack   - raw items in the backpack
function fake.new(options)
    options = options or {}
    local self = setmetatable({}, Client)
    self.options = options
    self.entries = {}
    for i, e in ipairs(options.entries or {}) do
        table.insert(self.entries, { raw = e.raw, obj = objFromRaw(e.raw), tab = e.tab or 0, order = i,
            count = e.count or 1 })
    end
    self.display = {}
    for t, d in pairs(options.display or {}) do self.display[t] = d end
    self.backpack = {}
    for i, raw in ipairs(options.backpack or {}) do self.backpack[i] = { raw = raw, obj = objFromRaw(raw) } end
    self.view = 0                 -- 0 = all items, else a stored tab
    self.scrollY, self.tabScroll = 0, 0
    self.clipWidth = options.clipWidth or 369
    self.open = true
    self.counter = #self.entries
    self.frame = 0
    self.logs = {}
    self.store = options.store or {}
    self.handlers = {}
    self.characterName = options.characterName or "Tester"
    self.vars = {}
    self:buildComponents()
    self:layout()
    return self
end

-- The game's components the plugin looks at, made once and updated by layout().
function Client:buildComponents()
    local top = newComponent("Layer", nil, { xyGlobal = { x = 0, y = 0 }, width = 1536, height = 889,
        visibleGlobal = true, staticID = 28, interfaceID = 0 })
    local function game(staticId, parent, x, y, w, h)
        return newComponent("Layer", parent, { interfaceID = BANK, staticID = staticId, dynamicID = -1,
            xyGlobal = { x = x, y = y }, xyLocal = { x = 0, y = 0 }, width = w, height = h, visibleGlobal = true,
            scrollX = 0, scrollY = 0 })
    end
    local c = {}
    -- The tab bar strip (168) is `clipWidth` wide, with the arrows either side;
    -- the window grows to fit a wide strip.
    local barRight = 723 + self.clipWidth + 24
    c[0] = game(0, top, 635, 29, math.max(714, barRight - 635 + 16), 822)
    c[158] = game(158, c[0], 651, 73, barRight - 651, 38)
    c[159] = game(159, c[158], 651, 73, 23, 34)
    c[162] = game(162, c[158], 723 + self.clipWidth + 1, 73, 23, 34)
    c[165] = game(165, c[158], 675, 73, 48, 38)
    c[168] = game(168, c[158], 723, 73, self.clipWidth, 38)
    c[170] = game(170, c[168], 723, 73, 0, 38)
    c[199] = game(199, c[0], 651, 120, 470, 600)
    c[201] = game(201, c[199], 651, 120, 470, 0)
    c[15] = game(15, c[0], 1140, 120, 190, 290)
    self.c = c
    -- Pools of dynamic children (bank slots, tab icons, backpack slots).
    local function pool(parent, count)
        local list = {}
        for i = 1, count do
            list[i] = newComponent("Sprite", parent, { interfaceID = BANK, staticID = parent.staticID,
                dynamicID = i - 1, xyGlobal = { x = 0, y = 0 }, xyLocal = { x = 0, y = 0 }, width = 0, height = 0,
                visibleGlobal = false, associatedObjectID = -1 })
        end
        rawset(parent, "dynamic", list)
        return list
    end
    self.slots = pool(c[201], 1100)
    self.icons = pool(c[170], MAX_TABS + 1)
    self.packSlots = pool(c[15], 28)
    self.pluginLayer = newComponent("Layer", nil, { xyGlobal = { x = 0, y = 0 }, width = 1536, height = 889,
        visibleGlobal = true })
end

-- Bank order: tabs in made order, then items not in a tab.
function Client:sortEntries()
    table.sort(self.entries, function(a, b)
        local ta, tb = a.tab == 0 and math.huge or a.tab, b.tab == 0 and math.huge or b.tab
        if ta ~= tb then return ta < tb end
        return a.order < b.order
    end)
end

-- Removes empty tabs (the game does), renumbering the rest.
function Client:dropEmptyTabs()
    local used, maxTab = {}, 0
    for _, e in ipairs(self.entries) do
        if e.tab > 0 then used[e.tab], maxTab = true, math.max(maxTab, e.tab) end
    end
    for t in pairs(self.display) do maxTab = math.max(maxTab, t) end
    local newIndex, display, n = {}, {}, 0
    for t = 1, maxTab do
        if used[t] then
            n = n + 1
            newIndex[t] = n
            display[n] = self.display[t] or (1000 + t)
        end
    end
    for _, e in ipairs(self.entries) do if e.tab > 0 then e.tab = newIndex[e.tab] end end
    self.display = display
    if self.view > 0 then self.view = newIndex[self.view] or 0 end
end

function Client:tabCount()
    local n = 0
    for _ in pairs(self.display) do n = n + 1 end
    return n
end

-- Stored tabs in tab bar order.
function Client:tabsByDisplay()
    local list = {}
    for t in pairs(self.display) do table.insert(list, t) end
    table.sort(list, function(a, b) return self.display[a] < self.display[b] end)
    return list
end

-- Lays everything out again from the bank model.
function Client:layout()
    self:dropEmptyTabs()
    self:sortEntries()
    local c = self.c
    local sizes, first = {}, {}
    for i, e in ipairs(self.entries) do
        e.slot = i
        if e.tab > 0 then
            sizes[e.tab] = (sizes[e.tab] or 0) + 1
            first[e.tab] = first[e.tab] or e
        end
    end
    self.sizes = sizes
    local tabCount = self:tabCount()

    -- Tab bar: one icon per tab in tab bar order, then "+" while there's room.
    local order = self:tabsByDisplay()
    local iconCount = #order + (tabCount < MAX_TABS and 1 or 0)
    rawset(c[170], "width", iconCount * ICON_PITCH)
    rawset(c[168], "width", self.clipWidth)
    local maxScroll = math.max(0, iconCount * ICON_PITCH - self.clipWidth)
    self.tabScroll = math.max(0, math.min(self.tabScroll, maxScroll))
    rawset(c[168], "scrollX", self.tabScroll)
    rawset(c[168], "scrollWidth", iconCount * ICON_PITCH)
    local overflow = maxScroll > 0
    rawset(c[159], "visibleGlobal", overflow and self.open)
    rawset(c[162], "visibleGlobal", overflow and self.open)
    self.iconTab = {}
    for i, icon in ipairs(self.icons) do
        local shown = i <= iconCount and self.open
        rawset(icon, "visibleGlobal", shown)
        rawset(icon, "xyGlobal", { x = 729 + (i - 1) * ICON_PITCH, y = 75 })
        rawset(icon, "width", 36); rawset(icon, "height", 32)
        local t = order[i]
        rawset(icon, "associatedObjectID", (shown and t) and first[t].raw.id or -1)
        self.iconTab[i] = t -- nil for "+"
    end
    self.iconCount = iconCount

    -- Item grid: the open tab, or every item (items not in a tab first, then
    -- each tab in tab bar order, each starting a new section).
    local sections = {}
    if self.view == 0 then
        local loose = {}
        for _, e in ipairs(self.entries) do if e.tab == 0 then table.insert(loose, e) end end
        if #loose > 0 then table.insert(sections, loose) end
        for _, t in ipairs(order) do
            local list = {}
            for _, e in ipairs(self.entries) do if e.tab == t then table.insert(list, e) end end
            table.insert(sections, list)
        end
    else
        local list = {}
        for _, e in ipairs(self.entries) do if e.tab == self.view then table.insert(list, e) end end
        sections[1] = list
    end
    for _, s in ipairs(self.slots) do rawset(s, "visibleGlobal", false); rawset(s, "associatedObjectID", -1) end
    local y = 0
    self.rows = {} -- { top, slots = { [column] = slot } } for finding what's at a point
    for k, list in ipairs(sections) do
        if k > 1 then y = y + SECTION_GAP end
        for i, e in ipairs(list) do
            local col = (i - 1) % COLUMNS
            if col == 0 then
                if i > 1 then y = y + PITCH_Y end
                table.insert(self.rows, { top = y, slots = {} })
            end
            self.rows[#self.rows].slots[col] = e.slot
            local s = self.slots[e.slot]
            rawset(s, "visibleGlobal", self.open)
            rawset(s, "associatedObjectID", e.raw.id)
            rawset(s, "xyGlobal", { x = 651 + col * PITCH_X + 4, y = 120 + y + 2 })
            rawset(s, "xyLocal", { x = col * PITCH_X + 4, y = y + 2 })
            rawset(s, "width", SLOT_W); rawset(s, "height", SLOT_H)
        end
        if #list > 0 then y = y + PITCH_Y end
    end
    self.contentHeight = y
    rawset(c[201], "height", math.max(y, 1))
    self.scrollY = math.max(0, math.min(self.scrollY, math.max(0, y - c[199].height)))
    rawset(c[199], "scrollY", self.scrollY)
    for _, key in ipairs({ 0, 158, 165, 168, 170, 199, 201, 15 }) do rawset(c[key], "visibleGlobal", self.open) end

    -- Backpack beside the bank.
    for i, s in ipairs(self.packSlots) do
        local item = self.backpack[i]
        rawset(s, "visibleGlobal", self.open)
        rawset(s, "xyGlobal", { x = 1140 + ((i - 1) % 4) * PITCH_X, y = 120 + ((i - 1) // 4) * PITCH_Y })
        rawset(s, "width", SLOT_W); rawset(s, "height", SLOT_H)
        rawset(s, "associatedObjectID", item and item.raw.id or -1)
    end

    -- Player variables.
    local old = self.vars
    self.vars = { BANK_CURRENT_TAB = self.view, BANKINSERT = self.options.insertMode and 1 or 0 }
    for k = 1, MAX_TABS do self.vars["BANK_TAB" .. (k + 1)] = sizes[k] or 0 end
    self.changedVars = {}
    for name, value in pairs(self.vars) do
        if old[name] ~= value then table.insert(self.changedVars, { name = name, old = old[name] or 0, new = value }) end
    end
end

-- The plugin API ------------------------------------------------------------------

-- Sets the globals the plugin uses. Call before loading main.lua.
function Client:install()
    local client = self
    local function newEvent(name)
        return { Subscribe = function(id, fn)
            client.handlers[name] = client.handlers[name] or {}
            client.handlers[name][id] = fn
        end }
    end
    Event = setmetatable({}, { __index = function(t, name)
        local e = newEvent(name)
        rawset(t, name, e)
        return e
    end })
    Vector4 = { new = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end }
    log = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        table.insert(client.logs, table.concat(parts, " "))
    end
    print = function(...) log(...) end
    GameState = { GAME = 30 }
    ObjStackType = { ALWAYS = "ALWAYS" }
    PlayerList = { Self = function() return { displayName = client.characterName } end }
    game = { options = { Language = { setting = 0, GetLabel = function() return client.options.language or "English" end } } }
    local fonts = {
        [26] = { configName = "MUSEO_SANS_11PT_REGULAR", baseline = 16 },
        [28] = { configName = "MUSEO_SANS_13PT_REGULAR", baseline = 18 },
        [29] = { configName = "MUSEO_SANS_13PT_BOLD", baseline = 18 },
        [30] = { configName = "MUSEO_SANS_15PT_REGULAR", baseline = 18 },
        [31] = { configName = "MUSEO_SANS_15PT_BOLD", baseline = 18 },
    }
    config = {
        Font = { FromID = function(i) return fonts[i] end },
        Inv = { BANK = { id = 95 }, INV = { id = 93 } },
    }
    id = {
        Component = { TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP = "PLUGIN_LAYER" },
        StyleSheet = {},
        Font = { MUSEO_SANS_15PT_REGULAR = 30 },
        Category = { FromID = function(n) return categoryNames[n] end },
    }
    var = { VarPlayer = setmetatable({}, { __index = function(_, name)
        if client.options.noVars and name:find("^BANK_TAB%d") then error("no such variable") end
        return { value = client.vars[name], configName = name }
    end }) }
    Inventory = { Find = function(invConfig)
        if invConfig == config.Inv.BANK then
            if not client.open then return nil end
            return { isValid = true, slotCount = 1020, GetSlots = function()
                local slots = {}
                for _, e in ipairs(client.entries) do slots[e.slot] = { obj = e.obj, count = e.count } end
                return slots
            end }
        elseif invConfig == config.Inv.INV then
            return { isValid = true, slotCount = 28, GetSlots = function()
                local slots = {}
                for i, item in pairs(client.backpack) do slots[i] = { obj = item.obj, count = 1 } end
                return slots
            end }
        end
        return nil
    end }
    PersistentDB = {
        GetStructuredData = function(_, key) return client.store[key] end,
        SetStructuredData = function(_, key, value) client.store[key] = value; return true end,
        Clear = function() for key in pairs(client.store) do client.store[key] = nil end return true end,
        IterateEntries = function(_, fn) for key in pairs(client.store) do if not fn(key) then break end end end,
        Delete = function(_, key) client.store[key] = nil end,
    }
    local function plugin(kind)
        return { new = function(parent)
            local comp = newComponent(kind, parent)
            if kind == "Button" or kind == "InputField" or kind == "Carousel" then rawset(comp, "text", {}) end
            return comp
        end }
    end
    ui = {
        Text = plugin("Text"), Button = plugin("Button"), Rectangle = plugin("Rectangle"), Layer = plugin("Layer"),
        InputField = plugin("InputField"), Sprite = plugin("Sprite"), Carousel = plugin("Carousel"),
        Hook = { ONCLICK = "ONCLICK", ONBUTTONPRESSED = "ONBUTTONPRESSED", ONCONTENTCHANGED = "ONCONTENTCHANGED",
            ONSELECTIONCHANGED = "ONSELECTIONCHANGED", ONSCROLLWHEEL = "ONSCROLLWHEEL",
            ONSWIPEVERTICAL = "ONSWIPEVERTICAL", ONSWIPECOMPLETE = "ONSWIPECOMPLETE" },
        AlignMode = { CENTRE = 1, TOPLEFT = 0 },
        ObjectQuantityDisplayMode = { NEVER = 0 },
        InputFieldActionResult = { SUBMIT = 1 },
        Interfaces = { GetComponent = function(_, interfaceId, staticId, _, index)
            if staticId == nil then
                return interfaceId == "PLUGIN_LAYER" and client.pluginLayer or nil
            end
            if interfaceId ~= BANK then return nil end
            local comp = client.c[staticId]
            if index ~= nil then
                local list = comp and rawget(comp, "dynamic")
                return list and list[index + 1] or nil
            end
            return comp
        end },
    }
end

-- Loads the plugin fresh (every module reloaded), then opens its window.
function Client:loadPlugin(pluginDir)
    for name in pairs(package.loaded) do
        if name:find("^src/") then package.loaded[name] = nil end
    end
    self:install()
    dofile(pluginDir .. "/main.lua")
    self.panelRoot = newComponent("Layer", nil, { xyGlobal = { x = 10, y = 300 }, width = 300, height = 480,
        visibleGlobal = true })
    self:fireEvent("ContentLayerReady", { component = self.panelRoot })
    self.settingsRoot = newComponent("Layer", nil, { xyGlobal = { x = 0, y = 0 }, width = 380, height = 200,
        visibleGlobal = true })
    self:fireEvent("SettingsLayerReady", { component = self.settingsRoot })
end

function Client:fireEvent(name, payload)
    for _, fn in pairs(self.handlers[name] or {}) do fn(payload) end
end

-- Runs `n` client ticks (50 a second; a game tick every 30).
function Client:tick(n)
    for _ = 1, n or 1 do
        self.frame = self.frame + 1
        if self.frame % 30 == 0 then self:fireEvent("ServerLogic", {}) end
        self:fireEvent("Logic", {})
    end
end

-- Lays out again and tells the plugin the bank changed (as the client does).
function Client:changed()
    self:layout()
    if self.open then
        self:fireEvent("InventoryUpdated", { inv = config.Inv.BANK, slotsUpdated = { 1 } })
    end
    for _, v in ipairs(self.changedVars) do
        self:fireEvent("VarTransmit", { var = { configName = v.name }, oldValue = v.old, newValue = v.new })
    end
end

-- Bank actions (what a player's drags and clicks do) ------------------------------

-- Drags the item in `slot` onto tab bar icon `iconIndex` (a tab, or "+").
-- Returns false if that isn't possible.
function Client:dragItemToIcon(slot, iconIndex)
    local e = self.entries[slot]
    if not e or iconIndex > self.iconCount then return false end
    local t = self.iconTab[iconIndex]
    if not t then
        if self:tabCount() >= MAX_TABS then return false end
        t = self:tabCount() + 1
        local last = 0
        for _, d in pairs(self.display) do last = math.max(last, d) end
        self.display[t] = last + 1
    end
    self.counter = self.counter + 1
    e.tab, e.order = t, self.counter
    self:changed()
    return true
end

-- Drags the item in slot `a` onto the item in slot `b`: they swap places, or
-- (insert mode) `a` is put in `b`'s place and the rest shuffle along.
function Client:dragItemToItem(a, b)
    local ea, eb = self.entries[a], self.entries[b]
    if not ea or not eb or a == b then return false end
    if self.options.insertMode then
        local tab, order = eb.tab, eb.order
        for _, e in ipairs(self.entries) do
            if e.tab == tab and e.order >= order and e ~= ea then
                e.order = e.order + 1
                self.counter = math.max(self.counter, e.order) -- later drags still go last
            end
        end
        ea.tab, ea.order = tab, order
    else
        ea.tab, eb.tab = eb.tab, ea.tab
        ea.order, eb.order = eb.order, ea.order
    end
    self:changed()
    return true
end

-- Drags tab bar icon `from` onto icon `to` (both tabs): they swap places, or
-- (tab insert) `from` moves to `to`'s place.
function Client:dragIconToIcon(from, to)
    local a, b = self.iconTab[from], self.iconTab[to]
    if not a or not b or a == b then return false end
    if self.options.tabInsert then
        local order = self:tabsByDisplay()
        local ia, ib
        for i, t in ipairs(order) do
            if t == a then ia = i end
            if t == b then ib = i end
        end
        table.remove(order, ia)
        table.insert(order, ib, a)
        for i, t in ipairs(order) do self.display[t] = i end
    else
        self.display[a], self.display[b] = self.display[b], self.display[a]
    end
    self:changed()
    return true
end

-- Clicks the all-items tab, or a tab bar icon (opens that tab on its own).
function Client:openAll()
    self.view = 0
    self.scrollY = 0
    self:changed()
end
function Client:openTabIcon(iconIndex)
    local t = self.iconTab[iconIndex]
    if not t then return false end
    self.view = t
    self.scrollY = 0
    self:changed()
    return true
end

function Client:scrollGrid(dy)
    self.scrollY = self.scrollY + dy
    self:layout()
end
function Client:clickArrow(side)
    self.tabScroll = self.tabScroll + (side == "right" and 63 or -63)
    self:layout()
end

-- Closes or opens the bank.
function Client:setOpen(open)
    self.open = open
    self:layout()
    if open then
        self:fireEvent("InventoryAdded", { inv = config.Inv.BANK })
    else
        self:fireEvent("InventoryRemoved", { inv = config.Inv.BANK })
    end
end

-- Puts the mouse over a bank slot: fires the menu event the plugin reads.
function Client:hover(slot)
    local s = slot and self.slots[slot]
    local entries = { { componentData = s and { component = s, objConfig = { id = s.associatedObjectID } } or nil } }
    self:fireEvent("MiniMenuReady", { miniMenu = { entries = entries } })
end

-- What's on screen at a point -----------------------------------------------------

-- Returns what a player would hit at (x, y): { kind = "slot", slot },
-- { kind = "icon", index }, { kind = "all" }, { kind = "arrow", side }, or nil.
function Client:hitTest(x, y)
    local c = self.c
    local function inside(comp, px, py)
        local p = comp.xyGlobal
        return px >= p.x and px < p.x + comp.width and py >= p.y and py < p.y + comp.height
    end
    if not self.open then return nil end
    if c[159].visibleGlobal and inside(c[159], x, y) then return { kind = "arrow", side = "left" } end
    if c[162].visibleGlobal and inside(c[162], x, y) then return { kind = "arrow", side = "right" } end
    if inside(c[165], x, y) then return { kind = "all" } end
    if inside(c[168], x, y) then
        local local_x = x + self.tabScroll - 729
        local index = math.floor(local_x / ICON_PITCH) + 1
        if local_x >= 0 and local_x - (index - 1) * ICON_PITCH < 36 and index <= self.iconCount then
            return { kind = "icon", index = index }
        end
        return nil
    end
    if inside(c[199], x, y) then
        local cy = y - 120 + self.scrollY
        local col = math.floor((x - 651 - 4) / PITCH_X)
        for _, row in ipairs(self.rows) do
            if cy >= row.top + 2 and cy < row.top + 2 + SLOT_H then
                local slot = row.slots[col]
                if slot and x - 651 - 4 - col * PITCH_X < SLOT_W then return { kind = "slot", slot = slot } end
            end
        end
    end
    return nil
end

-- The visible strip of the tab bar and the grid, for checking where things are drawn.
function Client:tabStripRect()
    local p = self.c[168].xyGlobal
    return { x = p.x, y = p.y, w = self.clipWidth, h = self.c[168].height }
end
function Client:windowRect()
    local p = self.c[0].xyGlobal
    return { x = p.x, y = p.y, w = self.c[0].width, h = self.c[0].height }
end

-- Plugin errors logged so far.
function Client:errors()
    local list = {}
    for _, line in ipairs(self.logs) do
        if line:find("^Error in") then table.insert(list, line) end
    end
    return list
end

return fake
