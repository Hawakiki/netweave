--!strict
--!optimize 2

--[=[
	@class Trust

	Provenance in the type. `Untrusted<T>` says: this value came off the wire.

	```lua
	local function giveItem(player: Player, amount: nw.Trusted<{ id: number, count: number }>) end

	combat.openedMenu:listen(function(ctx, request)  -- request: Untrusted<...>
		log("menu " .. request.id)                   -- fine
		giveItem(ctx.player, request)                -- type error
	end)
	```

	Only three things produce `Trusted<T>`: a `command` handler, a `query` handler, and
	[Trust.validate] — plus an explicit cast, `(value :: any) :: nw.Trusted<T>`, for server-authored
	data that never came off a wire. **There is no `nw.untrust`.** An unwrap function would be reached for
	reflexively and the brand would become decoration — the same reason `unsafe` in Rust is ugly
	on purpose (`DESIGN-API.md` §10.6).
]=]

--[[
	Enforcement is opt-in on the game's side, and that is not a shortcut. Luau is structurally
	typed, so a value usable as `T` is accepted anywhere `T` is; `Untrusted<T>` is deliberately a
	subtype of `T`, which is what lets arithmetic, logging and UI work without ceremony. The price
	is that it also satisfies an un-annotated `f(x: T)`.

	Deciding which of your functions carry authority is the discipline this library sells, so
	requiring that to be written down is the intended cost, not an oversight (`DESIGN-API.md` §6).
]]

--[[
	**The tag is required, and that is a correction.**

	It was `{ __nwTrusted: true? }` — optional — until M3 phase 3, and an optional property is one
	a table literal is inferred to satisfy by not having it. So `giveItem({ screen = 1 })` compiled,
	and the claim above that only three things produce `Trusted<T>` was **false**: a literal of the
	right shape produced one too, and the one-line laundering

		giveItem({ screen = untrusted.screen })

	rebuilt an untrusted payload into a trusted one with nothing to see. Measured, then fixed by
	making the property required; `tests/api_reject.luau` cases 16 and 17 are those two lines.

	The cost is that the type asserts a field the runtime does not have. Reading `__nwTrusted` off
	a payload gives `nil` where the type promises `true`. That is a phantom on a `__nw`-prefixed
	name nobody reads, and it is a much smaller lie than the alternative §6 rejected — a wrapper,
	which would misdescribe the whole value and allocate one per packet.

	**What it still does not stop.** Writing the tag out — `giveItem({ screen = 1, __nwTrusted = true })`
	— type-checks. That is deliberate: the escape hatch has to exist for server-authored data, and
	a forgery you have to spell is one a reviewer sees and `grep` finds. The supported spelling is a
	cast, `(value :: any) :: nw.Trusted<T>`, which is pinned in `tests/api_ok.luau`.

	**The four places that build a tag must agree**, and they cannot share code: a `type function`
	body sees only the `types` library, so `src/api/View.luau` builds its own. `tests/api_ok.luau`
	asserts the agreement by assigning one to the other, and a divergence fails it — verified by
	changing one side alone.
]]

local Serdes = require("../codec/Serdes")
local Types = require("../types")

local Trust = {}

--[[
	Measured in `spike/declare/brand.luau`, and the reason both brands are type functions rather
	than the plain intersections `DESIGN-API.md` §6 originally specified:

	`number & { __nwTrusted: true? }` normalises to `never`. A branded scalar therefore rejects
	every legitimate use of the value — `wire + 1` does not type-check — while satisfying *every*
	parameter, including `Trusted<number>`, because `never` is a subtype of everything. That is
	strictly worse than no brand at all: it breaks the honest caller and admits the dishonest one.

	So the brand binds to table payloads and passes scalars through unchanged. A scalar payload is
	unbranded and the type says so, rather than pretending to a guarantee Luau cannot express.
]]

