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
| Counters, an immutable snapshot, and a default sink that warns | `src/api/Observer.luau` — ~~`src/api/Diagnostics.luau`~~, which would have been a file re-exporting one function rather than a boundary |
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

### D-5 — Every channel has a byte ceiling, derived from its schema

~~Decode work is a budget, in the same accounting as bytes. A per-tick decode-work ceiling is
charged per element read and per table allocated.~~ **Corrected during phase 2, by measurement.**

The premise was that `rate` counts packets and nothing bounds work, so a small packet could cost
what a large one costs. D-4 removed that: once a claim is bounded by the bytes behind it, decode
work is proportional to payload size. Measured on the nested schema D-5 was written for,
`t.array(t.array(t.u8, 0, 1000), 0, 1000)`:

| | per packet | per byte |
|---|---|---|
| hostile, 1000 x 1000 from 2002 bytes | 47.7 us | **0.0238 us** |
| honest, one array of 1000, 1004 bytes | 48.2 us | **0.0480 us** |

The hostile packet is *cheaper per byte* than the honest one. There is no amplification left to
charge for, and a per-element counter would tax every honest packet for a threat that no longer
exists.

What is built instead is a byte ceiling, and it is **derived from the schema** rather than
declared. Every netweave type is bounded — a number by its encoding, a string or array by its
range, an unbounded array by the 65535 its prefix can express — so the layout can add them up and
every channel gets a ceiling whether or not its author thought to ask for one.
`t.struct({ origin = t.vector3, seq = t.u16 })` derives 14, and a packet claiming more is provably
a lie, refused before decode at stage `"budget"`. `RESEARCH §3.7-F` records that no surveyed
library checks a payload size at all; the reason is that they would have to ask the author for the
number.

A declared `maxBytes` can only *tighten* it, and asking for more than the schema can produce is
refused rather than clamped — a ceiling that could never be reached would let an author believe
they had set a limit. That is what the nested schema needs: it derives 1,002,002, which is honest
and useless, and `maxBytes = 2048` at `rate = 20` bounds it to 40,960 bytes per second.

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

### D-9 — `Untrusted<T>` stays a subtype, and the tag becomes required — **decided**

The shared plan asked that `Untrusted<T>`'s fields be *inaccessible*. That is rejected, and
something smaller and measured is done instead.

**Why not the wrapper.** Making field access impossible needs a runtime wrapper, which allocates
per packet — the cost `CLAUDE.md` §4 forbids and that M1 and M2 spent two milestones removing. A
type-only wrapper instead lies about the value, which §6 already rejected. And neither helps: a
scalar cannot carry a brand (`number & { tag }` is `never`), so after unwrapping you are holding
plain numbers again. The proposal delays the leak rather than closing it.

**What the audit found instead.** Probing eight cases through `analyze` showed §6's central claim
was already false. The tag was `{ __nwTrusted: true? }` — optional — and a table literal checked
against an optional property satisfies it by not having it:

| case | optional tag | required tag |
|---|---|---|
| `giveItem({ screen = 1 })` | compiles | **rejected** |
| `giveItem({ screen = untrusted.screen })` | compiles | **rejected** |
| a `command` handler's payload | compiles | compiles |
| `nw.validate` output | compiles | compiles |
| `api_reject` | 15 | 15 |

The second row is the one that matters: the brand is on the container, so taking an untrusted
payload apart and rebuilding it laundered it in a line a programmer writes without thinking.

**Decision: the tag is required.** Four lines across `src/api/Trust.luau` and `src/api/View.luau`,
no runtime change. The price is a type asserting a field the runtime has not got, which is a much
smaller lie than the wrapper. A spelled-out `__nwTrusted = true` still compiles, and that is the
escape hatch: a forgery you have to write is one a reviewer sees.

**Measured honestly, the whole apparatus buys one diagnostic.** Making both brands identity drops
`api_reject` from 15 to 14. It is kept because it is the only mechanism that travels with the
value — every other guarantee lives in the declaration and is visible only at the call site.

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
### D-12 — A refusal crosses the wire as a code, never as a reason

