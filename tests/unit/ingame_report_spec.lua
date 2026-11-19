-- The in-game report: checks TinyTweaks' saved records against the frame state the dev recorder
-- saved at logout, and picks TinyTweaks' entries out of errors and taint.log.

local A = require("support.assert")
local R = dofile("tools/ingame_report.lua")

local PIN = { point = "CENTER", relativeTo = "UIParent", relativePoint = "CENTER", offsetX = 100, offsetY = -50 }

local function frame(extra)
	local f = {
		name = "TargetFrame", scale = 1, alpha = 1, settings = { [13] = 0 },
		point = { "CENTER", "UIParent", "CENTER", 100, -50 },
		pin = { "CENTER", "UIParent", "CENTER", 100, -50 },
	}
	for k, v in pairs(extra or {}) do
		f[k] = v
	end
	return f
end

local function statuses(layout, frames)
	local out = {}
	for _, r in ipairs(R.check(layout, { frames = frames })) do
		out[#out + 1] = r.status
	end
	return out
end

test("given_a_typed_size_on_its_step_when_checked_then_it_passes_only_if_the_frame_has_that_scale", function()
	-- Given
	local layout = { overrides = { ["3:2"] = { [13] = { value = 87.5, raw = 0 } } } }
	-- When / Then
	A.eq(statuses(layout, { ["3:2"] = frame({ scale = 0.875 }) }), { "pass" })
	A.eq(statuses(layout, { ["3:2"] = frame({ scale = 1 }) }), { "fail" })
end)

test("given_a_typed_value_whose_slider_moved_when_checked_then_it_is_reported_as_inactive", function()
	-- Given
	local layout = { overrides = { ["3:2"] = { [13] = { value = 87.5, raw = 0 } } } }
	-- When / Then
	A.eq(statuses(layout, { ["3:2"] = frame({ settings = { [13] = 2 } }) }), { "info" })
end)

test("given_a_typed_size_on_a_managed_frame_in_its_default_position_when_checked_then_it_must_not_be_applied", function()
	-- Given
	local layout = { overrides = { ["16:0"] = { [0] = { value = 87.5, raw = 5 } } } }
	local function durability(scale)
		return { ["16:0"] = frame({ name = "DurabilityFrame", managed = true, default = true, scale = scale, settings = { [0] = 5 } }) }
	end
	-- When / Then
	A.eq(statuses(layout, durability(1)), { "pass" })
	A.eq(statuses(layout, durability(0.875)), { "fail" })
end)

test("given_an_offset_on_the_current_pin_when_checked_then_the_point_must_be_pin_plus_offset_in_the_frames_scale", function()
	-- Given
	local layout = { positions = { ["3:2"] = { x = 0, y = -20, pin = PIN } } }
	-- When / Then
	A.eq(statuses(layout, { ["3:2"] = frame({ scale = 2, point = { "CENTER", "UIParent", "CENTER", 50, -35 } }) }), { "pass" })
	A.eq(statuses(layout, { ["3:2"] = frame({ scale = 2, point = { "CENTER", "UIParent", "CENTER", 50, -25 } }) }), { "fail" })
end)

test("given_an_offset_for_an_old_pin_when_checked_then_it_is_reported_as_inactive", function()
	-- Given
	local layout = { positions = { ["3:2"] = { x = 0, y = -20, pin = PIN } } }
	-- When / Then
	A.eq(statuses(layout, { ["3:2"] = frame({ pin = { "TOP", "UIParent", "TOP", 0, 0 } }) }), { "info" })
end)

test("given_raid_group_positions_when_formatted_then_rows_read_top_down_and_left_to_right", function()
	-- Given
	local groups = {
		{ 0, 0 }, { 80, 0 }, { 160, 0 }, { 240, 0 },
		{ 0, -200 }, { 80, -200 }, { 160, -200 }, { 240, -200 },
	}
	-- When / Then
	A.eq(R.gridString(groups), "1 2 3 4 / 5 6 7 8")
end)

test("given_errors_from_several_addons_when_filtered_then_only_tinytweaks_ones_are_ours", function()
	A.truthy(R.isOurs({ message = "x", stack = '[string "@Interface/AddOns/TinyTweaks/Core.lua"]:12: in function' }))
	A.falsy(R.isOurs({ message = "x", stack = '[string "@Interface/AddOns/!TinyTweaksDev/Recorder.lua"]:3:' }))
	A.falsy(R.isOurs({ message = "x", stack = '[string "@Interface/AddOns/Questie/Questie.lua"]:3:' }))
	A.truthy(R.isOurs({ addon = "TinyTweaks", func = "TargetFrame:SetPoint()" }))
end)

test("given_a_taint_log_when_read_then_only_blocks_naming_tinytweaks_are_returned", function()
	-- Given
	local text = table.concat({
		"11/18 18:30:01.000  An action was blocked because of taint from TinyTweaks - TargetFrame:SetPoint()",
		"11/18 18:30:01.000      Interface/AddOns/TinyTweaks/EditModePosition.lua:131",
		"11/18 18:31:00.000  Global variable Foo tainted by Questie - Interface/AddOns/Questie/Q.lua:1",
		"11/18 18:32:00.000  Global variable TinyTweaksDevLog tainted by !TinyTweaksDev",
	}, "\n")
	-- When
	local blocks, total = R.taintBlocks(text:gsub("\n11/18 18:30:01.000      ", "\n    "))
	-- Then
	A.eq(total, 3)
	A.eq(#blocks, 1)
	A.truthy(blocks[1]:find("EditModePosition.lua:131", 1, true))
end)

test("given_a_character_layout_when_looking_up_records_then_the_key_with_the_character_suffix_is_found", function()
	-- Given
	local db = { layouts = { ["1:Main:Hero-Realm"] = { positions = {} } } }
	-- When
	local layout, key = R.layoutFor(db, "1:Main")
	-- Then
	A.truthy(layout)
	A.eq(key, "1:Main:Hero-Realm")
end)

test("given_a_slider_drag_recorded_as_one_entry_when_listed_then_it_shows_first_and_last_value_and_steps", function()
	-- Given
	local drag = { at = "19:23:41", event = "slider", frame = "3:5", name = "CompactRaidFrameContainer", setting = 20, first = 100, value = 92, steps = 61 }
	-- When
	local lines = R.trailLines({ drag })
	-- Then
	A.eq(lines[1], "19:23:41  slider: CompactRaidFrameContainer (3:5) setting 20 100 -> 92 (61 steps)")
end)
