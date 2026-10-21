-- sorter.lua
-- The order items should be in inside a tab, the way tidy banks are laid out:
--   gear      - by level, each set together (smithing upgrades as their own
--               set), in slot order (weapon, off-hand, head, body, legs,
--               hands, feet, shield, cape, neck, ring)
--   runes     - elemental, combination, catalytic, then Necromancy runes
--   potions   - by type (every dose of a potion together), most doses first
--   food      - by how much it heals
--   herblore  - grimy herbs, clean herbs, unfinished potions, then the rest
--   skilling  - by kind (logs, then nests, unstrung bows, shafts...; ores,
--               then stone spirits, bars...), then by the level needed to make
--               or use it, then cheapest first
--   quest     - by quest
--   cosmetic  - by outfit
-- Within a tab, categories come in the order the plan lists them.
--
-- Pure Lua: works on the item tables from bank.describe.

local classifier = require("src/classifier")
local categories = require("src/categories")

local sorter = {}

local RUNES = { "air", "water", "earth", "fire", "dust", "lava", "mist", "mud", "smoke", "steam", "mind", "body",
    "cosmic", "chaos", "astral", "nature", "law", "death", "blood", "soul", "armadyl", "time", "spirit", "bone",
    "flesh", "miasma" }
local runeRank = {}
for i, name in ipairs(RUNES) do runeRank[name] = i end

local METALS = { "bronze", "iron", "black", "steel", "white", "mithril", "adamant", "rune", "orikalkum", "dragon",
    "necronium", "bane", "elder" }
local metalRank = {}
for i, name in ipairs(METALS) do metalRank[name] = i end

local CLUE_TIERS = { easy = 1, medium = 2, hard = 3, elite = 4, master = 5 }

-- The order of the kinds of item within a skilling category, matched
-- against the game's item category or the item's name (first match wins).
local SUBGROUPS = {
    woodcutting = { "LOGS", "logs", "WOOD_SPIRIT", "NEST", "nest", "UNSTRUNG", "%(u%)", "SHAFT", "shaft",
        "ARROWHEAD", "arrowhead", "BOLT_TIP", "tip", "FEATHER", "feather", "STRING", "string" },
    mining = { "^ORE", " ore$", "^coal$", "STONE_SPIRIT", "METAL_BAR", " bar$", "SALVAGE", "GEODE", "granite",
        "sandstone", "limestone", "clay" },
    fishing = { "RAW_FISH", "^raw ", "MEAT", "FISH", "bait" },
    crafting = { "UNCUT", "uncut ", "CUT_GEM", "HIDE", "hide$", "LEATHER", "leather", "flax", "wool", "glass",
        "THREAD", "thread" },
    farming = { "SEED", "seed", "SAPLING", "sapling", "compost", "pot" },
    construction = { "PLANK", "plank", "NAIL", "nails" },
    divination = { "MEMORY", "memory", "ENERGY", "energy" },
}

local function subgroup(it, category)
    local list = SUBGROUPS[category]
    if not list then return 1 end
    for i, pattern in ipairs(list) do
        if it.catName:find(pattern) or it.lname:find(pattern) then return i end
    end
    return #list + 1
end

local GEAR = { melee = true, ranged = true, magic = true, necromancy = true, gear = true, jewellery = true }

-- Where a piece of gear goes in a set.
-- From the game's item category where it has one, else the item's params,
-- else words in its name (a third of wearables have no category).
local SLOT_WORDS = {
    { 3, { "helm", " hat$", "^hat", "hood", "coif", "mask", "crown", "tiara", "headwear", "sallet" } },
    { 4, { "body", "torso", "chest", " top$", "shirt", "jacket", "tunic", "garb", "gown", "robe$" } },
    { 5, { "legs", "skirt", "chaps", "trousers", "bottom", "tassets", "legwear", "cuisse" } },
    { 6, { "gloves", "gauntlets", "vambraces", "bracers", "handwear", "hands$" } },
    { 7, { "boots", "shoes", "footwear", "sandals", "feet$" } },
    { 8, { "shield", "defender", "ward", "kite" } },
    { 9, { "cape", "cloak", "drape" } },
    { 10, { "amulet", "necklace", "pendant", "charm$" } },
    { 11, { " ring$", "^ring of", " ring %(" } },
}

