# Netweave Security & Correctness Report

**Scope:** `src/` at commit `7f5871c` on `develop` (2026-09-05), read in full, plus `docs/DESIGN-API.md`,
`docs/WIRE-FORMAT.md`, `docs/milestone/PLAN-M3.md` and the test suite for the claims they make.

**Method:** every finding marked *measured* was reproduced under `lune` against the current tree
with a probe built from the shipped modules (`Inbound`, `Batch`, `Budget`, `Serdes`, `Outbound`),
the same rig `tests/hostile_runtime.luau` uses. Findings marked *inferred* come from reading the
code and are labelled as such, per `CLAUDE.md` §7. The baseline suite is green: all fourteen
`*_runtime` files, `lune run analyze` (44 files clean, three rejection files at their declared
counts) and `lune run tools/messages` pass — none of what follows is caught by it. Appendix A holds
the probes so every number below can be re-run.

## Severity
- 미미 — cosmetic, or a limit the documentation already states elsewhere
- 경고 — a real defect with a bounded blast radius, or a documented guarantee that is weaker than stated
- 위험 — a client can cause measurable harm (resource use, wrong data reaching a handler) without a game bug
- 중대 — a guarantee the library sells is broken, or ordinary traffic is refused or lost
- 심각 — remote code execution, cross-player data exposure, or authoritative state changed without a policy

## Current Security Risks

### [중대] A non-Instance sidecar entry throws on the receive path and leaks every decoded value in the batch
- Location: `src/codec/Serdes.luau:903-926` (instance reader), `src/transport/Link.luau:137-152` (`onServer`), `src/transport/Inbound.luau:705-726` (`receive`)
- Problem: `Link.onServer` checks only `type(instances) == "table"` and passes the table through. The
  instance reader then calls `value:IsA(class)` on whatever sits in that slot. A client sends
  `FireServer(buffer, { {} })` or `{ 5 }` against any channel with a `t.instance("Class")` field, and
  the call raises inside the read phase. Nothing catches it: `Inbound.receive` restores `sender`,
  `filling` and `full` and decrements `depth` only on the path that returns normally.
- Impact: guarantee G4 ("wire data never reaches `error()`") is false for every schema that names an
  instance class. Every packet read before the bad one in that batch is never dispatched, `depth`
  drifts up by one per batch, and the pooled pending list at that depth — holding every value decoded
  so far — is never reused or cleared. Memory grows by roughly `pendingPerBatch × maxBytes` per
  hostile batch and is never returned.
- Evidence: measured. A batch of one `t.struct({ who = t.instance("Part") })` packet with sidecar
  `{ { fake = true } }` returns `false, "Serdes:920: attempt to call missing method 'IsA' of table"`
  from `pcall(inbound.receive, ...)`. Fifty batches each carrying 100 honest 4 KB packets ahead of one
  such packet: 50 raises, 0 packets dispatched, `gcinfo()` up 6.9 MB and not reclaimed. Neither
  `tests/hostile_runtime.luau` nor `tests/fuzz_runtime.luau` ever puts a non-Instance in the sidecar;
  the fuzzer only over- and under-states the count.

### [위험] Packets on a server-to-client channel id are decoded and queued with no rate budget
- Location: `src/transport/Batch.luau:438-445` (`resolve` accepts any class), `src/transport/Budget.luau:85-87` (`if not rate then return nil`), `src/transport/Inbound.luau:604-621` (`deliver` → `enqueue`)
- Problem: `Namespace.channelById` resolves every id, including `state` and `event`. Those classes have
  no `rate` by design, so `Budget.admit` returns nil — admitted — for every packet. On the server no
  handler is ever attached to an outbound channel, so each packet is fully decoded and pushed into that
  channel's queue, and the queue's drop-oldest keeps the newest 256 decoded values alive per channel.
  `enqueue` returns before the `pendingPerBatch` check, so that ceiling never applies either.
- Impact: decode work and retained memory are bounded only by the client's send rate and Roblox's remote
  limits, not by anything the game declared. Direction (G6) is enforced by the view types and not on
  the wire.
- Evidence: measured. 600 packets on a `nw.state` id in one batch with `pendingPerBatch = 256`: all 600
  decoded, 0 refusals at `budget`, 344 refusals at `queue`, `budget.usage()` reports `0 0 0`. Forty
  senders × 300 packets of a 4 KB `t.string` on a `state` id: 12,000 decodes, 11,744 `queue` reports,
  ~1.7 MB retained in the queue afterwards.

