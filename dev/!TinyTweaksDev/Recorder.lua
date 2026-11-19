--[[
	TinyTweaks Dev: records what an in-game test session needs, so nothing has to be copied by hand.
	Development only: `make link` installs it next to TinyTweaks; `make dist` and the packager leave
	it out. `make ingame-report` reads what it saves.

	  * Turns on taint logging (taintLog 1). The "!" in the folder name makes the client load this
	    addon before TinyTweaks, so taint from TinyTweaks' own load is logged too.
	  * Copies every Lua error and warning, from a post-hook on ScriptErrorsFrame's
	    DisplayMessageInternal (Blizzard calls it for each one, whether or not the error popup is
	    enabled), and every blocked or forbidden action.
	  * Snapshots the Edit Mode system frames (scale, alpha, point, pin, raw setting values) and the
	    raid groups' positions when Edit Mode opens or closes, a frame is selected, a layout changes,
	    combat starts or ends, and at logout.

	Everything goes to TinyTweaksDevLog, which the client writes on /reload or logout. The session
	records whether it ended in a reload or a logout. Same taint contract as TinyTweaks: post-hooks,
	HookScript and reads only.
]]

local ADDON_NAME = ...

local MAX_SESSIONS = 5
local MAX_ENTRIES = 500
local MAX_TEXT = 4000

local entries = {} -- this session's trail; attached to the saved session once variables load
local seenErrors = {}
local session
local reloading = false

local function Plain(value)
	if issecretvalue and issecretvalue(value) then
		return "<secret>"
	end
	return value
end

local function Round(value)
	value = Plain(value)
	if type(value) ~= "number" then
		return value
	end
	return math.floor(value * 1000 + 0.5) / 1000
end

local function Text(value)
	value = Plain(value)
	if type(value) ~= "string" then
		return value ~= nil and tostring(value) or nil
	end
	return #value > MAX_TEXT and (value:sub(1, MAX_TEXT) .. "...") or value
end

