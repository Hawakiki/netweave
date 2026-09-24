--!strict

--[[
	The declaration surface, asserted by assignment. This file must produce zero diagnostics.

	Everything here is a claim `docs/DESIGN-API.md` makes about types: that a payload type survives
	from `t.struct` through a channel declaration into a handler parameter, that the two directional
	views expose different methods, and that the trust brand reaches the handler. A claim of that
	kind is only tested by a file that type-checks — running it proves nothing, because at runtime
	none of it exists.

	The negative controls are in `tests/api_reject.luau`.
]]

local nw = require("../src/netweave")
local t = require("../src/types")

local Trust = require("../src/api/Trust")

local allow = nw.policy(function()
	return function()
		return nw.allow()
	end
end)

type Shot = { origin: Vector3, direction: Vector3, seq: number }
type Loadout = { primary: number, secondary: number }

local ShotSchema = t.struct({
	origin = t.vector3,
	direction = t.unitVector3,
	seq = t.u16,
})

--[[ ASSERTION: `t.struct` infers its payload, which is the property the whole surface rests on. ]]
local _schema: t.Type<Shot> = ShotSchema

local combat = nw.namespace("combat", {
	fireWeapon = nw.command({
		data = ShotSchema,
		rate = 20,
		authorize = allow,
	}),

	aim = nw.intent({
		data = t.struct({ pitch = t.f32(-90, 90), yaw = t.f32(-180, 180) }),
		rate = 60,
	}),

	openedMenu = nw.signal({
		data = t.struct({ screen = t.u8(0, 8) }),
		rate = 2,
	}),

	getLoadout = nw.query({
		args = t.u8(0, 2),
		returns = t.struct({ primary = t.u16, secondary = t.u16 }),
		rate = 2,
		timeout = 5,
		authorize = allow,
	}),

	playerState = nw.state({
		data = t.struct({ entityId = t.u16, grounded = t.boolean }),
		audience = nw.audience.nearby(120),
	}),

	roundOver = nw.event({
		data = t.struct({ winner = t.u16 }),
		audience = nw.audience.everyone,
	}),
})

local server = combat.server
local client = combat.client

-- ---------------------------------------------------------------------------------------------
-- The payload survives the mapping, per class
-- ---------------------------------------------------------------------------------------------

server.fireWeapon:listen(function(_ctx, shot)
	local _origin: Vector3 = shot.origin
	local _seq: number = shot.seq
end)

server.aim:listen(function(_ctx, look)
	local _pitch: number = look.pitch
	local _yaw: number = look.yaw
end)

server.openedMenu:listen(function(_ctx, opened)
	local _screen: number = opened.screen
end)

server.getLoadout:handle(function(_ctx, slot): Loadout
	local _n: number = slot
	return { primary = 1, secondary = 2 }
end)

client.playerState:listen(function(state)
	local _entity: number = state.entityId
	local _grounded: boolean = state.grounded
end)

client.roundOver:listen(function(over)
	local _winner: number = over.winner
end)

-- ---------------------------------------------------------------------------------------------
-- Direction (G6) and audience (G3), in the affirmative
-- ---------------------------------------------------------------------------------------------

client.fireWeapon:send({ origin = Vector3.zero, direction = Vector3.zAxis, seq = 1 })
client.aim:send({ pitch = 0, yaw = 0 })
client.openedMenu:send({ screen = 1 })

local _loadout: Loadout?, _failure: string? = client.getLoadout:invoke(0)

server.playerState:publish(nil, { entityId = 1, grounded = true })
server.roundOver:publish(nil, { winner = 2 })

--[[ `broadcast` exists here because `roundOver` declared `nw.audience.everyone`. That it is
     *absent* on `playerState` is the assertion, and it lives in `api_reject.luau`. ]]
server.roundOver:broadcast({ winner = 2 })

-- ---------------------------------------------------------------------------------------------
-- The trust brand
-- ---------------------------------------------------------------------------------------------

local function applyDamage(_shot: nw.Trusted<Shot>) end

server.fireWeapon:listen(function(_ctx, shot)
	--[[ ASSERTION: a command handler's payload is `Trusted<T>` and reaches an authoritative
	     function. If this stopped compiling, `command` would have stopped being the class that
	     means "approved". ]]
	applyDamage(shot)
end)

