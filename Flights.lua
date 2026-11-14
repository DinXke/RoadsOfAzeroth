-- Roads of Azeroth by DinX: flight paths.
-- The game gives no flight times, so they are estimated from the distance at
-- first and measured on every flight you take (for all your characters; the
-- estimates learn from those measurements too). At a flight master a list
-- shows each destination with its time and price; in the air a bar counts down
-- to the landing; the world map marks the flight paths you know and the ones
-- you don't (click one to add it to your route); entering a zone with an
-- unknown flight path says so once. Which alts know a flight path shows on its
-- map pin. Display only: it never takes a flight or talks to a flight master.
local _, ns = ...
local RoA = ns.RoA
local L = RoA.L
local S = RoA.Style
local Safe = RoA.Safe or function(v, d) if v == nil then return d end return v end

local F = RoA:NewModule("Flights")

local MIN_FLIGHT, MAX_FLIGHT = 5, 3600 -- seconds a measured flight may take
local PIN_SIZE = 16
local ROWS = 24

local WMF = WorldMapFrame

local function cfg() return RoA.char.flights end

local function try(fn, ...)
	if not fn then return end
	local ok, a, b, c = pcall(fn, ...)
	if ok then return a, b, c end
end

local function num(v) v = Safe(v, nil) return type(v) == "number" and v or nil end
local function str(v) v = Safe(v, nil) return type(v) == "string" and v ~= "" and v or nil end

-- account data: measured times and which character knows which flight path
local function data()
	local d = RoA.db.flights
	if type(d) ~= "table" then d = {} RoA.db.flights = d end
	if type(d.times) ~= "table" then d.times = {} end
	if type(d.chars) ~= "table" then d.chars = {} end
	if type(d.calib) ~= "table" then d.calib = { sum = 0, n = 0 } end
	return d
end
F.Data = data

function F.Clock(sec)
	sec = math.max(0, math.floor(sec + 0.5))
	return ("%d:%02d"):format(math.floor(sec / 60), sec % 60)
end

---------------------------------------------------------------------------
-- Times: measured, the way back measured, or estimated from the distance
---------------------------------------------------------------------------
local function key(a, b) return a .. ">" .. b end

-- the straight-line estimate, corrected by what your flights taught so far
function F:Estimate(a, b)
	local NV = RoA.Nav
	if not (NV and NV.TaxiNodes and NV.ContinentOf) then return end
	local cont = NV.ContinentOf(NV.PlayerMap())
	local e = cont and NV.TaxiNodes(cont)
	if not e then return end
	local na, nb
	for _, n in ipairs(e.all) do
		if n.nodeID == a then na = n end
		if n.nodeID == b then nb = n end
	end
	if not (na and nb) then return end
	local raw = NV.WorldDist(na, nb) * (NV.FLY_FACTOR or 1.25) / (NV.FLY_SPEED or 32)
	local c = data().calib
	local factor = c.n > 0 and c.sum / c.n or 1
	return raw * factor, raw
end

-- seconds and how sure: "measured", "reverse" or "estimate" (measuredOnly: nil unless flown)
function F:Time(a, b, measuredOnly)
	a, b = num(a), num(b)
	if not (a and b) then return end
	local t = data().times
	if t[key(a, b)] then return t[key(a, b)], "measured" end
	if t[key(b, a)] then return t[key(b, a)], "reverse" end
	if measuredOnly then return end
	local est = self:Estimate(a, b)
	if est then return est, "estimate" end
end

function F:TimeText(a, b)
	local sec, how = self:Time(a, b)
	if not sec then return "?" end
	return (how == "measured" and "" or "~") .. F.Clock(sec)
end

-- a flight that landed: remember its time, teach the estimate
function F:Learn(a, b, sec)
	a, b = num(a), num(b)
	if not (a and b and sec and sec >= MIN_FLIGHT and sec <= MAX_FLIGHT) then return end
	local d = data()
	d.times[key(a, b)] = math.floor(sec + 0.5)
	local _, raw = self:Estimate(a, b)
	if raw and raw > 0 then
		local r = sec / raw
		if r > 0.3 and r < 4 then
			d.calib.sum, d.calib.n = d.calib.sum + r, d.calib.n + 1
		end
	end
end

---------------------------------------------------------------------------
-- Your characters: who knows which flight path
---------------------------------------------------------------------------
function F:SyncChar()
	local guid = str(UnitGUID and UnitGUID("player"))
	if not guid then return end
	local _, class = UnitClass("player")
	local known = {}
	for k, v in pairs(RoA.char.nav and RoA.char.nav.taxiKnown or {}) do if v then known[k] = true end end
	data().chars[guid] = { name = str(UnitName("player")) or "?", class = class, known = known }
