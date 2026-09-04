--!strict
--!optimize 2

--[[
	Raw `RemoteEvent` control.

	No schema, no serialization: the canonical table goes straight onto the wire and Roblox's
	own replication encodes it. This is the floor every library has to beat, and the only mode
	whose cost is not under anyone's control.

	Because there is no schema, the idiomatic and naive flag variants are the same table. That
	is itself a result worth showing — raw pays the same either way, so the entire spread
	between those two columns for Blink is self-inflicted by schema authoring.

	One RemoteEvent per schema and direction, rather than one shared remote with a type tag.
	A tag would be a serialization scheme, which is exactly what this mode is meant not to have.

	`bindFire` returns a closure because `FireServer` is a method and needs its receiver. Blink's
	own harness does the same for its raw mode, so the extra call is present in both baselines.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modes = require(script.Parent)

type Adapter = Modes.Adapter
type SchemaName = Modes.SchemaName
type Direction = Modes.Direction

local FOLDER_NAME = "RawRemotes"
local WAIT_TIMEOUT = 30

local function serverFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if existing then
		return existing :: Folder
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = ReplicatedStorage
	return folder
end

local function serverRemote(folder: Folder, name: string): RemoteEvent
	local existing = folder:FindFirstChild(name)
	if existing then
		return existing :: RemoteEvent
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder
	return remote
end

return function(canonical): Adapter
	local isServer = RunService:IsServer()
	local folder: Folder

	if isServer then
		folder = serverFolder()
		for _, schema in Modes.SCHEMAS do
			for _, direction in Modes.DIRECTIONS do
				serverRemote(folder, `{schema}{direction}`)
			end
		end
	else
		folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, WAIT_TIMEOUT) :: Folder
		assert(folder, "raw remotes never replicated to the client")
	end

	local function remote(schema: SchemaName, direction: Direction): RemoteEvent
		local name = `{schema}{direction}`
		local instance = if isServer
			then folder:FindFirstChild(name)
			else folder:WaitForChild(name, WAIT_TIMEOUT)
		assert(instance, `raw remote "{name}" is missing`)
		return instance :: RemoteEvent
	end

	return {
		name = "raw",
		version = "RemoteEvent",
		payloads = {
			ArrayHeavy = canonical.ArrayHeavy,
			FlagIdiomatic = canonical.FlagIdiomatic,
			FlagNaive = canonical.FlagNaive,
		},

		bindFire = function(schema, direction, player)
			local instance = remote(schema, direction)

			if isServer then
				assert(player, "server-side raw fire needs a recipient")
				return function(payload)
					instance:FireClient(player, payload)
				end
			end

			return function(payload)
				instance:FireServer(payload)
			end
		end,

		bindFireAll = if isServer
			then function(schema, direction)
				local instance = remote(schema, direction)
				return function(payload)
					instance:FireAllClients(payload)
				end
			end
			else nil,

		onReceive = function(schema, direction, callback)
			local instance = remote(schema, direction)

			if isServer then
				instance.OnServerEvent:Connect(function(player, payload)
					callback(payload, player)
				end)
			else
				instance.OnClientEvent:Connect(function(payload)
					callback(payload, nil)
				end)
			end
		end,

		flush = nil,
	}
end
