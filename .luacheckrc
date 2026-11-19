-- luacheck configuration. Run: luacheck .   (CI runs it on every push)
--
-- The addon runs in the WoW client's Lua 5.1 with WoW's globals. Every WoW global the addon reads
-- is listed below on purpose: a new global is a new dependency on Blizzard's API surface and
-- should be added here deliberately, not silenced. The addon writes exactly one global, its
-- SavedVariables table.

std = "lua51"
max_line_length = false
codes = true

exclude_files = {
	"dist/",
	".luarocks/",
	".lua/",
}

ignore = {
	"212/self", -- unused self in methods (ns:On, M:Init) is idiomatic
}

globals = {
	"TinyTweaksDB",
}

read_globals = {
	-- WoW API and Blizzard UI
	"C_AddOns",
	"C_GameRules",
	"C_Timer",
	"CompactRaidFrameContainer",
	"CopyTable",
	"CreateFrame",
	"EditModeManagerFrame",
	"EditModeSystemSettingsDialog",
	"Enum",
	"ERR_NOT_IN_COMBAT",
	"GameTooltip",
	"GameTooltip_Hide",
	"geterrorhandler",
	"GetCursorPosition",
	"GetNormalizedRealmName",
	"hooksecurefunc",
	"InCombatLockdown",
	"InputUtil",
	"IsAddOnLoaded",
	"MinimalSliderWithSteppersMixin",
	"Minimap",
	"NUM_RAID_GROUPS",
	"Settings",
	"UIErrorsFrame",
	"UIParent",
	"UnitName",
}

-- Test code runs on the host (it may use io/os/debug/require) and gets the runner's globals.
files["tests/"] = {
	std = "lua51",
	globals = {},
	read_globals = { "test", "skip", "bench" },
}

-- The dev-only recorder addon (not shipped). It writes its own SavedVariables table and reads the
-- WoW globals below on top of the addon's.
files["dev/"] = {
	globals = { "TinyTweaksDevLog" },
	read_globals = {
		"C_CVar",
		"C_UI",
		"date",
		"GetBuildInfo",
		"GetCVar",
		"issecretvalue",
		"ScriptErrorsFrame",
		"SetCVar",
	},
}
