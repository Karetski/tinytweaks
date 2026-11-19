--[[
	Raid group grid: arrange the raid groups (1-8) in a grid.

	  Columns 4, across:  1 2 3 4 / 5 6 7 8
	  Columns 2, across:  1 2 / 3 4 / 5 6 / 7 8
	  Columns 2, down:    1 5 / 2 6 / 3 7 / 4 8
	  Start corner mirrors the grid (e.g. top right: 2 1 / 4 3 / ...).

	Each cell is as large as the largest group. Cells keep their place even when a group is empty
	or hidden, so groups never jump around.

	Only applies in "Separate Groups" mode. Settings are stored per Edit Mode layout.

	Taint notes: this module never writes into Blizzard tables, never sets fields on Blizzard frames,
	and never parents anything to Blizzard frames whose layout code iterates children. It only moves
	frames with widget APIs after Blizzard's own layout has run (hooksecurefunc). Raid frames are
	protected, so nothing is moved in combat. Changes made in combat (e.g. roster changes) fall back
	to Blizzard's layout until combat ends, then the grid is re-applied.
]]

local _, ns = ...

local M = {}
table.insert(ns.modules, M)

local DEFAULTS = {
	enabled = false,
	columns = 4,
	order = "across",   -- "across" (fill each row first) | "down" (fill each column first)
	corner = "TOPLEFT", -- where group 1 goes: TOPLEFT | TOPRIGHT | BOTTOMLEFT | BOTTOMRIGHT
	hSpacing = 0,
	vSpacing = 0,
}

-- Settings from earlier versions of this panel (perLine/fill/hDir/vDir, typed pattern).
local function Migrate(cfg)
	if cfg.perLine and cfg.columns == nil then
		local perLine = cfg.perLine
		if cfg.fill == "columns" then
			cfg.order = "down"
			cfg.columns = math.ceil(NUM_RAID_GROUPS / perLine)
		else
			cfg.order = "across"
			cfg.columns = perLine
		end
		cfg.corner = (cfg.vDir == "up" and "BOTTOM" or "TOP") .. (cfg.hDir == "left" and "RIGHT" or "LEFT")
	end
	cfg.perLine, cfg.fill, cfg.hDir, cfg.vDir, cfg.rows = nil, nil, nil, nil, nil
end

-- Brings every stored config up to date: earlier formats migrated, missing keys defaulted.
-- Idempotent; runs once at load, so reads never have to.
local function MigrateAll()
	for _, layout in pairs(ns.db.layouts) do
		layout.raidGrid = nil -- the earlier member-grid version of this module
		local cfg = layout.groupGrid
		if cfg then
			Migrate(cfg)
			for k, v in pairs(DEFAULTS) do
				if cfg[k] == nil then
					cfg[k] = v
				end
			end
		end
	end
end

local function GetConfig(create)
	local layout = ns:GetLayoutDB(create)
	if not layout then
		return DEFAULTS
	end
	local cfg = layout.groupGrid
	if not cfg and create then
		cfg = CopyTable(DEFAULTS)
		layout.groupGrid = cfg
	end
	return cfg or DEFAULTS
end

function M:IsActive()
	return GetConfig().enabled
		and CompactRaidFrameContainer ~= nil
		and CompactRaidFrameContainer:GetGroupMode() == "discrete"
end

-- Grid -------------------------------------------------------------------------------

-- Returns the grid's actual column and row count. With "down", some column counts give the
-- same grid (8 groups in 5, 6 or 7 columns all need 2 rows, so only 4 columns get used).
local function GetGridSize(columns, order)
	local count = NUM_RAID_GROUPS
	columns = math.max(1, math.min(count, math.floor(columns or 4)))
	local rows = math.ceil(count / columns)
	if order == "down" then
		columns = math.ceil(count / rows)
	end
	return columns, rows
end

-- Returns group index -> { row, col } (0-based).
local function GetCells(cfg)
	local cols, rows = GetGridSize(cfg.columns, cfg.order)
	local corner = cfg.corner or "TOPLEFT"
	local cells = {}
	for group = 1, NUM_RAID_GROUPS do
		local index = group - 1
		local row, col
		if cfg.order == "down" then
			row, col = index % rows, math.floor(index / rows)
		else
			row, col = math.floor(index / cols), index % cols
		end
		if corner:find("RIGHT$") then
			col = cols - 1 - col
		end
		if corner:find("^BOTTOM") then
			row = rows - 1 - row
		end
		cells[group] = { row, col }
	end
	return cells