### [위험] A bare `t.instance` field hands the handler whatever the client put in the sidecar
- Location: `src/codec/Serdes.luau:903-926`
- Problem: when no class is declared the reader only checks `value == nil`. A number, string or table in
  the sidecar is returned as the field value and reaches the handler, the policy and `nw.validate`'s
  brand as an `Instance`.
- Impact: type confusion in game code that trusts the schema. A handler doing `who.Name`, `who:IsA(...)`
  or `who.Parent` raises inside its `xpcall` (reported at `handler`); a handler that stores the value
  — an ownership table, a target reference — stores a client-chosen non-Instance.
- Evidence: measured. `t.struct({ who = t.instance })` with sidecar `{ 12345 }` delivers
  `value.who == 12345`, `typeof == "number"`, no report.

### [경고] Control packets on id 0 bypass the budget and the pending ceiling, and a mismatched hello is answered without limit
- Location: `src/transport/Batch.luau:387-436`, `src/api/Protocol.luau:320-342` (`greet`), `src/transport/Inbound.luau:598-602` (`hello` sink)
- Problem: id 0 is read before `sink.admit`, so no rate is charged and `full` is not consulted. Every
  `HELLO` whose hash differs builds a fresh refusal string and calls `announce`, which writes a hello
  into the sender's parked outbound buffer. Nothing is reported for the hello itself; a refusal only
  surfaces when a data packet follows it.
- Impact: a client can fill a batch with hellos and make the server encode one reply per hello, outside
  every declared limit. The ratio is 1:1 in bytes, so this is unbudgeted work rather than
  amplification.
- Evidence: measured. 300 mismatched hellos in one batch: `announced == 300`, `reports == 0`.

### [경고] A refused query request is answered before decode, outside any budget
- Location: `src/transport/Inbound.luau:497-505` (`decline`), `:681-700` (refuse → `decline`), `src/transport/Outbound.luau:343-355` (`reply` — "It is not budgeted")
- Problem: a request refused at `budget`, `protocol` or the pending ceiling still gets a status-only
  reply written to the sender's buffer. The refusal path therefore costs a report plus an encode, and
  `Batch.read`'s premise that "refusing has to stay cheaper than accepting" does not hold for this
  class.
- Impact: a client over its rate on a query channel receives one reply per refused request, so the
  server's outbound to that client scales with what it sent. Bounded by the client's own bandwidth.
- Evidence: inferred from the three call sites; the `pendingPerBatch` path was exercised in
  `tests/query_runtime.luau` only for correctness of the status, never for cost.

### [미미] The refusal path allocates one interpolated string per refused packet
- Location: `src/transport/Inbound.luau:465-471`, `:517-523`, `:659-665`
- Problem: the queue-full, pending-ceiling and reply-dropped reasons are built with string interpolation
  on every refusal, so a flood that is refused allocates per packet — the case the `Observer` and
  `Budget` comments say allocates nothing.
- Impact: garbage pressure proportional to a flood. Small per packet, but it is the exact cost the design
  documents claim not to pay.
- Evidence: measured. The 12,000-packet flood above produced 11,744 distinct reason strings.

## Potential Security Risks

### [위험] `nw.validate` brands values that do not satisfy the schema
- Location: `src/api/Trust.luau:238-262`, `src/codec/Serdes.luau:462-470` (boolean writer), `:530-538` (instance writer), `:301-330` (number writer)
- Problem: `validate` runs the encoder and treats "did not raise" as "conforms". The boolean writer
  accepts any value (it only tests truthiness), the instance writer accepts anything non-nil, and the
  integer writers accept any number in range including fractions.
- Impact: this is the documented escape hatch for DataStore and HTTP data. A JSON body
  `{ admin = "false" }` validates against `t.boolean` and is truthy afterwards; `{ target = 5 }`
  validates against `t.instance("Player")`. The value comes back branded `Trusted<T>`.
- Evidence: measured. `Trust.validate(t.struct({ f = t.boolean }), { f = "no" })` returns the table and
  nil; likewise `{ f = 0 }`, `{ i = 5 }` against `t.instance("Part")`, and `{ n = 3.7 }` against
  `t.u8`.

