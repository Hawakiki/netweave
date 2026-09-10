--!strict

--[[
	Every declaration and every call `docs/tutorial/` shows, in one file the analyzer has to accept.

	The tutorial is prose with code in it, and prose is not checked. This is the half that can be:
	each step's snippets, with the tutorial's `require(ReplicatedStorage.netweave.netweave)` replaced
	by the relative path so the types resolve, and nothing else changed. A method the tutorial names
	that does not exist, a field a class forbids, a payload shape that does not match its schema — all
	of those are diagnostics here before they are a reader's confusion there.

	Analysis only, like every `_ok` file: the Studio runner picks up `_runtime` modules and lune runs
	the same list, so nothing in here executes. The step each block comes from is named above it.
]]

local nw = require("../src/netweave")

--[[ Required directly rather than taken as `nw.types`, because the type names — `t.PayloadOf`,
     `t.Type`, `t.InstanceOptions` — hang off the module and a value cannot carry them. Step 9 says
     so; the values are the same either way. ]]
local t = require("../src/types")

local refusals: { string } = {}
local held: { [number]: { hp: number, gold: number }? } = {}

-- ---------------------------------------------------------------------------------------------
-- Step 2 — a placeholder policy, and the first two channels
-- ---------------------------------------------------------------------------------------------

local Equip = t.struct({ slot = t.u8(0, 9) })

local allow = nw.policy(function()
	return function()
		return nw.allow()
	end
end)

--[[ The vocabulary block, each spelling as the step shows it. ]]
local _u8 = t.u8
local _u16 = t.u16
local _u32 = t.u32
local _i8 = t.i8
local _i16 = t.i16
local _i32 = t.i32
local _f32 = t.f32
local _f64 = t.f64
local _narrowed = t.u16(0, 1000)
local _boolean = t.boolean
local _text = t.string(0, 32)
local _weapon = t.enum({ primary = true, secondary = true })
local _maybe = t.optional(t.u16)
local _list = t.array(t.u8, 0, 8)
local _byName = t.map(t.string(1, 16), t.u8)
local _position = t.vector3
local _placed = t.vector3(t.i16(-2048, 2048))
local _direction = t.unitVector3
local _cframe = t.cframe
local _colour = t.color3
local _part = t.instance("BasePart")
local _player = t.player

-- ---------------------------------------------------------------------------------------------
-- Step 3 — two real policies
-- ---------------------------------------------------------------------------------------------

type Equip = { slot: number }

local policy = {}

policy.alive = nw.policy(function()
	return function(ctx: nw.Ctx, _request: Equip)
		return ctx.humanoid ~= nil and nw.allow() or nw.deny("dead")
	end
end)

policy.ownsSlot = nw.policy(function(config)
	local slots: number = config.slots or 3

	return function(_ctx: nw.Ctx, request: Equip)
		if request.slot > slots then
			return nw.deny(`slot {request.slot} is past the {slots} this player owns`)
		end
		return nw.allow(request)
	end
end)

--[[ What a check can see. ]]
policy.seen = nw.policy(function()
	return function(ctx: nw.Ctx, _request: Equip)
		local _player = ctx.player
		local _channel: string = ctx.channel
		local _now: number = ctx.now
		local _character = ctx.character
		local _humanoid = ctx.humanoid
		return nw.allow()
	end
end)

--[[ A value you already hold, checked without a wire. ]]
local trusted: nw.Trusted<Equip>?, reason: string? = nw.validate(Equip, { slot = 2 })
local _reason = reason

local function authoritative(_chosen: nw.Trusted<Equip>) end

if trusted then
	authoritative(trusted)
end

-- ---------------------------------------------------------------------------------------------
-- Steps 2, 4 and 7 — the namespace, with every class the tutorial declares
-- ---------------------------------------------------------------------------------------------

