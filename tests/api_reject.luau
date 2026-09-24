--!strict
-- netweave:expect 33

--[[
	The negative controls for the declaration surface. Every statement below **must** fail
	analysis, and `analyze.luau` fails the build if the count moves in either direction.

	This is the file that actually tests guarantees G1, G2, G3 and G6, because those guarantees
	are the absence of something: a declaration you cannot write, a method that is not there. A
	rejection file that stops erroring means a guarantee has silently stopped being enforced,
	which is worse than a build break — nothing announces it.

	One diagnostic per numbered case. Adding a case means raising the header count.
]]

local nw = require("../src/netweave")
local t = require("../src/types")

local allow = nw.policy(function()
	return function()
		return nw.allow()
	end
end)

type Shot = { origin: Vector3, seq: number }

local ShotSchema = t.struct({ origin = t.vector3, seq = t.u16 })
local StateSchema = t.struct({ entityId = t.u16 })

-- ---------------------------------------------------------------------------------------------
-- G2 — every inbound channel declares a rate budget
-- ---------------------------------------------------------------------------------------------

--[[ 1. A command with no rate. ]]
local _noRate = nw.command({ -- netweave:reject nw.command needs `rate`
	data = ShotSchema,
	authorize = allow,
})

--[[ 2. A signal with no rate. The class carries no authority, which does not make it free. ]]
local _signalNoRate = nw.signal({ -- netweave:reject nw.signal needs `rate`
	data = ShotSchema,
})

-- ---------------------------------------------------------------------------------------------
-- G1 — a state-changing channel has no listener until a policy is attached
-- ---------------------------------------------------------------------------------------------

--[[ 3. A command with no authorize. ]]
local _noPolicy = nw.command({ -- netweave:reject nw.command needs `authorize`
	data = ShotSchema,
	rate = 20,
})

--[[ 4. A query with no authorize. A read is how an exploit finds what to write. ]]
local _queryNoPolicy = nw.query({ -- netweave:reject nw.query needs `authorize`
	args = t.u8(0, 2),
	returns = StateSchema,
	rate = 2,
	timeout = 5,
})

--[[ 5. An intent that authorizes. Forbidden, or the class name is a lie: per-packet approval is
     exactly what an intent says it does not do. ]]
local _intentAuthorizes = nw.intent({ -- netweave:reject nw.intent forbids `authorize`
	data = ShotSchema,
	rate = 60,
	authorize = allow,
})

--[[ 6. A signal that authorizes. If you need to approve it, it was a command. ]]
local _signalAuthorizes = nw.signal({ -- netweave:reject nw.signal forbids `authorize`
	data = ShotSchema,
	rate = 2,
	authorize = allow,
})

-- ---------------------------------------------------------------------------------------------
-- G3 — every server-to-client channel declares its audience
-- ---------------------------------------------------------------------------------------------

--[[ 7. A state with no audience. There is no default, because the default everyone reaches for
     is "everyone", and that is how positional data feeds a wallhack. ]]
local _noAudience = nw.state({ -- netweave:reject needs `audience`
	data = StateSchema,
})

--[[ 8. An event that budgets. The server is the sender; there is nobody to rate limit. ]]
local _outboundRate = nw.event({ -- netweave:reject nw.event forbids `rate`
	data = StateSchema,
	audience = nw.audience.owner,
	rate = 10,
})

-- ---------------------------------------------------------------------------------------------
-- G6 — direction is a class, not a string field
-- ---------------------------------------------------------------------------------------------

local combat = nw.namespace("rejects", {
	fireWeapon = nw.command({ data = ShotSchema, rate = 20, authorize = allow }),
	openedMenu = nw.signal({ data = t.struct({ screen = t.u8 }), rate = 2 }),
	playerState = nw.state({ data = StateSchema, audience = nw.audience.nearby(120) }),
	roundOver = nw.event({ data = StateSchema, audience = nw.audience.everyone }),
})

