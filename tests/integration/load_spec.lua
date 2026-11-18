-- Loading: the whole addon in TOC order, in both load orders, without errors, globals or taint.

local wow = require("support.wow")
local A = require("support.assert")

local function exercise(world)
	local target = world:addSystemFrame(wow.frames.target())
	world:setRaidRoster({ 5, 5, 5, 5, 5, 5, 5, 5 })
	world:selectSystem(target)
	world:typeInto(world:fineTuneBox("FrameSize"), "87.5")
	world:selectSystem(world.container)
	world:switchLayout("Other")
	world:nextFrame()
	world:closeDialog()
end

test("given_blizzard_addons_loaded_first_when_the_addon_loads_and_is_used_then_no_errors_or_violations", function()
	-- Given
	local world = wow.new()
	-- When
	world:loadAddon()
	exercise(world)
	-- Then: wow.finish() fails the test on any recorded error or taint violation
	A.eq(world.errors, {})
end)

test("given_the_addon_loaded_before_blizzard_addons_when_they_load_and_it_is_used_then_no_errors_or_violations", function()
	-- Given
	local world = wow.new()
	world:loadAddon({ blizzardFirst = false })
	-- When
	world:loadBlizzardAddon("Blizzard_CompactRaidFrames")
	world:loadBlizzardAddon("Blizzard_EditMode")
	exercise(world)
	-- Then
	A.eq(world.errors, {})
end)

test("given_the_addon_when_loaded_and_used_then_the_only_global_it_writes_is_its_saved_variables", function()
	-- Given
	local world = wow.new()
	-- When
	world:loadAddon()
	exercise(world)
	-- Then
	A.eq(world.globalWrites, { TinyTweaksDB = true })
end)

test("given_the_toc_when_read_then_it_lists_the_core_first", function()
	-- Given / When
	local files = wow.tocFiles()
	-- Then
	A.eq(files[1], "Core.lua")
end)

-- The emulator's own guards: these prove a violation would be caught, so a green run means something.

test("given_addon_code_when_it_writes_a_field_on_a_blizzard_frame_then_the_emulator_flags_taint", function()
	-- Given
	local world = wow.new()
	world:loadAddon()
	-- When
	A.errors(function()
		world.dialog.myField = true
	end, "taint: addon wrote myField on EditModeSystemSettingsDialog")
	-- Then
	A.eq(world:takeViolations(), { "taint: addon wrote myField on EditModeSystemSettingsDialog" })
end)

test("given_addon_code_when_it_calls_a_blizzard_edit_mode_method_then_the_emulator_flags_taint", function()
	-- Given
	local world = wow.new()
	world:loadAddon()
	local frame = world:addSystemFrame(wow.frames.target())
	-- When
	A.errors(function()
		frame:ApplySystemAnchor()
	end, "taint: addon called ApplySystemAnchor")
	A.errors(function()
		world.manager:UpdateSystems()
	end, "taint: addon called UpdateSystems")
	-- Then
	A.eq(#world:takeViolations(), 2)
end)

test("given_addon_code_when_it_parents_a_frame_to_the_settings_dialog_then_the_emulator_flags_taint", function()
	-- Given
	local world = wow.new()
	world:loadAddon()
	-- When
	A.errors(function()
		world.G.CreateFrame("Frame", nil, world.dialog)
	end, "taint: addon parented a frame to EditModeSystemSettingsDialog")
	-- Then
	A.eq(#world:takeViolations(), 1)
end)

test("given_combat_when_addon_code_moves_a_protected_frame_then_the_emulator_flags_a_blocked_action", function()
	-- Given
	local world = wow.new()
	world:loadAddon()
	local frame = world:addSystemFrame(wow.frames.target())
	world:setCombat(true)
	-- When
	A.errors(function()
		frame:SetScaleBase(2)
	end, "blocked: addon called SetScale on protected TargetFrame in combat")
	frame:SetAlpha(0.5)
	-- Then
	A.eq(#world:takeViolations(), 1)
end)

test("given_addon_code_when_it_calls_blizzards_set_scale_or_set_point_override_on_a_system_frame_then_the_emulator_flags_taint", function()
	-- Given
	local world = wow.new()
	world:loadAddon()
	local frame = world:addSystemFrame(wow.frames.target())
	-- When
	A.errors(function()
		frame:SetScale(2)
	end, "taint: addon called SetScale on TargetFrame")
	A.errors(function()
		frame:SetPoint("CENTER", world.UIParent, "CENTER", 0, 0)
	end, "taint: addon called SetPoint on TargetFrame")
	A.errors(function()
		frame:ClearAllPoints()
	end, "taint: addon called ClearAllPoints on TargetFrame")
	frame:SetScaleBase(2)
	frame:SetPointBase("CENTER", world.UIParent, "CENTER", 0, 0)
	-- Then
	A.eq(#world:takeViolations(), 3)
	A.eq(frame:GetScale(), 2)
end)

test("given_a_hook_on_a_blizzard_method_when_blizzard_calls_it_then_the_hook_runs_as_addon_code_after_it", function()
	-- Given
	local world = wow.new()
	world:loadAddon()
	local frame = world:addSystemFrame(wow.frames.target())
	local order = {}
	world.G.hooksecurefunc(frame, "ApplySystemAnchor", function()
		order[#order + 1] = world:isBlizzard() and "hook as blizzard" or "hook as addon"
	end)
	-- When
	world:blizzard(function()
		frame:ApplySystemAnchor()
	end)
	-- Then
	A.eq(order, { "hook as addon" })
end)
