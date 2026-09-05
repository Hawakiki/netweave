# PLAN-M4 — L3 replication

## 1. Goal

When M4 is done, netweave replicates *state* rather than only carrying it. A game declares what a
client should see and netweave keeps it there: a joining client gets a snapshot, an existing one
gets only what changed, and a client whose audience membership changes gets the difference between
what it had and what it should now have. The codec and the transport are the ones M1 through M3
built — L3 adds a store, a diff, and a per-client baseline, and nothing else.

It is an **adapter, not a replacement**. Charm and Replica already own the store in real games
(`RESEARCH §4`), and a library that demands they be torn out to get delta compression will not be
adopted. The seam is: the game's state library owns the truth and says when it changed; netweave
owns what each client has and what that costs on the wire.

## 2. Why now

`RESEARCH §3` calls this gap **G4 — event and state replication are separate**, and §1's
"인접 영역" section records why: every surveyed game runs an event library *and* a replication
library, and nothing integrates them. §4 positions netweave as the three layers in one, so L1 and L2
without L3 is two thirds of the argument. M3 was the last milestone that could be spent on something
else.

Three things also make now the right time rather than merely the next slot:

- **`nw.state` is named for a thing it does not do.** It takes a whole value, filters by audience
  and sends it — a `nw.event` with coalescing. It holds nothing, diffs nothing, and knows nothing
  about what a client already has. The name is a promise M4 either keeps or has to rename.
- **M3 built the resource discipline this needs first, and that ordering was luck.** A per-client
  baseline is memory proportional to players times state size, chosen by how many people join. Had
  L3 landed before the budgets, the ceilings and the observer, it would have shipped exactly the
  unbounded growth `PLAN-M3` D-6 exists to prevent.
- **The benchmark cannot yet measure what this milestone changes.** Delta compression is a bytes
  claim and an allocation claim, and phase 9 established that this harness resolves neither on the
  cells that matter. That is the first task, not the last.

## 3. Scope

| Deliverable | Artifact |
|---|---|
| Charm, Replica and DeltaCompress cloned, pinned and read before any claim about them | `_refsrc/`, `_refsrc/README.md`, `docs/RESEARCH-AND-PLAN.md` |
| The per-frame allocation window, ported from the lune probe to Studio | `bench/src/shared/Alloc.luau`, `bench/README.md` |
| A replication axis in the benchmark: snapshot cost, delta cost, and both against a full resend | `bench/src/shared/Modes/`, `bench/RESULTS.md` |
| The diff: a structural delta over the lowered IR, reusing L1's writers | `src/replication/Delta.luau` |
| Per-client baselines, bounded, with what they cost visible | `src/replication/Baseline.luau` |
| The store seam — what an adapter has to provide, and adapters for Charm and Replica | `src/replication/Store.luau`, `src/replication/adapters/` |
| `nw.replicate`, or `nw.state` grown into it — decided in D-1 before anything is written | `src/api/Channel.luau`, `src/netweave.luau` |
| The `ArrayHeavy` framerate gap, measured before it is chased | `src/codec/Serdes.luau`, `bench/RESULTS.md` |
| The adversarial suite extended to the receive half of replication | `tests/hostile_runtime.luau`, `tests/replication_runtime.luau` |

## 4. Non-goals

| Deferred | To |
|---|---|
| Client-side prediction, rollback, or interpolation | never; this is a networking library, not a movement system |
| Interest management beyond the existing `audience` scopes | M5, if a game asks for it |
| Replicating Instances or their properties | never; the sidecar carries references, not state |
| Wally or npm packaging | no path exists — `CLAUDE.md` §8 |
| Encrypting or signing state | never; `PLAN-M3` D-8 |

## 5. Design decisions

Each of these is open. They are written here so the phase that answers one writes the answer beside
the question rather than in a commit message.

### D-1 — is this a new channel class, or `nw.state` growing up?

`nw.state` today is `nw.event` with coalescing and an audience (`src/api/Channel.luau`). Growing it
means every existing declaration silently changes behaviour; a new class means two things named
almost the same. **G6 says direction is a class rather than a field** (`DESIGN-API.md` §3), and the
same argument applies here: if replicated and pushed state behave differently under packet loss,
they must not be the same declaration.

Answer this first. Nothing else in the milestone is independent of it.

### D-2 — a delta assumes a baseline, and `unreliable` does not deliver one

This is the decision the milestone turns on. A delta is only meaningful against the state the
receiver actually has, so a dropped delta leaves that client permanently and silently wrong — which
is the failure mode `RESEARCH §3.7-F` records for the 908-byte limit and §3.8-R for batch death, in
a form no length prefix can rescue.

Three shapes, and the cost of each has to be measured rather than argued:

1. **Deltas are reliable, snapshots are whatever the channel declares.** Simplest, and gives up the
   one thing `unreliable` buys on positional state.
2. **Acknowledged baselines.** The client says what it has; the server diffs against that. Correct
   under loss, and costs an upstream packet per client per tick plus a baseline history — which is
   memory chosen by a client, and therefore `PLAN-M3` D-6 territory.
