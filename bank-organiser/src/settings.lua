-- settings.lua
-- The player's settings, tab locks and plan, saved with PersistentDB (local
-- to this device only):
--   "meta"              - { perCharacter = bool }
--   "settings"          - shared settings (when perCharacter is off)
--   "settings:<name>"   - per-character settings (when perCharacter is on)
--
-- Two modes:
--   fresh - "Organise my bank" (the default): follow a plan, a list of tabs
--           each { label, family, categories = { ids } }, copied from a plan
--           style (presets.lua) and then edited by the player.
--   tidy  - "Just tidy my tabs": keep the player's own tabs, move only items
--           that clearly belong in another of them.
-- Either way the plugin can then put the items inside each tab in order.
-- Locked tabs are left alone in both modes. They're remembered by the item
-- on the tab's icon (the tab's first item), which the plugin never asks the
-- player to move.

local util = require("src/util")
local presets = require("src/presets")

local settings = {}

-- Saves from before this version get the current defaults for the plan and
-- mode (the categories changed), keeping the player's locks and own rules.
settings.VERSION = 2

-- Simple settings, shown on the "Edit plan" screen.
--   int    - number from min to max
--   bool   - yes/no
--   choice - one of `choices` ({ value, label })
settings.SCHEMA = {
    { key = "mode", type = "choice", default = "fresh",
      choices = { { "fresh", "Organise my bank" }, { "tidy", "Just tidy my tabs" } } },
    { key = "strictness", type = "choice", default = "normal",
      choices = { { "relaxed", "Relaxed" }, { "normal", "Normal" }, { "strict", "Strict" } } },
    { key = "maxTabs", type = "int", default = 14, min = 2, max = 14 },
    { key = "minTabSize", type = "int", default = 5, min = 1, max = 30 },
    { key = "orderTabs", type = "bool", default = true },
    { key = "sortInside", type = "bool", default = true },
    { key = "tabFocus", type = "bool", default = true },
    { key = "hoverTips", type = "bool", default = true },
    { key = "depositHelp", type = "bool", default = true },
    { key = "perCharacter", type = "bool", default = true },
}

settings.byKey = {}
for _, entry in ipairs(settings.SCHEMA) do
    settings.byKey[entry.key] = entry
end

-- A fresh settings table: defaults plus the Recommended plan.
function settings.defaults()
    local values = {}
    for _, entry in ipairs(settings.SCHEMA) do
        values[entry.key] = entry.default
    end
    return {
        version = settings.VERSION,
        values = values,
        plan = util.deepCopy(presets.BUILT_IN[1].groups),
        activePreset = presets.BUILT_IN[1].id,
        customRules = {},
        lockedTabs = {}, -- tostring(icon item id) -> true
    }
end

settings.data = settings.defaults()
settings.profile = nil
local listeners = {}

-- Returns true if `value` is allowed for the setting `entry`.
local function valid(entry, value)
    if type(value) ~= type(entry.default) then return false end
    if entry.type == "int" then
        return value >= entry.min and value <= entry.max
    elseif entry.type == "choice" then
        for _, choice in ipairs(entry.choices) do
            if choice[1] == value then return true end
        end
        return false
    end
    return true
end

-- Fills in anything missing or invalid (e.g. from older saves).
local function repair(data)
    local fresh = settings.defaults()
    if type(data) ~= "table" then
        return fresh
    end
    data.values = type(data.values) == "table" and data.values or {}
    if (tonumber(data.version) or 1) < settings.VERSION then
        data.values.mode, data.values.maxTabs = nil, nil
        data.plan = nil
        data.version = settings.VERSION
    end
    for _, entry in ipairs(settings.SCHEMA) do
        if not valid(entry, data.values[entry.key]) then
            data.values[entry.key] = entry.default
        end
    end
    if type(data.plan) ~= "table" or #data.plan == 0 then
        data.plan = fresh.plan
        data.activePreset = fresh.activePreset
    end
    for i, tab in ipairs(data.plan) do
        if type(tab) ~= "table" then tab = {}; data.plan[i] = tab end
        tab.label = type(tab.label) == "string" and tab.label or ("Tab " .. i)
        tab.categories = type(tab.categories) == "table" and tab.categories or {}
        tab.items = type(tab.items) == "table" and tab.items or {}
    end
    data.customRules = type(data.customRules) == "table" and data.customRules or {}
    data.lockedTabs = type(data.lockedTabs) == "table" and data.lockedTabs or {}
    data.activePreset = data.activePreset or "custom"
    return data
end

local function storageKey()
    if settings.profile then
        return "settings:" .. settings.profile
    end
    return "settings"
end

-- Loads settings for a character. Pass nil when the character name is unknown.
function settings.load(characterName)
    local meta = PersistentDB:GetStructuredData("meta") or { perCharacter = true }
    settings.characterName = characterName
    settings.profile = (meta.perCharacter and characterName) or nil
    settings.data = repair(PersistentDB:GetStructuredData(storageKey()))
    settings.data.values.perCharacter = meta.perCharacter and true or false
end

