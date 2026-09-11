# PLAN-M5 — the declaration surface, typed all the way down

**Status: not opened.** Written during `PLAN-M4-BUG` so that nothing deferred from the M4-1 report is
lost in a margin; `nw.milestone` stays `M4` until this line is removed, which is the act of opening
it (`tools/messages` reads the marker).

Drafted from `PLAN-M4-BUG` §4. This
is a plan in outline: the tasks are named, the design decisions are the ones the reports already
argued, and the phases are ordered but not yet sized.

## 1. Goal

When this is done, every value `nw` hands a game has a type the game can name through `nw`, every
constructor's arguments are checked by the analyzer and not only by the runtime `check()`, a
declaration record cannot be changed after it is sealed, and the optimisation residue the M4-1
report measured (a closure per `Delta.write`, a string per `Batch.read` refusal, a send buffer
regrown per frame) is closed with a number beside each.

## 2. Why now

M4 closed the security and correctness findings of two audits; what it left open is the type layer,
by decision (`PLAN-M4-BUG` D-1 put instruments and client-triggerable costs first) and because each
of these items reshapes a public type. `DESIGN-API.md` §7 says half the guarantees are type errors;
M4-1 measured that the `__call` signatures check arity and not argument types, that seven exported
types no `_ok` file wrote, and that public values have no public type. `RESEARCH §3.8-T`/`§3.9-W`
is the argument that a runtime schema can be as typed as generated code; this milestone is where
that is made true for the declaration surface. `spike/declare/README.md` records what the surface
can and cannot enforce, and Q5 is the hazard every item here has to be tested against.

## 3. Scope

| Phase | Deliverable | Artifact |
|---|---|---|
| 1 | `Ranged`/`Text`/`Componented`/`Classed` as intersections; the three payload type functions and every `readproperty` site look through one | `src/types/init.luau`, `src/api/Trust.luau`, `src/api/Channel.luau`, `src/api/View.luau`, `tests/types_reject.luau` |
| 2 | `Policy<T>`, `Check<T>`, `Snapshot`, `Described`, `Rules`, `Limits`, `Audience<S>`, `Observer` re-exported from `nw`; `tools/exports` demands a type per public value family | `src/netweave.luau`, `tools/exports.luau`, `tests/api_ok.luau` |
| 3 | the M4 report's type-layer residue: `nw.validate` returns a copy (5), the channel record frozen at seal (6), a private brand behind `isType` (7), `Policy<T>` bound to the projected payload (43), unknown spec keys refused per class (45), a real `Channel` record at the transport boundary (46), `{ [Encoding]: … }` tables (47), a shared `Stage` (48), `Sidecar = { unknown }` (50), `Ir.patch` framing (42) | `src/api/*`, `src/transport/*`, `src/codec/Ir.luau` |
| 4 | optimisation residue with a probe each: `Delta.write` closure (73), `Batch.read` refusal interpolation (74), `Buffer.take` regrowth (76), per-tick allocations (77), `Budget.admit` refusal string, instance-reader concatenation, the free list | `src/replication/Delta.luau`, `src/transport/*`, `bench/*` |
| 5 | `t.string`'s `{ charset = … }`; recipient-set caching per tick for `select`/`nearby`; the nice-to-have types (`t.literal`, `t.set`, `t.optional(x, default)`, compact `cframe`) as their own `_ok`/`_reject` pairs | `src/types/init.luau`, `src/transport/Recipients.luau`, `tests/` |
| 6 | selene block-scoped allows in place of the hand-kept global list; `bench/` and `tools/` type-checked by `analyze` | `netweave.toml`, `analyze.luau`, `src/**`, `bench/**` |

## 4. Non-goals

- A `changed` signal on `Store`, `t.refine`, `t.id`, `t.timestamp`, `t.recursive`, `t.tuple`,
  `t.buffer(n)`, `nw.untrust`/`nw.trust`, a wrapper `Trusted<T>`, a discriminated `Verdict` while
  the record is shared, analysis-time numeric bound checks (the solver widens literals), a
  per-destination packet ceiling typed into `Config` — each declined with its argument in
  `docs/SECURITY-REPORT-M4-1.md` "Do not add".
- A per-client "received the last snapshot" flag over `baselinesPerClient` — declined in
  `src/replication/Baseline.luau` (PLAN-M4-BUG phase 5).

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

## 6. Tasks

