-- The Stats section of the hub: what this character has done, from the
-- totals Collect.lua keeps. The sidebar lists the pages (Activity,
-- Character, Time, Gold, Professions) and, under a rule, the zones played
-- in, the longest stayed in first: picking a zone shows its heat map on the
-- zone's own map art (UI/ZoneArt.lua: the client's textures, none shipped),
-- with a tab per layer: the walked path as thin lines, then heat cells for
-- time spent, kills, XP from kills, XP from quests and deaths. The mouse
-- wheel over the map zooms in on the cursor (to MAX_ZOOM), dragging moves
-- it, a right-click shows the whole zone again.
--
--   SV.Zoom(steps[, px, py]), SV.Pan(dx, dy), SV.ResetView(): the same, in
--   frame pixels (the scripts on the map call them; tests too).
--
-- Registered with UI.RegisterSection; opened by SHOW_STATS
-- (/polestar stats, the minimap menu).

local ADDON, ns = ...
local UI, Theme, W = ns.UI, ns.Theme, ns.Widgets
local Stats = ns.Stats
local Compat = ns.Compat
local L = ns.L
local max, min, floor, sqrt, ipairs, pairs, format, tostring, tonumber = math.max, math.min, math.floor, math.sqrt, ipairs, pairs, string.format, tostring, tonumber
local sort = table.sort

if not (UI and W and W.SHELL and Stats and Stats.Charts) then return end

local C = Stats.Charts
local SH = W.SHELL
local DOT = "  \194\183  "
local MAX_ZONES = 30 -- zones listed in the sidebar
local MAX_CELLS = 4000 -- heat cells drawn in the frame, the strongest first
local MAX_LINES = 4000 -- path segments drawn in the frame, the newest first
local MAX_ZOOM = 12 -- how far in the map goes (1 = the whole zone)
local ZOOM_STEP = 1.25 -- one wheel click
local MAP_RATIO = 2 / 3 -- a zone map's height over its width

local SV = {}
UI.StatsSection = SV

local root, shellRef, scroll, pool, mapArt, mapPool
local shown = {}

local PAGES = {
	{ key = "activity", label = L["Activity"] },
	{ key = "character", label = L["Character"] },
	{ key = "time", label = L["Time"] },
	{ key = "gold", label = L["Gold"] },
	{ key = "professions", label = L["Professions"] },
}

local LAYERS = {
	{ key = "p", label = L["Path"], unit = L["%s path points"] },
	{ key = "t", label = L["Time spent"], unit = L["%s here"] },
	{ key = "k", label = L["Kills"], unit = L["%s kills"] },
	{ key = "x", label = L["XP from kills"], unit = L["%s XP"] },
	{ key = "q", label = L["XP from quests"], unit = L["%s XP"] },
	{ key = "d", label = L["Deaths"], unit = L["%s deaths"], color = "danger" },
}

local DAY_NAMES = { [0] = L["Sun"], L["Mon"], L["Tue"], L["Wed"], L["Thu"], L["Fri"], L["Sat"] }

local PROF_NAMES = {
	[171] = L["Alchemy"], [164] = L["Blacksmithing"], [333] = L["Enchanting"], [202] = L["Engineering"],
	[182] = L["Herbalism"], [165] = L["Leatherworking"], [186] = L["Mining"], [393] = L["Skinning"],
	[197] = L["Tailoring"], [185] = L["Cooking"], [356] = L["Fishing"], [129] = L["First Aid"],
}

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

local function num(n)
	local s = tostring(floor((n or 0) + 0.5))
	while true do
		local k
		s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
		if k == 0 then return s end
	end
end

local function elapsed(seconds)
	local m = floor((seconds or 0) / 60)
	if m >= 60 then return format(L["%d h %d min"], floor(m / 60), m % 60) end
	return format(L["%d min"], m)
end

local function day(t) return t and date and date("%b %d", t) or "" end

local function share(n, whole)
	if not whole or whole <= 0 then return "" end
	return DOT .. floor(n / whole * 100 + 0.5) .. "%"
