--[[
	Edit Mode fine-tuning: type an exact value into some Edit Mode sliders.

	Only sliders whose Blizzard handler is a single SetScale or SetAlpha on the frame are supported.
	Those can be repeated with widget calls, so Blizzard code never has to run from here.

	  * The typed value is stored in TinyTweaksDB per layout/system/setting, together with the raw
	    slider step it was typed against. Blizzard's layout keeps the slider's own value, so without
	    this addon the frame simply uses the slider value.
	  * After Blizzard's own UpdateSystemSetting<Name> runs (hooksecurefunc), the typed value is
	    applied. Alpha is a plain SetAlpha. Scale is not: Blizzard replaces SetScale on system frames
	    with SetScaleOverride (Lua), so the module calls the original SetScaleBase and repeats the
	    override's offset compensation with SetPointBase, keeping the frame in place.
	  * Managed frames in their default position (laid out by Blizzard's managed-frame containers)
	    get no typed scale: Blizzard re-runs the container layout on a scale change, which addon code
	    can't do.
	  * A typed value is only used while the Blizzard raw value still matches. Moving the slider, reverting,
	    or resetting the layout makes it inactive, and moving the slider deletes it.

	Taint notes: this module never calls Blizzard Edit Mode functions that change state, never writes
	into Blizzard tables (settingMap, dirtySettings) and never sets fields on Blizzard frames. Running
	Blizzard's setting code from addon code taints the settings dialog, after which unit frame code fails
	on secret values ("execution tainted by TinyTweaks") until /reload.
]]

local _, ns = ...

local M = {}
table.insert(ns.modules, M)

-- Supported sliders: supported[system][setting] = { kind = "scale"|"alpha", method = <Blizzard apply method>, check = fn }
local supported

local function BuildSupported()
	local list = {}
	local function add(systemKey, enumName, settingKey, kind, method, check)
		local system = Enum.EditModeSystem[systemKey]
		local settingEnum = Enum[enumName]
		local setting = settingEnum and settingEnum[settingKey]
		if system and setting ~= nil then
			list[system] = list[system] or {}
			list[system][setting] = { kind = kind, method = method, check = check }
		end
	end

	local indices = Enum.EditModeUnitFrameSystemIndices or {}
	local unitSetting = Enum.EditModeUnitFrameSetting or {}
	local castBarSetting = Enum.EditModeCastBarSetting or {}

	-- Same conditions under which Blizzard's own handler applies the value.
	local function unitFrameSize(frame)
		-- Player: Blizzard also rescales the pet frame and the cast bar. Pet: scaled with the player.
		if frame.systemIndex == indices.Player or frame.systemIndex == indices.Pet then
			return false
		end
		-- Party: Blizzard ignores the slider while a game rule forces the party frame scale.
		local rule = Enum.GameRule and Enum.GameRule.ForcedPartyFrameScale
		if frame.systemIndex == indices.Party and rule and C_GameRules and C_GameRules.IsGameRuleActive
			and C_GameRules.IsGameRuleActive(rule) then
			return false
		end
		local larger = unitSetting.UseLargerFrame
		if larger and frame:HasSetting(larger) and not frame:GetSettingValueBool(larger) then
			return false
		end
		return true
	end
	local function unitFrameOpacity(frame)
		return frame:ShouldShowSetting(unitSetting.Opacity)
	end
	local function castBarSize(frame)
		-- Locked to the player frame, Blizzard counteracts the player frame's scale and re-anchors.
		local locked = castBarSetting.LockToPlayerFrame
		return not (locked and frame:HasSetting(locked) and frame:GetSettingValueBool(locked))
	end

	add("Bags", "EditModeBagsSetting", "Size", "scale", "UpdateSystemSettingSize")
	add("DurabilityFrame", "EditModeDurabilityFrameSetting", "Size", "scale", "UpdateSystemSettingSize")
	add("TimerBars", "EditModeTimerBarsSetting", "Size", "scale", "UpdateSystemSettingSize")
	add("VehicleSeatIndicator", "EditModeVehicleSeatIndicatorSetting", "Size", "scale", "UpdateSystemSettingSize")
	add("ArchaeologyBar", "EditModeArchaeologyBarSetting", "Size", "scale", "UpdateSystemSettingSize")
	add("GroupFinder", "EditModeGroupFinderSetting", "Size", "scale", "UpdateSystemSettingSize")
	add("LossOfControl", "EditModeLossOfControlSetting", "Size", "scale", "UpdateSystemSettingSize")
	add("SwingTimer", "EditModeSwingTimerSetting", "Scale", "scale", "UpdateSystemSettingScale")
	add("SwingTimer", "EditModeSwingTimerSetting", "Opacity", "alpha", "UpdateSystemSettingOpacity")
	add("CastBar", "EditModeCastBarSetting", "BarSize", "scale", "UpdateSystemSettingBarSize", castBarSize)
	add("UnitFrame", "EditModeUnitFrameSetting", "FrameSize", "scale", "UpdateSystemSettingFrameSize", unitFrameSize)
	add("UnitFrame", "EditModeUnitFrameSetting", "Opacity", "alpha", "UpdateSystemSettingOpacity", unitFrameOpacity)
	add("AuraFrame", "EditModeAuraFrameSetting", "Opacity", "alpha", "UpdateSystemSettingOpacity")
	add("CooldownViewer", "EditModeCooldownViewerSetting", "Opacity", "alpha", "UpdateSystemSettingOpacity")
	add("PersonalResourceDisplay", "EditModePersonalResourceDisplaySetting", "Opacity", "alpha", "UpdateSystemSettingOpacity")
	return list
end

local function GetSpec(frame, setting)
	local system = supported and frame and supported[frame.system]
	return system and system[setting]
end

local function SystemKey(frame)
	return tostring(frame.system) .. ":" .. tostring(frame.systemIndex or 0)
end

local function GetOverrides(frame, create)
	local layout = ns:GetLayoutDB(create)
	if not layout then
		return nil
	end
	if not layout.overrides then
		if not create then
			return nil
		end
		layout.overrides = {}
	end
	local key = SystemKey(frame)
	local overrides = layout.overrides[key]
	if not overrides and create then
		overrides = {}
		layout.overrides[key] = overrides
	end
	return overrides
end

-- Removes a typed value. Returns true if there was one. A frame without typed values keeps no
-- record, and a layout without any keeps no overrides table.
local function ClearOverride(frame, setting)
	local overrides = GetOverrides(frame, false)
	if not (overrides and overrides[setting]) then
		return false
	end
	overrides[setting] = nil
	if not next(overrides) then
		local layout = ns:GetLayoutDB(false)
		layout.overrides[SystemKey(frame)] = nil
		if not next(layout.overrides) then
			layout.overrides = nil
		end
	end
	return true
end

local function FormatValue(value)
	if not value then
		return ""
	end
	if value == math.floor(value) then
		return string.format("%d", value)
	end
	return (string.format("%.2f", value):gsub("0+$", ""):gsub("%.$", ""))
end

-- Applying -------------------------------------------------------------------------

local ApplyAllOverrides, SettleFrame -- defined below; re-run after combat
local applied = {} -- frame -> { [setting] = true }: settings we've changed with a typed value

-- Returns the typed value for this setting if it's still valid (the slider hasn't moved since).
local function GetActiveOverride(frame, setting)
	local overrides = GetOverrides(frame, false)
	local override = overrides and overrides[setting]
	if not override then
		return nil
	end
	local useRawValue = true
	if frame:GetSettingValue(setting, useRawValue) ~= override.raw then
		return nil
	end
	return override.value
