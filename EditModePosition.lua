--[[
	Edit Mode position offsets, relative to the pin.

	The pin is where Blizzard's Edit Mode put the frame: the point it snapped to (screen center, a
	screen edge, a grid line, another frame) or where it was dropped. Blizzard's layout keeps the pin
	unchanged. TinyTweaks stores an X/Y offset from the pin per layout and frame, and applies it after
	Blizzard positions the frame. Offset 0/0 is exactly the pin.

	  * Moving the frame in Edit Mode (drag, arrow keys) makes a new pin and resets the offset to 0.
	  * The offset only applies while Blizzard's stored anchor still equals the pin it was made for;
	    resetting or re-pinning the frame drops it.
	  * The offset is saved right away (SavedVariables); Edit Mode's Save button isn't involved.
	    Without TinyTweaks, the frame sits at its pin.

	Taint notes: this module never writes into Blizzard tables and never calls Blizzard Edit Mode
	functions. It only reads Blizzard state, moves frames with their original widget SetPoint
	(SetPointBase, bypassing Blizzard's override), and uses hooksecurefunc post-hooks. The panel is
	parented to UIParent (not to the dialog), so Blizzard's layout code never iterates over it.
	Calling Blizzard's position code from here (e.g. OnSystemPositionChange) would run the whole
	settings dialog tainted, which breaks native settings like the raid frame size.
]]

local _, ns = ...

local M = {}
table.insert(ns.modules, M)

local EPSILON = 0.05

local panel

-- Row: label, slider, value box. The box's border art reaches ~6px outside it.
local LABEL_WIDTH = 90
local SLIDER_WIDTH = 180
local BOX_WIDTH = 48
local ROW_WIDTH = LABEL_WIDTH + 5 + SLIDER_WIDTH + 10 + BOX_WIDTH + 6
local PANEL_MIN_WIDTH = ROW_WIDTH + 2 * 24
local pendingAfterCombat = {}

local function Round1(value)
	return math.floor(value * 10 + 0.5) / 10
end

local function FormatNumber(value)
	value = Round1(value)
	if value == math.floor(value) then
		return string.format("%d", value)
	end
	return string.format("%.1f", value)
end

local function SystemKey(frame)
	return tostring(frame.system) .. ":" .. tostring(frame.systemIndex or 0)
end

-- Storage ------------------------------------------------------------------------------
-- layout.positions[systemKey] = { x, y, pin = { point, relativeTo, relativePoint, offsetX, offsetY }, label }
-- `pin` is a copy of Blizzard's anchorInfo the record was made for; `label` describes what it snapped to.

local function GetRecords(create)
	local layout = ns:GetLayoutDB(create)
	if not layout then
		return nil
	end
	if not layout.positions and create then
		layout.positions = {}
	end
	return layout.positions
end

local function GetAnchorInfo(frame)
	local info = frame.systemInfo
	if not info or info.isInDefaultPosition or info.anchorInfo2 or not info.anchorInfo then
		return nil
	end
	return info.anchorInfo
end

local function SamePin(pin, anchorInfo)
	return pin and anchorInfo
		and pin.point == anchorInfo.point
		and pin.relativeTo == anchorInfo.relativeTo
		and pin.relativePoint == anchorInfo.relativePoint
		and math.abs(pin.offsetX - anchorInfo.offsetX) < EPSILON
		and math.abs(pin.offsetY - anchorInfo.offsetY) < EPSILON
end

local function CopyPin(anchorInfo)
	return {
		point = anchorInfo.point,
		relativeTo = anchorInfo.relativeTo,
		relativePoint = anchorInfo.relativePoint,
		offsetX = anchorInfo.offsetX,
		offsetY = anchorInfo.offsetY,
	}
end

-- The record for the frame's current pin, or nil.
local function GetRecord(frame)
	local records = GetRecords(false)
	local record = records and records[SystemKey(frame)]
	if record and SamePin(record.pin, GetAnchorInfo(frame)) then
		return record
	end
	return nil
end

-- Applying -------------------------------------------------------------------------------

-- Puts the frame at its pin plus the offset. Blizzard's anchor (the pin) must already be applied.
local function ApplyOffset(frame)
	local anchorInfo = GetAnchorInfo(frame)
	if not anchorInfo or frame:GetNumPoints() ~= 1 then
		return
	end
	if InCombatLockdown() and frame:IsProtected() then
		pendingAfterCombat[frame] = true
		return
	end
	local record = GetRecord(frame)
	local dx, dy = 0, 0
	if record then
		dx, dy = record.x or 0, record.y or 0
	end
	local point, relativeTo, relativePoint = frame:GetPoint(1)
	if point ~= anchorInfo.point or relativePoint ~= anchorInfo.relativePoint then
		return
	end
	-- anchorInfo offsets are at 1.0 scale; the frame's point offsets are in its own scale.
	local scale = frame:GetScale()
	local setPoint = frame.SetPointBase or frame.SetPoint
	setPoint(frame, point, relativeTo, relativePoint, (anchorInfo.offsetX + dx) / scale, (anchorInfo.offsetY + dy) / scale)
