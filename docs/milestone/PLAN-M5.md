# PLAN-M5 — the declaration surface, typed all the way down

**Status: opened 2026-09-11**, on `develop`. Written during `PLAN-M4-BUG` so that nothing deferred
from the M4-1 report was lost in a margin, and held until the owner's hosting situation changed; it
did not, and the milestone is opened anyway because nothing in it needs a remote. `CLAUDE.md` §8
stands unchanged: no remote, nothing published.

Drafted from `PLAN-M4-BUG` §4, extended on 2026-09-11 with what the tutorial pass exposed. The
phases below are numbered by subject, not by the order they run in; the order is under §6.

## 1. Goal

When this is done, every value `nw` hands a game has a type the game can name through `nw`, every
constructor's arguments are checked by the analyzer and not only by the runtime `check()`, a
declaration record cannot be changed after it is sealed, and the optimisation residue the M4-1
report measured (a closure per `Delta.write`, a string per `Batch.read` refusal, a send buffer
regrown per frame) is closed with a number beside each. And the lifecycle a first user learned by
breaking it — where a policy's factory runs, how long a `ctx` lives, when an intent is counted, which
side a namespace must be declared on — is either folded into the surface or reported the moment it
is broken, so that `docs/tutorial/mistakes.md` shrinks from its quiet end.

## 2. Why now

M4 closed the security and correctness findings of two audits; what it left open is the type layer,
by decision (`PLAN-M4-BUG` D-1 put instruments and client-triggerable costs first) and because each
of these items reshapes a public type. `DESIGN-API.md` §7 says half the guarantees are type errors;
M4-1 measured that the `__call` signatures check arity and not argument types, that seven exported
types no `_ok` file wrote, and that public values have no public type. `RESEARCH §3.8-T`/`§3.9-W`
is the argument that a runtime schema can be as typed as generated code; this milestone is where
that is made true for the declaration surface. `spike/declare/README.md` records what the surface
can and cannot enforce, and Q5 is the hazard every item here has to be tested against.

A second source, from outside the audits. On 2026-09-11 a first reader wrote a trade system from the
tutorial and ranked the ten mistakes they made by how quietly each failed
(`docs/tutorial/mistakes.md`, `tests/trade_ok.luau`). Six of the ten are lifecycle — a namespace
declared where the client cannot require it, an intent sent every frame against its rate, a factory
reaching for `ServerStorage`, a yield in a `command` handler, a `ctx` kept in an upvalue, a write into
a replicated value — and not one of them is caught by the analyzer or reported by the runtime; the
four that fail immediately are the ones the reader ranked last. `docs/DESIGN-API.md` §8 and
`src/api/Context.luau` chose a shared record over an allocation per packet (`RESEARCH §3.6-A4`,
`§3.6-B4`), and that list is the cost of the choice, paid by the game instead of the library. The
declaration surface is high and the lifecycle under it is bare, with nothing between; this milestone
is also where that gap is closed from below, by folding what a game cannot decide and reporting what
it can only get wrong (D-5).

## 3. Scope

| Phase | Deliverable | Artifact |
|---|---|---|
| 1 | `Ranged`/`Text`/`Componented`/`Classed` as intersections; the three payload type functions and every `readproperty` site look through one | `src/types/init.luau`, `src/api/Trust.luau`, `src/api/Channel.luau`, `src/api/View.luau`, `tests/types_reject.luau` |
| 2 | `Policy<T>`, `Check<T>`, `Snapshot`, `Described`, `Rules`, `Limits`, `Audience<S>`, `Observer` re-exported from `nw`; `tools/exports` demands a type per public value family | `src/netweave.luau`, `tools/exports.luau`, `tests/api_ok.luau` |
| 3 | the M4 report's type-layer residue: `nw.validate` returns a copy (5), the channel record frozen at seal (6), a private brand behind `isType` (7), `Policy<T>` bound to the projected payload (43), unknown spec keys refused per class (45), a real `Channel` record at the transport boundary (46), `{ [Encoding]: … }` tables (47), a shared `Stage` (48), `Sidecar = { unknown }` (50), `Ir.patch` framing (42) | `src/api/*`, `src/transport/*`, `src/codec/Ir.luau` |
| 4 | optimisation residue with a probe each: `Delta.write` closure (73), `Batch.read` refusal interpolation (74), `Buffer.take` regrowth (76), per-tick allocations (77), `Budget.admit` refusal string, instance-reader concatenation, the free list | `src/replication/Delta.luau`, `src/transport/*`, `bench/*` |
| 5 | `t.string`'s `{ charset = … }`; recipient-set caching per tick for `select`/`nearby`; the nice-to-have types (`t.literal`, `t.set`, `t.optional(x, default)`, compact `cframe`) as their own `_ok`/`_reject` pairs | `src/types/init.luau`, `src/transport/Recipients.luau`, `tests/` |
| 6 | selene block-scoped allows in place of the hand-kept global list; `bench/` and `tools/` type-checked by `analyze` | `netweave.toml`, `analyze.luau`, `src/**`, `bench/**` |
| 7 | the lifecycle, folded: a policy's server stage, run once at seal; a yield across a `ctx` reported at `handler`/`authorize` in production; `nw.keep(ctx)`; an intent paced by the client at its declared rate | `src/api/Policy.luau`, `src/api/Context.luau`, `src/api/Namespace.luau`, `src/transport/Inbound.luau`, `src/transport/Driver.luau`, `tests/transport_runtime.luau`, `bench/tick.luau` |
| 8 | the declaration that cannot work: a namespace declared under `ServerScriptService`/`ServerStorage` refused at its line; a protocol disagreement whose reason names the namespace | `src/api/Namespace.luau`, `src/api/Protocol.luau`, `src/transport/Batch.luau`, `docs/WIRE-FORMAT.md` §4, `tests/protocol_runtime.luau`, `tests/roblox_runtime.luau` |
| 9 | the documents the above move: `Policy`'s docstring, the vocabulary card, `mistakes.md` re-ranked in place, the prototyping pattern in step 3 | `src/api/Policy.luau`, `docs/tutorial/README.md`, `docs/tutorial/mistakes.md`, `docs/tutorial/step3-policies.md`, `docs/DESIGN-API.md` §8 |

## 4. Non-goals

- A `changed` signal on `Store`, `t.refine`, `t.id`, `t.timestamp`, `t.recursive`, `t.tuple`,
  `t.buffer(n)`, `nw.untrust`/`nw.trust`, a wrapper `Trusted<T>`, a discriminated `Verdict` while
  the record is shared, analysis-time numeric bound checks (the solver widens literals), a
  per-destination packet ceiling typed into `Config` — each declined with its argument in
  `docs/SECURITY-REPORT-M4-1.md` "Do not add".
- A per-client "received the last snapshot" flag over `baselinesPerClient` — declined in
  `src/replication/Baseline.luau` (PLAN-M4-BUG phase 5).
- Merging `state` and `event`. They share a publish and differ in name only, and the name is the
  point: `docs/DESIGN-API.md` §3 makes the class a reviewer's documentation of whether a channel
  carries the latest value of something or a thing that occurred once. The cost is one row on the
  vocabulary card and nothing per packet; a game that wants one class writes `event` everywhere and
  loses nothing. Considered while the trade example was written, and declined for that reason.