local function slotRank(it)
    local c, n = it.catName, it.lname
    if n:find("off%-hand") or n:find("off hand") then return 2 end
    if c:find("^WEAPON_") or it.params.WEAPON_CATEGORY ~= nil then return 1 end
    if c:find("HELM") or c:find("HEAD") or it.params.CHATHAT ~= nil then return 3 end
    if c:find("BODY") or c:find("TORSO") then return 4 end
    if c:find("LEGS") then return 5 end
    if c:find("HANDS") or c:find("GLOVES") then return 6 end
    if c:find("FEET") or c:find("BOOTS") then return 7 end
    if c:find("SHIELD") or it.params.COMBATV2_ITEM_IS_SHIELD ~= nil then return 8 end
    if c:find("CAPE") then return 9 end
    for _, entry in ipairs(SLOT_WORDS) do
        for _, word in ipairs(entry[2]) do
            if n:find(word) then return entry[1] end
        end
    end
    return 12
end

local function num(value)
    return tonumber(tostring(value or "")) or 0
end

-- A list of values to sort by (compared in order) for an item of `category`.
--   group - the name items of the same family (every dose or charge of one
--           potion, food or piece of jewellery) sort under
local function categoryKey(it, category, group)
    local base, variant = classifier.variantKey(it.lname)
    local dose = -(variant or 0) -- bigger doses and charges first
    local firstWord = it.lname:match("^(%S+)") or ""
    group = group or base

    if GEAR[category] then
        -- Gear without a tier (mostly quest rewards) goes after the tiered sets.
        local tier = it.tier > 0 and it.tier or (metalRank[firstWord] and metalRank[firstWord] * 10) or 999
        return { tier, firstWord, it.upgrade, slotRank(it), base, dose }
    elseif category == "runes" then
        return { runeRank[firstWord] or 99, base, dose }
    elseif category == "potions" then
        return { group, base, dose }
    elseif category == "food" then
        return { num(it.params.FOOD_HEAL), it.cost, group, base, dose }
    elseif category == "herblore" then
        local group = 4
        if it.lname:find("^grimy") or it.catName == "UNIDENTIFIED" then group = 1
        elseif it.catName == "HERB" or it.lname:find("^clean") then group = 2
        elseif it.lname:find("unf") then group = 3 end
        return { group, it.tier, it.cost, base, dose }
    elseif category == "clues" then
        local tier = 0
        for word, rank in pairs(CLUE_TIERS) do
            if it.lname:find(word) then tier = rank end
        end
        return { tier, base, dose }
    elseif category == "quest" then
        return { it.questName or "~", base, dose }
    elseif category == "cosmetic" then
        return { it.catName, it.configName, base, dose }
    end
    -- Skilling supplies and everything else: by kind (see SUBGROUPS), then
    -- the game's item category, then the level needed to make or use it,
    -- then cheapest first.
    return { subgroup(it, category), it.catName, it.tier, it.cost, group, base, dose }
end

-- Compares two key lists. Numbers sort before text at the same position.
local function lessThan(a, b)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i], b[i]
        if x ~= y then
            if x == nil then return true end
            if y == nil then return false end
            local tx, ty = type(x), type(y)
            if tx ~= ty then return tx == "number" end
            return x < y
        end
    end
    return false
end

-- Returns `list` (items in one tab) sorted into the order they should be in.
--   categoryOf     - function(item) -> category id
--   categoryOrder  - category ids in the order the tab should hold them
--                    (defaults to categories.DEFAULT_ORDER)
--   icon           - an item to put first, so it's the tab's icon (optional)
function sorter.sorted(list, categoryOf, categoryOrder, icon)
    local out = sorter.sortedBody(list, categoryOf, categoryOrder)
    for i, it in ipairs(out) do
        if it == icon then
            table.remove(out, i)
            table.insert(out, 1, icon)
            break
        end
    end
    return out
end

