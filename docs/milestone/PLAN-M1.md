# PLAN-M1 — Declaration Surface and L1 Codec

**Status: closed.** Six of eight acceptance criteria met, one partially, one missed. The miss is
`ArrayHeavy` encode throughput; its cause was isolated by a second measurement rather than guessed,
and implementing the fix is M2's opening item. See §9.
**Depends on:** M0 (baseline harness and numbers), `docs/DESIGN-API.md` (agreed API shape)
**Blocks:** M2 (transport: batching, budgets, audience evaluation, intent coalescing)

---

## 1. Goal

A schema you can declare in plain Luau that produces, from one definition, the payload type,
the validation, and the buffer serdes — plus the declaration surface from `DESIGN-API.md`:
channel classes, policies, `Trusted`/`Untrusted`, and the rejection observer.

When M1 is done, `bench/src/shared/Modes/netweave.luau` exists and the empty mode slot in the
M0 harness reports real numbers next to Blink, Zap, ByteNet and raw.

## 2. Why now

M0 answered what the competition costs. Four of its findings set this milestone's targets:

- **`table.clone(TEMPLATE)` is unclaimed.** ByteNet allocates 389 B/packet on decode against
  Blink's 641 and Zap's 1474 because its `struct.read` clones a pre-sized template. This is the
  one axis where a runtime schema beats both code generators, and it is a design decision, not
  an optimisation to add later.
- **Allocation coalescing is narrow.** Blink's advantage appeared in exactly one cell of twelve
  (`ArrayHeavy`, 145 FPS vs 125/124). Worth recovering, not worth contorting the design for.
- **Serialization does not always pay.** On small flag payloads raw `RemoteEvent` beat all three
  libraries. netweave should know where that crossover is.
- **Zap's automatic bit packing is the byte win** (7 B against Blink's 10-20 B), and Blink's
  `set` reaches 32 bits per word against Zap's 16. Doing both is open ground (`§3.9-AA`).

Security and structure lead this project; the codec exists so that enforcing the guarantees in
`DESIGN-API.md` costs little enough that nobody turns them off.

## 3. Scope

| # | Deliverable | Artifact |
|---|---|---|
| D1 | Type-inference spike, with a written verdict | `spike/inference/`, `docs/DESIGN-API.md` §7, §11 |
| D2 | Frozen wire format | `docs/WIRE-FORMAT.md` |
| D3 | Type combinators with constraints | `src/types/` |
| D4 | Schema → IR → closure codec | `src/codec/` |
| D5 | Channel classes, specs, policies, trust types, observer | `src/` |
| D6 | netweave adapter in the M0 harness, and numbers | `bench/src/shared/Modes/netweave.luau`, `bench/RESULTS.md` |

## 4. Non-goals

| Deferred | To |
|---|---|
| Batching, channels, flush scheduling | M2 |
| Runtime budget enforcement (rate limiting) | M2 |
| `audience` evaluation and recipient sets | M2 |
| `intent` tick coalescing | M2 |
| Delta state replication | M4 |
| roblox-ts typings | ~~M5~~ **not planned** — not the audience yet |
| Wally and npm publishing | ~~M5~~ **not planned** — there is no publishing path; see `CLAUDE.md` §8 |

M1 defines the *types* for budgets and audiences — a declaration missing them must not compile
— but the runtime that enforces them belongs with the transport that owns the frame loop.

## 5. Design decisions

Carried from `docs/DESIGN-API.md`, which is the authority; repeated here only where M1 has to
act on them.

**D-1. Schema → IR → closures, two stages.**
ByteNet builds closures directly from the schema, which closes the window in which sizes, bit
layout and templates could be computed (`§3.8-N`). netweave lowers the schema to a small IR
first, runs the layout passes over that, then synthesises closures.

**D-2. Three layout passes, all at definition time.**
Fixed-size prefix calculation so the top level allocates once (`§3.7-D`); bit packing for
booleans, optional presence flags and small enum tags (`§3.8-P`); a `table.clone` template per
struct so decode never rehashes (`§3.8-S`, measured in M0).

