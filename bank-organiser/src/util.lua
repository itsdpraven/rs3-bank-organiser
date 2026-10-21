-- util.lua
-- Small helper functions shared by the rest of the plugin.
-- Nothing in here touches the game API except the "safe lookup" helpers,
-- which exist so that a renamed font or stylesheet never crashes the plugin.

local util = {}

-- Returns a deep copy of a table, so presets and defaults are never edited in place.
function util.deepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for k, v in pairs(value) do
        copy[k] = util.deepCopy(v)
    end
    return copy
end

-- Keeps a number between a minimum and a maximum.
function util.clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

-- Removes spaces from both ends of a string.
function util.trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Returns true if the list contains the value.
function util.contains(list, value)
    for _, v in ipairs(list) do
        if v == value then
            return true
        end
    end
    return false
end

-- Returns the position of a value in a list, or nil.
function util.indexOf(list, value)
    for i, v in ipairs(list) do
        if v == value then
            return i
        end
    end
    return nil
end

-- Converts a 0xRRGGBB colour into a Vector4 with the given alpha (0..1).
-- Vector4 is provided by the game API.
function util.rgbToVector(rgb, alpha)
    local r = ((rgb >> 16) & 0xFF) / 255
    local g = ((rgb >> 8) & 0xFF) / 255
    local b = (rgb & 0xFF) / 255
    return Vector4.new(r, g, b, alpha or 1.0)
end

-- Looks up a name in one of the game's id tables (for example id.Font) without
-- crashing if the name does not exist. Tries each name in order and returns the
-- first one found, or the fallback.
function util.safeId(idTable, names, fallback)
    for _, name in ipairs(names) do
        local ok, value = pcall(function() return idTable[name] end)
        -- Missing names can come back as nil or as a negative "invalid" ID.
        if ok and value ~= nil and not (type(value) == "number" and value < 0) then
            return value
        end
    end
    return fallback
end

-- Calls a function and logs (instead of throwing) any error, returning success.
-- Used around UI callbacks so one bad click can't break the whole plugin.
-- Each distinct error is logged once, so a fault in something that runs
-- every tick doesn't flood the console.
local loggedErrors, loggedCount = {}, 0
function util.try(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        local message = "Error in " .. label .. ": " .. tostring(err)
        if not loggedErrors[message] and loggedCount < 50 then
            loggedErrors[message] = true
            loggedCount = loggedCount + 1
            log(message)
        end
    end
    return ok
end

return util
