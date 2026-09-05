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
| **Added after an external review**: the 26 findings it returned, and the encode regression the benchmark measured | `docs/SECURITY-REPORT.md`, phase 9 |

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

~~Currently it covers channel names only~~ **— done in phase 5, and the gap was wider than this
said.**

The claim was that changing `t.u8` to `t.u16` leaves the hash identical. Measured on eleven
single-change pairs, the name-only hash was identical for **ten**: a field renamed, added, narrowed,
made optional; an array bound raised; an enum variant added or renamed; a channel's *class* changed;
and a query's `returns` changed with its `args` untouched. Only a channel renamed moved it — which
is the one thing hashing names can catch.

The hash now covers the qualified name, the class, and the lowered node tree of every schema the
channel carries, plus the derived framing and size numbers as a cross-check on the lowering itself.
It deliberately excludes `rate`, `burst`, `maxBytes`, `authorize`, `audience` and `unreliable`:
those are one side's policy, and a hash that moved when a server tuned a rate limit would force a
client redeploy for a server-side edit, which is how a project learns to stop tuning rate limits.

Two things were added that the decision did not ask for and that it needs to be worth anything.
`nw.signature()` prints the text the hash is taken over, because "the hashes do not match" without
it is a dead end — the affordance is a diff, not a number. And `Batch.Sink.admit` gained a stage
alongside its reason, so that a mismatched peer's packets report at `protocol` rather than at
`budget`; a refusal filed under the wrong stage is a diagnostic that misdirects.

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

**Landed in phase 6, with two things the decision did not say.**

The counter tags per **section**, not per assertion, and the two numbers are therefore not
comparable: the 14% above was counted by reading assertions one at a time. A hostile case is written
as a block — craft the bytes, feed them in, then assert the bad packet was refused *and that the
ones behind it still arrived*. That middle assertion asserts a success and tests a failure, and
tagging it per line invites arguing every one. Per section is also the granularity at which the
ratio cannot be moved by relabelling. `transport_runtime` reads 59% under the new counter.

And the rule applies to files whose job is refusal, which is not every file. `ir_runtime`'s 13% is
not a gap: lowering a schema has one correct answer and no adversary, and padding it with refusal
cases to reach a number would be the failure mode of every metric. The floors live in the four files
the acceptance criteria name, declared in the file the way `-- netweave:expect N` is, so a floor
someone lowered is a floor in the diff.


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
- [x] The reply path is a channel like any other: ~~budgeted~~, observed, and unable to throw. **Not
      budgeted, and the checkbox was wrong** — `Outbound.reply`'s own comment says so and gives the
      argument: a reply is one-for-one with a request that already spent the sender's rate on the
      way in. What that argument does not cover is a reply to a *refused* request, which is a second
      write on a packet the budget declined; it is bounded by the client's own bandwidth and is
      recorded rather than fixed (M3 phase 9).
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

- [x] The hash covers the lowered IR, not channel names (D-7). `src/api/Protocol.luau`; the codec
      keeps its `Layout` so nothing is lowered twice.
- [x] A test that changes exactly one field's type and asserts the hash **moves** — and eleven other
      single-change pairs. Reverting to the name-only signature collapses **ten of the eleven** to
      the same number, including a class change and a query's `returns`. Measured, not asserted.
- [x] Six things that must **not** move it: `rate`, `burst`, `audience`, `unreliable`, the order the
      fields were typed in, and declaring the same thing twice. A hash that moved when a server
      tuned a rate limit would force a client redeploy for a server-side edit.
- [x] Mismatch is refused at stage `"protocol"` with both hashes in the reason
- [x] The check happens once at join, not per packet — but the *refusal* is per packet, because the
      hello is in the first batch and the packets behind it in that same batch are the first ones
      that must not land. `Batch.Sink.admit` now returns a stage alongside its reason so that
      refusal reports honestly rather than as `budget`.
- [x] Reserved id 0 carries `kind:u8 length:varint body`, so a control kind a build has never heard
      of is stepped over rather than fatal. Id 0 was reserved for "anything v2 needs", and a
      reserved slot that cannot be extended is not reserved for anything.
- [x] `nw.signature()`: the text the hash is taken over. A hash that differs says *that* two builds
      disagree and nothing about where; this is what makes the mismatch diagnosable rather than a
      dead end.
