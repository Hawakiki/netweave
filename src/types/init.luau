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
	@type Encoding "u8" | "u16" | "u32" | "u53" | "i8" | "i16" | "i32" | "i53" | "f32" | "f64"
	@within Types

	Storage width for a number, and the component width of a vector.

	This is an upper bound, not a promise: a range narrower than the encoding lets the codec store
	fewer bytes and subtract the minimum, so `t.u16(1000, 1255)` occupies one byte on the wire.
]=]
export type Encoding = "u8" | "u16" | "u32" | "u53" | "i8" | "i16" | "i32" | "i53" | "f32" | "f64"

--[=[
	@type Kind "boolean" | "number" | "string" | "buffer" | "vector2" | "vector3" | "cframe" | "color3" | "instance" | "enum" | "literal" | "optional" | "array" | "map" | "struct" | "union"
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
	| "literal"
	| "optional"
	| "array"
	| "map"
	| "struct"
	| "union"

--[=[
	@interface Descriptor
	@within Types
	.kind Kind
	.encoding Encoding? -- numbers, and vector components
	.min number? -- value range for numbers, length range for strings, buffers and arrays
	.max number?
	.step number? -- `quantized`: the size of one wire level
	.utf8 boolean? -- `string`: the bytes must decode as UTF-8
	.pattern string? -- `string`: a Lua pattern the whole value must match
	.class string? -- `instance`: the class an arrival must be, or nil for any
	.descendantOf Instance? -- `instance`: the container an arrival must be inside
	.variants { string }? -- `enum`: variant names, sorted. Wire index is the position here
	.literal (string | boolean | number)? -- `literal`: the one value, which costs nothing on the wire
	.default (string | boolean | number)? -- `optional`: what an absent value reads as, and what is not sent
	.unit boolean? -- `vector3`: the magnitude must be 1
	.inner Descriptor? -- `optional`
	.element Descriptor? -- `array`
	.key Descriptor? -- `map`
	.value Descriptor? -- `map`
	.fields { [string]: Descriptor }? -- `struct`
	.branches { [string]: Descriptor }? -- `union`: branch name to schema
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
	descendantOf: Instance?,
	utf8: boolean?,
	pattern: string?,
	variants: { string }?,
	literal: (string | boolean | number)?,
	default: (string | boolean | number)?,
	unit: boolean?,
	inner: Descriptor?,
	element: Descriptor?,
	key: Descriptor?,
	value: Descriptor?,
	fields: { [string]: Descriptor }?,
	branches: { [string]: Descriptor }?,
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
	descendantOf: Instance?,
	utf8: boolean?,
	pattern: string?,
	variants: { string }?,
	literal: (string | boolean | number)?,
	default: (string | boolean | number)?,
	unit: boolean?,
	inner: Descriptor?,
	element: Descriptor?,
	key: Descriptor?,
	value: Descriptor?,
	fields: { [string]: Descriptor }?,
	branches: { [string]: Descriptor }?,
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
-- selene: allow(undefined_variable)
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

--[[
	**The two-parameter seam, and the one-parameter one behind it.**

	`t.map<K, V>(key: Type<K>, value: Type<V>)` compiled for primitives and failed for the schema
	every replicated-entities game writes first: `t.map(t.u16, Entity)` was `Expected this to be
	exactly 'unknown', but got '{ hp: number }'`, because the solver does not unify a generic
	parameter against a type-function result — `Entity` is a `Type<StructPayload<…>>`, and a `T`
	read out of that is `unknown`, not the struct (M4-1, 중대). Measured next: `t.optional(Entity)`
	and `t.array(Entity)` had the same seam outside a spec literal, so `nw.validate(t.optional(S),
	v)` returned an unbranded `unknown?` and the brand never applied on that path.

	Reading `__payload` directly is what `t.struct` has always done and what works. Three small
	type functions, one per constructor, each with its own message, rather than `PayloadOf` reused,
	because the message prints verbatim at the call site and has to name the constructor that was
	called. The extraction is spelled out three times because a type function cannot reference an
	outer local — the analyzer refuses it as a syntax error.
]]

--[=[
	@type OptionalPayload<I, D> I? | I
	@within Types

	What [Types.optional] carries: the inner type's payload, or nil — and with a default, the
	payload alone, because an absent value reads as the default. Applied for you.
]=]
--[[ A schema built at runtime reaches these through `any`, and `any` carries no `__payload`. It
     stays `any` on the way out rather than being refused: the analyzer has been bypassed on
     purpose, and the runtime `check()` is the guard on that path. ]]
-- selene: allow(undefined_variable)
export type function OptionalPayload(inner, default)
	if inner:is("any") then
		return types.any
	end

	local advice = "t.optional takes a netweave type, as in t.optional(t.u16) or t.optional(Entity). "
		.. "What was passed carries no payload, so it did not come from t.u8, t.struct, t.enum or "
		.. "another constructor"

	if not inner:is("table") then
		error(advice)
	end

	local payload = inner:readproperty(types.singleton("__payload"))

	if not payload then
		error(advice)
	end

	--[[ An absent second argument arrives as `unknown` (measured, `spike/additions`), and nil is
	     the spelling of "no default" a caller could write out. ]]
	if default:is("unknown") or default:is("nil") then
		return types.unionof(payload :: type, types.singleton(nil))
	end

	--[[ The default's tag against the payload's, for the primitives the runtime admits: a string
	     default on a number field is a diagnostic here rather than a raise at the declaration. A
	     singleton's tag is "singleton", so its value's kind is read through it. ]]
	local function primitive(ty: type): string?
		if ty:is("singleton") then
			return type(ty:value())
		end

		if ty:is("number") or ty:is("string") or ty:is("boolean") then
			return ty.tag
		end

		if ty:is("union") then
			local kind: string? = nil

			for _, component in ty:components() do
				local each = primitive(component)

				if each == nil or (kind ~= nil and each ~= kind) then
					return nil
				end

				kind = each
			end

			return kind
		end

		return nil
	end

	local wanted = primitive(payload :: type)
	local given = primitive(default)

	if wanted == nil then
		error(
			"t.optional takes a default only for a number, a string, a boolean or an enum: those are the "
				.. "values two peers can compare, and a table default would be a fresh table on every read"
		)
	end

	if given ~= wanted then
		error(
			`t.optional was given a default of the wrong kind: this field carries a {wanted}, and the `
				.. `default is a {given or default.tag}`
		)
	end

	return payload :: type
end

--[=[
	@type ArrayPayload<E> { E }
	@within Types

	What [Types.array] carries: a list of the element type's payload. Applied for you.
]=]
-- selene: allow(undefined_variable)
export type function ArrayPayload(element)
	if element:is("any") then
		return types.newtable(nil, { index = types.number, readresult = types.any, writeresult = types.any })
	end

	local advice = "t.array takes a netweave element type, as in t.array(t.u8) or t.array(Entity, 100). "
		.. "What was passed carries no payload, so it did not come from t.u8, t.struct, t.enum or "
		.. "another constructor"

	if not element:is("table") then
		error(advice)
	end

	local payload = element:readproperty(types.singleton("__payload"))

	if not payload then
		error(advice)
	end

	return types.newtable(
		nil,
		{ index = types.number, readresult = payload :: type, writeresult = payload :: type }
	)
end

--[=[
	@type MapPayload<K, V> { [K]: V }
	@within Types

	What [Types.map] carries: the key type's payload indexing the value type's. Applied for you.
]=]
-- selene: allow(undefined_variable)
export type function MapPayload(key, value)
	local advice = "t.map takes two netweave types, a key and a value, as in t.map(t.u16, Entity). "
		.. "One of them carries no payload, so it did not come from t.u16, t.string, t.struct or "
		.. "another constructor"

	local function payloadOf(carrier: type): type
		if carrier:is("any") then
			return types.any
		end

		if not carrier:is("table") then
			error(advice)
		end

		local payload = carrier:readproperty(types.singleton("__payload"))

		if not payload then
			error(advice)
		end

		return payload
	end

	local index = payloadOf(key)
	local payload = payloadOf(value)

	return types.newtable(nil, { index = index, readresult = payload, writeresult = payload })
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
-- selene: allow(undefined_variable)
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
--[=[
	@type UnionPayload<B> B
	@within Types

	Turns a table of branch schemas into a **discriminated union** of `{ tag, value }` pairs. Applied
	by [Types.union].

	`t.union({ move = M, attack = A })` carries
	`{ tag: "move", value: MovePayload } | { tag: "attack", value: AttackPayload }`, so
	`if action.tag == "move" then` narrows `action.value` to the move payload and nothing else.
]=]
--[[
	The `tag`/`value` shape rather than `{ move: M? } | { attack: A? }`, and the reason is narrowing
	rather than taste. Luau narrows a union of tables on a **singleton property**, so comparing `tag`
	against a literal selects one component and its `value` with it. A union of tables distinguished
	by which optional field is present narrows on `if action.move then`, which leaves the other
	branches' fields readable as `nil` — the reader can still write `action.attack` and get no error,
	which is the whole failure the tag exists to prevent.
]]
-- selene: allow(undefined_variable)
export type function UnionPayload(branches)
	local result = nil

	for key, property in branches:properties() do
		local branch = property.read

		if not branch or not branch:is("table") then
			error("a union branch is not a netweave type")
		end

		local payload = branch:readproperty(types.singleton("__payload"))

		if not payload then
			error("a union branch is not a netweave type")
		end

		local case = types.newtable()
		case:setproperty(types.singleton("tag"), key)
		case:setproperty(types.singleton("value"), payload)

		result = if result then types.unionof(result, case) else case
	end

	if not result then
		error("a union needs at least one branch")
	end

	return result
end

-- selene: allow(undefined_variable)
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
	@interface TextOptions
	@within Types
	.utf8 boolean? -- the bytes must decode as UTF-8
	.pattern string? -- a Lua pattern the whole value must match, anchored by netweave
	.charset string? -- a Lua character class every byte must belong to, written without the brackets

	What [Types.string] accepts after its length bounds.

	`charset` and `pattern` say the same kind of thing and cannot both be given. `charset = "%w_"`
	is stored as the pattern `[%w_]*`, so two peers declaring it either way agree; it exists
	because a class with one repetition is the one shape of pattern whose cost is linear in the
	value whatever the length, and a peer chooses the length.
]=]
export type TextOptions = {
	utf8: boolean?,
	pattern: string?,
	charset: string?,
}

--[=[
	@type Text Type<string>
	@within Types

	A string type: callable to bound the length, and to say what the bytes may contain.

	```lua
	t.string(1, 20)                                 -- a length, as before
	t.string(1, 20, { utf8 = true })                -- and valid UTF-8
	t.string(1, 20, { charset = "%w_" })            -- and only word characters, at any length
	t.string(1, 20, { pattern = "%a+%d?" })         -- or a shape, when a set is not enough
	```

	:::note
	A `pattern` with more than one unbounded item (`*`, `+`, `-`) is refused past a length the
	matcher can afford, because the matcher backtracks and a peer chooses the bytes. A `charset` is
	one class and one repetition, so it is never refused for cost.
	:::
]=]
export type Text = typeof(setmetatable(
	{} :: Type<string>,
	{} :: { __call: (self: any, min: number, max: number, options: TextOptions?) -> Type<string> }
))

--[=[
	@type Componented<T> Type<T>
	@within Types

	A vector type, callable with the schema its **components** are carried at.

	```lua
	t.vector3                                   -- three f32, twelve bytes
	t.vector3(t.i16(-2048, 2048))               -- three u16, six
	t.unitVector3(t.quantized(-1, 1, 2 / 254))  -- three u8, three
	```
]=]
export type Componented<T> = typeof(setmetatable(
	{} :: Type<T>,
	{} :: { __call: (self: any, component: Type<number>) -> Type<T> }
))

--[=[
	@interface InstanceOptions
	@within Types
	.descendantOf Instance? -- the container an arrival must be inside

	What [Types.instance] accepts after its class name.
]=]
export type InstanceOptions = {
	descendantOf: Instance?,
}

--[=[
	@type Classed Type<Instance>
	@within Types

	An instance type, callable with a class name to restrict what may arrive — and with a container
	to restrict where it may have come from.

	```lua
	t.instance("Sound")
	t.instance("BasePart", { descendantOf = workspace })
	```
]=]
export type Classed = typeof(setmetatable(
	{} :: Type<Instance>,
	{} :: { __call: (self: any, className: string, options: InstanceOptions?) -> Type<Instance> }
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
	u53 = { min = 0, max = 2 ^ 53 },
	i8 = { min = -128, max = 127 },
	i16 = { min = -32768, max = 32767 },
	i32 = { min = -2147483648, max = 2147483647 },
	i53 = { min = -(2 ^ 53), max = 2 ^ 53 },
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

--[[
	Every key is checked to be a string before the sort. A number key reached `table.sort` and
	either sorted in silently — `t.enum({ [1] = true })` accepted with `variants = {1}` while the
	analyzer refused it for a different reason — or, mixed with strings, died in the VM's
	`attempt to compare string < number`, which names neither the constructor nor the key (M4-1).
]]
local function sortedKeys(source: { [string]: any }, what: string): { string }
	local keys = {}

	for key in source do
		check(
			type(key) == "string",
			`a {what} is named by a string key, and {tostring(key)} is a {typeof(key)}. Write `
				.. `\{ name = ... \}, not \{ ... \} — a list has positions where this needs names`
		)
		table.insert(keys, key)
	end

	table.sort(keys)
	return table.freeze(keys)
end

--[[
	Bare and callable share one descriptor, so `t.u8` and `t.u8(0, 10)` describe the same kind. The
	constrained form is a fresh frozen copy; nothing is mutated after definition.
]]
--[[
	What `t.string`'s third argument may say, checked at declaration rather than ignored.

	The report's own row for this asks for it because client strings reach `SetAsync` keys,
	`Instance.Name` and chat, where invalid UTF-8 or a control character surfaces as an error in game
	code with no packet to point at. A length bound cannot say any of that.

	`pattern` is anchored by netweave rather than by the author, so a pattern that already carries an
	anchor is refused: `"^" .. "^%w+$" .. "$"` matches a literal caret, and silently. Anchoring is the
	whole difference between "the name is word characters" and "the name contains a word character
	somewhere", and the unanchored reading is the one that lets anything through.
]]
local TEXT_OPTIONS: { [string]: boolean } = { utf8 = true, pattern = true, charset = true }
table.freeze(TEXT_OPTIONS)

--[[
	The matcher's worst case for a pattern with k unbounded items is about `max^k` steps, and this
	is the largest product `t.string` admits. 2^16 steps is 0.4 ms measured (`spike/pattern/cost`:
	two items at 256 bytes), which a `rate` can budget; the default `max` of 65,535 with two items
	is 4 × 10^9 steps, 25 seconds, which nothing can. So two unbounded items allow a `max` of 256,
	three allow 40, four allow 16, and one is linear at any length.
]]
local PATTERN_STEPS = 65536

--[[
	What the declaration checks, because the matcher does not: Lua 5.3 §6.4.1 says a malformed
	pattern raises *during matching*, and the M4-1 report found the previous check — `string.find`
	against the empty string — reached nothing behind a literal. `"a%b"` was accepted at
	declaration and raised on the receive path, on a peer's string, outside `reject` (G4).

	So the pattern is walked here by the grammar in that section. Two things are refused that are
	well-formed: a back-reference (`%1`), because it needs a capture the walk would have to track
	and its cost is not the `max^k` bound below; and an anchor at either end, because netweave adds
	its own (see `TEXT_OPTIONS`). A `^` or `$` anywhere else is the literal character, as it is in
	Lua, and `%$` at the end is an escaped dollar, not an anchor — the old check read the last
	character alone and refused it.

	Returns the count of unbounded items — a single-character class followed by `*`, `+` or `-` —
	which is what the cost rule needs; `?` is bounded and `%b`/`%f` are linear.
]]
local function scanPattern(pattern: string): (string?, number)
	local length = #pattern
	local at = 1
	local depth = 0
	local unbounded = 0

	--[[ The index of the ']' closing a set that opens at `open`, or nil. A '^' first negates, a
	     ']' first (after that) is the literal bracket, and a '%' escapes the character after it. ]]
	local function closeSet(open: number): number?
		local close = open + 1
		if string.sub(pattern, close, close) == "^" then
			close += 1
		end
		if string.sub(pattern, close, close) == "]" then
			close += 1
		end
		while close <= length and string.sub(pattern, close, close) ~= "]" do
			if string.sub(pattern, close, close) == "%" then
				close += 1
			end
			close += 1
		end
		return if close <= length then close else nil
	end

	if string.sub(pattern, 1, 1) == "^" then
		return "anchor", 0
	end

	while at <= length do
		local char = string.sub(pattern, at, at)
		local item = true

		if char == "(" then
			depth += 1
			at += 1
			item = false
		elseif char == ")" then
			if depth == 0 then
				return "a ')' with no '(' before it", 0
			end
			depth -= 1
			at += 1
			item = false
		elseif char == "$" and at == length then
			return "anchor", 0
		elseif char == "%" then
			local next = string.sub(pattern, at + 1, at + 1)

			if next == "" then
				return "ends in a '%', which has to be followed by a class or the character it escapes", 0
			elseif next == "b" then
				if at + 3 > length then
					return "'%b' needs the two characters it balances, as in %b()", 0
				end
				at += 4
				item = false
			elseif next == "f" then
				if string.sub(pattern, at + 2, at + 2) ~= "[" then
					return "'%f' needs a set after it, as in %f[%w]", 0
				end
				local close = closeSet(at + 2)
				if not close then
					return "a '[' that never closes", 0
				end
				at = close + 1
				item = false
			elseif string.match(next, "%d") then
				return `a back-reference '%{next}', which netweave patterns do not support; spell the repeated text out`,
					0
			else
				at += 2
			end
		elseif char == "[" then
			local close = closeSet(at)
			if not close then
				return "a '[' that never closes", 0
			end
			at = close + 1
		else
			at += 1
		end

		if item then
			local quantifier = string.sub(pattern, at, at)
			if quantifier == "*" or quantifier == "+" or quantifier == "-" then
				unbounded += 1
				at += 1
			elseif quantifier == "?" then
				at += 1
			end
		end
	end

	if depth > 0 then
		return "a '(' that never closes", 0
	end

	return nil, unbounded
end

--[[ The body of a set, as Lua reads one: a leading `^` negates, a `]` first is literal, `%`
     escapes the next byte, and the first other `]` closes the set. The caller supplies the
     brackets, so a close inside the body is the one thing this has to find. ]]
local function classProblem(charset: string): string?
	local length = #charset
	local at = if string.sub(charset, 1, 1) == "^" then 2 else 1

	if string.sub(charset, at, at) == "]" then
		at += 1
	end

	while at <= length do
		local char = string.sub(charset, at, at)

		if char == "%" then
			if at == length then
				return "it ends with a lone %, which escapes nothing"
			end

			at += 2
		elseif char == "]" then
			return "a ] inside it closes the set early, and what follows would sit outside the brackets"
		else
			at += 1
		end
	end

	return nil
end

local function refineText(constrained: any, options: any)
	if options == nil then
		return
	end

	check(
		type(options) == "table",
		`t.string's options come as a table: t.string(0, 24, \{ utf8 = true \}). Got {typeof(options)}`
	)

	for key in options do
		check(
			TEXT_OPTIONS[key] == true,
			`t.string has no option \`{tostring(key)}\`. The three are utf8, pattern and charset — `
				.. `check the spelling, because an option that is ignored looks exactly like one that passed`
		)
	end

	local wantsUtf8 = options.utf8

	if wantsUtf8 ~= nil then
		check(type(wantsUtf8) == "boolean", `t.string's \`utf8\` takes a boolean, got {typeof(wantsUtf8)}`)

		--[[ `false` records nothing. A descriptor that carries the default is a descriptor two peers
		     can spell differently and hash differently for no reason. ]]
		constrained.utf8 = wantsUtf8 or nil
	end

	local pattern = options.pattern
	local charset = options.charset

	--[[
		A set is a pattern with one class and one repetition, stored as that pattern: the reader,
		the writer and the protocol signature then have one attribute to carry, and a peer that
		spelled the same set as a pattern agrees with one that spelled it as a set. What the option
		adds is the guarantee — a class with `*` is one unbounded item, which the rule below admits
		at any length, so a set can never be refused for cost the way a pattern can (M4-1, the
		matcher-cost finding; `PLAN-M5` phase 5).
	]]
	if charset ~= nil then
		check(type(charset) == "string", `t.string's \`charset\` takes a string, got {typeof(charset)}`)
		check(
			pattern == nil,
			"t.string takes `charset` or `pattern`, not both: a charset is the pattern [charset]*, so "
				.. "write the set into the pattern if the pattern needs more than a set"
		)
		check(
			charset ~= "",
			"t.string's `charset` is empty, which admits no byte at all. Use a length of 0..0 if that is what you meant"
		)

		--[[ Two walks: the class walk, for a `]` that would close the set early and leave the rest
		     outside it (`"%w]"` between brackets scans as the well-formed set `[%w]` followed by a
		     literal bracket, not the set the author wrote), then the pattern walk over the whole
		     thing for everything else the grammar refuses. ]]
		local problem = classProblem(charset) or scanPattern(`[{charset}]`)

		check(
			problem == nil,
			`t.string's \`charset\` "{charset}" is not a Lua character class: {problem or ""}. Write `
				.. `what goes between the brackets — %w_ for word characters, a-z for a range, ^%c for `
				.. `anything but a control character, %] for a bracket`
		)

		pattern = `[{charset}]*`
	end

	if pattern ~= nil then
		check(type(pattern) == "string", `t.string's \`pattern\` takes a string, got {typeof(pattern)}`)
		check(
			pattern ~= "",
			"t.string's `pattern` is empty, which matches only an empty string. Use a length of 0..0 if that is what you meant"
		)

		local problem, unbounded = scanPattern(pattern)

		check(
			problem ~= "anchor",
			`t.string's \`pattern\` "{pattern}" carries its own anchor, and netweave adds one — the `
				.. `two together match a literal ^ or $. Write the pattern for the whole value and `
				.. `leave the anchors off; a literal dollar at the end is %$`
		)

		check(
			problem == nil,
			`t.string's \`pattern\` "{pattern}" is not a Lua pattern: {problem or ""}. It would raise `
				.. `on a peer's string rather than refuse it, so it is refused here`
		)

		--[[ `max` is the length of the value the matcher runs over, and it is the attacker's choice
		     up to that bound. The rule is on the product, so a short field keeps its two `.*`. ]]
		local max = constrained.max
		local allowed = math.floor(PATTERN_STEPS ^ (1 / math.max(unbounded, 1)))

		check(
			unbounded <= 1 or max ^ unbounded <= PATTERN_STEPS,
			`t.string's \`pattern\` "{pattern}" has {unbounded} unbounded items (*, + or -) over a `
				.. `value of up to {max} bytes, and the matcher backtracks over every one of them: `
				.. `about {max}^{unbounded} steps on a hostile string, which is seconds per packet at `
				.. `the default maximum. `
				.. `Lower the maximum to {allowed} or fewer for this many items, or rewrite the `
				.. `pattern so at most one item is unbounded — a character class with a count, `
				.. `[%w]?[%w]?, or a class instead of '.'`
		)

		constrained.pattern = pattern
	end
end

local function ranged(base: { [string]: any }, label: string, refine: ((any, any) -> ())?): any
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
			__call = function(_self: any, min: number, max: number, extra: any): any
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

				--[[ Only `t.string` takes a third argument, and everything else refuses one rather
				     than dropping it. `t.u8(0, 10, { utf8 = true })` is a mistake with an obvious
				     cause and no symptom, which is the shape this repository keeps finding. ]]
				if refine then
					refine(constrained, extra)
				else
					check(
						extra == nil,
						`{label} takes a minimum and a maximum and nothing after them. Only t.string `
							.. `has options, and they are utf8 and pattern`
					)
				end

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
	@prop u53 Ranged<number>
	@within Types

	A whole number in `0..9007199254740992`, which is every integer a Luau double holds exactly.

	```lua
	owner = t.u53,                  -- a UserId
	stamp = t.u53(0, 2 ^ 42),       -- milliseconds, narrowed
	```

	Eight bytes bare, and **narrowed like any other integer**: a range whose span fits four bytes or
	fewer takes that instead, so `t.u53(1, 1000)` is two.

	:::note
	Before this existed the widest integer was `t.u32` and a `UserId` had to be declared `t.f64` —
	a float, whose wholeness only the *writer* refused. A peer sending `1.5` on a field a game reads
	as an id got 1.5 delivered, and `Players:GetPlayerByUserId`, a table key and a datastore write
	all behave differently for it. This is checked on both sides.
	:::
]=]
t.u53 = number("u53") :: Ranged<number>

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
	@prop i53 Ranged<number>
	@within Types

	[Types.u53] with a sign: a whole number in `-9007199254740992..9007199254740992`.

	A balance that can go negative, a signed offset from an epoch, a difference between two ids.
	Eight bytes bare, and narrowed the same way — `t.i53(-1000, 1000)` is two.
]=]
t.i53 = number("i53") :: Ranged<number>

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
function t.quantized(min: number, max: number, step: number, ...: any): Type<number>
	check(
		select("#", ...) == 0,
		`t.quantized takes a minimum, a maximum and a step and nothing after them, got `
			.. `{select("#", ...) + 3} arguments. An argument that is dropped looks exactly like one `
			.. `that was applied`
	)
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
	@prop string Text
	@within Types

	A length-prefixed string, up to 65535 bytes. `t.string(0, 64)` bounds the length and shrinks
	the prefix.

	A third argument says what the bytes may **contain**:

	```lua
	name = t.string(1, 20, { utf8 = true, pattern = "[%w_]+" }),
	```

	  * `utf8` — the bytes decode as UTF-8. Roblox's own text APIs assume this, and invalid bytes
	    surface later as an error in game code with no packet to point at.
	  * `pattern` — a Lua pattern the **whole** value must match. netweave anchors it, so
	    `"[%w_]+"` means the entire string is word characters rather than "contains one".

	Both are checked on the way out *and* on the way in: a value the schema forbids is a raise at
	the `:send` that wrote it, and a peer's is a refused packet.

	A pattern has a **cost**, and a peer chooses the string it runs over. Lua's matcher backtracks,
	so a pattern with `k` unbounded items (`*`, `+` or `-`) costs about `max^k` steps on a hostile
	string: `(.*)@(.*)%.(.*)` over the default 65,535 bytes is 34 seconds per packet, inside any
	`rate`. `t.string` refuses a pattern whose `max^k` passes 2^16 — two unbounded items need a
	`max` of 256 or less, three need 40, and one unbounded item is linear at any length. Write the
	shape with bounded classes where you can: `[%w_]+` is one item and costs nothing.

	:::caution
	A pattern is a promise about shape, not about safety. It cannot make a string safe to
	concatenate into a query or a rich-text label — it only means the string is the shape you said.
	Escaping is still the caller's job.
	:::
]=]
t.string = ranged({
	kind = "string" :: Kind,
	min = 0,
	max = MAX_LENGTH,
}, "string", refineText) :: Text

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

