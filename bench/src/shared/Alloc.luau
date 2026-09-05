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

	~~What this file cannot fix is the window's shape, because that belongs to the caller.~~
	**[Alloc.frames] is that shape, added in M4 phase 0**, and the caller's window turned out to be
	the whole defect rather than a contributing one.

	`Alloc.measure` calls `fn` `iterations` times back to back and never lets a frame end. For a
	batching library that means nothing is ever flushed: five thousand payloads accumulate into one
	outgoing buffer that grows by **doubling**, so most calls allocate nothing at all and a handful
	allocate a block the size of everything before them. That is not a frame, and the median of
	twenty-five windows over it is a lottery on where the doublings landed — which is exactly what
	the M3 matrix reported. Every `ArrayHeavy` encode cell in it survived four to eight windows of
	twenty-five with a low-to-high range of four to sixteen times, and netweave's own median moved
	40% between two runs of identical code.

	[Alloc.frames] measures **one frame per window and many windows**: the caller's frame function
	does a frame's worth of sends and then yields, so every library's own scheduler flushes inside
	the window and the buffer growth is amortised the way production amortises it. The same shape
	under lune returned 400 usable windows out of 400 with a spread of zero.

	It buys that with a known cost: a window now contains one real engine frame, so Studio's own
	allocation — rendering, physics, replication — is charged to the library. That is why
	[Alloc.frames] is meant to be run against an **idle frame** as well, in the same units, so the
	engine's share is a measured number in the run document rather than an unknown inside every
	cell. A control group, in the sense `CLAUDE.md` §9 means it.
]]

local Alloc = {}

local DEFAULT_ITERATIONS = 2000
local DEFAULT_REPEATS = 25

--[[ Frames are cheap — one window is one frame rather than two hundred sends — so the count that
     was too small is raised by more than an order of magnitude and still costs less wall clock than
     what it replaces. ]]
local DEFAULT_WINDOWS = 400

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

--[=[
	@within Alloc
	@function frames
	@param frame () -> () -- one frame's work, ending in a yield so the library's scheduler runs
	@param callsPerFrame number -- what to divide a window by, so the result is per call
	@param windows number? -- how many frames to sample
	@return Measurement

	Heap growth per call, measured **one frame at a time**.

	This is [Alloc.measure]'s window shape corrected. The difference is the yield: `frame` has to
	end by waiting for the frame boundary, so whatever the library under test does on its own
	scheduler — netweave flushes on `PostSimulation`, and every competitor has an equivalent —
	happens *inside* the window being measured. Without it the probe measures an outgoing buffer
	that grows by doubling and is never emptied, which is bursty by construction and is why the M3
	encode column reported a different number every run.

	```lua
	local frame = function()
		for _ = 1, packetsPerFrame do
			fire(payload)
		end

		RunService.PostSimulation:Wait()
	end

	local measured = Alloc.frames(frame, packetsPerFrame)
	local idle = Alloc.frames(function()
		RunService.PostSimulation:Wait()
	end, packetsPerFrame)
	```

	:::caution
	A window now contains a real engine frame, so Studio's own allocation is inside it. **Measure an
	idle frame in the same units and record it beside the cell** — the second half of the example
	above. A cell whose median is not comfortably above the idle figure is measuring Studio, and only
	a reader who is shown both can tell.
	:::

	`frame` must be built once, outside the call. A closure created per window is an allocation per
	window, which is the thing being measured.
]=]
function Alloc.frames(frame: () -> (), callsPerFrame: number, windows: number?): Measurement
	local windowCount = windows or DEFAULT_WINDOWS
	local samples = {}

	--[[ Warm up: the first frames pay one-time costs — a buffer reaching its working size, a
	     scheduler connecting — that no later frame pays and that would land entirely in window
	     one. ]]
	for _ = 1, 8 do
		frame()
	end

	for _ = 1, windowCount do
		local before = heapBytes()

		frame()

		local delta = heapBytes() - before

		--[[ A collection ran inside this frame; the number is meaningless. Same filter as
		     [Alloc.measure], and the same upward bias — windows the collector visited are dropped
		     rather than corrected, because Roblox does not expose enough to correct them. ]]
		if delta > 0 then
			table.insert(samples, delta / callsPerFrame)
		end
	end

	local sorted = table.clone(samples)
	table.sort(sorted)

	return {
		bytesPerCall = if #samples > 0 then median(samples) else nil,
		low = sorted[1],
		high = sorted[#sorted],
		usableSamples = #samples,
		repeats = windowCount,
	}
end

return Alloc