- A library placeholder policy — `nw.todo`, `nw.pending` — for prototyping. The `nw.untrust`
  argument applies unchanged: a pleasant name would be reached for reflexively, and a command whose
  authorization is a library constant is one a reviewer cannot tell from a finished one. A game that
  wants to defer a policy writes its own `todo(schema)` helper, one allow and one name to grep for,
  and phase 9 puts that pattern in step 3 so that deferring is spelled rather than silent.
- A third `deps` parameter on `Check<T>` for the server stage. It would move every type function
  that reads a check's arity and change the signature every policy in every game writes; the second
  return in D-5 leaves `Check<T>` and `Policy<T>` where they are.
- Handing a handler `ctx.player` as `Player` by any spelling that puts a Roblox class into a type
  function body. `docs/DESIGN-API.md` §8 stands; phase 1 measures the one witness spelling that does
  not, before this is written off for the milestone.

## 5. Design decisions

### D-1 — an intersection is the callable, and the type functions look through it

Measured in M4-1: a `typeof(setmetatable({} :: T, {} :: { __call: … }))` alias enforces argument
count and not argument type, while `Base & ((min: number, max: number) -> Base)` checks both and is
usable bare. The cost is that `StructPayload`'s `field:is("table")` is false for an intersection, so
every payload type function and every `readproperty` site has to look through one first. That is
the phase-1 deliverable and the reason it is first: nothing else in this milestone touches the
callable shape, and everything downstream of it reads `__payload`. `spike/declare/README.md` Q5 is
re-run for each of the three functions after the change.

### D-2 — a union payload alias is checkable only after use, and that is recorded rather than fixed

Measured while writing `tests/types_ok.luau` (PLAN-M4-BUG phase 6): `local _: Union = { tag = "wait",
value = 3 }` as an alias's first use fails with the literal's tag widened to every branch, and the same
line passes once a function taking the alias has been called with a literal. A solver behaviour,
not a netweave one; `types_ok` carries the working spelling, this milestone does not spend time on a
workaround, and the note stays until the solver changes.

### D-3 — a public value gets a public type, and the checker demands it

`tools/exports` enumerates `export type` declarations, so it cannot see a public value with no type
at all — which is how `nw.policy`'s return, `nw.audience.nearby`'s return and `nw.configure`'s
snapshot had no nameable type through `nw` (M4-1). The checker is taught to demand a type per public
value family, so the list of things a game cannot name shrinks the way the `UNCOVERED` list did.

### D-4 — optimisation residue lands with a probe, or not at all

Every item in phase 4 was measured by M4-1 (112 B per `Delta.write` call, 500 claims → 50 distinct
strings, 64 → 2048 → 64 across one frame). Each fix carries the probe that showed it, in `bench/`,
with a `BEFORE` produced on the parent tree — `CLAUDE.md` §9, "a measurement is not a number until
it survives re-running".

### D-5 — what a game cannot decide is folded; what it can only get wrong is reported

`replicate` hides the delta, the baseline, the resync window and audience entry because none of
them is a decision a game could make differently, and it leaves exactly two things visible — a
frozen value and `nil` for a subject going away — because those two are the ones a game has to act
on. The policy and context lifecycle never got the same treatment. The factory running at load on
both sides, the `ctx` record being recycled, the verdict being one shared table are all consequences
of `RESEARCH §3.6-A4` that a game cannot change and today has to know, and `mistakes.md` 3, 5 and 8
are what knowing it looks like. So the same rule is applied to them, without an allocation on the
hot path.

A policy factory may return a second function. It runs once, on the server, at `Namespace.seal()`,
before any packet decodes — so a server-only dependency has a named place that is never the client
and never the receive loop, and the tutorial's seam becomes the library's. The client discards it.
The structural idea is still Flamework's two-stage middleware (`RESEARCH §3.5-S3`); what is added is
a stage that knows which side it is on, which Flamework gets from `createServer` and a shared
declaration file cannot.

A handler or check that yields across another packet of the same player is detected by the
generation counter `Context.release` already moves: one integer compare after the `xpcall`, nothing
allocated, and a moved generation is reported at `handler` or `authorize` with the fix in the reason.
In production, not only behind the Studio guard — "nothing on the receive path is silent"
(`CLAUDE.md` §9) has been false for exactly this case, and it is the case where production hands a
handler another request's player.

And `nw.keep(ctx)` is the one spelling for holding a context past its handler: a table the game
asked for by name, so the cost is in the code the way `(value :: any) :: nw.Trusted<T>` is.

### D-6 — an intent's `send` is the newest value, at the declared rate

Measured writing the tutorial (2026-09-11): a `send` in every `RenderStepped` against `rate = 30` is
forty refusals a second at stage `budget`, reported on the server and invisible on the client, while
the handler sees at most one value a tick because the class coalesces. Everything past the rate was
wasted bytes and a refusal count that reads as an attack. The class already says stale input has no
value (`docs/DESIGN-API.md` §3, "`intent` changes behaviour"), so the client view holds the newest
value per intent channel and pushes it at the declared rate — the same token bucket `Budget` runs on
the server, keyed by channel rather than sender. A held value is superseded, never dropped and never
reported; `nw.diagnostics()` gains a per-channel `paced` count so a game that over-sends can see it
without a refusal. `send` on an intent then means what the class means.

It does not apply to `signal` or `command`, where every packet is a packet. The server's budget
stays as the enforcement; the client's bucket is the courtesy that makes the enforcement quiet on
honest traffic, and a client that bypasses the view still meets the server's.

### D-7 — a declaration that cannot work is refused where it is written

The first mistake in `docs/tutorial/mistakes.md` is a namespace declared in a server-only script,
and its symptom is every client refused at `protocol` with a reason that names two hashes. Nothing
about it is a matter of degree: a namespace the client cannot require can never agree, so the
declaration is the bug and the line is known. On Roblox, `debug.info(2, "s")` inside
`Namespace.declare` is the declaring module's full name, and one under `ServerScriptService` or
`ServerStorage` is refused there with the fix — `ReplicatedStorage`, required by both — in the
message. Under lune the source is a path and the check does nothing, so `tests/roblox_runtime.luau`
carries it and `CLAUDE.md` §9's note on the quiet half applies.

For the disagreements that are a matter of degree — a stale client, a partial deploy — the refusing
peer answers its hello with a per-namespace digest: control kind 3, a count and then a name and its
FNV-1a per namespace, once per mismatched peer as the hello answer already is (M3 phase 9). The
reason can then say which namespace one side lacks or which one differs, and `nw.signature()` is
reached for only to find the channel. Kind 3 is steppable by a v1 reader that predates it, which is
what `docs/WIRE-FORMAT.md` §2 reserved id 0 for and what `RESYNC` already used it for.

### D-8 — one bad channel is one bad channel

Measured writing step 3: a policy whose request type is `any` reaches `CommandPayload` as an error
type, `channelView` raises on it, and `ServerView`/`ClientView` — one type function over the whole
declaration — take every sibling's view down with it. The diagnostic the user needs is at the
channel's own line and already fires; the second one, at the namespace, removes the types of the
channels that were right, and the reader is left looking for a fault in code that has none. The view
functions are taught to give a channel whose type is not a channel `unknown` on its own key and
continue, keeping the raise for the case where the namespace line is the only diagnostic (a schema
or a function where a channel should be). Which of those two an error type arrives as is measured
first in `spike/declare/`, because the type API's `is` may not name it.

