# netweave API design

**Status:** implemented. `spike/inference/` resolved §7 and §10 Q1-Q3; M1 phase 5 built the surface
in `src/api/` and corrected §6 where measurement contradicted it (`spike/declare/`).
What remains open is disclosure, not shape: §10.5 and §10.6.

Security and structure are the first-order goals of this library. Performance is a supporting
claim — the benchmark in `bench/` exists to show that enforcing the guarantees below costs
little, not to win a throughput contest. Everything here traces to `docs/RESEARCH-AND-PLAN.md`.

---

## 0. Who this is for

netweave is **strict by theme**. The guarantees in §2 are the product; performance is a
supporting claim, and optimization is deliberately deferred until the guarantees are in place
and the benchmark says where to spend (`PLAN-M1` phase 6).

That choice narrows the audience, and pretending otherwise would set the wrong expectation:

| | Fit |
|---|---|
| Writes `--!strict`, has used ByteNet/Blink/Zap | **the target.** The declaration is no longer than ByteNet's, and the rate limits and authorization checks they already scatter by hand move into one reviewable place. |
| Does not use `--!strict`, does not know the solver setting | **not the target.** Half the guarantees are type errors; without the new solver they are nothing, and the user sees analysis errors inside code they did not write (§7). |

Blink and Zap serve anyone who can run a CLI. netweave asks for a typed codebase first. That is
a smaller slice of the ecosystem, chosen on purpose.

### The guarantees are layered

The inner layer is unconditional: framing, rate declaration, audience declaration, direction.
No user code can opt out of it.

The outer layer — whether a channel's *class* is honest — depends on the author. `command`
requires `authorize`, but nothing forces a state-changing packet to be declared a `command`
rather than a `signal`, which forbids `authorize` and is therefore the shortest thing to
write. §6's `Untrusted<T>` closes that route for any function annotated `Trusted<T>`, and only
for those.

This is a real limit, not an oversight. Stated here so the library does not appear to promise
enforcement it cannot deliver. See §10.5.

## 1. The question this design answers

Not "how does a user send a packet" — every library in `RESEARCH §1` answers that, and they all
answer it about the same way. The question is **what the API refuses to let you write.**

The five libraries surveyed all treat validation as schema conformance: *is this a Vector3?*
That is parsing. It says nothing about whether this player was entitled to send this Vector3
right now. No library in the ecosystem makes that distinction first-class, and it is where the
actual exploits live.

## 2. Guarantees

| | Guarantee | Violating code |
|---|---|---|
| G1 | An inbound channel that changes authoritative state has no listener until a policy is attached | type error |
| G2 | Every inbound channel declares a rate budget. There is no "unlimited" | type error |
| G3 | Every server-to-client channel declares its audience. `broadcast` exists only where the audience is everyone | type error |
| G4 | Wire data never reaches `error()`. Rejections are values, routed to an observer | not expressible |
| G5 | Length-prefixed framing: one malformed packet cannot stop the rest of its batch | not expressible |
| G6 | Direction is a class, not a string field | type error (see §7) |

**G4 is enforced rather than inspected, since M3 phase 9.** It was stated unconditionally and held
for the byte stream and not for the two paths an external review found: a non-Instance in the
instance sidecar, which is wire data that does not travel in the buffer, and a pooled pending list
that two dispatch loops both believed they owned. Both are closed — but fixing the paths somebody
found does nothing for the next one, so the read phase and the dispatch phase now each run under a
guard that restores the shared state, returns the pending list and reports the raise. The claim
costs two `pcall`s per batch and stops resting on an argument.

G4 and G5 are transport properties, settled by the wire format in `PLAN-M1` phase 2. G1 through
G3 and G6 are what the declaration syntax has to carry.

Both codegen libraries fail G4 and G5 today: a failed `assert` inside their receive loop aborts
the whole batch, and neither has a length field to resynchronise on (`RESEARCH §3.8-R`).

## 2.1 The whole surface, on one page

Six classes, and the class name is the security documentation. What each one requires is what it
cannot work without; what each one forbids is what would make its name a lie.

| Class | Direction | Requires | Forbids | The handler receives |
|---|---|---|---|---|
| `nw.command` | C→S | `data`, `rate`, `authorize` | — | `Trusted<T>` |
| `nw.intent` | C→S | `data`, `rate` | `authorize` — per-packet approval is the wrong model for 60 Hz input | constrained `T`, at most one per player per frame |
| `nw.signal` | C→S | `data`, `rate` | `authorize` — if it needs approving it was a command | `Untrusted<T>` |
| `nw.query` | C→S→C | `args`, `returns`, `rate`, `authorize`, `timeout` | a top-level optional `returns` | `Trusted<T>`, and the handler may yield |
| `nw.state` | S→C | `data`, `audience` | `rate`, `burst`, `maxBytes`, `authorize` — the server is the sender | `T` |
| `nw.event` | S→C | `data`, `audience` | `rate`, `burst`, `maxBytes`, `authorize` — same reason | `T` |

Everything else on the surface:

