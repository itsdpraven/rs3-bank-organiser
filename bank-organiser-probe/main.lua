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

log("PROBE: verification running (run " .. run .. "). Use the bank as described at the top of main.lua.")
