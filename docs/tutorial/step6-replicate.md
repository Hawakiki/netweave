# Step 6 — Replicate a store

**What you have at the end:** a server-side table whose changes reach every client as the smallest
difference, without the game calling netweave.

## Declare it

```lua
--!strict
-- ReplicatedStorage/Vault.luau

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local nw = require(ReplicatedStorage.netweave.netweave)
local t = require(ReplicatedStorage.netweave.types)

local world: { [number]: { hp: number, gold: number } } = {}

local vault = nw.namespace("vault", {
	inventory = nw.replicate({
		subject = t.u16,
		data = t.struct({ hp = t.u8, gold = t.u16 }),
		audience = nw.audience.everyone,
		store = nw.store.of(world),
	}),
})

return { vault = vault, world = world }
```

Four fields, all required. `subject` is the type of the key, because a replicated channel keeps one
value per subject on the client and the subject goes on the wire. `data` is the value's schema.
`audience` says who should see each subject. `store` is where the truth lives, and it is the only way
in: the server view of a `replicate` channel has no `publish`, and the absence is the guarantee that
nothing can skip the baseline and leave a client wrong in a way nothing could detect.

`nw.store.of(table)` wraps a plain table whose keys are subjects and whose values match `data`. If
your state already lives in Charm, `nw.store.charm(getter)` takes the atom's getter; for
ReplicaService, `nw.store.replica(replicas)`. netweave never requires either library. It asks a store
for two things, the subjects and the value of one of them, and adapts the store rather than the
store's own replication layer (`docs/DESIGN-API.md` §3, "Replication is a seventh class").

## The server writes its own state

```lua
local shared = require(ReplicatedStorage.Vault)

shared.world[1] = { hp = 10, gold = 500 }

task.wait(2)
shared.world[1].gold = 480
```

That is the whole server side. Once a frame, after the handlers have run and before the flush,
netweave reads the store and sends each client the difference between what it should see and what
it has. The first frame after subject 1 appears, every client in the audience gets the whole value.
The frame where `gold` moves, each of them gets the one field: on a twelve-field struct that is three
bytes against twelve for a resend, and a frame where nothing moved costs nothing at all.

## The client listens

```lua
local shared = require(ReplicatedStorage.Vault)
local held: { [number]: { hp: number, gold: number }? } = {}

shared.vault.client.inventory:listen(function(subject, value)
	held[subject] = value
end)
```

The listener takes the subject first, then the whole value — never a patch. A client that had to
know whether it was sent a snapshot or a change is a client the library has failed. `nil` is the
subject going away: it left this client's audience, or it ceased to exist, and one packet shape says
both.

The value is the client's baseline, and it is frozen. A change is folded into what the client already
had, sharing every subtree the change did not touch, which is why one field of twelve costs three
bytes. Writing into it would rewrite the base the next change is applied to, so `value.hp -= 1` for
a prediction raises rather than leaving that field wrong for ever. Copy as deep as you write.

## Joining, leaving, and asking again

A client that joins mid-session has no baseline, and no baseline is the same condition as any other
gap: the server sends everything for that channel. A client entering a `nearby` or `select` audience
is the same case. A client that receives a change it cannot read gives up the channel and asks for
all of it again; the server honours one such resync per `resyncTicks` window per client per channel
and reports the rest, so a peer asking every frame cannot make the server re-encode its state every
frame. A disconnecting player leaves no baseline behind.

Reliable delivery is what makes deltas safe, which is why `unreliable = true` on a `replicate`
channel does not type-check: a dropped delta would leave that client wrong until the next full
resync, silently. On `state` and `event` the same flag is legal, because a dropped packet there costs
one tick and the next packet corrects it.

## What it costs on the server

A baseline per client per subject, for as long as that client is connected, bounded by the
`baselinesPerClient` limit. Passing it is reported at stage `replicate`, once, and the client is
re-armed when it falls below the line. That is memory proportional to players times state size,
chosen by how many people join, which is exactly the kind of number a declaration has to carry.

**Next:** [Step 7 — The other classes](step7-the-other-classes.md)
