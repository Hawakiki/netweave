--!strict
--!optimize 2

--[[
	Driver for the benchmark. The client owns the run order; the server receives, counts, and
	fires back on request.

	For every (mode, schema) it runs three measurements:

	1. Encode allocation — heap growth per `fire` call, measured directly on this side.
	2. `Up` — client to server. Load is applied here; bytes are counted by the server's wire tap,
	   logical packets by the server's receiver.
	3. `Down` — server to client. The server applies the load and samples its own send bandwidth,
	   because the client's `Stats.DataReceiveKbps` reads zero in Studio. Bytes are counted by this
	   side's wire tap.

	Two rules the first version of this driver got wrong, both corrected here:

	- Bytes per packet does not come from `Stats`. Studio under-reports buffer payloads by roughly
	  280x (see `WireTap.luau`), so byte counts come off the remote directly.
	- The server's counters are snapshotted the instant a sampling window closes, not at the end of
	  the whole run. Read later they would include everything that drained afterwards, and the byte
	  total would no longer match the packet count it is divided by.

	Bandwidth is still recorded, normalized by observed framerate, but it is a cost signal only —
	never the source of a byte figure.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Stats = game:GetService("Stats")

local TESTS_TIMEOUT = 120

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Alloc = require(Shared:WaitForChild("Alloc"))
local Config = require(Shared:WaitForChild("Config"))
local Metrics = require(Shared:WaitForChild("Metrics"))
local Modes = require(Shared:WaitForChild("Modes"))
local Payloads = require(Shared:WaitForChild("Payloads"))
local WireTap = require(Shared:WaitForChild("WireTap"))

local control = ReplicatedStorage:WaitForChild("Control") :: RemoteEvent
local getResults = ReplicatedStorage:WaitForChild("GetResults") :: RemoteFunction
local publishResults = ReplicatedStorage:WaitForChild("PublishResults") :: RemoteEvent

--[[ Strip everything that costs frame time but is not the thing under test. ]]
local function quietTheClient()
	local camera = workspace.CurrentCamera
	if camera then
		camera.FieldOfView = 1
	end

	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		playerGui:ClearAllChildren()
	end

	for _, item in Enum.CoreGuiType:GetEnumItems() do
		pcall(function()
			StarterGui:SetCoreGuiEnabled(item, false)
		end)
	end
end

--[[
	Wait for the queues to empty. Without this a backlog from the previous cell lands inside the
	next cell's window and is attributed to the wrong library.
]]
local function drain()
	local deadline = os.clock() + Config.DRAIN_TIMEOUT_SECONDS

	while os.clock() < deadline do
		if Stats.DataSendKbps <= Config.DRAIN_KBPS and Stats.DataReceiveKbps <= Config.DRAIN_KBPS then
			break
		end
		RunService.Heartbeat:Wait()
	end

	task.wait(Config.DRAIN_SETTLE_SECONDS)
end

--[[
	Samples bandwidth and framerate once per wall-clock second for `RUN_SECONDS`.

	`apply` runs every `PostSimulation` step and returns how many packets it fired, so the same
	sampler serves both directions: for `Up` it fires, for `Down` it does nothing and the server
	supplies the load.
]]
local function sample(apply: () -> number): (Metrics.Summary, Metrics.Summary, number)
	local bandwidthSamples: { number } = {}
	local framerateSamples: { number } = {}

	local elapsed = 0
	local frames = 0
	local sent = 0
	local finished = false

	local connection
	connection = RunService.PostSimulation:Connect(function(deltaTime: number)
		elapsed += deltaTime
		frames += 1

		if elapsed >= 1 then
			elapsed -= 1
			table.insert(bandwidthSamples, Metrics.normalizeBandwidth(Stats.DataSendKbps, frames))
			table.insert(framerateSamples, frames)
			frames = 0
		end

		sent += apply()
	end)

	task.delay(Config.RUN_SECONDS, function()
		connection:Disconnect()
		finished = true
	end)

	while not finished do
		RunService.Heartbeat:Wait()
	end

	return Metrics.summarize(bandwidthSamples), Metrics.summarize(framerateSamples), sent
end

quietTheClient()

--[[
	The benchmark place maps `tests/` in beside `src/` so that one Play produces both the suite and
	the matrix. The suite installs and uninstalls transports and declares and resets namespaces, so
	it has to finish before any mode is loaded.

	The wait is conditional on the folder being there: a place built without the tests has nothing
	to wait for, and a timeout rather than an indefinite wait means a suite that hangs shows up as a
	slow start rather than a benchmark that never runs.
]]
local netweaveFolder = ReplicatedStorage:FindFirstChild("netweave")

if netweaveFolder and netweaveFolder:FindFirstChild("tests") then
	print("[bench] waiting for the netweave test suite")
	local marker = ReplicatedStorage:WaitForChild("netweaveTests", TESTS_TIMEOUT)
	print(`[bench] tests: {if marker then (marker :: StringValue).Value else "timed out"}`)
end

local entries = Modes.load()
local adapters: { [string]: Modes.Adapter } = {}
local unavailable: { [string]: string } = {}

--[[
	`Config.ONLY_MODES` narrows the run while an adapter is being debugged. A skipped mode is
	recorded in `unavailable` with the reason rather than dropped, so a run document can never look
	like a full matrix that happens to be missing a column.
]]
local function requested(name: string): boolean
	local only = Config.ONLY_MODES

	if not only then
		return true
	end

	return table.find(only, name) ~= nil
end

for _, entry in entries do
	if not requested(entry.name) then
		unavailable[entry.name] = "not in Config.ONLY_MODES"
	elseif entry.available and entry.adapter then
		adapters[entry.name] = entry.adapter
	else
		unavailable[entry.name] = entry.error or "unknown"
		warn(`[bench] mode "{entry.name}" unavailable: {entry.error}`)
	end
end

if Config.SMOKE then
	warn("[bench] SMOKE run: short windows, few samples. These numbers do not belong in RESULTS.md.")
end

local taps: { [string]: WireTap.Tap? } = {}
for mode in adapters do
	taps[mode] = WireTap.forMode(mode)
end

--[[
	Down-direction receivers, registered once up front for every mode. Mirrors the server's Up
	handlers: increment always, validate only the first packet.
]]
local downReceived: { [string]: number } = {}
local downCorrect: { [string]: boolean } = {}

local function cellKey(mode: string, schema: string): string
	return `{mode}|{schema}`
end

for mode, adapter in adapters do
	for _, schema in Modes.SCHEMAS do
		local expected = adapter.payloads[schema]
		local currentKey = cellKey(mode, schema)
		downReceived[currentKey] = 0

		adapter.onReceive(schema, "Down", function(payload)
			downReceived[currentKey] += 1

			if downCorrect[currentKey] == nil then
				downCorrect[currentKey] = Payloads.deepEquals(payload, expected)

				if not downCorrect[currentKey] then
					warn(`[bench] {mode}/{schema} Down failed payload validation`)
				end
			end
		end)
	end
end

local function warmUp(fire: (any) -> (), payload: any)
	local deadline = os.clock() + Config.WARMUP_SECONDS

	while os.clock() < deadline do
		for _ = 1, Config.PACKETS_PER_FRAME do
			fire(payload)
		end
		RunService.PostSimulation:Wait()
	end
end

local function runUp(mode: string, adapter: Modes.Adapter, schema: Modes.SchemaName): any
	local fire = adapter.bindFire(schema, "Up")
	local payload = adapter.payloads[schema]
	local packetsPerFrame = Config.PACKETS_PER_FRAME

	warmUp(fire, payload)
	drain()
	control:FireServer(Config.COMMAND.RESET, mode, schema)

	local bandwidth, framerate, sent = sample(function()
		for _ = 1, packetsPerFrame do
			fire(payload)
		end
		return packetsPerFrame
	end)

	--[[ Snapshot immediately: anything that drains after this must not be counted. ]]
	local snapshot = getResults:InvokeServer("cell", mode, schema)

	return {
		sent = sent,
		received = snapshot.received,
		correct = if snapshot.validated then snapshot.correct else nil,
		bandwidth = bandwidth,
		framerate = framerate,
		wireBytes = snapshot.wireBytes,
		wireCalls = snapshot.wireCalls,
		bytesPerPacket = if snapshot.wireBytes
			then Metrics.bytesPerPacket(snapshot.wireBytes, snapshot.received)
			else nil,
		decodeBytesPerPacket = snapshot.decodeBytesPerPacket,
		--[[ The spread the server computed, which this used to drop on the way into the document.

		     Phase 9 taught both sides to record it and then measured a run where every encode cell
		     carried its range and no decode cell did — because the copy here listed the fields by
		     hand and nobody added the two new ones. That is the same shape as the `Config` limit
		     name and the `Protocol` attribute list (`CLAUDE.md` §9): a hand-kept list, drifting from
		     what it lists. It matters more here than there, because acceptance 6 is a *decode*
		     allocation figure and it is the one number this milestone could not answer. ]]
		decodeBytesLow = snapshot.decodeBytesLow,
		decodeBytesHigh = snapshot.decodeBytesHigh,
		decodeAllocSamples = snapshot.decodeAllocSamples,
	}
end

--[[
	`startCommand` is either a targeted send or the library's broadcast primitive. With one
	client the broadcast case cannot show fan-out scaling, only the overhead of taking the
	broadcast path for a single recipient (see the server's `startDown`).
]]
local function runDown(mode: string, schema: Modes.SchemaName, startCommand: string): any
	local currentKey = cellKey(mode, schema)
	local tap = taps[mode]

	downReceived[currentKey] = 0
	downCorrect[currentKey] = nil
	if tap then
		tap.reset()
	end

	control:FireServer(startCommand, mode, schema)

	local _clientBandwidth, framerate = sample(function()
		return 0
	end)

	control:FireServer(Config.COMMAND.STOP_DOWN, mode, schema)

	local received = downReceived[currentKey]
	local bytes: number? = nil
	local calls: number? = nil
	if tap then
		bytes, calls = tap.read()
	end

	--[[ Bandwidth for this direction is measured by the sender; see the module comment. ]]
	local serverSide = getResults:InvokeServer("down")

	return {
		sent = 0,
		received = received,
		correct = downCorrect[currentKey],
		bandwidth = serverSide.bandwidth,
		framerate = framerate,
		serverFramerate = serverSide.framerate,
		wireBytes = bytes,
		wireCalls = calls,
		bytesPerPacket = if bytes then Metrics.bytesPerPacket(bytes, received) else nil,
	}
end

local results = {
	generatedAt = os.time(),
	config = {
		packetsPerFrame = Config.PACKETS_PER_FRAME,
		runSeconds = Config.RUN_SECONDS,
		targetFramerate = Metrics.TARGET_FRAMERATE,

		--[[ Carried into the run document so a smoke pass cannot be filed as a measurement. The
		     report prints it, and `bench/runs/` keeps it. ]]
		smoke = Config.SMOKE,
	},
	versions = {},
	unavailable = unavailable,
	cells = {},
}

for mode, adapter in adapters do
	(results.versions :: any)[mode] = adapter.version

	for _, schema in Modes.SCHEMAS do
		print(`[bench] {mode} / {schema}`)

		local fire = adapter.bindFire(schema, "Up")
		local payload = adapter.payloads[schema]

		--[[
			Encode allocation. Bound to the exact payload so no wrapper closure allocates on top
			of what the library does (PLAN-M0 R-3).
		]]
		local encodeAlloc = Alloc.measure(function()
			fire(payload)
		end, Config.ALLOC_ITERATIONS, Config.ALLOC_REPEATS)
		drain()

		local up = runUp(mode, adapter, schema)
		drain()

		local down = runDown(mode, schema, Config.COMMAND.START_DOWN)
		drain()

		local fireAll = runDown(mode, schema, Config.COMMAND.START_FIREALL)
		drain();
		(results.cells :: any)[cellKey(mode, schema)] = {
			mode = mode,
			schema = schema,
			up = up,
			down = down,
			fireAll = fireAll,
			encodeBytesPerPacket = encodeAlloc.bytesPerCall,
			--[[ The spread, so a cell whose median is where the collector happened to run announces
			     itself in the document rather than in the next milestone's plan (`Alloc.luau`). ]]
			encodeBytesLow = encodeAlloc.low,
			encodeBytesHigh = encodeAlloc.high,
			encodeAllocSamples = encodeAlloc.usableSamples,
			encodeAllocRepeats = encodeAlloc.repeats,
		}
	end
end

local json = HttpService:JSONEncode(results)
publishResults:FireServer(json)

print("[bench] done")
