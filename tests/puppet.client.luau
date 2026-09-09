--!strict

--[[
	The client half of the Studio suite, which has no client.

	`tests/run.server.luau` runs on the server, so anything a section wants to know about the other
	end of a remote — did the packet arrive, how many bytes, how many instances survived the sidecar,
	does Roblox really drop an unreliable payload at 908 — has nothing to ask. This script is that
	something: it does nothing until the server creates `NETWEAVE_PUPPET`, then obeys it and echoes
	what it sees. `tests/roblox_runtime.luau` is the only file that talks to it.

	A `Script` with `RunContext = Client` under `ReplicatedStorage`, which is what Rojo emits for a
	`.client.luau` when `emitLegacyScripts` is false — the same mechanism the runner itself relies on
	(`CLAUDE.md` §6). The runner lists it under "not run", correctly: it is not a test.

	It arms itself on the netweave remotes only while the server says so, because the benchmark place
	maps `tests/` in beside `src/` and an echo per batch during the matrix would be a second client.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PUPPET_NAME = "NETWEAVE_PUPPET"
local UNRELIABLE_NAME = "NETWEAVE_PUPPET_UNRELIABLE"
local WAIT_TIMEOUT = 60

local puppet = ReplicatedStorage:WaitForChild(PUPPET_NAME, WAIT_TIMEOUT) :: RemoteEvent?

if not puppet then
	return
end

local strings = ReplicatedStorage:WaitForChild(UNRELIABLE_NAME, WAIT_TIMEOUT) :: UnreliableRemoteEvent?

if not strings then
	return
end

local function reply(...: any)
	(puppet :: RemoteEvent):FireServer(...)
end

local armed: { RBXScriptConnection } = {}

--[[ Every netweave batch, while armed: which remote, how many bytes, how many instances the
     sidecar delivered — an instance the client cannot see arrives as nil, and `#` does not count it. ]]
local function arm()
	local folder = ReplicatedStorage:WaitForChild("NETWEAVE", 10)

	if not folder then
		reply("armed", false)
		return
	end

	local reliable = folder:WaitForChild("NETWEAVE_RELIABLE", 10) :: RemoteEvent?
	local unreliable = folder:WaitForChild("NETWEAVE_UNRELIABLE", 10) :: UnreliableRemoteEvent?

	if not reliable or not unreliable then
		reply("armed", false)
		return
	end

	--[[ The first two bytes go back as well: the version and the first packet's channel id, which
	     is how the server can tell a packet that went out numbered from one that went out on the
	     reserved id 0. ]]
	local function echo(isReliable: boolean)
		return function(packed: any, instances: any)
			local bytes = if type(packed) == "buffer" then buffer.len(packed) else -1
			local count = if type(instances) == "table" then #instances else -1
			local version = if bytes >= 1 then buffer.readu8(packed, 0) else -1
			local id = if bytes >= 2 then buffer.readu8(packed, 1) else -1
			reply("netweave", isReliable, bytes, count, version, id)
		end
	end

	table.insert(armed, reliable.OnClientEvent:Connect(echo(true)))
	table.insert(armed, unreliable.OnClientEvent:Connect(echo(false)))
	reply("armed", true)
end

local function disarm()
	for _, connection in armed do
		connection:Disconnect()
	end

	table.clear(armed)
	reply("disarmed")
end

--[[ What a hostile client can put on netweave's own remotes: not a buffer, not a table, and a buffer
     that is not a batch. `Link.roblox` drops the first two before the decoder sees them and hands the
     third on, which is the server's `receive` handler's problem and the point of sending it. ]]
local function junk()
	local folder = ReplicatedStorage:WaitForChild("NETWEAVE", 10)
	local reliable = if folder then folder:FindFirstChild("NETWEAVE_RELIABLE") :: RemoteEvent? else nil
	local unreliable = if folder
		then folder:FindFirstChild("NETWEAVE_UNRELIABLE") :: UnreliableRemoteEvent?
		else nil

	if not reliable or not unreliable then
		reply("junked", false)
		return
	end

	reliable:FireServer("not a buffer", {})
	reliable:FireServer(buffer.create(3), "not a table")
	unreliable:FireServer(buffer.create(3), {})
	reply("junked", true)
end

puppet.OnClientEvent:Connect(function(command: any)
	if command == "arm" then
		arm()
	elseif command == "disarm" then
		disarm()
	elseif command == "junk" then
		junk()
	elseif command == "ping" then
		reply("pong")
	end
end)

--[[ The 908 probe: whatever arrives on the unreliable puppet remote is reported by size, with the
     count of instances that survived beside it. ]]
strings.OnClientEvent:Connect(function(packed: any, instances: any)
	local bytes = if type(packed) == "buffer" then buffer.len(packed) else -1
	local count = if type(instances) == "table" then #instances else 0
	reply("got", bytes, count)
end)

reply("ready")
