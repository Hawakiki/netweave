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
]]

local Alloc = {}

local DEFAULT_ITERATIONS = 2000
local DEFAULT_REPEATS = 9

--[[ Heap size in bytes. `collectgarbage("count")` reports kilobytes. ]]
local function heapBytes(): number
	return collectgarbage("count") * 1024
end

export type Measurement = {
	--[[ Bytes of heap growth attributable to one call, or nil if every window was disturbed. ]]
	bytesPerCall: number?,
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

	return {
		bytesPerCall = if #samples > 0 then median(samples) else nil,
		usableSamples = #samples,
		repeats = repeatCount,
	}
end

return Alloc