- [x] **A peer that says nothing is accepted, deliberately.** The handshake diagnoses deploy skew
      and is not an authorization boundary — a hostile client omits the hello and is held to exactly
      the same per-field validation, so refusing a silent peer gains nothing and costs a real client
      whose hello was lost. Written into `WIRE-FORMAT.md` §4 rather than left as behaviour.

### Phase 6 — the adversarial suite

- [x] `tests/hostile_runtime.luau`: every refusal path in `Batch`, `Inbound`, `Budget` and the
      readers, driven by crafted bytes rather than by API calls. 135 assertions, 99% failure-path.
- [x] `tests/fuzz_runtime.luau`: structured mutation of valid batches — bit flips, byte
      substitution, truncation, noise appended, id substitution, sidecar over- and under-statement,
      replayed frames, and whole-batch noise. 10,000 rounds on a printed seed.
- [x] The invariant is uniform: **the receive path never throws, and never loses a packet it did
      not report losing**. Both are asserted per case in `hostile_runtime` — for the three failures
      that stop a batch, the report's byte count is asserted to equal exactly what was discarded —
      and per round in `fuzz_runtime`.
- [x] Two invariants the plan did not ask for and that turned out to be the valuable ones. **A
      value that reaches a handler must satisfy its own schema**, checked with `codec.check` on
      every delivery: a mutated batch may decode into a *different* valid value, and must never
      decode into an invalid one. And **a canary batch after every mutation must still arrive**,
      which is the only thing that would catch a sticky rejection, a stranded cursor or a
      half-consumed sidecar, because every other suite starts from a clean decoder.
- [x] A harness counter reports failure-path against success-path assertions per file, and the suite
      fails when a file falls under the floor it declares (D-10). `tests/harness.luau`.
- [x] **Found by the fuzzer:** an unknown control kind on reserved id 0 was stepped over in
      silence — the only exception to "nothing vanishes" in 10,000 rounds. It is reported at `parse`
      now. The forward-compatibility argument for silence lost to this milestone's rule that nothing
      on the receive path is silent, and the repeat suppression already caps what saying so costs.
- [x] **Found while writing the hostile cases:** a two-variant enum has no unrepresentable tag. One
      bit, and both values name a variant, so the extra bits a hostile peer sets are masked off and
      what comes out is legal. Not a defect — but a test that thought it was writing an invalid tag
      was testing nothing, and three variants is where the case actually lives.

### Phase 7 — the learning curve

- [x] Every `error(` in `src/api/` names the fix, not the rule. Seventy of them, twenty rewritten,
      and `tools/messages.luau` is the check acceptance 13 asks for: a message must carry a **repair
      marker** — a netweave spelling to write, or an imperative naming an action — and must either
      show the offending value or spend eighty characters explaining a mistake that has none.
- [x] The `type function` errors got the same treatment. They print verbatim at the call site, in
      the declaration file, next to the line that is wrong, which is exactly where somebody learning
      the library is looking — so "`rate` is a number of packets per second" was the worst message
      in the repository rather than a small one.
- [x] `docs/DESIGN-API.md` §2.1: six classes with what each requires and what each forbids, then a
      second table for everything else on the surface, one row each with the one thing to know.
- [x] One worked example that declares, sends, authorizes, refuses and observes, in sixty lines.
      `tests/example_runtime.luau` runs it against the real `Outbound`, `Inbound`, budget and
      policy; `tools/messages.luau` asserts the code in the document is the same text, character for
      character, and that check was verified to fail against a deliberately drifted copy.
- [x] **Found by writing the example:** a `:listen` handler's `ctx` was `types.unknown`, which made
      it unreadable *and* un-annotatable — `Ctx` is not a supertype of `unknown`, so even
      `function(ctx: nw.Ctx, shot)` was rejected. Nothing caught it because every handler in the
      suite is written `function(_ctx, ...)` and none of them wanted the context. The view builds a
      shaped table now: `ctx.now` is a number, `ctx.playr` is a diagnostic, and the three
      Roblox-typed fields stay `unknown` because a type function body cannot name `Player`.
- [x] **Found by the same pass:** two stale messages. `Transport` told the reader that batching was
      M2 and nothing crossed the wire yet, which was true when it was written and a lie once the
      transport shipped, and `tests/api_runtime.luau` asserted on the word "M2".