--[[
	A vector, callable with the schema its components are carried at.

	Bare, a vector is three `f32` and **unbounded**: a position of `1e38` on an `intent` passes
	`parse`, and `t.unitVector3` covers directions only (M4 report). Naming a component schema is
	how a position says where the map is, and it narrows the storage at the same time, because
	everything a number type knows is reused per component — a range, a declared minimum subtracted,
	a quantisation step.

	The component has to be a number and cannot be optional: a vector with two components is not a
	vector, and there is no bit to spend saying so — a vector opens no scope of its own.
]]
local function vectored(base: { [string]: any }, label: string, axes: number): any
	local self = table.clone(base)

	local callable = setmetatable(
		self,
		table.freeze({
			__call = function(_self: any, component: any, ...: any): any
				check(
					select("#", ...) == 0,
					`{label} takes one component schema and nothing after it, got `
						.. `{select("#", ...) + 1} arguments. An argument that is dropped looks `
						.. `exactly like one that was applied`
				)

				--[[ The kind test rather than `isType`, which is defined further down and is a duck
				     check anyway: what a component has to be is a *number* schema, and asking that
				     directly is both narrower and available here. ]]
				check(
					type(component) == "table",
					`{label} needs a netweave type for its components, got {typeof(component)}`
				)
				check(
					component.kind == "number",
					`{label} carries {axes} numbers, and its component schema is a `
						.. `{tostring(component.kind)}. Use t.f32, a narrowed integer like `
						.. `t.i16(-2048, 2048), or t.quantized`
				)

				--[[
					A unit vector's components are in [-1, 1] and almost never whole, so a component
					that is an integer can represent six directions, an unsigned one three, and a
					range that stops short of ±1 none along that axis. The writer refuses a
					fractional value in an integer component and the reader's tolerance widens only
					for a quantised step, so `t.unitVector3(t.u8)` lowered to three bytes and refused
					almost every honest direction — the `t.array(x, 1.5)` shape one level up (M4-1).
				]]
				if base.unit then
					local fractional = FRACTIONAL[component.encoding or ""] == true or component.step ~= nil
					local low = if component.min ~= nil then component.min else -math.huge
					local high = if component.max ~= nil then component.max else math.huge

					check(
						fractional,
						`{label} is a direction, and its components are fractions in -1..1; a `
							.. `{tostring(component.encoding)} component can hold only whole numbers. `
							.. `Use t.f32, or t.quantized(-1, 1, 2 / 254) for one byte per axis`
					)
					check(
						low <= -1 and high >= 1,
						`{label} is a direction, and its components reach -1 and 1; this one covers `
							.. `{low}..{high}. Declare the component over -1..1 or wider`
					)
				end

				local constrained = table.clone(base)
				constrained.element = component
				constrained.encoding = nil

				return descriptor(constrained)
			end,
		})
	)

	return table.freeze(callable)
