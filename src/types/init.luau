--!strict
--!optimize 2

--[=[
	@class Types

	The type vocabulary. One declaration yields the payload type, the validation, and the
	serialisation — you never write a schema and a type guard that can drift apart.

	```lua
	local t = require(Packages.netweave).types

	local Shot = t.struct({
		origin = t.vector3,
		direction = t.unitVector3,
		seq = t.u16,
	})
	-- Shot : Type<{ origin: Vector3, direction: Vector3, seq: number }>
	```

	Constraints live inside the type rather than beside it. `t.f32(-90, 90)` is a pitch, and the
	codec derives both the range check and a narrower encoding from that one expression.

	:::caution
	Payload inference needs Luau's new type solver. Without it the library still loads and runs,
	but nothing here is checked. See `docs/DESIGN-API.md` §7.
	:::
]=]

--[[
	A type is inert. It computes nothing and encodes nothing; the codec lowers it to an IR and runs
	the layout passes over that (`PLAN-M1` D-1). Keeping it inert is what creates the layout window
	at all — ByteNet builds closures straight from the schema and so can never see two fields at
	once (`RESEARCH §3.8-N`).
]]

--[=[
	@type Encoding "u8" | "u16" | "u32" | "i8" | "i16" | "i32" | "f32" | "f64"
	@within Types

	Storage width for a number, and the component width of a vector.

	This is an upper bound, not a promise: a range narrower than the encoding lets the codec store
	fewer bytes and subtract the minimum, so `t.u16(1000, 1255)` occupies one byte on the wire.
]=]
export type Encoding = "u8" | "u16" | "u32" | "i8" | "i16" | "i32" | "f32" | "f64"

--[=[
	@type Kind "boolean" | "number" | "string" | "buffer" | "vector2" | "vector3" | "cframe" | "color3" | "instance" | "enum" | "optional" | "array" | "map" | "struct"
	@within Types

	What a descriptor describes. The codec dispatches on this.
]=]
export type Kind =
	"boolean"
	| "number"
	| "string"
	| "buffer"
	| "vector2"
	| "vector3"
	| "cframe"
	| "color3"
	| "instance"
	| "enum"
	| "optional"
	| "array"
	| "map"
	| "struct"

--[=[
	@interface Descriptor
	@within Types
	.kind Kind
	.encoding Encoding? -- numbers, and vector components
	.min number? -- value range for numbers, length range for strings, buffers and arrays
	.max number?
	.class string? -- `instance`: the class an arrival must be, or nil for any
	.variants { string }? -- `enum`: variant names, sorted. Wire index is the position here
	.unit boolean? -- `vector3`: the magnitude must be 1
	.inner Descriptor? -- `optional`
	.element Descriptor? -- `array`
	.key Descriptor? -- `map`
	.value Descriptor? -- `map`
	.fields { [string]: Descriptor }? -- `struct`
	.order { string }? -- `struct`: field names, sorted. Wire order is the order here

	An untyped type. Most fields are unused by most kinds; the codec reads only the ones its
	`kind` implies.
]=]
export type Descriptor = {
	kind: Kind,
	encoding: Encoding?,
	min: number?,
	max: number?,
	class: string?,
	variants: { string }?,
	unit: boolean?,
	inner: Descriptor?,
	element: Descriptor?,
	key: Descriptor?,
	value: Descriptor?,
	fields: { [string]: Descriptor }?,
	order: { string }?,
}

--[=[
	@type Type<T> Descriptor & { __payload: T }
	@within Types

	A descriptor carrying the payload type it decodes to. `__payload` is a phantom: never assigned
	at runtime, never read at runtime, present so a `type function` can pull `T` back out.
]=]
--[[
	`Descriptor` and `Type<T>` duplicate their fields on purpose, and must stay in sync.

	Luau refuses a recursive type instantiated at different parameters, so `Type<T>` cannot both be
	generic and refer to itself for its children. Expressing it as `Descriptor & { __payload: T }`
	does compile, but breaks two things verified working in `spike/inference/`: a metatable-wrapped
	table stops being a subtype of the intersection, so `t.u8` is no longer usable where a
	`Type<number>` is expected; and `readproperty` inside a `type function` can no longer see
	through it, so `t.struct` stops inferring. A flat duplicate keeps both.

	`tests/types_ok.luau` asserts the two stay structurally compatible, so drift is a build break
	rather than a surprise.
]]
export type Type<T> = {
	kind: Kind,
	encoding: Encoding?,
	min: number?,
	max: number?,
	class: string?,
	variants: { string }?,
	unit: boolean?,
	inner: Descriptor?,
	element: Descriptor?,
	key: Descriptor?,
	value: Descriptor?,
	fields: { [string]: Descriptor }?,
	order: { string }?,
	__payload: T,
}

