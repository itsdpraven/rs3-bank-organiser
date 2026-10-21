-- classifier.lua
-- Decides which category (see categories.lua) each bank item belongs to.
--
-- Rules are tried in order and the first match wins:
--   1. the player's own rules ("put anything called X in Y")
--   2. things the game marks clearly: clue scrolls, Archaeology, Divination,
--      holiday and cosmetic items, currencies and lamps, Summoning and
--      Runecrafting supplies
--   3. the item's Grand Exchange category - Jagex's own sorting of every
--      tradeable item (with runes split from teleports, and teleport
--      jewellery split from other jewellery)
--   4. equipment by combat style, from the item's combat params
--   5. teleports, then name and right-click option rules for the rest
--   6. untradeable items tied to quests
--   7. anything left: wearable items are outfits, the rest "misc"
--
-- Items reach this file as plain tables built by bank.describe, so it never
-- calls the game API and can be tested against recorded bank data.

local categories = require("src/categories")

local classifier = {}

local function any(text, patterns)
    for _, pattern in ipairs(patterns) do
        if text:find(pattern) then return true end
    end
    return false
end

-- Grand Exchange category -> plugin category. 0 (Miscellaneous) and 48
-- (Pyramid Plunder loot) are left to the later rules.
local GE_CATEGORY = {
    [1] = "ammo", [2] = "ammo", [3] = "ammo",
    [4] = "construction", [5] = "construction",
    [6] = "fishing", [7] = "cosmetic", [8] = "crafting", [9] = "summoning", [10] = "farming",
    [11] = "woodcutting", [12] = "food", [13] = "herblore", [14] = "hunter", [15] = "hunter",
    [16] = "jewellery", [17] = "magic", [18] = "magic",
    [19] = "melee", [20] = "melee", [21] = "melee", [22] = "melee", [23] = "melee", [24] = "melee",
    [25] = "mining", [26] = "potions", [27] = "gear", [28] = "prayer", [29] = "ranged", [30] = "ranged",
    [31] = "runecrafting", [32] = "runes", [33] = "farming", [34] = "summoning", [35] = "tools",
    [36] = "woodcutting", [37] = "tools", [38] = "mining", [39] = "mining", [40] = "woodcutting",
    [41] = "archaeology", [42] = "woodcutting", [43] = "necromancy", [44] = "necromancy",
    [45] = "necromancy", [46] = "divination", [47] = "cosmetic", [49] = "gear", [50] = "currency",
}

local TELEPORT_JEWELLERY = {
    "ring of duelling", "games necklace", "amulet of glory", "skills necklace", "combat bracelet",
    "digsite pendant", "ring of wealth", "ring of slaying", "traveller's necklace", "ring of respawn",
    "ring of kinship", "sixth%-age circuit", "enlightened amulet", "ring of fortune", "luck of the dwarves",
}

local function isRune(it)
    return it.catName:find("RUNE$") ~= nil or any(it.lname, { "^[%a%-]+ runes?$", "^[%a%-]+ rune %(" })
end

local function isTeleport(it)
    return it.ops.teleport or it.ops["break"] or it.wearOps.teleport or it.ops.rub
        or any(it.lname, TELEPORT_JEWELLERY) or any(it.lname, { "teleport", "lodestone" })
end

-- Holiday, Treasure Hunter, circus and other cosmetic items, as the game marks them.
local function isCosmetic(it)
    -- Items Diango can give back (holiday, skilling outfits, cosmetics) and
    -- Treasure Hunter promotions. (CHATHAT only marks a head-slot item.)
    local p = it.params
    if p.DIANGO_FILTER_HOLIDAY ~= nil or p.DIANGO_FILTER_SKILL ~= nil or p.DIANGO_FILTER_COSMETIC ~= nil
        or p.TRH_RELEASE_PROMO ~= nil then
        return true
    end
    if any(it.catName, { "^CRCS_", "^PENG_RAK_HAT", "^TRH%d+_OUTFIT", "^EASTER", "^XMAS", "^HALLOWEEN",
        "^CHRISTMAS", "^WOF_SKILL_SET", "^FOLLOWER_", "^PET_", "OUTFIT" }) then
        return true
    end
    if any(it.configName, { "^EASTER", "^XMAS", "^CHRISTMAS", "^HALLOWEEN", "^HWEEN", "^THANKSGIVING",
        "^CRCS_", "^TRH%d+_", "^WOF%d+_SKILL_", "^VALENTINE", "^SUMMER%d*_", "^BIRTHDAY" }) then
        return true
    end
    -- Untradeable Treasure Hunter wearables (its prizes also include ordinary items).
    return it.params.TRH_EXTENDED_DESC ~= nil and it.wearable and not it.ge
end