--[=[
	@type Trusted<T> T
	@within Trust

	A value that has passed the checks its channel declares. Produced by a `command` handler, a
	`query` handler, and [Trust.validate], and by nothing else.

	:::caution
	The brand binds to **table** payloads only. `Trusted<number>` is `number`, because Luau
	normalises the intersection of a primitive and a table to `never`, which would satisfy every
	parameter rather than none. Wrap a scalar in a one-field struct if you want the brand on it.
	:::
]=]
--[[
	**A union is branded component by component, and until M4 it was not branded at all.**

	`T?` is a union, and the test that guarded these functions was `value:is("table")` — false for a
	union, so an optional payload came back untouched. A `signal` whose `data` is
	`t.optional(t.struct({ ... }))` handed its handler a plain `{ screen: number }?`, and
	`nw.Trusted<Req?>` reduced to `Req?` as well, so the two coincided: untrusted client data reached
	a parameter annotated for trusted data **with no cast to grep for** (M4 report).

	The documented limit was "scalar payloads are unbranded", which is still true and is a different
	sentence: `Trusted<number>` is `number` because Luau normalises the intersection of a primitive
	and a table to `never`, which would satisfy every parameter rather than none. An optional table
	is not a scalar, and there was never a reason for it to be exempt.

	Branding each table component and rebuilding the union keeps the narrowed case working too:
	`if r then authoritative(r) end` narrows to the branded table, so the brand survives the `if`
	the payload's optionality forces a game to write.
]]
-- selene: allow(undefined_variable)
type function branded(payload, name)
	local value = types.copy(payload)

	local function tagged(inner)
		local tag = types.newtable()
		tag:setproperty(types.singleton(name), types.singleton(true))
		return types.intersectionof(inner, tag)
	end

	if value:is("table") then
		return tagged(value)
	end

	if value:is("union") then
		local rebuilt = nil
		local marked = false

		for _, component in value:components() do
			local part = component

			if component:is("table") then
				part = tagged(component)
				marked = true
			end

			rebuilt = if rebuilt then types.unionof(rebuilt, part) else part
		end

		--[[ A union with no table in it is a scalar union — `number | string` — and the caution
		     above applies to it whole. Returning the copy rather than the rebuilt one keeps that
		     case byte-identical to what it was. ]]
		if marked and rebuilt then
			return rebuilt
		end
	end

	return value
end

-- selene: allow(undefined_variable)
export type function Trusted(payload)
	return branded(payload, "__nwTrusted")
end

--[=[
	@type Untrusted<T> T
	@within Trust

	A value that arrived from a client and has been checked for *shape* only. It conforms to the
	schema; nothing has said the sender was entitled to send it.

	This is what a `signal` handler receives, because `signal` is the class that carries no
	authority (`DESIGN-API.md` §3).

	:::caution
	Table payloads only, for the reason given on [Trust.Trusted].
	:::
]=]
-- selene: allow(undefined_variable)
export type function Untrusted(payload)
	return branded(payload, "__nwUntrusted")
end

--[[
	These two aliases are load-bearing, and deleting them breaks the library silently.

	Measured in `spike/declare/mod/`: an `export type function` that its own module never references
	does **not** reduce for a module that requires it. It becomes `any`, with no diagnostic — so
	every `nw.Trusted<T>` annotation in a game would keep compiling and stop meaning anything, and
	`tests/api_reject.luau` would stop reporting the untrusted-reaches-authoritative-function case.
	Any reference inside this file is enough; a local alias is the smallest one.
]]
type _instantiateTrusted = Trusted<{ probe: boolean }>
type _instantiateUntrusted = Untrusted<{ probe: boolean }>

--[[
	`Trusted<PayloadOf<S>>` would say this more directly, and does not work: nesting one type
	function inside another over an un-resolved generic fails to reduce, and the analyser reports
	`type functions do not currently support types of the form '*error-type*'` — inside netweave's
	source, where a user cannot act on it.

	Taking the schema whole and reading `__payload` here is also what makes the inference work at
	all. `validate<T>(schema: Types.Type<T>, ...)` does not bind `T`: the solver resolves it to
	`unknown`, so the brand sees a non-table and passes it through, and every validated value comes
	back as `unknown?`. Inferring the schema type and projecting the payload out of it is the shape
	`src/types/init.luau` already had to use for `t.struct`, for the same reason.
]]
--[[
	A callable constructor's table half.

	`t.u8`, `t.string`, `t.vector3` and `t.instance` are `Type<T> & ((…) -> Type<T>)` since
	`PLAN-M5` phase 1 — an intersection, because that is the only spelling that checks the argument
	*types* rather than only their count. To a `type function` an intersection is not a table, so
	anything reading `__payload` off a schema has to take the table half out first.

	`src/types/init.luau` carries the same walk. A `type function` cannot reference an outer local
	and calling one across a `require` needs it exported, so the copy is the cheaper of the two
	costs — and the two are tested by the same `_ok` files, which annotate a payload projected
	through both.
]]
-- selene: allow(undefined_variable)
type function carrierOf(ty)
	if not ty:is("intersection") then
		return ty
	end

	for _, part in ty:components() do
		if part:is("table") and part:readproperty(types.singleton("__payload")) then
			return part
		end
	end

	return ty
