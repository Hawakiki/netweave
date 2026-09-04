# PLAN-M3 — security and reliability

## 1. Goal

When M3 is done, netweave's receive path is hostile-input-complete: nothing a client can send —
malformed, oversized, replayed, mistimed, or merely expensive — can throw, hang, exhaust memory,
or take down another player's traffic, and every refusal is visible without the game having asked
for it. `query` gains the timeout that Blink and Zap do not have. The declaration surface stops
being something a user has to memorise correctly to stay safe: the failures that M1 and M2 made
type errors get error *messages* that name the fix.

The bar is not "we added checks". It is that the failure-path tests outnumber the success-path
tests, because a security layer has one way to succeed and many ways to fail, and a suite that
does not reflect that ratio has not tested the layer.

## 2. Why now

M2 made the budget real and observable but left five things open, and its own phase audits found
four more that are live in `develop` today.

- **The budget is enforced but not policed.** M2's non-goals defer adaptive limits and what to do
  about a player who keeps overrunning. A budget with no consequence is a metric.
- **Observable is not observed.** `nw.observe` is opt-in, so a game that attaches nothing gets
  silent drops at every stage M2 added. That is the exact failure `RESEARCH §3.7-K` criticises
  Warp for, reproduced by building the signal and not raising it. It is M2's own admission in its
  non-goals.
- **`query` is a hole with a promise in it.** `src/transport/Driver.luau:120` returns
  `nil, "netweave queries land in M3"`. `RESEARCH §3.7-G` is why it was left a hole rather than
  shipped without a timeout.
- **Four defects survived M2's audits and were found by writing this plan's verification lists as
  probes.** They are in phase 0 and they come first.
- **The benchmark handed M3 a resource limit.** `bench/RESULTS.md` "M2: the stand-in replaced by
  the real transport" measures `ArrayHeavy` decode allocation at 9309.2 B per packet against
  1184.8 B behind the stand-in — 200 decoded values held live because `Inbound` reads a whole batch
  before dispatching any of it. Correct, deliberate, and sized by an untrusted client.

## 3. Scope

| Deliverable | Artifact |
|---|---|
| Policies that cannot throw, cannot fail open, and cannot return a shrug | `src/transport/Inbound.luau` |
| Token-bucket rate limiting with a declared burst | `src/transport/Budget.luau` |
| Decode-work accounting: a per-tick cap, and a claim that costs nothing until it is paid for | `src/codec/Serdes.luau`, `src/transport/Inbound.luau` |
| A bound on what one batch may hold live before dispatch | `src/transport/Inbound.luau` |
| Per-channel `maxBytes`, and a total-element bound that nesting cannot evade | `src/api/Channel.luau`, `src/codec/Ir.luau` |
| Counters, an immutable snapshot, and a default sink that warns | `src/api/Observer.luau`, `src/api/Diagnostics.luau` |
| Global settings: severities per rule, limits, an immutable snapshot | `src/api/Config.luau` — **landed early**, see D-11 |
| `query`: varint call ids, a pending table, a declared timeout, cancellation on disconnect | `src/transport/Query.luau`, `src/transport/Driver.luau` |
| A protocol hash over types, not only names, checked at join | `src/api/Protocol.luau` |
| The adversarial suite, with the failure/success ratio measured and asserted | `tests/hostile_runtime.luau`, `tests/fuzz_runtime.luau` |
| Error messages that name the fix rather than the rule | every `error(` in `src/api/` |
| The verification rules, promoted to repository policy | `CLAUDE.md` §9 |

## 4. Non-goals

| Deferred | To |
|---|---|
| Delta state replication, the L3 adapter | M4 |
| **The `ArrayHeavy` framerate gap** — 86 against Blink's 132, `PLAN-M1` criterion 5 | M4 |
| Encrypting or signing payloads | never; see D-8 |
| Server-side authoritative movement, anti-cheat heuristics | out of scope for a networking library |
| Bans, kicks, or any moderation action | M3 reports and refuses; the game decides |