function settings.save()
    PersistentDB:SetStructuredData("meta", { perCharacter = settings.data.values.perCharacter })
    PersistentDB:SetStructuredData(storageKey(), settings.data)
end

-- Registers fn(key), called whenever anything changes.
function settings.onChange(fn)
    table.insert(listeners, fn)
end

local function changed(key)
    settings.save()
    for _, fn in ipairs(listeners) do
        util.try("settings listener", fn, key)
    end
end

function settings.get(key)
    return settings.data.values[key]
end

function settings.set(key, value)
    if settings.data.values[key] == value then
        return
    end
    settings.data.values[key] = value
    if key == "perCharacter" then
        -- Switching storage: the current settings are copied to the new location.
        settings.profile = (value and settings.characterName) or nil
    end
    changed(key)
end

-- Replaces the plan with a plan style.
function settings.applyPreset(presetId)
    local preset = presets.find(presetId)
    if not preset then return end
    settings.data.plan = util.deepCopy(preset.groups)
    settings.data.activePreset = presetId
    changed("plan")
end

-- Returns the index of the planned tab holding `categoryId` (the last tab,
-- "Everything else", if the category isn't listed anywhere).
function settings.tabOfCategory(categoryId)
    for i, group in ipairs(settings.data.plan) do
        if util.contains(group.categories, categoryId) then
            return i
        end
    end
    return #settings.data.plan
end

-- Moves a category to planned tab `tabIndex`.
function settings.moveCategory(categoryId, tabIndex)
    local plan = settings.data.plan
    if not plan[tabIndex] or settings.tabOfCategory(categoryId) == tabIndex then
        return
    end
    for _, group in ipairs(plan) do
        local i = util.indexOf(group.categories, categoryId)
        if i then table.remove(group.categories, i) end
    end
    table.insert(plan[tabIndex].categories, categoryId)
    settings.data.activePreset = "custom"
    changed("plan")
end

-- Editing the plan's tabs -----------------------------------------------------
-- The last tab is the catch-all: it can be renamed but not moved or deleted,
-- and categories taken out of other tabs go there.

local function custom(key)
    settings.data.activePreset = "custom"
    changed(key)
end

function settings.renameTab(index, label)
    local tab = settings.data.plan[index]
    label = util.trim(label or "")
    if not tab or label == "" or tab.label == label then return end
    tab.label = label:sub(1, 40)
    custom("plan")
end

-- Moves a tab up (delta -1) or down (+1). Returns its new index.
function settings.moveTab(index, delta)
    local plan = settings.data.plan
    local target = index + delta
    if index >= #plan or target < 1 or target >= #plan then return index end
    plan[index], plan[target] = plan[target], plan[index]
    custom("plan")
    return target
end

-- Adds an empty tab just before the catch-all. Returns its index.
function settings.addTab(label)
    local plan = settings.data.plan
    table.insert(plan, #plan, { label = label or "New tab", categories = {}, items = {} })
    custom("plan")
    return #plan - 1
end

-- Deletes a tab; its categories go to the catch-all.
function settings.removeTab(index)
    local plan = settings.data.plan
    if index >= #plan or not plan[index] then return end
    local removed = table.remove(plan, index)
    for _, categoryId in ipairs(removed.categories) do
        table.insert(plan[#plan].categories, categoryId)
    end
    custom("plan")
end

-- Takes a category out of its tab (it goes to the catch-all).
function settings.removeCategory(categoryId)
    settings.moveCategory(categoryId, #settings.data.plan)
end

-- Item rules: items whose name contains `text` always go in tab `index`,
-- whatever their category.
function settings.addItemRule(index, text)
    local tab = settings.data.plan[index]
    text = util.trim(text or ""):lower()
    if not tab or text == "" then return end
    tab.items = tab.items or {}
    if util.contains(tab.items, text) then return end
    table.insert(tab.items, text:sub(1, 40))
    custom("plan")
end

function settings.removeItemRule(index, ruleIndex)
    local tab = settings.data.plan[index]
    if not tab or not tab.items or not tab.items[ruleIndex] then return end
    table.remove(tab.items, ruleIndex)
    custom("plan")
end

-- Deletes everything the plugin has saved, for every character on this
-- device, and goes back to the defaults. Nothing is written again until the
-- player changes a setting.
function settings.deleteAll(characterName)
    local cleared = pcall(function() return PersistentDB:Clear() end)
    if not cleared then
        pcall(function()
            local keys = {}
            PersistentDB:IterateEntries(function(key)
                table.insert(keys, key)
                return true
            end)
            for _, key in ipairs(keys) do PersistentDB:Delete(key) end
        end)
    end
    settings.load(characterName)
    for _, fn in ipairs(listeners) do
        util.try("settings listener", fn, "all")
    end
end

-- Tab locks, by the item ID on the tab's icon.
function settings.isTabLocked(iconItemId)
    return settings.data.lockedTabs[tostring(iconItemId)] == true
end

function settings.setTabLocked(iconItemId, locked)
    if settings.isTabLocked(iconItemId) == (locked and true or false) then
        return
    end
    settings.data.lockedTabs[tostring(iconItemId)] = locked and true or nil
    changed("lockedTabs")
end

return settings