### Phase 8 — repository policy

- [x] `CLAUDE.md` §9: the verification rules. The three the plan named, and six more that M3 paid
      for rather than reasoned its way to — each written next to the incident that produced it,
      because a rule with no incident behind it reads as taste and gets dropped by the next person.
- [x] The three from the plan, with what they cost: **failure paths outnumber success paths** and
      the count is in the harness (D-10); **a regression test is confirmed to fail against the
      pre-fix code**, which caught two tests in this milestone that were testing nothing; **no
      security claim without a probe**, whose corollary is that an unprobeable claim gets softened —
      D-5 changed from a decode-work counter to a byte ceiling because the measurement contradicted
      it.
- [x] The six the milestone found: a probe that finds nothing is written down; a rejection count
      guarding a feature with no positive test guards nothing (D-14); a parameter every test ignores
      is a coverage gap rather than a convention; a hand-kept list is tested against what it lists;
      nothing on the receive path is silent; errors name the fix, and that is checked rather than
      reviewed.
- [x] **The Studio run rehearsed before it was spent.** `tests/run.server.luau` requires every suite
      in one session and the benchmark declares its namespace in that same session; under lune each
      file is its own process, so everything a suite leaves behind is invisible here and costs a
      whole Play there. Requiring all fourteen in runner order found two:

      - `tests/example_runtime.luau` installed a loopback transport and did not put the real one
        back, which would have sent every mode after it into a hole. `api_runtime` already saved and
        restored; this file did not.
      - `tests/query_runtime.luau` left eight bytes parked in an `Outbound`'s loaded record, and
        `serdes_runtime` — which measures `Buffer.used()` after every write — failed on them. The
        suite that dirties shared state cleans up, and the suite that measures it starts from a
        state it knows.

### Phase 9 — the external review, and the number that went the wrong way

An outside security and correctness review of `src/` at `7f5871c` returned 26 findings:
3 중대, 5 위험, 12 경고, 6 미미 (`docs/SECURITY-REPORT.md`). The baseline suite is green against
every one of them — fourteen `*_runtime` files, `analyze` at 44 clean, three rejection files at
their declared counts, and `tools/messages`. **None of it is caught by anything this milestone
built**, and that is the finding behind the findings.

Five were reproduced here before any of the report was accepted, per §7. All five reproduce
exactly as described:

| Finding | Reproduced |
|---|---|
| `Ir.ceiling` omits per-element scope bytes | `t.array(t.boolean, 0, 10)` at ten elements: `maxSize` 1, actual 11. An honest three-element packet is refused with `payload claims 4 bytes, over the 1 this channel can hold` |
| A non-Instance sidecar entry raises on the receive path | `pcall(inbound.receive, ...)` returns false: `Serdes:920: attempt to call missing method 'IsA' of table`. Also with a number in the slot |
| Pooled pending lists under non-LIFO resumption | Three batches, alice resumes before bob: `Inbound:315: attempt to index nil with 'handler'`, and bob's second and third packets never arrive and are never reported |
| A bare `t.instance` hands the handler what the client sent | `who = 12345`, `typeof == "number"`, no report |
| A `state` id is decoded with no rate budget | 600 packets on a `nw.state` id: `queue=344`, `budget=0` |

The remaining 21 are **not** accepted on the strength of those five and are to be reproduced or
refuted one at a time.

#### The three that break a guarantee

- [x] **`Ir.ceiling` counts the scope a dynamic element opens.** The walker's comment — "flags live
      in the enclosing scope's bytes … the layout adds the scope once at the top" — was true of the
      root scope and false of every array or map element that opens one, so **every channel whose
      element type contained a boolean, an enum or an optional refused its own honest traffic** at
      stage `budget`, against the sender. One line: a node that opens a scope pays for it in
      `ceiling`, which is uniform rather than special-cased because only those three sites open one.
      The root's scope lives on the `Layout` rather than on `root`, so it cannot double-count.
- [x] **The sidecar's contents are checked where they are read.** `value:IsA(class)` on a table
      raised out of the read phase — G4 broken by the one piece of wire data that does not travel in
      the buffer. Refused per packet rather than per batch, because the length prefix can step over
      it and G5 says it should. The bare `t.instance` case was worse and is closed by the same
      check: with no class to test, whatever the client sent used to reach the handler *as an
      Instance*, with no report at all.