end

--[=[
	@prop vector2 Componented<Vector2>
	@within Types

	Two `f32` components, or two of whatever you name: `t.vector2(t.i16(-1024, 1024))` is four bytes.
]=]
t.vector2 =
	vectored({ kind = "vector2" :: Kind, encoding = "f32" :: Encoding }, "vector2", 2) :: Componented<Vector2>

--[=[
	@prop vector3 Componented<Vector3>
	@within Types

	Three `f32` components — twelve bytes, and **unbounded**.

	```lua
	position = t.vector3(t.i16(-2048, 2048)),   -- six bytes, and off the map is refused
	```

	A component schema is the difference between "a Vector3 arrived" and "a Vector3 inside the world
	arrived". Bare, `1e38` on an `intent` is a legal position; naming the range makes it a refusal at
	`parse` with the bounds in the message, and pays for itself in bytes.
]=]
t.vector3 =
	vectored({ kind = "vector3" :: Kind, encoding = "f32" :: Encoding }, "vector3", 3) :: Componented<Vector3>

--[=[
	@prop unitVector3 Componented<Vector3>
	@within Types

	A direction: a `Vector3` validated to unit length on arrival.

	This is the check a shooter would otherwise write by hand in every handler, and forgetting it
	once is how a client sends a 10,000-stud "direction".

	```lua
	direction = t.unitVector3(t.quantized(-1, 1, 2 / 254)),   -- three bytes instead of twelve
	```

	:::note
	A quantised direction does not land exactly on the unit sphere, so the length check widens by
	what the step can move it — `sqrt(3)` half-steps, derived rather than guessed. Naming a component
	coarse enough to matter is therefore a wider tolerance rather than a refusal, and the coarser the
	step the less "unit" promises.
	:::
]=]
t.unitVector3 = vectored({
	kind = "vector3" :: Kind,
	encoding = "f32" :: Encoding,
	unit = true,
}, "unitVector3", 3) :: Componented<Vector3>

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
			__call = function(_self: any, className: string, options: any, ...: any): Type<Instance>
				check(
					select("#", ...) == 0,
					`t.instance takes a class and an options table and nothing after them, got `
						.. `{select("#", ...) + 2} arguments. An argument that is dropped looks exactly `
						.. `like one that was applied`
				)
				check(type(className) == "string", "instance class must be a string")

				local constrained = table.clone(base)
				constrained.class = className

				if options ~= nil then
					check(
						type(options) == "table",
						`t.instance's options come as a table: t.instance("BasePart", `
							.. `\{ descendantOf = workspace \}). Got {typeof(options)}`
					)

					for key in options do
						check(
							key == "descendantOf",
							`t.instance has no option \`{tostring(key)}\`. The one is descendantOf — `
								.. `check the spelling, because an option that is ignored looks exactly `
								.. `like one that passed`
						)
					end

					local root = options.descendantOf

					if root ~= nil then
						check(
							typeof(root) == "Instance",
							`t.instance's \`descendantOf\` takes the container itself, not a name: `
								.. `t.instance("BasePart", \{ descendantOf = workspace \}). Got `
								.. `{typeof(root)}`
						)

						constrained.descendantOf = root
					end
				end

				return descriptor(constrained)
			end,
		})
	)

	return (table.freeze(callable) :: any) :: Classed
