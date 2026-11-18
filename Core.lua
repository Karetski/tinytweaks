local ADDON_NAME, ns = ...

ns.modules = {}

local eventFrame = CreateFrame("Frame")
local handlers = {}

function ns:On(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		eventFrame:RegisterEvent(event)
	end
	table.insert(handlers[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
	for _, fn in ipairs(handlers[event]) do
		fn(event, ...)
	end
end)

local function IsLoaded(addon)
	if C_AddOns and C_AddOns.IsAddOnLoaded then
		return C_AddOns.IsAddOnLoaded(addon)
	end
	return IsAddOnLoaded(addon)
end

-- Runs fn once the given (Blizzard) addon is loaded.
function ns:WhenLoaded(addon, fn)
	if IsLoaded(addon) then
		fn()
		return
	end
	local done = false
	self:On("ADDON_LOADED", function(_, name)
		if not done and name == addon then
			done = true
			fn()
		end
	end)
end

-- Work on protected frames waits for combat to end. Each fn/arg pair runs once, however often it
-- was queued, in the order first queued.
local afterCombat, afterCombatQueued = {}, {}

function ns:RunAfterCombat(fn, arg)
	local queued = afterCombatQueued[fn]
	if not queued then
		queued = {}
		afterCombatQueued[fn] = queued
	end
	if queued[arg] then
		return
	end
	queued[arg] = true
	afterCombat[#afterCombat + 1] = { fn, arg }
end

ns:On("PLAYER_REGEN_ENABLED", function()
	local queue = afterCombat
	afterCombat, afterCombatQueued = {}, {}
	for _, item in ipairs(queue) do
		item[1](item[2])
	end
end)

-- Calls fn(frame) for every Edit Mode system frame: those already registered, and each one Blizzard
-- registers later. Requires Blizzard_EditMode to be loaded.
function ns:ForEachSystemFrame(fn)
	for _, frame in ipairs(EditModeManagerFrame.registeredSystemFrames) do
		fn(frame)
	end
	hooksecurefunc(EditModeManagerFrame, "RegisterSystemFrame", function(_, frame)
		fn(frame)
	end)
end

function ns:Print(...)
	print("|cff66ccffTinyTweaks|r:", ...)
end

-- Per Edit Mode layout storage. Character layouts are also keyed by character,
-- since different characters can have character layouts with the same name.
function ns:GetLayoutKey()
	local info = EditModeManagerFrame and EditModeManagerFrame:GetActiveLayoutInfo()
	if not info then
		return nil
	end
	local key = tostring(info.layoutType) .. ":" .. tostring(info.layoutName)
	if info.layoutType == Enum.EditModeLayoutType.Character then
		key = key .. ":" .. (UnitName("player") or "?") .. "-" .. (GetNormalizedRealmName() or "?")
	end
	return key
end

function ns:GetLayoutDB(create)
	local key = self:GetLayoutKey()
	if not key then
		return nil
	end
	local layout = self.db.layouts[key]
	if not layout and create then
		layout = {}
		self.db.layouts[key] = layout
	end
	return layout
end

ns:On("ADDON_LOADED", function(_, name)
	if name ~= ADDON_NAME then
		return
	end
	TinyTweaksDB = TinyTweaksDB or {}
	TinyTweaksDB.layouts = TinyTweaksDB.layouts or {}
	ns.db = TinyTweaksDB

	for _, module in ipairs(ns.modules) do
		module:Init()
	end
end)