- [x] **The pending lists are held by whoever walks one.** `claim` took `pool[depth]` and `dispatch`
      decremented at the end of its loop, which assumed claims and releases nest; Roblox resumes
      remote callbacks in whatever order their waits complete. A free list has no order to get
      wrong — two overlapping walks hold different lists because neither has returned its own — and
      the high-water mark is the number of dispatches in flight, which is what the counter was
      reaching for and could not express.

#### The probes that were never written, which is why the three are there

- [x] `hostile_runtime` mutates the sidecar's **contents** now, not only its count: a number where a
      classed instance was declared, and a string where a bare one was. Both confirmed to raise
      against the pre-fix reader.
- [x] `ir_runtime` compares `codec.maxSize` against what the encoder actually wrote, as a property
      over sixteen schemas chosen to open a scope everywhere one can — and one fixed-length array as
      the control, because its positions unroll into the enclosing scope and must not move. Six
      failed before the fix. Phase 3's audit was the same idea as a table of ten examples, and the
      ten it picked all happened to work.
- [x] **The stand-ins had to become honest first.** Under lune there are no Instances and the suite
      stood them in with bare tables, so the strict check would have refused every test that carried
      one. The lune half of the check now asks the only thing the reader ever asks — *does it answer
      `:IsA`* — which is the exact precondition rather than an approximation, so a hostile bare table
      fails in both places instead of only in Studio. `tests/harness.luau` builds them.
- [x] `transport_runtime` resumes two parked batches out of order with a third arriving between
      them, and asserts every packet from every batch arrived exactly once. Against the pre-fix code:
      `Inbound:315: attempt to index nil with 'handler'`, seven of nine delivered, and the two lost
      ones never reported.

#### The five 위험, each with its own probe first

- [x] **G6 arrives on the wire.** Outbound-class ids were resolved, admitted and decoded for packets
      a client sent, and could not be budgeted because those classes declare no `rate` — so the
      reason they may not declare one, "the server is the sender on this class", rested on a check
      that did not exist. Refused before decode now, at a stage of its own: `direction`, which is
      `error` by default because nobody sends on a channel they receive on by accident.
      `Channel.directionOf` is the single source of truth and the test helpers read it rather than
      keeping a copy.
- [x] A bare `t.instance` field delivered a client-chosen non-Instance to the handler, the policy
      and `nw.validate`'s brand. Closed by the same check as the 중대 above: the reader refuses
      anything that is not an Instance whether or not a class was declared.
- [x] **The encoder stopped treating "did not raise" as "conforms".** The boolean writer tested
      truthiness, so `"false"` went on the wire as `true`; the instance writer tested only non-nil;
      the integer writers checked the range and let `buffer.writeu8` truncate the fraction — with an
      offset that is not even truncation, `-0.4` on `t.i16(-100, 100)` reading back as `-1`. Eight
      cases in `serdes_runtime`, all confirmed to pass against the pre-fix writers. Measured cost:
      **+4%** on both benchmark schemas (`ArrayHeavy` 0.02523 to 0.02626 ms per encode), which is
      what closing a silent type coercion across the wire is worth.
- [x] A throwing `link.send` in `flush` no longer parks its bytes for the next frame, and the loop
      no longer stops at the destination that raised. The probe needed a recipient that *recovers*
      to bite: one that only ever fails cannot distinguish the two bugs, because the `pcall` alone
      fixes the starvation and only the save ordering fixes the retry. Against the pre-fix code the
      recovered recipient's first successful frame carries five bytes where it should carry three.
- [x] **Handler-less channels bypass `pendingPerBatch`, and that is the examined answer rather than
      an oversight.** The two limits answer different questions: `queueCapacity` bounds what is held
      and drops the *oldest*, which is right for a `:listen` that attached a frame late, where the
      batch ceiling drops the newest and would lose exactly what the queue exists to keep. What was
      left unbounded is decode work, and on an inbound class that is what `rate` licenses — the
      genuinely unbounded case the finding pointed at was the outbound-class id above, which has no
      rate and is now refused before decode. Written into `Inbound` beside the code, and pinned.

