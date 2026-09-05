--!strict
-- netweave:expect 19

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
local _noRate = nw.command({
	data = ShotSchema,
	authorize = allow,
})

--[[ 2. A signal with no rate. The class carries no authority, which does not make it free. ]]
local _signalNoRate = nw.signal({
	data = ShotSchema,
})

-- ---------------------------------------------------------------------------------------------
-- G1 — a state-changing channel has no listener until a policy is attached
-- ---------------------------------------------------------------------------------------------

--[[ 3. A command with no authorize. ]]
local _noPolicy = nw.command({
	data = ShotSchema,
	rate = 20,
})

--[[ 4. A query with no authorize. A read is how an exploit finds what to write. ]]
local _queryNoPolicy = nw.query({
	args = t.u8(0, 2),
	returns = StateSchema,
	rate = 2,
	timeout = 5,
})

--[[ 5. An intent that authorizes. Forbidden, or the class name is a lie: per-packet approval is
     exactly what an intent says it does not do. ]]
local _intentAuthorizes = nw.intent({
	data = ShotSchema,
	rate = 60,
	authorize = allow,
})

--[[ 6. A signal that authorizes. If you need to approve it, it was a command. ]]
local _signalAuthorizes = nw.signal({
	data = ShotSchema,
	rate = 2,
	authorize = allow,
})

-- ---------------------------------------------------------------------------------------------
-- G3 — every server-to-client channel declares its audience
-- ---------------------------------------------------------------------------------------------

--[[ 7. A state with no audience. There is no default, because the default everyone reaches for
     is "everyone", and that is how positional data feeds a wallhack. ]]
local _noAudience = nw.state({
	data = StateSchema,
})

--[[ 8. An event that budgets. The server is the sender; there is nobody to rate limit. ]]
local _outboundRate = nw.event({
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
combat.server.fireWeapon:send({ origin = Vector3.zero, seq = 1 })

--[[ 10. The client does not listen to a command. ]]
combat.client.fireWeapon:listen(function() end)

--[[ 11. The client does not publish. ]]
combat.client.playerState:publish(nil, { entityId = 1 })

--[[ 12. `broadcast` exists only where the audience is everyone. `playerState` is `nearby(120)`,
     so the method is absent rather than present and refusing at runtime — the difference between
     a leak that never ships and one that ships and is found later. ]]
combat.server.playerState:broadcast({ entityId = 1 })

-- ---------------------------------------------------------------------------------------------
-- Trust
-- ---------------------------------------------------------------------------------------------

local function giveItem(_request: nw.Trusted<{ screen: number }>) end

--[[ 13. A signal's payload is `Untrusted<T>` and must not reach a function that declared
     `Trusted<T>`. This is the whole of §6 in one line; if it stops erroring, the brand has become
     decoration. ]]
combat.server.openedMenu:listen(function(_ctx, opened)
	giveItem(opened)
end)

--[[ 14. `maxBytes` on a class the server sends. The server is not a peer whose payload size needs
     policing, and the schema gives every channel a ceiling regardless — so the field would be
     configuring a check that does not apply to it. ]]
local _oversizedEvent = nw.event({
	data = t.struct({ seq = t.u16 }),
	audience = nw.audience.everyone,
	maxBytes = 4,
})

--[[ 15. And `burst`, for the same reason `rate` is forbidden here: the depth of a budget that
     does not exist. ]]
local _burstyEvent = nw.event({
	data = t.struct({ seq = t.u16 }),
	audience = nw.audience.everyone,
	burst = 30,
})

--[[ 16. A bare table literal claiming to be trusted.

     This is the case that made §6's central claim false until M3 phase 3. The tag used to be
     `{ __nwTrusted: true? }` — *optional* — and a table literal checked against an optional
     property is inferred to satisfy it, so any literal of the right shape was `Trusted<T>` and
     "only three things produce it" was not true. The tag is required now. ]]
giveItem({ screen = 1 })

--[[ 17. The same laundering one step less obvious, and the one a programmer actually writes:
     take an untrusted payload apart and put it back together. The brand is on the container, so
     a new container is a new brand — which is exactly why the container's tag has to be
     something a literal cannot supply by accident. ]]
combat.server.openedMenu:listen(function(_ctx, opened)
	giveItem({ screen = opened.screen })
end)

--[[ 18. Pins the `Untrusted` brand specifically.

     Case 13 above would still fail if `Untrusted` became `any` tomorrow, because what it really
     tests is the *absence* of `__nwTrusted`. This one fails only because `__nwUntrusted` is
     present and required, so it is the case that notices if that half turns into decoration —
     the failure `spike/declare/README.md` Q5 documents and that dropped M1's count from 13 to 8
     without anything announcing it. ]]
local function sanitise(_wire: nw.Untrusted<{ screen: number }>) end

sanitise({ screen = 1 })

--[[ 19. `nw.validate` takes a schema, and a policy is not one. The shared M3 plan proposed
     `nw.validate(policy)`; the implemented shape is `nw.validate(schema, value)` and this is the
     case that keeps the other reading from compiling. ]]
local _validatedByPolicy = nw.validate(allow, { screen = 1 })
return nil
