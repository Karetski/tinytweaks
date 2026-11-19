-- Edit Mode fine values: typing exact size/opacity values into supported Edit Mode sliders.

local wow = require("support.wow")
local A = require("support.assert")

local function setup(spec, opts)
	local world = wow.new(opts)
	world:loadAddon()
	local frame = world:addSystemFrame(spec or wow.frames.target())
	world:selectSystem(frame)
	return world, frame
end

local function overrides(world, frame)
	local layout = world:saved().layouts["1:Main"]
	return layout and layout.overrides and layout.overrides[frame.system .. ":" .. tostring(frame.systemIndex or 0)]
end

test("given_a_target_frame_when_selected_then_size_gets_a_box_and_width_does_not", function()
	-- Given / When
	local world = setup()
	-- Then
	A.truthy(world:fineTuneBox("FrameSize"), "size box")
	A.isNil(world:fineTuneBox("FrameWidth"), "width box")
end)

test("given_raid_style_party_frames_when_selected_then_opacity_gets_a_box", function()
	-- Given / When
	local world = setup(wow.frames.party())
	-- Then
	A.truthy(world:fineTuneBox("Opacity"))
end)

test("given_a_box_when_shown_then_it_shows_the_slider_value_and_hides_blizzards_label", function()
	-- Given / When
	local world = setup()
	-- Then
	A.eq(world:fineTuneBox("FrameSize"):GetText(), "100")
	A.eq(world:sliderFrame("FrameSize").Slider.RightText:GetAlpha(), 0)
	A.eq(world:sliderFrame("FrameWidth").Slider.RightText:GetAlpha(), 1)
end)

test("given_player_or_pet_frames_when_selected_then_size_has_no_box", function()
	for _, spec in ipairs({ wow.frames.player(), wow.frames.pet() }) do
		-- Given / When
		local world = setup(spec)
		-- Then
		A.isNil(world:fineTuneBox("FrameSize"), spec.name .. " size box")
	end
end)

test("given_boss_frames_without_the_larger_frame_option_when_selected_then_size_has_no_box", function()
	-- Given / When
	local small = setup(wow.frames.boss(false))
	local large = setup(wow.frames.boss(true))
	-- Then
	A.isNil(small:fineTuneBox("FrameSize"))
	A.truthy(large:fineTuneBox("FrameSize"))
end)

test("given_a_cast_bar_locked_to_the_player_frame_when_selected_then_size_has_no_box", function()
	-- Given / When
	local locked = setup(wow.frames.castBar(true))
	local free = setup(wow.frames.castBar(false))
	-- Then
	A.isNil(locked:fineTuneBox("BarSize"))
	A.truthy(free:fineTuneBox("BarSize"))
end)

test("given_an_action_bar_when_selected_then_no_slider_gets_a_box", function()
	-- Given / When
	local world = setup(wow.frames.actionBar())
	-- Then
	A.isNil(world:fineTuneBox("IconSize"))
	A.isNil(world:fineTuneBox("IconPadding"))
end)

test("given_a_pooled_slider_with_a_box_when_another_frame_reuses_it_for_an_unsupported_setting_then_the_box_hides", function()
	-- Given
	local world = setup()
	local bar = world:addSystemFrame(wow.frames.actionBar())
	-- When
	world:selectSystem(bar)
	-- Then
	A.isNil(world:fineTuneBox("IconSize"))
	A.eq(world:sliderFrame("IconSize").Slider.RightText:GetAlpha(), 1)
end)

test("given_a_size_box_when_typing_a_value_then_the_frame_scales_and_the_value_is_stored_with_the_raw_step", function()
	-- Given
	local world, frame = setup()
	local setting = world:settingId(frame, "FrameSize")
	-- When
	world:typeInto(world:fineTuneBox("FrameSize"), "87.5")
	-- Then
	A.near(frame:GetScale(), 0.875)
	A.eq(world:fineTuneBox("FrameSize"):GetText(), "87.5")
	A.eq(overrides(world, frame)[setting], { value = 87.5, raw = frame:GetSettingValue(setting, true) })
end)

test("given_an_opacity_box_when_typing_a_value_then_the_frame_alpha_changes", function()
	-- Given
	local world, frame = setup(wow.frames.auras())
	-- When
	world:typeInto(world:fineTuneBox("Opacity"), "73")
	-- Then
	A.near(frame:GetAlpha(), 0.73)
end)