--[=[
	@type PayloadOf<T> T
	@within Types

	Extracts the payload type out of a `Type<T>`.

	```lua
	type Shot = t.PayloadOf<typeof(ShotType)>
	```
]=]
export type function PayloadOf(ty)
	local payload = ty:readproperty(types.singleton("__payload"))

	if not payload then
		error("expected a netweave type")
	end

	return payload
end

--[=[
	@type StructPayload<F> F
	@within Types

	Maps a table of types to a table of their payloads. This is what lets [Types.struct] infer its
	own result.

	Rarely written by hand — `t.struct` applies it for you.
]=]
--[[
	Luau has no mapped types, so without this a heterogeneous struct cannot even be expressed: the
	naive `struct<V>(fields: { [string]: Type<V> })` signature unifies `V` across fields and
	rejects `{ id = t.u8, name = t.string }` outright (`spike/inference/README.md`, Q1 candidate A).
]]
export type function StructPayload(fields)
	local result = types.newtable()

	for key, property in fields:properties() do
		local field = property.read

		if not field or not field:is("table") then
			error("a struct field is not a netweave type")
		end

		local payload = field:readproperty(types.singleton("__payload"))

		if not payload then
			error("a struct field is not a netweave type")
		end

		result:setproperty(key, payload)
	end

	return result
end

--[=[
	@type EnumPayload<V> V
	@within Types

	Turns a set of variant names into a union of string singletons. Applied by [Types.enum].
]=]
--[[
	The variants have to be written as table *keys* because Luau widens `{"a", "b"}` to `{string}`,
	losing exactly the information this exists to preserve.
]]
export type function EnumPayload(variants)
	local result = nil

	for key in variants:properties() do
		result = if result then types.unionof(result, key) else key
	end

	if not result then
		error("an enum needs at least one variant")
	end

	return result
end

--[=[
	@type Ranged<T> Type<T>
	@within Types

	A type that is usable bare and callable to constrain it. Both forms appear in the same
	declaration:

	```lua
	seq = t.u16,           -- the encoding's full range
	slot = t.u8(0, 2),     -- narrowed, and stored in fewer bits
	```

	The pair means a **value** range for numbers and a **length** range for strings and buffers.
]=]
export type Ranged<T> = typeof(setmetatable(
	{} :: Type<T>,
	{} :: { __call: (self: any, min: number, max: number) -> Type<T> }
))

--[=[
	@type Classed Type<Instance>
	@within Types

	An instance type, callable with a class name to restrict what may arrive.
]=]
export type Classed = typeof(setmetatable(
	{} :: Type<Instance>,
	{} :: { __call: (self: any, className: string) -> Type<Instance> }
))

local ENCODING_RANGE: { [string]: { min: number, max: number } } = {
	u8 = { min = 0, max = 255 },
	u16 = { min = 0, max = 65535 },
	u32 = { min = 0, max = 4294967295 },
	i8 = { min = -128, max = 127 },
	i16 = { min = -32768, max = 32767 },
	i32 = { min = -2147483648, max = 2147483647 },
	f32 = { min = -16777216, max = 16777216 },
	f64 = { min = -(2 ^ 53), max = 2 ^ 53 },
}

local MAX_LENGTH = 65535

--[[ Declaring a schema is programmer territory, so it throws. Wire data never reaches here. ]]
local function check(condition: boolean, message: string)
	if not condition then
		error(`[netweave] {message}`, 3)
	end
end

--[[
	Returns `any` on purpose. The new solver does not push a call site's expected type into a
	generic return (`spike/inference/README.md`), so a `descriptor<T>` would infer `Type<unknown>`
	and every constructor would have to cast twice. Each public constructor states its own return
	type instead, which is where the type belongs to be read anyway.
]]
local function descriptor(fields: { [string]: any }): any
	return table.freeze(fields)