function sorter.sortedBody(list, categoryOf, categoryOrder)
    local rank = {}
    for i, id in ipairs(categoryOrder or categories.DEFAULT_ORDER) do rank[id] = i end
    -- Each family sorts under the alphabetically first name in it.
    local familyName = {}
    for _, it in ipairs(list) do
        if it.family then
            local base = classifier.variantKey(it.lname)
            if not familyName[it.family] or base < familyName[it.family] then familyName[it.family] = base end
        end
    end
    local keyed = {}
    for _, it in ipairs(list) do
        local category = categoryOf(it)
        local key = { rank[category] or 999, category }
        for _, v in ipairs(categoryKey(it, category, it.family and familyName[it.family])) do
            table.insert(key, v)
        end
        table.insert(key, it.id)
        table.insert(keyed, { item = it, key = key })
    end
    table.sort(keyed, function(a, b) return lessThan(a.key, b.key) end)
    local out = {}
    for i, k in ipairs(keyed) do out[i] = k.item end
    return out
end

-- How typical an item is of its category, for picking icons (lower is
-- better): weapons, then other wearables, for gear; clean herbs for
-- Herblore, and each skill's main kind (logs, ores, raw fish...) first.
local function iconPreference(it, category)
    if GEAR[category] then
        if slotRank(it) == 1 then return 0 end
        return it.wearable and 1 or 2
    end
    if category == "cosmetic" then
        -- Items the game marks as outfits or holiday items, a hat or top first.
        local p = it.params
        local marked = p.DIANGO_FILTER_HOLIDAY or p.DIANGO_FILTER_SKILL or p.DIANGO_FILTER_COSMETIC
            or p.TRH_RELEASE_PROMO or it.ge == 7 or it.catName:find("OUTFIT")
        local slot = slotRank(it)
        return (marked and 0 or 2) + ((slot == 3 or slot == 4) and 0 or 1)
    end
    if category == "clues" then
        if it.lname:find("clue scroll") then return 0 end
        if it.lname:find("casket") or it.lname:find("puzzle") then return 1 end
        return 2
    end
    if category == "herblore" then
        if it.catName == "HERB" or it.lname:find("^clean") then return 0 end
        if it.lname:find("unf") then return 1 end
        if it.lname:find("^grimy") or it.catName == "UNIDENTIFIED" then return 2 end
        return 3
    end
    return subgroup(it, category)
end

-- How clearly a category's items say what a tab holds when shown as its
-- icon (lower is clearer). A mixed tab takes its icon from its clearest
-- category: a clue scroll for "Quest items & clues", a staff rather than a
-- rune for "Magic", a teleport rather than a tool for "Teleports & tools".
local ICON_CLARITY = {
    melee = 1, ranged = 1, magic = 1, necromancy = 1, teleports = 1, food = 1, herblore = 1, woodcutting = 1,
    mining = 1, fishing = 1, crafting = 1, archaeology = 1, clues = 1, cosmetic = 1,
    runes = 2, jewellery = 2, potions = 2, farming = 2, hunter = 2, divination = 2, construction = 2,
    runecrafting = 2, summoning = 2, prayer = 2, tools = 2,
    ammo = 3, gear = 3, invention = 3, quest = 3, currency = 3,
    misc = 5,
}

-- The item that best shows what a tab holds, to use as its icon (a tab's
-- icon is its first item), picked afresh from whatever the player's bank
-- has: from the tab's clearest category (ties go to the plan's order), a
-- real stack rather than a placeholder, the most typical kind of item (see
-- iconPreference), then the highest level, best food and most valuable.
-- Returns nil for an empty list.
function sorter.iconFor(list, categoryOf, categoryOrder)
    local rank = {}
    for i, id in ipairs(categoryOrder or categories.DEFAULT_ORDER) do rank[id] = i end
    local best, bestKey = nil, nil
    for _, it in ipairs(list) do
        local category = categoryOf(it)
        local key = { ICON_CLARITY[category] or 4, rank[category] or 999, it.placeholder and 1 or 0,
            iconPreference(it, category), -it.tier, -num(it.params.FOOD_HEAL), -it.cost, it.id }
        if not best or lessThan(key, bestKey) then best, bestKey = it, key end
    end
    return best
end

-- How many swaps it takes to turn `current` into `desired` (same items):
-- the number of items minus the number of cycles in the rearrangement.
function sorter.swapsNeeded(current, desired)
    local target = {}
    for i, it in ipairs(desired) do target[it] = i end
    local seen, cycles = {}, 0
    for i = 1, #current do
        if not seen[i] then
            cycles = cycles + 1
            local j = i
            while not seen[j] do
                seen[j] = true
                j = target[current[j]]
            end
        end
    end
    return #current - cycles
end

return sorter
