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
	authorize = policy.alive,
}),
```

```lua
-- server
combat.server.getLoadout:handle(function(ctx, slot)
	return loadouts[ctx.player][slot]   -- may yield: a datastore read, a WaitForChild
end)

-- client
local loadout, failure = combat.client.getLoadout:invoke(0)
if loadout then
	print(loadout.primary)
else
	warn(failure)  -- "no answer within 5s", "the server refused it", ...
end
```

`timeout` is required and has no unlimited value, because a request that never resolves is a leaked
thread. `returns` may not be a top-level `t.optional`, because `invoke` reports failure as `nil` and
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

`state` carries the current state of a subject to whoever should see it, and it coalesces per subject
per tick, so publishing twice in a frame sends the newer value once. It does not diff — that is
`replicate`, Step 6 — and the two share no method: `state` is `publish(subject, value)` with the game
holding the value, `replicate` is a store with the game never calling netweave. `unreliable` is legal
here, because a dropped packet costs one tick of staleness and the next packet corrects it, and
positional data is where that trade is right. It is refused on `replicate`, where the same drop would
be permanent.

## `event` — a fact, downward

The `loadout` channel from Step 2. Like `state` but delivered as sent, one packet per publish, for
things that happen rather than things that are.

## What every downward class shares

`audience` is required. `everyone` gives the channel `broadcast(value)`; `owner` sends to the player
who owns the subject; `nearby(studs)` to players within that distance of it; `select(fn)` to whatever
list your function returns, checked against the players who are actually here, with duplicates and
departed players dropped and reported. Making the recipient set a declaration rather than a call site
turns "who can see this" into a reviewable line, which is how positional data stops leaking to
wallhacks by accident.

That is the whole surface. The README has it on one page, `docs/DESIGN-API.md` has the contract, and
`tests/api_ok.luau` is a file that uses every class and analyses clean, which is the place to look
when a spelling here does not match what you see.