end

local function sortedKeys(source: { [string]: any }): { string }
	local keys = {}

	for key in source do
		table.insert(keys, key)
	end

	table.sort(keys)
	return table.freeze(keys)
end

--[[
	Bare and callable share one descriptor, so `t.u8` and `t.u8(0, 10)` describe the same kind. The
	constrained form is a fresh frozen copy; nothing is mutated after definition.
]]
local function ranged(base: { [string]: any }, label: string): any
	local self = table.clone(base)

	local callable = setmetatable(
		self,
		table.freeze({
			__call = function(_self: any, min: number, max: number): any
				check(type(min) == "number", `{label} range needs a numeric minimum`)
				check(type(max) == "number", `{label} range needs a numeric maximum`)
				check(min <= max, `{label} range has min {min} above max {max}`)
				check(
					min >= base.min and max <= base.max,
					`{label} range {min}..{max} is outside {base.min}..{base.max}`
				)

				local constrained = table.clone(base)
				constrained.min = min
				constrained.max = max
				return descriptor(constrained)
			end,
		})
	)

	return table.freeze(callable)
end

local t = {}

local function number(encoding: Encoding): any
	local bounds = ENCODING_RANGE[encoding]
	return ranged({
		kind = "number" :: Kind,
		encoding = encoding,
		min = bounds.min,
		max = bounds.max,
	}, encoding)
end

--[=[
	@prop u8 Ranged<number>
	@within Types
	An integer in `0..255`. `t.u8(0, 10)` narrows it further.
]=]
t.u8 = number("u8") :: Ranged<number>

--[=[
	@prop u16 Ranged<number>
	@within Types
	An integer in `0..65535`.
]=]
t.u16 = number("u16") :: Ranged<number>

--[=[
	@prop u32 Ranged<number>
	@within Types
	An integer in `0..4294967295`.
]=]
t.u32 = number("u32") :: Ranged<number>

--[=[
	@prop i8 Ranged<number>
	@within Types
	A signed integer in `-128..127`.
]=]
t.i8 = number("i8") :: Ranged<number>

--[=[
	@prop i16 Ranged<number>
	@within Types
	A signed integer in `-32768..32767`.
]=]
t.i16 = number("i16") :: Ranged<number>

--[=[
	@prop i32 Ranged<number>
	@within Types
	A signed integer in `-2147483648..2147483647`.
]=]
t.i32 = number("i32") :: Ranged<number>

--[=[
	@prop f32 Ranged<number>
	@within Types
	A single-precision float. A range on a float validates but never narrows the storage.
]=]
t.f32 = number("f32") :: Ranged<number>

--[=[
	@prop f64 Ranged<number>
	@within Types
	A double-precision float.
]=]
t.f64 = number("f64") :: Ranged<number>

--[=[
	@prop boolean Type<boolean>
	@within Types

	One bit, not one byte. Booleans, optional presence markers and small enum tags share a bitfield
	per struct, so twelve of these cost two bytes rather than twelve.
]=]
t.boolean = descriptor({ kind = "boolean" :: Kind }) :: Type<boolean>

--[=[
	@prop string Ranged<string>
	@within Types

	A length-prefixed string, up to 65535 bytes. `t.string(0, 64)` bounds the length and shrinks
	the prefix.
]=]
t.string = ranged({
	kind = "string" :: Kind,
	min = 0,
	max = MAX_LENGTH,
}, "string") :: Ranged<string>

--[=[
	@prop buffer Ranged<buffer>
	@within Types
	A length-prefixed buffer, up to 65535 bytes.
]=]
t.buffer = ranged({
	kind = "buffer" :: Kind,
	min = 0,
	max = MAX_LENGTH,
}, "buffer") :: Ranged<buffer>

--[=[
	@prop vector2 Type<Vector2>
	@within Types
	Two `f32` components.
]=]
t.vector2 = descriptor({ kind = "vector2" :: Kind, encoding = "f32" :: Encoding }) :: Type<Vector2>

