# netweave

*[한국어](README.ko.md) · [Tutorial](docs/tutorial/README.md) · [Worked example](docs/tutorial/example-trade.md) · [Common mistakes](docs/tutorial/mistakes.md) · [API design](docs/DESIGN-API.md) · [Wire format](docs/WIRE-FORMAT.md) · [Benchmarks](bench/RESULTS.md)*

netweave is a networking library for Roblox whose declaration file is the security review. Every
channel says, on the line that declares it, who may send on it, how often, to whom it goes, and what
has to be true before a handler sees the payload. Half of that is enforced by the type checker before
the game runs. The other half is enforced on the wire, where a malicious client cannot reach
`error()`, cannot stop the packets behind its own, and cannot send on a channel it is supposed to
receive on. The schema is runtime Luau, with no code generation and no build step, and it packs bytes
as tightly as the generators do.

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
Declare it a `signal` instead and the handler receives `Untrusted<T>`, which no function annotated
`Trusted<T>` will accept. That is the product. The rest of this page is what it costs and what it
refuses, and the [tutorial](docs/tutorial/README.md) is the same material as nine short steps you
can follow in an empty place.

## Who it is for

netweave is for authors who write `--!strict` and have used ByteNet, Blink or Zap. The declaration
is no longer than ByteNet's, and the rate limits and authorization checks those libraries leave you
to scatter by hand move into one place a reviewer can open. It is deliberately a smaller slice of the
ecosystem than the generators serve, chosen on purpose.

It requires the new Luau type solver. Half the guarantees are `type function` errors, and the old
solver rejects the syntax outright. As of the solver's general release, a `--!strict` project stays
on the old solver by default and opts in under **Workspace Properties → Scripting**, per project.
Without it the library still runs, because the VM does not type-check, but the editor reports
hundreds of errors inside netweave's own files — `This syntax is not supported` on every
`type function`, `read keyword is illegal here` on every read-only field — and none of the guarantee
diagnostics; the solver setting is the first thing to check when the library folder is red.
`docs/DESIGN-API.md` §0 and §7 say why this was decided rather than worked around.

## What it guarantees

Six things, each with a mechanism behind it rather than a convention. An inbound channel that
changes authoritative state has no listener until a policy is attached, and every inbound channel
declares a rate budget with no "unlimited" spelling; both are type errors when missing. Every
server-to-client channel declares its audience, and `broadcast` exists only where that audience is
everyone, which is also a type error. Wire data never reaches `error()`: rejections are values,
routed to an observer, and the receive path runs under a guard per batch so that a raise costs one
packet rather than the session. Framing is length-prefixed, so one malformed packet cannot stop the
rest of its batch. And direction is a class rather than a string field, checked twice, once by the
views at analysis and once on arrival, where a packet on a channel this peer sends on is refused
before a byte of it is decoded.

Two limits belong next to those, because the library does not pretend them away. The inner layer,
meaning framing, rate, audience and direction, is unconditional. Whether a channel's class is honest
is up to the author: nothing stops a state-changing packet from being declared a `signal`, which
forbids `authorize` and is the shortest thing to write. `Untrusted<T>` closes that route for every
function annotated `Trusted<T>`, and only for those. The second limit is that every number the
benchmark reports was measured in Studio's loopback, which supports relative comparison between
libraries and nothing else.

## Sixty lines

This is the whole of the library in one file, required by both sides: declaring, sending,
authorizing, refusing and observing. It is not a sketch. It is the text of
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

What is not in it is as much the point. There is no middleware chain, no per-call options table, no
place to pass a validator at the send site, and nothing that would let a second file change what
`equip` accepts. The declaration is the whole security model.

The seventh class replicates state instead of carrying it. The game writes its own table and never
calls netweave again. Once a frame netweave reads the store and sends each client the difference
between what it should see and what it has, so a joining client gets the whole value, a frame where
one field of twelve moved costs three bytes, and a client whose audience membership changes gets
exactly the difference. The same file continues:

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

Channels are classified by security obligation, not by transport, so that the class name is the
documentation. A `command` changes authoritative state, requires `data`, `rate` and `authorize`, and
hands its handler `Trusted<T>`. An `intent` is a continuous observed input such as movement or aim;
it forbids `authorize`, because per-packet approval is the wrong model at 60 Hz, and it coalesces to
at most one value per player per tick so that a flood cannot become per-packet work. A `signal`
carries no authority, forbids `authorize` so that it stays honest, and delivers `Untrusted<T>`. A
`query` is a command that answers: it requires `args`, `returns`, `rate`, `authorize` and a `timeout`
with no unlimited value, and it is the one class whose handler may yield. `state` and `event` go the
other way, from server to client, and must name their audience. `replicate` also goes down, takes a
`store` at declaration, and refuses `unreliable`, because a dropped delta would leave that client
wrong for ever, where a dropped `state` packet costs one tick.

Every channel also carries a byte ceiling it derived from its schema, because every netweave type is
bounded, and a packet claiming more is refused before it is decoded. `rate` is a sustained rate
enforced by a token bucket rather than a window, so the promise is "no more than `rate` per second in
any second" and not in the seconds netweave happened to draw.

## What happens to a refused packet

