--[[
	Raid group grid: lay out the 5 members of each raid group as a grid
	(e.g. 3+2) with a chosen fill order and flow direction.

	Only applies in "Separate Groups" mode. Settings are stored per Edit Mode layout.

	Taint notes: this module never writes into Blizzard tables or calls Blizzard code that does.
	It only moves frames with widget APIs after Blizzard's own layout has run (hooksecurefunc).
	Raid frames are protected, so nothing is moved in combat. Changes made in combat (e.g. roster
	changes) fall back to Blizzard's layout until combat ends, then the grid is re-applied.
]]

local _, ns = ...

local M = {}
table.insert(ns.modules, M)

local DEFAULTS = {
	enabled = false,
	perLine = 3,       -- members per row (rows first) or per column (columns first)
	fill = "rows",     -- "rows" | "columns"
	hDir = "right",    -- "right" (left to right) | "left" (right to left)
	vDir = "down",     -- "down" (top to bottom) | "up" (bottom to top)
	spacing = 0,
}

local function GetConfig(create)
	local layout = ns:GetLayoutDB(create)
	if not layout then
		return CopyTable(DEFAULTS)
	end
	local cfg = layout.raidGrid
	if not cfg and create then
		cfg = CopyTable(DEFAULTS)
		layout.raidGrid = cfg
	end
	if cfg then
		for k, v in pairs(DEFAULTS) do
			if cfg[k] == nil then
				cfg[k] = v
			end
		end
	end
	return cfg or DEFAULTS
end

function M:IsActive()
	return GetConfig().enabled
		and CompactRaidFrameContainer ~= nil
		and CompactRaidFrameContainer:GetGroupMode() == "discrete"
end

