-- Options: the TinyTweaks page in the game's AddOns settings and the minimap button that opens it.

local wow = require("support.wow")
local A = require("support.assert")

local RECORDER = "!TinyTweaksDev"

local function setup(opts)
	opts = opts or {}
	local world = wow.new({ saved = opts.saved })
	if opts.recorder then
		world:installAddon(RECORDER, opts.recorder)
	end
	world:loadAddon()
	return world
end

local function reload(world, opts)
	opts = opts or {}
	opts.saved = { TinyTweaksDB = wow.deepcopy(world:saved()) }
	return setup(opts)
end

local function page(world)
	return world:openSettings("TinyTweaks")
end

-- Page and button ------------------------------------------------------------------------------

test("given_the_addon_when_loaded_then_a_tinytweaks_page_is_listed_under_addons_settings", function()
	-- Given / When
	local world = setup()
	-- Then
	A.eq(#world.addonCategories, 1)
	A.eq(world.addonCategories[1]:GetName(), "TinyTweaks")
	A.truthy(world:findText(page(world), "TinyTweaks"))
	A.truthy(world:findText(page(world), "Version " .. wow.tocField("Version")))
end)

test("given_the_minimap_button_when_clicked_then_settings_open_on_the_tinytweaks_page", function()
	-- Given
	local world = setup()
	local button = world:minimapButton()
	-- When
	world:click(button)
	-- Then: opened through Settings.OpenToCategory (the emulator flags SettingsPanel methods)
	A.eq(world.openedCategory, world.addonCategories[1]:GetID())
	A.truthy(world.settingsPanel:IsShown())
	A.eq(world.currentCategory.name, "TinyTweaks")
	A.truthy(world.currentCategory.frame:IsVisible())
end)

test("given_combat_when_the_minimap_button_is_clicked_then_settings_stay_closed_and_the_player_is_told_why", function()
	-- Given
	local world = setup()
	world:setCombat(true)
	-- When
	world:click(world:minimapButton())
	-- Then: no blocked action (the emulator would record one)
	A.falsy(world.settingsPanel:IsShown())
	A.eq(world.uiErrors, { "You can't do that while in combat" })
end)

test("given_the_minimap_button_when_hovered_then_the_tooltip_says_what_it_does", function()
	-- Given
	local world = setup()
	-- When
	local lines = world:hover(world:minimapButton())
	-- Then
	A.eq(lines, { "TinyTweaks", "Click to open settings. Drag to move." })
end)

test("given_no_saved_position_when_loaded_then_the_button_sits_on_the_minimap_edge_at_the_bottom_left", function()
	-- Given / When
	local world = setup()
	-- Then
	local button = world:minimapButton()
	A.truthy(button:IsVisible())
	local angle, distance = world:minimapAngle(button)
	A.near(angle, 225, 0.01)
	A.near(distance, 80, 0.01)
	A.isNil(world:saved().minimap)
end)

test("given_the_button_when_dragged_around_the_minimap_then_it_follows_and_keeps_its_place_after_reload", function()
	-- Given
	local world = setup()
	-- When
	world:dragAroundMinimap(world:minimapButton(), 30)
	-- Then
	A.near((world:minimapAngle(world:minimapButton())), 30, 0.01)
	A.eq(world:saved().minimap, { angle = 30 })
	local after = reload(world)
	local angle, distance = after:minimapAngle(after:minimapButton())
	A.near(angle, 30, 0.01)
	A.near(distance, 80, 0.01)
end)

test("given_a_scaled_minimap_when_the_button_is_dragged_then_the_angle_follows_the_cursor", function()
	-- Given
	local world = setup()
	world:state(world.minimap).scale = 1.5
	-- When
	world:dragAroundMinimap(world:minimapButton(), 120)
	-- Then
	A.near((world:minimapAngle(world:minimapButton())), 120, 0.01)
end)

test("given_the_button_when_dropped_back_at_its_default_place_then_nothing_is_stored", function()
	-- Given
	local world = setup()
	world:dragAroundMinimap(world:minimapButton(), 30)
	-- When
	world:dragAroundMinimap(world:minimapButton(), 225)
	-- Then
	A.isNil(world:saved().minimap)
	A.near((world:minimapAngle(world:minimapButton())), 225, 0.01)
end)

test("given_show_minimap_button_when_unchecked_then_the_button_hides_and_stays_hidden_after_reload", function()
	-- Given
	local world = setup()
	local show = world:findCheckbox(page(world), "Show minimap button")
	A.truthy(show:GetChecked())
	-- When
	world:click(show)
	-- Then
	A.falsy(world:minimapButton():IsShown())
	A.eq(world:saved().minimap, { hide = true })
	local after = reload(world)
	A.falsy(after:minimapButton():IsShown())
	A.falsy(after:findCheckbox(page(after), "Show minimap button"):GetChecked())
end)

test("given_a_hidden_button_when_show_minimap_button_is_checked_then_it_returns_and_nothing_is_stored", function()
	-- Given
	local world = setup({ saved = { TinyTweaksDB = { layouts = {}, minimap = { hide = true } } } })
	-- When
	world:click(world:findCheckbox(page(world), "Show minimap button"))
	-- Then
	A.truthy(world:minimapButton():IsShown())
	A.isNil(world:saved().minimap)
end)

-- Debug ----------------------------------------------------------------------------------------

local function debugBox(world)
	return world:findCheckbox(page(world), "Record debug sessions")
end

local function reloadPrompt(world)
	local p = page(world)
	local text = world:findText(p, "Reload to apply.")
	local button = world:findButton(p, "Reload UI")
	return text and text:IsVisible() and button and button:IsVisible() and button or nil
end

test("given_the_recorder_not_installed_when_the_page_opens_then_it_has_no_debug_section", function()
	-- Given / When
	local world = setup()
	-- Then
	A.isNil(debugBox(world))
	A.isNil(world:findText(page(world), "Debug"))
end)

test("given_the_recorder_running_when_the_page_opens_then_debug_recording_is_checked_with_no_reload_prompt", function()
	-- Given / When
	local world = setup({ recorder = { enabled = true, loaded = true } })
	-- Then
	A.truthy(debugBox(world):IsVisible())
	A.truthy(debugBox(world):GetChecked())
	A.isNil(reloadPrompt(world))
end)

test("given_the_recorder_running_when_debug_recording_is_unchecked_then_it_is_disabled_taint_logging_stops_and_a_reload_is_offered", function()
	-- Given
	local world = setup({ recorder = { enabled = true, loaded = true } })
	world.cvars.taintLog = "1"
	-- When
	world:click(debugBox(world))
	-- Then
	A.falsy(world.addons[RECORDER].enabled)
	A.eq(world.cvars.taintLog, "0")
	A.truthy(reloadPrompt(world))
end)

test("given_the_recorder_disabled_when_debug_recording_is_checked_then_it_is_enabled_and_a_reload_is_offered", function()
	-- Given
	local world = setup({ recorder = { enabled = false } })
	A.falsy(debugBox(world):GetChecked())
	-- When
	world:click(debugBox(world))
	-- Then
	A.truthy(world.addons[RECORDER].enabled)
	A.truthy(reloadPrompt(world))
	-- And unchecking returns to what is loaded, so nothing needs a reload
	world:click(debugBox(world))
	A.isNil(reloadPrompt(world))
end)

test("given_a_pending_debug_change_when_reload_ui_is_clicked_then_the_ui_reloads", function()
	-- Given
	local world = setup({ recorder = { enabled = false } })
	world:click(debugBox(world))
	-- When
	world:click(reloadPrompt(world))
	-- Then
	A.eq(world.reloads, 1)
end)

test("given_debug_recording_unchecked_when_the_addon_list_closes_without_okay_then_the_change_stays", function()
	-- Given
	local world = setup({ recorder = { enabled = true, loaded = true } })
	world:click(debugBox(world))
	-- When
	world:closeAddonList(false)
	-- Then
	A.falsy(world.addons[RECORDER].enabled)
end)

test("given_the_recorder_toggled_in_the_addon_list_when_the_page_is_opened_again_then_it_shows_the_new_state", function()
	-- Given
	local world = setup({ recorder = { enabled = true, loaded = true } })
	page(world)
	world:closeSettings()
	world.addons[RECORDER].enabled = false
	-- When
	world:click(world:minimapButton())
	-- Then
	A.falsy(debugBox(world):GetChecked())
	A.truthy(reloadPrompt(world))
end)

-- Missing capabilities ------------------------------------------------------------------------

test("given_a_client_without_the_settings_api_when_loaded_then_there_is_no_page_or_button_and_no_error", function()
	-- Given
	local world = wow.new()
	rawset(world.G, "Settings", nil)
	-- When
	world:loadAddon()
	-- Then
	A.isNil(world:minimapButton())
	A.eq(#world.addonCategories, 0)
end)