end)()

--[=[
	@prop player Type<Player>
	@within Types

	A `Player`, which is [Types.instance] with the payload type Luau cannot get from a class name.

	```lua
	target = t.player,
	```

	:::caution
	**A `Player` object that arrives is not necessarily a player who is here.** `IsA("Player")` is
	still true for someone who left the instant before the packet was written, and the reference the
	sender used keeps it alive. Where the sender's own identity is what you need, `ctx.player` is the
	server's answer and cannot be chosen by anybody; this is for naming *another* player, and what
	makes that name current is the roster, not the type.
	:::
]=]
t.player = descriptor({ kind = "instance" :: Kind, class = "Player" }) :: Type<Player>

local function isType(value: any): boolean
	return type(value) == "table" and type(value.kind) == "string"
end

--[[
	A default is checked here, at the declaration, by the bounds the descriptor already carries —
	not by the codec, which this module cannot require. The kinds are the ones whose `==` is value
	equality, because the writer decides "is this the default" with it, and a string or a number
	is also what a default *is* to the game: the value the field has when nobody set it.
]]
local INTEGER: { [string]: boolean } = {
	u8 = true,
	u16 = true,
	u32 = true,
	u53 = true,
	i8 = true,
	i16 = true,
	i32 = true,
	i53 = true,
}

