--!strict

--[[
	Candidate E — the three things `src/types/` is about to be built on.

	Candidate C proved a `type function` can map a table of schemas to a table of payloads. That
	is not yet enough to write `t.struct(...)`, because three questions remain:

	  E1  Can a *generic function* return a type-function-applied type? `struct<F>(fields: F)`
	      has to yield `Type<StructPayload<F>>`, with `F` inferred from the call site.
	  E2  Can a scalar be both a bare value and a callable that applies a range?
	      `DESIGN-API.md` uses `t.u16` and `t.u8(0, 2)` in the same declaration.
	  E3  Do singleton strings survive into an enum's payload type, and in what shape does the
	      author have to write the variants for that to happen?

	Each is answered by an assignment that either type-checks or does not. Lines marked MUST FAIL
	are the negative controls: if they stop erroring, the mechanism has silently stopped working.
]]

export type Type<T> = {
	kind: string,
	--[[ Phantom. Never populated at runtime; exists so type functions can read `T` back out. ]]
	__payload: T,
}

type function StructPayload(fields)
	local result = types.newtable()

	for key, property in fields:properties() do
		local field = property.read

		if not field then
			error("struct field has no readable type")
		end

		local payload = field:readproperty(types.singleton("__payload"))

		if not payload then
			error("struct field is not a netweave type")
		end

		result:setproperty(key, payload)
	end

	return result
end

type function EnumPayload(variants)
	local result = nil

	for key in variants:properties() do
		result = if result then types.unionof(result, key) else key
	end

	if not result then
		error("enum needs at least one variant")
	end

	return result
end

local u8 = (nil :: any) :: Type<number>
local u16 = (nil :: any) :: Type<number>
local str = (nil :: any) :: Type<string>

-- ---------------------------------------------------------------------------------------------
-- E1: generic function returning a type-function-applied type
-- ---------------------------------------------------------------------------------------------

local function struct<F>(_fields: F): Type<StructPayload<F>>
	return (nil :: any) :: Type<StructPayload<F>>
end

local shot = struct({
	origin = u8,
	label = str,
})

local _e1_ok: Type<{ origin: number, label: string }> = shot

--[[ MUST FAIL: wrong field type ]]
local _e1_bad: Type<{ origin: string, label: string }> = shot

-- Plain generics, no type function needed.

local function array<E>(_element: Type<E>): Type<{ E }>
	return (nil :: any) :: Type<{ E }>
end

local function optional<E>(_inner: Type<E>): Type<E?>
	return (nil :: any) :: Type<E?>
end

local function map<K, V>(_key: Type<K>, _value: Type<V>): Type<{ [K]: V }>
	return (nil :: any) :: Type<{ [K]: V }>
end

local _e1_array: Type<{ number }> = array(u8)
local _e1_optional: Type<number?> = optional(u16)
local _e1_map: Type<{ [string]: number }> = map(str, u8)

--[[ MUST FAIL: array of numbers is not an array of strings ]]
local _e1_arrayBad: Type<{ string }> = array(u8)

--[[ Nesting: a struct inside an array inside a struct. ]]
local nested = struct({
	entities = array(struct({
		id = u8,
		tag = str,
	})),
})

local _e1_nested: Type<{ entities: { { id: number, tag: string } } }> = nested

-- ---------------------------------------------------------------------------------------------
-- E2: a scalar that is both a value and a callable
-- ---------------------------------------------------------------------------------------------

type Ranged<T> = typeof(setmetatable(
	{} :: Type<T>,
	{} :: { __call: (self: any, min: number, max: number) -> Type<T> }
))

local rangedU8 = (nil :: any) :: Ranged<number>

--[[ Used bare, it has to be accepted anywhere a `Type<number>` is. ]]
local _e2_bare: Type<number> = rangedU8

--[[ Called, it has to produce a constrained type of the same payload. ]]
local _e2_called: Type<number> = rangedU8(0, 10)

--[[ And it has to survive being a struct field, which is the whole point. ]]
local ranged = struct({
	slot = rangedU8,
	pitch = rangedU8(-90, 90),
})

local _e2_struct: Type<{ slot: number, pitch: number }> = ranged

-- ---------------------------------------------------------------------------------------------
-- E3: enum variants as singleton strings
-- ---------------------------------------------------------------------------------------------

--[[
	Written as a set rather than an array: Luau widens `{"a", "b"}` to `{string}`, but a table
	literal's *keys* stay singletons. Wire order comes from sorting the names, never from table
	iteration order (`WIRE-FORMAT.md` §3).
]]
local function enumOf<V>(_variants: V): Type<EnumPayload<V>>
	return (nil :: any) :: Type<EnumPayload<V>>
end

local weapon = enumOf({
	primary = true,
	secondary = true,
	melee = true,
})

local _e3_ok: Type<"primary" | "secondary" | "melee"> = weapon

--[[ MUST FAIL: `grenade` was never declared ]]
local _e3_bad: Type<"primary" | "grenade"> = weapon

--[[ For comparison: the array form, expected to widen to plain `string`. ]]
local function enumArray<V>(_variants: { V }): Type<V>
	return (nil :: any) :: Type<V>
end

local weaponArray = enumArray({ "primary", "secondary" })
local _e3_widened: Type<string> = weaponArray

return nil
