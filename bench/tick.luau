--!strict
--!optimize 2

--[[
	What a replication tick costs when nothing has changed.

		lune run bench/tick

	M4's security report filed `src/replication/Tick.luau` as O(subjects × players) with a full
	change attempt per pair, *even when nothing moved*, and gave four numbers for it. Those four are
	the `idle` rows below. This file exists because they were produced by a probe nobody committed,
	and a number that cannot be re-run is not a number (`CLAUDE.md` §5, §9) — least of all after the
	thing it measured has been changed.

	Every rung runs the **real** `Tick.new`, against the real `Outbound`, `Baseline` and
	`Recipients`, over a link that throws the bytes away. What the driver supplies and this file
	stands in for is only the frame: the tick is called by hand instead of by `PostSimulation`.

	### The rungs

	  * `idle` — the store has not been touched since the last tick and every client is up to date.
	    A tick here should cost as close to nothing as the audience walk allows, and before M4 phase
	    8 it cost a full `switchTo`, `pcall`, differ walk and `rollback` per (subject, player) pair.
	    Four shapes, so the cost can be seen to grow with the product rather than the sum.
	  * `one in ten` — a tenth of the subjects moved. The shape a game actually has.
	  * `all` — every subject moved. The gate must not make this case worse: it adds one comparison
	    per subject and has to earn it back.
	  * `narrow` — the same 500 subjects with an audience of one player, so the other forty-nine
	    take the removal pass. That pass is O(players²) per subject through `among`, and this is the
	    rung that prices it apart from the change attempt.

	:::caution
	This runs under lune, so the absolute milliseconds are not Studio's. What transfers is the
	**ratio between rungs and between shapes**, because every rung runs on the same VM in the same
	run. A frame budget at 60 FPS is 16.7 ms; the rows print against that as a guide to reading them,
	not as a claim about a Roblox server.
	:::
]]

local Baseline = require("../src/replication/Baseline")
local Config = require("../src/api/Config")
local Link = require("../src/transport/Link")
local Namespace = require("../src/api/Namespace")
local Outbound = require("../src/transport/Outbound")
local Recipients = require("../src/transport/Recipients")
local Tick = require("../src/replication/Tick")
local nw = require("../src/netweave")
local t = require("../src/types")

--[[ Twelve, because that is the width the report priced the per-pair attempt at: `write(nil, nil)`
     early return 130 ns against `write(v, v)` on twelve fields 646 ns. It is also past
     `Serdes.FUSED_MAX`, so the change writer takes the loop rather than the unrolled path — the
     pessimistic side of the cliff, which is the right side for a cost this file is arguing is too
     high. ]]
local FIELDS = 12

local REPEATS = 21
local WARMUP = 3

--[[ One frame at 60 FPS. Printed beside every row because "47 ms" means nothing until it is read
     against the budget it has to fit inside. ]]
local FRAME_MS = 1000 / 60

--[[
	What this file printed on the tree before the phase 8 gate existed — the same script, one commit
	earlier, which is what makes it a number rather than a memory. This file did not exist on that
	tree, so to reproduce them copy it there: `git worktree add ../before 37937c7~1`, copy this file
	into that tree's `bench/`, and run it. M4-1 did, and got every row 3–5% above the values here —
	the session, not the tree; the same offset moved every rung.

	`idle 50x500` is the report's 47.28 ms row, reproduced by this script rather than quoted from it.
]]
local BEFORE: { [string]: number } = {
	["idle 10x100"] = 1.25,
	["idle 10x500"] = 6.23,
	["idle 50x100"] = 7.13,
	["idle 50x500"] = 36.26,
	["one in ten 50x500"] = 36.51,
	["all 50x500"] = 40.24,
	["narrow 50x500"] = 1.67,
	--[[ The three rungs PLAN-M4-BUG phase 5 added, measured on the tree before that phase's tick
	     changes — the parent of the commit that changed `Tick.luau` — so the ratio printed beside
	     them is against a tree this file ran on. ]]
	["select-all 50x500"] = 14.32,
	["extra key 50x500"] = 31.02,
	["subtree 50x500"] = 1.85,
	--[[ Measured on `d982242`, the parent of the commit that hands the tick's list down
	     (`PLAN-M5` phase 5), with the rig's `has` in place — the same session as the values that
	     commit records beside it. ]]
	["nearby-all 50x500"] = 2.37,
}

