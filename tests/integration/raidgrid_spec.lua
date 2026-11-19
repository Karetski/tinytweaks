-- Raid group grid: raid groups 1-8 arranged in a grid instead of Blizzard's single line.

local wow = require("support.wow")
local A = require("support.assert")

local FULL = { 5, 5, 5, 5, 5, 5, 5, 5 }
local BLIZZARD_LINE = "1 2 3 4 5 6 7 8"
local GROUP_HEIGHT = 14 + 5 * 36 -- a full group in the emulator

local function setup(opts)
	local world = wow.new(opts)
	world:loadAddon()
	world:setRaidRoster(FULL)
	world:selectSystem(world.container)
	world:nextFrame() -- Blizzard's next-frame container size refresh
	return world
end

local function panel(world)
	return world:findPanel("Group Layout")
end

local function toggle(world)
	world:click(world:findKind(panel(world), "CheckButton"))
end

local function columnsText(world)
	local p = panel(world)
	return world:findAnchoredTo(p, world:findButton(p, "-"), "FontString"):GetText()
end

local function setColumns(world, n)
	local p = panel(world)
	for _ = 1, 8 do
		local current = tonumber(columnsText(world))
		if current == n then
			return
		end
		world:click(world:findButton(p, current < n and "+" or "-"))
	end
	error("could not reach " .. n .. " columns")
end

local function choose(world, text)
	world:click(world:findButton(panel(world), text))
end

local function corner(world, name)
	world:click(world:findByTooltip(panel(world), name))
end

local function spacing(world, label, value)
	local p = panel(world)
	world:typeInto(world:findAnchoredTo(p, world:findText(p, label), "EditBox"), value)
end

local function note(world)
	local p = panel(world)
	for _, obj in ipairs(world:descendants(p)) do
		local s = world:state(obj)
		if s.kind == "FontString" and s.font == "GameFontDisableSmall" and s.text and s.text:find("%.$") then
			return s.text
		end
	end
end

local function config(world)
	return world:saved().layouts["1:Main"].groupGrid
end

test("given_raid_frames_when_selected_in_edit_mode_then_the_group_layout_panel_shows", function()
	-- Given / When
	local world = setup()
	-- Then
	A.truthy(panel(world):IsShown())
	A.eq(world:raidGrid(), BLIZZARD_LINE, "grid is off by default")
	world:selectSystem(world:addSystemFrame(wow.frames.target()))
	A.falsy(panel(world):IsShown(), "hidden for other frames")
end)

test("given_the_readme_examples_when_configured_then_groups_are_placed_as_documented", function()
	local cases = {
		{ 4, "Across", "Top left", "1 2 3 4 / 5 6 7 8" },
		{ 2, "Across", "Top left", "1 2 / 3 4 / 5 6 / 7 8" },
		{ 2, "Down", "Top left", "1 5 / 2 6 / 3 7 / 4 8" },
		{ 2, "Across", "Bottom right", "8 7 / 6 5 / 4 3 / 2 1" },
		{ 4, "Across", "Top right", "4 3 2 1 / 8 7 6 5" },
		{ 1, "Across", "Top left", "1 / 2 / 3 / 4 / 5 / 6 / 7 / 8" },
	}
	for _, case in ipairs(cases) do
		-- Given
		local world = setup()
		toggle(world)
		-- When
		choose(world, case[2])
		setColumns(world, case[1])
		corner(world, case[3])
		-- Then
		A.eq(world:raidGrid(), case[4], table.concat({ case[1], case[2], case[3] }, " / "))
	end
end)

test("given_a_grid_when_placed_then_every_cell_is_the_size_of_the_largest_group", function()
	-- Given
	local world = setup()
	world:setRaidRoster({ 5, 1, 5, 5, 5, 5, 5, 5 })
	-- When
	toggle(world)
	-- Then
	A.eq({ world:groupOffset(2) }, { 72, 0 })
	A.eq({ world:groupOffset(5) }, { 0, -GROUP_HEIGHT })
end)

test("given_a_grid_when_spacing_is_set_then_cells_are_separated_by_it", function()
	-- Given
	local world = setup()
	toggle(world)
	-- When
	spacing(world, "Horiz.", "10")
	spacing(world, "Vert.", "20")
	-- Then
	A.eq({ world:groupOffset(2) }, { 82, 0 })
	A.eq({ world:groupOffset(5) }, { 0, -(GROUP_HEIGHT + 20) })
	A.eq(config(world).hSpacing, 10)
	A.eq(config(world).vSpacing, 20)
end)

