-- Roads of Azeroth by DinX: quest tracker, smart quest route, GPS and arrow.
-- Display and navigation only: it never accepts, turns in, casts or moves anything.
local ADDON, ns = ...

local RoA = CreateFrame("Frame", "RoadsOfAzerothCore")
ns.RoA = RoA
_G.RoadsOfAzeroth = RoA

RoA.version = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON, "Version") or "?"
RoA.modules = {}

---------------------------------------------------------------------------
-- Defaults
---------------------------------------------------------------------------
local charDefaults = {
	next = { enabled = true },  -- the next step in one line (NextStep.lua, mover "next")
	flights = {                 -- Flights.lua
		enabled = true,
		panel = true,       -- times and prices beside the flight map
		bar = true,         -- countdown to the landing (mover "flight")
		mapPins = true,     -- known and unknown flight paths on the world map
		newNearby = true,   -- one line when a zone has a flight path you don't know
	},
	nav = {
		enabled = true,
		followQuests = true, -- smart quest route (QuestPlan) after the own stops
		useFlights = true,   -- suggest known flight paths when they save > 60 s
		showPanel = true,    -- GPS panel (mover "nav"); off = the small arrow frame
		panelScale = 1,
		mapList = true,      -- route list docked to the world map
		minimap = true,      -- current stop + next 3 on the minimap, with lines
		autoAdvance = true,  -- own custom waypoints leave the route on arrival
		trails = true,       -- learn walked paths (account wide) and steer along them
		queue = {},          -- own stops {mapID, x, y, title, kind, questID}
		taxiKnown = {},      -- flight path node IDs (and "n:<name>") seen at flight masters
	},
	quests = {
		enabled = true,
		hideBlizzard = true,
		hideQuestieTracker = true,
		zoneFirst = true,
		hideDone = true,
		maxQuests = 12,
		width = 260,
		fontSize = 12,
		collapsed = {},
		allCollapsed = false,
		sortMode = "smart", -- smart, distance, xp, xpmin, level, progress, zone
		routeStrategy = "balanced", -- balanced, turnin, quest, nearest
		lockRoute = true, -- keep the smart route until "Recalculate route" is clicked
		frozenRoute = nil, -- saved stop order (quest keys) while the route is locked
		showEstimates = true,
		arrow = true, -- the arrow (Arrow.lua) to the next stop
		pickup = true,      -- "Pick up nearby" under the quest list (Pickup.lua)
		pickupOpen = false, -- folded open or not
	},
	map = {
		enabled = true, -- route on the world map
		route = true,
		trails = false, -- learned paths as a heatmap (button on the map)
	},
	arrow = {
		enabled = true,
		scale = 1,
		arriveYards = 15,
	},
	bars = { locked = true }, -- "Frames locked": movers hidden (same key as in Casters of Azeroth)
	questLearn = {}, -- learned kill time, drop rates, run speed (QuestPlan.lua)
	points = {},     -- saved positions of movable frames, by key
}

local accountDefaults = {
	language = "auto", -- "auto", "enUS" or "nlNL"
	font = "roboto",   -- "roboto" or "wow"; Casters of Azeroth's choice wins when loaded
	fontOutline = false,
}

-- Bumped when the layout of the saved data changes (external tools read it).
RoA.SCHEMA = 1

local function merge(dst, src)
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then dst[k] = {} end
			merge(dst[k], v)
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
end

local function copy(t)
	local r = {}
	for k, v in pairs(t) do r[k] = type(v) == "table" and copy(v) or v end
	return r
end
RoA.CopyTable = copy

---------------------------------------------------------------------------
-- Printing, events, modules
---------------------------------------------------------------------------
function RoA:Print(...)
	print("|cff69ccf0Roads of Azeroth|r:", ...)
end

