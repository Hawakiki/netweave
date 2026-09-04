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

return table.freeze({
	--[[ Fires per `PostSimulation` step, per mode and schema. ]]
	PACKETS_PER_FRAME = 200,

	--[[ Sampling window per (mode, schema, direction) cell. ]]
	RUN_SECONDS = 10,

	--[[ Discarded before sampling starts, so first-call costs are not charged to the run. ]]
	WARMUP_SECONDS = 1,

	--[[
		Between cells, wait for the send queue to empty before starting the next one. Without
		this, a backlog from the previous mode is attributed to the next one.
	]]
	DRAIN_KBPS = 0.5,
	DRAIN_SETTLE_SECONDS = 5,
	DRAIN_TIMEOUT_SECONDS = 30,

	--[[
		Encode-side allocation probe, run as its own short phase away from bandwidth sampling.

		Small windows, many of them. A large window is more likely to contain a collection, and a
		disturbed window is discarded — the first run got zero usable samples for `raw` at 500x5.
	]]
	ALLOC_ITERATIONS = 200,
	ALLOC_REPEATS = 25,

	--[[
		Decode-side allocation. The receiver samples the heap every this many logical packets and
		keeps the median of the windows the collector did not disturb. A single delta across a whole
		run does not work: the smoke run produced a negative number in 11 of 12 cells.
	]]
	DECODE_ALLOC_WINDOW = 500,

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
