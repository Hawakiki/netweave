--!strict
export type Type<T> = { kind: string, __payload: T }

-- (a) bounded generic for a string literal
local function literalA<V>(value: V & string): Type<V>
	return { kind = "literal", __payload = value :: any }
end
local a = literalA("v3")
local _a: Type<"v3"> = a

-- (b) type function reporting what it sees for an absent optional argument
-- selene: allow(undefined_variable)
type function Tag(default)
	return types.singleton(default.tag)
end
local function probe<D>(default: D?): Type<Tag<D>>
	return { kind = "probe", __payload = nil :: any }
end
local absent = probe()
local _absent: Type<"nil"> = absent
local present = probe(5)
local _present: Type<"number"> = present
