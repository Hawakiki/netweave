--!strict
--!optimize 2

--[[
	Where an `ArrayHeavy` frame goes, split into the part the send call owns and the part it does not.

	Selected by `Config.FRAME_PROBE`, which runs this instead of the matrix.

	### The hole this fills

	M4 phase 7 made netweave's encode 1.31x faster on this VM — 38,434 to 29,314 ns a packet,
	measured in Studio, which at 200 packets a frame is 1.8 ms out of an 11.76 ms frame — and the
	matrix measured 85 FPS before and 85 FPS after. Two instruments had been used and neither could
	explain that:

	  * the matrix reports the frame as **one number**, so nothing inside it can be attributed;
	  * `bench/profile.luau` takes the encode apart with **the frame removed**, so it can prove a
	    component got faster and say nothing about the frame it lives in.

	This is the third instrument, and it is the one that was missing: the real place, the real load,
	the real server, with a clock around the fire loop and the server's own framerate sampled in the
	same window.

	### What each phase measures

	| phase | what it adds |
	|---|---|
	| `idle` | the engine's own frame, with this place's scripts doing nothing |
	| per mode | 200 sends a frame — the client's encode, framing and remote call, plus whatever the server does with them in the same process |

	`fire` is the wall time inside the send loop, so `frame − fire` is everything else: the engine,
	the library's own flush on `PostSimulation`, and — because Studio Play runs both peers in one
	process — the server decoding the batch that loop just sent. The server's framerate is asked for
	separately, so those last two can be told apart at least by their sign.

	:::caution
	Diagnostics, not a cell. These numbers do not go into `RESULTS.md` as a result and they do not go
	into a run document; what they are for is naming the next thing to measure. The matrix is still
	the number of record (`CLAUDE.md` §5).
	:::
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Modes = require(Shared:WaitForChild("Modes"))

local SCHEMA: Modes.SchemaName = "ArrayHeavy"

export type Context = {
	adapters: { [string]: Modes.Adapter },
	drain: () -> (),
	control: RemoteEvent,
	getResults: RemoteFunction,
}

type Phase = {
	name: string,
	frames: number,
	seconds: number,
	fire: number,
	serverFramerate: number?,
}

--[[
	One window: run `work` every `PostSimulation` step for `PROBE_SECONDS` and keep two clocks — the
	wall time of the window and the time spent inside `work`.

	`os.clock` around the loop rather than a profiler because the question is a ratio, and because a
	number this file can print is one the next reader can re-run. `PostSimulation` is where the
	matrix fires too, so the phase and the cell it explains are the same shape.
]]
local function window(name: string, work: (() -> ())?): Phase
	local frames = 0
	local fire = 0
	local started = os.clock()
	local deadline = started + Config.PROBE_SECONDS

	while os.clock() < deadline do
		RunService.PostSimulation:Wait()
		frames += 1

		if work then
			local at = os.clock()
			work()
			fire += os.clock() - at
		end
	end

	return {
		name = name,
		frames = frames,
		seconds = os.clock() - started,
		fire = fire,
	}
end

local function report(phase: Phase)
	local fps = phase.frames / phase.seconds
	local frame = 1000 / fps
	local fire = phase.fire * 1000 / math.max(phase.frames, 1)
	local server = phase.serverFramerate

	print(
		`[probe] {string.format("%-10s", phase.name)} {string.format("%5.1f", fps)} FPS `
			.. `({string.format("%5.2f", frame)} ms a frame) — send loop {string.format("%5.2f", fire)} ms `
			.. `({string.format("%3.0f", fire / frame * 100)}%), everything else `
			.. `{string.format("%5.2f", frame - fire)} ms`
			.. (if server then `, server {string.format("%.0f", server)} FPS` else "")
	)
end

return function(context: Context)
	local adapters = context.adapters
	local drain = context.drain
	local control = context.control
	local getResults = context.getResults

	print(
		`[probe] frame partition on {SCHEMA}, {Config.PACKETS_PER_FRAME} sends a frame, `
			.. `{Config.PROBE_SECONDS} s a phase`
	)

	--[[ Before any mode runs, so no library's backlog is inside the engine's own number. ]]
	drain()
	report(window("idle"))

	--[[ Deterministic order, so two runs of this file print their rows in the same sequence and can
	     be diffed. `Modes.load` returns them in its own order and a table iteration would not. ]]
	local names: { string } = {}

	for name in adapters do
		table.insert(names, name)
	end

	table.sort(names)

	for _, name in names do
		local adapter = adapters[name]
		local fire = adapter.bindFire(SCHEMA, "Up")
		local payload = adapter.payloads[SCHEMA]
		local packetsPerFrame = Config.PACKETS_PER_FRAME

		--[[ The same warm-up the matrix gives a cell, so a first-call cost is not charged to the
		     phase. Then a drain, so the previous mode's backlog is not either. ]]
		for _ = 1, 60 do
			for _ = 1, packetsPerFrame do
				fire(payload)
			end
			RunService.PostSimulation:Wait()
		end

		drain()

		control:FireServer(Config.COMMAND.START_PROBE)

		local phase = window(name, function()
			for _ = 1, packetsPerFrame do
				fire(payload)
			end
		end)

		control:FireServer(Config.COMMAND.STOP_PROBE)

		--[[ Asked after the window closes: an `InvokeServer` inside it would park the client's
		     thread and the frame it yielded in would be charged to the send loop. ]]
		local answer = getResults:InvokeServer("probe")
		phase.serverFramerate = if answer and answer.samples > 0 then answer.framerate.p50 else nil

		report(phase)
		drain()
	end

	print("[probe] done")
end