end

-- Container flow -----------------------------------------------------------------------
-- Read-only port of FlowContainer_DoLayout. When the grid is active, all raid groups are replaced
-- by one virtual block (the grid) at the position of the first group, so flagged members, pets
-- etc. still flow around it. Without the grid this reproduces Blizzard's own layout.

local function GetGroupIndexes()
	local indexes = {}
	for i = 1, NUM_RAID_GROUPS do
		local group = _G["CompactRaidGroup" .. i]
		if group then
			indexes[group] = i
		end
	end
	return indexes
end

-- Group sizes at the last grid placement, to skip re-placing when nothing changed.
local lastSizes = {}

local function GetGroupSizes()
	local sizes = {}
	for i = 1, NUM_RAID_GROUPS do
		local group = _G["CompactRaidGroup" .. i]
		if group then
			local w, h = group:GetSize()
			sizes[i] = w .. "x" .. h
		end
	end
	return sizes
end

function M:GroupSizesChanged()
	for i, size in pairs(GetGroupSizes()) do
		if lastSizes[i] ~= size then
			return true
		end
	end
	return false
end

local function BuildGridBlock(container)
	lastSizes = GetGroupSizes()
	local cfg = GetConfig()
	local cells = GetCells(cfg)
	local indexes = GetGroupIndexes()
	local members = {}
	local first
	local cellW, cellH, maxRow, maxCol = 0, 0, 0, 0
	for i, object in ipairs(container.flowFrames) do
		local index = container.flowFrameTypes[i] == "object" and indexes[object]
		if index then
			local cell = cells[index]
			members[object] = cell
			first = first or object
			cellW = math.max(cellW, object:GetWidth())
			cellH = math.max(cellH, object:GetHeight())
			maxRow = math.max(maxRow, cell[1])
			maxCol = math.max(maxCol, cell[2])
		end
	end
	if not first then
		return nil
	end

	local hSpacing, vSpacing = cfg.hSpacing or 0, cfg.vSpacing or 0
	local width = (maxCol + 1) * cellW + maxCol * hSpacing
	local height = (maxRow + 1) * cellH + maxRow * vSpacing

	local block = { members = members, isFlowGroup = first.isFlowGroup }
	function block.GetWidth()
		return width
	end
	function block.GetHeight()
		return height
	end
	function block.IsShown()
		return true
	end
	function block.ClearAllPoints() end
	function block.SetPoint(_, point, relativeTo, relativePoint, left, top)
		for frame, cell in pairs(members) do
			frame:ClearAllPoints()
			frame:SetPoint(point, relativeTo, relativePoint,
				left + cell[2] * (cellW + hSpacing), top - cell[1] * (cellH + vSpacing))
		end
	end
	return block
end

local function ReflowContainer(useGrid)
	local container = CompactRaidFrameContainer
	if container.flowPauseUpdates or not container.flowFrames then
		return
	end

	local block = useGrid and BuildGridBlock(container)
	local blockPlaced, blockIndex = false, nil

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
	-- Blizzard always flows at 3000x3000 (LayoutFrames), then shrinks the container to fit.
	local containerPrimarySize = 3000
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
		local skip, restart = false, false

		if block and objectType == "object" and block.members[object] then
			if blockPlaced then
				skip = true -- already placed as part of the grid
			else
				blockIndex = i
			end
			object, blockPlaced = block, true
		end

		if skip then
			i = i + 1
		else
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
						if blockIndex and blockIndex >= atomicStart then
							blockPlaced = false -- the grid is inside the restarted section
						end
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
		end

		lastObject, lastObjectType = object, objectType
	end

	-- Keep the Edit Mode selection box roughly matching the content.
	if maxX > 0 and maxY > 0 then
		container:SetSize(maxX, maxY)
	end
end

-- Refresh ------------------------------------------------------------------------------

