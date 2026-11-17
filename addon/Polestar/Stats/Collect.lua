-- Stats: what the Stats section draws, kept per character in
-- PolestarCharDB.stats as running totals. Nothing here is an event log and
-- nothing leaves the game: every figure is a sum, a short capped list or a
-- grid of cells, so the saved table stays small however long the character
-- is played. Off with stats.enabled: no events, no ticker, no writes; what
-- was saved stays until Stats.Reset().
--
--   Stats.Enabled() -> bool
--   Stats.Store() -> the saved table (made when missing)
--   Stats.Summary() -> totals over every day, for the pages (see below)
--   Stats.Heat(uiMapID) -> { t, s, k, x, q, d } cell tables | nil; Stats.HeatMaps() -> { { map, seconds }, ... }
--   Stats.Trail(uiMapID) -> the walked path's points | nil; Stats.TrailXY(point) -> x, y in percent (nil for a break)
--   Stats.Routes("f" | "r") -> { [continent uiMapID] = points } flown, ridden; Stats.Jumps() -> the jumps
--   Stats.Cell(x, y) -> cell index of a map position in percent; Stats.GRID cells a side
--   Stats.Tick(dt) -> one sampler step (the 2 s ticker calls it; tests too)
--   Stats.Reset() -> forgets everything saved for this character
--
-- The saved table:
--   v = 3, since (first write), seen (last sample), active (seconds sampled, all time), sessions
--   days["YYYYMMDD"] = { p played, c combat, f fights, m mounted, a AFK, r resting (seconds; f a count),
--     xt XP gained, xq from quests, xe from exploring (kills are the rest), k kills, d deaths, b bosses,
--     qa accepted, qt turned in, qr abandoned, il looted, iq quest money, iv sold to vendors,
--     st training, sb bought, sr repairs, sx flights (copper) }; at most MAX_DAYS, older ones summed into `old`
--   hours[0..23], weekdays[0..6]: seconds played
--   levels = { { l, t, p (active seconds then) }, ... }
--   quests = { { q, t, xp, m, dur, lv }, ... } newest last, at most MAX_QUESTS; open[questID] = accepted at
--   killers[npcID] = { n, name }; dungeons = { { name, t, s }, ... }; inst = the run in progress
--   money = { { t, copper }, ... } one every MONEY_GAP seconds while it changes, at most MAX_MONEY
--   profs[skillLine] = { first, t, rank }; ilvl
--   heat[uiMapID] = { t = { [cell] = seconds on the move }, s = seconds standing still, k = kills, x = kill XP,
--     q = quest XP, d = deaths }
--   trail[uiMapID] = { point, ... } the walked path, oldest first, at most MAX_TRAIL a zone: a point is
--     x * 10000 + y + 1 with x, y in hundredths of a percent; 0 breaks the line (a flight, a death, a jump)
--   routes = { f = { [continent uiMapID] = { point, ... } }, r = the same }: the routes flown on flight
--     paths (f) and ridden on boats, zeppelins and whatever else carries the character (r), as points on
--     the continent's map (the trail's format, at most MAX_ROUTE a continent)
--   jumps = { { map, point, map, point }, ... }: where the character left and arrived when they crossed
--     the world without travelling it (a portal, a hearthstone, the tram), at most MAX_JUMPS
--   days also count fl flights, ft seconds in flight, rd rides, rt seconds riding
--
-- Kills: Forever's combat log is closed to addons, so a kill is the client's
-- XP line (CHAT_MSG_COMBAT_XP_GAIN): kills that give no XP are not counted.
-- Money: looted is what the purse gains while a loot window is open (or a
-- second after), a merchant visit is its net (less the repair bill it paid),
-- training and flights are what the purse lost across those windows.
-- Auction house, mail and trades are not followed.
-- Rides: the client does not say when the character is aboard a boat or a
-- zeppelin, so a ride is being carried: the position keeps changing by more
-- than the character's own speed accounts for (as FlowUp's play log does).

local ADDON, ns = ...
local Compat = ns.Compat
local L = ns.L
local type, pairs, ipairs, pcall, tonumber, floor, max, min = type, pairs, ipairs, pcall, tonumber, math.floor, math.max, math.min
local abs, sqrt = math.abs, math.sqrt
local remove, sort = table.remove, table.sort
local readable = Compat.Readable

local Stats = {}
ns.Stats = Stats

