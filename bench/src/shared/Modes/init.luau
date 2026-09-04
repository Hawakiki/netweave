--!strict
--!optimize 2

--[[
	Mode discovery.

	Every library under test is wrapped in an adapter exposing the same tiny interface. A mode
	whose vendored module is missing (netweave, until M1) is skipped rather than erroring, so
	the harness runs from day one with an empty netweave slot.

	Adapters are loaded with `pcall`: a library that fails to load is recorded as unavailable
	with its error, not silently dropped. Two of the five libraries surveyed ship a `master`
	that does not load at all (RESEARCH §3.6-B8, §3.7-J), so this is a real failure mode.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Payloads = require(script.Parent.Payloads)

export type SchemaName = "ArrayHeavy" | "FlagIdiomatic" | "FlagNaive"
export type Direction = "Up" | "Down"

export type Adapter = {
	name: string,
	version: string,

	--[[ This library's shape of each canonical payload, built once at load (PLAN-M0 R-3). ]]
	payloads: { [SchemaName]: any },

	--[[
		Returns the send function for one schema and direction, resolved outside the measured
		loop. On the server, `player` is the recipient. The returned function takes the payload
		and nothing else, matching how Blink's own harness binds `Event.Fire` once up front.
	]]
	bindFire: (schema: SchemaName, direction: Direction, player: Player?) -> (payload: any) -> (),

	--[[ Server-only broadcast, or nil if the library has no fan-out primitive. ]]
	bindFireAll: ((schema: SchemaName, direction: Direction) -> (payload: any) -> ())?,

	--[[ `player` is nil when receiving on the client. ]]
	onReceive: (
		schema: SchemaName,
		direction: Direction,
		callback: (payload: any, player: Player?) -> ()
	) -> (),

	--[[ Batching libraries flush here; nil for libraries that send immediately. ]]
	flush: (() -> ())?,
}

export type ModeEntry = {
	name: string,
	available: boolean,
	adapter: Adapter?,
	error: string?,
}

local ADAPTER_NAMES = { "raw", "bytenet", "blink", "zap", "netweave" }

local Modes = {}

Modes.SCHEMAS = { "ArrayHeavy", "FlagIdiomatic", "FlagNaive" } :: { SchemaName }
Modes.DIRECTIONS = { "Up", "Down" } :: { Direction }

--[[
	The canonical payloads, shared by every adapter as the input to its own reshaping.
]]
Modes.canonical = {
	ArrayHeavy = Payloads.arrayHeavy(),
	FlagIdiomatic = Payloads.flags(),
	FlagNaive = Payloads.flags(),
}

function Modes.load(): { ModeEntry }
	local entries: { ModeEntry } = {}

	for _, name in ADAPTER_NAMES do
		local module = script:FindFirstChild(name)

		if not module then
			table.insert(entries, {
				name = name,
				available = false,
				error = "no adapter module",
			})
			continue
		end

		--[[ `xpcall` with a traceback: "this mode failed" is useless without knowing where. ]]
		local ok, result = xpcall(function()
			return (require(module) :: any)(Modes.canonical)
		end, function(err)
			return tostring(err) .. "\n" .. debug.traceback("", 2)
		end)

		if ok then
			table.insert(entries, { name = name, available = true, adapter = result })
		else
			table.insert(entries, { name = name, available = false, error = tostring(result) })
		end
	end

	return entries
end

--[[ Names of the modes that loaded, in `ADAPTER_NAMES` order. ]]
function Modes.availableNames(entries: { ModeEntry }): { string }
	local names = {}

	for _, entry in entries do
		if entry.available then
			table.insert(names, entry.name)
		end
	end

	return names
end

--[[ Vendored library modules live under `ReplicatedStorage.Shared.Vendor`. ]]
function Modes.vendor(): Folder
	return ReplicatedStorage.Shared.Vendor :: Folder
end

return Modes