local pendingAfterCombat = false
local gridApplied = false -- whether any group currently uses the grid (so disabling restores Blizzard's layout)

-- Group layout -----------------------------------------------------------------

local function LayoutGroup(group)
	local cfg = GetConfig()
	local name = group:GetName()
	local members = {}
	local used = 1
	for i = 1, MEMBERS_PER_RAID_GROUP do
		local member = _G[name .. "Member" .. i]
		members[i] = member
		if member:IsShown() or i <= (group.minUnitFrames or 0) then
			used = i
		end
	end

	local perLine = math.max(1, math.min(MEMBERS_PER_RAID_GROUP, math.floor(cfg.perLine or 3)))
	local rowsFirst = cfg.fill ~= "columns"
	local cols, rows
	if rowsFirst then
		cols, rows = math.min(used, perLine), math.ceil(used / perLine)
	else
		rows, cols = math.min(used, perLine), math.ceil(used / perLine)
	end

	local w, h = members[1]:GetSize()
	local spacing = cfg.spacing or 0
	local gridW = cols * w + (cols - 1) * spacing
	local gridH = rows * h + (rows - 1) * spacing
	local titleH = group.title:GetHeight()
	local border = group.borderFrame:IsShown()
	local originX, originY = border and 2 or 0, -titleH

	group.title:ClearAllPoints()
	group.title:SetPoint("TOPLEFT")

	for i, member in ipairs(members) do
		local index = i - 1
		local col, row
		if rowsFirst then
			col, row = index % perLine, math.floor(index / perLine)
		else
			row, col = index % perLine, math.floor(index / perLine)
		end
		if cfg.hDir == "left" then
			col = cols - 1 - col
		end
		if cfg.vDir == "up" then
			row = rows - 1 - row
		end
		member:ClearAllPoints()
		member:SetPoint("TOPLEFT", group, "TOPLEFT", originX + col * (w + spacing), originY - row * (h + spacing))
	end

	if border then
		group.borderFrame:ClearAllPoints()
		group.borderFrame:SetPoint("TOPLEFT", group, "TOPLEFT", originX - 2, originY + 2)
		group.borderFrame:SetPoint("BOTTOMRIGHT", group, "TOPLEFT", originX + gridW + 2, originY - gridH - 3)
	end

	group:SetSize(gridW + (border and 4 or 0), titleH + gridH + (border and 3 or 0))
	gridApplied = true
end

-- Container flow ---------------------------------------------------------------
-- Read-only port of FlowContainer_DoLayout. Group sizes change after Blizzard has already flowed
-- the groups, so the groups are re-anchored here without touching the container's Lua state.

local function ReflowContainer()
	local container = CompactRaidFrameContainer
	if container.flowPauseUpdates or not container.flowFrames then
		return
	end

	local horizontal = container.flowOrientation == "horizontal"
	local primary, secondary = "GetHeight", "GetWidth"
	local primarySpacing = container.flowVerticalSpacing or 0
	local secondarySpacing = container.flowHorizontalSpacing or 0
	if horizontal then
		primary, secondary = "GetWidth", "GetHeight"
		primarySpacing, secondarySpacing = secondarySpacing, primarySpacing
	end

	local startSecondary = container.startingSecondaryOffset or 0
	local startPrimary = container.startingPrimaryOffset or 0
	local maxPerLine = container.flowMaxPerLine
	local containerPrimarySize = container[primary](container)
	local gamepad = InputUtil and InputUtil.IsGamepadUIEnabled and InputUtil:IsGamepadUIEnabled()

	local primaryLine = 1
	local secondaryOffset, primaryOffset = startSecondary, startPrimary
	local lineMaxSize = 0
	local atomicStart, atomicAtBeginning
	local targetVerticalOffset
	local lastObject, lastObjectType
	local maxX, maxY = 0, 0

	local i = 1
	while i <= #container.flowFrames do
		local object = container.flowFrames[i]
		local objectType = container.flowFrameTypes[i]
		local restart = false

		if objectType == "linebreak" or (objectType == "object" and (
			object.isFlowGroup
			or (lastObject and lastObjectType == "object" and lastObject.isFlowGroup)
			or (maxPerLine and primaryLine > maxPerLine)
			or secondaryOffset + object[primary](object) > containerPrimarySize))
		then
			if not (atomicStart and atomicAtBeginning) then
				secondaryOffset = startSecondary
				primaryLine = 1
				primaryOffset = primaryOffset + lineMaxSize + secondarySpacing
				lineMaxSize = 0
				if atomicStart then
					i = atomicStart
					atomicAtBeginning = true
					restart = true
				end
			end
		end

		if not restart then
			if objectType == "object" then
				local xOffset = secondaryOffset
				if gamepad and object.frameType == "flagged" then
					xOffset = xOffset + 14
				end

				local left, top
				if horizontal then
					left, top = xOffset, primaryOffset + (targetVerticalOffset or 0)
					if object.frameType == "target" and not targetVerticalOffset then
						targetVerticalOffset = object[secondary](object)
					else
						targetVerticalOffset = nil
					end
				else
					left, top = primaryOffset, xOffset
				end
				object:ClearAllPoints()
				object:SetPoint("TOPLEFT", container, "TOPLEFT", left, -top)
				if object:IsShown() then
					maxX = math.max(maxX, left + object:GetWidth())
					maxY = math.max(maxY, top + object:GetHeight())
				end

				if not targetVerticalOffset then
					secondaryOffset = secondaryOffset + object[primary](object) + primarySpacing
				end
				if object.frameType ~= "flagged" and object.frameType ~= "target" then
					primaryLine = primaryLine + 1
				end
				lineMaxSize = math.max(lineMaxSize, object[secondary](object))
			elseif objectType == "spacer" then
				secondaryOffset = secondaryOffset + object
			elseif objectType == "primarySpacer" then
				primaryOffset = primaryOffset + object
			elseif objectType == "beginatomic" then
				if secondaryOffset == 0 then
					atomicAtBeginning = true
				end
				atomicStart = i + 1
			elseif objectType == "endatomic" then
				atomicStart, atomicAtBeginning = nil, nil
			end
			i = i + 1
		end

		lastObject, lastObjectType = object, objectType
	end

	-- Keep the Edit Mode selection box roughly matching the content.
	if maxX > 0 and maxY > 0 then
		container:SetSize(maxX, maxY)
	end
end

-- Refresh ------------------------------------------------------------------------

local function ForEachGroup(fn)
	for i = 1, NUM_RAID_GROUPS do
		local group = _G["CompactRaidGroup" .. i]
		if group then
			fn(group)
		end
	end
end

-- Re-applies the grid (or Blizzard's layout if disabled) to all groups and re-flows the container.
function M:Refresh()
	if not CompactRaidFrameContainer then
		return
	end
	if InCombatLockdown() then
		pendingAfterCombat = true
		return
	end
	if CompactRaidFrameContainer:GetGroupMode() ~= "discrete" then
		return
	end

	if self:IsActive() then
		ForEachGroup(LayoutGroup)
	elseif gridApplied then
		-- Restore Blizzard's layout. The original function only uses widget APIs.
		ForEachGroup(CompactRaidGroup_UpdateLayout)
		gridApplied = false
	else
		return
	end
	ReflowContainer()
end

local refreshScheduled = false
function M:ScheduleRefresh()
	if refreshScheduled then
		return
	end
	refreshScheduled = true
	C_Timer.After(0, function()
		refreshScheduled = false
		M:Refresh()
	end)
end

local hookedGroups = {}

local function OnGroupLayout(group)
	if not M:IsActive() then
		return
	end
	if InCombatLockdown() then
		pendingAfterCombat = true
		return
	end
	LayoutGroup(group)
	M:ScheduleRefresh()
end

local function HookGroup(group)
	if group and not hookedGroups[group] and type(group.updateLayoutFunc) == "function" then
		hookedGroups[group] = true
		hooksecurefunc(group, "updateLayoutFunc", OnGroupLayout)
	end
end

-- Settings panel ---------------------------------------------------------------------

local panel

local CYCLES = {
	fill = { { "rows", "Rows first" }, { "columns", "Columns first" } },
	hDir = { { "right", "Left to right" }, { "left", "Right to left" } },
	vDir = { { "down", "Top to bottom" }, { "up", "Bottom to top" } },
}

local function CycleLabel(key, value)
	for _, option in ipairs(CYCLES[key]) do
		if option[1] == value then
			return option[2]
		end
	end
	return CYCLES[key][1][2]
end

local function CycleNext(key, value)
	local options = CYCLES[key]
	for i, option in ipairs(options) do
		if option[1] == value then
			return options[i % #options + 1][1]
		end
	end
	return options[1][1]
end

local function OnConfigChanged()
	M:Refresh()
	M:UpdatePanel()
end

local function CreateRow(parent, previous, labelText)
	local row = CreateFrame("Frame", nil, parent)
	row:SetSize(240, 26)
	row:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -4)
	row.Label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	row.Label:SetPoint("LEFT")
	row.Label:SetText(labelText)
	return row
end

local function CreateCycleRow(parent, previous, labelText, key)
	local row = CreateRow(parent, previous, labelText)
	local button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	button:SetSize(130, 22)
	button:SetPoint("RIGHT")
	button:SetScript("OnClick", function()
		local cfg = GetConfig(true)
		cfg[key] = CycleNext(key, cfg[key])
		OnConfigChanged()
	end)
	row.Update = function(_, cfg, enabled)
		button:SetText(CycleLabel(key, cfg[key]))
		button:SetEnabled(enabled)
	end
	return row
end

local function CreateNumberRow(parent, previous, labelText, key, minValue, maxValue)
	local row = CreateRow(parent, previous, labelText)
	local box = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	box:SetSize(40, 20)
	box:SetPoint("RIGHT", -4, 0)
	box:SetAutoFocus(false)
	box:SetJustifyH("CENTER")
	box:SetMaxLetters(3)
	local function Commit(self)
		local value = tonumber(self:GetText())
		if value then
			local cfg = GetConfig(true)
			cfg[key] = math.max(minValue, math.min(maxValue, math.floor(value)))
			OnConfigChanged()
		end
		self:SetText(tostring(GetConfig()[key]))
	end
	box:SetScript("OnEnterPressed", function(self)
		Commit(self)
		self:ClearFocus()
	end)
	box:SetScript("OnEscapePressed", function(self)
		self:SetText(tostring(GetConfig()[key]))
		self:ClearFocus()
	end)
	box:SetScript("OnEditFocusLost", function(self)
		self:SetText(tostring(GetConfig()[key]))
	end)
	row.Update = function(_, cfg, enabled)
		if not box:HasFocus() then
			box:SetText(tostring(cfg[key]))
		end
		box:SetEnabled(enabled)
		box:SetAlpha(enabled and 1 or 0.5)
	end
	return row
end

local function CreatePanel(dialog)
	panel = CreateFrame("Frame", nil, dialog)
	panel:SetSize(280, 270)
	panel:SetPoint("TOPRIGHT", dialog, "TOPLEFT", -4, 0)
	panel:EnableMouse(true)

	local border = CreateFrame("Frame", nil, panel, "DialogBorderTranslucentTemplate")
	border:SetAllPoints()

	panel.Title = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
	panel.Title:SetPoint("TOP", 0, -15)
	panel.Title:SetText("Group Layout")

	local enable = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	enable:SetPoint("TOPLEFT", 16, -40)
	enable.Text:SetFontObject("GameFontHighlight")
	enable.Text:SetText("Grid inside each group")
	enable:SetScript("OnClick", function(self)
		GetConfig(true).enabled = self:GetChecked()
		OnConfigChanged()
	end)
	panel.Enable = enable

	local rows = {}
	rows[#rows + 1] = CreateNumberRow(panel, enable, "Members per line", "perLine", 1, MEMBERS_PER_RAID_GROUP)
	rows[1]:SetPoint("TOPLEFT", enable, "BOTTOMLEFT", 4, -4)
	rows[#rows + 1] = CreateCycleRow(panel, rows[#rows], "Fill", "fill")
	rows[#rows + 1] = CreateCycleRow(panel, rows[#rows], "Horizontal", "hDir")
	rows[#rows + 1] = CreateCycleRow(panel, rows[#rows], "Vertical", "vDir")
	rows[#rows + 1] = CreateNumberRow(panel, rows[#rows], "Spacing", "spacing", 0, 50)
	panel.rows = rows

	panel.Note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	panel.Note:SetPoint("TOPLEFT", rows[#rows], "BOTTOMLEFT", 0, -8)
	panel.Note:SetWidth(240)
	panel.Note:SetJustifyH("LEFT")
end

function M:UpdatePanel()
	if not panel then
		return
	end
	local dialog = EditModeSystemSettingsDialog
	local isRaid = dialog.attachedToSystem ~= nil and dialog.attachedToSystem == CompactRaidFrameContainer
	panel:SetShown(isRaid)
	if not isRaid then
		return
	end

	local cfg = GetConfig()
	local separate = CompactRaidFrameContainer:GetGroupMode() == "discrete"
	panel.Enable:SetChecked(cfg.enabled)
	panel.Enable:SetEnabled(separate)
	for _, row in ipairs(panel.rows) do
		row:Update(cfg, separate and cfg.enabled)
	end
	if not separate then
		panel.Note:SetText("Only applies when Groups is set to Separate.")
	elseif InCombatLockdown() then
		panel.Note:SetText("Changes apply after combat.")
	else
		panel.Note:SetText("Saved per Edit Mode layout.")
	end
end

-- Init -------------------------------------------------------------------------------

function M:Init()
	ns:WhenLoaded("Blizzard_CompactRaidFrames", function()
		ns:WhenLoaded("Blizzard_EditMode", function()
			ForEachGroup(HookGroup)
			hooksecurefunc("CompactRaidGroup_GenerateForGroup", function(groupIndex)
				local group = _G["CompactRaidGroup" .. groupIndex]
				if group and not hookedGroups[group] then
					HookGroup(group)
					OnGroupLayout(group)
				end
			end)

			-- Blizzard re-flowed the container (roster change, setting change, layout switch).
			hooksecurefunc(CompactRaidFrameContainer, "LayoutFrames", function()
				if M:IsActive() then
					M:ScheduleRefresh()
				end
			end)
			hooksecurefunc(EditModeManagerFrame, "UpdateRaidContainerFlow", function()
				M:ScheduleRefresh()
				M:UpdatePanel()
			end)

			CreatePanel(EditModeSystemSettingsDialog)
			hooksecurefunc(EditModeSystemSettingsDialog, "UpdateSettings", function()
				M:UpdatePanel()
			end)

			ns:On("PLAYER_REGEN_ENABLED", function()
				if pendingAfterCombat then
					pendingAfterCombat = false
					M:Refresh()
				end
			end)
			-- Layout switched or reloaded: the new layout may have different grid settings.
			hooksecurefunc(EditModeManagerFrame, "UpdateSystems", function()
				M:ScheduleRefresh()
				M:UpdatePanel()
			end)
		end)
	end)
end
