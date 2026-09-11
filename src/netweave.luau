--!strict
--!optimize 2

--[=[
	@class netweave

	A Roblox networking library whose first-order goals are security and structure.

	```lua
	local nw = require(Packages.netweave)
	local t = nw.types

	return nw.namespace("combat", {
		fireWeapon = nw.command({
			data = t.struct({ origin = t.vector3, direction = t.unitVector3, seq = t.u16 }),
			rate = 20,
			authorize = nw.all(policy.alive, policy.originNearCharacter),
		}),

		playerState = nw.state({
			data = t.struct({ entityId = t.u16, position = t.vector3 }),
			audience = nw.audience.nearby(120),
		}),
	})
	```

	What makes this different from the libraries surveyed in `docs/RESEARCH-AND-PLAN.md` is not
	how a packet is sent — every one of them answers that about the same way. It is **what the API
	refuses to let you write**:

	| | Guarantee | Violating code |
	|---|---|---|
	| G1 | An inbound channel that changes authoritative state has no listener until a policy is attached | type error |
	| G2 | Every inbound channel declares a rate budget. There is no unlimited | type error |
	| G3 | Every server-to-client channel declares its audience. `broadcast` exists only where the audience is everyone | type error |
	| G4 | Wire data never reaches `error()`. Rejections are values, routed to an observer. The sidecar is wire data, and the read and dispatch phases are guarded rather than trusted | not expressible |
	| G5 | Length-prefixed framing: one malformed packet cannot stop the rest of its batch | not expressible |
	| G6 | Direction is a class, not a string field | type error |

	:::caution
	netweave **requires Luau's new type solver** (`LuauSolverV2`). Half the guarantees above are
	type errors or they are nothing, and on the stock solver you would see analysis errors inside
	code you did not write. See `docs/DESIGN-API.md` §7.
	:::
]=]

--[[
	The public surface is assembled here and nowhere else. Each module below owns one idea and is
	independently testable; this file exists so a game writes `nw.command` rather than requiring
	six paths, and so there is exactly one place to look for what netweave exposes.
]]

local Audience = require("./api/Audience")
local Driver = require("./transport/Driver")
local Channel = require("./api/Channel")
local Config = require("./api/Config")
local Context = require("./api/Context")
local Namespace = require("./api/Namespace")
local Protocol = require("./api/Protocol")
local Observer = require("./api/Observer")
local Policy = require("./api/Policy")
local Store = require("./replication/Store")
local Transport = require("./api/Transport")
local Trust = require("./api/Trust")
local Types = require("./types")
local View = require("./api/View")

--[[
	Requiring netweave inside Roblox installs the transport. There is nothing to configure and no
	step to remember: a game that declared its channels correctly has already said everything the
	transport needs, and an install call in every game would be a step to forget.

	The guard is a check rather than a `pcall`, so that a genuine failure inside `install` is loud.
	Under lune there is no `game`, and the whole transport is testable there because Roblox lives
	behind `Link` and `Recipients` (`tests/transport_runtime.luau`).
]]
if typeof(game) == "Instance" then
	Driver.install()
end

local nw = {}

--[=[
	@prop milestone string
	@within netweave

	Which milestone this build is. `"M5"`.

	It moves when the **plan** for the next milestone appears, not when that milestone's code lands,
	because the question this answers is "what was the tree doing when it produced that number" and
	a tree with `PLAN-M4.md` in it is doing M4. `master` still says M3, because that is where M3 is.

	netweave has no release versions yet, so this is the coarsest true thing it can say about
	itself, and it exists because something else needed it to be true: the benchmark writes the
	subject of every run into the run document, and it wrote `"M2"` for the whole of M3, because the
	string was typed into the harness rather than read from the library. A results file that
	misattributes its own subject is worse than one with no attribution — it is evidence for the
	wrong thing (`CLAUDE.md` §5). Read this instead of typing it.

	:::note
	The wire format has its own version, which is not this one and moves for different reasons. See
	`docs/WIRE-FORMAT.md` and `nw.protocol()`.
	:::
]=]
nw.milestone = "M5"

--[=[
	@prop types Types
	@within netweave

	The type vocabulary. One declaration yields the payload type, the validation and the
	serialisation.
]=]
nw.types = Types