--[[
	ASSERTION: the brand built by `src/api/View.luau`'s type function and the one built by
	`src/api/Trust.luau`'s are the same type.

	They are necessarily written twice — a type function body has only the `types` library and
	cannot call across modules — so nothing but this assignment stops them drifting. If they drift,
	`Trusted<T>` in a game's own annotation silently stops matching what a handler receives, and
	every authoritative function starts accepting everything.
]]
local branded = (nil :: any) :: Trust.Trusted<Shot>
applyDamage(branded)

server.fireWeapon:listen(function(_ctx, shot)
	local sameShape: Trust.Trusted<Shot> = shot
	local _plain: Shot = sameShape
end)

--[[ ASSERTION: an untrusted payload is still usable as its plain type. The brand is a subtype, so
     reading, logging and arithmetic work without ceremony — that is the whole reason it is an
     intersection rather than a wrapper (`DESIGN-API.md` §6). ]]
server.openedMenu:listen(function(_ctx, opened)
	local _plain: { screen: number } = opened
	local _sum: number = opened.screen + 1
end)

--[[ ASSERTION: a scalar payload is *not* branded, because `number & { tag }` normalises to `never`
     and a `never` satisfies every parameter rather than none (`src/api/Trust.luau`). This is a
     documented limit, so it is pinned rather than left to be discovered. ]]
local _scalarTrusted: number = (nil :: any) :: nw.Trusted<number>
local _scalarUntrusted: number = (nil :: any) :: nw.Untrusted<number>

-- ---------------------------------------------------------------------------------------------
-- validate, the third producer of Trusted
-- ---------------------------------------------------------------------------------------------

local checked = nw.validate(ShotSchema, nil :: any)

if checked ~= nil then
	applyDamage(checked)
end

-- ---------------------------------------------------------------------------------------------
-- Policies, contexts and rejections
-- ---------------------------------------------------------------------------------------------

local nearCharacter = nw.policy(function(config)
	local maxStuds: number = config.maxStuds or 8

	return function(ctx: nw.Ctx, shot: Shot)
		local character = ctx.character

		if not character then
			return nw.deny("no character")
		end

		local root = character.PrimaryPart

		if not root or (shot.origin - root.Position).Magnitude > maxStuds then
			return nw.deny("origin detached")
		end

		return nw.allow(shot)
	end
end)

local _composed = nw.all(allow, nearCharacter({ maxStuds = 12 }))

local _stop: () -> () = nw.observe(function(rejection: nw.Rejection)
	local _channel: string = rejection.channel
	local _stage: nw.Stage = rejection.stage
	local _bytes: number = rejection.bytes
end)

local protocol: nw.Protocol = nw.protocol()
local _count: number = protocol.count
local _first: string = protocol.names[1]

-- ---------------------------------------------------------------------------------------------
-- Trust: what still has to compile
-- ---------------------------------------------------------------------------------------------

local function authoritative(_request: nw.Trusted<{ screen: number }>) end

--[[ The three producers, each of which must keep working. `tests/api_reject.luau` cases 16 to 19
     are the other half: nothing else may produce one. ]]
server.openedMenu:listen(function(_ctx, opened)
	--[[ Reading through the brand is the whole reason it is an intersection rather than a wrapper.
	     Logging, arithmetic and UI have to work without ceremony or the brand gets cast away on
	     the first line of every handler. ]]
	local _screen: number = opened.screen
	local _doubled: number = opened.screen * 2
end)

local validated = nw.validate(t.struct({ screen = t.u8 }), { screen = 1 })

if validated then
	authoritative(validated)
end

--[[ The escape hatch, and it is deliberately a cast rather than a function.

     Server-authored data that never came off a wire has nothing to validate against and no reason
     to pay for a serialisation, so there has to be a way to say "I am taking responsibility for
     this". A cast is that way: explicit, greppable, and impossible to write by accident — which
     an `nw.trust(value)` helper would not be. §6's "there is no `nw.untrust`" is the same
     argument from the other side. ]]
local configured: { screen: number } = { screen = 3 }

authoritative((configured :: any) :: nw.Trusted<{ screen: number }>)

--[[
	A replicated channel, declared and listened to.

	`tests/api_reject.luau` cases 20-23 are the four ways to get this wrong, and `CLAUDE.md` §9 says
	a feature whose only test is a rejection file has no test — `nw.configure` shipped typed so that
	Luau refused every call and the rejection count counted the bug. So this is the half that has to
	work: the declaration analyses, the client's handler receives the payload with its fields
	readable, and the store is an ordinary table.
]]
local held: { [number]: { hp: number, gold: number } } = { [1] = { hp = 10, gold = 5 } }