test("given_a_box_when_typing_comma_decimals_percent_or_spaces_then_the_value_is_parsed_and_rounded", function()
	local cases = {
		{ "87,456", "87.46", 0.8746 },
		{ " 120 % ", "120", 1.2 },
		{ "99.999", "100", 1.0 },
	}
	for _, case in ipairs(cases) do
		-- Given
		local world, frame = setup()
		local box = world:fineTuneBox("FrameSize")
		-- When
		world:typeInto(box, case[1])
		-- Then
		A.eq(box:GetText(), case[2], case[1])
		A.near(frame:GetScale(), case[3], 1e-9, case[1])
	end
end)

test("given_a_box_when_typing_out_of_range_values_then_they_are_clamped", function()
	-- Given
	local world, frame = setup()
	local auraWorld, auras = setup(wow.frames.auras())
	-- When
	world:typeInto(world:fineTuneBox("FrameSize"), "5")
	auraWorld:typeInto(auraWorld:fineTuneBox("Opacity"), "150")
	-- Then
	A.near(frame:GetScale(), 0.10, 1e-9, "size min 10")
	A.near(auras:GetAlpha(), 1.0, 1e-9, "opacity max 100")
	world:typeInto(world:fineTuneBox("FrameSize"), "9999")
	A.near(frame:GetScale(), 4.0, 1e-9, "size max 400")
end)

test("given_a_box_when_typing_text_that_is_not_a_number_then_nothing_changes", function()
	-- Given
	local world, frame = setup()
	local box = world:fineTuneBox("FrameSize")
	-- When
	world:typeInto(box, "abc")
	-- Then
	A.eq(box:GetText(), "100")
	A.eq(frame:GetScale(), 1)
	A.isNil(overrides(world, frame))
end)

test("given_a_typed_value_when_typing_the_slider_value_then_the_override_is_removed", function()
	-- Given
	local world, frame = setup()
	local box = world:fineTuneBox("FrameSize")
	world:typeInto(box, "87.5")
	-- When
	world:typeInto(box, "100")
	-- Then
	A.isNil(overrides(world, frame)[world:settingId(frame, "FrameSize")])
	A.eq(frame:GetScale(), 1)
end)

test("given_a_typed_value_when_moving_the_slider_to_the_same_step_then_the_override_is_removed_and_blizzards_value_returns", function()
	-- Given
	local world, frame = setup()
	world:typeInto(world:fineTuneBox("FrameSize"), "87.5")
	-- When
	world:moveSlider("FrameSize", 100)
	-- Then
	A.eq(frame:GetScale(), 1)
	A.isNil(overrides(world, frame)[world:settingId(frame, "FrameSize")])
	-- The box text is refreshed by the next UpdateSettings; whether Blizzard calls it after a
	-- slider move is not modelled (verify), so the box text isn't asserted here.
end)

test("given_a_typed_value_when_moving_the_slider_to_another_step_then_the_slider_value_applies", function()
	-- Given
	local world, frame = setup()
	world:typeInto(world:fineTuneBox("FrameSize"), "87.5")
	-- When
	world:moveSlider("FrameSize", 150)
	-- Then
	A.near(frame:GetScale(), 1.5)
	A.isNil(overrides(world, frame)[world:settingId(frame, "FrameSize")])
end)

test("given_a_typed_value_when_blizzard_reverts_the_slider_step_then_the_override_stays_inactive", function()
	-- Given
	local world, frame = setup()
	world:typeInto(world:fineTuneBox("FrameSize"), "87.5")
	-- When
	world:applyLayoutData({ [frame] = { settings = { FrameSize = 120 } } })
	-- Then
	A.near(frame:GetScale(), 1.2)
	world:selectSystem(frame)
	A.eq(world:fineTuneBox("FrameSize"):GetText(), "120")
end)

test("given_a_typed_value_when_switching_to_a_layout_with_the_same_step_then_blizzards_value_is_restored", function()
	-- Given
	local world, frame = setup()
	world:typeInto(world:fineTuneBox("FrameSize"), "87.5")
	-- When
	world:switchLayout("Other")
	-- Then
	A.eq(frame:GetScale(), 1)
end)

test("given_a_typed_value_when_switching_away_and_back_then_the_typed_value_returns", function()
	-- Given
	local world, frame = setup()
	world:typeInto(world:fineTuneBox("FrameSize"), "87.5")
	world:switchLayout("Other")
	-- When
	world:switchLayout("Main")
	-- Then
	A.near(frame:GetScale(), 0.875)
end)

test("given_a_saved_typed_value_when_the_ui_loads_then_it_is_applied", function()
	-- Given
	local first, frame = setup()
	first:typeInto(first:fineTuneBox("FrameSize"), "87.5")
	local saved = wow.deepcopy(first:saved())
	-- When
	local world = wow.new({ saved = { TinyTweaksDB = saved } })
	world:loadBlizzardAddon("Blizzard_EditMode")
	local reloaded = world:addSystemFrame(wow.frames.target())
	world:loadAddon()
	-- Then
	A.near(reloaded:GetScale(), 0.875)
	A.truthy(frame ~= reloaded)
end)