Ordered by phase; sized when the milestone opens.

### Phase 1 — the callable shape
- [ ] `Ranged<T>`, `Text`, `Componented<T>`, `Classed` as `Type<T> & ((…) -> Type<T>)`
- [ ] `PayloadOf`, `StructPayload`, `UnionPayload`, `MapPayload`, `OptionalPayload`, `ArrayPayload` look through an intersection
- [ ] every `readproperty` site in `Trust`, `Channel`, `View` does the same
- [ ] `types_reject` gains a case per constructor for a wrong-typed argument; Q5 re-run
- [ ] the fifth `nw.Views` spelling, measured writing the tutorial (2026-09-10): passing a namespace
      *bare* to a parameter typed `nw.Views<typeof(ns.channels)>` or `typeof(ns)` turns the payloads of
      the handlers already written on that namespace into `unknown`, retroactively; the cast at the call
      keeps them. `tests/tutorial_ok.luau` carries the cast with the measurement beside it. Pin the bare
      call in `api_reject` as a canary the way the annotated-local spelling is, or find the instantiation
      that loses the brand and fix it in `View`

### Phase 2 — a type for every public value
- [ ] re-export `Policy<T>`, `Check<T>`, `Snapshot`, `Described`, `Rules`, `Limits`, `Audience<S>`, `Observer`
- [ ] `tools/exports` demands a type per public value family
- [ ] `api_ok` writes each

### Phase 3 — the M4 report's type-layer residue
- [ ] items 5, 6, 7, 42, 43, 45, 46, 47, 48, 50 of `docs/SECURITY-REPORT-M4.md`, each its own commit
- [ ] for 43, the measurement from the tutorial (2026-09-11): a payload-agnostic policy cannot be composed
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
      cannot drift from the schema

### Phase 4 — optimisation residue
- [ ] items 73, 74, 76, 77 and the three M4-1 미미 optimisation findings, each with its probe
- [ ] the reader: `bench/decode` in Studio at `249ca27` prices netweave's client decode at 2.81x the
      generated-code ceiling (35,073 against 12,476 ns a packet) and there is no fused struct reader to
      match the writer; and the Down cell re-run on `0cb731d` beside the current tree in one session, to
      find which of its four readings is the outlier (`bench/RESULTS.md`, "The Down cell")

### Phase 5 — additions
- [ ] `t.string` `{ charset = … }`, linear by construction
- [ ] recipient-set caching per tick, measured on `bench/tick`'s `select-all` and a `nearby` rung
- [ ] the delta crossover `PLAN-M4` acceptance 8 asked for and never measured: a replication mode in the
      matrix, and the subject size below which a diff loses to a resend written into `bench/RESULTS.md`
- [ ] the nice-to-have types, each with an `_ok`/`_reject` pair

### Phase 6 — the tooling
- [ ] selene block allows replace the global list in `netweave.toml`
- [ ] `bench/` top-level scripts and `tools/` under `analyze`

## 7. Acceptance criteria

1. `t.u8(0, "b")`, `t.string(0, 5, { utf8 = 1 })`, `t.vector3(t.boolean)`, `t.instance(5)` each produce a diagnostic, and `types_reject` marks the line and the text.
2. `local policy: nw.Policy<Equip>`, `local snapshot: nw.Snapshot`, `local observer: nw.Observer` analyse in an `_ok` file with a negative control each.
3. `tools/exports` fails when a public value family gains a member with no nameable type.
4. `nw.validate` returns a table the caller did not pass in; a channel record raises on write after seal; `nw.command({ store = {} })` is refused at declaration.
5. Each phase-4 probe's `BEFORE` reproduces on the parent tree within the session drift `bench/tick` records, and the after is lower.
6. `analyze` walks `bench/*.luau` and `tools/*.luau` and is clean.

## 8. Risks

- **The intersection breaks `t.u8` where a `Type<number>` is expected**, which is the spike's original
  reason for the flat duplicate (`src/types/init.luau`, the `Descriptor`/`Type<T>` note). Mitigation:
  phase 1 starts from `spike/declare/`, and `types_ok`'s scalar block is the first thing run.
- **Re-exporting internal types freezes their shape.** Mitigation: only the eight the report names, and
  `Snapshot`/`Described` as read-only tables.
- **An optimisation lands without its probe because the probe is hard to write.** Mitigation: D-4 —
  it does not land.
