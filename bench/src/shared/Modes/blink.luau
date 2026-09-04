--!strict
--!optimize 2

--[[
	Blink 0.18.8 adapter.

	`FlagIdiomatic` uses Blink's `set` type, which packs flags into a bitfield at up to 32 per
	word, so the payload nests them under `flags`. `FlagNaive` keeps twelve separate booleans.
	Both variants are measured because a Blink author would reach for `set` and benchmarking
	only the naive form would be a strawman (PLAN-M0 D-7, RESEARCH §3.9-AA).

	Blink batches into one buffer and flushes on `Heartbeat` unless `ManualReplication` is set;
	our schema leaves it automatic, so `flush` is nil.
]]

local RunService = game:GetService("RunService")

local Modes = require(script.Parent)
local Payloads = require(script.Parent.Parent.Payloads)

type Adapter = Modes.Adapter
type SchemaName = Modes.SchemaName
type Direction = Modes.Direction

local VERSION = "0.18.8"

local function toBlinkFlags(flags: Payloads.Flags, nested: boolean): any
	local weapon = Payloads.WEAPONS[flags.weapon + 1]
	local team = Payloads.TEAMS[flags.team + 1]

	if not nested then
		local flat = table.clone(flags) :: any
		flat.weapon = weapon
		flat.team = team
		return flat
	end

	local packed = {} :: any
	for index = 1, Payloads.FLAG_COUNT do
		local key = `f{index}`
		packed[key] = (flags :: any)[key]
	end

	return {
		flags = packed,
		weapon = weapon,
		team = team,
		targetId = flags.targetId,
		combo = flags.combo,
	}
end

return function(canonical): Adapter
	local vendor = Modes.vendor()
	local blinkFolder = vendor:FindFirstChild("blink")
	assert(blinkFolder, "blink vendor folder is missing; run bench/schemas/generate.luau")

	local isServer = RunService:IsServer()
	local module = blinkFolder:FindFirstChild(if isServer then "Server" else "Client")
	assert(module, `blink {if isServer then "Server" else "Client"} module is missing`)

	local blink = require(module) :: any

	local payloads = {
		ArrayHeavy = canonical.ArrayHeavy,
		FlagIdiomatic = toBlinkFlags(canonical.FlagIdiomatic, true),
		FlagNaive = toBlinkFlags(canonical.FlagNaive, false),
	}

	local function event(schema: SchemaName, direction: Direction): any
		local name = `{schema}{direction}`
		local handle = blink[name]
		assert(handle, `blink has no event "{name}"`)
		return handle
	end

	return {
		name = "blink",
		version = VERSION,
		payloads = payloads,

		bindFire = function(schema, direction, player)
			local fire = event(schema, direction).Fire

			if isServer then
				assert(player, "server-side Blink fire needs a recipient")
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
			event(schema, direction).On(function(...)
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
