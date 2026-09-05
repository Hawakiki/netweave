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

**What can drop a delta is netweave.** `pendingPerBatch` drops the tail of an oversized batch and
reports it; on a `signal` that is one lost packet, and on a `replicate` it is a client that will
never be right again. So: **reliable deltas, plus a break detector** — a sequence per client per
subject, and a client that sees a gap gets a snapshot instead of another delta.

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
- [ ] **Acceptance 9 is met on three of four columns and stays open on the fourth.** Encode
      `ArrayHeavy` within 1.7%; decode flags identical to the decimal for all five modes; encode
      flags at the **±5.12 B quantisation floor** rather than inside 10%, which no arrangement of
      windows improves on because `collectgarbage("count")` reports kilobytes. Decode `ArrayHeavy`
      moves 13-17% — far better than the M3 instrument's 76% and 146%, still outside the bar. A
      window big enough to hold an `ArrayHeavy` batch is one the collector almost always visits, and
      Roblox exposes enough to detect that and not enough to correct for it. **Carried to phase 7**,
      which is the only phase that needs that cell.

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

      What the framing missed is that **netweave is the thing that drops deltas**: `pendingPerBatch`
      takes the tail of an oversized batch, which is one lost packet on a `signal` and a permanently
      wrong client on a `replicate`. Reliable deltas plus a **break detector** — a sequence per
      client per subject, a gap answered with a snapshot.
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
      expensive, degrading to exactly what `nw.state` does for a living. That is how a bound should
      fail. An already-held baseline stays replaceable at the limit, or a full store would freeze
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

- [x] `Store.luau` — `subjects`, `read`, and an **optional** `changed`. Three constructors:
      `Store.of` for a plain table, `Store.charm` for an atom and Charm's own `subscribe`, and
      `Store.replica` for `Replica.Data`.
- [x] **D-3's answer is refined by having built phases 3 and 4, and the refinement is worth naming.**
      Phase 1 concluded "netweave is the transport a replication library plugs into", because
      `charm-sync` already diffs and wants `connect(onSync)`. One step too far: **netweave adapts
      the store, not the store's replication layer.**

      Carrying `charm-sync`'s `SyncPayload` would mean moving an arbitrarily shaped patch table
      through a schema-driven codec — as an opaque blob, which is exactly what phase 1 warned
      throws the byte case away. `charm` underneath it is an atom and a `subscribe`, which is a
      value and a signal, and that is all `Baseline` and `Delta` need. netweave **replaces**
      `charm-sync` rather than riding it, and replaces ReplicaService's six RemoteEvents the same
      way.
- [x] **`changed` is optional, and that is the finding rather than a convenience.** Charm can say
      when something moved (`charm/packages/charm/src/init.luau:821`); ReplicaService cannot — the
      game calls `SetValue` and nothing observes it server-side (`ReplicaService.lua:403`). A seam
      that required a change signal would have supported one of the two libraries it was designed
      for. A store that cannot say is polled once a tick, which the transport does anyway — and the
      polling is also the win, because six mutations in one frame are six RemoteEvent calls per
      player under ReplicaService and one batched patch under netweave.
- [x] netweave **never requires either library**. The game passes Charm's own `subscribe`, so the
      adapter is a shape rather than a dependency — which is also the only thing `CLAUDE.md` §8
      leaves available, there being no package path.
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
      not choose, so it is bounded rather than refused: 300 in one batch clear a baseline once and
      the tick that follows resends once. A resync naming a channel that is not replicated, and one
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
- [x] **The optimisation is real; the frame did not care.** Measured on the same VM in the same
      session: the codec 38,434 → 29,314 ns per packet, **1.31x** (lune said 1.88x), which is
      1.8-2.3 ms removed from an 11.76 ms frame. The fastcall finding also reproduces on that VM —
      11,042 named against 18,186 fetched, 1.65x against lune's 1.60x — so the *design* decision
      stands and only the frame arithmetic falls.
- [x] **So the profile's frame model is withdrawn.** It predicted a 4.38 ms gap and Studio had
      measured 4.21 ms; that agreement was read as corroboration and **was a coincidence**. The
      probe's own caution said what to do with a disagreement, and the disagreement is what arrived.
      `bench/profile.luau` now reports both numbers and predicts nothing.
- [ ] **Where the frame actually goes is open, with no measurement behind it.** Leading candidate,
      *inferred*: Studio Play runs client and server in one process; the server decodes 200
      `ArrayHeavy` packets a frame in the same budget, and the decode path never took M2's block
      optimisation. `docs/SECURITY-REPORT-M4.md` measures decode at 2.5x the encode and 4x a
      hand-rolled reader, and `Buffer.ensure` — written for exactly that — has no caller in `src/`.
      `raw` finishing last at 30 FPS while serialising nothing points the same way. **Measure before
      touching anything**: that is the whole lesson of this phase, twice over.

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
