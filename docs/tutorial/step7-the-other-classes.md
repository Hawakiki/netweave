# Step 7 — The other classes: intent, signal, query, state

**What you have at the end:** the whole taxonomy, and the reason each class refuses what it refuses.

Channels are classified by security obligation, not by transport. The class name is the security
documentation: a reader who sees `nw.intent` knows the server does not approve each packet, and one
who sees `nw.signal` knows the payload carries no authority (`docs/DESIGN-API.md` §3).

## `intent` — continuous input the server judges on its own tick

```lua
aim = nw.intent({
	data = t.struct({ pitch = t.f32(-90, 90), yaw = t.f32(-180, 180) }),
	rate = 60,
}),
```

```lua
combat.server.aim:listen(function(ctx, look)
	-- at most once per player per frame, with the newest value
end)
```

Movement, aim, a held button. Approving each packet is the wrong model at 60 Hz, so `authorize` is
forbidden, and the class says so out loud so nobody mistakes it for a command. It also coalesces:
however many `aim` packets a player sends inside one frame, the handler runs once with the newest.
Stale input has no value, and an attacker filling the rate budget cannot convert that into per-packet
work on the server.

The budget is counted before the coalescing, per packet, on the server. `rate = 30` with a `send`
in every `RenderStepped` at 60 frames a second is thirty refusals a second at stage `budget`, and
the client is not told. Send at the rate you declared — every other frame, or from a `Heartbeat`
accumulator — and declare the rate you send at.

An `intent` may declare `unreliable = true`, and for movement it usually should: a lost datagram
costs one frame of input the next frame supersedes anyway, and an unreliable packet is not held
back behind a reliable one that is still being retransmitted. `signal` accepts the flag on the same
terms. `command` and `query` refuse it, because a command that might not arrive is a class name
that is a promise it does not keep.

## `signal` — no authority, and typed to say so

```lua
openedMenu = nw.signal({
	data = t.struct({ screen = t.u8(0, 8) }),
	rate = 2,
}),
```

A signal is what a client says about itself: a menu opened, a chat bubble, a cosmetic. `authorize`
is forbidden here, which keeps the class honest — if you find yourself wanting to approve it, it was
a `command`. Its payload arrives as `Untrusted<T>`, and that brand is what stops the shortcut:
declare a state-changing channel a `signal` to avoid writing a policy, and the handler's payload will
not fit any function annotated `Trusted<T>`. That protection is exactly as wide as the annotations
you write, which `docs/DESIGN-API.md` §0 states as a limit rather than hiding.

## `query` — a command that answers

```lua
getLoadout = nw.query({
	args = t.u8(0, 2),
	returns = t.struct({ primary = t.u16, secondary = t.u16 }),
	rate = 2,
	timeout = 5,
	authorize = alive(t.u8),   -- the schema-witness helper from Step 3; args here are a t.u8
}),
```

```lua
-- server
combat.server.getLoadout:handle(function(ctx, slot)
	local player = ctx.player :: Player
	return loadouts[player][slot + 1]   -- may yield: a datastore read, a WaitForChild
end)

-- client
local loadout, failure = combat.client.getLoadout:invoke(0)
if loadout then
	print(loadout.primary)
else
	warn(failure)  -- "no answer within 5s", "the server refused it", ...
end
```

`invoke` yields the calling thread until the answer, a refusal, or the timeout, so it is called from
somewhere that may wait — a button handler, a `task.spawn` — and never from a `RenderStepped`
callback. `timeout` is required and has no unlimited value, because a request that never resolves
is a leaked thread. `returns` may not be a top-level `t.optional`, because `invoke` reports failure as `nil` and
an answer that may itself be nil would be indistinguishable from a call that never came back. The
server handler is `:handle`, not `:listen`, and it is the one handler in the library that may yield:
it runs on its own thread with a context of its own, and a player's parked handlers are bounded by
the `callsInFlight` limit, because they are a resource that player can spend.

The reason a refused query gives the caller is a code, never the policy's text. The authorization
model is not the client's to learn.

## `state` — the latest value per subject, downward

```lua
playerState = nw.state({
	data = t.struct({ entityId = t.u16, grounded = t.boolean }),
	audience = nw.audience.nearby(120),
	unreliable = true,
}),
```