end

local function SetOffset(frame, axis, value)
	local anchorInfo = GetAnchorInfo(frame)
	if not anchorInfo then
		return
	end
	local records = GetRecords(true)
	if not records then
		return
	end
	-- No record for the current pin yet (pinned before TinyTweaks saw it): start one.
	local record = GetRecord(frame) or { x = 0, y = 0, pin = CopyPin(anchorInfo) }
	record[axis] = Round1(value)
	records[SystemKey(frame)] = record
	ApplyOffset(frame)
end

-- Pin labels ----------------------------------------------------------------------------

local REGION_NAMES = {
	CENTER = "center",
	TOP = "top edge",
	BOTTOM = "bottom edge",
	LEFT = "left edge",
	RIGHT = "right edge",
	TOPLEFT = "top-left corner",
	TOPRIGHT = "top-right corner",
	BOTTOMLEFT = "bottom-left corner",
	BOTTOMRIGHT = "bottom-right corner",
}

local function RegionName(point)
	return REGION_NAMES[point] or point:lower()
end

local function FrameName(frame)
	if type(frame) == "string" then
		frame = _G[frame] or frame
	end
	if type(frame) == "string" then
		return frame
	end
	if frame.systemNameString and frame.GetSystemName then
		return frame:GetSystemName()
	end
	return frame:GetName() or frame:GetDebugName() or "?"
end

-- "Below Player Frame", "Right of Minimap", "Player Frame, center".
local function DescribeFrameSnap(point, frame, relativePoint)
	local name = FrameName(frame)
	if point:find("^TOP") and relativePoint:find("^BOTTOM") then
		return "Below " .. name
	elseif point:find("^BOTTOM") and relativePoint:find("^TOP") then
		return "Above " .. name
	elseif point:find("LEFT$") and relativePoint:find("RIGHT$") then
		return "Right of " .. name
	elseif point:find("RIGHT$") and relativePoint:find("LEFT$") then
		return "Left of " .. name
	end
	return name .. ", " .. RegionName(relativePoint)
end

-- One magnetism result (see EditModeMagnetismManager) as text.
local function DescribeSnapInfo(info)
	if info.frame ~= UIParent then
		return DescribeFrameSnap(info.point, info.frame, info.relativePoint)
	end
	if (info.offset or 0) ~= 0 then
		return "Grid line"
	end
	if info.point ~= info.relativePoint then
		return "Screen center line"
	end
	return "Screen " .. RegionName(info.relativePoint)
end