**D-3.** ~~Accumulators are 32-bit; Zap caps at 16 and Blink's `set` reaches 32, so the wider one
wins.~~ **Wrong, corrected in `docs/WIRE-FORMAT.md` §5.** Accumulator width is irrelevant — total
bytes is what counts, and 17 bits costs 3 bytes whether stored as one `u32` or as `u16 + u8`.
Zap's 16-bit cap already yields the minimal byte count. **There is no byte win available against
Zap on packing.** netweave reaches parity, and beats Blink only where a Blink author did not
reach for `set`. The advantage over Blink is that packing is automatic (6 B vs 19 B for an author
who does not know the escape hatch), not that it is denser.

**D-4. Global buffer with save/load swap, symmetric across read and write.**
Not an anti-pattern — Blink and Zap both do it, and per-player multiplexing is built on the
swap (`§3.7-I`). ByteNet's mistake was doing it asymmetrically.

**D-5. Length-prefixed framing, but only where the size is not static.** A failed decode must be
able to skip to the next packet boundary; Blink and Zap cannot, so one malformed packet kills a
whole batch (`§3.8-R`). Measured cost (`docs/WIRE-FORMAT.md` §2): **zero on `ArrayHeavy`** (601 B,
identical to Blink and Zap, because a static schema needs no prefix) and **one byte on
`FlagIdiomatic`** (8 B against Zap's 7 B, +14%). A `derived` mode that recovers that byte is
specified but deferred (`WIRE-FORMAT.md` §7).

**D-7. `LuauSolverV2` is a hard requirement.** `type function` is what makes G1-G3 and G6 type
errors rather than documentation; the stock solver rejects the syntax. The library still loads
and runs under stock Luau — the construct is analysis-only — but none of its guarantees hold, so
supporting that configuration would be dishonest rather than generous.

**D-6. Channel ids are the declared string keys.** Nothing depends on table iteration order.
ByteNet derives packet ids that way and this project hit the resulting silent mis-decode during
M0 phase 3.

## 6. Tasks

### Phase 1 — inference spike (gate) — **done**
- [x] `spike/inference/` — four candidate encodings, with assertions made by assignment
- [x] Type-check them with `luau-lsp analyze`
- [x] **Q1 answered: yes, via `type function`.** The naive combinator signature does not merely
      collapse field names, it rejects heterogeneous structs outright; naming the payload type by
      hand type-checks but verifies nothing. `type function StructPayload` maps correctly.
- [x] **Q2 answered: no fallback needed.** A type function can branch on a `__class` singleton and
      build a different view per channel class. Direction violations fail at analysis time, so G6
      is a compile-time guarantee.
- [x] Verdict written into `docs/DESIGN-API.md` §7 and `spike/inference/README.md`
- [x] **Decided: `LuauSolverV2` is required.** Half the guarantees in `DESIGN-API.md` §2 are type
      errors or they are nothing, and a second untyped path would be a version of netweave that
      cannot keep its own promises (`DESIGN-API.md` §7)

### Phase 2 — wire format — **done**
- [x] `docs/WIRE-FORMAT.md` v1: batch envelope, varint channel ids from sorted qualified names,
      per-channel framing modes, flag packing, decode-failure behaviour, schema handshake
- [x] Length prefix costed against the M0 baseline: **0% on `ArrayHeavy`**, **+14% on
      `FlagIdiomatic`** (8 B vs 7 B). `derived` framing specified in §7 to recover it, deferred
      pending phase 6 measurement
- [x] Corrected D-3 while writing it: there is no packing win available against Zap

### Phase 3 — types — **done**
- [x] `src/types/` — numbers with ranges, bool, string, buffer, Vector2/3, unit vector, CFrame,
      Color3, Instance, enum, optional, array, map, struct
- [x] Constraints live in the type (`t.f32(-90, 90)`), so validation is derived, not written twice
- [x] `tests/types_ok.luau` — payload inference asserted by assignment, including nesting and the
      `DESIGN-API.md` §4 shapes
- [x] `tests/types_reject.luau` — 8 negative controls; `analyze.luau` fails if the count moves in
      either direction
- [x] `tests/types_runtime.luau` — descriptor contents, sorted order, narrowing, construction guards
- [x] `analyze.luau` + `tools/globalTypes.d.luau` — type checking is part of the test suite, since
      the guarantees are type errors
- [x] Three implementation findings, recorded where they belong:
      `Type<T>` cannot be `Descriptor & { __payload: T }` (breaks metatable subtyping and
      `readproperty`); the new solver does not push a call site's expected type into a generic
      return, so internal builders return `any`; selene cannot scope a lint filter, so the
      `type function` globals are declared in `netweave.toml`

### Phase 4 — codec
- [x] Root project files: `default.project.json` builds the library as a package,
      `test.project.json` builds a Studio place that mirrors the repository root. Both verified
      building.
- [x] Confirmed in Studio that relative string requires resolve there — `require("../types")` and
      `require("./Buffer")` both work, so `src/` needs no `script.Parent` chains, no darklua pass,
      and the same test file runs under lune and in Roblox. `@self` aliases do not resolve.
- [x] `src/codec/Buffer.luau` — byte layer: growable outgoing buffer with `save`/`load`, bounded
      reads that reject instead of throwing, varint, instance sidecar, reserve/patch for bitfields
- [x] `src/codec/Ir.luau` — schema lowering plus the layout passes: fixed size, flag packing into
      the fewest bytes, `table.clone` templates, number narrowing
- [x] `src/codec/Serdes.luau` — IR to read/write closures
      **Closure synthesis, not code generation.** The name matters: netweave has no build step,
      and calling this a compiler invites exactly the confusion it is meant to avoid. It binds a
      node's decisions into a function at definition time so nothing is re-decided per packet
      (`RESEARCH §3.6-B5`).
      The asymmetry is the security posture: **encode raises, decode never does.** A value from
      game code that the schema forbids is a bug and the alternative is silent wraparound on the
      wire; a value off the wire is hostile input and must not be able to abort a batch.
- [x] Correction to `Ir.lower`: `lowerLength` discarded the length bounds, so the decoder had no
      basis to reject an out-of-range count. A narrowed prefix admits more than the schema does —
      `t.array(e, 0, 200)` writes its count in a byte, and a byte holds 255. The bounds now travel
      on the node, and `.min` / `.max` mean a value bound for numbers and a length bound for
      strings, arrays and maps.
- [x] Round-trip tests, including every constraint boundary — `tests/serdes_runtime.luau`.
      Includes the byte counts the M0 competitors produced: `Entity` 6 B, `ArrayHeavy` 600 B, and
      `FlagIdiomatic` **6 B**, which is Zap's number and better than Blink's 9 B with `set`
      (`RESEARCH §3.9-AA`).
- [x] Adversarial decode tests: truncated, oversized, out-of-range, non-finite, unknown enum tag,
      missing instance — none raise. Plus a seeded fuzz of 4,200 random payloads across fourteen
      schemas, asserting only that decoding terminates and returns.
- [x] `tests/roblox_runtime.luau` — the half lune cannot reach: `Vector2`, `Vector3`, `CFrame`,
      `Color3` and real instances, including the `t.instance("Sound")` class check that no
      surveyed library performs. **Written and analysed; not yet executed in Studio.**
- [x] Fixed `tests/run.server.luau`, which would have failed every test in Studio: it required
      every `ModuleScript` under `tests/`, but the test files returned nothing (Roblox rejects a
      module that does not return exactly one value) and the analyser fixtures are not runnable.
      It now filters to `*_runtime`, and those files return `true`.
- [x] ~~Second defect in the same path: the runner is in `ReplicatedStorage`, where a `Script` never
      executes.~~ **Wrong, and the fix was worse than the bug.** `emitLegacyScripts: false` makes
      Rojo emit a `.server.luau` as a `Script` with `RunContext = Server`, which runs wherever it
      sits. Mapping it into `ServerScriptService` as well ran the entire suite twice. Reverted.

### Phase 5 — declaration surface
- [x] `spike/declare/` — five questions answered before `src/api/` was written, because three of
      the answers contradicted `DESIGN-API.md`. See `spike/declare/README.md`.
- [x] `src/api/Channel.luau` — `command` / `intent` / `signal` / `query` / `state` / `event` over
      three internal primitives (`AuthorizedInbound`, `UntrustedInbound`, `Outbound`; `query` is an
      `AuthorizedInbound` that also owns a paired `Outbound`).
      **Corrects `DESIGN-API.md` §3's "four primitives".** Six classes, three implementations —
      the fourth was `query`'s response, which is not a separate primitive but the `Outbound` it
      already owns.
- [x] `src/api/Policy.luau` — `nw.policy`, `nw.all`, `nw.allow`, `nw.deny`. Nothing allocates per
      request: one shared verdict record, and `nw.all` flattens its members into an array at
      declaration time (risk **R-3**).
- [x] `src/api/Trust.luau` — `Trusted<T>` / `Untrusted<T>` / `nw.validate`, no unwrap function
- [x] `src/api/Context.luau` — one `ctx` per player, refreshed in place, with a Studio-only
      generation guard. The proxy is built once per player, so the guard costs nothing per packet
      and is absent entirely in production.
- [x] `src/api/Observer.luau` — `nw.observe`, one reused rejection record, `xpcall` so an observer
      that throws cannot abort the batch it is reporting on
- [x] `src/api/Audience.luau` — `everyone` / `owner` / `nearby(studs)` / `select(fn)`, each
      carrying a `scope` singleton. Evaluation is M2; what M1 fixes is the type.
- [x] `src/api/View.luau` — the directional views, and `src/api/Namespace.luau` — ids from sorted
      qualified names plus the FNV-1a protocol hash (`WIRE-FORMAT.md` §3, §4)
- [x] `src/api/Transport.luau` — the seam M2 attaches to. Written as a hole that names the missing
      milestone rather than a stub that silently drops packets.
- [x] `Serdes.Codec.check` — `nw.validate` runs the **encoder** against a parked buffer rather than
      restating its rules. Two implementations of "what a value must satisfy" would drift, and they
      would drift on exactly the boundary cases nobody re-tests.
- [x] `tests/api_ok.luau`, `tests/api_reject.luau` (13 negative controls), `tests/api_runtime.luau`

#### What the spike changed about the plan

Three claims in `DESIGN-API.md` did not survive measurement, and one mechanism failed silently
enough to be worth recording as a hazard.

- **`Untrusted<number>` is `never`.** §6 specified `T & { __nwUntrusted: true? }` for all `T`.
  Intersecting a primitive with a table normalises to `never`, which is a subtype of everything —
  so a branded scalar rejects every legitimate use of the value *and* satisfies every parameter it
  was meant to guard. Both brands are now type functions that brand tables and pass scalars
  through. §6 is corrected with the strikethrough, including its example, which used `t.u8`.
- **A spec type cannot forbid a field.** Width subtyping accepts extra properties, so listing only
  the allowed fields forbids nothing. `authorize: nil` works; a type function that reads the
  property and calls `error()` works better, because it says which class to use instead.
- **`command<T>(spec: { data: Types.Type<T> })` does not bind `T`.** It resolves to `unknown`, and
  an unannotated policy in the same spec widened it further to `any` — silently disabling payload
  inference for the whole channel while everything still compiled. Constructors now take the spec
  as a free generic and project the payload out with a type function.
- **An `export type function` its own module never references becomes `any` across a `require`,
  with no diagnostic.** `View.ServerView` and `Trust.Trusted` were both `any` for a while:
  `api_ok.luau` type-checked, and `api_reject.luau` reported eight of thirteen — the five that
  vanished were exactly the direction and trust guarantees. Pinned by `Views<D>` in `View.luau` and
  two local aliases in `Trust.luau`, each with a comment saying what deleting it breaks.

The last one is why acceptance criterion 1 is checked by a **count** rather than by "analysis
fails". A guarantee that stops being enforced does not announce itself.

#### What running it in Studio changed

Lune cannot reach two things, and both were wrong.

- **The Studio-only `ctx` guard expired every context permanently.** The proxy was built once per
  player and captured `record.generation` at construction, so the first `release` invalidated it
  for good: in a real game every handler from the *second packet onward* would have raised, in
  Studio only, which is the environment a developer actually runs. `acquire` now hands out a fresh
  proxy per acquisition — two allocations per packet, in Studio, where throughput is not measured;
  production still returns the record itself and allocates nothing. A plain `active` boolean was
  considered and rejected: it answers "is some handler running", so it misses a `ctx` retained and
  read during a *later* packet, which is the case that silently hands over another request's data.
- **The runner did not say what it had found.** Pressing play produced a clean-looking
  five-module pass with `api_runtime` absent and nothing anywhere saying so — the place was stale,
  and a missing module leaves no trace in a summary that counts only what it saw. The runner now
  prints what it found and what it skipped, and errors if it finds nothing.

  The first diagnosis of that — "a `Script` under `ReplicatedStorage` never executes" — was wrong,
  and mapping the runner into `ServerScriptService` on the strength of it ran the whole suite
  twice. `emitLegacyScripts: false` gives the script `RunContext = Server`, which runs anywhere.
  Reverted, and recorded in `CLAUDE.md` so the same wrong inference is not made again.

And one assumption is now measured rather than assumed: **`src/netweave.luau` requiring
`./api/Context` resolves in Roblox.** A module beside its sibling directories works; an
`init.luau` reaching its own children still does not, which is why there is not one.

### Phase 6 — measurement
- [x] `bench/src/shared/Modes/netweave.luau` — the six benchmark channels declared through the real
      surface (`command` with a policy attached, per R-3), plus a stand-in transport installed
      through `nw.internal.transport`. The stand-in is the harness's, not netweave's: M2 owns
      batching, budgets, audience evaluation and coalescing, and every number here has to be read
      with that in mind. Blink and Zap both batch and flush on `Heartbeat`, so a netweave measured
      without batching would be measuring the absence of a milestone rather than a library.
- [x] `bench/envelope.luau` — the batch envelope under lune, so a framing bug fails in a second
      rather than as "the payload garbled" after a Studio run. It found one immediately: a
      rejection is sticky, so a refused packet stopped the whole batch at the *next* packet's id
      read. That is the exact failure G5 and the length prefix are paid for, reintroduced by the
      code meant to honour them.
- [x] `bench/report.luau` and `bench/src/shared/WireTap.luau` know about netweave
- [x] `Config.SMOKE` and `Config.ONLY_MODES`, because a full matrix is a quarter of an hour and
      finding a broken adapter at the end of one is the worst order to learn it in
- [x] M0 matrix rerun with all five modes — `bench/runs/2026-09-04.json`, `bench/RESULTS.md`
      rewritten around it
- [x] Codegen gap recorded as a percentage per schema family, and `§3.7-D` revised — the new
      `RESEARCH §3.10` records it. The claim is narrowed rather than deleted: allocation coalescing
      is a code generator's advantage **on encode only**, and on the same payload in the same run
      the runtime schema wins decode.
- [x] **Re-measured `ArrayHeavy` after the encode fix** — `bench/runs/2026-09-04-recheck.json`.
      **netweave stayed at exactly 85** while Blink went 139 to 144 and Zap 116 to 120 on a
      slightly quicker machine, so the gap widened to 1.69x. The discriminating test came back
      against the adapter hypothesis and left the other standing.

      ~~The bench adapter's two `Buffer.save()` tables per send are the likeliest cause of the one
      acceptance criterion this milestone misses.~~ **Too small to be.** Two tables per send is a
      constant, and the gap appears only on the payload with six hundred fields. Reading `Serdes`
      afterwards found the real one: **it never calls `Buffer.allocate`.** Every scalar goes through
      `Buffer.writeU8` and friends, which allocate their own bytes — 600 allocations for one
      `ArrayHeavy` packet, 120,000 a frame, against six for a flag packet.

      That is D-2's first layout pass, computed and then not used: `Ir.lower` produces `fixedSize`,
      `Serdes.build` copies it onto the `Codec`, and nothing reads it.

      **Confirmed.** The fix landed where it should — on the flag schemas, where the two tables
      *were* the whole measurement, encode allocation fell from 609.3 B to 81.92 B, which is Zap's
      figure to the decimal — and moved the `ArrayHeavy` framerate not at all. Implementing D-2's
      first pass is M2's opening item.

## 7. Acceptance criteria

1. Declaring a channel without `rate`, without `authorize` where the class requires it, or
   without `audience` where the class requires it, fails `luau-lsp analyze`.
2. Round-trip equality for every type at its constraint boundaries, both directions.
3. No adversarial input reaches `error()` on the receive path. Truncated, oversized,
   out-of-range and unknown-id packets each produce a rejection value and leave the reader able
   to continue at the next packet boundary.
4. Bytes per packet, measured by the same wire tap that produced the M0 baseline: **equal to
   Blink and Zap on `ArrayHeavy`** (601 B), and **within one byte of Zap on `FlagIdiomatic`**
   (8 B vs 7 B) — that byte being the framing guarantee G5, not overhead. Beating Zap on bytes is
   not a goal and is not available (`D-3`, corrected).
5. Framerate under the M0 load is within 1.3x of the best library per schema family.
6. Decode allocation per packet is at or below ByteNet's, which is the current best (389 B on
   `ArrayHeavy`).
