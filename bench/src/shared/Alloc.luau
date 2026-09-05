--!strict
--!optimize 2

--[[
	Heap-growth probe.

	Nobody in the ecosystem measures allocation, and RESEARCH §3.8-S predicts it is where the
	real decode cost hides: every generated decoder builds its result with `value = {}` followed
	by keyed assignment, so the hash part rehashes at 1 -> 2 -> 4 -> 8 keys. Blink's harness
	cannot see any of that.

	Caveat, and it is a real one: Roblox only permits `collectgarbage("count")`. The collector
	cannot be stopped or forced, so a collection landing inside a sample window shows up as a
	negative or absurdly small delta. We therefore take several windows, discard the ones the
	collector visibly interfered with, and report the median of the rest. Treat the result as
	an order-of-magnitude signal, not a precise byte count (PLAN-M0 R-2).

	**And the median alone is not enough to say that with.** Measured in M3 phase 9: on the
	`ArrayHeavy` cell three to seven of twenty-five windows survived, and across two runs of the
	*same* matrix, libraries whose code had not changed by a line moved 19% and 21% on their encode
	number and 37% and 86% on their decode number. netweave's own numbers moved 67% and 9% and were
	written into a milestone plan as a regression before anyone looked at the control group. A probe
	whose surviving samples number four is reporting where the collector happened to run.

	Two things follow, and they are both here rather than in a caveat somebody has to remember.

	The **spread** is returned and recorded alongside the median, so a number that cannot be
	reproduced says so in the run document instead of looking like every other number. `bytesPerCall`
	with `low` and `high` a factor apart is not a measurement, and only the reader who is shown all
	three can tell.

	The **repeat count** is raised, because the surviving-sample count is the thing that was too
	small and it is free to make it larger — the windows the collector eats cost time and nothing
	else.

	What this file cannot fix is the window's shape, because that belongs to the caller: a window has
	to allocate enough that the collector's behaviour inside it is noise against the total. The same
	measurement under lune with one *frame* per window instead of one packet returns 400 usable
	windows out of 400 with a spread of zero, and that is the shape to reach for.
]]

local Alloc = {}

local DEFAULT_ITERATIONS = 2000
local DEFAULT_REPEATS = 25

--[[ Heap size in bytes. `collectgarbage("count")` reports kilobytes. ]]
local function heapBytes(): number
	return collectgarbage("count") * 1024
end

export type Measurement = {
	--[[ Bytes of heap growth attributable to one call, or nil if every window was disturbed. ]]
	bytesPerCall: number?,
	--[[ The smallest and largest surviving window, so a median nobody can reproduce is visible as
	     one. A cell whose `low` and `high` straddle its median by a factor is not a number to quote,
	     and the run document is where that has to be legible. ]]
	low: number?,
	high: number?,
	--[[ How many windows survived filtering, out of `repeats`. ]]
	usableSamples: number,
	repeats: number,
}

local function median(values: { number }): number
	local sorted = table.clone(values)
	table.sort(sorted)

	local count = #sorted
	if count % 2 == 1 then
		return sorted[(count + 1) // 2]
	end

	return (sorted[count // 2] + sorted[count // 2 + 1]) / 2
end

--[[
	Runs `fn` `iterations` times per window, `repeats` windows, and returns the median heap
	growth per call.

	`fn` must be the exact function under test with its arguments already bound — no wrapper
	closure, no varargs — or the wrapper's own allocation is what gets measured.
]]
function Alloc.measure(fn: () -> (), iterations: number?, repeats: number?): Measurement
	local iterationCount = iterations or DEFAULT_ITERATIONS
	local repeatCount = repeats or DEFAULT_REPEATS
	local samples = {}

	--[[ Warm up so first-call constant costs are not charged to the first window. ]]
	for _ = 1, iterationCount do
		fn()
	end

	for _ = 1, repeatCount do
		local before = heapBytes()

		for _ = 1, iterationCount do
			fn()
		end

		local delta = heapBytes() - before

		--[[ A collection ran inside this window; the number is meaningless. ]]
		if delta > 0 then
			table.insert(samples, delta / iterationCount)
		end
	end

	local sorted = table.clone(samples)
	table.sort(sorted)

	return {
		bytesPerCall = if #samples > 0 then median(samples) else nil,
		low = sorted[1],
		high = sorted[#sorted],
		usableSamples = #samples,
		repeats = repeatCount,
	}
end

return Alloc
