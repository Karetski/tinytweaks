-- Edit Mode position offsets: an X/Y offset from where Edit Mode pinned a frame.

local wow = require("support.wow")
local A = require("support.assert")

local GRID_LINE = { point = "LEFT", relativeTo = "UIParent", relativePoint = "LEFT", offsetX = 400, offsetY = -120 }

local function setup(spec, opts)
	local world = wow.new(opts)
	world:loadAddon()
	local frame = world:addSystemFrame(spec or wow.frames.target())
	return world, frame
end

local function panel(world)
	return world:findPanel("Position")
end

local function pinText(world)
	local p = panel(world)
	return world:findAnchoredTo(p, world:findText(p, "Pinned to"), "FontString"):GetText()
end

-- Returns the slider and the value box of the "X Offset" / "Y Offset" row.
local function row(world, label)
	local p = panel(world)
	local slider = world:findAnchoredTo(p, world:findText(p, label), "Frame")
	return slider, world:findAnchoredTo(p, slider, "EditBox")
end

local function offset(frame)
	local _, _, _, x, y = frame:GetPoint(1)
	return x, y
end

local function record(world, frame)
	local layout = world:saved().layouts["1:Main"]
	return layout and layout.positions and layout.positions[frame.system .. ":" .. tostring(frame.systemIndex or 0)]
end

test("given_edit_mode_when_a_frame_is_selected_then_the_position_panel_shows_and_hides_with_the_dialog", function()
	-- Given
	local world, frame = setup()
	A.falsy(panel(world):IsShown(), "hidden before selection")
	-- When
	world:selectSystem(frame)
	-- Then
	A.truthy(panel(world):IsShown(), "shown with the dialog")
	world:closeDialog()
	A.falsy(panel(world):IsShown(), "hidden with the dialog")
end)

test("given_the_position_panel_when_created_then_it_is_not_a_child_of_the_settings_dialog", function()
	-- Given / When
	local world = setup()
	-- Then
	A.truthy(panel(world):GetParent() == world.UIParent)
end)

test("given_a_drag_with_snaps_when_the_frame_is_dropped_then_pinned_to_describes_the_snaps", function()
	local cases = {
		{ "screen center", { { frame = "UIParent", point = "CENTER", relativePoint = "CENTER", offset = 0 } }, "Screen center" },
		{ "screen edge", { { frame = "UIParent", point = "TOP", relativePoint = "TOP", offset = 0 } }, "Screen top edge" },
		{ "center line", { { frame = "UIParent", point = "LEFT", relativePoint = "CENTER", offset = 0 } }, "Screen center line" },
		{ "one grid line", { { frame = "UIParent", point = "LEFT", relativePoint = "LEFT", offset = 400 } }, "Grid line" },
		{ "two grid lines", {
			{ frame = "UIParent", point = "LEFT", relativePoint = "LEFT", offset = 400 },
			{ frame = "UIParent", point = "TOP", relativePoint = "TOP", offset = -120 },
		}, "Grid lines" },
		{ "below another frame", { { frame = "PlayerFrame", point = "TOP", relativePoint = "BOTTOM" } }, "Below Player Frame" },
		{ "right of another frame", { { frame = "PlayerFrame", point = "LEFT", relativePoint = "RIGHT" } }, "Right of Player Frame" },
		{ "center and grid", {
			{ frame = "UIParent", point = "CENTER", relativePoint = "CENTER", offset = 0 },
			{ frame = "UIParent", point = "TOP", relativePoint = "TOP", offset = -120 },
		}, "Screen center and Grid line" },
		{ "nothing", {}, "Nothing (placed freely)" },
	}
	for _, case in ipairs(cases) do
		-- Given
		local world, frame = setup()
		world:addSystemFrame(wow.frames.player())
		local snaps = {}
		for i, snap in ipairs(case[2]) do
			snaps[i] = { frame = world.G[snap.frame], point = snap.point, relativePoint = snap.relativePoint, offset = snap.offset }
		end
		-- When
		world:dragSystem(frame, GRID_LINE, snaps)
		world:selectSystem(frame)
		-- Then
		A.eq(pinText(world), case[3], case[1])
	end
end)