--[[ 9. The server does not send. ]]
combat.server.fireWeapon:send({ origin = Vector3.zero, seq = 1 }) -- netweave:reject Key 'send' not found

--[[ 10. The client does not listen to a command. ]]
combat.client.fireWeapon:listen(function() end) -- netweave:reject Key 'listen' not found

--[[ 11. The client does not publish. ]]
combat.client.playerState:publish(nil, { entityId = 1 }) -- netweave:reject Key 'publish' not found

--[[ 12. `broadcast` exists only where the audience is everyone. `playerState` is `nearby(120)`,
     so the method is absent rather than present and refusing at runtime — the difference between
     a leak that never ships and one that ships and is found later. ]]
combat.server.playerState:broadcast({ entityId = 1 }) -- netweave:reject Key 'broadcast' not found

-- ---------------------------------------------------------------------------------------------
-- Trust
-- ---------------------------------------------------------------------------------------------

local function giveItem(_request: nw.Trusted<{ screen: number }>) end

--[[ 13. A signal's payload is `Untrusted<T>` and must not reach a function that declared
     `Trusted<T>`. This is the whole of §6 in one line; if it stops erroring, the brand has become
     decoration. ]]
combat.server.openedMenu:listen(function(_ctx, opened)
	giveItem(opened) -- netweave:reject '{ __nwTrusted: true } & { screen: number }'
end)

--[[ 14. `maxBytes` on a class the server sends. The server is not a peer whose payload size needs
     policing, and the schema gives every channel a ceiling regardless — so the field would be
     configuring a check that does not apply to it. ]]
local _oversizedEvent = nw.event({ -- netweave:reject nw.event forbids `maxBytes`
	data = t.struct({ seq = t.u16 }),
	audience = nw.audience.everyone,
	maxBytes = 4,
})

--[[ 15. And `burst`, for the same reason `rate` is forbidden here: the depth of a budget that
     does not exist. ]]
local _burstyEvent = nw.event({ -- netweave:reject nw.event forbids `burst`
	data = t.struct({ seq = t.u16 }),
	audience = nw.audience.everyone,
	burst = 30,
})

--[[ 16. A bare table literal claiming to be trusted.

     This is the case that made §6's central claim false until M3 phase 3. The tag used to be
     `{ __nwTrusted: true? }` — *optional* — and a table literal checked against an optional
     property is inferred to satisfy it, so any literal of the right shape was `Trusted<T>` and
     "only three things produce it" was not true. The tag is required now. ]]
giveItem({ screen = 1 }) -- netweave:reject missing field '__nwTrusted'

--[[ 17. The same laundering one step less obvious, and the one a programmer actually writes:
     take an untrusted payload apart and put it back together. The brand is on the container, so
     a new container is a new brand — which is exactly why the container's tag has to be
     something a literal cannot supply by accident. ]]
combat.server.openedMenu:listen(function(_ctx, opened)
	giveItem({ screen = opened.screen }) -- netweave:reject missing field '__nwTrusted'
end)

--[[ 18. Pins the `Untrusted` brand specifically.

     Case 13 above would still fail if `Untrusted` became `any` tomorrow, because what it really
     tests is the *absence* of `__nwTrusted`. This one fails only because `__nwUntrusted` is
     present and required, so it is the case that notices if that half turns into decoration —
     the failure `spike/declare/README.md` Q5 documents and that dropped M1's count from 13 to 8
     without anything announcing it. ]]
local function sanitise(_wire: nw.Untrusted<{ screen: number }>) end

sanitise({ screen = 1 }) -- netweave:reject missing field '__nwUntrusted'

--[[ 19. `nw.validate` takes a schema, and a policy is not one. The shared M3 plan proposed
     `nw.validate(policy)`; the implemented shape is `nw.validate(schema, value)` and this is the
     case that keeps the other reading from compiling. ]]
local _validatedByPolicy = nw.validate(allow, { screen = 1 }) -- netweave:reject nw.validate takes a netweave type

