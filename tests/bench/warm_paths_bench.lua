-- Micro benchmarks for the paths that run on Blizzard events (re-flows, layout updates, re-anchors).
-- Numbers include the emulator's own overhead (hook wrappers, guarded proxies), so compare runs with
-- each other, not with in-game profiler numbers. Run: luajit tests/run.lua bench

local wow = require("support.wow")

local FULL = { 5, 5, 5, 5, 5, 5, 5, 5 }

local function raidWorld(gridEnabled)
	local world = wow.new()
	world:loadAddon()
	world:setRaidRoster(FULL)
	world:selectSystem(world.container)
	if gridEnabled then
		world:click(world:findKind(world:findPanel("Group Layout"), "CheckButton"))
	end
	world:closeDialog()
	world:nextFrame()
	return world
end

bench("raid re-flow, 40 players, grid off (Blizzard + hook baseline)", function()
	local world = raidWorld(false)
	return function()
		world:raidLayout()
	end
end)

bench("raid re-flow, 40 players, grid on", function()
	local world = raidWorld(true)
	return function()
		world:raidLayout()
	end
end)

bench("UpdateSystems, 6 frames with typed values and offsets", function()
	local world = wow.new()
	world:loadAddon()
	local specs = {
		{ wow.frames.target(), "FrameSize" },
		{ wow.frames.focus(), "FrameSize" },
		{ wow.frames.boss(true), "FrameSize" },
		{ wow.frames.bags(), "Size" },
		{ wow.frames.castBar(false), "BarSize" },
		{ wow.frames.auras(), "Opacity" },
	}
	for _, s in ipairs(specs) do
		local frame = world:addSystemFrame(s[1])
		world:selectSystem(frame)
		world:typeInto(world:fineTuneBox(s[2]), "87.5")
		local p = world:findPanel("Position")
		local slider = world:findAnchoredTo(p, world:findText(p, "Y Offset"), "Frame")
		world:typeInto(world:findAnchoredTo(p, slider, "EditBox"), "-20")
	end
	world:closeDialog()
	return function()
		world:applyLayoutData({})
	end
end)

bench("ApplySystemAnchor on one frame with an offset", function()
	local world = wow.new()
	world:loadAddon()
	local frame = world:addSystemFrame(wow.frames.target())
	world:selectSystem(frame)
	local p = world:findPanel("Position")
	local slider = world:findAnchoredTo(p, world:findText(p, "Y Offset"), "Frame")
	world:typeInto(world:findAnchoredTo(p, slider, "EditBox"), "-220")
	world:closeDialog()
	return function()
		world:blizzard(function()
			frame:ApplySystemAnchor()
		end)
	end
end)

bench("Edit Mode dialog update for a fine-tunable frame", function()
	local world = wow.new()
	world:loadAddon()
	local frame = world:addSystemFrame(wow.frames.target())
	world:selectSystem(frame)
	return function()
		world:blizzard(function()
			world.dialog:UpdateSettings(frame)
		end)
	end
end)
