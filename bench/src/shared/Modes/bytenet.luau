--!strict
--!optimize 2

--[[
	ByteNet 0.4.3 adapter.

	0.4.3 rather than `master`: master requires three modules that do not exist in the
	repository, so it cannot load at all (RESEARCH §3.6-B8). The vendored copy is the `v0.4.3`
	tag, recorded in `_refsrc/README.md`.

	ByteNet has no enum type and no bitfield type, so `weapon` and `team` are `uint8` and the
	idiomatic and naive flag variants are identical — the canonical payload is used unchanged.
	That is what a ByteNet author would actually write, which is the point of PLAN-M0 D-7.

	Unlike Blink and Zap, the schema is declared here in Luau rather than generated, because
	ByteNet is a runtime-schema library. The declaration order matters: packet ids are assigned
	by iteration order inside `defineNamespace`, so both peers must build the namespace the
	same way.

	Listener callbacks receive `(data, player)` — data first. This is the opposite of every
	other library here and is the reason Blink's own harness swaps its arguments for ByteNet.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modes = require(script.Parent)
local Payloads = require(script.Parent.Parent.Payloads)

type Adapter = Modes.Adapter
type SchemaName = Modes.SchemaName
type Direction = Modes.Direction

local VERSION = "0.4.3"
local NAMESPACE = "netweaveBench"
local WAIT_TIMEOUT = 30

return function(canonical): Adapter
	local vendor = Modes.vendor()
	local module = vendor:FindFirstChild("bytenet")
	assert(module, "bytenet vendor folder is missing")

	local ByteNet = require(module) :: any
	local isServer = RunService:IsServer()

	--[[
		ByteNet replicates the namespace packet-id table as JSON in a StringValue, and the client
		reads it with `FindFirstChild` rather than `WaitForChild`, without checking that the server
		has written to it yet (`replicated/values.luau`, `replicated/replicatedValue.luau`). A client
		that calls `defineNamespace` first fails with a bare "Argument 1 missing or nil" out of
		`JSONDecode("")`.

		That is a race in ByteNet, not in the harness, so wait it out rather than reporting the mode
		as broken.
	]]
	if not isServer then
		local storage = ReplicatedStorage:WaitForChild("BytenetStorage", WAIT_TIMEOUT) :: Folder
		assert(storage, "ByteNet never created its storage folder")

		local published = storage:WaitForChild(NAMESPACE, WAIT_TIMEOUT) :: StringValue
		assert(published, `ByteNet namespace "{NAMESPACE}" never replicated`)

		local deadline = os.clock() + WAIT_TIMEOUT
		while published.Value == "" and os.clock() < deadline do
			task.wait()
		end

		assert(published.Value ~= "", `ByteNet namespace "{NAMESPACE}" replicated but stayed empty`)
	end

	local function flagFields()
		local fields = {
			weapon = ByteNet.uint8,
			team = ByteNet.uint8,
			targetId = ByteNet.optional(ByteNet.uint16),
			combo = ByteNet.optional(ByteNet.uint8),
		}

		for index = 1, Payloads.FLAG_COUNT do
			fields[`f{index}`] = ByteNet.bool
		end

		return fields
	end

	--[[
		Both structs are created inside the callback, and exactly once each.

		`ByteNet.struct` is not a pure constructor: on the server it appends to the namespace's
		dependency list, and on the client it looks its own definition up by creation index in the
		replicated namespace data (`dataTypes/struct.luau:55-71`). Calling it outside
		`defineNamespace` leaves `namespacesDependencies.currentName()` nil and fails with a bare
		"Argument 1 missing or nil". Calling it a different number of times on each peer would
		shift every struct index.

		Packet ids come from iterating the returned table, so both peers must also agree on that
		order. They do because both build the identical literal and Luau hashes the same keys the
		same way — ByteNet's own assumption, not something this adapter can enforce.
	]]
	local namespace = ByteNet.defineNamespace(NAMESPACE, function()
		local entity = ByteNet.struct({
			id = ByteNet.uint8,
			x = ByteNet.uint8,
			y = ByteNet.uint8,
			z = ByteNet.uint8,
			orientation = ByteNet.uint8,
			animation = ByteNet.uint8,
		})

		local flags = ByteNet.struct(flagFields())
		local entities = ByteNet.array(entity)

		return {
			ArrayHeavyDown = ByteNet.definePacket({ value = entities }),
			ArrayHeavyUp = ByteNet.definePacket({ value = entities }),
			FlagIdiomaticDown = ByteNet.definePacket({ value = flags }),
			FlagIdiomaticUp = ByteNet.definePacket({ value = flags }),
			FlagNaiveDown = ByteNet.definePacket({ value = flags }),
			FlagNaiveUp = ByteNet.definePacket({ value = flags }),
		}
	end)

	local function packet(schema: SchemaName, direction: Direction): any
		local name = `{schema}{direction}`
		local handle = namespace[name]
		assert(handle, `bytenet has no packet "{name}"`)
		return handle
	end

	return {
		name = "bytenet",
		version = VERSION,
		payloads = {
			ArrayHeavy = canonical.ArrayHeavy,
			FlagIdiomatic = canonical.FlagIdiomatic,
			FlagNaive = canonical.FlagNaive,
		},

		bindFire = function(schema, direction, player)
			local handle = packet(schema, direction)

			if isServer then
				assert(player, "server-side ByteNet send needs a recipient")
				local sendTo = handle.sendTo
				return function(payload)
					sendTo(payload, player)
				end
			end

			return handle.send
		end,

		bindFireAll = if isServer
			then function(schema, direction)
				return packet(schema, direction).sendToAll
			end
			else nil,

		onReceive = function(schema, direction, callback)
			packet(schema, direction).listen(function(payload, player)
				callback(payload, player)
			end)
		end,

		flush = nil,
	}
end