-- The Grand Exchange's "Tools and containers" also holds supplies that
-- belong with a skill.
local TOOLS_TO_SKILL = {
    { "farming", { "compost", "plant pot" } },
    { "prayer", { " urn " } },
    { "fishing", { " bait$", "pie dish", "cake tin", "^bowl$", "^jug$", "beer glass", "^empty pot$", "^pot$" } },
    { "crafting", { "^thread$", "papyrus", "^charcoal$", "^white apron$" } },
    { "invention", { "augment" } },
    { "mining", { "ore box" } },
    { "woodcutting", { "wood box" } },
}

-- Equipment by combat style: from the item's combat params, else from the
-- kind of weapon or armour the game says it is, else from its name.
local function gearCategory(it)
    local isGear = it.style ~= nil or it.catName:find("^WEAPON_") or it.catName:find("^ARMOUR_")
    if not isGear then return nil end
    if it.style == "generic" then return "gear" end
    if it.style then return it.style end
    local c = it.catName
    if any(c, { "STAFF", "WAND", "MAGICBOOK", "ORB", "ARMOUR_MAGIC" }) then return "magic" end
    if any(c, { "BOW", "THROWN", "CHINCHOMPA", "ARMOUR_RANGED" }) then return "ranged" end
    if any(c, { "SCYTHE", "LANTERN", "NECRO" }) then return "necromancy" end
    if c:find("^WEAPON_") then return "melee" end
    if c == "ARMOUR_CAPE" then return "gear" end
    if any(it.lname, { "robe", "wizard", "mystic", "hat$", "hood$" }) then return "magic" end
    if any(it.lname, { "d'hide", "coif", "chaps", "vambraces", "leather" }) then return "ranged" end
    if any(it.lname, { "plate", "helm", "chainbody", "shield", "gauntlets" }) then return "melee" end
    return "gear"
end

-- Name and right-click option rules, for items the game data doesn't place.
local NAME_RULES = {
    { "food", function(it) return it.ops.eat or it.params.FOOD_HEAL ~= nil end },
    { "potions", function(it)
        return it.ops.drink or it.params.POTION_TYPE ~= nil or it.params.POTION_STRUCT ~= nil
            or any(it.lname, { "potion", "flask", "brew", "overload", "antifire", "antipoison", " mix ?%(" })
    end },
    { "prayer", function(it)
        return it.ops.bury or it.ops.scatter or it.catName == "URN" or any(it.lname, { "bones$", "ashes$", " urn " })
    end },
    { "herblore", function(it)
        return it.catName == "HERB" or it.catName:find("UNFINISHED_POTION")
            or any(it.lname, { "^grimy ", "^clean ", "%(unf%)", "unfinished", "^vial", "eye of newt", "snape grass",
                "limpwurt", "white berries", "red spiders", "wine of zamorak", "potato cactus" })
    end },
    { "farming", function(it)
        return it.catName:find("^FARMING") or it.configName:find("^POF_")
            or any(it.lname, { " seeds?$", " sapling$", "seedling", "compost", "plant cure", "watering can" })
    end },
    { "woodcutting", function(it)
        return any(it.catName, { "LOGS", "LONGBOW", "SHORTBOW", "WOODCUTTING", "BIRD_NEST", "FEATHER", "BOLT_TIP" })
            or any(it.lname, { "^logs$", " logs$", "%(u%)$", "unstrung", "bow ?string", "arrow shafts",
                "headless arrow", "arrowheads", "^feathers?$", "bird's nest" })
    end },
    { "mining", function(it)
        return any(it.catName, { "^ORE", "METAL_BAR", "^MINING_", "STATUE_ROCK" })
            or any(it.lname, { " ore$", " bar$", "^coal$", "^clay$", "^soft clay", "stone spirit", "geode" })
    end },
    { "crafting", function(it)
        return any(it.catName, { "GEM", "CRAFTING", "DYE" })
            or any(it.lname, { "^uncut ", "sapphire$", "emerald$", "ruby$", "diamond$", "dragonstone$", "onyx$",
                "leather$", " hide$", "dragonhide", "molten glass", "^flax$", " thread$" })
    end },
    { "fishing", function(it)
        return any(it.catName, { "RAW_FISH", "^MEAT", "^FISH$" }) or any(it.lname, { "^raw ", "^burnt ", " bait$" })
    end },
    { "construction", function(it)
        return any(it.catName, { "PLANK", "^NAIL" }) or it.configName:find("^POH_")
            or any(it.lname, { " plank$", "^plank$", " nails$", "limestone brick", "marble block", "bolt of cloth" })
    end },
    { "hunter", function(it)
        return it.catName:find("HUNT") or any(it.lname, { " trap$", "bird snare", "butterfly net", "impling jar",
            " fur$", "kebbit", "noose wand" })
    end },
    { "invention", function(it)
        return it.catName:find("^INVENT") or it.configName:find("^INVENT_")
            or any(it.lname, { "gizmo", "^augmentor", "divine charge", "equipment separator" })
    end },
    { "necromancy", function(it)
        return it.params.NECRO_RITUAL_FOCUS_ITEM ~= nil or any(it.catName, { "GHOSTLY_INK", "NECRO" })
            or any(it.lname, { " ink$", "ectoplasm", "^ritual ", "necroplasm" })
    end },
    { "tools", function(it)
        return any(it.catName, { "BAG", "LOCKPICK", "WATERING_CAN", "COLLECTION_LOG", "TOOL" })
            or any(it.lname, { "pickaxe", "hatchet", "^tinderbox", "^hammer$", "^chisel$", "^knife$", "^saw$",
                "^spade$", "^rake$", "^seed dibber", "secateurs", "^needle$", "fishing net", "fishing rod",
                "harpoon", "lobster pot", "^machete", "^shears$", "^bucket$", "^pestle and mortar", "^trowel",
                "glassblowing pipe", " mould$", " bag$", " bag %(", "lantern", "^rope$", "collection log", "^waterskin" })
    end },
    { "jewellery", function(it)
        return it.wearable and any(it.lname, { " ring$", " ring %(", "^ring of ", "amulet", "necklace", "bracelet",
            "pendant" })
    end },
}