local combat = nw.namespace("combat", {
	equip = nw.command({
		data = Equip,
		rate = 5,
		authorize = nw.all(policy.alive, policy.ownsSlot({ slots = 3 })),
	}),

	loadout = nw.event({
		data = t.struct({ primary = t.u16 }),
		audience = nw.audience.owner,
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
		authorize = policy.alive,
	}),

	playerState = nw.state({
		data = t.struct({ entityId = t.u16, grounded = t.boolean }),
		audience = nw.audience.nearby(120),
		unreliable = true,
	}),

	roundOver = nw.event({
		data = t.struct({ winner = t.u16 }),
		audience = nw.audience.everyone,
	}),

	placeholder = nw.command({
		data = Equip,
		rate = 5,
		authorize = allow,
	}),
})

-- Step 4, server
combat.server.equip:listen(function(ctx, chosen)
	combat.server.loadout:publish(ctx.player, { primary = 100 + chosen.slot })
end)

-- Step 4, client
combat.client.loadout:listen(function(loadout)
	local _primary: number = loadout.primary
end)

combat.client.equip:send({ slot = 1 })
combat.client.equip:send({ slot = 7 })

-- Step 7
combat.server.aim:listen(function(_ctx, look)
	local _pitch: number = look.pitch
end)

combat.server.openedMenu:listen(function(_ctx, opened)
	local _opened = opened
end)

type Loadout = { primary: number, secondary: number }
local loadouts: { [any]: { Loadout } } = {}

combat.server.getLoadout:handle(function(ctx, slot)
	local player = ctx.player :: Player
	return loadouts[player][slot + 1]
end)

local loadout: Loadout?, failure: string? = combat.client.getLoadout:invoke(0)

if loadout then
	local _primary: number = loadout.primary
else
	local _failure = failure
end

combat.server.playerState:publish(nil, { entityId = 1, grounded = true })
combat.server.roundOver:publish(nil, { winner = 2 })
combat.server.roundOver:broadcast({ winner = 2 })

combat.client.aim:send({ pitch = 0, yaw = 0 })
combat.client.openedMenu:send({ screen = 1 })

-- ---------------------------------------------------------------------------------------------
-- Step 5 — refusals
-- ---------------------------------------------------------------------------------------------

