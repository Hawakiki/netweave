--!strict

--[[
	Candidate B — the payload type is named by the author, the schema is checked against it.

	`structOf<T>` takes the payload type as an explicit type argument. The question is whether
	the field table can be constrained to actually match `T`, or whether this degenerates into a
	cast that lets a mismatched schema through silently.

	If B is the answer, `DESIGN-API.md` §1 changes meaning: netweave stops *deriving* the payload
	type and starts *checking* the schema against a type the author wrote. Still one source of
	truth for validation and serdes, but the type is no longer free.
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

type Shot = {
	origin: number,
	label: string,
}

--[[
	Attempt 1: no relationship between the fields and `T` at all. Compiles anything.
]]
local function structOf<T>(_fields: { [string]: Schema<any> }): Schema<T>
	return (nil :: any) :: Schema<T>
end

local shot: Schema<Shot> = structOf({
	origin = u8,
	label = str,
})

local payload = shot.read(buffer.create(0), 0)

--[[ ASSERTION: should hold — the type was supplied by hand. ]]
local _named: Shot = payload

--[[
	ASSERTION: this SHOULD be an error but almost certainly is not. A schema that does not match
	the declared type is accepted, which is the whole weakness of candidate B.
]]
local wrong: Schema<Shot> = structOf({
	origin = str,
	nothingLikeShot = u8,
})
local _wrong: Shot = wrong.read(buffer.create(0), 0)

return nil