7. No allocation on the receive hot path: no Promise, no `BindableEvent`, no fresh coroutine.
8. `stylua --check`, `selene`, and `lune run bench/check` pass.

## 8. Risks

**R-1 — The spike fails Q1 and per-field inference is impossible.**
This is the milestone's central risk and the reason phase 1 gates everything. If Luau cannot
infer `{x: number}` from `{x: Schema<number>}`, the declaration has to name the payload type
explicitly and the library's job becomes checking the schema against it rather than deriving
it. That is a materially different product and `DESIGN-API.md` §1 would need rewriting before
any code is committed. Mitigation: find out first, in a throwaway directory, before phase 3.

**R-2 — The layout passes do not close the gap.**
M0 showed Blink's coalescing advantage is real but narrow — one cell of twelve. If the runtime
passes recover most of that cell and cost complexity everywhere else, they were a bad trade.
Mitigation: phase 6 reports the gap per schema family, and phase 4 keeps each pass separately
switchable so its contribution can be measured rather than assumed.

**R-3 — Security enforcement costs more than the codec saves.**
An authorization callback per packet, plus context setup, could erase the byte and CPU
advantages entirely and hand the argument to "just use a RemoteEvent" — which M0 showed is
already faster for small payloads. Mitigation: `allow`/`deny` must not allocate, `ctx` is
reused, and phase 6 measures a channel with a real policy attached, not a bare one.

