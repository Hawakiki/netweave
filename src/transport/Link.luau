--!strict
--!optimize 2

--[=[
	@class Link

	The two remotes, behind an interface.

	Everything above this line is plain Luau and runs under lune. `RemoteEvent`, `Players` and the
	rest of Roblox live below it, which is what lets the batch envelope, the fan-out and the
	dispatch be tested in-process instead of through a Studio round trip.

	Internal.
]=]

--[[
	Two remotes per side, one reliable and one unreliable, as every batching library surveyed does
	(`RESEARCH §3.7-E`). Not one per event: Zap creates a `RemoteEvent` per unreliable event and
	pays an instance for each, which buys nothing once packets carry a channel id anyway.
]]

--[[
	Services are looked up inside `roblox()` rather than at the top of the file. A module that
	reaches for `game` while loading cannot be *required* under lune at all, and `Outbound` needs
	this module for its type — so a top-level lookup here would take the whole transport out of the
	lune test suite to save one line.
]]
local Link = {}

local FOLDER_NAME = "NETWEAVE"
local RELIABLE_NAME = "NETWEAVE_RELIABLE"
local UNRELIABLE_NAME = "NETWEAVE_UNRELIABLE"
local WAIT_TIMEOUT = 30

--[=[
	@interface Link
	@within Link
	.send (reliable: boolean, destination: any, packed: buffer, instances: { Instance }) -> ()
	.sendAll (reliable: boolean, packed: buffer, instances: { Instance }) -> ()
	.receive ((packed: buffer, instances: { Instance }, sender: any?) -> ()) -> ()

	`destination` is the recipient on the server and ignored on the client, where there is only one
	place to send. `sendAll` is server-only; on the client it is the same as `send`.

	`sender` is the player on the server and nil on the client — the server does not need to be
	identified, and pretending it can be would invite a check that means nothing.
]=]
export type Link = {
	send: (reliable: boolean, destination: any, packed: buffer, instances: { Instance }) -> (),
	sendAll: (reliable: boolean, packed: buffer, instances: { Instance }) -> (),
	receive: ((packed: buffer, instances: { Instance }, sender: any?) -> ()) -> (),
}

local function remoteFolder(): Folder
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	if game:GetService("RunService"):IsServer() then
		local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)

		if existing then
			return existing :: Folder
		end

		local folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = ReplicatedStorage

		return folder
	end

	local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, WAIT_TIMEOUT) :: Folder
	assert(folder, "netweave remotes never replicated to the client")

	return folder
end

local function remote(folder: Folder, name: string, unreliable: boolean): any
	if game:GetService("RunService"):IsServer() then
		local existing = folder:FindFirstChild(name)

		if existing then
			return existing
		end

		local created = Instance.new(if unreliable then "UnreliableRemoteEvent" else "RemoteEvent")
		created.Name = name
		created.Parent = folder

		return created
	end

	local found = folder:WaitForChild(name, WAIT_TIMEOUT)
	assert(found, `netweave remote "{name}" never replicated`)

	return found
end

--[=[
	@within Link
	@function roblox
	@return Link

	Builds the real link. Creates the remotes on the server and waits for them on the client.

	Calling this outside Roblox fails, which is correct — a test wants a loopback link, not a
	pretend `RemoteEvent`.
]=]
function Link.roblox(): Link
	local folder = remoteFolder()
	local reliable = remote(folder, RELIABLE_NAME, false)
	local unreliable = remote(folder, UNRELIABLE_NAME, true)
	local isServer = game:GetService("RunService"):IsServer()

	return {
		send = function(useReliable: boolean, destination: any, packed: buffer, instances: { Instance })
			local channel = if useReliable then reliable else unreliable

			if isServer then
				channel:FireClient(destination, packed, instances)
			else
				channel:FireServer(packed, instances)
			end
		end,

		sendAll = function(useReliable: boolean, packed: buffer, instances: { Instance })
			local channel = if useReliable then reliable else unreliable

			if isServer then
				channel:FireAllClients(packed, instances)
			else
				channel:FireServer(packed, instances)
			end
		end,

		receive = function(handler: (packed: buffer, instances: { Instance }, sender: any?) -> ())
			if isServer then
				local function onServer(player: Player, packed: any, instances: any)
					--[[ Both arguments come from a client and are whatever it chose to send. A
					     wrong type here is a hostile peer, not a bug, so it is dropped rather
					     than passed on to be discovered inside the decoder. ]]
					if type(packed) == "buffer" then
						handler(packed, if type(instances) == "table" then instances else {}, player)
					end
				end

				reliable.OnServerEvent:Connect(onServer)
				unreliable.OnServerEvent:Connect(onServer)
			else
				local function onClient(packed: any, instances: any)
					if type(packed) == "buffer" then
						handler(packed, if type(instances) == "table" then instances else {}, nil)
					end
				end

				reliable.OnClientEvent:Connect(onClient)
				unreliable.OnClientEvent:Connect(onClient)
			end
		end,
	}
end

return Link