| | What it is | The one thing to know |
|---|---|---|
| `nw.namespace(name, channels)` | a group of channels, declared once and required by both sides | declare every one at startup; ids depend on all of them (`WIRE-FORMAT.md` §3) |
| `nw.types` | the schema library: `t.u8`, `t.string(0, 32)`, `t.array`, `t.struct`, `t.enum`, `t.optional`, `t.union`, `t.quantized` | every type is bounded, which is where each channel's byte ceiling comes from |
| `nw.policy(factory)` | two stages: the factory runs once, the check runs per request | a verdict is `nw.allow(value)` or `nw.deny(reason)`, and `ok == true` or it is a refusal |
| `nw.all(...)` | composes policies, threading the allowed value onward | it stops at the first denial |
| `nw.audience` | `everyone`, `owner`, `nearby(studs)`, `select(fn)` | only `everyone` gives a channel `broadcast` |
| `nw.observe(fn)` | every rejection, with its stage | attaching one replaces the default console output; it does not make refusals stop |
| `nw.configure(settings)` | severities per rule, and numeric limits | a severity governs output and never enforcement |
| `nw.protocol()` / `nw.signature()` | what both peers must agree on, and the text it is hashed from | a mismatched peer is refused at stage `protocol` |
| `nw.validate(schema, value)` | check a value you already hold | the escape hatch that produces `Trusted<T>` without a wire; it decides by running the encoder, so it is exactly as strict as the encoder is |
| `nw.diagnostics()` | every refusal since the counters were reset, by channel and stage | frozen on read; a rule set to `"off"` still counts |

### One worked example

Declaring, sending, authorizing, refusing and observing, in sixty lines. This is not a sketch:
`tests/example_runtime.luau` runs it in the suite, and `tools/messages.luau` asserts that the code
below is the same text. A document quoting code it does not execute rots on the first rename.

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

What is *not* in it is as much the point. There is no middleware chain, no per-call options
table, no place to pass a validator at the send site, and nothing that would let a second file
change what `equip` accepts. The declaration is the whole security model.

### The same file, replicating

The seventh class in the same shape. The server never calls it: `store` is the only way in, so
the absence of `publish` on the server view is the guarantee rather than a convention.

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

## 3. Channel classes

The taxonomy is by **security obligation**, not by transport. The class name is the security
documentation — a reader sees `nw.intent` and knows the server does not approve each packet.

| Class | Direction | Required | Forbidden | Handler receives |
|---|---|---|---|---|
| `command` | C→S | `data`, `rate`, `authorize` | — | `Trusted<T>` |
| `intent` | C→S | `data`, `rate` | `authorize` | constrained `T` |
| `signal` | C→S | `data`, `rate` | `authorize` | `Untrusted<T>` |
| `query` | C→S→C | `args`, `returns`, `rate`, `authorize`, `timeout` | — | `Trusted<T>` |
| `state` | S→C | `data`, `audience` | `rate`, `burst`, `maxBytes`, `authorize` | `T` |
| `event` | S→C | `data`, `audience` | `rate`, `burst`, `maxBytes`, `authorize` | `T` |

**Direction is checked on arrival, not only in the views.** ~~The reason `state` and `event` forbid
`rate` is that the server is the sender, so there is nobody to budget.~~ That was true of the views
and not of the wire: a client could put any id in a packet it writes, and until M3 phase 9 the
server resolved it, found no rate to charge, decoded it and queued it. Six hundred such packets
measured `budget=0`. A packet arriving on a channel this peer is the sender of is refused before
decode, at stage `direction`, which G6 needed to be a guarantee about peers rather than about the
game's own code.

**Every channel carries a byte ceiling, and it derived it from the schema.** Every netweave type is
bounded — a number by its encoding, a string or array by its range, an unbounded array by the 65535
its prefix can express — so the layout can add them up. `t.struct({ origin = t.vector3, seq = t.u16 })`
can never be more than fourteen bytes, and a packet claiming more is refused before a byte of it is
decoded, at stage `budget`, with the game having declared nothing. `RESEARCH §3.7-F` records that no
surveyed library checks a payload size at all; the reason is that they would have to ask the author
for the number.

~~and a packet claiming more is provably a lie~~ — **it was provably a lie only where the schema had
no flags below its top level.** `Ir.ceiling` counted the root's bitfield and not the one a dynamic
array or map element opens per element, so `t.array(t.boolean, 0, 10)` derived one byte where ten
elements cost eleven, and an honest three-element packet was refused at stage `budget` against its
own sender. Corrected in M3 phase 9, and `tests/ir_runtime.luau` now asserts the property the number
claims — encode at the maximum, assert it fits — rather than a table of examples that all happened
to work.

An inbound class may declare **`maxBytes`** to *tighten* that ceiling, and only to tighten it. Two
declarations are refused rather than accepted, because both would let an author believe they had set
a limit: a ceiling above what the schema can produce, and **any** ceiling on a statically framed
channel — a static payload carries no length prefix, so there is no claim to check and the number
would never be consulted. It is for the schema whose bound is
honest and useless — `t.array(t.array(t.u8, 0, 1000), 0, 1000)` derives 1,002,002, and `maxBytes = 2048`
at `rate = 20` turns that into 40,960 bytes per second.