local function Add(entry)
	if #entries >= MAX_ENTRIES then
		if session then
			session.truncated = true
		end
		return
	end
	entry.at = date("%H:%M:%S")
	entries[#entries + 1] = entry
end

-- Snapshots ------------------------------------------------------------------------------

local function SystemKey(frame)
	return tostring(frame.system) .. ":" .. tostring(frame.systemIndex or 0)
end

local function DescribeFrame(frame)
	local info = frame.systemInfo
	local settings = {}
	for _, setting in ipairs(info and info.settings or {}) do
		settings[setting.setting] = Plain(setting.value)
	end
	local point, relativeTo, relativePoint, x, y = frame:GetPoint(1)
	local anchor = info and info.anchorInfo
	return {
		name = frame:GetName(),
		scale = Round(frame:GetScale()),
		alpha = Round(frame:GetAlpha()),
		shown = frame:IsShown(),
		point = point and { point, relativeTo and relativeTo:GetName() or "?", relativePoint, Round(x), Round(y) } or nil,
		pin = anchor and { anchor.point, anchor.relativeTo, anchor.relativePoint, Round(anchor.offsetX), Round(anchor.offsetY) } or nil,
		managed = frame.isManagedFrame or nil,
		default = info and info.isInDefaultPosition or nil,
		settings = settings,
	}
end

local function DescribeGroups()
	local groups = {}
	for i = 1, 8 do
		local group = _G["CompactRaidGroup" .. i]
		if group and group:IsShown() then
			local _, _, _, x, y = group:GetPoint(1)
			groups[i] = { Round(x), Round(y) }
		end
	end
	return next(groups) and groups or nil
end

-- Edit Mode state now, for every system frame or only `onlyFrame`.
local function Snapshot(reason, onlyFrame)
	local manager = EditModeManagerFrame
	local snapshot = { reason = reason, combat = InCombatLockdown() or nil }
	if not manager then
		return snapshot
	end
	local layout = manager:GetActiveLayoutInfo()
	snapshot.layout = layout and (tostring(layout.layoutType) .. ":" .. tostring(layout.layoutName)) or nil
	snapshot.editMode = manager:IsShown() or nil
	snapshot.frames = {}
	for _, frame in ipairs(manager.registeredSystemFrames or {}) do
		if not onlyFrame or frame == onlyFrame then
			local ok, described = pcall(DescribeFrame, frame)
			snapshot.frames[SystemKey(frame)] = ok and described or { error = Text(described) }
		end
	end
	if not onlyFrame then
		snapshot.groups = DescribeGroups()
	end
	return snapshot
end

local function Record(reason, onlyFrame)
	local ok, snapshot = pcall(Snapshot, reason, onlyFrame)
	Add(ok and snapshot or { reason = reason, error = Text(snapshot) })
end

-- Errors -------------------------------------------------------------------------------------

-- Blizzard: ErrorMessageType = 0, WarningMessageType = 1 (Blizzard_ScriptErrorsFrame.lua).
local function OnScriptMessage(_, message, messageType, stack, locals)
	local key = tostring(Plain(message)) .. "\n" .. tostring(Plain(stack))
	local seen = seenErrors[key]
	if seen then
		seen.count = seen.count + 1
		return
	end
	local entry = {
		event = messageType == 1 and "warning" or "error",
		message = Text(message), stack = Text(stack), locals = Text(locals), count = 1,
	}
	seenErrors[key] = entry
	Add(entry)
end

if ScriptErrorsFrame and type(ScriptErrorsFrame.DisplayMessageInternal) == "function" then
	hooksecurefunc(ScriptErrorsFrame, "DisplayMessageInternal", OnScriptMessage)
end

if C_UI and type(C_UI.Reload) == "function" then
	hooksecurefunc(C_UI, "Reload", function()
		reloading = true
	end)
end

-- Session -----------------------------------------------------------------------------------

local function GetCVarValue(name)
	return (C_CVar and C_CVar.GetCVar or GetCVar)(name)
end

local function StartSession()
	TinyTweaksDevLog = TinyTweaksDevLog or {}
	local sessions = TinyTweaksDevLog.sessions or {}
	TinyTweaksDevLog.sessions = sessions
	while #sessions >= MAX_SESSIONS do
		table.remove(sessions, 1)
	end
	local version, build, buildDate, interface = GetBuildInfo()
	session = {
		started = date("%Y-%m-%d %H:%M:%S"),
		build = string.format("%s (%s, %s), interface %s", tostring(version), tostring(build), tostring(buildDate), tostring(interface)),
		entries = entries,
	}
	sessions[#sessions + 1] = session

	if (tonumber(GetCVarValue("taintLog")) or 0) < 1 then
		local ok, err = pcall(C_CVar and C_CVar.SetCVar or SetCVar, "taintLog", "1")
		if not ok then
			session.taintLogError = Text(err)
		end
	end
	session.taintLog = GetCVarValue("taintLog")
	session.scriptErrors = GetCVarValue("scriptErrors")
end

local function OnLogin()
	local addons = {}
	for i = 1, C_AddOns.GetNumAddOns() do
		local name = C_AddOns.GetAddOnInfo(i)
		if C_AddOns.IsAddOnLoaded(i) then
			addons[#addons + 1] = name
		end
	end
	session.addons = addons
	session.tinyTweaksVersion = C_AddOns.GetAddOnMetadata("TinyTweaks", "Version")

	local manager, dialog = EditModeManagerFrame, EditModeSystemSettingsDialog
	if manager then
		manager:HookScript("OnShow", function()
			Record("Edit Mode opened")
		end)
		manager:HookScript("OnHide", function()
			Record("Edit Mode closed")
		end)
	end
	if dialog then
		hooksecurefunc(dialog, "AttachToSystemFrame", function(_, frame)
			Record("selected", frame)
		end)
		hooksecurefunc(dialog, "OnSettingValueChanged", function(self, setting, value)
			local frame = self.attachedToSystem
			Add({ event = "slider", frame = frame and SystemKey(frame), name = frame and frame:GetName(), setting = setting, value = Plain(value) })
		end)
	end
	Record("login")
end

local events = {
	ADDON_LOADED = function(name)
		if name == ADDON_NAME then
			StartSession()
		end
	end,
	PLAYER_LOGIN = OnLogin,
	EDIT_MODE_LAYOUTS_UPDATED = function()
		Record("layouts updated")
	end,
	PLAYER_REGEN_DISABLED = function()
		Record("combat started")
	end,
	PLAYER_REGEN_ENABLED = function()
		Record("combat ended")
	end,
	ADDON_ACTION_BLOCKED = function(addon, func)
		Add({ event = "blocked", addon = Text(addon), func = Text(func) })
	end,
	ADDON_ACTION_FORBIDDEN = function(addon, func)
		Add({ event = "forbidden", addon = Text(addon), func = Text(func) })
	end,
	PLAYER_LOGOUT = function()
		if session then
			local ok, snapshot = pcall(Snapshot, "logout")
			session.final = ok and snapshot or { error = Text(snapshot) }
			session.ended = reloading and "reload" or "logout"
			session.endedAt = date("%Y-%m-%d %H:%M:%S")
		end
	end,
}

local eventFrame = CreateFrame("Frame")
for event in pairs(events) do
	eventFrame:RegisterEvent(event)
end
eventFrame:SetScript("OnEvent", function(_, event, ...)
	events[event](...)
end)
