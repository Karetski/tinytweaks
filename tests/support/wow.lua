--[[
	Simulated WoW client for tests: a small model of the widget API and of the Blizzard UI code
	TinyTweaks hooks (Edit Mode and the raid frame container), detailed enough to load the addon
	from its TOC and drive it the way a player and Blizzard's code do.

	  local wow = require("support.wow")
	  local world = wow.new()          -- fresh client: globals, frames, events, timers, combat state
	  world:loadAddon()                -- Blizzard addons, then TinyTweaks files in TOC order
	  local target = world:addSystemFrame(wow.frames.target())
	  world:selectSystem(target)       -- what clicking the frame in Edit Mode does
	  world:typeInto(world:fineTuneBox("FrameSize"), "87.5")

	The emulator is a MODEL, not ground truth. The Blizzard behavior below was checked against
	Blizzard's UI source for the Forever client, build 1.60.1 (70959), from the forever branch of
	Gethe/wow-ui-source; paths are under Interface/AddOns/. When the client changes, re-check the cited
	functions first (the blizzard-source skill does this).

	Taint contract enforcement
	--------------------------
	Real taint can't be observed outside the client, so the emulator enforces the rules that keep
	TinyTweaks taint-free and fails the test when addon code breaks one:

	  * Blizzard-owned frames and tables are guarded proxies. Writing a field on one from addon code
	    raises "taint: addon wrote <field> on <name>".
	  * Blizzard methods that change Edit Mode or raid layout state raise "taint: addon called
	    <method> on <name>" when called from addon code: on system frames the SetScale, SetPoint and
	    ClearAllPoints overrides, UpdateSystem, UpdateSystemSetting*, UpdateSystemSettingValue,
	    ApplySystemAnchor, SnapToFrame, BreakFrameSnap, OnSystemPositionChange and the snap
	    bookkeeping; on the manager and dialog UpdateSystems, InitSystemAnchors,
	    OnSystemSettingChange, OnSystemPositionChange, UpdateRaidContainerFlow, AttachToSystemFrame,
	    UpdateSettings, UpdateDialog, OnSettingValueChanged and RegisterSystemFrame; on the raid
	    container and groups LayoutFrames and updateLayoutFunc; and the globals
	    CompactRaidGroup_GenerateForGroup and ManageFramePositions. SetScript on a Blizzard frame is a
	    violation too.
	  * Creating a frame parented to EditModeSystemSettingsDialog (a layout frame that iterates its
	    children) raises "taint: addon parented a frame to ...".
	  * Moving, scaling, resizing, showing or hiding a protected frame from addon code in combat
	    raises "blocked: ..." (ADDON_ACTION_BLOCKED in the client).

	"Addon code" means: anything not running inside world:blizzard(). Emulator-side Blizzard code
	runs inside it; hooksecurefunc post-hooks and script handlers run outside it, like in the client.
	Errors raised in hooks, scripts, timers and event handlers are recorded, not propagated (the
	client reports them and carries on); wow.finish(), called by the runner after every test, fails
	the test if any error or violation was recorded and not taken with world:takeErrors() /
	world:takeViolations().

	Blizzard behavior modelled (build 1.60.1)
	----------------------------------------
	ET = Blizzard_EditMode/Shared/EditModeSystemTemplates.lua, EM = .../EditModeManager.lua,
	ED = .../EditModeDialogs.lua, C = Blizzard_CompactRaidFrames/Blizzard_CompactRaidFrameContainer.lua,
	G = Blizzard_UnitFrame/Shared/CompactRaidGroup.lua.

	  1. System frames replace SetScale, SetPoint and ClearAllPoints with Blizzard Lua (ET:9-17); the
	     widget methods stay reachable as SetScaleBase, SetPointBase and ClearAllPointsBase. The
	     SetScale override keeps the frame in place by scaling every point's offsets by old/new through
	     the SetPoint override, and re-runs ManageFramePositions for a managed frame in its default
	     position (ET:117). The SetPoint override records the snap and sets
	     EditModeManagerFrame.editModeSystemAnchorDirty (ET:147, EM:1039). Addon code calling the
	     overrides is a taint violation; the *Base methods are plain widget calls.
	  2. ApplySystemAnchor (ET:350): a managed frame in its default position is placed by its container
	     (modelled as its default point); otherwise ClearAllPoints, then anchorInfo (and anchorInfo2)
	     with offsets divided by the frame's scale, through the overrides. The cast bar re-applies its
	     size afterwards (ET:1853).
	  3. UpdateSystem (ET:385): settings diff marks changed ones dirty, then ApplySystemAnchor, then the
	     dialog update, then UpdateSystemSetting<Name> for each dirty setting. A layout load, layout
	     switch or Revert All runs InitSystemAnchors, then UpdateSystems (EM:1010, EM:1479-1483); the
	     dialog's per-frame Revert calls frame:UpdateSystem directly (EM:407).
	  4. Sliders: raw = (value - min) / step, unrounded; display = Clamp(raw * step + min, min, max).
	     GetSettingValue returns 0 before IsInitialized() or for a setting the frame lacks (ET:483).
	     Moving a slider: dialog:OnSettingValueChanged → manager:OnSystemSettingChange →
	     frame:UpdateSystemSettingValue, which acts only when the raw step changes: it stores it, marks it
	     dirty, refreshes the dialog (UpdateSettings), then runs UpdateSystemSetting<Name>
	     (ED:659, EM:400, ET:268, ET:409).
	  5. The size, scale and opacity handlers TinyTweaks supports are one SetScale or SetAlpha of
	     value / 100 each (ET:2578, 2681, 2751, 2784, 2788, 2852, 2898, 3822, 3850, 1629, 1586, 2141, 3001,
	     3518). The party frame skips its size while the ForcedPartyFrameScale game rule is active
	     (Blizzard_UnitFrame/Shared/PartyFrame.lua:28).
	  6. AttachToSystemFrame sets attachedToSystem, runs UpdateDialog (UpdateSettings first) and shows
	     the dialog (ED:537). UpdateSettings does nothing for another frame; it releases the slider
	     frames except one whose thumb is being dragged, re-acquires the rest, sets .setting and the
	     value text, and re-shows the label (ED:598, MinimalSlider.lua:160-172). The slider pool is a
	     secure pool: EnumerateActive yields (frame, true) in next order.
	  7. Dragging: magnetism calls SnapToFrame once per snap (EditModeUtil.lua:444-465), then
	     OnSystemPositionChange stores GetPoint(1) at 1.0 scale into anchorInfo IN PLACE, with
	     relativeTo as a frame NAME, updates anchorInfo2 only if it exists, and clears
	     isInDefaultPosition only when the anchor changed; the frame isn't moved (EM:316, EM:372).
	     Arrow keys re-pin to UIParent's top left without snapping (ET:737 BreakFrameSnap).
	  8. MinimalSliderWithSteppers:Init sets the value before installing its OnValueChanged script, so
	     the first Init fires nothing and a later Init fires through the previous script when the value
	     changes (MinimalSlider.lua:126).
	  9. Raid container, discrete mode: LayoutFrames hides what it flowed, re-adds only used groups
	     (generating them on first use), flows at 3000x3000, sizes to its shown children, and resizes
	     from the visible bounds one frame later (C:233-345, C:162-192). flowMaxPerLine is 5 in the
	     separate-groups modes (EM:483-488). A group's size: member width (+8 with border) by 14 + member
	     height x max(members, 1) (+2 with border) (G:95). UpdateRaidContainerFlow re-flows twice at the
	     current size, then LayoutFrames if ready (EM:477).
	 10. On a roster change existing groups re-lay out on their own GROUP_ROSTER_UPDATE (G:8-15) and the
	     container re-lays out on its own; the order isn't fixed (C:266-267), so setRaidRoster can run the
	     groups after the container. The container's OnSizeChanged only updates its border; resizing it
	     doesn't re-flow.

	Still unverified (client C code, not in the Lua source):
	  * Which widget calls combat lockdown refuses on protected frames. Modelled from warcraft.wiki.gg
	    (Widget_API #secureframe): SetPoint, ClearAllPoints, SetAllPoints, SetScale, SetSize, SetWidth,
	    SetHeight, Show, Hide, SetShown; SetAlpha is allowed.
	  * Taint itself: the guards above encode the rules, not the client's taint tracking.
	  * Enum values (the addon only looks names up; the names follow the source).
]]

local wow = {}

local live = {}

local function pack(...)
	return { n = select("#", ...), ... }
end

local function deepcopy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in pairs(value) do
		copy[deepcopy(k)] = deepcopy(v)
	end
	return copy
end
wow.deepcopy = deepcopy

local function readFile(path)
	local f = assert(io.open(path, "r"))
	local text = f:read("*a")
	f:close()
	return text
end

-- Enums ------------------------------------------------------------------------------------
-- Values are arbitrary but distinct; TinyTweaks only looks them up by name.

local function newEnum()
	return {
		EditModeSystem = {
			ActionBar = 0, CastBar = 1, Minimap = 2, UnitFrame = 3, EncounterBar = 4, ExtraAbilities = 5,
			AuraFrame = 6, TalkingHeadFrame = 7, ChatFrame = 8, VehicleLeaveButton = 9, LootFrame = 10,
			HudTooltip = 11, ObjectiveTracker = 12, MicroMenu = 13, Bags = 14, StatusTrackingBar = 15,
			DurabilityFrame = 16, TimerBars = 17, VehicleSeatIndicator = 18, ArchaeologyBar = 19,
			CooldownViewer = 20, PersonalResourceDisplay = 21, GroupFinder = 22, LossOfControl = 23,
			SwingTimer = 24,
		},
		EditModeUnitFrameSystemIndices = { Player = 1, Target = 2, Focus = 3, Party = 4, Raid = 5, Boss = 6, Arena = 7, Pet = 8 },
		EditModeLayoutType = { Preset = 0, Account = 1, Character = 2, Server = 3 },
		EditModeSettingDisplayType = { Dropdown = 0, Checkbox = 1, Slider = 2 },
		EditModeActionBarSetting = { Orientation = 0, NumRows = 1, NumIcons = 2, IconSize = 3, IconPadding = 4 },
		EditModeUnitFrameSetting = { HidePortrait = 0, UseLargerFrame = 5, FrameWidth = 8, FrameHeight = 9, FrameSize = 13, Opacity = 20 },
		EditModeCastBarSetting = { BarSize = 0, LockToPlayerFrame = 1, ShowCastTime = 2 },
		EditModeBagsSetting = { Orientation = 0, Direction = 1, Size = 2 },
		EditModeDurabilityFrameSetting = { Size = 0 },
		EditModeTimerBarsSetting = { Size = 0 },
		EditModeVehicleSeatIndicatorSetting = { Size = 0 },
		EditModeArchaeologyBarSetting = { Size = 0 },
		EditModeGroupFinderSetting = { Size = 0 },
		EditModeLossOfControlSetting = { Size = 0 },
		EditModeSwingTimerSetting = { Scale = 0, Opacity = 1 },
		EditModeAuraFrameSetting = { Orientation = 0, IconSize = 3, Opacity = 6 },
		EditModeCooldownViewerSetting = { IconSize = 2, Opacity = 4 },
		EditModePersonalResourceDisplaySetting = { Opacity = 5 },
		GameRule = { ForcedPartyFrameScale = 40 },
	}
end

local SETTING_ENUMS = {
	ActionBar = "EditModeActionBarSetting",
	UnitFrame = "EditModeUnitFrameSetting",
	CastBar = "EditModeCastBarSetting",
	Bags = "EditModeBagsSetting",
	DurabilityFrame = "EditModeDurabilityFrameSetting",
	TimerBars = "EditModeTimerBarsSetting",
	VehicleSeatIndicator = "EditModeVehicleSeatIndicatorSetting",
	ArchaeologyBar = "EditModeArchaeologyBarSetting",
	GroupFinder = "EditModeGroupFinderSetting",
	LossOfControl = "EditModeLossOfControlSetting",
	SwingTimer = "EditModeSwingTimerSetting",
	AuraFrame = "EditModeAuraFrameSetting",
	CooldownViewer = "EditModeCooldownViewerSetting",
	PersonalResourceDisplay = "EditModePersonalResourceDisplaySetting",
}

local STDLIB = {
	"math", "string", "table", "pairs", "ipairs", "type", "tostring", "tonumber", "select", "next",
	"unpack", "pcall", "xpcall", "error", "assert", "setmetatable", "getmetatable", "rawget", "rawset",
	"rawequal",
}

local BLIZZARD_ADDONS = { "Blizzard_EditMode", "Blizzard_CompactRaidFrames" }

local COSMETIC = {
	"SetJustifyH", "SetJustifyV", "SetWordWrap", "SetHighlightTexture", "SetTexture", "SetAutoFocus",
	"SetCursorPosition", "SetMaxLetters",
}

-- Widget calls refused on a protected frame in combat (#secureframe on warcraft.wiki.gg Widget_API);
-- SetAlpha isn't restricted.
local PROTECTED_OPS = {
	SetPoint = true, ClearAllPoints = true, SetAllPoints = true, SetScale = true, SetSize = true,
	SetWidth = true, SetHeight = true, Show = true, Hide = true, SetShown = true,
}

-- World ---------------------------------------------------------------------------------------

local World = {}
World.__index = World

function wow.new(opts)
	opts = opts or {}
	local world = setmetatable({
		depth = 0,
		combat = false,
		ws = {},
		backing = {},
		events = {},
		timers = {},
		errors = {},
		violations = {},
		printed = {},
		uiErrors = {},
		created = {},
		globalWrites = {},
		loaded = {},
		systemFrames = {},
		player = opts.player or "Tester",
		realm = opts.realm or "TestRealm",
		savedInit = opts.saved and deepcopy(opts.saved) or nil,
	}, World)
	world.Enum = newEnum()
	world.layout = {
		layoutType = opts.layoutType or world.Enum.EditModeLayoutType.Account,
		layoutName = opts.layoutName or "Main",
	}
	world:buildMethods()
	world:buildGlobals()
	live[#live + 1] = world
	return world
end

-- Fails if any world created since the last call recorded an error or violation.
function wow.finish()
	local worlds = live
	live = {}
	local problems = {}
	for _, world in ipairs(worlds) do
		for _, v in ipairs(world.violations) do
			problems[#problems + 1] = "violation: " .. tostring(v)
		end
		for _, e in ipairs(world.errors) do
			problems[#problems + 1] = "error: " .. tostring(e)
		end
	end
	if #problems > 0 then
		error("simulated client recorded problems:\n  " .. table.concat(problems, "\n  "), 0)
	end
end

function World:recordError(err)
	self.errors[#self.errors + 1] = tostring(err)
end

function World:violation(message)
	self.violations[#self.violations + 1] = message
	error(message, 3)
end

function World:takeErrors()
	local errors = self.errors
	self.errors = {}
	return errors
end

-- Returns and clears recorded violations, and the errors they raised.
function World:takeViolations()
	local violations = self.violations
	self.violations = {}
	local kept = {}
	for _, e in ipairs(self.errors) do
		if not (e:find("taint:", 1, true) or e:find("blocked:", 1, true)) then
			kept[#kept + 1] = e
		end
	end
	self.errors = kept
	return violations
end

-- Runs fn as Blizzard code: guarded methods and fields are open to it.
function World:blizzard(fn, ...)
	self.depth = self.depth + 1
	local result = pack(pcall(fn, ...))
	self.depth = self.depth - 1
	if not result[1] then
		error(result[2], 0)
	end
	return unpack(result, 2, result.n)
end

-- Runs addon code (hooks, scripts, timers, event handlers); errors are recorded, not raised.
function World:addonCall(fn, ...)
	local saved = self.depth
	self.depth = 0
	local ok, err = pcall(fn, ...)
	self.depth = saved
	if not ok then
		self:recordError(err)
	end
	return ok
end

function World:isBlizzard()
	return self.depth > 0
end

function World:state(obj)
	return self.ws[obj]
end

function World:calls(obj, method)
	return self.ws[obj].calls[method] or 0
end

-- Writes a field on a Blizzard object with Blizzard's rights.
function World:bset(obj, key, value)
	rawset(self.backing[obj] or obj, key, value)
end

-- Widgets -------------------------------------------------------------------------------------

function World:newWidget(kind, name, parent, blizzard)
	local world = self
	local methods = assert(self.methods[kind], "unknown widget kind " .. tostring(kind))
	local obj
	if blizzard then
		local backing = setmetatable({}, { __index = methods })
		obj = setmetatable({}, {
			__index = backing,
			__newindex = function(_, key, value)
				if world.depth == 0 then
					world:violation("taint: addon wrote " .. tostring(key) .. " on " .. (name or kind))
				end
				rawset(backing, key, value)
			end,
		})
		self.backing[obj] = backing
	else
		obj = setmetatable({}, { __index = methods })
	end
	self.ws[obj] = {
		kind = kind,
		name = name,
		parent = parent,
		blizzard = blizzard or false,
		points = {},
		scale = 1,
		alpha = 1,
		width = 0,
		height = 0,
		shown = true,
		enabled = true,
		scripts = {},
		scriptHooks = {},
		children = {},
		calls = {},
	}
	if parent then
		local ps = self.ws[parent]
		ps.children[#ps.children + 1] = obj
	end
	if name then
		rawset(self.G, name, obj)
	end
	return obj
end

-- Defines a Blizzard method on a Blizzard object. Guarded methods can't be called from addon code.
function World:defineMethod(obj, name, impl, guarded)
	local world = self
	rawset(self.backing[obj], name, function(this, ...)
		if guarded and world.depth == 0 then
			local s = world.ws[this] or world.ws[obj]
			world:violation("taint: addon called " .. name .. " on " .. (s and s.name or "a Blizzard object"))
		end
		return world:blizzard(impl, this, ...)
	end)
end

function World:runScript(obj, name, ...)
	local s = self.ws[obj]
	local handler = s.scripts[name]
	if handler then
		self:addonCall(handler, obj, ...)
	end
	local hooks = s.scriptHooks[name]
	if hooks then
		for _, hook in ipairs(hooks) do
			self:addonCall(hook, obj, ...)
		end
	end
end

function World:buildMethods()
	local world = self
	local function st(o)
		return world.ws[o]
	end
	local function count(s, op)
		s.calls[op] = (s.calls[op] or 0) + 1
	end
	local function guardProtected(o, op)
		local s = st(o)
		if s.protected and world.combat and world.depth == 0 and PROTECTED_OPS[op] then
			world:violation("blocked: addon called " .. op .. " on protected " .. (s.name or s.kind) .. " in combat")
		end
		count(s, op)
	end
	local function resolve(rel)
		if type(rel) == "string" then
			return world.G[rel]
		end
		return rel
	end

	local region = {}
	function region.SetPoint(o, point, a, b, c, d)
		guardProtected(o, "SetPoint")
		local s = st(o)
		local relTo, relPoint, x, y
		if a == nil or type(a) == "number" then
			relTo, relPoint, x, y = s.parent, point, a or 0, b or 0
		elseif type(b) == "string" then
			relTo, relPoint, x, y = resolve(a), b, c or 0, d or 0
		else
			relTo, relPoint, x, y = resolve(a), point, b or 0, c or 0
		end
		for _, p in ipairs(s.points) do
			if p[1] == point then
				p[2], p[3], p[4], p[5] = relTo, relPoint, x, y
				return
			end
		end
		s.points[#s.points + 1] = { point, relTo, relPoint, x, y }
	end
	function region.ClearAllPoints(o)
		guardProtected(o, "ClearAllPoints")
		st(o).points = {}
	end
	function region.SetAllPoints(o, rel)
		guardProtected(o, "SetAllPoints")
		local s = st(o)
		rel = resolve(rel) or s.parent
		s.points = { { "TOPLEFT", rel, "TOPLEFT", 0, 0 }, { "BOTTOMRIGHT", rel, "BOTTOMRIGHT", 0, 0 } }
	end
	function region.GetPoint(o, index)
		local p = st(o).points[index or 1]
		if p then
			return p[1], p[2], p[3], p[4], p[5]
		end
	end
	function region.GetNumPoints(o)
		return #st(o).points
	end
	-- Rect in the frame's own units (bottom-left origin), for frames whose first point is on UIParent.
	local FX = { LEFT = 0, CENTER = 0.5, RIGHT = 1, TOP = 0.5, BOTTOM = 0.5 }
	local FY = { TOP = 1, CENTER = 0.5, BOTTOM = 0, LEFT = 0.5, RIGHT = 0.5 }
	local function fraction(point)
		local v = point:match("^(TOP)") or point:match("^(BOTTOM)")
		local h = point:match("(LEFT)$") or point:match("(RIGHT)$")
		return h and FX[h] or 0.5, v and FY[v] or 0.5
	end
	local function rect(o)
		local s = st(o)
		local p = assert(s.points[1], "emulator: frame has no point")
		local ui = world.UIParent
		assert(p[2] == ui, "emulator: geometry only for frames anchored to UIParent")
		local scale = s.scale
		local rfx, rfy = fraction(p[3])
		local pfx, pfy = fraction(p[1])
		local us = st(ui)
		local ax, ay = rfx * us.width + p[4] * scale, rfy * us.height + p[5] * scale
		local left = ax - pfx * s.width * scale
		local bottom = ay - pfy * s.height * scale
		return left / scale, bottom / scale, s.width, s.height
	end
	function region.GetLeft(o)
		return (rect(o))
	end
	function region.GetBottom(o)
		return select(2, rect(o))
	end
	function region.GetTop(o)
		local _, bottom, _, height = rect(o)
		return bottom + height
	end
	function region.GetRight(o)
		local left, _, width = rect(o)
		return left + width
	end
	function region.SetSize(o, w, h)
		guardProtected(o, "SetSize")
		local s = st(o)
		s.width, s.height = w, h
	end
	function region.SetWidth(o, w)
		guardProtected(o, "SetWidth")
		st(o).width = w
	end
	function region.SetHeight(o, h)
		guardProtected(o, "SetHeight")
		st(o).height = h
	end
	function region.GetWidth(o)
		return st(o).width
	end
	function region.GetHeight(o)
		return st(o).height
	end
	function region.GetSize(o)
		local s = st(o)
		return s.width, s.height
	end
	function region.Show(o)
		guardProtected(o, "Show")
		local s = st(o)
		if not s.shown then
			s.shown = true
			world:runScript(o, "OnShow")
		end
	end
	function region.Hide(o)
		guardProtected(o, "Hide")
		local s = st(o)
		if s.shown then
			s.shown = false
			world:runScript(o, "OnHide")
		end
	end
	function region.SetShown(o, shown)
		guardProtected(o, "SetShown")
		if shown then
			o:Show()
		else
			o:Hide()
		end
	end
	function region.IsShown(o)
		return st(o).shown
	end
	function region.IsVisible(o)
		local s = st(o)
		if not s.shown then
			return false
		end
		return s.parent == nil or s.parent:IsVisible()
	end
	function region.SetAlpha(o, a)
		count(st(o), "SetAlpha")
		st(o).alpha = a
	end
	function region.GetAlpha(o)
		return st(o).alpha
	end
	function region.GetParent(o)
		return st(o).parent
	end
	function region.GetName(o)
		return st(o).name
	end
	function region.GetDebugName(o)
		return st(o).name or ("<anonymous " .. st(o).kind .. ">")
	end
	function region.GetObjectType(o)
		return st(o).kind
	end
	function region.IsProtected(o)
		return st(o).protected or false
	end
	for _, name in ipairs(COSMETIC) do
		region[name] = function() end
	end

	local function extend(base, extra)
		local t = {}
		for k, v in pairs(base) do
			t[k] = v
		end
		for k, v in pairs(extra or {}) do
			t[k] = v
		end
		return t
	end

	local fontString = extend(region, {
		SetText = function(o, text)
			st(o).text = text ~= nil and tostring(text) or nil
		end,
		GetText = function(o)
			return st(o).text
		end,
		SetFontObject = function(o, font)
			st(o).font = font
		end,
		GetFontObject = function(o)
			return st(o).font
		end,
		SetTextColor = function(o, r, g, b, a)
			st(o).textColor = { r, g, b, a }
		end,
		GetTextColor = function(o)
			local c = st(o).textColor or { 1, 1, 1, 1 }
			return c[1], c[2], c[3], c[4]
		end,
	})

	local texture = extend(region, {
		SetColorTexture = function(o, r, g, b, a)
			st(o).color = { r, g, b, a }
		end,
	})

	local frame = extend(region, {
		SetScale = function(o, scale)
			guardProtected(o, "SetScale")
			st(o).scale = scale
		end,
		GetScale = function(o)
			return st(o).scale
		end,
		GetEffectiveScale = function(o)
			local s = st(o)
			return s.scale * (s.parent and s.parent:GetEffectiveScale() or 1)
		end,
		SetScript = function(o, name, fn)
			local s = st(o)
			if s.blizzard and world.depth == 0 then
				world:violation("taint: addon called SetScript(" .. name .. ") on " .. (s.name or s.kind))
			end
			s.scripts[name] = fn
		end,
		GetScript = function(o, name)
			return st(o).scripts[name]
		end,
		HookScript = function(o, name, fn)
			local hooks = st(o).scriptHooks
			hooks[name] = hooks[name] or {}
			table.insert(hooks[name], fn)
		end,
		RegisterEvent = function(o, event)
			local list = world.events[event]
			if not list then
				list = {}
				world.events[event] = list
			end
			for _, f in ipairs(list) do
				if f == o then
					return
				end
			end
			list[#list + 1] = o
		end,
		UnregisterEvent = function(o, event)
			local list = world.events[event] or {}
			for i, f in ipairs(list) do
				if f == o then
					table.remove(list, i)
					return
				end
			end
		end,
		CreateFontString = function(o, name, _, font)
			local fs = world:newWidget("FontString", name, o, st(o).blizzard and world.depth > 0)
			st(fs).font = font
			return fs
		end,
		CreateTexture = function(o, name)
			return world:newWidget("Texture", name, o, st(o).blizzard and world.depth > 0)
		end,
		SetFrameStrata = function(o, strata)
			st(o).strata = strata
		end,
		GetFrameStrata = function(o)
			return st(o).strata or "MEDIUM"
		end,
		SetFrameLevel = function(o, level)
			st(o).level = level
		end,
		GetFrameLevel = function(o)
			return st(o).level or 1
		end,
		EnableMouse = function(o, enabled)
			st(o).mouse = enabled
		end,
		SetMouseMotionEnabled = function(o, enabled)
			st(o).mouseMotion = enabled
		end,
	})

	local function enabling(t)
		t.SetEnabled = function(o, enabled)
			st(o).enabled = not not enabled
		end
		t.Enable = function(o)
			st(o).enabled = true
		end
		t.Disable = function(o)
			st(o).enabled = false
		end
		t.IsEnabled = function(o)
			return st(o).enabled
		end
		return t
	end

	local button = enabling(extend(frame, {
		GetFontString = function(o)
			local s = st(o)
			if not s.fontString then
				s.fontString = world:newWidget("FontString", nil, o, s.blizzard)
			end
			return s.fontString
		end,
		SetText = function(o, text)
			o:GetFontString():SetText(text)
		end,
		GetText = function(o)
			return o:GetFontString():GetText()
		end,
		LockHighlight = function(o)
			st(o).highlightLocked = true
		end,
		UnlockHighlight = function(o)
			st(o).highlightLocked = false
		end,
	}))

	local checkButton = extend(button, {
		SetChecked = function(o, checked)
			st(o).checked = not not checked
		end,
		GetChecked = function(o)
			return st(o).checked or false
		end,
	})

	local editBox = enabling(extend(frame, {
		SetText = function(o, text)
			st(o).text = tostring(text)
		end,
		GetText = function(o)
			return st(o).text or ""
		end,
		SetFontObject = function(o, font)
			st(o).font = font
		end,
		SetFocus = function(o)
			if world.focused and world.focused ~= o then
				world.focused:ClearFocus()
			end
			world.focused = o
			st(o).focus = true
		end,
		ClearFocus = function(o)
			local s = st(o)
			if s.focus then
				s.focus = false
				if world.focused == o then
					world.focused = nil
				end
				world:runScript(o, "OnEditFocusLost")
			end
		end,
		HasFocus = function(o)
			return st(o).focus or false
		end,
	}))

	-- The thumb part of MinimalSliderWithSteppersTemplate.
	local slider = enabling(extend(frame, {
		IsDraggingThumb = function(o)
			return st(o).dragging or false
		end,
	}))

	local tooltip = extend(frame, {
		SetOwner = function(o, owner)
			local s = st(o)
			s.owner, s.lines = owner, {}
		end,
		SetText = function(o, text)
			st(o).lines = { text }
		end,
		AddLine = function(o, text)
			local s = st(o)
			s.lines = s.lines or {}
			s.lines[#s.lines + 1] = text
		end,
	})

	local messageFrame = extend(frame, {
		AddMessage = function(_, message)
			world.uiErrors[#world.uiErrors + 1] = message
		end,
	})

	self.methods = {
		Region = region,
		FontString = fontString,
		Texture = texture,
		Frame = frame,
		Button = button,
		CheckButton = checkButton,
		EditBox = editBox,
		Slider = slider,
		GameTooltip = tooltip,
		MessageFrame = messageFrame,
	}
end

-- Templates applied to addon-created frames.
function World:applyTemplate(obj, template)
	local world = self
	if template == nil or template == "InputBoxTemplate" or template == "UIPanelButtonTemplate"
		or template == "DialogBorderTranslucentTemplate" then
		return
	end
	if template == "UICheckButtonTemplate" then
		obj.Text = self:newWidget("FontString", nil, obj, false)
		return
	end
	if template == "MinimalSliderWithSteppersTemplate" then
		local thumb = self:newWidget("Slider", nil, obj, false)
		local s = self.ws[obj]
		s.slider = { value = 0, min = 0, max = 1, steps = 1, callbacks = {}, thumb = thumb }
		obj.Slider = thumb
		local function fire(value)
			for _, cb in ipairs(s.slider.callbacks) do
				world:addonCall(cb.fn, cb.owner, value)
			end
		end
		s.slider.fire = fire
		function obj.RegisterCallback(_, event, fn, owner)
			assert(event == "OnValueChanged", "unknown slider event " .. tostring(event))
			table.insert(s.slider.callbacks, { fn = fn, owner = owner })
		end
		-- MinimalSlider.lua:126: Init sets the value before it installs its OnValueChanged script, so
		-- the first Init fires nothing; a later Init fires through the script the previous one left.
		function obj.Init(_, value, minValue, maxValue, steps)
			local sl = s.slider
			local changed = sl.value ~= value
			local scripted = sl.scripted
			sl.value, sl.min, sl.max, sl.steps = value, minValue, maxValue, steps
			sl.scripted = true
			if changed and scripted then
				fire(value)
			end
		end
		function obj.GetValue()
			return s.slider.value
		end
		function obj.SetEnabled(_, enabled)
			s.enabled = not not enabled
			thumb:SetEnabled(enabled)
		end
		function obj.IsEnabled()
			return s.enabled
		end
		return
	end
	error("emulator: unknown template " .. tostring(template))
end

-- Globals ------------------------------------------------------------------------------------

function World:buildGlobals()
	local world = self
	local G = {}
	self.G = G
	for _, name in ipairs(STDLIB) do
		G[name] = _G[name]
	end
	G._G = G
	setmetatable(G, {
		__newindex = function(t, key, value)
			world.globalWrites[key] = true
			rawset(t, key, value)
		end,
	})

	local function set(name, value)
		rawset(G, name, value)
	end

	set("print", function(...)
		local parts = {}
		for i = 1, select("#", ...) do
			parts[#parts + 1] = tostring((select(i, ...)))
		end
		world.printed[#world.printed + 1] = table.concat(parts, " ")
	end)
	set("Enum", self.Enum)
	set("NUM_RAID_GROUPS", 8)
	set("ERR_NOT_IN_COMBAT", "You can't do that while in combat")
	set("CopyTable", deepcopy)
	set("UnitName", function(unit)
		if unit == "player" then
			return world.player
		end
	end)
	set("GetNormalizedRealmName", function()
		return world.realm
	end)
	set("geterrorhandler", function()
		return function(err)
			world:recordError(err)
		end
	end)
	set("InCombatLockdown", function()
		return world.combat
	end)
	set("InputUtil", {
		IsGamepadUIEnabled = function()
			return false
		end,
	})
	set("MinimalSliderWithSteppersMixin", { Event = { OnValueChanged = "OnValueChanged" } })
	world.gameRules = {}
	set("C_GameRules", {
		IsGameRuleActive = function(rule)
			return world.gameRules[rule] == true
		end,
	})
	-- UIParentPanelManager.lua:836. The emulator re-places managed frames in their default position.
	set("ManageFramePositions", function()
		if world.depth == 0 then
			world:violation("taint: addon called ManageFramePositions")
		end
		world:blizzard(function()
			world.managedLayouts = (world.managedLayouts or 0) + 1
			for _, frame in ipairs(world.systemFrames) do
				if frame.isManagedFrame and frame:IsInDefaultPosition() then
					world:placeManaged(frame)
				end
			end
		end)
	end)
	set("C_AddOns", {
		IsAddOnLoaded = function(name)
			local loaded = world.loaded[name] == true
			return loaded, loaded
		end,
	})
	set("C_Timer", {
		After = function(_, fn)
			world.timers[#world.timers + 1] = fn
		end,
	})
	set("hooksecurefunc", function(a, b, c)
		local tbl, name, hook
		if type(a) == "string" then
			tbl, name, hook = G, a, b
		else
			tbl, name, hook = a, b, c
		end
		local original = tbl[name]
		if type(original) ~= "function" then
			error("hooksecurefunc: " .. tostring(name) .. " is not a function", 2)
		end
		local wrapper = function(...)
			local result = pack(original(...))
			world:addonCall(hook, ...)
			return unpack(result, 1, result.n)
		end
		rawset(world.backing[tbl] or tbl, name, wrapper)
	end)
	set("CreateFrame", function(kind, name, parent, template)
		if kind ~= "Frame" and kind ~= "Button" and kind ~= "CheckButton" and kind ~= "EditBox" then
			error("emulator: CreateFrame kind " .. tostring(kind) .. " not modelled", 2)
		end
		if parent and world.ws[parent] and world.ws[parent].iteratesChildren and world.depth == 0 then
			world:violation("taint: addon parented a frame to " .. (world.ws[parent].name or "a Blizzard layout frame"))
		end
		local obj = world:newWidget(kind, name, parent, world.depth > 0)
		world:applyTemplate(obj, template)
		world.created[#world.created + 1] = obj
		return obj
	end)

	local uiParent = self:newWidget("Frame", "UIParent", nil, true)
	self.ws[uiParent].width, self.ws[uiParent].height = 1920, 1080
	self.UIParent = uiParent

	local gameTooltip = self:newWidget("GameTooltip", "GameTooltip", uiParent, true)
	self.ws[gameTooltip].shown = false
	self.GameTooltip = gameTooltip
	set("GameTooltip_Hide", function()
		gameTooltip:Hide()
	end)
	self:newWidget("MessageFrame", "UIErrorsFrame", uiParent, true)
end

-- Events, timers, combat ----------------------------------------------------------------------

function World:fire(event, ...)
	local list = self.events[event]
	if not list then
		return
	end
	local copy = {}
	for i, f in ipairs(list) do
		copy[i] = f
	end
	for _, f in ipairs(copy) do
		self:runScript(f, "OnEvent", event, ...)
	end
end

-- Blizzard's RunNextFrame: a next-frame callback that runs as Blizzard code.
function World:runNextFrame(fn)
	self.timers[#self.timers + 1] = { blizzard = fn }
end

-- Runs the next-frame callbacks queued so far (C_Timer.After(0) and Blizzard's RunNextFrame), like
-- the next rendered frame does. Returns how many ran.
function World:nextFrame()
	local queue = self.timers
	self.timers = {}
	for _, entry in ipairs(queue) do
		if type(entry) == "table" then
			self:blizzard(entry.blizzard)
		else
			self:addonCall(entry)
		end
	end
	return #queue
end

function World:setCombat(inCombat)
	if inCombat == self.combat then
		return
	end
	if inCombat then
		self:fire("PLAYER_REGEN_DISABLED")
		self.combat = true
	else
		self.combat = false
		self:fire("PLAYER_REGEN_ENABLED")
	end
end

-- Loading ---------------------------------------------------------------------------------------

function wow.tocFiles(path)
	local files = {}
	for line in readFile(path or "TinyTweaks.toc"):gmatch("[^\r\n]+") do
		line = line:match("^%s*(.-)%s*$")
		if line ~= "" and not line:find("^#") then
			files[#files + 1] = (line:gsub("\\", "/"))
		end
	end
	return files
end

function World:loadBlizzardAddon(name)
	if self.loaded[name] then
		return
	end
	self:blizzard(function()
		if name == "Blizzard_EditMode" then
			self:createEditMode()
		elseif name == "Blizzard_CompactRaidFrames" then
			self:createRaidContainer()
		else
			error("emulator: Blizzard addon " .. name .. " not modelled")
		end
	end)
	self.loaded[name] = true
	self:fire("ADDON_LOADED", name)
end

-- Loads TinyTweaks like the client: files in TOC order with (addonName, ns), then SavedVariables,
-- then ADDON_LOADED. opts.blizzardFirst = false loads it before the Blizzard addons.
-- opts.replace = { ["File.lua"] = "/path/to/other.lua" } loads another copy of a TOC file, e.g. an
-- older revision, to prove that a regression test fails without a fix.
function World:loadAddon(opts)
	opts = opts or {}
	if opts.blizzardFirst ~= false then
		for _, name in ipairs(BLIZZARD_ADDONS) do
			self:loadBlizzardAddon(name)
		end
	end
	local ns = {}
	for _, file in ipairs(wow.tocFiles()) do
		local chunk, err = loadfile(opts.replace and opts.replace[file] or file)
		if not chunk then
			error("emulator: " .. tostring(err))
		end
		setfenv(chunk, self.G)
		self:addonCall(chunk, "TinyTweaks", ns)
	end
	for name, value in pairs(self.savedInit or {}) do
		rawset(self.G, name, value)
	end
	self.loaded.TinyTweaks = true
	self:fire("ADDON_LOADED", "TinyTweaks")
	self.ns = ns
	return ns
end

-- SavedVariables as the client would write them on logout.
function World:saved()
	return rawget(self.G, "TinyTweaksDB")
end

-- Blizzard: Edit Mode ---------------------------------------------------------------------------
-- Source references are to Blizzard_EditMode/Shared/ (build 1.60.1): ET = EditModeSystemTemplates.lua,
-- EM = EditModeManager.lua, ED = EditModeDialogs.lua.

local function anchorsEqual(a, b)
	if a and b then
		return a.point == b.point and a.relativeTo == b.relativeTo and a.relativePoint == b.relativePoint
			and math.abs(a.offsetX - b.offsetX) <= 0.1 and math.abs(a.offsetY - b.offsetY) <= 0.1
	end
	return a == b
end

local function copyAnchorInto(target, source)
	if target and source then
		target.point, target.relativeTo, target.relativePoint = source.point, source.relativeTo, source.relativePoint
		target.offsetX, target.offsetY = source.offsetX, source.offsetY
	end
end

function World:createEditMode()
	local world = self
	local G = self.G
	local manager = self:newWidget("Frame", "EditModeManagerFrame", self.UIParent, true)
	self.manager = manager
	self:bset(manager, "registeredSystemFrames", {})
	self.ws[manager].shown = false

	self:defineMethod(manager, "GetActiveLayoutInfo", function()
		return { layoutType = world.layout.layoutType, layoutName = world.layout.layoutName }
	end, false)
	self:defineMethod(manager, "RegisterSystemFrame", function(this, frame)
		table.insert(this.registeredSystemFrames, frame)
	end, true)
	self:defineMethod(manager, "OnEditModeSystemAnchorChanged", function(this)
		this.editModeSystemAnchorDirty = true -- EM:1039
	end, true)
	-- EM:1479 initSystemAnchor: everything but managed frames in their default position starts at
	-- TOPLEFT of UIParent before the layout is applied.
	self:defineMethod(manager, "InitSystemAnchors", function(this)
		for _, frame in ipairs(this.registeredSystemFrames) do
			if not (frame.isManagedFrame and frame:IsInDefaultPosition()) then
				frame:ClearAllPoints()
				frame:SetPoint("TOPLEFT", world.UIParent, "TOPLEFT", 0, 0)
			end
		end
	end, true)
	-- EM:1483 UpdateSystems → EM:1492 UpdateSystem → frame:UpdateSystem(systemInfo).
	self:defineMethod(manager, "UpdateSystems", function(this)
		for _, frame in ipairs(this.registeredSystemFrames) do
			frame:UpdateSystem(world:nextSystemInfo(frame))
		end
	end, true)
	-- EM:400 OnSystemSettingChange → ET:268 UpdateSystemSettingValue.
	self:defineMethod(manager, "OnSystemSettingChange", function(_, frame, setting, value)
		frame:UpdateSystemSettingValue(setting, value)
	end, true)
	-- EM:372 OnSystemPositionChange → EM:316 UpdateSystemAnchorInfo.
	self:defineMethod(manager, "OnSystemPositionChange", function(this, frame)
		local info = frame.systemInfo
		local scale = frame:GetScale()
		local changed = false
		for index, key in ipairs({ "anchorInfo", "anchorInfo2" }) do
			local point, relativeTo, relativePoint, x, y = frame:GetPoint(index)
			if index == 1 and point and not relativeTo then
				relativeTo = world.UIParent
			end
			local new
			if point then
				new = {
					point = point,
					relativeTo = relativeTo and relativeTo:GetName() or "UIParent", -- a name, EM:262
					relativePoint = relativePoint,
					offsetX = x * scale,
					offsetY = y * scale,
				}
			end
			if not anchorsEqual(info[key], new) then
				copyAnchorInto(info[key], new) -- in place, and only into an existing table (EM:248)
				changed = true
			end
		end
		if changed then
			info.isInDefaultPosition = false
			if world.dialog then
				world.dialog:UpdateDialog(frame)
			end
		end
		this:OnEditModeSystemAnchorChanged()
	end, true)
	self:defineMethod(manager, "UpdateRaidContainerFlow", function()
		-- EM:477: FlowContainer_SetOrientation and FlowContainer_SetMaxPerLine each re-flow at the
		-- container's current size, then TryUpdate.
		local container = G.CompactRaidFrameContainer
		if container then
			world:blizzardFlow(container)
			world:blizzardFlow(container)
			if container:ReadyToUpdate() then
				container:LayoutFrames()
			end
		end
	end, true)

	local dialog = self:newWidget("Frame", "EditModeSystemSettingsDialog", self.UIParent, true)
	self.dialog = dialog
	local ds = self.ws[dialog]
	ds.iteratesChildren = true
	ds.shown = false
	ds.width, ds.height = 350, 300
	ds.strata, ds.level = "DIALOG", 100

	local pool = setmetatable({}, {}) -- Blizzard table; addon only enumerates it
	local active, inactive = {}, {}
	self.sliderPool = { active = active, inactive = inactive }
	local poolBacking = {
		-- A secure pool: next-order iteration yielding (frame, true).
		EnumerateActive = function()
			return next, active, nil
		end,
	}
	setmetatable(pool, {
		__index = poolBacking,
		__newindex = function(_, key)
			world:violation("taint: addon wrote " .. tostring(key) .. " on the slider pool")
		end,
	})

	local function acquireSlider()
		local sf = table.remove(inactive)
		if not sf then
			sf = world:newWidget("Frame", nil, dialog, true)
			local thumb = world:newWidget("Slider", nil, sf, true)
			world:bset(sf, "Slider", thumb)
			world:bset(thumb, "RightText", world:newWidget("FontString", nil, thumb, true))
		end
		active[sf] = true
		sf:Show()
		return sf
	end

	self:defineMethod(dialog, "GetSettingPool", function(_, displayType)
		if displayType == world.Enum.EditModeSettingDisplayType.Slider then
			return pool
		end
	end, false)
	-- ED:598: only for the attached frame; sliders are released and re-acquired, except one whose
	-- thumb is being dragged, which keeps its frame. SetupSetting sets .setting and the value text,
	-- and the slider's FormatValue re-shows the label (MinimalSlider.lua:160-172).
	self:defineMethod(dialog, "UpdateSettings", function(this, frame)
		if frame == nil or frame ~= this.attachedToSystem then
			return
		end
		local dragging
		for sf in pairs(active) do
			if world.ws[sf.Slider].dragging then
				dragging = sf
			else
				active[sf] = nil
				sf:Hide()
				table.insert(inactive, sf)
			end
		end
		local fs = world.ws[frame]
		for _, setting in ipairs(fs.settingOrder or {}) do
			local def = fs.settings[setting]
			if def.displayType == world.Enum.EditModeSettingDisplayType.Slider and frame:ShouldShowSetting(setting) then
				local sf
				if dragging and dragging.setting == setting then
					sf = dragging
				else
					sf = acquireSlider()
				end
				world:bset(sf, "setting", setting)
				sf.Slider.RightText:SetText(tostring(frame:GetSettingValue(setting)))
				sf.Slider.RightText:Show()
			end
		end
	end, true)
	-- ED:556: UpdateSettings, UpdateButtons, UpdateExtraButtons, UpdateSizeAndAnchors.
	self:defineMethod(dialog, "UpdateDialog", function(this, frame)
		this:UpdateSettings(frame)
	end, true)
	-- ED:537: attach, update, then show.
	self:defineMethod(dialog, "AttachToSystemFrame", function(this, frame)
		this.attachedToSystem = frame
		this:UpdateDialog(frame)
		this:Show()
	end, true)
	-- ED:659.
	self:defineMethod(dialog, "OnSettingValueChanged", function(this, setting, value)
		if this.attachedToSystem then
			manager:OnSystemSettingChange(this.attachedToSystem, setting, value)
		end
	end, true)

	-- Frames created before Edit Mode loaded register now.
	for _, frame in ipairs(self.systemFrames) do
		manager:RegisterSystemFrame(frame)
	end
end

-- The systemInfo Blizzard hands a frame on the next layout apply: a new table built from the current
-- one plus any changes queued with applyLayoutData / switchLayout / revertSystem.
function World:nextSystemInfo(frame)
	local s = self.ws[frame]
	local change = s.nextChange or {}
	s.nextChange = nil
	local current = frame.systemInfo
	local info = {
		anchorInfo = deepcopy(change.anchorInfo or current.anchorInfo),
		anchorInfo2 = deepcopy(current.anchorInfo2),
		isInDefaultPosition = current.isInDefaultPosition,
		settings = {},
	}
	if change.isInDefaultPosition ~= nil then
		info.isInDefaultPosition = change.isInDefaultPosition
	elseif change.anchorInfo then
		info.isInDefaultPosition = false
	end
	for setting, def in pairs(s.settings) do
		info.settings[setting] = def.raw
	end
	for key, value in pairs(change.settings or {}) do
		local setting = self:settingId(frame, key)
		local def = s.settings[setting]
		if def.displayType == self.Enum.EditModeSettingDisplayType.Slider then
			info.settings[setting] = (value - def.min) / def.step
		else
			info.settings[setting] = value
		end
	end
	return info
end

-- Blizzard positions a managed frame in its default position through its container. The emulator
-- has no containers; it puts the frame at its default point.
function World:placeManaged(frame)
	local p = self.ws[frame].defaultPoint
	frame:ClearAllPoints()
	frame:SetPoint(p.point, p.relativeTo, p.relativePoint, p.offsetX, p.offsetY)
end

-- Settings spec: { key = "FrameSize", value = 100, min = 50, max = 200, step = 5,
--   kind = "scale" | "alpha" | nil, method = "UpdateSystemSettingFrameSize", type = "Slider" | "Checkbox", hidden }
-- Frame spec: name, system, index, systemName, protected, initialized, locked, managed,
--   anchorInfo, anchorInfo2, isInDefaultPosition, defaultPoint, width, height, settings.
function World:addSystemFrame(spec)
	local world = self
	local Enum = self.Enum
	local G = self.G
	local widget = self.methods.Frame
	local system = assert(Enum.EditModeSystem[spec.system], "unknown system " .. tostring(spec.system))
	local settingEnum = Enum[SETTING_ENUMS[spec.system] or ""] or {}

	local frame = self.ws[spec.frame] and spec.frame or self:newWidget("Frame", spec.name, self.UIParent, true)
	local s = self.ws[frame]
	s.protected = spec.protected or false
	s.initialized = spec.initialized ~= false
	s.width, s.height = spec.width or 200, spec.height or 80
	s.settings, s.settingOrder = {}, {}
	s.defaultPoint = spec.defaultPoint
		or { point = "TOPLEFT", relativeTo = "UIParent", relativePoint = "TOPLEFT", offsetX = 10, offsetY = -10 }

	local displayInfo = {}
	self:blizzard(function()
		frame.system = system
		frame.systemIndex = spec.index and Enum.EditModeUnitFrameSystemIndices[spec.index] or nil
		frame.systemNameString = spec.systemName or spec.name
		frame.isLocked = spec.locked or nil
		frame.isManagedFrame = spec.managed or nil
		frame.systemInfo = {
			-- ResetToDefaultPosition stores the default anchor in anchorInfo (ET:310).
			anchorInfo = deepcopy(spec.anchorInfo or s.defaultPoint),
			anchorInfo2 = spec.anchorInfo2 and deepcopy(spec.anchorInfo2) or nil,
			isInDefaultPosition = spec.isInDefaultPosition or false,
		}
		frame.settingDisplayInfoMap = displayInfo
		frame.snappedFrames = {}
		-- OnSystemLoad (ET:9-17): the widget methods stay reachable as *Base; SetScale, SetPoint and
		-- ClearAllPoints become Blizzard Lua (below).
		frame.SetScaleBase = widget.SetScale
		frame.SetPointBase = widget.SetPoint
		frame.ClearAllPointsBase = widget.ClearAllPoints
	end)

	-- ET:117 SetScaleOverride: keeps the frame in place across the scale change, through the SetPoint
	-- override; a managed frame in its default position re-runs the managed layout.
	self:defineMethod(frame, "SetScale", function(this, newScale)
		local oldScale = this:GetScale()
		this:SetScaleBase(newScale)
		if oldScale == newScale then
			return
		end
		for i = 1, this:GetNumPoints() do
			local point, relativeTo, relativePoint, x, y = this:GetPoint(i)
			this:SetPoint(point, relativeTo, relativePoint, x * oldScale / newScale, y * oldScale / newScale)
		end
		if this.isManagedFrame and this:IsInDefaultPosition() then
			G.ManageFramePositions()
		end
	end, true)
	-- ET:147 SetPointOverride: records the snap and marks Edit Mode's anchors dirty.
	self:defineMethod(frame, "SetPoint", function(this, point, relativeTo, relativePoint, x, y)
		this:SetPointBase(point, relativeTo, relativePoint, x, y)
		this:SetSnappedToFrame(relativeTo)
		local manager = rawget(G, "EditModeManagerFrame")
		if manager then
			manager:OnEditModeSystemAnchorChanged()
		end
	end, true)
	-- ET:153 ClearAllPointsOverride.
	self:defineMethod(frame, "ClearAllPoints", function(this)
		this:ClearAllPointsBase()
		this:ClearFrameSnap()
	end, true)
	-- ET:719-735.
	self:defineMethod(frame, "SetSnappedToFrame", function(this, target)
		if type(target) == "string" then
			target = G[target]
		end
		if type(target) == "table" and target.AddSnappedFrame then
			target:AddSnappedFrame(this)
			this.snappedToFrame = target
		end
	end, true)
	self:defineMethod(frame, "ClearFrameSnap", function(this)
		if this.snappedToFrame then
			this.snappedToFrame:RemoveSnappedFrame(this)
			this.snappedToFrame = nil
		end
	end, true)
	self:defineMethod(frame, "AddSnappedFrame", function(this, other)
		this.snappedFrames[other] = true
	end, true)
	self:defineMethod(frame, "RemoveSnappedFrame", function(this, other)
		this.snappedFrames[other] = nil
	end, true)

	for _, def in ipairs(spec.settings or {}) do
		local setting = assert(settingEnum[def.key], "unknown setting " .. tostring(def.key) .. " for " .. spec.system)
		local displayType = Enum.EditModeSettingDisplayType[def.type or "Slider"]
		local entry = {
			key = def.key, displayType = displayType, kind = def.kind, method = def.method, hidden = def.hidden,
			min = def.min or 0, max = def.max or 100, step = def.step or 1,
		}
		if displayType == Enum.EditModeSettingDisplayType.Slider then
			entry.raw = ((def.value or entry.min) - entry.min) / entry.step
		else
			entry.raw = def.value or 0
		end
		s.settings[setting] = entry
		s.settingOrder[#s.settingOrder + 1] = setting
		displayInfo[setting] = { setting = setting, type = displayType, minValue = entry.min, maxValue = entry.max, stepSize = entry.step }
		if def.method then
			-- The size/scale/opacity handlers are one widget call each (ET:2578, 2681, 2751, 2784, 2788,
			-- 2852, 2898, 3822, 3850, 1629, 1586, 2141, 3001, 3518); SetScale is the override above.
			-- PartyFrame skips its size while a game rule forces the party frame scale
			-- (Blizzard_UnitFrame/Shared/PartyFrame.lua:28).
			self:defineMethod(frame, def.method, function(this)
				if entry.kind == "scale" and this.systemIndex == Enum.EditModeUnitFrameSystemIndices.Party
					and G.C_GameRules.IsGameRuleActive(Enum.GameRule.ForcedPartyFrameScale) then
					return
				end
				local value = this:GetSettingValue(setting)
				if entry.kind == "scale" then
					this:SetScale(value / 100)
				elseif entry.kind == "alpha" then
					this:SetAlpha(value / 100)
				end
			end, true)
		end
	end

	self:defineMethod(frame, "HasSetting", function(_, setting)
		return s.settings[setting] ~= nil
	end, false)
	-- ET:483: 0 until initialized or for a missing setting; raw = settingMap value, display =
	-- Clamp(raw * step + min, min, max) (EditModeSettingDisplayInfo.lua:8-14).
	self:defineMethod(frame, "GetSettingValue", function(_, setting, useRawValue)
		local def = s.settings[setting]
		if not def or not s.initialized then
			return 0
		end
		if useRawValue or def.displayType ~= Enum.EditModeSettingDisplayType.Slider then
			return def.raw
		end
		return math.max(def.min, math.min(def.max, def.min + def.raw * def.step))
	end, false)
	self:defineMethod(frame, "GetSettingValueBool", function(_, setting)
		local def = s.settings[setting]
		return def ~= nil and def.raw == 1
	end, false)
	self:defineMethod(frame, "ShouldShowSetting", function(_, setting)
		local def = s.settings[setting]
		return def ~= nil and not def.hidden
	end, false)
	self:defineMethod(frame, "IsInitialized", function()
		return s.initialized
	end, false)
	self:defineMethod(frame, "IsInDefaultPosition", function(this)
		return s.initialized and this.systemInfo.isInDefaultPosition or false
	end, false)
	self:defineMethod(frame, "GetSystemName", function(this)
		return this.systemNameString
	end, false)
	-- ET:268 UpdateSystemSettingValue: stores the raw step (unrounded) and updates only on a change.
	self:defineMethod(frame, "UpdateSystemSettingValue", function(this, setting, newValue)
		if not s.initialized then
			return
		end
		local def = s.settings[setting]
		if not def then
			return
		end
		local raw = newValue
		if def.displayType == Enum.EditModeSettingDisplayType.Slider then
			raw = (newValue - def.min) / def.step
		end
		if def.raw ~= raw then
			def.raw = raw
			this:UpdateSystemSetting(setting)
		end
	end, true)
	-- ET:409 base UpdateSystemSetting (marks dirty, refreshes the dialog), then the derived dispatch
	-- runs UpdateSystemSetting<Name> for a dirty setting and clears it.
	self:defineMethod(frame, "UpdateSystemSetting", function(this, setting, entireSystemUpdate)
		local def = s.settings[setting]
		if not entireSystemUpdate then
			def.dirty = true
			if world.dialog then
				world.dialog:UpdateDialog(this)
			end
		end
		if def.dirty then
			def.dirty = false
			if def.method then
				this[def.method](this)
			end
		end
	end, true)
	-- ET:385 UpdateSystem: settings diff → ApplySystemAnchor → dialog → handlers of dirty settings.
	self:defineMethod(frame, "UpdateSystem", function(this, systemInfo)
		for setting, raw in pairs(systemInfo.settings or {}) do
			local def = s.settings[setting]
			if def and def.raw ~= raw then
				def.raw = raw
				def.dirty = true
			end
		end
		this.systemInfo = {
			anchorInfo = systemInfo.anchorInfo,
			anchorInfo2 = systemInfo.anchorInfo2,
			isInDefaultPosition = systemInfo.isInDefaultPosition,
		}
		this:ApplySystemAnchor()
		if world.dialog then
			world.dialog:UpdateDialog(this)
		end
		for _, setting in ipairs(s.settingOrder) do
			this:UpdateSystemSetting(setting, true)
		end
	end, true)
	-- ET:350 ApplySystemAnchor: a managed frame in its default position is placed by its container;
	-- otherwise the anchors from systemInfo at the frame's scale, through the overrides. The cast bar
	-- re-applies its size after anchoring (ET:1853).
	self:defineMethod(frame, "ApplySystemAnchor", function(this)
		local info = this.systemInfo
		if this.isManagedFrame and this:IsInDefaultPosition() then
			world:placeManaged(this)
		else
			this:ClearAllPoints()
			local scale = this:GetScale()
			for _, a in ipairs({ info.anchorInfo, info.anchorInfo2 }) do
				this:SetPoint(a.point, a.relativeTo, a.relativePoint, a.offsetX / scale, a.offsetY / scale)
			end
		end
		if this.system == Enum.EditModeSystem.CastBar and this.UpdateSystemSettingBarSize then
			this:UpdateSystemSettingBarSize()
		end
	end, true)
	-- ET:311 ResetToDefaultPosition: the default anchor, back in the default position, re-anchored
	-- (a managed frame returns to its container), then the dialog refreshes. No setting handler runs.
	self:defineMethod(frame, "ResetToDefaultPosition", function(this)
		this.systemInfo.anchorInfo = deepcopy(world.ws[this].defaultPoint)
		this.systemInfo.anchorInfo2 = nil
		this.systemInfo.isInDefaultPosition = true
		this:ApplySystemAnchor()
		world.dialog:UpdateDialog(this)
	end, true)
	-- ET:766: the frame snaps to the reported point (offsets from GetSnapOffsets; the emulator places
	-- the final pin itself in dragSystem).
	self:defineMethod(frame, "SnapToFrame", function(this, info)
		this:ClearAllPoints()
		this:SetPoint(info.point, info.frame, info.relativePoint, 0, 0)
	end, true)
	-- ET:737 BreakFrameSnap: TOPLEFT of UIParent from the current rect, plus the nudge.
	self:defineMethod(frame, "BreakFrameSnap", function(this, dx, dy)
		local scale = this:GetScale()
		local x = this:GetLeft() + (dx or 0)
		local y = -((world.UIParent:GetHeight() - this:GetTop() * scale) / scale) + (dy or 0)
		this:ClearAllPoints()
		this:SetPoint("TOPLEFT", world.UIParent, "TOPLEFT", x, y)
		this:OnSystemPositionChange()
	end, true)
	-- ET:919.
	self:defineMethod(frame, "OnSystemPositionChange", function(this)
		world.manager:OnSystemPositionChange(this)
	end, true)

	-- Blizzard applies the setup, then registers the frame with Edit Mode.
	self:blizzard(function()
		for _, setting in ipairs(s.settingOrder) do
			local def = s.settings[setting]
			if def.method then
				frame[def.method](frame)
			end
		end
		frame:ApplySystemAnchor()
		self.systemFrames[#self.systemFrames + 1] = frame
		if self.manager then
			self.manager:RegisterSystemFrame(frame)
		end
	end)
	return frame
end

-- Blizzard: raid frames -------------------------------------------------------------------------
-- Source references are to Blizzard_CompactRaidFrames/Blizzard_CompactRaidFrameContainer.lua (C),
-- Blizzard_UnitFrame/Shared/CompactRaidGroup.lua (G) and Blizzard_SharedXML FlowContainer.lua.

local TITLE_HEIGHT = 14

-- G:95 CompactRaidGroup_UpdateLayout for vertical groups: the title, member 1 always (minUnitFrames
-- = 1), every shown member after it; +8 width / +2 height with the border.
function World:groupSize(group)
	local m = self.raidMember
	local members = self.ws[group].members
	local width = m.width + (m.border and 8 or 0)
	local height = TITLE_HEIGHT + m.height * math.max(members, 1) + (m.border and 2 or 0)
	return width, height
end

function World:createRaidContainer()
	local world = self
	local G = self.G
	local container = self:newWidget("Frame", "CompactRaidFrameContainer", self.UIParent, true)
	self.container = container
	local cs = self.ws[container]
	cs.groupMode = "discrete"
	cs.ready = true
	self:bset(container, "flowFrames", {})
	self:bset(container, "flowFrameTypes", {})
	self:bset(container, "flowOrientation", "vertical")
	self:bset(container, "flowMaxPerLine", 5) -- separate groups modes (EM:483-488)
	self:bset(container, "flowVerticalSpacing", 0)
	self:bset(container, "flowHorizontalSpacing", 0)
	self.groups = {}
	self.roster = { 0, 0, 0, 0, 0, 0, 0, 0 }
	self.raidMember = { width = 72, height = 36, border = false }

	self:defineMethod(container, "GetGroupMode", function()
		return cs.groupMode
	end, false)
	self:defineMethod(container, "ReadyToUpdate", function()
		return cs.ready
	end, false)
	-- C:233 LayoutFrames: hide what was flowed, re-add only used groups (C:288-340), flow at
	-- 3000x3000, size to the shown children (ResizeLayoutMixin:Layout), and resize from the visible
	-- bounds one frame later (C:187 RefreshSize).
	self:defineMethod(container, "LayoutFrames", function(this)
		for _, object in ipairs(this.flowFrames) do
			if type(object) == "table" and object.unusedFunc then
				object:unusedFunc()
			end
		end
		this.flowFrames, this.flowFrameTypes = {}, {}
		if this:GetGroupMode() == "discrete" then
			for i = 1, 8 do
				if world.roster[i] > 0 then
					local group = G.CompactRaidGroup_GenerateForGroup(i)
					group.unusedFunc = group.Hide
					group:Show()
					table.insert(this.flowFrames, group)
					table.insert(this.flowFrameTypes, "object")
				end
			end
		end
		this:SetSize(3000, 3000)
		world:blizzardFlow(this)
		world:sizeToChildren(this)
		world.blizzardLayouts = (world.blizzardLayouts or 0) + 1
		if not cs.pendingSizeRefresh then
			cs.pendingSizeRefresh = true
			world:runNextFrame(function()
				world:refreshContainerSize(this)
				cs.pendingSizeRefresh = nil
			end)
		end
	end, true)

	-- G:30: creates the group on first use; a new group lays out its members right away.
	rawset(G, "CompactRaidGroup_GenerateForGroup", function(index)
		if world.depth == 0 then
			world:violation("taint: addon called CompactRaidGroup_GenerateForGroup")
		end
		return world:blizzard(function()
			local existing = world.groups[index]
			if existing then
				return existing, false
			end
			local group = world:newWidget("Frame", "CompactRaidGroup" .. index, container, true)
			local gs = world.ws[group]
			gs.protected = true
			gs.members = world.roster[index]
			group.isFlowGroup = true
			world:defineMethod(group, "updateLayoutFunc", function(this)
				this:SetSize(world:groupSize(this))
			end, true)
			world.groups[index] = group
			group:updateLayoutFunc()
			return group, true
		end)
	end)

	-- Raid frames are an Edit Mode system (UnitFrame / Raid) with unsupported size sliders.
	self:addSystemFrame({
		frame = container,
		system = "UnitFrame",
		index = "Raid",
		systemName = "Raid Frames",
		protected = true,
		anchorInfo = { point = "TOPLEFT", relativeTo = "UIParent", relativePoint = "TOPLEFT", offsetX = 20, offsetY = -200 },
		settings = {
			{ key = "FrameWidth", value = 72, min = 72, max = 144, step = 2 },
			{ key = "FrameHeight", value = 36, min = 36, max = 72, step = 2 },
		},
	})
end

-- FlowContainer_DoLayout for objects and line breaks (no atomic sections, spacers, flagged or target
-- frames): a flow group, and the object after one, starts a new line; a line also wraps at
-- flowMaxPerLine or at the container's current primary size.
function World:blizzardFlow(container)
	local horizontal = container.flowOrientation == "horizontal"
	local primary, secondary = "GetHeight", "GetWidth"
	local primarySpacing = container.flowVerticalSpacing or 0
	local secondarySpacing = container.flowHorizontalSpacing or 0
	if horizontal then
		primary, secondary = "GetWidth", "GetHeight"
		primarySpacing, secondarySpacing = secondarySpacing, primarySpacing
	end
	local limit = container[primary](container)
	local maxPerLine = container.flowMaxPerLine
	local secondaryOffset, primaryOffset, lineMax, line = 0, 0, 0, 1
	local last
	for i, object in ipairs(container.flowFrames) do
		local objectType = container.flowFrameTypes[i]
		if objectType == "linebreak" or (objectType == "object" and (object.isFlowGroup or (last and last.isFlowGroup)
			or (maxPerLine and line > maxPerLine) or secondaryOffset + object[primary](object) > limit)) then
			secondaryOffset = 0
			primaryOffset = primaryOffset + lineMax + secondarySpacing
			lineMax, line = 0, 1
		end
		if objectType == "object" then
			local left, top
			if horizontal then
				left, top = secondaryOffset, primaryOffset
			else
				left, top = primaryOffset, secondaryOffset
			end
			object:ClearAllPoints()
			object:SetPoint("TOPLEFT", container, "TOPLEFT", left, -top)
			secondaryOffset = secondaryOffset + object[primary](object) + primarySpacing
			lineMax = math.max(lineMax, object[secondary](object))
			line = line + 1
			last = object
		end
	end
end

-- Extent of the container's shown children, from its top-left: { right, bottom } or nil.
function World:childExtent(container, visibleOnly)
	local minX, minY, maxX, maxY
	for _, child in ipairs(self.ws[container].children) do
		local cs = self.ws[child]
		local p = cs.points[1]
		local shown = visibleOnly and child:IsVisible() or (not visibleOnly and cs.shown)
		if shown and p and p[1] == "TOPLEFT" and p[2] == container and p[3] == "TOPLEFT" then
			local left, top = p[4], -p[5]
			minX = math.min(minX or left, left)
			minY = math.min(minY or top, top)
			maxX = math.max(maxX or 0, left + cs.width)
			maxY = math.max(maxY or 0, top + cs.height)
		end
	end
	return minX, minY, maxX, maxY
end

-- ResizeLayoutMixin:Layout (LayoutFrame.lua:488): the container takes the extent of its shown children.
function World:sizeToChildren(container)
	local _, _, maxX, maxY = self:childExtent(container, false)
	if maxX and maxX > 0 and maxY > 0 then
		container:SetSize(maxX, maxY)
	end
end

-- C:162 GetBounds / C:187 RefreshSize over the visible groups. (With nothing visible Blizzard would
-- compute a negative size; the emulator leaves the size alone.)
function World:refreshContainerSize(container)
	local minX, minY, maxX, maxY = self:childExtent(container, true)
	if minX then
		container:SetSize(maxX - minX, maxY - minY)
	end
end

-- Sets the raid roster as members per group (1-8) and runs Blizzard's updates for it. Existing groups
-- handle GROUP_ROSTER_UPDATE themselves (G:8-15) and the container re-lays out on the same event; the
-- order between them isn't fixed (C:266-267). opts.groupsAfter = true runs the groups after the
-- container, so the container flows them at their old size.
function World:setRaidRoster(counts, opts)
	opts = opts or {}
	for i = 1, 8 do
		self.roster[i] = counts[i] or 0
	end
	self:blizzard(function()
		local function updateGroups()
			for i = 1, 8 do
				local group = self.groups[i]
				if group then
					self.ws[group].members = self.roster[i]
					group:updateLayoutFunc()
				end
			end
		end
		if not opts.groupsAfter then
			updateGroups()
		end
		if self.container:ReadyToUpdate() then
			self.container:LayoutFrames()
		end
		if opts.groupsAfter then
			updateGroups()
		end
	end)
end

-- Blizzard re-lays out the members of each group at a new size (the frame width/height settings, the
-- border) without re-flowing the container.
function World:resizeRaidMembers(width, memberHeight, border)
	self.raidMember = { width = width, height = memberHeight, border = border or false }
	self:blizzard(function()
		for i = 1, 8 do
			local group = self.groups[i]
			if group then
				group:updateLayoutFunc()
			end
		end
	end)
end

function World:setRaidGroupMode(mode)
	self.ws[self.container].groupMode = mode
	self:blizzard(function()
		self.container:LayoutFrames()
	end)
end

function World:raidLayout()
	self:blizzard(function()
		self.container:LayoutFrames()
	end)
end

-- Shown group numbers by on-screen position, e.g. "1 2 3 4 / 5 6 7 8"; "." is an empty cell.
function World:raidGrid()
	local xs, ys, at = {}, {}, {}
	local function addUnique(list, v)
		for _, x in ipairs(list) do
			if math.abs(x - v) < 0.01 then
				return x
			end
		end
		list[#list + 1] = v
		return v
	end
	for i = 1, 8 do
		local group = self.groups[i]
		if group and group:IsShown() then
			local point, rel, relPoint, x, y = group:GetPoint(1)
			assert(point == "TOPLEFT" and rel == self.container and relPoint == "TOPLEFT", "group " .. i .. " is not anchored to the container")
			x, y = addUnique(xs, x), addUnique(ys, y)
			at[x .. ":" .. y] = i
		end
	end
	table.sort(xs)
	table.sort(ys, function(a, b)
		return a > b
	end)
	local rows = {}
	for _, y in ipairs(ys) do
		local cells = {}
		for _, x in ipairs(xs) do
			cells[#cells + 1] = tostring(at[x .. ":" .. y] or ".")
		end
		rows[#rows + 1] = table.concat(cells, " ")
	end
	return table.concat(rows, " / ")
end

function World:groupOffset(index)
	local _, _, _, x, y = self.groups[index]:GetPoint(1)
	return x, y
end

-- Player actions ---------------------------------------------------------------------------------

function World:selectSystem(frame)
	self:blizzard(function()
		self.dialog:AttachToSystemFrame(frame)
	end)
end

function World:closeDialog()
	self:blizzard(function()
		self.dialog:Hide()
	end)
end

-- The active slider setting frame for a setting key ("FrameSize") of the selected frame.
function World:sliderFrame(key)
	local frame = self.dialog.attachedToSystem
	local setting = self.ws[frame].settings and self:settingId(frame, key)
	for sf in pairs(self.sliderPool.active) do
		if sf.setting == setting then
			return sf
		end
	end
	return nil
end

function World:settingId(frame, key)
	for setting, def in pairs(self.ws[frame].settings) do
		if def.key == key then
			return setting
		end
	end
	error("frame has no setting " .. tostring(key))
end

-- The TinyTweaks input box on a slider, or nil when there is none or it's hidden.
function World:fineTuneBox(key)
	local sf = self:sliderFrame(key)
	if not sf then
		return nil
	end
	for _, child in ipairs(self.ws[sf].children) do
		local cs = self.ws[child]
		if cs.kind == "EditBox" and not cs.blizzard and cs.shown then
			return child
		end
	end
	return nil
end

-- Drags a Blizzard slider to a value: its OnValueChanged reaches dialog:OnSettingValueChanged while the
-- thumb is held, so UpdateSettings keeps that slider's frame.
function World:moveSlider(key, value)
	local frame = self.dialog.attachedToSystem
	local sf = self:sliderFrame(key)
	local thumb = sf and self.ws[sf.Slider]
	if thumb then
		thumb.dragging = true
	end
	self:blizzard(function()
		self.dialog:OnSettingValueChanged(self:settingId(frame, key), value)
	end)
	if thumb then
		thumb.dragging = false
	end
end

function World:typeInto(box, text)
	local s = self.ws[box]
	assert(s.kind == "EditBox", "not an edit box")
	assert(box:IsVisible(), "can't type into a hidden box")
	assert(s.enabled, "can't type into a disabled box")
	box:SetFocus()
	box:SetText(text)
	self:runScript(box, "OnEnterPressed")
end

function World:click(button)
	local s = self.ws[button]
	assert(button:IsVisible(), "can't click a hidden button")
	assert(s.enabled, "can't click a disabled button")
	if s.kind == "CheckButton" then
		s.checked = not s.checked
	end
	self:runScript(button, "OnClick", "LeftButton", false)
end

function World:dragSlider(sliderTemplate, value)
	local s = self.ws[sliderTemplate]
	assert(s.slider, "not a MinimalSliderWithSteppers")
	assert(s.enabled ~= false, "can't drag a disabled slider")
	local sl = s.slider
	value = math.max(sl.min, math.min(sl.max, value))
	local thumb = self.ws[sl.thumb]
	thumb.dragging = true
	if sl.value ~= value then
		sl.value = value
		sl.fire(value)
	end
	thumb.dragging = false
end

-- Hovers a region and returns the tooltip lines it showed.
function World:hover(region)
	self:runScript(region, "OnEnter")
	local lines = self.ws[self.GameTooltip].lines or {}
	self:runScript(region, "OnLeave")
	return lines
end

-- Queues layout data for frames, as a layout load would bring it:
-- changes = { [frame] = { settings = { Key = displayValue }, anchorInfo = {...}, isInDefaultPosition = bool } }
function World:queueLayoutData(changes)
	for frame, change in pairs(changes or {}) do
		self.ws[frame].nextChange = change
	end
end

-- A layout load, layout switch or Revert All (EM:1010 UpdateLayoutInfo): new systemInfo for every
-- frame, InitSystemAnchors, then UpdateSystems.
function World:applyLayoutData(changes)
	self:queueLayoutData(changes)
	self:blizzard(function()
		self.manager:InitSystemAnchors()
		self.manager:UpdateSystems()
	end)
end

function World:switchLayout(name, layoutType, changes)
	self.layout = { layoutName = name, layoutType = layoutType or self.Enum.EditModeLayoutType.Account }
	self:applyLayoutData(changes)
end

-- The settings dialog's Revert button (EM:407 RevertSystemChanges): one frame's saved systemInfo goes
-- straight to frame:UpdateSystem; UpdateSystems doesn't run.
function World:revertSystem(frame, change)
	self:queueLayoutData({ [frame] = change or {} })
	self:blizzard(function()
		frame:UpdateSystem(self:nextSystemInfo(frame))
	end)
end

-- Drag a system frame and drop it at a pin. Magnetism calls SnapToFrame once per snap it reports
-- (Blizzard_EditMode/Shared/EditModeUtil.lua:444-465); the frame ends at the pin, and
-- OnSystemPositionChange stores where it is (EM:316). Blizzard doesn't move it afterwards.
function World:dragSystem(frame, anchorInfo, snaps)
	self:blizzard(function()
		for _, snap in ipairs(snaps or {}) do
			frame:SnapToFrame(snap)
		end
		local scale = frame:GetScale()
		frame:ClearAllPoints()
		frame:SetPoint(anchorInfo.point, anchorInfo.relativeTo, anchorInfo.relativePoint,
			anchorInfo.offsetX / scale, anchorInfo.offsetY / scale)
		frame:OnSystemPositionChange()
	end)
end

-- The dialog's "Reset To Default Position" button (ET:311).
function World:resetToDefaultPosition(frame)
	self:blizzard(function()
		frame:ResetToDefaultPosition()
	end)
end

-- Arrow-key nudge (ET:49 → ET:737 BreakFrameSnap): re-pinned to UIParent's top left, moved by dx/dy,
-- no magnetism.
function World:nudgeSystem(frame, dx, dy)
	self:blizzard(function()
		frame:BreakFrameSnap(dx, dy)
	end)
end

-- Finding addon UI ----------------------------------------------------------------------------------

function World:descendants(root)
	local out = {}
	local function walk(obj)
		for _, child in ipairs(self.ws[obj].children) do
			out[#out + 1] = child
			walk(child)
		end
	end
	walk(root)
	return out
end

-- The addon frame that has a direct font string child with this text (a panel's title).
function World:findPanel(title)
	for _, obj in ipairs(self.created) do
		for _, child in ipairs(self.ws[obj].children) do
			local cs = self.ws[child]
			if cs.kind == "FontString" and cs.text == title then
				return obj
			end
		end
	end
	return nil
end

function World:findText(root, text)
	for _, obj in ipairs(self:descendants(root)) do
		local s = self.ws[obj]
		if s.kind == "FontString" and s.text == text then
			return obj
		end
	end
	return nil
end

-- The first descendant of the given kind whose first point is relative to `target`.
function World:findAnchoredTo(root, target, kind)
	for _, obj in ipairs(self:descendants(root)) do
		local s = self.ws[obj]
		local p = s.points[1]
		if p and p[2] == target and (not kind or s.kind == kind) then
			return obj
		end
	end
	return nil
end

function World:findButton(root, text)
	for _, obj in ipairs(self:descendants(root)) do
		local s = self.ws[obj]
		if (s.kind == "Button" or s.kind == "CheckButton") and s.fontString and self.ws[s.fontString].text == text then
			return obj
		end
	end
	return nil
end

-- The first descendant whose tooltip title is `title`.
function World:findByTooltip(root, title)
	for _, obj in ipairs(self:descendants(root)) do
		if self.ws[obj].scripts.OnEnter and self:hover(obj)[1] == title then
			return obj
		end
	end
	return nil
end

function World:findKind(root, kind)
	for _, obj in ipairs(self:descendants(root)) do
		if self.ws[obj].kind == kind then
			return obj
		end
	end
	return nil
end

-- Standard Edit Mode frames ----------------------------------------------------------------------

local CENTER = { point = "CENTER", relativeTo = "UIParent", relativePoint = "CENTER", offsetX = 0, offsetY = 0 }
wow.CENTER = CENTER

local function sizeSetting(key, method)
	return { key = key, value = 100, min = 50, max = 200, step = 5, kind = "scale", method = method }
end
local function opacitySetting(min)
	return { key = "Opacity", value = 100, min = min or 50, max = 100, step = 1, kind = "alpha", method = "UpdateSystemSettingOpacity" }
end

local function unitFrame(name, index, extra)
	local spec = {
		name = name, system = "UnitFrame", index = index, systemName = name:gsub("Frame$", " Frame"),
		protected = true, anchorInfo = CENTER,
		settings = {
			sizeSetting("FrameSize", "UpdateSystemSettingFrameSize"),
			opacitySetting(),
			{ key = "FrameWidth", value = 120, min = 72, max = 240, step = 2 },
		},
	}
	for k, v in pairs(extra or {}) do
		spec[k] = v
	end
	return spec
end

wow.frames = {
	target = function(extra)
		return unitFrame("TargetFrame", "Target", extra)
	end,
	focus = function(extra)
		return unitFrame("FocusFrame", "Focus", extra)
	end,
	player = function(extra)
		return unitFrame("PlayerFrame", "Player", extra)
	end,
	pet = function(extra)
		return unitFrame("PetFrame", "Pet", extra)
	end,
	-- Boss frames with the "use larger frame" checkbox.
	boss = function(useLarger)
		local spec = unitFrame("BossTargetFrameContainer", "Boss")
		table.insert(spec.settings, { key = "UseLargerFrame", type = "Checkbox", value = useLarger and 1 or 0 })
		return spec
	end,
	party = function(extra)
		return unitFrame("PartyFrame", "Party", extra)
	end,
	-- A managed frame (laid out by Blizzard's right-side container while in its default position).
	durability = function(extra)
		local spec = {
			name = "DurabilityFrame", system = "DurabilityFrame", systemName = "Durability", anchorInfo = CENTER,
			managed = true, settings = { sizeSetting("Size", "UpdateSystemSettingSize") },
		}
		for k, v in pairs(extra or {}) do
			spec[k] = v
		end
		return spec
	end,
	bags = function()
		return {
			name = "BagsBar", system = "Bags", systemName = "Bags", anchorInfo = CENTER,
			settings = { sizeSetting("Size", "UpdateSystemSettingSize") },
		}
	end,
	castBar = function(locked)
		return {
			name = "PlayerCastingBarFrame", system = "CastBar", systemName = "Cast Bar", anchorInfo = CENTER,
			settings = {
				sizeSetting("BarSize", "UpdateSystemSettingBarSize"),
				{ key = "LockToPlayerFrame", type = "Checkbox", value = locked and 1 or 0 },
			},
		}
	end,
	auras = function()
		return {
			name = "BuffFrame", system = "AuraFrame", systemName = "Buff Frame", anchorInfo = CENTER,
			settings = {
				{ key = "IconSize", value = 100, min = 50, max = 200, step = 10 },
				opacitySetting(),
			},
		}
	end,
	actionBar = function()
		return {
			name = "MainActionBar", system = "ActionBar", systemName = "Action Bar 1", anchorInfo = CENTER,
			settings = {
				{ key = "IconSize", value = 100, min = 50, max = 200, step = 10 },
				{ key = "IconPadding", value = 2, min = 0, max = 10, step = 1 },
			},
		}
	end,
}

return wow
