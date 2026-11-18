-- Physical properties the design depends on: work that must not happen, and allocation budgets.
-- A failing invariant means the change broke a performance property, not that the number is wrong;
-- re-measure and raise a budget only with a stated reason.

local wow = require("support.wow")
local A = require("support.assert")

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

local function groupMoves(world)
	local n = 0
	for i = 1, 8 do
		n = n + world:calls(world.groups[i], "SetPoint")
	end
	return n
end

-- KB allocated by fn per call, averaged over `runs`, with the collector stopped.
local function allocatedKB(fn, runs)
	for _ = 1, 5 do
		fn()
	end
	collectgarbage("collect")
	collectgarbage("stop")
	local before = collectgarbage("count")
	for _ = 1, runs do
		fn()
	end
	local kb = (collectgarbage("count") - before) / runs
	collectgarbage("restart")
	return kb
end

test("given_a_grid_when_group_layouts_update_without_a_size_change_then_nothing_is_re_flowed", function()
	-- Given
	local world = raidWorld(true)
	local moves, resizes = groupMoves(world), world:calls(world.container, "SetSize")
	-- When
	world:blizzard(function()
		for i = 1, 8 do
			world.groups[i]:updateLayoutFunc()
		end
	end)
	world:nextFrame()
	-- Then
	A.eq(groupMoves(world), moves, "group SetPoint calls")
	A.eq(world:calls(world.container, "SetSize"), resizes, "container SetSize calls")
end)

test("given_the_grid_is_off_when_blizzard_re_flows_then_tinytweaks_moves_no_group", function()
	-- Given
	local world = raidWorld(false)
	local moves = groupMoves(world)
	-- When
	world:raidLayout()
	-- Then: exactly Blizzard's one SetPoint per group
	A.eq(groupMoves(world) - moves, 8)
end)

test("given_a_grid_when_blizzard_re_flows_then_each_group_is_placed_once_more_by_tinytweaks", function()
	-- Given
	local world = raidWorld(true)
	local moves = groupMoves(world)
	-- When
	world:raidLayout()
	-- Then: Blizzard's 8 plus the grid's 8, and nothing re-placed next frame
	A.eq(groupMoves(world) - moves, 16)
	local placed = groupMoves(world)
	A.eq(world:nextFrame(), 1, "only Blizzard's container size refresh")
	A.eq(groupMoves(world), placed)
end)

test("given_frames_and_layouts_when_only_viewed_then_nothing_is_written_to_saved_variables", function()
	-- Given
	local world = wow.new()
	world:loadAddon()
	local frames = {
		world:addSystemFrame(wow.frames.target()),
		world:addSystemFrame(wow.frames.bags()),
		world:addSystemFrame(wow.frames.auras()),
	}
	world:setRaidRoster(FULL)
	-- When
	for _, frame in ipairs(frames) do
		world:selectSystem(frame)
	end
	world:selectSystem(world.container)
	world:switchLayout("Other")
	world:nextFrame()
	world:closeDialog()
	-- Then
	A.eq(world:saved(), { layouts = {} })
end)

-- Budget: measured 4.5 KB/reflow for the grid (8 groups) on top of the emulator's own 2.6 KB
-- (LuaJIT 2.1, the grid rebuilds its cell table, group index and block closures every reflow).
-- 8 KB gives ~1.8x headroom; a regression to per-member or per-frame work would exceed it.
test("given_a_grid_when_blizzard_re_flows_then_tinytweaks_allocates_under_8_kb", function()
	-- Given
	local off, on = raidWorld(false), raidWorld(true)
	-- When
	local baseline = allocatedKB(function()
		off:raidLayout()
	end, 200)
	local withGrid = allocatedKB(function()
		on:raidLayout()
	end, 200)
	-- Then
	A.truthy(withGrid - baseline < 8, string.format("grid reflow allocated %.2f KB over Blizzard's", withGrid - baseline))
end)