local stop = nw.observe(function(rejection)
	if rejection.stage == "authorize" then
		refusals[#refusals + 1] = `{rejection.channel} at {rejection.stage}: {rejection.reason}`
	end

	local _player = rejection.player
	local _bytes: number = rejection.bytes
end)

stop()

local seen = nw.diagnostics()
local _total: number = seen.total
local _count: number = seen.channels["combat.equip"].authorize.count

nw.configure({
	rules = { authorize = "warn", budget = "off" },
	limits = { queueCapacity = 512 },
})

local _hash: number = nw.protocol().hash
local _signature: string = nw.signature()

-- ---------------------------------------------------------------------------------------------
-- Step 6 — a replicated store
-- ---------------------------------------------------------------------------------------------

local world: { [number]: { hp: number, gold: number } } = {}

local vault = nw.namespace("vault", {
	inventory = nw.replicate({
		subject = t.u16,
		data = t.struct({ hp = t.u8, gold = t.u16 }),
		audience = nw.audience.everyone,
		store = nw.store.of(world),
	}),
})

world[1] = { hp = 10, gold = 500 }
world[1].gold = 480

vault.client.inventory:listen(function(subject, value)
	held[subject] = value
end)

-- ---------------------------------------------------------------------------------------------
-- Step 7 — unreliable on an intent, and a select audience
-- ---------------------------------------------------------------------------------------------

local function teammatesOf(_player: Player): { Player }
	return {}
end

local squad = nw.namespace("squad", {
	move = nw.intent({
		data = t.struct({ x = t.f32, z = t.f32 }),
		rate = 60,
		unreliable = true,
	}),

	teamChat = nw.event({
		data = t.string(1, 200),
		audience = nw.audience.select(function(subject)
			return teammatesOf(subject :: Player)
		end),
	}),
})

squad.client.move:send({ x = 0, z = 0 })
squad.server.teamChat:publish(nil, "go")

-- ---------------------------------------------------------------------------------------------
-- Step 5 — the rest of the settings table
-- ---------------------------------------------------------------------------------------------

nw.configure({ rules = { rateUnbounded = "off" } })
nw.configure({ contextGuard = false })

local snapshot = nw.config.snapshot()
local _queue: string = snapshot.rules.queue
local _capacity: number = snapshot.limits.queueCapacity
local _guarded: boolean? = snapshot.contextGuard

for _, described in nw.config.describe() do
	local _line = described
end

-- ---------------------------------------------------------------------------------------------
-- Step 8 — every spelling in the vocabulary, and a union that narrows
-- ---------------------------------------------------------------------------------------------

local _u53 = t.u53
local _i53 = t.i53
local _offset = t.u16(1000, 1255)
local _normal = t.quantized(-1, 1, 2 / 254)
local _heading = t.quantized(-180, 180, 0.25)
local _three = t.enum({ primary = true, secondary = true, melee = true })
local _named = t.string(1, 20, { utf8 = true, pattern = "[%w_]+" })
local _exact = t.array(t.u8, 100)
local _bytes = t.buffer(0, 900)
local _flat = t.vector2(t.i16(-1024, 1024))
local _compact = t.unitVector3(t.quantized(-1, 1, 2 / 254))
local _where: t.InstanceOptions = { descendantOf = workspace }
local _contained = t.instance("BasePart", _where)

local Action = t.union({
	move = t.struct({ x = t.u8, y = t.u8 }),
	wait = t.u8,
})

type Action = t.PayloadOf<typeof(Action)>
local _actionSchema: t.Type<Action> = Action

local function cost(action: Action): number
	if action.tag == "move" then
		return action.value.x + action.value.y
	end

	return action.value
end

local _cost: number = cost({ tag = "wait", value = 3 })

-- ---------------------------------------------------------------------------------------------
-- Step 9 — the types, named
-- ---------------------------------------------------------------------------------------------

local function equipFor(_player: Player, _chosen: nw.Trusted<Equip>) end

combat.server.equip:listen(function(ctx, chosen)
	equipFor(ctx.player :: Player, chosen)
end)

combat.server.openedMenu:listen(function(_ctx, opened)
	local _screen: number = opened.screen
end)

local authored = ({ slot = 1 } :: any) :: nw.Trusted<Equip>
equipFor(nil :: any, authored)

local SPAWN = Vector3.new(0, 0, 0)

local function nearSpawn(ctx: nw.Ctx): boolean
	local character = ctx.character
	return character ~= nil and (character:GetPivot().Position - SPAWN).Magnitude < 50
end

policy.nearSpawn = nw.policy(function()
	return function(ctx: nw.Ctx, _request: Equip)
		return nearSpawn(ctx) and nw.allow() or nw.deny("too far from spawn")
	end
end)

local Shot = t.struct({ origin = t.vector3, seq = t.u16 })
type Shot = t.PayloadOf<typeof(Shot)>
local _shotSchema: t.Type<Shot> = Shot
local _shot: Shot = { origin = Vector3.zero, seq = 1 }

local function wire(namespace: nw.Views<typeof(combat.channels)>)
	namespace.server.equip:listen(function(_ctx, _chosen) end)
end

--[[ Cast at the call, not passed bare. Measured while writing the tutorial: `wire(combat)` — and
     a parameter typed `typeof(combat)` alike — turns the payloads of the handlers written on
     `combat` *above* this line into `unknown`, retroactively, on a namespace that has already been
     used; `tests/api_ok.luau`'s `attach(shots)` passes because `shots` is used nowhere else. The
     cast is the spelling that keeps every handler typed, and step 9 says so (PLAN-M5 phase 1). ]]
wire(combat :: nw.Views<typeof(combat.channels)>)

local function onRejection(rejection: nw.Rejection)
	local stage: nw.Stage = rejection.stage
	local _stage = stage
end

nw.observe(onRejection)

local level: nw.Severity = "warn"
local settings: nw.Settings = { rules = { budget = level } }
nw.configure(settings)

local function verdictOf(ok: boolean): nw.Verdict
	return if ok then nw.allow() else nw.deny("no")
end

local _verdict = verdictOf(true)
local _diagnostics: nw.Diagnostics = nw.diagnostics()
local _schema: t.Type<number> = t.u8
local _ranged: t.Ranged<number> = t.u16
local _text: t.Text = t.string
local _componented: t.Componented<Vector3> = t.vector3
local _classed: t.Classed = t.instance

return true
