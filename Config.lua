-- Roads of Azeroth by DinX: settings window
local _, ns = ...
local RoA = ns.RoA
local L = RoA.L
local S = RoA.Style

local C = RoA:NewModule("Config")

---------------------------------------------------------------------------
-- Widgets (flat, the same as in Casters of Azeroth)
---------------------------------------------------------------------------
local function changed(group)
	RoA:Fire("SETTINGS", group)
	if C.frame and C.frame:IsShown() then C:Refresh() end
end

local function tooltip(frame, text)
	if not text then return end
	frame:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(text, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	frame:SetScript("OnLeave", GameTooltip_Hide)
end

local Page = {}
Page.__index = Page

function Page:Header(text)
	local fs = S:Font(self.frame, 14)
	fs:SetPoint("TOPLEFT", 0, self.y)
	fs:SetText(text)
	fs:SetTextColor(unpack(S.colors.accent))
	self.y = self.y - 24
end

function Page:Note(text)
	local fs = self.frame:CreateFontString(nil, "OVERLAY")
	fs:SetFont(S.font, 11, "")
	fs:SetTextColor(unpack(S.colors.muted))
	fs:SetPoint("TOPLEFT", 0, self.y)
	fs:SetWidth(430)
	fs:SetJustifyH("LEFT")
	fs:SetText(text)
	self.y = self.y - math.max(16, fs:GetStringHeight() + 6)
	return fs
end

function Page:Check(label, tip, get, set)
	local b = CreateFrame("Button", nil, self.frame, "BackdropTemplate")
	b:SetSize(16, 16)
	b:SetPoint("TOPLEFT", 0, self.y)
	S:Backdrop(b, 1)
	local mark = b:CreateTexture(nil, "OVERLAY")
	mark:SetPoint("TOPLEFT", 3, -3)
	mark:SetPoint("BOTTOMRIGHT", -3, 3)
	mark:SetColorTexture(unpack(S.colors.accent))
	local fs = S:Font(b, 12)
	fs:SetPoint("LEFT", b, "RIGHT", 8, 0)
	fs:SetText(label)
	b:SetHitRectInsets(0, -fs:GetStringWidth() - 10, 0, 0)
	b.refresh = function() mark:SetShown(get() and true or false) end
	b:SetScript("OnClick", function() set(not get()); b.refresh() end)
	tooltip(b, tip)
	table.insert(self.widgets, b)
	self.y = self.y - 24
	return b
end

function Page:Slider(label, minV, maxV, step, get, set, fmt)
	local fs = S:Font(self.frame, 12)
	fs:SetPoint("TOPLEFT", 0, self.y)
	local s = CreateFrame("Slider", nil, self.frame, "BackdropTemplate")
	s:SetOrientation("HORIZONTAL")
	s:SetSize(220, 10)
	s:SetPoint("TOPLEFT", 200, self.y - 2)
	S:Backdrop(s, 1)
	s:SetThumbTexture(S.flat)
	local thumb = s:GetThumbTexture()
	thumb:SetSize(10, 14)
	thumb:SetVertexColor(unpack(S.colors.accent))
	s:SetMinMaxValues(minV, maxV)
	s:SetValueStep(step)
	s:SetObeyStepOnDrag(true)
	local val = S:Font(self.frame, 12)
	val:SetPoint("LEFT", s, "RIGHT", 10, 0)
	local function show(v) val:SetText(fmt and fmt(v) or tostring(v)); fs:SetText(label) end
	s.refresh = function()
		s.updating = true
		s:SetValue(get())
		show(get())
		s.updating = false
	end
	s:SetScript("OnValueChanged", function(_, v)
		if s.updating then return end
		v = math.floor(v / step + 0.5) * step
		show(v)
		set(v)
	end)
	table.insert(self.widgets, s)
	self.y = self.y - 28
	return s
end

-- Cycling choice: ◀ value ▶ (options may be a function returning the list)
function Page:Choice(label, opts, get, set)
	local options = opts
	local fs = S:Font(self.frame, 12)
	fs:SetPoint("TOPLEFT", 0, self.y)
	fs:SetText(label)
	local holder = CreateFrame("Frame", nil, self.frame, "BackdropTemplate")
	holder:SetSize(220, 20)
	holder:SetPoint("TOPLEFT", 200, self.y + 3)
	S:Backdrop(holder, 1)
	local text = S:Font(holder, 12)
	text:SetPoint("CENTER")
	local function step(dir)
		if type(opts) == "function" then options = opts() end
		if #options == 0 then return end
		local cur = get()
		local idx = 1
		for i, o in ipairs(options) do if o[1] == cur then idx = i end end
		idx = (idx - 1 + dir) % #options + 1
		set(options[idx][1])
		holder.refresh()
	end
	for _, d in ipairs({ { -1, "LEFT", "<" }, { 1, "RIGHT", ">" } }) do
		local a = CreateFrame("Button", nil, holder)
		a:SetSize(20, 20)
		a:SetPoint(d[2])
		local t = S:Font(a, 13)
		t:SetPoint("CENTER")
		t:SetText(d[3])
		t:SetTextColor(unpack(S.colors.accent))
		a:SetScript("OnClick", function() step(d[1]) end)
	end
	holder.refresh = function()
		if type(opts) == "function" then options = opts() end
		local cur = get()
		text:SetText("-")
		for _, o in ipairs(options) do if o[1] == cur then text:SetText(o[2]) end end
	end
	table.insert(self.widgets, holder)
	self.y = self.y - 28
	return holder
end

function Page:Button(label, onClick, width)
	local b = CreateFrame("Button", nil, self.frame, "BackdropTemplate")
	b:SetSize(width or 160, 22)
	b:SetPoint("TOPLEFT", 0, self.y)
	S:Backdrop(b, 1)
	local t = S:Font(b, 12)
	t:SetPoint("CENTER")
	t:SetText(label)
	b:SetScript("OnEnter", function() b:SetBackdropBorderColor(unpack(S.colors.accent)) end)
	b:SetScript("OnLeave", function() b:SetBackdropBorderColor(0, 0, 0, 1) end)
	b:SetScript("OnClick", onClick)
	self.y = self.y - 30
	return b
end

function Page:Edit(label, width)
	local fs = S:Font(self.frame, 12)
	fs:SetPoint("TOPLEFT", 0, self.y)
	fs:SetText(label)
	local e = CreateFrame("EditBox", nil, self.frame, "BackdropTemplate")
	e:SetSize(width or 220, 20)
	e:SetPoint("TOPLEFT", 200, self.y + 3)
	S:Backdrop(e, 1)
	e:SetFont(S.font, 12, "")
	e:SetTextInsets(6, 6, 0, 0)
	e:SetAutoFocus(false)
	e:SetMaxLetters(32)
	e:SetScript("OnEscapePressed", e.ClearFocus)
	e:SetScript("OnEnterPressed", e.ClearFocus)
	self.y = self.y - 28
	return e
end

-- Button placed next to the previous row instead of below it.
function Page:ButtonRight(label, onClick, x, width)
	local b = self:Button(label, onClick, width)
	self.y = self.y + 30
	b:ClearAllPoints()
	b:SetPoint("TOPLEFT", x, self.y)
	self.y = self.y - 30
	return b
end

function Page:Gap(h) self.y = self.y - (h or 8) end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local function setting(group, key)
	return function() return RoA.char[group][key] end,
		function(v) RoA.char[group][key] = v; changed(group) end
end

function C:CreateWindow()
	local f = CreateFrame("Frame", "RoadsOfAzerothConfig", UIParent, "BackdropTemplate")
	f:SetSize(680, 560)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	S:Backdrop(f, 0.95)
	f:Hide()
	tinsert(UISpecialFrames, "RoadsOfAzerothConfig")

	local bar = f:CreateTexture(nil, "ARTWORK")
	bar:SetPoint("TOPLEFT", 1, -1)
	bar:SetPoint("TOPRIGHT", -1, -1)
	bar:SetHeight(28)
	bar:SetColorTexture(0.08, 0.10, 0.14, 1)
	local title = S:Font(f, 14)
	title:SetPoint("TOPLEFT", 12, -8)
	title:SetText(("|cff69ccf0Roads of Azeroth|r  |cff999999v%s|r"):format(RoA.version))

	local close = CreateFrame("Button", nil, f)
	close:SetSize(28, 28)
	close:SetPoint("TOPRIGHT", 0, 0)
	local x = S:Font(close, 16)
	x:SetPoint("CENTER")
	x:SetText("X")
	close:SetScript("OnClick", function() f:Hide() end)

	local nav = CreateFrame("Frame", nil, f, "BackdropTemplate")
	nav:SetPoint("TOPLEFT", 1, -29)
	nav:SetPoint("BOTTOMLEFT", 1, 1)
	nav:SetWidth(140)
	nav:SetBackdrop({ bgFile = S.flat })
	nav:SetBackdropColor(0.06, 0.07, 0.10, 1)

	self.frame = f
	self.pages = {}
	self.tabs = {}

	local function newPage(key, label)
		local container = CreateFrame("Frame", nil, f)
		container:SetPoint("TOPLEFT", 164, -44)
		container:SetPoint("BOTTOMRIGHT", -16, 16)
		container:Hide()
		local page = setmetatable({ frame = container, y = 0, widgets = {} }, Page)
		self.pages[key] = page

		local tab = CreateFrame("Button", nil, nav)
		tab:SetSize(138, 26)
		tab:SetPoint("TOPLEFT", 1, -8 - (#self.tabs) * 28)
		local hl = tab:CreateTexture(nil, "BACKGROUND")
		hl:SetAllPoints()
		hl:SetColorTexture(0.41, 0.80, 0.94, 0.18)
		hl:Hide()
		local t = S:Font(tab, 12)
		t:SetPoint("LEFT", 12, 0)
		t:SetText(label)
		tab.hl = hl
		tab:SetScript("OnClick", function() self:Show(key) end)
		tab.key = key
		table.insert(self.tabs, tab)
		return page
	end

	self:BuildGeneral(newPage("general", L["General"]))
	self:BuildQuests(newPage("quests", L["Quests"]))
	self:BuildMap(newPage("map", L["Map and arrow"]))
	self:BuildNav(newPage("nav", L["Navigation"]))
end

function C:Show(key)
	for k, page in pairs(self.pages) do page.frame:SetShown(k == key) end
	for _, tab in ipairs(self.tabs) do tab.hl:SetShown(tab.key == key) end
	self.currentPage = key
	self:Refresh()
end

function C:Refresh()
	for _, page in pairs(self.pages) do
		for _, w in ipairs(page.widgets) do if w.refresh then w.refresh() end end
	end
end

---------------------------------------------------------------------------
-- Pages (also shown inside the Casters of Azeroth settings when it is loaded)
---------------------------------------------------------------------------
function C:BuildGeneral(p)
	p:Header(L["General"])
	p:Check(L["Frames locked"], L["Turn off to drag the quest list, the GPS panel and the arrow."],
		function() return RoA:FramesLocked() end,
		function(v) RoA:SetFramesLocked(v) end)
	p:Choice(L["Language"], { { "auto", L["Automatic"] }, { "enUS", "English" }, { "nlNL", "Nederlands" } },
		function() return RoA.db.language end,
		function(v) RoA.db.language = v end)
	p:Choice(L["Font"], { { "roboto", "Roboto" }, { "wow", L["Game font"] } },
		function() return RoA.db.font end,
		function(v) RoA.db.font = v end)
	p:Check(L["Thick outline on text"], L["Off: clean text with a soft shadow, easier to read."],
		function() return RoA.db.fontOutline end,
		function(v) RoA.db.fontOutline = v end)
	p:Note(L["Reload the UI to apply the language and font everywhere. With Casters of Azeroth loaded, its font settings are used."])
end

function C:BuildQuests(p)
	p:Header(L["Quests"])
	p:Check(L["Quest tracker"], L["A compact list: level colours, progress bars, turn-ins on top."], setting("quests", "enabled"))
	p:Check("   " .. L["Quests to pick up nearby"], L["A folded line under the list; open it for the nearest quests you don't have yet. More with Questie loaded."], setting("quests", "pickup"))
	p:Check(L["Hide the Blizzard quest tracker"], nil, setting("quests", "hideBlizzard"))
	p:Check(L["Hide the Questie tracker (Questie keeps its map pins)"], nil, setting("quests", "hideQuestieTracker"))
	p:Check(L["Quests in your current zone first"], nil, setting("quests", "zoneFirst"))
	p:Check(L["Hide finished objectives"], nil, setting("quests", "hideDone"))
	p:Choice(L["Sort by"], {
		{ "smart", L["Smart route (fastest leveling)"] }, { "distance", L["Distance"] }, { "xp", L["XP reward"] },
		{ "xpmin", L["XP per minute"] }, { "level", L["Level"] }, { "progress", L["Almost done"] }, { "zone", L["Zone"] },
	}, setting("quests", "sortMode"))
	p:Choice(L["Route strategy"], {
		{ "balanced", L["Balanced"] }, { "turnin", L["Turn in first"] },
		{ "quest", L["Quest first"] }, { "nearest", L["Nearest"] },
	}, (function()
		local get, set = setting("quests", "routeStrategy")
		return get, function(v)
			set(v)
			if RoA.QuestPlan and RoA.QuestPlan.Recalculate then RoA.QuestPlan:Recalculate() end
		end
	end)())
	p:Check(L["Keep the route until I recalculate"], L["The smart route keeps its order while you walk. Click the refresh button in the quest list header to plan it again from where you are."], setting("quests", "lockRoute"))
	p:Check(L["Show time and XP per hour estimates"], L["Estimates get better as the add-on learns your kill speed and drop rates."], setting("quests", "showEstimates"))
	p:Check(L["Arrow to the next stop"], L["The navigation arrow. Unlock the frames to move it."], setting("quests", "arrow"))
	p:Slider(L["Quests shown"], 3, 25, 1, setting("quests", "maxQuests"))
	p:Slider(L["Width"], 180, 400, 10, setting("quests", "width"))
	p:Slider(L["Font size"], 10, 16, 1, setting("quests", "fontSize"))
end

function C:BuildMap(p)
	p:Header(L["World map"])
	p:Check(L["Show the quest route on the map"], L["Numbered stops in the fastest order, with lines between them."], setting("map", "route"))
	p:Check(L["Show learned paths (heatmap)"], L["Where you walked, coloured by how often. Also the \"Paths\" button at the bottom left of the world map."], setting("map", "trails"))
	p:Gap()
	p:Header(L["Navigation arrow"])
	p:Check(L["Use the arrow"], nil, setting("arrow", "enabled"))
	local getA, setA = setting("arrow", "scale")
	p:Slider(L["Arrow size"], 0.6, 1.6, 0.05, getA, setA, function(v) return ("%d%%"):format(v * 100 + 0.5) end)
	p:Slider(L["Arrived within"], 5, 40, 1, setting("arrow", "arriveYards"))
	p:Note(L["Click a quest (title or lines) to make it your target: the arrow points to it (click again for the route). Shift-click opens it in the quest log, Alt-click opens its details in Scrum of Azeroth, Ctrl-click adds it to the navigation route. Right-click the title folds it."])
end

function C:BuildNav(p)
	p:Header(L["Next step"])
	p:Check(L["Show the next step in one line"], L["One sentence about the one thing to do now: urgent things first (dead, bags full, repair, trainer), then the first stop of your route. Unlock the frames (General) to move it."], setting("next", "enabled"))
	p:Gap()
	p:Header(L["Navigation (GPS)"])
	p:Check(L["Use the GPS"], L["A route of stops with a GPS panel: direction, distance, arrival time and the next stop."], setting("nav", "enabled"))
	p:Check(L["Follow the quest route"], L["The smart quest route (objectives, then turn-ins) comes after your own stops."], setting("nav", "followQuests"))
	p:Check(L["Suggest flight paths"], L["Only flight paths you know. A flight is suggested when it saves more than a minute."], setting("nav", "useFlights"))
	p:Check(L["Next stop on arrival"], L["Your own waypoints leave the route when you reach them. Quest stops move on when the quest log changes."], setting("nav", "autoAdvance"))
	p:Check(L["Show the GPS panel"], L["Off: the small navigation arrow is used instead. Unlock the frames (General) to move the panel."], setting("nav", "showPanel"))
	local getS, setS = setting("nav", "panelScale")
	p:Slider(L["Panel size"], 0.6, 1.6, 0.05, getS, setS, function(v) return ("%d%%"):format(v * 100 + 0.5) end)
	p:Check(L["Route on the minimap"], L["The current stop and the next three, with lines. Stops outside the minimap show as an arrow on the edge."], setting("nav", "minimap"))
	p:Check(L["Route list next to the world map"], L["Click a stop to go there first; ^ v x to reorder or remove."], setting("nav", "mapList"))
	p:Button(L["Clear route"], function()
		if RoA.Nav and RoA.Nav.Clear then RoA.Nav:Clear() end
	end)
	p:Gap()
	p:Header(L["Flight paths"])
	p:Check(L["Flight path helpers"], L["The game gives no flight times: they are estimated from the distance and measured on every flight you take (for all your characters)."], setting("flights", "enabled"))
	p:Check("   " .. L["Times and prices at the flight master"], L["A list beside the flight map, fastest first. ~ = estimated."], setting("flights", "panel"))
	p:Check("   " .. L["Countdown to the landing"], L["A bar while you fly. Unlock the frames (General) to move it."], setting("flights", "bar"))
	p:Check("   " .. L["Flight paths on the world map"], L["Green = you know it, grey = not yet. Hover: which of your characters know it. Click: add it to your route."], setting("flights", "mapPins"))
	p:Check("   " .. L["Say when a zone has a new flight path"], L["One line in the chat, once per flight path."], setting("flights", "newNearby"))
	p:Gap()
	p:Header(L["Learned paths"])
	p:Check(L["Learn paths and follow them"], L["Remembers where you walk (all your characters). The arrow then follows those paths when that is shorter than going straight over unknown ground."], setting("nav", "trails"))
	p:Button(L["Forget learned paths"], function()
		if RoA.Trails then RoA.Trails:Clear() end
		RoA:Print(L["Learned paths cleared."])
	end)
	p:Note(L["Ctrl-click a quest title or a spot on the world map to add a stop. WoW gives addons no data for hills, walls or water: without learned paths the arrow points in a straight line."])
end

function C:RegisterBlizzardSettings()
	if not (Settings and Settings.RegisterCanvasLayoutCategory) then return end
	local panel = CreateFrame("Frame")
	local t = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	t:SetPoint("TOPLEFT", 16, -16)
	t:SetText("Roads of Azeroth")
	local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	b:SetSize(220, 26)
	b:SetPoint("TOPLEFT", 16, -50)
	b:SetText(L["Open Roads of Azeroth settings"])
	b:SetScript("OnClick", function()
		if SettingsPanel then HideUIPanel(SettingsPanel) end
		RoA:ToggleConfig(true)
	end)
	pcall(function()
		local cat = Settings.RegisterCanvasLayoutCategory(panel, "Roads of Azeroth")
		Settings.RegisterAddOnCategory(cat)
	end)
end

-- Our pages inside the Casters of Azeroth settings window (its own widgets, same API).
local function registerWithCasters()
	local c = _G.CastersOfAzeroth or _G.CasterKit
	if type(c) ~= "table" then return end
	c.configPages = type(c.configPages) == "table" and c.configPages or {}
	local pages = {
		{ key = "roa_quests", label = L["Quests"], group = "Roads of Azeroth", build = function(p) C:BuildQuests(p) end },
		{ key = "roa_map", label = L["Map and arrow"], group = "Roads of Azeroth", build = function(p) C:BuildMap(p) end },
		{ key = "roa_nav", label = L["Navigation"], group = "Roads of Azeroth", build = function(p) C:BuildNav(p) end },
	}
	for _, def in ipairs(pages) do
		local known = false
		for _, d in ipairs(c.configPages) do if d.key == def.key then known = true end end
		if not known then table.insert(c.configPages, def) end
	end
end

function RoA:ToggleConfig(forceShow)
	if not C.frame then C:CreateWindow() end
	if C.frame:IsShown() and not forceShow then
		C.frame:Hide()
	else
		C.frame:Show()
		C:Show(C.currentPage or "quests")
	end
end

function C:OnInit()
	registerWithCasters() -- before Casters of Azeroth builds its window (on first open)
end

function C:OnEnable()
	self:RegisterBlizzardSettings()
end

---------------------------------------------------------------------------
-- Dutch for the strings that are new in Roads of Azeroth
---------------------------------------------------------------------------
RoA.AddTranslations({
	["Map and arrow"] = "Kaart en pijl",
	["Automatic"] = "Automatisch",
	["Font"] = "Lettertype",
	["Game font"] = "Lettertype van het spel",
	["Thick outline on text"] = "Dikke rand rond tekst",
	["Off: clean text with a soft shadow, easier to read."] = "Uit: strakke tekst met een zachte schaduw, leest makkelijker.",
	["Reload the UI to apply the language and font everywhere. With Casters of Azeroth loaded, its font settings are used."] = "Herlaad de interface om taal en lettertype overal toe te passen. Met Casters of Azeroth geladen gelden de lettertype-instellingen daarvan.",
	["Turn off to drag the quest list, the GPS panel and the arrow."] = "Zet uit om de questlijst, het GPS-paneel en de pijl te verslepen.",
	["Quest tracker"] = "Questlijst",
	["Estimates get better as the add-on learns your kill speed and drop rates."] = "Schattingen worden beter naarmate de add-on je doodsnelheid en droprates leert.",
	["The navigation arrow. Unlock the frames to move it."] = "De navigatiepijl. Ontgrendel de kaders om hem te verplaatsen.",
	["Use the arrow"] = "De pijl gebruiken",
	["Use the GPS"] = "De GPS gebruiken",
	["Open Roads of Azeroth settings"] = "Instellingen van Roads of Azeroth openen",
	["Your quest list, route and GPS settings were moved over from CasterKit."] = "Je questlijst-, route- en GPS-instellingen zijn overgezet vanuit CasterKit.",
	["/roa: settings. /roa recalc: plan the route again. /roa clear: clear the GPS route. /roa unlock: move the frames."] = "/roa: instellingen. /roa recalc: route opnieuw plannen. /roa clear: GPS-route wissen. /roa unlock: kaders verplaatsen.",
})