**On the `ArrayHeavy` gap.** M2 isolated it and M3 must not chase it. It measured 85 behind the
stand-in and 86 with the full transport, so it is the codec's array decode and no transport work
will move it. `RESEARCH §3.8-S`'s table-rehash fix is already applied — `structReader` clones a
pre-sized template — so the remaining cost is 600 closure calls per `ArrayHeavy` packet against
generated inline code, which is a different axis from `§3.10-BB`'s encode-only finding and needs
its own measurement before anyone tries to fix it. Recording it here so M3 does not absorb it.

## 5. Design decisions

### D-1 — A policy is game code, and game code is not trusted with the batch

`RESEARCH §3.8-R` says a validation failure must not kill a batch, and M2 applied that to peer data
and to handlers. It did not apply it to `authorize`. A policy that throws currently takes every
remaining packet in the batch, including other players'. That turns the authorization layer into a
denial-of-service surface: find one input that trips a game's policy, and every packet batched
behind it dies.

Every policy call is wrapped, and a policy that throws is a **refusal**, reported at stage
`"authorize"` with the raised message as the reason.

### D-2 — A verdict is `== true` or it is a refusal

Not truthy. `nil`, `false`, `0`, `{}` and a table missing `ok` all refuse. A policy that returns
nothing is a policy someone forgot to finish, and the safe reading of an unfinished policy is
"no". This is the one place in netweave where a shrug must not mean yes.

### D-3 — Token bucket, with the burst declared

A fixed window admits `2n` across a window boundary. Measured, on the current code: a channel
declared `rate = 20` admitted **40 packets inside a sliding 1.0 s span**. A game that declares 20
gets 40 and has no way to know.

`rate` becomes the sustained rate and `burst` the bucket depth, defaulting to `rate`. `RESEARCH
§3.7-K` is the reason the budget exists at all; this is the reason the shape of it matters.

### D-4 — A claim is not paid for until it is honoured

`arrayReader` allocates `table.create(count)` from the wire's claimed count before reading a single
element. Measured: a **2-byte** packet claiming 65535 elements costs **0.173 ms** against 0.0003 ms
for an honest 3-byte packet — 690x, and the packet is correctly *rejected* immediately afterwards.
The rejection is free; the allocation is not.

A source comment on that line currently reads "the length was already bounded, so this is a cost
question, not a safety one". **That is wrong and is struck through in this plan.** A cost an
attacker controls and does not pay for is an amplification. The reader grows as it reads, and no
claim buys memory before the bytes behind it exist.

### D-5 — Decode work is a budget, in the same accounting as bytes

`rate` counts packets and `maxBytes` counts bytes, and neither bounds work: a 5-byte packet can
cost as much as a 900-byte one (D-4). A per-tick decode-work ceiling is charged per element read
and per table allocated, refusing at stage `"budget"` when it is exhausted. This is the only limit
that bounds the nested-array case — `t.array(t.array(t.u8))` — without inventing a rule about
nesting depth.

### D-6 — Read-then-dispatch stays, and gains a ceiling

`PLAN-M2` phase 3 made the read phase complete before dispatch because a yielding handler plus a
global decode cursor attributes one player's bytes to another. That is not negotiable and is not
being revisited. What changes is that the pending set is bounded: past the ceiling the batch stops
and the remainder is refused at stage `"queue"`, which is the same shape as M2's ring buffer and
the same shape `RESEARCH §3.7-H` credits Zap for.

### D-7 — The protocol hash covers types

Currently it covers channel names only, so changing `t.u8` to `t.u16` on a field leaves the hash
**identical**: a stale client connects successfully and is then refused on every packet, forever,
with no diagnosis. Hashing the lowered IR makes that a single, legible failure at join.

### D-8 — netweave does not encrypt, and says so

Roblox terminates TLS at the platform edge and the client is the attacker's machine. Anything
netweave encrypted would be decryptable by the client that holds the key. The trust boundary is
"the server does not believe the client", not "the wire is private". Stating it is part of the
milestone, because a security milestone that stays silent about what it does not do invites the
assumption that it does.

### D-9 — `Untrusted<T>` stays a subtype — **needs the owner's confirmation**

