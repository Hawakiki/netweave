# PLAN-M4-BUG — closing the M4-1 report

A sub-milestone that gates M4's close. It works through `docs/SECURITY-REPORT-M4-1.md` (84 new
findings at `460aa41`, plus the 51 still open from `SECURITY-REPORT-M4.md`) in a fixed order, and
says which of them M4 does **not** close and where those go.

## 1. Goal

When this is done, every 중대 and 위험 in the M4-1 report is closed or declined with an argument
written next to it; every client-triggerable cost is bounded at declaration time; the checkers that
guard the tree cannot report green on a tree they did not check; `bench/RESULTS.md` says what
`bench/runs/` says; and `PLAN-M4` carries a disposition of both reports and a Result section. What is
left over is listed in `PLAN-M5` by name, not by omission.

## 2. Why now

The M4-1 report found two library 중대 in shapes no test had written (the `replicate` join path and
`t.map` with a struct payload), a 위험 a client can trigger without a game bug (`t.string` pattern cost,
34 s per packet inside the declared `rate`), and four one-line holes in the checkers that would let any
of the later fixes go unverified. M4 cannot close over those, and the fixes are cheaper in this order
than in any other: instruments first, so every fix after them is confirmed the way §9 asks; code
before record, so the record is rewritten once. `RESEARCH §3.8-R` (failure isolation on the receive
path) is the guarantee most of the security items are about; `§3.11` is where the benchmark numbers
this plan corrects came from.

## 3. Scope

| Phase | Deliverable | Artifact |
|---|---|---|
| 1 | checkers that cannot pass unchecked; the `select` hole test that bites | `analyze.luau`, `tools/exports.luau`, `tests/transport_runtime.luau`, `tests/hostile_runtime.luau` |
| 1 | the criterion-5 result on the record, now | `bench/RESULTS.md`, `docs/milestone/PLAN-M4.md` |
| 2 | pattern cost and malformed patterns refused at `t.string` | `src/types/init.luau`, `tests/types_runtime.luau`, `tests/types_reject.luau` |
| 3 | `replicate` before `:listen` delivered; `t.map(t.u16, Entity)` compiles; batch survives a handler raise | `src/transport/Inbound.luau`, `src/types/init.luau`, `tests/replication_runtime.luau`, `tests/types_ok.luau` |
| 4 | residue of the phase-8 types and my own regressions | `src/api/Context.luau`, `src/api/Protocol.luau`, `src/types/init.luau`, `src/codec/Serdes.luau`, `src/transport/Recipients.luau` |
| 5 | a tick that is schema-aware, broadcast-aware and bounded over the ceiling | `src/replication/Tick.luau`, `src/replication/Baseline.luau`, `src/transport/Inbound.luau`, `bench/tick.luau` |
| 6 | honest harness floors and a fuzzer that sees the M4 surface | `tests/*_runtime.luau`, `tools/exports.luau`, `tests/roblox_runtime.luau` |
| 7 | a results document derived from committed artifacts only | `bench/report.luau`, `bench/RESULTS.md`, `bench/runs/`, `bench/profile.luau`, `bench/envelope.luau` |
| 8 | documents that describe the code as it is | `PLAN-M4.md`, `DESIGN-API.md`, `WIRE-FORMAT.md`, `CLAUDE.md`, `src/**` comments |

## 4. Non-goals

Deferred to **M5**, each named so it cannot be lost in the margin:

- `Ranged`/`Text`/`Componented`/`Classed` as intersections so `__call` checks argument types. Three
  payload type functions and the `readproperty` sites in `Trust`, `Channel` and `View` must all look
  through an intersection first.
- Re-exporting `Policy<T>`, `Check<T>`, `Snapshot`, `Described`, `Rules`, `Limits`, `Audience<S>`,
  `Observer` from `nw`, and teaching `tools/exports` to demand a type per public value family.
- The type-layer items open since the M4 report: `nw.validate` laundering (5), channel record mutable
  after seal (6), `isType` duck check (7), `Policy<T>` unbound (43), misspelt spec keys (45),
  `channel: any` (46), encoding tables keyed `string` (47), `Sink` stage `string` (48), sidecar typed
  `{ Instance }` (50), `Ir.patch` framing `static` (42).