test("given_spacing_input_when_out_of_range_or_fractional_then_it_is_clamped_to_whole_pixels", function()
	-- Given
	local world = setup()
	toggle(world)
	-- When
	spacing(world, "Horiz.", "250")
	spacing(world, "Vert.", "3.7")
	-- Then
	A.eq(config(world).hSpacing, 100)
	A.eq(config(world).vSpacing, 3)
end)

test("given_a_group_with_no_members_when_the_grid_is_placed_then_other_groups_keep_their_cells", function()
	-- Given
	local world = setup()
	toggle(world)
	local x4, y4 = world:groupOffset(4)
	-- When
	world:setRaidRoster({ 5, 5, 0, 5, 5, 5, 5, 5 })
	-- Then: Blizzard drops the empty group from the flow and hides it; its cell stays empty
	A.eq({ world:groupOffset(4) }, { x4, y4 })
	A.eq(world:raidGrid(), "1 2 . 4 / 5 6 7 8")
	A.falsy(world.groups[3]:IsShown(), "group 3 hidden")
	for _, object in ipairs(world.container.flowFrames) do
		A.truthy(object ~= world.groups[3], "group 3 is not in the flow")
	end
end)

test("given_groups_that_never_existed_when_the_grid_is_placed_then_their_cells_stay_empty", function()
	-- Given
	local world = wow.new()
	world:loadAddon()
	world:setRaidRoster({ 5, 5, 0, 5 })
	world:selectSystem(world.container)
	-- When
	toggle(world)
	-- Then
	A.eq({ world:groupOffset(2) }, { 72, 0 })
	A.eq({ world:groupOffset(4) }, { 3 * 72, 0 }, "group 4 keeps column 4; column 3 stays empty")
end)

test("given_a_grid_when_it_is_turned_off_then_blizzards_layout_returns", function()
	-- Given
	local world = setup()
	toggle(world)
	A.eq(world:raidGrid(), "1 2 3 4 / 5 6 7 8")
	-- When
	toggle(world)
	-- Then
	A.eq(world:raidGrid(), BLIZZARD_LINE)
	A.eq(config(world).enabled, false)
end)

test("given_a_grid_when_blizzard_re_flows_the_container_then_the_grid_is_re_applied_in_the_same_frame", function()
	-- Given
	local world = setup()
	toggle(world)
	-- When
	world:raidLayout()
	-- Then
	A.eq(world:raidGrid(), "1 2 3 4 / 5 6 7 8")
end)

test("given_combined_groups_mode_when_the_grid_is_enabled_then_nothing_is_rearranged_and_the_option_is_disabled", function()
	-- Given
	local world = setup()
	toggle(world)
	-- When
	local moves = 0
	for i = 1, 8 do
		moves = moves + world:calls(world.groups[i], "SetPoint")
	end
	world:setRaidGroupMode("flush")
	world:selectSystem(world.container)
	-- Then: Blizzard lays out players, not groups, and TinyTweaks moves nothing
	A.eq(world:raidGrid(), "", "no group is shown")
	local after = 0
	for i = 1, 8 do
		after = after + world:calls(world.groups[i], "SetPoint")
	end
	A.eq(after, moves, "no group moved")
	A.falsy(world:findKind(panel(world), "CheckButton"):IsEnabled(), "checkbox disabled")
	A.eq(note(world), "Only applies when Groups is set to Separate.")
end)

test("given_a_grid_when_the_roster_changes_in_combat_then_blizzards_layout_holds_until_combat_ends", function()
	-- Given
	local world = setup()
	toggle(world)
	world:setCombat(true)
	-- When
	world:setRaidRoster({ 5, 5, 5, 5, 5, 5, 5, 4 })
	A.eq(world:raidGrid(), BLIZZARD_LINE, "during combat")
	world:setCombat(false)
	-- Then
	A.eq(world:raidGrid(), "1 2 3 4 / 5 6 7 8")
end)

test("given_combat_when_the_panel_is_shown_then_it_says_changes_apply_after_combat", function()
	-- Given
	local world = setup()
	world:setCombat(true)
	-- When
	world:selectSystem(world.container)
	-- Then
	A.eq(note(world), "Changes apply after combat.")
end)