--[[ 20. `nw.replicate` without a `store`. netweave does not own the state it replicates, so there
     is nothing to send without one — and the store being required at *declaration* rather than at
     a call site is what makes it the only way in. ]]
local _storeless = nw.replicate({ -- netweave:reject nw.replicate needs `store`
	subject = t.u16,
	data = t.struct({ hp = t.u8 }),
	audience = nw.audience.everyone,
})

--[[ 21. And without a `subject`. It is the one class that names its subjects on the wire, because
     the client keeps a value per subject and has to know which one arrived. ]]
local _subjectless = nw.replicate({ -- netweave:reject nw.replicate needs `subject`
	data = t.struct({ hp = t.u8 }),
	audience = nw.audience.everyone,
	store = nw.store.of({}),
})

--[[ 22. **`unreliable` on a replicated channel**, which is the whole reason this is a class rather
     than a flag on `nw.state` (`PLAN-M4` D-1). A dropped `state` packet costs one tick; a dropped
     *change* leaves that client wrong for the session, because every later change is relative to a
     baseline it does not have. A single class with a flag meaning "fine" or "silently wrong
     forever" depending on its value is the shape this design exists to make unwritable. ]]
local _lossy = nw.replicate({ -- netweave:reject nw.replicate forbids `unreliable`
	subject = t.u16,
	data = t.struct({ hp = t.u8 }),
	audience = nw.audience.everyone,
	store = nw.store.of({}),
	unreliable = true,
})

--[[ 23. The server view of a replicated channel has **no `publish`**, and that absence is the
     class's argument made mechanical: the store is the only way in, so a second one would be a way
     to be wrong that nothing could detect. ]]
local world = nw.namespace("world", {
	inventory = nw.replicate({
		subject = t.u16,
		data = t.struct({ hp = t.u8 }),
		audience = nw.audience.everyone,
		store = nw.store.of({}),
	}),
})

world.server.inventory:publish(1, { hp = 1 }) -- netweave:reject Key 'publish' not found

--[[ 24. An **optional** payload carries the same brand a required one does, and until M4 it carried
     none: `T?` is a union, and the branding tested for a bare table. A `signal` handed its handler a
     plain `{ screen: number }?`, `nw.Trusted<Req?>` reduced to `Req?`, and the two coincided — so
     client data reached a function annotated for trusted data with nothing at the call site to see.
     `tests/api_ok.luau` holds the positive half; this is the one that must not compile. ]]
local function authoritativeOptional(_request: nw.Trusted<{ screen: number }?>) end

local menus = nw.namespace("menus", {
	open = nw.signal({ data = t.optional(t.struct({ screen = t.u8 })), rate = 10 }),
})

menus.server.open:listen(function(_ctx, request)
	authoritativeOptional(request) -- netweave:reject '({ __nwTrusted: true } & { screen: number })?'
end)

-- ---------------------------------------------------------------------------------------------
-- The canary: two diagnostics this file expects and does not get
-- ---------------------------------------------------------------------------------------------

--[[
	**Everything below this line should error and does not, and the header count says so by not
	counting it.**

	`local ns: nw.Views<D> = <a namespace>` — an annotated local with a value assigned into it —
	makes the whole file stop reporting anything about `ns`, retroactively. The two statements below
	are copies of cases 3 and 11 above; on their own they are two diagnostics, and after the
	annotation they are none.

	It is specifically that shape. Measured against the same declarations, at
	`--flag:LuauSolverV2=true`:

	  | written as | diagnostics |
	  |---|---|
	  | no annotation at all | 2 |
	  | `type V = nw.Views<D>`, never assigned through | 2 |
	  | `local v = ns :: nw.Views<D>` | 2 |
	  | `local v: nw.Views<D>` with no value | 2 |
	  | `local v: typeof(ns) = ns` | 2 |
	  | a parameter typed `nw.Views<D>`, called with `ns` | 2 |
	  | **`local v: nw.Views<D> = ns`** | **0** |

	So the working spellings outnumber the broken one and are the ones `tests/api_ok.luau` pins.
	What this section pins is the hazard itself: it is here because M4's security report found it,
	and because nothing in `tests/` had ever written `Views<` — the erasure removes diagnostics, so
	no rejection count could see it and no `_ok` file could either.

	**If the two statements below start erroring, the hazard is gone**: delete this section, lower the
	header by two, and take the caution off `View.Views` and `DESIGN-API.md` §7. That is the only way
	this file is allowed to hold code that does not error. ~~If the count moves to 25~~ — the count is
	the wrong instrument for it, because a case added anywhere else moves it too, which is what
	happened when the channel record's fields became `read`.
]]
--[[
	**A misspelt key is refused, and so is a key of the wrong type** (M4 report finding 45).

	Each class used to forbid a hand-picked list of keys belonging to *other* classes and check nothing
	else, so `maxbytes = 4`, `bursts = 50`, `authorise`, `Rate`, `timeOut` and `rate_` all compiled —
	the runtime ignored the key and the author believed a ceiling or a depth was set. Twenty-two such
	declarations produced one diagnostic in the M4 probe; they produce fifteen now. Each class passes
	the keys it takes and the walk reports the rest: a key of another class keeps that class's reason,
	anything else is a spelling and the message lists what the class does take.
]]
local _typoKey = nw.command({ data = t.struct({ x = t.u8 }), rate = 20, authorize = allow, maxbytes = 4 }) -- netweave:reject has no `maxbytes`
local _wrongClassKey =
	nw.command({ data = t.struct({ x = t.u8 }), rate = 20, authorize = allow, store = nw.store.of({}) }) -- netweave:reject forbids `store`
local _typoValue = nw.command({ data = t.struct({ x = t.u8 }), rate = 20, authorize = allow, maxBytes = "4" }) -- netweave:reject takes `maxBytes` as a number
local _typoBurst = nw.intent({ data = t.struct({ x = t.u8 }), rate = 60, burst = "60" }) -- netweave:reject takes `burst` as a number
local _typoUnreliable =
	nw.event({ data = t.struct({ x = t.u8 }), audience = nw.audience.everyone, unreliable = "yes" }) -- netweave:reject takes `unreliable` as a boolean
local _typoOnEvent =
	nw.event({ data = t.struct({ x = t.u8 }), audience = nw.audience.everyone, ratelimit = 5 }) -- netweave:reject has no `ratelimit`

--[[
	**A channel's fields are `read`, so switching a guarantee off takes a cast** (M4 report finding 6).

	`Inbound` reads `authorize`, `rate` and `maxBytes` per packet and treats a nil `authorize` as
	allow, so each of these was one typed line that took G1 or G2 off — and a reviewer grepping for
	`:: any` found nothing, because none was needed. The three below are the three the transport
	reads; `Channel.Channel` says why the record itself is not frozen at seal.
]]
local guarded = nw.namespace("guarded", {
	fire = nw.command({ data = t.struct({ x = t.u8 }), rate = 10, authorize = allow }),
})

guarded.channels.fire.authorize = nil -- netweave:reject Property authorize of table 'Channel<"command", "none", { x: number }, nil, nil>' is read-only
guarded.channels.fire.rate = 1000000000 -- netweave:reject Property rate of table 'Channel<"command", "none", { x: number }, nil, nil>' is read-only
guarded.channels.fire.maxBytes = 1000000000 -- netweave:reject Property maxBytes of table 'Channel<"command", "none", { x: number }, nil, nil>' is read-only

local canary = nw.namespace("canary", {
	fire = nw.command({ data = t.struct({ x = t.u8 }), rate = 10, authorize = allow }),
})

local _erased: nw.Views<typeof(canary.channels)> = canary

canary.server.fire:send({ x = 1 })

canary.server.fire:listen(function(_ctx, payload)
	local _mistyped: string = payload.x
end)

return nil
