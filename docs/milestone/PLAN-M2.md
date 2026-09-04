# PLAN-M2 — L2 Transport

**Status:** not started
**Depends on:** M1 (declaration surface and codec), `docs/WIRE-FORMAT.md` (frozen v1)
**Blocks:** M3 (security and reliability), M4 (delta state replication)

---

## 1. Goal

netweave sends and receives on its own. The channels M1 taught the type system about start
carrying real packets: batched once per frame, addressed to the audience each one declared,
budgeted per player in real bytes, and framed so that one malformed packet costs one packet.
When M2 is done, `nw.internal.transport` is filled by netweave rather than by a benchmark
stand-in, and G2 and G3 stop being types with nothing behind them.

## 2. Why now

M1 shipped every guarantee that a type can carry and none that needs a frame loop. Four things
make this the next milestone rather than a later one:

- **Two of the six guarantees are currently unenforced.** G2 says every inbound channel declares
  a rate budget and G3 says every outbound channel declares its audience. Both are type errors
  today and *nothing else*. A declaration that passes analysis still sends unbudgeted packets to
  everyone, because there is no runtime to do otherwise.
- **`src/api/Transport.luau` is a hole on purpose.** It raises with a message naming this
  milestone. Every `send`, `publish`, `broadcast` and `invoke` in the library ends there.
- **M0 measured that batching matters more than serialization.** Server to client on
  `ArrayHeavy`, a raw `RemoteEvent` delivered 11,138 of roughly 64,000 offered while every
  batching library delivered all of it at the same payload size — ~6,400 remote invocations a
  second against ~126 (`bench/RESULTS.md`, `RESEARCH §3.7-E`).
- **The benchmark currently measures a stand-in.** `bench/src/shared/Modes/netweave.luau`
  implements just enough of `WIRE-FORMAT.md` to be comparable. Until the real transport replaces
  it, every netweave number carries an asterisk.

## 3. Scope

| # | Deliverable | Artifact |
|---|---|---|
| D1 | Codec carry-over from M1: allocate the fixed-size prefix once | `src/codec/Buffer.luau`, `src/codec/Serdes.luau` |
| D2 | Batch envelope, promoted out of the benchmark | `src/transport/Batch.luau` |
| D3 | Outbound: per-player buffers, serialize-once fan-out, flush scheduling | `src/transport/Outbound.luau` |
| D4 | Inbound: receive loop, per-packet isolation, ring-buffer queue | `src/transport/Inbound.luau` |
| D5 | Byte accounting and rate budgets | `src/transport/Budget.luau` |
| D6 | Audience evaluation and recipient sets | `src/api/Audience.luau`, `src/transport/Outbound.luau` |
| D7 | `intent` tick coalescing | `src/transport/Inbound.luau` |
| D8 | The driver, installed for real | `src/transport/init.luau`, `src/netweave.luau` |
| D9 | Tests, including a hostile-batch suite | `tests/transport_runtime.luau`, `tests/budget_runtime.luau` |
| D10 | The benchmark adapter drops its stand-in, and the matrix is rerun | `bench/src/shared/Modes/netweave.luau`, `bench/RESULTS.md` |

## 4. Non-goals

| Deferred | To |
|---|---|
| Rate-limit *policy* beyond a per-channel budget — adaptive limits, bans | M3 |
| Backpressure on the send side | M3 |
| `query` timeouts and varint call ids | M3 |
| Malicious-client fuzzing as a suite | M3 |
| Delta state replication | M4 |

M2 makes the budget real and observable. M3 decides what to *do* about a player who keeps
exceeding it. The split is deliberate: a budget nobody can measure is not a security feature, and
a punishment built on an unmeasured budget is worse than none.

## 5. Design decisions

**D-1. Serialize once, memcpy N times.**
Blink's `RELIABLE_BODY` and Zap's `push_return_fire_all` both do `save()` → serialise once into a
scratch buffer → per player `load(map[p])`, `alloc(len)`, `buffer.copy`, `save()`. It is the
universal idiom in this space and netweave adopts it (`RESEARCH §3.7-E`). The benchmark stand-in
does not do this — it re-encodes per recipient — so the fan-out numbers in `bench/RESULTS.md` are
a floor, not a forecast.

**D-2. A dedicated `FireAllClients` channel for identical payloads.**
ByteNet's `globalReliable` is the one place ByteNet beats both code generators: Blink and Zap
serialise once but still issue N memcpys and N remote calls for 100 players, while ByteNet issues
one (`RESEARCH §3.7-E`). netweave already knows which channels qualify — `nw.audience.everyone`
is a singleton in the type, and it is the same tag that decides whether `broadcast` exists.

