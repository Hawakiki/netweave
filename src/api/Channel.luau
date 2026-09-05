--!strict
--!optimize 2

--[=[
	@class Channel

	The six channel classes. A class is a **security obligation**, not a transport mode: a reader
	who sees `nw.intent` knows the server does not approve each packet, and a reader who sees
	`nw.command` knows it does.

	| Class | Direction | Required | Forbidden | The handler receives |
	|---|---|---|---|---|
	| `command` | C→S | `data`, `rate`, `authorize` | `audience`, `args`, `returns`, `timeout` | `Trusted<T>` |
	| `intent` | C→S | `data`, `rate` | `authorize`, `audience`, `returns`, `timeout` | `T` |
	| `signal` | C→S | `data`, `rate` | `authorize`, `audience`, `returns`, `timeout` | `Untrusted<T>` |
	| `query` | C→S→C | `args`, `returns`, `rate`, `authorize`, `timeout` | `data`, `audience` | `Trusted<T>` |
	| `state` | S→C | `data`, `audience` | `rate`, `authorize`, `args`, `returns`, `timeout` | `T` |
	| `event` | S→C | `data`, `audience` | `rate`, `authorize`, `args`, `returns`, `timeout` | `T` |

	Omitting a required field is a type error. So is supplying a forbidden one — which is the part
	that keeps the taxonomy honest, because `signal` exists precisely as the class that may not
	authorize, and a `signal` carrying an `authorize` would have been a `command` all along.
]=]

--[[
	Two layers check a declaration, and they are not redundant.

	The type functions below are the guarantee: they run at analysis time, and a declaration that
	does not satisfy them never ships. The plain Lua checks further down run at load, and exist for
	the declaration that reached here anyway — through an `any`, through a table built at runtime,
	or in a build where `LuauSolverV2` is off and none of the type layer applies (`PLAN-M1` D-7).

	Neither is decoration. The type layer catches what a reviewer would miss; the runtime layer
	catches what the type layer was bypassed for.
]]

local Audience = require("./Audience")
local Config = require("./Config")
local Policy = require("./Policy")
local Serdes = require("../codec/Serdes")
local Types = require("../types")

local Channel = {}

--[=[
	@type Class "command" | "intent" | "signal" | "query" | "state" | "event"
	@within Channel
]=]
export type Class = "command" | "intent" | "signal" | "query" | "state" | "event"

--[=[
	@type Primitive "AuthorizedInbound" | "UntrustedInbound" | "Outbound"
	@within Channel

	Six public classes, three inbound-or-outbound implementations — `query` is an
	`AuthorizedInbound` that also owns a paired `Outbound` for its response.

	The public surface is where meaning lives; the implementation stays small
	(`DESIGN-API.md` §3).
]=]
export type Primitive = "AuthorizedInbound" | "UntrustedInbound" | "Outbound"

--[=[
	@interface Channel
	@within Channel
	.__class Class -- a singleton, so the directional views can branch on it
	.__audience "everyone" | "subset" -- a singleton, so `broadcast` exists only where G3 allows it
	.__payload T -- phantom
	.__response R -- phantom
	.class Class
	.primitive Primitive
	.rate number? -- packets per second the sender may send. nil on outbound classes
	.burst number? -- bucket depth; nil means one second at `rate`
	.maxBytes number -- the most bytes a payload may claim; derived from the schema, tightened by declaration
	.timeout number? -- `query` only, seconds
	.authorize Check<T>? -- resolved from the declared policy at load
	.audience Audience? -- outbound classes only
	.data Descriptor
	.returns Descriptor? -- `query` only
	.key string -- assigned by `nw.namespace`
	.qualified string -- `"namespace.key"`, assigned by `nw.namespace`
	.id number -- wire id, assigned when the protocol is sealed

	A declared channel. Everything except the last three is fixed the moment it is declared; the
	last three are filled in by the namespace and the registry, because an id depends on every
	other channel in the program (`WIRE-FORMAT.md` §3).
]=]
export type Channel<C, A, T, R> = {
	__class: C,
	__audience: A,
	__payload: T,
	__response: R,

	class: Class,
	primitive: Primitive,
	rate: number?,
	burst: number?,
	maxBytes: number?,
	timeout: number?,
	authorize: Policy.Check<T>?,
	audience: Audience.Audience<A>?,
	data: Types.Descriptor,
	returns: Types.Descriptor?,
	codec: Serdes.Codec,
	responseCodec: Serdes.Codec?,

	key: string,
	qualified: string,
	id: number,
	handler: any,
}