**R-4 — The length prefix is a visible byte cost on small packets.**
On a 7-byte `FlagIdiomatic` payload, one or two extra bytes is 15-30%. Mitigation: phase 2
measures it before phase 4 commits, and a varint keeps the common case to one byte. The
guarantee it buys — one bad packet cannot kill a batch — is worth stating in those terms
rather than hiding the cost.

## 9. Result

**Shipped.** A schema declared in plain Luau yields the payload type, the validation and the
buffer serdes; six channel classes carry the security obligation in the type; and the whole thing
is measured next to Blink, Zap, ByteNet and a raw `RemoteEvent` rather than argued about.

### Against the acceptance criteria

| | | |
|---|---|---|
| 1 | Missing `rate`, `authorize` or `audience` fails analysis | **met** — `tests/api_reject.luau`, 13 diagnostics, counted exactly |
| 2 | Round-trip at every constraint boundary | **met** — `tests/serdes_runtime.luau` and `tests/roblox_runtime.luau`, the latter run in Studio |
| 3 | No adversarial input reaches `error()` | **met** — truncation, out-of-range, non-finite, unknown tag, missing instance, plus a 4,200-case fuzz |
| 4 | Bytes equal to Blink and Zap on `ArrayHeavy`, within one byte of Zap on `FlagIdiomatic` | **met** — 601 and 601, 8 against 7 |
| 5 | Framerate within 1.3x of the best library per schema family | **missed on `ArrayHeavy`** — 1.69x of Blink on encode, confirmed by re-measurement. Met on both flag families, where the whole field is inside the harness's own 14% noise |
| 6 | Decode allocation at or below ByteNet's | **met** — 389 B against 520 B, though Zap's 65 B in the same run resets what the bar should be |
| 7 | No allocation on the receive hot path | **receive path met; send path improved, not closed** — the adapter's two tables per send are gone, measured; `Serdes` still allocates per field, deferred to M2 |
| 8 | `stylua --check`, `selene`, `lune run bench/check` pass | **met** |