-- ---------------------------------------------------------------------------------------------
-- The world, and the one channel per shape that replicates it
-- ---------------------------------------------------------------------------------------------

--[[ Limits out of the way, and said rather than assumed: this file is measuring the loop, and a
     `baselinesPerClient` refusal would replace the cost under test with the cost of refusing it —
     which is a different finding, already fixed, with its own test. ]]
Config.configure({
	limits = {
		baselinesPerClient = 65536,
		queueCapacity = 65536,
		pendingPerBatch = 65536,
	},
})

local shape: { [string]: any } = {}

for index = 1, FIELDS do
	shape[`f{index}`] = t.u16
end

type Shape = {
	name: string,
	players: number,
	subjects: number,
	narrow: boolean,
	--[[ A `select` that returns the whole roster: the most common `select` shape — everyone but
	     spectators, a team — and the one the broadcast skip did not cover (M4-1). ]]
	selectAll: boolean?,
	--[[ A `nearby` whose radius holds the whole roster: what `within` fills is then compacted
	     through the membership check per recipient, the same S × P the `select` shape pays, by the
	     other rule (`PLAN-M5` phase 5). The distance checks themselves are the Roblox roster's and
	     are not here. ]]
	nearbyAll: boolean?,
	--[[ One key per subject the schema never reads, changing every tick: `lastSeen = os.clock()`,
	     a `Character` reference. A walk over the whole table calls every subject moved (M4-1). ]]
	extra: boolean?,
	--[[ A subtree per subject the schema never reads — the inventory a `Replica.Data` carries that
	     this channel does not replicate — cloned into every baseline and walked every tick. ]]
	subtree: boolean?,
}

local SUBTREE_ENTRIES = 20

local SHAPES: { Shape } = {
	{ name = "10x100", players = 10, subjects = 100, narrow = false },
	{ name = "10x500", players = 10, subjects = 500, narrow = false },
	{ name = "50x100", players = 50, subjects = 100, narrow = false },
	{ name = "50x500", players = 50, subjects = 500, narrow = false },
	{ name = "narrow", players = 50, subjects = 500, narrow = true },
	{ name = "select-all", players = 50, subjects = 500, narrow = false, selectAll = true },
	{ name = "nearby-all", players = 50, subjects = 500, narrow = false, nearbyAll = true },
	{ name = "extra", players = 50, subjects = 500, narrow = false, extra = true },
	{ name = "subtree", players = 50, subjects = 500, narrow = false, subtree = true },
}

type Rig = {
	shape: Shape,
	channel: any,
	players: { any },
	world: { [number]: any },
	baselines: Baseline.Baseline,
	tick: () -> (),
	--[[ Bumps one field on every `step`th subject, so a rung can move a tenth of the world or all
	     of it without allocating anything the tick would then be timed carrying. ]]
	move: (step: number) -> (),
	--[[ Bumps the non-schema key on every subject, which is what a `lastSeen` does between ticks. ]]
	churn: () -> (),
}

local rigs: { [string]: Rig } = {}

--[[ Discards. A link that queued would grow by the size of the frame this file is deliberately
     making as large as it can, and the tick is finished before `flush` is reached either way. ]]
local sink: Link.Link = {
	send = function() end,
	sendAll = function() end,
	receive = function() end,
}

local declared: { [string]: any } = {}

