--[[
	Options: the TinyTweaks page in the game's settings (Options → AddOns) and a minimap button that
	opens it. The page holds addon-wide settings; per-frame settings stay next to the Edit Mode dialog.

	  * Minimap button: on the minimap's edge; click opens the page, drag moves it around the edge.
	    "Show minimap button" on the page hides it.
	  * Debug: only when the dev recorder (!TinyTweaksDev) is installed. "Record debug sessions"
	    enables or disables the recorder for every character and saves that at once (the AddOns
	    list reverts unsaved changes when it closes without Okay); turning it off also turns taint
	    logging off at once (the recorder turns it on when it loads). The recorder change takes
	    effect on reload, which the page offers while the setting differs from what is loaded.

	Stored (account-wide, not per layout): TinyTweaksDB.minimap = { hide = true?, angle = degrees? },
	absent while everything is at its default (shown, at DEFAULT_ANGLE). The recorder's enable state
	is the client's own; nothing about it is stored here.

	Taint notes: the page is an addon frame registered with Settings.RegisterCanvasLayoutCategory and
	Settings.RegisterAddOnCategory, which hand it to the panel through Blizzard's forbidden delegate;
	the panel reparents it into its canvas while it is displayed. The page is opened only with
	Settings.OpenToCategory, which opens the panel as secure code; SettingsPanel's own Open and
	OpenToCategory would run ShowUIPanel and the panel tainted. The button is parented to Minimap,
	never to MinimapCluster (an Edit Mode system and resize-layout frame that walks its children).
	The page sets no fields Blizzard reads (OnRefresh, OnCommit, OnDefault) and uses no StaticPopup,
	whose dialogs live in a Blizzard table.
]]

local ADDON_NAME, ns = ...

local M = {}
table.insert(ns.modules, M)

local TITLE = "TinyTweaks"
local RECORDER = "!TinyTweaksDev"
local DEFAULT_ANGLE = 225 -- degrees, counterclockwise from the right: bottom left
local BUTTON_SIZE = 31
local EDGE_OFFSET = 10 -- button center beyond the minimap's radius

local category
local page
local button

-- Storage -------------------------------------------------------------------------------------

local function GetMinimapDB(create)
	local db = ns.db.minimap
	if not db and create then
		db = {}
		ns.db.minimap = db
	end
	return db
end

-- Stores one value (nil clears it) and drops the table once nothing differs from the defaults.
local function SetMinimapValue(key, value)
	local db = GetMinimapDB(true)
	db[key] = value
	if next(db) == nil then
		ns.db.minimap = nil
	end
end

-- Compute ---------------------------------------------------------------------------------------

local function ButtonOffset(angle, radius)
	local rad = math.rad(angle)
	return math.cos(rad) * radius, math.sin(rad) * radius
end

local function CursorAngle(x, y, centerX, centerY)
	return math.deg(math.atan2(y - centerY, x - centerX)) % 360
end

local function RoundAngle(angle)
	return math.floor(angle * 10 + 0.5) / 10 % 360
end

-- Apply -----------------------------------------------------------------------------------------

local function PlaceButton(angle)
	local x, y = ButtonOffset(angle, Minimap:GetWidth() / 2 + EDGE_OFFSET)
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function SavedAngle()
	local db = GetMinimapDB()
	return db and db.angle or DEFAULT_ANGLE
end

-- The client blocks opening the settings panel from addon code in combat.
local function OpenPage()
	if InCombatLockdown() then
		UIErrorsFrame:AddMessage(ERR_NOT_IN_COMBAT, 1, 0.1, 0.1)
		return
	end
	Settings.OpenToCategory(category:GetID())
end

-- Minimap button --------------------------------------------------------------------------------

local dragAngle

local function OnDragUpdate()
	local scale = Minimap:GetEffectiveScale()
	local x, y = GetCursorPosition()
	local centerX, centerY = Minimap:GetCenter()
	local angle = CursorAngle(x / scale, y / scale, centerX, centerY)
	if angle ~= dragAngle then
		dragAngle = angle
		PlaceButton(angle)
	end
end

local function CreateButton()
	button = CreateFrame("Button", nil, Minimap)
	button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetSize(24, 24)
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	background:SetPoint("CENTER")
	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetSize(18, 18)
	icon:SetTexture("Interface\\Icons\\INV_Misc_Gear_01")
	icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
	icon:SetPoint("CENTER")
	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetSize(53, 53)
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetPoint("TOPLEFT")

	button:SetScript("OnClick", OpenPage)
	button:SetScript("OnEnter", function(self)
		ns:ShowTooltip(self, TITLE, "Click to open settings. Drag to move.", "ANCHOR_LEFT")
	end)
	button:SetScript("OnLeave", GameTooltip_Hide)
	button:SetScript("OnDragStart", function(self)
		GameTooltip_Hide()
		dragAngle = nil
		self:SetScript("OnUpdate", OnDragUpdate)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
		if dragAngle then
			local angle = RoundAngle(dragAngle)
			SetMinimapValue("angle", angle ~= DEFAULT_ANGLE and angle or nil)
		end
		PlaceButton(SavedAngle())
	end)
	-- The drag's OnUpdate must not outlive it, even if the button hides before the drop.
	button:SetScript("OnHide", function(self)
		self:SetScript("OnUpdate", nil)
	end)

	PlaceButton(SavedAngle())
	local db = GetMinimapDB()
	button:SetShown(not (db and db.hide))