test("given_a_grid_in_one_layout_when_switching_layouts_then_each_layout_keeps_its_own_setting", function()
	-- Given
	local world = setup()
	toggle(world)
	-- When
	world:switchLayout("Other")
	world:nextFrame()
	-- Then
	A.eq(world:raidGrid(), BLIZZARD_LINE, "other layout")
	world:switchLayout("Main")
	world:nextFrame()
	A.eq(world:raidGrid(), "1 2 3 4 / 5 6 7 8", "back in the main layout")
end)

test("given_down_order_when_stepping_columns_then_counts_that_give_the_same_grid_are_skipped", function()
	-- Given
	local world = setup()
	toggle(world)
	choose(world, "Down")
	A.eq(columnsText(world), "4")
	-- When
	world:click(world:findButton(panel(world), "+"))
	-- Then
	A.eq(columnsText(world), "8")
	A.eq(world:raidGrid(), BLIZZARD_LINE)
	world:click(world:findButton(panel(world), "-"))
	A.eq(columnsText(world), "4")
end)

test("given_down_order_when_stepping_back_from_8_columns_and_switching_to_across_then_the_grid_keeps_4_columns", function()
	-- Given
	local world = setup()
	toggle(world)
	choose(world, "Down")
	world:click(world:findButton(panel(world), "+"))
	world:click(world:findButton(panel(world), "-"))
	-- When
	choose(world, "Across")
	-- Then
	A.eq(columnsText(world), "4")
	A.eq(world:raidGrid(), "1 2 3 4 / 5 6 7 8")
end)

-- Distance from root's top edge down to region's top edge, along a chain of TOPLEFT anchors.
local function depthBelowTop(root, region)
	local _, relTo, relPoint, _, y = region:GetPoint(1)
	local depth = relTo == root and 0 or depthBelowTop(root, relTo)
	if relPoint:find("^BOTTOM") then
		depth = depth + relTo:GetHeight()
	end
	return depth - y
end

test("given_the_panel_when_shown_then_its_note_stays_clear_of_the_bottom_border", function()
	for _, columns in ipairs({ 4, 1 }) do
		-- Given
		local world = setup()
		toggle(world)
		-- When
		setColumns(world, columns)
		-- Then
		local p = panel(world)
		local text = world:findText(p, "Saved per Edit Mode layout.")
		local noteBottom = depthBelowTop(p, text) + text:GetStringHeight()
		A.truthy(p:GetHeight() - noteBottom >= 14, columns .. " columns: " .. p:GetHeight() - noteBottom .. " px below the note")
	end
end)