--[=[
	@prop vector3 Type<Vector3>
	@within Types
	Three `f32` components.
]=]
t.vector3 = descriptor({ kind = "vector3" :: Kind, encoding = "f32" :: Encoding }) :: Type<Vector3>

--[=[
	@prop unitVector3 Type<Vector3>
	@within Types

	A direction: a `Vector3` validated to unit length on arrival.

	This is the check a shooter would otherwise write by hand in every handler, and forgetting it
	once is how a client sends a 10,000-stud "direction".
]=]
t.unitVector3 = descriptor({
	kind = "vector3" :: Kind,
	encoding = "f32" :: Encoding,
	unit = true,
}) :: Type<Vector3>

--[=[
	@prop cframe Type<CFrame>
	@within Types
	Position and rotation.
]=]
t.cframe = descriptor({ kind = "cframe" :: Kind }) :: Type<CFrame>

--[=[
	@prop color3 Type<Color3>
	@within Types
	Three bytes.
]=]
t.color3 = descriptor({ kind = "color3" :: Kind }) :: Type<Color3>

--[=[
	@prop instance Classed
	@within Types

	An instance, carried alongside the buffer rather than in it. `t.instance("Sound")` rejects
	anything that is not a `Sound`.

	:::note
	The payload type stays `Instance` even when a class is named — Luau cannot resolve a class-name
	string to its type, so narrow it yourself if you need the specific class.
	:::
]=]
t.instance = (function(): Classed
	local base = { kind = "instance" :: Kind }
	local self = table.clone(base)

	local callable = setmetatable(
		self,
		table.freeze({
			__call = function(_self: any, className: string): Type<Instance>
				check(type(className) == "string", "instance class must be a string")

				local constrained = table.clone(base)
				constrained.class = className
				return descriptor(constrained)
			end,
		})
	)

	return (table.freeze(callable) :: any) :: Classed
end)()

local function isType(value: any): boolean
	return type(value) == "table" and type(value.kind) == "string"
end