**Measured 2026-09-11, and the view functions are not where this can be done.** With one channel's
`CommandPayload` carrying an error type, the diagnostic at the namespace line is "Type functions do
not currently support types of the form 'ServerView<{ …CommandPayload<…*error-type*…> }>'" and the
views are reported as *not having* keys `a` and `b` at all: the runtime refuses to reduce `ServerView`
when its argument contains an error type, so the body never runs and there is nothing for it to give
`unknown` to. The lever is upstream — the argument must not carry an error type — which makes D-8 the
same work as item 43 in phase 3: a `Policy<T>` whose composition does not produce one.

**Closed with item 43, and not the way D-8 was written.** Re-measured on the intersection: a channel
whose only policy takes `any` is clean now, where it used to take the namespace down, so the
accidental cause is gone — an agnostic policy composes without `any` at all. What remains is a
malformed declaration: no `rate`, a `data` that is not a schema, or `any` still composed through
`nw.all`. Each reports five times at its own line, correctly, and twice or three times at the
namespace line, where the message is that the views lack the keys of the channels that were fine.
The mappers still cannot localise it — `ServerView` is one type function over the whole table, and an
`error()` inside a channel's payload function leaves `CommandPayload<…>` unreduced, so the
application is stuck and the body never runs. Returning `unknown` instead of erroring would unstick
it and trade away the analysis-time half of G2 and G3, which is not a trade this milestone makes. So
what ships is the reading: the channel named inside the `ServerView<…>` type is the one to fix, and
`DESIGN-API` §7 says so under a heading of its own.

## 6. Tasks

Numbered by subject. **Run in this order**, decided at opening (2026-09-11), smallest blast radius
and highest user-facing value first, the type layer's callable rewrite last because it touches every
payload type function at once:

1. phase 9's correction of step 1 and the README on the old solver — a false sentence, not a feature
2. phase 8, the `ServerScriptService` refusal — one `error(` and a Studio case, mistake 1 on the list
3. phase 7, the yield report and `nw.keep` — the generation compare exists, this is one integer
4. phase 8, the per-namespace digest — a control kind, the fuzzer and `protocol_runtime`
5. phase 7, the server stage (D-5) — the seam becomes the library's
6. phase 3 item 43 and D-8 — `Policy<T>` composition and one bad channel staying one
7. phase 7, client-side pacing (D-6) — last of the lifecycle work, because it changes what `send` does
8. phases 2, 4, 5, 6 — types for public values, the optimisation residue with probes, additions, tooling
9. phase 1 — the callable shape
10. phase 9's remaining documents, re-ranked as each mechanism lands rather than at the end

