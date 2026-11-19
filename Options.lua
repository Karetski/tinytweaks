--[[
	Options: the TinyTweaks page in the game's settings (Options → AddOns) and a minimap button that
	opens it. The page holds addon-wide settings; per-frame settings stay next to the Edit Mode dialog.

	  * Minimap button: on the minimap's edge; click opens the page, drag moves it around the edge.
	    "Show minimap button" on the page hides it.

	Stored (account-wide, not per layout): TinyTweaksDB.minimap = { hide = true?, angle = degrees? },
	absent while everything is at its default (shown, at DEFAULT_ANGLE).

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

local function OpenPage()
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

local function CreatePage()
	page = CreateFrame("Frame")
	page:Hide() -- shown by the settings panel, so each display runs OnShow

	local title = page:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText(TITLE)

	local version = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	version:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	version:SetText("Version " .. tostring(C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")))

	if button then
		local show = CreateCheckbox(page, "Show minimap button")
		show:SetPoint("TOPLEFT", version, "BOTTOMLEFT", -4, -16)
		show:SetScript("OnClick", function(self)
			SetMinimapValue("hide", not self:GetChecked() or nil)
			button:SetShown(self:GetChecked())
		end)
		page.ShowButton = show
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
