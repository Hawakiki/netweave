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

--[[
	**Where an `ArrayHeavy` frame actually goes**, instead of the matrix.

	`PLAN-M4` phase 7 made the codec 1.31x faster on this VM, removed 1.8 ms from an 11.76 ms frame,
	and the framerate did not move by one FPS. The matrix cannot say why, because it reports the
	frame as one number; `bench/profile.luau` cannot either, because it takes the encode apart with
	the frame removed. This flag runs the missing instrument: the same Play, the same load, the same
	server, with the frame split into the part the fire loop owns and the part it does not — and the
	server's own framerate sampled in the same window, which the Up cell has never had.

	It replaces the matrix rather than running beside it: the matrix takes fifteen minutes and this
	takes under one, and running the two together would put a drain-less probe inside the run it is
	trying to explain.

	Its numbers are diagnostics and do not go in `RESULTS.md` as a cell. What they can do is name the
	next thing to measure — which is more than the phase that needed them had.
]]
local FRAME_PROBE = false

--[[ nil runs every adapter that loaded. A list runs only those, in the harness's own order. ]]
local ONLY_MODES: { string }? = nil

return table.freeze({
	SMOKE = SMOKE,
	ONLY_MODES = ONLY_MODES,
	FRAME_PROBE = FRAME_PROBE,

	--[[ Per phase. Short because the question is a ratio between phases in one session, not a
	     number to quote — and every phase is separated by the same drain the matrix uses. ]]
	PROBE_SECONDS = 5,

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

		~~Small windows, many of them. A large window is more likely to contain a collection, and a
		disturbed window is discarded — the first run got zero usable samples for `raw` at 500x5.~~
		**Both were true and neither was the problem** (M4 phase 0).

		`ALLOC_ITERATIONS` sends back to back without ever ending a frame, so for a batching library
		nothing is flushed and 5,200 payloads pile into one buffer that grows by doubling. Most calls
		then allocate nothing and a few allocate a block the size of everything before them, which is
		bursty by construction — so the median of `ALLOC_REPEATS` windows is a lottery on where the
		doublings landed. Every `ArrayHeavy` encode cell in the M3 matrix survived four to eight
		windows of twenty-five with a four-to-sixteen-times range, and netweave's median moved 40%
		between two runs of identical code.

		`ALLOC_WINDOWS` replaces both: one **frame** per window, ending in a yield so every library's
		own scheduler flushes inside the window, and many more windows because a frame is cheap.
		`Alloc.frames` has the argument; the two constants above stay for `Alloc.measure`, which
		nothing in the matrix uses any more.
	]]
	ALLOC_ITERATIONS = 200,
	ALLOC_REPEATS = if SMOKE then 5 else 25,
	ALLOC_WINDOWS = if SMOKE then 20 else 400,

	--[[
		Decode-side allocation. The receiver samples the heap every this many logical packets and
		keeps the median of the windows the collector did not disturb. A single delta across a whole
		run does not work: the smoke run produced a negative number in 11 of 12 cells.

		**Stays packet-aligned, and M4 phase 0 is where that stopped being an accident.** The send
		side moved to a frame window in that phase and the receive side was moved with it and then
		moved back, because the two costs have opposite shapes: an outgoing buffer is still there at
		the frame boundary and a batch of decoded values is not. `bench/src/server/init.server.luau`
		carries the measurement that settled it.
	]]
	DECODE_ALLOC_WINDOW = if SMOKE then 100 else 500,

	--[[ Control channel command names. ]]
	COMMAND = table.freeze({
		RESET = "reset",
		START_DOWN = "startDown",
		START_FIREALL = "startFireAll",
		STOP_DOWN = "stopDown",
		--[[ Clears the server's Down samples and send count after the warm-up, so the window the
		     client then samples starts from zero on both ends (M4-1: Down had no warm-up and no
		     denominator). ]]
		RESET_DOWN = "resetDown",
		START_PROBE = "startProbe",
		STOP_PROBE = "stopProbe",
	}),

	--[[ Where the client parks the final JSON for the harness driver to read. ]]
	RESULTS_NAME = "Results",
})