The shared plan asks that `Untrusted<T>`'s fields be *inaccessible*. `docs/DESIGN-API.md` §6 chose
the opposite deliberately: the brand is a subtype, so logging, arithmetic and comparison work
without ceremony, and the wrapper alternative was rejected because it lies about the runtime value
— there is no wrapper at runtime, and a type that claims otherwise makes every `print` a puzzle.

Making access impossible requires that wrapper. **The recommendation is to keep §6** and get the
guarantee from D-2 and the validation boundary instead: what must be impossible is *acting* on
untrusted data, not *reading* it. If the owner prefers the stricter reading, §6 is what changes,
and it changes before phase 3 starts rather than during it.

### D-10 — Failure paths outnumber success paths, and the ratio is asserted

The shared plan's closing rule, adopted. It is not rhetoric here: measured on the current suite,
`transport_runtime` is at 14% failure-path assertions and `ir_runtime` at 13%. A rule nobody counts
is a rule nobody keeps, so phase 6 lands a counter and the acceptance criteria name a number.


### D-11 — Settings are ESLint-shaped, and a severity cannot reach enforcement

Landed ahead of the rest of this milestone, because phase 1 needs somewhere for "how loud is this"
to live and inventing that later would have meant changing the sink twice.

`nw.configure` takes `rules` (severities) and `limits` (numbers) and the two cannot cross. A
severity governs netweave's own console output and nothing else: a packet refused at `budget` is
refused whatever `budget` is set to, and callbacks attached with `nw.observe` receive every
rejection regardless of any setting.

The reason to nail that down in a design decision rather than in a docstring is the failure mode.
A linter's `off` is safe because a linter only ever reports. If `off` here had meant "stop
refusing", then a config block copied off a forum post would be a supported way to delete G1
through G6 from a game whose author never read it — and it would look like tuning.
`Config.raises(rule)` answers `false` for every wire rule at every severity, so the rule is a
function rather than a convention, and `tests/config_runtime.luau` asserts it for all six stages at
`"error"`.

The one rule that raises is `rateUnbounded`, which fires on the game's own declaration rather than
on wire data. It is also the only rule in the ESLint sense — legal, and probably a mistake — and it
exists because `rate = 1e6` satisfies G2 on paper while admitting everything the platform can
deliver. The benchmark declares exactly that and turns the rule off immediately above the
declaration, which is the shape the rule exists to produce: a considered exception, written down.

**What this does not do yet.** The counters in phase 1 are not built; `nw.config.snapshot()` reports
settings, not rejection totals. `nw.diagnostics()` remains phase 1's.
## 6. Tasks

### Phase 0 — the five defects that were live in this tree — **done**

- [x] `authorize` is called through `xpcall`; a raise becomes a refusal at stage `"authorize"`
      carrying the message, and the batch continues (D-1)
- [x] The dispatch loop is isolated per packet — by wrapping the two call sites that reach game
      code rather than the loop itself. Everything else in it is netweave's own, and an `xpcall`
      per packet around code that cannot legitimately raise is a cost with no guarantee attached
- [x] A verdict is accepted only on an explicit `ok == true`; `nil`, `false`, numbers, `{}`, a
      table with no `ok`, and a truthy non-`true` `ok` all refuse (D-2)
- [x] `Budget` becomes a token bucket; `burst` is declarable, defaults to `rate`, is forbidden on
      the outbound classes beside `rate`, and is refused below `rate` (D-3)
- [x] No claimed count allocates ahead of the bytes that justify it (D-4). A static element gives
      an exact bound; a dynamic one caps the allocation at the bytes remaining. `mapReader` never
      had the bug — it grows from `{}` — and takes the bound anyway so the refusal reads the same.
      The "cost question, not a safety one" comment is struck through in place
- [x] Each gets a test **run against the pre-fix code and confirmed to fail there**: 14 failing
      assertions in `transport_runtime`, 4 in `budget_runtime`, 2 in `serdes_runtime`
- [x] **A raising policy also leaked the context.** `Context.release` was reached only on the paths
      that returned normally, so a `ctx` retained from the raising packet stayed valid into the
      next one — M2 phase 3's wrong-player attribution, reintroduced one packet at a time by an
      exception path, and invisible in production because the guard is Studio-only

### Phase 1 — observability that is on by default

