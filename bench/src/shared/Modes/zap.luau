--!strict
--!optimize 2

--[[
	Zap 0.6.29 adapter.

	Zap packs booleans, optional presence flags and small enum tags into a shared bitfield with
	no author involvement (RESEARCH §3.9-V2), so `FlagIdiomatic` and `FlagNaive` are written
	identically in `bench.zap` and reshape to the same value here. The two cells are kept so the
	table lines up column-for-column against Blink, where they differ.

	Zap batches into one buffer and flushes on `Heartbeat` unless `manual_event_loop` is set;
	our schema leaves it automatic, so `flush` is nil.

	Receivers are `SetCallback` rather than `On` because the schema declares `SingleSync`.
]]

local RunService = game:GetService("RunService")

local Modes = require(script.Parent)
local Payloads = require(script.Parent.Parent.Payloads)

type Adapter = Modes.Adapter
type SchemaName = Modes.SchemaName
type Direction = Modes.Direction

local VERSION = "0.6.29"

local function toZapFlags(flags: Payloads.Flags): any
	local flat = table.clone(flags) :: any
	flat.weapon = Payloads.WEAPONS[flags.weapon + 1]
	flat.team = Payloads.TEAMS[flags.team + 1]
	return flat
end

return function(canonical): Adapter
	local vendor = Modes.vendor()
	local zapFolder = vendor:FindFirstChild("zap")
	assert(zapFolder, "zap vendor folder is missing; run bench/schemas/generate.luau")

	local isServer = RunService:IsServer()
	local module = zapFolder:FindFirstChild(if isServer then "Server" else "Client")
	assert(module, `zap {if isServer then "Server" else "Client"} module is missing`)

	local zap = require(module) :: any

	local payloads = {
		ArrayHeavy = canonical.ArrayHeavy,
		FlagIdiomatic = toZapFlags(canonical.FlagIdiomatic),
		FlagNaive = toZapFlags(canonical.FlagNaive),
	}

	local function event(schema: SchemaName, direction: Direction): any
		local name = `{schema}{direction}`
		local handle = zap[name]
		assert(handle, `zap has no event "{name}"`)
		return handle
	end

	return {
		name = "zap",
		version = VERSION,
		payloads = payloads,

		bindFire = function(schema, direction, player)
			local fire = event(schema, direction).Fire

			if isServer then
				assert(player, "server-side Zap fire needs a recipient")
				return function(payload)
					fire(player, payload)
				end
			end

			return fire
		end,

		bindFireAll = if isServer
			then function(schema, direction)
				return event(schema, direction).FireAll
			end
			else nil,

		onReceive = function(schema, direction, callback)
			event(schema, direction).SetCallback(function(...)
				if isServer then
					local player, payload = ...
					callback(payload, player)
				else
					local payload = ...
					callback(payload, nil)
				end
			end)
		end,

		flush = nil,
	}
end