test("given_combat_when_typing_into_a_protected_frames_box_then_it_is_refused_with_an_error_message", function()
	-- Given
	local world, frame = setup()
	world:setCombat(true)
	local box = world:fineTuneBox("FrameSize")
	-- When
	world:typeInto(box, "87.5")
	-- Then
	A.eq(world.uiErrors, { "You can't do that while in combat" })
	A.eq(frame:GetScale(), 1)
	A.eq(box:GetText(), "100")
end)

test("given_a_typed_value_when_blizzard_reapplies_the_size_in_combat_then_the_typed_value_returns_after_combat", function()
	-- Given
	local world, frame = setup()
	world:typeInto(world:fineTuneBox("FrameSize"), "87.5")
	world:setCombat(true)
	-- When
	world:blizzard(function()
		frame:UpdateSystemSettingFrameSize()
	end)
	A.eq(frame:GetScale(), 1, "Blizzard's value during combat")
	world:setCombat(false)
	-- Then
	A.near(frame:GetScale(), 0.875)
end)

test("given_overrides_for_sliders_no_longer_supported_when_the_addon_loads_then_they_are_dropped", function()
	-- Given
	local probe = wow.new()
	local E = probe.Enum
	local unit = E.EditModeSystem.UnitFrame .. ":" .. E.EditModeUnitFrameSystemIndices.Target
	local bar = E.EditModeSystem.ActionBar .. ":0"
	local saved = { layouts = { ["1:Main"] = { overrides = {
		[unit] = {
			[E.EditModeUnitFrameSetting.FrameSize] = { value = 87.5, raw = 10 },
			[E.EditModeUnitFrameSetting.FrameWidth] = { value = 101, raw = 14 },
		},
		[bar] = { [E.EditModeActionBarSetting.IconSize] = { value = 95, raw = 5 } },
	} } } }
	local world = wow.new({ saved = { TinyTweaksDB = saved } })
	-- When
	world:loadAddon()
	-- Then
	A.eq(world:saved().layouts["1:Main"].overrides, {
		[unit] = { [E.EditModeUnitFrameSetting.FrameSize] = { value = 87.5, raw = 10 } },
	})
end)

-- Screen offset of the frame's first point: point offsets are in the frame's own scale.
local function screenOffset(frame)
	local _, _, _, x, y = frame:GetPoint(1)
	local scale = frame:GetScale()
	return x * scale, y * scale
end

test("given_a_frame_pinned_off_center_when_typing_a_size_then_it_stays_at_its_pin_on_screen", function()
	-- Given
	local pin = { point = "CENTER", relativeTo = "UIParent", relativePoint = "CENTER", offsetX = 400, offsetY = -220 }
	local world, frame = setup(wow.frames.target({ anchorInfo = pin }))
	-- When
	world:typeInto(world:fineTuneBox("FrameSize"), "87.5")
	-- Then
	A.near(frame:GetScale(), 0.875)
	local x, y = screenOffset(frame)
	A.near(x, 400)
	A.near(y, -220)
end)

test("given_a_system_frame_when_typing_a_size_then_blizzard_set_scale_override_is_not_run", function()
	-- Given
	local world, frame = setup()
	local before = world:calls(frame, "SetScale")
	world:bset(world.manager, "editModeSystemAnchorDirty", nil)
	-- When
	world:typeInto(world:fineTuneBox("FrameSize"), "87.5")
	-- Then: the widget SetScale ran (as SetScaleBase), Blizzard's override recorded no snap and left
	-- Edit Mode's anchors clean
	A.near(frame:GetScale(), 0.875)
	A.eq(world:calls(frame, "SetScale"), before + 1)
	A.eq(world:takeViolations(), {})
	A.isNil(world.manager.editModeSystemAnchorDirty)
end)

test("given_a_managed_frame_in_its_default_position_when_selected_then_size_has_no_box_until_it_is_moved", function()
	-- Given
	local world, frame = setup(wow.frames.durability({ isInDefaultPosition = true }))
	-- Then
	A.isNil(world:fineTuneBox("Size"), "no box while Blizzard's container places it")
	-- When
	world:dragSystem(frame, { point = "TOP", relativeTo = "UIParent", relativePoint = "TOP", offsetX = 0, offsetY = -100 }, {})
	world:selectSystem(frame)
	-- Then
	A.truthy(world:fineTuneBox("Size"), "box once moved out of the default position")
	world:typeInto(world:fineTuneBox("Size"), "87.5")
	A.near(frame:GetScale(), 0.875)
	A.eq(world.managedLayouts or 0, 0, "the managed layout never ran from TinyTweaks")
end)