Every class that declares a `rate` may also declare a **`burst`**, the depth of its token bucket.
It defaults to `rate` — one second's worth, the safe reading of silence — and it cannot be
declared below `rate`, because tokens accrue at the rate and a shallower bucket would throw the
difference away every second, leaving the declared rate unreachable and therefore fiction.

`rate` is a *sustained* rate, enforced by a bucket rather than a window. A window that resets on a
boundary admits a full allowance on each side of it: a channel declared `rate = 20` measured **39
admissions across ten milliseconds** before M3 phase 0. The guarantee is now "no more than `rate`
per second in any second", not "in the seconds netweave happened to draw".

**`command`** changes authoritative state. Authorization is not optional, because a command
without it is the exact shape of every Roblox exploit writeup.

**`intent`** is a continuous observed input — movement, aim. Per-packet approval is the wrong
model and too expensive at 60 Hz; the server decides authority during its own tick. The class
says that out loud so nobody mistakes it for an RPC.

**`signal`** carries no authority. `authorize` is *forbidden* here so the class stays honest:
if you need to approve it, it was a `command`. Its payload arrives branded `Untrusted<T>`.

**`query`** is a `command` that answers, and the differences all follow from the answer. `timeout`
is required and has no unlimited value, because a request that never resolves is a leak
(`RESEARCH §3.7-G`). `returns` may not be a top-level `t.optional`, because `invoke` reports failure
as `nil` and an answer that may itself be nil would be indistinguishable from a call that never came
back (§7). Its reply gets a derived ceiling of its own from `returns`, which is not declarable —
`maxBytes` exists to police a peer, and on a query the peer is the client asking the question, not
the server answering it.

It is also **the one class whose handler may yield**, which is what a query is for: a datastore
read, a `WaitForChild`, an HTTP call. Three things follow. The handler runs on its own thread, so
the rest of the batch is not waiting on it. It receives a context of its own rather than the shared
per-player one, which is refreshed out from under anything that yields (§8). And a player's parked
handlers are a resource they can spend, so `callsInFlight` bounds how many of them one player may
hold at once.

**`state`** and **`event`** must name their audience. Broadcasting everything to everyone is how
positional data leaks to wallhacks; making the recipient set a declaration rather than a call
site turns that into a reviewable line of code.

### `intent` changes behaviour, not just documentation

An `intent` channel **coalesces: at most one value per player per tick is delivered.** Stale
input has no value, and an attacker filling the rate budget cannot convert that into per-packet
server work. This also makes `rate` mean something concrete rather than being a cap nobody hits.

This is the one place where merging is semantically safe. `RESEARCH §3.7-E` argues batching
unreliable traffic is a semantic error in general — losing one datagram loses N events — and
`intent` is the exception that proves it, because losing a superseded input is free.

### Internally there are three primitives, not six

```
command ─┐
query   ─┼─ AuthorizedInbound   (query also owns a paired response Outbound)
intent  ─┘
signal ──── UntrustedInbound
state  ─┐
event  ─┴── Outbound
```

~~Six public classes, four implementations.~~ **Three** — the diagram above only ever listed
three, and the fourth was `query`'s response, which is not a separate primitive but the `Outbound`
that `query` already owns. Corrected in M1 phase 5. The public surface is where meaning lives; the
implementation stays small.

### Replication is a seventh class, not `state` growing up

`PLAN-M4` D-1, answered in phase 2 before any of L3 was written, because everything else in that
milestone depends on it.

**`nw.state` is not misnamed, and the plan was unfair to it.** "State" means the current state of a
subject, sent to whoever should see it, and that is exactly what it does. What it never promised was
delta compression. What was missing was a docstring saying which of the two it is.

Replication is `nw.replicate`, and three things make it a different declaration rather than a flag
on this one. Any one of them would be enough; the first is the plainest.

**They have no method in common.** `nw.state` is `publish(subject, value)` — the game holds the
value and hands it over each tick. `nw.replicate` takes a **store** at declaration and the game
never calls netweave again; netweave reads the store and decides what each client is missing. Two
surfaces with no call in common are not one class with an option.

**They sit on opposite sides of the reliability trade, and G6's argument applies exactly.** A
dropped `state` packet costs one tick of staleness and the next packet corrects it, which is why
`unreliable` is legal there and why positional data belongs on it. A dropped *delta* leaves that
client permanently and silently wrong, because every later delta is relative to a baseline it does
not have. `unreliable` is therefore **forbidden** on `replicate` — and a single class with a flag
that means "fine" on one setting and "silently wrong forever" on the other is precisely the shape
this design exists to make unwritable.

**They cost different memory on the server, and the declaration has to carry the limit.** `state`
holds one coalesced value per player per channel and releases it at the tick. `replicate` holds a
**baseline per client per subject** for as long as that client is connected — memory proportional to
players times state size, chosen by how many people join, which is `PLAN-M3` D-6 territory and needs
a declared ceiling that `state` has no use for.