-- Plain-text match (so "(4)" in a player's rule is matched literally).
local function plain(text)
    return (text:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- Returns the category id for an item.
--   item    - table from bank.describe
--   options - { customRules = { { pattern =, category = } } }
function classifier.classify(item, options)
    options = options or {}
    local it = item

    -- 1. The player's own rules always win.
    for _, rule in ipairs(options.customRules or {}) do
        if rule.pattern ~= "" and categories.byId[rule.category] and it.lname:find(plain(rule.pattern:lower())) then
            return rule.category
        end
    end

    -- 2. Things the game marks clearly.
    if it.catName:find("^TRAIL") or it.catName:find("CLUE") or it.configName:find("^TRAIL")
        or any(it.lname, { "clue scroll", "puzzle box", "scroll box", "^casket", "reward casket" }) then
        return "clues"
    end
    if it.catName:find("^ARCH_") or it.configName:find("^ARCH_") or it.ge == 41 or it.catName == "WEAPON_MATTOCK" then
        return "archaeology"
    end
    if it.catName:find("^DIV_") or it.configName:find("^DIV_") or it.ge == 46 then
        return "divination"
    end
    if it.ge == 50 or any(it.catName, { "LAMP", "TOKEN", "^SAFES_", "STATUE_ROCK" })
        or it.configName:find("CURRENCY") or it.configName:find("LAMP$")
        or any(it.lname, { "^coins$", "^tokkul$", " tokens?$", " tokens? %(", " ticket", "reset token", " lamp$" }) then
        return "currency"
    end
    if it.ge == 7 or it.ge == 47 or isCosmetic(it) then
        return "cosmetic"
    end
    if it.ge == 9 or it.ge == 34 or it.catName:find("CHARM") or it.catName:find("SUMMONING")
        or any(it.lname, { "spirit shards?$", " pouch %(", "^summoning " }) then
        return "summoning"
    end
    if it.ge == 31 or it.catName:find("TALISMAN") or it.catName == "RCU_POUCH"
        or any(it.lname, { "talisman$", " tiara$", "essence$", "^small pouch$", "^medium pouch$", "^large pouch$",
            "^giant pouch$", "^massive pouch$" }) then
        return "runecrafting"
    end

    -- 3. Grand Exchange category.
    local fromGe = it.ge and GE_CATEGORY[it.ge]
    if fromGe == "runes" then
        return isRune(it) and "runes" or "teleports"
    elseif fromGe == "jewellery" then
        return isTeleport(it) and "teleports" or "jewellery"
    elseif fromGe == "tools" then
        for _, rule in ipairs(TOOLS_TO_SKILL) do
            if any(it.lname, rule[2]) then return rule[1] end
        end
        return "tools"
    elseif fromGe then
        return fromGe
    end

    -- 4. Equipment, by combat style.
    if isRune(it) then return "runes" end
    if isTeleport(it) and not it.style then return "teleports" end
    local gear = gearCategory(it)
    if gear then return gear end

    -- 5. Name and right-click options.
    for _, rule in ipairs(NAME_RULES) do
        if rule[2](it) then return rule[1] end
    end

    -- 6. Untradeable items linked to quests (or kept on death, as quest items
    --    are), and untradeable items nothing else recognises: what's left of
    --    those is almost always quest or minigame leftovers (keys, notes, finds).
    if not it.tradeable and (it.questCount > 0 or it.params.PROTECT_ON_DEATH ~= nil
        or (not it.wearable and not it.ge)) then
        return "quest"
    end

    -- 7. What's left: outfits if wearable, otherwise miscellaneous.
    if it.wearable and not it.tradeable then return "cosmetic" end
    return "misc"
end

-- Splits an item name into a "base" name and a variant number so that related
-- items sort next to each other, e.g.
--   "Super attack (3)"  -> "super attack", 3
--   "Ring of duelling (8)" -> "ring of duelling", 8
--   "Lobster" -> "lobster", nil
function classifier.variantKey(lname)
    local base, number = lname:match("^(.-)%s*%((%d+)%)$")
    if base then
        return base, tonumber(number)
    end
    return lname, nil
end

return classifier
