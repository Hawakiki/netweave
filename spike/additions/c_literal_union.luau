--!strict
export type Type<T> = { kind: string, __payload: T }

local function literal<V>(value: V & (string | boolean | number)): Type<V>
	return { kind = "literal", __payload = value :: any }
end
local a = literal("v3")
local _a: Type<"v3"> = a
local b = literal(true)
local _b: Type<true> = b
local c = literal(7)
local _c: Type<number> = c
local _bad = literal({}) -- expect an error: a table is not a literal