local function checkDefault(inner: { [string]: any }, default: any)
	local kind = inner.kind
	local given = type(default)

	if kind == "number" then
		check(given == "number", `t.optional's default for a number field is a number, got {given}`)
		check(
			default == default and default ~= math.huge and default ~= -math.huge,
			"t.optional's default is not finite"
		)
		check(
			(inner.min == nil or default >= inner.min) and (inner.max == nil or default <= inner.max),
			`t.optional's default {default} is outside the field's range {tostring(inner.min)}..{tostring(
				inner.max
			)}`
		)
		check(
			not INTEGER[inner.encoding] or default % 1 == 0,
			`t.optional's default {default} is not whole, and the field is an integer`
		)
	elseif kind == "string" then
		check(given == "string", `t.optional's default for a string field is a string, got {given}`)
		check(
			#default >= (inner.min or 0) and #default <= (inner.max or MAX_LENGTH),
			`t.optional's default is {#default} bytes, outside the field's length {tostring(inner.min)}..{tostring(
				inner.max
			)}`
		)
	elseif kind == "boolean" then
		check(given == "boolean", `t.optional's default for a boolean field is a boolean, got {given}`)
	elseif kind == "enum" then
		check(
			given == "string" and table.find(inner.variants, default) ~= nil,
			`t.optional's default {tostring(default)} is not a variant of the enum`
		)
	else
		error(
			`[netweave] t.optional takes a default only for a number, a string, a boolean or an enum, `
				.. `not a {tostring(kind)}: those are the values two peers can compare, and a table `
				.. `default would be a fresh table on every read`,
			3
		)
	end
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

	local names = sortedKeys(variants :: any, "enum variant")
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
	@function literal
	@param value V -- a string, a boolean or a number
	@return Type<V>

	One value, known to both sides, costing nothing on the wire.

	```lua
	version = t.literal("v3"),   -- payload type "v3"
	ready = t.literal(true),     -- payload type true
	```

	The writer refuses any other value, the reader hands the constant back, and a change never
	moves it. It is for versioning a payload, for a `t.union` branch that carries a name and
	nothing else, and for [Types.set], whose entries are literal `true`. A number literal's payload
	is `number`, because Luau has no number singletons; the value is still checked on the way out.
]=]
function t.literal<V>(value: V & (string | boolean | number)): Type<V>
	local kind = type(value)

	check(
		kind == "string" or kind == "boolean" or kind == "number",
		`t.literal takes a string, a boolean or a number, got {typeof(value)}`
	)
	check(
		kind ~= "number" or (value == value and value ~= math.huge and value ~= -math.huge),
		"t.literal takes a finite number; NaN and the infinities are not values two peers can agree on"
	)

	return descriptor({
		kind = "literal" :: Kind,
		literal = value,
	})