A query has to tell the caller it was refused, or the caller waits out the timeout for something the
server knew instantly. What it must not tell them is *why*.

A refusal's reason is written for the game that owns the server. It names the policy, often the
field, sometimes the player — `"not in guild 7"`, `"cooldown, 2.1s left"`. Sending that back turns
every denied request into a probe: an exploiter learns the shape of the authorization model by
being refused by it, which is a cheaper way in than reading the client bundle.

So the reply carries one of five codes (`WIRE-FORMAT.md` §2) and the reason goes to the observer on
the server, where the game can read it. The codes are chosen so each implies a different response
from the caller — retry later, do not retry, report a bug, wire up a handler, back off — which is
everything a caller can act on and nothing it can learn from.

### D-13 — `callsInFlight` is one number, read from both ends

A query handler is the only handler netweave lets yield, and that permission is a resource. A player
whose handler blocks on a datastore holds a thread until it returns, and `rate` does not bound that:
`rate` counts arrivals, and a handler that takes five seconds at `rate = 20` is a hundred threads.

`callsInFlight` bounds the threads one player may have parked. The same number bounds the answers
one caller may be waiting for, because it counts the same player from the other side — so a game
that trips one is about to trip the other and is told so in whichever place it happens first.

The bound is per **player**, not per channel. The resource is a parked thread and a thread does not
become cheaper for being parked in a different handler; a per-channel bound would let one player
multiply their budget by the number of query channels the game happens to declare.

**What it does not do is cancel anything.** A yielded Luau coroutine cannot be resumed from
outside into a failure, so a handler wedged on something that never returns holds its slot until it
returns or the player leaves. That is self-denial — a player can only wedge their own slots — and it
is stated in `Query.forget` rather than papered over.

### D-14 — `nw.configure` never type-checked, and the reject file was counting the bug

Found in phase 4, by needing to raise `callsInFlight` in a test.

`nw.configure` was typed `<S>(settings: S & Config.Settings)`. That reads correctly — capture the
literal in `S` for the name check, require it to satisfy `Settings` — and Luau rejects **every**
argument to it: it binds `S` to the argument's own type and then requires the intersection to be
exactly that type, so a settings table that omits any optional field fails, and all of them are
optional. The example in the function's own docstring did not compile.

Nothing said so, and the reason is the interesting half. The only file calling `nw.configure` was
`tests/config_reject.luau`, where a diagnostic is what success looks like. Nine of its twelve
expected diagnostics were this bug, and its header comment explained them as a deliberate two-layer
design. **A rejection count guarding a feature that has no positive test is guarding nothing.**

The fix moves both halves — names and value types — into the `CheckedSettings` type function, which
now says what is wrong in one line instead of eight lines of union explanation. `config_reject` is
8, one per mistake. `tests/config_ok.luau` is the half that was missing.

One check did not survive: a severity that is a string but not one of the three. With the parameter
typed as a bare `S` there is no expected type to hold `"warn"` at its singleton, so severities
arrive widened to `string` and there is no literal left to compare. `Config.configure` refuses
`"loud"` at startup with the same message, which is loud and immediate; and the case D-11 is
actually about — a misspelled rule *name*, which reads as "I configured this" while the default
stays in force — is still caught at analysis.

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
- [x] **The bucket is at least one token deep, whatever the rate.** Found by the audit after the
      phase closed, not by a test: a rate below one packet per second is legal and ordinary, and a
      bucket 0.5 deep can never hold the whole token the admission test wants — so `rate = 0.5`
      refused every packet after the first, forever. Warp's failure reintroduced by the fix meant
      to make it unreachable
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

### Phase 1 — observability that is on by default — **done**

- [x] `Observer` keeps counters per channel per stage, not only the live callback — two integers,
      allocated once per channel and refilled after, so a sustained flood allocates nothing