for _, entry in SHAPES do
	local world: { [number]: any } = {}

	for subject = 1, entry.subjects do
		local value: { [string]: any } = {}

		for index = 1, FIELDS do
			value[`f{index}`] = index
		end

		if entry.extra then
			value.lastSeen = 0
		end

		if entry.subtree then
			local inventory: { number } = (table.create(SUBTREE_ENTRIES) :: any) :: { number }

			for index = 1, SUBTREE_ENTRIES do
				inventory[index] = index
			end

			value.inventory = inventory
		end

		world[subject] = value
	end

	local players: { any } = table.create(entry.players)

	for index = 1, entry.players do
		players[index] = { name = `p{index}` }
	end

	--[[ `select` returning one player is the narrow shape; a `select` returning the roster is the
	     shape the broadcast skip does not cover; everything else is `everyone`, which is the
	     branch that expands the roster into the recipient array. ]]
	local audience = if entry.narrow
		then nw.audience.select(function(): { any }
			return { players[1] }
		end)
		elseif entry.selectAll then nw.audience.select(function(): { any }
			return players
		end)
		elseif entry.nearbyAll then nw.audience.nearby(64)
		else nw.audience.everyone

	--[[ Through `any`: the audience differs per rung, three audience types are not one type, and a
	     union reaches the class type function as something `readproperty` refuses. The channel's view
	     is never used here — `Tick` drives it directly — so nothing the type function computes is lost. ]]
	declared[entry.name] = (nw.replicate :: any)({
		subject = t.u16,
		data = t.struct(shape),
		audience = audience,
		store = nw.store.of(world),
	})

	rigs[entry.name] = {
		shape = entry,
		channel = nil :: any,
		players = players,
		world = world,
		baselines = nil :: any,
		tick = nil :: any,

		move = function(step: number)
			for subject = step, entry.subjects, step do
				local value = world[subject]
				value.f1 = (value.f1 + 1) % 65536
			end
		end,

		churn = function()
			for subject = 1, entry.subjects do
				local value = world[subject]
				value.lastSeen = (value.lastSeen or 0) + 1
			end
		end,
	}
end

local channels = Namespace.declare("bench", declared)
Namespace.seal()

