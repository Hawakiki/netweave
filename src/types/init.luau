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
	.step number? -- `quantized`: the size of one wire level
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
	step: number?,
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
	step: number?,
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
	--[[ Asked before `readproperty`, which raises its own message on a non-table — `type.readproperty:
	     expected self to be either a table, but got number instead` — printed verbatim at the call
	     site in a game's declaration file, where nothing about it names netweave or the fix. ]]
	local advice = "PayloadOf takes a netweave type and extracts what it carries: "
		.. "t.PayloadOf<typeof(ShotType)>, where ShotType came from t.struct, t.u8 or t.array. "
		.. "A payload type is what comes out of it, not what goes in."

	if not ty:is("table") then
		error(advice)
	end

	local payload = ty:readproperty(types.singleton("__payload"))

	if not payload then
		error(advice)
	end

	return payload
end

--[[
	**The Q5 instantiation, which this type function needed and did not have.**

	`spike/declare/README.md` Q5, measured again by M4's security report: an `export type function`
	that its own module never references does not reduce for a module that requires it. It becomes an
	error type — silently — so `type Shot = t.PayloadOf<typeof(ShotType)>` named nothing, and
	`local wrong: Shot = { origin = "no" }` compiled. Every game function annotated with the alias
	the docstring above prescribes was unchecked.

	`StructPayload` and `EnumPayload` never had the problem because `t.struct` and `t.enum` name them
	in their own signatures. `PayloadOf` is the one nothing else in this file mentions, and one
	reference is enough. `Trust.luau` carries the same two lines for the same reason.
]]
type _instantiatePayloadOf = PayloadOf<Type<{ probe: boolean }>>

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

--[[
	~~`f32` is `-2^24..2^24` and `f64` is `-2^53..2^53`.~~ **Those were the spans in which each
	encoding represents every *integer* exactly, and using them as the value range refused ordinary
	numbers** (M4 report): bare `t.f32` refused `1e8`, bare `t.f64` refused `1e18`, and
	`t.f32(0, 1e9)` was refused at declaration — with a range the author never wrote appearing in the
	message.

	The cap did no layout work either. A float is never narrowed (`Ir.lowerNumber`: subtracting a
	lower bound from a float and storing it narrower changes which values are representable), so
	these two numbers only ever validated, and validated the wrong property. What a float range is
	for is the author's own claim about the value — `t.f32(-1, 1)` for a normal, `t.f32(-90, 90)` for
	a pitch — and the encoding's own limit is the largest finite value it can hold.

	So: the largest finite `f32` and the largest finite double. `inf` is outside both, which is the
	intent — it round-trips, but it is a value no schema means to declare, and NaN was already
	refused because it fails both comparisons.

	The precision this does *not* promise is now in the docstrings, where the finding says it should
	have been: `f32` carries about seven significant digits, so a number past 2^24 comes back rounded.
]]
local MAX_F32 = 3.4028234663852886e38
local MAX_F64 = 1.7976931348623157e308

local ENCODING_RANGE: { [string]: { min: number, max: number } } = {
	u8 = { min = 0, max = 255 },
	u16 = { min = 0, max = 65535 },
	u32 = { min = 0, max = 4294967295 },
	i8 = { min = -128, max = 127 },
	i16 = { min = -32768, max = 32767 },
	i32 = { min = -2147483648, max = 2147483647 },
	f32 = { min = -MAX_F32, max = MAX_F32 },
	f64 = { min = -MAX_F64, max = MAX_F64 },
}

--[[ Which encodings carry a fraction. Everything else — every integer encoding, and the *lengths*
     `t.string` and `t.buffer` are ranged by — has to be given whole bounds. ]]
local FRACTIONAL: { [string]: boolean } = { f32 = true, f64 = true }

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

	--[[
		Whole bounds, unless the encoding itself carries a fraction.

		`t.u8(0.5, 2.5)` type-checked, lowered and encoded — and delivered a different number than
		was sent, with no rejection anywhere: the offset became 0.5, the writer's whole-number test
		passed on the *value*, `buffer.writeu8(1 - 0.5)` truncated, and the reader added 0.5 back.
		Sent 1, got 0.5. That is the failure M3 phase 9 closed for fractional values, re-opened one
		level up by the bound (M4 report).

		The same applies to `t.string` and `t.buffer`, whose range is a **length**: half a byte is
		not a length, and a fractional one would reach the length prefix.
	]]
	local whole = not FRACTIONAL[base.encoding or ""]

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
				check(
					not whole or (min % 1 == 0 and max % 1 == 0),
					`{label} range {min}..{max} is not whole, and this one counts in whole numbers. `
						.. `Round the bounds — or use t.f32 or t.f64 if the value really is fractional`
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

	A single-precision float, four bytes, up to ±3.4028235e38.

	A range on a float validates but never narrows the storage — subtracting a lower bound and
	storing it smaller would change which values are representable, which is not what the schema
	said.

	:::caution
	**About seven significant digits.** Every integer up to 16,777,216 is exact and past that they
	come back rounded: 16777217 arrives as 16777216, silently, because that is what the encoding is.
	Use `t.f64` where a large number has to be exact, `t.u32` or `t.i32` where it is an integer, or
	[Types.quantized] where a bounded range needs fewer bytes than either.
	:::
]=]
t.f32 = number("f32") :: Ranged<number>

--[=[
	@prop f64 Ranged<number>
	@within Types

	A double-precision float, eight bytes, up to ±1.7976931348623157e308 — every number Luau has,
	`inf` and NaN excepted.

	Integers are exact to 2^53, which is every `UserId`, every timestamp in milliseconds and every
	currency balance a game will hold.
]=]
t.f64 = number("f64") :: Ranged<number>

--[=[
	@within Types
	@function quantized
	@param min number -- the lowest value the field carries
	@param max number -- the highest
	@param step number -- the smallest difference the wire keeps
	@return Type<number>

	A fractional value carried as **the number of steps from `min`** — the one range on a float that
	narrows the storage.

	```lua
	normal = t.quantized(-1, 1, 2 / 254),    -- one byte, where t.f32 is four
	yaw    = t.quantized(-180, 180, 0.25),   -- 1440 levels, two bytes
	```

	`t.f32` costs four bytes whatever range you declare, because subtracting a lower bound from a
	float and storing it smaller changes which values are representable — so a range on a float
	validates and nothing more. This is the declaration that says how much precision you actually
	need, and the layout then spends what that precision costs: one byte up to 256 levels, two up to
	65,536, four beyond.

	:::caution
	**The value comes back rounded to the nearest step**, and that is the trade rather than a defect
	— it is written into the declaration instead of hidden in the encoding. `t.quantized(-1, 1,
	2 / 254)` sent `0.5` returns `0.49606…`. Use `t.f32` where the exact bits matter, or a smaller
	step where they nearly do.
	:::

	:::note
	The range has to divide into a whole number of steps. `t.quantized(0, 100, 3)` is 33.3 of them
	and is refused here rather than rounded silently, because which end moves is the author's call
	and not netweave's.
	:::
]=]
function t.quantized(min: number, max: number, step: number): Type<number>
	check(type(min) == "number", "quantized needs a numeric minimum")
	check(type(max) == "number", "quantized needs a numeric maximum")
	check(type(step) == "number", "quantized needs a numeric step")
	check(min < max, `quantized range has min {min} at or above max {max}. Put the smaller one first`)
	check(
		step > 0,
		`quantized step {step} is not above zero. The step is how far apart two `
			.. `neighbouring values are, so it is a positive number smaller than the range`
	)
	check(
		step <= max - min,
		`quantized step {step} is wider than the {max - min} it divides. One step across the whole `
			.. `range is the coarsest this gets; anything wider carries no information`
	)

	local levels = (max - min) / step
	local whole = math.floor(levels + 0.5)

	--[[ Relative, because `2 / (2 / 254)` is 254.00000000000003 and the declaration that produced it
	     is exactly the one this is for. What it refuses is a range genuinely off a step boundary. ]]
	check(
		math.abs(levels - whole) <= 1e-9 * math.max(1, whole),
		`quantized range {min}..{max} is {levels} steps of {step}, which is not a whole number of `
			.. `them. Move a bound or change the step so it divides evenly — netweave will not pick `
			.. `which one for you`
	)

	check(
		whole <= 4294967295,
		`quantized range {min}..{max} in steps of {step} is {whole} levels, past the 4294967295 a `
			.. `four-byte count holds. Use a larger step, or t.f64 if the value really needs that `
			.. `much precision`
	)

	return descriptor({
		kind = "number" :: Kind,
		min = min,
		max = max,
		step = step,
	})
end

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

	--[[ A count is not a range through `ranged`, so it needs the same check separately.
	     `t.array(t.u8, 1.5)` lowered happily and then refused **every** length the game could send:
	     a channel declared, accepted, and unable to carry anything (M4 report). ]]
	check(
		lower % 1 == 0 and upper % 1 == 0,
		`array length {lower}..{upper} is not whole. A length is a count of elements, and a `
			.. `fractional one is a channel that refuses every list you can build`
	)

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