local function JoinLabels(labels)
	local unique, seen = {}, {}
	for _, label in ipairs(labels) do
		if not seen[label] then
			seen[label] = true
			unique[#unique + 1] = label
		end
	end
	if #unique == 0 then
		return "Nothing (placed freely)"
	end
	if #unique == 1 and labels[2] == "Grid line" then
		return "Grid lines"
	end
	return table.concat(unique, " and ")
end

-- Label for a pin made before TinyTweaks saw it snap.
local function GuessLabel(anchorInfo)
	if anchorInfo.relativeTo ~= "UIParent" then
		return DescribeFrameSnap(anchorInfo.point, anchorInfo.relativeTo, anchorInfo.relativePoint)
	end
	if math.abs(anchorInfo.offsetX) < EPSILON and math.abs(anchorInfo.offsetY) < EPSILON then
		return "Screen " .. RegionName(anchorInfo.relativePoint)
	end
	return "Saved position"
end

local function GetPinLabel(frame, anchorInfo)
	local records = GetRecords(false)
	local record = records and records[SystemKey(frame)]
	if record and record.label and SamePin(record.pin, anchorInfo) then
		return record.label
	end
	return GuessLabel(anchorInfo)
end

-- Blizzard hooks ----------------------------------------------------------------------

local snapsDuringMove = {} -- frame -> magnetism results since the last position change

local function OnSnapToFrame(frame, info)
	if type(info) == "table" then
		snapsDuringMove[frame] = snapsDuringMove[frame] or {}
		table.insert(snapsDuringMove[frame], DescribeSnapInfo(info))
	end
end

-- Blizzard stored a new position for the frame (drag, arrow keys, ...): that's a new pin.
local function OnSystemPositionChange(frame)
	local labels = snapsDuringMove[frame] or {}
	snapsDuringMove[frame] = nil
	local anchorInfo = GetAnchorInfo(frame)
	local records = GetRecords(anchorInfo ~= nil)
	if records then
		local key = SystemKey(frame)
		if anchorInfo then
			records[key] = { x = 0, y = 0, pin = CopyPin(anchorInfo), label = JoinLabels(labels) }
		else
			records[key] = nil
		end
	end
	M:UpdatePanel()
end

local hookedFrames = {}

local function HookSystemFrame(frame)
	if hookedFrames[frame] or type(frame.ApplySystemAnchor) ~= "function" then
		return
	end
	hookedFrames[frame] = true
	hooksecurefunc(frame, "ApplySystemAnchor", ApplyOffset)
	if type(frame.SnapToFrame) == "function" then
		hooksecurefunc(frame, "SnapToFrame", OnSnapToFrame)
	end
	if type(frame.OnSystemPositionChange) == "function" then
		hooksecurefunc(frame, "OnSystemPositionChange", OnSystemPositionChange)
	end
	-- The frame may already be positioned (addon loaded after Edit Mode set it up).
	if frame.systemInfo then
		ApplyOffset(frame)
	end
end

-- Panel -------------------------------------------------------------------------------------

local function GetBlockedReason(frame)
	if frame.isLocked or not frame.systemInfo then
		return "Locked", "This frame can't be moved."
	end
	if frame.systemInfo.isInDefaultPosition then
		return "Default position", "Blizzard positions this frame. Drag it once to pin it, then adjust the offset here."
	end
	if not GetAnchorInfo(frame) or frame:GetNumPoints() ~= 1 then
		return "Two anchor points", "This frame is stretched between two points; it has no single pin."
	end
	return nil
end

-- Fixed range centered on the pin, so 0 is always the middle of the slider. A typed value outside it
-- widens the range symmetrically.
local SLIDER_RANGE = 200

local function GetRange(current)
	local range = math.max(SLIDER_RANGE, math.ceil(math.abs(current)))
	return -range, range
end

local function CommitOffset(axis, value)
	local frame = EditModeSystemSettingsDialog.attachedToSystem
	if not frame or GetBlockedReason(frame) then
		return
	end
	if InCombatLockdown() and frame:IsProtected() then
		UIErrorsFrame:AddMessage(ERR_NOT_IN_COMBAT, 1, 0.1, 0.1)
		return
	end
	SetOffset(frame, axis, value)
	M:UpdatePanel()
end

local function UpdateOffsetRow(row, frame, editable)
	row.Label:SetFontObject(editable and "GameFontHighlightMedium" or "GameFontDisableMed2")
	row.Slider:SetEnabled(editable)
	row.Box:SetEnabled(editable)
	row.Box:SetAlpha(editable and 1 or 0.5)

	local value = 0
	if editable then
		local record = GetRecord(frame)
		value = record and record[row.axis] or 0
	end
	if not row.Slider.Slider:IsDraggingThumb() then
		local minValue, maxValue = GetRange(value)
		row.initInProgress = true
		row.Slider:Init(value, minValue, maxValue, maxValue - minValue, {})
		row.initInProgress = false
	end
	if not row.Box:HasFocus() then
		row.Box:SetText(editable and FormatNumber(value) or "")
		row.Box:SetCursorPosition(0)
	end
end

function M:UpdatePanel()
	if not panel then
		return
	end
	local dialog = EditModeSystemSettingsDialog
	local frame = dialog:IsShown() and dialog.attachedToSystem
	if not frame then
		panel:Hide()
		return
	end
	panel:Show()
	panel:SetWidth(math.max(dialog:GetWidth(), PANEL_MIN_WIDTH))

	local reason, explanation = GetBlockedReason(frame)
	if reason then
		panel.Pin.Value:SetText(reason)
		panel.Pin.Value:SetFontObject("GameFontDisable")
		panel.Pin.tooltip = explanation
	else
		local anchorInfo = GetAnchorInfo(frame)
		panel.Pin.Value:SetText(GetPinLabel(frame, anchorInfo))
		panel.Pin.Value:SetFontObject("GameFontHighlight")
		panel.Pin.tooltip = "Where Edit Mode placed this frame. X and Y Offset move it from here; 0 is exactly the pin."
			.. "\n\nDrag the frame to pin it somewhere else (the offset resets to 0)."
	end

	UpdateOffsetRow(panel.X, frame, not reason)
	UpdateOffsetRow(panel.Y, frame, not reason)
end

local function ShowTooltip(owner, title, text)
	GameTooltip:SetOwner(owner, "ANCHOR_TOP")
	GameTooltip:SetText(title)
	GameTooltip:AddLine(text, 1, 1, 1, true)
	GameTooltip:Show()
end

local function CreateRow(previous, labelText, height)
	local row = CreateFrame("Frame", nil, panel)
	row:SetSize(ROW_WIDTH, height)
	row:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -2)
	row.Label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightMedium")
	row.Label:SetSize(LABEL_WIDTH, height)
	row.Label:SetPoint("LEFT")
	row.Label:SetJustifyH("LEFT")
	row.Label:SetText(labelText)
	return row