- [ ] `Observer` keeps counters per channel per stage, not only the live callback
- [x] An immutable snapshot exists as `nw.config.snapshot()` — frozen at every level, and a second
      call is a second table so two diagnostic screens cannot share a moment
- [ ] `nw.diagnostics()` returns the same for the *counters*; mutating it does not touch them
- [x] A default sink warns on the first refusal of each `(channel, stage)` pair, with the reason.
      Silence is opt-in, not default — `src/api/Observer.luau`, and `DESIGN-API.md` §9.1 carries the
      strikethrough
- [ ] A `"protocol"` stage for handshake refusals (phase 5 fills it)
- [x] Rate-limit the default sink itself — the thing that reports a flood must not become one.
      Three per `(channel, stage)`, then a line saying so; `limits.repeatsPerDiagnostic` moves it

### Phase 2 — resource limits

- [ ] Per-channel `maxBytes`, enforced before decode, refused at stage `"budget"`
- [ ] A per-tick decode-work ceiling, charged per element and per table (D-5)
- [ ] The nested-array case has a test: `t.array(t.array(t.u8))` cannot cost more than the ceiling
      however the nesting is arranged
- [ ] `Inbound`'s pending set is bounded; past the ceiling the batch stops and the remainder is
      refused at stage `"queue"` (D-6)
- [ ] Re-measure `ArrayHeavy` decode allocation against the M2 figure of 9309.2 B and record both

### Phase 3 — the trust boundary, decided

- [ ] **Resolve D-9 first.** Either `docs/DESIGN-API.md` §6 gets a strikethrough and a wrapper, or
      this plan's D-9 stands. Nothing else in this phase starts until it is settled
- [ ] `Trusted<T>` is producible only where the value has actually been validated, and the
      producers are enumerated in one place
- [ ] `nw.validate` reconciled — the shared plan says `nw.validate(policy)`, the implementation is
      `nw.validate(schema, value)`. Pick one, write it in `DESIGN-API.md`, and make the other a
      type error
- [ ] A `*_reject.luau` case per producer, with the diagnostic count updated in the header

### Phase 4 — `query`, with the timeout the field does not have

- [ ] `src/transport/Query.luau`: varint call ids, so there is no 256 ceiling (`RESEARCH §3.7-G`)
- [ ] A declared timeout per channel, required, with no unlimited option — the same shape as `rate`
- [ ] A timed-out call resolves as a failure value, never a hung thread
- [ ] Every pending call for a leaving player is cancelled in `PlayerRemoving`, alongside M2's
      three existing forgets
- [ ] The reply path is a channel like any other: budgeted, observed, and unable to throw
- [ ] Reconcile the failure shape — `invoke` currently returns `(R?, string?)` and the shared plan
      forbids `nil` as failure. Decide, and write it into `DESIGN-API.md` §7
- [ ] Delete the hole at `Driver.luau:120` and the comment that promises this milestone

### Phase 5 — the protocol handshake

- [ ] The hash covers the lowered IR, not channel names (D-7)
- [ ] A test that changes exactly one field's type and asserts the hash **moves** — the current
      behaviour is that it does not
- [ ] Mismatch is refused at stage `"protocol"` with both hashes in the reason
- [ ] The check happens once at join, not per packet

### Phase 6 — the adversarial suite

- [ ] `tests/hostile_runtime.luau`: every refusal path in `Batch`, `Inbound`, `Budget` and the
      readers, driven by crafted bytes rather than by API calls
- [ ] `tests/fuzz_runtime.luau`: structured mutation of valid batches — bit flips, truncation,
      length and count corruption, id substitution, sidecar overstatement, replayed frames
- [ ] The invariant is uniform: **the receive path never throws, and never loses a packet it did
      not report losing**
- [ ] A harness counter reports failure-path against success-path assertions per file, and the
      suite fails when a security-relevant file falls under parity (D-10)

### Phase 7 — the learning curve

- [ ] Every `error(` in `src/api/` names the fix, not the rule: what was written, what was
      expected, and the one line that repairs it
- [ ] The M1/M2 `type function` errors get the same treatment — they surface verbatim at the call
      site, which is exactly where a beginner reads them