| Class | Direction | Required | Forbidden | Handler receives |
|---|---|---|---|---|
| `replicate` | S→C | `data`, `audience`, `store` | `rate`, `burst`, `maxBytes`, `authorize`, `unreliable` | `T` |

The one thing they do share is the receiving end: `:listen(function(value) end)` hands the client
the whole value, because a client that has to know whether it was sent a snapshot or a patch is a
client the library has failed.

They do not share what that value *is*. On `replicate` it **is the client's baseline**, frozen —
a change is folded into what the client already had and every subtree the patch did not touch is
shared with it, which is why one field of twelve costs three bytes and not a whole subject. Writing
into it would rewrite the base the next change is applied to, so a prediction written as
`value.hp -= 1` would leave that field wrong for ever with nothing on either side to say so
(M4 report, measured). A game that wants one to write to takes `table.clone(value)`; the freeze is
there so that requirement is a raise on the offending line rather than a bug three patches later.

#### Reliable delivery is the answer to D-2, and netweave's own limits are the hole in it

`PLAN-M4` D-2 offered three shapes — reliable deltas, acknowledged baselines, periodic snapshots —
as though loss were possible on the reliable path. **It is not.** netweave's reliable path is a
`RemoteEvent`, which Roblox delivers reliably and in order, so a delta that netweave hands to the
engine arrives. Acknowledgements and periodic re-snapshots are answers to a problem the transport
does not have, and both cost what `PLAN-M3` spent a milestone bounding.

What *can* drop a delta is **netweave itself**. `pendingPerBatch` drops the tail of an oversized
batch and reports it; on a `signal` that is one lost packet and on a `replicate` it is a client
that will never be right again. So the design is reliable deltas **plus a break detector**: a
sequence per client per subject, and a client that sees a gap is sent a snapshot rather than
another delta.

That same path answers D-4 for free. A client entering a `nearby` audience has no baseline, which
is the same condition as a gap, so "you are out of sync, here is everything" is one mechanism
serving a join, a drop and an audience transition alike.

## 4. Declaration

Configuration objects, not builder chains. A required field in the spec type enforces a
requirement just as well as a staged builder and reads far shorter.

```lua
local nw = require(Packages.netweave)
local t = nw.types
local policy = require(Shared.Policies)

return nw.namespace("combat", {
    fireWeapon = nw.command({
        data = t.struct({ origin = t.vector3, direction = t.unitVector3, seq = t.u16 }),
        rate = 20,
        authorize = nw.all(policy.alive, policy.originNearCharacter),
    }),

    aim = nw.intent({
        data = t.struct({ pitch = t.f32(-90, 90), yaw = t.f32(-180, 180) }),
        rate = 60,
    }),

    openedMenu = nw.signal({
        data = t.u8,
        rate = 2,
    }),

    getLoadout = nw.query({
        args = t.u8(0, 2),
        returns = t.struct({ primary = t.u16, secondary = t.u16 }),
        rate = 2,
        timeout = 5,
        authorize = policy.ownsSlot,
    }),

    playerState = nw.state({
        data = t.struct({
            entityId = t.u16,
            grounded = t.boolean,
            sprinting = t.boolean,
            weapon = t.enum({ "primary", "secondary", "melee" }),
            position = t.vector3,
        }),
        audience = nw.audience.nearby(120),
    }),

    hitConfirmed = nw.event({
        data = t.struct({ victim = t.u16, damage = t.u8 }),
        audience = nw.audience.owner,
    }),
})
```

Reading only the declaration tells you the security model of this namespace. Constraints live
inside the types (`t.f32(-90, 90)`), so validation is derived rather than written twice
(`RESEARCH §3.5-S1`).

Channel ids are the string keys, qualified by the namespace name. Nothing depends on table
iteration order — ByteNet assigns packet ids by iterating its declaration table, and this
project hit the resulting silent mis-decode during M0.

## 5. Policies

Two-stage, the structural idea worth keeping from Flamework (`RESEARCH §3.5-S3`): the outer
call runs once at load, the inner runs per request. Unlike Flamework, the attachment point is
the declaration itself, so "what is enforced on this channel" is one place, not two.

```lua
-- shared/Policies.luau
local nw = require(Packages.netweave)

local policy = {}

policy.alive = nw.policy(function()
    return function(ctx)
        return ctx.humanoid and ctx.humanoid.Health > 0 and nw.allow() or nw.deny("dead")
    end
end)

policy.originNearCharacter = nw.policy(function(config)
    local maxStuds = config.maxStuds or 8
    return function(ctx, shot)
        local root = ctx.character and ctx.character.PrimaryPart
        if not root then
            return nw.deny("no character")
        end
        if (shot.origin - root.Position).Magnitude > maxStuds then
            return nw.deny("origin detached")
        end
        return nw.allow(shot)
    end
end)

return policy
```

Named values, so they are reusable and unit-testable without a network. `nw.all` composes.

## 6. Trust

`Untrusted<T>` records provenance in the type: this value came off the wire.

