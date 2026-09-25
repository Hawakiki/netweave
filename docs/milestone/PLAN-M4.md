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
| **`nw.replicate`** — a seventh class, decided in D-1 and written up in `DESIGN-API.md` §3 | `src/api/Channel.luau`, `src/netweave.luau` |
| The `ArrayHeavy` framerate gap, measured before it is chased | `src/codec/Serdes.luau`, `bench/RESULTS.md` |
| The adversarial suite extended to the receive half of replication | `tests/hostile_runtime.luau`, `tests/replication_runtime.luau` |

## 4. Non-goals

| Deferred | To |
|---|---|
| Client-side prediction, rollback, or interpolation | never; this is a networking library, not a movement system |
| Acknowledged baselines, and periodic snapshots between deltas | never; D-2 found both answer a loss the reliable path does not have |
| Interest management beyond the existing `audience` scopes | M5, if a game asks for it |
| Replicating Instances or their properties | never; the sidecar carries references, not state |
| Wally or npm packaging | no path exists — `CLAUDE.md` §8 |
| Encrypting or signing state | never; `PLAN-M3` D-8 |

## 5. Design decisions

Each of these is open. They are written here so the phase that answers one writes the answer beside
the question rather than in a commit message.

### D-1 — is this a new channel class, or `nw.state` growing up? — **answered in phase 2**

**A seventh class, `nw.replicate`.** Written up in `DESIGN-API.md` §3, "Replication is a seventh
class, not `state` growing up". Three independent reasons, the plainest first:

- **They have no method in common.** `nw.state` is `publish(subject, value)`; `nw.replicate` takes
  a store at declaration and the game never calls netweave again.
- **They sit on opposite sides of the reliability trade.** A dropped `state` packet costs one tick
  and the next corrects it, which is why `unreliable` belongs there. A dropped delta leaves that
  client wrong forever, so `unreliable` is **forbidden** on `replicate` — and one class with a flag
  meaning "fine" or "silently wrong forever" depending on its value is the exact shape this design
  exists to make unwritable.
- **They cost different server memory.** One coalesced value released at the tick, against a
  baseline per client per subject held for the session — `PLAN-M3` D-6 territory, needing a declared
  ceiling `state` has no use for.

~~`nw.state` is named for a thing it does not do.~~ **This plan was unfair to it.** "State" means
the current state of a subject sent to whoever should see it, which is what it does; it never
promised delta compression. What was missing was a docstring saying which of the two it is, not a
rename.

### D-2 — a delta assumes a baseline, and `unreliable` does not deliver one — **answered in phase 2**

~~Three shapes, and the cost of each has to be measured rather than argued: deltas are reliable /
acknowledged baselines / periodic snapshots between deltas.~~ **The question was posed wrong.** All
three are answers to loss on the reliable path, and netweave's reliable path is a `RemoteEvent`,
which Roblox delivers reliably and in order. A delta netweave hands to the engine arrives.
Acknowledgements and periodic re-snapshots buy nothing and cost exactly what `PLAN-M3` spent a
milestone bounding — an upstream packet per client per tick, a baseline history sized by a client.

~~**What can drop a delta is netweave.** `pendingPerBatch` drops the tail of an oversized batch and
reports it; on a `signal` that is one lost packet, and on a `replicate` it is a client that will
never be right again. So: **reliable deltas, plus a break detector** — a sequence per client per
subject, and a client that sees a gap gets a snapshot instead of another delta.~~ **Both halves were
overturned in phase 8 and this decision was left saying them (M4-1).** 7df2228 made the ceiling
server-only, because a batch's size is chosen by an untrusted peer only when the peer is a client, so
nothing netweave-side drops a delivered change; phase 4 struck the sequence number. What remains is
reliable deltas plus the client's own refusal: a change it cannot read makes it give up the channel
and ask for everything again (`WIRE-FORMAT.md` §2).

`unreliable` is forbidden on the class rather than merely discouraged (D-1). A game that wants
lossy positional updates already has `nw.state`, un-delta'd, and that is why the two classes exist.

### D-3 — what a store adapter has to provide — **answered in phase 1**

~~The narrowest seam that supports Charm and Replica both. Candidate: `read()`, `changed(callback)`,
and nothing else — netweave diffs, so an adapter that can only say *that* something changed is
enough and one that says *what* changed is an optimisation.~~

**The candidate was wrong, and wrong in a way that changes the milestone's framing.** Both libraries
are now in `_refsrc/` and read (`RESEARCH §1`, "실제로 읽고 나서"); neither wants that shape:

- **Charm Sync already diffs.** `patch.diff` is a recursive structural diff
  (`charm/packages/charm-sync/src/patch.luau:59-89`) and the server seam is
  `addSignalsToClient(client, { key = atom })` plus `connect(onSync)`
  (`src/server.luau:284, 381`). What it wants from netweave is `onSync` — **a transport**, not a
  diff engine.
- **ReplicaService does not diff at all.** The game declares the mutation by name — `SetValue`,
  `SetValues`, `ArrayInsert`, `ArraySet`, `ArrayRemove`, `Write`
  (`ReplicaService/src/ServerScriptService/ReplicaService.lua:403-528`) — and each fires its own
  RemoteEvent **once per player** (`:416`). What it wants from netweave is the six RemoteEvents,
  batched.

So the seam is lower than the plan assumed: **netweave is the transport a replication library
plugs into**, and `Store.luau` describes what netweave needs in order to carry somebody else's
patches, not what netweave needs in order to compute them. Two functions:

- `changes() -> Patch?` — pull what has changed since the last call, or nil. Charm's adapter drives
  this from `connect(onSync)`; Replica's builds one from the mutation calls.
- `snapshot() -> State` — the whole thing, for a client that has no baseline.

netweave still owns the **baseline** (D-4 needs per-client-per-subject state that neither library
has) and still owns the **encoding**, which is where the argument is.

#### The byte case, which phase 1 also settled

`delta-compress` writes a **type tag per value** — twenty-one ids covering both datatypes and diff
operations (`delta-compress/src/TypeId.luau:3-22`) — because it has no schema and cannot do
otherwise. netweave does have one. A patch of a twelve-field struct is **a twelve-bit field saying
which moved, then the moved values in schema order**: field identity is a position, not a
serialised key. That is the whole reason L3 belongs in this library rather than beside it.

Two consequences, both of which close open questions elsewhere in this plan:

- **The deletion sentinel question in phase 3 is closed.** Charm needs `None = { __none = "__none" }`
  (`patch.luau:10`) because it travels over Roblox's default serialisation, where `nil` is
  indistinguishable from absent. netweave has flag scopes; "removed" is one bit. No magic value.
- **A patch has a different shape from the state, and that is the real work.** The codec is schema
  driven and the schema describes `PlayerState`, not a *patch of* `PlayerState`. `Ir` has to derive
  a patch layout from a state layout — every field optional, plus a removal bit — which is
  machinery it already has in the optional/flag path. Without that step a patch is an opaque
  payload and the byte case above evaporates.

### D-4 — the audience is dynamic, and that is not a diff — **design answered in phase 2, probe in phase 4**

`nw.audience.nearby(120)` means membership changes as players move. A client entering the radius
needs a snapshot, not a delta; one leaving needs to be told to forget. So the baseline is per client
*per subject*, and the transitions are their own packets. This is the part Replica and Charm solve
differently and the part a naive diff gets silently wrong.

**D-2's break detector already covers it.** A client entering an audience has no baseline, which is
the same condition as a sequence gap, so one mechanism — "you are out of sync, here is everything" —
serves a join, a netweave-side drop and an audience transition alike. A client leaving needs its
baseline dropped, which is the same code as a disconnect.

The probe the plan asked for here needs baselines to exist, so it moves to phase 4 rather than being
written against nothing.

### D-5 — the framerate gap is measured before it is chased — **answered in phase 7**