- [ ] `docs/DESIGN-API.md` gains a "the whole surface on one page" table: six classes, what each
      requires, and the one thing each forbids
- [ ] One worked example that declares, sends, authorizes, refuses and observes — under 60 lines,
      and executed by the test suite so it cannot rot

### Phase 8 — repository policy

- [ ] `CLAUDE.md` §9: the verification rules. Failure paths outnumber success paths; a regression
      test is confirmed to fail against the pre-fix code; no security claim without a probe that
      demonstrates the defect it prevents

## 7. Acceptance criteria

1. A policy that raises refuses that one packet at stage `"authorize"` with the raised message, and
   every other packet in the same batch is delivered. Demonstrated with 3 packets, 1 throwing, 2
   delivered — against today's code the number delivered is **0**.
2. A policy returning `nil`, `false`, `{}` or `{ ok = "yes" }` refuses. None of the four throws.
3. A channel declared `rate = 20` admits at most 20 in **any** sliding 1.0 s window, not merely in
   an aligned one. Against today's code the measured figure is 40.
4. A 2-byte packet claiming 65535 elements costs within 2x of an honest 3-byte packet. Today it
   costs 690x.
5. Any nesting of bounded arrays reaching the per-tick decode ceiling refuses at stage `"budget"`
   rather than completing.
6. `ArrayHeavy` decode allocation per packet is reported against the M2 baseline of 9309.2 B in
   `bench/RESULTS.md`, whether it moved or not.
7. A game that attaches no observer sees a warning on the first refusal of each channel and stage,
   and does not see a second for the same pair.
8. `nw.diagnostics()` returns a snapshot that cannot be mutated into the live counters.
9. A `query` whose peer never answers resolves as a failure within its declared timeout. No thread
   is left suspended, and the pending entry is gone. Call ids pass 256 without collision.
10. Changing one field from `t.u8` to `t.u16` changes the protocol hash. A client on the old hash
    is refused once at stage `"protocol"`, not once per packet.
11. The fuzz suite runs at least 10,000 mutated batches with **zero** raises off the receive path
    and zero unreported losses.
12. Failure-path assertions outnumber success-path assertions in `transport_runtime`,
    `budget_runtime`, `hostile_runtime` and `fuzz_runtime`. The counter is in the harness and the
    suite enforces it.
13. Every `error(` reachable from `src/api/` names what was written and what to write instead. A
    test greps for the ones that do not.
14. `stylua --check`, `selene`, `lune run analyze`, every `*_runtime`, `lune run bench/check` and
    `lune run bench/envelope` pass.

## 8. Risks

**The security work makes the library slower, and the benchmark is the argument.**
Token buckets, decode-work accounting and per-packet `xpcall` are all costs on the hot path, and
M2's `ArrayHeavy` cell has no headroom to give. Mitigation: phase 2 re-measures against a recorded
baseline and `bench/RESULTS.md` reports the delta whichever way it goes. A security milestone that
quietly costs 30% of throughput and does not say so is the same dishonesty as a benchmark that
hides a drop rate.

**`xpcall` per policy call allocates.** Luau's `xpcall` is cheaper than `pcall` with a closure but
it is not free, and `CLAUDE.md` §4 says hot paths allocate nothing. Mitigation: the handler is a
module-level function rather than a per-call closure, and phase 0 measures the cost before and
after on the flag schemas, where the per-packet overhead is visible against an 81.92 B encode.

**D-9 is a design fork that could invalidate phase 3 mid-flight.** Mitigation: it is the first task
in the phase and nothing else starts until it is answered, in `DESIGN-API.md`, in writing.

**The fuzz suite finds something the wire format cannot fix.** If a mutation class requires a
format change, `docs/WIRE-FORMAT.md` says v1 is frozen. Mitigation: a v2 is allowed and the version
byte exists precisely for it — but it is a milestone boundary decision, recorded in
`WIRE-FORMAT.md` with the case that forced it, not a quiet bump.

**The failure/success ratio becomes a number people game.** Writing four trivial rejection tests
raises the ratio and tests nothing. Mitigation: the ratio is a floor, not the goal, and the
adversarial suite is reviewed for whether each case corresponds to a byte sequence a client can
actually produce.