#### The documentation that is now wrong

- [x] **G4 is enforced rather than inspected.** Both paths are fixed *and* the claim is made
      structural, because fixing the two somebody found does nothing for the third: the read phase
      and the dispatch phase each run under a guard that restores the shared state, returns the
      pending list and reports the raise. Two `pcall`s per batch. `hostile_runtime` tests it as a
      property — something raises where nothing should, and the batch comes back, says so, and
      leaves a decoder the next honest batch still works through.
- [x] "A packet claiming more is provably a lie" was true only where the schema had no flags below
      its top level. Corrected in `DESIGN-API.md` §3 with what it was wrong about.
- [x] `t.string`, `t.buffer` and `t.array` document 65,535 while the writer frames at most 16,383.
      Stated in `WIRE-FORMAT.md` §2 rather than left in a comment calling it "a design problem, not
      a runtime one". **The cap itself is not raised**: widening a frame to three bytes costs a byte
      on every counted packet forever to buy a payload size no channel in this project reaches, and
      that trade belongs to whoever needs it.
- [x] The reply-path checkbox is struck in phase 4 rather than fixed, with the argument
      `Outbound.reply` already carries and the gap that argument does not cover.
- [x] "The server is the sender on this class" now describes the wire as well as the views — see the
      `direction` stage above — so `DESIGN-API.md` §3 no longer rests the argument on a check that
      does not exist.
- [x] `nw.validate` is documented as being exactly as strict as the encoder, which is now a claim
      worth making.
- [x] Acceptance 5 and 10 were corrected in phase 8 and are correct. **Acceptance 1, 2 and 11 said
      "does not throw", and the two throws they were failing are fixed** — re-stated against the
      guard below, now that the remaining findings are triaged. Acceptance 10 gained a fourth
      refusal, because the mismatched hello is reported now.

#### The nine that were left, one at a time

Twenty-six findings, seventeen answered above. The nine below are the rest, each reproduced or
refuted against this tree before anything was changed — the report's own probes were not taken on
trust, and one of them turns out to be wrong.

- [x] **A mismatched hello is judged once per peer, not once per hello.** Id 0 is read before
      `sink.admit`, because resolving 0 would fail and *that* failure is the unrecoverable one — so
      nothing charges a hello a rate. Reproduced at 300 mismatched hellos in one 2,101-byte batch:
      **300 replies, 0 reports, 76 KB of garbage**, and repeating a single hash cost the same as
      rotating one. `greet` now returns before it rebuilds anything if the peer is already refused,
      which is the whole bound: the only thing that lifts a refusal is a hash that agrees. Measured
      after: **1 reply, 1 report**, allocation below the collector's noise floor. Pinned twice — as
      an `Agreement` property in `protocol_runtime`, and over the wire in `hostile_runtime`.
- [x] **The mismatched hello is reported.** It was recorded silently and first surfaced on a data
      packet behind it, so a peer that sent a hello and nothing else disagreed forever with neither
      console saying so. `greet` hands back the reason it minted and `sink.hello` emits it at
      `protocol`, with the control packet's own byte count.
- [x] ~~**A refused query request is answered before decode, outside any budget, and
      `Batch.read`'s premise that refusing stays cheaper than accepting does not hold for this
      class.**~~ **The second half is false, and it was inferred rather than measured.** Three
      hundred requests refused at `budget`, in one batch, against the same three hundred admitted
      and answered:

      | | bytes in | bytes out | time |
      |---|---|---|---|
      | refused | 1,074 | **1,074** | 0.71 ms |
      | admitted | 1,074 | **2,274** | 1.60 ms |

      Refusing is half of accepting in both, and the outbound never exceeds what the peer spent to
      provoke it. What the finding correctly names is the *gap in the argument* — `Outbound.reply`
      justified itself with "one-for-one with an admitted request", which says nothing about a
      refused one — and that is closed with these numbers written beside it. The reply itself
      stays: dropping it turns a client one packet over its burst into a caller parked for the
      whole `timeout`, which is the failure D-12 exists to prevent.
- [x] **A departing player's queued packets go with them.** `forget` released the budget, the
      context, the intent and the call slots and left the queues alone, so a `:listen` attached
      afterwards ran commands for somebody who was gone — and `Context.acquire` built a fresh
      record for the departed `Player` to run them against, which nothing would forget a second
      time. The ring is compacted in place, in arrival order, and the drop is reported once per
      channel. Six packets from two peers interleaved: all six arrived before the fix, three after.
