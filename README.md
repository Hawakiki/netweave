# netweave

A networking library for Roblox whose declaration file is the security review.

Every channel says, on the line that declares it, who may send on it, how often, to whom it goes,
and what has to be true before a handler sees the payload. Half of that is enforced by the type
checker before the game runs; the other half is enforced on the wire, where a malicious client
cannot reach `error()`, cannot stop the packets behind its own, and cannot send on a channel it is
supposed to receive on. The schema is runtime Luau — no code generation, no build step — and it
packs bytes as tightly as the generators do.

```lua
local combat = nw.namespace("combat", {
	equip = nw.command({
		data = t.struct({ slot = t.u8(0, 9) }),
		rate = 5,
		authorize = nw.all(policy.alive, policy.ownsSlot({ slots = 3 })),
	}),
})
```

Leave out `authorize` and the file does not type-check. Leave out `rate` and it does not type-check.
Declare it a `signal` instead, and the handler receives `Untrusted<T>`, which no function annotated
`Trusted<T>` will accept. That is the product; the rest of this file is what it costs and what it
refuses.

## Who it is for

Authors who write `--!strict` and have used ByteNet, Blink or Zap. The declaration is no longer than
ByteNet's, and the rate limits and authorization checks those libraries leave you to scatter by hand
move into one place a reviewer can open.

**It requires the new Luau type solver.** Half the guarantees are `type function` errors, and the
old solver rejects the syntax outright. As of the solver's general release a `--!strict` project
stays on the old solver by default and opts in under **Workspace Properties → Scripting**, per
project. Without it the declaration surface still runs, and the guarantees below marked *type error*
are not checked. `docs/DESIGN-API.md` §0 and §7 say why this was decided rather than worked around.

## The guarantees

| | Guarantee | Enforced by |
|---|---|---|
| G1 | An inbound channel that changes authoritative state has no listener until a policy is attached | type error |
| G2 | Every inbound channel declares a rate budget. There is no "unlimited" | type error |
| G3 | Every server-to-client channel declares its audience. `broadcast` exists only where the audience is everyone | type error |
| G4 | Wire data never reaches `error()`. Rejections are values, routed to an observer | the transport, under a guard per batch |
| G5 | Length-prefixed framing: one malformed packet cannot stop the rest of its batch | the wire format |
| G6 | Direction is a class, not a string field. A packet arriving on a channel this peer sends on is refused before decode | type error, and the wire |

Two limits, stated up front because the library does not pretend otherwise. The inner layer —
framing, rate, audience, direction — is unconditional. Whether a channel's *class* is honest is up
to the author: nothing stops a state-changing packet being declared a `signal`, which forbids
`authorize` and is the shortest thing to write. `Untrusted<T>` closes that route for every function
annotated `Trusted<T>`, and only for those. And every number the benchmark reports was measured in
Studio's loopback, which supports relative comparison and nothing else.

## Sixty lines

Declaring, sending, authorizing, refusing and observing. This is not a sketch: it is the text of
`tests/example_runtime.luau`, which runs in the suite, and `tools/messages.luau` fails the build if
this copy and that file ever differ.

<!-- example: tests/example_runtime.luau -->
```lua
--[[ One file, required by both sides. Everything a reviewer needs to know about this channel's
     security is on the line that declares it. ]]
local t = nw.types

local Equip = t.struct({ slot = t.u8(0, 9) })
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
})

--[[ The server. `chosen` is `Trusted<{ slot: number }>` — it decoded, it was inside the declared
     rate, and the policy allowed it. Nothing else in the process can produce that type by
     accident, which is what makes the annotation on an authoritative function worth writing. ]]
--[[ Nothing is annotated: `chosen` is `Trusted<Equip>` and `ctx.player` is the sender, both from
     the declaration (`DESIGN-API.md` §8 on why the player is `unknown`). ]]
combat.server.equip:listen(function(ctx, chosen)
	combat.server.loadout:publish(ctx.player, { primary = 100 + chosen.slot })
end)

combat.client.loadout:listen(function(loadout)
	equipped[#equipped + 1] = loadout.primary
end)

--[[ Every refusal, whether or not anything is listening. Attaching this replaces the default
     console output; detaching it does not make the refusals stop. ]]
nw.observe(function(rejection)
	refusals[#refusals + 1] = `{rejection.channel} at {rejection.stage}: {rejection.reason}`
end)
```

What is *not* in it is as much the point. There is no middleware chain, no per-call options table,
no place to pass a validator at the send site, and nothing that would let a second file change what
`equip` accepts.