local TICK = 2 -- seconds between samples
local MAX_DT = 4 -- a sample never counts more than this (a stalled client, a loading screen)
local MAX_DAYS = 370
local MAX_QUESTS = 1000
local MAX_MONEY = 600
local MAX_DUNGEONS = 100
local MAX_KILLERS = 200
local MONEY_GAP = 300 -- seconds between purse samples
local SESSION_GAP = 300 -- a login this long after the last sample is a new session
local NEAR = 1 -- seconds within which an XP gain belongs to a turn-in, a discovery or a kill line
local FOE_AGE = 10 -- seconds a foe seen in combat stays the likely killer
local GRID = 480 -- heat cells a side of a zone map (some 7 yards a cell)
local OLD_GRIDS = { 80, 240 } -- the grid of a v1 and of a v2 store
local MAX_TRAIL = 6000 -- path points kept a zone, the oldest dropped first
local TRAIL_STEP = 0.12 -- percent of the map moved before the next path point
local TRAIL_JUMP = 4 -- percent in one sample that is no walk (a hearth, a portal): the line breaks
local STILL = 0.01 -- percent of the map: a sample that moved less than this was standing still
local ZONE_TYPE = 3 -- Enum.UIMapType.Zone
local CONTINENT_TYPE = 2 -- Enum.UIMapType.Continent
local MAX_ROUTE = 6000 -- flight and ride points kept a continent, the oldest dropped first
local ROUTE_STEP = 0.03 -- percent of the continent's map moved before the next route point (some 10 yards)
local RIDE_ENTER = 2 -- samples in a row carried before a ride begins
local RIDE_LEAVE = 4 -- ... and not carried before it ends
local RIDE_MIN = 6 -- route points a ride needs to be kept: fewer was a lift or a knockback
local RIDE_SPEED = { 3, 120 } -- yards a second a ride moves at: slower is standing, faster is no ride
local MAX_JUMPS = 300
local JUMP_MIN = 300 -- yards between two places that make a jump
local JUMP_SPEED = 40 -- ... crossed faster than this (yards a second), or unseen

Stats.GRID, Stats.TICK = GRID, TICK

ns.RegisterDefaults("stats", { enabled = true, page = "activity", layer = "p" })

function Stats.Enabled() return ns.Get("stats.enabled") and true or false end

---------------------------------------------------------------------------
-- The store
---------------------------------------------------------------------------

local TABLES = { "days", "old", "hours", "weekdays", "levels", "quests", "open", "killers", "dungeons", "money", "profs", "heat", "trail", "routes", "jumps" }

function Stats.Store()
	local cs = ns.CharState()
	local s = cs.stats
	if type(s) ~= "table" then
		s = { v = 3 }
		cs.stats = s
	end
	if s.v ~= 3 then
		-- An older store kept heat on a coarser grid. Twice as coarse (v2): each cell is
		-- shared out over the four it covers; else (v1) it moves to the cell at its middle.
		local old = OLD_GRIDS[s.v] or OLD_GRIDS[1]
		if type(s.heat) == "table" then
			for _, h in pairs(s.heat) do
				if type(h) == "table" then
					for layer, cells in pairs(h) do
						local out = {}
						if type(cells) == "table" then
							for cell, n in pairs(cells) do
								local cx, cy = (cell - 1) % old, floor((cell - 1) / old)
								if old * 2 == GRID then
									for dy = 0, 1 do
										for dx = 0, 1 do
											local to = (cy * 2 + dy) * GRID + cx * 2 + dx + 1
											out[to] = (out[to] or 0) + n / 4
										end
									end
								else
									local to = Stats.Cell((cx + 0.5) / old * 100, (cy + 0.5) / old * 100)
									out[to] = (out[to] or 0) + n
								end
							end
						end
						h[layer] = out
					end
				end
			end
		end
		s.v = 3
	end
	for _, k in ipairs(TABLES) do if type(s[k]) ~= "table" then s[k] = {} end end
	if type(s.active) ~= "number" then s.active = 0 end
	if type(s.sessions) ~= "number" then s.sessions = 0 end
	return s
end

function Stats.Reset()
	ns.CharState().stats = nil
	if Stats.TrailBreak then Stats.TrailBreak() end
	if Stats.TravelBreak then Stats.TravelBreak() end
	ns.Fire("STATS_UPDATED")
end

local function dayKey(t)
	return date and date("%Y%m%d", t or Compat.Now()) or "0"
end