end

local function questName(q)
	local name = Compat.GetQuestTitle and Compat.GetQuestTitle(q)
	if type(name) == "string" and name ~= "" then return name end
	return format(L["Quest %d"], q)
end

local function pageWidth()
	local full = shellRef and (shellRef:GetWidth() - (shellRef.psRail or 0) - (shellRef.psSidebar or SH.sidebar) - 2) or 0
	if full <= 0 then full = 654 end
	return full - SH.pad * 2
end

---------------------------------------------------------------------------
-- Pages: each draws into the pool and returns the y its content ends at
---------------------------------------------------------------------------

local pages = {}

function pages.activity(p, w, a)
	local y = C.Cards(p, 0, w, {
		{ L["Quests accepted"], num(a.accepted) }, { L["Quests turned in"], num(a.turned) }, { L["Abandoned"], num(a.abandoned) },
	})
	y = C.Cards(p, y, w, {
		{ L["Monsters killed"], num(a.kills) }, { L["Fights"], num(a.fights) },
		{ L["Average quest"], a.timedQuests > 0 and elapsed(a.questSeconds / a.timedQuests) or "\226\128\148" },
		{ L["Time played"], elapsed(a.played) },
	})
	y = C.Heading(p, y + 8, L["Experience by source"])
	local xp = a.xp
	local total = xp.quests + xp.kills + xp.explore
	local function line(n) return format(L["%s XP"], num(n)) .. share(n, total) end
	y = C.Bars(p, y, w, {
		{ L["Quests"], xp.quests, line(xp.quests) },
		{ L["Monsters"], xp.kills, line(xp.kills) },
		{ L["Exploration"], xp.explore, line(xp.explore) },
	})
	y = C.Heading(p, y + 8, L["Play time by hour"])
	y = C.Columns(p, y, w, 84, 0, 23, a.hours, function(h) return tostring(h) end)
	y = C.Heading(p, y + 8, L["Best paying quests"])
	local list = {}
	for _, q in ipairs(a.quests) do if (q.xp or 0) > 0 then list[#list + 1] = q end end
	sort(list, function(x, z)
		if x.xp ~= z.xp then return x.xp > z.xp end
		return x.q < z.q
	end)
	if #list == 0 then y = C.Note(p, y, w, L["No quests turned in yet."]) end
	for i = 1, min(10, #list) do
		local q = list[i]
		y = C.Table(p, y, {
			{ questName(q.q), 0, w - 260 },
			{ format(L["%s XP"], num(q.xp)), w - 250, 110 },
			{ q.lv and format(L["at level %d"], q.lv) or "", w - 130, 130, "textDim" },
		})
	end
	shown.best = #list
	return y
end

function pages.character(p, w, a)
	local info = Compat.GetPlayerInfo and Compat.GetPlayerInfo() or {}
	local class = UI.ClassName and UI.ClassName(info.class) or tostring(info.class or "")
	local race = UI.RaceName and UI.RaceName(info.race) or tostring(info.race or "")
	local level = Compat.Readable(UnitLevel and UnitLevel("player")) or 0
	local y = C.Cards(p, 0, w, {
		{ L["Character"], race .. DOT .. class }, { L["Level"], num(level) },
		{ L["Item level"], a.ilvl and num(a.ilvl) or "\226\128\148" },
	})
	y = C.Cards(p, y, w, {
		{ L["Deaths"], num(a.deaths) }, { L["Bosses defeated"], num(a.bosses) }, { L["Dungeon runs"], num(#a.dungeons) },
	})
	y = C.Heading(p, y + 8, L["Levels gained"])
	local levels = a.levels
	if #levels == 0 then y = C.Note(p, y, w, L["No level-ups counted yet."]) end
	for i = max(1, #levels - 11), #levels do
		local lv, before = levels[i], levels[i - 1]
		local took = ""
		if before and before.l == lv.l - 1 and lv.p and before.p then
			took = format(L["%s on level %d"], elapsed(lv.p - before.p), before.l)
		end
		y = C.Table(p, y, {
			{ format(L["Level %d"], lv.l), 0, 100 }, { day(lv.t), 110, 90, "textDim" },
			{ lv.p and format(L["%s played"], elapsed(lv.p)) or "", 210, 170, "textDim" }, { took, 390, w - 390 },
		})
	end
	y = C.Heading(p, y + 14, L["Deaths"])
	local killers = {}
	for id, k in pairs(a.killers) do
		local name = k.name or (id == 0 and L["Unknown"] or format(L["Creature %d"], id))
		killers[#killers + 1] = { name, k.n or 0, k.n == 1 and L["1 death"] or format(L["%d deaths"], k.n or 0) }
	end
	sort(killers, function(x, z)
		if x[2] ~= z[2] then return x[2] > z[2] end
		return x[1] < z[1]
	end)
	while #killers > 8 do killers[#killers] = nil end
	if #killers == 0 then y = C.Note(p, y, w, L["No deaths counted."]) else y = C.Bars(p, y, w, killers, "danger") end
	y = C.Heading(p, y + 8, L["Dungeon runs"])
	local runs = a.dungeons
	if #runs == 0 then y = C.Note(p, y, w, L["No dungeon runs counted."]) end
	for i = max(1, #runs - 7), #runs do
		local run = runs[i]
		y = C.Table(p, y, {
			{ run.name or L["Unknown"], 0, 300 }, { day(run.t), 310, 90, "textDim" }, { run.s and elapsed(run.s) or "", 410, 160 },
		})
	end
	shown.levels, shown.killers = #levels, #killers
	return y
end

function pages.time(p, w, a)
	local y = C.Note(p, 0, w, L["Counted while you play, a few seconds at a time; time logged out is never counted."])
	y = C.Cards(p, y, w, {
		{ L["Time played"], elapsed(a.played) },
		{ L["Time on quests"], a.timedQuests > 0 and elapsed(a.questSeconds) or "\226\128\148" },
		{ L["Sessions"], num(a.sessions) }, { L["Days played"], num(a.days) },
	})
	y = C.Heading(p, y + 8, L["How it was spent"])
	local function part(s) return elapsed(s) .. share(s, a.played) end
	y = C.Bars(p, y, w, {
		{ L["In combat"], a.combat, part(a.combat) },
		{ L["Mounted"], a.mounted, part(a.mounted) },
		{ L["Resting in a town or inn"], a.resting, part(a.resting) },
		{ L["Away from keyboard"], a.afk, part(a.afk) },
	}, nil, max(a.played, 1))
	y = C.Heading(p, y + 8, L["Play time by hour"])
	y = C.Columns(p, y, w, 90, 0, 23, a.hours, function(h) return tostring(h) end)
	y = C.Heading(p, y + 8, L["Play time by day"])
	y = C.Columns(p, y, w, 60, 0, 6, a.weekdays, function(d) return DAY_NAMES[d] end)
	return y
end

function pages.gold(p, w, a)
	local now = Compat.GetMoney and Compat.GetMoney() or 0
	now = tonumber(now) or 0
	local series = a.money
	local first, peak = series[1] and series[1][2], now
	for _, pt in ipairs(series) do peak = max(peak, pt[2]) end
	local change = first and now - first
	local income = a.income.loot + a.income.quests + a.income.vendor
	local y = C.Cards(p, 0, w, {
		{ L["Gold now"], ns.MoneyText(now) },
		{ L["Change since counting began"], change and ((change < 0 and "-" or "+") .. ns.MoneyText(math.abs(change))) or "\226\128\148" },
		{ L["Most held"], ns.MoneyText(peak) },
		{ L["Earned per hour"], a.played > 0 and ns.MoneyText(floor(income / (a.played / 3600))) or "\226\128\148" },
	})
	y = C.Heading(p, y + 8, L["Gold over time"])
	y = C.Line(p, y, w, 130, series, ns.MoneyText, L["Not enough samples yet. One is kept every five minutes while your gold changes."])
	if #series >= 2 then
		C.Text(p, "caption", "textMuted", day(series[1][1]), 0, y - 8)
		local last = C.Text(p, "caption", "textMuted", day(series[#series][1]), w - 80, y - 8, 80)
		last:SetJustifyH("RIGHT")
		y = y + 12
	end
	y = C.Heading(p, y + 8, L["Where it came from"])
	y = C.Bars(p, y, w, {
		{ L["Looted"], a.income.loot, ns.MoneyText(a.income.loot) },
		{ L["Sold to vendors"], a.income.vendor, ns.MoneyText(a.income.vendor) },
		{ L["Quest rewards"], a.income.quests, ns.MoneyText(a.income.quests) },
	})
	y = C.Heading(p, y + 8, L["Where it went"])
	y = C.Bars(p, y, w, {
		{ L["Training"], a.spent.trainer, ns.MoneyText(a.spent.trainer) },
		{ L["Bought from vendors"], a.spent.buy, ns.MoneyText(a.spent.buy) },
		{ L["Repairs"], a.spent.repair, ns.MoneyText(a.spent.repair) },
		{ L["Flights"], a.spent.taxi, ns.MoneyText(a.spent.taxi) },
	}, "warning")
	y = C.Note(p, y, w, L["Auction house, mail and trades are not followed, so the two lists will not add up to the change exactly."])
	shown.money = #series
	return y
end

function pages.professions(p, w, a)
	local rows = {}
	for line, pr in pairs(a.profs) do
		local live = Compat.GetSkillRank and Compat.GetSkillRank(line)
		local name = Compat.GetSkillLineName and Compat.GetSkillLineName(line) or PROF_NAMES[line] or tostring(line)
		rows[#rows + 1] = { name = name, rank = live or pr.rank or 0, first = pr.first, t = pr.t }
	end
	sort(rows, function(x, z)
		if x.rank ~= z.rank then return x.rank > z.rank end
		return x.name < z.name
	end)
	local y = 0
	if #rows == 0 then y = C.Note(p, y, w, L["No profession skills counted for this character yet."]) end
	local barW = max(40, w - 170 - 60 - 220 - 36)
	for _, r in ipairs(rows) do
		-- No cap is read: the bar runs to the classic 300, further when the rank is.
		local cap = max(300, r.rank)
		C.Text(p, "body", "text", r.name, 0, y, 170)
		C.Meter(p, 182, y + 3, barW, 10, r.rank / cap)
		C.Text(p, "number", "text", tostring(r.rank), 194 + barW, y, 60)
		local gained = r.first and r.rank - r.first or 0
		if gained > 0 then C.Text(p, "small", "accent", format(L["+%d since %s"], gained, day(r.t)), 260 + barW, y + 1, 220) end
		y = y + 28
	end
	shown.profs = #rows
	return y
end

---------------------------------------------------------------------------
-- The zone heat map
---------------------------------------------------------------------------

local function layerOf(key)
	for _, l in ipairs(LAYERS) do if l.key == key then return l end end
	return LAYERS[1]
end

local function hideMap()
	if mapArt then mapArt:Hide() end
end

-- The view of the map in sight: how far in, and the map percent at the
-- middle of the frame. A new zone starts at the whole map.
local view = { zoom = 1, fx = 50, fy = 50 }
local drawn -- what the map shows: { map, layer, list (heat cells, strongest first), points (path) }

local function clampView()
	view.zoom = max(1, min(MAX_ZOOM, view.zoom))
	local half = 50 / view.zoom -- the frame shows 100 / zoom percent of the map
	view.fx = max(half, min(100 - half, view.fx))
	view.fy = max(half, min(100 - half, view.fy))
end

-- Lays the art and the layer's marks out for the view. Only this runs while
-- the map is zoomed or dragged: the page around it stays as it is.
local function paintMap()
	if not (mapArt and drawn) then return end
	local mw, mh = mapArt.psW, mapArt.psH
	clampView()
	mapArt.psZoom = view.zoom
	local painted = UI.ZoneArt and UI.ZoneArt.Paint and UI.ZoneArt.Paint(mapArt, drawn.map, view.fx, view.fy, 1) or false
	local cv = mapArt.psCanvas
	if not cv then
		-- No art here: the same framing, worked out for a plain panel.
		local cw, ch = mw * view.zoom, mh * view.zoom
		cv = { mw / 2 - view.fx / 100 * cw, mh / 2 - view.fy / 100 * ch, cw, ch }
	end
	drawn.canvas = cv
	C.Reset(mapPool)
	local layer = drawn.layer
	local color = layer.color or "accent"
	local n = 0
	if layer.key == "p" then
		local pts = drawn.points
		local thick = min(2.5, 1 + (view.zoom - 1) * 0.15)
		local px, py
		-- Newest first, so a long history gives way to the latest walks.
		for i = #pts, 1, -1 do
			local tx, ty = Stats.TrailXY(pts[i])
			if not tx then
				px, py = nil, nil
			else
				local x, y = cv[1] + tx / 100 * cv[3], cv[2] + ty / 100 * cv[4]
				if px and n < MAX_LINES and not ((x < 0 and px < 0) or (x > mw and px > mw) or (y < 0 and py < 0) or (y > mh and py > mh)) then
					n = n + 1
					C.Segment(mapPool, px, py, x, y, color, thick, 0.9)
				end
				px, py = x, y
			end
		end
	else
		local G = Stats.GRID
		local cw, ch = cv[3] / G, cv[4] / G
		local list = drawn.list
		local peak = list[1] and list[1][2] or 1
		for i = 1, #list do
			if n >= MAX_CELLS then break end
			local cell, v = list[i][1] - 1, list[i][2]
			local x, y = cv[1] + (cell % G) * cw, cv[2] + floor(cell / G) * ch
			if x < mw and y < mh and x + cw > 0 and y + ch > 0 then
				n = n + 1
				-- The square root lifts the faint cells: one busy spot would hide the rest.
				C.Rect(mapPool, "ARTWORK", x, y, cw + 0.5, ch + 0.5, color, 0.25 + 0.7 * sqrt(v / peak))
			end
		end
	end
	shown.cells, shown.painted, shown.zoom = n, painted and true or false, view.zoom
	shown.focus = { view.fx, view.fy }
	return painted
end

-- Zooms by `steps` wheel clicks, keeping the map point under (px, py) (frame
-- pixels from the top left; the middle when left out) where it is.
function SV.Zoom(steps, px, py)
	if not (mapArt and drawn and drawn.canvas) then return end
	local mw, mh, cv = mapArt.psW, mapArt.psH, drawn.canvas
	px, py = px or mw / 2, py or mh / 2
	local u, v = (px - cv[1]) / cv[3], (py - cv[2]) / cv[4]
	local was = view.zoom
	view.zoom = max(1, min(MAX_ZOOM, was * ZOOM_STEP ^ steps))
	local k = view.zoom / was
	view.fx = ((mw / 2 - px) / (cv[3] * k) + u) * 100
	view.fy = ((mh / 2 - py) / (cv[4] * k) + v) * 100
	paintMap()
end

-- Moves the view by (dx, dy) frame pixels: the map follows the hand.
function SV.Pan(dx, dy)
	if not (mapArt and drawn and drawn.canvas) then return end
	local cv = drawn.canvas
	view.fx = view.fx - dx / cv[3] * 100
	view.fy = view.fy - dy / cv[4] * 100
	paintMap()
end

function SV.ResetView()
	view.zoom, view.fx, view.fy = 1, 50, 50
	paintMap()
end

-- The cursor in frame pixels from the art's top left.
local function cursorIn(f)
	if not (GetCursorPosition and f.GetLeft and f.GetTop) then return nil end
	local x, y = GetCursorPosition()
	local scale = f.GetEffectiveScale and f:GetEffectiveScale() or 1
	local left, top = f:GetLeft(), f:GetTop()
	if not (x and y and left and top and scale and scale > 0) then return nil end
	return x / scale - left, top - y / scale
end

local function wireMap(f)
	if f.EnableMouse then f:EnableMouse(true) end
	if f.EnableMouseWheel then f:EnableMouseWheel(true) end
	f:SetScript("OnMouseWheel", function(self, delta)
		local px, py = cursorIn(self)
		SV.Zoom(delta, px, py)
	end)
	f:SetScript("OnMouseDown", function(self, button)
		if button == "RightButton" then return SV.ResetView() end
		self.psDragX, self.psDragY = cursorIn(self)
	end)
	f:SetScript("OnMouseUp", function(self) self.psDragX, self.psDragY = nil, nil end)
	f:SetScript("OnHide", function(self) self.psDragX, self.psDragY = nil, nil end)
	f:SetScript("OnUpdate", function(self)
		if not self.psDragX then return end
		if IsMouseButtonDown and not IsMouseButtonDown("LeftButton") then
			self.psDragX, self.psDragY = nil, nil
			return
		end
		local x, y = cursorIn(self)
		if not x or (x == self.psDragX and y == self.psDragY) then return end
		SV.Pan(x - self.psDragX, y - self.psDragY)
		self.psDragX, self.psDragY = x, y
	end)
end

local function drawMap(map, w)
	local layer = layerOf(ns.Get("stats.layer"))
	local list, points, total = {}, {}, 0
	if layer.key == "p" then
		points = Stats.Trail(map) or points
		for _, pt in ipairs(points) do if pt ~= 0 then total = total + 1 end end
	else
		local h = Stats.Heat(map) or {}
		for cell, v in pairs(h[layer.key] or {}) do
			list[#list + 1] = { cell, v }
			total = total + v
		end
		sort(list, function(x, z)
			if x[2] ~= z[2] then return x[2] > z[2] end
			return x[1] < z[1]
		end)
	end
	local amount = layer.key == "t" and elapsed(total) or num(total)
	local y = C.Note(pool, 0, w, format(layer.unit, amount) .. DOT .. L["Scroll to zoom, drag to move, right-click for the whole map"])

	local mw, mh = w, floor(w * MAP_RATIO)
	if not mapArt or mapArt.psW ~= mw then
		if mapArt then mapArt:Hide() end
		mapArt = UI.ZoneArt and UI.ZoneArt.Create(scroll.Child, mw, mh, "panel") or CreateFrame("Frame", nil, scroll.Child)
		mapArt:SetSize(mw, mh)
		mapArt.psW, mapArt.psH = mw, mh
		-- The map as it is: no fades, the view's point in the middle.
		mapArt.psFocusY, mapArt.psDesat = mh / 2, 0.6
		if mapArt.Fade then mapArt.Fade:Hide() end
		if mapArt.Top then mapArt.Top:Hide() end
		mapPool = C.Pool(mapArt.Over or mapArt)
		wireMap(mapArt)
	end
	mapArt:ClearAllPoints()
	mapArt:SetPoint("TOPLEFT", scroll.Child, "TOPLEFT", SH.pad, -(y + 8))
	mapArt:Show()
	if not drawn or drawn.map ~= map then view.zoom, view.fx, view.fy = 1, 50, 50 end
	drawn = { map = map, layer = layer, list = list, points = points }
	local painted = paintMap()
	y = y + 8 + mh + 12
	if not painted then y = C.Note(pool, y, w, L["This map's art is not available here, so the marks are drawn without it."]) end
	if total == 0 then
		y = C.Note(pool, y, w, layer.key == "p" and L["No path walked here yet: it is drawn from now on, as you move."] or L["Nothing counted on this layer here yet."])
	end
	shown.total = total
	return y
end

---------------------------------------------------------------------------
-- The section
---------------------------------------------------------------------------

function SV.Build(parent, shell)
	if root then return root end
	shellRef = shell
	root = CreateFrame("Frame", nil, parent)
	root:SetAllPoints(parent)
	scroll = W.Scroll(root)
	scroll:SetPoint("TOPLEFT", root, "TOPLEFT", 0, 0)
	scroll:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", 0, 0)
	root.Page = CreateFrame("Frame", nil, scroll.Child)
	root.Page:SetPoint("TOPLEFT", scroll.Child, "TOPLEFT", SH.pad, -12)
	root.Page:SetSize(1, 1)
	pool = C.Pool(root.Page)
	return root
end

-- The page in view: a page key, or "map:<uiMapID>".
local function current()
	local key = ns.Get("stats.page")
	local map = type(key) == "string" and tonumber(key:match("^map:(%d+)$"))
	if map then return key, map end
	for _, pg in ipairs(PAGES) do if pg.key == key then return key end end
	return PAGES[1].key
end

function SV.Render()
	if not root then return end
	for k in pairs(shown) do shown[k] = nil end
	local key, map = current()
	local on = Stats.Enabled()
	local a = Stats.Summary()
	local w = pageWidth()
	local title, sub = L["Stats"], nil
	if not on then
		sub = L["Turned off: showing what was counted"]
	elseif a.since then
		sub = format(L["Counting since %s"], day(a.since)) .. DOT .. L["kept on this computer only"]
	end
	C.Reset(pool)
	local y
	if map then
		title = Compat.MapName and Compat.MapName(map) or tostring(map)
		if shellRef then
			local tabs = {}
			for i, l in ipairs(LAYERS) do tabs[i] = { key = l.key, label = l.label } end
			W.ShellTabs(shellRef, tabs, layerOf(ns.Get("stats.layer")).key, function(k) SV.SetLayer(k) end)
		end
		y = drawMap(map, w)
	else
		hideMap()
		for _, pg in ipairs(PAGES) do if pg.key == key then title = pg.label end end
		y = pages[key](pool, w, a)
	end
	if shellRef then W.ShellTitle(shellRef, title, sub) end
	if not on then y = C.Note(pool, y + 8, w, L["Stats is turned off. Turn it on under Options > Discovery > Stats."]) end
	scroll.Child:SetWidth(w + SH.pad * 2)
	W.SetScrollContent(scroll, y + 32)
	shown.page, shown.map, shown.title, shown.subtitle, shown.off = key, map, title, sub, not on
	shown.fonts, shown.rects, shown.lines = C.Counts(pool)
end

-- The sidebar: the pages, then the zones played in.
function SV.Nav()
	local out = {}
	for i, pg in ipairs(PAGES) do out[i] = { key = pg.key, label = pg.label } end
	local zones = Stats.HeatMaps()
	if #zones > 0 then out[#out + 1] = { separator = true } end
	for i = 1, min(#zones, MAX_ZONES) do
		local z = zones[i]
		local name = Compat.MapName and Compat.MapName(z.map) or tostring(z.map)
		out[#out + 1] = { key = "map:" .. z.map, label = name, icon = "icon-explore" }
	end
	return out, (current())
end

local function repaint()
	local P = UI.Picker
	if root and root:IsVisible() and P and P.Render then P.Render() else SV.Render() end
end

function SV.OnNav(key)
	ns.Set("stats.page", key)
	if scroll then W.ScrollTo(scroll, 0) end
	repaint()
end

function SV.SetLayer(key)
	ns.Set("stats.layer", key)
	repaint()
end

function SV.Shown() return shown end

function SV.Show()
	local P = UI.Picker
	if UI.ShowPicker then UI.ShowPicker() end
	if P and P.ShowSection then P.ShowSection("Stats") end
	SV.Render()
end

ns.On("SHOW_STATS", SV.Show)
ns.On("STATS_UPDATED", function() if root and root:IsVisible() then repaint() end end)
-- The pool's colours are set as they are drawn: a new look draws the page again.
Theme.OnChanged(function() if root and root:IsVisible() then SV.Render() end end)

if UI.RegisterSection then
	UI.RegisterSection({
		key = "Stats", label = L["Stats"], icon = "layers", order = 70,
		build = SV.Build, render = SV.Render,
		nav = SV.Nav, onNav = SV.OnNav,
	})
end