### [경고] Queued packets are dispatched after their sender has left
- Location: `src/transport/Inbound.luau:731-761` (`drain`), `src/api/Context.luau:164-185` (`acquire`), `src/transport/Driver.luau:155-170`
- Problem: `PlayerRemoving` forgets the player's budget, context, intent and call slots but not their
  entries in per-channel queues. A `:listen` attached later drains those entries, `Context.acquire`
  recreates a record for the departed `Player`, and the policy and handler run against it.
- Impact: a command executes for a player who is gone, with `ctx.character == nil`, and the recreated
  context record is never forgotten. Bounded by `queueCapacity` per channel.
- Evidence: inferred. `forget` clears `coalescedValue` and `Context` only; `queues` is untouched.

### [미미] An observer that detaches itself during `emit` skips the observer after it
- Location: `src/api/Observer.luau:225-247`, `:260-274`
- Problem: the remover does `table.remove(observers, index)` while `emit` is iterating `1..count` with
  the pre-loop `count`; the next observer shifts into the current index and the last index reads nil.
  `xpcall(nil, ...)` does not raise, so the miss is silent.
- Impact: one rejection unseen by one observer, once.
- Evidence: inferred.

## Current Bugs

### [중대] The derived byte ceiling omits per-element bitfield bytes, so honest packets are refused
- Location: `src/codec/Ir.luau:685-730` (`ceiling`), `src/api/Channel.luau:595-657` (`make`), `src/transport/Batch.luau:563-583`
- Problem: `ceiling` says "flags live in the enclosing scope's bytes … the layout adds the scope once at
  the top". That is true for the root scope only. A dynamic array or map element that carries flags
  opens a scope of its own (`Ir.luau:448`, `:460-464`) and the encoder writes `scope.bytes` per
  element, but `ceiling` never adds them. `make` stores the result as `channel.maxBytes`, and
  `Batch.read` refuses any packet whose declared length exceeds it.
- Impact: every channel whose element type contains a boolean, an enum, or an optional is unusable
  past a handful of elements, and the refusal is reported at stage `budget` against the *sender* —
  a game reads its own traffic as an attack. Declaring the correct `maxBytes` is refused too, because
  it is "above what the schema can reach".
- Evidence: measured.

  | schema | `maxSize` | actual bytes |
  |---|---|---|
  | `t.array(t.boolean, 0, 10)` × 10 | 1 | 11 |
  | `t.array(t.optional(t.u8), 0, 10)` × 10 | 11 | 21 |
  | `t.array(t.struct({ f = t.boolean, x = t.u8 }), 0, 10)` × 10 | 11 | 21 |

  A `nw.signal({ data = t.array(t.boolean, 0, 10), rate = 1000 })` channel refuses `{ true, false, true }`
  with `payload claims 4 bytes, over the 1 this channel can hold`. `tests/serdes_runtime.luau:363`
  round-trips this exact schema and asserts 5 bytes, so the encoder is right and the ceiling is wrong;
  no test compares the two.

### [중대] The pooled pending lists assume yielding handlers resume in LIFO order
- Location: `src/transport/Inbound.luau:172-173` (`pool`, `depth`), `:374-386` (`claim`), `:388-433` (`dispatch`)
- Problem: `claim` hands out `pool[depth]` and `dispatch` does `depth -= 1` when its loop ends. Roblox
  resumes yielded remote callbacks in whatever order their waits complete, not in nesting order. If
  batch A yields at depth 1, batch B arrives and yields at depth 2, and A resumes and finishes first,
  `depth` is back to 1 while B is still walking `pool[2]`. The next `claim` — a third batch, or
  `tick()` on the next frame with any intent pending — takes `pool[2]`, resets its `count` and
  overwrites the entries B has not reached.
- Impact: B's remaining packets are lost with no report, and whichever loop reads a slot the other
  already cleared indexes nil and raises `attempt to index nil with 'handler'` — an `error()` on the
  receive path from ordinary traffic — after which `depth` is never decremented. What does **not**
  happen: `dispatch` clears each slot before calling `call`, so an overwritten entry is dispatched
  exactly once, by whichever loop reaches it first, and the six arrays are written together so the
  entry it dispatches is still attributed to its real sender with its real value; the policy runs for
  it as usual. This is silent loss plus a throw, not duplicate execution or cross-player attribution,
  which is why it is `중대` and not `심각`. A third party controls the timing of the third batch, so
  the loss can be aimed at whichever player's handler happens to be parked. Any handler that yields
  (a DataStore read in a `signal` or `command` handler) with two players online is enough to reach it.