**D-3. Unreliable batching is a per-packet opt-in, off by default.**
Batching unreliable traffic is a semantic error, not an optimisation: losing one datagram loses
N events instead of one. Blink not batching unreliable looks like a choice rather than an
omission (`RESEARCH §3.7-E`). netweave hands the decision to the author per packet rather than
choosing for them.

**D-4. Ring-buffer receive queue with drop-oldest.**
Blink's queue for a listener-less event is `table.insert` with no bound: past 256 it warns on
every insert and keeps inserting, so a missing listener becomes warn spam plus unbounded memory
(`Generator/init.luau:413-418`). Zap uses read/write cursors and grows by doubling with two
`table.move`s (`server.rs:287-362`). Zap's is better and netweave takes it, with one change:
**a full queue drops the oldest and reports it**, because silently growing under load is how a
memory leak gets called a networking library.

**D-5. The 908-byte check nobody does.**
`grep` for `900|908|buffer.len` across `blink/src` and `zap/src/output/luau` returns nothing. An
unreliable payload past the limit is dropped by Roblox **silently** (`RESEARCH §3.7-F`). netweave
knows a schema's maximum size at definition time for static schemas and its actual size at flush
for the rest, so it can refuse loudly instead.

**D-6. Byte accounting is real bytes, on a time window, observable, and runs in Studio.**
Warp is the counter-example and fails all four (`RESEARCH §3.7-K`): it counts
`math.max(buffer.len(b), 800)` so a 1-byte packet costs 800; it resets the counter inside a send
loop that `continue`s when there is nothing to send, so a player the server is not talking to is
**never reset and is blackholed permanently**; and the whole thing is wrapped in
`if not RunService:IsStudio()` so no test can ever catch it. Each of those is a requirement
stated in reverse.

**D-7. Per-packet failure isolation, using the length prefix that already exists.**
`WIRE-FORMAT.md` §2 put a varint length on every `counted` channel for this. A packet that fails
to decode is discarded, reported through `nw.observe`, and the cursor skips to the next boundary
(`RESEARCH §3.8-R`). `bench/envelope.luau` already demonstrates it working — and already caught
the way it breaks: **a rejection is sticky, so without clearing it the next packet's id read
reports the previous packet's failure and the batch dies anyway.**

**D-8. The codec carry-over is measured before the transport changes, not after.**
M1 missed acceptance criterion 5 because `Serdes` never calls `Buffer.allocate`: every scalar
allocates its own bytes, so one `ArrayHeavy` packet costs 600 allocations and a frame costs
120,000. `Ir.lower` computes `fixedSize` and nothing reads it — D-2 of PLAN-M1, computed and then
unused.

It is task zero of this milestone **and it is measured on its own**, before the transport is
touched. M1 spent a run separating two encode hypotheses precisely because they had been allowed
to move together; doing the codec and the transport in one step would put that back.

**D-9. `intent` coalesces: at most one value per player per tick.**
Not an optimisation but the class's meaning (`DESIGN-API.md` §3). Stale input has no value, so an
attacker who fills the rate budget cannot convert it into per-packet server work. This is the one
place merging is semantically safe, and it is what makes `rate` on an `intent` a number that
means something rather than a cap nobody hits.

## 6. Tasks

### Phase 0 — the codec carry-over, measured alone
- [ ] `Buffer`: offset-addressed writes, so a caller that has allocated a block can fill it
- [ ] `Serdes`: read `layout.fixedSize` and allocate the fixed-size prefix once per payload
- [ ] `tests/serdes_runtime.luau` and `tests/roblox_runtime.luau` still pass unchanged — the wire
      format must not move by one byte, and `bench/envelope.luau` is what proves it
- [ ] Re-run the three-mode matrix with the transport untouched. This is the number that closes or
      keeps acceptance criterion 5 of M1, and it has to be attributable

### Phase 1 — the envelope, out of the benchmark
- [ ] `src/transport/Batch.luau` — write and read the `WIRE-FORMAT.md` §1-§2 envelope
- [ ] Carry over the two defects `bench/envelope.luau` found: clear the rejection after a skipped
      packet, and stop the batch on a `static` packet that cannot be resynchronised
- [ ] The one-byte length reservation the benchmark could not generalise: a `counted` payload past
      127 bytes needs the reserved byte widened, which needs a shift the benchmark refused to add