--[=[
	@prop audience Audience
	@within netweave

	Who a `state` or `event` reaches. Guarantee G3.
]=]
nw.audience = Audience

-- Channel classes -------------------------------------------------------------------------------

nw.command = Channel.command
nw.intent = Channel.intent
nw.signal = Channel.signal
nw.query = Channel.query
nw.state = Channel.state
nw.event = Channel.event

--[=[
	@prop replicate (spec) -> Channel
	@within netweave

	Server-to-client state, sent as **changes** against what each client already has. The seventh
	class, and the one the server never calls: its `store` is the only way in.

	:::caution
	The value a handler receives is **frozen**: it is this client's baseline, and the next change is
	applied to it. `table.clone` it if you need one to write to.
	:::

	See `docs/DESIGN-API.md` §3, "Replication is a seventh class, not `state` growing up".
]=]
nw.replicate = Channel.replicate

--[=[
	@prop store Store
	@within netweave

	Where the game keeps what `nw.replicate` replicates. `nw.store.of` for a plain table,
	`nw.store.charm` for a Charm atom, `nw.store.replica` for ReplicaService.

	netweave never requires either library, and asks nothing of them either: a store is a shape
	rather than a dependency, and anything with `subjects()` and `read(subject)` is one.
]=]
nw.store = Store

-- Policies --------------------------------------------------------------------------------------

nw.policy = Policy.policy
nw.all = Policy.all
nw.allow = Policy.allow
nw.deny = Policy.deny

-- Trust -----------------------------------------------------------------------------------------

nw.validate = Trust.validate

-- Rejections ------------------------------------------------------------------------------------

nw.observe = Observer.observe

--[=[
	@within netweave
	@function diagnostics
	@return Observer.Diagnostics

	Every refusal since the counters were last reset, by channel and stage.

	```lua
	for channel, stages in nw.diagnostics().channels do
		for stage, tally in stages do
			print(channel, stage, tally.count, tally.bytes)
		end
	end
	```

	The console goes quiet after a few reports per channel and stage so a flood does not become the
	outage, which makes this the only way to answer "is this channel refusing more than it was" —
	the question that separates a bug from an attack.
]=]
nw.diagnostics = Observer.diagnostics

-- Settings --------------------------------------------------------------------------------------

--[=[
	@within netweave
	@function configure
	@param settings Config.Settings

	Global settings, in the shape ESLint made familiar.

	```lua
	nw.configure({
		rules = {
			budget = "warn",     -- a sender over its declared rate
			authorize = "error", -- with a traceback, and suppressed like any other
			handler = "warn",
		},
		limits = { queueCapacity = 512 },
	})
	```

	Call it before declaring channels: limits are read when the transport builds the thing they
	limit, and a queue that already exists keeps the capacity it was created with.

	:::caution `"off"` is discouraged, and it is not an off switch
	No severity turns enforcement off. A packet refused at `budget` is refused whatever `budget` is
	set to — `"off"` silences netweave's console output for that stage and nothing else, and
	callbacks attached with [netweave.observe] keep receiving it.

	Reach for `"off"` when a stage is *expected* to fire in normal play and the log is drowning
	something else out — a `signal` channel that refuses under load by design, say. Reaching for it
	because a warning is annoying removes the only notice a game gets that it is dropping traffic,
	which is the failure `RESEARCH §3.7-K` documents in Warp and the reason these defaults are on.
	:::
]=]
--[[ `S` alone, not `S & Config.Settings`. The intersection reads correctly and rejects every call:
     Luau binds `S` to the argument's own type and then wants the intersection to be exactly that,
     so a settings table that omits any optional field — which is all of them — fails. The names and
     the value types are both checked by `CheckedSettings`, which says what is wrong in one line
     rather than eight. ]]
nw.configure = function<S>(settings: S): Config.CheckedSettings<S, Config.Snapshot>
	Config.configure(settings :: any)

	--[[
		`contextGuard` is applied here rather than read inside `Context` because the guard is
		checked once per packet and `Config` would be a second table index on that path. Pushing it
		at configure time keeps the read side a single upvalue, which is what `CLAUDE.md` §4 asks
		of anything the receive loop touches.
	]]
	local guard = Config.contextGuard()

	if guard ~= nil then
		Context.setGuarded(guard)
	end

	--[[ The declared return is a type function the analyzer cannot reduce while `S` is free, so the
	     cast is the only way to say "this is that". The type function is in the signature for its
	     `error()`, which is what rejects a misspelled rule at the call site; the value handed back
	     is a plain snapshot either way. ]]
	return Config.snapshot() :: any
