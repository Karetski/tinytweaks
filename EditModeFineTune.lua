--[[
	Edit Mode fine-tuning: type any value into Edit Mode sliders.

	Blizzard stores each slider as a step index (e.g. action bar icon size 50-200% in 10% steps),
	so finer values can't live in the Blizzard layout. Instead:
	  * The Blizzard layout keeps the nearest step (so the layout still looks right without this addon).
	  * The exact value is stored in TinyTweaksDB per layout/system/setting, together with the raw
	    step it was made against.
	  * After Blizzard builds a system's settingMap, the override replaces displayValue. That's the value
	    every Blizzard UpdateSystemSetting* function reads via GetSettingValue, so Blizzard's own code
	    applies it.
	  * An override is only used while the Blizzard raw value still matches. Moving the slider, reverting,
	    or resetting the layout makes it inactive, and moving the slider deletes it.
]]

local _, ns = ...

local M = {}
table.insert(ns.modules, M)

-- Slider settings that are counts (rows, icons, limits). Fractional values make no sense there.
local excluded

local function BuildExcluded()
	local ex = {}
	local function add(systemKey, enumName, settingKey)
		local system = Enum.EditModeSystem[systemKey]
		local settingEnum = Enum[enumName]
		if system and settingEnum and settingEnum[settingKey] ~= nil then
			ex[system] = ex[system] or {}
			ex[system][settingEnum[settingKey]] = true
		end
	end
	add("ActionBar", "EditModeActionBarSetting", "NumRows")
	add("ActionBar", "EditModeActionBarSetting", "NumIcons")
	add("UnitFrame", "EditModeUnitFrameSetting", "RowSize")
	add("AuraFrame", "EditModeAuraFrameSetting", "IconLimitBuffFrame")
	add("AuraFrame", "EditModeAuraFrameSetting", "IconLimitDebuffFrame")
	add("CooldownViewer", "EditModeCooldownViewerSetting", "IconLimit")
	return ex
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

local function FormatValue(value)
	if not value then
		return ""
	end
	if value == math.floor(value) then
		return string.format("%d", value)
	end
	return (string.format("%.2f", value):gsub("0+$", ""):gsub("%.$", ""))
end

-- Writes active overrides into a freshly built settingMap. When oldMap is given (layout switch /
-- full system update), settings whose effective value changed are marked dirty so Blizzard re-applies them.
local function ApplyOverrides(frame, oldMap)
	local map = frame.settingMap
	if not map then
		return
	end

	local overrides = GetOverrides(frame, false)
	if overrides then
		for setting, override in pairs(overrides) do
			local entry = map[setting]
			if entry and entry.value == override.raw then
				entry.displayValue = override.value
			end
		end
	end

	if oldMap and frame.dirtySettings then
		for setting, entry in pairs(map) do
			local old = oldMap[setting]
			if old and old.displayValue ~= entry.displayValue then
				frame.dirtySettings[setting] = true
			end
		end
	end
end

local hookedFrames = {}

local function HookSystemFrame(frame)
	if hookedFrames[frame] or type(frame.UpdateSettingMap) ~= "function" then
		return
	end
	hookedFrames[frame] = true
	hooksecurefunc(frame, "UpdateSettingMap", function(self)
		ApplyOverrides(self)
	end)
	if type(frame.UpdateDirtySettings) == "function" then
		hooksecurefunc(frame, "UpdateDirtySettings", ApplyOverrides)
	end
end

function M:IsFineTunable(frame, setting)
	local info = frame and frame.settingDisplayInfoMap and frame.settingDisplayInfoMap[setting]
	if not info or info.type ~= Enum.EditModeSettingDisplayType.Slider then
		return false
	end
	if info.isCompositeNumberSetting or info.hideValue then
		return false
	end
	local ex = excluded and excluded[frame.system]
	return not (ex and ex[setting])
end

function M:ClearOverride(frame, setting)
	local overrides = frame and GetOverrides(frame, false)
	if overrides then
		overrides[setting] = nil
	end
end

function M:SetValue(frame, setting, value)
	local info = frame.settingDisplayInfoMap[setting]
	local step = info.stepSize or 1
	local minValue, maxValue = info.minValue, info.maxValue

	-- Nearest value the Blizzard slider can represent; that's what goes into the Blizzard layout.
	local stepped = minValue + math.floor((value - minValue) / step + 0.5) * step
	stepped = math.min(maxValue, math.max(minValue, stepped))
	local raw = frame:ConvertSettingDisplayValueToRawValue(setting, stepped)

	if value == stepped then
		self:ClearOverride(frame, setting)
	else
		GetOverrides(frame, true)[setting] = { value = value, raw = raw }
	end

	local useRawValue = true
	if frame:GetSettingValue(setting, useRawValue) ~= raw then
		-- Same path the slider uses; marks the layout as changed so Save works as usual.
		EditModeManagerFrame:OnSystemSettingChange(frame, setting, stepped)
	else
		-- Raw step unchanged, so force Blizzard to re-apply this setting with the new display value.
		frame:UpdateSystemSetting(setting)
	end
end

-- Slider input boxes ---------------------------------------------------------

local function RefreshInput(box)
	if box.systemFrame and box.setting then
		box:SetText(FormatValue(box.systemFrame:GetSettingValue(box.setting)))
		box:SetCursorPosition(0)
	end
end

local function CommitInput(box)
	local frame, setting = box.systemFrame, box.setting
	if not frame or not setting then
		return
	end
	if InCombatLockdown() then
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

	-- Paddings/offsets may go to 0; sizes, scales and opacities stay above 0.
	local info = frame.settingDisplayInfoMap[setting]
	local lowerBound = (info.minValue or 0) <= 10 and 0 or 1
	value = math.max(lowerBound, math.floor(value * 100 + 0.5) / 100)

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

	sliderFrame.TinyTweaksInput = box
	return box
end

local function DecorateSlider(sliderFrame, systemFrame)
	local box = sliderFrame.TinyTweaksInput
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

function M:Init()
	ns:WhenLoaded("Blizzard_EditMode", function()
		excluded = BuildExcluded()

		for _, frame in ipairs(EditModeManagerFrame.registeredSystemFrames) do
			HookSystemFrame(frame)
		end
		hooksecurefunc(EditModeManagerFrame, "RegisterSystemFrame", function(_, frame)
			HookSystemFrame(frame)
		end)

		hooksecurefunc(EditModeSystemSettingsDialog, "UpdateSettings", DecorateDialog)

		-- The user moved a Blizzard control: an override for that setting is no longer wanted.
		hooksecurefunc(EditModeSystemSettingsDialog, "OnSettingValueChanged", function(dialog, setting)
			local frame = dialog.attachedToSystem
			local overrides = frame and GetOverrides(frame, false)
			if overrides and overrides[setting] then
				overrides[setting] = nil
				-- If the slider landed on the same step the override was based on, Blizzard saw no change
				-- and the override value is still applied; re-apply with the plain step value.
				local entry = frame.settingMap and frame.settingMap[setting]
				if entry and entry.displayValue ~= frame.settingDisplayInfoMap[setting]:ConvertValueForDisplay(entry.value) then
					frame:UpdateSystemSetting(setting)
				end
			end
		end)
	end)
end
