-- Core: the namespace services every module builds on (events, addon-load waits, per-layout storage).

local wow = require("support.wow")
local A = require("support.assert")

local function loaded(opts)
	local world = wow.new(opts)
	local ns = world:loadAddon()
	return world, ns
end

test("given_no_saved_variables_when_the_addon_loads_then_an_empty_db_with_layouts_is_created", function()
	-- Given
	local world = wow.new()
	-- When
	local ns = world:loadAddon()
	-- Then
	A.eq(world:saved(), { layouts = {} })
	A.truthy(ns.db == world:saved(), "ns.db is the SavedVariables table")
end)

test("given_existing_saved_variables_when_the_addon_loads_then_they_are_kept", function()
	-- Given
	local world = wow.new({ saved = { TinyTweaksDB = { layouts = { ["1:Main"] = { custom = 1 } }, other = true } } })
	-- When
	local ns = world:loadAddon()
	-- Then
	A.eq(ns.db.layouts["1:Main"].custom, 1)
	A.eq(ns.db.other, true)
end)

test("given_two_handlers_for_an_event_when_it_fires_then_both_run_in_registration_order_with_args", function()
	-- Given
	local world, ns = loaded()
	local seen = {}
	ns:On("PLAYER_ENTERING_WORLD", function(event, a, b)
		seen[#seen + 1] = { "first", event, a, b }
	end)
	ns:On("PLAYER_ENTERING_WORLD", function(event, a)
		seen[#seen + 1] = { "second", event, a }
	end)
	-- When
	world:fire("PLAYER_ENTERING_WORLD", true, false)
	-- Then
	A.eq(seen, {
		{ "first", "PLAYER_ENTERING_WORLD", true, false },
		{ "second", "PLAYER_ENTERING_WORLD", true },
	})
end)

test("given_an_addon_already_loaded_when_waiting_for_it_then_the_callback_runs_immediately", function()
	-- Given
	local _, ns = loaded()
	local ran = 0
	-- When
	ns:WhenLoaded("Blizzard_EditMode", function()
		ran = ran + 1
	end)
	-- Then
	A.eq(ran, 1)
end)

test("given_an_addon_not_loaded_yet_when_it_loads_twice_then_the_callback_runs_once", function()
	-- Given
	local world = wow.new()
	local ns = world:loadAddon({ blizzardFirst = false })
	local ran = 0
	ns:WhenLoaded("Blizzard_EditMode", function()
		ran = ran + 1
	end)
	A.eq(ran, 0, "not before the addon loads")
	-- When
	world:loadBlizzardAddon("Blizzard_EditMode")
	world:fire("ADDON_LOADED", "Blizzard_EditMode")
	-- Then
	A.eq(ran, 1)
end)

test("given_an_account_layout_when_getting_the_layout_key_then_it_is_type_and_name", function()
	-- Given
	local world, ns = loaded()
	-- When
	local key = ns:GetLayoutKey()
	-- Then
	A.eq(key, tostring(world.Enum.EditModeLayoutType.Account) .. ":Main")
end)

test("given_a_character_layout_when_getting_the_layout_key_then_it_includes_the_character_and_realm", function()
	-- Given
	local world = wow.new({ player = "Thrall", realm = "Durotan" })
	world.layout.layoutType = world.Enum.EditModeLayoutType.Character
	world.layout.layoutName = "Raid"
	local ns = world:loadAddon()
	-- When
	local key = ns:GetLayoutKey()
	-- Then
	A.eq(key, tostring(world.Enum.EditModeLayoutType.Character) .. ":Raid:Thrall-Durotan")
end)

test("given_edit_mode_not_loaded_when_getting_layout_storage_then_there_is_none", function()
	-- Given
	local world = wow.new()
	local ns = world:loadAddon({ blizzardFirst = false })
	-- When
	local key, layout = ns:GetLayoutKey(), ns:GetLayoutDB(true)
	-- Then
	A.isNil(key)
	A.isNil(layout)
end)

test("given_no_storage_for_the_layout_when_reading_without_create_then_nothing_is_written", function()
	-- Given
	local world, ns = loaded()
	-- When
	local layout = ns:GetLayoutDB(false)
	-- Then
	A.isNil(layout)
	A.eq(world:saved().layouts, {})
end)

test("given_no_storage_for_the_layout_when_reading_with_create_then_one_table_per_layout_is_kept", function()
	-- Given
	local world, ns = loaded()
	-- When
	local first = ns:GetLayoutDB(true)
	local second = ns:GetLayoutDB(true)
	world:switchLayout("Other")
	local other = ns:GetLayoutDB(true)
	-- Then
	A.truthy(first == second, "same table for the same layout")
	A.truthy(first ~= other, "a different table for another layout")
	A.eq(world:saved().layouts, { [ns:GetLayoutKey()] = {}, ["1:Main"] = {} })
end)

test("given_the_addon_when_it_prints_then_the_message_has_the_addon_prefix", function()
	-- Given
	local world, ns = loaded()
	-- When
	ns:Print("hello", 1)
	-- Then
	A.eq(world.printed, { "|cff66ccffTinyTweaks|r: hello 1" })
end)
