--!strict

--[[
	Candidate C — user-defined type functions.

	Luau's new solver added `type function`, which runs at analysis time and can take a type
	apart and build a new one. If it can reflect over a table type's properties it does what a
	mapped type would: turn `{ origin: Schema<number>, label: Schema<string> }` into
	`{ origin: number, label: string }`.

	This is the only candidate that keeps per-field types without the author restating them, so
	it decides whether `DESIGN-API.md` §1 survives as written.

	Note: `type function` is rejected outright unless `LuauSolverV2` is enabled. That is an
	adoption constraint, not a detail — see the verdict in `docs/DESIGN-API.md`.
]]

export type Schema<T> = {
	read: (b: buffer, cursor: number) -> (T, number),
	write: (value: T) -> (),
}

--[[
	Extracts `T` out of `Schema<T>` by reading the first return of its `read` member.
]]
type function Payload(schema)
	local read = schema:readproperty(types.singleton("read"))
	return read:returns().head[1]
end

--[[
	Maps a table of schemas to a table of their payloads.
]]
type function StructPayload(fields)
	local result = types.newtable()

	for key, property in fields:properties() do
		local schema = property.read
		local read = schema:readproperty(types.singleton("read"))
		result:setproperty(key, read:returns().head[1])
	end

	return result
end

--[[
	Scalars are concrete values in the real library, not calls to a generic factory. The new
	solver does not push a local's annotation into a generic call's return, so `scalar()` would
	infer `Schema<unknown>` — an artifact of the stub, not of the design.
]]
local u8 = (nil :: any) :: Schema<number>
local str = (nil :: any) :: Schema<string>

--[[ ASSERTION 1: a single schema's payload can be read back out. ]]
local _single: Payload<Schema<number>> = 1

local fields = {
	origin = u8,
	label = str,
}

--[[ ASSERTION 2: the mapped payload keeps both field names and both types. ]]
local _named: StructPayload<typeof(fields)> = (nil :: any) :: { origin: number, label: string }

--[[ ASSERTION 3: a wrong field type is rejected. This one must error. ]]
local _wrong: StructPayload<typeof(fields)> = (nil :: any) :: { origin: string, label: string }

return nil