- [x] An immutable snapshot exists as `nw.config.snapshot()` — frozen at every level, and a second
      call is a second table so two diagnostic screens cannot share a moment
- [x] `nw.diagnostics()` returns the counters, frozen at every level; mutating it at any depth
      raises and the live tallies are untouched. Built on read rather than kept assembled, so
      counting a refusal stays two increments
- [x] **A rule set to `"off"` still counts.** Severity is about output; if it reached the counters
      it would be a way to make a channel's refusals vanish from a diagnostic screen, which is the
      one thing D-11 says a severity must never do
- [x] A default sink warns on the first refusal of each `(channel, stage)` pair, with the reason.
      Silence is opt-in, not default — `src/api/Observer.luau`, and `DESIGN-API.md` §9.1 carries the
      strikethrough
- [x] A `"protocol"` stage for handshake refusals (phase 5 fills it), defaulting to `"error"` —
      every one, because a mismatch means that client cannot play at all and the rate is bounded by
      joins rather than by packets
- [x] Rate-limit the default sink itself — the thing that reports a flood must not become one.
      Three per `(channel, stage)`, then a line saying so; `limits.repeatsPerDiagnostic` moves it

### Phase 2 — resource limits — **done bar the measurement**

- [x] A byte ceiling per channel, enforced before decode, refused at stage `"budget"` — **derived
      from the schema** rather than declared, so a game that asks for nothing still gets one. A
      declared `maxBytes` may only tighten it, and asking for more than the schema can produce is
      refused (D-5)
- [x] **A ceiling on a statically framed channel is refused too.** Found by the phase 3 audit: a
      static payload carries no length prefix, so there is no claim to check and the declaration
      was accepted, stored and never consulted — `maxBytes = 4` on a schema fixed at fourteen bytes
      did nothing at all. The same disease as a ceiling above what the schema can reach, in the
      form the upper-bound check could not see
- [x] ~~A per-tick decode-work ceiling, charged per element and per table.~~ **Not built, and D-5
      carries the measurement.** After D-4 the hostile nested packet costs 0.0238 us per byte and
      the honest one 0.0480 — decode work is proportional to payload size, so bounding the bytes
      bounds the work and a per-element counter would tax every honest packet for a threat that no
      longer exists
- [x] The nested-array case has a test: nesting cannot evade the ceiling, because the ceiling is on
      bytes and nesting is paid for in bytes. It also pins the derived figure, 1,002,002 — honest,
      and useless as a limit, which is the case a declaration exists for
- [x] `Inbound`'s pending set is bounded; past the ceiling the rest of the batch is refused
      **before decode** rather than decoded and dropped, because refusing has to stay cheaper than
      accepting. Reported at stage ~~`"queue"`~~ **`"budget"`**: `"queue"` means the game attached
      no listener, and this is the sender being over a limit (D-6)
- [ ] Re-measure `ArrayHeavy` decode allocation against the M2 figure of 9309.2 B and record both
      — folded into the single Studio run at the end of the milestone

### Phase 3 — the trust boundary, decided — **done**

- [x] **D-9 resolved before anything else in the phase.** Not the wrapper the shared plan asked for
      — it allocates per packet, lies about the value, and does not help scalars. The tag becomes
      **required** instead, which closes a hole the audit found while answering the question
- [x] `Trusted<T>` is producible only where the value has actually been validated. It was not
      before: an optional tag is satisfied by a table literal that omits it, so `giveItem({ screen = 1 })`
      and the one-line laundering `giveItem({ screen = untrusted.screen })` both compiled. Cases 16
      and 17
- [x] The producers are enumerated in `src/api/Trust.luau` and `DESIGN-API.md` §6, and the fourth
      — an explicit cast for server-authored data — is written down rather than left to be
      discovered. It is a cast and not an `nw.trust()` helper for the same reason there is no
      `nw.untrust`