**Six of eight met, one partially, one missed**, and both open items are on the encode side.

The first is small and fixed: the bench adapter allocated two tables per send. The second is
D-2's own first layout pass, and it was never implemented. **`Serdes` computes `fixedSize` and
never calls `Buffer.allocate`** — every scalar allocates its own bytes through `Buffer.writeU8`,
so one `ArrayHeavy` packet costs 600 allocations and a frame of them costs 120,000, while a flag
packet costs six. That is why the gap appears on exactly one schema family and nowhere else, and
it is a code change in `src/codec/`, not a benchmark artifact.

A second run separated the two causes rather than leaving the attribution to argument: with the
adapter fixed, the flag schemas' encode allocation fell to Zap's exact figure and `ArrayHeavy`
throughput did not move by one frame. That is what makes the remaining item a known task instead
of an open question.

Doing it is deliberately left to M2 rather than smuggled into M1's closing hours. The theme of this
project is that the guarantees come first and the optimisation follows the measurement; the
measurement now exists and says precisely where to spend.

And it says one more thing worth carrying forward: **the harness cannot resolve differences under
about 15%.** netweave's two flag cells run the same schema through the same code and differ by 14%
in the same run. Every claim M2 makes from this harness has to clear that bar.

### Against the risks

- **R-1 — the spike fails and per-field inference is impossible.** Did not happen. `type function`
  under `LuauSolverV2` maps a declaration table to per-channel directional views, and G6 is a
  compile-time guarantee (`DESIGN-API.md` §7).