### Phase 2 — outbound
- [ ] Per-player parked buffers, swapped rather than reallocated (`PLAN-M1` D-4)
- [ ] Serialize once, `buffer.copy` per recipient (D-1)
- [ ] `FireAllClients` path for `nw.audience.everyone` (D-2)
- [ ] Audience evaluation: `owner`, `nearby(studs)`, `select(fn)` to recipient sets
- [ ] Flush on `PostSimulation`; unreliable is immediate unless the packet opts in (D-3)
- [ ] 908-byte refusal with a reason, before the send rather than after the drop (D-5)

### Phase 3 — inbound
- [ ] Receive loop with per-packet isolation (D-7)
- [ ] Ring-buffer queue, drop-oldest, reported (D-4)
- [ ] `ctx` acquired and released per packet, policies run, handler dispatched
- [ ] `intent` coalescing (D-9)

### Phase 4 — budgets
- [ ] Real `buffer.len` accumulation per player per channel (D-6)
- [ ] Time-based windows, reset on a path that runs whether or not the server is sending
- [ ] Every refusal reaches `nw.observe` at stage `"budget"`
- [ ] Runs in Studio. A guard that only runs in production is a guard nobody has tested

### Phase 5 — install and measure
- [ ] `src/transport/init.luau` installs the driver; `nw` exposes nothing new
- [ ] `bench/src/shared/Modes/netweave.luau` deletes its stand-in
- [ ] Rerun the full matrix; update `bench/RESULTS.md` and `bench/runs/`
- [ ] Record what changed against the stand-in, per schema family

## 7. Acceptance criteria

1. A channel declared with `rate = n` refuses packet `n + 1` inside its window, and the refusal
   appears at `nw.observe` stage `"budget"` with the player and the byte count. Verified in a test
   that runs under lune, not only in Studio.
2. The budget counter resets on a window boundary regardless of whether the server has sent that
   player anything. This is Warp's exact bug (`RESEARCH §3.7-K`) and it needs its own test.
3. A `state` declared `nw.audience.nearby(120)` reaches every player inside the radius and no
   player outside it. A channel declared `nw.audience.everyone` issues **one** remote call for N
   players, not N.
4. A batch containing one packet that fails to decode delivers every other packet in that batch,
   and reports the failure once. Both framing modes, and the `static` limit stated rather than
   silently mishandled.
5. An unreliable payload over 908 bytes is refused with a reason before it is sent. No silent drop.
6. A listener-less channel under sustained load has bounded memory, and the drops are counted.
7. `intent` delivers at most one value per player per tick under any offered rate.
8. Bytes per packet are unchanged from M1 — 601 on `ArrayHeavy`, 8 on the flag schemas. The
   transport must not cost a byte the wire format did not already account for.
9. Framerate under the M0 load is no worse than M1's stand-in on any cell, and `ArrayHeavy` encode
   clears the 1.3x bar that M1 missed.
10. `stylua --check`, `selene`, `lune run analyze`, every `*_runtime` test, `lune run bench/check`
    and `lune run bench/envelope` pass.

## 8. Risks

**R-1 — the transport becomes the thing that allocates.**
M1 kept the codec's hot path clean and then measured the *bench adapter* allocating two tables per
send. A real transport has more places to make that mistake: per-flush recipient tables, per-packet
closures, a fresh `ctx`. Mitigation: the benchmark's encode-allocation column already catches a
constant-per-send cost — it is how the last one was found — and acceptance criterion 9 makes a
regression a build failure rather than a footnote.

**R-2 — budget accounting costs more than it protects.**
A per-packet byte counter with a time window is work on the receive hot path, which is exactly
where an attacker's traffic lands. If refusing a packet costs more than accepting it, the budget is
an amplifier. Mitigation: measure the refusal path specifically, not just the accept path, and
treat "denial is cheaper than acceptance" as a criterion rather than an assumption.

**R-3 — audience evaluation per publish does not scale.**
`nearby(120)` runs per publish, and `DESIGN-API.md` §10.4 left open whether that is per-subject or
cached per tick. At 100 players and a 60 Hz state channel the difference is four orders of
magnitude. Mitigation: decide it in phase 2 with a measurement, and write the answer into §10.4
rather than leaving it open a second time.

**R-4 — the codec carry-over changes the wire format by accident.**
Allocating once and writing at offsets is a rewrite of every writer's addressing. A single wrong
offset moves bytes without failing any round-trip test, because the reader is symmetric and would
read them back from the same wrong place. Mitigation: `bench/envelope.luau` asserts absolute byte
counts and field offsets against a literal layout, and `tests/serdes_runtime.luau` pins the M0
competitor byte counts. Both must pass unchanged, and neither is symmetric with the writer.