end

-- selene: allow(undefined_variable)
export type function TrustedPayload(schema)
	local descriptor = carrierOf(types.copy(schema))

	--[[ One sentence, two failures: something that is not a table, and a table that is not a
	     netweave type. Both are the same mistake at the call site. ]]
	local advice = "nw.validate takes a netweave type as its first argument and the value as its "
		.. "second: nw.validate(t.struct({ screen = t.u8 }), value). A plain Luau table is not a "
		.. "schema, so there is nothing to check the value against."

	if not descriptor:is("table") then
		error(advice)
	end

	local payload = descriptor:readproperty(types.singleton("__payload"))

	if not payload then
		error(advice)
	end

	--[[ `nw.validate(t.optional(S), v)` returned an unbranded value for the same reason `Trusted`
	     did, so it goes through the same helper. ]]
	return branded(payload, "__nwTrusted")
end

--[[
	One codec per descriptor, built on first use and kept. Building one walks the schema and
	synthesises closures; doing that per `validate` call would make the honest path the expensive
	one, which is how a safety feature gets switched off.

	Weak keys so a descriptor built inside a function does not pin its codec forever.
]]
local codecs: { [Types.Descriptor]: Serdes.Codec } = setmetatable({}, { __mode = "k" }) :: any

local function codecFor(schema: Types.Descriptor): Serdes.Codec
	local existing = codecs[schema]

	if existing then
		return existing
	end

	local codec = Serdes.fromSchema(schema)
	codecs[schema] = codec

	return codec
end

--[=[
	@within Trust
	@function validate
	@param schema S -- any type from `nw.types`
	@param value any -- typically from outside netweave entirely
	@return T? -- the value, branded `Trusted<T>`, or nil
	@return string? -- why it was refused

	The third and last producer of `Trusted<T>`: check an arbitrary value against a schema.

	```lua
	local settings, failure = nw.validate(SettingsSchema, HttpService:JSONDecode(body))

	if not settings then
		warn(`stored settings for {userId} are unusable: {failure}`)
		settings = DEFAULTS
	end
	```

	Use it for data that did not arrive on a netweave channel — a DataStore read, an HTTP
	response, a legacy `RemoteEvent` you have not migrated. Data that *did* arrive on a channel is
	already validated by its codec, and validating it twice buys nothing.

	:::caution
	This runs the encoder against `value` to decide, so it costs a real serialisation. It is an
	escape hatch, not a hot path.
	:::

	:::caution
	**It is exactly as strict as the encoder**, and until M3 phase 9 the encoder was not strict
	enough for this to mean what it says. The boolean writer tested truthiness, so
	`{ admin = "false" }` validated against `t.boolean` and came back branded and truthy; the
	instance writer tested only non-nil; the integer writers checked the range and let the fraction
	truncate. All three are refused now, and the reason to say so here is that the two ways this
	function is reached — a DataStore row and an HTTP body — are exactly the values nobody wrote.
	:::
]=]
function Trust.validate<S>(schema: S, value: any): (TrustedPayload<S>?, string?)
	if type(schema) ~= "table" or type((schema :: any).kind) ~= "string" then
		error(
			`nw.validate takes a netweave type as its first argument and the value as its second, `
				.. `got {typeof(schema)}. Write it as nw.validate(t.struct(...), value); a policy is `
				.. `not a schema and neither is a plain table.`,
			2
		)
	end

	local failure = codecFor(schema :: any).check(value)

	if failure then
		return nil, failure
	end

	return (value :: any) :: TrustedPayload<S>, nil
end

return Trust