--[[
	Every constructor takes its spec as a free generic and lets a type function do the checking.
	That is not the obvious shape, and three measurements forced it (`spike/declare/`):

	  1. `command<T>(spec: { data: Types.Type<T>, ... })` **does not bind `T`.** The solver resolves
	     it to `unknown`, so every channel's payload is lost and the directional views map nothing.
	     A minimal `{ __payload: T }` in `data`'s place does not help either. Reading `__payload`
	     out of an inferred spec is the only form that yields `{ origin: Vector3, seq: number }`.
	  2. Where `T` appeared in two positions — `data` and `authorize` — an unannotated policy
	     widened it to `any`, which silently disabled inference for the *whole channel*. Projecting
	     from `data` alone cannot be clobbered.
	  3. **Width subtyping accepts extra properties**, so a spec type listing only the allowed
	     fields forbids nothing: `intent({ data = ..., rate = 60, authorize = f })` type-checks
	     against a type with no `authorize`. A type function reading `readproperty` sees the field
	     and can refuse it.

	The third is why the messages here are worth writing carefully. A type function's `error()` is
	reported at the call site verbatim, so a bad declaration can say what to write instead of
	printing two structural table types and leaving the reader to diff them.

	A type function body sees only the `types` library — not this module's locals — so the reasons
	live inside `forbid` rather than in a constant table beside it.
]]
type function payloadOf(descriptor, field)
	local schema = types.copy(descriptor)
	local name = field:value()

	--[[ The same sentence twice, because the two failures are the same mistake seen from either
	     side: something that is not a netweave type, and something that is a table but not one. A
	     reader who hits either has written the same wrong thing. ]]
	--[[ Concatenated rather than interpolated: the advice has to show `t.struct({ ... })`, and a
	     brace inside an interpolated string is an interpolation. ]]
	--[[ `:value()` on a type object is `unknown` to the analyser, and concatenating an unknown is an
	     error inside netweave's own source — the one place a user cannot act on it. ]]
	local advice = "`"
		.. tostring(name)
		.. "` must be a netweave type. Build one with the type library: local t = nw.types, then "
		.. "t.struct({ ... }), t.u8, t.string(0, 32) or t.array(t.u16). A plain Luau table is not a "
		.. "schema — there is nothing in it to serialise from."

	if not schema:is("table") then
		error(advice)
	end

	local payload = schema:readproperty(types.singleton("__payload"))

	if not payload then
		error(advice)
	end

	return payload
end

type function propertyOf(spec, field)
	local declaration = types.copy(spec)

	if not declaration:is("table") then
		error(
			"a channel is declared with a table of fields, written inline. Use "
				.. "nw.signal({ data = ..., rate = 20 }) rather than a value built elsewhere and "
				.. "passed in: the fields have to be visible here for the analyzer to read them."
		)
	end

	return declaration:readproperty(types.singleton(field:value()))
end

type function requireRate(spec, class)
	local rate = propertyOf(spec, types.singleton("rate"))

	if not rate then
		error(
			`nw.{class:value()} needs \`rate\`, in packets per second per player. There is no `
				.. `unlimited: netweave guarantee G2.`
		)
	end

	if not rate:is("number") then
		error(
			"`rate` is a number of packets per second per player, written as a literal: "
				.. "nw.signal({ data = ..., rate = 20 }). There is no unlimited and no default — "
				.. "netweave guarantee G2."
		)
	end

	return rate
end

type function forbid(spec, class, field)
	local name = field:value()

	if not propertyOf(spec, field) then
		return types.singleton(true)
	end

	local reason = {
		authorize = "A channel that authorizes is a command or a query; an intent and a signal "
			.. "carry no authority by definition, and letting them approve requests would make "
			.. "the class name a lie. If you need to approve it, it is a command.",
		rate = "The server is the sender on this class, so there is nobody to budget.",
		burst = "Burst is the depth of the rate budget, and this class has no rate to be the depth of.",
		maxBytes = "This class is sent by the server, which is not a peer whose payload size needs "
			.. "policing. The schema still gives it a ceiling.",
		audience = "Only state and event have an audience; an inbound channel has exactly one "
			.. "recipient, which is the server.",
		timeout = "Only a query waits for a reply.",
		returns = "Only a query replies.",
		args = "This class carries `data`, not `args`.",
		data = "A query carries `args` and `returns`, not `data`.",
		unreliable = "This class must arrive. A command changes authoritative state and a query is "
			.. "waiting for an answer; delivering either at best effort would make the class name a "
			.. "promise it does not keep.",
	}

	error(`nw.{class:value()} forbids \`{name}\`. {reason[name]}`)
end

type function requireData(spec, class, field, purpose)
	local declared = propertyOf(spec, field)

	if not declared then
		error(`nw.{class:value()} needs \`{field:value()}\`, a netweave type describing {purpose:value()}`)
	end

	return payloadOf(declared, field)
end

--[=[
	@type CommandPayload<S> S
	@within Channel

	Checks a `command` declaration and projects the payload out of its `data`.
]=]
export type function CommandPayload(spec)
	local command = types.singleton("command")

	requireRate(spec, command)

	if not propertyOf(spec, types.singleton("authorize")) then
		error(
			"nw.command needs `authorize`. Build one with nw.policy, or compose several with "
				.. "nw.all. A command without authorization is the shape of every Roblox exploit "
				.. "writeup; if this channel genuinely carries no authority, declare it a signal."
		)
	end

	forbid(spec, command, types.singleton("audience"))
	forbid(spec, command, types.singleton("args"))
	forbid(spec, command, types.singleton("returns"))
	forbid(spec, command, types.singleton("timeout"))
	forbid(spec, command, types.singleton("unreliable"))

	return requireData(spec, command, types.singleton("data"), types.singleton("what the client sends"))
end

--[=[
	@type IntentPayload<S> S
	@within Channel
]=]
export type function IntentPayload(spec)
	local intent = types.singleton("intent")

	requireRate(spec, intent)

	forbid(spec, intent, types.singleton("authorize"))
	forbid(spec, intent, types.singleton("audience"))
	forbid(spec, intent, types.singleton("returns"))
	forbid(spec, intent, types.singleton("timeout"))

	return requireData(spec, intent, types.singleton("data"), types.singleton("the input being observed"))
end

--[=[
	@type SignalPayload<S> S
	@within Channel
]=]
export type function SignalPayload(spec)
	local signal = types.singleton("signal")

	requireRate(spec, signal)

	forbid(spec, signal, types.singleton("authorize"))
	forbid(spec, signal, types.singleton("audience"))
	forbid(spec, signal, types.singleton("returns"))
	forbid(spec, signal, types.singleton("timeout"))

	return requireData(spec, signal, types.singleton("data"), types.singleton("what the client sends"))
end

--[=[
	@type QueryArgs<S> S
	@within Channel
]=]
export type function QueryArgs(spec)
	local query = types.singleton("query")

	requireRate(spec, query)

	if not propertyOf(spec, types.singleton("authorize")) then
		error(
			"nw.query needs `authorize`. A query reads authoritative state, and a read is how an "
				.. "exploit finds what to write."
		)
	end

	if not propertyOf(spec, types.singleton("timeout")) then
		error("nw.query needs `timeout`, in seconds. A request that never resolves is a leak.")
	end

	forbid(spec, query, types.singleton("data"))
	forbid(spec, query, types.singleton("audience"))
	forbid(spec, query, types.singleton("unreliable"))

	return requireData(spec, query, types.singleton("args"), types.singleton("the request"))
end

--[=[
	@type QueryReturns<S> S
	@within Channel
]=]
export type function QueryReturns(spec)
	return requireData(
		spec,
		types.singleton("query"),
		types.singleton("returns"),
		types.singleton("the reply")
	)
end

--[=[
	@type OutboundPayload<S> S
	@within Channel

	Shared by `state` and `event`: both are server-to-client, so both forbid a budget and a policy.
]=]
export type function OutboundPayload(spec, class)
	forbid(spec, class, types.singleton("rate"))
	forbid(spec, class, types.singleton("burst"))
	forbid(spec, class, types.singleton("maxBytes"))
	forbid(spec, class, types.singleton("authorize"))
	forbid(spec, class, types.singleton("args"))
	forbid(spec, class, types.singleton("returns"))
	forbid(spec, class, types.singleton("timeout"))

	return requireData(spec, class, types.singleton("data"), types.singleton("what the server sends"))
end

--[=[
	@type OutboundScope<S> "everyone" | "subset"
	@within Channel

	Projects the declared audience's scope, which is what decides whether `broadcast` exists on the
	server view. Guarantee G3 is this type function and the branch it feeds in `src/api/View.luau`.
]=]
export type function OutboundScope(spec)
	local audience = propertyOf(spec, types.singleton("audience"))

	if not audience then
		error(
			"this channel needs `audience`. Use nw.audience.everyone, nw.audience.owner, "
				.. "nw.audience.nearby(studs) or nw.audience.select(fn). There is no default: "
				.. "broadcasting everything to everyone is how positional data reaches a wallhack, "
				.. "so the recipient set is a declaration rather than a call site. Guarantee G3."
		)
	end

	local scope = types.copy(audience):readproperty(types.singleton("scope"))

	if not scope then
		error(
			"`audience` must come from nw.audience: use nw.audience.everyone, nw.audience.owner, "
				.. "nw.audience.nearby(studs) or nw.audience.select(fn). A plain table will not do, "
				.. "because the scope has to be a singleton in the type for `broadcast` to exist only "
				.. "where it is safe (guarantee G3)."
		)
	end

	return scope
end

local function isType(value: any): boolean
	return type(value) == "table" and type(value.kind) == "string"
end

local function requireType(spec: any, field: string, class: string): Types.Descriptor
	local value = spec[field]

	if not isType(value) then
		error(`nw.{class} needs {field} to be a netweave type, got {typeof(value)}`, 3)
	end

	return value
end

--[[
	`rate` is checked at declaration rather than trusted, because G2 says there is no unlimited and
	a `rate` of `math.huge` would be exactly that with the type system none the wiser.
]]

--[[
	A rate above this is documentation, not a limit. One client at 60 fps sending 166 packets a
	frame is already an order of magnitude past any shipped game, so a declaration above it admits
	everything the platform can physically deliver — which is what G2 exists to stop being written
	by accident.

	It is a lint rather than a rejection because the number is legitimate in a benchmark, where the
	point is to measure the library and not the budget. `bench/src/shared/Modes/netweave.luau`
	declares 1e6 and turns this rule off, in that order, which is the intended shape: a considered
	exception, written down.
]]
local BINDING_RATE = 10000

local function lintRate(rate: number, class: string)
	if rate <= BINDING_RATE then
		return
	end

	local level = Config.severityOf("rateUnbounded")

	if level == "off" then
		return
	end

	local message = `nw.{class} declares rate = {rate}, which no client can reach — the channel is `
		.. `effectively unlimited (netweave guarantee G2). Declare the rate the game actually needs, `
		.. `or set rules.rateUnbounded = "off" if this is deliberate.`

	--[[ This one fires on the game's own declaration rather than on wire data, which is why it is
	     allowed to raise at all. G4 covers the receive path; a declaration is programmer error and
	     `CLAUDE.md` §4 says that is what raising is for. ]]
	if Config.raises("rateUnbounded") then
		error(message, 4)
	end

	warn(`[netweave] {message}`)
end
local function checkedRate(spec: any, class: string): number
	local rate = spec.rate

	if type(rate) ~= "number" or rate ~= rate or rate <= 0 or rate == math.huge then
		error(
			`nw.{class} needs a positive finite rate in packets per second, got {tostring(rate)}. `
				.. `There is no unlimited: netweave guarantee G2.`,
			3
		)
	end

	lintRate(rate, class)

	return rate
end

--[[
	The depth of the bucket, and optional: omitting it means one second.s worth, which is the safe
	reading of silence. Declaring it is how a game says "this channel is bursty" — an input the codec
	sends in a flurry on a key press and then not at all — without also raising the sustained rate,
	which is what a game would otherwise have to do and is the thing `rate` exists to bound.

	Below `rate` is refused rather than clamped. A depth under the rate cannot be honoured: tokens
	accrue at `rate` per second and the cap would throw the difference away every second, so the
	channel would run at the depth and the declared rate would be fiction.
]]
local function checkedBurst(spec: any, class: string, rate: number): number?
	local burst = spec.burst

	if burst == nil then
		return nil
	end

	if type(burst) ~= "number" or burst ~= burst or burst == math.huge or burst % 1 ~= 0 then
		error(`nw.{class} takes burst as a whole number of packets, got {tostring(burst)}`, 3)
	end

	if burst < rate then
		error(
			`nw.{class} declares burst = {burst} below rate = {rate}. The bucket refills at the rate, `
				.. `so a depth under it would be discarded every second and the rate would never be `
				.. `reached. Raise the burst, or lower the rate.`,
			3
		)
	end

	return burst
end

--[[
	Optional, and only ever a tightening. The schema already gives every channel a ceiling, so this
	exists for the case the schema cannot express: a channel whose type allows a megabyte because an
	array is unbounded, but whose game never sends more than a few hundred bytes. Declaring the
	smaller number turns a theoretical bound into a real one.
]]
local function checkedMaxBytes(spec: any, class: string): number?
	local maxBytes = spec.maxBytes

	if maxBytes == nil then
		return nil
	end

	if type(maxBytes) ~= "number" or maxBytes ~= maxBytes or maxBytes < 1 or maxBytes % 1 ~= 0 then
		error(`nw.{class} takes maxBytes as a whole number of bytes, at least 1, got {tostring(maxBytes)}`, 3)
	end

	return maxBytes
end

local function requirePolicy(spec: any, class: string): any
	local authorize = spec.authorize

	if not Policy.isPolicy(authorize) then
		error(
			`nw.{class} needs authorize. Build one with nw.policy, or compose several with `
				.. `nw.all. A {class} without authorization is the shape of every Roblox exploit `
				.. `writeup; if this channel genuinely carries no authority, declare it a signal.`,
			3
		)
	end

	return Policy.checkOf(authorize)
end

--[[
	The type system already refuses these, so reaching one of these messages means the declaration
	was written without the new solver (`PLAN-M1` D-7) or came through an `any`. The message has to
	say what to write instead, because at that point nothing else will.
]]
local FORBIDDEN_REASON: { [string]: string } = {
	authorize = "A channel that authorizes is a command or a query; a signal and an intent carry "
		.. "no authority by definition, and letting them approve requests would make the class "
		.. "name a lie.",
	rate = "The server is the sender on this class, so there is nobody to budget.",
	burst = "Burst is the depth of the rate budget, and this class has no rate to be the depth of.",
	maxBytes = "This class is sent by the server, which is not a peer whose payload size needs "
		.. "policing. The schema still gives it a ceiling.",
	audience = "Only state and event have an audience; an inbound channel has one recipient, "
		.. "which is the server.",
	timeout = "Only a query waits for a reply.",
	returns = "Only a query replies.",
	args = "This class carries `data`, not `args`.",
	data = "A query carries `args` and `returns`, not `data`.",
}

--[[
	Optional, and false unless it is exactly `true`. An unreliable channel is delivered at best
	effort and is not batched — one lost datagram would otherwise cost N events instead of one
	(`RESEARCH §3.7-E`) — so it is a per-channel decision the author makes on purpose.
]]
local function checkedUnreliable(spec: any, class: string): boolean
	local value = spec.unreliable

	if value ~= nil and type(value) ~= "boolean" then
		error(`nw.{class} takes unreliable as a boolean, got {typeof(value)}`, 3)
	end

	return value == true
end

local function requireAudience(spec: any, class: string): any
	local audience = spec.audience

	if type(audience) ~= "table" or type(audience.scope) ~= "string" then
		error(
			`nw.{class} needs an audience. Use nw.audience.everyone, nw.audience.owner, `
				.. `nw.audience.nearby(studs) or nw.audience.select(fn). There is no default: `
				.. `netweave guarantee G3.`,
			3
		)
	end

	return audience
end

local function rejectForbidden(spec: any, class: string, fields: { string })
	for _, field in fields do
		if spec[field] ~= nil then
			error(
				`nw.{class} forbids {field}. {FORBIDDEN_REASON[field] or "It has no meaning on this class."}`,
				3
			)
		end
	end
end

--[=[
	@within Channel
	@function directionOf
	@param class string
	@return (boolean, boolean) -- may the client send on it, may the server
	@private

	Which side may send on a class, as the receive path asks it.

	Exported rather than inlined into [make] because `tests/transport_runtime.luau` builds channel
	records by hand to keep its cases about the envelope, and a second copy of this table in a test
	is a table that drifts from the one that matters — which `CLAUDE.md` §9 has already been bitten
	by twice.
]=]
function Channel.directionOf(class: string): (boolean, boolean)
	local inbound = class == "command" or class == "intent" or class == "signal" or class == "query"
	local outbound = class == "state" or class == "event" or class == "query"

	return inbound, outbound
end

local function make(
	class: Class,
	primitive: Primitive,
	data: Types.Descriptor,
	fields: { [string]: any }
): any
	local channel: any = {
		class = class,
		primitive = primitive,
		data = data,
		codec = Serdes.fromSchema(data),

		--[[ Filled in by `nw.namespace`, and by the registry when the protocol is sealed. An id of
		     0 is reserved for control traffic, so it doubles as "not yet assigned"
		     (`WIRE-FORMAT.md` §3). ]]
		key = "",
		qualified = "",
		id = 0,
		handler = nil,
	}

	for field, value in fields do
		channel[field] = value
	end

	--[[
		Which side may **send** on this channel, as two booleans the receive path can read without a
		string compare.

		G6 says direction is a class rather than a field, and until M3 phase 9 it was enforced only
		on the views — at analysis time, on the game's own code. The wire had no opinion:
		`Namespace.channelById` resolved every id, `Budget.admit` returned nil for a class with no
		`rate` because there was nothing to charge, and a client's packet on a `nw.state` id was
		decoded and queued on the server. Six hundred of them measured `budget=0, queue=344`.

		Which also means the reason those classes may not declare a `rate` — "the server is the
		sender on this class, so there is nobody to budget" — rested on a check that did not exist.
		Now it does.

		`query` is on both lists and is the only class that is: a request goes one way and its reply
		comes back on the same id (`docs/WIRE-FORMAT.md` §2).
	]]
	channel.fromClient, channel.fromServer = Channel.directionOf(class)

	--[[
		The byte ceiling, derived from the schema and tightened by a declaration if there is one.

		Deriving it is what makes it universal: a game that declares nothing still gets a bound,
		because every netweave type is bounded and the layout can add them up. A declared `maxBytes`
		can only lower it — asking for more than the schema can produce is a number that could never
		be reached, and accepting it would let an author believe they had set a limit.

		The same disease has a second form, and it was live until an audit found it: a declaration on a
		**statically framed** channel is inert. A static payload carries no length prefix — the reader
		already knows where it ends — so there is no claim to check and the ceiling is never consulted.
		`maxBytes = 4` on a schema fixed at fourteen bytes was accepted, stored, and did nothing.
	]]
	local derived = channel.codec.maxSize
	local declared = channel.maxBytes

	if declared and channel.codec.framing == "static" then
		error(
			`nw.{class} declares maxBytes = {declared}, and this schema is a fixed {derived} bytes every `
				.. `time. A static payload carries no length to police — the size is guaranteed by the `
				.. `framing rather than by a check, so the declaration would do nothing. Remove it.`,
			3
		)
	end

	if declared and declared > derived then
		error(
			`nw.{class} declares maxBytes = {declared}, but this schema can never produce more than `
				.. `{derived} bytes. A ceiling above what the schema can reach is not a limit — remove it, `
				.. `or lower it to the size this channel should actually accept.`,
			3
		)
	end

	channel.maxBytes = declared or derived

	return channel
end

--[=[
	@within Channel
	@function command
	@param spec S -- the declaration: `data`, `rate`, `authorize`
	@return Channel<"command", "none", T, nil>

	A client-to-server channel that **changes authoritative state**. `authorize` is required.

	```lua
	fireWeapon = nw.command({
		data = ShotSchema,
		rate = 20,
		authorize = nw.all(policy.alive, policy.originNearCharacter),
	}),
	```

	The handler receives `Trusted<T>` — the payload decoded, in budget, and approved.
]=]
function Channel.command<S>(spec: S): Channel<"command", "none", CommandPayload<S>, nil>
	local raw: any = spec
	rejectForbidden(raw, "command", { "audience", "args", "returns", "timeout", "unreliable" })

	--[[ Once: `checkedRate` also runs the `rateUnbounded` lint, and a channel that warns twice for
	     one declaration is a channel whose warning gets ignored. ]]
	local rate = checkedRate(raw, "command")

	return make("command", "AuthorizedInbound", requireType(raw, "data", "command"), {
		rate = rate,
		burst = checkedBurst(raw, "command", rate),
		maxBytes = checkedMaxBytes(raw, "command"),
		authorize = requirePolicy(raw, "command"),
	})
end

--[=[
	@within Channel
	@function intent
	@param spec S -- data, rate
	@return Channel<"intent", "none", T, nil>

	A continuous observed input: movement, aim, a held button.

	```lua
	aim = nw.intent({
		data = t.struct({ pitch = t.f32(-90, 90), yaw = t.f32(-180, 180) }),
		rate = 60,
	}),
	```

	:::note
	An intent **coalesces**: at most one value per player per tick is delivered. Stale input has no
	value, so an attacker who fills the rate budget cannot convert that into per-packet server
	work. This is the one place merging is semantically safe — `RESEARCH §3.7-E` argues batching
	unreliable traffic is a semantic error in general, and losing a superseded input is the
	exception that proves it. Coalescing itself lands with the transport in M2.
	:::
]=]
function Channel.intent<S>(spec: S): Channel<"intent", "none", IntentPayload<S>, nil>
	local raw: any = spec
	rejectForbidden(raw, "intent", { "authorize", "audience", "args", "returns", "timeout" })

	--[[ Once: `checkedRate` also runs the `rateUnbounded` lint, and a channel that warns twice for
	     one declaration is a channel whose warning gets ignored. ]]
	local rate = checkedRate(raw, "intent")

	return make("intent", "AuthorizedInbound", requireType(raw, "data", "intent"), {
		rate = rate,
		burst = checkedBurst(raw, "intent", rate),
		maxBytes = checkedMaxBytes(raw, "intent"),
		unreliable = checkedUnreliable(raw, "intent"),
	})
end

--[=[
	@within Channel
	@function signal
	@param spec S -- data, rate
	@return Channel<"signal", "none", T, nil>

	A client-to-server channel that carries **no authority**: a menu opened, an emote played, a
	tutorial step acknowledged.

	```lua
	openedMenu = nw.signal({
		data = t.struct({ screen = t.u8(0, 8) }),
		rate = 2,
	}),
	```

	The handler receives `Untrusted<T>`.

	:::caution
	This is the class an author reaches for to avoid writing a policy, because it is the shortest
	thing that compiles. `Untrusted<T>` closes that route for code annotated `Trusted<T>`, and only
	for that code — the limit is stated in `DESIGN-API.md` §0 and §10.5 rather than papered over.
	:::
]=]
function Channel.signal<S>(spec: S): Channel<"signal", "none", SignalPayload<S>, nil>
	local raw: any = spec
	rejectForbidden(raw, "signal", { "authorize", "audience", "args", "returns", "timeout" })

	--[[ Once: `checkedRate` also runs the `rateUnbounded` lint, and a channel that warns twice for
	     one declaration is a channel whose warning gets ignored. ]]
	local rate = checkedRate(raw, "signal")

	return make("signal", "UntrustedInbound", requireType(raw, "data", "signal"), {
		rate = rate,
		burst = checkedBurst(raw, "signal", rate),
		maxBytes = checkedMaxBytes(raw, "signal"),
		unreliable = checkedUnreliable(raw, "signal"),
	})
end

--[=[
	@within Channel
	@function query
	@param spec S -- args, returns, rate, timeout, authorize
	@return Channel<"query", "none", T, R>

	A request that expects an answer. Authorized like a command, because it reads authoritative
	state and a read is how an exploit finds what to write.

	```lua
	getLoadout = nw.query({
		args = t.u8(0, 2),
		returns = t.struct({ primary = t.u16, secondary = t.u16 }),
		rate = 2,
		timeout = 5,
		authorize = policy.ownsSlot,
	}),
	```
]=]
function Channel.query<S>(spec: S): Channel<"query", "none", QueryArgs<S>, QueryReturns<S>>
	local raw: any = spec
	rejectForbidden(raw, "query", { "data", "audience", "unreliable" })

	--[[ Once: `checkedRate` also runs the `rateUnbounded` lint, and a channel that warns twice for
	     one declaration is a channel whose warning gets ignored. ]]
	local rate = checkedRate(raw, "query")

	local timeout = raw.timeout

	if type(timeout) ~= "number" or timeout ~= timeout or timeout <= 0 or timeout == math.huge then
		error(
			`nw.query needs a positive finite timeout in seconds, got {tostring(timeout)}. `
				.. `A request that never resolves is a leak.`,
			2
		)
	end

	local returns = requireType(raw, "returns", "query")

	--[[
		`invoke` reports failure as `nil`, so an answer that can legitimately *be* nil would make the
		two indistinguishable: a handler returning nothing and a server that never replied would
		reach the caller as the same value, and the caller's `if answer then` would be right about
		one of them by accident.

		Refused at the declaration rather than papered over at the call site, because the fix is a
		line the author writes once — wrap it in a struct, and "no loadout" becomes a field that says
		so (`DESIGN-API.md` §7).
	]]
	if returns.kind == "optional" then
		error(
			"nw.query cannot return an optional at the top level. invoke() reports failure by "
				.. "returning nil, so an answer that may itself be nil cannot be told apart from a "
				.. "call that never came back. Wrap it, and the absence becomes a field that says "
				.. "so: returns = t.struct({ found = t.boolean, value = t.optional(...) }).",
			2
		)
	end

	local channel = make("query", "AuthorizedInbound", requireType(raw, "args", "query"), {
		rate = rate,
		burst = checkedBurst(raw, "query", rate),
		maxBytes = checkedMaxBytes(raw, "query"),
		authorize = requirePolicy(raw, "query"),
		timeout = timeout,
		returns = returns,
		responseCodec = Serdes.fromSchema(returns),
	})

	--[[
		The reply gets a ceiling of its own, derived the same way `make` derives the request's.

		Not declarable, and that asymmetry is the point: `maxBytes` exists to police a *peer*, and
		the peer on a query is the client asking the question. The answer is this server's own bytes,
		so the number here is a check on netweave and on the game's handler rather than on anyone
		else — which is exactly what a derived bound is good at and what a declared one would only
		make configurable.
	]]
	channel.replyMaxBytes = channel.responseCodec.maxSize

	return channel
end

--[=[
	@within Channel
	@function state
	@param spec S -- data, audience
	@return Channel<"state", Scope, T, nil>

	Server-to-client replicated state.

	```lua
	playerState = nw.state({
		data = t.struct({ entityId = t.u16, position = t.vector3 }),
		audience = nw.audience.nearby(120),
	}),
	```

	`broadcast` exists on this channel only if the audience is [Audience.everyone]. That is
	guarantee G3, and it is a type error rather than a runtime check — broadcasting positional
	data to everyone is how wallhacks are fed, and a call site that does it is invisible in review.
]=]
function Channel.state<S>(spec: S): Channel<"state", OutboundScope<S>, OutboundPayload<S, "state">, nil>
	local raw: any = spec
	rejectForbidden(raw, "state", { "rate", "burst", "maxBytes", "authorize", "args", "returns", "timeout" })

	return make("state", "Outbound", requireType(raw, "data", "state"), {
		audience = requireAudience(raw, "state"),
		unreliable = checkedUnreliable(raw, "state"),
	})
end

--[=[
	@within Channel
	@function event
	@param spec S -- data, audience
	@return Channel<"event", Scope, T, nil>

	A server-to-client occurrence — something happened, once.

	```lua
	hitConfirmed = nw.event({
		data = t.struct({ victim = t.u16, damage = t.u8 }),
		audience = nw.audience.owner,
	}),
	```

	The difference from [Channel.state] is what M4 does with it: state is a value that can be
	delta-replicated and re-sent to a late joiner, an event is a moment that cannot.
]=]
function Channel.event<S>(spec: S): Channel<"event", OutboundScope<S>, OutboundPayload<S, "event">, nil>
	local raw: any = spec
	rejectForbidden(raw, "event", { "rate", "burst", "maxBytes", "authorize", "args", "returns", "timeout" })

	return make("event", "Outbound", requireType(raw, "data", "event"), {
		audience = requireAudience(raw, "event"),
		unreliable = checkedUnreliable(raw, "event"),
	})
end

--[=[
	@within Channel
	@function isChannel
	@param value any
	@return boolean
	@private
]=]
function Channel.isChannel(value: any): boolean
	return type(value) == "table" and type((value :: any).primitive) == "string"
end

return Channel
