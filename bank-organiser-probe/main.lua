-- Bank Organiser Probe (development only - do not submit)
-- Verification session for API details the organiser relies on but the docs
-- don't settle. While it runs it records, as chunks shaped VFY<run>.<n>{...}VFY
-- in PersistentDB (read from outside the game):
--   VARS   - the bank player variables (tab sizes, tab order mapping, icons,
--            current tab, insert mode, placeholders, capacity), on load
--   ICONS  - the tab bar icons, left to right
--   VAR    - every change to a BANK* variable (name, old -> new)
--   INV    - each bank update: the slot numbers reported and what those slots hold
--   HOVER  - the top menu entry's component and item while pointing at the bank
--   FONTS  - the Museo Sans fonts and their line heights
-- Turn it on with the bank open:  pon bank-organiser-probe
-- Then: switch tabs, drag an item onto another tab, drag one onto "+",
-- swap two items, point at a few items, and withdraw/deposit one.

local MAX_NOTES = 400
local BANK = 517

local function try(fn)
    local ok, result = pcall(fn)
    if ok then return result end
    return nil
end

local run = (PersistentDB:GetInt("verifyRun") or 0) + 1
PersistentDB:SetInt("verifyRun", run)
local count = 0
local function note(text)
    if count >= MAX_NOTES then return end
    count = count + 1
    PersistentDB:SetString(string.format("v%03d", count), string.format("VFY%d.%03d{%s}VFY", run, count,
        tostring(text):sub(1, 600)))
end

local function varValue(name)
    local value = try(function() return var.VarPlayer[name].value end)
    return value == nil and "?" or tostring(value)
end

-- Bank variables, read once.
local names = {}
for k = 2, 15 do table.insert(names, "BANK_TAB" .. k) end
for k = 2, 15 do table.insert(names, "BANK_TAB_" .. k .. "_MAPPING_SERVER") end
for k = 2, 15 do table.insert(names, "BANK_TAB_ICON_" .. k) end
for k = 2, 15 do table.insert(names, "BANK_TAB_ICON_NAME_" .. k) end
for _, name in ipairs({ "BANK_CURRENT_TAB", "BANK_ACTIVE", "BANKINSERT", "BANK_ALWAYS_PLACEHOLDER",
    "BANK_MEMBERS_SIZE", "BANK_FREE_SIZE", "BANK_USED_SLOTS", "BANK_TAB_VERTICAL", "BANK_PREVENT_FORCE_TAB" }) do
    table.insert(names, name)
end
local line = {}
for _, name in ipairs(names) do
    table.insert(line, name .. "=" .. varValue(name))
    if #line == 12 then
        note("VARS " .. table.concat(line, " "))
        line = {}
    end
end
if #line > 0 then note("VARS " .. table.concat(line, " ")) end

-- Tab bar icons, left to right.
local icons = {}
try(function()
    ui.Interfaces:GetComponent(BANK, 170):IterateDynamicComponents(function(child)
        if try(function() return child.visibleGlobal end) then
            table.insert(icons, tostring(try(function() return child.associatedObjectID end)))
        end
        return false
    end)
end)
note("ICONS " .. table.concat(icons, ","))

-- Fonts.
local fonts = {}
for fontId = 0, 600 do
    local font = try(function() return config.Font.FromID(fontId) end)
    local name = font and try(function() return font.configName end)
    if name and name:find("MUSEO") then
        table.insert(fonts, fontId .. ":" .. name .. "=" .. tostring(try(function() return font.baseline end)))
    end
end
note("FONTS " .. table.concat(fonts, " "))

-- Changes to bank variables.
Event.VarTransmit.Subscribe("probeVars", function(event)
    local name = try(function() return event.var.configName end)
        or try(function() return event.var.name end) or "?"
    if tostring(name):find("^BANK") then
        note(string.format("VAR %s %s -> %s (varbit=%s)", name, tostring(event.oldValue), tostring(event.newValue),
            tostring(try(function() return event.var.isVarBit end))))
    end
end)

-- Bank updates: which slot numbers are reported, and what's in them.
Event.InventoryUpdated.Subscribe("probeInv", function(event)
    local isBank = try(function() return event.inv.id == config.Inv.BANK.id end)
    if not isBank then return end
    local inv = try(function() return Inventory.Find(config.Inv.BANK) end)
    local parts = {}
    for i, slotId in ipairs(event.slotsUpdated or {}) do
        if i > 12 then break end
        local here = inv and try(function()
            local s = inv:GetSlot(slotId)
            return s and s.obj and (s.obj.id .. "x" .. tostring(s.count)) or "empty"
        end)
        table.insert(parts, tostring(slotId) .. "=" .. tostring(here))
    end
    note(string.format("INV %d slots: %s | BANK_TAB2..4=%s,%s,%s current=%s", #(event.slotsUpdated or {}),
        table.concat(parts, " "), varValue("BANK_TAB2"), varValue("BANK_TAB3"), varValue("BANK_TAB4"),
        varValue("BANK_CURRENT_TAB")))
end)

