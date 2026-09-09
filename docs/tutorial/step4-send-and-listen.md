# Step 4 — Send, listen, publish

**What you have at the end:** a client that sends `equip`, a server that handles it and answers on
`loadout`, and a client that hears the answer. This is the loop the sixty-line example in the README
closes.

## The two views

`nw.namespace` returns one record with two views, `server` and `client`, and each view exposes only
what that side may do. On a `command`, the server view has `listen` and the client view has `send`;
on an `event`, the server view has `publish` (and `broadcast`, only if the audience is everyone) and
the client view has `listen`. Calling the wrong one is not a runtime error. It is a type error, because
the method is absent from that view's type: `combat.client.loadout:publish(...)` is refused with
"Key 'publish' not found", which is guarantee G6 (`docs/DESIGN-API.md` §7).

## Server

```lua
--!strict
-- ServerScriptService/Combat.server.luau

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local combat = require(ReplicatedStorage.Combat)

combat.server.equip:listen(function(ctx, chosen)
	-- `chosen` is Trusted<{ slot: number }>; `ctx.player` is the sender.
	combat.server.loadout:publish(ctx.player, { primary = 100 + chosen.slot })
end)
```

Nothing is annotated. `chosen` is typed from the declaration, and `ctx.player` is the sender. The
handler runs once per admitted packet, in the frame the packet arrived, and its `publish` goes out
in that same frame's batch rather than the next one.

`publish(subject, value)` takes the subject first because the audience is evaluated against it:
`nw.audience.owner` sends to the player who owns the subject, and a `Player` owns themselves, so
publishing for `ctx.player` reaches exactly the sender. An audience of `everyone` would also give
this channel `broadcast(value)`; `owner` does not, and its absence is the point.

## Client

```lua
--!strict
-- StarterPlayerScripts/Combat.client.luau

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local combat = require(ReplicatedStorage.Combat)

combat.client.loadout:listen(function(loadout)
	print(`equipped primary {loadout.primary}`)
end)

combat.client.equip:send({ slot = 1 })
combat.client.equip:send({ slot = 7 })
```

The first send arrives, passes both policies, and the client prints `equipped primary 101`. The
second decodes cleanly — 7 is inside `t.u8(0, 9)` — and is refused by `ownsSlot` with the reason
"slot 7 is past the 3 this player owns". Nothing on the client says so, by design; Step 5 is where the
server sees it.

`send({ slot = 12 })` type-checks, because the payload type is `{ slot: number }` and 12 is a
number, and then raises at the send: the encoder refuses 12 against `t.u8(0, 9)` on the client,
before a byte is written, with the range in the message. A schema bound is a bound on both ends,
and on the sending end it is the programmer's error to see, not the peer's.

## Order, and what a batch is

Sends are batched per frame and flushed on `PostSimulation`, into one buffer per recipient. A packet
is a channel id, an optional length prefix, and the payload; a batch is a version byte and packets.
On a reliable channel, packets from one peer arrive in the order they were sent; an `unreliable`
one promises neither order nor arrival, which is what makes it cheap. The length prefix is what
lets a refused packet be skipped and the one behind it decoded, which is guarantee G5 and the one
byte netweave pays on small payloads that the generators do not (`docs/WIRE-FORMAT.md` §2).

A handler attached *after* traffic arrived still receives it: what arrived before `:listen` is
queued, bounded by the `queueCapacity` limit, and delivered when the handler is attached, so the
order your modules happen to require in is not a source of lost packets.

## What does not type-check

`combat.server.equip:send(...)`, `combat.client.equip:listen(...)`, `combat.client.loadout:publish(...)`
and `combat.server.loadout:broadcast(...)` are each refused at analysis. The last one is the useful
surprise: `broadcast` exists only where the audience is `everyone`, and `loadout` declared `owner`.

**Next:** [Step 5 — Read the refusals](step5-refusals.md)