3. **Periodic snapshots between deltas.** Bounded staleness instead of correctness. Cheap, and the
   staleness window is a number the game has to be told rather than one netweave picks.

### D-3 — what a store adapter has to provide

The narrowest seam that supports Charm and Replica both. Candidate: `read()`, `changed(callback)`,
and nothing else — netweave diffs, so an adapter that can only say *that* something changed is
enough and one that says *what* changed is an optimisation. Verify against both libraries' actual
APIs in `_refsrc/` before committing to it; `CLAUDE.md` §7 says a claim about a competitor is read,
not assumed, and there are currently **no state libraries vendored at all**.

### D-4 — the audience is dynamic, and that is not a diff

`nw.audience.nearby(120)` means membership changes as players move. A client entering the radius
needs a snapshot, not a delta; one leaving needs to be told to forget. So the baseline is per client
*per subject*, and the transitions are their own packets. This is the part Replica and Charm solve
differently and the part a naive diff gets silently wrong.

### D-5 — the framerate gap is measured before it is chased

`PLAN-M3` deferred `ArrayHeavy` framerate (84 against Blink's 130) with the cause narrowed but not
measured: 600 closure calls per packet against generated inline code. §3.10-BB found the allocation
advantage was encode-only, so this is a different axis and needs its own number. **The instrument
comes first** — between the two M3 runs, on unchanged code, Blink's `ArrayHeavy` decode allocation
moved 76% and Zap's 146%. Tuning against that is tuning against noise.

## 6. Tasks

### Phase 0 — the instrument — **done**

- [x] Port the per-frame allocation window into `bench/src/shared/Alloc.luau` — `Alloc.frames`.
      **The port turned into a diagnosis.** The encode probe called `fire` five thousand times back
      to back and never let a frame end, so for a batching library nothing was ever flushed and the
      payloads piled into one outgoing buffer that grows by *doubling*: most calls allocating
      nothing, a handful allocating a block the size of everything before them. The median of
      twenty-five windows over that was a lottery on where the doublings landed. The window is one
      frame now, ending in a yield, so every library's own scheduler flushes inside it.
- [x] Re-run twice on the unchanged tree and show the spread collapsed. **It did, on the column that
      was broken.** Surviving windows 4-8 of 25 → **276-385 of 400**; the `ArrayHeavy` range 16x →
      **0.3%**; the two runs agree to **1.7% or better on every encode cell**.

      The old numbers were **biased high by two to six times**, not merely imprecise. Two
      independent checks say the new ones are right: netweave's 1909.8 B agrees with phase 9's lune
      probe at 1908.4 B to **0.07%**, and `raw` — which serialises nothing — lands exactly on the
      idle control group's 10.24 B, because all that is left in its window is the engine.

      The ranking changed with the precision. M3 read blink 4040 / netweave 3932 / zap 3932 /
      bytenet 3722, four libraries inside 8%, which is a tie, which is noise. What is there is
      bytenet at a third of the field, netweave and zap together, blink 42% behind.
- [x] **An idle control group, which was not in the plan and should have been.** A frame window
      contains a real engine frame, so Studio's own allocation is inside every encode cell. `idle`
      in the run document is a frame that sends nothing, same units, same window count: **10.24 B,
      400/400**, in both runs. `CLAUDE.md` §9's control-group rule, applied to the harness itself.
- [x] ~~The same window on the receive side.~~ **Tried and reverted, with the measurement that
      settled it.** The two costs have opposite shapes: an outgoing buffer is still there at the
      frame boundary and a batch of decoded values is not, because `inbound.receive` decodes,
      dispatches and returns its pending list to the pool before `PostSimulation` runs. One decoded
      `ArrayHeavy` value is **32,097 B** under lune (phase 9's independent probe: 32,048.2 B, 0.15%
      apart); the frame boundary reported **604 B**, out by 53x, against the packet-aligned window's
      ~10,200, out by 3.2x. Both are lower bounds — the discarded windows are the ones the collector
      visited — so the Studio decode column reads "at least this much".
- [x] Record it in `bench/RESULTS.md` — "M4 phase 0: the instrument, rebuilt on the send side",
      including what did not work. `bench/README.md` carries the same for whoever runs it next.
- [ ] **Acceptance 9 is met on three of four columns and stays open on the fourth.** Encode
      `ArrayHeavy` within 1.7%; decode flags identical to the decimal for all five modes; encode
      flags at the **±5.12 B quantisation floor** rather than inside 10%, which no arrangement of
      windows improves on because `collectgarbage("count")` reports kilobytes. Decode `ArrayHeavy`
      moves 13-17% — far better than the M3 instrument's 76% and 146%, still outside the bar. A
      window big enough to hold an `ArrayHeavy` batch is one the collector almost always visits, and
      Roblox exposes enough to detect that and not enough to correct for it. **Carried to phase 7**,
      which is the only phase that needs that cell.

### Phase 1 — read the neighbours

- [ ] Clone Charm, Replica/ReplicaService and DeltaCompress into `_refsrc/`, pinned by commit in `_refsrc/README.md`.
- [ ] Read each one's store API, change signal and delta format. Append to `RESEARCH-AND-PLAN.md` §1 in the same shape as the event libraries, with file and line citations.
- [ ] Answer **D-3** in writing, against what they actually expose.

### Phase 2 — the decisions that gate the code

- [ ] Answer **D-1** in `DESIGN-API.md`. Nothing is written until this is decided.
- [ ] Answer **D-2** with a measurement, not a preference: implement the reliable-delta shape, measure it, then measure at least one alternative against it.
- [ ] Answer **D-4** with a probe — a subject moving in and out of a `nearby` audience while its state changes, asserting the client's view is correct at every step.

### Phase 3 — the diff

- [ ] `Delta.luau`: a structural diff over the lowered IR, emitting through L1's existing writers. A field that did not change costs its flag bit and nothing else.
- [ ] Deletion needs a sentinel the schema cannot produce — Charm Sync uses a `__none` marker; netweave has a flag scope and should not need a magic value. Decide and write down which.
- [ ] `ir_runtime`-style property test: for every schema in the ceiling suite, `apply(baseline, diff(baseline, next))` equals `next`.

### Phase 4 — baselines, bounded

- [ ] `Baseline.luau`: what each client has, per subject.
- [ ] A declared limit on it, in `Config`, in the same shape as `queueCapacity` — and a refusal that reports rather than grows.
- [ ] `forget` on disconnect, tested the way the M3 queue drop was: interleaved subjects, one player leaves, assert nothing of theirs survives.

### Phase 5 — the seam and the adapters

- [ ] `Store.luau` — the interface D-3 answered.
- [ ] An adapter for Charm and one for Replica, each with a runtime test that replicates a real change through the real library.
- [ ] The worked example in `DESIGN-API.md` gains a replication half, and `tools/messages.luau` checks it the way it checks the existing one.

### Phase 6 — the hostile half

- [ ] A client cannot make the server hold a baseline it did not ask for.
- [ ] A malformed or replayed delta is refused per packet, at a stage of its own, and the batch survives — G4 and G5 as they apply here.
- [ ] `fuzz_runtime` mutates deltas as well as packets, with the same "nothing vanishes" invariant.

### Phase 7 — the framerate gap

- [ ] Measure it on the fixed instrument: where do the 600 closure calls per `ArrayHeavy` packet actually go?
- [ ] Decide against the number, not the intuition. `PLAN-M1` criterion 5 asks for 1.3x of the best library; 84 against 130 is 1.55x.

## 7. Acceptance criteria

1. A client joining mid-session receives a snapshot and is correct on the first frame it renders — asserted against a subject whose state changed while that client was absent.
2. A field that did not change costs its flag bit and no payload bytes. Measured on a struct where one of twelve fields moves.
3. `apply(baseline, diff(baseline, next))` equals `next` as a property over the same sixteen schemas `ir_runtime` uses for the ceiling.
4. A player entering a `nearby` audience gets a snapshot; one leaving is told once and costs nothing thereafter. Both asserted with the subject moving, not with the audience swapped by hand.
5. Baselines are bounded by a declared limit, and passing it reports rather than grows.
6. A disconnecting player leaves no baseline behind. Asserted the way `PLAN-M3` asserted queued packets: interleaved subjects, one departure, nothing of theirs survives.
7. No delta a client can send reaches `error()`, and one bad delta does not stop the batch.
8. Replicating a changing struct costs fewer bytes than resending it, measured, with the crossover point recorded — if there is a size below which the diff loses, that number is the finding.
9. **The allocation column is reproducible.** Two runs of the unchanged tree agree within 10% on every cell, netweave's and every competitor's. Against the M3 instrument this fails by 76% and 146%.
10. `stylua --check`, `selene`, `lune run analyze`, every `*_runtime`, `tools/messages`, `bench/check` and `bench/envelope` pass, and the Studio suite is run and green before the milestone closes.
11. Failure-path assertions outnumber success-path assertions in `replication_runtime`, enforced by the harness floor.

## 8. Risks

**The adapter seam is wrong and both adapters end up reaching around it.** D-3 is answered from
reading two libraries, and two is a small sample. Mitigation: the adapters are written in the same
phase as the seam, and an adapter that needs a hole punched in the interface is the interface being
wrong rather than the adapter being special.

**Delta compression loses to full resend at the sizes real games use.** A twelve-field struct where
one field moves is the good case; a positional update where everything moves every tick is the
common one, and there the diff is overhead. Mitigation: acceptance 8 measures the crossover instead
of assuming a win, and a crossover that says "resend below N bytes" is a finding to ship, not a
failure to hide.

**D-2 has no cheap correct answer and the milestone stalls on it.** Mitigation: phase 2 implements
the simplest shape first — reliable deltas — so there is a working system to measure alternatives
against, and the answer is a comparison rather than an argument.

**The state libraries have moved and `_refsrc/` is a snapshot.** ReplicaService in particular has a
v1/v2 split. Mitigation: pin by commit in `_refsrc/README.md` like every other vendored source, and
state the version in every claim.

**`nw.state` growing into replication breaks games that used it as a push channel.** Nothing is
shipped yet, so the cost is documentation rather than migration — but the decision still has to be
made before the code, which is why D-1 gates phase 2.