- **R-2 — the layout passes do not close the gap.** Half true, and the half that is true is
  narrower than feared. Bytes reached parity with Zap; encode CPU did not close on `ArrayHeavy`.
- **R-3 — security enforcement costs more than the codec saves.** No evidence of it. Every
  benchmark channel is a `command` with a policy attached and a context acquired per packet, and
  netweave still ties or wins on both flag families.
- **R-4 — the length prefix is a visible byte cost on small packets.** Real and exactly as costed:
  one byte, 14% of a 7-byte payload, zero on a static schema.

### What M1 changed about the plan

Four claims did not survive contact with a measurement, and each is corrected where it was made:

- `DESIGN-API.md` §6 — `Untrusted<number>` normalises to `never`. Both brands are type functions
  that bind to table payloads only.
- `DESIGN-API.md` §3 — three internal primitives, not four.
- `RESEARCH §3.7-D` — allocation coalescing is a code generator's advantage on **encode**; the
  runtime schema wins decode on the same payload (`§3.10-BB`).
- `PLAN-M0`'s "raw beats every library on small payloads" reproduced as a tie, not a win.

And one hazard is worth carrying into M2: an `export type function` that its own module never
references becomes `any` across a `require`, with no diagnostic. It silently disabled five of the
thirteen guarantees in `tests/api_reject.luau`, and the exact count is what caught it.