- Evidence: measured. Three batches of three packets on a yielding `signal` handler: alice yields,
  bob yields, alice resumes and finishes, mallory's batch arrives and dispatches normally, bob's resume
  raises `Inbound:315: attempt to index nil with 'handler'`. Delivered:
  `alice:1, bob:1, alice:2, alice:3, mallory:7, mallory:8, mallory:9` — bob's second and third packets
  never arrive and nothing reports them. A second run where mallory's first packet also yields shows
  bob's resumed loop delivering `mallory:7, mallory:8` once each, attributed to mallory, and mallory's
  own loop raising when it reaches the cleared slots — no entry is dispatched twice. `tests/transport_runtime.luau:1290-1370` tests exactly two
  batches resumed in LIFO order, which is the one interleaving that works.

### [위험] A throwing `link.send` in `flush` is retried every frame and starves every destination after it
- Location: `src/transport/Outbound.luau:370-392` (`flush`), `src/transport/Recipients.luau:183-192` (`select` copied without checking entries)
- Problem: `flush` does `Buffer.take()` and then `link.send`; `Buffer.saveInto(record)` runs only if the
  send returns. If it raises, the record keeps its old `buffer` and `used`, so the next frame loads and
  sends the same bytes again, raises again, and the `for destination, record in parked` loop never
  reaches the destinations iterated after it. `nw.audience.select` hands back whatever the game
  returned, so one non-Player entry is enough to reach this.
- Impact: one bad recipient silently stops delivery to a subset of players permanently, with a
  `PostSimulation` error every frame. Whether `FireClient` on a player who left between `publish` and
  `flush` raises in Roblox was not verified here; if it does, the same failure needs no game bug.
- Evidence: measured with a fake link whose `send` raises for one destination: three packets to
  `bad`, `good1`, `good2`; three consecutive `flush` calls each raise, and `good1`/`good2` are sent
  once on frame 1 and never again while `bad` is retried each frame.

### [경고] The send path raises on legal payloads above 16,383 bytes
- Location: `src/transport/Batch.luau:175-190` (`patchVarint`), `src/types/init.luau:402-425` (`t.string`/`t.buffer` "up to 65535 bytes"), `src/codec/Buffer.luau:1049-1066` (`readVarint` accepts five bytes)
- Problem: a `counted` frame's length is reserved as one byte and widened to at most two. A string,
  buffer or array the schema allows at 20,000 bytes encodes fine and then `patchVarint` calls `error`.
  The reader accepts up to five varint bytes, so this is a writer-only cap the type vocabulary does not
  know about.
- Impact: `send`/`publish` raise on a value the schema accepted; a query handler returning such an
  answer resolves the caller with `FAILED`.
- Evidence: measured. `Batch.writePacket` on `t.struct({ s = t.string })` with a 20,000-byte string
  raises `a packet field of 20002 does not fit two varint bytes`.

### [경고] Integer encodings silently truncate fractional values
- Location: `src/codec/Serdes.luau:301-330` (`numberWriter`)
- Problem: the range check passes `3.7` for `t.u8` and `buffer.writeu8` truncates it. With an offset
  encoding the result is not even truncation: `-0.4` on `t.i16(-100, 100)` becomes `99.6`, stored as
  `99`, read back as `-1`.
- Impact: the module header's "encode errors loudly … the alternative is silent wraparound" does not
  hold; a game sending a float where it meant an integer gets a different number on the other side
  with no report.
- Evidence: measured. `{ n = 3.7, m = -0.4 }` round-trips as `{ n = 3, m = -1 }`.

### [경고] Handler-less channels bypass `pendingPerBatch`
- Location: `src/transport/Inbound.luau:604-621` (`deliver` returns from `enqueue` before the ceiling check at `:655`)
- Problem: the pending ceiling exists because "every decoded value in a batch is live at once" (D-6).
  A packet on a channel with no handler is decoded and queued before that count is taken, so a batch of
  N such packets decodes all N regardless of the limit.
- Impact: on inbound classes the rate budget still bounds it; on outbound-class ids nothing does (see
  the second security finding).
- Evidence: measured. 600 packets, `pendingPerBatch = 256`, no `budget` refusal, 344 `queue` drops.

## Potential Bugs

