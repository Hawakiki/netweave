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

vault.client.inventory:listen(function(value)
	--[[ The whole value, not a patch. A client that had to know which of the two it was sent is a
	     client the library has failed (`DESIGN-API.md` §3). ]]
	local _total: number = value.hp + value.gold
end)

return nil
