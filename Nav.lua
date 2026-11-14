-- Roads of Azeroth by DinX: navigation (GPS)
-- A route of waypoints (own stops plus the smart quest route), a GPS panel with
-- direction, distance, ETA and the next stop, a route list next to the world map,
-- and flight path suggestions from the flight paths you know.
-- Display only: it never moves the player, never clicks or takes a flight.
-- The arrow shows the straight-line direction: WoW gives addons no paths or terrain.
local _, ns = ...
local RoA = ns.RoA
local L = RoA.L
local S = RoA.Style
local IsSecret = RoA.IsSecret

local NV = RoA:NewModule("Nav")

local QL = C_QuestLog

-- Travel model
local FLY_SPEED = 32       -- yd/s on a flight path
local FLY_FACTOR = 1.25    -- flight routes are not straight
local FLY_OVERHEAD = 10    -- s: talk to the flight master, take off, land
local FLY_MIN_SAVE = 60    -- s a flight must save to be suggested
local FLY_KEEP_SAVE = 20   -- s it must keep saving once suggested (no flip-flop)
local NODE_CANDIDATES = 3  -- nearest known nodes tried at each end
local FLIGHT_LEGS = 12     -- legs checked for flights
local NEW_NODE_YD = 80     -- a new flight path is the known-to-be node this close

-- Limits and timing
local MAX_QUEUE = 40
local HISTORY_MAX = 20
local REBUILD_WAIT = 0.3
local PANEL_TICK = 0.1
local LIST_ROWS = 16
local ROW_H = 18

local GREEN = { 0.35, 0.85, 0.40 }

local DEFAULTS = {
	enabled = true, followQuests = true, useFlights = true, showPanel = true,
	panelScale = 1, mapList = true, autoAdvance = true, minimap = true,
}

local KIND = {
	quest = { icon = "Interface\\GossipFrame\\AvailableQuestIcon", label = "Quest objective" },
	turnin = { icon = "Interface\\GossipFrame\\ActiveQuestIcon", label = "Turn-in" },
	custom = { icon = "Interface\\Icons\\INV_Misc_Map_01", label = "Waypoint", crop = true },
	flight = { icon = "Interface\\GossipFrame\\TaxiGossipIcon", label = "Flight" },
	corpse = { icon = "Interface\\Icons\\Spell_Holy_Resurrection", label = "Your corpse", crop = true },
}

local function kindColor(kind)
	if kind == "turnin" then return S.colors.hint end
	if kind == "custom" then return GREEN end
	if kind == "flight" then return S.colors.proc end
	if kind == "corpse" then return { 1, 1, 1 } end
	return S.colors.accent
end

---------------------------------------------------------------------------
-- Safe helpers
---------------------------------------------------------------------------
local function num(v)
	if v == nil or IsSecret(v) or type(v) ~= "number" or v ~= v then return nil end
	return v
end

local function str(v)
	if v == nil or IsSecret(v) or type(v) ~= "string" or v == "" then return nil end
	return v
end

local function flag(v)
	if v == nil or IsSecret(v) then return false end
	return v ~= false and v ~= 0
end

local function try(fn, ...)
	if not fn then return end
	local ok, a, b, c, d = pcall(fn, ...)
	if ok then return a, b, c, d end
end

