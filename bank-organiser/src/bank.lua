-- bank.lua
-- Reads the player's bank. The bank inventory is only sent to the game client
-- while the bank is open, so this is read whenever the bank opens or changes.
--
-- Each item is described from the game's own data: its Grand Exchange
-- category, the game's item category, its config name, combat style and
-- tier params, and right-click options. That data is read once per item ID
-- (rawFromObj) into a plain table, and bank.describe turns it into the item
-- table the rest of the plugin uses - so the tests can feed in recorded data.

local bank = {}

-- The latest read: { items = { ... } } with one entry per non-empty slot,
-- in slot order. Nil until the bank has been read.
bank.snapshot = nil

local function num(value)
    return tonumber(tostring(value or ""))
end

-- Lower-case set of a list of option names.
local function opSet(list)
    local set = {}
    for _, op in pairs(list or {}) do
        if type(op) == "string" and op ~= "" then set[op:lower()] = true end
    end
    return set
end

-- Which combat style an item is for, from its params:
-- "melee", "ranged", "magic", "necromancy", "generic" or nil.
local function styleOf(params, catName)
    if num(params.COMBATV2_MELEE_ITEM) == 1 or num(params.COMBATV2_MELEE_WEAPON) == 1 then return "melee" end
    if num(params.COMBATV2_RANGED_ITEM) == 1 or num(params.COMBATV2_RANGED_WEAPON) == 1 then return "ranged" end
    if num(params.COMBATV2_MAGIC_ITEM) == 1 or num(params.COMBATV2_MAGIC_WEAPON) == 1 then return "magic" end
    if num(params.COMBATV2_NECROMANCY_ITEM) == 1 or num(params.COMBATV2_NECROMANCY_WEAPON) == 1 then
        return "necromancy"
    end
    if num(params.MAGICATTACK) then return "magic" end
    if num(params.RANGEATTACK) then return "ranged" end
    if num(params.MELEEATTACK) or (num(params.MELEE_STRENGTH) and catName:find("^WEAPON_")) then return "melee" end
    if num(params.COMBATV2_GENERIC_ITEM) == 1 then return "generic" end
    return nil
end

-- Turns raw item data plus a stack count into the item table used by
-- classifier.lua, guide.lua and sorter.lua.
--   raw = { id, name, configName, catName, cost, tradeable, stackable,
--           ops = { option names }, params = { NAME = value },
--           questCount, questName }
function bank.describe(raw, count, slot)
    local name = raw.name or ("Item " .. tostring(raw.id))
    local params = raw.params or {}
    local catName = (raw.catName or ""):upper()
    local ops = opSet(raw.ops)
    local wearOps = {}
    for i = 1, 8 do
        local op = params["WEAR_OP" .. i]
        if type(op) == "string" and op ~= "" then wearOps[op:lower()] = true end
    end
    return {
        id = raw.id,
        slot = slot,
        name = name,
        lname = name:lower(),
        count = count,
        placeholder = (count == 0),
        cost = raw.cost or 0,
        tradeable = raw.tradeable and true or false,
        stackable = raw.stackable and true or false,
        questCount = raw.questCount or 0,
        questName = raw.questName,
        configName = (raw.configName or ""):upper(),
        catName = catName,
        ge = num(params.GE_CATEGORY),
        style = styleOf(params, catName),
        -- The level needed to wear it (the same for a whole set), else its tier.
        tier = num(params.WEAR_REQUIRES_STAT_LEVEL1) or num(params.COMBATV2_ITEM_TIER) or num(params.LEVELREQUIRE)
            or num(params.RECIPE_REQUIREMENT_VALUE_1) or 0,
        -- Smithing upgrades (+1, +2, +3) of the same armour.
        upgrade = num(params.SMITHING_UPGRADE_VERSION) or 0,
        -- Shared by every dose or charge of the same potion, food or jewellery.
        family = params.POTION_STRUCT and tostring(params.POTION_STRUCT) or nil,
        ops = ops,
        wearOps = wearOps,
        wearable = ops.wear or ops.wield or ops.equip or params.EQUIP_SOUND ~= nil or false,
        params = params,
    }
end

-- Reads an ObjType's data into the raw table bank.describe takes.
local rawCache = {}
function bank.rawFromObj(obj)
    local cached = rawCache[obj.id]
    if cached then return cached end
    local raw = { id = obj.id, name = obj.name, cost = obj.cost or 0, params = {}, ops = {} }
    pcall(function() raw.configName = obj.configName end)
    pcall(function() raw.tradeable = obj.isTradeable end)
    pcall(function() raw.stackable = obj.stackType == ObjStackType.ALWAYS end)
    pcall(function()
        for _, op in pairs(obj.interfaceOpNames) do table.insert(raw.ops, op) end
    end)
    pcall(function()
        if obj.category and obj.category >= 0 then raw.catName = tostring(id.Category.FromID(obj.category)) end
    end)
    pcall(function()
        for _, p in pairs(obj.params) do
            local value = obj:GetParamValue(p)
            if type(value) ~= "number" and type(value) ~= "string" then value = tostring(value) end
            raw.params[p.configName] = value
        end
    end)
    pcall(function()
        local quests = obj.quests
        raw.questCount = quests and #quests or 0
        if quests and quests[1] then
            raw.questName = quests[1].sortName or quests[1].name
        end
    end)
    rawCache[obj.id] = raw
    return raw
end

-- Returns true if a slot holds a real item (empty slots have no object).
local function isRealItem(slotData)
    if not slotData or not slotData.obj then return false end
    local obj = slotData.obj
    return obj.id and obj.id >= 0 and obj.name ~= nil and obj.name ~= "" and obj.name:lower() ~= "null"
end

-- Returns true if an inventory event payload refers to the bank.
function bank.isBankInv(invConfig)
    if not invConfig then return false end
    local ok, same = pcall(function() return invConfig.id == config.Inv.BANK.id end)
    return ok and same
end

-- Reads the bank right now. Returns the snapshot, or nil if the bank isn't
-- available (closed, or not yet sent by the server).
function bank.read()
    local ok, inv = pcall(function() return Inventory.Find(config.Inv.BANK) end)
    if not ok or not inv or not inv.isValid then
        return nil
    end
    local items = {}
    local slots = inv:GetSlots() or {}
    for slot = 1, inv.slotCount do
        local slotData = slots[slot]
        if isRealItem(slotData) then
            table.insert(items, bank.describe(bank.rawFromObj(slotData.obj), slotData.count or 0, slot))
        end
    end
    bank.snapshot = { items = items }
    return bank.snapshot
end

return bank