end

--[=[
	@within Types
	@function optional
	@param inner I -- a netweave type
	@param default D? -- what an absent value reads as; a number, a string, a boolean or an enum variant
	@return Type<OptionalPayload<I, D>>

	A value that may be absent. Presence costs one bit in the enclosing bitfield, not a byte.

	```lua
	target = t.optional(t.u16),          -- payload number?, nil when absent
	speed = t.optional(t.u8, 16),        -- payload number, 16 when absent, and 16 is never sent
	```

	With a default the payload is the inner type alone: the reader hands the default back where
	the bit is clear, and the writer clears the bit for the default as well as for nil, so the
	common value costs a bit rather than its bytes. The default is part of the protocol — two peers
	declaring different ones disagree — and it is a primitive, because a table default would be a
	fresh table on every read and no two of them equal.
]=]
function t.optional<I, D>(inner: I, default: D?): Type<OptionalPayload<I, D>>
	check(isType(inner), "optional needs a netweave type")
	check((inner :: any).kind ~= "optional", "optional cannot wrap an optional")

	if default == nil then
		return descriptor({
			kind = "optional" :: Kind,
			inner = inner,
		})
	end

	checkDefault(inner :: any, default)

	return descriptor({
		kind = "optional" :: Kind,
		inner = inner,
		default = default,
	})
