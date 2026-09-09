# Netweave Security & Correctness Report — M4

**Scope:** the whole of `src/` at commit `0cb731d` on `develop` (2026-09-05, "Write a struct of numbers in
one claim — M4 phase 7"), plus `docs/DESIGN-API.md`, `docs/WIRE-FORMAT.md`, `docs/SECURITY-REPORT.md`,
`docs/milestone/PLAN-M3.md` phase 9 and `docs/milestone/PLAN-M4.md`, and `CLAUDE.md`. The previous report
audited `7f5871c`; this one re-verifies its closure and audits everything M3 phase 9 and M4 added.

**Method:** six auditors ran in parallel, one per `src/` folder (`api`, `codec`, `transport`,
`replication`, `types` together with `src/netweave.luau`) and one for `docs/`. Each could read any file
its folder requires or is consumed by, but could report only on its own folder; anything it noticed
elsewhere went to the owning auditor as a dependency notice, and the two were reconciled here. Every
finding marked *measured* was reproduced under `lune` or `luau-lsp analyze` (with `LuauSolverV2`) against
the tree at `0cb731d`; *inferred* findings are labelled as such, per `CLAUDE.md` §7. Where two auditors
reached the same defect independently it is said so. Line numbers were verified with `grep -n` at
`0cb731d` by the auditing agent and spot-checked during synthesis.

**Baseline:** green. `lune run analyze` 52 files clean, the three rejection files at their declared
counts ~~(23 / 8 / 8)~~ (24 / 8 / 11 at `460aa41`), all eighteen `*_runtime` files pass (`replication_runtime` at ~~49%~~ 41% tagged, 17% honest — M4-1, PLAN-M4-BUG phase 6 — failure-path
against a declared floor of 30%), `tools/messages`, `bench/check`, `bench/envelope`, `selene src`,
`stylua --check` all pass. **None of what follows is caught by the suite.**

**Three axes added at the owner's request** beyond the previous report's shape: the type layer (type
errors, type insufficiency, and types that compile but do not guarantee what they exist for), optimization,
and an opinion on which types the vocabulary should gain.

## Severity
- 미미 — cosmetic, or a limit the documentation already states elsewhere
- 경고 — a real defect with a bounded blast radius, or a documented guarantee that is weaker than stated
- 위험 — a client can cause measurable harm without a game bug, or a type hole lets untrusted data reach an authoritative function without a spelled-out cast
- 중대 — a guarantee the library sells is broken, or ordinary traffic is refused or lost
- 심각 — remote code execution, cross-player data exposure, or authoritative state changed without a policy

## Previous report — closure verification

All 26 findings of `docs/SECURITY-REPORT.md` were re-checked against `0cb731d`. Every Appendix A probe
re-run reproduces the *fixed* behaviour, and three "confirmed to fail against the pre-fix code" claims were
checked by extracting the at-commit `tests/` over the pre-commit `src/` with `git archive` (801a6d5
`ir_runtime` 6 failures, f8799d3 `serdes_runtime` 8 failures and `hostile_runtime` "at direction:
expected 40, got 0", b86c584 `observer_runtime` 3 failures).

| # | Finding | Status |
|---|---|---|
| 1 | non-Instance sidecar throws and leaks | closed — `isInstance` before `:IsA` (`Serdes.luau:149-155`, `:1392`); refused per packet at `parse`; both guards at `Inbound.luau:549, 1014` |
| 2 | S→C ids decoded with no budget | closed — `direction` stage refuses before decode, both endpoints, all seven classes; 600 `state` packets → `direction=600`, `usage 0 0 0` |
| 3 | bare `t.instance` hands over the sidecar value | closed by the same check |
| 4 | hellos bypass budget, answered per hello | closed differently — bounded per peer (300 mismatched → 1 announce, 1 report); id 0 still runs before `admit` by design, which is where the new `RESYNC` kind matters (below) |
| 5 | refused query answered outside budget | declined with an argument that holds (`Outbound.luau:405-416`) |
| 6 | interpolated reason per refusal | closed in `Inbound`; one per-packet interpolation remains in `Batch.read:733` (below) |
| 7 | `nw.validate` brands non-conforming values | closed for boolean / integer / instance; **not** for the Roblox datatypes (below) |
| 8 | queued packets dispatched after leave | closed — ring compaction `Inbound.luau:1114-1147` |
| 9 | observer detaching during emit | closed — measured `A1,B1,C1,B2,C2` |
| 10 | ceiling omits per-element scope bytes | closed — `Ir.luau:709`; 3,000 random state schemas and 610 patch layouts, 0 over the ceiling |
| 11 | pooled pending lists under non-LIFO | closed — free list; three- and six-batch interleavings deliver exactly once, 0 reports |
| 12 | raising `link.send` retried, starves others | closed — no retry, no starvation, 3 fresh bytes on recovery |
| 13 | send raises above 16,383 | declined and documented in `WIRE-FORMAT.md` §2; the three `types/` docstrings and the `Batch.luau:211-212` comment phase 9 said it replaced are unchanged (below) |
| 14 | fractional truncation | closed — `FRACTIONAL` check; `-0.4` on `t.i16(-100,100)` refused |
| 15 | handler-less channels bypass `pendingPerBatch` | declined with an argument that holds within `rate × burst` and `queueCapacity` |
| 16 | client seals on first inbound packet | declined (not fixable); diagnosis written into `Namespace.luau:109-141` |
| 17 | `depth`/`filling`/`sender` not unwound on raise | closed — restored on both paths; nested raise probe keeps attribution |
| 18 | `validate` leaves instances in the sidecar | closed — `mark`/`rollback` |
| 19 | `owner` passes a non-Model | closed — `IsA("Model")` narrowing; Studio suite ran in phase 9, though `SECURITY-REPORT.md:345-347` still says it has not |
| 20–26 | the seven documentation items | closed as claimed, except 13/23 (65,535 docstrings) which is partial |

Nothing in this table is re-counted below; what follows is new.

## Current Security Risks

### [위험] A `RESYNC` control packet buys a full-state re-encode and resend every frame, outside every budget and the protocol verdict
- Location: `src/transport/Batch.luau:516-581` (control kinds read before `resolve` and `admit`), `src/transport/Inbound.luau:801-814` (`resync` clears the peer's baselines unconditionally), `src/replication/Baseline.luau:183-205` (`desync` has no cooldown or count), `src/replication/Tick.luau:144-156` (the next tick snapshots and diffs every visible subject against nothing)
- Problem: id 0 is read before `sink.admit`, so no rate is charged and `full` is not consulted; `agreement.verdict` is checked for `HELLO` only, so a protocol-refused peer can still send it. Every resync wipes that client's baselines for the channel, and the tick then deep-clones and encodes every subject in the client's audience. `PLAN-M4` phase 6 bounds it to "once per batch", which bounds the clear and not the per-frame cost. Found independently by the transport and replication auditors.
- Impact: a ~5-byte packet per frame per hostile client costs the server a diff-against-nothing encode for every subject that client can see and a full snapshot on its downlink, at 60 Hz, for the game's whole replicated state. Bounded by state size rather than by anything the client sends, which is what a budget exists to prevent.
- Evidence: measured. 100 subjects of `{ n = u8 }`, steady state 0 B/frame; a client resync every frame → `up=5 B, down=601 B` every frame (120x). 200 subjects: honest idle frame 0.48 ms, resync-each-frame 0.96 ms and 1,800 B to the asker. Mitigation: charge the resync to the peer's budget (or accept one per channel per second), and consult `verdict` before acting on any control kind.

### [위험] Zero-byte array and map elements re-open the D-4 amplification: allocation and loop count are unbounded by the packet
- Location: `src/codec/Serdes.luau:1185-1210` (`arrayReader`: the claim bound runs only when `perElement > 0`, and the loop runs `count` times), `:1225, :1236` (`mapReader`, same shape)
- Problem: the D-4 fix bounds the *pre-allocation* by `remaining()` but the loop still runs to the claimed count, bailing only on a rejection. An element that consumes no bytes, no scope byte and no instance never rejects: `t.enum({ x = true })` (zero bits), `t.string(0, 0)`, `t.buffer(0, 0)`, `t.array(T, 0)`, or a struct of only those. Nesting multiplies it, and the schema's own `maxSize` for `t.array(t.enum({ x = true }))` is 2, so the byte ceiling cannot help.
- Impact: roughly 1 KB of table per byte a client sends, and with a 60 KB packet on a nested schema on the order of 10⁹ loop iterations on the server. It needs a declared zero-byte element type, which is legal (a single-variant placeholder enum is ordinary).
- Evidence: measured.

  | claim | bytes | result |
  |---|---|---|
  | `array(boolean)` 65,535 (control) | 3 | `truncated`, bounded |
  | `array(enum{x})` 65,535 | 2 | accepted, 65,535 entries, 1.9 ms, +1,024 KB |
  | `array(buffer(0,0))` 65,535 | 2 | accepted, 65,535 `buffer.create(0)`, 7.5 ms, +2,047 KB |
  | `array(struct{e=enum{x}})` 65,535 | 2 | accepted, 8.0 ms, +6,144 KB |
  | `array(array(enum{x}))` 20 × 65,535 | 42 | accepted, 34 ms, +20,481 KB |

  Fix: in `lowerArray`/`lowerMap` treat an element whose worst-case cost is zero bytes and zero instances as carrying no information past count zero, and refuse `count > 0` for it — or cap `count` at `remaining()` whenever `perElement == 0`.

### [위험] A map whose key is `t.optional(...)` raises `table index is nil` on the receive path from one cleared bit
- Location: `src/codec/Serdes.luau:1254` (`result[entryKey] = entryValue`), `src/types/init.luau:608-619` (`t.map` accepts any type as a key)
- Problem: `t.map(t.optional(K), V)` type-checks with zero diagnostics, lowers, and encodes honestly — a Lua table has no nil key, so the presence bit is dead weight only a hostile packet can clear. When it does, `readKey` returns nil with no rejection and the assignment raises. It is the one path in the codec where wire data reaches a Luau error rather than `Buffer.reject`, and it contradicts the `Serdes` header (`:17-28`). Found independently by the codec and types auditors.
- Impact: G4 at the codec is broken. The read-phase guard at `Inbound.luau:1014` catches it and reports `the read phase raised: ...`, packets already read in that batch are still dispatched, and every packet *behind* it in the batch is lost — the sender's own, so the blast radius is bounded, which is why this is 위험 and not 중대. Keys of kind `struct`, `array` and `buffer` are also accepted and decode to fresh tables that never collide, so two entries with equal content arrive as two keys the receiver cannot look up.
- Evidence: measured. Honest encode of `{ [3] = 7 }` on `t.map(t.optional(t.u8), t.u8)` is `01 00 01 03 07`; with byte 2 cleared, `pcall(codec.read)` → `false, "Serdes:1254: table index is nil"`. Fix: reject a nil key in `mapReader`, and restrict map keys in `t.map` to `number`, `string`, `boolean` and `enum` (see Suggested types).

## Potential Security Risks

### [위험] The trust brand is silently dropped on any non-table payload type, which includes `t.optional(struct)` — the documentation exempts scalars only
- Category: Type-not-fit-for-purpose
- Location: `src/api/Trust.luau:98` and `:125` (`if not value:is("table") then return value end`), `src/api/View.luau:57` (`brandedAs`, the same test), `src/api/Trust.luau:178` (`TrustedPayload`)
- Problem: `types.copy(payload):is("table")` is false for a union, and `T?` is a union. A `signal` whose `data` is `t.optional(t.struct({...}))` hands its handler a plain `{ screen: number }?` with no `__nwUntrusted`; a `command` with the same shape hands over no `__nwTrusted`; `nw.Trusted<Req?>` reduces to `Req?`, so the two coincide. `DESIGN-API.md` §6 and both `:::caution` blocks state the limit as "scalar payloads are unbranded" only.
- Impact: a `signal` payload reaches a function annotated `nw.Trusted<Req?>` with no cast. The narrowed case (`if r then authoritative(r)`) is still refused because the narrowed table lacks the tag, so the hole is exactly the optional-typed authoritative parameter — and `nw.validate(t.optional(S), v)` returns an unbranded value too.
- Evidence: measured. A scratch file with `menuOpt:listen(function(ctx, r) authoritativeOpt(r) end)` produces no diagnostic, while the same code without `t.optional` produces `Expected '{ __nwTrusted: true } & { screen: number }' but got '{ __nwUntrusted: true } & { screen: number }'`. Fix: in `Trusted`, `Untrusted`, `TrustedPayload` and `brandedAs`, when `value:is("union")` brand each table component and `types.unionof` them back; until then, add the optional case to both cautions and §6.

### [경고] `nw.validate` returns the caller's table by reference with unschema'd keys inside it, and launders an `Untrusted<T>` into `Trusted<T>` without a cast
- Location: `src/api/Trust.luau:247-264` (`return (value :: any) :: TrustedPayload<S>`), `:228-231` (docstring: "validating it twice buys nothing")
- Problem: the encoder ignores keys the schema does not name, so `{ screen = 1, isAdmin = true }` validates against `t.struct({ screen = t.u8 })` and the same table comes back branded with `isAdmin` still in it. And `value: any` accepts an `Untrusted<T>` payload, so `nw.validate(Schema, untrusted)` is the `nw.untrust` §6 refused to ship, spelled as a call rather than a cast.
- Impact: a DataStore row's stray keys ride inside a `Trusted<T>` whose type says they are not there, and reviewers looking for `:: nw.Trusted` will not find this route.
- Evidence: measured. `extra fields accepted: true, same table: true, isAdmin rides: true`; a scratch handler doing `local v = nw.validate(Schema, r); authoritative(v)` on a `signal` payload compiles with no diagnostic.

### [경고] The channel record is mutable after seal, and its policy and budget fields are typed read-write through `Views<D>.channels`
- Category: Type-not-fit-for-purpose
- Location: `src/api/Channel.luau:90-116` (`rate`, `authorize`, `maxBytes`, `handler` all writable), `src/api/Namespace.luau:192-197` (`channels` is the caller's table, unfrozen), `:244-282` (`seal` freezes nothing), `src/transport/Inbound.luau:290-294` (nil `authorize` is allow), `src/transport/Budget.luau:83`, `src/transport/Batch.luau:609`
- Problem: `ns.channels.c.authorize = nil`, `.rate = 1e9`, `.maxBytes = 1e9`, `.handler = fn` all type-check with no cast, and the transport reads each of these per packet. A direct `handler` write also bypasses `attach`'s single-handler guard and `Transport.dispatch`. Declaring another key on the declaration table after `nw.namespace` and before seal numbers a channel whose `qualified` is `""`.
- Impact: G1 and G2 can be switched off by one typed line after declaration — game code, so not 위험, but it is the one route that defeats "a forgery you have to write is one a reviewer sees" without a `:: any` for `grep` to find.
- Evidence: measured. `channels frozen? false`, `channel frozen? false`, `after mutation authorize: nil rate: 1000000000`; seal after a late key → `channelById(1).qualified: ""`. Fix: copy-then-freeze `channels` in `declare`, freeze each record at seal (keep `handler` in a side table), and mark the fields `read` in `Channel<...>`.

### [경고] `isType` is a duck check, so a hand-built table bypasses every constructor invariant and reaches the codec, the channel and `nw.validate`
- Category: Type-not-fit-for-purpose
- Location: `src/types/init.luau:500-502` (`isType`), `src/api/Channel.luau:474-481` (`requireType`, the same test), `src/api/Trust.luau:246`
- Problem: any table with a string `kind` passes `t.optional`, `t.array`, `t.map`, `t.struct`, `requireType` and `validate`. Every invariant the constructors enforce — `MAX_LENGTH`, encoding spans, non-empty enums, sorted unique `order`, `encoding` present — is therefore advisory. The analyzer half is stricter (a literal needs `__payload`), which is the wrong way round for a runtime library.
- Impact: game-side only, but silent: `order = {"a","a"}` double-encodes, a string `max` of 2^31 gives a 2 GB ceiling the `maxBytes` policy is measured against, `variants = {}` lowers to zero bits, and `nw.validate(bogus, 5)` mints a `Trusted`.
- Evidence: measured for all five shapes. Fix: a private brand — a weak set of constructed descriptors, or a frozen sentinel field — costs nothing per packet.

### [미미] `readVarint` wraps a five-byte value above 2^32 silently
- Location: `src/codec/Buffer.luau:1091-1108`
- Problem: the fifth byte's seven bits are shifted by 28 through `bit32`, which is mod 2^32 ([luau.org/library](https://luau.org/library): operands are treated as 32-bit unsigned), so `80 80 80 80 7F` reads as 4,026,531,840 with no rejection. Every consumer bounds the result afterwards, so nothing is reachable through it today.
- Evidence: measured (`-> 4026531840 rejected: nil`).

### [미미] `nw.internal` is `@private` in prose only, and the modules behind it are unfrozen
- Location: `src/netweave.luau:366-382`
- Problem: `nw.internal.transport.uninstall()`, `namespaces.reset()`, `observer.setSink`, `context.setGuarded`, `config.reset` are typed, autocompleted and one call away; `Config`, `Transport`, `Context`, `Observer`, `Namespace` and `View` all return unfrozen tables, so their functions are reassignable from any script that can require the module. Only `nw`, `nw.internal` and `t` are frozen.
- Evidence: measured (analyzer accepts the calls; each module's `return` read).

## Current Bugs

### [중대] The client applies `pendingPerBatch` to the server's own batch, so a `replicate` channel with more than 256 subjects visible to one client never converges
- Location: `src/transport/Inbound.luau:883-890` (deliver ceiling), `:940-951` (change ceiling → `desync`), `:727-729` (`admit` refuses everything once `full`), `:971-973` (every refused change desyncs), `src/replication/Tick.luau:169-210` (one change per subject per recipient per tick, no per-client cap), `src/replication/Baseline.luau:183-205` (`desync` wipes the whole channel, including subjects just applied), `src/transport/Outbound.luau:437-477` (`flush` sends everything parked as one batch)
- Problem: `pendingPerBatch` was designed against an untrusted client (D-6) and `Inbound.new` applies it identically on the client, where the peer is the server. The writer has no matching bound: `Tick` writes one change per subject the client lacks into that frame's batch. Past 256 the client sets `full`, refuses the rest at `budget`, desyncs the channel (clearing the 256 it just applied), sends `RESYNC`, the server clears its baselines and resends everything next tick. Found independently by the transport and replication auditors with two different rigs.
- Impact: any `replicate` channel with >256 subjects visible to one client (a lobby of 300 items, an `everyone` audience over a 300-entity world) never replicates and burns a full snapshot per frame per client for the life of the session, with `budget` and `replicate` refusals every frame. Both defaults are 256, so `baselinesPerClient` is hit at the same size and adds a whole-subject re-send per frame for each subject over it. Independently of replication, a frame in which the server sends >256 `nw.state`/`nw.event` packets to one client loses the tail on the client, reported only on the client's console against the server. Ordinary traffic lost, and the milestone's deliverable does not work at scale.
- Evidence: measured (real `Tick`, `Outbound`, `Inbound`, `Baseline`, loopback link, default config, nothing changing after frame 1):

  | subjects | every frame |
  |---|---|
  | 256 | frame 1: 1,537 B, mirror 256/256; frames 2+: 0 B |
  | 257 | 1,543 B down, mirror 256, `budget=1 replicate=1 resyncs=1`, both sides hold 0 |
  | 300 | 1,801 B down, 177 B up, mirror 256/300, 44 refusals, 44 resyncs, both sides hold 0 |
  | 300 with `pendingPerBatch = 512` | converges to 300; server holds 256 and re-sends 44 whole subjects (265 B) every frame — `baselinesPerClient` |
  | 300 `nw.state` publishes to one player in one frame | delivered 256, 44 `budget` refusals on the client, server sees nothing |

  Fix direction: exempt the trusted peer (sender `nil`) from the ceiling on the client, or bound packets per batch per destination in `Outbound.flush`/`Tick` (split across sends); and in any case desync once per channel per batch, not per packet.

### [중대] The protocol hash omits a `replicate` channel's `subject` schema
- Location: `src/api/Protocol.luau:178-190` (`signatureOf` describes `data` and `returns` only), `src/api/Channel.luau:1099-1112` (`subjectCodec` built beside the state codec, never handed to `Protocol`); documented as covering "the lowered node tree of every schema the channel carries" at `docs/WIRE-FORMAT.md:260-262` and `src/netweave.luau:294-295`
- Problem: a change packet on the wire is subject bytes followed by the patch (`src/transport/Batch.luau:316, :753`), but the signature never walks `channel.subjectCodec.layout`. Two builds whose `replicate` channels differ only in `subject` hash identically and print byte-identical `nw.signature()` text. This is exactly the D-7 failure class M3 phase 5 closed for field types, reproduced by the new class. Found independently by the api and docs auditors.
- Impact: a stale client on `subject = t.u8` against a server on `t.u16` says hello, is accepted at stage `protocol`, and then mis-reads every change packet for the session — one subject byte short, so the patch flags land in the wrong place. For subject ids below 256 the byte read as the flags is `0x00`, which decodes as a **removal**: a well-formed packet that reaches the handler. The docs auditor rated this 경고 on the ground that §4 calls the hash a skew detector and not a security boundary; it is rated 중대 here because the detector's one job is this case and a decodable-but-wrong value reaches game code.
- Evidence: measured. `subject u16 -> u8 moves hash: false`, `subject u16 -> struct moves hash: false`, `data u8 -> u16 moves hash (control): true`; `base maxBytes: 4, subjectChanged maxBytes: 3` shows the wire size differs while the hash does not. `tests/protocol_runtime.luau`'s attribute walk cannot see it because `subject` is a second layout, not a node attribute. Fix: `describeLayout("subject", channel.subjectCodec and channel.subjectCodec.layout, out)` plus a protocol test that changes the subject alone; consider the patch layout's `framing/maxSize` as a cross-check line.

### [중대] `t.f32(min, max)` refuses honest values at a bound that is not exactly representable in f32
- Location: `src/codec/Serdes.luau:1038-1051` (float reader compares the f32-rounded value to double bounds), `:352, :365` (writer validates the unrounded double), `src/codec/Ir.luau:307-317` (`lowerNumber` carries the double bounds unchanged), `src/types/init.luau:298-322` (`ranged` keeps the double)
- Problem: the writer checks `value <= max` on the double, then `buffer.writef32` rounds it. If `max` itself is not an f32 value, rounding can land above `max` (f32(0.1) = 0.10000000149, f32(π) = 3.14159274), and the reader rejects it with `number out of range`; likewise at `min`. Only values within one f32 ulp of a non-dyadic bound are affected — which is exactly the clamped value a game sends (`math.clamp(yaw, -math.pi, math.pi)`). Found independently by the codec and types auditors.
- Impact: ordinary traffic refused at stage `parse` against its own sender on any `t.f32` whose bound is not a dyadic rational; the worked example's `t.f32(-90, 90)` happens to be exact. The refusal is counted in `nw.diagnostics()` as a hostile-looking rejection.
- Evidence: measured. `t.f32(-π, π)` at π and at −π → `nil, number out of range`; `t.f32(0, 0.1)` at 0.1 and `t.f32(0, 0.3)` at 0.3 the same; `t.f32(0, 1)` at 1 and `t.f64(0, 0.1)` at 0.1 round-trip (controls); over 4,000 random f32 ranges, 1,935 bound values refused on read. Fix: snap bounds through an f32 round-trip at lowering (`min` down, `max` up), or compare the reader's value against rounded bounds.

### [경고] A nested `Observer.emit` overwrites the shared record for the outer emit's remaining observers
- Location: `src/api/Observer.luau:334-358` (`emit` fills `record` at `:335-339`, iterates at `:347-353`, restores nothing after a nested emit)
- Problem: `emitting` guards compaction, not the record. If observer *k* provokes a refusal synchronously, the nested `emit` refills `record` and observers *k+1..n* of the outer rejection are handed the inner one's channel, stage and reason.
- Impact: an observer that calls `invoke` on the client with `callsInFlight` exhausted (`Query.luau:172` emits synchronously) or any future synchronous refusal path reached from game code misreports the outer rejection to every later observer, silently.
- Evidence: measured. Observer I emits an inner rejection from inside the outer one; J records `Iouter, Jinner, Jinner` — J saw `inner` for both. Fix: snapshot the five fields to locals before the loop and refill when `emitting` was already positive on entry.

### [경고] Integer bounds are not required to be integers: `t.u8(0.5, 2.5)` corrupts values and `t.array(x, 1.5)` declares a channel that can never send
- Location: `src/types/init.luau:304-316` (`ranged.__call`), `:581-597` (`t.array`)
- Problem: `ranged` checks type, order and encoding span but not integrality, so a fractional bound yields `offset = 0.5`; the writer's whole-number test passes `1`, `buffer.writeu8(1 - 0.5)` truncates, and the reader adds the offset back. `t.array(t.u8, 1.5)` lowers to `count = 1.5` and the writer refuses every length.
- Impact: a schema the library accepts silently delivers a different number than was sent — the failure phase 9 closed for fractional *values* — or a channel that cannot send.
- Evidence: measured. `t.u8(0.5, 2.5)`: sent 1 → got 0.5, sent 2 → got 1.5, no rejection; `t.array(t.u8, 1.5)` lowers (`maxSize = 1.5`) and refuses `{7}` and `{7, 8}`.

### [경고] Floats are capped at ±2^24 / ±2^53 and the docstrings do not say so
- Location: `src/types/init.luau:260-261` (`ENCODING_RANGE.f32/f64`), `:378-390` (docstrings: "A single-precision float", "A double-precision float")
- Problem: the cap is f32's *integer-exact* span, not its value range (±3.4e38). Floats are never narrowed, so the cap does no layout work — it only validates, and validates the wrong thing. Bare `t.f32` refuses `1e8`; bare `t.f64` refuses `1e18`; `t.f32(0, 1e9)` is refused at declaration.
- Impact: a squared distance, a currency balance, or a scaled clock cannot be declared, and the refusal arrives at send time with a range the author never wrote.
- Evidence: measured (`f32 1e8 → outside the declared range -16777216..16777216`; `f64 1e18 → outside … -9007199254740992..9007199254740992`).

### [경고] A failed `nw.namespace` leaves the earlier channels tagged with `qualified`, so the corrected redeclaration is refused with the wrong message
- Location: `src/api/Namespace.luau:149-181` (`key`/`qualified` assigned inside the validation loop, before the namespace is registered)
- Problem: when a later key fails (`b = 5`), the raise leaves `a.qualified = "mix.a"` with no namespace holding it; re-declaring `a` in a fixed table raises `mix2.a is already declared as mix.a`.
- Evidence: measured. Fix: validate every key, then assign.

### [경고] `t.struct` keeps the caller's `fields` table by reference, unfrozen — and the type says every field is writable
- Location: `src/types/init.luau:643-658` (`fields = fields :: any`), `:294-296` (comment: "nothing is mutated after definition"), `:126-141` (`Type<T>` has no `read` modifiers)
- Problem: the descriptor is frozen but `.fields` is the original table; `f.id = t.string` after `t.struct(f)` changes what a codec built later encodes, and `s.fields.id = t.string` compiles. `tests/types_runtime` asserts `isfrozen` on the descriptor only.
- Evidence: measured (`fields frozen false, same table true`; after mutation `codec.check({ id = "text" })` → nil).

### [경고] Over the `baselinesPerClient` limit a subject is re-sent whole and reported every frame, not "what `nw.state` does"
- Location: `src/replication/Baseline.luau:145-148` (docstring: "degrades to what `nw.state` does for a living"), `:153` (report per subject per tick), `src/replication/Tick.luau:153-155` (deep clone before `keep` refuses it)
- Problem: `nw.state` sends when the game publishes; a refused baseline makes the tick send the whole subject every frame with nothing changing, deep-clone it every frame and discard the clone, and emit a refusal every frame (console-suppressed after three, but every one reaches `nw.observe`).
- Evidence: measured (`baselinesPerClient = 2`, 5 subjects, store untouched: 31 B and 6 reports per idle frame, climbing).

### [경고] A departed player's baselines are recreated after `forget` and never released
- Location: `src/replication/Tick.luau:144-156` (`send` keeps a baseline for whoever the audience names, with no check against `roster.all()`), `:206-210, :216-222` (both removal passes walk `roster.all()` only), `src/replication/Baseline.luau:103-113` (`channelsOf` recreates the record)
- Problem: if the store still lists the departed player's subject for one more tick (the game's own cleanup yielded on a profile save), `owner`/`select` still names the `Player` instance, the tick recreates `records[player]` with a snapshot, and once the subject disappears nobody drops it. The worked example in `DESIGN-API.md:190-194` (`audience = owner, store = of(byPlayer)`) is exactly this shape.
- Evidence: measured (`held by alice after forget: 0 → one tick later: 1 → after the subject is gone: 1`).

### [경고] Game code raising inside the replication tick aborts the frame's flush for every channel
- Location: `src/replication/Tick.luau:169-178` (`store.subjects()`, `store.read()`, `audience.select` unguarded), `:119-133` (`snapshot`: `table.clone` raises on a protected metatable), `:176` (`present[subject] = true` raises on a NaN subject), `src/transport/Driver.luau:189-193` (`outbound.flush()` runs after `replicate()`)
- Problem: `Outbound.change` pcalls the encode "because re-raising would take down every other channel in that tick" (`Outbound.luau:279-285`), but the calls into game code around it are not guarded. A raise escapes `Tick` and the frame's batches for every channel stay parked; a persistently raising store or selector stalls all outbound traffic.
- Evidence: measured (`tick raised … packets flushed after the raise: 0`; NaN subject → `Tick:176 table index is NaN`; protected metatable → `Tick:124 invalid argument #1 to 'clone'`).

### [경고] The client handler receives the client's baseline table itself; mutating it silently corrupts every later patch
- Location: `src/replication/Delta.luau:226-229, :312-348` (the merger's result shares every untouched subtree with the baseline and is used as both the new baseline and the handler's value), `src/transport/Inbound.luau:937, :956` (`store.keep(…, value)` then `values[count] = value`)
- Problem: nothing in the `replicate` docstrings says the value is read-only. A game that writes to it (client prediction, `value.hp -= 1`, the `Replica.Data` habit) changes the baseline; the next patch carries only the fields the server changed and the rest come from the corrupted base.
- Evidence: measured (`handler value is the client baseline table: true`; after `seen.hp = 3` and a gold-only patch: `server hp=10, client sees hp=3`). Fix: a documented read-only contract or a defensive copy at the handler boundary.

### [경고] `nw.signature()` and `nw.protocol()` seal the protocol as a side effect, and the docstring says to print it
- Location: `src/netweave.luau:289-337` (both docstrings), `src/api/Namespace.luau:295-297`
- Problem: "Print this on both sides and diff it" is the advertised affordance; neither docstring says the call fixes the id numbering, so a game that prints it in its bootstrap before a later-required module declares its namespace has that declaration raise.
- Evidence: measured (`nw.signature()` then `nw.namespace("second", …)` → `declared after the protocol was sealed`).

### [경고] The Roblox-datatype writers accept what the readers refuse, so `nw.validate` brands NaN and non-unit vectors
- Location: `src/codec/Serdes.luau:947-985` (vector2/vector3/color3/cframe writers: no finiteness or unit check) versus `:1302-1330, :1343-1355` (readers reject non-finite and non-unit), `src/codec/Serdes.luau:986-1000` (instance writer checks `isInstance` but never `class`)
- Problem: `t.unitVector3` and finiteness are enforced on decode only. The phase-9 principle "the encoder stopped treating 'did not raise' as 'conforms'" was applied to booleans, instances and integers only.
- Impact: `nw.validate(schema, { direction = Vector3.new(400, 0, 0) })` returns a `Trusted<T>`; a server that publishes a NaN position, a zero-length "unit" vector, or an instance of the wrong class sees no error — every client refuses the packet at `parse` and the server never learns.
- Evidence: measured (`vector3 check NaN: nil`, `unitVector3 check magnitude 400: nil`, `cframe check NaN position: nil` — all "conforms").

### [경고] A `replicate` change past the 16,383-byte frame cap is reported and retried every tick, forever
- Location: `src/transport/Outbound.luau:288-301` (`change` reports and returns false; the baseline is not advanced), `src/transport/Batch.luau:204-219` (`patchVarint` raises)
- Problem: `WIRE-FORMAT.md` §2 documents the cap as a `send`-time raise; on the tick there is no call site to raise at, so the failure mode is a per-tick report (suppressed after three) and a subject that never arrives while the client's ceiling says it would accept it.
- Evidence: measured (`t.struct({ s = t.string })` with 20,000 bytes → `change x5: false`, 5 reports `a packet field of 20004 does not fit two varint bytes`). Fix: refuse at declaration when `delta.layout.maxSize + subjectCodec.maxSize > 16383`, or drop the subject with a distinct reason and advance.

### [미미] `Baseline.keep(…, nil)` removes the entry but keeps the count
- Location: `src/replication/Baseline.luau:139-141`; the type at `:68` (`value: any`) permits it
- Problem: the replace branch assigns nil and returns without decrementing; the next `keep` counts it again. No current caller passes nil.
- Evidence: measured (`after keep(nil): of = nil, held = 1; re-keep: held = 2`).

### [미미] `Protocol.Agreement.forget` bypasses `keyOf`, so `forget(nil)` raises where every other method maps nil to the server sentinel
- Location: `src/api/Protocol.luau:379-381` versus `:315-317`
- Evidence: measured (`table index is nil`). No caller passes nil today.

### [미미] `closeBlock` reports an overrun as a negative shortfall
- Location: `src/codec/Buffer.luau:201-205`
- Problem: "short by -N bytes" when a writer wrote past its claim; the overrun also wrote into unclaimed space before the check ran.
- Evidence: measured.

### [미미] Color3 with NaN or out-of-range components encodes a platform-specific byte
- Location: `src/codec/Serdes.luau:962-969`
- Problem: `math.clamp(NaN, 0, 255)` is NaN and `buffer.writeu8(NaN)` is platform-specific ([luau.org/library](https://luau.org/library)); `G = 2` clamps to `ff` silently rather than raising as every number field would.
- Evidence: measured (`{ R = 0/0, G = 2, B = -1 }` → `00 ff 00`).

### [미미] `t.instance(className)` accepts any string, including `""`
- Location: `src/types/init.luau:480-498`
- Problem: only `type(className) == "string"` is checked; `Instance:IsA` with an unknown class returns `false` (inferred), so a typo refuses every honest packet on that channel at `parse`, attributed to the sender.
- Evidence: measured for acceptance; inferred for `IsA`.

### [미미] An unknown stage or rule name is silent, contrary to §9 "nothing on the receive path is silent"
- Location: `src/api/Config.luau:699-701` (`severityOf` returns `"off"` for an unknown name), `:727-729` (`limitOf` returns nil typed `number`)
- Problem: a stage added to `Observer.Stage` and not to `RULES` reports nothing by default. None today — `direction` and `replicate` are complete on both sides — but it is the hand-kept-list drift §9 warns about with no test on this pair.
- Evidence: measured (`severityOf('bogus'): off`, `limitOf('bogus'): nil`).

## Potential Bugs

### [경고] A joining client's first snapshot is believed delivered whether or not its client has connected
- Location: `src/replication/Tick.luau:144-156` (baseline kept the moment the change is written), `src/replication/Baseline.luau:210-214` (nothing re-clears on the client's hello)
- Problem: a player is in `Players:GetPlayers()` before their scripts have required netweave and connected `OnClientEvent`. Roblox queues events fired before a connection exists, but the queue is bounded ("Remote event invocation queue exhausted"); with a batch per frame on a changing world a slow join can overflow it. A subject whose snapshot was lost that way is never re-sent until it *changes* — a static subject stays invisible for the session.
- Evidence: inferred — queueing from [the remote-events docs](https://create.roblox.com/docs/scripting/events/remote) and [this devforum thread](https://devforum.roblox.com/t/remote-event-invocation-queue-exhausted-did-you-forget-to-implement-onclientevent-error/2338546); the no-resend-until-change half follows from `Delta.write(base, current)` returning false at `Tick.luau:144`. Treating the client's hello as "start this player from nothing" would close it.

### [경고] A raise inside the dispatch loop drops the rest of the batch with a report that names no channel, no player and no count
- Location: `src/transport/Inbound.luau:548-556` (`dispatch`), `:492-516` (`walk` has no per-entry guard)
- Problem: `walk` is one `pcall`; the guard protects state, not the remaining entries. G5 is per packet in the read phase and per batch here.
- Impact: whatever raises in `call`/`queries.*` outside the `xpcall`s — today only an injected fault — loses every packet behind it, and the report is `handler ? nil 0`.
- Evidence: measured with an injected raise in `queries.enter`: delivered `alice:1` only, one report `dispatch raised: …` attributed to `?`; the next batch is clean and a batch parked in another coroutine is intact. Fix: guard per entry, or resume at `index + 1` with a report per skipped entry.

### [경고] `nw.audience.select` results with holes raise or silently skip; non-Player and departed entries create parked records that are never forgotten; duplicates send twice
- Location: `src/transport/Recipients.luau:200-212` (copies `1..#chosen` unchecked), `src/transport/Outbound.luau:157-178` (`switchTo` creates a record for any key; the nil-destination hazard is named at `:75-82` and not guarded), `:481-489` (`forget` only runs from `PlayerRemoving`)
- Problem: `#` over a table with holes is unspecified in Luau, so the outcome depends on how the game built the list; every bogus value leaks one `Buffer.Save`; a departed `Player` still named by a stale list recreates its record after `forget`, and `FireClient` on a departed player is silent ([devforum](https://devforum.roblox.com/t/does-remoteeventfireclientplayer-ever-fail/3103421)), so nothing reports it.
- Evidence: measured (`{alice, nil, bob}` → `Outbound:173: table index is nil`, alice sent, bob not; `{nil, bob}` → only bob; `{alice, alice}` → the packet twice; 5,000 publishes to fresh bogus destinations → +5.5 MB retained).

### [경고] The install guard distinguishes lune from Roblox, not run mode from edit mode
- Location: `src/netweave.luau:77-79` (`if typeof(game) == "Instance" then Driver.install()`)
- Problem: in Studio edit mode `game` exists and `RunService:IsServer()` is true while `IsRunning()` is false ([RunService reference](https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/classes/RunService.yaml)). `Driver.install` then takes the server branch of `Link.roblox()` — `Instance.new("Folder")` and two remotes under `ReplicatedStorage` — and connects `PostSimulation`. A plugin, a command-bar `require`, or test tooling that loads netweave in edit mode inserts the remote folder into the open place, where a save persists it.
- Evidence: inferred (docs plus code read; not executed in Studio). An `IsRunning()` check is one line.

### [미미] The server's protocol also seals on the first client packet
- Location: `src/transport/Driver.luau:163-169` (`link.receive` → `ensure()`), `src/transport/Link.luau:355-358` (remotes exist from install)
- Problem: a client whose hello arrives while the server is still yielding before a later namespace module seals the server, and that `declare` raises. Phase 9 corrected the docs for the client side only.
- Evidence: inferred from control flow.

### [미미] `check()` inside an open block corrupts the block's cursor
- Location: `src/codec/Serdes.luau:1571-1588` (`check` → `rollback` sets `blockDepth = 0` but not `blockCursor`), `src/codec/Buffer.luau:178-184, :738-746`
- Problem: a static codec's `check` calls `openBlock`, which overwrites the outer `blockCursor`. Reachable only if game code calls `nw.validate` from inside a value's `__index` or `ToAxisAngle` during an encode — contrived, recorded so it is not rediscovered.
- Evidence: measured (`closeBlock after: false, short by -4 bytes`).

## Type Errors

### [중대] Annotating a namespace with the exported `nw.Views<D>` silently erases G3, G6 and every payload type for that value
- Location: `src/netweave.luau:285-287` (`nw.namespace` return type), `:362` (`export type Views<D> = View.Views<D>`), `src/api/View.luau` (`Views<D>` itself — reproduced through `View.Views` directly)
- Problem: `local ns: nw.Views<typeof(decl)> = nw.namespace(...)` — or `local _v: nw.Views<typeof(ns.channels)> = ns` — makes `ns` reduce to an unreduced `Views<decl>` whose `.server.fire` is an error type. Afterwards `ns.server.fire:send(...)`, `:publish` on a `replicate`, `:broadcast` on a non-everyone audience, and a wrong-typed field read all compile. The effect is whole-file and retroactive: a `:send` on the line *above* the annotation also stops erroring. Writing the alias alone (`type V = nw.Views<...>`) is harmless; assigning through it is the trigger. Nothing in `tests/` ever writes `Views<`, so `api_reject`'s count cannot see it.
- Impact: the first game that types a namespace parameter or a module-level local — exactly what a re-exported alias invites — loses G3 and G6 with no diagnostic. This is the spike Q5 failure class ("silent, looks like success") reached through the public alias rather than through an unreferenced type function.
- Evidence: measured with `luau-lsp analyze --flag:LuauSolverV2=true`. The control (alias declared, not assigned through) reports `Key 'send' not found in table '{ listen: ... }'` and `Expected this to be 'string', but got 'number'`; the same file with `local _v: nw.Views<typeof(ns.channels)> = ns` reports nothing but an unused import. A third variant (`local _n2: number = ns.server.fire`) also reports nothing, while `local _n1: number = ns` still reports `Expected 'number', but got 'Views<decl>'`.

### [위험] `t.PayloadOf` never reduces; on the direct-require path it is a silent error type, and on the documented path it does not exist
- Location: `src/types/init.luau:143-161` (`PayloadOf`), `:10-18` and `:149-151` (docstring examples)
- Problem: `PayloadOf` is the one `export type function` in the module that the module itself never references (`StructPayload`/`EnumPayload` are pinned by the `t.struct`/`t.enum` signatures), so per `spike/declare/README.md` Q5 it does not reduce across a `require`. Via `require("…/types")`, `type Shot = t.PayloadOf<typeof(shot)>` yields an error type: `local _bad: Shot = { origin = "no", seq = "no" }` compiles with no diagnostic, and `t.PayloadOf<number>` — which should print "expected a netweave type" — prints nothing. Via the path the docstring prescribes (`require(Packages.netweave).types`), it is `Unknown type 't.PayloadOf'`, because type aliases do not flow through a property access; `t.Type<T>` is unreachable the same way.
- Impact: every game function annotated with the documented payload alias is unchecked, and feeding the error type to `Trusted<Shot>` produces `Type functions do not currently support types of the form '*error-type*'` in the game's file with no hint at the cause.
- Evidence: measured (scratch lines with wrong-typed assignments: no diagnostic; the `.types` path: `Unknown type 't.PayloadOf'`). Fix is the shape `Trust.luau:144-145` already uses: a local instantiation alias.

### [위험] `CheckedSettings` refuses any argument typed `nw.Settings`, `Config.Rules` or `Config.Limits`
- Location: `src/api/Config.luau:367` (`if not declared:is("table")`), `:344` (`isNumber` = `value:is("number")`), `:380` (`guard:is("boolean")`)
- Problem: `Settings.rules` is `Rules?`, `Limits.queueCapacity` is `number?`, `contextGuard` is `boolean?` — each a union at the type level — and the three checks test for the bare tag, so the optional wrapper the library's own types put on every field is what the type function rejects. Only `isSeverity` anticipates a union.
- Impact: `local s: nw.Settings = {...}; nw.configure(s)` is a type error, and so is `nw.configure({ limits = lim })` for `lim: { queueCapacity: number? }`. The exported `nw.Settings` cannot be used to build the argument it names; the runtime accepts the same value. The message is `takes a table of rules, got that` — `named()` falling through for a union, so it does not even say what was wrong.
- Evidence: measured (`'CheckedSettings' type function errored at runtime: … nw.configure: \`rules\` takes a table of rules, got that`; `limit \`queueCapacity\` takes a number, got that`). Fix: when `declared:is("union")`, strip `nil` from `components()` and check the rest; add `nw.configure(s)` with `s: nw.Settings` to `tests/config_ok.luau` — the missing `_ok` half of the exported type.

### [경고] A plain-table `audience` with a widened `scope` crashes the view type functions inside netweave's source and erases every channel in the namespace
- Location: `src/api/Channel.luau:448-472` (`OutboundScope` returns `scope` without checking it is a singleton), `src/api/View.luau:77` (`:value()` on `__audience`), `src/api/Channel.luau:655-668` (`requireAudience` checks `type(scope) == "string"` only)
- Problem: `{ scope = "everyone", kind = "owner" }` gives `scope: string`; `channelView` calls `:value()` on it and the type function raises `[string "channelView"]:77: type.value: expected self to be a singleton` — reported against netweave's own module, the class of message D-7 says a user cannot act on — and the whole `ServerView` fails to reduce, so a correct channel in the same namespace also becomes `does not have key`. The runtime accepts the same table, and with `kind = nil` `Recipients.of` falls through to `audience.select(subject)` on a nil.
- Evidence: measured (five diagnostics including the internal crash and the erased sibling; runtime `state audience {scope='x'} -> OK`). Fix: `if not scope:is("singleton") then error("audience must come from nw.audience ...")` in `OutboundScope`, and identity/`kind` checks in `requireAudience`.

### [미미] Analysis and runtime disagree on seven edge declarations
- Location: `src/types/init.luau:237-240` (`Ranged`), `:528-542`, `:552-560`, `:581`, `:608`, `:643`
- Problem, each measured: `t.optional(t.optional(x))` — analysis accepts as `Type<number?>`, runtime throws. `t.struct({})` — analysis `Type<{}>`, runtime throws. `t.enum({ [1] = true })` — analysis errors, runtime accepts `variants = {1}`. `t.struct({ [1] = t.u8 })` — analysis payload `{}`, runtime works. `t.enum({ a = true, b = "yes" })` — analysis accepts, runtime throws. `t.u8(0, 10, 99)` — rejected with `Function expects 3 arguments, but 3 are specified` (the `self: any` in `__call` miscounts). Numeric bounds have no analysis-time check at all. Together they say the vocabulary's runtime guards and its type functions are two hand-kept lists.

### [미미] `Ir.patch` reports `framing = "static"` for an all-flag struct while a change is always `counted`
- Location: `src/codec/Ir.luau:1005`, versus `src/api/Channel.luau:1129` (hardcodes `"counted"`) and `WIRE-FORMAT.md` ("A change is always `counted`")
- Problem: the field exists on the patch layout, is wrong for the wire, and nothing reads it — a future reader of `delta.layout.framing` gets an answer the format contradicts.
- Evidence: measured (`t.struct({ a = t.boolean, b = t.enum{x,y} })` → `framing static fixedSize 1 maxSize 1`).

## Type Insufficiency

### [경고] `Policy<T>` never binds to the channel payload; `authorize` is a presence check at the type layer
- Location: `src/api/Channel.luau:262-268`, `:322-327` (`if not propertyOf(spec, "authorize")`), `:803`, `:917` (spec is a free `S`)
- Problem: the type functions test that `authorize` exists and nothing else. A policy typed `(Ctx, { foo: string }) -> Verdict` attaches to a `{ screen: number }` command, and so do `authorize = 5`, a bare function, or `"TODO"`; only `nw.all`'s own generic checks `T`, with the message `Expected this to be 'Policy', but got 'Policy'`.
- Impact: G1's "type error" is a spelling check. Runtime `requirePolicy` refuses the non-policy cases at declaration; the shape mismatch is never refused anywhere, so a policy narrowing on `payload.foo` runs against a payload with no `foo`.
- Evidence: measured (wrong-shape policy, bare function, `5`: no diagnostics).

### [경고] A handler's `ctx` cannot be annotated `nw.Ctx`, cannot be passed to a helper typed `nw.Ctx`, and its Roblox fields are `unknown` — while the fix `Config` already uses is available
- Location: `src/api/View.luau:110-120` (`context()` builds `player: unknown`, `character: unknown?`, `humanoid: unknown?`), `:279-284` (`Views<D>` passes only `D`), `src/netweave.luau:355` (`export type Ctx`)
- Problem: `DESIGN-API.md` §8 documents the asymmetry as "what a type function can and cannot name". It can: `Config.CheckedSettings(spec, snapshot)` threads `Snapshot` in as a second parameter for exactly this reason. Threading `Context.Ctx` into `ServerView<D, Ctx>` and using `types.copy(ctx)` yields a handler parameter with `player: Player`, `character: Model?`, `humanoid: Humanoid?`. Found by the api and types auditors.
- Impact: today every handler that needs a `Player` casts, no helper can take `nw.Ctx` from a handler, `publish(ctx.player, …)` accepts `unknown` so a wrong argument there is unchecked, and `ctx.character.PrimaryPart` needs two casts.
- Evidence: measured. Current: `Expected '({ …, player: unknown }, …) -> ()' but got '(Ctx, …) -> ()' … 'Player' is not exactly 'unknown'`. Proposed: a scratch `ServerView<D, Ctx>` accepts `function(ctx: nw.Ctx, shot)` and `helper(ctx)` and still catches `Key 'playr' not found`. A `setreadproperty` projection is not the answer — it rejects the annotation (`channel is a read-only property in the latter type`).

### [경고] Optional spec fields accept any misspelling and any value type at the type layer
- Location: `src/api/Channel.luau:257-277`, `:283-294`, `:300-311`, `:317-338`, `:359-369`, `:384-415` (each class forbids a hand-picked list and checks nothing else)
- Problem: every one of these compiles: `command` with `authorise`, `maxbytes`, `bursts`, `Rate`, `reliable`, `subject`, `store`; `intent`/`signal` with `args`, `maxbytes`, `store`, `authorise`; `query` with `store`, `subject`, `maxbytes`, `timeOut`; `state`/`event` with `store`, `subject`, `Audience`, `ratelimit`, `unreliable = "yes"`; `replicate` with `unrealiable`, `rate_`. `burst`, `maxBytes`, `timeout`, `unreliable` accept strings; `timeout` and `store` are presence-only (`store = {}` compiles).
- Impact: `maxbytes = 4` and `bursts = 50` are the ones that matter — the author believes a ceiling or a depth is set, the runtime silently ignores the key, and nothing at either layer says so. This is the hole `CheckedSettings` closed for `nw.configure` (`Config.luau:269-277`), left open on the surface the design calls the security documentation. The runtime lists also drift from the type functions: `intent`/`signal` refuse `args` at runtime (`:844, :884`) but not at analysis (`:283-311`), and no class other than `replicate` forbids `store` or `subject` at either layer despite `FORBIDDEN_REASON` carrying text for both.
- Evidence: measured (one diagnostic in the whole probe file, for `rate = "20"`; runtime `maxbytes typo -> OK`).

### [경고] `channel: any` across the transport and replication boundary; `Tick.Config`, `Baseline` and `Store.charm` type their collaborators `any`
- Location: `src/transport/Batch.luau` (`Sink`), `Inbound.luau` (`Config.resolve`), `Outbound.luau`, `Budget.luau` (`admit`), `Query.luau`, `Recipients.luau` (`of(audience: any)`), `src/replication/Tick.luau:44-55` (docstring says `.outbound Outbound`, `.baselines Baseline`; type says `any`, `any`, `channels: () -> { any }`), `src/replication/Baseline.luau:66-74` (all `any`, dereferences `channel.qualified` at `:153`), `src/replication/Store.luau:127` (`subscribe: any?` while the docstring at `:112` spells the exact signature; cast at `:147`)
- Problem: `Channel.Channel<...>`, `Audience.Audience`, `Outbound.Outbound` and `Baseline.Baseline` exist and are exported; the loops that bind the three M4 collaborators call `outbound.change`, `baselines.of/keep/drop`, `channel.store/audience` through `any`, and `fromClient`, `changeFraming`, `subjectCodec`, `delta`, `replyMaxBytes`, `changeInstances` are set dynamically on an `any` record in `Channel.make` and read unchecked everywhere. `lune run analyze` is clean because there is nothing to check.
- Impact: a renamed method, a wrong argument order or a channel value without `qualified` (which raises inside `keep` on the tick) is not a diagnostic. Found by the transport and replication auditors.
- Evidence: measured (`lune run analyze`: 52 files clean, zero diagnostics in these folders).

### [미미] `ENCODING_SIZE`, `WRITE_NUMBER`/`PUT_NUMBER`/`READ_NUMBER`, `STORAGE_CODE` and `Row.storage` are keyed by `string`, so a misspelt or missing encoding types as present
- Location: `src/codec/Ir.luau:43-52`, `src/codec/Serdes.luau:68-104, :467-473, :480-489`
- Problem: `{ [string]: number }` makes `ENCODING_SIZE[node.lengthStorage]` type as `number`, not `number?`. A sixth encoding added to `Types.Encoding` but not to `STORAGE_CODE` is what `rowsOf`'s runtime `code == nil` guard exists for — the analyzer would say nothing. These are the hand-kept lists §9 warns about, and the type system could check them for free.

### [미미] `Batch.Sink.admit` and `refuse` carry the stage as `string`, cast to `Observer.Stage` in `Inbound`
- Location: `src/transport/Batch.luau` (`Sink`), `src/transport/Inbound.luau:966`
- Problem: a misspelt stage in `Batch.read` would type-check. A `Stage` union shared below `Observer` closes it.

## Types That Compile but Do Not Guarantee What They Exist For

Three findings of this kind are security-relevant and are filed above: the brand dropped on
`t.optional(struct)` (Potential Security Risks, 위험), the mutable channel record typed read-write
(Potential Security Risks, 경고), and `isType` as a duck check (Potential Security Risks, 경고). Two remain.

### [경고] `store.changed` is declared, documented, checked at declaration — and never read
- Location: `src/replication/Store.luau:58` (`changed` in the `Store` type), `:122-124` ("with it, a tick where nothing moved costs one branch"), `:138-149` (`Store.charm` wires the subscription), `src/replication/Tick.luau:169` (iterates `store.subjects()` unconditionally), `src/api/Channel.luau:1027-1029` (shape check only); `PLAN-M4.md` phase 5 repeats the claim
- Problem: `grep -rn "\.changed" src` finds the shape check and nothing else. The docstring's promise that passing Charm's `subscribe` makes an idle tick cheap is false; a game that passes it gets exactly the walk it was told it would avoid. A type with no consumer is the Q5 failure in a different form.
- Evidence: measured (grep; idle tick cost identical with or without `changed`).

### [미미] The sidecar is typed `{ Instance }` on the receive side, where it is wire data
- Location: `src/transport/Inbound.luau` (`receive(instances: { Instance }?)`), `src/transport/Link.luau` (`receive`'s handler type), `src/transport/Batch.luau` (`read`)
- Problem: the annotation asserts what the read phase exists to check; the honest type is `{ unknown }`, so that `Serdes.isInstance` is the narrowing rather than a contradiction of the signature.

## Documentation / Implementation Mismatches

### [경고] WIRE-FORMAT §6 says an over-long length is "clamped, and the packet is rejected"; the batch is abandoned
- Location: `docs/WIRE-FORMAT.md:358`; `src/transport/Batch.luau:669-674` refuses `packet length runs past the batch` and returns
- Impact: a reader believes G5 isolation extends to a lying length; everything behind it is lost. `tests/hostile_runtime.luau:18-21` already calls this one of "the three failures that stop a batch", so code and test agree and the document disagrees with both.
- Evidence: measured (`[one][id, len=100, …][three]` → `one` delivered, `three` never arrives).

### [경고] The worked example and §2.1 say attaching `nw.observe` replaces the default console output; it does not
- Location: `docs/DESIGN-API.md:101`, `:167-168` (the worked-example comment, which `tools/messages` asserts is the same text as `tests/example_runtime.luau`), `:887-888` (§11 item 7, unstruck)
- Problem: `Observer.emit` calls `announce` unconditionally after the observer loop (`src/api/Observer.luau:355`); the `nw.configure` docstring and §9.1 describe the actual behaviour ("Observers are unaffected").
- Evidence: measured (`sink lines with no observer: 1; with an observer attached: 1`).

### [경고] DESIGN-API §10's severity table still says `"error"` reports every occurrence; PLAN-M3 phase 9 says that was corrected "in three places"
- Location: `docs/DESIGN-API.md:828`; claim at `docs/milestone/PLAN-M3.md:813-814`
- Problem: since 2d6c2a0 every level is suppressed after `repeatsPerDiagnostic` (`src/api/Observer.luau:239-258`). The three corrected places are source comments; the user-facing table was not one of them.

### [경고] DESIGN-API §3 still specifies a sequence number per client per subject; M4 removed it and WIRE-FORMAT says so
- Location: `docs/DESIGN-API.md:376-378, :381-382`; `PLAN-M4.md:99-100` (D-2) and `:283-284` (phase 2) carry the sentence unstruck while phase 4 (`:351-357`) strikes it; `WIRE-FORMAT.md:190-194` ("There is no sequence number"); `src/replication/Baseline.luau:19-29`
- Impact: a reader designing against DESIGN-API expects a gap detector on the wire and a per-subject counter; neither exists. A CLAUDE.md §3 strikethrough-in-place miss.

### [경고] DESIGN-API's `replicate` row omits `subject` from Required and documents a one-argument listener
- Location: `docs/DESIGN-API.md:360, :362`; `src/api/Channel.luau:396-403, :1091` require `subject` at both layers; `src/api/View.luau:182-190` — the client listener is `(subject, value)` and `PLAN-M4.md:509-514` says a one-argument handler "no longer compiles"
- Impact: the class table is the "security documentation" the doc says it is; copying it writes a declaration that is refused and a handler that is refused. The §2.1 example twelve lines earlier shows `(subject, value)`, so the document disagrees with itself.

### [경고] PLAN-M4 acceptance 4 requires "the subject moving, not the audience swapped by hand"; the phase-4 probe marked done swaps it by hand
- Location: `docs/milestone/PLAN-M4.md:622` (criterion), `:371-375` (the `[x]`); `tests/baseline_runtime.luau:195`, `tests/replication_runtime.luau:48-49, :63-64` (`nw.audience.select` "standing in for `nw.audience.nearby` … without a `Vector3`")
- Problem: `nearby` needs `Vector3`, which only `tests/roblox_runtime.luau` can supply, and it has no replication section. Nothing in the plan says the criterion is unmet or re-stated. CLAUDE.md §3: acceptance criteria are objectively checkable, and corrections are written in with a strikethrough.

### [경고] PLAN-M4 acceptance 11 ("failure-path outnumber success-path in `replication_runtime`, enforced by the harness floor") is neither true nor enforceable by the floor declared
- Location: `docs/milestone/PLAN-M4.md:629`; `tests/replication_runtime.luau:37` (`harness.suite("replication_runtime", 0.3)`)
- Evidence: measured (`35 assertions, 17 failure-path (49%)`; a 30% floor can never enforce ">50%").

### [경고] `t.string`, `t.buffer` and `t.array` still promise 65,535 bytes; the `Batch` comment phase 9 said it replaced is unchanged; DESIGN-API §3 still says 65535
- Location: `src/types/init.luau:405, :417, :573` and `MAX_LENGTH` at `:264`; `src/transport/Batch.luau:211-212` ("a design problem, not a runtime one"); `docs/DESIGN-API.md:239`; `docs/milestone/PLAN-M3.md:694-698`
- Problem: WIRE-FORMAT §2 states the 16,383 cap; the type vocabulary a user reads does not, and the discrepancy now lives in three places instead of one. A bare `t.string` struct derives `maxSize 65,537`, a ceiling four times what the writer frames; the effective limit for a string inside a counted struct is 16,381 (its own two-byte prefix counts).
- Evidence: measured (16,383-, 16,384- and 20,000-byte strings all raise).

### [경고] The reference-equality fast path the docstrings promise can never fire through the tick
- Location: `src/replication/Delta.luau:92-95` ("Reference equality first, at every level… a game that replaces pays a pointer compare"), `src/replication/Store.luau:75-77`, `src/replication/Tick.luau:119-133` (`snapshot` deep-clones every table before it becomes a baseline), `Delta.luau:245-259` (the struct differ has no `old == new` check; only leaf `sameFor` checks identity)
- Problem: the baseline is always a recursive clone, so `a == b` is false at every table level for every store, including an immutable Charm atom; and even `write(v, v)` walks every scalar. Charm users pay the clone and the walk; the comment at `Tick.luau:129-130` ("Charm does not have the problem") is true of correctness and false of cost.
- Evidence: measured (`baseline is the store's own table: false`, `baseline.a is the store's own a: false`; `write(v,v)` 2,993 ns vs `write(clone,v)` 3,919 ns on a 60-field + 64-array value — the difference is the array leaf only).

### [경고] Every construction error in `src/types/` fails the bar `tools/messages` enforces one directory over, including the four that print at the call site
- Location: `src/types/init.luau:157, :184, :190, :217` (type-function `error()`s), `:305-310`, `:488`, `:529-535`, `:553-554`, `:582-589`, `:609-610`, `:644-650`
- Problem: applying `tools/messages.luau`'s two rules (a repair marker, and either the offending value or 80 characters) to the 23 messages: 23 fail. `a struct field is not a netweave type` does not say which field. Non-string keys escape `check()` entirely: `t.struct({ a = t.u8, [1] = t.u8 })` and `t.enum({ a = true, [1] = true })` die in `table.sort` with `attempt to compare string < number`.
- Evidence: measured (the `src/api` rules re-applied: 23 of 23 fail). The same applies to `Serdes.check`/`Trust.validate` reasons for a wrongly typed value: `attempt to compare number <= string`, `attempt to get length of a number value`, `invalid argument #1 to 'len'` — the VM's text, naming no field, invisible to `tools/messages`, contradicting `Serdes.luau:26-27` and the `validate` docstring's `warn(... {failure})`.

### [미미] DESIGN-API §2.1 still says "Six classes", omits `replicate` from the class table and `nw.store` and `nw.config` from the surface table, and lists stages, rules and limits without `direction`, `replicate`, `baselinesPerClient`
- Location: `docs/DESIGN-API.md:80, :83-90, :92-105, :748-753, :782-803`; `src/api/Observer.luau:74-84` has eleven stages, `src/api/Config.luau:504-519` six limits. Every value the §10 example does quote is correct.

### [미미] The class tables' Forbids columns disagree with `Channel.luau`'s type functions and runtime lists
- Location: `docs/DESIGN-API.md:85, :88, :223, :226`; `src/api/Channel.luau:274, :335, :805, :919`
- Problem: `command` and `query` forbid `unreliable` at both layers; `query` also forbids `data` and `audience`; the doc lists none of it. The relation is doc ⊂ type-function ⊂ runtime, with `args` on `intent`/`signal` the runtime-only extra.

### [미미] PLAN-M4 D-3 cites "twenty-one ids" in `delta-compress/src/TypeId.luau:3-22`; the file lists nineteen
- Location: `docs/milestone/PLAN-M4.md:138, :256`
- Evidence: measured (`grep -c` → 19). Every other `_refsrc/` citation in PLAN-M4 was checked and holds.

### [미미] PLAN-M4's Scope table names artifacts that do not exist and no task corrects it
- Location: `docs/milestone/PLAN-M4.md:46` (`src/replication/adapters/` — the three constructors live in `Store.luau`), `:43` (a replication axis in `bench/src/shared/Modes/` — no mode, no phase schedules one, and acceptance 8's crossover has nothing to be measured by)
- Evidence: measured (`ls`).

### [미미] CLAUDE.md §6 quotes measured shares as if they were the declared floors
- Location: `CLAUDE.md:281-283` ("`budget_runtime` 100%, `hostile_runtime` 99%, `fuzz_runtime` 90%, `transport_runtime` 66%"); `docs/milestone/PLAN-M3.md:1072-1073` with `fuzz_runtime` 92%
- Problem: the floors the files declare are 0.95 / 0.9 / 0.9 / 0.5; `transport_runtime` can fall to 50% and still pass.

### [미미] CLAUDE.md §2 layout is stale
- Location: `CLAUDE.md:44-63`
- Problem: `docs/milestone/` lists PLAN-M0..M2 only; `docs/` omits `SECURITY-REPORT.md`; `bench/` omits `profile.luau`, `RESULTS.md`, `README.md`, `runs/`, `schemas/`, `src/`, `vendor/`; `tools/` omits `messages.luau`; `tests/` omits `harness.luau`. `src/replication/` and the four M4 runtimes *are* listed.

### [미미] Stale cross-references and unstruck items across the documents
- Location: `docs/DESIGN-API.md:5, :41` ("§10.5 and §10.6" — the open items are §11.5/§11.6; §11 numbers its items 1,2,3,4,5,7,6), `:882-889` (item 7 describes the pre-M3 observability state, unstruck), `:739-740` (§8: the context guard "compiles out in production" — it is a runtime boolean from `RunService:IsStudio()`, togglable); `docs/WIRE-FORMAT.md:6-8` (the query correlation is "the one addition since the freeze" — M4 added the change packet and the `RESYNC` kind, both described further down the same file)

### [미미] SECURITY-REPORT.md's Disposition and Appendix A are stale in two places
- Location: `docs/SECURITY-REPORT.md:345-347` ("has not been run yet" — phase 9 ran `roblox_runtime`, `owner` included), `:467, :473` (Appendix A.2 writes `{ who = { fake = true } }` through `Batch.writePacket`, which the encoder now refuses; re-running it needs a stand-in from `tests/harness.luau:180` with the hostile sidecar swapped in)

### [미미] Stale docstrings and comments in `src/`
- Location and problem, one line each:
  - `src/transport/Outbound.luau:112-118` — `@param isServer boolean`; `Outbound.new(link, roster)` has no such parameter.
  - `src/transport/Outbound.luau:446-449` — "the record keeps [the buffer] so the destination does not have to allocate one again" — `Buffer.take` calls `load(nil)`, which allocates a fresh 64-byte buffer and drops the grown one (see Optimization).
  - `src/transport/Outbound.luau:59` — "908 is the documented limit" — Roblox's [UnreliableRemoteEvent page](https://create.roblox.com/docs/reference/engine/classes/UnreliableRemoteEvent) says 1,000 bytes in one revision and 900 in another; 908 is the [devforum-measured](https://devforum.roblox.com/t/incorrect-size-of-data-being-sent-limit-specified-when-using-unreliableremoteevent/3048788) figure. `DESIGN-API.md:849` "908 is Roblox's ceiling" is inferred, not official.
  - `src/transport/Inbound.luau:14` "Four things happen to a packet" (eleven stages), `:219` "the same six arrays" (seven), `src/transport/Driver.luau:198` "Four places hold something per player" (six `forget`s), `src/transport/Batch.luau:9-16` (the grammar omits the change and control packet shapes this file writes).
  - `src/api/Channel.luau:4-23, :57`, `src/api/View.luau:68-73, :411-416`, `src/api/Namespace.luau:160-165` — "six classes" and three "not a channel" messages that omit `nw.replicate`; `src/api/Observer.luau:32-73` — the `@type Stage` table lists eight stages, `replicate` is in the union and described nowhere; `src/api/Config.luau:138, :627` — "all three behave the same way" (six limits); `src/api/Config.luau:200-215` — a truncated duplicate of the `wire`/`floor` comment opens a `--[[` that swallows the width-subtyping note.
  - `src/api/Channel.luau:987` — `nw.state`'s docstring says "Server-to-client **replicated** state", the opposite of what DESIGN-API §3 says the class does now.
  - `src/codec/Ir.luau:161-179` (`@interface Layout` lacks `.instances`), `src/codec/Serdes.luau:1431-1453` (`@interface Codec` lacks `.maxSize`, `.layout`), `src/codec/Ir.luau:676` (the ceiling docstring derives from 65,535).
  - `src/netweave.luau:10`, `src/types/init.luau:11` — `require(Packages.netweave)`; `default.project.json` builds `src` as a Folder and CLAUDE.md §2 says `require(Packages.netweave.netweave)`.
  - `src/netweave.luau:31-38` — G6 is now also refused on the wire at stage `direction`; the table still says "type error" only, and `nw.milestone` is typed `string`, not `"M4"`.
  - `tests/example_runtime.luau:8` refers to `tests/messages.luau`; the checker is `tools/messages.luau`.

## Optimization

### [경고] The replication tick is O(subjects × players) with a full change attempt per pair, even when nothing moved
- Location: `src/replication/Tick.luau:169-189` (per subject: `Recipients.of`, `everyone` copied into `recipients`), `:144` (`outbound.change` per recipient: `switchTo`, `pcall`, `Buffer.mark/reserve`, full differ walk, `rollback`), `:92-100, :206-210, :216-222` (`among` linear scan × `baselines.of` for every player for every subject — O(S × P × R), O(S × P²) for `everyone`)
- Problem: nothing gates on "did this subject change since last tick". Every up-to-date recipient holds the same `copy` table (`:153-156`), so one compare per subject would answer for all recipients; instead the deep compare runs once per pair after a buffer switch. `store.changed` is never consulted. Contradicts "hot paths allocate nothing" and the O(clients × changed fields) shape the design describes.
- Evidence: measured. Idle tick, nothing changing: P=10 S=100 → 1.16 ms/frame; P=10 S=500 → 8.74 ms; P=50 S=100 → 6.75 ms; P=50 S=500 → **47.28 ms/frame**; the removal pass alone with one recipient per subject at P=50 S=500 → 2.36 ms. Per-pair cost is dominated by the attempt itself (`write(nil,nil)` early return 130 ns; `write(v,v)` on 12 fields 646 ns).

### [경고] The decode side never takes a block path: 2.5× the encode cost, 4× a hand-rolled reader
- Location: `src/codec/Buffer.luau:911-918` (`Codec.ensure`, no caller in `src/`), `:925-1046` (every `read*` bounds-checks per primitive), `src/codec/Serdes.luau:1104-1129` (`structReader`: one closure call per field), `:1031-1066` (`numberReader`: one closure plus one `READ_NUMBER` call per value)
- Problem: M2's block optimisation and M4 phase 7's fused writer exist on the encode side only. A statically sized payload could `ensure(fixedSize)` once and read with `buffer.readu8(incoming, at + k)` fastcalls; instead a 600-byte `ArrayHeavy` packet pays 600 closure calls, 600 dispatch-table calls and 600 bounds checks. `ensure` was written for exactly this and has no caller. Decode is the server's per-client cost.
- Evidence: measured (lune, 2,000 iterations): encode 6 fields fused 14.42 µs; decode 6 fields 35.62 µs; hand-rolled decode with `ensure` once plus fastcalls 8.71 µs (same `table.clone`); encode 9 fields (past the `FUSED_MAX` cliff) 38.35 µs, 2.1× the 8-field case.

### [경고] `Context.acquire` pays two property reads and a `FindFirstChildOfClass` per dispatched packet, not per player per batch
- Location: `src/api/Context.luau:164-185` (`:176-178`), called from `src/transport/Inbound.luau:444` per non-query packet
- Problem: a batch from one player refreshes `Character` and searches its children for a `Humanoid` once per packet, whether or not any policy on that channel reads `humanoid`. The note at `:171-175` justifies caching across *policies*, not across packets of the same sender in one batch. At 20 packets per batch that is 20 tree searches where one would do, and on `signal`/`intent` channels with no policy it is needed by nobody.
- Evidence: inferred from the call site being inside the per-packet dispatch; not measured under the benchmark.

### [미미] `Delta.write` allocates a `commit` closure and reserves flag bytes on every call, including the "nothing changed" path
- Location: `src/replication/Delta.luau:477` (`Buffer.reserve(bytes)` before the compare), `:483-489` (`local function commit()` captures `base`, a per-call local)
- Problem: Luau caches a closure only when its upvalues are immutable and module-scoped ([luau.org/performance](https://luau.org/performance), "Closure caching"); `base` is a local of `write`, so a closure is built per (subject, recipient) per frame on the hottest path in the folder.
- Evidence: inferred from the cited rule; lune's `gcinfo()` could not resolve it.

### [미미] Per-refusal string interpolation survives in three places
- Location: `src/transport/Batch.luau:732-734` (`payload claims {n} bytes, over the {ceiling}` — the value varies per packet, so it is a distinct string per packet), `src/transport/Budget.luau:399` and `src/transport/Query.luau:243` (interned, so time only), `src/transport/Inbound.luau:1145` (per departing player per channel, not per packet)
- Evidence: measured (500 oversize claims → 500 distinct reasons; `Budget.admit` admitted 72 ns, refused 188 ns, +0 KB over 10⁶ refusals). The M3 phase-9 line "all four are constants now" missed the first.

### [미미] A batch with many refused `replicate` packets sends one `RESYNC` per refused packet
- Location: `src/transport/Inbound.luau:971-973, :928, :949`
- Problem: `desync` runs per refusal; the store clear is idempotent but `onDesync` writes a control packet each time.
- Evidence: measured (44 refused changes → 44 resync packets, 177 B, per frame).

### [미미] `Buffer.take` discards the grown buffer on every take, so each destination regrows from 64 bytes every frame
- Location: `src/codec/Buffer.luau:781-800` (`take` → `load(nil)`), consumed by `src/transport/Outbound.luau:437-477` (`flush`); the comment at `Outbound.luau:446-449` says the opposite
- Problem: a destination that sends 1.5 KB a frame allocates a 64-byte buffer and regrows it through 128, 256, 512, 1,024, 2,048 every frame. `take` could hand back an exact copy and keep the grown buffer in the record.
- Evidence: inferred from the two call sites; `gcinfo` deltas were not stable enough under lune to quote.

### [미미] Per-tick allocations in the audience path
- Location: `src/api/Namespace.luau:326-342` (`Namespace.replicated` builds a fresh array per call; consumed per frame by `Tick.luau:162` via `Driver.luau:125`), `src/transport/Recipients.luau:134` (`Players:GetPlayers()` per subject per publish — a `nearby` channel with 1,000 subjects calls it 60,000 times a second; `Tick` already takes `roster.all()` once per tick), `Recipients.luau:208-210` and `Outbound.luau:143` (the `recipients` scratch keeps stale entries past `count`)
- Evidence: measured for `replicated()` (fresh table per call: true); inferred for `GetPlayers`.

### [미미] Dead code and a per-batch allocation in the codec
- Location: `src/codec/Buffer.luau:911-918` (`ensure`) and `src/codec/Ir.luau:282-285` (`lengthSize`) have no caller in `src/` (only `tests/ir_runtime.luau:227, :234`); `src/codec/Buffer.luau:812` (`beginRead(nil)` allocates a table per batch: 100,000 calls → 2,279 KB, ≈23 B per batch)

## Suggested Types

Consolidated from the five source auditors. "Should add" closes a finding above; "nice to have" is a
judgment; "do not add" is recorded so it is not proposed again. The codec column says whether the current
`Ir.Node` shape can carry it.

### Should add

| Type or change | Closes | Cost | Feasible now? |
|---|---|---|---|
| **Thread `Context.Ctx` into the views**: `Views<D> = { …, server: ServerView<D, Context.Ctx>, … }` and `types.copy(ctx)` in `context()` | `ctx` unannotatable, `player: unknown` | one extra type-function parameter; no runtime change | yes — measured working in a scratch `ServerView<D, Ctx>`; `setreadproperty` is not the answer |
| **Brand unions component-wise** in `Trusted`, `Untrusted`, `TrustedPayload`, `brandedAs` (`value:is("union")` → brand each table component, `types.unionof` back) | brand dropped on `t.optional(struct)` | a loop in four type functions | yes |
| **Close `CheckedSettings` over optional sections** (strip `nil` from `components()` before the tag tests) and add `nw.configure(s: nw.Settings)` to `tests/config_ok.luau` | `nw.Settings` refused | small | yes |
| **`OutboundScope` returns a singleton or errors at the call site** | the internal crash that erases a namespace | one `is("singleton")` check | yes |
| **Refuse unknown spec keys per class**, the `CheckedSettings` shape (one `allowed` set per class, one loop over `spec:properties()`), and check the value types of `burst`, `maxBytes`, `timeout`, `unreliable`, `store` | misspelt fields silently ignored; the hand-kept `forbid` lists | one loop per class | yes |
| **Freeze the channel record at seal**, copy-then-freeze `channels` in `declare`, and mark `rate`, `authorize`, `maxBytes`, `handler` `read` in `Channel<...>` (keep `handler` in a side table) | mutable record typed read-write | `attach` writes `handler`; otherwise none | yes — `read` properties are supported by the new solver ([RFC](https://rfcs.luau.org/property-readonly.html)) |
| **Add `subject` to `Protocol.signatureOf`** and a protocol test that changes the subject alone; consider the patch layout's `framing/maxSize` as a cross-check line | subject schema not hashed | one `describeLayout` call | yes |
| **A real `Channel` record type** at the transport boundary: `{ class, id, qualified, codec, maxBytes, fromClient, fromServer, handler?, authorize?, rate?, burst?, unreliable?, responseCodec?, replyMaxBytes?, timeout?, audience?, subjectCodec?, delta?, changeFraming?, changeInstances?, store? }` | `channel: any` everywhere | one cast in `Channel.make`; put the type in a leaf module to avoid a `Delta` require cycle | yes |
| **`Tick.Config` typed** (`outbound: Outbound.Outbound`, `baselines: Baseline.Baseline`, `channels: () -> { ReplicatedChannel }`), `Baseline`'s `channel: { qualified: string }`, `Store.charm`'s `subscribe` typed as its docstring already spells it | the M4 collaborators bound through `any` | none | yes |
| **Either make `Tick` consume `store.changed` or delete it from the type** | a documented optimisation that does not exist | if consumed: a per-store dirty flag, which is also the fix for the O(S × P) tick | yes |
| **`Stage` shared below `Observer`** (e.g. in `src/types`), used by `Batch.Sink` and `Inbound.report`; a `tests/config_runtime` assertion that every `Stage` member is a rule | the `string` stage cast; silent unknown stage | none | yes |
| **`{ [Encoding]: … }`** for `ENCODING_SIZE`, the three number-writer tables, `STORAGE_CODE`; `Row.storage: Encoding`; `export type Framing = "static" \| "counted"` in `Ir`; export `Flags`, `Writer`, `Reader` from `Serdes` (`Delta.luau:45` re-declares `Flags` by hand) | hand-kept encoding lists; duplicated literal unions | index-type changes | yes |
| **`Sidecar = { unknown }`**, **`Sender = Player?`**, **`Destination = Player \| false \| number`** for `Link`, `Inbound.receive`, `Batch.read`, `Outbound` | sidecar typed as what it is checked to be | none | yes |
| **A private brand on descriptors** (a weak set of constructed descriptors, or a frozen sentinel field) checked by `isType`, `requireType`, `validate` | `isType` duck check | none per packet | yes |
| **Map-key restriction** in `t.map`: keys limited to `number`, `string`, `boolean`, `enum`; refuse `optional`, `struct`, `array`, `buffer`, `vector*`, `instance`, `cframe` | the nil-key raise; non-colliding table keys | one `check()` | yes |
| **Integrality and f32-snapping of bounds** in `ranged` and `t.array`: refuse fractional bounds on integer encodings and fractional counts; snap f32 bounds outward through a 4-byte round-trip | the three bounds bugs | none | yes |
| **`t.union({ tag = schema, … })` — tagged union** | the "one optional field per case" pattern lets a client set two cases at once or none; `WIRE-FORMAT.md` §5 already specifies the layout ("tagged enums fork the bit budget per branch") — **documented and not implemented** | `ceil(log2 n)` bits plus the chosen branch; static only when every branch is | needs a new node kind with `branches: { Node }`, `bits = tagBits + max(branch.bits)`; ceiling = max |
| **`t.vector3(componentRange)` / int16 vectors** | `t.vector3` is unbounded f32 — a position of `1e38` on an `intent` passes `parse`; `unitVector3` covers directions only | as chosen; 6 bytes instead of 12 for int16 | yes — a vector node holding a component number node |
| **`t.quantized(min, max, step)`** | the only way a range on a float narrows storage; `t.quantized(-1, 1, 1/127)` is one byte where a normalized float is four | precision loss explicit in the declaration | yes — number node with `storage` from `(max-min)/step`, `offset = min`, a `scale` |
| **`t.player`, and `t.instance(class, { descendantOf = … })`** | the sidecar admits any instance of the class the client can reference; `t.player` is free at the type level (`Type<Player>`) | one `IsA`/`IsDescendantOf` per instance on receive | yes — the instance node already carries `class` |
| **`t.string(min, max, { utf8 = true, pattern = "…" })`** | client strings reach `SetAsync` keys, `Instance.Name`, chat — invalid UTF-8 or control characters raise later in game code | O(n) per string on receive | yes |
| **`t.u53` or a varint integer** | the widest integer is `u32`; a `UserId` today must be `t.f64` (8 bytes, integer-checked only by the writer) | varint 1–8 bytes, or f64 storage with an integer check | yes — `Buffer` has varint helpers |
| **`read` modifiers on `Type<T>` / `Descriptor`**, and clone-then-freeze `fields` in `t.struct` | `s.fields.id = …` compiles; `fields` shared by reference | none | yes |

### Nice to have

| Type | Why | Cost |
|---|---|---|
| Per-kind `Node` shapes as a discriminated union on `kind` | deletes ~40 `:: Node`/`:: number` casts in `Serdes`/`Ir` and makes `cloneNode`'s completeness a type error | a rewrite of every builder's head |
| `Serdes.fromSchema<T>(d: Type<T>): Codec<T>` with `write: (T) -> ()`, `read: () -> (T?, string?)`, `check: (unknown) -> string?` | the payload type is erased at the codec boundary today | call sites in `Channel`/`Trust` |
| `Store<S, V>` generic tied to `ReplicateSubject<S>`/`ReplicatePayload<S>` | typed subjects and values in the store seam | crosses a `type function` seam and will likely reduce to `any` at the require (Q5); needs its own `_ok`/`_reject` pair |
| `Delta.apply` returning a tagged result (`removed` / `value` / `refused`) | the `(nil, nil)` vs `(nil, reason)` distinction lives in a `--[[ ]]` at `Delta.luau:408-410` | one table per apply on the client — a docstring line is the free alternative |
| `Query.Config.spawn` split into `spawn` and `resume` | one field per job `task.spawn` does, so a stand-in cannot satisfy one and not the other | none |
| `Audience.kind` narrowed to the four literals; `requireAudience` checking `kind` membership and identity against the frozen sentinels | `{ scope = "everyone", kind = "owner" }` gets a runtime `broadcast` that ignores `owner` | none |
| `t.literal("v3")` / `t.literal(true)` | a zero-bit constant for versioning and union discriminants; number literals cannot be singletons in Luau | trivial |
| `t.set(elem)` | `t.map(k, t.boolean)` spends a scope byte per entry for a bit that is always true | saves a byte per entry |
| `t.optional(x, default)` | payload `T` instead of `T?`; must not apply to map keys | none |
| `t.enum({ a = 0, b = 1 })` with explicit ids | today the wire index is the sorted position, so adding a variant renumbers and the hash forces a redeploy | none |
| Compact `t.cframe` rotation (Zap's 24-rotation byte, or smallest-three quaternion) | 7 bytes vs 12 for the rotation half; `Ir` already notes it | codec-local |
| Per-element array deltas for M4 via `t.map(t.u16 → elementPatch)` | expressible with the current node shape; a `t.array` option would select it | one index per changed element |
| `Verdict` as `{ ok: true, value } \| { ok: false, reason }` | narrowing at call sites | the shared mutable record makes the union a lie about immutability; leave as is unless the record becomes per-call |

### Do not add

- `t.refine(schema, predicate)` — game code on the read path must run under the dispatch guard per packet; it is a policy with a schema attached, and `authorize` already is that.
- `t.id("entity")` brand — `number & { tag }` normalises to `never` (spike Q2); a scalar cannot carry a brand without a wrapper that lies about the runtime value.
- `t.timestamp` — a client-supplied time is a lie by construction; `ctx.now` is the server's.
- `t.recursive` — lowering is eager and the byte ceiling is derived from a finite tree; a recursive schema forfeits `maxSize`.
- `t.tuple` — Luau has no heterogeneous array type, so the payload would be `{ A | B | C }`, weaker than a struct at the same wire cost.
- `t.buffer(n)` — `t.buffer(n, n)` already gives a fixed-size buffer.

## Null results

What was probed and holds, so the next reader can see it was looked at.

- **Codec.** `maxSize` is a true upper bound over 3,000 random state schemas and 610 patch layouts. Patch presence bits in every impossible combination decode without a raise and leave `remaining() == 0`. `cloneNode` is complete against `Node` (21 nodes, 14 kinds); the shared nested-scope object is never written by `assignBits`. The fused writer raising mid-struct inside a block leaves `used` at the claim and the next honest write byte-exact. Enum tags straddling a u16/u8 chunk boundary round-trip. Narrowed integer readers at every bound; `u32` at 4,294,967,295 and `i32` at −2,147,483,648 exact. `table.clone` of a frozen template is mutable, so `Ir.luau:387-388` is right. `isInstance`'s Roblox half is exact.
- **Transport.** Non-LIFO: three batches and six batches with a longer one arriving mid-park deliver exactly once, 0 reports. The read-phase guard restores `sender`/`filling`/`full` under nesting with correct attribution. `full` is cleared per batch. Sidecar shapes `{nil, inst}`, `{inst}` short, `{x = inst}`, `{inst, 5}` refused per packet or batch stopped, never a raise. `direction`: `state`, `replicate`, reply-shaped-on-query at the server and `command` at the client all refused before decode; `query` admitted both ways by design. Hello: 300 mismatched → 1 announce, 1 report. Query slots: duplicate id → `REFUSED` and count unchanged; 17th call → `BUSY`; `forget` mid-flight → `inflight 0`, no reply, no raise. Free-list high-water mark equals concurrent walks. `flush` after a raising send: no retry, no starvation.
- **Replication.** `Delta.apply` truncated at every length 0..9: 0 raises, 10 refused. nil vs absent on optionals is not a change; removal round-trips with the key gone. Arrays and maps replaced whole as documented. A subject listed twice by a store writes once. In-place mutation and replacement both arrive. Audience swap and store change in the same frame: departing client told, arriving client snapshotted with the new value. Trailing bytes inside a change's declared length are accepted silently — consistent with `codec.read()`'s lenience, not a replication defect.
- **api.** All 23 `api_reject` cases fire. `replicate` views: nine intended rejections fire; payload and subject types correct for struct, scalar, array, map, nested-with-optional, optional struct, struct subject with enum; no `broadcast` even with `everyone`. Every `export type function` in the folder reduces across a require (confirmed by rejection, not only by reading). Laundering routes closed: field-by-field rebuild, `table.clone`, array element, map, intent payload, state client value, boolean-typed tag. `CheckedSettings` knows `direction`, `replicate`, `baselinesPerClient`; the snapshot is read-only. `invoke`'s answer cannot be used without a nil check. `Policy.all` allocates nothing per request. `Observer`: `"off"` counts, suppression at 3 with the pointer line, `"?"` for unknown ids so a peer cannot grow `seen`. `make`'s ceiling logic: `maxBytes` on static, above derived, and on outbound classes all refused; replicate ceiling is `subject + patch`.
- **types.** Nothing in `types/` runs per packet. `-0.0`/`0.0` collapse to one key; a NaN `f64` key is refused. `Type<T>` → `Descriptor` compatibility pinned by `types_ok.luau`. `StructPayload`, `EnumPayload`, `Trusted`, `Untrusted` reduce. Runtime refuses optional-of-optional, inverted ranges, `t.array` > 65,535, non-`true` enum values, empty struct/enum. A second `Transport.install` is refused with a message.
- **docs.** G1–G3, G5, G6 as stated; every `~~strikethrough~~` correction in DESIGN-API and WIRE-FORMAT is true today; every WIRE-FORMAT byte-level claim other than §6's "clamped" and §4's hash coverage dumps as specified (envelope, frames, hello `00 01 04 <u32>`, resync `00 02 01 <id>`, request/reply, status codes, change `id length subject flags [fields]`, removal `0x00` with an empty body). `tools/messages` → `worked examples 57 and 29 lines, milestone M4`. Every `RESEARCH §` and `_refsrc/` citation in PLAN-M4 holds except the TypeId count. Assertion counts 35 / 42 / 139 / 186 / 40 match the suite. `Co-Authored-By` matches the twelve most recent commits.

## Summary
- 심각: 0
- 중대: 4
- 위험: 6
- 경고: 38
- 미미: 30

Total: 78 findings across nine sections. The four `중대` share the shape the previous report's three did: a
probe the suite never wrote. `replication_runtime` restores `pendingPerBatch` after one frame, so the
livelock is one frame away from the case it tests; `protocol_runtime` walks node attributes and cannot see
a second layout; no `_ok` file has ever annotated a value with `nw.Views<D>`; and `serdes_runtime` uses
bounds that happen to be dyadic. Each fix is small, and each should land with its probe run against the
pre-fix code first, per `CLAUDE.md` §9.

## Appendix A — probes

Run from the repository root with `lune run "<absolute path>"`; `R` is the relative prefix to `src/` from
wherever the file lives (from `spike/` it is `"../src/"`). The scratch probes the six auditors wrote are
larger and live only in the session scratchpad; these four are the compact re-runs made during synthesis
and reproduce the numbers quoted.

### A.1 f32 bounds, subject hash, optional map key

```lua
local R = "../src/"
local Buffer = require(R .. "codec/Buffer")
local Serdes = require(R .. "codec/Serdes")
local Namespace = require(R .. "api/Namespace")
local Protocol = require(R .. "api/Protocol")
local nw = require(R .. "netweave")
local t = require(R .. "types")

-- f32 bounds: a bound that is not an f32 value refuses the value at the bound
for _, case in { { t.f32(-math.pi, math.pi), math.pi }, { t.f32(0, 0.1), 0.1 }, { t.f32(0, 1), 1 } } do
	local codec = Serdes.fromSchema(t.struct({ v = case[1] }))
	Buffer.load(nil)
	codec.write({ v = case[2] })
	Buffer.beginRead((Buffer.take()), nil)
	local value, failure = codec.read()
	print("f32 bound", case[2], "->", value and value.v, failure)
end
-- f32 bound 3.141592653589793 -> nil number out of range
-- f32 bound 0.1 -> nil number out of range
-- f32 bound 1 -> 1 nil

-- the subject schema and the protocol hash
local function hashWith(subject)
	Namespace.reset()
	local ns = Namespace.declare("h", {
		x = nw.replicate({
			data = t.struct({ n = t.u8 }),
			subject = subject,
			audience = nw.audience.everyone,
			store = nw.store.of({}),
		}),
	})
	local p = Namespace.seal()
	return p.hash, Protocol.signatureOf(ns.channels.x)
end
local h16, s16 = hashWith(t.u16)
local h8, s8 = hashWith(t.u8)
print("subject u16 -> u8 moves hash:", h16 ~= h8, "signatures identical:", s16 == s8)
-- subject u16 -> u8 moves hash: false signatures identical: true

-- an optional map key, one presence bit cleared
Namespace.reset()
local codec = Serdes.fromSchema(t.map(t.optional(t.u8), t.u8))
Buffer.load(nil)
codec.write({ [3] = 7 })
local honest = Buffer.take()          -- 01 00 01 03 07
buffer.writeu8(honest, 2, 0)          -- clear the key's presence bit
Buffer.beginRead(honest, nil)
print("read after clearing the presence bit:", pcall(codec.read))
-- read after clearing the presence bit: false ...Serdes:1254: table index is nil
```

### A.2 `nw.Views<D>` erasure (analyzer)

Run with the same invocation `analyze.luau` uses: `luau-lsp analyze --platform=roblox
--definitions=tools/globalTypes.d.luau --flag:LuauSolverV2=true --no-strict-dm-types <file>`.

```lua
--!strict
local nw = require("../src/netweave")
local t = nw.types
local allow = nw.policy(function()
	return function()
		return nw.allow()
	end
end)
local decl = { fire = nw.command({ data = t.struct({ x = t.u8 }), rate = 10, authorize = allow }) }
local ns = nw.namespace("n", decl)
local _v: nw.Views<typeof(ns.channels)> = ns  -- delete this line for the control
ns.server.fire:send({ x = 1 })                -- must fail: a command has no send on the server
ns.server.fire:listen(function(ctx, x)
	local _bad: string = x.x                  -- must fail: x.x is a number
end)
return nil
```

With the annotation line: no diagnostics. Without it (the control): `Key 'send' not found in table
'{ listen: ... }'` and `Expected this to be 'string', but got 'number'`.

### A.3 The replication livelock (setup, from the auditors' rigs)

The two independent rigs that measured it build a server `Inbound`/`Outbound`/`Baseline`/`Tick` and a
client `Inbound`/`Outbound`/`Baseline` over a loopback `Link` (the shape `tests/replication_runtime.luau`
uses), declare one `nw.replicate` channel with `audience = everyone` and `store = nw.store.of(subjects)`,
fill `subjects` with N entries of `{ n = u8 }`, and run `tick → flush → client receive → client flush →
server receive` per frame under default `nw.configure` limits, recording bytes each way, the client's
mirror count, and refusals by stage. At N = 256 the mirror completes on frame 1 and every later frame is
0 bytes; at N = 257 and above every frame repeats the full snapshot and both sides end the frame holding
0 baselines. `tests/replication_runtime.luau:433-435` exercises the same shape for one frame with the
limit restored afterwards, which is why the suite passes.