local vault = nw.namespace("vault", {
	inventory = nw.replicate({
		subject = t.u16,
		data = t.struct({ hp = t.u8, gold = t.u16 }),
		audience = nw.audience.owner,
		store = nw.store.of(held),
	}),
})

vault.client.inventory:listen(function(subject, value)
	--[[ The subject, then the whole value — not a patch. A client that had to know which of the two
	     it was sent is a client the library has failed (`DESIGN-API.md` §3), and one that could not
	     tell its subjects apart could not keep a mirror at all.

	     Both are typed from the declaration: `subject` is `t.u16`'s payload and `value` is `data`'s.
	     Before `ReplicateSubject` existed this signature took one argument at analysis and was
	     handed two at runtime, so `value` here was the id. ]]
	local _total: number = subject + value.hp + value.gold
end)

--[[
	The exported types a game writes down, written down.

	`tools/exports.luau` requires every `export type` on the public surface to appear in a file that
	must compile, and these three had no such file — not because they are broken but because nothing
	had ever annotated them. That is the same gap `nw.configure` shipped through in M3 phase 0, and
	the reason the rule is "write the `_ok` half" rather than "write a test".

	The ones still missing are listed in `tools/exports.luau` with the reason, and three of them are
	findings rather than gaps: `nw.Views`, `nw.Settings` and `t.PayloadOf` cannot be annotated
	correctly today.
]]
--[[
	**How a namespace is written down, and the one spelling that must not be used.**

	`nw.Views<D>` names what `nw.namespace` returns. Three of the four ways to write it keep every
	guarantee; the fourth — an annotated local with a value assigned into it — makes the file stop
	reporting anything about that namespace, retroactively. It is pinned as a canary at the end of
	`tests/api_reject.luau`, and the caution is on `View.Views` where a game reads it.

	What this section is for is the other three: they are what the documentation tells a game to
	write, so they are what has to keep compiling.
]]
local shots = nw.namespace("shots", {
	fired = nw.command({ data = t.struct({ x = t.u8 }), rate = 20, authorize = allow }),
})

--[[ A parameter, which is the shape a game reaches for first: a module that takes the namespace
     rather than requiring it. ]]
local function attach(namespace: nw.Views<typeof(shots.channels)>)
	namespace.server.fired:listen(function(_ctx, payload)
		local _read: number = payload.x
	end)
end

--[[ Bare, and safe *here*: this namespace has one channel. On a namespace of about nine, passing it
     bare makes the payload of a handler written earlier `unknown` — `spike/declare/passed.luau`, and
     `tests/tutorial_ok.luau` casts at the call for that reason. Do not copy this line into a dense
     file (`PLAN-M5` phase 1). ]]
attach(shots)

--[[
	**A handler's `ctx` is `nw.Ctx`**, which is what `PLAN-M5` phase 1 closed.

	It was a shape the view built with `player`, `character` and `humanoid` left `unknown`, on the
	grounds that a `type function` body cannot name `Player`, `Model` or `Humanoid`. It cannot name
	one — but it can be handed one, because a type function's arguments are types, so `Views<D>`
	instantiates the mappers with `Context.Ctx`. What that buys is below: the fields read at their
	real types, the whole `ctx` assignable to `nw.Ctx`, and a typo still caught.
]]
local function whoFor(_player: Player, _slot: number) end

local function pivotOf(ctx: nw.Ctx): CFrame?
	local character = ctx.character
	return character and character:GetPivot()
end

shots.server.fired:listen(function(ctx, payload)
	local _id: number = ctx.player.UserId
	local _name: string = ctx.player.Name
	local _humanoid: Humanoid? = ctx.humanoid
	local _channel: string = ctx.channel
	local _now: number = ctx.now

	whoFor(ctx.player, payload.x)
	local _pivot: CFrame? = pivotOf(ctx)
end)

--[[ A cast, and `typeof` — the two spellings for a local. Both keep the views typed; the cast is
     the one to reach for when the type has to be named. ]]
local byCast = shots :: nw.Views<typeof(shots.channels)>
local byTypeof: typeof(shots) = shots

byCast.client.fired:send({ x = 1 })
byTypeof.client.fired:send({ x = 2 })

