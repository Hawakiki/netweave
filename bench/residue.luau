--!strict
--!optimize 2

--[[
	The optimisation residue M4 and M4-1 left open, one rung per finding, each printing what the
	finding said was there so a fix can be seen to remove it (`PLAN-M5` phase 4, D-4).

		lune run bench/residue

	Every rung counts where it can and weighs only where it must (`CLAUDE.md` §9, "count it instead
	of weighing it"): a distinct-string set, a table identity, a call counter, a record's size. The
	rungs that have to weigh — bytes per call — read `collectgarbage("count")` across short windows,
	throw away the windows the collector stepped inside, and print the median with the spread and how
	many windows survived, so the reader can see how much to trust the number.

	Each rung's header records the BEFORE, measured on the parent tree of the commit that fixed it,
	because a number is not a number until it survives being re-run.
]]

local Buffer = require("../src/codec/Buffer")
local Delta = require("../src/replication/Delta")
local Ir = require("../src/codec/Ir")
local t = require("../src/types")

--[[ `gcinfo` is the heap in whole kilobytes — the analyzer deprecates `collectgarbage("count")`
     in its favour — so a window has to allocate enough for one call's share of a kilobyte to be
     below the noise, and be small enough that a full collection does not always land inside it.
     At 1,024 calls a window a kilobyte is one byte a call. ]]
local WINDOW = 1024
local WINDOWS = 64

type Weighed = { median: number, low: number, high: number, survived: number }

local function weigh(step: () -> ()): Weighed
	local perCall: { number } = {}

	for _ = 1, WINDOWS do
		local before = gcinfo()
		for _ = 1, WINDOW do
			step()
		end
		local delta = (gcinfo() - before) * 1024 / WINDOW

		--[[ A window the collector stepped inside reads low or negative, and there is no way to
		     tell a small step from a small allocation, so a window is kept only when nothing was
		     freed — which biases towards the true number, never away from it. ]]
		if delta >= 0 then
			table.insert(perCall, delta)
		end
	end

	table.sort(perCall)

	if #perCall == 0 then
		return { median = 0 / 0, low = 0 / 0, high = 0 / 0, survived = 0 }
	end

	return {
		median = perCall[math.ceil(#perCall / 2)],
		low = perCall[1],
		high = perCall[#perCall],
		survived = #perCall,
	}
end

--[[ What the fixed tree has to show, checked at the end so every rung prints first: on the parent
     tree this file is the BEFORE and should say so in full, not stop at the first rung. ]]
local failures: { string } = {}

local function expect(condition: boolean, message: string)
	if not condition then
		table.insert(failures, message)
	end
end

local function bytes(label: string, weighed: Weighed)
	print(
		string.format(
			"        %-44s %6.1f B/call  [%5.1f–%5.1f]  n = %d",
			label,
			weighed.median,
			weighed.low,
			weighed.high,
			weighed.survived
		)
	)
end

--[[ "Allocates nothing" is the one weighed claim that can be checked like a count: with nothing
     allocated the collector never steps, so every window survives and every one reads zero. ]]
local function nothing(label: string, weighed: Weighed)
	bytes(label, weighed)
	expect(
		weighed.survived == WINDOWS and weighed.high == 0,
		`{label}: expected 0 B/call in all {WINDOWS} windows`
	)
end

-- -------------------------------------------------------------------------------------------
-- 73 — Delta.write's commit closure
-- -------------------------------------------------------------------------------------------

--[[
	M4 finding 73: `write` defined `commit` inside itself, capturing `base`, a per-call local, so
	Luau built a closure per call — on the path `Tick` runs once per subject per recipient per
	frame. M4-1 measured 112 B a call; this rung measures both of `write`'s paths, since the
	"nothing changed" path built it too, for nothing to call it with.

	BEFORE (bea4631): changed 112.0 B/call [67–112, n = 45], unchanged 112.0 B/call [84–112, n = 46].
	AFTER: 0.0 in all 64 windows on both paths.
]]
local function rung73()
	print("73      Delta.write, bytes per call")

	local delta = Delta.build(Ir.lower(t.struct({ x = t.u16, y = t.u16, hp = t.u8 })))
	local record = Buffer.emptySave()
	local old = { x = 1, y = 2, hp = 3 }
	local new = { x = 1, y = 5, hp = 3 }

	--[[ The record is grown once, outside the windows, so a doubling never lands inside one. ]]
	Buffer.load(record)
	delta.write(old, new)
	Buffer.saveInto(record)

	nothing(
		"changed (a patch is written)",
		weigh(function()
			Buffer.load(record)
			delta.write(old, new)
		end)
	)

	nothing(
		"unchanged (nothing written)",
		weigh(function()
			Buffer.load(record)
			delta.write(old, old)
		end)
	)
end

rung73()

if #failures > 0 then
	print("")
	for _, failure in failures do
		print(`FAILED  {failure}`)
	end
	error(`{#failures} residue rung(s) still show what the finding described`)
end

print("OK      residue")

return true