- Optimisation residue: `Delta.write` closure (73), `Batch.read` interpolation (74), `Buffer.take`
  regrowth (76), per-tick allocations (77), `Budget.admit` refusal string, instance-reader
  concatenation, free list never trimmed.
- A `{ charset = … }` constraint on `t.string`; the nice-to-have types; selene block-scoped allows.

## 5. Design decisions

### D-1 — instruments before what they measure

§9 says a regression test is confirmed to fail against the pre-fix code, and this plan makes about
thirty-five such confirmations. Four one-line holes in the checkers (a `--!nonstrict` header, a
luau-lsp that did not run, an `expect N` satisfied by junk, a string literal counted as coverage) make
every one of those confirmations worth less than it reads. So they go first, before any code they
would be asked to check. `RESEARCH §3.11` is the record of what happens when an instrument is trusted
before it is checked: a 6.7% single reading rejected a design, and the instrument drifts 5%.

### D-2 — a client-triggerable cost is bounded at declaration, not at receive

The pattern matcher's cost is polynomial in the input and the input is bounded only by `max`. A
receive-side step counter does not exist in Luau, and a timeout would have to be a yield on the
receive path, which `§3.6-A4` forbids. The only place the cost can be bounded is where the pattern is
declared: refuse a pattern with more than one unbounded item unless `max` is small enough that the
worst case is under a tenth of a millisecond. `§3.8-R` is the guarantee being kept: one packet must not
stop the batch, and a 34-second packet stops every batch.

### D-3 — the baseline is the queue

A `replicate` snapshot that arrives before the handler is already in the client's baseline, so
re-queueing the value would be a second copy of something the transport already holds. `drain` for a
`replicate` channel walks the baselines instead. This is the same argument `Store.luau` makes for
deleting `changed`: do not keep a second record of a fact the first record already answers.

### D-4 — code before record

Phases 5 and 6 change the numbers phase 7 reports and the text phase 8 describes. Doing the record
first means doing it twice. The one exception is the criterion-5 result: a 중대 that a sentence with a
strikethrough stops today, so that sentence lands in phase 1 and the regeneration in phase 7
(`CLAUDE.md` §5 rule 1; `§3.11-II` for the last time a number sat unrecorded).

### D-5 — a harness floor that is met by relabelling is lowered, not defended

`§9` says the floor is per section so the ratio cannot be moved by relabelling; the M4-1 report shows
it was moved by tagging. The honest share is what is written, and where it falls under the floor the
floor moves to the honest number with a strikethrough saying why. Acceptance criterion 11 of `PLAN-M4`
is then judged against the honest share, and written as missed if it is.

## 6. Tasks

Each fix is its own commit on `develop`. Each regression test is run over the pre-fix tree before the
fix lands, and the commit message says which mutation was used.

### Phase 1 — the instruments

- [x] `analyze.luau`: refuse any file under `src/` whose first non-empty line is not `--!strict`
- [x] `analyze.luau`: fail when luau-lsp exits non-zero and reported zero diagnostics
- [x] `analyze.luau`: `-- netweave:expect N` also marks the lines, and each mark says what its diagnostic
      has to contain — lines alone were measured and let junk swapped onto the marked line pass
- [x] `tools/exports.luau`: skip string bodies in the same walk that skips comments
- [x] `tests/transport_runtime.luau`: a `select` hole built by assignment (`t[1] = a; t[3] = b`); confirmed
      to fail with `Recipients.luau:337` reverted to `#`
- [x] `tests/hostile_runtime.luau`: the nine `reports[1].reason` reads guarded, so a disabled stage counts
      its failures instead of raising
- [x] `bench/RESULTS.md` and `PLAN-M4.md`: criterion 5 at 1.15x on `2026-09-06-m4p8.json`, the Down
      cell at −30% as unexplained, both with strikethroughs on the old text

### Phase 2 — what a client can trigger

- [x] `refineText`: a scanner that refuses a malformed `%b` or `%f`, `%<digit>`, an unbalanced `(` or `[`, a
      trailing `%` — a well-formed `%b()` and `%f[set]` are allowed, since the grammar admits them
- [x] `refineText`: ~~refuse more than one unbounded item unless `max <= 64`~~ refuse when `max^k` for `k`
      unbounded items passes 2^16 steps (two items allow 256, three allow 40); measured at the boundary,
      0.4 ms; the rule and the reason in the docstring