- [x] **Under a flood the rejection path allocates nothing, which is what `Observer` and `Budget`
      already promised and `Inbound` did not keep.** Four reasons were built per packet: the
      queue-full one (`dropped {n} so far`), the two pending-ceiling ones, and — new in this
      milestone, so it was mine — the `direction` refusal, which is the cheapest one a hostile peer
      can provoke. All four are constants or per-configuration now.

      Pinned by **counting distinct strings rather than weighing the heap**, because a collector
      reading is not a number until it survives re-running (§9) and this property does not need
      one: a reason built per packet is a reason that *differs* per packet. Two thousand refusals
      across three stages produce **1,994 distinct reasons before the fix and 3 after**. The same
      shape as the report's 11,744-for-12,000.
- [x] **An observer that detaches itself no longer skips the one behind it.** `table.remove` inside
      a walk of `1..count` shifted the next observer into an index already passed, and the last
      index read `nil` — which `xpcall` accepts without a word. Removal is a tombstone and the list
      compacts when nothing is iterating it.
- [x] **`Trust.validate` clears the sidecar it filled.** `check` serialises for real, which is the
      design — the encoder stays the only statement of what a value must satisfy — and then rewound
      with `save`/`load`, which restores the instance *count* and leaves the entries past it. Every
      `nw.validate` of a payload carrying an Instance held a reference to it until some later write
      reused the slot. `mark`/`rollback` is the pair that clears them, and it is what the send path
      already uses for an encode that raised. It also stops allocating a record per call.
- [x] **`Recipients.roblox().owner` narrows instead of casting.** A `BasePart` or `Folder` subject
      reached `GetPlayerFromCharacter` behind a `:: Model`, on a path whose whole contract is "or
      nil". The report could not say whether Roblox raises on that; the check makes the answer not
      matter, and `tests/roblox_runtime.luau` grew its first non-codec section to pin it — that
      module's whole body is Roblox API calls, so lune sees an injected roster and never the real
      one, which is how it survived to an external review.
- [x] ~~**The client's protocol seals on the first inbound packet, so a namespace required later
      raises.**~~ **Real, reproduced by reading, and not fixable where the report looks.** The
      client's first `Driver.install` connects `OnClientEvent`, and the first batch to arrive seals
      — so a client that yields between `require(netweave)` and its namespace modules can be sealed
      by traffic it did not ask for. Deferring the seal is not available: decoding the packet that
      sealed it needs the id numbering, and the numbering needs every declaration
      (`WIRE-FORMAT.md` §3). What was wrong was the *diagnosis*, which said "declare every
      namespace before the first packet moves" without saying that on a client the first packet is
      one that **arrives**. The `declare` error and both cautions say it now, because a developer
      hitting this is staring at that message.

#### The benchmark, which answered acceptance 6 and asked a new question

`bench/runs/2026-09-05-m3.json`, sixteen minutes, delivery exact in all three netweave cells
(`received == sent`). The `pendingPerBatch` refusals seen in the console are warm-up only, before
the measured window opens.

| netweave, `up` | M2 | M3 | |
|---|---|---|---|
| `ArrayHeavy` framerate | 86 | 83 | −3.5% |
| `ArrayHeavy` encode alloc | 3932.2 B | **6551.0 B** | **+66.6%** |
| `ArrayHeavy` decode alloc | 9309.2 B | **10176.5 B** | **+9.3%** |
| `FlagIdiomatic` encode / decode | 81.9 / 462.8 | 81.9 / 462.8 | byte-identical |
| `FlagNaive` encode / decode | 81.9 / 462.8 | 81.9 / 462.8 | byte-identical |

