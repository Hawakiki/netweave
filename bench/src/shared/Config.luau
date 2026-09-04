--!strict
--!optimize 2

--[[
	Run parameters, shared so both peers agree on load and timing.

	The load is deliberately unrealistic: `PACKETS_PER_FRAME` at `RUN_SECONDS` is far past the
	60 Hz guidance every Roblox networking doc gives (RESEARCH §2). Saturating is the point — the
	goal is to separate the libraries, not to model a game (PLAN-M0 D-5).

	~~These values match Blink's own harness.~~ **Changed after the first measured run.** Blink
	uses 1000 fires per frame, which assumes roughly 60 FPS. Studio runs uncapped and measured
	200-240 FPS here, so 1000/frame on the 601 B `ArrayHeavy` payload offers ~138 MB/s — that
	measures the send queue, not the library. Since bytes are now counted exactly at the remote
	(`WireTap`) and are independent of load, the load only has to be heavy enough to separate the
	libraries on framerate.
]]

--[[
	A full matrix is five modes times three schemas, and each cell samples three directions with a
	drain between each. That is about 57 seconds a cell and a **quarter of an hour** for the run,
	most of it spent waiting for the send queue rather than measuring.

	`SMOKE` trades all of the statistical quality away for a run that finishes in two or three
	minutes. It exists for one question — does this adapter round-trip its payload at all — and its
	numbers must never reach `RESULTS.md`. `ONLY_MODES` narrows it further while an adapter is
	being debugged.

	The drains are what make the full run slow and they are not padding: `DRAIN_SETTLE_SECONDS`
	is why a backlog from the previous mode is not charged to the next one, and shortening it
	silently contaminates every cell after the first.
]]
local SMOKE = false

--[[ nil runs every adapter that loaded. A list runs only those, in the harness's own order. ]]
local ONLY_MODES: { string }? = nil

return table.freeze({
	SMOKE = SMOKE,
	ONLY_MODES = ONLY_MODES,

	--[[ Fires per `PostSimulation` step, per mode and schema. ]]
	PACKETS_PER_FRAME = 200,

	--[[ Sampling window per (mode, schema, direction) cell. ]]
	RUN_SECONDS = if SMOKE then 2 else 10,

	--[[ Discarded before sampling starts, so first-call costs are not charged to the run. ]]
	WARMUP_SECONDS = if SMOKE then 0.25 else 1,

	--[[
		Between cells, wait for the send queue to empty before starting the next one. Without
		this, a backlog from the previous mode is attributed to the next one.
	]]
	DRAIN_KBPS = 0.5,
	DRAIN_SETTLE_SECONDS = if SMOKE then 0.5 else 5,
	DRAIN_TIMEOUT_SECONDS = if SMOKE then 5 else 30,

	--[[
		Encode-side allocation probe, run as its own short phase away from bandwidth sampling.

		Small windows, many of them. A large window is more likely to contain a collection, and a
		disturbed window is discarded — the first run got zero usable samples for `raw` at 500x5.
	]]
	ALLOC_ITERATIONS = 200,
	ALLOC_REPEATS = if SMOKE then 5 else 25,

	--[[
		Decode-side allocation. The receiver samples the heap every this many logical packets and
		keeps the median of the windows the collector did not disturb. A single delta across a whole
		run does not work: the smoke run produced a negative number in 11 of 12 cells.
	]]
	DECODE_ALLOC_WINDOW = if SMOKE then 100 else 500,

	--[[ Control channel command names. ]]
	COMMAND = table.freeze({
		RESET = "reset",
		START_DOWN = "startDown",
		START_FIREALL = "startFireAll",
		STOP_DOWN = "stopDown",
	}),

	--[[ Where the client parks the final JSON for the harness driver to read. ]]
	RESULTS_NAME = "Results",
})