### The same file, replicating

The seventh class. The game writes its own state and never calls netweave; once a frame netweave
reads the store and sends each client the difference between what it should see and what it has.
A joining client gets the whole value, a frame where one field of twelve moved costs three bytes,
and a client whose audience membership changes gets exactly the difference.

<!-- example: tests/example_runtime.luau replication -->
```lua
--[[ The server never calls this channel. `store` is the only way in, so there is no `publish` on
     the server view to be called by mistake — the absence is the guarantee. ]]
local world: { [number]: { hp: number, gold: number } } = {}

local vault = nw.namespace("vault", {
	inventory = nw.replicate({
		subject = t.u16,
		data = t.struct({ hp = t.u8, gold = t.u16 }),
		audience = nw.audience.everyone,
		store = nw.store.of(world),
	}),
})

--[[ The subject, then the value. `nil` is that subject leaving this client's audience or ceasing
     to exist — the one packet shape says both. ]]
vault.client.inventory:listen(function(subject, value)
	held[subject] = value
end)

--[[ The game writes its own state and tells netweave nothing. Once a frame netweave reads the
     store and sends each client the difference between what it should see and what it has: the
     first frame is the whole value, and a frame where one field moved is that field. ]]
world[1] = { hp = 10, gold = 500 }

--[[ Everything is declared before anything is sent, and that is a rule rather than a habit: a
     namespace declared after the first packet has moved raises, because an id depends on every
     other channel in the program (`WIRE-FORMAT.md` §3). ]]
combat.client.equip:send({ slot = 1 })
combat.client.equip:send({ slot = 7 })
```

## The classes

The taxonomy is by security obligation, not by transport. The class name is the documentation: a
reader sees `nw.intent` and knows the server does not approve each packet.

| Class | Direction | Required | Forbidden | Handler receives |
|---|---|---|---|---|
| `command` | C→S | `data`, `rate`, `authorize` | — | `Trusted<T>` |
| `intent` | C→S | `data`, `rate` | `authorize` | constrained `T`, at most one per player per tick |
| `signal` | C→S | `data`, `rate` | `authorize` | `Untrusted<T>` |
| `query` | C→S→C | `args`, `returns`, `rate`, `authorize`, `timeout` | — | `Trusted<T>`; the one handler that may yield |
| `state` | S→C | `data`, `audience` | `rate`, `authorize` | `T`, the latest value per subject |
| `event` | S→C | `data`, `audience` | `rate`, `authorize` | `T` |
| `replicate` | S→C | `data`, `subject`, `audience`, `store` | `rate`, `authorize`, `unreliable` | `(subject, T?)`; `nil` is the subject leaving |

Every channel carries a byte ceiling it derived from its schema, because every netweave type is
bounded, and a packet claiming more is refused before a byte of it is decoded. `rate` is sustained,
enforced by a token bucket rather than a window, so "no more than `rate` per second in any second".
`timeout` on a query has no unlimited value. `unreliable` is legal on `state` and `event`, where a
dropped packet costs one tick, and forbidden on `replicate`, where a dropped delta would leave the
client wrong for ever.

## What happens to a refused packet

Nothing is thrown. Every refusal is a value with a channel, a player, a stage and a reason, written
to the console by default — three times per channel and stage, then suppressed, so a flood cannot
become the outage — and delivered in full to whatever the game attaches:

```lua
nw.observe(function(rejection)
	-- rejection.stage: "parse" | "budget" | "direction" | "protocol" | "authorize"
	--                | "handler" | "queue" | "send" | "query" | "replicate"
end)
```

`nw.diagnostics()` is the count of every refusal since the counters were reset, by channel and
stage, which is what answers "is this channel refusing more than it was an hour ago" — the question
that separates a bug from an attack. `nw.configure` sets a severity per rule and never enforcement:
a rule set to `"off"` still refuses and still counts.

## The surface, on one page