- [x] ~~**Acceptance 6 is answered and the answer is a regression.**~~ ~~**Find the encode
      regression.**~~ **There is no regression, and the numbers that said there was are not
      reproducible.**

      The `ArrayHeavy` allocation cells survive three to seven sample windows out of twenty-five,
      and between the M2 and M3 runs, libraries whose code had not changed by a line moved **19%**
      (blink encode), **21%** (zap encode), **37%** (blink decode) and **86%** (zap decode). Every
      flag cell in both runs agreed to the decimal, in all five modes — which is the tell: their
      windows are small enough that every one survives.

      The same comparison run under lune against both trees, with one *frame* per window instead of
      one packet, returns four hundred usable windows out of four hundred with a spread of zero and
      says the two are identical:

      | per packet | M2 `272965a` | M3 `7e5e00b` |
      |---|---|---|
      | `ArrayHeavy` encode | 1908.4 B | 1908.4 B |
      | `ArrayHeavy` through `inbound.receive` | 32048.2 B `[0 spread]` | 32048.2 B `[0 spread]` |
      | `Flags` encode | 30.5 B | 30.5 B |
      | `Flags` through `inbound.receive` | 560.2 B `[0 spread]` | 560.2 B `[0 spread]` |

      Reproduced twice. The lune absolute figures are not comparable to Studio's — a different
      runtime accounts for its heap differently — but the *comparison* is the question, and both
      trees ran the same probe on the same machine in the same minute.

      What nearly happened is the part worth recording. The flag cells being identical narrowed it
      to "something on the large-payload send path", and phase 4's `guarded(writer, ...)` vararg
      forwarding was the named suspect. Reverting it would have "fixed" a regression that did not
      exist, and the commit would have stood forever with a plausible message and no defect behind
      it. What answered the question was the **control group** — how far the code that did not change
      moved in the same run.
- [x] **The harness records its spread now.** `Alloc.measure` returns `low` and `high` beside the
      median, both the client and the server write them into the run document, `ALLOC_REPEATS`
      doubles, and `bench/README.md` says to read the spread and the sample count before quoting the
      median. A probe that cannot be reproduced now says so in the document instead of in the next
      milestone's plan. `CLAUDE.md` §5 already said never to report a number that was not produced
      by a committed, re-runnable script; a number that does not survive re-running fails the same
      test and nothing was checking it.
- [ ] **Decide what to do about `ArrayHeavy`.** Against the field netweave is now last on framerate
      (83 against blink 131, bytenet 115, zap 111) and worst on decode allocation by 13 to 21 times
      (10176.5 against zap 480.3, blink 770.0, bytenet 2338.8). The decode number is read-then-
      dispatch working as designed — D-6 chose it over cross-player attribution and that trade
      stands — but "as designed" is not the same as "as measured", and the flag cells show netweave
      winning decode allocation outright (462.8, best of five). The array case is one schema family
      and the second is `§3.9-Z`'s reason for measuring two.
- [ ] `bench/src/shared/Modes/netweave.luau` raises `pendingPerBatch` beside its `rateUnbounded`
      exception, in the same "considered exception, written down" shape, so the harness stops
      dropping during warm-up.
- [ ] The run document reports `"netweave":"M2 (protocol 502048910)"`. The mode hardcodes the
      milestone; a results file that misattributes its own subject is a provenance bug.

#### What this phase is really about

Every one of the three 중대 is a probe nobody wrote, and this milestone spent a whole phase writing
`CLAUDE.md` §9 about exactly that. §9 says a hand-kept list is tested against what it lists; the
ceiling is a *derivation* tested against nothing. It says a parameter every test ignores is a
coverage gap; the sidecar's contents are that parameter. It says a regression test is confirmed
against pre-fix code; the LIFO case was confirmed, and only for the interleaving that was written.

The rules were right and the coverage they demand was read too narrowly. That belongs in §9 as a
worked example rather than as another rule.

## 7. Acceptance criteria

1. A policy that raises refuses that one packet at stage `"authorize"` with the raised message, and
   every other packet in the same batch is delivered. Demonstrated with 3 packets, 1 throwing, 2
   delivered — against today's code the number delivered is **0**.
2. A policy returning `nil`, `false`, `{}` or `{ ok = "yes" }` refuses. None of the four throws.
3. A channel declared `rate = 20` admits at most 20 in **any** sliding 1.0 s window, not merely in
   an aligned one. Against today's code the measured figure is 40.
4. A packet claiming 65535 elements costs within 2x of an honest one. ~~Today it costs 690x.~~
   **Met: 1.27x** — 0.000492 ms against 0.000386, over 20,000 rounds each, and the hostile one is
   still refused with `array claims 65535 elements, needing 65535 bytes, and 1 remain`. (Three bytes
   and four rather than two and three: the varint for 65535 takes three on its own.)