end

-- the other characters that know this flight path: { "Name", ... } (class coloured)
function F:AltsKnowing(node)
	local me = str(UnitGUID and UnitGUID("player"))
	local out = {}
	for guid, c in pairs(data().chars) do
		if guid ~= me and type(c.known) == "table" and (c.known[node.nodeID] or (node.name and c.known["n:" .. node.name])) then
			local col = c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
			out[#out + 1] = col and ("|cff%02x%02x%02x%s|r"):format(math.floor(col.r * 255), math.floor(col.g * 255), math.floor(col.b * 255), c.name) or c.name
		end
	end
	table.sort(out)
	return out
end

---------------------------------------------------------------------------
-- At the flight master: where you are, the destinations by slot
---------------------------------------------------------------------------
local here, slots = nil, {} -- here = { nodeID, name }; slots[slotIndex] = { nodeID, name, cost }

local function readTaxiMap()
	here, slots = nil, {}
	local FS = Enum and Enum.FlightPathState
	local mapID = GetTaxiMapID and num(try(GetTaxiMapID))
	local nodes = mapID and C_TaxiMap and C_TaxiMap.GetAllTaxiNodes and try(C_TaxiMap.GetAllTaxiNodes, mapID)
	if type(nodes) == "table" then
		for _, n in ipairs(nodes) do
			if type(n) == "table" then
				local id, st, name, slot = num(n.nodeID), num(n.state), str(n.name), num(n.slotIndex)
				if id and FS and st == FS.Current then
					here = { nodeID = id, name = name }
				elseif id and slot and (not FS or st == FS.Reachable) then
					slots[slot] = { nodeID = id, name = name or ("#" .. id), cost = num(TaxiNodeCost and try(TaxiNodeCost, slot)) or 0 }
				end
			end
		end
	end
	return here, slots
end
F.ReadTaxiMap = readTaxiMap

-- the list beside the flight map
local function money(c)
	if GetCoinTextureString then
		local ok, s = pcall(GetCoinTextureString, c)
		if ok and s then return s end
	end
	return ("%dg %ds %dc"):format(math.floor(c / 10000), math.floor(c / 100) % 100, c % 100)
end

function F:BuildPanel()
	local f = CreateFrame("Frame", "RoadsOfAzerothFlightList", UIParent, "BackdropTemplate")
	f:SetSize(250, 40)
	f:SetFrameStrata("HIGH")
	S:Backdrop(f, 0.92)
	f.title = S:Font(f, 13)
	f.title:SetPoint("TOPLEFT", 8, -8)
	f.title:SetText(L["Flights from here"])
	f.rows = {}
	for i = 1, ROWS do
		local r = CreateFrame("Frame", nil, f)
		r:SetSize(234, 16)
		r:SetPoint("TOPLEFT", 8, -28 - (i - 1) * 17)
		r.name = S:Font(r, 12)
		r.name:SetPoint("LEFT")
		r.name:SetPoint("RIGHT", r, "RIGHT", -96, 0)
		r.name:SetJustifyH("LEFT")
		r.name:SetWordWrap(false)
		r.time = S:Font(r, 12)
		r.time:SetPoint("RIGHT", r, "RIGHT", -52, 0)
		r.cost = S:Font(r, 11)
		r.cost:SetPoint("RIGHT")
		r:Hide()
		f.rows[i] = r
	end
	f.note = S:Font(f, 10)
	f.note:SetTextColor(unpack(S.colors.muted))
	f.note:SetText(L["~ = estimated; flown once, the real time is kept."])
	f:Hide()
	self.panel = f
end

function F:ShowPanel()
	local f = self.panel
	if not (f and cfg().enabled and cfg().panel) then return end
	readTaxiMap()
	local list = {}
	for _, d in pairs(slots) do
		local sec = here and self:Time(here.nodeID, d.nodeID)
		list[#list + 1] = { d = d, sec = sec or math.huge }
	end
	table.sort(list, function(a, b) if a.sec ~= b.sec then return a.sec < b.sec end return a.d.name < b.d.name end)
	local n = math.min(#list, ROWS)
	for i, r in ipairs(f.rows) do
		local e = list[i]
		if e and i <= n then
			r.name:SetText(e.d.name)
			r.time:SetText(here and self:TimeText(here.nodeID, e.d.nodeID) or "?")
			r.cost:SetText(money(e.d.cost))
			r:Show()
		else
			r:Hide()
		end
	end
	f.note:ClearAllPoints()
	f.note:SetPoint("TOPLEFT", 8, -32 - n * 17)
	f:SetHeight(48 + n * 17)
	local host = (FlightMapFrame and FlightMapFrame:IsShown() and FlightMapFrame) or (TaxiFrame and TaxiFrame:IsShown() and TaxiFrame)
	f:ClearAllPoints()
	if host then f:SetPoint("TOPLEFT", host, "TOPRIGHT", 4, 0) else f:SetPoint("LEFT", UIParent, "CENTER", 200, 0) end
	f:SetShown(n > 0)
end

---------------------------------------------------------------------------
-- In the air: a bar that counts down to the landing
---------------------------------------------------------------------------
local pending   -- { from, to, name, est } from the flight you picked
local flight    -- { start, from, to, name, total, how } while on a taxi

function F:OnTake(slot)
	if not here then readTaxiMap() end
	local d = slots[num(slot) or -1]
	if not d then pending = nil return end
	local sec, how = here and self:Time(here.nodeID, d.nodeID)
	pending = { from = here and here.nodeID, to = d.nodeID, name = d.name, total = sec, how = how }
end

function F:BuildBar()
	local f = CreateFrame("Frame", "RoadsOfAzerothFlightBar", UIParent, "BackdropTemplate")
	f:SetSize(300, 22)
	S:Backdrop(f, 0.85)
	f.bar = S:StatusBar(f, S.colors.proc)
	f.bar:SetPoint("TOPLEFT", 1, -1)
	f.bar:SetPoint("BOTTOMRIGHT", -1, 1)
	f.bar:SetMinMaxValues(0, 1)
	f.text = S:Font(f.bar, 12)
	f.text:SetPoint("CENTER")
	f:Hide()
	S:RegisterMover(f, "flight", L["Flight bar"], function(fr)
		fr:SetPoint("TOP", UIParent, "TOP", 0, -150)
	end)
	self.bar = f
end

function F:UpdateBar(now)
	local f = self.bar
	if not f then return end
	if not (flight and cfg().enabled and cfg().bar) then return f:Hide() end
	local gone = now - flight.start
	local dest = flight.name or L["unknown destination"]
	if flight.total then
		local left = flight.total - gone
		f.bar:SetValue(math.min(1, gone / math.max(1, flight.total)))
		if left > 0 then
			f.text:SetText(L["%s: landing in %s"]:format(dest, (flight.how == "measured" and "" or "~") .. F.Clock(left)))
		else
			f.text:SetText(L["%s: landing soon"]:format(dest))
		end
	else
		f.bar:SetValue(0)
		f.text:SetText(L["%s: in the air for %s"]:format(dest, F.Clock(gone)))
	end
	f:Show()
end

-- taking off and landing, from UnitOnTaxi
function F:Watch(now)
	now = now or GetTime()
	local onTaxi = UnitOnTaxi and Safe(UnitOnTaxi("player"), false) or false
	if onTaxi and not flight then
		local p = pending or {}
		flight = { start = now, from = p.from, to = p.to, name = p.name, total = p.total, how = p.how }
		pending = nil
	elseif not onTaxi and flight then
		if flight.from and flight.to then self:Learn(flight.from, flight.to, now - flight.start) end
		flight = nil
	end
	self:UpdateBar(now)
end
F.Flying = function() return flight end

---------------------------------------------------------------------------
-- Entering a zone with a flight path you don't know yet: one line, once
---------------------------------------------------------------------------
local told = {}

local function inside(n) return n.x >= 0 and n.x <= 1 and n.y >= 0 and n.y <= 1 end

function F:CheckZone()
	if not (cfg().enabled and cfg().newNearby) then return end
	local NV = RoA.Nav
	local m = NV and NV.PlayerMap and NV.PlayerMap()
	if not (m and NV.TaxiNodesOn) then return end
	for _, n in ipairs(NV.TaxiNodesOn(m)) do
		if not n.known and inside(n) and not told[n.nodeID] then
			told[n.nodeID] = true
			RoA:Print(L["A flight path you don't know yet is in this zone: %s. Click its grey pin on the world map to add it to your route."]:format(n.name))
		end
	end
end

---------------------------------------------------------------------------
-- World map: known (green) and unknown (grey) flight paths
---------------------------------------------------------------------------
local pins = {}
local shownMap, shownScale, shownW

local function canvas()
	if not WMF then return end
	local c = WMF.GetCanvas and try(WMF.GetCanvas, WMF)
	return c or (WMF.ScrollContainer and WMF.ScrollContainer.Child)
end

local function pinEnter(self)
	local n = self.node
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine(n.name, 1, 1, 1)
	if n.known then
		GameTooltip:AddLine(L["You know this flight path."], 0.35, 0.9, 0.45)
	else
		GameTooltip:AddLine(L["Not known yet: talk to its flight master."], 0.6, 0.65, 0.71)
	end
	local alts = F:AltsKnowing(n)
	if #alts > 0 then GameTooltip:AddLine(L["Also known by: %s"]:format(table.concat(alts, ", ")), 0.8, 0.8, 0.8, true) end
	GameTooltip:AddLine(L["Click: add to your route"], 0.4, 0.8, 1)
	GameTooltip:Show()
end

local function pinClick(self)
	local NV = RoA.Nav
	if NV and NV.Add then
		NV:Add(self.mapID, self.node.x, self.node.y, L["Flight path: %s"]:format(self.node.name), "custom")
		RoA:Print(L["Added to your route: %s"]:format(self.node.name))
	end
end

local function getPin(i, c)
	local p = pins[i]
	if not p then
		p = CreateFrame("Button", nil, c)
		p:SetSize(PIN_SIZE, PIN_SIZE)
		p.tex = p:CreateTexture(nil, "OVERLAY")
		p.tex:SetAllPoints()
		p:SetScript("OnEnter", pinEnter)
		p:SetScript("OnLeave", function() GameTooltip:Hide() end)
		p:SetScript("OnClick", pinClick)
		pins[i] = p
	end
	if p:GetParent() ~= c then p:SetParent(c) end
	p:SetFrameLevel(math.min(9000, c:GetFrameLevel() + 5000))
	return p
end

function F:HidePins()
	for _, p in ipairs(pins) do p:Hide() end
end
F.pins = pins

function F:MapPinsShown()
	local n = 0
	for _, p in ipairs(pins) do if p:IsShown() then n = n + 1 end end
	return n
end

function F:DrawPins()
	shownMap, shownScale, shownW = nil, nil, nil
	self:HidePins()
	if not (cfg().enabled and cfg().mapPins and WMF and WMF:IsShown()) then return end
	local c = canvas()
	local mapID = WMF.GetMapID and num(try(WMF.GetMapID, WMF))
	local NV = RoA.Nav
	if not (c and mapID and NV and NV.TaxiNodesOn) then return end
	local w, h = c:GetWidth(), c:GetHeight()
	local scale = c:GetScale()
	shownMap, shownScale, shownW = mapID, scale, w
	local i = 0
	for _, n in ipairs(NV.TaxiNodesOn(mapID)) do
		if inside(n) then
			i = i + 1
			local p = getPin(i, c)
			p.node, p.mapID = n, mapID
			p.tex:SetTexture(n.known and "Interface\\TaxiFrame\\UI-Taxi-Icon-Green" or "Interface\\TaxiFrame\\UI-Taxi-Icon-Gray")
			p.tex:SetDesaturated(not n.known)
			p:SetAlpha(n.known and 0.9 or 1)
			p:SetScale(1 / math.max(0.01, scale))
			p:ClearAllPoints()
			p:SetPoint("CENTER", c, "TOPLEFT", n.x * w * scale, -n.y * h * scale)
			p:Show()
		end
	end
end

-- redraw when the map, its zoom or size changes (checked while it is open)
function F:MapTick()
	if not (WMF and WMF:IsShown()) then
		if shownMap then self:HidePins() shownMap = nil end
		return
	end
	local c = canvas()
	local mapID = WMF.GetMapID and num(try(WMF.GetMapID, WMF))
	if mapID ~= shownMap or (c and (c:GetScale() ~= shownScale or c:GetWidth() ~= shownW)) then self:DrawPins() end
end

---------------------------------------------------------------------------
function F:OnEnable()
	self:BuildPanel()
	self:BuildBar()
	self:SyncChar()
	RoA:On("TAXIMAP_OPENED", function()
		readTaxiMap()
		-- after Nav learned the known nodes from this flight master
		C_Timer.After(0, function() F:SyncChar() F:ShowPanel() end)
	end)
	RoA:On("TAXIMAP_CLOSED", function() if F.panel then F.panel:Hide() end end)
	RoA:On("UI_INFO_MESSAGE", function() C_Timer.After(0.5, function() F:SyncChar() end) end)
	RoA:On("ZONE_CHANGED_NEW_AREA", function() C_Timer.After(2, function() F:CheckZone() end) end)
	RoA:On("PLAYER_ENTERING_WORLD", function() C_Timer.After(5, function() F:CheckZone() end) end)
	RoA:Listen("SETTINGS", function() F:DrawPins() F:UpdateBar(GetTime()) end)
	if hooksecurefunc and TakeTaxiNode then
		hooksecurefunc("TakeTaxiNode", function(slot) pcall(F.OnTake, F, slot) end)
	end
	C_Timer.NewTicker(0.25, function()
		pcall(F.Watch, F)
		pcall(F.MapTick, F)
	end)
end