~~`export type Untrusted<T> = T & { __nwUntrusted: true? }`~~
**Wrong for scalar payloads, corrected in M1 phase 5.** `number & { __nwUntrusted: true? }`
normalises to **`never`**, and `never` is a subtype of everything — so a branded number rejects
every legitimate use of the value (`id + 1` does not type-check) *and* satisfies every parameter
it was meant to guard, including `Trusted<number>`. That is strictly worse than no brand:
it breaks the honest caller and admits the dishonest one. Measured in `spike/declare/brand.luau`.

Both brands are therefore type functions. They intersect the tag onto **table** payloads and pass
anything else through unchanged:

```lua
export type function Untrusted(payload)   -- T & { __nwUntrusted: true? } when T is a table,
export type function Trusted(payload)     -- T otherwise
```

Only three things produce `Trusted<T>`: a `command` handler, a `query` handler, and
`nw.validate(schema, value)` — plus an explicit cast for server-authored data. **There is no
`nw.untrust`.** An unwrap function would be used reflexively and the brand would become
decoration; a cast has to be written out, which is why it is the escape hatch.

```lua
local function giveItem(player: Player, request: nw.Trusted<{ id: number, count: number }>) end

combat.openedMenu:listen(function(ctx, request)   -- request: Untrusted<{ id, count }>
    log("menu " .. request.id)                    -- fine
    giveItem(ctx.player, request)                 -- type error
end)
```

~~The example above used `data = t.u8` and a `Trusted<number>` parameter.~~ It could not have
worked, for the reason just given. A channel whose payload you intend to brand carries a struct.

### What `Trusted<T>` actually asserts

Not "this data is well-formed" — the codec already guaranteed that. By the time a handler runs, a
`t.u8(0, 100)` field **is** in 0..100; anything else was refused at the `parse` stage and the
handler was never called. `Untrusted<T>` does not mean unvalidated.

It means: **the server has not taken responsibility for this value.** The hazard is authorization
confusion, not malformed data. Both producers confer trust on that reading — a `command` handler
because a policy ran and allowed it, `nw.validate` because the caller ran a check and wrote the
failure branch. A `signal` payload is structurally perfect and nobody vouched for it.

### The tag is required

~~`Untrusted<T>` is deliberately a subtype of `T`, and only three things produce `Trusted<T>`.~~
The first half stands; **the second was false until M3 phase 3.** The tag was
`{ __nwTrusted: true? }`, and an optional property is one a table literal is inferred to satisfy by
not having it:

```lua
giveItem({ screen = 1 })                        -- compiled
giveItem({ screen = untrusted.screen })         -- compiled
```

The second line is the one that matters. The brand is on the container, so taking an untrusted
payload apart and putting it back together laundered it, in a line a programmer writes without
thinking. Making the property required rejects both; `tests/api_reject.luau` cases 16 and 17 are
those two lines, and cases 13 and 18 pin the two brands separately so neither can quietly become
`any`.

`Trusted<T>` is still a subtype of `T`, so reading fields, logging and arithmetic work with no
ceremony — that has not changed and is what a wrapper would have cost.

**The price** is a type that asserts a field the runtime has not got: `__nwTrusted` reads `nil`
where the type promises `true`. A phantom on a name nobody reads, against a wrapper that would have
misdescribed the entire value and allocated one per packet.

**Server-authored data uses a cast**, `(value :: any) :: nw.Trusted<T>`, pinned in
`tests/api_ok.luau`. Deliberately a cast rather than an `nw.trust()` helper, for the same reason
there is no `nw.untrust`: a function gets reached for reflexively and a cast does not.

### The limits, stated plainly

**A scalar payload is unbranded.** `Trusted<number>` *is* `number`, and the type says so rather
than pretending to a guarantee Luau cannot express. `number & { tag }` normalises to `never`, which
would satisfy every parameter rather than none. Wrap a scalar in a one-field struct if the brand
matters on that channel — which is also the shape that survives adding a second field later.

**Reading a field escapes the brand, and no encoding fixes that.** `untrusted.amount` is a plain
`number`, because a scalar cannot carry the tag. Taint does not propagate into fields and cannot be
made to. The brand catches confusion about a *payload*; it cannot catch confusion about a number
that came out of one.

**A spelled-out forgery still compiles.** `giveItem({ screen = 1, __nwTrusted = true })`
type-checks. That is the cast escape hatch wearing a different hat, and the difference from the old
behaviour is the one that counts: a forgery you have to write is one a reviewer sees and `grep`
finds, where an omitted optional property was invisible.

**Enforcement is opt-in on the game's side.** Luau is structurally typed, so `Untrusted<T>`
satisfies an un-annotated `f(x: T)`. Functions that carry authority have to declare `Trusted<T>`.
netweave cannot make that automatic, and claiming otherwise would be false. Deciding which of your
functions are authoritative is the discipline this library is selling, so requiring it to be
written down is acceptable.