5. ~~Any nesting of bounded arrays reaching the per-tick decode ceiling refuses at stage
   `"budget"`.~~ **The ceiling changed, in phase 2, because the measurement contradicted the premise
   — see D-5.** What holds instead: any nesting of bounded arrays past the channel's *byte* ceiling
   refuses at stage `"budget"` before a byte of the payload is decoded, and the ceiling is derived
   from the schema whether or not the game declared one. Pinned in `tests/transport_runtime.luau`
   with `t.array(t.array(t.u8, 0, 1000), 0, 1000)`, which derives 1,002,002 and is bounded by a
   declared 64.
6. `ArrayHeavy` decode allocation per packet is reported against the M2 baseline of 9309.2 B in
   `bench/RESULTS.md`, whether it moved or not. ~~**Measured: 10176.5 B, +9.3%** — it moved the wrong
   way, and the same run shows encode allocation on that cell at +66.6%.~~ **Both figures are
   artefacts of a probe that survives four sample windows; the criterion is not met, because the
   harness cannot yet produce a reproducible number for this cell.** Phase 9 makes the spread
   visible so the next run can say whether it has one. The run document is
   `bench/runs/2026-09-05-m3.json`; `bench/RESULTS.md` is pending.
7. A game that attaches no observer sees a warning on the first refusal of each channel and stage,
   and does not see a second for the same pair.
8. `nw.diagnostics()` returns a snapshot that cannot be mutated into the live counters.
9. A `query` whose peer never answers resolves as a failure within its declared timeout. No thread
   is left suspended, and the pending entry is gone. Call ids pass 256 without collision.
10. Changing one field from `t.u8` to `t.u16` changes the protocol hash. ~~A client on the old hash
    is refused once at stage `"protocol"`, not once per packet.~~ **Half of that is wrong and the
    correction matters.** The *check* happens once, at the hello; the *refusal* is per packet, and
    has to be. The hello is the first packet of the first batch, so the packets behind it in that
    same batch are the first ones that must not land — and they would not fail to decode, they would
    decode into whatever channel this peer has at that id and reach a handler as a well-formed
    payload. Pinned in `tests/protocol_runtime.luau`: three packets behind a mismatched hello,
    ~~three refusals at `"protocol"`~~ **four** — the hello itself is reported now (phase 9), which
    is what a peer that sends one and nothing else needs — and nothing delivered.
11. The fuzz suite runs at least 10,000 mutated batches with **zero** raises off the receive path
    and zero unreported losses.
12. Failure-path assertions outnumber success-path assertions in `transport_runtime`,
    `budget_runtime`, `hostile_runtime` and `fuzz_runtime`. The counter is in the harness and the
    suite enforces it.
13. Every `error(` reachable from `src/api/` names what was written and what to write instead. A
    test greps for the ones that do not.
14. `stylua --check`, `selene`, `lune run analyze`, every `*_runtime`, `lune run bench/check` and
    `lune run bench/envelope` pass.

~~**Criteria 1, 2 and 11 each say "does not throw", and two receive-path throws are now measured
(phase 9). They are not met, and the suite passing is the reason to distrust the suite rather than
the measurement.**~~ **Met, and re-stated so that passing means something.**

The two throws are fixed, but "the two we found are fixed" is what the suite already believed
before an external review found them, so the criteria are no longer read as a list of paths.
**Criteria 1, 2 and 11 are met by the guard**: the read phase and the dispatch phase each run under
a `pcall` that restores the shared state, returns the pending list and reports the raise, so
*anything* that raises where nothing should costs one packet and a report rather than the batch.
`hostile_runtime` tests that as a property — something raises inside each phase, and the batch comes
back, says so, and leaves a decoder the next honest batch still works through — and `fuzz_runtime`
runs its 10,000 mutated batches against the same guard.

Criterion 5 was corrected in phase 8 to describe the byte ceiling that shipped; phase 9 found that
ceiling refusing honest traffic, fixed it, and pinned the property — `codec.maxSize` against what
the encoder actually writes, over sixteen schemas — so it is met.

Criterion 6 is the one still open, and it is open on the *harness* rather than on netweave: see
phase 9.

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