end

--[=[
	@within Types
	@function array
	@param element E -- a netweave type
	@param min number? -- alone, an exact length
	@param max number?
	@return Type<ArrayPayload<E>>

	A list.

	```lua
	t.array(t.u8)            -- 0..65535, length-prefixed
	t.array(entity, 100)     -- exactly 100
	t.array(t.string, 0, 8)  -- at most 8
	```

	The exact form is what makes a schema statically sized, and a statically sized packet carries
	no length prefix at all — the framing guarantee costs it nothing.
]=]
function t.array<E>(element: E, min: number?, max: number?): Type<ArrayPayload<E>>
	check(isType(element), "array needs a netweave element type")

	--[[
		`{ T? }` with no exact length has no length: `#` on a table with nils is a border, and Luau
		picks it from how the table was built — `{1, nil, 3}` as a literal is three, filled by
		assignment it is one. So `{1, 2, nil}` sent two and `{[2] = -5}` sent nothing, with no raise
		and no report (M4-1). With an exact length nothing is measured, every position is written;
		without one the honest spellings are a map keyed by index, or a struct.
	]]
	check(
		(element :: any).kind ~= "optional" or (min ~= nil and (max == nil or max == min)),
		`t.array(t.optional(...)) needs an exact length, because a list with holes has no length `
			.. `Luau agrees on. Give it one — t.array(t.optional(t.u8), 4) — or key the entries: `
			.. `t.map(t.u8, t.u8)`
	)

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
	@param key K -- a netweave type the receiver can look a value up by
	@param value V -- a netweave type
	@return Type<MapPayload<K, V>>

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

