//! The Stats section (addon/Polestar/Stats): the per-character totals (what is counted from which events, the
//! sampler, the heat grid, the caps), the off switch, and the hub section's pages.

use forge_addontest::{emitted, is_match, text, Addon, RunAddon};
use serde_json::{json, Value};

const CORE: &[&str] = &["Core/Core.xml", "Theme/Theme.xml", "Stats/Stats.xml"];
const WITH_UI: &[&str] = &["Core/Core.xml", "Theme/Theme.xml", "UI/UI.xml", "Stats/Stats.xml"];

/// A level 18 Mage in Darkshore with 5 silver, standing at 40, 50 on the zone's map.
const WORLD: &str = r#"
local w = stub.world
w.class, w.className, w.race, w.raceName = "MAGE", "Mage", "NightElf", "Night Elf"
w.level, w.xp, w.xpMax = 18, 1000, 4000
w.zone, w.subzone = "Darkshore", ""
w.money = 500
w.addMap(1439, { name = "Darkshore", c = 1, left = 1000, right = -1000, top = 1000, bottom = -1000 })
w.moveTo(1439, 40, 50)
local combat, mounted, inside = false, false, false
InCombatLockdown = function() return combat end
IsMounted = function() return mounted end
IsInInstance = function() if inside then return true, "party" end return false end
GetInstanceInfo = function() return "Blackfathom Deeps", "party", 1, "", 5, 0, false, 48 end
function setCombat(v) combat = v; stub.fire(v and "PLAYER_REGEN_DISABLED" or "PLAYER_REGEN_ENABLED") end
function setMounted(v) mounted = v end
function setInside(v) inside = v end
"#;

const PRELUDE: &str = r#"local Stats = Polestar.Stats
local function S() return Stats.Summary() end
"#;

fn run_in(script: &str, files: &[&str], ui: bool) -> Value {
	let mut stubs = vec!["stub_world.lua"];
	if ui {
		stubs.push("stub_ui.lua");
	}
	emitted(&RunAddon { stubs, before: WORLD.into(), addons: vec![Addon::files("Polestar", files)], login: true, script: [PRELUDE, script].concat(), ..Default::default() }).remove(0)
}

fn run(script: &str) -> Value {
	run_in(script, CORE, false)
}