### Phase 1 — the callable shape
- [x] `Ranged<T>`, `Text`, `Componented<T>`, `Classed` as `Type<T> & ((…) -> Type<T>)`
- [x] `PayloadOf`, `StructPayload`, `UnionPayload`, `MapPayload`, `OptionalPayload`, `ArrayPayload` look through an intersection
      — one private `carrierOf` type function, called by all six. A type function may call another in
      its own module (measured), so the six do not each need a copy; and a private one still reduces
      across a `require` as long as the module references the exported caller (Q5's rule, re-measured).
      `StructPayload` and `UnionPayload` needed the call placed *before* their `is("table")` guard, not
      after — with it after, every `t.u8` in a struct was "not a netweave type": 1,352 diagnostics
- [x] every `readproperty` site in `Trust`, `Channel`, `View` does the same — `Channel.payloadOf` and
      `Trust.TrustedPayload` carry their own copy of the walk, because a type function cannot reference
      an outer local and calling one across a `require` needs it exported, which would put a helper on
      the public surface. `View`'s five sites read a *channel* record built by `Channel`'s own type
      functions, never a schema, so they need nothing
- [x] `types_reject` gains a case per constructor for a wrong-typed argument (18-24, count 17 → 24),
      each with its accepted twin in `types_ok`; Q5 re-run — `spike/declare`'s five files still report
      3, 3, 4, 5, 4, and `api_reject` still 24, which is what would drop if a mapper became `any`.
      One gap measured and not closed: `t.unitVector3(t.string)` produces nothing, because the argument
      is itself an intersection and Luau's subtyping of one against `Type<number>` lets it through —
      `t.vector3(t.boolean)`, a plain table type, is refused. The runtime refuses both
- [x] the fifth `nw.Views` spelling, measured writing the tutorial (2026-09-10): passing a namespace
      *bare* to a parameter typed `nw.Views<typeof(ns.channels)>` or `typeof(ns)` turns the payloads of
      the handlers already written on that namespace into `unknown`, retroactively; the cast at the call
      keeps them. `tests/tutorial_ok.luau` carries the cast with the measurement beside it. ~~Pin the bare
      call in `api_reject` as a canary the way the annotated-local spelling is, or find the instantiation
      that loses the brand and fix it in `View`~~ — **neither, and both were tried.** The reproduction is
      `spike/declare/passed.luau` (Q6), where the cast gives the two intended diagnostics and the bare
      call gives four. It is not a lost brand and not the self-reference in the parameter's type: typing
      the parameter by the channel table's own local, so the namespace is not named in it at all, changes
      nothing, and a five-channel namespace with four handlers does not reproduce it while a nine-channel
      one with a handler doing arithmetic on a payload does. So there is nothing in `View` to fix. And it
      cannot be a canary: the shape *adds* two diagnostics while removing others, so `api_reject` would
      have to declare a count that moves with the solver rather than with netweave. The guard is the cast,
      recorded in `DESIGN-API` §7 beside the other `Views` caution, and `api_ok`'s own bare call now says
      it is safe only because that namespace has one channel
- [x] `ctx.player` in a handler is `unknown` (`docs/DESIGN-API.md` §8), and the trade example casts it in
      every handler that publishes. ~~Measure once, in `spike/declare/`, whether a class type given at the
      `nw.Views` cast can be threaded to the handler's `ctx` by the view type function~~ — it does not have
      to come from the cast, and no spike was needed: a type function's **arguments** are types, so
      `Views<D>` instantiates `ServerView`/`ClientView` with `Context.Ctx` and the shape arrives with its
      real classes. The route was already in the codebase unnoticed — `nw.policy`'s own signature is how
      `{ player: Player, character: Model? }` reaches `Channel`'s type functions, which is what the
      earlier phase-1 diagnostics printed. A handler's `ctx` is `nw.Ctx` now: `ctx.player.UserId` type
      checks, `ctx.character` narrows from `Model?`, `ctx.playr` is still a typo the analyser catches, and
      every `ctx.player :: Player` in the tutorial, the worked example, `mistakes.md`, `trade_ok` and
      `tutorial_ok` is gone. `api_ok` pins the fields and the whole-`ctx` annotation; §8's "the one field
      that is `unknown`" section is struck and rewritten

### Phase 2 — a type for every public value
- [x] re-export `Policy<T>`, `Check<T>`, `Snapshot`, `Described`, `Rules`, `Limits`, `Audience<S>`, `Observer`
      — and `Factory<T>` and `Store`, because `nw.policy` takes the one and every `nw.store.*` returns the
      other, and both were value families with no name
- [x] `tools/exports` demands a type per public value family: a `FAMILIES` table maps each top-level value
      on `nw` to the type that names it, an `UNTYPED` table names the rest with the reason (modules, two
      strings, the private seam, and the seven channel constructors — a record's type is five internal
      parameters and the name a game writes is `nw.Views<typeof(ns.channels)>`), and both are tested
      against `src/netweave.luau` in both directions. Confirmed to bite three ways: a value in neither
      list, a family naming a type not exported, an entry naming a value that is gone
- [x] `api_ok` writes each, in an annotation position: 39 public types covered, 0 gaps, 8 families

### Phase 3 — the M4 report's type-layer residue
- [x] items 5, 6, 7, 42, 43, 45, 46, 47, 48, 50 of `docs/SECURITY-REPORT-M4.md`, each its own commit —
      nine closed, 46 in part with the reason for the rest written down
  - [x] 5 — `nw.validate` returns a schema-shaped copy; the brand-laundering half stays open with its
        measurement (`Unbranded<V>` costs "Code is too complex to typecheck")
  - [x] 6 — every field of `Channel<…>` is `read` and the declaration table is a frozen copy; the
        per-record freeze is not done, and the ordering hazard that decided it is written down
  - [x] 7 — a weak set of what `src/types` built, asked by `isType`, `Channel.requireType` and
        `nw.validate`; a clone of a real descriptor is refused, which a sentinel field would admit
  - [x] 43 — `Policy<T>` as an intersection (above)
  - [x] 45 — each class passes the keys it takes and `permit` walks the declaration: a key of another
        class keeps that class's reason, anything else is a spelling with the list beside it, and
        `burst`/`maxBytes`/`timeout`/`unreliable` are checked by type. The M4 probe's twenty-two
        declarations produced one diagnostic; they produce fifteen. `forbid` is gone, its reasons moved
  - [x] 42 — a patch layout is `counted`, whatever its size; the all-flag struct that reported `static`
        is the case `delta_runtime` pins
  - [x] 47 — `ENCODING_SIZE`, the three number-writer families, `STORAGE_CODE` and `Row.storage` keyed
        by `Encoding`, so a ninth encoding missing from one of them is a diagnostic
  - [x] 48 — one `Stage`, in `Config` where the rules are named, re-exported by `Observer`; `Sink`
        carries it and `Inbound`'s cast is gone. `config_runtime` asserts every member is a rule and
        names `rateUnbounded` as the one rule that is not a stage
  - [x] 46, in part — `Tick.Config` names `Outbound.Outbound` and `Baseline.Baseline` where it said
        `any`, and `Baseline` names what it needs a channel to be (`{ qualified: string }`, the field
        `keep` dereferences when the limit refuses). The `store.changed` and `Store.charm(subscribe)`
        halves of the finding are stale — both were removed in M4. **`channel: any` across the transport
        is not done**, and the reason is measured rather than assumed: `Batch`, `Inbound`, `Outbound`,
        `Budget`, `Query` and `Recipients` each read a different handful of a channel's fields, and six
        test rigs build partial channel tables with exactly the fields their section needs. A full
        `Channel` record at the boundary makes every one of those a cast; a per-module structural type
        is the shape that would not, and it is a module-by-module job rather than one commit. Carried
        with that note rather than closed by omission
  - [x] 50 — the sidecar is `{ unknown }` from `Buffer.beginRead` outward, so `Serdes.isInstance` is
        the narrowing rather than a contradiction of the signature. Four suites take it back through a
        `takeAsWire` helper that names the loopback, and the fuzzer's mutators say `{ unknown }` too —
        which is what they were always building
- [x] for 43, the measurement from the tutorial (2026-09-11): a payload-agnostic policy cannot be composed
      onto two payloads through `nw.all` in any spelling — `Policy<Equip>` is not `Policy<Offer>`,
      unannotated and `unknown` mismatch the same way, `any` reaches `CommandPayload` as `*error-type*`
      and drops the namespace's views, and `read __nwCheck` on the `Policy<T>` field changes nothing
      (tried and reverted: 71 diagnostics elsewhere). The schema-witness helper in `tests/tutorial_ok.luau`
      is the working spelling and the tutorial teaches it; the fix is a `Policy<T>` that is contravariant in
      `T`, or an `nw.all` whose `T` is taken from the channel rather than from its arguments. A second
      measurement from the same session, ten spellings: a policy whose check names its request through a
      `t.PayloadOf` alias composes through `nw.all` only as a bare local with a parameterless factory and an
      `if` expression; as a field of a `local policy = {}`, as a configured factory, or with the
      `and … or` idiom, one side is inferred `Policy<unknown>` and the pair is refused. Hand-written request
      types compose in every shape. The tutorial writes policy request types by hand until this closes, and
      says so in step 3; the alias is the spelling the fix has to make work, because it is the one that
      cannot drift from the schema. **Third measurement, at opening**: `read __nwCheck` and
      `read __nwStages` on the record analyse clean across the tree (the earlier 71 were the scratch
      file's own) and change nothing about composition — `nw.all(unk, onlyB)` and the configured-factory
      pair still read "expected Policy, got Policy … not exactly", because a `typeof(setmetatable(…))`
      type is compared exactly through its `__call` return and variance never enters. So 43 is not a
      field-modifier fix; it is the callable shape, which is phase 1's D-1 (`Base & ((config) -> …)`),
      and it runs after phase 1 rather than before it. Run order item 6 is therefore behind item 9.
      **Closed, and phase 1's D-1 was the whole of it.** `Policy<T>` is
      `Configured<T> & ((config: any) -> Configured<T>)`: two aliases rather than one recursive
      intersection, because writing the call's return as `Policy<T>` takes `Channel`'s type functions
      down with `type functions do not currently support types of the form '*error-type*'` — measured.
      A reconfigured policy is a `Configured<T>`, which is what `all`, `stagesOf` and `checkOf` take, so
      a bare and a configured policy compose alike. Re-measured at the ten spellings the tutorial was
      written against: zero diagnostics, the `t.PayloadOf` alias included. The one spelling still to
      avoid is `any` as the request type — eleven diagnostics on a single channel, because it reaches
      the class type function as `*error-type*`, which is Luau's behaviour and not netweave's. `unknown`
      is the word a payload-agnostic check wants anyway. The schema-witness helper is gone from
      `tutorial_ok`, `trade_ok`, step 3, step 7, `example-trade.md`, `mistakes.md` 4 and the vocabulary
      card, and every policy request type in the tutorial is a `t.PayloadOf` alias now

### Phase 4 — optimisation residue
- [x] items 73, 74, 76, 77 and the three M4-1 미미 optimisation findings, each with its probe. The
      probes are rungs of `bench/residue`, which prints every rung and then refuses to pass while any
      still shows what its finding described, so it is a check-script step from the first rung on.
      Seven commits, `d98e91d` … `251b1c5`, each BEFORE measured on its parent.
  - [x] 73 — `commit` hoisted out of `Delta.write`, `flagsAt` an upvalue. BEFORE on `bea4631`:
        112 B a call on both paths [67–112, n = 45 of 64 windows]; AFTER: 0 in all 64.
  - [x] 74 — the oversize-claim reason no longer quotes the claim; one string per ceiling, built
        on first refusal. BEFORE on `d98e91d`: 500 claims over 50 lengths → 50 distinct reasons;
        AFTER: 1. `PLAN-M3` phase 9's "all four" corrected in place.
  - [x] 76 — `Buffer.take` empties the buffer instead of replacing it, so a parked record keeps
        the size it grew to; unreliable packets get a record of their own instead of `load(nil)`.
        BEFORE on `0ee4327`: 64 → 2048 → 64 across one 1.5 KB frame, the next frame a new object,
        5,696 B a frame [3,008–5,760, n = 56], 768 B an unreliable 200 B packet; AFTER: 64 → 2048 →
        2048, the same object, 1,600 and 256 — the exact copy and the sidecar table. The flush
        comment that said the record kept its buffer now describes what happens.
  - [x] 77 — `Namespace.replicated` is one frozen list built at seal; `within` is handed the
        frame's players and the Roblox roster no longer calls `GetPlayers()` per subject;
        `Recipients.of` trims the scratch past `count`; a broadcast reads the roster in place
        instead of copying it per subject. BEFORE on `f15828a`: two asks two tables, `within`
        handed no list, 50 entries left after an audience of 1; AFTER: one table, handed to all
        100, 1 left. `roblox_runtime` asserts `within` reads the list it is given, not the engine.
  - [x] M4-1 minors, the two refusal strings — `Budget.admit`'s sentence is one per rate, built on
        the first refusal; the instance reader's two are built with the closure. Time only, since
        Luau interns short strings (and a long one is collected inside a `gcinfo` window, measured —
        the heap instrument reads zero for both). ~~BEFORE on `78689c7` a refusal at 2.8x an admission
        (186 against 67 ns) and 1.4x (159 against 111); AFTER 1.3x (84) and 1.1x (125).~~ Those two
        columns were timed in separate passes and read from the median, and the instance ratio moved
        1.1 → 1.5 between two runs with a Studio pass in between, failing its own assertion. The rung
        races the two paths in one alternating pass and takes the fastest, per `bench/tick`'s reason:
        BEFORE, reverted in place on `6aeff0e`, 2.84–2.87x and 1.40–1.52x over three runs each, both
        red; AFTER 1.19–1.25x and 1.09–1.11x, ceilings 2.0 and 1.3.
  - [x] M4-1 minor, the free list — `Inbound.pooled()` counts it, since lune cannot force a
        collection; the pool keeps at most 8 lists on the way back in. BEFORE on `5214fd1`: 64
        walks parked inside a yielding handler, 64 lists pooled after; AFTER: 8.
- [x] the reader: `bench/decode` in Studio at `249ca27` prices netweave's client decode at 2.81x the
      generated-code ceiling (35,073 against 12,476 ns a packet) ~~and there is no fused struct reader to
      match the writer~~ — **there is, and it is taken**: instrumented at build time, six rows and six
      bytes, for the `ArrayHeavy` element and for the struct alone. Re-priced under lune on `1c021e5`,
      three runs: 20,936–21,413 ns a packet, 3.33x the bare ceiling and 2.21x the ceiling that checks
      what it reads, 1.23x the `dispatched` rung — so what is left is the array's length handling and
      one `table.clone(template)` per element, not the per-value dispatch. The encode side is 6.54x and
      3.25x on the same instrument, so the writer is the further of the two from its ceiling, which is
      the opposite of what this item assumed. `bench/RESULTS.md`, "The reader, priced"
  - [ ] the Down cell re-run on `0cb731d` beside the current tree in one session, to find which of its
        four readings is the outlier (`bench/RESULTS.md`, "The Down cell") — **left open on purpose**: it
        needs the bench place built from a worktree at `0cb731d`, that matrix run, then the current
        tree's in the same session, about twenty minutes of Studio for a question about the instrument
        rather than about netweave. Nothing in the library waits on it, and the owner declined the
        comparable multi-client runs on 2026-09-19

### Phase 5 — additions
- [x] `t.string` `{ charset = … }`, linear by construction: stored as the pattern `[set]*`, so the
      reader, the writer and the signature carry one attribute and a peer that wrote the pattern agrees;
      refused beside `pattern`, when empty, when a `]` closes it early, or when it ends in a lone `%`.
      `types_ok`/`types_reject` (12), `types_runtime`, `serdes_runtime`, tutorial step 8.
- [x] recipient-set caching per tick, measured on `bench/tick`'s `select-all` and a `nearby` rung. The
      first number from real remotes (`live/`, 2026-09-19, two players): 200 subjects published twice a
      frame under `nearby(50)` cost 0.39 ms a frame with no players and 1.80–1.95 ms with two, at ~230
      server frames a second uncapped. That is 4.5 µs a publish with two distance checks and one or two
      encodes in it; `nearby` walks every player per subject, so the distance half grows with players ×
      subjects and the encode half with recipients. Two points do not give a slope, ~~and the `BEFORE` for
      this task is a live run at 4 and 8 players before the cache lands~~. The owner declined the 4- and
      8-player runs (2026-09-19), so the `BEFORE` is two probes instead, both on `d982242`: `bench/tick`
      under lune with the rig answering `has` (`select-all` 3.43–3.47 ms, the new `nearby-all` 2.37–2.38),
      and `roblox_runtime` in Studio with one player, timing `within` and a roster-returning `select` over
      the frame's list (693 and 355 ns a subject). What landed: `Recipients.of` answers membership from a
      set built once per distinct list, and the Roblox roster reads every player's position once per list
      rather than once per subject. AFTER: lune 3.16–3.24 and 2.17–2.25 (−7%, the function call per pair);
      Studio 364 and 140 ns a subject (−47% and −61%, the engine calls per pair). Per player: the tick
      pays P position reads a frame instead of S × P × 3, and S × P lookups instead of S × P `has`.
- [x] the delta crossover `PLAN-M4` acceptance 8 asked for and never measured: ~~a replication mode in the
      matrix, and~~ the subject size below which a diff loses to a resend written into `bench/RESULTS.md`.
      Not a matrix mode: the question is bytes and both sides are netweave, so `bench/crossover` writes
      both shapes with `Batch` itself under lune, exactly and without a spread, and asserts the shape of the
      answer. The diff loses for a one-field subject (by two bytes) and when every field moved (by its
      flags and length prefix, two to six bytes); level at two fields; wins from three; zero bytes when
      nothing moved, which the resend cannot say. `bench/RESULTS.md`, "The delta crossover, in bytes"
- [x] the nice-to-have types, each with an `_ok`/`_reject` pair
  - [x] `t.literal(value)` — zero bits, zero bytes, in the hash with its type; a bounded generic
        (`V & (string | boolean | number)`) keeps the string and boolean singletons where a bare one
        widened `"v3"` to `string` (`spike/additions`). `t.set(element)` — a map to the literal `true`,
        seven bytes where the map of booleans is nine. `t.optional(inner, default)` — the payload
        without its nil, the default read for a clear bit and never written, one value with absent
        to the differ, in the hash with its type; an absent second argument reaches the type function
        as `unknown`, measured. `types_ok`, `types_reject` (17), `types_runtime`, `serdes_runtime`,
        `delta_runtime`, `protocol_runtime`, WIRE-FORMAT §5, tutorial step 8.
  - [x] compact `t.cframe` — `t.cframe(component)`, the position as three of the component and the
        rotation as a quaternion with its largest component dropped: three `i16` and a two-bit index
        where an enum's tag goes. 13 bytes for a narrowed position against the bare 24, 19 with an
        `f32` one. `CFrame` is Roblox's, so the arithmetic is verified separately under lune
        (`spike/additions/f_quaternion.luau`, five runs of 200,000 rotations: angle error 6.1e-5 to
        6.4e-5 rad), and that run corrected the reader — the three kept squares sum to at most **3/4**,
        not 1, because the dropped component is the largest. `types_ok`, `types_runtime`, `ir_runtime`,
        `protocol_runtime`; the wire half is `roblox_runtime`, and the Studio pass ran green on
        `6aeff0e` — 20 of 20 files, the compact cframe at 13 bytes for a narrowed position and 19 for a
        float one, a quarter and a wide turn about each axis, the packing just over 3/4 refused and the
        one exactly on it accepted. The `within` numbers reproduced in the same run: 346 and 142 ns a
        subject against 364 and 140.

### Phase 6 — the tooling
- [x] selene block allows replace the global list in `netweave.toml`: `-- selene: allow(undefined_variable)`
      on the line before each of the thirty `type function`s, measured at the pinned 0.29.0 to cover that
      body and nothing else — an undefined global outside it in the same file is still an error, and
      dropping one allow puts six `types` errors back. `netweave.toml` is empty but for the base, and says why
- [x] `bench/` top-level scripts, `tools/*.luau` and `analyze.luau` itself under `analyze`: 68 files clean,
      up from 57. The 22 real diagnostics were ten `table.create` arrays, `Buffer.take()`'s second return
      reaching `buffer.len`, `luau.compile` through `pcall`, an `os.date` overload on an `any`, a
      `string.find` pair not narrowed together, and `bench/tick`'s per-rung audience reaching `OutboundScope`
      as `any` (the constructor is cast now, since the view is never used there). The `@lune/*` requires
      resolve through the alias `lune setup` writes into `.luaurc`, committed and documented in
      `tools/README.md`; `analyze.luau` had to stop spelling its own markers out in a comment, because it
      reads itself now

### Phase 7 — the lifecycle, folded
- [x] `Factory<T>` may return a second function; `callable` keeps it as ~~`__nwServer`~~ `__nwStages`, a
      list, so `all` can carry its members' and `Namespace.runStages` can dedupe by function; the command
      and query records carry `stages = Policy.stagesOf(authorize)`. A second return that is not a function
      is refused at `nw.policy` with the message saying what the stage is. One thing measured on the way:
      `Factory<T>` typed `-> (Check<T>, Stage?)` refused every factory that returns the check alone (35
      diagnostics), because a pack of one is not a subtype of a pack of two; it is `-> (Check<T>, ...Stage?)`
- [x] ~~`Namespace.seal()` runs every registered stage~~ `Namespace.runStages()` does, once per distinct
      function, and `Driver.ensure` calls it on the server after the seal *and* whenever it finds the
      protocol already sealed — because `nw.protocol()` seals too, from a game printing its hash before its
      first packet, and a seal that ran there must not leave the stages unrun; the second call is one
      boolean. A stage that raises fails with the channel named, once (marked ran before running, so a
      startup error is loud rather than repeated per batch)
- [x] the stage runs on a coroutine of its own, so a yield is seen and refused as the same startup error
      rather than parked on; `api_runtime` has the raise, the yield, the once-for-two-channels count, the
      reset re-running it, and the check reading what the stage filled; `roblox_runtime`'s Driver section
      counts the stage running once at the first send's seal, on the server
- [x] `Policy.luau`'s docstring stops saying "resolve services" in the factory and shows the stage; step 3's
      seam became the stage, with the seam kept on the page (and in `tutorial_ok`) as the spelling for a
      library older than this milestone; `DESIGN-API.md` §5 records it beside the Flamework citation
- [x] `Context.generation(player)` exposed to the transport; `Inbound` reads it before
      `xpcall(handler)` and `xpcall(authorize)` and compares after, and a moved generation reports at
      `handler` / `authorize` with a reason naming ~~`nw.keep`~~ the field copy and `query`. One compare
      per call and one constant string; `hostile_runtime`'s flood probe is unchanged at 214 assertions
- [x] the report is confirmed to fail against the pre-fix tree: a `coroutine.yield` handler (lune has no
      `task.wait` in a module) and a second packet of the same player in `transport_runtime`, guard off —
      with the two compares replaced by `false` the section reads "expected 1, got 0"; with them it also
      shows the corruption itself, the resumed handler's `ctx.channel` being the *later* packet's channel
- [x] ~~`nw.keep(ctx)`~~ **not added.** The count: zero places in `tests/trade_ok.luau`, `tests/tutorial_ok.luau`
      or the suite keep more than one field of a `ctx` past a yield; every one copies `ctx.player`
      alone. A name for a table nobody has needed is a name that will be reached for instead of the
      copy, and the copy is one line. The report's reason spells the copy. Reopen if a second field is
      ever kept
- [x] the client's `send` on an intent holds the newest value per channel and pushes it at the declared
      rate through a client-side `Budget` keyed by channel — `src/transport/Pacer.luau`, lune-loadable, so
      `transport_runtime` drives it with an injected clock; `Driver.send` routes intents through it and
      `Driver`'s frame ticks it before the flush; a held value is superseded, never dropped, never
      reported; `nw.diagnostics()` gains `paced` per channel
- [x] the probe, ~~on `bench/tick`~~ as `bench/pace.luau`, because the pacer is a client-side object and
      `bench/tick` prices the server's replication tick: both rungs in one run under an injected clock,
      BEFORE being the parent tree's behaviour reproduced (every send pushed as it comes) and AFTER the
      pacer, each feeding a server-side `Budget.admit`; the numbers are in the commit and in §Result

### Phase 8 — the declaration that cannot work
- [x] ~~`Namespace.declare` reads `debug.info(2, "s")`~~ `nw.namespace` reads it — level 2 from there is
      the game's module, from `declare` it would be `nw.namespace` — and hands it to `Namespace.declare`
      as a third argument, which refuses a source under `ServerScriptService` or `ServerStorage` with the
      fix in the message and does nothing for any other shape. The lune half (`api_runtime`) hands the
      source in and was confirmed to fail on the pre-fix tree, four assertions; the Studio half
      (`roblox_runtime`) requires `tests/serveronly/declares.luau` through the second mapping both place
      files give it under `ServerScriptService` and measured the real `debug.info` value to be
      `ServerScriptService.netweaveServerOnly.declares`, refused with `ReplicatedStorage` in the message,
      while every namespace the suite declares from `ReplicatedStorage` is not. `messages` counts the
      `error(`: 75 now
- [x] control kind 3 in `Batch`, the per-namespace digest, written beside *every* hello — the client's
      first packet as well as the server's answer, so both consoles can name it — and read by
      ~~`Protocol.disagree`~~ `Protocol.difference` through `agreement.digest`, which rewrites a refused
      peer's reason once. `Batch.read` hands the body over undecoded and `Batch.readDigest` is called only
      when `agreement.wants` says the peer is refused and unnamed. `docs/WIRE-FORMAT.md` §4 has the layout
      and the two bounds (1,024 namespaces, 255-byte names)
- [x] `protocol_runtime`: a namespace only one side declares, said from either side, and a channel
      differing inside a shared namespace — named in the reason on both; the digest round-trips beside a
      hello with the packet behind it decoding; a body past the bound is refused, not decoded. Three
      hundred digests from a refused peer are one named report and no parse reports; from an agreeing peer,
      nothing at all (`hostile_runtime`)
- [x] the fuzzer's corpus gains kind 3 with a mutated body, and the receive path never raises on it. The
      fuzzer found two silences on the way: a digest from a peer the endpoint had not refused was stepped
      over without a word (counted now, through `wants`, the way a hello is counted through `hash`), and on
      an endpoint with no agreement the kind was accepted and dropped — it is absent from that sink now, so
      `Batch` reports it as a kind this build does not read, which there it is

### Phase 9 — the documents the above move
- [x] the vocabulary card's `intent` row says "send at the declared rate" now, and says the client paces
      once phase 7 lands — the row changes in the same commit as `Driver`
- [x] `docs/tutorial/mistakes.md` re-ranked in place as each mechanism lands: ~~1 moves to the immediate
      section after phase 8~~; 2, 3, 5 and 8 are struck through with the phase-7 commit beside them, the
      way `CLAUDE.md` §3 corrects a plan, so the page keeps saying what used to go wrong and why it no
      longer does. 1 is *listed* in §10 and stays where it is: renumbering ten entries loses the reason
      the list was ranked that way, and five of the ten changed. So the correction is at the top and at
      the bottom — the order is M4's, read by silence today the top three are 7, 6 and 9, and the closing
      paragraph's "the frightening one is the first on this page" is struck with what replaced it
- [x] step 3 gains the prototyping pattern from the non-goal: a `todo(schema)` helper, one allow, and the
      sentence that a reviewer greps for it; `tests/tutorial_ok.luau` carries it
- [x] `docs/DESIGN-API.md` §8 records the stage, `nw.keep` and the yield report beside the shared-record
      decision they are the cost of — as a three-row ledger, with the note that the yield report is the
      one place in netweave where a report was chosen over a refusal, and why
- [x] **Done first, at opening** (step 1, both READMEs, `DESIGN-API.md` §0; re-measured with the exact
      flags `analyze` passes: 390 errors in `src/` alone, 435 with `tests/*_ok.luau`, 13 in `tutorial_ok`,
      76 in `api_reject`, the two messages as below). Step 1's sentence about the solver being off — "every
      declaration still runs, but the lines marked 'does not type-check' will type-check" — is wrong in
      direction, measured 2026-09-11 with luau-lsp
      1.69.0 and `--flag:LuauSolverV2=false` over `src/` and `tests/*_ok.luau`: the old solver does not
      parse `type function` or `read` properties, and the library folder reports **573** errors (`read
      keyword is illegal here`, `This syntax is not supported`; 182 in `types/init.luau`, 130 in
      `api/Channel.luau`), a user's own declaration file gets a handful of knock-on errors (13 in
      `tutorial_ok`, 4 in `trade_ok`: `Unknown type 't.PayloadOf'`, `Expected 'Type<a>', got 'Ranged'`,
      `Key 'rules' not found in table 'Snapshot'`), and not one guarantee diagnostic appears —
      `api_reject` produces 76 errors, none from a type function, against its 24. The owner saw the same
      two messages in the Studio editor with the setting off. So the first thing an old-solver user sees
      is a red library folder, not a quiet pass; step 1 says that, with the count and the two messages so
      the reader recognises them, and `DESIGN-API.md` §0's "analysis errors inside code they did not write"
      gets the number beside it. The measurement itself: new solver 2.29 s / 187 MB peak / 0 errors over
      the same 33 files, old solver 2.59 s / 183 MB / 573 — the cost of the solver is not performance,
      and the tutorial should not imply it might be

## 7. Acceptance criteria

1. `t.u8(0, "b")`, `t.string(0, 5, { utf8 = 1 })`, `t.vector3(t.boolean)`, `t.cframe(t.boolean)`, `t.instance(5)` each produce a diagnostic, and `types_reject` marks the line and the text. (`t.cframe` became `Componented` in phase 5. ~~Its bad-component case is measured to produce nothing today for the same reason as the vector's.~~ That was measured *before* phase 1: an intersection checks the argument's type, so both produce a diagnostic and `types_reject` marks both.)
2. `local policy: nw.Policy<Equip>`, `local snapshot: nw.Snapshot`, `local observer: nw.Observer` analyse in an `_ok` file with a negative control each.
3. `tools/exports` fails when a public value family gains a member with no nameable type.
4. `nw.validate` returns a table the caller did not pass in; ~~a channel record raises on write after seal~~ **every field of a channel's type is `read`, so the write needs a cast, and the declaration table is a frozen copy**; `nw.command({ store = {} })` is refused at declaration. The runtime freeze of each record is not done and the reason is measured rather than asserted: `handler` is written after declaration by `:listen` and sealing is triggered by the first packet, so freezing at seal would raise on a legal sequence, and moving the handler to a side table costs a lookup on the per-packet dispatch path plus 94 assignments across six test rigs. `src/api/Channel.luau` carries the note beside the type.
5. Each phase-4 probe's `BEFORE` reproduces on the parent tree within the session drift `bench/tick` records, and the after is lower.
6. `analyze` walks `bench/*.luau` and `tools/*.luau` and is clean.
7. A policy whose server stage requires a `ServerStorage` module: the shared file in `tests/trade_ok.luau` analyses, the Studio suite requires it on the puppet client without raising, and on the server the stage has run before the first `authorize` — counted by the stage, not inferred. Under lune a stage attached to two channels runs once.
8. A `command` handler that `task.wait()`s while a second packet of the same player is dispatched produces exactly one report at stage `handler` in `transport_runtime` with the Studio guard off, and the case fails on the pre-fix tree. The flood probe's distinct-reason count does not move.
9. `bench/tick`: 60 intent sends a second against `rate = 30` — `budget` refusals 0, packets on the wire at most 30 a second, the handler sees the newest value each tick; `BEFORE` on the parent tree shows the 30 refusals.
10. A namespace declared from a module under `ServerScriptService` raises at that line in Studio with `ReplicatedStorage` in the message, and one from `ReplicatedStorage` does not; `roblox_runtime` carries both.
11. Two peers that differ by one namespace: the `protocol` reason names it, on both peers, in `protocol_runtime`.
12. ~~A namespace of three channels, one declared with a `Policy<any>`: `api_reject` counts that channel's diagnostic at its own line and `api_ok` keeps the other two handlers' payloads typed.~~ **Not met, and the shape it describes no longer exists.** Measured on the intersection: a channel whose *only* policy takes `any` produces **no** diagnostic at all now and its siblings are untouched, so there is nothing for `api_reject` to count; composed through `nw.all`, `any` still reaches the class type function as an error type and takes the siblings' views with it — thirteen diagnostics beside two healthy channels, three of them the healthy ones'. D-8 closed on the finding that the view mappers cannot localise that, and phase 3 item 43 removed the reason a game would write `any` in the first place. `mistakes.md` 4 and `DESIGN-API` §7 carry what is left.

## 8. Risks

- **The intersection breaks `t.u8` where a `Type<number>` is expected**, which is the spike's original
  reason for the flat duplicate (`src/types/init.luau`, the `Descriptor`/`Type<T>` note). Mitigation:
  phase 1 starts from `spike/declare/`, and `types_ok`'s scalar block is the first thing run.
- **Re-exporting internal types freezes their shape.** Mitigation: only the eight the report names, and
  `Snapshot`/`Described` as read-only tables.
- **An optimisation lands without its probe because the probe is hard to write.** Mitigation: D-4 —
  it does not land.
- **The server stage changes what a factory's second return means.** A factory that already returns
  two values by accident — a trailing `, nil` — is harmless; one that returns a function it did not
  mean as a stage would run it at seal. Mitigation: the second return is the docstring's example, a
  non-function second return is refused at `nw.policy` with a message `tools/messages` checks, and
  every factory in the suite is grepped for a second return before the change lands.
- **Client-side pacing changes what an intent `send` observably does**, and a test that counted intent
  packets on the wire will move. Mitigation: D-6 — the class already promised newest-per-tick, the
  phase-7 probe is the number, and `transport_runtime`'s intent sections are re-read for packet counts
  before `Driver` changes.
- **`debug.info(2, "s")` is a heuristic about script names.** A bundler or a `loadstring` wrapper
  gives a source that matches neither prefix. Mitigation: a non-match does nothing, so the worst case
  is today's behaviour; only the two prefixes are checked; both directions are measured in Studio
  before the message is written.
- **A yield detector that fires on an honest handler.** A handler that yields while no other packet of
  that player arrives is neither detected nor harmed; one that is detected has, by construction, held
  a `ctx` that was refreshed under it. Mitigation: the report sits under the observer's own repeat
  suppression, and `hostile_runtime` gains a section proving a flood cannot make the detector allocate.
- **Folding the lifecycle hides the cost the shared record was chosen to make visible.** `nw.keep`
  allocates, the stage runs game code at seal, the client bucket is state per intent channel.
  Mitigation: each is an allocation the game asks for by name or a table sized by the declaration, and
  the hot-path criterion (`PLAN-M1` acceptance 7) is re-run on the flood probe after phase 7 the way
  phase 4 re-runs its `BEFORE`.

## 9. Result

Closed 2026-09-24 on `develop`. Every task is ticked except one, left open on purpose and named
below. The lune half is 28 green steps through `scripts/check.ps1`, run on every commit of the
milestone with the pre-commit hook refusing the rest; the Studio half ran green on the closing tree —
**19 runtime modules, 0 console errors**, which is the pass `CLAUDE.md` §9 asks for before a milestone
is called green. (`6aeff0e`'s pass was recorded as "20 of 20" above and that was a miscount: there are
eighteen lune modules and `roblox_runtime`.)

### What shipped

| Phase | What is true now that was not |
|---|---|
| 1 | A constructor's arguments are checked by **type**: `t.u8(0, "b")`, `t.vector3(t.boolean)`, `t.cframe(t.boolean)`, `t.instance(5)` are diagnostics where only the argument *count* was enforced. One private `carrierOf` per module looks through the intersection; `types_reject` went 11 → 24 |
| 1 | A handler's `ctx` is `nw.Ctx`. `ctx.player.UserId` type-checks, and every `ctx.player :: Player` is gone from the tutorial, the worked example and the tests — a type function cannot *name* a Roblox class but can be *handed* one |
| 2 | Every public value family has a nameable type through `nw`, and `tools/exports` fails when one gains a member without one |
| 3 | `nw.validate` returns a schema-shaped copy; a channel's fields are `read` and its declaration table a frozen copy; a descriptor is branded by construction; a misspelt spec key is refused with the class's key list beside it; `Policy<T>` composes across payloads; one `Stage`; the sidecar is `{ unknown }` where it is wire data |
| 4 | Seven optimisation findings closed with a probe each, in `bench/residue`: 112 B a call → 0, 50 distinct refusal strings → 1, a parked buffer that regrew every frame → kept, `GetPlayers` per subject → once a tick, a refusal at 2.8x an admission → 1.2x, an unbounded pool → 8 |
| 5 | `t.string`'s `charset`; `t.literal`, `t.set`, `t.optional(x, default)`, a compact `t.cframe`; recipient sets and positions read once per tick; the delta crossover measured in bytes |
| 6 | `analyze` walks `bench/`, `tools/` and itself; selene's global list is gone, replaced by 30 block-scoped allows |
| 7 | A policy's **server stage**, run once at seal; a yield across a `ctx` reported at `handler`/`authorize`; an intent paced by the client at its declared rate |
| 8 | A namespace declared under `ServerScriptService` refused at its line; a per-namespace digest, so a protocol disagreement names the namespace on both consoles |
| 9 | The tutorial, the worked example, `mistakes.md`, `DESIGN-API` and both READMEs moved with the above, corrections struck rather than rewritten |

### The measurements, in one place

| What | Before | After |
|---|---|---|
| `Delta.write` | 112 B a call, both paths | 0 in all 64 windows |
| `Batch.read` oversize refusals | 50 distinct strings for 500 claims | 1 |
| A 1.5 KB frame's buffer | 64 → 2048 → 64, a new object each frame | 64 → 2048 → 2048, the same object; 5,696 → 1,600 B a frame |
| An unreliable 200 B packet | 768 B | 256 B |
| `Namespace.replicated()` | a fresh array per ask | one frozen list |
| `within`, per subject | `GetPlayers()` per subject | the frame's list, handed down |
| `Budget.admit` refusal | 2.84–2.87x an admission | 1.19–1.25x |
| The instance reader's refusal | 1.40–1.52x | 1.09–1.11x |
| The pending pool after 64 parked walks | 64 lists | 8 |
| `bench/tick` `select-all` 50×500 | 3.43–3.47 ms | 3.16–3.24 ms |
| `within` in Studio, one player | 693 ns a subject | 348 ns |
| A roster-returning `select` in Studio | 355 ns a subject | 159 ns |
| A compact `t.cframe` | 24 bytes | 13, rotation within 6.1e-5 rad |
| A set of two short strings | 9 bytes as `map(k, boolean)` | 7 |
| The intent pacer | 180 on the wire, 61 refused | 119, 0 |
| `types_reject` / `api_reject` | 11 / 24 | 24 / 36 |

### One correction the closing pass produced

The Studio measurement of `within` and of a roster-returning `select` was one timed pass, and it moved
**364 → 650 ns** and **142 → 220** across three sessions — the same instability `bench/residue`'s two
timing rungs were corrected for mid-milestone. It takes the fastest of seven passes now, for the reason
`bench/tick` gives: the work is deterministic, so noise only ever adds. Re-measured on the closing
tree, 348 and 159 ns a subject, which is what the table above quotes.

### The one task left open

The `ArrayHeavy` Down cell's outlier (§6 phase 4). It needs the bench place built from a worktree at
`0cb731d`, that matrix run, and the current tree's matrix in the same Studio session — twenty minutes
for a question about the instrument rather than about netweave. `bench/RESULTS.md` says so where the
cell is, and nothing in the library waits on it.

### What was measured and deliberately not done

Each of these is a decision with a number behind it, not an omission:

- **`nw.validate` still launders a brand.** The type-level refusal was written: an `Unbranded<V>` on
  the value parameter makes `api_ok` report "Code is too complex to typecheck" with 709 diagnostics
  behind it. `DESIGN-API` §6 tells a game not to pass a channel payload to `validate`, and why.
- **A channel record is not frozen at seal.** `handler` is written after declaration by `:listen` and
  sealing is triggered by the first packet, so freezing would raise on a legal sequence; moving the
  handler to a side table costs a per-packet lookup and 94 assignments across six rigs. The typed
  route is closed instead, which is the one the finding is about.
- **`channel: any` stands across the transport.** Six modules each read a different handful of a
  channel's fields and six rigs build partial channel tables; a full record makes every rig a cast. A
  per-module structural type is the shape that would not, and it is a module-by-module job.
- **The view mappers cannot localise a bad channel** (D-8). `ServerView` is one type function over the
  whole declaration table, and an `error()` inside a channel's payload function leaves the application
  stuck, so the body never runs. Unsticking it means the payload functions returning `unknown`, which
  trades away the analysis-time half of G2 and G3.
- **The bare-namespace erasure has no canary.** `spike/declare/passed.luau` reproduces it and Q6
  records the bisect; it cannot be pinned in `api_reject`, because the shape *adds* diagnostics while
  removing others. The guard is the cast at the call, in `DESIGN-API` §7 and the tutorial.