**A brand that its own module never mentions silently disappears.** An `export type function` that
the module defining it does not reference anywhere reduces to `any` for a module that requires it,
with no diagnostic — so `nw.Trusted<T>` would keep compiling and stop meaning anything. This is
guarded in `src/api/Trust.luau` by two local aliases whose only job is to be that reference, and in
`src/api/View.luau` by `Views<D>`. `tests/api_reject.luau` is what would catch a regression: its
count would drop, and `analyze` fails on that. See `spike/declare/README.md` Q5.

**Four places build the tag and they cannot share code.** A `type function` body sees only the
`types` library, so `src/api/View.luau` builds its own copy of what `src/api/Trust.luau` builds.
`tests/api_ok.luau` asserts they agree by assigning one to the other; changing one side alone fails
it, which was verified rather than assumed.

*(The alternative — typing `Untrusted<T>` as a table with arithmetic metamethods while it is a
bare number at runtime — buys automatic rejection at the cost of a type that lies about the
value. Still rejected.)*

## 7. Views

```lua
-- server.luau
local combat = require(Shared.Combat).server

combat.fireWeapon:listen(function(ctx, shot) end)
combat.aim:listen(function(ctx, look) end)
combat.getLoadout:handle(function(ctx, slot) return loadout end)
combat.playerState:publish(subject, state)
-- combat.playerState:broadcast   -- absent: this channel's audience is `nearby`
```

```lua
-- client.luau
local combat = require(Shared.Combat).client

combat.fireWeapon:send(shot)
combat.playerState:listen(function(state) end)
local loadout, failure = combat.getLoadout:invoke(0)
```

### What `invoke` returns

`(R?, string?)` — the answer, or `nil` and a reason. Decided in M3 phase 4, against a shared plan
that asked for `nil` not to mean failure.

The objection to `nil` is real in general: it conflates "failed" with "returned nothing". It does
not apply here, because **a query's `returns` may not be a top-level `t.optional`**. That is
refused at the declaration, where the fix is one line the author writes once:

```lua
returns = t.struct({ found = t.boolean, value = t.optional(...) })
```

With that rule in force `nil` is unambiguous, and the alternatives cost more than they buy:

| Shape | Cost |
|---|---|
| `(R?, string?)` | none; `R?` cannot be used without a nil check under the solver netweave requires |
| `{ ok, value } \| { ok, reason }` | a table per call, to buy narrowing that `if not answer then` already gives |
| raise on failure | a refused query is an ordinary outcome, not an exception (G4) |
| `(boolean, R \| string)` | the caller cannot narrow a union off a separate boolean, so every call site casts |

The failure cannot be ignored, and the type system is what enforces that rather than a convention:
`local loadout = getLoadout:invoke(0)` types `loadout` as `Loadout?`, and reading a field off it is
a diagnostic. That is the same bargain §7 makes for direction — a guarantee that is a type error or
it is nothing.

**The reason is netweave's own words, never the server's.** A refusal's reason names the policy and
sometimes the player, and it goes to the observer on the server. What crosses the wire is a status
code (`WIRE-FORMAT.md` §2), and the caller sees a sentence built from that code plus, for a
timeout, the deadline it missed. Sending the real reason back would publish the authorization model
to the machine it exists to distrust, one denied request at a time.

**Every way a call can end resolves the caller.** A refusal, a raising policy, a raising handler, an
answer that will not encode, a missing handler, a full call budget, a rate refusal, an answer the
pending-set ceiling discarded, and a deadline — nine failure paths, each of which resumes the parked
thread, and each with a reason describing what actually happened rather than defaulting to the
timeout's wording. Blink and Zap resolve none of them: they have no timeout at all, so a peer that
does not answer parks the caller for the session (`RESEARCH §3.7-G`).

**How many calls may be open** is `callsInFlight`, and it is one number read from both ends. On the
server it bounds the threads one player can have parked inside slow handlers; on the caller it
bounds the answers one game may be waiting for. They are the same number because they count the
same player from either side.

~~`.server` and `.client` need to map each key of the declaration to a different channel type,
and Luau has no mapped types, so one of two fallbacks is required.~~

**Resolved by the spike (`spike/inference/`). No fallback is needed.**

A `type function` can branch on a singleton `__class` tag and build a different result type per
channel class, then map the whole declaration table. Payload types survive the mapping, including
inside handler parameters, and both direction violations fail at analysis time:

```
Key 'send' not found in table '{ listen: ((unknown, { origin: number, seq: number }) -> ()) -> () }'
Key 'publish' not found in table '{ listen: (({ health: number }) -> ()) -> () }'
```

G6 is a compile-time guarantee.

### The condition attached

`type function` requires **`LuauSolverV2`**. The stock solver rejects the syntax outright.

It does compile and run under stock Luau — verified with `luau.compile` — so it is purely an
analysis-time construct. The library loads either way; what varies is whether anything is
checked:

| | New solver on | New solver off |
|---|---|---|
| Loads and runs | yes | yes |
| Payload types inferred | yes | no |
| Direction violations caught | at analysis | not at all |
| Editor errors inside netweave source | no | yes |

**Decision: netweave requires `LuauSolverV2`.** Half of the guarantees in §2 are type errors or
they are nothing, and shipping a second untyped declaration path would mean maintaining a version
of this library that cannot keep its own promises. The last row above is the reason not to
pretend otherwise: on the stock solver a user sees errors in code they did not write, and telling
them to ignore those is worse than telling them to turn the solver on.

