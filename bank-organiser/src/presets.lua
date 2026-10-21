-- presets.lua
-- Plan styles: ready-made layouts saying which categories share a tab, in
-- tab order. The player picks one under "Edit plan" and can then move any
-- category to a different tab.
--
-- "Recommended" follows how experienced players lay out a bank: utility
-- first, a tab per combat style, consumables, then skilling supplies by
-- skill, with quest items, clues and cosmetics at the end. It uses 14 tabs,
-- the most the game allows; tabs that would be small fold into a related
-- tab (same `family`) or, failing that, into the last tab.
--
-- The last tab of every style is the catch-all: categories not listed
-- anywhere end up there.

local presets = {}

presets.BUILT_IN = {
    {
        id = "recommended",
        name = "Recommended",
        description = "14 tabs: utility, a tab per combat style, food and potions, skills, then quests and cosmetics.",
        groups = {
            { label = "Teleports & tools", family = "utility", categories = { "teleports", "tools", "currency" } },
            { label = "Melee", family = "combat", categories = { "melee" } },
            { label = "Ranged", family = "combat", categories = { "ranged", "ammo" } },
            { label = "Magic", family = "combat", categories = { "magic", "runes" } },
            { label = "Necromancy", family = "combat", categories = { "necromancy" } },
            { label = "Jewellery & other gear", family = "combat", categories = { "jewellery", "gear" } },
            { label = "Food & potions", family = "supplies", categories = { "food", "potions" } },
            { label = "Herblore & farming", family = "skilling", categories = { "herblore", "farming" } },
            { label = "Gathering", family = "skilling", categories = { "woodcutting", "mining", "fishing", "hunter",
                "divination" } },
            { label = "Crafting & production", family = "skilling", categories = { "crafting", "construction",
                "runecrafting", "summoning", "prayer", "invention" } },
            { label = "Archaeology", family = "skilling", categories = { "archaeology" } },
            { label = "Quest items & clues", family = "other", categories = { "quest", "clues" } },
            { label = "Cosmetics & outfits", family = "other", categories = { "cosmetic" } },
            { label = "Everything else", categories = { "misc" } },
        },
    },
    {
        id = "compact",
        name = "Compact",
        description = "8 tabs: utility, combat gear, magic and runes, consumables, three skilling tabs and the rest.",
        groups = {
            { label = "Teleports & tools", family = "utility", categories = { "teleports", "tools", "currency" } },
            { label = "Combat gear", family = "combat", categories = { "melee", "ranged", "ammo", "necromancy",
                "jewellery", "gear" } },
            { label = "Magic & runes", family = "combat", categories = { "magic", "runes" } },
            { label = "Food & potions", family = "supplies", categories = { "food", "potions" } },
            { label = "Herblore & farming", family = "skilling", categories = { "herblore", "farming" } },
            { label = "Gathering", family = "skilling", categories = { "woodcutting", "mining", "fishing", "hunter",
                "divination" } },
            { label = "Crafting & production", family = "skilling", categories = { "crafting", "construction",
                "runecrafting", "summoning", "prayer", "invention", "archaeology" } },
            { label = "Everything else", categories = { "quest", "clues", "cosmetic", "misc" } },
        },
    },
    {
        id = "skiller",
        name = "Skiller",
        description = "A tab for each group of skills, with all combat items sharing one tab.",
        groups = {
            { label = "Tools & teleports", family = "utility", categories = { "tools", "teleports", "currency" } },
            { label = "Logs & fletching", family = "skilling", categories = { "woodcutting" } },
            { label = "Mining & smithing", family = "skilling", categories = { "mining" } },
            { label = "Fish & cooking", family = "skilling", categories = { "fishing", "food" } },
            { label = "Herblore & farming", family = "skilling", categories = { "herblore", "farming", "potions" } },
            { label = "Crafting & construction", family = "skilling", categories = { "crafting", "construction" } },
            { label = "Runecrafting & summoning", family = "skilling", categories = { "runecrafting", "summoning",
                "prayer", "divination", "hunter", "invention" } },
            { label = "Archaeology", family = "skilling", categories = { "archaeology" } },
            { label = "Combat", family = "combat", categories = { "melee", "ranged", "ammo", "magic", "runes",
                "necromancy", "jewellery", "gear" } },
            { label = "Everything else", categories = { "quest", "clues", "cosmetic", "misc" } },
        },
    },
    {
        id = "simple",
        name = "Simple",
        description = "Just four tabs: gear, consumables, skilling and everything else.",
        groups = {
            { label = "Gear", family = "combat", categories = { "melee", "ranged", "ammo", "magic", "necromancy",
                "jewellery", "gear", "tools", "teleports" } },
            { label = "Consumables", family = "supplies", categories = { "food", "potions", "runes" } },
            { label = "Skilling", family = "skilling", categories = { "herblore", "farming", "woodcutting", "mining",
                "fishing", "hunter", "divination", "crafting", "construction", "runecrafting", "summoning",
                "prayer", "invention", "archaeology" } },
            { label = "Everything else", categories = { "currency", "quest", "clues", "cosmetic", "misc" } },
        },
    },
}

-- Returns a built-in plan style by id, or nil.
function presets.find(presetId)
    for _, preset in ipairs(presets.BUILT_IN) do
        if preset.id == presetId then
            return preset
        end
    end
    return nil
end

-- Choices for a style picker: every style, plus "Custom" once the player has
-- moved categories around (so the picker doesn't pretend it's a preset).
function presets.choices(activeId)
    local list = {}
    if not presets.find(activeId) then
        table.insert(list, { "custom", "Custom" })
    end
    for _, preset in ipairs(presets.BUILT_IN) do
        table.insert(list, { preset.id, preset.name })
    end
    return list
end

return presets
