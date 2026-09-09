# Step 5 — Read the refusals

**What you have at the end:** every refused packet accounted for, in the console by default, in your
own observer when you attach one, and in a counter you can put on a screen.

## Nothing is thrown

The second send in Step 4 was refused by a policy. Run it and the server console says:

```
[netweave] combat.equip refused at authorize from Player1: slot 7 is past the 3 this player owns
```

That line is the default observer. Every refusal, whether or not anything is listening, is a value
with a channel, a player, a stage and a reason, and by default it is written to the console. The
console goes quiet on its own: one channel and stage prints three times, then says further reports
are suppressed. That is what makes it safe to report everything — under a flood the rejection path is
the hot path, and a library that printed a line per refused packet would be the outage
(`docs/DESIGN-API.md` §9).

## The stages

Each report names the stage that refused. Reading them tells you where in the pipeline a packet
stopped, and most of them can only be reached by a peer that is broken or hostile:

- `parse` — the bytes did not decode against the channel's schema: a value out of range, a length
  that runs past the batch, an instance of the wrong class in the sidecar.
- `budget` — over the declared `rate`, or a payload claiming more bytes than the schema can produce,
  or a batch holding more packets than the server admits per batch.
- `direction` — a packet on a channel this peer is the sender of. A client wrote a server-only id.
- `protocol` — the peer is on a different set of declarations; every packet between them would
  decode as the wrong channel, so the whole peer is refused.
- `authorize` — a policy said `nw.deny`.
- `handler` — the game's own handler raised. The packet cost nothing else.
- `queue` — nothing is listening on that channel yet and the backlog is full.
- `send` — this side could not send: an unreliable payload over 908 bytes, an audience that returned
  something that is not a player.
- `query` — the caller's side of a request that produced no answer.
- `replicate` — a resync asked for inside the window, or on an id that is not replicated.

## Attach your own

```lua
nw.observe(function(rejection)
	-- rejection.channel, rejection.player, rejection.stage, rejection.reason, rejection.bytes
	if rejection.stage == "authorize" then
		warn(`{rejection.player} was refused {rejection.channel}: {rejection.reason}`)
	end
end)
```

Attaching an observer replaces the console output; it does not make the refusals stop, and it does
not suppress anything — an observer receives every report, including the ones the console would have
gone quiet on. `nw.observe` returns a function that detaches it.

## Count them

Because the console goes quiet, `nw.diagnostics()` is what is left when you want a number:

```lua
local seen = nw.diagnostics()
print(seen.total)                                    -- every refusal since the counters were reset
print(seen.channels["combat.equip"].authorize.count) -- by channel, then by stage
```

It is frozen on read and built on read, so counting a refusal stays two increments and a diagnostic
screen cannot become a way to reset the counters by accident. This is the question the survey in
`docs/RESEARCH-AND-PLAN.md` found no library could answer: is this channel refusing more than it was
an hour ago, which is the difference between a bug and an attack.

## Severity is about output, never enforcement

```lua
nw.configure({
	rules = { authorize = "warn", budget = "off" },
	limits = { queueCapacity = 512 },
})
```

Each rule takes `"error"`, `"warn"` or `"off"`, and the setting changes what the console prints and
nothing else: a rule set to `"off"` still refuses the packet and still counts it. `error` adds a stack
trace to the first reports, which is right for `direction` and `protocol` in a game and wrong for a
test that provokes them on purpose. A misspelled rule or limit is refused at the call site, at
analysis, because a setting that reads as "configured" while the default silently stays in force is
the one thing a settings table must not allow (`docs/DESIGN-API.md` §10).

**Next:** [Step 6 — Replicate a store](step6-replicate.md)