### [경고] The client's protocol seals on the first inbound packet, and a namespace required later raises
- Location: `src/transport/Driver.luau:104-135` (`ensure` on `link.receive`), `src/api/Namespace.luau:121-128`
- Problem: the server broadcasts `state` as soon as a client's remotes connect. The client's first
  `Driver.install` (first `require(netweave)`) connects `OnClientEvent`, and the first batch to arrive
  calls `Namespace.seal()`. Any namespace module the client requires after that raises "declared after
  the protocol was sealed", and the hello already sent carries a hash over the partial set, so the
  server refuses that client at `protocol` for the session.
- Impact: a client whose namespace modules load across frames (a `WaitForChild`, a deferred require)
  fails deterministically under normal server traffic. The docstring says "declare every namespace
  before the first packet moves", but the client does not control when that packet arrives.
- Evidence: inferred from `ensure` being reachable from `link.receive`.

### [경고] `depth`, `filling` and `sender` are not unwound when the read or dispatch phase raises
- Location: `src/transport/Inbound.luau:705-726`
- Problem: `receive` restores its shared state after `Batch.read` and decrements `depth` at the end of
  `dispatch`, both without protection. Today the sidecar defect is the reachable trigger; any future
  raise inside the read phase inherits the same leak, and a raise inside a nested `dispatch` leaves the
  outer one's `depth` one too high for the rest of the session.
- Impact: pool growth and stale `filling` per raise, as measured under the first security finding.
- Evidence: inferred from the control flow; measured only through the sidecar path.

### [미미] `Trust.validate` leaves trial-encoded instances in the outgoing sidecar
- Location: `src/codec/Serdes.luau:1094-1107` (`check`), `src/codec/Buffer.luau:711-728` (`load` restores the count, not the entries)
- Problem: `check` saves and reloads the outgoing record, which restores `instanceCount` but does not
  nil the entries the trial write appended past it. `rollback` does; `load` does not.
- Impact: Instance references retained in `outgoingInstances` until the next write overwrites them.
- Evidence: inferred.

### [미미] `Recipients.roblox().owner` passes any non-Player Instance to `GetPlayerFromCharacter`
- Location: `src/transport/Recipients.luau:93-105`
- Problem: a `BasePart` or `Folder` subject reaches `Players:GetPlayerFromCharacter(instance :: Model)`.
  Whether Roblox raises on a non-Model argument was not verified in Studio for this report.
- Impact: if it raises, it does so inside `publish` from game code — a loud failure, not a silent one.
- Evidence: inferred, unverified.

## Documentation / Implementation Mismatches

### [위험] G4 "Wire data never reaches `error()`" is stated as unconditional and is not
- Location: `src/netweave.luau:36` (guarantee table), `docs/DESIGN-API.md` §2 and §9, `docs/WIRE-FORMAT.md` §6, `src/codec/Serdes.luau:18-25`, `CLAUDE.md` §9 ("Nothing on the receive path is silent")
- Problem: two measured paths raise on the receive side — a non-Instance sidecar entry, and the pooled
  pending list under non-LIFO resumption. `PLAN-M3` §1 states the milestone bar as "nothing a client
  can send … can throw".
- Impact: a reader of the guarantee table relies on a property that holds for the byte stream and not
  for the sidecar or the dispatch loop.
- Evidence: the two `중대` findings above.

### [경고] "The server is the sender on this class" is true of the views and not of the wire
- Location: `src/api/Channel.luau:212` and `:542` (`FORBIDDEN_REASON.rate`), `docs/DESIGN-API.md` §3 ("`rate`, `burst`, `maxBytes` — the server is the sender"), `docs/DESIGN-API.md` §2 G6
- Problem: the reason a `state` may not declare a rate is that nobody sends to the server on it. The
  server nevertheless resolves, admits, decodes and queues client packets on that id. G6 is enforced
  at analysis time on the views, not on arrival.
- Impact: the security argument for forbidding `rate` on outbound classes rests on a check that does
  not exist.
- Evidence: the second security finding.

### [경고] "A packet claiming more is provably a lie" is false for scoped elements
- Location: `docs/DESIGN-API.md` §3, `docs/milestone/PLAN-M3.md` D-5, `src/codec/Ir.luau:688-690`
- Problem: the ceiling is presented as an upper bound the schema proves. For any element that opens a
  bitfield it is below what the encoder itself produces.
- Impact: the derived limit refuses honest traffic and the plan records it as complete.
- Evidence: the `Ir.ceiling` table above.