test("given_a_pin_made_before_tinytweaks_saw_it_when_selected_then_pinned_to_is_guessed_from_the_anchor", function()
	local cases = {
		{ wow.CENTER, "Screen center" },
		{ GRID_LINE, "Saved position" },
		{ { point = "TOP", relativeTo = "PlayerFrame", relativePoint = "BOTTOM", offsetX = 0, offsetY = 0 }, "Below Player Frame" },
	}
	for _, case in ipairs(cases) do
		-- Given
		local world = setup(wow.frames.player())
		local frame = world:addSystemFrame(wow.frames.target({ anchorInfo = case[1] }))
		-- When
		world:selectSystem(frame)
		-- Then
		A.eq(pinText(world), case[2])
	end
end)

test("given_frames_that_cannot_take_an_offset_when_selected_then_the_reason_shows_and_the_rows_are_disabled", function()
	local cases = {
		{ wow.frames.target({ isInDefaultPosition = true }), "Default position" },
		{ wow.frames.target({ anchorInfo2 = { point = "BOTTOMRIGHT", relativeTo = "UIParent", relativePoint = "CENTER", offsetX = 10, offsetY = 10 } }), "Two anchor points" },
		{ wow.frames.target({ locked = true }), "Locked" },
	}
	for _, case in ipairs(cases) do
		-- Given
		local world, frame = setup(case[1])
		-- When
		world:selectSystem(frame)
		-- Then
		A.eq(pinText(world), case[2])
		local slider, box = row(world, "X Offset")
		A.falsy(box:IsEnabled(), case[2] .. ": box disabled")
		A.falsy(slider:IsEnabled(), case[2] .. ": slider disabled")
		A.eq(box:GetText(), "")
	end
end)

test("given_a_pinned_frame_when_typing_offsets_then_it_moves_from_the_pin_and_the_offset_is_saved", function()
	-- Given
	local world, frame = setup()
	world:selectSystem(frame)
	local _, xBox = row(world, "X Offset")
	local _, yBox = row(world, "Y Offset")
	-- When
	world:typeInto(xBox, "15")
	world:typeInto(yBox, "-220")
	-- Then
	A.eq({ offset(frame) }, { 15, -220 })
	A.eq(frame:GetNumPoints(), 1)
	A.eq(record(world, frame).x, 15)
	A.eq(record(world, frame).y, -220)
	A.eq(yBox:GetText(), "-220")
end)

test("given_a_scaled_frame_when_typing_an_offset_then_the_point_offset_is_in_the_frames_scale", function()
	-- Given
	local spec = wow.frames.target()
	spec.settings[1].value = 50 -- FrameSize 50% -> scale 0.5
	local world, frame = setup(spec)
	world:selectSystem(frame)
	local _, xBox = row(world, "X Offset")
	-- When
	world:typeInto(xBox, "100")
	-- Then
	A.eq(frame:GetScale(), 0.5)
	A.eq({ offset(frame) }, { 200, 0 })
end)

test("given_an_offset_box_when_typing_decimals_or_text_then_values_round_to_one_decimal_and_text_is_ignored", function()
	-- Given
	local world, frame = setup()
	world:selectSystem(frame)
	local _, xBox = row(world, "X Offset")
	-- When
	world:typeInto(xBox, "12,34")
	-- Then
	A.eq(xBox:GetText(), "12.3")
	A.near((offset(frame)), 12.3)
	world:typeInto(xBox, "abc")
	A.eq(xBox:GetText(), "12.3")
end)

test("given_the_offset_slider_when_dragged_then_the_frame_moves_and_the_box_follows", function()
	-- Given
	local world, frame = setup()
	world:selectSystem(frame)
	local slider, box = row(world, "X Offset")
	-- When
	world:dragSlider(slider, 50)
	-- Then
	A.eq((offset(frame)), 50)
	A.eq(box:GetText(), "50")
	A.eq(slider:GetValue(), 50)
end)