- [x] `nw.validate` reconciled in favour of `nw.validate(schema, value)`, and the other reading was
      **already** a type error — `TrustedPayload` refuses a first argument with no `__payload`.
      Verified rather than built, and pinned as case 19. What is new is §6 saying what `Trusted<T>`
      *asserts*, which it never did: not "well-formed" — the codec guaranteed that — but "the server
      has taken responsibility". Both producers confer trust on that reading
- [x] Four cases added, count 15 to 19. Case 18 exists because case 13 was not what it claimed:
      it fails on the *absence* of `__nwTrusted`, so it would still pass if `Untrusted` became `any`
      tomorrow. Case 18 fails only on `__nwUntrusted`, so the two brands are pinned separately
- [x] `tests/api_ok.luau` pins the positive half — reading fields through the brand, all three
      producers, and the cast escape hatch

### Phase 4 — `query`, with the timeout the field does not have

- [x] `src/transport/Query.luau`: varint call ids, so there is no 256 ceiling (`RESEARCH §3.7-G`).
      Wrapping at 16,383 and skipping ids that are still outstanding, so a collision is impossible
      by construction rather than by being unlikely. Demonstrated at **300 concurrent calls**, which
      is past the point where Blink and Zap raise.
- [x] A declared timeout per channel, required, with no unlimited option — the same shape as `rate`
- [x] A timed-out call resolves as a failure value, never a hung thread
- [x] Every pending call for a leaving player is cancelled in `PlayerRemoving`, alongside M2's
      three existing forgets. **With one correction written into the code:** a handler already
      parked inside a yield is *not* cancelled, because a yielded Luau coroutine cannot be. What is
      released is the accounting; the thread returns when it returns, finds its slot gone, and
      writes no reply.
- [x] The reply path is a channel like any other: budgeted, observed, and unable to throw
- [x] Reconcile the failure shape — `invoke` currently returns `(R?, string?)` and the shared plan
      forbids `nil` as failure. **Decided: `(R?, string?)` stays**, and the ambiguity is closed at
      the declaration instead — a query's `returns` may not be a top-level `t.optional`. Written
      into `DESIGN-API.md` §7 with the three alternatives and what each costs.
- [x] Delete the hole at `Driver.luau:120` and the comment that promises this milestone
- [x] `docs/WIRE-FORMAT.md` §2 gains the query correlation, which was never specified because no
      query had ever crossed the wire
- [x] `tests/query_runtime.luau`: two peers in one process, over the real envelope. Eight failure
      paths against one success path, and the three bounds confirmed to fail without their guards
- [x] **Found and fixed while writing the tests:** `nw.configure` did not type-check at all. See
      D-14.
- [x] **Found by the phase audit:** an answer the pending-set ceiling discards left its caller
      parked for the whole timeout and then told it `no answer within 5s` — about a packet that had
      arrived, decoded, and been dropped a frame earlier. `Query.abandon` moves the deadline into
      the past and records what actually happened, so the caller gives up on the next tick with the
      real reason. Reaching it needs `callsInFlight` above `pendingPerBatch`, which is a
      misconfiguration rather than a peer, and it is still the rule the rest of the phase keeps.

**The rest of the audit found nothing.** Recorded because a probe that finds nothing is the only
evidence the claim is not merely unexamined:

| Probe | Result |
|---|---|
| Instances through a query, both directions | args and returns each carry one; request 4 B / sidecar 1, answer 5 B / sidecar 1 |
| A refused reply in front of an answered one, both on an instance-carrying channel | the answer reads its own instance; a status-only packet advances the sidecar by zero |
| Hostile call ids — 0, 127, 128, 16383, 16384, 2^32-1 | every one round-trips and is echoed back; no raise, no report |
| `replyMaxBytes` | consulted: a reply claiming 500 on a 201-byte `returns` refuses at `budget` |
| The `query` stage in `nw.diagnostics()` | counted, with zero bytes, which is what a timeout weighs |
| `maxBytes` on a query — static args, below the derived, above it | refused, accepted, refused |
| A request that fails decode with an instance behind it | the packet behind it gets its *own* instance, and both calls are answered |

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