--[=[
	@within Types
	@function enum
	@param variants V -- a set: `{ primary = true, secondary = true }`
	@return Type<EnumPayload<V>>

	A closed set of names, encoded as an index in the enclosing bitfield. Two variants cost one
	bit; four cost two.

	```lua
	weapon = t.enum({ primary = true, secondary = true, melee = true }),
	-- payload type: "primary" | "secondary" | "melee"
	```

	:::note
	Variants are written as keys rather than as an array because Luau widens `{"a", "b"}` to
	`{string}`, which would throw away the literal types this exists to give you.
	:::
]=]
--[[
	Wire index is the position in the sorted name list, never table iteration order. ByteNet derives
	packet ids from iteration order and the failure mode is that everything decodes as the wrong
	thing, silently (`docs/WIRE-FORMAT.md` §3).
]]
function t.enum<V>(variants: V): Type<EnumPayload<V>>
	check(type(variants) == "table", "enum variants must be a table")

	local names = sortedKeys(variants :: any)
	check(#names > 0, "an enum needs at least one variant")

	for _, name in names do
		check((variants :: any)[name] == true, `enum variant "{name}" must be set to true`)
	end

	return descriptor({
		kind = "enum" :: Kind,
		variants = names,
	})
end

--[=[
	@within Types
	@function optional
	@param inner Type<T>
	@return Type<T?>

	A value that may be absent. Presence costs one bit in the enclosing bitfield, not a byte.
]=]
function t.optional<T>(inner: Type<T>): Type<T?>
	check(isType(inner), "optional needs a netweave type")
	check(inner.kind ~= "optional", "optional cannot wrap an optional")

	return descriptor({
		kind = "optional" :: Kind,
		inner = inner,
	})
end

--[=[
	@within Types
	@function array
	@param element Type<T>
	@param min number? -- alone, an exact length
	@param max number?
	@return Type<{ T }>

	A list.

	```lua
	t.array(t.u8)            -- 0..65535, length-prefixed
	t.array(entity, 100)     -- exactly 100
	t.array(t.string, 0, 8)  -- at most 8
	```

	The exact form is what makes a schema statically sized, and a statically sized packet carries
	no length prefix at all — the framing guarantee costs it nothing.
]=]
function t.array<T>(element: Type<T>, min: number?, max: number?): Type<{ T }>
	check(isType(element), "array needs a netweave element type")

	local lower = min or 0
	local upper = max or (if min then min else MAX_LENGTH)

	check(lower >= 0, `array length {lower} is negative`)
	check(lower <= upper, `array length range has min {lower} above max {upper}`)
	check(upper <= MAX_LENGTH, `array length {upper} exceeds {MAX_LENGTH}`)

	return descriptor({
		kind = "array" :: Kind,
		element = element,
		min = lower,
		max = upper,
	})
end

--[=[
	@within Types
	@function map
	@param key Type<K>
	@param value Type<V>
	@return Type<{ [K]: V }>

	A dictionary, length-prefixed and written as key/value pairs.
]=]
--[[
	**What can be a map key, and why the list is this short.**

	A key has to be a value the *receiver* can look one up by. That is a property of how the decoded
	value behaves as a table index, not of how it serialises:

	  * `number`, `string`, `boolean` and `enum` decode to primitives, and two equal ones are the
	    same key. Those work.
	  * `instance` decodes to the reference the sidecar carried, and reference identity is exactly
	    what a map keyed by an instance wants. That works too.
	  * `struct`, `array`, `map` and `buffer` decode to **fresh tables**. Two entries the sender
	    wrote with equal keys arrive as two distinct keys, and the game cannot look up either — it
	    would have to walk the map comparing contents, which is not a map.
	  * `optional` cannot be a key at all: a Lua table has no nil index. The presence bit it adds is
	    dead weight that only a hostile packet can clear, and when it did, the reader raised on
	    `result[nil]` — wire data reaching a Luau error, which is guarantee G4 (M4 report, finding 3).
	  * `vector2`, `vector3`, `color3` and `cframe` are refused for the same reason as tables, but the
	    reason is one this file must not have to know: whether two separately decoded datatypes are
	    the same table key depends on whether the runtime interns them. **A schema is not allowed to
	    depend on that**, so they are out here rather than out on some runtimes.

	A game that wants one of the refused kinds as a key has the same options either way: key by
	something primitive that names it — an id, a name, an enum — and put the rest in the value.
]]
local MAP_KEYS: { [string]: boolean } = {
	number = true,
	string = true,
	boolean = true,
	enum = true,
	instance = true,
}

function t.map<K, V>(key: Type<K>, value: Type<V>): Type<{ [K]: V }>
	check(isType(key), "map needs a netweave key type")
	check(isType(value), "map needs a netweave value type")

	local keyKind = (key :: any).kind

	check(
		MAP_KEYS[keyKind] == true,
		`a map key is {tostring(keyKind)}, and a map key has to be something the receiver can look `
			.. `it up by. Use t.u16, t.string(0, 32), t.boolean, an enum, or t.instance — a `
			.. `{tostring(keyKind)} decodes to a fresh value on the other side, so two entries the `
			.. `sender wrote with equal keys arrive as two keys nothing can index. Key by an id or a `
			.. `name and put the rest in the value.`
	)

	return descriptor({
		kind = "map" :: Kind,
		key = key,
		value = value,
		min = 0,
		max = MAX_LENGTH,
	})
end

--[=[
	@within Types
	@function struct
	@param fields F -- a table of netweave types
	@return Type<StructPayload<F>>

	A record. The payload type is derived from the fields, so there is nothing to keep in sync.

	```lua
	local Entity = t.struct({
		id = t.u8,
		position = t.vector3,
		alive = t.boolean,
	})
	-- Type<{ id: number, position: Vector3, alive: boolean }>
	```
]=]
--[[
	Fields are encoded in sorted name order, not declaration order. Both peers build the same
	literal so hash order would usually agree, but "usually" is how ByteNet's id assignment behaves
	too, and sorting costs nothing at definition time.
]]
function t.struct<F>(fields: F): Type<StructPayload<F>>
	check(type(fields) == "table", "struct fields must be a table")

	local order = sortedKeys(fields :: any)
	check(#order > 0, "a struct needs at least one field")

	for _, name in order do
		check(isType((fields :: any)[name]), `struct field "{name}" is not a netweave type`)
	end

	return descriptor({
		kind = "struct" :: Kind,
		fields = fields :: any,
		order = order,
	})
end

return table.freeze(t)
