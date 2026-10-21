-- Bank Organiser Test Kit (development only - do not submit)
-- Fills your developer-world bank with a deliberately messy mix of items so
-- Bank Organiser has something to sort, then opens the bank.
--
-- Uses developer cheat commands, which only work on the plugin developer
-- world. Enable with:  pon bank-organiser-testkit

-- { config name, amount }. Names are checked against the game's item configs
-- first, so any that don't exist are skipped and listed in the console.
local ITEMS = {
    { "coins", 5000000 }, { "shark", 200 }, { "lobster", 150 }, { "raw_lobster", 80 },
    { "burnt_lobster", 6 }, { "yew_logs", 500 }, { "logs", 120 }, { "magic_logs", 40 },
    { "nature_rune", 3000 }, { "air_rune", 10000 }, { "fire_rune", 8000 }, { "law_rune", 900 },
    { "rune_platebody", 1 }, { "rune_platelegs", 1 }, { "rune_full_helm", 1 }, { "rune_scimitar", 1 },
    { "dragon_pickaxe", 1 }, { "rune_pickaxe", 1 }, { "rune_hatchet", 1 }, { "tinderbox", 1 },
    { "iron_ore", 300 }, { "coal", 600 }, { "steel_bar", 250 }, { "gold_bar", 60 },
    { "uncut_sapphire", 30 }, { "uncut_diamond", 12 }, { "bones", 40 }, { "dragon_bones", 90 },
    { "vial_water", 100 }, { "eye_of_newt", 200 }, { "potato_seed", 50 }, { "bowstring", 300 },
    { "pure_essence", 2000 }, { "plank", 150 }, { "feather", 1000 }, { "bronze_arrow", 500 },
    { "amulet_of_glory", 1 }, { "ring_of_duelling", 2 }, { "varrock_teleport", 40 },
}

local given, missing = 0, {}
for _, entry in ipairs(ITEMS) do
    local name, amount = entry[1], entry[2]
    local ok, obj = pcall(function() return config.Obj[name:upper()] end)
    if ok and obj then
        ExecuteConsoleCommand("!give " .. name .. " " .. amount .. " bank")
        given = given + 1
    else
        table.insert(missing, name)
    end
end

log("Gave " .. given .. " item types to the bank.")
if #missing > 0 then
    log("Not found (skipped): " .. table.concat(missing, ", "))
    log("Tip: 'pan Obj' copies every item config name to your clipboard.")
end
ExecuteConsoleCommand("!bank")
log("Bank opened. Now enable the organiser:  pon bank-organiser")