- [x] `refineText`: the anchor check reads `%$` as a literal; ~~a mid-pattern `^` or `$` is refused~~ a
      mid-pattern `^` or `$` is the literal character in Lua and stays accepted
- [x] `readVarint` refuses a fifth byte above `0x0F` instead of wrapping (M4 finding 8)
- [x] a probe in `spike/pattern/` reproducing the curve to 16 KB (2.1 s) against the pre-fix tree, and the
      declaration refused after

### Phase 3 — the two library 중대, and G5

- [x] `Inbound`: `change` skips the pending entry when `channel.handler == nil`; `drain` of a `replicate`
      channel delivers every held baseline; the five-step probe from the report's appendix as the test
- [x] `MapPayload(key, value)` type function — and `OptionalPayload`, `ArrayPayload`, because
      `t.optional(Entity)` and `t.array(Entity)` were measured at `Type<unknown?>` / `Type<{unknown}>`
      outside a spec literal on the same seam; `t.map(t.u16, Entity)`, `t.map(t.enum(…), t.u8)` and
      `t.map(t.u8, t.union(…))` in `types_ok`; `t.optional(struct)` outside a spec keeps its payload
- [x] `Inbound` dispatch: a raising handler loses its own packet and nothing behind it (M4 finding 32)

### Phase 4 — residue of phase 8

- [ ] `Context.acquire` clears `character` and `humanoid` unconditionally; `live` gets a `__newindex`
      that raises with the guard's message
- [ ] `Protocol.ATTRIBUTES` carries `whole`; `protocol_runtime` changes it alone
- [ ] `t.unitVector3` requires a fractional component whose range covers `[-1, 1]`
- [ ] `t.union`, `t.struct`, `t.enum`: clone-then-freeze the caller's table; refuse a non-string key
      before `sortedKeys`
- [ ] `quantized`, `vectored`, `instance` refuse extra arguments, as their comment says
- [ ] arrays of optionals: an exact length iterates `1..exact` without `#`; a dynamic array of optionals
      is refused at declaration
- [ ] `owner` and `nearby` consult `roster.has`; an end-to-end test runs `forget(alice)` through the real
      `Tick` and asserts `held(alice) == 0` on the next frame
- [ ] the instance writer checks class and `descendantOf`, so `nw.validate` brands what the reader accepts

### Phase 5 — the tick

- [ ] `snapshot` and `moved` walk the schema's fields, not the table; the cycle probe no longer overflows
- [ ] a `select` audience that returns the roster takes the broadcast skip; `bench/tick` gains the rung
- [ ] a client over `baselinesPerClient` is marked as holding the last snapshot; an idle frame sends nothing
- [ ] a coalesced `RESYNC` reports at stage `replicate`, charges `bytes`, and `RESYNC_TICKS` is a
      `Config` limit
- [ ] the tick's calls into store, selector and audience are isolated, so a game raise loses one subject
      and not the frame's flush (M4 finding 20)
- [ ] a change past 16,383 bytes is reported once and the subject advances (M4 finding 24)

### Phase 6 — the suite

- [ ] every failure-path tag re-read; sections that assert a lifecycle or a no-op re-tagged; floors moved
      to the honest share with a strikethrough where they fall
- [ ] `fuzz_runtime`: a fifth invariant, "the packet consumed exactly its declared length"; confirmed to
      go red with `Buffer.span`'s bound deleted
- [ ] `fuzz_runtime` corpus: union, quantised, u53, constrained string, componented vector; sidecar
      contents mutated; server-side `RESYNC`
- [ ] the seven `UNCOVERED` types annotated in `types_ok`; `tools/exports` list emptied
- [ ] the D-5 ceiling and the union bit-fork each pinned by an assertion that fails under its mutation
- [ ] `roblox_runtime` prints `skip` when no player is present; sections for `Driver`, `Link.roblox`, the
      908 limit, a table in the sidecar, `Context.acquire` on a real `Player`
- [ ] the Studio pass run and its console read

### Phase 7 — the record

- [ ] `bench/report.luau`: Down and FireAll columns; framerate p0..p100 and `n`; `correct` and drop rate;
      a missing field is a failure, not a `—`
- [ ] run documents carry the commit they were produced on
- [ ] the Studio ns ladder and the frame probe produced by a committed script; `STUDIO_NOW` and
      `STUDIO_BEFORE` removed from `bench/profile.luau`