## 8. Context

`ctx` reaches every policy and every handler, so it must not be allocated per packet — that
would break the zero-hot-path-allocation criterion on day one (`RESEARCH §3.6-A4`, `§3.6-B4`).

### What a handler sees, and the one field that is `unknown`

A `:listen` handler's `ctx` is a table the view builds, so `ctx.now` is a `number`, `ctx.channel` a
`string`, and `ctx.playr` is a typo the analyser catches. `player`, `character` and `humanoid` are
`unknown`, because a `type function` body has only the `types` library and no way to reach `Player`,
`Model` or `Humanoid`. They pass anywhere `unknown` is accepted — `publish(ctx.player, ...)` is the
common case and works — and take a cast anywhere it is not:

```lua
local player = ctx.player :: Player
```

~~The whole context was `unknown`.~~ **Until M3 phase 7**, which is worse than it sounds: a handler
could neither read through it nor annotate it, because `Ctx` is not a supertype of `unknown` and
`function(ctx: nw.Ctx, shot)` was rejected outright. Nothing caught it, because every handler in the
suite was written `function(_ctx, ...)` and none of them wanted the context. Writing the worked
example is what found it — `ctx.player` is the first thing a real handler reaches for.

A **policy** is a plain function typed `(ctx: Ctx, value: T) -> Verdict`, so `nw.Ctx` annotates
normally there, and the example above does. The asymmetry is not a design; it is what a type
function can and cannot name.

**One `ctx` per player, fields refreshed in place, valid only for the synchronous duration of
the handler.** Retaining it is a defect:

```lua
combat.fireWeapon:listen(function(ctx, shot)
    task.defer(function()
        print(ctx.player)   -- caught in Studio; ctx has been recycled
    end)
end)
```

A generation counter bumped when the handler returns makes expired access an error in Studio.
The guard compiles out in production, so the cost is zero where it matters.

## 9. Rejections

Nothing is thrown. Every rejection is a value delivered to an observer, which is also what
makes rejection rates measurable rather than invisible — the gap `RESEARCH §3-G6` identifies,
and the failure Warp demonstrates by silently blackholing players (`§3.7-K`).

```lua
nw.observe(function(rejection)
    -- channel, player, stage, reason, bytes
    -- stage: "parse" | "budget" | "authorize" | "handler"
    --      | "queue" | "send" | "protocol" | "query"
end)
```

`query` is the caller's side of a request that produced no answer — a timeout, or a refusal the
server sent back as a code. It is not a duplicate of the stage that made the refusal: that one
fired on the server with the real reason, and this one fires on the end that was waiting, which is
the end that has to decide what to do next.

### 9.1 Observed by default

~~`nw.observe` is the only way to find out.~~ **Corrected.** M2 shipped six rejection stages and
returned early from `emit` when nothing was observing, so a game that attached no observer got
silent drops at all six — the failure `§3.7-K` faults Warp for, rebuilt with extra steps. netweave
now writes to the console by default and goes quiet on its own: one channel and stage prints three
times and then says it is suppressed. Observers are unaffected and always receive everything.

Because the console goes quiet, `nw.diagnostics()` is what is left: every refusal since the
counters were last reset, by channel and then by stage, with a count and the bytes those packets
carried. It is frozen at every level and built on read rather than kept assembled, so counting a
refusal stays two increments and a diagnostic screen cannot become a way to reset them. A rule set
to `"off"` still counts — severity is about output, and a setting that could make refusals vanish
from a diagnostic screen would be the one thing §10 says a severity must never do.

## 10. Settings

`nw.configure` takes rules in the shape ESLint made familiar, and one thing about it is not like
ESLint at all.

```lua
nw.configure({
    rules = {
        parse = "warn",       -- default
        budget = "warn",      -- default
        authorize = "off",    -- default: expected to fire in normal play
        handler = "error",    -- default: the game's own bug, so with a traceback
        queue = "warn",
        send = "warn",
        protocol = "error",
        query = "warn",       -- a call that came back without an answer
        rateUnbounded = "warn",
    },
    limits = {
        queueCapacity = 256,
        pendingPerBatch = 256,
        unreliableBytes = 908,
        repeatsPerDiagnostic = 3,
        callsInFlight = 16,   -- unanswered queries one player may hold
    },
    contextGuard = nil,       -- nil means Studio-only, as before
})
```

:::note
Every field is optional and a call that sets one leaves the rest alone. That was not true until M3
phase 4: `nw.configure` was typed `<S>(settings: S & Settings)`, which Luau rejects for every
argument, and no test called it with settings that should work — so the example above did not
compile and the rejection file's count was counting the bug. `tests/config_ok.luau` is the missing
half, and the name and value checks now both live in the `CheckedSettings` type function, one
message per mistake.
:::

**A severity governs output and never enforcement.** A packet refused at `budget` is refused
whatever `budget` is set to. There is no setting anywhere in netweave that makes a refused packet
arrive, a missing policy optional, or an unauthorised sender authorised.