#[test]
fn quests_accepted_turned_in_and_abandoned_with_the_xp_money_and_time_of_a_turn_in() {
	let out = run(r#"
local w = stub.world
w.accept(7, { 10 })
w.accept(8, { 1 })
stub.advance(120)
w.turnIn(7, 450, 250)
w.abandon(8)
local a = S()
local q = a.quests[1]
emit({ counts = { a.accepted, a.turned, a.abandoned }, xp = a.xp.quests, money = a.income.quests,
	quest = { q.q, q.xp, q.m, q.lv }, dur = q.dur, timed = a.timedQuests, open = next(Stats.Store().open) == nil })"#);
	assert_eq!(out["counts"], json!([2, 1, 1]), "a turn-in's QUEST_REMOVED is not an abandon");
	assert_eq!(out["xp"], 450);
	assert_eq!(out["money"], 250);
	assert_eq!(out["quest"], json!([7, 450, 250, 18]));
	assert!((119..=120).contains(&out["dur"].as_i64().unwrap()), "accepted two minutes before: {}", out["dur"]);
	assert_eq!(out["timed"], 1);
	assert_eq!(out["open"], true);
}

#[test]
fn xp_is_split_into_quests_exploring_and_kills_and_a_kill_is_the_clients_xp_line() {
	let out = run(r#"
local w = stub.world
ERR_ZONE_EXPLORED_XP = "Discovered %s: %d experience gained"
w.setXP(1100)                                   -- a kill: the gain, then its line
stub.fire("CHAT_MSG_COMBAT_XP_GAIN", "Moonstalker dies, you gain 100 experience.")
stub.advance(5)
stub.fire("CHAT_MSG_COMBAT_XP_GAIN", "x")       -- a kill: the line, then the gain
w.setXP(1160)
stub.advance(5)
stub.fire("CHAT_MSG_SYSTEM", "Discovered Auberdine: 40 experience gained")
stub.fire("UI_INFO_MESSAGE", 1, "Discovered Auberdine: 40 experience gained")
w.setXP(1200)
stub.advance(5)
w.turnIn(9, 300, 0)
w.setXP(1500)
local a = S()
local h = Stats.Heat(1439)
local cell = Stats.Cell(40, 50)
emit({ xp = { a.xp.total, a.xp.quests, a.xp.explore, a.xp.kills }, kills = a.kills,
	heat = { h.k[cell], h.x[cell], h.q[cell] } })"#);
	assert_eq!(out["xp"], json!([500, 300, 40, 160]), "total, quests, exploring (its line counted once), kills the rest");
	assert_eq!(out["kills"], 2);
	assert_eq!(out["heat"], json!([2, 160, 300]), "kills, kill XP and quest XP in the cell the player stands in");
}

#[test]
fn the_sampler_counts_played_combat_and_mounted_time_by_hour_and_into_the_heat_cell() {
	let out = run(r#"
Stats.Tick(2)
setCombat(true)
Stats.Tick(2)
setCombat(false)
setMounted(true)
Stats.Tick(2)
stub.world.onTaxi = true
Stats.Tick(2)
local a = S()
local hours, days = 0, 0
for _, v in pairs(a.hours) do hours = hours + v end
for _, v in pairs(a.weekdays) do days = days + v end
emit({ time = { a.played, a.combat, a.mounted, a.fights }, hours = hours, days = days,
	cell = Stats.Heat(1439).t[Stats.Cell(40, 50)], active = Stats.Store().active, sessions = a.sessions })"#);
	assert_eq!(out["time"], json!([8, 2, 4, 1]));
	assert_eq!(out["hours"], 8);
	assert_eq!(out["days"], 8);
	assert_eq!(out["cell"], 6, "a flight is played time, not time spent in a place");
	assert_eq!(out["active"], 8);
	assert_eq!(out["sessions"], 1);
}

#[test]
fn gold_looted_a_merchant_visits_net_training_and_the_purse_samples() {
	let out = run(r#"
local w = stub.world
stub.fire("LOOT_OPENED")
w.setMoney(560)                                  -- 60c from a corpse
stub.fire("LOOT_CLOSED")
stub.advance(5)
w.setMoney(600)                                  -- not loot: nothing open
w.merchant(54)
w.setMoney(900)                                  -- sold 3s
w.close()
w.merchant(54)
w.setMoney(700)                                  -- bought 2s
w.close()
w.trainer(911)
w.setMoney(450)
w.close()
local a = S()
emit({ income = { a.income.loot, a.income.vendor }, spent = { a.spent.buy, a.spent.trainer }, first = a.money[1] })"#);
	assert_eq!(out["income"], json!([60, 300]));
	assert_eq!(out["spent"], json!([200, 250]));
	assert_eq!(out["first"][1], 500, "the purse at login is the line's first sample");
}

#[test]
fn level_ups_deaths_and_a_dungeon_run_are_listed() {
	let out = run(r#"
local w = stub.world
Stats.Tick(2)
w.setLevel(19)
stub.fire("PLAYER_DEAD")
stub.fire("PLAYER_DEAD")
setInside(true)
Stats.Tick(2)
stub.advance(600)
Stats.Tick(2)
stub.fire("ENCOUNTER_END", 1, "Boss", 1, 5, 1)
stub.fire("ENCOUNTER_END", 2, "Boss", 1, 5, 0)
setInside(false)
Stats.Tick(2)
local a = S()
local run = a.dungeons[1]
emit({ level = { a.levels[1].l, a.levels[1].p }, deaths = a.deaths, unknown = a.killers[0].n, bosses = a.bosses,
	run = { run.name, run.s >= 600 }, open = Stats.Store().inst == nil, cell = Stats.Heat(1439).d[Stats.Cell(40, 50)] })"#);
	assert_eq!(out["level"], json!([19, 2]), "the level and the time played by then");
	assert_eq!(out["deaths"], 2);
	assert_eq!(out["unknown"], 2, "no foe seen: filed under unknown");
	assert_eq!(out["bosses"], 1, "only a won encounter");
	assert_eq!(out["run"], json!(["Blackfathom Deeps", true]));
	assert_eq!(out["open"], true);
	assert_eq!(out["cell"], 2);
}

#[test]
fn turned_off_nothing_is_counted_and_what_was_saved_stays_reset_forgets_it() {
	let out = run(r#"
local w = stub.world
w.accept(7, { 1 })
Polestar.Set("stats.enabled", false)
w.accept(8, { 1 })
Stats.Tick(2)
local off = { S().accepted, S().played }
Polestar.Set("stats.enabled", true)
w.accept(9, { 1 })
local on = S().accepted
Stats.Reset()
emit({ off = off, on = on, reset = { S().accepted, PolestarCharDB.stats ~= nil } })"#);
	assert_eq!(out["off"], json!([1, 0]));
	assert_eq!(out["on"], 2);
	assert_eq!(out["reset"][0], 0);
}

#[test]
fn days_beyond_the_cap_are_summed_away_and_the_totals_keep_them() {
	let out = run(r#"
local s = Stats.Store()
for i = 1, 400 do s.days[string.format("2020%04d", i)] = { qa = 1 } end
stub.world.accept(7, { 1 })
local n = 0
for _ in pairs(s.days) do n = n + 1 end
emit({ days = n, old = s.old.qa, total = S().accepted })"#);
	assert_eq!(out["days"], 370);
	assert_eq!(out["old"], 31);
	assert_eq!(out["total"], 401);
}

#[test]
fn the_section_draws_each_page_lists_the_zones_played_in_and_a_zones_heat_map() {
	let out = run_in(
		r#"
local w = stub.world
w.accept(7, { 1 })
stub.advance(60)
w.turnIn(7, 450, 250)
Stats.Tick(2)
stub.fire("PLAYER_DEAD")
Polestar.Fire("SHOW_STATS")
local V = Polestar.UI.StatsSection
local pages = {}
for _, key in ipairs({ "activity", "character", "time", "gold", "professions" }) do
	V.OnNav(key)
	local s = V.Shown()
	pages[#pages + 1] = { s.page, s.title, s.fonts > 0 }
end
local nav, active = V.Nav()
local keys = {}
for i, item in ipairs(nav) do keys[i] = item.separator and "-" or item.key end
V.OnNav("map:1439")
local path = { V.Shown().page, V.Shown().cells, V.Shown().total }
V.SetLayer("t")
local m = V.Shown()
local time = { m.page, m.map, m.cells, math.floor(m.total + 0.5) }
local title, subtitle = m.title, m.subtitle
V.SetLayer("d")
local deaths = { V.Shown().cells, V.Shown().total }
Polestar.Set("stats.enabled", false)
V.Render()
emit({ pages = pages, keys = keys, active = active, path = path, time = time, deaths = deaths, title = title,
	subtitle = subtitle, offSubtitle = V.Shown().subtitle, off = V.Shown().off, section = Polestar.UI.Picker.Section() })"#,
		WITH_UI,
		true,
	);
	assert_eq!(out["section"], "Stats");
	assert_eq!(out["pages"], json!([["activity", "Activity", true], ["character", "Character", true], ["time", "Time", true], ["gold", "Gold", true], ["professions", "Professions", true]]));
	assert_eq!(out["keys"], json!(["activity", "character", "time", "gold", "professions", "-", "map:1439"]));
	assert_eq!(out["active"], "professions");
	assert_eq!(out["time"], json!(["map:1439", 1439, 1, 62]), "the ticker's minute and the one sample");
	assert_eq!(out["deaths"], json!([1, 1]));
	assert_eq!(out["path"], json!(["map:1439", 0, 1]), "the path layer comes first: one point where the player stood, no line yet");
	assert_eq!(out["title"], "Darkshore");
	assert!(is_match(text(&out["subtitle"]), r"^Counting since "));
	assert_eq!(out["off"], true);
	assert_eq!(out["offSubtitle"], "Turned off: showing what was counted");
}

#[test]
fn the_walked_path_is_kept_as_points_broken_at_a_jump_and_capped_a_zone() {
	let out = run(r#"
local w = stub.world
local function at(x, y) w.moveTo(1439, x, y) Stats.Tick(2) end
at(40, 50) at(40.05, 50) at(41, 50) at(42, 51)
at(80, 20) at(81, 20)
local t = Stats.Trail(1439)
local pts = {}
for i, p in ipairs(t) do
	local x, y = Stats.TrailXY(p)
	pts[i] = x and { x, y } or "break"
end
for i = 1, 7000 do at(10 + (i % 800) / 10, 10 + i / 100) end
emit({ pts = pts, kept = #Stats.Trail(1439) <= 6200, newest = { Stats.TrailXY(Stats.Trail(1439)[#Stats.Trail(1439)]) } })"#);
	assert_eq!(out["pts"], json!([[40, 50], [41, 50], [42, 51], "break", [80, 20], [81, 20]]), "standing still adds nothing, a jump across the map breaks the line");
	assert_eq!(out["kept"], true);
	assert_eq!(out["newest"], json!([70, 80]));
}

#[test]
fn a_v1_store_moves_its_heat_onto_the_finer_grid() {
	let out = run(r#"
PolestarCharDB.stats = { v = 1, heat = { [1439] = { t = { [50 * 80 + 40 + 1] = 30 }, k = { [1] = 2 } } } }
local s = Stats.Store()
local h = Stats.Heat(1439)
emit({ v = s.v, grid = Stats.GRID, t = h.t[Stats.Cell(50.6, 63.1)], k = h.k[Stats.Cell(0.6, 0.6)], again = Stats.Store().heat[1439].t[Stats.Cell(50.6, 63.1)] })"#);
	assert_eq!(out["v"], 2);
	assert_eq!(out["grid"], 240);
	assert_eq!(out["t"], 30);
	assert_eq!(out["k"], 2);
	assert_eq!(out["again"], 30, "migrated once");
}

#[test]
fn the_map_zooms_in_on_a_point_pans_and_draws_the_path_as_lines() {
	let out = run_in(
		r#"
local w = stub.world
local function at(x, y) w.moveTo(1439, x, y) Stats.Tick(2) end
at(40, 50) at(41, 50) at(42, 51) at(43, 51)
at(90, 90) at(91, 90)
Polestar.Fire("SHOW_STATS")
local V = Polestar.UI.StatsSection
V.OnNav("map:1439")
local s = V.Shown()
local whole = { s.cells, s.total, s.zoom, s.focus[1], s.focus[2] }
for _ = 1, 40 do V.Zoom(1) end
local deep = { V.Shown().zoom, V.Shown().focus[1], V.Shown().focus[2] }
V.ResetView()
V.Zoom(4, 0, 0)
local corner = { V.Shown().zoom > 2.4, V.Shown().focus[1] < 25, V.Shown().focus[2] < 25, V.Shown().cells }
V.Pan(-100000, -100000)
local far = { V.Shown().focus[1] > 75, V.Shown().focus[2] > 75, V.Shown().cells }
V.Zoom(-40)
local out = { V.Shown().zoom, V.Shown().focus[1], V.Shown().focus[2], V.Shown().cells }
V.SetLayer("t")
V.Zoom(3)
local heat = { V.Shown().zoom > 1.9, V.Shown().cells }
emit({ whole = whole, deep = deep, corner = corner, far = far, out = out, heat = heat })"#,
		WITH_UI,
		true,
	);
	assert_eq!(out["whole"], json!([4, 6, 1, 50, 50]), "three segments, a break, one more");
	assert_eq!(out["deep"], json!([12, 50, 50]), "the wheel stops at the deepest zoom");
	assert_eq!(out["corner"], json!([true, true, true, 0]), "zooming on the top left corner leaves the path out of the frame");
	assert_eq!(out["far"], json!([true, true, 1]), "dragged to the bottom right: the last stretch only");
	assert_eq!(out["out"], json!([1, 50, 50, 4]));
	assert_eq!(out["heat"], json!([true, 4]), "the heat cells are culled the same way: four of the six are in the frame");
}