test("given_a_grid_when_previewed_then_the_panel_preview_matches_the_placement", function()
	-- Given
	local world = setup()
	toggle(world)
	-- When
	setColumns(world, 2)
	corner(world, "Bottom left")
	-- Then
	local cells = {}
	for _, obj in ipairs(world:descendants(panel(world))) do
		local s = world:state(obj)
		if s.kind == "Frame" and s.width == 22 and s.height == 16 then
			local text = world:findKind(obj, "FontString"):GetText()
			local _, _, _, x, y = obj:GetPoint(1)
			cells[#cells + 1] = { tonumber(text), x, y }
		end
	end
	table.sort(cells, function(a, b)
		if a[3] ~= b[3] then
			return a[3] > b[3]
		end
		return a[2] < b[2]
	end)
	local order = {}
	for i, c in ipairs(cells) do
		order[i] = c[1]
	end
	A.eq(order, { 7, 8, 5, 6, 3, 4, 1, 2 })
	A.eq(world:raidGrid(), "7 8 / 5 6 / 3 4 / 1 2")
end)

test("given_group_sizes_change_without_a_re_flow_when_the_next_frame_runs_then_the_grid_is_re_measured_once", function()
	-- Given
	local world = setup()
	toggle(world)
	local before = world:calls(world.container, "SetSize")
	-- When
	world:resizeRaidMembers(80, 40)
	A.eq(world:calls(world.container, "SetSize"), before, "nothing before the next frame")
	world:nextFrame()
	-- Then
	A.eq(world:calls(world.container, "SetSize"), before + 1, "one re-flow for eight resized groups")
	A.eq({ world:groupOffset(2) }, { 80, 0 })
	A.eq(world:nextFrame(), 0, "settled")
end)

test("given_settings_from_the_earlier_panel_version_when_loaded_then_they_are_migrated", function()
	-- Given
	local saved = { layouts = { ["1:Main"] = {
		groupGrid = { enabled = true, perLine = 2, fill = "columns", vDir = "up", hDir = "left", rows = 4 },
		raidGrid = { enabled = true },
	} } }
	local world = wow.new({ saved = { TinyTweaksDB = saved } })
	-- When
	world:loadAddon()
	world:setRaidRoster(FULL)
	-- Then
	A.eq(world:raidGrid(), "8 6 4 2 / 7 5 3 1")
	A.eq(config(world), { enabled = true, columns = 4, order = "down", corner = "BOTTOMRIGHT", hSpacing = 0, vSpacing = 0 })
	A.isNil(world:saved().layouts["1:Main"].raidGrid)
end)

test("given_earlier_settings_in_a_layout_that_is_not_active_when_loaded_then_they_are_migrated_at_load", function()
	-- Given
	local old = { enabled = true, perLine = 2, fill = "rows", vDir = "down", hDir = "right" }
	local saved = { layouts = { ["1:Other"] = { groupGrid = old } } }
	local world = wow.new({ saved = { TinyTweaksDB = saved } })
	-- When
	world:loadAddon()
	-- Then
	A.eq(world:saved().layouts["1:Other"].groupGrid,
		{ enabled = true, columns = 2, order = "across", corner = "TOPLEFT", hSpacing = 0, vSpacing = 0 })
end)

test("given_migrated_settings_when_loaded_again_then_they_are_unchanged", function()
	-- Given
	local current = { enabled = true, columns = 3, order = "down", corner = "TOPRIGHT", hSpacing = 4, vSpacing = 2 }
	local world = wow.new({ saved = { TinyTweaksDB = { layouts = { ["1:Main"] = { groupGrid = wow.deepcopy(current) } } } } })
	-- When
	world:loadAddon()
	-- Then
	A.eq(world:saved().layouts["1:Main"].groupGrid, current)
end)

test("given_the_addon_loads_before_blizzards_raid_frames_when_they_load_later_then_the_grid_still_works", function()
	-- Given
	local world = wow.new()
	world:loadAddon({ blizzardFirst = false })
	world:loadBlizzardAddon("Blizzard_EditMode")
	world:loadBlizzardAddon("Blizzard_CompactRaidFrames")
	world:setRaidRoster(FULL)
	world:selectSystem(world.container)
	-- When
	toggle(world)
	-- Then
	A.eq(world:raidGrid(), "1 2 3 4 / 5 6 7 8")
end)

test("given_wider_taller_bordered_members_when_the_grid_is_placed_then_cells_use_blizzards_group_size", function()
	-- Given
	local world = setup()
	world:resizeRaidMembers(80, 40, true)
	world:raidLayout()
	world:nextFrame()
	-- When
	toggle(world)
	-- Then: width 80 + 8 border, height 14 + 5 * 40 + 2 border
	A.eq({ world:groupOffset(2) }, { 88, 0 })
	A.eq({ world:groupOffset(5) }, { 0, -(14 + 5 * 40 + 2) })
end)

test("given_a_grid_when_blizzard_refreshes_the_container_size_next_frame_then_it_fits_the_grid", function()
	-- Given
	local world = setup()
	toggle(world)
	-- When
	world:raidLayout()
	world:nextFrame()
	-- Then
	A.eq(world:raidGrid(), "1 2 3 4 / 5 6 7 8")
	A.eq({ world.container:GetSize() }, { 4 * 72, 2 * GROUP_HEIGHT })
end)

test("given_a_grid_when_groups_resize_after_blizzards_re_flow_then_the_grid_is_re_applied_once_next_frame", function()
	-- Given
	local world = setup()
	toggle(world)
	local placements = world:calls(world.groups[5], "SetPoint")
	-- When: every group drops to 3 members, and the groups re-lay out after the container did
	world:setRaidRoster({ 3, 3, 3, 3, 3, 3, 3, 3 }, { groupsAfter = true })
	A.eq({ world:groupOffset(5) }, { 0, -GROUP_HEIGHT }, "placed at the old size first")
	world:nextFrame()
	-- Then
	A.eq({ world:groupOffset(5) }, { 0, -(14 + 3 * 36) })
	A.eq(world:calls(world.groups[5], "SetPoint") - placements, 3, "Blizzard's flow, the grid, one re-apply")
	A.eq(world:nextFrame(), 0, "settled")
end)
