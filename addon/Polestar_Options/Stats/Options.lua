-- The Stats setting on the Discovery options page's Stats tab
-- (docs/ARCHITECTURE.md, "Options registry"). stats.enabled switches the
-- module off: nothing more is counted, and the Stats page says so. What was
-- counted earlier is still shown until it is cleared.
-- Part of the settings' addon: nothing of it is in memory before the settings open.

local ns = Polestar
local L = ns.L

if not (ns.Stats and ns.RegisterOptions) then return end

local ok, err = ns.RegisterOptions({
	page = L["Discovery"], tab = L["Stats"], section = L["Stats"],
	controls = {
		{ kind = "toggle", key = "stats.enabled", label = L["Stats"], search = "stats, statistics, dashboard, progress, play time, gold, heat map",
			help = L["Count what this character does (quests, experience, time, gold, where you play) for the Stats page (/pole stats). Kept on this computer only."] },
	},
})
if not ok and geterrorhandler then geterrorhandler()(err) end