Nothing is thrown. Every refusal is a value with a channel, a player, a stage and a reason. By default
it is written to the console, three times per channel and stage and then suppressed, so that a flood
cannot become the outage; whatever the game attaches with `nw.observe` receives all of them. The
stages are `parse`, `budget`, `direction`, `protocol`, `authorize`, `handler`, `queue`, `send`,
`query` and `replicate`, and each report says which one refused and why. `nw.diagnostics()` returns
the count of every refusal since the counters were reset, by channel and stage, which is what answers
whether a channel is refusing more than it was an hour ago, the question that separates a bug from an
attack. `nw.configure` sets a severity per rule and never enforcement: a rule set to `"off"` still
refuses and still counts.

## The surface

Everything hangs off `nw`. `nw.namespace(name, channels)` declares a group of channels once, to be
required by both sides, and every namespace has to be declared before the first packet moves because
each channel's id depends on all of them. `nw.types` is the schema library, where every type is
bounded: `t.u8`, `t.u16(0, 1000)`, `t.string(0, 32)`, `t.array(t.u8, 0, 8)`, `t.struct`,
`t.enum({ a = true, b = true })`, `t.optional`, `t.map`, `t.union`, `t.quantized`, `t.vector3`,
`t.cframe`, `t.instance("BasePart")` and `t.player`; the payload type of any schema is
`t.PayloadOf<typeof(schema)>`, so a helper never writes a type the schema already states. `nw.policy(factory)` builds a policy in two stages, the factory once and the check per
request, and a check returns `nw.allow(value)` or `nw.deny(reason)`; `nw.all(...)` composes policies
and stops at the first denial. `nw.audience` offers `everyone`, `owner`, `nearby(studs)` and
`select(fn)`. `nw.store.of(table)`, `nw.store.charm(getter)` and `nw.store.replica(replicas)` are
what `replicate` reads. `nw.observe(fn)` sees every rejection, `nw.configure(settings)` sets
severities and limits and refuses a misspelled name at the call site, `nw.protocol()` and
`nw.signature()` are what both peers must agree on, `nw.validate(schema, value)` checks a value you
already hold and produces `Trusted<T>` without a wire, and `nw.diagnostics()` is the counters.

`docs/DESIGN-API.md` is the full contract, with the reasoning and the corrections that measurement
forced on it, and `docs/WIRE-FORMAT.md` is the frozen v1 wire format.

## Installing

There is no package registry entry. The library is the `src/` directory, it has no build step, and
every require in it is a relative string that resolves the same way in Studio and under lune. Either
copy `src/` into your project as a folder named `netweave`, or build the package with
`rojo build default.project.json -o netweave.rbxm` and insert it where both sides can reach it. On
both sides, `local nw = require(ReplicatedStorage.netweave.netweave)` and `local t = nw.types` is all
there is. Requiring it inside Roblox installs the transport, and there is nothing to configure and no
step to remember, because a game that declared its channels has already said everything the transport
needs. [Step 1 of the tutorial](docs/tutorial/step1-install.md) walks through it in an empty place.

## What it costs

`bench/RESULTS.md` has every number with its spread, its sample count and the run document it came
from, and says at the top why none of it is a bandwidth figure. From the two runs that closed M4, in
Studio loopback at 200 packets a frame, the array payload of a hundred six-byte structs is a three-way
tie at the theoretical floor: 601 bytes for netweave, Blink and Zap, 603 for ByteNet. On a payload of
twelve booleans, two enums and two optionals netweave pays 8 bytes against Zap's 7, and that byte is
the length prefix the framing guarantee needs; Blink pays 10 or 20 depending on how its author
spelled the schema, and ByteNet pays 20. Encoding the array payload, netweave held 114 and 115 frames
a second across the two runs against Blink's 131 and 134, with Zap and ByteNet at 112 to 116, so it
sits with the other two generators and behind Blink by 1.15x. Decoding it, netweave is behind Blink,
at 63 and 54 against 78 and 83, and the results file says what is known about why and what is not.
Every cell delivered and validated its payload in every direction, and the harness counts drops next
to throughput because a fast library that loses packets is not fast.

## Developing

Tools are managed by [rokit](https://github.com/rojo-rbx/rokit) and pinned in `rokit.toml`: `rojo`,
`lune`, `stylua`, `selene` and `luau-lsp`. Type checking is part of the test suite, not a
convenience. `pwsh scripts/check.ps1` runs every lune-side check in one command and is also the
pre-commit hook; `lune run analyze` is the type checker over both halves, the files that must be clean
and the files that must fail; and `rojo build test.project.json -o netweave-test.rbxl` builds the
Studio half, which is where `Vector3`, `CFrame`, `Instance` and a real client live. `CLAUDE.md` is
the repository's rulebook, and `docs/milestone/` has one plan per milestone, kept as live documents
with their corrections struck through in place rather than rewritten.

## Status

Milestone M4 is closed. Codec, transport and replication are implemented, two external security
audits have been worked through with a disposition for every finding, in `docs/SECURITY-REPORT*.md`
and `docs/milestone/PLAN-M4.md` §9, and both the lune suite and the Studio suite are green.
`PLAN-M5.md` is written and not opened; it holds the type-layer work the audits deferred. This
repository is developed locally and has no hosted remote.