- [ ] every probe's `BEFORE` comment names a way to reproduce it that works
- [ ] `bench/envelope.luau` calls `Batch` instead of re-implementing it
- [ ] the matrix run twice on the tree at the end of phase 6; the Down cell's move settled or written as
      unsettled
- [ ] `bench/RESULTS.md` regenerated over the newest run; the M1 tables under the M3 header struck; the
      acceptance table reconciled with its own §2; 31.4 ns → 31.4 µs
- [ ] `bench/` type-checked by `analyze` (the `OutboundScope` type function error in `bench/tick.luau`)

### Phase 8 — the documents

- [ ] `PLAN-M4.md`: the disposition table for both reports; D-2 / phase 2 / phase 4 / phase 6 sentences
      overturned by phase-8 commits struck; acceptance 4, 8, 10, 11 given a status; a Result section
- [ ] `DESIGN-API.md`: §3 sequence number and client `pendingPerBatch` struck; the `table.clone` escape
      corrected to a deep clone; §6 component-wise brands; §7 the `Views<D>` caution; the `replicate` row
- [ ] `WIRE-FORMAT.md`: offset-binary integers; layouts for quantised, u53/i53, componented vectors,
      strings with constraints; §4 lists the hashed attributes and says `descendantOf` is not one
- [ ] the 908 citation, the 39/40 and "9%" numbers, `Batch.luau`'s resync sentence, `Buffer.luau`'s Zap
      claim, the replication pointer-compare docstrings, the `§` citations that do not hold
- [ ] `CLAUDE.md`: the four statements that measure false; §2 layout brought current
- [ ] `SECURITY-REPORT.md` and `SECURITY-REPORT-M4.md`: the statements now wrong, struck
- [ ] `PLAN-M5.md` opened with the non-goals above as its first entries

## 7. Acceptance criteria

1. `analyze` goes red on a `--!nonstrict` header under `src/`, on a luau-lsp that fails to run, and on
   a reject file whose diagnostic moved lines. Each is demonstrated by a mutation in the commit message.
2. `tools/exports` goes red when a covered type's only mention is inside a string.
3. `t.string(0, 65535, { pattern = "(.*)@(.*)%.(.*)" })` is refused at declaration; the worst accepted
   pattern at the default `max` matches a hostile string in under 1 ms (measured, n ≥ 5).
4. Every malformed construct the report lists is refused at declaration; the receive path never raises
   on a declared pattern (added to `fuzz_runtime`'s corpus).
5. A `replicate` snapshot delivered before `:listen` reaches the handler on `drain` with no server
   re-send and no `handler` report.
6. `t.map(t.u16, t.struct({ … }))` analyses clean with the value typed `{ [number]: { … } }`.
7. Every 중대 and 위험 in the M4-1 report is closed with a test confirmed to fail on the pre-fix tree, or
   declined with a sentence in `PLAN-M4`'s disposition table.
8. Every harness floor equals or is under the file's honest failure-path share, and the number in the
   file matches the number in `CLAUDE.md`.
9. Every number in `bench/RESULTS.md` is produced by `bench/report.luau` over a file in `bench/runs/`, or
   by a committed probe whose `BEFORE` can be reproduced by following its own comment.
10. `PLAN-M4.md` has a Result section, and `PLAN-M5.md` names every item in §4 above.

## 8. Risks

- **The pattern rule refuses something a game needs.** A chat filter with two `.*` is plausible.
  Mitigation: the rule is on unbounded items, and the docstring shows the linear spelling (a class
  with an explicit count). If the rule still bites, `charset` in M5 is the escape, not a relaxation.
- **Walking baselines on `drain` delivers a subject the handler has already seen.** Only if a handler was
  attached, detached and re-attached; the test covers the join path and the plan says re-listen is not
  supported.
- **Schema-aware `snapshot` misses a field the codec reads.** The codec and the walk must read the same
  layout; the test compares the walk's key set with the layout's for every schema in the corpus.
- **The honest harness share fails acceptance 11 and the criterion is softened rather than met.**
  That is the intended outcome if the honest share is what it is; D-5 says the strikethrough carries
  the reason, and the phase-6 corpus work adds real failure-path sections before the floor is judged.
- **Studio time.** Phases 6 and 7 need the owner at Studio for a suite pass and two matrix runs. Nothing
  in phases 1 to 5 depends on them, so they wait rather than block.
