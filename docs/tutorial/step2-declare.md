# Step 2 — Declare a namespace

**What you have at the end:** one module, required by both sides, that declares two channels and
is the whole security model for them.

## One file, both sides

A namespace is declared once and required by the server and the client alike. Put it in
`ReplicatedStorage`, next to the library:

```lua
--!strict
-- ReplicatedStorage/Combat.luau

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local nw = require(ReplicatedStorage.netweave.netweave)
local t = require(ReplicatedStorage.netweave.types)

local Equip = t.struct({ slot = t.u8(0, 9) })
type Equip = { slot: number }   -- by hand here, and Step 3 says why; elsewhere t.PayloadOf derives it

--[[ A policy that allows everything, until Step 3 writes a real one. ]]
local allow = nw.policy(function()
	return function()
		return nw.allow()
	end
end)

return nw.namespace("combat", {
	equip = nw.command({
		data = Equip,
		rate = 5,
		authorize = allow,
	}),

	loadout = nw.event({
		data = t.struct({ primary = t.u16 }),
		audience = nw.audience.owner,
	}),
})
```

Read the two declarations as a reviewer would. `equip` is a `command`: a client sends it, it changes
authoritative state, it may arrive at most five times a second per player, and every one of them is
checked by `authorize` before a handler sees it. `loadout` is an `event`: the server sends it, and it
goes to the owner of whatever subject it is published for, and nobody else.

`allow` is the placeholder that lets this file type-check before Step 3 writes a real policy. It
allows everything, and it is still a policy built with `nw.policy`: the declaration says out loud
that this channel has one, and `nw.allow` alone would not do, because a verdict is not a policy.

## The schema is bounded, and that is where the limits come from

`t.u8(0, 9)` is a byte that must be between 0 and 9. Every netweave type is bounded like that — a
number by its encoding or its declared range, a string or an array by its length, a struct by its
fields — and the layout adds them up. So `equip` can never be more than a byte on the wire, a packet
claiming more is refused before any of it is decoded, and the game declared nothing to get that.

The vocabulary you will use most:

```lua
t.u8, t.u16, t.u32, t.i8, t.i16, t.i32, t.f32, t.f64   -- numbers by encoding
t.u16(0, 1000)                                        -- narrowed to a range
t.boolean
t.string(0, 32)                                       -- length 0..32
t.enum({ primary = true, secondary = true })          -- payload type "primary" | "secondary"
t.optional(t.u16)                                     -- number?
t.array(t.u8, 0, 8)                                   -- up to eight
t.map(t.string(1, 16), t.u8)
t.struct({ ... })
t.vector3, t.vector3(t.i16(-2048, 2048)), t.unitVector3, t.cframe, t.color3
t.instance("BasePart"), t.player
```

The payload type is inferred from the schema: `Equip` above is `Type<{ slot: number }>`, and every
handler and every `send` on that channel is typed from it. Where your own code needs to name that
type — a helper that builds one, a union to switch on — `t.PayloadOf<typeof(Equip)>` derives it
from the schema so the two cannot drift (Steps 8 and 9). The one place to write it by hand is a
policy's request parameter, which is why this file does: Step 3 has the measurement. The value and
the type may share a name, as above; Luau keeps them in separate namespaces.

Two spellings in the list are shaped the way they are for a reason. `t.enum` takes a table of keys,
`{ primary = true, secondary = true }`, not an array: an array literal is widened to `{ string }` and
the variant names would be lost to the type, whereas keys survive as `"primary" | "secondary"`.
And a range is a second call, `t.u16(0, 1000)`, not a field, so that a bare `t.u16` stays a plain
value a helper can pass around.

## What does not type-check

Delete `rate = 5` and the analyzer prints, at the `nw.command` line, that a command declares a rate
budget and there is no unlimited spelling of one. Delete `authorize = allow` and it prints that a
command needs `authorize`, and how to build one. Add `authorize` to the `event` and it prints
that a channel that authorizes is a command or a query. Write `rate = 5` on the `event` and it
prints that the server is the sender on this class, so there is nobody to budget. Each of those messages names what to write instead, because
half of them print verbatim in *your* declaration file, on the line that is wrong.

These are guarantees G1, G2 and G3 in `docs/DESIGN-API.md` §2, and `tests/api_reject.luau` counts
every one of them: a rejection file that stops erroring is how a guarantee silently stops being
enforced.

## Declare everything before the first packet, and on both sides

Every channel's wire id is derived from the sorted names of *every* channel in the program, and so
is the protocol hash both peers compare on the first batch. That has a consequence worth its own
sentence: **a namespace declared in a server-only script can never agree with any client.** The
server's hash would include it, the client's cannot, and each client would be refused at stage
`protocol` from its first batch onward, with "nothing works" as the symptom. So `nw.namespace`
refuses it where it is written: a declaring module under `ServerScriptService` or `ServerStorage`
raises at that line, naming the module and the fix. Admin commands are declared in a shared module
like everything else; what is server-only is the policy's dependency, reached through a seam
(Step 3), not the declaration.

A namespace declared after the first packet has moved would renumber the ids the other peer already
agreed to. netweave refuses that: declaring after the protocol is sealed raises. On a client "the
first packet" is one that *arrives*, so require every namespace before anything yields — a
`WaitForChild` between requiring netweave and requiring this module is enough to lose the race
(`docs/WIRE-FORMAT.md` §3).

**Next:** [Step 3 — Write a policy](step3-policies.md)
