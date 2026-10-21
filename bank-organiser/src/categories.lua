-- categories.lua
-- The kinds of item the plugin sorts a bank into. Which category an item
-- belongs to is decided in classifier.lua, mostly from the game's own data
-- (Grand Exchange category, combat style, the game's item category); this
-- file only describes the categories.
--
-- The list follows how experienced players lay out a bank: a tab per combat
-- style, consumables together, skilling supplies by skill, and the odds and
-- ends (quest items, clues, cosmetics) out of the way.

local categories = {}

-- id -> { label, colour (0xRRGGBB, for the window) }
categories.byId = {
    teleports = { label = "Teleports", colour = 0x50C878 },
    tools = { label = "Tools & utility", colour = 0xB0B0B0 },
    currency = { label = "Currency, tokens & lamps", colour = 0xFFD700 },
    melee = { label = "Melee gear", colour = 0xE05050 },
    ranged = { label = "Ranged gear", colour = 0x60C060 },
    ammo = { label = "Ammunition", colour = 0xC08040 },
    magic = { label = "Magic gear", colour = 0x6080E0 },
    runes = { label = "Runes", colour = 0x8A5CF6 },
    necromancy = { label = "Necromancy", colour = 0x7050A0 },
    jewellery = { label = "Jewellery", colour = 0x40C0C0 },
    gear = { label = "Other gear", colour = 0xA0A0D0 },
    food = { label = "Food", colour = 0xFF9040 },
    potions = { label = "Potions", colour = 0xE070E0 },
    herblore = { label = "Herblore", colour = 0x60B040 },
    farming = { label = "Farming & seeds", colour = 0x90C060 },
    woodcutting = { label = "Logs & fletching", colour = 0xA0522D },
    mining = { label = "Mining & smithing", colour = 0x9A9A9A },
    fishing = { label = "Fish & cooking", colour = 0x4080C0 },
    hunter = { label = "Hunter", colour = 0x80A050 },
    divination = { label = "Divination", colour = 0x80E0E0 },
    crafting = { label = "Crafting", colour = 0x40A0FF },
    construction = { label = "Construction", colour = 0xC09060 },
    runecrafting = { label = "Runecrafting", colour = 0xB070FF },
    summoning = { label = "Summoning", colour = 0xD0A040 },
    prayer = { label = "Prayer", colour = 0xF0F0C0 },
    invention = { label = "Invention", colour = 0x60A0A0 },
    archaeology = { label = "Archaeology", colour = 0xD2B48C },
    quest = { label = "Quest items", colour = 0xFFFF80 },
    clues = { label = "Clue scrolls", colour = 0xFFB0B0 },
    cosmetic = { label = "Cosmetics & outfits", colour = 0xFF80C0 },
    misc = { label = "Miscellaneous", colour = 0xC0C0C0 },
}

-- Categories in reading order, used when listing them in the window.
categories.DEFAULT_ORDER = {
    "teleports", "tools", "currency", "melee", "ranged", "ammo", "magic", "runes", "necromancy",
    "jewellery", "gear", "food", "potions", "herblore", "farming", "woodcutting", "mining",
    "fishing", "hunter", "divination", "crafting", "construction", "runecrafting", "summoning",
    "prayer", "invention", "archaeology", "quest", "clues", "cosmetic", "misc",
}

-- Families of related categories that often share a tab. In "Tidy my tabs"
-- mode a gear tab can hold any gear, so a ring in your armour tab isn't
-- treated as out of place. Categories not listed are a family of their own.
categories.FAMILIES = {
    combat = { label = "Gear", categories = { "melee", "ranged", "ammo", "magic", "runes", "necromancy",
        "jewellery", "gear" } },
    supplies = { label = "Food & potions", categories = { "food", "potions" } },
    herbs = { label = "Herblore & farming", categories = { "herblore", "farming" } },
    gathering = { label = "Gathering", categories = { "woodcutting", "mining", "fishing", "hunter", "divination" } },
    production = { label = "Crafting & production", categories = { "crafting", "construction", "runecrafting",
        "summoning", "prayer", "invention", "archaeology" } },
    utility = { label = "Teleports & tools", categories = { "teleports", "tools", "currency" } },
}

local familyOf = {}
for familyId, family in pairs(categories.FAMILIES) do
    for _, categoryId in ipairs(family.categories) do familyOf[categoryId] = familyId end
end

-- Returns the family id for a category (the category's own id if it has none).
function categories.family(categoryId)
    return familyOf[categoryId] or categoryId
end

-- Returns the display label for a family id (or a category id).
function categories.familyLabel(familyId)
    local family = categories.FAMILIES[familyId]
    return family and family.label or categories.label(familyId)
end

-- Returns the display label for a category id (falls back to the id itself).
function categories.label(categoryId)
    local def = categories.byId[categoryId]
    return def and def.label or tostring(categoryId)
end

-- Returns the colour for a category id.
function categories.colour(categoryId)
    local def = categories.byId[categoryId]
    return def and def.colour or 0xC0C0C0
end

return categories
