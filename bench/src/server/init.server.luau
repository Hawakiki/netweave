--!strict
--!optimize 2

--[[
	Receiving side of the benchmark.

	Responsibilities, all driven by the client over `Control`:

	- Count arrivals on every (mode, schema) client-to-server event, and validate the first packet
	  so a mode that garbles its payload is reported as failed rather than looking fast.
	- Sample decode-side heap growth in windows. Nobody in the ecosystem publishes this number and
	  RESEARCH §3.8-S predicts it is where the real decode cost hides.
	- Count exact wire bytes through `WireTap`, because `Stats` does not account for buffer
	  payloads in Studio (see `WireTap.luau`).
	- Drive server-to-client traffic on request, and sample its own send bandwidth while doing so —
	  the client's `Stats.DataReceiveKbps` reads zero in Studio, so the sender has to measure.

	The receive handler stays as small as it can be, because everything it does is charged to the
	library under test.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Metrics = require(Shared:WaitForChild("Metrics"))
local Modes = require(Shared:WaitForChild("Modes"))
local Payloads = require(Shared:WaitForChild("Payloads"))
local WireTap = require(Shared:WaitForChild("WireTap"))

local control = ReplicatedStorage:WaitForChild("Control") :: RemoteEvent
local getResults = ReplicatedStorage:WaitForChild("GetResults") :: RemoteFunction
local publishResults = ReplicatedStorage:WaitForChild("PublishResults") :: RemoteEvent

type CellStats = {
	received: number,
	validated: boolean,
	correct: boolean,
	--[[ Heap samples for the decode-allocation probe, in bytes per packet. ]]
	allocSamples: { number },
	allocWindowStart: number,
	allocWindowHeap: number,
}

local entries = Modes.load()
local adapters: { [string]: Modes.Adapter } = {}
local unavailable: { [string]: string } = {}

for _, entry in entries do
	if entry.available and entry.adapter then
		adapters[entry.name] = entry.adapter
	else
		unavailable[entry.name] = entry.error or "unknown"
		warn(`[bench] mode "{entry.name}" unavailable: {entry.error}`)
	end
end

local taps: { [string]: WireTap.Tap? } = {}
for mode in adapters do
	taps[mode] = WireTap.forMode(mode)
end

local stats: { [string]: CellStats } = {}

local function key(mode: string, schema: string): string
	return `{mode}|{schema}`
end

local function heapBytes(): number
	return collectgarbage("count") * 1024
end

local function resetCell(mode: string, schema: string)
	stats[key(mode, schema)] = {
		received = 0,
		validated = false,
		correct = false,
		allocSamples = {},
		allocWindowStart = 0,
		allocWindowHeap = heapBytes(),
	}

	local tap = taps[mode]
	if tap then
		tap.reset()
	end
end

for mode, adapter in adapters do
	for _, schema in Modes.SCHEMAS do
		resetCell(mode, schema)

		local expected = adapter.payloads[schema]
		local cellKey = key(mode, schema)
		local window = Config.DECODE_ALLOC_WINDOW

		adapter.onReceive(schema, "Up", function(payload)
			local cell = stats[cellKey]
			cell.received += 1

			--[[
				Windowed heap delta. The collector cannot be stopped in Roblox, so a window it
				ran inside comes out negative; those are dropped and the median of the rest is
				reported (PLAN-M0 R-2, corrected).
			]]
			if cell.received - cell.allocWindowStart >= window then
				local now = heapBytes()
				local delta = now - cell.allocWindowHeap

				if delta > 0 then
					table.insert(cell.allocSamples, delta / window)
				end

				cell.allocWindowStart = cell.received
				cell.allocWindowHeap = now
			end

			if not cell.validated then
				cell.validated = true
				cell.correct = Payloads.deepEquals(payload, expected)

				if not cell.correct then
					warn(`[bench] {mode}/{schema} Up failed payload validation`)
				end
			end
		end)
	end
end

--[[
	Server-to-client load, plus the bandwidth sampling for that direction. Runs until the client
	says stop, so the client's sampling window is what defines the run.
]]
local downConnection: RBXScriptConnection? = nil
local downBandwidth: { number } = {}
local downFramerate: { number } = {}

local function stopDown()
	if downConnection then
		downConnection:Disconnect()
		downConnection = nil
	end
end

--[[
	`viaFireAll` selects the library's broadcast primitive instead of a targeted send.

	With a single client this cannot show fan-out scaling — the interesting property, that
	ByteNet has a dedicated `FireAllClients` channel while Blink and Zap copy bytes into every
	player's buffer (RESEARCH §3.7-E), only pays off with many recipients. What it does show is
	the overhead of the broadcast path itself, which for one recipient is pure cost.
]]
local function startDown(player: Player, mode: string, schema: Modes.SchemaName, viaFireAll: boolean?)
	stopDown()
	table.clear(downBandwidth)
	table.clear(downFramerate)

	local adapter = adapters[mode]
	if not adapter then
		return
	end

	local send = if viaFireAll and adapter.bindFireAll
		then adapter.bindFireAll(schema, "Down")
		else adapter.bindFire(schema, "Down", player)
	local payload = adapter.payloads[schema]
	local packetsPerFrame = Config.PACKETS_PER_FRAME
	local elapsed = 0
	local frames = 0

	downConnection = RunService.PostSimulation:Connect(function(deltaTime: number)
		--[[ Stop feeding a player who left mid-run. ]]
		if player.Parent ~= Players then
			stopDown()
			return
		end

		elapsed += deltaTime
		frames += 1

		if elapsed >= 1 then
			elapsed -= 1
			table.insert(downBandwidth, Metrics.normalizeBandwidth(Stats.DataSendKbps, frames))
			table.insert(downFramerate, frames)
			frames = 0
		end

		for _ = 1, packetsPerFrame do
			send(payload)
		end
	end)
end

control.OnServerEvent:Connect(function(player, command, mode, schema)
	if command == Config.COMMAND.RESET then
		resetCell(mode, schema)
	elseif command == Config.COMMAND.START_DOWN then
		startDown(player, mode, schema, false)
	elseif command == Config.COMMAND.START_FIREALL then
		startDown(player, mode, schema, true)
	elseif command == Config.COMMAND.STOP_DOWN then
		stopDown()
	end
end)

local function median(values: { number }): number?
	if #values == 0 then
		return nil
	end

	local sorted = table.clone(values)
	table.sort(sorted)

	local count = #sorted
	if count % 2 == 1 then
		return sorted[(count + 1) // 2]
	end

	return (sorted[count // 2] + sorted[count // 2 + 1]) / 2
end

--[[
	Snapshot of one cell, taken by the client the instant its sampling window closes. Reading it
	later would fold in whatever drained afterwards, and bytes-per-packet would stop matching the
	packet count it is divided by.
]]
local function snapshot(mode: string, schema: string): any
	local cell = stats[key(mode, schema)]
	if not cell then
		return nil
	end

	local tap = taps[mode]
	local bytes, calls = 0, 0
	if tap then
		bytes, calls = tap.read()
	end

	return {
		received = cell.received,
		validated = cell.validated,
		correct = cell.correct,
		--[[ nil when this mode has no buffer remote to tap, which is not the same as zero. ]]
		wireBytes = if tap then bytes else nil,
		wireCalls = if tap then calls else nil,
		decodeBytesPerPacket = median(cell.allocSamples),
		decodeAllocSamples = #cell.allocSamples,
	}
end

getResults.OnServerInvoke = function(_player, command: string, mode: string?, schema: string?): any
	if command == "cell" then
		assert(mode and schema, "cell snapshot needs a mode and schema")
		return snapshot(mode, schema)
	elseif command == "down" then
		return {
			bandwidth = Metrics.summarize(downBandwidth),
			framerate = Metrics.summarize(downFramerate),
		}
	end

	return { unavailable = unavailable }
end

--[[
	The client owns the final document; the server only parks it where an external driver can read
	it without a live client session.
]]
publishResults.OnServerEvent:Connect(function(_player, json: string)
	local existing = ReplicatedStorage:FindFirstChild(Config.RESULTS_NAME)
	local holder = if existing then existing :: StringValue else Instance.new("StringValue")

	holder.Name = Config.RESULTS_NAME
	holder.Value = json
	holder.Parent = ReplicatedStorage

	print("--RESULTS JSON--")
	print(json)
end)

Players.PlayerRemoving:Connect(function()
	stopDown()
end)

local tapped = {}
for mode, tap in taps do
	if tap then
		table.insert(tapped, mode)
	end
end

print(`[bench] server ready with modes: {table.concat(Modes.availableNames(entries), ", ")}`)
print(`[bench] wire taps attached for: {table.concat(tapped, ", ")}`)