`PLAN-M3` deferred `ArrayHeavy` framerate (84 against Blink's 130) with the cause narrowed but not
measured: 600 closure calls per packet against generated inline code. §3.10-BB found the allocation
advantage was encode-only, so this is a different axis and needs its own number. **The instrument
comes first** — between the two M3 runs, on unchanged code, Blink's `ArrayHeavy` decode allocation
moved 76% and Zap's 146%. Tuning against that is tuning against noise.

**Answered, and the instrument earned its place first.** `bench/profile.luau` (§3.11) takes the
encode apart in rungs that differ by one thing each, and three things came out of it that the
framerate alone could not have said:

- The frame gap **is** the encode gap. The codec predicted 4.38 ms against generated code; Studio
  measured 4.21 ms. Nothing outside `Serdes` needed looking at.
- The cause M1 wrote down was **already falsified by M2's own matrix** and `bench/RESULTS.md` had
  repeated it for two milestones. Priced properly it was 45-47% of the *pre-M2* encode — real, and
  never capable of explaining 1.55x.
- The cause that was actually there is half closure-per-value and half something nobody had named:
  **a builtin called by name compiles to a fastcall and the same function fetched from a table does
  not** (§3.11-GG). One table lookup moved to build time is worth 1.6x on the whole packet.

The answer is `Serdes.fusedStructWriter` — one claim per struct, offsets computed at declaration,
unrolled to eight fields, every primitive named. 1.9x under lune and 1.31x in Studio, both measured.

~~1.28x of Blink predicted against criterion 5's 1.30x bar, and the Studio run is what settles it.~~
**The Studio run settled it the other way: 85 FPS against 133, 1.56x, unmoved.** So D-5's own
instruction — the gap is measured before it is chased — was followed on the *component* and skipped
on the *frame*: a probe that takes one packet apart can prove the codec got faster and say nothing
about the frame it lives in. The fourth question this phase should have asked, and did not, is what
else is in that frame.

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
- [x] **Acceptance 9 is met on three of four columns and stays open on the fourth.** Encode
      `ArrayHeavy` within 1.7%; decode flags identical to the decimal for all five modes; encode
      flags at the **±5.12 B quantisation floor** rather than inside 10%, which no arrangement of
      windows improves on because `collectgarbage("count")` reports kilobytes. Decode `ArrayHeavy`
      moves 13-17% — far better than the M3 instrument's 76% and 146%, still outside the bar. A
      window big enough to hold an `ArrayHeavy` batch is one the collector almost always visits, and
      Roblox exposes enough to detect that and not enough to correct for it. **Carried to phase 7**,
      which is the only phase that needs that cell. **Closed at `PLAN-M4-BUG` phase 7 with the same
      verdict**: run a → run b, decode `ArrayHeavy` 25-85% for the competitors and 4.8% for netweave;
      not met as written, and the §7 status table says so.

### Phase 1 — read the neighbours — **done**

- [x] Charm `b05f3a9` (charm-v0.11.0), ReplicaService `aaeb1c6`, delta-compress `46f0831`, cloned and
      pinned in `_refsrc/README.md`. There were **no state libraries vendored at all** before this.
- [x] Read each one's store API, change signal and delta format. `RESEARCH §1` gains
      "실제로 읽고 나서", with file and line citations in the same shape as the event libraries.

      **The first correction is that they are not one category.** Charm Sync holds state and diffs
      it itself; ReplicaService holds state and has no diff, because the game names the mutation;
      delta-compress holds nothing and only diffs. The roadmap's one line treated all three as
      "복제 라이브러리".
- [x] Answer **D-3** — see above. The candidate seam was wrong, and the milestone's framing moved
      with it: **netweave is the transport a replication library plugs into**, not a diff engine
      wrapping a store. Charm wants `onSync`; Replica wants its six RemoteEvents batched.
- [x] **The byte case is now a specific claim rather than a hope.** `delta-compress` writes a type
      tag per value because it has no schema (`TypeId.luau:3-22`, twenty-one ids). netweave has one,
      so a patch is a bitfield of which fields moved plus the moved values in schema order — field
      identity as a position rather than a serialised key.
- [x] **Two open questions closed early.** Phase 3's deletion sentinel: none needed, a flag scope
      makes "removed" one bit, where Charm needs a `__none` table because it rides Roblox's default
      serialisation. And phase 3's real work is now named: `Ir` has to **derive a patch layout from a
      state layout**, every field optional plus a removal bit, or a patch is an opaque payload and
      the byte case evaporates.
- [ ] **Not done, and it belongs to phase 5 rather than here.** ReplicaService is v1 and 2024; the
      author's newer `Replica` is a rewrite with a different surface. The adapter phase has to
      decide which it targets, and that decision needs the seam to exist first.

### Phase 2 — the decisions that gate the code — **done**

- [x] **D-1 answered in `DESIGN-API.md` §3**: a seventh class, `nw.replicate`, on three independent
      arguments — no method in common with `nw.state`, opposite sides of the reliability trade, and
      different server memory. `nw.state` keeps its name; this plan was unfair to it.
- [x] ~~Answer **D-2** with a measurement, not a preference: implement the reliable-delta shape,
      measure it, then measure at least one alternative against it.~~ **The question was posed
      wrong, and finding that out cost nothing to build.**

      All three shapes answer loss on the reliable path, and netweave's reliable path is a
      `RemoteEvent` — Roblox delivers it reliably and in order. There is nothing to measure between
      an answer to a real problem and two answers to a problem the transport does not have.

      ~~What the framing missed is that **netweave is the thing that drops deltas**: `pendingPerBatch`
      takes the tail of an oversized batch, which is one lost packet on a `signal` and a permanently
      wrong client on a `replicate`. Reliable deltas plus a **break detector** — a sequence per
      client per subject, a gap answered with a snapshot.~~ Struck with D-2: the client applies no
      ceiling since 7df2228 and there is no sequence number.
- [x] **D-4's design answered by the same mechanism**, which is the part worth having: a client
      entering an audience has no baseline, a client that missed a packet has a stale one, and a
      client that just joined has neither — three conditions, one path.
- [ ] ~~Answer **D-4** with a probe.~~ **Moved to phase 4**, where baselines exist to probe. Writing
      it here would mean writing it against nothing.

### Phase 3 — the diff — **done**

- [x] **`Ir.patch(layout)` derives a patch layout from a state layout.** One rule, applied
      recursively: **wrap it in an optional** — which is not a trick, it is what the two states of a
      patched field already are. A non-optional field becomes `optional(T)`, where absent is
      *unchanged*. A field that was already `optional(T)` becomes `optional(optional(T))`, and the
      two bits are different questions: the outer is *did it change*, the inner is *is it there
      now*. The removal bit the plan asked for was already in the type system.

      Structs recurse and get a bit of their own when nested, so "this sub-struct is untouched"
      costs one bit rather than a walk. Arrays and maps are replaced whole, recorded as a limit: a
      per-element diff needs its own operation vocabulary — `delta-compress` has five such tags —
      and that is a schema the state schema does not describe.
- [x] `Delta.luau`: the two walks over that shape. **Not a diff-to-table followed by an encode**,
      which is what the plan implied and what both neighbours do — that builds a table per patch on
      each side, which is the "decode into a table and then walk it" `RESEARCH §3.8-S` criticises,
      and on the receive side it is *wrong*: a patch table cannot express "this optional changed to
      nil", because an absent key and a key set to nil are the same table. Charm Sync spends a
      `__none` sentinel on exactly that. Reading the bit and folding it into the baseline in one
      pass has no intermediate to lose the distinction in.

      A merged value **shares every subtree the patch did not touch** and is a fresh table only
      where it did, which is both cheaper and what an immutable store wants back.
- [x] **`Serdes.nodeCodec`**, so `Delta` walks the tree and asks for a codec at each leaf rather
      than reimplementing fourteen kinds. The block optimisation is off for those, and the docstring
      says why: a patch is never statically sized, and mixing a growth-checked writer into a blocked
      layout would write past the block.
- [x] **The byte claim is asserted rather than asserted about.** A twelve-field struct with one
      field moved: **three bytes** — twelve bits of "which one" in two, then the byte that moved —
      against twelve for the whole thing.
- [x] ~~Deletion needs a sentinel the schema cannot produce — Charm Sync uses a `__none` marker;
      netweave has a flag scope and should not need a magic value. Decide and write down which.~~
      **Closed in phase 1: none needed.** Charm needs `__none` because it rides Roblox's default
      serialisation, where `nil` and absent are the same thing. A flag scope makes "removed" one bit.
- [x] `tests/delta_runtime.luau`: `apply(base, diff(base, next))` equals `next` over the sixteen
      schemas the ceiling suite uses — chosen because between them they open a bitfield everywhere
      one can open, which is where a derived layout is most likely to number something wrong — plus
      a nested struct, which the ceiling list had no reason to carry. Forward, backward and against
      itself, so removal is exercised in one direction and arrival in the other. **121 assertions.**

      Two findings from writing it. `cloneNode` dropped the **nested scope**, which is structure
      rather than assignment — `lowerArray` and `lowerMap` create it because an element whose count
      is unknown until runtime cannot fold its flags into the enclosing bitfield — and an array
      element then had flags and nowhere to put them. And a sparse `t.array(t.optional(T))` is a
      hazard for *test data* rather than a defect: `#` on `{1, nil, 3}` is three as a literal and
      one when the same table is filled by assignment, so the generator keeps its arrays dense.
- [x] The failure-path floor is **0.1**, and `CLAUDE.md` §9 is the reason rather than the excuse.
      Computing a difference between two values the game already owns has one correct answer and no
      adversary — the same shape as `ir_runtime` at 13%. Nothing in the file reads a byte a peer
      chose; the adversarial half is a malformed or replayed patch, which is phase 6.

### Phase 4 — baselines, bounded — **done**

- [x] `Baseline.luau`: what each client has, per subject. Three levels of table — client, channel,
      subject — because every operation that matters is "everything for this client" or "everything
      for this client on this channel", and both are one `nil` assignment on a nested table.

      This is the piece **neither neighbour holds**: Charm Sync keeps one `lastSyncedValue` per key
      and diffs everyone against it, and ReplicaService keeps nothing because the game names the
      mutation. Per client per subject is what a dynamic audience needs.
- [x] ~~**with a sequence number** — phase 2's break detector.~~ **Not needed, and finding out why
      is the better half of this phase.** A sequence exists so a receiver can notice a gap. But the
      packets that go missing here are the ones **netweave itself drops** — `pendingPerBatch` takes
      the tail of an oversized batch and *reports it* — so the receiving side already knows, by
      channel, at the moment it happens. A number on the wire would be paying every patch to
      rediscover something the receiver was already told. `Baseline.desync(who, channel)` is the
      whole mechanism, and it costs nothing until it fires.

      Phase 5 wires the client's own rejection at `budget` into it. The design is unchanged; what
      is gone is a varint per patch per subject, which on a three-byte patch would have been a
      third of it.
- [x] `baselinesPerClient` in `Config` — default 256, the same shape as `queueCapacity` — and a
      `replicate` stage in `Observer` to report against. Past the limit netweave stops holding a
      baseline, which means that subject is sent **whole** to that client every tick: correct and
      expensive, ~~degrading to exactly what `nw.state` does for a living~~ — which it does not:
      `nw.state` sends when the game publishes and this sends every tick whether anything moved or
      not, 265 B per idle frame at 300 subjects (M4 report; struck in `Baseline.luau` at d4d4938 and
      here only now, M4-1). That is how a bound should fail, and PLAN-M4-BUG phase 5 declined the
      per-client flag that would quiet it, with the argument in `Baseline.luau`. An already-held baseline stays replaceable at the limit, or a full store would freeze
      every subject it already knew about.
- [x] `forget` on disconnect, tested the way `PLAN-M3` tested the queued packets it forgot:
      interleaved subjects, one departure, nothing of theirs survives and nothing of anyone else's
      goes with it.
- [x] **D-4's probe.** A subject walks in and out of an audience while its state changes, over a
      real codec, with the client's view checked against the server's truth at every step — a
      client with nothing, a client with a baseline, an unchanged tick that sends no packet at all,
      an arrival snapshotted in the same tick another client is patched, a departure, a re-entry,
      and a `desync`. Three ways in, one path.

      **The first draft of it asserted nothing**, and that is the part worth keeping. Removing
      `store.drop` on audience exit still passed, because the re-entry value happened to differ
      from the stale baseline in *every* field — so the patch carried the whole subject and
      rebuilding from nothing was correct by accident. The value now shares a field with the stale
      baseline, and without the drop the re-entering client is silently missing it. `CLAUDE.md` §9:
      a regression test is confirmed against the code it is written for.

### Phase 5 — the seam and the adapters — **done**

- [x] ~~`Store.luau` — `subjects`, `read`, and an **optional** `changed`. Three constructors:
      `Store.of` for a plain table, `Store.charm` for an atom and Charm's own `subscribe`, and
      `Store.replica` for `Replica.Data`.~~ **`changed` is gone as of phase 8** and `Store.charm`
      takes only the getter. It was declared, documented and checked at declaration for four phases
      without one line ever reading it; the measurement that settled deleting it rather than
      consuming it is below and at the top of `src/replication/Store.luau`.
- [x] **D-3's answer is refined by having built phases 3 and 4, and the refinement is worth naming.**
      Phase 1 concluded "netweave is the transport a replication library plugs into", because
      `charm-sync` already diffs and wants `connect(onSync)`. One step too far: **netweave adapts
      the store, not the store's replication layer.**

      Carrying `charm-sync`'s `SyncPayload` would mean moving an arbitrarily shaped patch table
      through a schema-driven codec — as an opaque blob, which is exactly what phase 1 warned
      throws the byte case away. `charm` underneath it is an atom and a `subscribe`, ~~which is a
      value and a signal, and that is all `Baseline` and `Delta` need~~ — **and it turned out only
      the value was needed** (phase 8). netweave **replaces**
      `charm-sync` rather than riding it, and replaces ReplicaService's six RemoteEvents the same
      way.
- [x] ~~**`changed` is optional, and that is the finding rather than a convenience.**~~ **The
      finding survives; the field does not.** Charm can say when something moved
      (`charm/packages/charm/src/init.luau:821`); ReplicaService cannot — the game calls `SetValue`
      and nothing observes it server-side (`ReplicaService.lua:403`). That asymmetry is what made a
      *required* change signal the wrong seam, and it still is. What phase 8 measured is that the
      optional one was worth 0.23 ms of an idle tick against a silent freeze whenever it missed a
      mutation, so the answer to "one of the two libraries can say" is that neither has to.

      A store that cannot say is polled once a tick, which the transport does anyway — and the
      polling is also the win, because six mutations in one frame are six RemoteEvent calls per
      player under ReplicaService and one batched patch under netweave.
- [x] netweave **never requires either library**, and now asks nothing of them either: the adapter is
      a shape rather than a dependency — which is also the only thing `CLAUDE.md` §8 leaves
      available, there being no package path.
- [x] ~~a runtime test that replicates a real change through the real library~~ — **not a test this
      repository can have, and saying so is better than a test that looks like coverage.** Charm and
      ReplicaService are in `_refsrc/`: read-only, gitignored, and forbidden to import from (§2).
      A test requiring them would run on one machine and nowhere else.

      `tests/store_runtime.luau` does what `tests/harness.luau` does for Instances under lune —
      a stand-in that answers exactly what the code under test asks, with the real library's file
      and line beside each so the shape can be checked against the source rather than against
      memory. 42 assertions, and the last section is a real test rather than a shape check: the
      seam driving an actual diff against actual baselines, including a subject appearing, one
      going away, and a tick where nothing moved sending nothing.

### Phase 5b — the public class and the transport — **done**

**The plan omitted this and the omission is the point.** `nw.replicate` is in §3's scope table
against `src/api/Channel.luau` and `src/netweave.luau`, and **no phase schedules it** — phase 3 is
the diff, 4 is baselines, 5 is the seam, 6 is the hostile suite. Everything L3 needs to *work* was
built and nothing declares it. Found by trying to write phase 5's third task, which needs a public
API to write an example against.

- [x] `nw.replicate` in `Channel.luau`: required `data`, `audience`, `store` and **`subject`**;
      forbidden `rate`, `burst`, `maxBytes`, `authorize` and — the one that matters — `unreliable`.
      All five refusals are type errors first and named runtime errors second.

      `subject` was not in the plan and is not optional. Every other class lets the audience decide
      *who* gets a value and never has to say *which* value it is; replication keeps one per subject
      on the client, so the subject goes on the wire. Declaring its type rather than assigning ids
      means it is bounded and checked like everything else.
- [x] The view: `:listen(value)` on the client, and **nothing at all** on the server. `publish`
      would be a second way in, and the one that skipped the baseline would leave clients wrong in a
      way nothing could detect.
- [x] **There is only one packet shape, which was not the plan's assumption and is better than it.**
      A snapshot is a change against *nothing*: `Delta.write(nil, value)` finds every field
      different and writes all of them. Measured on a four-field struct with a nested struct and an
      optional: **six bytes either way** — the patch's flag bits fit in the byte the schema's own
      flags were already using. So there is no snapshot/patch discriminator on the wire, no second
      codec, and a join, a resync and an audience entry are the same code path rather than three.
- [x] **And a removal is the same packet again**, which the one-shape finding did not survive
      contact with on its own. D-4 says a client leaving an audience is *told to forget*, and there
      was nothing on the wire that could say it — a subject would have gone stale on that client
      forever. Rather than a second shape with a discriminator in front of both, `Ir.patch` gives
      the patch root **one bit**: set, and the bits below say what moved; clear, and there is no
      body because the subject is gone.

      Usually free — a patch's flags round up to whole bytes, so twelve fields go from twelve bits
      to thirteen and stay at two. A removal is the flag bytes and the subject that framed them.
- [x] **A defect the removal bit exposed, which is the reason to write the test before believing
      the design.** A subject arriving whose fields are *all* absent optionals decoded to `nil` —
      the struct merger returned its `nil` baseline unchanged because nothing moved — making it
      indistinguishable from a removal, which is the one thing that bit exists to separate. The
      merger now returns an empty table against no baseline. `t.struct({ a = t.optional(t.u8),
      b = t.optional(t.u8) })` with neither set is the case, and it is in `delta_runtime`.
- [x] Both test rigs moved to the single shape, because a rig that sends two shapes while the
      transport sends one is a difference that hides bugs rather than finding them.
- [x] `tests/api_reject.luau` 20-23 and the positive half in `tests/api_ok.luau`, because §9 says a
      feature whose only test is a rejection file has no test. The fourth rejection is the one worth
      naming: **`world.server.inventory:publish(...)` does not compile**, which is the class's
      argument enforced rather than described.
- [x] The tick, in `src/replication/Tick.luau` rather than in the driver, so it can be run by hand
      under lune. For each subject the store lists, for each client the audience admits, a change
      against whatever that client has — `nil` for one that has nothing. Plus two passes nothing in
      the plan had asked for and both of which the end-to-end suite needed: the players who hold a
      baseline and are **no longer recipients**, and the subjects the store has **stopped listing**.
      Neither is visible from the loop over what exists now.
- [x] `Batch.writeChange` and the `RESYNC` control kind; `Outbound.change` and `.resync`;
      `Inbound`'s `change` and `resync` sinks, a `subjects` array on the pending list so a handler
      can be told which value it was given, and a client baseline that is deliberately **not**
      bounded — the server's copy already is, and refusing to remember one here would make the next
      change unreadable rather than save anything.
- [x] **The client's own refusal, at any stage, clears the channel and asks for it again.** Phase 4
      said the receiver already knows when netweave dropped something; this is it saying so. No
      sequence number, which on a three-byte change would have been a third of it.
- [x] `tests/replication_runtime.luau`: two peers in one process, the real envelope, the real tick.
      **35 assertions**, and three defects came out of writing it —

      **`Batch.writeChange` never wrote the version byte.** The reader then took the length prefix
      for a channel id and the batch decoded as garbage without failing a single check, because a
      version of 1 is also a channel id of 1.

      **A baseline held the store's own table.** `Replica.Data.hp = 4` mutates in place — that is
      what ReplicaService's entire API does — so the baseline *became* the new value and the next
      diff compared a table against itself and found nothing. Every subject would have frozen at
      whatever it was when first sent, silently, on every client. Charm does not have the problem
      because its atoms are immutable, which is exactly why a seam built only for Charm would have
      been the wrong seam. Snapshotted once per subject per tick, shared by every recipient.

      **`nil` is not a table key**, and a client has no peer object for the server. The same
      sentinel `Protocol` already uses, for the same reason.
- [x] The rig had a defect of its own worth as much as the three: it fed **every** packet to one
      client regardless of who it was addressed to, so a client told a subject was gone was handed
      the other client's copy on the next frame and looked correct. It asserted nothing about
      audiences, which is half of what this milestone is. Two peers now, routed by destination.
- [x] `docs/WIRE-FORMAT.md` §2 gains the change and the resync. Id 0's reservation earned itself: a
      control kind was added without touching the batch version, because the length in front of a
      control body is what makes an unknown kind steppable.
- [x] The worked example gains a replication half — a **second region** rather than a longer one,
      because the sixty-line cap is a statement about how much a reader has to hold in their head
      to understand the declaration surface, and replication is a separate thing to understand. 57
      lines and 29, both checked against `DESIGN-API.md` by `tools/messages.luau`.
- [x] **Writing it found the one defect left in the class.** The client's listener took *one*
      argument at analysis and was handed *two* at runtime, so `value` in a handler was the subject
      id — and `tests/api_ok.luau` type-checked, because a one-argument signature is a valid
      subtype. `ReplicateSubject` projects the declared `subject` type, `Channel` carries it as a
      fifth type parameter, and the view emits `(subject, payload) -> ()`. A one-argument handler no
      longer compiles.
- [x] And a rule the example demonstrates by having tripped over it: **everything is declared before
      anything is sent.** Moving the two `:send` calls into the first region sealed the protocol, so
      the replicated namespace declared after them raised — exactly as `Namespace.declare` says it
      will. The sends moved after both declarations and the comment says why.

### Phase 6 — the hostile half

- [x] A client cannot make the server hold a baseline it did not ask for. Forty well-formed changes
      on the replicated id, from a client, in one batch: every one refused at `direction` before
      decode, none of them parsed, and the server holding exactly the two baselines it held. Nothing
      on the receive path reaches `keep` — the only thing that writes a baseline is the tick, driven
      by the store and the audience — and now something has tried.
- [x] **And it cannot make the server forget one either**, which was live until this phase.
      `Inbound.desync` cleared the sender's baselines for a channel on *any* refusal, at both ends;
      on the server that meant one malformed byte bought a full resend of everything that peer could
      see, every batch, forever. It is gated to the endpoint that *receives* changes. Confirmed by
      removing the guard and watching `the server holds exactly what it held` go from 2 to 0.
- [x] The resync control packet is the one thing a client sends that makes the server work it did
      not choose, so it is bounded rather than refused: ~~300 in one batch clear a baseline once and
      the tick that follows resends once~~ — that was the wrong bound, measured in phase 8 (one per
      tick is a full state per frame); 3351d58 coalesced it to one resend per `resyncTicks` window
      per (peer, channel), a `Config` limit since PLAN-M4-BUG phase 5, with the deferred asks
      reported. A resync naming a channel that is not replicated, and one
      naming id 60000, are both refused at `replicate` rather than assumed — a peer that could ask
      about ids it invented could otherwise walk the channel table on demand.
- [x] A malformed delta is refused per packet, at `parse`, and the batch survives. **Two defects
      before a test was written for either.** `Delta.apply` neither cleared nor checked
      `Buffer.rejected()`, so a change whose flag bits claimed fields the packet did not carry read
      past its own end and came back holding whatever the next packet's bytes were — silently,
      because nothing asked. And `Inbound` treated a change that could not be read as a *removal*,
      dropping a subject because a peer sent a short packet. `apply` returns `(any, string?)` now
      and the sink refuses on the reason, which is what separates a removal from a lie.
- [x] `fuzz_runtime` mutates deltas as well as packets: a second endpoint with `isServer = false`
      and a baseline store, 4,000 rounds of arrivals, patches and removals over the same nine
      mutations, with the same four invariants. The sender's picture of the client is kept and
      diverges as refusals land, and a desync clears it — which is the resync answered, and without
      it the run would have spent every round after the first refusal against a reader with no
      baselines at all.
- [x] **It found the one nobody had thought of.** A patch says which fields it carries; the rest are
      "unchanged", which is only readable against a value that has them. Merged into *nothing* it
      produced a struct with fields missing — a value the channel's own `codec.check` refuses,
      handed to a handler that was promised that cannot happen. 8 violations in 4,000 rounds, and
      **no attacker is needed**: a client that refuses one change holds a baseline the server has
      already moved past, so the next honest patch is computed against something it no longer has.
      `Delta`'s merger rejects a required field it has neither a bit nor a baseline for, the channel
      is given up on, and the resync that already existed is what recovers it. Confirmed by taking
      the two rejections out and watching the same eight come back.
- [x] Two of the nine mutations are **not** claimed against changes, and the reason is written into
      the file: this schema carries no Instances, so trimming or padding the sidecar changes nothing
      a change reader can see. The assertion would have passed — a refusal earlier in the run leaves
      the reader without baselines and the next honest patch is refused in whichever round it falls
      in — which is §9's "passing for the wrong reason" exactly. The claim was dropped rather than
      made loosely.
- [x] `hostile_runtime` 186 assertions at 99% failure-path, `fuzz_runtime` 40 at 90%, `delta_runtime`
      139 at 22% with the partial-merge refusal as a named case rather than only a fuzz finding.

### Phase 7 — the framerate gap

- [x] **A frame is not an instrument.** The matrix has said 84 against 130 since M1 and cannot say
      why, because a frame holds rendering, physics and replication as well as the codec.
      `bench/profile.luau` encodes the same 100-entity payload with the frame taken away, in rungs
      that differ from each other by one thing each: generated code, generated code plus the
      schema's checks, one call per value, one call per value that allocates, and the real codec.
      Two runs of it agree within 1.3% on every rung.
- [x] **The engine half cancels, so the frame gap is the encode gap.** At 200 packets a frame the
      codec predicted a 4.38 ms difference against generated code; Studio measured 4.21 ms. Two
      instruments on two VMs, 4% apart. Disagreement would have been the useful answer — it would
      have meant something outside `Serdes` was paying for the gap.
- [x] Where the 24 µs went: **10%** the range and whole-number checks netweave promises, **30%** one
      call per value, **52%** a closure per value plus the struct walk that finds the field to hand
      it. Seven calls for a six-field struct before a byte is written.
- [x] **The M1 hypothesis was falsified two milestones ago and `bench/RESULTS.md` went on repeating
      it.** M1 blamed 600 `allocate` calls per packet; M2 phase 0 removed them and the next matrix
      read 86 FPS against 85. The prediction was made, the fix shipped, the number did not move, and
      nobody came back to the paragraph. It is struck through now, with the cost priced: those calls
      were 45-47% of the *pre-M2* encode, which is real and was never going to be 1.55x.
- [x] **Decided, and against the number.** `Serdes.fusedStructWriter`: a struct whose fields are all
      fixed-size numbers claims its bytes once and writes them at offsets computed at declaration,
      unrolled to eight fields with the general loop behind it. 23,992 → 12,741 ns per packet under
      lune, **1.9x**, ~~which predicts **84 → about 101 FPS, 1.28x of Blink against criterion 5's
      1.30x bar**~~ — **wrong, see below.** The prediction went into `bench/RESULTS.md` before the
      run, which is the only reason it can now be said plainly that it was wrong.
- [x] **The finding that nearly did not happen.** The probe priced the fix at 2.7x and the first
      implementation delivered 10%. The gap between them is that
      `buffer.writeu8(out, at, value)` **written out** compiles to a fastcall performed inline, and
      the same function reached through a table does not — and a builder driven by a schema reaches
      for the table without thinking about it. The `dispatched` rung isolates it at **1.6x on the
      whole packet**, more than every other layer put together, so the writer names all five
      primitives in a branch chain. It is also the honest answer to why code generators win here:
      not that they avoid closures, but that they emit the *name* of the primitive.
- [x] And one shape that lost outright, kept in the probe so it is not tried again: claim once but
      keep the loop, reading each field's offset and bounds out of parallel arrays. **25,490 ns,
      slower than doing nothing.** The array reads cost more than the calls they save, which is why
      the unroll is not a matter of taste.
- [x] `Buffer.claim` is the one new primitive — the bytes and where they start, one call per struct
      instead of one per value. It works inside a claimed block and outside one, so a dynamic
      payload gets it too.
- [x] `tests/serdes_runtime.luau` gains the seams between the two writers: both arity boundaries, a
      storage of each width in one struct, a narrowed range at both ends, floats, a dynamic array
      where nothing is claimed in advance, all three error messages including one from the sixth
      slot, and the two implementations compared byte for byte on the same fields. Confirmed to bite
      by dropping the declared-minimum subtraction and by breaking one arm of the branch chain.
- [x] **Studio ran it, and the prediction was wrong.** `bench/runs/2026-09-05-m4p7.json`, 19 of 19
      runtime modules green in the same Play. `ArrayHeavy` Up: **85** against Blink's 133 —
      **1.56x**, criterion 5 missed by the margin it was already missed by. netweave's own spread is
      84..87 and the control group moved 2-4%, so this is not resolution and not the machine.
      **Phase 8 moved it: 115 [114..116] against 132, 1.15x, on `bench/runs/2026-09-06-m4p8.json`
      (`7737e09`), controls within 3.3% — criterion 5 met on the array family for the first time.
      The same run puts the client-decode direction 30% lower with no mechanism found;
      `bench/RESULTS.md` carries both, and PLAN-M4-BUG phase 7 repeats the run.**
- [x] **The optimisation is real; the frame did not care.** Measured on the same VM in the same
      session: the codec 38,434 → 29,314 ns per packet, **1.31x** (lune said 1.88x), which is
      1.8-2.3 ms removed from an 11.76 ms frame. The fastcall finding also reproduces on that VM —
      11,042 named against 18,186 fetched, 1.65x against lune's 1.60x — so the *design* decision
      stands and only the frame arithmetic falls.
- [x] **So the profile's frame model is withdrawn.** It predicted a 4.38 ms gap and Studio had
      measured 4.21 ms; that agreement was read as corroboration and could not be checked by either
      instrument in the repository. `bench/profile.luau` now reports both VMs and predicts nothing.
- [x] **The instrument that was missing now exists, and it says the frame *is* the send loop.**
      `Config.FRAME_PROBE` puts a clock around the 200 sends in the same place, the same load and
      the same server: netweave 11.58 ms a frame of which **6.27 ms (54%) is the send loop**, against
      Blink's 7.32 and 1.03. The frame gap is 4.26 ms and the send-loop gap is 5.24 ms — the whole
      of it, and more. ~~"The frame is not encode-bound"~~ was written an hour earlier from two
      instruments that could not see a frame, and is struck through in `bench/RESULTS.md`.
- [x] **And the codec really is 1.34x faster on that VM**, measured with the real code by walking the
      arity where the fused writer hands back to the loop: 48.6 ns a value fused against 64.9 on the
      loop, so a six-field struct went 38.9 → 29.1 us a packet. The hand-built reconstruction that
      first said 38,434 was faithful to 1.3%.
- [x] **One inconsistency is left, and reasoning will not close it.** The codec is 1.96 ms a frame
      cheaper and the frame is 0.3 ms shorter, with the control group at 2-5%. The probe that settles
      it is the one that now exists, run on `1ce998b` — the tree phase 7 was applied to. If the send
      loop there is ~8.2 ms, something outside the codec grew by what phase 7 removed; if it is
      ~6.5 ms, the arity ladder is measuring something the bench's channel does not do.

      ~~One run on each tree settles it.~~ **It does not, and re-running the probe on an unchanged
      tree is what says so** (2026-09-06, `bench/RESULTS.md`): the **send loop** reproduces within
      2% on every library — 6.27 → 6.31 for netweave, 1.03 → 1.01 for blink, 5.43 → 5.39 for
      bytenet — and the **frame** does not, netweave's moving 11.58 → 12.24 ms, +5.7%, with
      `everything else` at +12%. 0.3 ms is less than half that drift, so a single reading either side
      would compare two samples of a quantity whose spread nobody had measured. What the probe can
      answer is the send loop; what it needs is repeats on both trees.

      **Never run on `1ce998b`, and the question dissolved at phase 8 instead of being answered**: with
      the encode work in, the phase 8 run measured 115 FPS and the two `PLAN-M4-BUG` runs 114 and 115,
      against Blink's 131-134. What is left open with a number on it is the Down cell
      (`bench/RESULTS.md`, "The Down cell, written as unsettled").
- [x] **An independent target came out of the same run.** ByteNet spends 5.43 ms in its send loop
      against netweave's 6.27 and **3.12 ms outside it against netweave's 5.30**, and runs 30 FPS
      faster. What is outside the loop is the flush and — one process, both peers — the server's
      decode, which never took M2's block optimisation or M4's fused writer:
      `docs/SECURITY-REPORT-M4.md` measures it at 2.5x netweave's own encode and 4x a hand-rolled
      reader, with `Buffer.ensure` written for it and no caller in `src/`.

### Phase 8 — the M4 report

`docs/SECURITY-REPORT-M4.md` audits the tree at `15f74f2` and files 78 findings. Each fix is its own
commit and the report is the tracker; what belongs *here* is the subset that changed a **decision**
this document had already written down, because those are the ones this document has wrong until
they are struck through.

- [x] **The tick asked before it looked, and asked once per pair.** `Tick` ran a `switchTo`, a
      `pcall`, a `Buffer.mark`, the whole differ walk and a `rollback` for every
      (subject, recipient) pair, every tick, whether or not anything had moved. `bench/tick.luau` is
      the probe the report's numbers needed and did not have: fifty players and five hundred
      subjects, **nothing moving**, cost **36.26 ms a tick** — twice a frame at 60 FPS — and a tenth
      of the world moving cost the same 36.51. The price was the asking, not the answering.
- [x] **One comparison for the whole audience.** Every settled recipient holds *the same table* —
      the snapshot `send` returned — so one structural comparison per subject answers for all of
      them and a pointer comparison per recipient says who is settled. The per-subject copy is
      seeded with that snapshot rather than nil, so a client joining a world at rest is handed the
      table everyone else already holds instead of a second one equal to it; two would split the
      audience into identity classes and cost every one of them an attempt for ever. **36.26 → 1.63
      ms, 22x**, with `all 50x500` — every subject moving — 40.24 → 33.99, so the gate pays for
      itself in the case it cannot help.
- [x] The removal pass is skipped outright for a broadcast, where the recipients *are* the roster
      and it is O(players²) per subject to conclude nothing, and asked baseline-first otherwise.
      `narrow 50x500` 1.67 → 0.97 ms.
- [x] **~~`changed` is optional.~~ `changed` is deleted**, and the choice was measured rather than
      argued. Both ways out of "declared, documented, never read" were open, so the tick was built
      both ways: comparing costs 1.63 ms an idle tick and trusting a perfect signal costs 1.40. That
      is 0.23 ms, and only while *nothing at all* is moving — a whole-store signal reads dirty every
      tick in any world where anything happens, which is the only kind of world whose tick cost
      matters. Against it: a signal that misses one mutation is a subject that stops replicating
      silently and permanently, and there is no probe for "the store told the truth", because when
      it does not the freeze *is* the behaviour (`CLAUDE.md` §9).
- [x] `tests/replication_runtime.luau` counts the attempts instead of timing them — §9's "count it
      instead of weighing it" — and gains the audience kind it never had, `everyone`, because the
      broadcast skip is a branch. Confirmed by four mutations: trusting the snapshot without
      comparing (12 failures, the existing suite included), seeding the copy with nil (3, all of them
      the ones written for it), removing the per-recipient skip (6, at exactly the pre-fix counts),
      and skipping the removal pass for every audience (6).
- [x] `bench/check.luau` said it compiled "every Luau file under `bench/`" and walked three
      subdirectories, so the five files sitting directly in `bench/` — including `tick.luau` — were
      reported as compiling by a check that had never opened them. 54 files became 59.
- [x] **What a `replicate` handler is given is the client's baseline, and it is frozen now.** The
      merger returns every untouched subtree by reference — the sharing that makes one field of
      twelve cost three bytes — so the table handed to `:listen` is the same one `store.keep`
      records, and `value.hp -= 1` rewrote the base the next patch folds into. Measured: after
      `seen.hp = 3` and a gold-only patch, the server says hp=10 and the client sees hp=3, for ever.
      A deep defensive copy per subject per patch is that sharing thrown away to protect it;
      `table.freeze` allocates nothing and moves the failure to the line that causes it. It is also
      nearly free for the reason the hazard exists — an untouched subtree is already frozen, so the
      walk stops there and visits only what this patch built, and `table.clone` hands back an
      unfrozen copy so the merger keeps working. Confirmed by removing the freeze (7 failures, one of
      them the report's measurement to the digit) and by making it shallow (4).
- [x] **The decode side never took a block path, and `bench/decode.luau` is the mirror phase 7 never
      wrote.** M2's block optimisation and phase 7's fused writer are both encode-side; decode is
      what a server pays per client per packet for a session, and nobody had taken it apart. Five
      rungs over the same 600 bytes: the real reader **32,731 ns a packet** against 8,100 for the
      same read written out with the range guard kept — **4.0x**, which is the report's number
      reproduced by a committed script rather than quoted from one.
- [x] `Serdes.fusedStructReader`, `fusedStructWriter`'s mirror: `Buffer.span` bounds the whole struct
      once against a size the layout already knew, and the fields are read with `buffer.readu8`
      **named**. That removes all three per-value costs at once — the closure call, the
      `READ_NUMBER` lookup behind it, and the per-primitive bounds check asking what the span already
      answered. **32,731 → 21,475 ns, 1.5x**, and 4.0x the checked ceiling became 2.6x.
- [x] **`RESEARCH §3.11-GG` reproduces on the read side, harder.** `dispatched` — the same unroll
      with the primitive fetched from a table instead of named — costs **2.7x** against the write
      side's 1.6x. The branch chain is not a matter of taste in either direction.
- [x] `Buffer.ensure` was the shape written for exactly this in M2 and **had no caller** for two
      milestones. It is `Buffer.span` now, returning the buffer and the offset, because reading with
      a named primitive needs both and a boolean is not enough to be used.
- [x] **Fusing the array as well was measured and refused.** Replacing the per-struct `span` with an
      unchecked cursor step — the ceiling a fused array could reach — moved 21,960 to 20,856, about
      5%. That is not worth a second 270-line unroll, and the remaining gap to the ceiling is the
      per-element closure call and the branch chain, neither of which an array-level span removes.
- [x] `tests/serdes_runtime.luau` gains the seams a round trip cannot reach, because every `trip`
      already runs both halves: the two readers over the same bytes, a value the *wire* put past a
      narrowed maximum, the same from the eighth slot, a run cut short with the packet behind it
      still arriving (G5), and `t.f32(-pi, pi)` accepting the bound it just wrote. Confirmed by three
      mutations — the declared bound in place of the one f32 holds (2 failures), the eighth slot
      comparing the first field's bounds (1), and `span` not bounding the run (the truncation case
      *and* 72 of 4,200 fuzzed payloads raising, which is G4).
- [x] **`Context.acquire` looked the character up for every packet, and now looks when something
      reads it.** It runs per packet and read `.Character` and searched its children for a `Humanoid`
      on every one — whether or not the channel had a policy, and whether or not the handler ever
      asked. The comment justifying that was about sharing one lookup between the *policies* of one
      request, which is right and still happens; paying for it on a request nobody asks is what the
      report found. Both fields are computed together on either one's first read, so a policy that
      wants one has already paid for the other, and each acquisition still gets its own answer — a
      deferral, not a cache.
- [x] The report filed that one as **inferred**. `tests/api_runtime.luau` makes it measured, and
      counts rather than times it: a `FindFirstChildOfClass` is a Roblox call lune does not have, so
      a clock would be timing a stand-in, where "how many times netweave asked" is the claim itself
      and is the same number in both places. Twenty packets nobody looked at: **20 property reads and
      20 tree searches before, 0 after**. A packet that does read: one of each, covering both fields.
      Confirmed by restoring the eager lookup (5 failures) and by never clearing the flag, which
      turns the deferral into a cache (1).
- [x] `Context.detached` stays eager, and that is the class paying rather than an oversight: a query
      has already cost a coroutine, a round trip and a reply packet, and its record is frozen so a
      lazy field could not cache into it anyway.

#### The type vocabulary the report asked for

The report's "Suggested Types" table is the last section of it, and these are the entries that can be
verified end to end under lune. The ones needing `Vector3`, `CFrame` or a real `Instance` wait for the
Studio pass.

- [x] **Bounds count in whole numbers.** `t.u8(0.5, 2.5)` type-checked, lowered, encoded and
      delivered a different number than was sent with no rejection anywhere — the offset became 0.5,
      the writer's whole-number test passed on the *value*, `buffer.writeu8(1 - 0.5)` truncated, and
      the reader added it back. Sent 1, got 0.5. Same for `t.string`/`t.buffer` lengths and
      `t.array`'s count, where `t.array(t.u8, 1.5)` was a channel that refused every list.
- [x] **A float reaches its encoding.** `f32` was capped at 2^24 and `f64` at 2^53 — the spans in
      which each holds every *integer* exactly, not the values it carries — so bare `t.f32` refused
      1e8 and `t.f32(0, 1e9)` was refused at declaration. The cap did no layout work either, because
      a float is never narrowed. Largest finite value of each now, with the precision that is *not*
      promised written into the docstrings.
- [x] **`t.quantized(min, max, step)`** — the one range on a fractional value that narrows the
      storage, because it declares how much precision is needed rather than how large the number
      gets. `t.quantized(-1, 1, 2 / 254)` is one byte where `t.f32` is four; a quarter-degree turn is
      two. The range must divide into a whole number of steps, refused rather than rounded, because
      which end moves is the author's call.
- [x] **The quantised arithmetic is three more arms on the branch chain, not a fold.** Folding it —
      one multiply and one add above the chain, which is the smaller diff — was measured on
      `bench/profile.luau` at **12,670 → 13,524 ns a packet, 6.7%**, with `put` flat across both sets
      of runs. That is a tax on every struct in the library for a type most do not use, so `u8`,
      `u16` and `u32` get quantised codes of their own at the end of the chain and a plain field
      never reaches them. Re-measured after: 12,896 against 12,670, unmoved.
- [x] **The node's ceiling is the top level it can reconstruct, not the declaration.** `raw * step +
      min` lands a rounding *above* the declared maximum for **67 of 2,400** evenly-dividing ranges,
      2.8% — `t.quantized(0, 100, 100 / 11)` is one — so a reader bounded by the declaration refuses
      the value its own writer accepted, at the top of the range, which is where a game sends. Same
      fix and same reason as the `f32` bound.
- [x] `step` joins the protocol hash. `t.quantized(-1, 1, 2 / 254)` and `t.quantized(-1, 1, 2 / 200)`
      lower to the same storage and the same bounds, hashed identically and printed byte-identical
      signatures, and mean something different for every byte on the wire. That is the `subject`
      failure in a third place.
- [x] Confirmed by mutation: no integrality check on a range (4 failures) or on an array count (2),
      the 2^24 cap restored (2, one of them the report's own message), the fused path treating a
      quantised field as plain (1), `step` out of the hash (2), and the reader bounded by the
      declaration (2).
- [x] **`t.u53` and `t.i53`** — whole numbers wider than four bytes, checked on **both** sides. The
      widest integer was `u32`, so a `UserId` had to be declared `t.f64`: a float, whose wholeness
      only the writer refused, so a peer sending `1.5` on a field a game reads as an id got 1.5
      delivered. They are the only declared encodings with no storage of their own — a span that
      fits four bytes narrows exactly like `u32`, and one that does not is carried in an `f64`,
      where every integer to 2^53 is exact.
- [x] **`offset` is zero on the wide path and has to be.** `value - min` for a bare `t.i53` spans
      2^54, and an odd integer above 2^53 is not representable as a double, so subtracting the bound
      would round the values the encoding exists to carry. Subtracted only where the span narrowed,
      and exact by construction there.
- [x] Integrality moved from "derive it from the storage" to a `whole` flag on the node, because a
      `u53` and a `t.f64` land on the same storage and only one of them is a whole number. That is a
      distinction only `Ir.lowerNumber` can see, and it was being re-derived in two places from
      something that does not carry it.
- [x] A struct holding a **wide** `u53` takes the loop writer: the unrolled reader has no wholeness
      check, and folding one in would be a test per field on every struct in the library for a shape
      few have — the same trade the quantised arms answered the other way, and the reason the two
      answers differ is that the quantised case had no existing path that asked the question. A
      *narrowed* `u53` lands on an unsigned storage where the value is whole by construction, and
      keeps the unroll.
- [x] Confirmed by mutation: the reader not asking for wholeness (2 failures), the wide path
      subtracting the lower bound (3, one of them an odd integer coming back rounded), and a wide
      `u53` left on the fused path, which is refused by the unrolled *writer* and taken by the
      unrolled reader — so the case that bites is a fraction forged into a struct's bytes (2).
      `bench/profile` 12,496 and `bench/decode` 21,034 across the whole of this, unmoved.
- [x] **`t.string(min, max, { utf8, pattern })`** — what a string may *contain*, not only how long it
      is. Client strings reach `SetAsync` keys, `Instance.Name` and chat, where invalid UTF-8 or a
      control character surfaces as an error in game code with no packet to point at. Checked on both
      sides: a raise at the `:send` that wrote it, a refused packet from a peer.
- [x] **netweave anchors the pattern, and refuses one that carries its own anchor.** An unanchored
      `"[%w_]+"` accepts anything *containing* a word character, which is the reading that lets
      everything through; `"^" .. "^%w+$" .. "$"` matches a literal caret, silently, which is why the
      author's own anchors are refused rather than stripped.
- [x] The third argument is refused by everything else. `t.u8(0, 10, { utf8 = true })` was accepted
      and ignored, which looks exactly like an option that worked.
- [x] `utf8` and `pattern` join the protocol hash for the reason `unit` has always been in it: the
      same bytes, and a peer without the constraint accepts what a peer with it refuses.
- [x] Confirmed by mutation: the reader not anchoring (2 failures), the reader not checking UTF-8
      (2), and `utf8` out of the hash (1). **The UTF-8 mutation did not bite the first time** — the
      assertion used a schema declaring a pattern *and* `utf8`, and a word-character pattern refuses
      every byte that is not one, so the two guards covered for each other. That is M3's `maxBytes`
      incident (§9) in a fourth place, and it is why the mutations are run rather than reasoned
      about. The assertion now goes through a `utf8`-only schema.
- [x] **`Ir.cloneNode` copied a hand-kept field list, in the one place nothing tests it.** `Ir.patch`
      derives a second layout and copies everything that is not a struct whole; a property added to
      `Node` and not added there compiles, passes every round trip on the *state* side, and produces
      a patch layout that reads a different value than the state layout wrote. All four properties
      this phase added were missing — measured, a `t.quantized` field inside `nw.replicate` sent
      `-0.5` and delivered `-1`. It is `table.clone` now, so the list inverts to the four bit
      *positions*, which do not grow.
- [x] **`t.union({ tag = schema, … })`** — the tagged union `WIRE-FORMAT.md` §5 specified two
      milestones before anything implemented it, which is where the report found it. The payload is
      `{ tag: "move", value: … } | …`, so comparing `tag` against a literal narrows `value` with it;
      the pattern it replaces — one optional field per case — cannot say *exactly one*, and lets a
      peer set two cases at once or none.
- [x] **The branches fork the bit budget**, as the document always said. The tag is `ceil(log2 n)`
      bits in the enclosing bitfield and every branch is numbered from the same slot after it, so a
      union of two structs carrying five flags each is `1 + 5` bits — one byte — where summing is
      `1 + 10`, which is two. Zap sums (`RESEARCH §3.9-Y`). Bytes cannot fork, so a static framing
      survives only where every branch is the same fixed size, and the ceiling is the widest branch.
- [x] `Delta` gets its own comparison for a union: two branches share no fields, so comparing them
      the way a struct is compared reads `value.x` off a branch that has no `x`, finds nil on both
      sides, and calls two different actions the same.
- [x] Both branch *names* and each branch's *schema* reach the protocol hash. **The obvious test for
      the second passed for the wrong reason** — a widened branch changes the union's own `fixedSize`
      and `maxSize`, which are on the layout header the signature prints before it walks a node, so
      that pair moved the hash with the branch walk deleted. The pair is `t.u8` against `t.i8` now:
      same bits, same size, same ceiling, and only the branch's declared range differs.
- [x] Confirmed by five mutations: branches summing their bits (5 failures across two files),
      branches numbered after one another (raises inside `Ir`, which is the loud half), an
      out-of-range tag not refused (the codec calls a nil reader — wire data reaching a Luau error,
      which is G4), no union case in `sameFor` (1), and `branches` out of the signature (1).
      `bench/profile` 12,711 and `bench/decode` 20,792, unmoved.

- [x] **The Studio pass caught what the lune pass could not, on this phase's own code.** `67fe53f`
      hardened `audience.select` with a shape test written the way `Serdes.isInstance` is — exact
      inside Roblox, a table under lune — and every lune run passed while `replication_runtime` and
      `transport_runtime` were red from the moment the place was opened. That is §9's "the half that
      cannot run under lune is the half that goes red quietly", reproduced by the commit that quoted
      it.

      `Serdes.isInstance` may branch, because the Studio suite hands it a **real Instance**. A
      `Player` cannot be constructed and Play mode has one, so no rig can do the same — the analogy
      broke exactly where it mattered. The two questions are separated now: **kind** (could this ever
      be addressed — a number cannot be a table key, true in both runtimes, no branch) and
      **identity** (`roster.has`, which `Recipients.roblox` answers with `Parent == Players` and
      which is strictly stronger). A roster that answers `has` is the whole test; the kind check is
      the floor for one that does not, and both rigs supply `has` now so the Studio run takes the
      path production takes.

      What the floor gives up is a plain table — `{ 5, "text", {} }` was three parked send buffers
      before phase 8 and is one rather than zero without a roster, and zero everywhere `has` exists,
      which is every path netweave builds itself.

#### The three that need Studio to finish

Written, lowered, hashed and refused under lune; the *wire* half of each needs a `Vector3` or a real
`Instance` and is asserted in `tests/roblox_runtime.luau`, which is the one file the lune list cannot
run. **This section is not green until that file has been run in Studio** (§9: the half that cannot
run under lune is the half that goes red quietly).

- [x] **`t.vector2(component)` / `t.vector3(component)` / `t.unitVector3(component)`.** Bare, a
      vector is three `f32` and unbounded — a position of `1e38` on an `intent` passes `parse`, and
      `t.unitVector3` covers directions only. A component schema is how a position says where the map
      is, and it is a **number node** rather than an encoding name, so a range, a subtracted minimum
      and a quantisation step all apply per axis for free. `t.vector3(t.i16(-2048, 2048))` is six
      bytes; `t.unitVector3(t.quantized(-1, 1, 2 / 254))` is three, against twelve.
- [x] **A quantised direction does not land on the unit sphere**, so the length check widens by
      `sqrt(3)` half-steps — derived from the component's step, and zero for every encoding that is
      not quantised, so a bare `t.unitVector3` keeps exactly the tolerance it had. Without it the
      compact spelling the docstring recommends would be refused by its own reader.
- [x] **`t.instance(class, { descendantOf })`.** A class says *what* a client handed over and nothing
      about where it got it; the sidecar admits anything the sender can reference. It takes the
      container itself rather than a name, because a game declares its schema at startup when
      `workspace` exists and resolving a path per packet would be a tree walk on the receive path.
      **Not in the protocol hash** — this is enforcement one endpoint does over its own tree, like a
      rate limit, and two peers naming their own `workspace` mean the same thing while holding
      different objects.
- [x] **`t.player`** — `t.instance("Player")` with the payload type Luau cannot get from a class
      name. Its docstring says what it does not promise: `IsA("Player")` is still true for someone
      who left, and where the sender's own identity is the question `ctx.player` is the server's
      answer.
- [x] Confirmed by the three mutations lune can run: a vector lowering to one component instead of
      `axes` of them (3 failures), `descendantOf` accepting a name (2), and `element` out of the
      signature (1). **That last one failed only on the second of its two pairs**, and the first
      would have passed without the walk — naming a component takes a `vector3` from twelve bytes to
      six, which is on the layout header. Two six-byte vectors differing only in their components'
      range is what isolates it. Same shape as the union's branch pair, found the same way.

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

### Status, written at the close of PLAN-M4-BUG

M4-1 found four of these stated as checkable and their status never written. Each is judged here
against an artifact, and the ones that are not met say so.

| # | Status | Evidence |
|---|---|---|
| 1 | **met** | `tests/replication_runtime.luau`, "Two clients, two baselines": a client joining after a change is correct on its first frame |
| 2 | **met** | `tests/delta_runtime.luau`, "The bytes": one of twelve fields moving is three bytes against twelve |
| 3 | **met** | `tests/delta_runtime.luau`, the property over the sixteen `ir_runtime` schemas |
| 4 | **not met as written** | both rigs still move the player by swapping the audience's answer by hand; a `nearby` case with the subject *moving* needs Studio geometry and `roblox_runtime` has none. Listed for the Studio pass in `PLAN-M4-BUG` phase 6 |
| 5 | **met** | `tests/baseline_runtime.luau`: the fourth baseline over a limit of three is refused and reported once, re-armed below the line |
| 6 | **met** | `tests/replication_runtime.luau`, "A player who has left stays gone, through the real tick" (PLAN-M4-BUG phase 4) — the M4-1 report's point was that no test ran `forget` against the real tick, and one does now |
| 7 | **met** | `tests/fuzz_runtime.luau`, the second run: 4,000 mutated changes, no raise, nothing lost in silence, the safety net under the read phase never fires |
| 8 | **not measured** ~~at close~~ — measured in `PLAN-M5` phase 5 | no replication mode in the matrix and no crossover artifact. Carried to `PLAN-M5` as a named task rather than closed by omission. `bench/crossover` answered it under lune on `ce4f228`: the diff loses only for a one-field subject (by two bytes) and when every field moved (by its flags and length prefix); it is level at two fields, wins from three, and writes nothing when nothing moved. `bench/RESULTS.md`, "The delta crossover, in bytes" |
| 9 | **not met as written** | run a → run b (`bench/runs/2026-09-09-m4bug-a.json`, `-b.json`): encode `ArrayHeavy` within 1.7%, decode flags within 3%, encode flags at the ±5.12 B quantisation floor, decode `ArrayHeavy` 25-85% for the competitors and 4.8% for netweave — the same column phase 0 named. `bench/RESULTS.md`, "Allocation per packet, run b, with run a beside it" |
| 10 | **met at 610d69d** | every lune check green through `scripts/check.ps1`; the Studio suite 19 of 19 with `roblox_runtime`'s new cases, run from this session through the Studio MCP and recorded here rather than only in a commit message |
| 11 | **missed** | the honest failure-path share of `replication_runtime` is 17% (PLAN-M4-BUG phase 6); the file's floor is that number, and the criterion as written is not met and not softened |

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

## 9. Disposition of the security reports

`docs/SECURITY-REPORT-M4.md` (78 findings at `15f74f2`) and `docs/SECURITY-REPORT-M4-1.md` (84 at
`7737e09`). Phase 8 above said "the report is the tracker" and neither report had one; this is it.

**The M4 report's 78.** M4-1's "Disposition" table re-established every row from the code at
`7737e09`: closed 18, closed differently 4, partial 4, declined 1, open 51. `PLAN-M4-BUG` then
closed, from those 51: 8 (`readVarint` past 32 bits), 17 (`t.struct` by reference, and `t.union`),
19 (`owner`/`nearby` through `roster.has`), 20 (a tick raise isolated per channel), 23 (the instance
writer's class and container), 24 (a change past 16,383 left alone until it moves), 32 (a raise
between the guards costs one packet), 54 and 55 (DESIGN-API §3), 57 (acceptance 11 judged on the
honest share), 59 (the pointer-compare docstrings), 63 (TypeId 21 → 19), 65 and 66 (CLAUDE.md), 68
(the older report's stale lines). Still open, and named in `PLAN-M5`: 5, 6, 7, 42, 43, 45, 46, 47,
48, 50 (the type layer, phase 3 there), 73, 74, 76, 77 (optimisation, phase 4 there). Open and not
yet placed: 9 (`nw.internal` exposure), 13 (nested `Observer.emit`), 16 (a failed `nw.namespace`
leaves `qualified`), 22 (`nw.signature()` seals), 25–30 (five small runtime edges), 31 (the joiner
snapshot bound, still inferred), 34–36, 40, 41 (nineteen analysis/runtime disagreements, of which
the numeric-bound ones cannot be closed at analysis), 51, 52, 53, 56, 58, 60, 61, 62, 64, 67, 69
(docs), 71 (the root static payload is not spanned), 75 (client `desync` per refusal).

**The M4-1 report's 84**, by severity:

| # | Finding | Where it went |
|---|---|---|
| 중대 | `replicate` before `:listen` loses the join-time snapshot | closed, PLAN-M4-BUG phase 3 (4858980) |
| 중대 | `t.map(t.u16, Entity)` does not compile | closed, phase 3 (757e7a5), with `t.optional`/`t.array` on the same seam |
| 중대 | the `select` hole test passes with the walk reverted | closed, phase 1 (da91798) |
| 중대 ×3 | `RESULTS.md` against `bench/runs/` | phase 1 put the 1.15x on record (f46b086); phase 7 regenerates the tables and archives two attributed runs |
| 위험 | `t.string` pattern cost | closed, phase 2 (6465deb): `max^k ≤ 2^16` |
| 위험 ×4 | the checkers (`--!strict`, exit code, `expect N`, string coverage) | closed, phase 1 (ca067e4, e2ccd42) |
| 위험 | the Studio numbers have no committed script | closed, phase 7 (fbcc766): the probes run in Studio, the run carries its tree |
| 경고, 15 in `src/` | malformed pattern, resync report and limit, `owner`/`nearby`, `ctx` write, `whole`, arrays of optionals, the cycle, over-limit resend (declined), `t.union` keys, `t.unitVector3`, anchor check, schema-unaware gate, `select`-all pass, decode span (unchanged), `__call` arity (M5), unnameable types (M5), `TextOptions` keys (M5) | closed in phases 2, 4, 5 except the three marked M5 and the decode span, which stays as measured |
| 경고, 12 in `docs/` | dispositions, overturned decisions, DESIGN-API §3/§6/§7, WIRE-FORMAT, 908, 39/40 | closed, phase 8 (this section, the struck decisions above, the two documents) |
| 경고, 4 comments | `Batch` resync sentence, `Buffer` Zap claim, pointer-compare docstrings, unreachable `Query.abandon` | first three closed, phase 8; `Query.abandon`'s comments are open |
| 경고, 9 tests | floors, `span` invariant, corpus, `UNCOVERED`, D-5/union pins, departed e2e, `roblox_runtime` skip, hostile crash, Studio coverage | closed, phase 6, except the `Driver`/`Link.roblox` Studio sections, which are open |
| 경고, 8 bench | `BEFORE` notes, `bench/` unchecked, `report` degrades, no spread, no drop rate, envelope copy, fairness, provenance | closed, phase 7, except `bench/` under `analyze` (M5) |
| 경고, 8 tools | repair markers, `src/types` messages, `findLuauLsp`, `messages` extraction, selene allows, unchecked checkers | open; selene allows and the checkers under `analyze` are M5, the rest not yet placed |
| 미미, 16 | | the counted-fact comments closed in phase 8; the rest open |

Everything marked open here is open in the plan that owns it or in no plan yet; nothing is closed
by silence.

**`nw.state` growing into replication breaks games that used it as a push channel.** Nothing is
shipped yet, so the cost is documentation rather than migration — but the decision still has to be
made before the code, which is why D-1 gates phase 2.

## 10. Result

Written 2026-09-09 at the close of `PLAN-M4-BUG`, the pass that worked through this milestone's two
security reports. Every number below comes from a committed artifact named beside it.

**What shipped.** L3 as four modules — `Delta` (a structural patch over the lowered IR; snapshot,
change and removal are one packet shape), `Baseline` (per client, bounded by `baselinesPerClient`,
reported when the bound is passed), `Store` (the seam: `subjects` and `read`, with `Store.of` and
`Store.charm`; `changed` deleted in phase 8 after four phases in which nothing read it) and `Tick`
(the loop, with schema-shaped snapshots and a `pcall` per channel) — and **`nw.replicate`** as the
seventh class, `:listen` on the client and nothing on the server. There is no `src/replication/adapters/`:
the seam asks two functions of a store, and the Charm and Replica adapters collapsed into that (phase 5).
Around it: the per-frame allocation window in Studio (phase 0), `Config.FRAME_PROBE` (phase 7), the three
ladders runnable in Studio by `require` (`PLAN-M4-BUG` phase 7), the resync window as a `Config` limit,
and `scripts/check.ps1` with the pre-commit hook.

**The numbers.**

| | |
|---|---|
| bytes on the wire, `ArrayHeavy` / flags | 601 / 8 — unchanged since M1, and level with Blink and Zap on the array |
| one of twelve fields moved | 3 bytes against 12 for a resend (`tests/delta_runtime.luau`) |
| snapshot against change | one packet shape; six bytes either way on the four-field probe struct (phase 5b) |
| `ArrayHeavy` Up, p50 | 114 and 115 against Blink's 131 and 134 — **1.15x and 1.17x**, `PLAN-M1` criterion 5 met in two runs after missing since M1 |
| `ArrayHeavy` Down, p50 | 63 and 54 against Blink's 78 and 83 — **unsettled**, `bench/RESULTS.md` "The Down cell, written as unsettled" |
| encode B/call, `ArrayHeavy`, run a → run b | 1909.8 → 1917.4 (+0.4%); Zap 1914.9, Blink 2729.0, ByteNet 614.4 |
| decode B/packet, `ArrayHeavy`, run a → run b | 10447.9 → 9951.2 (−4.8%), a lower bound; the competitors moved 25-85% on unchanged code |
| Studio ladders at `fbcc766` | encode 27,952 ns a packet against a 6,458 ceiling, 4.33x; decode 35,073 against 12,476, 2.81x |
| `bench/tick`, median ms a tick at 50x500 | select-all 14.32 → 3.00, extra key 31.02 → 1.69, subtree 1.85 → 1.71 (`PLAN-M4-BUG` phase 5) |
| the suites | 25 lune steps green through `scripts/check.ps1`; the Studio suite 19 of 19 at `610d69d`, run through the Studio MCP |
| the reports | 78 findings (`SECURITY-REPORT-M4.md`) and 84 (`SECURITY-REPORT-M4-1.md`), each with a disposition in §9 |

**Acceptance**, from the status table under §7: 1, 2, 3, 5, 6, 7 and 10 met; 4, 9 and 11 not met as
written; 8 not measured. None of the four was softened to fit.

**What this milestone did not do, and where each item went.**

- A replication mode in the matrix and the delta crossover (acceptance 8): `PLAN-M5` phase 5.
- The `nearby` case with the subject moving (acceptance 4) and the Studio-only `roblox_runtime` sections
  for `Driver`, `Link.roblox`, the 908 limit and a real `Player`: open in `PLAN-M4-BUG` phase 6.
- The type layer and the optimisation residue of both reports: `PLAN-M5` phases 3 and 4, with the
  client decode ladder added there.
- The Down cell: written as unsettled with the probe that would settle it named, in `bench/RESULTS.md`.
