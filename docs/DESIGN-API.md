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

G4 and G5 are transport properties, settled by the wire format in `PLAN-M1` phase 2. G1 through
G3 and G6 are what the declaration syntax has to carry.

Both codegen libraries fail G4 and G5 today: a failed `assert` inside their receive loop aborts
the whole batch, and neither has a length field to resynchronise on (`RESEARCH §3.8-R`).

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

**Every channel carries a byte ceiling, and it derived it from the schema.** Every netweave type is
bounded — a number by its encoding, a string or array by its range, an unbounded array by the 65535
its prefix can express — so the layout can add them up. `t.struct({ origin = t.vector3, seq = t.u16 })`
can never be more than fourteen bytes, and a packet claiming more is refused before a byte of it is
decoded, at stage `budget`, with the game having declared nothing. `RESEARCH §3.7-F` records that no
surveyed library checks a payload size at all; the reason is that they would have to ask the author
for the number.

An inbound class may declare **`maxBytes`** to *tighten* that ceiling, and only to tighten it: asking
for more than the schema can produce is refused rather than clamped, because a ceiling that can never
be reached would let an author believe they had set a limit. It is for the schema whose bound is
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
`nw.validate(schema, value)`. **There is no `nw.untrust`.** An unwrap function would be used
reflexively and the brand would become decoration.

```lua
local function giveItem(player: Player, request: nw.Trusted<{ id: number, count: number }>) end

combat.openedMenu:listen(function(ctx, request)   -- request: Untrusted<{ id, count }>
    log("menu " .. request.id)                    -- fine
    giveItem(ctx.player, request)                 -- type error
end)
```

~~The example above used `data = t.u8` and a `Trusted<number>` parameter.~~ It could not have
worked, for the reason just given. A channel whose payload you intend to brand carries a struct.

### The limits, stated plainly

**A scalar payload is unbranded.** `Trusted<number>` *is* `number`, and the type says so rather
than pretending to a guarantee Luau cannot express. Wrap a scalar in a one-field struct if the
brand matters on that channel — which is also the shape that survives adding a second field later.

**Enforcement is opt-in on the game's side.** Luau is structurally typed, so a value usable as `T`
is accepted anywhere `T` is. `Untrusted<T>` is deliberately a subtype of `T` — that is what makes
field access, logging and UI work without ceremony — and the price is that it also satisfies an
un-annotated `f(x: T)`. Functions that carry authority have to declare `Trusted<T>`. netweave
cannot make that automatic, and claiming otherwise would be false. Deciding which of your
functions are authoritative is the discipline this library is selling, so requiring it to be
written down is acceptable.

**A brand that its own module never mentions silently disappears.** An `export type function` that
the module defining it does not reference anywhere reduces to `any` for a module that requires it,
with no diagnostic — so `nw.Trusted<T>` would keep compiling and stop meaning anything. This is
guarded in `src/api/Trust.luau` by two local aliases whose only job is to be that reference, and in
`src/api/View.luau` by `Views<D>`. `tests/api_reject.luau` is what would catch a regression:
its count would drop, and `analyze` fails on that. See `spike/declare/README.md` Q5.

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
    -- stage: "parse" | "budget" | "authorize" | "handler" | "queue" | "send" | "protocol"
end)
```

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
        handler = "error",    -- default: the game's own bug, so every occurrence
        queue = "warn",
        send = "warn",
        rateUnbounded = "warn",
    },
    limits = {
        queueCapacity = 256,
        unreliableBytes = 908,
        repeatsPerDiagnostic = 3,
    },
    contextGuard = nil,       -- nil means Studio-only, as before
})
```

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