end

-- Page ------------------------------------------------------------------------------------------

local function CreateCheckbox(parent, label)
	local box = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	box.Text:SetFontObject("GameFontHighlight")
	box.Text:SetText(label)
	return box
end

-- What the debug section needs; without any of it the section isn't built.
local function HasAddOnAPI()
	return type(C_AddOns.DoesAddOnExist) == "function" and type(C_AddOns.GetAddOnEnableState) == "function"
		and type(C_AddOns.EnableAddOn) == "function" and type(C_AddOns.DisableAddOn) == "function"
		and type(C_AddOns.SaveAddOns) == "function" and Enum.AddOnEnableState ~= nil
		and C_CVar ~= nil and type(C_CVar.SetCVar) == "function" and type(ReloadUI) == "function"
end

local function IsRecorderEnabled()
	return C_AddOns.GetAddOnEnableState(RECORDER, UnitGUID("player")) > Enum.AddOnEnableState.None
end

-- Debug section, built only when the recorder is installed.
local function CreateDebugSection(anchor)
	local section = CreateFrame("Frame", nil, page)
	section:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -16)
	section:SetSize(400, 100)

	local header = section:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	header:SetPoint("TOPLEFT", 4, 0)
	header:SetText("Debug")

	local record = CreateCheckbox(section, "Record debug sessions")
	record:SetPoint("TOPLEFT", header, "BOTTOMLEFT", -4, -6)
	record:SetScript("OnClick", function(self)
		if self:GetChecked() then
			C_AddOns.EnableAddOn(RECORDER)
		else
			C_AddOns.DisableAddOn(RECORDER)
			C_CVar.SetCVar("taintLog", "0")
		end
		-- Unsaved, the change would be undone when the AddOns list closes without Okay.
		C_AddOns.SaveAddOns()
		M:UpdatePanel()
	end)
	record:SetScript("OnEnter", function(self)
		ns:ShowTooltip(self, "Record debug sessions", "Records Lua errors, blocked actions and frame state for testing, and turns on the taint log.")
	end)
	record:SetScript("OnLeave", GameTooltip_Hide)

	local reload = CreateFrame("Button", nil, section, "UIPanelButtonTemplate")
	reload:SetSize(120, 22)
	reload:SetPoint("TOPLEFT", record, "BOTTOMLEFT", 4, -4)
	reload:SetText("Reload UI")
	reload:SetScript("OnClick", function()
		ReloadUI()
	end)

	local note = section:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	note:SetPoint("LEFT", reload, "RIGHT", 8, 0)
	note:SetText("Reload to apply.")

	page.Record, page.Reload, page.ReloadNote = record, reload, note
end

local function CreatePage()
	page = CreateFrame("Frame")
	page:Hide() -- shown by the settings panel, so each display runs OnShow

	local title = page:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText(TITLE)

	local version = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	version:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	version:SetText("Version " .. tostring(C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")))

	local last = version
	if button then
		local show = CreateCheckbox(page, "Show minimap button")
		show:SetPoint("TOPLEFT", version, "BOTTOMLEFT", -4, -16)
		show:SetScript("OnClick", function(self)
			SetMinimapValue("hide", not self:GetChecked() or nil)
			button:SetShown(self:GetChecked())
		end)
		page.ShowButton = show
		last = show
	end

	if HasAddOnAPI() and C_AddOns.DoesAddOnExist(RECORDER) then
		CreateDebugSection(last)
	end

	page:SetScript("OnShow", function()
		M:UpdatePanel()
	end)
end

function M:UpdatePanel()
	if page.ShowButton then
		local db = GetMinimapDB()
		page.ShowButton:SetChecked(not (db and db.hide))
	end
	if page.Record then
		local enabled = IsRecorderEnabled()
		local pending = enabled ~= (C_AddOns.IsAddOnLoaded(RECORDER) and true or false)
		page.Record:SetChecked(enabled)
		page.Reload:SetShown(pending)
		page.ReloadNote:SetShown(pending)
	end
end

-- Init ------------------------------------------------------------------------------------------

local function HasSettingsAPI()
	return Settings and type(Settings.RegisterCanvasLayoutCategory) == "function"
		and type(Settings.RegisterAddOnCategory) == "function" and type(Settings.OpenToCategory) == "function"
end

function M:Init()
	if not HasSettingsAPI() then
		return
	end
	if Minimap then
		CreateButton()
	end
	CreatePage()
	category = Settings.RegisterCanvasLayoutCategory(page, TITLE)
	Settings.RegisterAddOnCategory(category)
end