end

-- Whether the typed value can be applied to this frame right now.
local function CanApply(frame, spec)
	if spec.check and not spec.check(frame) then
		return false
	end
	-- In its default position a managed frame is laid out by its container, and Blizzard's scale
	-- change re-runs that layout (ManageFramePositions), which addon code must not call.
	if spec.kind == "scale" and frame.isManagedFrame and frame.IsInDefaultPosition and frame:IsInDefaultPosition() then
		return false
	end
	return true
end

-- Blizzard replaces SetScale on system frames with SetScaleOverride, Lua that keeps the frame in
-- place by re-setting its points through its own SetPoint override, which records snapping and
-- marks Edit Mode's anchors dirty. Run from here, that code would run tainted. So: the original
-- widget SetScale, then the same offset compensation with the original widget SetPoint.
local function SetScaleKeepingPosition(frame, scale)
	local oldScale = frame:GetScale()
	local setScale = frame.SetScaleBase or frame.SetScale
	setScale(frame, scale)
	if oldScale == scale then
		return
	end
	local setPoint = frame.SetPointBase or frame.SetPoint
	for i = 1, frame:GetNumPoints() do
		local point, relativeTo, relativePoint, x, y = frame:GetPoint(i)
		setPoint(frame, point, relativeTo, relativePoint, x * oldScale / scale, y * oldScale / scale)
	end
end