for _, entry in SHAPES do
	local rig = rigs[entry.name]
	local players = rig.players

	--[[ Every rig's player is here, so `has` answers true — through a set, which is the cheapest
	     way to answer it under lune and still a function call per recipient per subject, which is
	     what production paid per pair before `PLAN-M5` phase 5 handed the tick's list down. A rig
	     without `has` runs the degraded path (`Recipients.isRecipient`), which is not the path a
	     game is on. ]]
	local here: { [any]: true } = {}

	for _, player in players do
		here[player] = true
	end

	local roster: Recipients.Roster = {
		all = function(): { any }
			return players
		end,

		owner = function(): any?
			return players[1]
		end,

		--[[ Everyone, for the `nearby` shape; one player for everything else, which no rung
		     measures through this rule. ]]
		within = function(_subject: any, _studs: number, out: { any }): number
			if entry.nearbyAll then
				table.move(players, 1, #players, 1, out)
				return #players
			end

			out[1] = players[1]
			return 1
		end,

		has = function(who: any): boolean
			return here[who] == true
		end,
	}

	rig.channel = (channels.channels :: any)[entry.name]
	rig.baselines = Baseline.new(true)

	rig.tick = Tick.new({
		outbound = Outbound.new(sink, roster),
		baselines = rig.baselines,
		roster = roster,
		channels = function(): { any }
			return { rig.channel }
		end,
	})
end

-- ---------------------------------------------------------------------------------------------
-- Measuring
-- ---------------------------------------------------------------------------------------------

type Rung = {
	name: string,
	rig: Rig,
	--[[ How much of the world moves between ticks: `nil` is nothing, 10 is a tenth, 1 is all of
	     it. ]]
	step: number?,
	--[[ Whether the non-schema key changes between ticks. Nothing the schema reads moves. ]]
	churn: boolean?,
}

local RUNGS: { Rung } = {
	{ name = "idle 10x100", rig = rigs["10x100"] },
	{ name = "idle 10x500", rig = rigs["10x500"] },
	{ name = "idle 50x100", rig = rigs["50x100"] },
	{ name = "idle 50x500", rig = rigs["50x500"] },
	{ name = "one in ten 50x500", rig = rigs["50x500"], step = 10 },
	{ name = "all 50x500", rig = rigs["50x500"], step = 1 },
	{ name = "narrow 50x500", rig = rigs["narrow"] },
	{ name = "select-all 50x500", rig = rigs["select-all"] },
	{ name = "nearby-all 50x500", rig = rigs["nearby-all"] },
	{ name = "extra key 50x500", rig = rigs["extra"], churn = true },
	{ name = "subtree 50x500", rig = rigs["subtree"] },
}

type Result = {
	name: string,
	pairs: number,
	fastest: number,
	median: number,
	high: number,
}

--[[ The fastest pass, for the reason `bench/profile.luau` gives at length: the work is
     deterministic, so noise only ever adds. The median and the slowest are printed beside it so
     that claim can be checked rather than taken (`CLAUDE.md` §9). ]]
local function measure(rung: Rung): Result
	local rig = rung.rig
	local samples: { number } = (table.create(REPEATS) :: any) :: { number }

	--[[ The first tick sends every subject to every client, which is the join and not the steady
	     state. Warming up is what puts every client's baseline in place, so the timed passes are
	     measuring a world at rest rather than one arriving. ]]
	for _ = 1, WARMUP do
		if rung.step then
			rig.move(rung.step)
		end

		if rung.churn then
			rig.churn()
		end

		rig.tick()
	end

	for index = 1, REPEATS do
		if rung.step then
			rig.move(rung.step)
		end

		if rung.churn then
			rig.churn()
		end

		local started = os.clock()
		rig.tick()
		local elapsed = os.clock() - started

		samples[index] = elapsed * 1000
	end

	table.sort(samples)

	return {
		name = rung.name,
		pairs = rig.shape.players * rig.shape.subjects,
		fastest = samples[1],
		median = samples[math.ceil(REPEATS / 2)],
		high = samples[REPEATS],
	}
end

local results: { Result } = {}

for _, rung in RUNGS do
	table.insert(results, measure(rung))
end

-- ---------------------------------------------------------------------------------------------
-- The report
-- ---------------------------------------------------------------------------------------------

print("")
print(
	`        {FIELDS} u16 fields a subject, {REPEATS} ticks a rung, `
		.. `a frame at 60 FPS is {string.format("%.1f", FRAME_MS)} ms`
)
print("")
print("        rung                    ms/tick     ns/pair    % of a frame     median    slowest")

local failed = false

for _, result in results do
	local before = BEFORE[result.name]
	local moved = if before > 0 then ` ({string.format("%.1f", before / result.fastest)}x)` else ""

	--[[ A tick that cannot fit in a frame is the finding, so it is marked in the output rather than
	     left to the reader to divide. It is not a failure of this script: printing 280% and calling
	     the run OK is what a probe measuring a defect looks like before the defect is fixed. ]]
	print(
		`        {string.format("%-22s", result.name)} {string.format("%8.2f", result.fastest)}    `
			.. `{string.format("%8.0f", result.fastest * 1e6 / result.pairs)}    `
			.. `{string.format("%9.1f", result.fastest / FRAME_MS * 100)}%    `
			.. `{string.format("%7.2f", result.median)}   {string.format("%7.2f", result.high)}{moved}`
	)

	if result.fastest ~= result.fastest then
		failed = true
	end
end

print("")
print(if failed then "FAIL    tick" else "OK      tick")

--[[ A module inside Roblox has to return exactly one value; under lune this is ignored. ]]
return true