That asymmetry is the whole design. A linter's `off` is safe because a linter only ever reports;
if `off` here had meant "stop refusing", then the single most copy-pasted artifact in any
ecosystem — a config block off a forum post — would be a way to delete G1 through G6 from a game
whose author never read what they pasted. Severities live in `rules`, limits live in `limits`, and
nothing can cross.

| Severity | On a wire rule | On a declaration rule |
|---|---|---|
| `"off"` | silent | the check does not run |
| `"warn"` | once per channel and stage | reported, and execution continues |
| `"error"` | **every** occurrence, with a stack | raised |

`"error"` on a wire rule does not raise and **cannot be made to** — that is G4, and
`Config.raises` answers `false` for every wire rule at every severity rather than leaving it to a
convention someone has to remember. Only `rateUnbounded` raises, because it fires on the game's own
declaration, where `CLAUDE.md` §4 says raising is correct.

**`"off"` is discouraged and the caution says why.** Reach for it when a stage fires in normal play
by design and its log is drowning something else out. Reaching for it because a warning is annoying
removes the only notice a game gets that it is dropping traffic.

**`rateUnbounded` is the only lint here**, in the ESLint sense of the word: a declaration that is
legal and probably a mistake. A `rate` above 10,000 packets per second is past anything a client can
reach, so the channel is effectively unlimited and G2 has been satisfied on paper only.
`bench/src/shared/Modes/netweave.luau` declares `1e6` and turns the rule off immediately above the
declaration — a considered exception, written down, which is the shape the rule exists to produce.

Limits are not all read at the same moment. `queueCapacity` is read when a channel's queue is first
created, so a queue that already exists keeps the depth it was made with; `unreliableBytes` and
`repeatsPerDiagnostic` are read at the point of use and take effect immediately. Configuring before
the first channel is declared makes all three behave alike, which is why that is the advice rather
than the rule. `unreliableBytes` can only be *lowered*: 908 is Roblox's ceiling, not netweave's
preference (`§3.7-F`).

**Two layers check a settings table, and they catch different things.** `Settings` catches the
values — a severity that is not one of the three, a limit that is not a number, a `contextGuard`
that is not a boolean. It cannot catch a *name*, because width subtyping accepts extra properties
and `{ rules = { handlers = "warn" } }` satisfies a type with no `handlers`. So `nw.configure` also
carries `CheckedSettings`, a `type function` that reads `properties` and refuses an unknown rule,
limit or section at the call site with the same message the runtime would have given — the answer
§4 already uses for channel specs. A misspelled rule is the case that matters: it reads as
"configured" while the default silently stays in force.

`nw.config.snapshot()` returns what is in force, frozen at every level, so a diagnostic screen
cannot become a way to reconfigure the library by accident. `nw.config.describe()` lists every rule
with its default, whether it is a wire rule, and one line on what it reports.

## 11. Open

1. ~~**Type-inference spike.**~~ **Answered** in `spike/inference/`. `type function` gives both
   per-field payload inference and directional views, under `LuauSolverV2`. See §7.
2. ~~**Does netweave require the new solver, or merely reward it?**~~ **Decided: required.** See §7.
3. ~~**Wire format.**~~ **Frozen** in `docs/WIRE-FORMAT.md` by M1 phase 2: varint ids from sorted
   qualified names, per-channel framing modes, and an FNV-1a protocol hash both peers compare.
4. **`audience` evaluation cost.** `nearby(120)` runs per publish; whether that is per-subject
   or cached per tick is a transport decision, not an API one, but it constrains the API's
   promises.
5. **The `signal` escape route.** `authorize` is mandatory on `command` and forbidden on
   `signal`, so an author who does not want to write a policy can simply declare a
   state-changing channel a `signal` — and nothing reports it. `Untrusted<T>` closes this for
   annotated code (§6), which is opt-in, so the hole is real for code that is not annotated.
   The intended answer is disclosure rather than enforcement: an `nw.audit()` that prints a
   namespace's security profile (`commands 3, intents 1, signals 9`) turns a silent failure
   into a visible smell. Deferred past M1.
7. **Observability is opt-in, and silence is the default.** `nw.observe` reports six stages of
   refusal, and a game that never attaches one sees none of them: a packet over its rate budget,
   refused by a policy, thrown out of a handler, dropped from a full queue or too large to send all
   vanish quietly. **This is the failure `RESEARCH §3.7-K` criticises Warp for** — a player silently
   blackholed with nothing anywhere saying so — reproduced by building the signal and then not
   raising it. The intended answer is a default observer that warns in Studio and goes quiet the
   moment the game attaches its own, so a rule broken for the first time is heard rather than
   memorised in advance. Deferred to M3, which owns what happens to a player who keeps overrunning.

6. **No prototyping escape hatch.** There is deliberately no "skip authorization" helper. If
   one is ever added it takes the Rust `unsafe` shape — an ugly, greppable name that also
   reports through `nw.observe` — because a pleasant name would make it the default, the same
   way `nw.untrust` would have (§6).