-- Report each kind of error once, then stay quiet (no error floods).
local reported = {}
local function guard(tag, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		if RoA.debug then RoA:Print("Nav " .. tostring(tag) .. ":", tostring(err)) end
		if not reported[tag] then
			reported[tag] = true
			local h = geterrorhandler and geterrorhandler()
			if h then pcall(h, err) end
		end
	end
	return ok
end

local function on(event, fn)
	guard("event", RoA.On, RoA, event, function(...)
		guard(event, fn, ...)
	end)
end

-- Settings: the lead adds defaults to Core.lua; missing keys are filled here too.
local lastDB
local function db()
	local c = RoA.char
	if not c then return nil end
	local n = c.nav
	if type(n) ~= "table" then
		n = {}
		c.nav = n
	end
	if n ~= lastDB then
		for k, v in pairs(DEFAULTS) do
			if n[k] == nil then n[k] = v end
		end
		if type(n.queue) ~= "table" then n.queue = {} end
		if type(n.taxiKnown) ~= "table" then n.taxiKnown = {} end
		lastDB = n
	end
	return n
end

local function active()
	local n = db()
	return n and n.enabled and true or false
end

---------------------------------------------------------------------------
-- Positions (shared helpers from Arrow.lua)
---------------------------------------------------------------------------
local function worldPos(mapID, x, y)
	local A = RoA.Arrow
	if A and A.WorldPos then return A.WorldPos(mapID, x, y) end
end

local function playerPos()
	local A = RoA.Arrow
	if A and A.PlayerPos then return A.PlayerPos() end
end

local function travelSpeed()
	local A = RoA.Arrow
	local v = A and A.TravelSpeed and num(try(A.TravelSpeed))
	if v and v > 0.5 then return v end
	return 7
end

local function distText(d)
	return L["%d yd"]:format(math.floor(d + 0.5))
end

local function etaText(sec)
	local A = RoA.Arrow
	if A and A.FormatETA then return A.FormatETA(sec) end
	return ("~%d:%02d"):format(math.floor(sec / 60), math.floor(sec % 60))
end

local function durText(sec)
	if sec < 90 then return L["%d s"]:format(math.floor(sec + 0.5)) end
	return L["%d min"]:format(math.floor(sec / 60 + 0.5))
end

local function wdist(a, b)
	local dn, dw = a.wn - b.wn, a.ww - b.ww
	return (dn * dn + dw * dw) ^ 0.5
end

local function onTaxi()
	return UnitOnTaxi and flag(try(UnitOnTaxi, "player")) or false
end

local CONTINENT = Enum and Enum.UIMapType and Enum.UIMapType.Continent or 2
local infoCache = {}
local function mapInfo(m)
	if not m then return end
	local info = infoCache[m]
	if info == nil then
		info = C_Map and C_Map.GetMapInfo and try(C_Map.GetMapInfo, m)
		if type(info) ~= "table" then info = false end
		infoCache[m] = info
	end
	return info or nil
end

local function mapName(m)
	local info = mapInfo(m)
	return info and str(info.name)
end

-- The continent map above a map (nil for world/cosmic maps).
local function continentOf(m)
	for _ = 1, 10 do
		local info = mapInfo(m)
		if not info then return end
		local t = num(info.mapType)
		if t == CONTINENT then return m end
		if t and t < CONTINENT then return end
		local p = num(info.parentMapID)
		if not p or p == 0 then return end
		m = p
	end
end

local function playerMap()
	return C_Map and C_Map.GetBestMapForUnit and num(try(C_Map.GetBestMapForUnit, "player"))
end

---------------------------------------------------------------------------
-- Quest helpers
---------------------------------------------------------------------------
local function questTitle(id)
	local t = QL and QL.GetTitleForQuestID and str(try(QL.GetTitleForQuestID, id))
	if not t and QuestUtils_GetQuestName then t = str(try(QuestUtils_GetQuestName, id)) end
	return t or ("#" .. tostring(id))
end

-- true / false, or nil when the client cannot tell
local function inLog(id)
	if QL and QL.GetLogIndexForQuestID then
		local ok, i = pcall(QL.GetLogIndexForQuestID, id)
		if ok then
			i = num(i)
			return i ~= nil and i > 0
		end
	end
end

local function readyForTurnIn(id)
	if QL and QL.ReadyForTurnIn and flag(try(QL.ReadyForTurnIn, id)) then return true end
	if QL and QL.IsComplete and flag(try(QL.IsComplete, id)) then return true end
	return false
end

-- Position of a quest's next step (objective area, or the turn-in when done).
local function questPosition(id)
	if QL and QL.GetNextWaypoint then
		local m, x, y = try(QL.GetNextWaypoint, id)
		m, x, y = num(m), num(x), num(y)
		if m and m > 0 and x and y then return m, x, y end
	end
	if not (QL and QL.GetQuestsOnMap) then return end
	local qm = GetQuestUiMapID and num(try(GetQuestUiMapID, id, true))
	for _, m in ipairs({ playerMap() or 0, qm or 0 }) do
		if m > 0 then
			local pins = try(QL.GetQuestsOnMap, m)
			if type(pins) == "table" then
				for _, info in ipairs(pins) do
					if type(info) == "table" and num(info.questID) == id and num(info.x) and num(info.y) then
						return m, info.x, info.y
					end
				end
			end
		end
	end
end
NV.QuestPosition = questPosition

local function titleFor(ids)
	local first = type(ids) == "table" and num(ids[1])
	if not first then return L["Next stop"] end
	local t = questTitle(first)
	if #ids > 1 then t = t .. " (+" .. (#ids - 1) .. ")" end
	return t
end

---------------------------------------------------------------------------
-- Flight paths: known nodes per continent map
---------------------------------------------------------------------------
local taxiCache = {} -- [continentMapID] = { all = {...}, known = {...} }

local function factionOK(node, faction)
	local FPF = Enum and Enum.FlightPathFaction
	local f = num(node.faction)
	if not (FPF and f) then return true end
	if f == FPF.Horde and faction ~= "Horde" then return false end
	if f == FPF.Alliance and faction ~= "Alliance" then return false end
	return true
end

-- Only nodes the player knows count (learned at a flight master, or reported
-- as discovered by the map API).
local function isKnown(node, id, name, known)
	if known[id] or (name and known["n:" .. name]) then return true end
	if node.isUndiscovered == true then return false end
	local atlas = str(node.atlas)
	if atlas and atlas:find("Undiscovered") then return false end
	if node.isUndiscovered == false then return true end
	local FS = Enum and Enum.FlightPathState
	local st = num(node.state)
	if FS and st and (st == FS.Current or st == FS.Reachable) then return true end
	return false
end

local function loadNodes(contMap)
	local entry = { all = {}, known = {} }
	if not (C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap) then return entry end
	local nodes = try(C_TaxiMap.GetTaxiNodesForMap, contMap)
	if type(nodes) ~= "table" then return entry end
	local faction = UnitFactionGroup and str(try(UnitFactionGroup, "player"))
	local known = db().taxiKnown
	for _, n in ipairs(nodes) do
		if type(n) == "table" and not flag(n.isMapLayerTransition) then
			local id, name = num(n.nodeID), str(n.name)
			local pos, x, y = n.position, nil, nil
			if type(pos) == "table" then
				x, y = num(pos.x), num(pos.y)
				if not (x and y) and pos.GetXY then
					x, y = try(pos.GetXY, pos)
					x, y = num(x), num(y)
				end
			end
			if id and x and y and factionOK(n, faction) then
				local cont, wn, ww = worldPos(contMap, x, y)
				if cont then
					local rec = { nodeID = id, name = name or ("#" .. id), mapID = contMap, x = x, y = y,
						cont = cont, wn = wn, ww = ww }
					entry.all[#entry.all + 1] = rec
					if isKnown(n, id, name, known) then entry.known[#entry.known + 1] = rec end
				end
			end
		end
	end
	return entry
end

local function nodesFor(contMap)
	if not contMap then return end
	local e = taxiCache[contMap]
	if not e then
		e = loadNodes(contMap)
		taxiCache[contMap] = e
	end
	return e
end

-- For Flights.lua: your faction's flight paths on one map (zone or continent),
-- placed on that map, each with known = true or false for this character.
function NV.TaxiNodesOn(mapID)
	local out = {}
	if not (mapID and C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap) then return out end
	local nodes = try(C_TaxiMap.GetTaxiNodesForMap, mapID)
	if type(nodes) ~= "table" then return out end
	local faction = UnitFactionGroup and str(try(UnitFactionGroup, "player"))
	local known = db().taxiKnown
	for _, n in ipairs(nodes) do
		if type(n) == "table" and not flag(n.isMapLayerTransition) then
			local id, name = num(n.nodeID), str(n.name)
			local pos, x, y = n.position, nil, nil
			if type(pos) == "table" then
				x, y = num(pos.x), num(pos.y)
				if not (x and y) and pos.GetXY then
					x, y = try(pos.GetXY, pos)
					x, y = num(x), num(y)
				end
			end
			if id and x and y and factionOK(n, faction) then
				out[#out + 1] = { nodeID = id, name = name or ("#" .. id), x = x, y = y, known = isKnown(n, id, name, known) }
			end
		end
	end
	return out
end
NV.TaxiNodes = function(contMap) return nodesFor(contMap) end
NV.ContinentOf, NV.PlayerMap, NV.WorldDist = function(m) return continentOf(m) end, function() return playerMap() end, wdist
NV.FLY_SPEED, NV.FLY_FACTOR = FLY_SPEED, FLY_FACTOR

-- At a flight master: every node you can fly to (or stand at) is known.
local function learnFromTaxiMap()
	local known = db().taxiKnown
	local FS = Enum and Enum.FlightPathState
	local mapID = GetTaxiMapID and num(try(GetTaxiMapID))
	local got = false
	if mapID and C_TaxiMap and C_TaxiMap.GetAllTaxiNodes then
		local nodes = try(C_TaxiMap.GetAllTaxiNodes, mapID)
		if type(nodes) == "table" then
			for _, n in ipairs(nodes) do
				local id, st, name
				if type(n) == "table" then id, st, name = num(n.nodeID), num(n.state), str(n.name) end
				if id and (not FS or not st or st == FS.Current or st == FS.Reachable) then
					known[id] = true
					if name then known["n:" .. name] = true end
					got = true
				end
			end
		end
	end
	-- older taxi frame API: names only
	if not got and NumTaxiNodes and TaxiNodeName and TaxiNodeGetType then
		for i = 1, num(try(NumTaxiNodes)) or 0 do
			local t, name = str(try(TaxiNodeGetType, i)), str(try(TaxiNodeName, i))
			if name and (t == "CURRENT" or t == "REACHABLE") then known["n:" .. name] = true end
		end
	end
	wipe(taxiCache)
end

-- "New flight path discovered": the nearest node to the player is now known.
local function learnNearestNode()
	local pc, pn, pw = playerPos()
	local cm = continentOf(playerMap())
	local e = nodesFor(cm)
	if not (pc and e) then return end
	local me = { wn = pn, ww = pw }
	local best, bd
	for _, n in ipairs(e.all) do
		if n.cont == pc then
			local d = wdist(n, me)
			if not bd or d < bd then best, bd = n, d end
		end
	end
	if best and bd <= NEW_NODE_YD then
		db().taxiKnown[best.nodeID] = true
		wipe(taxiCache)
	end
end

local function nearest(list, p, k)
	local tmp = {}
	for _, n in ipairs(list) do
		if n.cont == p.cont then tmp[#tmp + 1] = { node = n, d = wdist(n, p) } end
	end
	table.sort(tmp, function(a, b) return a.d < b.d end)
	for i = #tmp, k + 1, -1 do tmp[i] = nil end
	return tmp
end

local flightKeep = {} -- [destination key] = true while a flight is suggested
local noFlight = {}   -- [destination key] = true: the player chose to walk

-- Best known flight from a to b (both with cont/wn/ww), or nil.
local function bestFlight(a, b, speed, key, nodes)
	if not nodes or #nodes < 2 then return end
	local direct = wdist(a, b) / speed
	if direct < FLY_MIN_SAVE then return end
	local from, to = nearest(nodes, a, NODE_CANDIDATES), nearest(nodes, b, NODE_CANDIDATES)
	local best
	for _, f in ipairs(from) do
		for _, t in ipairs(to) do
			if f.node ~= t.node then
				local flyDist = wdist(f.node, t.node) * FLY_FACTOR
				-- a flight you took before: its measured time (Flights.lua)
				local F = RoA.Flights
				local learned = F and F.Time and F:Time(f.node.nodeID, t.node.nodeID, true)
				local flyTime = (learned or flyDist / FLY_SPEED) + FLY_OVERHEAD
				local total = f.d / speed + flyTime + t.d / speed
				if not best or total < best.total then
					best = { a = f.node, b = t.node, walkA = f.d, walkB = t.d, flyDist = flyDist, flyTime = flyTime, total = total }
				end
			end
		end
	end
	if not best then return end
	best.saves = direct - best.total
	local need = flightKeep[key] and FLY_KEEP_SAVE or FLY_MIN_SAVE
	if best.saves > need then return best end
end

---------------------------------------------------------------------------
-- Route model
---------------------------------------------------------------------------
local shown = {}      -- route as shown: own stops, quest stops, flight steps
local totals = { dist = 0, time = 0, rest = 0, restTime = 0, other = false }
local override        -- temporary destination (a quest picked in the tracker)
local skipped = {}    -- ["quest:123"] = true: quest-route stops skipped this session
local history = {}    -- undo stack for Previous
local arrowKey        -- position the arrow was last pointed at by us
local signature
local lists = {}      -- route list widgets (GPS panel and world map)

local function posKey(m, x, y)
	return ("%d:%.4f:%.4f"):format(m, x, y)
end

local function validWP(wp)
	return type(wp) == "table" and num(wp.mapID) and num(wp.x) and num(wp.y) and true or false
end

local function copyWP(wp)
	return { mapID = wp.mapID, x = wp.x, y = wp.y, title = wp.title, kind = wp.kind, questID = wp.questID }
end

local function pushHistory(h)
	history[#history + 1] = h
	while #history > HISTORY_MAX do table.remove(history, 1) end
end

-- Ghost: your corpse comes first (on your zone map, or the continent map)
local function corpseStop()
	local ghost = UnitIsGhost and flag(try(UnitIsGhost, "player"))
	if not ghost or not (C_DeathInfo and C_DeathInfo.GetCorpseMapPosition) then return end
	local m = playerMap()
	for _, map in ipairs({ m or 0, m and continentOf(m) or 0 }) do
		if map > 0 then
			local pos = try(C_DeathInfo.GetCorpseMapPosition, map)
			if pos and pos.GetXY then
				local x, y = pos:GetXY()
				x, y = num(x), num(y)
				if x and y and (x > 0 or y > 0) then
					return { mapID = map, x = x, y = y, title = L["Your corpse"], kind = "corpse", src = "corpse" }
				end
			end
		end
	end
end

local function questStops()
	local qp = RoA.QuestPlan
	if not (qp and qp.GetRoute) then return {} end
	local ok, route = pcall(qp.GetRoute, qp)
	if not ok or type(route) ~= "table" then return {} end
	local out = {}
	for _, stop in ipairs(route) do
		if type(stop) == "table" and validWP(stop) then
			local ids = type(stop.questIDs) == "table" and stop.questIDs or {}
			out[#out + 1] = {
				mapID = stop.mapID, x = stop.x, y = stop.y,
				kind = stop.turnIn and "turnin" or "quest",
				questID = num(ids[1]), questIDs = ids, title = titleFor(ids),
			}
		end
	end
	return out
end

local function buildBase()
	local cfg = db()
	local list, used = {}, {}
	local function mark(e)
		if e.questID then used[e.kind .. ":" .. e.questID] = true end
	end
	local corpse = corpseStop()
	if corpse then list[#list + 1] = corpse end
	if override and validWP(override) then
		local e = copyWP(override)
		e.src = "override"
		list[#list + 1] = e
		mark(e)
	end
	for i, wp in ipairs(cfg.queue) do
		if validWP(wp) then
			local e = copyWP(wp)
			e.kind = KIND[e.kind] and e.kind or "custom"
			e.title = str(e.title) or L["Waypoint"]
			e.src, e.index = "manual", i
			list[#list + 1] = e
			mark(e)
		end
	end
	if cfg.followQuests then
		for _, e in ipairs(questStops()) do
			local keep = false
			for _, id in ipairs(e.questIDs) do
				local k = e.kind .. ":" .. tostring(id)
				if not skipped[k] and not used[k] then keep = true end
			end
			if keep or #e.questIDs == 0 then
				e.src = "quest"
				list[#list + 1] = e
			end
		end
	end
	for _, e in ipairs(list) do e.key = posKey(e.mapID, e.x, e.y) end
	return list
end

local function applyArrow()
	local A = RoA.Arrow
	if not (A and A.SetTarget and A.Clear) then return end
	local cur = active() and shown[1]
	if not cur then
		if arrowKey then
			arrowKey = nil
			pcall(A.Clear, A)
		end
		return
	end
	local key = posKey(cur.mapID, cur.x, cur.y)
	if key == arrowKey then
		local m = A.GetTarget and try(A.GetTarget, A)
		if m then return end -- still set
	end
	if pcall(A.SetTarget, A, cur.mapID, cur.x, cur.y, cur.title) then arrowKey = key end
end

local updateLists, applyPanel, applyMinimap -- defined below

local function rebuild()
	local cfg = db()
	if not cfg then return end
	wipe(shown)
	totals.dist, totals.time, totals.rest, totals.restTime, totals.other = 0, 0, 0, 0, false
	if cfg.enabled then
		local base = buildBase()
		local pc, pn, pw = playerPos()
		local taxi = onTaxi()
		local speed = travelSpeed()
		local nodes
		if cfg.useFlights and not taxi and pc then
			local e = nodesFor(continentOf(playerMap()))
			nodes = e and e.known
		end
		local prev = pc and { cont = pc, wn = pn, ww = pw } or nil
		local cum, time = 0, 0
		for i, e in ipairs(base) do
			e.cont, e.wn, e.ww = worldPos(e.mapID, e.x, e.y)
			if prev and prev.cont and e.cont and prev.cont == e.cont then
				local f
				-- ghosts can't take flights
				if nodes and i <= FLIGHT_LEGS and not noFlight[e.key] and base[1].kind ~= "corpse" then
					f = bestFlight(prev, e, speed, e.key, nodes)
				end
				if f then
					flightKeep[e.key] = true
					local fe = {
						kind = "flight", src = "flight", mapID = f.a.mapID, x = f.a.x, y = f.a.y,
						cont = f.a.cont, wn = f.a.wn, ww = f.a.ww,
						title = L["Take flight at %s to %s"]:format(f.a.name, f.b.name),
						fromName = f.a.name, toName = f.b.name,
						toMapID = f.b.mapID, toX = f.b.x, toY = f.b.y,
						saves = f.saves, forKey = e.key, forTitle = e.title,
						legDist = f.walkA, legTime = f.walkA / speed,
					}
					fe.key = "flight:" .. e.key
					cum, time = cum + fe.legDist, time + fe.legTime
					fe.cum, fe.cumTime = cum, time
					shown[#shown + 1] = fe
					e.legDist = f.flyDist + f.walkB
					e.legTime = f.flyTime + f.walkB / speed
					e.viaFlight = true
				else
					flightKeep[e.key] = nil
					local d = wdist(prev, e)
					e.legDist, e.legTime = d, d / speed
				end
				cum, time = cum + e.legDist, time + e.legTime
				e.cum, e.cumTime = cum, time
			else
				e.other = (prev and prev.cont and e.cont) and true or nil
				if e.other then totals.other = true end
			end
			shown[#shown + 1] = e
			if e.cont then prev = e else prev = nil end
		end
		totals.dist, totals.time = cum, time
		local first = shown[1]
		if first and first.legDist then
			totals.rest, totals.restTime = cum - first.legDist, time - first.legTime
		else
			totals.rest, totals.restTime = cum, time
		end
	end
	for i, e in ipairs(shown) do e.rank = i end
	applyArrow()

	local parts = {}
	for _, e in ipairs(shown) do parts[#parts + 1] = e.kind .. "@" .. e.key end
	local sig = table.concat(parts, ",") .. (override and "o" or "")
	if sig ~= signature then
		signature = sig
		RoA:Fire("NAV")
	end
	if updateLists then updateLists() end
	if applyPanel then applyPanel() end
	if applyMinimap then guard("minimap", applyMinimap) end
end

local pendingRebuild = false
function NV:Request()
	if pendingRebuild then return end
	pendingRebuild = true
	C_Timer.After(REBUILD_WAIT, function()
		pendingRebuild = false
		guard("rebuild", rebuild)
	end)
end

function NV:RebuildNow()
	guard("rebuild", rebuild)
end

---------------------------------------------------------------------------
-- Own stops: keep quest stops up to date (objective -> turn-in -> gone)
---------------------------------------------------------------------------
local seenInLog = {}

local function refreshQuestWP(wp)
	local id = num(wp.questID)
	if not id or (wp.kind ~= "quest" and wp.kind ~= "turnin") then return "keep" end
	local il = inLog(id)
	if il then
		seenInLog[id] = true
		local changed = false
		local want = readyForTurnIn(id) and "turnin" or "quest"
		if wp.kind ~= want then
			wp.kind, changed = want, true
		end
		local m, x, y = questPosition(id)
		if m and (m ~= wp.mapID or math.abs(x - wp.x) > 0.002 or math.abs(y - wp.y) > 0.002) then
			wp.mapID, wp.x, wp.y, changed = m, x, y, true
		end
		return changed and "changed" or "keep"
	elseif il == false and seenInLog[id] then
		return "gone"
	end
	return "keep"
end

local function refreshManual()
	local cfg = db()
	if not cfg then return end
	local changed = false
	for i = #cfg.queue, 1, -1 do
		local wp = cfg.queue[i]
		if not validWP(wp) then
			table.remove(cfg.queue, i)
			changed = true
		else
			local r = refreshQuestWP(wp)
			if r == "gone" then
				table.remove(cfg.queue, i)
				changed = true
			elseif r == "changed" then
				changed = true
			end
		end
	end
	if override then
		local r = refreshQuestWP(override)
		if r == "gone" then
			override = nil
			changed = true
		elseif r == "changed" then
			changed = true
		end
	end
	if changed then NV:Request() end
end

-- QUEST_LOG_UPDATE comes in bursts: check the own quest stops at most once a second.
local pendingRefresh = false
local function requestRefresh()
	if pendingRefresh then return end
	pendingRefresh = true
	C_Timer.After(1, function()
		pendingRefresh = false
		guard("refresh", refreshManual)
	end)
end

local function removeQuest(id)
	local cfg = db()
	if not (cfg and id) then return end
	for i = #cfg.queue, 1, -1 do
		local wp = cfg.queue[i]
		if type(wp) == "table" and num(wp.questID) == id then table.remove(cfg.queue, i) end
	end
	if override and num(override.questID) == id then override = nil end
	NV:Request()
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function NV:IsActive() return active() end

-- While navigation is on, it decides where the arrow points.
function NV:OwnsArrow() return active() end

function NV:GetRoute() return shown end

function NV:GetTotals() return totals end

-- Adds a stop at the end of the own queue; returns its position or nil.
function NV:Add(mapID, x, y, title, kind, questID)
	local cfg = db()
	mapID, x, y = num(mapID), num(x), num(y)
	if not (cfg and mapID and x and y) then return end
	if x > 1 or y > 1 then x, y = x / 100, y / 100 end
	if x < 0 or x > 1 or y < 0 or y > 1 then return end
	if #cfg.queue >= MAX_QUEUE then
		RoA:Print(L["The route is full."])
		return
	end
	kind = KIND[kind] and kind or "custom"
	cfg.queue[#cfg.queue + 1] = { mapID = mapID, x = x, y = y, title = str(title) or L["Waypoint"], kind = kind, questID = num(questID) }
	self:RebuildNow()
	return #cfg.queue
end

-- Adds a quest (its objective area, or its turn-in when ready).
function NV:AddQuest(questID, title, m, x, y)
	local cfg = db()
	questID = num(questID)
	if not (cfg and questID) then return end
	title = str(title) or questTitle(questID)
	for _, wp in ipairs(cfg.queue) do
		if type(wp) == "table" and num(wp.questID) == questID then
			RoA:Print(L["Already in the route: %s"]:format(title))
			return
		end
	end
	if not (num(m) and num(x) and num(y)) then m, x, y = questPosition(questID) end
	if not m then
		RoA:Print(L["No position known for this quest."])
		return
	end
	seenInLog[questID] = true
	local n = self:Add(m, x, y, title, readyForTurnIn(questID) and "turnin" or "quest", questID)
	if n then RoA:Print(L["Added to route: %s (#%d)"]:format(title, n)) end
	return n
end

-- Temporary destination in front of the route (cleared on arrival).
function NV:SetOverride(mapID, x, y, title, kind, questID)
	mapID, x, y = num(mapID), num(x), num(y)
	if not (mapID and x and y) then return false end
	if questID then seenInLog[questID] = true end
	override = { mapID = mapID, x = x, y = y, title = str(title) or L["Next stop"],
		kind = KIND[kind] and kind or "custom", questID = num(questID) }
	self:RebuildNow()
	return true
end

function NV:ClearOverride()
	if not override then return end
	override = nil
	self:RebuildNow()
end

function NV:HasOverride() return override ~= nil end

function NV:SetFollowQuests(v)
	local cfg = db()
	if not cfg then return end
	cfg.followQuests = v and true or false
	RoA:Fire("SETTINGS", "nav")
end

-- Index of a shown own stop in the saved queue (re-checked: the queue may have changed).
local function manualIndex(e)
	local q = db().queue
	local function same(wp)
		if type(wp) ~= "table" then return false end
		if e.questID and wp.questID == e.questID then return true end
		return wp.mapID == e.mapID and wp.x == e.x and wp.y == e.y
	end
	if e.index and same(q[e.index]) then return e.index end
	for i, wp in ipairs(q) do
		if same(wp) then return i end
	end
end

local function skipEntry(e)
	local cfg = db()
	if not e then return end
	if e.src == "override" then
		pushHistory({ t = "override", wp = override })
		override = nil
	elseif e.src == "manual" then
		local i = manualIndex(e)
		local wp = i and table.remove(cfg.queue, i)
		if wp then pushHistory({ t = "manual", wp = wp, index = e.index }) end
	elseif e.src == "quest" then
		local keys = {}
		for _, id in ipairs(e.questIDs or {}) do
			local k = e.kind .. ":" .. tostring(id)
			skipped[k] = true
			keys[#keys + 1] = k
		end
		pushHistory({ t = "skip", keys = keys })
	elseif e.src == "flight" then
		noFlight[e.forKey] = true
		pushHistory({ t = "noflight", key = e.forKey })
	end
end

function NV:Skip()
	skipEntry(shown[1])
	self:RebuildNow()
end

function NV:RemoveShown(i)
	skipEntry(shown[i])
	self:RebuildNow()
end

function NV:Previous()
	local h = table.remove(history)
	if not h then return end
	local cfg = db()
	if h.t == "override" then
		override = h.wp
	elseif h.t == "manual" and h.wp then
		table.insert(cfg.queue, math.max(1, math.min(h.index or 1, #cfg.queue + 1)), h.wp)
	elseif h.t == "skip" then
		for _, k in ipairs(h.keys or {}) do skipped[k] = nil end
	elseif h.t == "noflight" and h.key then
		noFlight[h.key] = nil
	end
	self:RebuildNow()
end

function NV:CanGoBack() return #history > 0 end

-- Make a stop in the shown route the current one.
function NV:MakeCurrent(i)
	local e = shown[i]
	if not e or i == 1 then return end
	local cfg = db()
	if e.src == "flight" then
		e = shown[i + 1]
		if not e then return end
	end
	if e.src == "manual" then
		override = nil
		local idx = manualIndex(e)
		local wp = idx and table.remove(cfg.queue, idx)
		if wp then table.insert(cfg.queue, 1, wp) end
	elseif e.src == "quest" then
		override = { mapID = e.mapID, x = e.x, y = e.y, title = e.title, kind = e.kind, questID = e.questID }
	end
	self:RebuildNow()
end

-- Move an own stop up (-1) or down (+1).
function NV:MoveShown(i, delta)
	local e = shown[i]
	local cfg = db()
	if not (e and e.src == "manual" and cfg) then return end
	local i = manualIndex(e)
	if not i then return end
	local j = i + delta
	if j < 1 or j > #cfg.queue then return end
	cfg.queue[i], cfg.queue[j] = cfg.queue[j], cfg.queue[i]
	self:RebuildNow()
end

-- Ends the route: own stops, the selected quest and skips are cleared, and
-- following the quest route is paused (turn it back on in the route list).
function NV:Clear()
	local cfg = db()
	if not cfg then return end
	wipe(cfg.queue)
	override = nil
	wipe(skipped)
	wipe(noFlight)
	wipe(history)
	if cfg.followQuests then
		cfg.followQuests = false
		RoA:Print(L["Route cleared. Turn on \"Follow quest route\" to get the quest route back."])
		RoA:Fire("SETTINGS", "nav")
	end
	self:RebuildNow()
end

---------------------------------------------------------------------------
-- Arrival
---------------------------------------------------------------------------
local function onArrived(m, x, y)
	local cfg = db()
	local cur = shown[1]
	if not (cfg and cfg.enabled and cur and num(m) and num(x) and num(y)) then return end
	if posKey(m, x, y) ~= arrowKey then return end
	if cur.src == "override" then
		override = nil
		NV:RebuildNow()
	elseif cur.src == "manual" and cur.kind == "custom" and cfg.autoAdvance then
		local i = manualIndex(cur)
		local wp = i and table.remove(cfg.queue, i)
		if wp then pushHistory({ t = "manual", wp = wp, index = 1 }) end
		NV:RebuildNow()
	end
	-- quest stops move on when the quest log changes; flight steps when you take off
end

---------------------------------------------------------------------------
-- Small widgets
---------------------------------------------------------------------------
local function tip(owner, lines)
	if not GameTooltip then return end
	GameTooltip:SetOwner(owner, "ANCHOR_TOP")
	for i, l in ipairs(lines) do
		if i == 1 then
			GameTooltip:AddLine(l, 1, 1, 1)
		else
			GameTooltip:AddLine(l, 0.6, 0.65, 0.71, true)
		end
	end
	GameTooltip:Show()
end

local function hideTip(owner)
	if GameTooltip and GameTooltip:IsOwned(owner) then GameTooltip:Hide() end
end

local function smallButton(parent, text, w, tooltip, onClick)
	local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
	b:SetSize(w or 16, 14)
	S:Backdrop(b, 0.9)
	b.text = S:Font(b, 10)
	b.text:SetPoint("CENTER", 0, 0)
	b.text:SetText(text)
	b:RegisterForClicks("LeftButtonUp")
	b:SetScript("OnEnter", function(self)
		self:SetBackdropBorderColor(unpack(S.colors.accent))
		if tooltip then tip(self, { tooltip }) end
	end)
	b:SetScript("OnLeave", function(self)
		self:SetBackdropBorderColor(0, 0, 0, 1)
		hideTip(self)
	end)
	b:SetScript("OnClick", function(self, button) guard("button", onClick, self, button) end)
	return b
end

local function setKindIcon(tex, kind)
	local k = KIND[kind] or KIND.custom
	tex:SetTexture(k.icon)
	if k.crop then tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) else tex:SetTexCoord(0, 1, 0, 1) end
end

local function entryTooltip(owner, e)
	if not e then return end
	local lines = { e.title or L["Waypoint"], L[(KIND[e.kind] or KIND.custom).label] }
	if type(e.questIDs) == "table" and #e.questIDs > 1 then
		for _, id in ipairs(e.questIDs) do lines[#lines + 1] = questTitle(id) end
	end
	if e.cum then
		lines[#lines + 1] = distText(e.cum) .. "  " .. etaText(e.cumTime or 0)
	elseif e.other then
		lines[#lines + 1] = L["Other continent"]
	end
	if e.kind == "flight" and e.saves then
		lines[#lines + 1] = L["Saves ~%s"]:format(durText(e.saves))
	end
	if e.src == "quest" then
		lines[#lines + 1] = L["From the quest route"]
	end
	tip(owner, lines)
end

---------------------------------------------------------------------------
-- Route list (used under the GPS panel and next to the world map)
---------------------------------------------------------------------------
local function createList(parent, width)
	local o = { rows = {} }
	local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	f:SetSize(width, 80)
	S:Backdrop(f, 0.92)
	f:EnableMouse(true)
	o.frame = f

	local title = S:Font(f, 12)
	title:SetPoint("TOPLEFT", 6, -6)
	title:SetTextColor(unpack(S.colors.accent))
	title:SetText(L["Route"])

	local clear = smallButton(f, L["Clear"], 44, L["Clear route"], function()
		StaticPopupDialogs.ROADSOFAZEROTH_CLEAR = StaticPopupDialogs.ROADSOFAZEROTH_CLEAR or { button1 = YES, button2 = NO,
			timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3 }
		StaticPopupDialogs.ROADSOFAZEROTH_CLEAR.text = L["Clear the whole route?"]
		StaticPopupDialogs.ROADSOFAZEROTH_CLEAR.OnAccept = function() NV:Clear() end
		StaticPopup_Show("ROADSOFAZEROTH_CLEAR")
	end)
	clear:SetPoint("TOPRIGHT", -5, -5)
	local back = smallButton(f, "<", 18, L["Previous stop"], function() NV:Previous() end)
	back:SetPoint("RIGHT", clear, "LEFT", -10, 0)

	local chk = CreateFrame("Button", nil, f, "BackdropTemplate")
	chk:SetSize(12, 12)
	chk:SetPoint("TOPLEFT", 6, -24)
	S:Backdrop(chk, 1)
	chk.mark = chk:CreateTexture(nil, "OVERLAY")
	chk.mark:SetPoint("TOPLEFT", 2, -2)
	chk.mark:SetPoint("BOTTOMRIGHT", -2, 2)
	chk.mark:SetColorTexture(unpack(S.colors.accent))
	local chkText = S:Font(f, 11)
	chkText:SetPoint("LEFT", chk, "RIGHT", 5, 0)
	chkText:SetText(L["Follow quest route"])
	chk:SetHitRectInsets(0, -((chkText:GetStringWidth() or 100) + 8), 0, 0)
	chk:SetScript("OnClick", function()
		guard("follow", function() NV:SetFollowQuests(not db().followQuests) end)
	end)
	o.chk = chk

	o.empty = S:Font(f, 11)
	o.empty:SetTextColor(unpack(S.colors.muted))
	o.empty:SetJustifyH("LEFT")
	o.empty:SetWidth(width - 12)
	o.more = S:Font(f, 10)
	o.more:SetTextColor(unpack(S.colors.muted))
	o.footer = S:Font(f, 10)
	o.footer:SetTextColor(unpack(S.colors.muted))
	o.footer:SetJustifyH("LEFT")
	o.footer:SetWidth(width - 12)

	function o:Row(i)
		local r = self.rows[i]
		if r then return r end
		r = CreateFrame("Button", nil, f)
		r:SetHeight(ROW_H)
		r:RegisterForClicks("LeftButtonUp")
		local hl = r:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.06)
		r.num = S:Font(r, 11)
		r.num:SetPoint("LEFT", 0, 0)
		r.num:SetWidth(18)
		r.num:SetJustifyH("RIGHT")
		r.icon = r:CreateTexture(nil, "ARTWORK")
		r.icon:SetSize(13, 13)
		r.icon:SetPoint("LEFT", r.num, "RIGHT", 4, 0)
		r.del = smallButton(r, "x", 20, L["Remove from the route"], function(btn) NV:RemoveShown(btn:GetParent().index) end)
		r.del:SetPoint("RIGHT", 0, 0)
		r.down = smallButton(r, "v", 20, L["Move down"], function(btn) NV:MoveShown(btn:GetParent().index, 1) end)
		r.down:SetPoint("RIGHT", r.del, "LEFT", -2, 0)
		r.up = smallButton(r, "^", 20, L["Move up"], function(btn) NV:MoveShown(btn:GetParent().index, -1) end)
		r.up:SetPoint("RIGHT", r.down, "LEFT", -2, 0)
		r.dist = S:Font(r, 10)
		r.dist:SetPoint("RIGHT", r.up, "LEFT", -4, 0)
		r.dist:SetTextColor(unpack(S.colors.muted))
		r.text = S:Font(r, 11)
		r.text:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
		r.text:SetPoint("RIGHT", r.dist, "LEFT", -4, 0)
		r.text:SetJustifyH("LEFT")
		r.text:SetWordWrap(false)
		r:SetScript("OnClick", function(self) guard("row", function() NV:MakeCurrent(self.index) end) end)
		r:SetScript("OnEnter", function(self) guard("rowtip", entryTooltip, self, shown[self.index]) end)
		r:SetScript("OnLeave", hideTip)
		self.rows[i] = r
		return r
	end

	function o:Update()
		local cfg = db()
		if not cfg then return end
		self.chk.mark:SetShown(cfg.followQuests and true or false)
		back:SetEnabled(#history > 0)
		back:SetAlpha(#history > 0 and 1 or 0.4)
		local n = math.min(#shown, LIST_ROWS)
		local y = -42
		for i = 1, n do
			local e = shown[i]
			local r = self:Row(i)
			r.index = i
			r:ClearAllPoints()
			r:SetPoint("TOPLEFT", f, "TOPLEFT", 4, y)
			r:SetPoint("RIGHT", f, "RIGHT", -5, 0)
			r.num:SetText(i .. ".")
			local c = kindColor(e.kind)
			r.num:SetTextColor(c[1], c[2], c[3])
			setKindIcon(r.icon, e.kind)
			r.text:SetText(e.title or "")
			if i == 1 then
				r.text:SetTextColor(1, 1, 1)
			elseif e.kind == "flight" then
				local p = S.colors.proc
				r.text:SetTextColor(p[1], p[2], p[3])
			else
				r.text:SetTextColor(unpack(S.colors.text))
			end
			if e.cum then
				r.dist:SetText(distText(e.cum))
			elseif e.other then
				r.dist:SetText(L["Other continent"])
			else
				r.dist:SetText("")
			end
			local manual = e.src == "manual"
			r.up:SetShown(manual and e.index > 1)
			r.down:SetShown(manual and e.index < #cfg.queue)
			r:Show()
			y = y - ROW_H
		end
		for i = n + 1, #self.rows do self.rows[i]:Hide() end
		if #shown == 0 then
			self.empty:SetText(cfg.enabled and L["No stops yet: Ctrl-click the world map or a quest title to add one."]
				or L["Navigation is off (settings: Navigation)."])
			self.empty:ClearAllPoints()
			self.empty:SetPoint("TOPLEFT", f, "TOPLEFT", 6, y - 2)
			self.empty:Show()
			y = y - (self.empty:GetStringHeight() or 12) - 6
		else
			self.empty:Hide()
		end
		if #shown > n then
			self.more:SetText(L["+%d more"]:format(#shown - n))
			self.more:ClearAllPoints()
			self.more:SetPoint("TOPLEFT", f, "TOPLEFT", 26, y - 2)
			self.more:Show()
			y = y - 14
		else
			self.more:Hide()
		end
		local foot = L["Ctrl-click the map to add a stop."]
		if totals.dist > 0 then
			foot = L["Total: %s, %s"]:format(distText(totals.dist), etaText(totals.time))
				.. (totals.other and ("  " .. L["+ other continent"]) or "") .. "\n" .. foot
		end
		self.footer:SetText(foot)
		self.footer:ClearAllPoints()
		self.footer:SetPoint("TOPLEFT", f, "TOPLEFT", 6, y - 4)
		f:SetHeight(-y + (self.footer:GetStringHeight() or 24) + 12)
	end

	lists[#lists + 1] = o
	return o
end

---------------------------------------------------------------------------
-- GPS panel
---------------------------------------------------------------------------
local panel, gpsList
local listOpen = false
local inCombat = false

local function setArrowShown(show)
	if not panel then return end
	panel.arrow:SetShown(show)
end

local function updatePanel()
	if not panel or not panel:IsShown() then return end
	local cur = shown[1]
	local A = RoA.Arrow
	if not cur then
		panel.kind:Hide()
		panel.title:SetText(L["No route"])
		panel.dist:SetText("—")
		panel.eta:SetText("")
		panel.nextText:SetText("")
		panel.route:SetText("")
		panel.hint:SetText(L["Ctrl-click the world map or a quest title to add stops."])
		panel.arrow:SetRotation(0)
		panel.arrow:SetVertexColor(unpack(S.colors.muted))
		setArrowShown(true)
		return
	end
	panel.kind:Show()
	setKindIcon(panel.kind, cur.kind)
	panel.title:SetText(cur.title or L["Next stop"])

	local status, d, rel, arrived, r, g, b
	if A and A.GetState then status, d, rel, arrived, r, g, b = A:GetState() end
	local speed = travelSpeed()
	if status == "ok" and d then
		if rel then
			panel.arrow:SetRotation(rel)
			panel.arrow:SetVertexColor(r or 1, g or 1, b or 1, 1)
			setArrowShown(true)
		else
			setArrowShown(false)
		end
		if arrived then
			panel.dist:SetText(L["Arrived"])
			panel.dist:SetTextColor(GREEN[1], GREEN[2], GREEN[3])
			panel.eta:SetText("")
		else
			panel.dist:SetText(distText(d))
			panel.dist:SetTextColor(1, 1, 1)
			panel.eta:SetText(etaText(d / speed))
		end
	else
		setArrowShown(false)
		panel.dist:SetTextColor(unpack(S.colors.muted))
		panel.dist:SetText(status == "other" and L["Other continent"] or status == "nopos" and L["No position here"] or "—")
		panel.eta:SetText("")
	end

	local nxt = shown[2]
	panel.nextText:SetText(nxt and L["then: %s"]:format(nxt.title or "") or "")

	-- remaining route: live distance to the current stop plus the legs after it
	if #shown > 1 or totals.other then
		local liveD = (status == "ok" and d) or 0
		local dist = liveD + totals.rest
		local time = liveD / speed + totals.restTime
		local text = L["%d stops"]:format(#shown)
		if dist > 0 then text = text .. " · " .. distText(dist) .. " · " .. etaText(time) end
		if totals.other then text = text .. "  " .. L["+ other continent"] end
		panel.route:SetText(text)
	else
		panel.route:SetText("")
	end

	-- hint: flights
	local hint = ""
	if onTaxi() then
		hint = L["In flight"]
	elseif cur.kind == "flight" then
		if arrived then
			hint = L["Talk to the flight master: fly to %s"]:format(cur.toName or "?")
		else
			hint = L["Fly from %s to %s (saves ~%s)"]:format(cur.fromName or "?", cur.toName or "?", durText(cur.saves or 0))
		end
	else
		for i = 2, #shown do
			local e = shown[i]
			if e.kind == "flight" then
				hint = L["Later: fly from %s to %s"]:format(e.fromName or "?", e.toName or "?")
				break
			end
		end
	end
	panel.hint:SetText(hint)
end

local panelAcc = 0
local function panelOnUpdate(self, elapsed)
	panelAcc = panelAcc + elapsed
	if panelAcc < PANEL_TICK then return end
	panelAcc = 0
	if not guard("panel", updatePanel) then
		self:SetScript("OnUpdate", nil) -- never repeat an error every frame
	end
end

local function buildPanel()
	if panel or not RoA.char then return end
	local p = CreateFrame("Frame", "RoadsOfAzerothNavPanel", UIParent, "BackdropTemplate")
	p:SetSize(280, 92)
	p:SetFrameStrata("MEDIUM")
	S:Backdrop(p, 0.8)
	p:Hide()
	panel = p

	p.arrow = p:CreateTexture(nil, "ARTWORK")
	p.arrow:SetSize(60, 60)
	p.arrow:SetPoint("LEFT", 6, 2)
	p.arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
	p.arrow:SetDesaturated(true)
	p.arrow:SetVertexColor(unpack(S.colors.accent))

	-- hover area over the arrow: the straight-line note
	local ah = CreateFrame("Frame", nil, p)
	ah:SetAllPoints(p.arrow)
	ah:EnableMouse(true)
	ah:SetScript("OnEnter", function(self)
		tip(self, { L["Direction"], L["The arrow shows the straight-line direction, not a path around hills or water."],
			L["Green: ahead. Red: behind you."] })
	end)
	ah:SetScript("OnLeave", hideTip)

	local left = 72
	p.kind = p:CreateTexture(nil, "ARTWORK")
	p.kind:SetSize(14, 14)
	p.kind:SetPoint("TOPLEFT", left, -6)

	-- buttons, top right
	local clear = smallButton(p, "x", 16, L["Clear route"], function() NV:Clear() end)
	clear:SetPoint("TOPRIGHT", -5, -5)
	local list = smallButton(p, "=", 16, L["Route list"], function()
		listOpen = not listOpen
		applyPanel()
	end)
	list:SetPoint("RIGHT", clear, "LEFT", -2, 0)
	local skip = smallButton(p, ">", 16, L["Skip this stop"], function() NV:Skip() end)
	skip:SetPoint("RIGHT", list, "LEFT", -2, 0)
	local prev = smallButton(p, "<", 16, L["Previous stop"], function() NV:Previous() end)
	prev:SetPoint("RIGHT", skip, "LEFT", -2, 0)

	p.title = S:Font(p, 12)
	p.title:SetPoint("LEFT", p.kind, "RIGHT", 4, 0)
	p.title:SetPoint("RIGHT", prev, "LEFT", -4, 0)
	p.title:SetJustifyH("LEFT")
	p.title:SetWordWrap(false)
	if p.title.SetMaxLines then p.title:SetMaxLines(1) end

	p.dist = S:Font(p, 18)
	p.dist:SetPoint("TOPLEFT", left, -24)
	p.eta = S:Font(p, 13)
	p.eta:SetPoint("BOTTOMLEFT", p.dist, "BOTTOMRIGHT", 8, 1)
	p.eta:SetTextColor(unpack(S.colors.muted))

	local function line(y, color)
		local fs = S:Font(p, 11)
		fs:SetPoint("TOPLEFT", left, y)
		fs:SetPoint("RIGHT", p, "RIGHT", -6, 0)
		fs:SetJustifyH("LEFT")
		fs:SetWordWrap(false)
		fs:SetTextColor(unpack(color))
		return fs
	end
	p.nextText = line(-46, S.colors.text)
	p.route = line(-60, S.colors.muted)
	p.hint = line(-74, S.colors.hint)

	p:EnableMouse(true)
	S:RegisterMover(p, "nav", L["GPS"], function(f)
		f:SetPoint("TOP", UIParent, "TOP", 0, -120)
	end)

	gpsList = createList(p, 280)
	gpsList.frame:SetPoint("TOP", p, "BOTTOM", 0, -2)
	gpsList.frame:Hide()
end

function applyPanel()
	local cfg = db()
	if not cfg then return end
	buildPanel()
	if not panel then return end
	local want = cfg.enabled and cfg.showPanel and true or false
	local scale = num(cfg.panelScale)
	panel:SetScale((scale and scale >= 0.5 and scale <= 2) and scale or 1)
	local unlocked = RoA.char.bars and not RoA.char.bars.locked and not inCombat and not InCombatLockdown()
	if want and (shown[1] or unlocked or listOpen) then
		if not panel:IsShown() then
			panel:Show()
			panelAcc = PANEL_TICK
		end
		panel:SetScript("OnUpdate", panelOnUpdate)
	else
		panel:Hide()
		panel:SetScript("OnUpdate", nil)
	end
	if gpsList then
		local was = gpsList.frame:IsShown()
		gpsList.frame:SetShown(panel:IsShown() and listOpen)
		if gpsList.frame:IsShown() and not was then guard("list", gpsList.Update, gpsList) end
	end
	local A = RoA.Arrow
	if A and A.SetEmbedded then pcall(A.SetEmbedded, A, want) end
end

---------------------------------------------------------------------------
-- World map: route list and Ctrl-click to add a stop
---------------------------------------------------------------------------
local WMF, mapList
local mapMaximized

local function isMaximized()
	return WMF and WMF.IsMaximized and try(WMF.IsMaximized, WMF) and true or false
end

local function placeMapList()
	if not mapList then return end
	local f = mapList.frame
	mapMaximized = isMaximized()
	f:ClearAllPoints()
	local sc = WMF.ScrollContainer
	if mapMaximized and sc then
		-- full screen map: inside the map, top right
		f:SetPoint("TOPRIGHT", sc, "TOPRIGHT", -6, -6)
	else
		f:SetPoint("TOPLEFT", WMF, "TOPRIGHT", 3, 0)
	end
	local base = sc and sc:GetFrameLevel() or WMF:GetFrameLevel()
	f:SetFrameLevel(math.min(9500, base + 6000))
end

local function applyMapList()
	if not mapList then return end
	local cfg = db()
	local show = cfg and cfg.enabled and cfg.mapList and WMF:IsShown()
	if show then
		placeMapList()
		mapList.frame:Show()
		mapList:Update()
	else
		mapList.frame:Hide()
	end
end

function updateLists()
	for _, o in ipairs(lists) do
		if o.frame:IsShown() then guard("list", o.Update, o) end
	end
end

local function onMapMouseUp(_, button)
	if button ~= "LeftButton" or not (IsControlKeyDown and IsControlKeyDown()) then return end
	if not active() then return end
	local sc = WMF.ScrollContainer
	if not (sc and sc.GetNormalizedCursorPosition and WMF.GetMapID) then return end
	local cx, cy = try(sc.GetNormalizedCursorPosition, sc)
	cx, cy = num(cx), num(cy)
	local mapID = num(try(WMF.GetMapID, WMF))
	if not (cx and cy and mapID) or cx < 0 or cx > 1 or cy < 0 or cy > 1 then return end
	if not worldPos(mapID, cx, cy) or not continentOf(mapID) then
		RoA:Print(L["Cannot place a stop on this map."])
		return
	end
	local title = ("%s %.1f, %.1f"):format(mapName(mapID) or L["Waypoint"], cx * 100, cy * 100)
	local n = NV:Add(mapID, cx, cy, title, "custom")
	if n then RoA:Print(L["Stop added: %s (#%d)"]:format(title, n)) end
end

local function setupMap()
	if WMF or not WorldMapFrame then return end
	WMF = WorldMapFrame
	mapList = createList(WMF, 250)
	mapList.frame:Hide()
	-- read-only post-hooks: only the cursor position is read
	WMF:HookScript("OnShow", function() guard("maplist", applyMapList) end)
	WMF:HookScript("OnHide", function() if mapList then mapList.frame:Hide() end end)
	if WMF.ScrollContainer then
		WMF.ScrollContainer:HookScript("OnMouseUp", function(...) guard("ctrlclick", onMapMouseUp, ...) end)
	end
	-- follow maximize/minimize (checked twice a second while the map is open)
	local t = CreateFrame("Frame", nil, WMF)
	local acc = 0
	t:SetScript("OnUpdate", function(_, e)
		acc = acc + e
		if acc < 0.5 then return end
		acc = 0
		if mapList and mapList.frame:IsShown() and isMaximized() ~= mapMaximized then
			guard("maplist", placeMapList)
		end
	end)
	if WMF:IsShown() then guard("maplist", applyMapList) end
end

---------------------------------------------------------------------------
-- Minimap: current stop and the next ones, with lines (own frames on Minimap)
---------------------------------------------------------------------------
-- Minimap diameter in yards per zoom level (HereBeDragons-Pins tables)
local MM_INDOOR = { [0] = 300, [1] = 240, [2] = 180, [3] = 120, [4] = 80, [5] = 50 }
local MM_OUTDOOR = { [0] = 466 + 2 / 3, [1] = 400, [2] = 333 + 1 / 3, [3] = 266 + 2 / 6, [4] = 200, [5] = 133 + 1 / 3 }
local MM_STOPS = 4      -- current stop plus the next three
local MM_TICK = 0.1     -- ~10 Hz
local MM_PIN = 12
local MM_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local mm, mmPins, mmLines = nil, {}, {}

local function getCVar(name)
	local fn = C_CVar and C_CVar.GetCVar or GetCVar
	return fn and str(try(fn, name))
end

local function minimapYards()
	local zoom = Minimap.GetZoom and num(try(Minimap.GetZoom, Minimap)) or 0
	zoom = math.max(0, math.min(5, math.floor(zoom + 0.5)))
	local indoor
	if IsIndoors then
		local ok, v = pcall(IsIndoors)
		if ok and not IsSecret(v) then indoor = v and true or false end
	end
	if indoor == nil then
		-- the two zoom CVars differ: the one that matches the current zoom tells
		local outZ, inZ = tonumber(getCVar("minimapZoom") or ""), tonumber(getCVar("minimapInsideZoom") or "")
		indoor = outZ ~= nil and inZ ~= nil and outZ ~= inZ and inZ == zoom or false
	end
	return (indoor and MM_INDOOR or MM_OUTDOOR)[zoom] / 2 -- radius
end

local function minimapSquare()
	if not GetMinimapShape then return false end
	local shape = str(try(GetMinimapShape))
	return shape == "SQUARE"
end

local function mmPin(i)
	local p = mmPins[i]
	if p then return p end
	p = CreateFrame("Frame", nil, mm)
	p:SetSize(MM_PIN, MM_PIN)
	p.ring = p:CreateTexture(nil, "BACKGROUND")
	p.ring:SetSize(MM_PIN + 2, MM_PIN + 2)
	p.ring:SetPoint("CENTER")
	p.fill = p:CreateTexture(nil, "ARTWORK")
	p.fill:SetSize(MM_PIN - 2, MM_PIN - 2)
	p.fill:SetPoint("CENTER")
	for _, t in ipairs({ p.ring, p.fill }) do
		t:SetColorTexture(1, 1, 1, 1)
		if p.CreateMaskTexture then
			local mask = p:CreateMaskTexture()
			mask:SetTexture(MM_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
			mask:SetAllPoints(t)
			t:AddMaskTexture(mask)
		end
	end
	p.text = S:Font(p, 8)
	p.text:SetPoint("CENTER", 0, 0)
	-- edge marker: small arrow pointing outward
	p.edge = p:CreateTexture(nil, "OVERLAY")
	p.edge:SetSize(MM_PIN + 2, MM_PIN + 2)
	p.edge:SetPoint("CENTER")
	p.edge:SetTexture("Interface\\Minimap\\MinimapArrow")
	p.edge:SetDesaturated(true)
	mmPins[i] = p
	return p
end

local function mmLine(i, c, a)
	local ln = mmLines[i]
	if not ln then
		ln = mm:CreateLine(nil, "ARTWORK")
		ln:SetThickness(2)
		mmLines[i] = ln
	end
	ln:SetColorTexture(c[1], c[2], c[3], a or 0.8)
	ln:Show()
	return ln
end

local function mmHideAll()
	for _, p in ipairs(mmPins) do p:Hide() end
	for _, l in ipairs(mmLines) do l:Hide() end
end

local function mmUpdate()
	local pc, pn, pw = playerPos()
	if not pc or not shown[1] then return mmHideAll() end
	local rotate = getCVar("rotateMinimap") == "1"
	local cosF, sinF = 1, 0
	if rotate then
		local f = GetPlayerFacing and num(try(GetPlayerFacing))
		if not f then return mmHideAll() end -- facing hidden: positions would be wrong
		cosF, sinF = math.cos(f), math.sin(f)
	end
	local radiusPx = (num(Minimap:GetWidth()) or 140) / 2
	local scale = radiusPx / minimapYards()
	local square = minimapSquare()
	local limit = radiusPx - MM_PIN / 2 - 1
	local pts, n = {}, 0
	for i = 1, math.min(#shown, MM_STOPS) do
		local e = shown[i]
		if e.cont and e.cont == pc then
			-- screen: x east, y north
			local x, y = -(e.ww - pw) * scale, (e.wn - pn) * scale
			if rotate then x, y = x * cosF + y * sinF, -x * sinF + y * cosF end
			local edge = false
			if square then
				local m = math.max(math.abs(x), math.abs(y))
				if m > limit then x, y, edge = x * limit / m, y * limit / m, true end
			else
				local d = (x * x + y * y) ^ 0.5
				if d > limit then x, y, edge = x * limit / d, y * limit / d, true end
			end
			n = n + 1
			local p = mmPin(n)
			local c = kindColor(e.kind)
			p:ClearAllPoints()
			p:SetPoint("CENTER", mm, "CENTER", x, y)
			if edge then
				p.ring:Hide()
				p.fill:Hide()
				p.text:SetText("")
				p.edge:SetRotation(atan2(-x, y))
				p.edge:SetVertexColor(c[1], c[2], c[3], i == 1 and 1 or 0.7)
				p.edge:Show()
			else
				p.edge:Hide()
				p.ring:Show()
				p.fill:Show()
				if i == 1 then p.ring:SetVertexColor(1, 1, 1, 1) else p.ring:SetVertexColor(0, 0, 0, 0.9) end
				p.fill:SetVertexColor(c[1], c[2], c[3], 1)
				p.text:SetText(e.kind == "flight" and "F" or i)
			end
			p:Show()
			pts[i] = { x = x, y = y, edge = edge }
		end
	end
	for i = n + 1, #mmPins do mmPins[i]:Hide() end
	-- lines: player (centre) to the current stop, then between stops that fit
	local ln = 0
	if pts[1] then
		ln = ln + 1
		local l = mmLine(ln, S.colors.accent, 0.8)
		l:SetStartPoint("CENTER", mm, 0, 0)
		l:SetEndPoint("CENTER", mm, pts[1].x, pts[1].y)
	end
	for i = 2, MM_STOPS do
		local a, b = pts[i - 1], pts[i]
		if a and b and not a.edge and not b.edge then
			ln = ln + 1
			local l = mmLine(ln, shown[i - 1].kind == "flight" and S.colors.proc or S.colors.accent, 0.6)
			l:SetStartPoint("CENTER", mm, a.x, a.y)
			l:SetEndPoint("CENTER", mm, b.x, b.y)
		end
	end
	for i = ln + 1, #mmLines do mmLines[i]:Hide() end
end

local mmAcc = 0
local function mmOnUpdate(self, elapsed)
	mmAcc = mmAcc + elapsed
	if mmAcc < MM_TICK then return end
	mmAcc = 0
	if not guard("minimap", mmUpdate) then
		mmHideAll()
		self:SetScript("OnUpdate", nil) -- never repeat an error every frame
	end
end

function applyMinimap()
	if not Minimap then return end
	local cfg = db()
	local want = cfg and cfg.enabled and cfg.minimap and shown[1] and true or false
	if not mm then
		if not want then return end
		mm = CreateFrame("Frame", nil, Minimap)
		mm:SetAllPoints(Minimap)
		mm:EnableMouse(false)
		mm:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 5)
	end
	if want then
		mm:Show()
		mm:SetScript("OnUpdate", mmOnUpdate)
	else
		mm:SetScript("OnUpdate", nil)
		mmHideAll()
		mm:Hide()
	end
end

---------------------------------------------------------------------------
-- Learning the mounted speed (for ETAs while standing still on a mount)
---------------------------------------------------------------------------
local function learnMountSpeed()
	local A = RoA.Arrow
	if not (A and A.IsMounted and A.IsMounted()) or InCombatLockdown() or onTaxi() then return end
	if IsFlying and flag(try(IsFlying)) then return end
	if not GetUnitSpeed then return end
	local cur = num((try(GetUnitSpeed, "player")))
	if not cur or cur < 8 or cur > 60 then return end
	local q = RoA.char and RoA.char.questLearn
	if type(q) ~= "table" then return end
	local old = num(q.mountSpeed)
	q.mountSpeed = old and (old + (cur - old) * 0.1) or cur
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
local ticks = 0
local function tick()
	if not RoA.char then return end
	learnMountSpeed()
	ticks = ticks + 1
	-- re-plan every 2 s (distances, flight choices from where you stand)
	if ticks % 2 == 0 and active() then NV:Request() end
end

function NV:OnInit()
	db()
end

function NV:OnEnable()
	db()
	guard("panel", buildPanel)

	on("QUEST_LOG_UPDATE", function()
		if active() then
			requestRefresh()
			NV:Request()
		end
	end)
	on("QUEST_TURNED_IN", function(_, questID) removeQuest(num(questID)) end)
	on("TAXIMAP_OPENED", function() learnFromTaxiMap(); NV:Request() end)
	on("TAXIMAP_CLOSED", function() wipe(taxiCache); NV:Request() end)
	on("UI_INFO_MESSAGE", function(_, _, msg)
		local m = str(msg)
		if m and ERR_NEWTAXIPATH and m == ERR_NEWTAXIPATH then
			learnNearestNode()
			NV:Request()
		end
	end)
	on("PLAYER_ENTERING_WORLD", function() wipe(taxiCache); NV:Request() end)
	-- corpse run: the corpse becomes the first stop while you are a ghost
	for _, ev in ipairs({ "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST" }) do
		on(ev, function() NV:RebuildNow() end)
	end
	on("ZONE_CHANGED_NEW_AREA", function() NV:Request() end)
	on("PLAYER_CONTROL_LOST", function() NV:Request() end)   -- taking a flight
	on("PLAYER_CONTROL_GAINED", function() NV:Request() end) -- landed
	on("PLAYER_REGEN_DISABLED", function() inCombat = true; applyPanel() end)
	on("PLAYER_REGEN_ENABLED", function() inCombat = false; applyPanel() end)

	RoA:Listen("QUESTPLAN", function() if active() then NV:Request() end end)
	RoA:Listen("ARROW_ARRIVED", function(m, x, y) guard("arrived", onArrived, m, x, y) end)
	RoA:Listen("SETTINGS", function(group)
		if group == "nav" then
			guard("settings", function()
				if not active() then override = nil end
				-- taking over from the tracker: its old arrow target is ours to clear
				local A = RoA.Arrow
				if active() and not arrowKey and A and A.GetTarget and try(A.GetTarget, A) then arrowKey = "tracker" end
				rebuild()
				applyPanel()
				if WMF then applyMapList() end
				-- the quest tracker drives the arrow again when navigation is off
				local Q = RoA.Quests
				if Q and Q.Schedule then Q.arrowKey = nil; Q:Schedule() end
			end)
		elseif group == "bars" then
			guard("settings", applyPanel)
		end
	end)

	if WorldMapFrame then
		guard("map", setupMap)
	else
		on("ADDON_LOADED", function(_, name)
			if name == "Blizzard_WorldMap" then setupMap() end
		end)
	end

	if C_Timer and C_Timer.NewTicker then
		C_Timer.NewTicker(1, function() guard("tick", tick) end)
	end
	refreshManual()
	self:Request()
	guard("panel", applyPanel)
end