-- Today's row. More than MAX_DAYS of them: the oldest are summed into `old`.
local function today(s)
	local key = dayKey()
	local d = s.days[key]
	if type(d) ~= "table" then
		d = {}
		s.days[key] = d
		if not s.since then s.since = Compat.Now() end
		local keys = {}
		for k in pairs(s.days) do keys[#keys + 1] = k end
		if #keys > MAX_DAYS then
			sort(keys)
			for i = 1, #keys - MAX_DAYS do
				for f, v in pairs(s.days[keys[i]]) do
					if type(v) == "number" then s.old[f] = (s.old[f] or 0) + v end
				end
				s.days[keys[i]] = nil
			end
		end
	end
	return d
end

local function add(t, key, n)
	if n and n ~= 0 then t[key] = (t[key] or 0) + n end
end

local function clock() return GetTime and GetTime() or 0 end

local function number(v)
	v = readable(v)
	return type(v) == "number" and v or nil
end

local function flag(fn, ...)
	if type(fn) ~= "function" then return false end
	local ok, v = pcall(fn, ...)
	return ok and readable(v) and true or false
end

---------------------------------------------------------------------------
-- Where the player stands: the zone map and a cell on it
---------------------------------------------------------------------------

function Stats.Cell(x, y)
	local cx = min(GRID - 1, max(0, floor(x / 100 * GRID)))
	local cy = min(GRID - 1, max(0, floor(y / 100 * GRID)))
	return cy * GRID + cx + 1
end

-- The zone-type map at or above `map` (a cave or a town's own map files
-- under its zone), or `map` itself when none is.
local function zoneOf(map)
	local M = C_Map
	if not (M and M.GetMapInfo) then return map end
	local at = map
	for _ = 1, 8 do
		local ok, info = pcall(M.GetMapInfo, at)
		if not (ok and type(info) == "table") then break end
		if info.mapType == ZONE_TYPE then return at end
		local up = info.parentMapID
		if not up or up == 0 or up == at then break end
		at = up
	end
	return map
end

-- map, cell of the player on their zone's map; nil where the client gives
-- no position (instances).
local function place()
	local map, x, y = Compat.GetPlayerMapPosition()
	if not map then return nil end
	local zone = zoneOf(map)
	if zone ~= map and C_Map and C_Map.GetPlayerMapPosition then
		local ok, pos = pcall(C_Map.GetPlayerMapPosition, zone, "player")
		local zx, zy
		if ok and type(pos) == "table" then
			if pos.GetXY then zx, zy = pos:GetXY() else zx, zy = pos.x, pos.y end
		end
		zx, zy = number(zx), number(zy)
		if zx and zy and not (zx == 0 and zy == 0) then
			map, x, y = zone, zx * 100, zy * 100
		end
	end
	return map, Stats.Cell(x, y), x, y
end
Stats.Place = place

-- A place on a map (percent) as one number: the trail's and the routes' points.
local function pointOf(x, y)
	return min(9999, max(0, floor(x * 100))) * 10000 + min(9999, max(0, floor(y * 100))) + 1
end

-- Adds a point to a capped list, after a break when it does not join the last.
local function addPoint(list, x, y, joined, cap)
	if not joined and #list > 0 and list[#list] ~= 0 then list[#list + 1] = 0 end
	list[#list + 1] = pointOf(x, y)
	if #list > cap + 200 then
		local drop, n = #list - cap, #list
		for i = 1, n do list[i] = list[i + drop] end
	end
end

-- The walked path: a point when the player has moved far enough, a break
-- where the line must not join (off the ground, a jump, another zone).
local lastMap, lastX, lastY

local function trailBreak()
	lastMap, lastX, lastY = nil, nil, nil
end
Stats.TrailBreak = trailBreak

local function trail(s)
	local map, _, x, y = place()
	if not map then return trailBreak() end
	local joined = lastMap == map
	if joined then
		local dx, dy = x - lastX, y - lastY
		local d2 = dx * dx + dy * dy
		if d2 < TRAIL_STEP * TRAIL_STEP then return end
		if d2 > TRAIL_JUMP * TRAIL_JUMP then joined = false end
	end
	local list = s.trail[map]
	if type(list) ~= "table" then
		list = {}
		s.trail[map] = list
	end
	addPoint(list, x, y, joined, MAX_TRAIL)
	lastMap, lastX, lastY = map, x, y
end

function Stats.Trail(map)
	local list = Stats.Store().trail[map]
	return type(list) == "table" and list or nil
end

function Stats.TrailXY(point)
	if type(point) ~= "number" or point <= 0 then return nil end
	point = point - 1
	return floor(point / 10000) / 100, (point % 10000) / 100
end

---------------------------------------------------------------------------
-- Travel: flights, rides and jumps, on the continent's map
---------------------------------------------------------------------------

-- The continent the player is on, their place on its map (percent) and in
-- the world (yards; nil when the client does not convert); nil where the
-- client gives no position (an instance, a loading screen).
local function continentPlace()
	local M = C_Map
	if not (M and M.GetBestMapForUnit and M.GetMapInfo and M.GetPlayerMapPosition) then return nil end
	local ok, at = pcall(M.GetBestMapForUnit, "player")
	at = ok and number(at) or nil
	local cont
	for _ = 1, 8 do
		if not at then break end
		local ok2, info = pcall(M.GetMapInfo, at)
		if not (ok2 and type(info) == "table") then break end
		if info.mapType == CONTINENT_TYPE then
			cont = at
			break
		end
		local up = info.parentMapID
		if type(up) ~= "number" or up == 0 or up == at then break end
		at = up
	end
	if not cont then return nil end
	local ok3, pos = pcall(M.GetPlayerMapPosition, cont, "player")
	if not (ok3 and type(pos) == "table") then return nil end
	local x, y
	if pos.GetXY then x, y = pos:GetXY() else x, y = pos.x, pos.y end
	x, y = number(x), number(y)
	if not (x and y) or (x == 0 and y == 0) then return nil end
	local wx, wy
	if M.GetWorldPosFromMapPos then
		local ok4, _, world = pcall(M.GetWorldPosFromMapPos, cont, pos)
		if ok4 and type(world) == "table" then
			if world.GetXY then wx, wy = world:GetXY() else wx, wy = world.x, world.y end
			wx, wy = number(wx), number(wy)
		end
	end
	return cont, x * 100, y * 100, wx, wy
end

local function routeList(s, kind, map)
	local set = s.routes[kind]
	if type(set) ~= "table" then
		set = {}
		s.routes[kind] = set
	end
	local list = set[map]
	if type(list) ~= "table" then
		list = {}
		set[map] = list
	end
	return list
end

function Stats.Routes(kind)
	local set = Stats.Store().routes[kind]
	return type(set) == "table" and set or {}
end

function Stats.Jumps() return Stats.Store().jumps end

-- A flight path's route: a point every ROUTE_STEP of the continent's map
-- while on the taxi. -> whether the character is flying
local flight = { on = false }

local function sampleFlight(s, dt, map, x, y)
	if not Compat.IsOnTaxi() then
		flight.on, flight.map = false, nil
		return false
	end
	local d = today(s)
	if not flight.on then
		flight.on = true
		add(d, "fl", 1)
	end
	add(d, "ft", dt)
	if not map then return true end
	local joined = flight.map == map
	if joined and abs(x - flight.x) + abs(y - flight.y) < ROUTE_STEP then return true end
	addPoint(routeList(s, "f", map), x, y, joined, MAX_ROUTE)
	flight.map, flight.x, flight.y = map, x, y
	return true
end

-- A ride. Its first points wait (ride.held) until there are RIDE_MIN of them
-- or it reaches another continent: only then is it a ride, counted and kept.
local ride = { on = false, lead = 0, idle = 0, held = {}, kept = false }

local function endRide()
	ride.on, ride.lead, ride.idle, ride.kept, ride.map = false, 0, 0, false, nil
	for i = #ride.held, 1, -1 do ride.held[i] = nil end
end

local function ridePoint(s, map, x, y)
	local joined = ride.map == map
	if joined and abs(x - ride.x) + abs(y - ride.y) < ROUTE_STEP then return end
	if not ride.kept then
		local held = ride.held
		held[#held + 1] = { map, x, y }
		if #held < RIDE_MIN and held[1][1] == map then
			ride.map, ride.x, ride.y = map, x, y
			return
		end
		ride.kept = true
		add(today(s), "rd", 1)
		local before
		for i = 1, #held - 1 do
			local h = held[i]
			addPoint(routeList(s, "r", h[1]), h[2], h[3], before == h[1], MAX_ROUTE)
			before = h[1]
		end
	end
	addPoint(routeList(s, "r", map), x, y, joined, MAX_ROUTE)
	ride.map, ride.x, ride.y = map, x, y
end

-- -> whether the character is being carried (the walked path stops for it)
local function sampleRide(s, dt, map, x, y, wx, wy)
	if not map then return ride.on end -- a loading screen between continents: the ride carries on after it
	local now = clock()
	local pm, pwx, pwy, pt = ride.pm, ride.pwx, ride.pwy, ride.pt
	ride.pm, ride.pwx, ride.pwy, ride.pt = map, wx, wy, now
	if not pm then return ride.on end
	local carried = false
	if pm ~= map then
		carried = ride.on -- arriving on another continent: only a ride does that gradually
	elseif wx and pwx and GetUnitSpeed then
		local ok, own = pcall(GetUnitSpeed, "player")
		own = ok and number(own) or nil
		if own then
			local span = max(0.2, now - pt)
			local dx, dy = wx - pwx, wy - pwy
			local moved = sqrt(dx * dx + dy * dy) / span
			carried = moved > RIDE_SPEED[1] and moved > own * 1.5 + 2 and moved < RIDE_SPEED[2]
		end
	end
	if ride.on then
		if carried then ride.idle = 0 else ride.idle = ride.idle + 1 end
		if ride.idle >= RIDE_LEAVE then
			endRide()
		else
			ridePoint(s, map, x, y)
			if ride.kept then add(today(s), "rt", dt) end
		end
	elseif carried then
		ride.lead = ride.lead + 1
		if ride.lead >= RIDE_ENTER then
			ride.on, ride.idle = true, 0
			ridePoint(s, map, x, y)
		end
	else
		ride.lead = 0
	end
	return ride.on
end

local stillMap, stillX, stillY -- where the last sample was, for standing() (below)

-- A jump: the character was last seen in one place and is now in another,
-- too far to have walked there since (a portal, a hearthstone, the tram:
-- anything the client shows no journey for). `travelling`: on a flight, a
-- ride or dead, where the next place seen is no jump.
local seen = {}

local function sampleJump(s, travelling, map, x, y, wx, wy)
	if travelling then
		seen.map = nil
		return
	end
	if not map then
		if seen.map then seen.gap = true end
		return
	end
	local now = clock()
	if seen.map then
		local far, fast = true, true
		if seen.map == map and wx and seen.wx then
			local dx, dy = wx - seen.wx, wy - seen.wy
			local d = sqrt(dx * dx + dy * dy)
			far = d > JUMP_MIN
			fast = seen.gap or d / max(0.2, now - seen.t) > JUMP_SPEED
		elseif seen.map == map then
			-- No yards here: a twentieth of the continent's map is far.
			far = abs(x - seen.x) + abs(y - seen.y) > 5
			fast = seen.gap or now - seen.t <= MAX_DT * 2
		end
		if far and fast then
			local list = s.jumps
			list[#list + 1] = { seen.map, pointOf(seen.x, seen.y), map, pointOf(x, y) }
			while #list > MAX_JUMPS do remove(list, 1) end
		end
	end
	seen.map, seen.x, seen.y, seen.wx, seen.wy, seen.t, seen.gap = map, x, y, wx, wy, now, false
end

local function travelBreak()
	stillMap = nil
	flight.on, flight.map = false, nil
	endRide()
	ride.pm, seen.map = nil, nil
end

Stats.TravelBreak = travelBreak

local function heat(s, layer, n)
	if not n or n == 0 then return end
	local map, cell = place()
	if not map then return end
	local h = s.heat[map]
	if type(h) ~= "table" then
		h = {}
		s.heat[map] = h
	end
	local t = h[layer]
	if type(t) ~= "table" then
		t = {}
		h[layer] = t
	end
	t[cell] = (t[cell] or 0) + n
end

function Stats.Heat(map)
	local h = Stats.Store().heat[map]
	return type(h) == "table" and h or nil
end

-- The maps with anything on them, the longest stayed in first.
function Stats.HeatMaps()
	local out = {}
	for map, h in pairs(Stats.Store().heat) do
		local seconds = 0
		if type(h) == "table" then
			-- (on the move and standing still: all the time there)
			if type(h.t) == "table" then for _, v in pairs(h.t) do seconds = seconds + v end end
			if type(h.s) == "table" then for _, v in pairs(h.s) do seconds = seconds + v end end
		end
		out[#out + 1] = { map = map, seconds = seconds }
	end
	sort(out, function(a, b)
		if a.seconds ~= b.seconds then return a.seconds > b.seconds end
		return a.map < b.map
	end)
	return out
end

---------------------------------------------------------------------------
-- The sampler: time, where it was spent, the purse, the instance
---------------------------------------------------------------------------

local recentFoe -- { id, name, at }
local lastMoney, moneyAt
local profsDirty = true

local function money()
	return number(Compat.GetMoney and Compat.GetMoney() or (GetMoney and GetMoney()))
end

local function foe(unit)
	if not (UnitExists and UnitCanAttack) then return nil end
	if not flag(UnitExists, unit) or not flag(UnitCanAttack, "player", unit) then return nil end
	if flag(UnitIsPlayer, unit) then return nil end
	local id = Compat.GetNpcID(unit)
	if not id then return nil end
	local name = readable(UnitName and UnitName(unit))
	return { id = id, name = type(name) == "string" and name ~= "" and name or nil }
end

local function professions(s)
	profsDirty = false
	if not (Compat.Supports and Compat.Supports("skill")) then return end
	for _, line in pairs(Compat.SKILL_LINES or {}) do
		local rank = Compat.GetSkillRank(line)
		if rank and rank > 0 then
			local p = s.profs[line]
			if type(p) ~= "table" then
				p = { first = rank, t = Compat.Now() }
				s.profs[line] = p
			end
			p.rank = rank
		end
	end
end

local function itemLevel(s)
	if type(GetAverageItemLevel) ~= "function" then return end
	local ok, avg, worn = pcall(GetAverageItemLevel)
	local v = ok and (number(worn) or number(avg)) or nil
	if v and v > 0 then s.ilvl = floor(v + 0.5) end
end

local function purse(s, force)
	local m = money()
	if not m then return end
	local now = Compat.Now()
	local list = s.money
	local last = list[#list]
	if last and last[2] == m then return end
	if not force and moneyAt and now - moneyAt < MONEY_GAP then return end
	moneyAt = now
	list[#list + 1] = { now, m }
	-- Over the cap: every second sample of the older half goes, so the line keeps its whole span.
	if #list > MAX_MONEY then
		local keep = {}
		local half = floor(#list / 2)
		for i = 1, #list do
			if i > half or i % 2 == 1 then keep[#keep + 1] = list[i] end
		end
		s.money = keep
	end
end

-- The run in progress is saved (s.inst) so a /reload inside keeps it; a
-- logout inside ends it at the last sample.
local function instance(s)
	local inside = Compat.IsInInstance()
	local now = Compat.Now()
	local run = type(s.inst) == "table" and s.inst or nil
	local id = inside and Compat.GetInstanceMapID() or nil
	if run and (not inside or (id and run.id and id ~= run.id)) then
		local upTo = run.seen or now
		if not inside and now - upTo <= SESSION_GAP then upTo = now end
		local list = s.dungeons
		list[#list + 1] = { name = run.name, t = run.t, s = max(0, upTo - run.t) }
		while #list > MAX_DUNGEONS do remove(list, 1) end
		s.inst, run = nil, nil
	end
	if inside then
		if not run then
			local name = GetInstanceInfo and readable((GetInstanceInfo())) or nil
			run = { id = id, name = type(name) == "string" and name or nil, t = now }
			s.inst = run
		end
		run.seen = now
	end
end

-- Whether the player is where the last sample left them (the first sample
-- of a stay counts as moving: they came here).
local function standing()
	local map, _, x, y = place()
	local still = map ~= nil and map == stillMap and abs(x - stillX) + abs(y - stillY) < STILL
	stillMap, stillX, stillY = map, x, y
	return still
end

local lastTick

function Stats.Tick(dt)
	if not Stats.Enabled() then return end
	local s = Stats.Store()
	local now = GetTime and GetTime() or 0
	if not dt then
		dt = lastTick and min(now - lastTick, MAX_DT) or 0
		lastTick = now
	end
	instance(s)
	if profsDirty then professions(s) end
	purse(s)
	if dt <= 0 then return end
	local d = today(s)
	local at = Compat.Now()
	s.seen = at
	s.active = s.active + dt
	add(d, "p", dt)
	local h = tonumber(date and date("%H", at)) or 0
	local w = tonumber(date and date("%w", at)) or 0
	s.hours[h] = (s.hours[h] or 0) + dt
	s.weekdays[w] = (s.weekdays[w] or 0) + dt
	local combat = Compat.InCombat()
	if combat then
		add(d, "c", dt)
		local f = foe("target")
		if f then
			f.at = now
			recentFoe = f
		end
	end
	if flag(IsMounted) then add(d, "m", dt) end
	if flag(UnitIsAFK, "player") then add(d, "a", dt) end
	if flag(IsResting) then add(d, "r", dt) end
	local cont, cx, cy, wx, wy = continentPlace()
	local flying = sampleFlight(s, dt, cont, cx, cy)
	local dead = flag(UnitIsDeadOrGhost, "player")
	local riding = false
	if flying or dead then
		endRide()
		ride.pm = nil
	else
		riding = sampleRide(s, dt, cont, cx, cy, wx, wy)
	end
	sampleJump(s, flying or dead or riding, cont, cx, cy, wx, wy)
	if not flying and not dead then
		-- Time spent somewhere is time on the move there; standing still is kept apart.
		heat(s, standing() and "s" or "t", dt)
		if riding then trailBreak() else trail(s) end
	else
		trailBreak()
	end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local xpLevel, xpCur, xpMax
local turnInAt, exploreAt, killAt = -100, -100, -100
local pendingGain -- { n, at }: an XP gain no source has claimed yet
local lootOpen, lootUntil = false, 0
local vendor, trainerMoney, taxiMoney
local turned = {} -- questID -> true: handed in this session (its QUEST_REMOVED is not an abandon)


local function readXP()
	local lvl = number(UnitLevel and UnitLevel("player"))
	local xp = number(UnitXP and UnitXP("player"))
	local mx = number(UnitXPMax and UnitXPMax("player"))
	if not (lvl and xp and mx) then return nil end
	local gain
	if xpLevel and xpCur and xpMax then
		if lvl > xpLevel then gain = (xpMax - xpCur) + xp
		elseif lvl == xpLevel then gain = xp - xpCur end
	end
	xpLevel, xpCur, xpMax = lvl, xp, mx
	return gain and gain > 0 and gain or nil
end

local function onXP()
	local gain = readXP()
	if not gain then return end
	local s = Stats.Store()
	add(today(s), "xt", gain)
	local now = clock()
	if now - turnInAt <= NEAR or now - exploreAt <= NEAR then return end
	if now - killAt <= NEAR then
		killAt = -100
		heat(s, "x", gain)
	else
		pendingGain = { n = gain, at = now }
	end
end

local function onKillLine()
	local s = Stats.Store()
	add(today(s), "k", 1)
	heat(s, "k", 1)
	local now = clock()
	if pendingGain and now - pendingGain.at <= NEAR then
		heat(s, "x", pendingGain.n)
		pendingGain = nil
	else
		killAt = now
	end
end

-- The client's "Discovered %s: %d experience gained" line, as a pattern.
local explorePattern
local function exploreXP(msg)
	msg = readable(msg)
	if type(msg) ~= "string" then return nil end
	if explorePattern == nil then
		explorePattern = false
		local fmt = readable(ERR_ZONE_EXPLORED_XP)
		if type(fmt) == "string" then
			local p = fmt:gsub("%%[%d%$]*s", "\1"):gsub("%%[%d%$]*d", "\2")
			p = p:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"):gsub("\1", ".-"):gsub("\2", "(%%d+)")
			explorePattern = "^" .. p .. "$"
		end
	end
	return explorePattern and tonumber(msg:match(explorePattern)) or nil
end

local function onSystem(_, a, b)
	local n = exploreXP(a) or exploreXP(b)
	if not n then return end
	local now = clock()
	if now - exploreAt < 2 then return end -- the same line comes as a system message and as an info message
	exploreAt = now
	add(today(Stats.Store()), "xe", n)
	if pendingGain and now - pendingGain.at <= NEAR then pendingGain = nil end
end

-- QUEST_ACCEPTED carries the quest id last (the older client: log index, id).
local function onAccept(_, a, b)
	local q = number(b) or number(a)
	if not q then return end
	local s = Stats.Store()
	add(today(s), "qa", 1)
	s.open[q] = Compat.Now()
end

local function onTurnIn(_, q, xp, copper)
	q, xp, copper = number(q), number(xp) or 0, number(copper) or 0
	if not q then return end
	local s = Stats.Store()
	local d = today(s)
	local now = Compat.Now()
	turned[q] = true
	turnInAt = clock()
	if pendingGain and turnInAt - pendingGain.at <= NEAR then pendingGain = nil end
	add(d, "qt", 1)
	add(d, "xq", xp)
	if copper > 0 then add(d, "iq", copper) end
	heat(s, "q", xp)
	local accepted = s.open[q]
	s.open[q] = nil
	local list = s.quests
	list[#list + 1] = { q = q, t = now, xp = xp, m = copper ~= 0 and copper or nil,
		dur = accepted and max(0, now - accepted) or nil, lv = number(UnitLevel and UnitLevel("player")) }
	while #list > MAX_QUESTS do remove(list, 1) end
end

local function onRemoved(_, q)
	q = number(q)
	if not q then return end
	if turned[q] then
		turned[q] = nil
		return
	end
	local s = Stats.Store()
	if s.open[q] then
		s.open[q] = nil
		add(today(s), "qr", 1)
	end
end

local function onLevel(_, level)
	level = number(level)
	if not level then return end
	local s = Stats.Store()
	local list = s.levels
	local last = list[#list]
	if last and last.l == level then return end
	list[#list + 1] = { l = level, t = Compat.Now(), p = floor(s.active + 0.5) }
	purse(s, true)
end

local function onDead()
	local s = Stats.Store()
	add(today(s), "d", 1)
	heat(s, "d", 1)
	local f = foe("target")
	if not f and recentFoe and clock() - recentFoe.at <= FOE_AGE then f = recentFoe end
	local key = f and f.id or 0
	local k = s.killers[key]
	if type(k) ~= "table" then
		local n = 0
		for _ in pairs(s.killers) do n = n + 1 end
		if n >= MAX_KILLERS then key = 0 end
		k = s.killers[key]
		if type(k) ~= "table" then
			k = { n = 0 }
			s.killers[key] = k
		end
	end
	k.n = k.n + 1
	if f and f.name and key ~= 0 then k.name = f.name end
end

local function onCombat() add(today(Stats.Store()), "f", 1) end

local function onEncounterEnd(_, _, _, _, _, success)
	success = readable(success)
	if success == 1 or success == true then add(today(Stats.Store()), "b", 1) end
end

local function repairCost()
	if type(GetRepairAllCost) ~= "function" then return nil end
	local ok, c = pcall(GetRepairAllCost)
	return ok and number(c) or nil
end

local function onMoney()
	local m = money()
	if m and lastMoney and m > lastMoney and (lootOpen or clock() <= lootUntil) then
		add(today(Stats.Store()), "il", m - lastMoney)
	end
	lastMoney = m or lastMoney
	if vendor then
		local c = repairCost()
		if c and vendor.low and c < vendor.low then vendor.low = c end
	end
end

local function onLoot() lootOpen = true end
local function onLootClosed() lootOpen, lootUntil = false, clock() + 1 end

local function onMerchant()
	local c = repairCost()
	vendor = { m = money(), bill = c, low = c }
end

local function onMerchantClosed()
	if not vendor then return end
	local v = vendor
	vendor = nil
	local d = today(Stats.Store())
	local c = repairCost()
	if c and v.low and c < v.low then v.low = c end
	local repaired = (v.bill and v.low) and v.bill - v.low or 0
	if repaired > 0 then add(d, "sr", repaired) end
	local now = money()
	if now and v.m then
		local net = now - v.m + repaired
		if net > 0 then add(d, "iv", net) elseif net < 0 then add(d, "sb", -net) end
	end
end

local function onTrainer() trainerMoney = money() end

local function onTrainerClosed()
	local now = money()
	if trainerMoney and now and trainerMoney > now then add(today(Stats.Store()), "st", trainerMoney - now) end
	trainerMoney = nil
end

local function onTaxiMap() taxiMoney = money() end

-- Control goes as the flight starts; the fare has left the purse a moment later.
local function onControlLost()
	if not taxiMoney then return end
	ns.After(0.6, function()
		if not taxiMoney then return end
		if Compat.IsOnTaxi() then
			local now = money()
			if now and taxiMoney > now then add(today(Stats.Store()), "sx", taxiMoney - now) end
		end
		taxiMoney = nil
	end)
end

local function onSkills() profsDirty = true end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

local FIELDS = { "p", "c", "f", "m", "a", "r", "xt", "xq", "xe", "k", "d", "b", "qa", "qt", "qr", "il", "iq", "iv", "st", "sb", "sr", "sx", "fl", "ft", "rd", "rt" }

-- Totals over every day (and the days summed away), with the lists the pages
-- draw. Reads only; never makes today's row.
function Stats.Summary()
	local s = Stats.Store()
	local t = {}
	for _, f in ipairs(FIELDS) do t[f] = tonumber(s.old[f]) or 0 end
	local nDays = 0
	for _, d in pairs(s.days) do
		if type(d) == "table" then
			nDays = nDays + 1
			for _, f in ipairs(FIELDS) do t[f] = t[f] + (tonumber(d[f]) or 0) end
		end
	end
	local questSeconds, timed = 0, 0
	for _, q in ipairs(s.quests) do
		if q.dur then questSeconds, timed = questSeconds + q.dur, timed + 1 end
	end
	return {
		played = t.p, combat = t.c, fights = t.f, mounted = t.m, afk = t.a, resting = t.r,
		xp = { total = t.xt, quests = t.xq, explore = t.xe, kills = max(0, t.xt - t.xq - t.xe) },
		kills = t.k, deaths = t.d, bosses = t.b,
		accepted = t.qa, turned = t.qt, abandoned = t.qr,
		income = { loot = t.il, quests = t.iq, vendor = t.iv },
		spent = { trainer = t.st, buy = t.sb, repair = t.sr, taxi = t.sx },
		flights = t.fl, flightSeconds = t.ft, rides = t.rd, rideSeconds = t.rt,
		days = nDays, sessions = s.sessions, since = s.since,
		questSeconds = questSeconds, timedQuests = timed,
		hours = s.hours, weekdays = s.weekdays,
		levels = s.levels, quests = s.quests, killers = s.killers, dungeons = s.dungeons,
		money = s.money, profs = s.profs, ilvl = s.ilvl,
	}
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local EVENTS = {
	PLAYER_XP_UPDATE = onXP, CHAT_MSG_COMBAT_XP_GAIN = onKillLine,
	CHAT_MSG_SYSTEM = onSystem, UI_INFO_MESSAGE = onSystem,
	QUEST_ACCEPTED = onAccept, QUEST_TURNED_IN = onTurnIn, QUEST_REMOVED = onRemoved,
	PLAYER_LEVEL_UP = onLevel, PLAYER_DEAD = onDead, PLAYER_REGEN_DISABLED = onCombat,
	ENCOUNTER_END = onEncounterEnd,
	PLAYER_MONEY = onMoney, LOOT_READY = onLoot, LOOT_OPENED = onLoot, LOOT_CLOSED = onLootClosed,
	MERCHANT_SHOW = onMerchant, MERCHANT_CLOSED = onMerchantClosed,
	TRAINER_SHOW = onTrainer, TRAINER_CLOSED = onTrainerClosed,
	TAXIMAP_OPENED = onTaxiMap, PLAYER_CONTROL_LOST = onControlLost,
	SKILL_LINES_CHANGED = onSkills,
}

local started, ticker = false, nil

local function start()
	if started then return end
	started = true
	local s = Stats.Store()
	local now = Compat.Now()
	if not s.seen or now - s.seen > SESSION_GAP then s.sessions = s.sessions + 1 end
	s.seen = now
	if not s.since then s.since = now end
	readXP()
	lastMoney = money()
	lastTick = clock()
	profsDirty = true
	itemLevel(s)
	purse(s, true)
	for ev, fn in pairs(EVENTS) do ns.RegisterEvent(ev, fn) end
	ticker = ns.NewTicker(TICK, function()
		Stats.Tick()
		if started and floor(clock()) % MONEY_GAP < TICK then itemLevel(Stats.Store()) end
	end)
end

local function stop()
	if not started then return end
	started = false
	for ev, fn in pairs(EVENTS) do ns.UnregisterEvent(ev, fn) end
	if ticker and ticker.Cancel then ticker:Cancel() end
	ticker = nil
	trailBreak()
	travelBreak()
	xpLevel, xpCur, xpMax, vendor, trainerMoney, taxiMoney, pendingGain = nil, nil, nil, nil, nil, nil, nil
end

local loggedIn = false
ns.OnLogin(function()
	loggedIn = true
	if Stats.Enabled() then start() end
end)

ns.On("SETTING_CHANGED", function(path)
	if not loggedIn or type(path) ~= "string" or not (path == "stats.enabled" or path == "stats" or path == "") then return end
	if Stats.Enabled() then start() else stop() end
end)

ns.RegisterCommand("stats", function() ns.Fire("SHOW_STATS") end, L["Show your stats"])
