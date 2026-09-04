--!strict
--!optimize 2

--[[
	Exact wire-byte counter.

	The first version of this harness derived bytes-per-packet from `Stats.DataSendKbps`. The
	smoke run proved that unusable: raw `RemoteEvent` traffic measured correctly (1115 B for a
	100-entity table, as expected) while Blink, Zap and ByteNet all reported ~4 B for a 601 B
	payload — roughly 280x low — even though the receiver confirmed every packet arrived. In
	Studio's play mode `Stats` does not account for `buffer` payloads on remotes.

	So we stop asking Roblox and count the bytes ourselves. Every buffer library multiplexes all
	of its traffic through one reliable `RemoteEvent` whose first argument is the batched buffer;
	attaching a second listener to that remote and summing `buffer.len` gives the exact number of
	bytes that crossed, with no dependency on `Stats`, on compression, or on framerate.

	Two consequences worth stating plainly:

	- `raw` has no tap. Its payload is a table, not a buffer, so there is nothing to measure this
	  way and it is excluded from the byte axis. Byte efficiency is a buffer-library contest.
	- The tap is an extra connection on the hot path, so it costs the libraries a little. It costs
	  all three of them the same, and it is the only exact method available, so the comparison
	  stays fair.

	`packets` counted here is remote invocations, not logical packets — these libraries batch a
	frame's worth of sends into one call. Bytes per logical packet is `bytes` from here divided by
	the receiver's own logical count.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local WAIT_TIMEOUT = 30

--[[
	Path from `ReplicatedStorage` to each library's reliable remote. Read out of the vendored
	sources: Blink `Templates/Server.luau` (`BASE_EVENT_NAME .. "_RELIABLE_REMOTE"`, scope
	`BLINK`), Zap `output/luau/server.rs` (folder `ZAP`, remote `ZAP_RELIABLE`), ByteNet
	`process/server.luau` (`ByteNetReliable`).

	All three fire `(buffer, references)`, so the tap reads the same argument position for each.
]]
local REMOTE_PATHS: { [string]: { string } } = {
	blink = { "BLINK_RELIABLE_REMOTE" },
	zap = { "ZAP", "ZAP_RELIABLE" },
	bytenet = { "ByteNetReliable" },

	--[[ netweave has no code generator, so this path is the one `bench/src/shared/Modes/netweave.luau`
	     creates. `WIRE-FORMAT.md` §1 gives every peer two remotes, reliable and unreliable; the
	     benchmark only sends on the reliable one. ]]
	netweave = { "NETWEAVE", "NETWEAVE_RELIABLE" },
}

export type Tap = {
	reset: () -> (),
	--[[ Bytes crossed, and how many remote invocations carried them. ]]
	read: () -> (number, number),
}

local WireTap = {}

local function resolve(path: { string }): Instance?
	local current: Instance = ReplicatedStorage

	for _, segment in path do
		local nextInstance = if RunService:IsServer()
			then current:FindFirstChild(segment)
			else current:WaitForChild(segment, WAIT_TIMEOUT)

		if not nextInstance then
			return nil
		end

		current = nextInstance
	end

	return current
end

--[[
	Returns nil for a mode with no buffer remote, which the caller should report as "not
	applicable" rather than zero.
]]
function WireTap.forMode(mode: string): Tap?
	local path = REMOTE_PATHS[mode]
	if not path then
		return nil
	end

	local remote = resolve(path)
	if not remote or not remote:IsA("RemoteEvent") then
		return nil
	end

	local bytes = 0
	local calls = 0
	local isServer = RunService:IsServer()

	local function count(payload: any)
		if type(payload) == "buffer" then
			bytes += buffer.len(payload)
			calls += 1
		end
	end

	if isServer then
		remote.OnServerEvent:Connect(function(_player, payload)
			count(payload)
		end)
	else
		remote.OnClientEvent:Connect(function(payload)
			count(payload)
		end)
	end

	return {
		reset = function()
			bytes = 0
			calls = 0
		end,
		read = function()
			return bytes, calls
		end,
	}
end

return WireTap