-- Same widget call Blizzard's handler makes, with our value.
local function ApplyValue(frame, setting, value)
	local spec = GetSpec(frame, setting)
	if not spec or not value or (spec.kind == "scale" and value <= 0) then
		return
	end
	-- GetSettingValue returns 0 for frames that aren't set up yet.
	if (frame.IsInitialized and not frame:IsInitialized()) or not frame:HasSetting(setting) then
		return
	end
	if not CanApply(frame, spec) then
		return
	end
	if InCombatLockdown() and frame:IsProtected() then
		ns:RunAfterCombat(ApplyAllOverrides, frame)
		return
	end
	applied[frame] = applied[frame] or {}
	applied[frame][setting] = true
	if spec.kind == "scale" then
		SetScaleKeepingPosition(frame, value / 100)
	else
		frame:SetAlpha(value / 100)
	end
end

local function ApplyOverride(frame, setting)
	local value = GetActiveOverride(frame, setting)
	if value then
		ApplyValue(frame, setting, value)
	end
end

ApplyAllOverrides = function(frame)
	local system = supported and supported[frame.system]
	if system then
		for setting in pairs(system) do
			ApplyOverride(frame, setting)
		end
	end
end

-- After a layout switch or revert, Blizzard only re-applies settings whose step changed, so a
-- typed value from before could linger. Put back whatever should be shown now.
-- Puts back what should show for each setting we've changed on this frame: the typed value if it's
-- active and can apply, otherwise Blizzard's value. Blizzard re-applies a setting only when its slider
-- step changed, so after a layout switch, a revert or a return to the default position a typed value
-- would otherwise linger.
local function RestoreFrame(frame)
	local settings = applied[frame]
	if not settings then
		return
	end
	for setting in pairs(settings) do
		local spec = GetSpec(frame, setting)
		local typed = GetActiveOverride(frame, setting)
		if spec and CanApply(frame, spec) then
			ApplyValue(frame, setting, typed or frame:GetSettingValue(setting))
		elseif spec and spec.kind == "scale" and frame:HasSetting(setting) then
			-- A managed frame back in its default position: its container places it, so only the
			-- scale goes back to Blizzard's value. Nothing of ours applies anymore.
			if InCombatLockdown() and frame:IsProtected() then
				ns:RunAfterCombat(SettleFrame, frame)
			else
				local setScale = frame.SetScaleBase or frame.SetScale
				setScale(frame, frame:GetSettingValue(setting) / 100)
				settings[setting] = nil
			end
		end
	end
end

-- Everything this module shows on the frame, settled: Blizzard's value where ours no longer
-- applies, then each typed value that does.
SettleFrame = function(frame)
	RestoreFrame(frame)
	ApplyAllOverrides(frame)
end

local function RestoreApplied()
	for frame in pairs(applied) do
		RestoreFrame(frame)
	end
end

local hookedFrames = {}

local function HookSystemFrame(frame)
	local system = supported and supported[frame.system]
	if not system or hookedFrames[frame] then
		return
	end
	hookedFrames[frame] = true
	for setting, spec in pairs(system) do
		if type(frame[spec.method]) == "function" then
			hooksecurefunc(frame, spec.method, function(self)
				ApplyOverride(self, setting)
			end)
		end
	end
	-- Re-anchoring can change whether a typed value applies (a managed frame entering or leaving
	-- its default position) without any setting handler running.
	if type(frame.ApplySystemAnchor) == "function" then
		hooksecurefunc(frame, "ApplySystemAnchor", SettleFrame)
	end
end

function M:IsFineTunable(frame, setting)
	local spec = GetSpec(frame, setting)
	local info = spec and frame.settingDisplayInfoMap and frame.settingDisplayInfoMap[setting]
	if not info or info.type ~= Enum.EditModeSettingDisplayType.Slider then
		return false
	end
	return CanApply(frame, spec)
end

-- Stores and applies a typed value. A value on the slider's own step just clears the override.
function M:SetValue(frame, setting, value)
	local current = frame:GetSettingValue(setting)
	if value == current then
		ClearOverride(frame, setting)
	else
		local useRawValue = true
		GetOverrides(frame, true)[setting] = { value = value, raw = frame:GetSettingValue(setting, useRawValue) }
	end
	ApplyValue(frame, setting, value)
end

-- Value shown in the input box: the typed value if active, otherwise the slider's.
local function GetShownValue(frame, setting)
	return GetActiveOverride(frame, setting) or frame:GetSettingValue(setting)
end

-- Slider input boxes ---------------------------------------------------------
-- Kept in a local table, not as fields on Blizzard's pooled slider frames.

local inputs = setmetatable({}, { __mode = "k" }) -- slider frame -> box