### [경고] `t.string`, `t.buffer` and `t.array` document 65,535 while the writer frames at most 16,383
- Location: `src/types/init.luau:402-425`, `:564-580`, `src/transport/Batch.luau:181-186`, `docs/WIRE-FORMAT.md` §2
- Problem: the type vocabulary and the wire format describe a varint length with no stated writer cap;
  the cap lives in a `--[[ ]]` comment calling it "a design problem, not a runtime one" and is enforced
  with `error` at send time.
- Impact: a schema the library accepts describes payloads the library cannot send.
- Evidence: the 20,000-byte string probe.

### [경고] "Encode errors loudly" and "check an arbitrary value against a schema" overstate what the encoder checks
- Location: `src/codec/Serdes.luau:18-25`, `src/api/Trust.luau:212-237` (`validate` docstring)
- Problem: booleans, instances and fractional integers pass the encoder without a check, so
  `nw.validate` is a shape check for some kinds and a no-op for others.
- Impact: the escape hatch that mints `Trusted<T>` does less than its docstring says.
- Evidence: the `nw.validate` probe and the truncation probe.

### [미미] PLAN-M3 says the reply path is budgeted; the code says it is not
- Location: `docs/milestone/PLAN-M3.md:439` ("The reply path is a channel like any other: budgeted, observed, and unable to throw"), `src/transport/Outbound.luau:343-351`
- Problem: the plan's checkbox and the module comment contradict each other. The comment's argument
  (a reply is one-for-one with an admitted request) does not cover replies to *refused* requests.
- Impact: a reader of the plan believes a limit exists.
- Evidence: the two texts.

### [미미] "Under a flood the rejection path allocates nothing" is not what `Inbound` does
- Location: `src/api/Observer.luau:145-147`, `src/transport/Budget.luau`, versus `src/transport/Inbound.luau:465-471` and `:517-523`
- Problem: the observer and budget keep that promise; the queue-full and ceiling reasons in `Inbound` are
  interpolated per refusal.
- Impact: documentation only, plus the garbage measured above.
- Evidence: 11,744 reason strings for 12,000 packets.

## Summary
- 심각: 0
- 중대: 3
- 위험: 5
- 경고: 12
- 미미: 6

Total: 26 findings. The three `중대` items share one shape: a probe that the suite never wrote.
`hostile_runtime` mutates bytes and counts but never the sidecar's *contents*; `transport_runtime`
tests one interleaving of yielding handlers; `serdes_runtime` asserts the encoded size of
`t.array(t.boolean)` and nothing compares it to `maxSize`. Each fix is small, and each should land with
its probe run against the pre-fix code first, per `CLAUDE.md` §9.

## Appendix A — probes

Run from the repository root with `lune run <file>`. Paths are written for a file placed in
`spike/`; adjust the `R` prefix if it lives elsewhere.

### A.1 Ceiling against the encoder

```lua
local R = "../src/"
local Serdes = require(R .. "codec/Serdes")
local Buffer = require(R .. "codec/Buffer")
local t = require(R .. "types")

local function measure(label, schema, value)
	local codec = Serdes.fromSchema(schema)
	Buffer.load(nil)
	codec.write(value)
	local packed = Buffer.take()
	print(label, "maxSize=" .. codec.maxSize, "actual=" .. buffer.len(packed))
end

local ten = { true, true, true, true, true, true, true, true, true, true }
measure("array(boolean,0,10)", t.array(t.boolean, 0, 10), ten)
measure("array(optional(u8),0,10)", t.array(t.optional(t.u8), 0, 10), { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 })
```

### A.2 The receive path