| | What it is | The one thing to know |
|---|---|---|
| `nw.namespace(name, channels)` | a group of channels, declared once and required by both sides | declare every one at startup; ids depend on all of them |
| `nw.types` | the schema library: `t.u8`, `t.string(0, 32)`, `t.array`, `t.struct`, `t.enum`, `t.optional`, `t.union`, `t.quantized`, `t.vector3`, `t.instance("BasePart")` | every type is bounded, which is where each channel's byte ceiling comes from |
| `nw.policy(factory)` | two stages: the factory runs once, the check runs per request | a verdict is `nw.allow(value)` or `nw.deny(reason)` |
| `nw.all(...)` | composes policies, threading the allowed value onward | it stops at the first denial |
| `nw.audience` | `everyone`, `owner`, `nearby(studs)`, `select(fn)` | only `everyone` gives a channel `broadcast` |
| `nw.store` | `of(table)`, `charm(getter)`, `replica(replicas)` — what `replicate` reads | the game's state library owns the truth; netweave owns what each client has |
| `nw.observe(fn)` | every rejection, with its stage | attaching one replaces the console output; it does not make refusals stop |
| `nw.configure(settings)` | severities per rule, and numeric limits | a misspelled rule is refused at the call site |
| `nw.protocol()` / `nw.signature()` | what both peers must agree on, and the text it is hashed from | a mismatched peer is refused at stage `protocol` |
| `nw.validate(schema, value)` | check a value you already hold | produces `Trusted<T>` without a wire, exactly as strict as the encoder |
| `nw.diagnostics()` | every refusal since the counters were reset | frozen on read |

`docs/DESIGN-API.md` is the full contract, with the reasoning and the corrections that measurement
forced on it. `docs/WIRE-FORMAT.md` is the frozen v1 wire format.

## Installing

There is no package registry entry. The library is the `src/` directory, and it has no build step:
every require is a relative string that resolves the same way in Studio and under lune.

Either copy `src/` into your project as a folder named `netweave`, or build the package:

```sh
rojo build default.project.json -o netweave.rbxm
```

and insert it where both sides can reach it. Then, on both sides:

```lua
local nw = require(ReplicatedStorage.netweave.netweave)
local t = nw.types
```

Requiring it inside Roblox installs the transport. There is nothing to configure and no step to
remember: a game that declared its channels has already said everything the transport needs. Declare
every namespace before the first packet moves — on a client, that means before anything yields —
because every channel id depends on every other channel in the program.

## What it costs

`bench/RESULTS.md` has every number with its spread, sample count and the run document it came from,
and says at the top why none of it is a bandwidth figure. From the two runs that closed M4
(`bench/runs/2026-09-09-m4bug-a.json` and `-b.json`, Studio loopback, 200 packets a frame):

| | netweave | Blink 0.18.8 | Zap 0.6.29 | ByteNet 0.4.3 |
|---|---|---|---|---|
| bytes on the wire, 100 × 6 × `u8` | 601 | 601 | 601 | 603 |
| bytes on the wire, twelve booleans, two enums and two optionals | 8 | 10 or 20, by how the author spelled it | 7 | 20 |
| client encoding that array payload, frames per second | 114, 115 | 131, 134 | 112, 113 | 115, 116 |
| client decoding it | 63, 54 | 78, 83 | 70, 68 | 70, 55 |

The array payload is a three-way tie at the theoretical floor. On flags netweave pays one byte more
than Zap, and that byte is the length prefix G5 needs. On encode netweave sits with Zap and ByteNet,
behind Blink by 1.15x; on decode it is behind Blink, and `bench/RESULTS.md` says what is known about
why and what is not. Every cell is delivered and validated in every direction, and the harness counts
drops next to throughput because a fast library that loses packets is not fast.

## Developing

Tools are managed by [rokit](https://github.com/rojo-rbx/rokit): `rojo`, `lune`, `stylua`, `selene`
and `luau-lsp`, pinned in `rokit.toml`. Type checking is part of the test suite, not a convenience.

```sh
pwsh scripts/check.ps1        # every lune-side check, in one command; also the pre-commit hook
lune run analyze              # type checking, both halves: files that must be clean, files that must fail
lune run tests/fuzz_runtime   # one module; there are nineteen
rojo build test.project.json -o netweave-test.rbxl   # the Studio half: Vector3, CFrame, Instance, a real client
```

`CLAUDE.md` is the repository's rulebook — layout, conventions, and the verification discipline the
security work arrived at. `docs/milestone/` has one plan per milestone, kept as live documents with
their corrections struck through in place rather than rewritten.

## Status

Milestone M4 is closed: codec, transport, and replication are implemented, two external security
audits have been worked through with a disposition for every finding (`docs/SECURITY-REPORT*.md`,
`docs/milestone/PLAN-M4.md` §9), and the lune suite and the Studio suite are green. `PLAN-M5.md` is
written and not opened; it holds the type-layer work the audits deferred. This repository is
developed locally and has no hosted remote.