test("given_a_typed_offset_beyond_the_slider_range_when_shown_then_the_range_widens_symmetrically", function()
	-- Given
	local world, frame = setup()
	world:selectSystem(frame)
	local slider, yBox = row(world, "Y Offset")
	-- When
	world:typeInto(yBox, "-350")
	-- Then
	A.eq(world:state(slider).slider.min, -350)
	A.eq(world:state(slider).slider.max, 350)
	A.eq(slider:GetValue(), -350)
	A.eq({ offset(frame) }, { 0, -350 })
end)

test("given_an_offset_when_the_frame_is_dragged_to_a_new_pin_then_the_offset_resets_to_zero", function()
	-- Given
	local world, frame = setup()
	world:selectSystem(frame)
	local _, yBox = row(world, "Y Offset")
	world:typeInto(yBox, "-220")
	-- When
	world:dragSystem(frame, GRID_LINE, {})
	-- Then
	A.eq({ offset(frame) }, { 400, -120 })
	A.eq(record(world, frame).y, 0)
	A.eq(yBox:GetText(), "0")
end)

test("given_an_offset_when_blizzard_reapplies_the_same_pin_then_the_offset_is_kept", function()
	-- Given
	local world, frame = setup()
	world:selectSystem(frame)
	world:typeInto(select(2, row(world, "Y Offset")), "-220")
	-- When
	world:applyLayoutData({})
	-- Then
	A.eq({ offset(frame) }, { 0, -220 })
end)

test("given_an_offset_when_blizzard_changes_the_pin_without_a_drag_then_the_offset_no_longer_applies", function()
	-- Given
	local world, frame = setup()
	world:selectSystem(frame)
	world:typeInto(select(2, row(world, "Y Offset")), "-220")
	-- When
	world:applyLayoutData({ [frame] = { anchorInfo = GRID_LINE } })
	-- Then
	A.eq({ offset(frame) }, { 400, -120 })
	world:selectSystem(frame)
	A.eq(select(2, row(world, "Y Offset")):GetText(), "0")
end)

test("given_an_offset_in_one_layout_when_switching_layouts_then_it_applies_only_to_its_layout", function()
	-- Given
	local world, frame = setup()
	world:selectSystem(frame)
	world:typeInto(select(2, row(world, "Y Offset")), "-220")
	-- When
	world:switchLayout("Other")
	-- Then
	A.eq({ offset(frame) }, { 0, 0 })
	world:switchLayout("Main")
	A.eq({ offset(frame) }, { 0, -220 })
end)

test("given_a_saved_offset_when_the_ui_loads_then_the_frame_is_placed_with_it", function()
	-- Given
	local first, frame = setup()
	first:selectSystem(frame)
	first:typeInto(select(2, row(first, "Y Offset")), "-220")
	local world = wow.new({ saved = { TinyTweaksDB = wow.deepcopy(first:saved()) } })
	world:loadBlizzardAddon("Blizzard_EditMode")
	local reloaded = world:addSystemFrame(wow.frames.target())
	-- When
	world:loadAddon()
	-- Then
	A.eq({ offset(reloaded) }, { 0, -220 })
end)

test("given_combat_when_typing_an_offset_for_a_protected_frame_then_it_is_refused", function()
	-- Given
	local world, frame = setup()
	world:selectSystem(frame)
	world:setCombat(true)
	-- When
	world:typeInto(select(2, row(world, "Y Offset")), "-220")
	-- Then
	A.eq(world.uiErrors, { "You can't do that while in combat" })
	A.eq({ offset(frame) }, { 0, 0 })
	A.isNil(record(world, frame))
end)

test("given_an_offset_when_blizzard_re_anchors_a_protected_frame_in_combat_then_the_offset_returns_after_combat", function()
	-- Given
	local world, frame = setup()
	world:selectSystem(frame)
	world:typeInto(select(2, row(world, "Y Offset")), "-220")
	world:setCombat(true)
	-- When
	world:applyLayoutData({})
	A.eq({ offset(frame) }, { 0, 0 }, "Blizzard's pin during combat")
	world:setCombat(false)
	-- Then
	A.eq({ offset(frame) }, { 0, -220 })
end)