```lua
local R = "../src/"
local Batch = require(R .. "transport/Batch")
local Budget = require(R .. "transport/Budget")
local Buffer = require(R .. "codec/Buffer")
local Inbound = require(R .. "transport/Inbound")
local Namespace = require(R .. "api/Namespace")
local Observer = require(R .. "api/Observer")
local Protocol = require(R .. "api/Protocol")
local Query = require(R .. "transport/Query")
local nw = require(R .. "netweave")
local t = require(R .. "types")

local mallory, alice, bob = { name = "mallory" }, { name = "alice" }, { name = "bob" }

Namespace.reset()
local d = Namespace.declare("p", {
	flags = nw.signal({ data = t.array(t.boolean, 0, 10), rate = 1000 }),
	part = nw.signal({ data = t.struct({ who = t.instance("Part") }), rate = 1000 }),
	anyInst = nw.signal({ data = t.struct({ who = t.instance }), rate = 1000 }),
	outState = nw.state({ data = t.struct({ n = t.u8 }), audience = nw.audience.everyone }),
	yielder = nw.signal({ data = t.struct({ a = t.u8 }), rate = 1000 }),
})
local protocol = Namespace.seal()

local reports, delivered, announced = {}, {}, 0
local budget = Budget.new(function() return 0 end)
local queries = Query.new({
	request = function() end,
	reply = function() end,
	spawn = function(f, ...) coroutine.resume(coroutine.create(f), ...) end,
	clock = function() return 0 end,
})
local agreement = Protocol.new({
	hash = function() return protocol.hash end,
	announce = function() announced += 1 end,
	isServer = true,
})
local inbound = Inbound.new({
	resolve = Namespace.channelById, admit = budget.admit, isServer = true,
	queries = queries, agreement = agreement,
})
Observer.reset()
Observer.setSink(function() end)
Observer.observe(function(r) table.insert(reports, { stage = r.stage, reason = r.reason }) end)

local function reset()
	table.clear(reports); table.clear(delivered); announced = 0
	Buffer.take(); Buffer.load(nil)
end
local function feed(instances, who)
	local packed, carried = Buffer.take()
	return pcall(inbound.receive, packed, instances or carried, who or mallory)
end

-- honest packet against the derived ceiling
reset()
d.channels.flags.handler = function(_, v) table.insert(delivered, v) end
Batch.writePacket(d.channels.flags, { true, false, true })
print("ceiling:", feed(), #delivered, reports[1] and reports[1].reason)

-- a table in the sidecar
reset()
d.channels.part.handler = function() end
Batch.writePacket(d.channels.part, { who = { fake = true } })
print("sidecar table:", feed({ { fake = true } }))

-- a number where an Instance was promised
reset()
d.channels.anyInst.handler = function(_, v) table.insert(delivered, v) end
Batch.writePacket(d.channels.anyInst, { who = 12345 })
feed({ 12345 })
print("sidecar number:", delivered[1] and delivered[1].who)

-- 600 packets on a state id
reset()
for i = 1, 600 do Batch.writePacket(d.channels.outState, { n = i % 256 }) end
feed()
print("state id:", #reports, "reports;", budget.usage(mallory, d.channels.outState))

-- 300 mismatched hellos
reset()
for _ = 1, 300 do Batch.writeHello(0xDEADBEEF) end
feed()
print("hellos:", announced, "announced,", #reports, "reports")
agreement.forget(mallory)

-- non-LIFO resumption
reset()
local suspended = {}
d.channels.yielder.handler = function(ctx, v)
	table.insert(delivered, ctx.player.name .. ":" .. v.a)
	if v.a == 1 then
		suspended[ctx.player.name] = coroutine.running()
		coroutine.yield()
	end
end
local function batch(...)
	for _, a in { ... } do Batch.writePacket(d.channels.yielder, { a = a }) end
	return (Buffer.take())
end
local A, B, C = batch(1, 2, 3), batch(1, 2, 3), batch(7, 8, 9)
coroutine.resume(coroutine.create(function() inbound.receive(A, nil, alice) end))
coroutine.resume(coroutine.create(function() inbound.receive(B, nil, bob) end))
coroutine.resume(suspended.alice)
print("C:", pcall(inbound.receive, C, nil, mallory))
print("bob:", coroutine.resume(suspended.bob))
print(table.concat(delivered, ", "))
```

### A.3 `flush` with a raising link

```lua
local R = "../src/"
local Outbound = require(R .. "transport/Outbound")
local Serdes = require(R .. "codec/Serdes")
local t = require(R .. "types")

local sent = {}
local link = {
	send = function(_, dest, packed)
		if dest == "bad" then error("FireClient failed") end
		table.insert(sent, tostring(dest))
	end,
	sendAll = function() end,
	receive = function() end,
}
local roster = { all = function() return {} end, owner = function() end, within = function() return 0 end }
local out = Outbound.new(link, roster)
local ch = { id = 1, qualified = "x.c", codec = Serdes.fromSchema(t.struct({ a = t.u8 })) }
out.push(ch, "bad", { a = 1 })
out.push(ch, "good1", { a = 2 })
out.push(ch, "good2", { a = 3 })
for frame = 1, 3 do
	print(frame, pcall(out.flush), table.concat(sent, ","))
end
```