```lua
combat.server.playerState:publish(subject, { entityId = 1, grounded = true })
```

`state` carries the current state of a subject to whoever should see it, every time you publish it.
It does not diff, and it does not remember what each client has — that is `replicate`, Step 6 — and
the two share no method: `state` is `publish(subject, value)` with the game holding the value,
`replicate` is a store with the game never calling netweave. `unreliable` is legal here, because a
dropped packet costs one tick of staleness and the next publish corrects it, and positional data
sent every frame is where that trade is right. It is refused on `replicate`, where the same drop
would be permanent.

## `event` — a fact, downward

The `loadout` channel from Step 2: something that happened, delivered as sent. Mechanically it is
the same publish as `state`; the class name says whether a reader should expect the latest value of
something or a thing that occurred once, and that is what a reviewer needs to know.

## What every downward class shares

`audience` is required, and it is evaluated against the subject you publish for. `everyone` gives
the channel `broadcast(value)` and ignores the subject. `owner` sends to the player who owns the
subject, where a `Player` owns themselves and a character owns its player. `nearby(studs)` measures
from the subject — a `Player`'s character, a `Model`'s root, or a `BasePart` — to each player's
character, and a player with no character is not near anything. `select(fn)` sends to whatever
list your function returns for the subject, checked against the players who are actually here, with
duplicates and departed players dropped and reported at stage `send`:

```lua
teamChat = nw.event({
	data = t.string(1, 200),
	audience = nw.audience.select(function(subject)
		return teammatesOf(subject :: Player)   -- your own list, rebuilt per publish
	end),
}),
```

The function runs per publish, and on a replicated channel per subject per tick, so it is not the
place for a tree walk; return a list you already keep.

The subject is whatever the publisher passes, and it is typed `unknown` on the way in: nothing
checks that the `select` function receives a `Player` rather than a trade id, because the same
channel may be published for either. So the cast inside is where that agreement lives, and a subject
the function does not recognise should return an empty list rather than raise. Below, the subject is
a trade id and the recipients are the two parties, looked up in a table the server keeps:

```lua
resolved = nw.event({
	data = t.struct({ tradeId = t.u16, accepted = t.boolean }),
	audience = nw.audience.select(function(subject)
		local offer = pending[subject :: number]
		return if offer then playersOf(offer) else {}
	end),
}),

-- and on the server
trade.server.resolved:publish(tradeId, { tradeId = tradeId, accepted = true })
``` Making the recipient set a declaration rather
than a call site turns "who can see this" into a reviewable line, which is how positional data stops
leaking to wallhacks by accident.

## The numbers a declaration can tune

Every inbound class takes a `burst` beside its `rate`, the depth of the token bucket, defaulting to
one second's worth and never allowed below `rate`. Every inbound class whose payload has a length
prefix takes a `maxBytes`, which can only *tighten* the ceiling the schema derived, and is refused
where it could not be consulted. Everything else is a limit in `nw.configure`, with a default and a
range: `queueCapacity` (packets held for a channel nobody is listening on yet), `pendingPerBatch`
(packets the server admits from one batch), `callsInFlight` (a player's parked query handlers),
`unreliableBytes` (lowerable from 908, never raisable), `baselinesPerClient` and `resyncTicks`
(Step 6), and `repeatsPerDiagnostic` (how many times the console prints one channel and stage). A
name that is not one of those is refused at the call site.

## Two peers, one declaration

Both sides compute a hash over every channel's name, class and schema, and a client whose hash
differs from the server's is refused at stage `protocol` on its first batch, before any of its
packets decode as the wrong channel. `nw.protocol().hash` is the number, and `nw.signature()` is
the text it is hashed from, which is what to diff when a deploy went out half-way.

That is every class. Two steps remain: what each type costs and refuses, and how to name what
netweave hands you in your own annotations. `tests/tutorial_ok.luau` is every snippet in these nine
steps in one file the analyzer has to accept, which is the place to look when a spelling here does
not match what you see.

**Next:** [Step 8 — Types, bytes, and what the decoder refuses](step8-types-and-bytes.md)