--[[
	**An optional payload keeps its brand**, which is the pair of type functions that lost it.

	`T?` is a union, and both `Trust.branded` and `View.brandedAs` tested `value:is("table")` alone —
	false for a union — so a `signal` whose data is `t.optional(struct)` handed its handler a plain
	table and `nw.Trusted<Req?>` reduced to `Req?`. The two coincided: untrusted client data reached
	a parameter annotated for trusted data with no cast anywhere to grep for (M4 report).

	The two branding sites are copies — a type function's body cannot reach another module's value —
	so this is what holds them together. If either drifts, this assignment stops compiling.
]]
local optionals = nw.namespace("optionals", {
	menu = nw.signal({ data = t.optional(t.struct({ screen = t.u8 })), rate = 10 }),
})

optionals.server.menu:listen(function(_ctx, payload)
	local _asDeclared: nw.Untrusted<{ screen: number }?> = payload

	--[[ And the brand survives the narrowing an optional forces a game to write. ]]
	if payload then
		local _narrowed: nw.Untrusted<{ screen: number }> = payload
		local _screen: number = payload.screen
	end
end)

local _verdict: nw.Verdict = nw.allow()
local _denied: nw.Verdict = nw.deny("out of range")

local diagnostics: nw.Diagnostics = nw.diagnostics()
local _refusals: number = diagnostics.total

--[[ A tally is reached through the diagnostics rather than built, so this is the annotation a game
     writes when it walks them — one channel, one stage, one count. ]]
for _, byStage in diagnostics.channels do
	for _, tally: nw.Tally in byStage do
		local _count: number = tally.count
	end
end

-- ---------------------------------------------------------------------------------------------
-- A public value gets a public type (PLAN-M5 phase 2, D-3)
-- ---------------------------------------------------------------------------------------------

--[[
	Every alias `nw` gained in M5, each in an annotation position that checks — a local holding the
	value the family produces, or a parameter the family consumes. `tools/exports` demands one per
	value family and reads this file for the coverage.
]]

type Kit = { primary: number }

--[[ `nw.Policy<T>`: the return of `nw.policy` and of `nw.all`, and the type of `authorize`. ]]
local canEquip: nw.Policy<Kit> = nw.policy(function()
	return function(_ctx: nw.Ctx, request: Kit)
		return if request.primary > 0 then nw.allow(request) else nw.deny("nothing equipped")
	end
end)

local _both: nw.Policy<Kit> = nw.all(canEquip, canEquip)

--[[ `nw.Check<T>` and `nw.Factory<T>`: the two halves before `nw.policy` wraps them, for a game that
     keeps them as values — a factory in one module, the wrapping in the declaration file. ]]
local checkEquip: nw.Check<Kit> = function(_ctx: nw.Ctx, request: Kit)
	return nw.allow(request)
end

local makeEquip: nw.Factory<Kit> = function(_config: any)
	return checkEquip
end

local _fromFactory: nw.Policy<Kit> = nw.policy(makeEquip)

--[[ `nw.Audience<S>`: what `nw.audience.*` are. The scope parameter is what gives or withholds
     `broadcast`, and both spellings have to name it. ]]
local _all: nw.Audience<"everyone"> = nw.audience.everyone
local _mine: nw.Audience<"subset"> = nw.audience.owner
local _close: nw.Audience<"subset"> = nw.audience.nearby(64)

--[[ `nw.Store`: what every `nw.store.*` constructor returns and `replicate` takes. ]]
local _plain: nw.Store = nw.store.of(held)
local _fromAtom: nw.Store = nw.store.charm(function()
	return held
end)

--[[ `nw.Observer`: the function `nw.observe` takes, for a game that builds one elsewhere. ]]
local logRefusals: nw.Observer = function(rejection: nw.Rejection)
	local _where: nw.Stage = rejection.stage
end

local _detach: () -> () = nw.observe(logRefusals)

--[[ `nw.Snapshot`, `nw.Rules`, `nw.Limits`, `nw.Described`: the settings both ways. A game that
     maps its own log level onto netweave's builds a `Rules` and hands it over; one with a
     diagnostics screen reads the snapshot and the descriptions back. ]]
local quiet: nw.Rules = { budget = "off", queue = "warn" }
local roomy: nw.Limits = { queueCapacity = 1024 }
local applied: nw.Snapshot = nw.configure({ rules = quiet, limits = roomy })
local _inForce: nw.Severity = applied.rules.budget
local _capacity: number = applied.limits.queueCapacity

local snapshot: nw.Snapshot = nw.config.snapshot()
local _again: nw.Severity = snapshot.rules.queue

for _, row: nw.Described in nw.config.describe() do
	local _rule: string = row.rule
	local _now: nw.Severity = row.severity
end

return nil