local gridApplied = false -- whether the grid is currently applied (so disabling restores Blizzard's layout)
local reflowing = false

-- Re-applies the grid (or Blizzard's layout if disabled) to the container.
function M:Refresh()
	if not CompactRaidFrameContainer then
		return
	end
	if reflowing then
		-- Our container resize made Blizzard re-flow; re-apply once it's done.
		self:ScheduleRefresh()
		return
	end
	if InCombatLockdown() then
		ns:RunAfterCombat(M.Refresh, M)
		return
	end
	if CompactRaidFrameContainer:GetGroupMode() ~= "discrete" then
		gridApplied = false -- Blizzard lays out the other modes from scratch
		return
	end

	local active = self:IsActive()
	if not active and not gridApplied then
		return
	end
	reflowing = true
	local ok, err = pcall(ReflowContainer, active)
	reflowing = false
	gridApplied = active
	if not ok then
		geterrorhandler()(err)
	end
end

-- Coalesces refreshes to one per frame. onlyIfResized: skip it if the group sizes are unchanged
-- since the last grid placement (any Blizzard re-flow already re-applies through LayoutFrames).
local refreshScheduled, refreshAlways = false, false
function M:ScheduleRefresh(onlyIfResized)
	refreshAlways = refreshAlways or not onlyIfResized
	if refreshScheduled then
		return
	end
	refreshScheduled = true
	C_Timer.After(0, function()
		local always = refreshAlways
		refreshScheduled, refreshAlways = false, false
		if always or M:GroupSizesChanged() then
			M:Refresh()
		end
	end)
end

-- Settings panel ---------------------------------------------------------------------

local panel

local PANEL_WIDTH = 280
local PANEL_BASE_HEIGHT = 250
local PREVIEW_CELL_W, PREVIEW_CELL_H, PREVIEW_GAP = 22, 16, 3
local SELECTED_COLOR = { 1, 0.82, 0 }

local CORNER_NAMES = {
	TOPLEFT = "Top left",
	TOPRIGHT = "Top right",
	BOTTOMLEFT = "Bottom left",
	BOTTOMRIGHT = "Bottom right",
}

local function OnConfigChanged()
	M:Refresh()
	M:UpdatePanel()
end

local function SetConfig(key, value)
	GetConfig(true)[key] = value
	OnConfigChanged()
end

local function CreateRow(parent, labelText, height)
	local row = CreateFrame("Frame", nil, parent)
	row:SetSize(PANEL_WIDTH - 40, height or 26)
	row.Label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	row.Label:SetPoint("TOPLEFT", 0, -5)
	row.Label:SetText(labelText)
	return row
end

-- Columns [-] 2 [+]  4 rows
local function CreateColumnsRow(parent)
	local row = CreateRow(parent, "Columns")
	local minus = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	minus:SetSize(24, 22)
	minus:SetPoint("LEFT", 70, 0)
	minus:SetText("-")
	local value = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	value:SetSize(26, 22)
	value:SetPoint("LEFT", minus, "RIGHT", 2, 0)
	local plus = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	plus:SetSize(24, 22)
	plus:SetPoint("LEFT", value, "RIGHT", 2, 0)
	plus:SetText("+")
	local rowsText = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	rowsText:SetPoint("LEFT", plus, "RIGHT", 8, 0)

	-- Steps to the next column count that actually changes the grid, and stores the count the grid
	-- uses, so the shown count stays when the order changes.
	local function Step(delta)
		local cfg = GetConfig(true)
		local current = GetGridSize(cfg.columns, cfg.order)
		local columns = current
		repeat
			columns = columns + delta
		until columns < 1 or columns > NUM_RAID_GROUPS or GetGridSize(columns, cfg.order) ~= current
		if columns >= 1 and columns <= NUM_RAID_GROUPS then
			SetConfig("columns", (GetGridSize(columns, cfg.order)))
		end
	end
	minus:SetScript("OnClick", function()
		Step(-1)
	end)
	plus:SetScript("OnClick", function()
		Step(1)
	end)

	row.Update = function(_, cfg, enabled)
		local cols, rows = GetGridSize(cfg.columns, cfg.order)
		value:SetText(tostring(cols))
		value:SetAlpha(enabled and 1 or 0.5)
		rowsText:SetText(rows == 1 and "1 row" or (rows .. " rows"))
		minus:SetEnabled(enabled and cols > 1)
		plus:SetEnabled(enabled and cols < NUM_RAID_GROUPS)
	end
	return row
end

-- Order [Across] [Down]
local function CreateOrderRow(parent)
	local row = CreateRow(parent, "Order")
	local buttons = {}
	local options = {
		{ "across", "Across", "Fill each row, then the next row." },
		{ "down", "Down", "Fill each column, then the next column." },
	}
	for i, option in ipairs(options) do
		local button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		button:SetSize(80, 22)
		button:SetPoint("LEFT", 70 + (i - 1) * 84, 0)
		button:SetText(option[2])
		button.value = option[1]
		button:SetScript("OnClick", function()
			SetConfig("order", option[1])
		end)
		button:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(option[2])
			GameTooltip:AddLine(option[3], 1, 1, 1, true)
			GameTooltip:Show()
		end)
		button:SetScript("OnLeave", GameTooltip_Hide)
		buttons[i] = button
	end
	row.Update = function(_, cfg, enabled)
		for _, button in ipairs(buttons) do
			local selected = button.value == cfg.order
			button:SetEnabled(enabled)
			if selected then
				button:LockHighlight()
				button:GetFontString():SetTextColor(unpack(SELECTED_COLOR))
			else
				button:UnlockHighlight()
				button:GetFontString():SetTextColor(1, 1, 1)
			end
			if not enabled then
				button:GetFontString():SetTextColor(0.5, 0.5, 0.5)
			end
		end
	end
	return row
end

-- Start: 2x2 corner picker. Each button is a small box with a dot in its corner.
local function CreateCornerRow(parent)
	local row = CreateRow(parent, "Start", 40)
	local name = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	local buttons = {}
	local size, gap = 26, 4
	local corners = { "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }
	for i, corner in ipairs(corners) do
		local button = CreateFrame("Button", nil, row)
		button:SetSize(size, 18)
		local col, r = (i - 1) % 2, math.floor((i - 1) / 2)
		button:SetPoint("TOPLEFT", 70 + col * (size + gap), -r * (18 + gap))
		button.Background = button:CreateTexture(nil, "BACKGROUND")
		button.Background:SetAllPoints()
		button.Dot = button:CreateTexture(nil, "ARTWORK")
		button.Dot:SetSize(7, 7)
		button.Dot:SetPoint(corner, corner:find("LEFT$") and 3 or -3, corner:find("^TOP") and -3 or 3)
		button.Dot:SetColorTexture(1, 1, 1)
		button:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight", "ADD")
		button.corner = corner
		button:SetScript("OnClick", function()
			SetConfig("corner", corner)
		end)
		button:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(CORNER_NAMES[corner])
			GameTooltip:AddLine("Group 1 goes in this corner.", 1, 1, 1, true)
			GameTooltip:Show()
		end)
		button:SetScript("OnLeave", GameTooltip_Hide)
		buttons[i] = button
	end
	name:SetPoint("LEFT", buttons[2], "RIGHT", 8, -11)
	row.Update = function(_, cfg, enabled)
		for _, button in ipairs(buttons) do
			local selected = button.corner == cfg.corner
			button:SetEnabled(enabled)
			if selected then
				button.Background:SetColorTexture(SELECTED_COLOR[1] * 0.6, SELECTED_COLOR[2] * 0.6, 0, enabled and 0.9 or 0.3)
			else
				button.Background:SetColorTexture(0.2, 0.2, 0.2, enabled and 0.9 or 0.3)
			end
			button.Dot:SetAlpha(enabled and (selected and 1 or 0.6) or 0.3)
		end
		name:SetText(CORNER_NAMES[cfg.corner] or "")
	end
	return row
end

local function CreateSpacingBox(row, key, labelText, anchor, x)
	local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	label:SetPoint("LEFT", anchor, anchor == row and "LEFT" or "RIGHT", x, 0)
	label:SetText(labelText)
	local box = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	box:SetSize(36, 20)
	box:SetPoint("LEFT", label, "RIGHT", 8, 0)
	box:SetAutoFocus(false)
	box:SetJustifyH("CENTER")
	box:SetMaxLetters(3)
	box:SetScript("OnEnterPressed", function(self)
		local value = tonumber(self:GetText())
		if value then
			SetConfig(key, math.max(0, math.min(100, math.floor(value))))
		end
		self:ClearFocus()
	end)
	box:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	box:SetScript("OnEditFocusLost", function(self)
		self:SetText(tostring(GetConfig()[key]))
	end)
	return box, label
end

-- Spacing  Horizontal [0]  Vertical [0]
local function CreateSpacingRow(parent)
	local row = CreateRow(parent, "Spacing")
	local hBox, hLabel = CreateSpacingBox(row, "hSpacing", "Horiz.", row, 70)
	local vBox, vLabel = CreateSpacingBox(row, "vSpacing", "Vert.", hBox, 14)
	row.Update = function(_, cfg, enabled)
		for box, key in pairs({ [hBox] = "hSpacing", [vBox] = "vSpacing" }) do
			if not box:HasFocus() then
				box:SetText(tostring(cfg[key]))
			end
			box:SetEnabled(enabled)
			box:SetAlpha(enabled and 1 or 0.5)
		end
		hLabel:SetAlpha(enabled and 1 or 0.5)
		vLabel:SetAlpha(enabled and 1 or 0.5)
	end
	return row
end

local function CreatePreview(parent)
	local preview = CreateFrame("Frame", nil, parent)
	preview:SetSize(PANEL_WIDTH - 40, PREVIEW_CELL_H)
	preview.cells = {}
	for group = 1, NUM_RAID_GROUPS do
		local cell = CreateFrame("Frame", nil, preview)
		cell:SetSize(PREVIEW_CELL_W, PREVIEW_CELL_H)
		cell.Background = cell:CreateTexture(nil, "BACKGROUND")
		cell.Background:SetAllPoints()
		cell.Text = cell:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		cell.Text:SetPoint("CENTER")
		cell.Text:SetText(tostring(group))
		preview.cells[group] = cell
	end
	preview.Update = function(self, cfg, enabled)
		local cols, rows = GetGridSize(cfg.columns, cfg.order)
		local gridW = cols * PREVIEW_CELL_W + (cols - 1) * PREVIEW_GAP
		local left = math.floor((self:GetWidth() - gridW) / 2) -- centered
		for group, cell in pairs(GetCells(cfg)) do
			local frame = self.cells[group]
			frame:ClearAllPoints()
			frame:SetPoint("TOPLEFT", left + cell[2] * (PREVIEW_CELL_W + PREVIEW_GAP), -cell[1] * (PREVIEW_CELL_H + PREVIEW_GAP))
			if group == 1 then
				frame.Background:SetColorTexture(SELECTED_COLOR[1] * 0.6, SELECTED_COLOR[2] * 0.6, 0, enabled and 0.9 or 0.3)
			else
				frame.Background:SetColorTexture(0.15, 0.35, 0.6, enabled and 0.8 or 0.3)
			end
			frame.Text:SetAlpha(enabled and 1 or 0.5)
		end
		local height = rows * PREVIEW_CELL_H + (rows - 1) * PREVIEW_GAP
		self:SetHeight(height)
		return height
	end
	return preview
end

local function CreatePanel(dialog)
	-- Not a child of the dialog: the dialog is a ResizeLayoutFrame, and anything Blizzard's layout
	-- code reads from our frames (or setting fields on them) taints the whole settings dialog.
	-- Parented to UIParent and shown/hidden alongside the dialog instead.
	panel = CreateFrame("Frame", nil, UIParent)
	panel:SetFrameStrata(dialog:GetFrameStrata())
	panel:SetFrameLevel(dialog:GetFrameLevel() + 10)
	panel:SetSize(PANEL_WIDTH, PANEL_BASE_HEIGHT)
	panel:SetPoint("TOPRIGHT", dialog, "TOPLEFT", -4, 0)
	panel:EnableMouse(true)
	panel:Hide()
	dialog:HookScript("OnHide", function()
		panel:Hide()
	end)
	-- AttachToSystemFrame fills in the settings (UpdateSettings) before it shows the dialog,
	-- so check again once it's shown.
	dialog:HookScript("OnShow", function()
		M:UpdatePanel()
	end)
	hooksecurefunc(dialog, "AttachToSystemFrame", function()
		M:UpdatePanel()
	end)

	local border = CreateFrame("Frame", nil, panel, "DialogBorderTranslucentTemplate")
	border:SetAllPoints()

	panel.Title = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
	panel.Title:SetPoint("TOP", 0, -15)
	panel.Title:SetText("Group Layout")

	local enable = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	enable:SetPoint("TOPLEFT", 16, -40)
	enable.Text:SetFontObject("GameFontHighlight")
	enable.Text:SetText("Arrange groups in a grid")
	enable:SetScript("OnClick", function(self)
		SetConfig("enabled", self:GetChecked())
	end)
	panel.Enable = enable

	local rows = {}
	local function AddRow(row, anchor, gap)
		row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", anchor == enable and 4 or 0, -(gap or 4))
		rows[#rows + 1] = row
		return row
	end
	local columns = AddRow(CreateColumnsRow(panel), enable, 6)
	local order = AddRow(CreateOrderRow(panel), columns)
	local corner = AddRow(CreateCornerRow(panel), order)

	local preview = CreatePreview(panel)
	preview:SetPoint("TOPLEFT", corner, "BOTTOMLEFT", 0, -10)
	panel.Preview = preview

	AddRow(CreateSpacingRow(panel), preview, 10)
	panel.rows = rows

	panel.Note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	panel.Note:SetPoint("TOPLEFT", rows[#rows], "BOTTOMLEFT", 0, -8)
	panel.Note:SetWidth(PANEL_WIDTH - 40)
	panel.Note:SetJustifyH("LEFT")
end

function M:UpdatePanel()
	if not panel then
		return
	end
	local dialog = EditModeSystemSettingsDialog
	local isRaid = dialog:IsShown() and dialog.attachedToSystem ~= nil
		and dialog.attachedToSystem == CompactRaidFrameContainer
	panel:SetShown(isRaid)
	if not isRaid then
		return
	end

	local cfg = GetConfig()
	local separate = CompactRaidFrameContainer:GetGroupMode() == "discrete"
	local enabled = separate and cfg.enabled
	panel.Enable:SetChecked(cfg.enabled)
	panel.Enable:SetEnabled(separate)
	for _, row in ipairs(panel.rows) do
		row:Update(cfg, enabled)
	end
	local previewHeight = panel.Preview:Update(cfg, enabled)
	panel:SetHeight(PANEL_BASE_HEIGHT + previewHeight)

	if not separate then
		panel.Note:SetText("Only applies when Groups is set to Separate.")
	elseif InCombatLockdown() then
		panel.Note:SetText("Changes apply after combat.")
	else
		panel.Note:SetText("Saved per Edit Mode layout.")
	end
end

-- Init -------------------------------------------------------------------------------

local hookedGroups = {}

local function HookGroup(group)
	if group and not hookedGroups[group] and type(group.updateLayoutFunc) == "function" then
		hookedGroups[group] = true
		-- Group size changed (e.g. frame width/height setting): cells must be re-measured.
		hooksecurefunc(group, "updateLayoutFunc", function()
			if M:IsActive() then
				M:ScheduleRefresh(true)
			end
		end)
	end
end

function M:Init()
	MigrateAll()

	ns:WhenLoaded("Blizzard_CompactRaidFrames", function()
		ns:WhenLoaded("Blizzard_EditMode", function()
			for i = 1, NUM_RAID_GROUPS do
				HookGroup(_G["CompactRaidGroup" .. i])
			end
			hooksecurefunc("CompactRaidGroup_GenerateForGroup", function(groupIndex)
				HookGroup(_G["CompactRaidGroup" .. groupIndex])
			end)

			-- Blizzard re-flowed the container (roster change, setting change, layout switch). Every
			-- Blizzard re-flow of the raid container ends in LayoutFrames, so re-apply right after it,
			-- once, in the same frame (no flicker). Hooking FlowContainer_DoLayout instead ran this
			-- dozens of times per slider step.
			hooksecurefunc(CompactRaidFrameContainer, "LayoutFrames", function()
				M:Refresh()
			end)
			hooksecurefunc(EditModeManagerFrame, "UpdateRaidContainerFlow", function()
				-- Normally ends in LayoutFrames (hooked above). If the container wasn't ready to lay
				-- out, Blizzard still re-flowed it when changing orientation, so re-apply later.
				if not CompactRaidFrameContainer:ReadyToUpdate() then
					M:ScheduleRefresh()
				end
				M:UpdatePanel()
			end)

			CreatePanel(EditModeSystemSettingsDialog)
			hooksecurefunc(EditModeSystemSettingsDialog, "UpdateSettings", function()
				M:UpdatePanel()
			end)
			-- Layout switched or reloaded: the new layout may have different grid settings.
			hooksecurefunc(EditModeManagerFrame, "UpdateSystems", function()
				M:ScheduleRefresh()
				M:UpdatePanel()
			end)
		end)
	end)
end