-- What the top menu entry says about the thing under the cursor in the bank.
local lastHover = nil
Event.MiniMenuReady.Subscribe("probeHover", function(event)
    local text = try(function()
        local entries = event.miniMenu.entries
        local top = entries[#entries]
        local data = top.componentData
        if not data then return nil end
        local c = data.component
        if c.interfaceID ~= BANK then return nil end
        return string.format("HOVER if=%s static=%s dyn=%s parent=%s obj=%s(%s) assoc=%s op=%s entries=%d",
            tostring(c.interfaceID), tostring(try(function() return c.staticID end)),
            tostring(try(function() return c.dynamicID end)), tostring(try(function() return c.parent.staticID end)),
            tostring(try(function() return data.objConfig.id end)), tostring(try(function() return data.objConfig.name end)),
            tostring(try(function() return c.associatedObjectID end)), tostring(try(function() return data.opIndex end)),
            #entries)
    end)
    if text and text ~= lastHover then
        lastHover = text
        note(text)
    end
end)

-- The tab bar's layout: every component from the icons (170) up with its
-- position, size and scroll; the icons themselves; and every visible static
-- component of the bank level with the tab bar (to find the scroll arrows).
-- Logged with the bank open, then again whenever it changes (e.g. after the
-- player clicks a tab bar arrow).
local function rectOf(c)
    return try(function()
        local p = c.xyGlobal
        return string.format("%d,%d %dx%d", p.x, p.y, c.width, c.height)
    end) or "?"
end
local function tabBarReport()
    local bar = try(function() return ui.Interfaces:GetComponent(BANK, 170) end)
    if not bar or not try(function() return bar.visibleGlobal end) then return nil end
    local out = {}
    local c, depth = bar, 0
    while c and depth < 12 do
        local here = c
        table.insert(out, string.format("UP%d s=%s d=%s t=%s %s scroll=%s,%s of %sx%s", depth,
            tostring(try(function() return here.staticID end)), tostring(try(function() return here.dynamicID end)),
            tostring(try(function() return here.type end)), rectOf(here),
            tostring(try(function() return here.scrollX end)), tostring(try(function() return here.scrollY end)),
            tostring(try(function() return here.scrollWidth end)), tostring(try(function() return here.scrollHeight end))))
        c = try(function() return here.parent end)
        depth = depth + 1
    end
    local icons = {}
    try(function()
        bar:IterateDynamicComponents(function(child)
            if try(function() return child.visibleGlobal end) then
                table.insert(icons, string.format("%s@%s", tostring(try(function() return child.associatedObjectID end)),
                    rectOf(child)))
            end
            return false
        end)
    end)
    table.insert(out, "ICONS " .. table.concat(icons, " "))
    local top = try(function() return bar.xyGlobal.y end) or 0
    local bottom = top + (try(function() return bar.height end) or 0)
    local near = {}
    for staticId = 0, 400 do
        local s = try(function() return ui.Interfaces:GetComponent(BANK, staticId) end)
        local y = s and try(function() return s.visibleGlobal and s.xyGlobal.y end)
        local h = y and try(function() return s.height end)
        if y and h and h < 120 and y < bottom + 10 and y + h > top - 10 then
            table.insert(near, string.format("%d(t=%s p=%s)@%s", staticId, tostring(try(function() return s.type end)),
                tostring(try(function() return s.parent.staticID end)), rectOf(s)))
        end
    end
    table.insert(out, "NEAR " .. table.concat(near, " "))
    return out
end

local lastTabBar = nil
local probeTicks = 0
Event.Logic.Subscribe("probeTabBar", function()
    probeTicks = probeTicks + 1
    if probeTicks % 50 ~= 0 then return end
    local lines = tabBarReport()
    local joined = lines and table.concat(lines, "|")
    if joined and joined ~= lastTabBar then
        lastTabBar = joined
        for _, line in ipairs(lines) do
            for i = 1, #line, 560 do note("TABBAR " .. line:sub(i, i + 559)) end
        end
    end
end)

log("PROBE: verification running (run " .. run .. "). Use the bank as described at the top of main.lua.")