local function RefreshInput(box)
	if box.systemFrame and box.setting then
		box:SetText(FormatValue(GetShownValue(box.systemFrame, box.setting)))
		box:SetCursorPosition(0)
	end
end

local function CommitInput(box)
	local frame, setting = box.systemFrame, box.setting
	if not frame or not setting then
		return
	end
	if InCombatLockdown() and frame:IsProtected() then
		UIErrorsFrame:AddMessage(ERR_NOT_IN_COMBAT, 1, 0.1, 0.1)
		RefreshInput(box)
		return
	end

	local text = box:GetText():gsub("[%%%s]", ""):gsub(",", ".")
	local value = tonumber(text)
	if not value then
		RefreshInput(box)
		return
	end

	local spec = GetSpec(frame, setting)
	value = math.floor(value * 100 + 0.5) / 100
	if spec.kind == "alpha" then
		value = math.max(0, math.min(100, value))
	else
		value = math.max(10, math.min(400, value))
	end

	M:SetValue(frame, setting, value)
	RefreshInput(box)
end

local function CreateInput(sliderFrame)
	local box = CreateFrame("EditBox", nil, sliderFrame, "InputBoxTemplate")
	box:SetSize(40, 20)
	box:SetAutoFocus(false)
	box:SetJustifyH("CENTER")
	box:SetMaxLetters(7)
	box:SetPoint("LEFT", sliderFrame.Slider, "RIGHT", 6, 0)

	box:SetScript("OnEnterPressed", function(self)
		CommitInput(self)
		self:ClearFocus()
	end)
	box:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	box:SetScript("OnEditFocusLost", RefreshInput)
	box:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("TinyTweaks")
		GameTooltip:AddLine("Type any value and press Enter.", 1, 1, 1, true)
		GameTooltip:AddLine("Moving the slider replaces it again.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	box:SetScript("OnLeave", GameTooltip_Hide)

	inputs[sliderFrame] = box
	return box
end

local function DecorateSlider(sliderFrame, systemFrame)
	local box = inputs[sliderFrame]
	local rightText = sliderFrame.Slider and sliderFrame.Slider.RightText

	if not M:IsFineTunable(systemFrame, sliderFrame.setting) then
		if box then
			box:Hide()
		end
		if rightText then
			rightText:SetAlpha(1)
		end
		return
	end

	box = box or CreateInput(sliderFrame)
	box.systemFrame = systemFrame
	box.setting = sliderFrame.setting
	if rightText then
		-- Alpha instead of Hide: the slider re-shows its label whenever the value changes.
		rightText:SetAlpha(0)
	end
	if not box:HasFocus() then
		RefreshInput(box)
	end
	box:Show()
end

local function DecorateDialog(dialog)
	local systemFrame = dialog.attachedToSystem
	if not systemFrame then
		return
	end
	local pool = dialog:GetSettingPool(Enum.EditModeSettingDisplayType.Slider)
	if not pool then
		return
	end
	for sliderFrame in pool:EnumerateActive() do
		DecorateSlider(sliderFrame, systemFrame)
	end
end

-- Init ---------------------------------------------------------------------------------

function M:Init()
	ns:WhenLoaded("Blizzard_EditMode", function()
		supported = BuildSupported()

		-- Typed values from the earlier version for sliders that are no longer supported.
		for _, layout in pairs(ns.db.layouts) do
			for key, overrides in pairs(layout.overrides or {}) do
				local system = supported[tonumber(key:match("^(%-?%d+):"))]
				for setting in pairs(overrides) do
					if not (system and system[setting]) then
						overrides[setting] = nil
					end
				end
				if not next(overrides) then
					layout.overrides[key] = nil
				end
			end
			if layout.overrides and not next(layout.overrides) then
				layout.overrides = nil
			end
		end

		ns:ForEachSystemFrame(function(frame)
			HookSystemFrame(frame)
			ApplyAllOverrides(frame)
		end)

		hooksecurefunc(EditModeSystemSettingsDialog, "UpdateSettings", DecorateDialog)
		hooksecurefunc(EditModeManagerFrame, "UpdateSystems", RestoreApplied)

		-- The user moved a Blizzard control: the typed value for that setting is no longer wanted.
		-- Blizzard skips re-applying when the slider lands on the same step, so put its value back
		-- ourselves (the same widget call its handler makes).
		hooksecurefunc(EditModeSystemSettingsDialog, "OnSettingValueChanged", function(dialog, setting)
			local frame = dialog.attachedToSystem
			if frame and ClearOverride(frame, setting) then
				ApplyValue(frame, setting, frame:GetSettingValue(setting))
			end
		end)
	end)
end
