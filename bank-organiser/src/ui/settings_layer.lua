-- settings_layer.lua
-- The small settings screen shown from the Plugin Hub's "Manage" tab (the cog
-- icon): mode, plan style and per-character settings. Everything else is
-- under "Edit plan" in the plugin window.

local widgets = require("src/ui/widgets")
local presets = require("src/presets")

local settingsLayer = {}

function settingsLayer.build(root, ctx)
    local settings = ctx.settings
    widgets.place(widgets.text(root, "Bank Organiser", { colour = widgets.COLOUR_HEADING, heading = true }), 0, 0, 360, widgets.LINE + 4)

    widgets.place(widgets.text(root, "Mode:"), 0, 30, 110, widgets.ROW)
    widgets.place(widgets.picker(root, settings.byKey.mode.choices, settings.get("mode"),
        function(value) settings.set("mode", value) end), 110, 30, 240, widgets.ROW)

    widgets.place(widgets.text(root, "Plan style:"), 0, 60, 110, widgets.ROW)
    local active = settings.data.activePreset
    widgets.place(widgets.picker(root, presets.choices(active), active, function(presetId)
        settings.applyPreset(presetId)
    end), 110, 60, 240, widgets.ROW)

    widgets.place(widgets.text(root, "Per character:"), 0, 90, 110, widgets.ROW)
    widgets.place(widgets.picker(root, { { true, "Yes" }, { false, "No" } }, settings.get("perCharacter"),
        function(value) settings.set("perCharacter", value) end), 110, 90, 240, widgets.ROW)

    local hint = widgets.text(root, "Plan style is used by Organise my bank. Open your bank, then the plugin window "
        .. "from its ribbon icon.", { colour = widgets.COLOUR_MUTED, lines = 2 })
    widgets.place(hint, 0, 122, 350, 2 * widgets.LINE)
end

return settingsLayer