local handlers = {}
function RoA:On(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		local ok = pcall(self.RegisterEvent, self, event) -- unknown events on this client are skipped
		if not ok then handlers[event] = nil return end
	end
	table.insert(handlers[event], fn)
end

RoA:SetScript("OnEvent", function(self, event, ...)
	local list = handlers[event]
	if list then
		local prev = RoA.where
		RoA.where = (prev and prev .. " > " or "") .. event
		for i = 1, #list do list[i](event, ...) end
		RoA.where = prev
	end
end)

-- Modules get :OnInit() at ADDON_LOADED and :OnEnable() at PLAYER_LOGIN.
function RoA:NewModule(name)
	local m = { name = name }
	self.modules[#self.modules + 1] = m
	self[name] = m
	return m
end

-- Run fn now, or as soon as combat ends (secure frames cannot change in combat).
local afterCombat = {}
function RoA:OutOfCombat(key, fn)
	if not InCombatLockdown() then
		fn()
	else
		afterCombat[key] = fn
	end
end
RoA:On("PLAYER_REGEN_ENABLED", function()
	for k, fn in pairs(afterCombat) do
		afterCombat[k] = nil
		fn()
	end
end)

-- Simple callback bus so modules can react to settings changes.
local callbacks = {}
function RoA:Listen(msg, fn)
	callbacks[msg] = callbacks[msg] or {}
	table.insert(callbacks[msg], fn)
end
function RoA:Fire(msg, ...)
	for _, fn in ipairs(callbacks[msg] or {}) do fn(...) end
end

---------------------------------------------------------------------------
-- Secret values: in combat Blizzard hides some numbers from addons.
---------------------------------------------------------------------------
local issecret = issecretvalue or function() return false end
RoA.IsSecret = issecret

-- Returns v, or default when v is a secret value.
function RoA.Safe(v, default)
	if issecret(v) then return default end
	if v == nil then return default end
	return v
end

-- Remove a key we may have tainted and make the table slot secure again.
function RoA.PurgeKey(t, k)
	t[k] = nil
	local c = 42
	repeat
		if t[c] == nil then t[c] = nil end
		c = c + 1
	until not issecurevariable or issecurevariable(t, k)
end

-- Hide a Blizzard (Edit Mode) frame without tainting it.
function RoA.HideBlizzardFrame(frame, parent)
	if not frame then return end
	if frame.system then pcall(RoA.PurgeKey, frame, "isShownExternal") end
	if frame.HideBase then frame:HideBase() else frame:Hide() end
	if parent then frame:SetParent(parent) end
end

-- Casters of Azeroth (formerly CasterKit) when it is loaded, else nil.
function RoA:Casters()
	local c = _G.CastersOfAzeroth or _G.CasterKit
	if type(c) == "table" and type(c.char) == "table" then return c end
end

-- One lock for all frames: with Casters of Azeroth loaded its "Frames locked" wins.
function RoA:FramesLocked()
	local c = self:Casters()
	if c and type(c.char.bars) == "table" then return c.char.bars.locked ~= false end
	return self.char.bars.locked
end

function RoA:SetFramesLocked(locked)
	self.char.bars.locked = locked
	local c = self:Casters()
	if c and type(c.char.bars) == "table" then
		c.char.bars.locked = locked
		if c.Fire then c:Fire("SETTINGS", "bars") end
	end
	self:Fire("SETTINGS", "bars")
end

---------------------------------------------------------------------------
-- Timed quests: seconds left, or nil for quests without a timer
---------------------------------------------------------------------------
local deadlines, deadlinesAt = {}, -1

local function questIDAt(index)
	if C_QuestLog and C_QuestLog.GetInfo then
		local ok, info = pcall(C_QuestLog.GetInfo, index)
		local id = ok and type(info) == "table" and RoA.Safe(info.questID, nil)
		if type(id) == "number" then return id end
	end
	if GetQuestLogTitle then
		local ok, _, _, _, _, _, _, _, id = pcall(GetQuestLogTitle, index)
		id = ok and RoA.Safe(id, nil)
		if type(id) == "number" then return id end
	end
end

local function readTimers()
	wipe(deadlines)
	local now = GetTime()
	-- classic: one timer per timed quest, matched to its quest log line
	if GetQuestTimers and GetQuestIndexForTimer then
		local t = { pcall(GetQuestTimers) }
		if t[1] then
			for i = 2, #t do
				local left = RoA.Safe(t[i], nil)
				local ok, index = pcall(GetQuestIndexForTimer, i - 1)
				local id = ok and type(index) == "number" and questIDAt(index)
				if id and type(left) == "number" and left > 0 then deadlines[id] = now + left end
			end
		end
	end
	deadlinesAt = now
end

function RoA:QuestTimeLeft(questID)
	if not questID then return end
	local now = GetTime()
	if now - deadlinesAt > 5 then readTimers() end
	local d = deadlines[questID]
	if not d and C_QuestLog and C_QuestLog.GetTimeAllowed then
		local ok, total, elapsed = pcall(C_QuestLog.GetTimeAllowed, questID)
		total, elapsed = ok and RoA.Safe(total, nil), ok and RoA.Safe(elapsed, nil)
		if type(total) == "number" and type(elapsed) == "number" and total > 0 and elapsed < total then
			d = now + (total - elapsed)
			deadlines[questID] = d
		end
	end
	if d then return math.max(0, d - now) end
end

RoA:On("QUEST_LOG_UPDATE", function() deadlinesAt = -1 end)

---------------------------------------------------------------------------
-- One-time move of the route data from CasterKit's saved variables
---------------------------------------------------------------------------
local MOVED = { "nav", "quests", "arrow", "questLearn" }
local MOVED_POINTS = { "quests", "nav", "arrow" }

local function migrate(char)
	if char.migratedFromCK then return end
	local src = type(_G.CasterKitCharDB) == "table" and _G.CasterKitCharDB or nil
	if not src then return end -- CasterKit not loaded (yet): try again next time
	char.migratedFromCK = true
	local moved = false
	for _, k in ipairs(MOVED) do
		if type(src[k]) == "table" and next(src[k]) ~= nil then
			char[k] = copy(src[k])
			moved = true
		end
	end
	if type(src.map) == "table" and src.map.route ~= nil then
		char.map = char.map or {}
		char.map.route = src.map.route
	end
	if type(src.points) == "table" then
		char.points = char.points or {}
		for _, k in ipairs(MOVED_POINTS) do
			if type(src.points[k]) == "table" then char.points[k] = copy(src.points[k]) end
		end
	end
	if type(src.bars) == "table" and src.bars.locked ~= nil then
		char.bars = { locked = src.bars.locked }
	end
	if moved then RoA.migratedNow = true end
end

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------
RoA:On("ADDON_LOADED", function(_, name)
	if name ~= ADDON then return end
	RoadsOfAzerothDB = type(RoadsOfAzerothDB) == "table" and RoadsOfAzerothDB or {}
	RoadsOfAzerothCharDB = type(RoadsOfAzerothCharDB) == "table" and RoadsOfAzerothCharDB or {}
	migrate(RoadsOfAzerothCharDB)
	merge(RoadsOfAzerothDB, accountDefaults)
	merge(RoadsOfAzerothCharDB, charDefaults)
	RoA.db = RoadsOfAzerothDB
	RoA.char = RoadsOfAzerothCharDB
	RoA.db.schemaVersion = RoA.SCHEMA
	RoA.char.schemaVersion = RoA.SCHEMA
	RoA.Style:LoadFont(RoA.db)
	for _, m in ipairs(RoA.modules) do
		if m.OnInit then
			local ok, err = pcall(m.OnInit, m)
			if not ok and RoA.debug then RoA:Print("init " .. m.name .. ":", tostring(err)) end
		end
	end
end)

RoA:On("PLAYER_LOGIN", function()
	for _, m in ipairs(RoA.modules) do
		if m.OnEnable then
			RoA.where = "PLAYER_LOGIN " .. m.name
			local ok, err = pcall(m.OnEnable, m)
			if not ok then RoA:Print("|cffff5555" .. m.name .. ":|r " .. tostring(err)) end
		end
	end
	RoA.where = nil
	-- follow Casters of Azeroth's lock/unlock
	local c = RoA:Casters()
	if c and c.Listen then
		c:Listen("SETTINGS", function(group)
			if group == "bars" and RoA.Style then RoA.Style:UpdateMovers() end
		end)
	end
	if RoA.Style then RoA.Style:UpdateMovers() end
	if RoA.migratedNow then
		RoA:Print(RoA.L["Your quest list, route and GPS settings were moved over from CasterKit."])
	end
end)

SLASH_ROADSOFAZEROTH1 = "/roa"
SLASH_ROADSOFAZEROTH2 = "/roads"
SlashCmdList.ROADSOFAZEROTH = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")
	local L = RoA.L
	if msg == "" or msg == "config" or msg == "settings" then
		RoA:ToggleConfig()
	elseif msg == "recalc" or msg == "route" then
		if RoA.QuestPlan and RoA.QuestPlan.Recalculate then RoA.QuestPlan:Recalculate() end
	elseif msg == "clear" then
		if RoA.Nav and RoA.Nav.Clear then RoA.Nav:Clear() end
	elseif msg == "unlock" or msg == "lock" then
		RoA:SetFramesLocked(msg == "lock")
		RoA:Print(msg == "lock" and L["Frames locked."] or L["Frames unlocked: drag them where you like, drag a corner to make them bigger, type /roa lock when done."])
	elseif msg == "trails" then
		local n, c = RoA.Trails:Stats()
		RoA:Print(L["Learned paths: %d points on %d continent(s). /roa trails clear forgets them."]:format(n, c))
	elseif msg == "trails clear" then
		RoA.Trails:Clear()
		RoA:Print(L["Learned paths cleared."])
	elseif msg == "debug" then
		RoA.debug = not RoA.debug
		RoA:Print("debug " .. (RoA.debug and "on" or "off"))
	else
		RoA:Print(L["/roa: settings. /roa recalc: plan the route again. /roa clear: clear the GPS route. /roa unlock: move the frames."])
	end
end

-- Report which function Blizzard blocked (taint), so it can be fixed.
do
	local f = CreateFrame("Frame")
	f:RegisterEvent("ADDON_ACTION_BLOCKED")
	f:RegisterEvent("ADDON_ACTION_FORBIDDEN")
	f:SetScript("OnEvent", function(_, event, addon, func)
		if addon ~= ADDON then return end
		local where = tostring(RoA.where)
		C_Timer.After(3, function() RoA:Print("|cffff5555blocked:|r " .. tostring(func) .. " (" .. where .. ")") end)
	end)
end