end

local function CreatePinRow(previous)
	local row = CreateRow(previous, "Pinned to", 24)
	row.Value = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	row.Value:SetPoint("LEFT", row.Label, "RIGHT", 5, 0)
	row.Value:SetPoint("RIGHT")
	row.Value:SetJustifyH("LEFT")
	row.Value:SetWordWrap(false)
	if row.SetMouseMotionEnabled then
		row:SetMouseMotionEnabled(true)
	else
		row:EnableMouse(true)
	end
	row:SetScript("OnEnter", function(self)
		if self.tooltip then
			ShowTooltip(self, "Pinned to", self.tooltip)
		end
	end)
	row:SetScript("OnLeave", GameTooltip_Hide)
	return row
end

local function CreateOffsetRow(previous, labelText, axis, hint)
	local row = CreateRow(previous, labelText, 32)
	row.axis = axis

	-- Same layout as Blizzard's EditModeSettingSliderTemplate, with a value box like EditModeFineTune's.
	local slider = CreateFrame("Frame", nil, row, "MinimalSliderWithSteppersTemplate")
	slider:SetSize(SLIDER_WIDTH, 32)
	slider:SetPoint("LEFT", row.Label, "RIGHT", 5, 0)
	slider:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, value)
		if not row.initInProgress then
			CommitOffset(axis, value)
		end
	end, row)
	row.Slider = slider

	local box = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	box:SetSize(BOX_WIDTH, 20)
	box:SetPoint("LEFT", slider, "RIGHT", 10, 0)
	box:SetAutoFocus(false)
	box:SetJustifyH("CENTER")
	box:SetMaxLetters(7)
	box:SetScript("OnEnterPressed", function(self)
		local value = tonumber((self:GetText():gsub("%s", ""):gsub(",", ".")))
		if value then
			CommitOffset(axis, value)
		end
		self:ClearFocus()
	end)
	box:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	box:SetScript("OnEditFocusLost", function()
		M:UpdatePanel()
	end)
	box:SetScript("OnEnter", function(self)
		ShowTooltip(self, labelText, hint .. "\nDrag the slider, or type any value and press Enter.")
	end)
	box:SetScript("OnLeave", GameTooltip_Hide)
	row.Box = box

	return row
end

local function CreatePanel(dialog)
	-- Parented to UIParent and only anchored to the dialog: a child of the dialog would be iterated by
	-- its ResizeLayoutFrame code, which taints the dialog.
	panel = CreateFrame("Frame", nil, UIParent)
	panel:SetFrameStrata(dialog:GetFrameStrata())
	panel:SetFrameLevel(dialog:GetFrameLevel())
	panel:SetPoint("TOP", dialog, "BOTTOM", 0, 2)
	panel:SetWidth(PANEL_MIN_WIDTH)
	panel:SetHeight(140)
	panel:EnableMouse(true)
	panel:Hide()

	local border = CreateFrame("Frame", nil, panel, "DialogBorderTranslucentTemplate")
	border:SetAllPoints()

	panel.Title = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
	panel.Title:SetPoint("TOP", 0, -15)
	panel.Title:SetText("Position")

	-- Rows are centered; the panel is as wide as the dialog, or wider when the dialog is narrow.
	local top = CreateFrame("Frame", nil, panel)
	top:SetSize(ROW_WIDTH, 1)
	top:SetPoint("TOP", panel.Title, "BOTTOM", 0, -8)

	panel.Pin = CreatePinRow(top)
	panel.X = CreateOffsetRow(panel.Pin, "X Offset", "x", "Distance from the pin. Positive moves right, negative moves left.")
	panel.Y = CreateOffsetRow(panel.X, "Y Offset", "y", "Distance from the pin. Positive moves up, negative moves down.")
end

-- Init -------------------------------------------------------------------------------

function M:Init()
	ns:WhenLoaded("Blizzard_EditMode", function()
		for _, frame in ipairs(EditModeManagerFrame.registeredSystemFrames) do
			HookSystemFrame(frame)
		end
		hooksecurefunc(EditModeManagerFrame, "RegisterSystemFrame", function(_, frame)
			HookSystemFrame(frame)
		end)

		local dialog = EditModeSystemSettingsDialog
		CreatePanel(dialog)
		hooksecurefunc(dialog, "UpdateDialog", function()
			M:UpdatePanel()
		end)
		-- AttachToSystemFrame updates the dialog before showing it.
		dialog:HookScript("OnShow", function()
			M:UpdatePanel()
		end)
		dialog:HookScript("OnHide", function()
			panel:Hide()
		end)

		ns:On("PLAYER_REGEN_ENABLED", function()
			for frame in pairs(pendingAfterCombat) do
				pendingAfterCombat[frame] = nil
				ApplyOffset(frame)
			end
		end)
	end)
end