end

--[=[
	@within netweave
	@prop config Config
	@within netweave

	The settings themselves: `nw.config.snapshot()` for what is in force, `nw.config.describe()`
	for every rule with its default and one line on what it reports.
]=]
nw.config = Config

--[=[
	@within netweave
	@function namespace
	@param name string
	@param channels D -- a table of channels
	@return Views<D> -- `.server` and `.client`, typed per channel class

	Declares a namespace and returns its two directional views.

	```lua
	local combat = nw.namespace("combat", {
		fireWeapon = nw.command({ ... }),
	})

	combat.server.fireWeapon:listen(function(ctx, shot) end)
	combat.client.fireWeapon:send(shot)
	```

	The views are typed per channel class: a `command` has `listen` on the server and `send` on the
	client, and neither has the other. `combat.server.fireWeapon:send(...)` is an analysis error,
	not a runtime check — guarantee G6.
]=]
function nw.namespace<D>(name: string, channels: D): View.Views<D>
	return (Namespace.declare(name, channels :: any) :: any) :: View.Views<D>
end

--[=[
	@within netweave
	@function protocol
	@return Protocol

	The agreed protocol: an FNV-1a hash over every channel's name, class and **lowered schema**, plus
	the names themselves in id order.

	Both peers compute this independently and the client sends its hash as the first packet it ever
	sends. A peer whose hash differs is refused at stage `"protocol"` from that point on — every
	packet between them would otherwise decode as a different channel, successfully, and be handed
	to a handler as a well-formed payload (`docs/WIRE-FORMAT.md` §4).

	:::note
	The hash deliberately ignores `rate`, `burst`, `maxBytes`, `authorize`, `audience` and
	`unreliable`. Those are one side's policy, and a hash that moved when a server tuned a rate limit
	would force a client redeploy for a server-side edit.
	:::
]=]
nw.protocol = Namespace.protocol

--[=[
	@within netweave
	@function signature
	@return string

	The text the protocol hash is taken over: every channel, in id order, with its class and the
	shape its schema lowered to.

	```lua
	print(nw.signature())
	--> combat.fireWeapon|command
	--> data=static/14/14/0:struct(origin:vector3(...)seq:number(storage=u16;...))
	```

	A hash that differs tells you *that* two builds disagree and nothing about where. Print this on
	both sides and diff it: the line that differs is the declaration that differs. That is the whole
	affordance, and without it "the hashes do not match" is a dead end.
]=]
nw.signature = function(): string
	local protocol = Namespace.protocol()
	local byName: { [string]: any } = {}

	for _, qualified in protocol.names do
		byName[qualified] = Namespace.channelByName(qualified)
	end

	return Protocol.signature(protocol.names, byName)
end

--[=[
	@type Trusted<T> T
	@within netweave

	A value that has passed the checks its channel declares.
]=]
export type Trusted<T> = Trust.Trusted<T>

--[=[
	@type Untrusted<T> T
	@within netweave

	A value that arrived from a client and conforms to its schema, and nothing more.
]=]
export type Untrusted<T> = Trust.Untrusted<T>

export type Ctx = Context.Ctx
export type Verdict = Policy.Verdict
export type Rejection = Observer.Rejection
export type Stage = Observer.Stage
export type Diagnostics = Observer.Diagnostics
export type Tally = Observer.Tally
export type Protocol = Namespace.Protocol
export type Views<D> = View.Views<D>
export type Severity = Config.Severity
export type Settings = Config.Settings

--[=[
	@prop internal table
	@within netweave
	@private

	The seams M2 attaches to, and the resets the test suite needs. Not part of the public surface:
	everything here either belongs to a milestone that has not landed or exists to undo state that
	a game has no reason to undo.
]=]
nw.internal = table.freeze({
	config = Config,
	transport = Transport,
	context = Context,
	observer = Observer,
	namespaces = Namespace,
	view = View,
})

return table.freeze(nw)