function t.map<K, V>(key: K, value: V): Type<MapPayload<K, V>>
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
	@function set
	@param element E -- a netweave type the receiver can look an entry up by; the same kinds [Types.map] takes as a key
	@return Type<MapPayload<E, Type<true>>>

	A set of values, carried as `{ [E]: true }`.

	```lua
	unlocked = t.set(t.string(1, 32)),   -- payload type { [string]: true }
	```

	It is a [Types.map] whose value is [Types.literal] `true`, and that is not sugar: a
	`t.map(k, t.boolean)` spends a flag byte per entry on a bit that is always set, and a literal
	costs nothing, so a set is its count and its entries and no more. A change replaces the set
	whole, as it does a map.
]=]
function t.set<E>(element: E): Type<MapPayload<E, Type<true>>>
	check(isType(element), "set needs a netweave element type")

	local kind = (element :: any).kind

	--[[ The map's own check would refuse the same kinds, in the map's words; a set is what the
	     author wrote, so the refusal says so. ]]
	check(
		MAP_KEYS[kind] == true,
		`a set of {tostring(kind)} cannot be looked up on the other side: an entry that decodes to `
			.. `a fresh value is an entry nothing can find again. Use t.u16, t.string(0, 32), an enum `
			.. `or t.instance, and put the rest of the value in a map keyed by it.`
	)

	return t.map(element, t.literal(true)) :: any
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

	local order = sortedKeys(fields :: any, "struct field")
	check(#order > 0, "a struct needs at least one field")

	for _, name in order do
		check(isType((fields :: any)[name]), `struct field "{name}" is not a netweave type`)
	end

	--[[ A copy, frozen. The caller's table was kept by reference, so swapping a field after the
	     declaration changed what a codec built later encoded and what the signature hashed — a
	     schema that is not what was declared, with no message (M4 report, finding 17; the same
	     in `t.union`). ]]
	return descriptor({
		kind = "struct" :: Kind,
		fields = table.freeze(table.clone(fields :: any)),
		order = order,
	})
end

--[=[
	@within Types
	@function union
	@param branches B -- branch name to schema
	@return Type<UnionPayload<B>>

	**One of several shapes, and the wire says which.**

	```lua
	local Action = t.union({
		move = t.struct({ x = t.u8, y = t.u8 }),
		attack = t.struct({ target = t.u16 }),
		wait = t.u8,
	})

	action:listen(function(ctx, value)
		if value.tag == "move" then
			print(value.value.x)     -- narrowed to the move branch
		end
	end)
	```

	The payload is `{ tag: "move", value: … } | { tag: "attack", value: … }`, so comparing `tag`
	against a literal narrows `value` with it.

	Two branches cost **one bit**, three or four cost two, and only the chosen branch's bytes are
	written. Branches fork the bit budget rather than summing it: a union of two structs each
	carrying three flags costs `1 + 3` bits, not `1 + 6` — Zap sums, so its variants consume separate
	bits even though only one can ever be present (`RESEARCH §3.9-Y`, `WIRE-FORMAT.md` §5).

	:::caution
	**This is what the "one optional field per case" pattern was standing in for**, and the
	difference is that the pattern cannot say *exactly one*. A struct of optionals lets a peer set
	two cases at once, or none, and every handler that reads it has to check for both — which is a
	check that gets written once and forgotten twice.
	:::

	:::note
	Adding, removing or renaming a branch changes the wire and the protocol hash, the same as adding
	an enum variant: the tag is a **position**, so a branch inserted in the middle renumbers the ones
	after it. Both peers redeploy together, which the handshake enforces rather than hopes for.
	:::
]=]
--[[
	Branches are encoded in sorted name order for the same reason struct fields and enum variants
	are: both peers evaluate the same literal, and "hash order usually agrees" is exactly how
	ByteNet's id assignment behaves.
]]
function t.union<B>(branches: B): Type<UnionPayload<B>>
	check(type(branches) == "table", "union branches must be a table")

	local names = sortedKeys(branches :: any, "union branch")
	check(#names > 0, "a union needs at least one branch")

	for _, name in names do
		check(isType((branches :: any)[name]), `union branch "{name}" is not a netweave type`)
	end

	return descriptor({
		kind = "union" :: Kind,
		variants = names,
		branches = table.freeze(table.clone(branches :: any)),
	})
end

return table.freeze(t)