-- Blizzard re-applies a size only when its slider step changed, so returning to the default position
-- doesn't undo a typed size by itself; TinyTweaks must put Blizzard's value back.
test("given_a_typed_size_on_a_managed_frame_when_it_returns_to_its_default_position_then_blizzards_size_applies", function()
	-- Given
	local world, frame = setup(wow.frames.durability({ isInDefaultPosition = true }))
	world:dragSystem(frame, { point = "TOP", relativeTo = "UIParent", relativePoint = "TOP", offsetX = 0, offsetY = -100 }, {})
	world:selectSystem(frame)
	world:typeInto(world:fineTuneBox("Size"), "87.5")
	A.near(frame:GetScale(), 0.875)
	-- When
	world:resetToDefaultPosition(frame)
	-- Then
	A.near(frame:GetScale(), 1, nil, "Blizzard's slider value")
	A.isNil(world:fineTuneBox("Size"), "no box while Blizzard's container places it")
	A.eq(world.managedLayouts or 0, 0, "the managed layout never ran from TinyTweaks")
end)

test("given_a_typed_size_on_a_protected_managed_frame_when_it_returns_to_its_default_position_in_combat_then_blizzards_size_applies_after_combat", function()
	-- Given
	local world, frame = setup(wow.frames.durability({ isInDefaultPosition = true, protected = true }))
	world:dragSystem(frame, { point = "TOP", relativeTo = "UIParent", relativePoint = "TOP", offsetX = 0, offsetY = -100 }, {})
	world:selectSystem(frame)
	world:typeInto(world:fineTuneBox("Size"), "87.5")
	world:setCombat(true)
	-- When
	world:resetToDefaultPosition(frame)
	A.near(frame:GetScale(), 0.875, nil, "nothing changes in combat")
	world:setCombat(false)
	-- Then
	A.near(frame:GetScale(), 1, nil, "Blizzard's slider value once combat ends")
end)

test("given_a_typed_size_on_a_managed_frame_in_its_default_position_when_reverted_to_its_saved_pin_then_the_typed_size_returns", function()
	-- Given
	local world, frame = setup(wow.frames.durability({ isInDefaultPosition = true }))
	local pin = { point = "TOP", relativeTo = "UIParent", relativePoint = "TOP", offsetX = 0, offsetY = -100 }
	world:dragSystem(frame, pin, {})
	world:selectSystem(frame)
	world:typeInto(world:fineTuneBox("Size"), "87.5")
	world:resetToDefaultPosition(frame)
	-- When
	world:revertSystem(frame, { anchorInfo = pin })
	-- Then
	A.near(frame:GetScale(), 0.875)
end)

test("given_a_game_rule_forcing_the_party_frame_scale_when_the_party_frame_is_selected_then_size_has_no_box", function()
	-- Given
	local world = wow.new()
	world:loadAddon()
	world.gameRules[world.Enum.GameRule.ForcedPartyFrameScale] = true
	local party = world:addSystemFrame(wow.frames.party())
	-- When
	world:selectSystem(party)
	-- Then
	A.isNil(world:fineTuneBox("FrameSize"))
	A.truthy(world:fineTuneBox("Opacity"))
	local free = setup(wow.frames.party())
	A.truthy(free:fineTuneBox("FrameSize"), "without the rule")
end)

test("given_a_typed_value_when_the_slider_moves_then_the_box_shows_blizzards_value", function()
	-- Given
	local world = setup()
	local box = world:fineTuneBox("FrameSize")
	world:typeInto(box, "87.5")
	-- When
	world:moveSlider("FrameSize", 120)
	-- Then
	A.eq(world:fineTuneBox("FrameSize"):GetText(), "120")
	A.truthy(world:fineTuneBox("FrameSize") == box, "the dragged slider keeps its frame and box")
end)

test("given_a_typed_value_when_the_dialog_reverts_the_frame_to_another_step_then_blizzards_value_applies", function()
	-- Given
	local world, frame = setup()
	world:typeInto(world:fineTuneBox("FrameSize"), "87.5")
	-- When
	world:revertSystem(frame, { settings = { FrameSize = 120 } })
	-- Then
	A.near(frame:GetScale(), 1.2)
	A.eq(world:fineTuneBox("FrameSize"):GetText(), "120")
end)

test("given_a_box_when_hovered_then_the_tooltip_explains_typing_and_the_slider", function()
	-- Given
	local world = setup()
	-- When
	local lines = world:hover(world:fineTuneBox("FrameSize"))
	-- Then
	A.eq(lines, { "TinyTweaks", "Type any value and press Enter.", "Moving the slider replaces it again." })
end)
