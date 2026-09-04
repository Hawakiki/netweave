--!strict

--[[
	Candidate A — the obvious signature.

	`struct` is generic over the field *value* type, which is what a combinator library writes
	when it has no way to talk about the shape of the table it was handed.

	Expected failure: Luau unifies `V` across all fields, so a struct of mixed types collapses to
	`{ [string]: number | string }` and the field names are gone.

	The payload type is extracted by calling `read` — Luau has no conditional types, so this is
	the only way to observe what `Schema<T>` was instantiated with.
]]

export type Schema<T> = {
	read: (b: buffer, cursor: number) -> (T, number),
	write: (value: T) -> (),
}

local function scalar<T>(): Schema<T>
	return (nil :: any) :: Schema<T>
end

--[[ Luau has no explicit type arguments at a call site, so the type is supplied by the
     annotation on the local and inferred backwards. ]]
local u8: Schema<number> = scalar()
local str: Schema<string> = scalar()

local function struct<V>(fields: { [string]: Schema<V> }): Schema<{ [string]: V }>
	return (nil :: any) :: Schema<{ [string]: V }>
end

local shot = struct({
	origin = u8,
	label = str,
})

local payload = shot.read(buffer.create(0), 0)

--[[ ASSERTION: we want this to hold. Expected to fail. ]]
local _named: { origin: number, label: string } = payload

--[[ ASSERTION: this is what we expect to get instead. ]]
local _collapsed: { [string]: number | string } = payload

return nil
