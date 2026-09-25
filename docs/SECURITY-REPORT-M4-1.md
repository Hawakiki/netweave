# Netweave Security & Correctness Report — M4-1

**Scope:** the whole repository at commit `7737e09` on `develop` (2026-09-06, "Archive the M4 phase 8
matrix run"): `src/` by folder, `tests/`, `bench/`, `tools/` with `analyze.luau` and the root
configuration, and `docs/` with `CLAUDE.md`. The previous report (`SECURITY-REPORT-M4.md`) audited
`15f74f2`; 29 commits landed between the two, most of them closing that report's findings and adding
types. This pass re-verifies every one of those 78 closures from the code, not from the documents, and
audits everything new.

**Method:** nine auditors ran in parallel against a **frozen snapshot** of `7737e09` extracted with
`git archive` into the session scratchpad, so a commit landing mid-audit could not move a line number.
Seven ran on Fable 5.1 (the five `src/` scopes, `tests/`, `docs/`); two on Opus 5 (`bench/`, `tools/`).
Each could read any file its scope requires or is consumed by but could report only on its own scope;
anything else went to the owning auditor as a dependency notice and was reconciled here. Six axes
carried equal weight this pass at the owner's request: security, correctness, types (error /
insufficiency / not fit for purpose), optimization, comments and docstrings, documentation versus
implementation. Every auditor was told **not** to inherit any list of what is open or closed from the
plan documents or from the fixing session, and to establish it from the code. Every finding is marked
*measured* (probe, mutation or analyzer output) or *inferred* (with sources). Line numbers were verified
with `grep -n` in the snapshot by the auditing agent; the synthesis spot-checked the key ones.

**Baseline:** green. `lune run analyze` 52 files clean, rejection files at 24 / 8 / 11, all eighteen
`*_runtime` files pass, `tools/messages` (73 error calls), `tools/exports` (19 covered, 7 gaps),
`bench/check`, `bench/envelope`, `selene`, `stylua --check` all pass. **None of what follows is caught
by the suite**, and the suite itself is one of the scopes.

**What this report contains that the previous one did not:** a disposition table for the previous
report's 78 findings (the tracker `PLAN-M4` phase 8 says the report is, and which it did not have);
three scopes audited for the first time (the test suite, the benchmark harness, the checkers); comment
and optimization findings at full weight; and, per scope, the three things the auditor would block a
release on.

## Severity
- 미미 — cosmetic, or a limit the documentation already states elsewhere
- 경고 — a real defect with a bounded blast radius, or a documented guarantee that is weaker than stated
- 위험 — a client can cause measurable harm without a game bug; a type hole lets untrusted data reach an authoritative function without a spelled-out cast; a checker passes on something that would silently remove a guarantee; a number the plans rely on cannot be reproduced from a committed artifact
- 중대 — a guarantee the library sells is broken, ordinary traffic is refused or lost, a test passes with the guard it claims to pin removed, or a claim in a results document is contradicted by its own artifact
- 심각 — remote code execution, cross-player data exposure, or authoritative state changed without a policy

For optimization and comment findings the same tokens apply, with 위험 or above only where a reader
would rely on a security or correctness property that does not hold.

## Disposition of the previous report's 78 findings

Established from the code at `7737e09`. "Closed" means the probe re-run shows the fixed behaviour and,
where a regression test was added, that test was run over the pre-fix source (`git archive <commit>~1`)
and failed there. Nine such pre-fix runs were made this pass and all nine fail as claimed; one commit
(`2ea8c90`, roster `has`) has a test that passes over the pre-fix source under lune because the defect
was Studio-only, which the commit message says.

**Totals: closed 18, closed differently 4, partially closed 4, declined with an argument 1, open 51.**
Six of the closures (rows 2, 3, 4, 10, 38, 39) are recorded only in commit messages and source
docstrings; no document in `docs/` says they happened. Three closures overturned decisions written in
`PLAN-M4` (rows 1, 10, 18) and the plan carries the old sentences unstruck.

| # | Finding (M4 report) | Code at 7737e09 |
|---|---|---|
| 1 | RESYNC re-encode every frame | **closed differently** — coalesced to one resend per 30 ticks per (peer, channel), verdict checked (3351d58); still charged to no budget, silent when coalesced, window a constant (new finding below) |
| 2 | zero-byte array/map elements | closed (2596da8); `carriesNothing` refuses at lowering, hand-built descriptors too |
| 3 | optional map key raises | closed; `t.map` refuses at declaration and the reader rejects a nil key |
| 4 | brand dropped on `t.optional(struct)` | closed (916364b); unions branded component-wise; six must-fail cases fail, `api_reject` 23 → 24 |
| 5 | `nw.validate` returns caller's table, launders `Untrusted` | open |
| 6 | channel record mutable after seal | open |
| 7 | `isType` duck check | open; `types/init.luau:879-881` now documents it as a limitation |
| 8 | `readVarint` wraps ≥ 2^32 | open |
| 9 | `nw.internal` exposure, unfrozen modules | open |
| 10 | client applies `pendingPerBatch` → livelock | closed (7df2228); 257 and 300 subjects converge on frame 1; 1,000-packet server batch delivered whole; pre-fix test 4 failures |
| 11 | hash omits `subject` | closed (f495311); pre-fix test 5 failures |
| 12 | `t.f32` non-dyadic bounds refused | closed (9aad273); reader compares against `asF32(bound)`; 0 of 8,000 random bounds refused; pre-fix 4 failures |
| 13 | nested `Observer.emit` overwrites the record | open (re-measured: observer J sees `inner` twice) |
| 14 | fractional integer bounds | closed (cbed97d) |
| 15 | floats capped ±2^24 / ±2^53 | closed (cbed97d); `MAX_F32`/`MAX_F64` |
| 16 | failed `nw.namespace` leaves `qualified` | open |
| 17 | `t.struct` keeps `fields` by reference | open, and duplicated into `t.union` (new finding) |
| 18 | over `baselinesPerClient` re-sent and reported every frame | **closed differently** — reported once per crossing with re-arm (d4d4938); the whole-subject re-send every idle frame is kept by argument (new finding) |
| 19 | departed player's baselines recreated | **partial** — `select` filtered through `roster.has` (2ea8c90); `owner` and `nearby` are not (new finding) |
| 20 | game raise in tick aborts flush | open, plus a fourth trigger (new finding) |
| 21 | handler receives the mutable baseline | closed (477b24b); deep freeze measured; pre-fix 7 failures |
| 22 | `nw.signature()` seals as a side effect | open; `Namespace.protocol`'s docstring now says it, `nw.signature`'s does not |
| 23 | datatype writers accept NaN / non-unit / wrong class | open for bare `t.vector3`, `t.unitVector3`, `t.cframe`, `t.color3`, classed `t.instance`; closed for componented vectors only |
| 24 | replicate change past 16,383 retried forever | open (re-measured: 5 of 5 `false`, subject never advances) |
| 25 | `Baseline.keep(nil)` count drift | open (unreachable from `Tick.send`) |
| 26 | `Agreement.forget(nil)` | open |
| 27 | `closeBlock` negative shortfall | open |
| 28 | Color3 NaN byte | open |
| 29 | `t.instance("")` accepted | open |
| 30 | unknown stage/rule silent | open |
| 31 | joiner snapshot believed delivered | open; still inferred — the remote-events page states a bound exists and not its size |
| 32 | dispatch loop one `pcall` | open (re-measured: rest of batch dropped, report `? nil 0`) |
| 33 | `select` holes / departed / duplicates | closed (67fe53f, 2ea8c90); pre-fix 6 failures |
| 34 | install guard in edit mode | open (inferred; `RunService` YAML confirms `IsServer` true, `IsRunning` false in edit) |
| 35 | server seals on first client packet | open, no argument written |
| 36 | `check()` inside an open block | open |
| 37 | `nw.Views<D>` annotation erases G3/G6 | **declined with an argument that holds for the type** (0cac0ab: six safe spellings pinned, one canary); the erasure is unchanged (A.2 re-run: 0 diagnostics with the annotation, 2 without); the caution the code says is in `DESIGN-API.md` §7 is not there (new finding) |
| 38 | `t.PayloadOf` never reduces | **closed differently** — direct-require path fixed by a local instantiation (916364b); the path the docstring prescribes (`require(nw).types` then `t.PayloadOf<…>`) is still `Unknown type` (new finding) |
| 39 | `CheckedSettings` refuses `nw.Settings` | closed (916364b); `config_ok` writes `local declared: nw.Settings`; a literal `nil` section is still refused with "got that" (미미) |
| 40 | plain-table audience crashes view type functions | open; also crashes for a literal `{ scope = "everyone", kind = "owner" }` |
| 41 | seven analysis/runtime disagreements | open; now nineteen (new finding) |
| 42 | `Ir.patch` framing `static` | open |
| 43 | `Policy<T>` unbound | open |
| 44 | `ctx` not annotatable, `player: unknown` | **partial** — `function(ctx: nw.Ctx, …)` compiles now; `player` is still `unknown`; the threaded-`Ctx` fix was implemented in a private copy this pass and measured working (six lines in `View.luau`, suite unchanged) |
| 45 | misspelt spec keys accepted | open (22 declarations, 4 diagnostics) |
| 46 | `channel: any` across the boundary | open |
| 47 | encoding tables keyed `string` | open |
| 48 | `Sink` stage `string` | open |
| 49 | `store.changed` never read | closed — deleted (b8465eb), with a measurement recorded in `Store.luau` |
| 50 | sidecar typed `{ Instance }` | open |
| 51 | WIRE-FORMAT §6 "clamped" | open |
| 52 | "`nw.observe` replaces console output" | open (re-measured) |
| 53 | "`error` reports every occurrence" | open |
| 54 | DESIGN-API §3 sequence number | open; `PLAN-M4` D-2 and phase 2 also unstruck |
| 55 | `replicate` row: `subject` missing, one-arg listener | open |
| 56 | acceptance 4 met by hand-swapped audience | open |
| 57 | acceptance 11 unenforceable | open (41% at floor 0.3; honest share lower — new finding) |
| 58 | 65,535 in types docstrings, `Batch` comment, DESIGN-API:264 | open |
| 59 | reference-equality fast path cannot fire | **partial** — cost fixed by a different mechanism (b8465eb compares once per subject); the docstrings still promise a pointer compare that cannot fire |
| 60 | `src/types` messages fail the `tools/messages` bar | open; now 54 sites, checker still `src/api` only |
| 61 | "Six classes", stage/rule/limit lists | open (ten stages, not the eleven the M4 report said) |
| 62 | Forbids columns | open |
| 63 | TypeId 21 vs 19 | open; also in `Delta.luau:15` and `RESEARCH:75` |
| 64 | Scope artifacts that do not exist | open |
| 65 | CLAUDE.md floors quoted as measured | open |
| 66 | CLAUDE.md §2 layout stale | open; more files since |
| 67 | stale cross-references | open |
| 68 | SECURITY-REPORT.md stale | open |
| 69 | stale `src` docstrings | open, every one listed |
| 70 | tick O(S × P) | closed (b8465eb) for schema-shaped tables; 47 ms → 1.7 ms at 50 × 500 (n = 21); defeated by non-schema keys and select-all audiences (new findings) |
| 71 | decode never takes a block path | **closed differently** — `fusedStructReader` (db49ca5) spans a struct of 1–8 flagless number fields; the root static payload is not spanned; the at-commit test proves equivalence, not that the path is taken |
| 72 | `Context.acquire` per packet | closed (5478812); 0 reads for 20 untouched packets; pre-fix 5 failures; a new consequence (new finding) |
| 73 | `Delta.write` closure per call | open; now measured at 112 B per call, 0 with `commit` hoisted |
| 74 | per-refusal interpolation in `Batch.read` | open (500 claims, 50 distinct lengths → 50 distinct strings) |
| 75 | one RESYNC per refused packet | server side coalesced; client `desync` still per refusal (44 refusals → 44 calls) |
| 76 | `Buffer.take` regrows per frame | open; measured: record size 64 → 2048 → 64 across one 1.5 KB write and a take, five doublings per destination per frame |
| 77 | per-tick allocations (`replicated()`, `GetPlayers`) | open |
| 78 | dead code | `Buffer.ensure` → `span` (closed); `Ir.lengthSize` still test-only |

The findings below are **new**. An open row above is not re-listed as a finding; residue left by a
"closed differently" or "partial" row is.

## Current Security Risks

### [위험] A declared `t.string` pattern runs Lua's backtracking matcher on attacker-chosen bytes, and ordinary patterns cost seconds per packet
- Category: Security-current
- Location: `src/codec/Serdes.luau:2029` (reader: `string.find(value, anchored)`), `:1146` (writer), `src/types/init.luau:525-548` (`refineText`, no complexity constraint), docstring `:829-841` (covers escaping, not cost)
- Problem: the reader anchors the author's pattern and runs it on the full string after `readString`. Luau's matcher backtracks over every repetition of `.*`, `.-`, `%s*` and the like and bounds only recursion depth, not total steps; `luau.org/library` defers pattern semantics to the Lua 5.3 manual and says nothing about cost. A pattern with two unbounded quantifiers is quadratic in the input, three is cubic, and the input is bounded only by the declared `max`, which defaults to 65,535. Found independently by the codec and types auditors.
- Impact: one packet stalls the server thread for the whole match. The rate budget is per packet and the byte ceiling is per schema, so neither bounds it; a `(.*)@(.*)%.(.*)` on a chat or name field is a 34-second stall per packet inside the declared `rate`.
- Evidence: measured (lune, ms, n = 5 at ≤ 16 KB, n = 3 at 65,535):

  | pattern | 1,024 B | 16,384 B | 65,535 B |
  |---|---|---|---|
  | `(.*)x(.*)y` on `x^n` | 5.5–5.6 | 1,459–1,843 | 24,300–25,287 |
  | `(.*)@(.*)%.(.*)` on `@^n` | 7.7–13.2 | 2,103–2,177 | 34,125–37,814 |
  | `(.-)%s*` on `a^k ' '^k a` | 0.012 | — | 5,481–5,642 |
  | `.*.*.*x` on `a^n` | 800 B: 671 | (killed after 5 min) | — |
  | `[%w_]+` (control) | 0.012 | 0.19 | 0.78 |

  16× the length costs 280× the time for the two-`.*` case. Fix: refuse at `t.string` a pattern with more than one unbounded item unless `max` is small (≤ 64 keeps the worst case under 0.1 ms), or offer a character-class-only constraint (`{ charset = "%w_" }`) that is linear by construction; state the cost rule in the docstring either way.

### [경고] A malformed pattern that passes `t.string`'s validator makes the reader raise on a client string
- Category: Security-potential (G4)
- Location: `src/types/init.luau:541-545` (`check((pcall(string.find, "", pattern)), …)`), docstring `:834-835`; `src/codec/Serdes.luau:2029`
- Problem: the validator runs the pattern against the empty subject, so any malformed construct behind a literal that fails on `""` is never reached: `"a%b"`, `"a%f"`, `"a%1"`, `"a[b"`, `"a("`, `"a%"` are accepted at declaration, while `"%"`, `"[a"`, `"%1"` are refused. The reader then calls `string.find(value, "^a%b$")` on a peer's string and Luau raises `malformed pattern (missing arguments to '%b')` on the receive path, outside `reject`. `"a("` and `"a%"` do not raise but match nothing, so every honest string is refused at `parse` against its own sender. Lua 5.3 §6.4.1 states malformed patterns raise during matching, not at construction.
- Impact: one client string beginning with the literal prefix aborts the batch it arrived in — the guard is netweave's own and it is the guard that is wrong. Rated 경고 rather than 위험 because a game has to have declared the pattern; the writer raises the same way at `:send`, so a game whose test strings never hit the prefix ships it.
- Evidence: measured (`reader pcall ok: false … Serdes:2029: malformed pattern (missing arguments to '%b')`; `'a(' → nil, "string does not match the declared pattern"`). Fix: a scanner for `%b`, `%f`, `%<digit>`, unbalanced `(`/`[`, trailing `%`, or a `pcall` against subjects that exercise every item.

### [경고] The resync bound is a hard constant, charged to nothing, and a coalesced ask is silent
- Category: Security-current
- Location: `src/transport/Inbound.luau:672` (`RESYNC_TICKS = 30`, not a `Config` limit), `:944-961` (coalesce; the deferred branch `:953-957` returns without `report`), `src/transport/Batch.luau:516-581` (control kinds read before `admit`)
- Problem: 3351d58's bound holds — one full resend per window per (peer, channel), measured on frames 2, 31, 61 only — but three things remain. Nothing is charged: `budget.usage` is `0 0 0` after 101 resyncs, so `nw.diagnostics` cannot show the peer. The deferred branch neither reports nor counts, so a peer asking every frame is invisible to `nw.observe` (90 attack frames, `reports []`) — §9 "nothing on the receive path is silent". The window is a constant a game cannot tune: with a 30 KB replicated state (5,000 subjects) each hostile client extracts 60 KB/s of encode and downlink per channel for 10 B/s up.
- Impact: a bounded amplifier proportional to state size × replicated channels × colluding clients, with no observability and no knob.
- Evidence: measured. N = 100: 450 B up bought 1,803 B down over 90 frames; N = 300: 1,801 B per window. Fix: report the coalesced ask at stage `replicate` with a constant reason, charge `bytes` to the peer's usage, lift `RESYNC_TICKS` into `Config.LIMITS`.

### [경고] `owner` and `nearby` audiences bypass `roster.has`, so a departed player's baselines and parked send record are rebuilt after `forget`
- Category: Security-potential
- Location: `src/transport/Recipients.luau:289-302` (`owner`/`nearby` return the roster's answer unchecked; `has` consulted only in the `select` arm at `:341-342`), `src/replication/Tick.luau:196-216` (`send` keeps for whoever is named), `:309-334` (both removal passes walk `roster.all()`), `src/transport/Outbound.luau:157-178` (`switchTo` parks a record for any key)
- Problem: 2ea8c90 closed the `select` half of M4 finding 19. `owner` returns `roster.owner(subject)`, which for a `Player` subject is the instance itself, connected or not. If the store lists the departed player's subject for one more tick (a profile save that yields — the DESIGN-API worked example is `audience = owner, store = of(byPlayer)`), the tick keeps a snapshot for them and `Outbound` parks a record; once the subject vanishes, the removal pass cannot see a player the roster no longer returns. Found independently by the transport and replication auditors. Inferred second angle: `Players.yaml` says `PlayerRemoving` fires before `ChildRemoved` on `Players`, so during a game's own `PlayerRemoving` handler the player is still in `GetPlayers()` and a publish there rebuilds the record after netweave's `forget`.
- Impact: one `records[player]` tree plus a snapshot per subject, plus one `Buffer.Save`, per such departure, for the life of the server; and a `FireClient` to a departed player that Roblox does not document.
- Evidence: measured. After `forget(carol)` on all three server stores, one tick with `owner = carol` sent 7 B to carol and `serverBase.held(carol) == 1`; after the subject is gone the baseline stays at 1. `select` and `everyone` stay at 0.

## Current Bugs

### [중대] A `replicate` snapshot arriving before `:listen` is folded into the baseline, reported as a handler raise, and never delivered to the late listener
- Location: `src/transport/Inbound.luau:1058-1112` (`change` sink: folds into the store, queues to `filling`, never consults `channel.handler`), `:981-998` (the handler-less queue that only `deliver` takes), `:436-462` (`call` runs `xpcall(nil, …)`), `:1180-1210` (`drain` finds no queue for a `replicate` channel)
- Problem: every other class keeps packets for a handler attached one frame late (`Inbound.luau:595-598`: "losing the traffic to it is a bug the game cannot see"). `replicate` is the one class whose first packet is a join-time snapshot the server sends as soon as the player is in `GetPlayers()`, and its sink bypasses that queue: the value is hardened and kept, then dispatched to a nil handler. The baseline now says the client has the subject, so the server never re-sends it; the late listener sees it only if it changes.
- Impact: with declarations done and listeners in a controller loaded after a yield — the ordering the queue exists for — every subject in the first batch produces a `handler` report `attempt to call a nil value` with a traceback, attributed as a game handler bug, and a static subject is invisible for the session. Ordinary traffic lost and misreported, on the join path.
- Evidence: measured (loopback rig, `channel.handler = nil`, two subjects): after frame 1 `reports [handler=2]`, first reason `attempt to call a nil value`; client baseline holds 2, mirror 0; after `:listen` + `drain`: mirror 0; after subject 1 changes: mirror 1; after 100 idle frames subject 2 seen: **false**. Fix that allocates nothing: on `drain` of a `replicate` channel, walk the client's baselines and deliver each held subject — the baseline *is* the queue; and in `change`, skip the pending entry when `handler == nil`.

### [중대] `t.map` refuses a struct, enum or union payload at the type layer — the "entities by id" schema does not compile
- Category: Type-error
- Location: `src/types/init.luau:1203` (`function t.map<K, V>(key: Type<K>, value: Type<V>): Type<{ [K]: V }>`)
- Problem: with `--!strict` and `LuauSolverV2`, `t.map(t.u8, t.struct({ a = t.u8 }))` is `TypeError: Expected this to be exactly 'unknown', but got '{ a: number }'`; `t.map(t.u8, t.union({ a = t.u8 }))` the same; `t.map(t.enum({ a = true }), t.u8)` is `Expected this to be 'Type<unknown>', but got 'Type<"a">'`. Primitive, `t.array`, `t.optional`, `t.vector3` and `t.string` payloads on either side are fine, and the one-parameter generics (`t.array(struct)`, `t.optional(struct)`) are fine inside a spec literal — it is the two-parameter generic meeting a type-function-produced payload. Reproduced byte-for-byte on `15f74f2`, so it predates every commit in this window; no `tests/*_ok.luau` writes a map whose value is a struct (`grep "t\.map("` over `src tests docs`: one `t.map(t.string, t.u8)` in `types_ok:48`). The api auditor reached the same seam from the other side: `local o = t.optional(S)` outside a spec is `Type<unknown?>`, so `nw.validate(t.optional(struct), v)` returns `unknown?` and the brand the M4 fix describes never applies on that path.
- Impact: the canonical replicated-state schema (`t.map(t.u16, Entity)`) cannot be declared in the only mode the library supports without `(t.map :: any)(…)`, which erases the payload type for everything downstream. The runtime lowers and encodes it correctly; the sold guarantee is the type.
- Evidence: measured (`luau-lsp analyze` with the project's flags; the same file over `15f74f2` and `916364b~1`). Fix: a `MapPayload(key, value)` type function reading both `__payload`s, the way `t.struct` already does, and `t.map(t.u16, Entity)` written into `types_ok`.

### [경고] A stray write into a production `ctx` is now permanent for that player
- Location: `src/api/Context.luau:164-189` (`live` has `__index` only), `:207-237` (`acquire` clears `character`/`humanoid` only when `record.looked`)
- Problem: before 5478812 every `acquire` overwrote `character` and `humanoid`, so a handler that wrote into `ctx` was corrected on the next packet. Now the lazy `__index` fires only while the key is absent: a write to `ctx.character` (or any key) sits in the shared per-player record and is returned to every later policy and handler for that player until `forget`. The Studio guard's `__newindex` does not exist on the production record, although `Context.luau:17-21` says the footgun "is guarded rather than documented".
- Impact: one game bug (`ctx.character = …`, `ctx.cooldown = now`) becomes a persistent per-player context corruption that a policy such as `originNearCharacter` then trusts, with no message in production.
- Evidence: measured: `custom key leaks into the next packet: 1`; after `ctx2.character = "forged"`: `a forged character persists across packets: forged`, and again on the packet after. Fix costs nothing per packet: a `__newindex` on `live` that raises (the guard's message exists), or two `rawset`s clearing both keys unconditionally in `acquire`.

### [경고] `Protocol.ATTRIBUTES` omits `whole`, so a `t.u53` peer and a `t.f64(0, 2^53)` peer hash identically and read the same bytes differently
- Location: `src/api/Protocol.luau:76-97` (`ATTRIBUTES`)
- Problem: `t.u53` is an f64 on the wire with a wholeness check; `t.f64(0, 2^53)` is the same storage without it. The attribute list that feeds the hash does not carry `whole`, so `Protocol.signatureOf` is byte-identical for the two — one peer refuses 1.5 and the other delivers it, with no `protocol` refusal. Found by the codec auditor as a dependency notice and verified by its probe; the same class as M4 finding 11 (subject) and D-7.
- Evidence: measured (`codec_m41_clone.luau`: identical signatures). Fix: add `whole` (and any future reader-side attribute) to `ATTRIBUTES`, and a `protocol_runtime` case that changes it alone.

### [경고] Arrays of optionals are measured with `#`, so a value of the declared type is silently shortened or refused
- Location: `src/codec/Serdes.luau:1043, :1055, :1064` (`writeLength(#value, …)`, `count = #value`)
- Problem: `t.array(t.optional(T))` types as `{ T? }`, but `#` on a table with nils is a border. A leading or trailing nil changes what is sent with no raise and no report; an exact-length array with a trailing nil is refused outright.
- Impact: `{1, 2, nil}` on a dynamic array sends 2; `{[2] = -5}` sends `{}` (three of 6,000 random round-trips differed for exactly this); `{1, 2, 3, nil}` on `t.array(t.optional(t.u8), 4)` raises "must hold exactly 4, got 3" while `{1, nil, nil, 4}` is accepted — the same shape, decided by the VM's border choice. The silent-coercion class M3 phase 9 closed for booleans and fractions.
- Evidence: measured. Fix: iterate `1..exact` without consulting `#` for an exact length (the loop at `:1057` already does; only the check at `:1055` reads `#`); for a dynamic array of optionals either refuse the declaration (trailing nils are unrepresentable) or document that `#` decides.

### [경고] A cycle through a non-schema key overflows the stack in `snapshot`, a fourth way for game data to abort the frame's flush
- Location: `src/replication/Tick.luau:129-143` (`snapshot`: unbounded recursion over every key), `:164-192` (`moved`, same), `src/transport/Driver.luau:189-193` (`replicate()` unguarded before `outbound.flush()`)
- Problem: M4 finding 20 (a store, selector, NaN subject or protected metatable raising inside the tick stalls every channel's flush) is unchanged, and the walk being over the game's whole table rather than the schema's fields adds a trigger: a value carrying a back-reference through a key the schema never mentions (`entity.owner.entity`) overflows the stack.
- Impact: every outbound channel, every player, for as long as the value persists. Game bug required; the blast radius is the server.
- Evidence: measured (`Tick:134: stack overflow`; the three earlier triggers re-measured: `Tick:237 table index is NaN`, `Tick:134 invalid argument #1 to 'clone'`, store raise → ch2's change never flushed).

### [경고] Over `baselinesPerClient` the whole subject is re-sent every idle frame, and the default pair means an `everyone` audience pays it from subject 257
- Location: `src/replication/Baseline.luau:164-197` (refuse; the value is not remembered), `src/replication/Tick.luau:277-292` (`baselines.of(who) == held` is nil for a refused client, so `send` runs every tick)
- Problem: d4d4938's argument — correctness over bandwidth — holds for *not dropping state*; it does not cover *every tick whether it moved or not*. The tick already knows the value has not moved (`settled`); what it lacks is a record that the refused client received the last snapshot, a per-client boolean rather than a baseline. `pendingPerBatch` was fixed for the same 257 threshold; this one was documented instead.
- Impact: 300 subjects at defaults: 265 B/frame per client for a world at rest, forever (≈ 15.9 KB/s per client; 50 clients ≈ 795 KB/s of server upload for nothing). One report, then silence.
- Evidence: measured (`repl_livelock 300`: 265 B every frame from frame 2, `serverHeld = 256`, one `replicate` refusal; 257: 7 B/frame).

### [경고] `t.union` inherits `t.struct`'s by-reference branches and adds number keys the analyzer misreports
- Category: Bug-current / Type-error
- Location: `src/types/init.luau:1314-1329`
- Problem: `branches = branches :: any` keeps the caller's table by reference, unfrozen — swapping a branch after declaration changes what a codec built later encodes and what the signature hashes (measured: `S.fields.id.kind now string`). `t.union({ [1] = t.u8 })` and `{ [true] = t.u8 }` are accepted at runtime with `variants = {1}` while the analyzer rejects them with "a union needs at least one branch" — the wrong message, because `properties()` excludes indexer entries so the branch is invisible rather than absent; mixed keys `{ a = t.u8, [1] = t.u8 }` die in `table.sort` with the VM's `attempt to compare string < number` and the analyzer says nothing.
- Evidence: measured.

### [경고] `t.unitVector3` accepts a component schema that cannot hold a unit vector
- Location: `src/types/init.luau:872-903` (`vectored` checks `component.kind == "number"` only), `:951-955`
- Problem: `t.unitVector3(t.i16(-2048, 2048))`, `t.unitVector3(t.u8)`, `t.unitVector3(t.u53)` and `t.vector3(t.quantized(0, 1, 0.5))` are accepted and lower (6 and 3 bytes). An integer component can represent only the six axis-aligned unit vectors; an unsigned one cannot represent a negative axis. The writer refuses fractional components and the reader's unit tolerance widens only for a quantised step, so almost every honest direction is refused — the `t.array(x, 1.5)` shape one level up.
- Evidence: measured for acceptance and lowering; the refusal itself is inferred from `Serdes.luau:2095-2103`, since `Vector3` does not exist under lune. Fix: require a fractional component whose range covers `[-1, 1]`.

### [경고] `t.string`'s anchor check refuses an escaped `%$` and accepts a mid-pattern `^`/`$`
- Location: `src/types/init.luau:534-539`
- Problem: the check reads the last character only, so `pattern = "%d+%$"` (digits then a literal dollar, which Lua 5.3 §6.4.1 says `%$` means) is refused as "carries its own anchor"; `"a^b"` and `"a$b"` pass (harmless). There is no way to declare a value that must end in `$` except `[$]`.
- Evidence: measured.

### [미미] Every `nw.namespace` and `nw.configure` error names `src/netweave.luau` as the offending line
- Location: `src/api/Namespace.luau:68-95` (level 3), `:129-190` (level 2), `src/api/Config.luau:600, :612-620, :634-638, :668, :689, :699, :708`
- Problem: the levels were chosen for a direct call, but both are reached through wrappers (`src/netweave.luau:236` and `:290`), so every message carries the wrapper's line. `tools/messages` checks the text and cannot see the position.
- Evidence: measured (`bad name -> …src\netweave:291: nw.namespace takes the name first…`; control `nw.command` direct → the caller's line).

### [미미] A duck-typed non-channel is refused with "already declared as nil"
- Location: `src/api/Namespace.luau:168-176`, `src/api/Channel.luau:1177-1179` (`isChannel`: any table with a string `primitive`)
- Evidence: measured (`fake.f is already declared as nil`).

### [미미] `CheckedSettings` accepts any union as a severity and refuses a literal `nil` section with "got that"
- Location: `src/api/Config.luau:335-341` (`isSeverity` accepts `value:is("union")`), `:297-319` (`named` has no case for `nil`)
- Evidence: measured (`"warn" | number` passes; `nw.configure({ rules = nil })` refused with "got that").

### [미미] Extra arguments are dropped by exactly the constructors whose comment says they refuse them
- Location: `src/types/init.luau:589-591` (comment), `:764` (`quantized`), `:878` (`vectored`), `:990` (`instance`)
- Evidence: measured (`quantized(0,1,0.5,'extra')`, `vector3(t.u8,'extra')`, `instance('Sound', {}, 'y')` all accepted).

## Potential Bugs

### [경고] The idle gate is schema-unaware: non-schema keys are cloned into every baseline, compared every tick, and can defeat the gate entirely
- Category: Optimization (with the cycle above as its bug edge)
- Location: `src/replication/Tick.luau:129-143` (`snapshot` clones every key), `:164-192` (`moved` walks every key), comment `:253-266` and `src/replication/Store.luau:78-82` ("compares each subject once a tick")
- Problem: the comparison is over the game's whole table, not the schema's fields. A key the schema does not read but which changes every frame (`lastSeen = os.clock()`, a `Character` reference) makes every subject "moved" and the per-pair attempt that b8465eb removed comes back. A large non-schema subtree (a `Replica.Data` whose inventory is not replicated through this channel) is cloned into the baseline and walked every tick.
- Impact: the 22× claim holds only for tables shaped exactly like the schema.
- Evidence: measured (50 × 500, n = 21): constant extra key → 0 attempts, 1.58 ms; changing extra key → **25,000 attempts/tick, 22.4 ms** (21.3–28.8); 100 subjects × 2,000-entry non-schema list, 1 player → 18.8 MB cloned into baselines, idle **16.6 ms** (15.8–19.3) vs 0.036 ms control. Fix: restrict `snapshot`/`moved` to the schema's fields (the layout is in `channel.delta.layout`).

### [경고] A `select` audience that returns every player costs O(S · P²) at rest — 15.5 ms per tick at 50 × 500
- Category: Optimization
- Location: `src/replication/Tick.luau:100-110` (`among`, linear), `:309-315` (removal pass: for every player holding a baseline, an `among` scan of length P), comment `:100-101` ("an audience is a handful of players")
- Problem: the broadcast skip exists only for `kind == "everyone"`. The most common `select` shape — everyone except spectators, a team filter — returns P players, so every subject pays P `baselines.of` lookups × P-length scans to conclude nothing. `bench/tick` has no rung for it (`narrow` is one recipient).
- Evidence: measured (n = 21): `everyone` 1.62 ms (1.59–1.66); `select` returning all 50 → **15.55 ms** (15.3–19.0), 0 attempts either way. Fix: give `select` the broadcast skip when it returns the roster, or index `among`.

## Type Errors

### [경고] Analysis and runtime disagree on nineteen declarations; the seven from the previous report all reproduce
- Location: `src/types/init.luau:1106` (`optional`), `:1249` (`struct`), `:1082` (`enum`), `:568-604` (`ranged.__call`), `:764` (`quantized`), `:872-903` (`vectored`), `:983-1032` (`instance`), `:1203` (`map`), `:1314` (`union`)
- Problem, each measured:

  | declaration | analysis | runtime |
  |---|---|---|
  | `t.optional(t.optional(t.u8))` | accepts `Type<number?>` | rejects |
  | `t.struct({})` | accepts `Type<{}>` | rejects |
  | `t.enum({ [1] = true })` | rejects | accepts `variants = {1}` |
  | `t.struct({ [1] = t.u8 })` | payload `{}` | accepts, `order = {1}` |
  | `t.enum({ a = true, b = "yes" })` | accepts | rejects |
  | `t.u8(0, 10, 99)` | "expects 3 arguments, but 3 are specified" | rejects |
  | `t.u8(10, 0)`, `t.u8(0.5, 2.5)`, `t.u53(0, 2^54)` | accepts | rejects |
  | `t.quantized(1, -1, 0.1)`, `(0, 1, 0)` | accepts | rejects |
  | `t.quantized(0, 1, 0.5, "x")` | accepts | accepts, 4th dropped |
  | `t.string(0, 8, { patern = "%d+" })`, `{ utf8 = "yes" }`, `"utf8"` | accepts | rejects |
  | `t.vector3(t.string)`, `(t.optional(t.u8))`, `("x")` | accepts | rejects |
  | `t.vector3({ kind = "number" })` | accepts | `fromSchema` raises `Ir:382 arithmetic on nil` |
  | `t.instance(5)`, `("Sound", 5)`, `("Sound", { descendantOf = "workspace" })` | accepts | rejects |
  | `t.map(t.optional(t.u8), …)` | accepts | rejects |
  | `t.map(t.struct(…), …)` | rejects with the invariance message | rejects with the fix named |
  | `t.union({ [1] = t.u8 })` | rejects, wrong message | accepts |
  | `t.union({ a = t.u8, [1] = t.u8 })` | accepts | VM error |
  | `t.optional({ kind = "number" })` | rejects with 14 lines for one mistake | accepts |
  | `t.array(t.u8, "5")` | accepts | VM `attempt to compare number <= string` |

- Impact: the vocabulary's runtime guards and its type functions are two hand-kept lists (§9). Numeric bounds cannot be checked at analysis — the solver widens literals — and the matrix should say so.
- Evidence: measured (`types_matrix.luau`, `types_rt.luau`).

## Type Insufficiency

### [경고] The `__call` signatures on `Ranged`, `Text`, `Componented` and `Classed` check arity, not argument types
- Category: Type-not-fit-for-purpose
- Location: `src/types/init.luau:328-331`, `:358-361`, `:375-378`, `:403-406`
- Problem: under luau-lsp 1.69.0 with `LuauSolverV2`, a call through a `typeof(setmetatable({} :: T, {} :: { __call: … }))` alias enforces the count and not the types: `t.u8(0, "b")`, `t.string(0, 5, { utf8 = 1 })`, `t.vector3(t.boolean)`, `t.vector3(t.string)`, `t.instance(5)`, `t.instance("Sound", { descendantOf = "workspace" })` — no diagnostic. A minimal `setmetatable` callable reproduces it; typing `self` does not help; the intersection form `Base & ((min: number, max: number) -> Base)` checks both arguments and is usable bare, but `StructPayload`'s `field:is("table")` is false for an intersection, so the three payload type functions would need to look through one (the `types` library lists `"intersection"` as its own tag).
- Impact: every runtime `check()` on these constructors is the only check; `types_ok`'s `t.Text`/`t.Componented` assertions prove the return type, not the parameters.
- Evidence: measured (21-line probe, 8 diagnostics, none on a wrong-typed argument).

### [경고] Types this library hands to games cannot be named through `nw`
- Location: `src/netweave.luau:350-369` (the export list), `src/api/Policy.luau:85, :109-112`, `src/api/Config.luau:100, :141, :175, :192`, `src/api/Audience.luau:37, :52`, `src/api/Observer.luau:109`
- Problem: `nw.policy` returns `Policy<T>`, `nw.audience.nearby` returns `Audience<"subset">`, `nw.configure` returns a `Config.Snapshot`, `nw.config.describe()` returns `{ Described }`, `nw.observe` takes an `Observer` — and `nw` re-exports none of them, so a policies module (`local policy: { alive: nw.Policy<Equip> }`) has to `require("…/api/Config")`, which `CLAUDE.md` §2 and `tools/exports.luau:57-60` call internal. `tools/exports` enumerates `export type` declarations, so it structurally cannot see a public value with no type at all. Found by the api and tools auditors.
- Evidence: measured (four `Unknown type` diagnostics from a probe; the snapshot's real type has no public name).

### [경고] `TextOptions` and `InstanceOptions` cannot refuse a misspelt key, annotated or not
- Location: `src/types/init.luau:341-344`, `:387-389`
- Problem: `local o: t.TextOptions = { patern = "x" }` is clean (only an unused-variable lint); `{ utf8 = "yes" }` under the annotation does error. The type catches value types and not the spelling, which is the mistake the runtime check at `:507-513` says "looks exactly like one that passed". `tests/types_ok.luau:169-172, 232-236` claims the annotation checks the key.
- Evidence: measured.

## Types That Compile but Do Not Guarantee What They Exist For

### [경고] The `nw.Views<D>` export has no docstring, and the caution the code and tests say is in DESIGN-API §7 is not there
- Category: Doc-missing
- Location: `src/netweave.luau:360-369` (ten `export type`s, of which only `Trusted`/`Untrusted` carry a `--[=[ ]=]`), `src/api/View.luau:331` and `tests/api_reject.luau:272` ("the caution … on `DESIGN-API.md` §7"), `docs/DESIGN-API.md:711` ("G6 is a compile-time guarantee")
- Problem: M4 finding 37 was answered by 0cac0ab as documentation-plus-canary — the erasure is still there (A.2 re-run: 0 diagnostics with `local _v: nw.Views<…> = ns`, 2 without). The caution lives in `View.luau` (internal) and in a test comment, both of which say it is also in DESIGN-API §7; `grep "Views<" docs/DESIGN-API.md` finds only the Q5 paragraph at line 618. Both `View.luau:332` and `api_reject.luau:272` say the count "moves to 25" if the erasure lifts; it moves to 26. Found by the docs, types and api auditors.
- Impact: a reader of §7 relies on "G6 is a compile-time guarantee" and writes the one spelling that removes it, with no diagnostic and no caution anywhere a game reads.
- Evidence: measured (A.2 re-run; grep; a private copy of `api_reject.luau` with line 280 deleted → 26).

### [미미] `Roster.has` is optional, so a roster that omits it silently takes the weaker kind test
- Location: `src/transport/Recipients.luau:138`, `:341-342`
- Evidence: inferred; cost of making it required is the one `lenient` test section.

### [미미] `Delta.apply`'s `(nil, nil)` versus `(nil, reason)` contract lives only in a `--[[ ]]`
- Location: `src/replication/Delta.luau:435-442`
- Problem: `value` is `any`, so `value.n` on a removal or a refusal is not a diagnostic. The one caller handles it; the next will not be told.
- Evidence: measured (0 diagnostics).

## Documentation / Implementation Mismatches

### [경고] No document records the disposition of the previous report's 78 findings, and PLAN-M4 says the report is the tracker
- Category: Doc-missing / Plan-rule-violation (CLAUDE.md §3)
- Location: `docs/milestone/PLAN-M4.md:672-675` ("each fix is its own commit and the report is the tracker"); `docs/SECURITY-REPORT-M4.md` (no Disposition section, unlike `SECURITY-REPORT.md:333-373`)
- Problem: the report has no tracker; six closures exist only in commit messages; three phase-8 commits overturned decisions the plan wrote down and none was struck through; nothing says which of the remaining 51 are open, declined or deferred. The table at the top of this report is that tracker.
- Evidence: inferred (`grep -n "finding\|danger" PLAN-M4.md` finds no reference to the numbered findings).

### [경고] PLAN-M4 decisions overturned by phase-8 commits are still stated as current
- Category: Plan-rule-violation
- Location: `docs/milestone/PLAN-M4.md:97-100` and `:287-290` (D-2 / phase 2: `pendingPerBatch` drops deltas on the client → a sequence per client per subject), `:368-373` (phase 4: over `baselinesPerClient` it "degrad[es] to exactly what `nw.state` does"), `:546-550` (phase 6: resync "bounded rather than refused: 300 in one batch clear a baseline once")
- Problem: 7df2228 made the ceiling server-only (`src/api/Config.luau:132`), d4d4938 struck the `nw.state` claim in `Baseline.luau` and said why, 3351d58 replaced the per-batch bound with a 30-tick coalesce and struck it in WIRE-FORMAT:198-218. The plan carries all three pre-fix sentences live; phase 4 strikes the sequence number but D-2 and phase 2 do not.
- Evidence: inferred from the four texts against `Inbound.luau:672`, `Config.luau:132`, `Baseline.luau:165-170`.

### [경고] DESIGN-API §3 specifies a client-side `pendingPerBatch` drop and a sequence number; WIRE-FORMAT §2 justifies the absence of a sequence number with the same removed drop path
- Location: `docs/DESIGN-API.md:407-411`; `docs/WIRE-FORMAT.md:190-193` ("the only thing that drops one is netweave's own `pendingPerBatch`")
- Problem: since 7df2228 the client's ceiling is `math.huge`, so nothing netweave-side drops a delivered change on a client; recovery is the client's own refusal → `RESYNC`. DESIGN-API describes a wire feature that does not exist; WIRE-FORMAT justifies its absence with a drop that no longer exists. `Batch.luau:134-137` also states the pre-3351d58 per-tick resync bound as current — the sentence WIRE-FORMAT strikes.
- Evidence: inferred (`Inbound.luau:687`, `:289-315`).

### [경고] DESIGN-API §3's documented escape from the frozen value — `local mine = table.clone(value)` — is shallow, so the first nested write raises
- Location: `docs/DESIGN-API.md:396`; `src/api/Channel.luau:1069-1070`
- Problem: `luau.org/library`: `table.clone` returns a copy that "is not frozen even if `t` was" — of the top level only; every subtree is the frozen shared one. The advice works for a flat schema and fails for exactly the nested schemas whose sharing motivated the freeze.
- Evidence: measured (`mine.hp = 3` works; `mine.pos.x = 3` → "attempt to modify a readonly table").

### [경고] `t.instance("Sound")` "rejects anything that is not a `Sound`" — on the read path only; `nw.validate` brands a wrong class
- Category: Doc-mismatch / Security-potential
- Location: `src/types/init.luau:975-976` (docstring), `:1044-1050` (`t.player` caution); `src/codec/Serdes.luau:1236-1250` (writer checks `isInstance` only; class and `descendantOf` are read-side, `:2213`, `:2229`)
- Problem: `nw.validate(t.instance("Sound"), <BasePart>)` returns the value branded `Trusted<Instance>` with `failure = nil`, while the reader refuses the same bytes with `instance is not a Sound`. DESIGN-API §2.1 sells `nw.validate` as "exactly as strict as the encoder is" — true, and the encoder does not check class. This is the instance half of M4 finding 23, which the writer-side fix for componented vectors did not touch.
- Evidence: measured.

### [경고] WIRE-FORMAT §5 does not say signed integers are offset-binary on the wire
- Category: Doc-missing
- Location: `docs/WIRE-FORMAT.md:374-376` ("Written at their declared width. A range constraint narrows the width and subtracts the lower bound")
- Problem: a bare `t.i8`, `t.i16`, `t.i32` is stored as `value − min` in unsigned storage even with no range constraint. A second implementation written from this frozen document would emit two's complement and mis-decode every negative integer.
- Evidence: measured (`t.i8` −1 → `7f`; −128 → `00`; `t.i16` −1 → `ff 7f`; `t.i32` −1 → `ff ff ff 7f`; `t.f32` −1 → `00 00 80 bf`, floats are not offset).

### [경고] WIRE-FORMAT has no layout for six wire-affecting kinds added since 15f74f2, and §4 does not say which node attributes reach the hash
- Location: `docs/WIRE-FORMAT.md:373-376` (Numbers), `:378-382` (Instances), `:279-283` (hash coverage), `:6-8` (preamble: "the one addition since the freeze")
- Problem: `t.quantized` (a count of steps in u8/u16/u32), `t.u53`/`t.i53` (narrowed like `u32`, else an f64 with a wholeness check), `t.vector3(component)` (three component nodes), `t.union` (documented in §5 as a design and now implemented as designed — the one thing here that is in the document), and the string `utf8`/`pattern` constraints (hash-visible, not wire-visible) are documented only in commit messages and docstrings. §4 says the hash covers "the lowered node tree" but not that `step`, `utf8`, `pattern`, `unit`, union `branches` are in it and `descendantOf` deliberately is not. Found by the docs and codec auditors.
- Evidence: measured (probe bytes: quantized `{q=-0.5, deg=90}` → `68 01 40`; `u53` narrow 1000 → `e7 03`; `grep -i "quantiz\|u53\|utf8\|pattern\|component\|descendantOf"` over the doc returns nothing).

### [경고] DESIGN-API §6 describes the brands as passing non-tables through unchanged; since 916364b a union is branded component-wise
- Location: `docs/DESIGN-API.md:526-532` (the `type function` sample), `:593-596`; `src/api/Trust.luau:96-141`
- Problem: §6's code sample is now false; "a scalar payload is unbranded" stays true but the optional-table case that was the hole is neither listed as closed nor described.
- Evidence: inferred.

### [경고] PLAN-M4 acceptance criteria 4, 8, 10 and 11 are stated as checkable and their status is not written
- Category: Plan-rule-violation
- Location: `docs/milestone/PLAN-M4.md:943` (4), `:947` (8), `:949` (10), `:950` (11)
- Problem: (4) both rigs still swap the audience by hand and `roblox_runtime` has no `nearby` replication case. (8) the crossover has no measurement and no artifact (no replication mode in `bench/src/shared/Modes/`, no RESULTS entry). (10) "the Studio suite is run and green" is asserted only in commit 7737e09's message; the archived run carries no suite field. (11) "outnumber" means > 50%; measured 41% against a declared floor of 0.3 — and the honest share is lower (see the test suite section). None is marked unmet.
- Evidence: measured for 8, 10, 11; inferred for 4.

### [경고] "908 is Roblox's documented ceiling" is not what the official page says, and §3.7-F does not say it either
- Category: Citation-error
- Location: `docs/DESIGN-API.md:888-889`; `src/api/Config.luau:133`; `src/transport/Outbound.luau:59`
- Problem: the creator-docs YAML for `UnreliableRemoteEvent` says "Has a 1000 byte limit to the payload of the event"; `RESEARCH-AND-PLAN.md:97` says "실제 상한 약 908바이트(문서는 900)"; §3.7-F records only that no competitor checks any limit. 908 is a devforum-measured figure presented as Roblox's own number with a citation that does not contain it. The 908 ceiling is conservative and safe; the record is wrong.
- Evidence: measured (fetch of the YAML; the rendered page returned no limit sentence at all).

### [경고] CLAUDE.md §9 and DESIGN-API §3 cite PLAN-M3 D-3 for "39 admissions in ten milliseconds"; D-3 says 40 in a sliding 1.0 s span
- Category: Number-disagreement
- Location: `CLAUDE.md:419`; `docs/DESIGN-API.md:293-294`; `docs/milestone/PLAN-M3.md:93-95`
- Problem: neither "39" nor "ten milliseconds" appears in PLAN-M3. The incident behind a §9 rule is recorded with a number the cited document contradicts. `CLAUDE.md:432`'s "67% and 9%" has the same problem: "9%" is not in PLAN-M3.
- Evidence: measured (grep).

### [미미] Statements in `CLAUDE.md` that measure false
- Location: `CLAUDE.md:203` ("Rokit shims resolve only inside a directory with a manifest" — `luau-lsp --version` via the shim returned `1.69.0` from a scratch directory with no manifest; rokit's `discovery/mod.rs` searches cwd, every ancestor, the home manifests, then `PATH`), `:211` ("selene has no scoped lint filters" — see the checkers section), `:288-289` (floors quoted as measured, `transport_runtime` now 67%), §2 (`roblox.yml`, a 33,299-line generated file that `selene` needs — renaming it takes `selene src tests` from 0 to 212 errors — appears nowhere; `tools/` is still "globalTypes.d.luau for the analyzer"; `docs/milestone/` stops at `PLAN-M2.md`; `README.md` is referenced by DESIGN-API §0 and CLAUDE.md §1 and does not exist)
- Evidence: measured.

### [미미] Statements in the two previous reports now wrong, for this report to strike
- Location: `docs/SECURITY-REPORT.md:347` ("has not been run yet" — `roblox_runtime` ran in phase 9 and at 7737e09), `:467-468` (A.2 writes `{ fake = true }` through the encoder, which now refuses it); `docs/SECURITY-REPORT-M4.md:18` (23/8/8 → 24/8/11; 49% → 41%), `:263` (cites the remote-events page for queueing — that page says nothing about queueing), `:422` and `:455` ("eleven stages" — ten), `:454` (the YAML today says 1000 only), `:94` and `:651` (`Serdes:1254` is `1297` at the pre-fix commit and the path no longer exists), Appendix A.1 `:602` (`R = "../src/"` assumes `spike/`; the three printed outcomes are all inverted now)
- Evidence: measured.

## Comments and Docstrings

Judged by CLAUDE.md §4's two kinds: a `--[=[ ]=]` must let someone decide whether to use the thing; a
`--[[ ]]` must record the constraint, the failed alternative or the competitor mistake with a `§`
citation that says what is attributed, and never restate the line below. Every `§` citation in `src/`
was read at its heading in `RESEARCH-AND-PLAN.md`; the ones below are the ones that do not hold.

### [경고] `Batch.luau` states the pre-3351d58 resync bound as current
- Location: `src/transport/Batch.luau:134-137` ("the resend it provokes happens once in the tick that follows however many arrive — so the worst a peer can extract is a whole state per tick")
- Problem: that sentence is the bound `WIRE-FORMAT.md:198-207` strikes through as "the wrong bound … measured in M4 phase 8"; the file that owns the control kind still asserts it un-struck. A reader of `Batch` takes a per-tick bound as the security property; the real one is per 30 ticks and lives in `Inbound`.
- Evidence: measured (one resend per 30 frames) against the text.

### [경고] `Query.abandon`, `ceilingReplyReason` and the `holdReply` ceiling branch are unreachable, and four comments describe them as live
- Location: `src/transport/Inbound.luau:770-793` (`holdReply` runs only on a client, where `pendingCeiling` is `math.huge` since `:687`), `:777-785`, `src/transport/Query.luau:78-81, :404-434` ("The only caller is the pending-set ceiling"), `src/transport/Outbound.luau:416`
- Problem: 7df2228 made the branch dead and `query_runtime` says so; the source does not. A future reader restores the ceiling on the client "because the abandon path handles replies" — the M4 livelock, reintroduced with a citation.
- Evidence: inferred from `:687`, `:773` and `Batch.read:623-634`; `grep abandon` shows the one call.

### [경고] `Buffer.luau` says Zap coalesces block allocations; the research log says the opposite, and the cited section is about something else
- Location: `src/codec/Buffer.luau:143-144` ("Blink and Zap emit one allocation for a block and then write at `offset + k` (`RESEARCH §3.7-D`, §3.8-T)")
- Problem: `RESEARCH §3.8-O` (line 552, "Zap은 할당을 병합하지 않는다") and §3.9-V1 record that Zap's `push_writeu8` calls `alloc(1)` per primitive (`_refsrc/zap/zap/src/output/luau/base.luau:42-52`); §3.8-T is about named-type inlining. Only Blink coalesces. CLAUDE.md requires a competitor claim to cite a section that says it; this one cites a section that contradicts it, and a reader pricing the block optimisation against "what both generators do" gets the wrong control group.
- Evidence: inferred (three sources read).

### [경고] The replication docstrings still promise a pointer compare that cannot fire through the tick
- Location: `src/replication/Delta.luau:89-96`, `src/replication/Store.luau:62-64, :103-105, :154-155` ("Charm still gets the cheap path … differs on its first key"), `src/replication/Tick.luau:121-122` ("Charm does not have the problem")
- Problem: the baseline is always `snapshot(current)`, a deep clone (`Tick:212`), so `a == b` at any table level is false for every store, Charm included; the idle case is cheap because `moved()` walks structurally, and that walk costs a Charm atom exactly what it costs a plain table. This is the `changed` failure class again: an optimisation described, not present. Residue of M4 finding 59.
- Evidence: measured ("server baseline is the store's own table: false"; 0 attempts with the identical table because the structural walk found nothing).

### [미미] `§` and `_refsrc/` citations that do not say what is attributed
- Location and problem, one line each:
  - `src/codec/Ir.luau:570` cites `RESEARCH §3.9-P`; §3.9 runs V–DD, the section is §3.8-P (line 582).
  - `src/codec/Serdes.luau:1829` cites `§3.7-M` for the `table.clone` finding; §3.7-M is a corrections table; the finding is §3.8-S (line 662) and the 389 B figure is RESEARCH:1237.
  - `src/codec/Buffer.luau:99` ("Blink grows by 1.5x and Zap by 2x") is true — `_refsrc/blink/src/Templates/Base.luau:81`, `_refsrc/zap/zap/src/output/luau/base.luau:45` — and cites nothing.
  - `src/replication/Delta.luau:14-16` "twenty-one ids" — `_refsrc/delta-compress/src/TypeId.luau:4-22` lists 19; `:28-30` attributes "decode into a table and then walk it … criticises ByteNet" to `§3.8-S`, which is Blink's and Zap's rehash and never names ByteNet.
  - `src/replication/Baseline.luau:27-28` cites `PLAN-M3` D-6 for "memory sized by how many people join"; D-6 is the pending-set ceiling.
  - `src/api/Policy.luau:41-43` says Flamework "spreads the guard over a decorator and a registry" citing `§3.5-S3`; the section shows middleware declared in `createServer({ middleware })` and mentions no decorator.
  - `src/transport/Recipients.luau:21` cites "`DESIGN-API.md` §10.4" for the per-subject question; it is at `DESIGN-API.md:912` under "## 11. Open".
  - `src/transport/Inbound.luau:15` and `src/transport/Budget.luau:204` "no surveyed library reports rejection rates at all" — `§3-G6` as corrected says Warp attempts it and gets it wrong.
- Evidence: measured (grep of the log and the vendored sources).

### [미미] Stale, overstated or restating comments in `src/`
- Location and problem, one line each, all read in the snapshot:
  - `src/transport/Recipients.luau:31-39` — the pre-2ea8c90 paragraph sits un-struck directly above the block at `:40-66` that strikes the same sentence, and says "`has` above" for a function defined below.
  - `src/transport/Outbound.luau:57` "all three surveyed libraries" vs `:65` "none of the four"; `:117` `@param isServer` (no such parameter); `:446-449` "the record keeps [the buffer]" (it does not — measured 64 → 2048 → 64); `:59` "908 is the documented limit".
  - `src/transport/Inbound.luau:14` "Four things happen to a packet" (ten stages), `:256` "the same six arrays" (seven), `:682-687` (the client builds `ceilingReason` "if it ever does" report; it cannot), `:954` `seen[channel] = honoured` (dead store); `src/transport/Driver.luau:198` "Four places" (six `forget`s); `:57-61` `task.spawn` "propagating whatever that thread raises" — creator-docs `task.yaml` is silent on errors; `src/transport/Batch.luau:9-16` grammar omits the change and control shapes; `:566/569` an unknown control kind reports body bytes where every other refusal reports the whole packet.
  - `src/codec/Serdes.luau:20-27` "encode errors loudly … `error` with a message naming the field" — false for type-mismatched values (six VM messages) and for the bare datatype writers (silent); `:1291-1293` "refuses a count past the last level" — `t.quantized(1e15, 1e15+1, 0.001)` accepts count 1008 of 1000 because the step is below the ulp of the bound; `:944-945`, `:2007` ("The half the finding is actually about" names no finding); `src/codec/Buffer.luau:149-155` "`load` and `take` clear it" — `rollback` and `discardBlock` do too; `src/codec/Ir.luau:174-182` and `Serdes.luau:2266-2274` `@interface` blocks missing `instances`, `maxSize`, `layout`; `Ir.luau:954` ceiling derived from 65,535.
  - `src/replication/Baseline.luau:223-225` ("D-2's break detector" — withdrawn in phase 4), `src/replication/Tick.luau:100-101` ("an audience is a handful of players"), `src/replication/Delta.luau:46` (`type Flags` re-declared; `Serdes.luau:43` keeps its own).
  - `src/api/Channel.luau:7-18, :57` ("six channel classes"), `:987` (`nw.state` "Server-to-client replicated state" while `:1041` says the same for `replicate`), `:1157-1158` (`event` docstring attributes delta replication to `state`), `:839` ("Coalescing itself lands with the transport in M2"), `:232-235` (`forbid`'s `store`/`subject` reasons unreachable — no class calls them; `command store={}` compiles and is accepted at runtime), `:66-88` (`@interface` names none of `fromClient`, `fromServer`, `unreliable`, `replyMaxBytes`, `subject`, `store`, `subjectCodec`, `delta`, `changeFraming`, `changeInstances`); `src/api/View.luau:104-106, :469-471`, `src/api/Namespace.luau:162-163` ("not a channel" lists six constructors); `Namespace.luau:299-312` (the `@function channelById` block sits above `replicated`); `src/api/Observer.luau:32` (`@type Stage` names eight of ten; `replicate` described nowhere); `src/api/Config.luau:138, :662-663` ("all three" of six limits), `:200-215` (a truncated duplicate `--[[` swallows the width-subtyping note); `src/api/Audience.luau:22-27, :47-50` ("Evaluation belongs to M2 … Until M2 caches it per tick" — `select` still runs per publish); `src/api/Transport.luau:9-11` ("M1 defines … M2 defines"); `src/api/Trust.luau:12`, `src/api/Context.luau:10` (examples call `:listen` without `.server`).
  - `src/types/init.luau:21-22` (`t.f32(-90, 90)` "derives … a narrower encoding" — a float range never narrows, `:704-706`), `:11` and `src/netweave.luau:10` (`require(Packages.netweave)`; the package is a Folder and `t.PayloadOf`/`t.Type` are unreachable through `.types`), `:83` (`.variants` "enum" — `t.union` stores it too), `:118` (`Type<T>` as `Descriptor & { __payload: T }`, the shape `:127-132` says does not work), `:819, :852, :1127` (65535); `src/netweave.luau:38` (G6 "type error" only; stage `direction` refuses it on the wire), `:376` ("The seams M2 attaches to"), `:87` (`@prop milestone string` — nothing pins `"M4"`); eight of the ten exports at `:360-369` have no `--[=[ ]=]`.
  - `tests/example_runtime.luau:8` and `tools/messages.luau:6` name `tests/messages.luau`; the checker is `tools/messages.luau`.
- Evidence: measured by grep and reading.

## Optimization

### [경고] The decode side spans only a struct of 1–8 flagless number fields; the root static payload is not spanned
- Location: `src/codec/Serdes.luau:1447-1743` (`fusedStructReader`), `rowsOf` `:567-628`, `src/codec/Buffer.luau:934-944` (`span`)
- Problem: db49ca5 closed M4 finding 71 differently than described. The at-commit test passes over the pre-fix source (it proves equivalence, not that the fused path is taken), and the newest archived Studio run moves the client-decode direction the wrong way (see the harness section).
- Evidence: measured (lune, n = 5 × 3,000): `ArrayHeavy` fused 22.6 µs (22.5–24.0); `array(u8, 600)` general 28.6 (28.5–28.9); 100 × 9-field struct 50.3 (49.2–51.9).

### [미미] `Budget.admit`'s refusal costs 2.4× its admission, from one string per refusal
- Location: `src/transport/Budget.luau:184`
- Evidence: measured, n = 9 × 10⁶, spread ±5%: admitted 80 ns [76–98], refused 191 ns [189–198], 1 distinct reason, +0 KB. `rate` is fixed per channel, so the string could be built once per record.

### [미미] The free list is never trimmed
- Location: `src/transport/Inbound.luau:259, :509-515, :585-593`
- Problem: the pool grows to the peak number of concurrent walks and stays there. Reaching a high peak needs a yielding non-query handler, so a peer cannot drive it alone.
- Evidence: inferred; lune has no `collectgarbage("collect")`, so the retained-KB probe was inconclusive.

### [미미] Per-refusal string concatenation in the instance reader
- Location: `src/codec/Serdes.luau:2214` (`"instance is not a " .. class`), `:2230` (`"instance is not inside " .. root.Name`)
- Problem: both are constants per schema, built on every refusal. Not a distinct string per packet; time only. Build once at closure time.
- Evidence: inferred.

## Test Suite (`tests/`)

Audited for the first time. Method: `git diff e8d9589..7737e09 -- tests` read line by line for
weakened assertions; 40 guard mutations in a private copy, each test run over the mutated source;
every `UNCOVERED` entry attempted as a real `_ok` case; all eighteen runtimes required in one process in
runner order and in reverse.

**No test was weakened evasively.** Every removed or changed assertion since `e8d9589` traces to a
behaviour change in the fix commit; the one assertion removal (`query_runtime:865-895`, the parked
third answer that 7df2228 made unreachable) says so honestly. No harness floor moved. Cross-file
state leakage: none — all eighteen files pass with identical counts in one process in both orders.
**Of 40 mutations, 36 fail as claimed**; the exceptions are below.

### [중대] The `select`-audience hole case passes with the `pairs` walk reverted to `#`-indexing
- Category: Tests-nothing
- Location: `tests/transport_runtime.luau:2178-2218` (comment at 2178: "The walk is `pairs` now, which a hole cannot fool")
- Problem: with `Recipients.luau:337` changed to `for index = 1, #chosen do`, all 246 assertions pass. `{ alice, nil :: any, bob }` built as a constructor gives `#` = 3 under lune, the nil is dropped by the `has`/kind filter, and the count is 2 either way. The assertion pins the filter, not the walk it describes; a hole where `#` returns 1 (`t[1] = alice; t[3] = bob` by assignment) is the case that would separate them and it is not written.
- Impact: the M4 경고 the section names (`Outbound:173: table index is nil`) is prevented today by two guards covering for each other — §9's `maxBytes` shape. If the filter is ever relaxed, the `pairs` guard is the only one left and nothing tests it.
- Evidence: measured (`OK 246 assertions` with the guard reverted).

### [경고] `Buffer.span` can be deleted and the transport-level fuzzer stays green
- Category: Fuzzer
- Location: `tests/fuzz_runtime.luau:12-26` (the four invariants), `:466-532`, `:803-838`
- Problem: with `Buffer.luau:937` (`if offset + length > incomingLimit`) disabled, `fuzz_runtime` reports `OK 40 assertions` over 14,000 rounds and `hostile_runtime` `OK 192`; only `serdes_runtime`'s bare-buffer fuzz sees it. Under `Batch.read` a buffer never ends mid-struct (length and fixed size are pre-checked), so the unbounded fused reader silently reads the *next packet's* bytes; the values are range-checked and nothing "vanishes", so none of the four invariants can see a cross-packet read.
- Impact: the G5 guard on the read side of the hot path has one pin, in a file with no harness and no failure-path floor. A fifth invariant — "the packet consumed exactly its declared length" — would make the transport fuzz see it.
- Evidence: measured.

### [경고] The fuzzer's corpus has no union, quantised, u53, constrained-string or vector-component shape, no server-side `RESYNC`, and still never mutates the sidecar's contents
- Category: Fuzzer
- Location: `tests/fuzz_runtime.luau:70-110` (corpus), `:313-442` (mutations), `:389-411` (sidecar: count only)
- Problem: two G4 raises fixed in M4 phase 8 — a union tag past the last branch (`Serdes.luau:1799`) and an optional map key (`:1976`) — are invisible to both fuzz runs: deleting either guard leaves `fuzz_runtime` green. Each is pinned by exactly one hand-written `serdes_runtime` case. The gap `hostile_runtime:419` names as the reason the first sidecar raise was found by review rather than by the fuzzer is still open. The server corpus writes hellos and requests but never `writeResync`.
- Impact: the fuzzer's claim "the ones nobody thought of" covers the M3 packet kinds; every M4 type and control kind is covered only by the attacks somebody thought of.
- Evidence: measured (mutations at `Serdes.luau:1799-1802` and `:1976-1979` → `OK 40 assertions`).

### [경고] Harness floors on the four M4 files and on `fuzz_runtime` are met by tagging lifecycle, no-op and self-check sections as failure-path
- Category: Harness
- Location: `tests/replication_runtime.luau:37, :415, :691, :721, :762, :791`; `tests/baseline_runtime.luau:28, :90`; `tests/store_runtime.luau:39, :82, :185, :276, :287`; `tests/delta_runtime.luau:34, :295, :417, :551`; `tests/fuzz_runtime.luau:42, :555-557`; `tests/hostile_runtime.luau:307` (`check("without looping", true)`, a tautology counted as a refusal)
- Problem: the harness (`harness.luau:22-40`) says per-section tagging is what stops the ratio being gamed by relabelling, but nothing constrains what a section may be tagged. Re-tagged by reading, counting only refusals, bounds, hostile input and failure isolation as failure-path:

  | file | tagged share | floor | honest share | what is tagged failure-path |
  |---|---|---|---|---|
  | `replication_runtime` | 31/76 = 41% | 0.30 | ~13% | audience-leaving lifecycle, "a tick at rest sends nothing" |
  | `baseline_runtime` | 36/65 = 55% | 0.50 | ~23% | `drop`/`desync`/`forget` lifecycle |
  | `store_runtime` | 14/38 = 37% | 0.25 | 0% | "a subject not there reads nil", "an unchanged tick sends nothing" |
  | `delta_runtime` | 31/170 = 18% | 0.10 | ~2% | removal packets, "an equal union writes nothing" |
  | `fuzz_runtime` | 36/40 = 90% | 0.90 | 68% | nine `check("X was exercised", …)` self-checks |

  `fuzz_runtime` would fail its own floor without the nine "was exercised" lines.
- Impact: PLAN-M4 acceptance 11 is neither true nor enforced, and the instrument §9 relies on to notice a suite drifting to the happy path cannot notice this kind of drift.
- Evidence: measured (assertion counts per tagged region by script; re-tagging by reading each section).

### [경고] Every `UNCOVERED` reason in `tools/exports` is false: all seven types annotate cleanly, with annotations that really check
- Category: Missing-ok-half
- Location: `tests/types_ok.luau` (where the annotations belong); the list at `tools/exports.luau:74-88`
- Problem: a scratch `_ok` file with `local _r: t.Ranged<number> = t.u8`, `local _c: t.Classed = t.instance`, `local _e: t.Encoding = "u8"`, `local _k: t.Kind = "number"`, `t.StructPayload<…>`, `t.EnumPayload<…>`, `t.UnionPayload<…>` analyses with zero diagnostics, and a negative control with a wrong value in each of the five non-trivial positions produces 5/5 and 3/3 `TypeError`s — so the coverage would be real, not decorative. "Never written by hand" describes a habit, not an inability, which is the reason the list requires. Found independently by the tests, tools and types auditors; `tools/exports` then fails with seven "covered and still listed as a known gap" lines, which is the checker working.
- Evidence: measured.

### [경고] Two M4 fixes are pinned only by files with no failure-path floor, and the union bit-fork mutation is caught by a require-time self-check rather than a test
- Category: Coverage-gap
- Location: `tests/transport_runtime.luau:1937-1997` (D-5 ceiling section: no nested-scope schema, green with `Ir.luau:987` deleted), `tests/delta_runtime.luau:528-585` (union section asserts equality only, passes under a summed layout); `Ir.luau:797` (self-check raises at require time before any assertion runs)
- Evidence: measured (mutations 7 and 12 in the auditor's table).

### [경고] No end-to-end test that a departed player's baselines stay gone through the real tick
- Category: Coverage-gap
- Location: `tests/replication_runtime.luau:415-469` (audience leaving is tested; `forget` plus a stale `select` list or a shrunk roster is not); `tests/baseline_runtime.luau:145-146` asserts recreation as correct (right for a rejoin)
- Problem: `Baseline.forget` has no guard against `keep` recreating the entry; the M4 finding is prevented upstream for `select` only (see the security finding above) and no test runs `forget(alice)` against the real `Tick` and asserts `held(alice) == 0` on the next frame.
- Evidence: measured (no guard) and inferred (gap).

### [경고] `roblox_runtime` skips its only positive `t.player` and `owner(player)` cases silently when no player is present
- Category: Mechanics
- Location: `tests/roblox_runtime.luau:389-396, :477-481` (`if #players > 0`)
- Problem: in a server-only Play there are no players, the file prints `OK roblox_runtime`, and the one runtime assertion that `t.player` accepts a real `Player` has not run. A probe that did not run and says OK is the opposite of §9's "a probe that finds nothing is written down".
- Evidence: inferred (by reading; Studio not run in this audit).

### [경고] The `hostile_runtime` direction section aborts the file with a Luau error under its own mutation
- Category: Mechanics
- Location: `tests/hostile_runtime.luau:781` (`reports[1].reason` with `#reports == 0`); the same shape at `:300, :329, :389, :438, :566, :620, :679, :735`
- Problem: with the direction stage disabled, three assertions fail and then the test raises `attempt to index nil with 'reason'`, so the replication-direction section at 1174-1225 never executes. The regression is caught by the file crashing rather than by the assertions written for it, and a §9 "break the guard, watch the test fail" run reads as one failure instead of the true count.
- Evidence: measured.

### [경고] Nothing in `tests/` exercises `Driver` or `Link.roblox`, and a table in the sidecar is asserted nowhere in Studio
- Category: Coverage-gap (Studio-only)
- Location: `tests/roblox_runtime.luau` (no section for the real `RemoteEvent`/unreliable path, the 908 limit, `PostSimulation` ordering, install at startup, `Recipients.roblox().has`/`within`/`nearby` geometry, `Context.acquire` on a real `Player`, replication to a real `Player` with a character-driven `nearby` audience); `hostile_runtime` sends a number and a string in the sidecar, never `{}` or a table answering `:IsA` — the exact shape of the old double
- Evidence: inferred (`Driver`/`Link.roblox` appear in `tests/` only in comments).

### [미미] Smaller suite defects
- `tests/hostile_runtime.luau:433` "a number in the sidecar does not raise" passes with `isInstance` removed — satisfied by the read-phase guard, not by the guard the block describes (the block still fails on four other assertions). measured.
- `tests/replication_runtime.luau:558-563` describes a provocation (`pendingPerBatch = 1`, `Config.reset()`) the section above no longer uses since 7df2228; the strikethrough at 488-492 says so and this paragraph contradicts it. measured.
- `tests/serdes_runtime.luau:846-870` is the one lune assertion whose verdict depends on the host (`hostileCost < honestCost * 20 + 0.05` over `os.clock()`); §9's counting half — `table.create` never called from a claim — is unwritten. inferred.
- `tests/types_reject.luau:5` "the count on line 1" (the header is line 2); `tests/example_runtime.luau:8` names `tests/messages.luau`. measured.
- 2ea8c90's regression test passes over the pre-fix source under lune (`246 assertions`), because the pre-fix branch was `type(who) == "table"` under lune and the defect existed only in the Roblox branch; the commit message records the confirmation used a different mutation. measured.

## Benchmark Harness (`bench/`)

Audited for the first time. The instruments are in better shape than the record: `bench/decode`'s
pre-fix baseline reproduced to 0.03% and `bench/tick`'s to 3–5% when run against the pre-fix trees;
`bench/envelope`'s hand-written framing still matches the real `Batch` byte for byte (602 / 9 / 626);
the vendored Blink and Zap codegen regenerates identically from the pinned `_refsrc/`; the vendored
ByteNet is unmodified `v0.4.3`; every figure in the M2, M3, M4-phase-0 and M4-phase-7 sections
reconciles with its named run; and `PLAN-M3.md` disagrees with nothing. What is broken is
`RESULTS.md` and the provenance of the Studio numbers.

### [중대] The newest committed run puts acceptance criterion 5 at 1.15x, and no document mentions it
- Category: Reproducibility / Doc-mismatch
- Location: `bench/runs/2026-09-06-m4p8.json` (committed by `7737e09`); `bench/RESULTS.md:692` ("**missed on `ArrayHeavy`** … 1.56x at M4 phase 7 (85 against 133) … the framerate did not move at all"), `:97-102`; `docs/milestone/PLAN-M4.md:195, :628-630`
- Problem: reconstructed `ArrayHeavy` Up p50 [p0..p100] across every run: seven runs at 84–86 with ±2 FPS internal spread, then **115 [114..116]** in m4p8 against Blink 132. The control group moved −0.8% (blink), +0.9% (zap), −1.7% (bytenet), −3.3% (raw) — §9's control-group question, asked and answered. The cell is genuine: `sent == received == 230,000`, `correct = true`, `wireCalls = 1150` (115 × 10 s), `wireBytes = 230,000 × 601.005` exactly, `smoke = false`. `RESULTS.md` never cites the file.
- Impact: the milestone's headline open criterion is met on a committed artifact and the document says it is missed by 1.56x. Anyone quoting `RESULTS.md` quotes a number the folder next to it refutes.
- Evidence: measured (`report.luau` regenerated over all eleven runs).

### [중대] The same run reverses "netweave decodes the array payload faster than any of them", and the decode direction is in no table
- Category: Reproducibility / Coverage-gap
- Location: `bench/RESULTS.md:94-102`; `bench/report.luau:77-88` (framerate table prints `up` only)
- Problem: `ArrayHeavy` m4p7 → m4p8: Up 85 → 115 (+35%); Down (client decodes) **79 → 55 (−30%)**, netweave last; FireAll 79 → 57 (−28%). Control moves on the Down axis are wider (−11.5%..+9.5%), so the −30% is suggestive rather than settled on one pair — but it is 2.6× the largest control move, it repeats on FireAll, and it points the opposite way to `PLAN-M4:722-731`'s "`fusedStructReader` … 1.5x". The flag cells barely move, so the signal is `ArrayHeavy`-specific. `report.luau` tables only `up`, so a 30% move on the direction a server pays per client per packet is invisible unless someone opens the JSON — the third occurrence of the pattern §9 names, and this time nobody has looked.
- Evidence: measured.

### [중대] `RESULTS.md`'s report-generated tables are the M1 run under an M3 header, and its acceptance table contradicts its own M2 section
- Category: Doc-mismatch / Reproducibility
- Location: `bench/RESULTS.md:7` (header: "2026-09-05 — M3 matrices"), `:82-86`, `:630-636`, `:652-668`, `:693` vs `:255`, `:39-43`
- Problem: `lune run bench/report bench/runs/2026-09-04.json` — the **M1** run — reproduces lines 652–668 byte-identically and lines 82–86 and 630–636 exactly. So `:693` grades criterion 6 "met against ByteNet, 389 against 520" on M1 cells while `:255` in the same file says criterion 6 "has gone from met to missed on `ArrayHeavy`, 9309.2 B against 2273.3 B"; neither strikes the other. `:39-43` states "every allocation median is printed with the range of its surviving windows and the count" and the headline allocation table prints no range, because the M1 run predates the fields. Six runs are newer than the tables.
- Evidence: measured.

### [위험] The phase-7/8 Studio numbers have no committed script — including the ones carrying "the whole gap is in the send loop"
- Category: Reproducibility
- Location: `bench/profile.luau:115-116` (`STUDIO_NOW = 29314`, `STUDIO_BEFORE = 38940`, hard-coded), `bench/RESULTS.md:480-486` (Studio ns ladder), `:507-513, :526-531` (frame-partition tables — console output of `Config.FRAME_PROBE`, whose own docstring at `frame.luau:36-40` says "these numbers do not go into `RESULTS.md`"), `:559-564` (arity ladder, no script), `:546-552` (the re-run's own caution that the tree "is the same instrument on a pre-phase-8 tree rather than a pinned commit")
- Problem: CLAUDE.md §5 rule 1. "The whole gap is in the send loop" (`:515`) and "1.34x, and 1.96 ms out of an 11.6 ms frame" (`:568`) are the two claims the M4 optimisation narrative rests on, and neither can be re-derived from anything in the repository. The run documents also record no commit, so even archived runs cannot be attributed to a tree.
- Evidence: measured (`grep STUDIO_`; `lune run bench/profile` produces the lune column only; no `runs/` entry holds probe output); inferred for what produced them (an ad-hoc Studio `execute_luau`).

### [경고] Every probe's `BEFORE` baseline tells the reader to reproduce it in a way that cannot work
- Location: `bench/profile.luau:119-122`, `bench/decode.luau:66-75`, `bench/tick.luau:64-79` ("Check out the parent of the phase N commit and run this")
- Problem: each file was introduced by the very commit whose parent it names, so it is absent there. Copying the probe onto the older tree: decode reproduces (32,740 vs 32,731), tick reproduces (uniformly 3–5% high, the session offset); profile does not run at all on either tree (`Buffer.claim` is nil before phase 7), so `BEFORE = 23992` is reproducible by no committed version — a stand-in timing `codec.write` the same way gave 24,195 / 24,608 / 24,210, so the number is right and the route to it is not.
- Evidence: measured.

### [경고] `bench/` is not type-checked by anything, and it hides a `type function errored at runtime`
- Category: Type / Coverage-gap
- Location: `analyze.luau:24` (`ROOTS = { "src", "tests" }`); `bench/check.luau:24, :39` (`luau.compile` only); `bench/tick.luau:168-173` (`audience = audience :: any` to `nw.replicate`)
- Problem: `luau-lsp analyze` with the project's flags over the 21 non-vendor bench files gives 57 diagnostics; most are `Unknown require` artifacts, but `bench/tick.luau(168,25): 'OutboundScope' type function errored at runtime: type.readproperty: expected self to be either a table, but got any instead` (twice) is the silent-`any` class Q5 exists for, in the file that prices replication; plus `{unknown}` from `table.create` against declared arrays (`Payloads.luau:81`, `tick.luau:262`), `Unknown type 'Modes.SchemaName'` (`server/init.server.luau:205`), `Expected 'Player', got 'nil'` (`Modes/raw.luau:125`), and two deprecated `collectgarbage` calls.
- Evidence: measured.

### [경고] `report.luau` degrades silently when a run document's field names drift — the incident the driver already survived once
- Location: `bench/report.luau:33-34, :71, :113-123, :135`; `bench/src/client/init.client.luau:279-289` (documents the previous occurrence)
- Problem: `cell()` returns `any` and every field is read by name; a missing field prints `—` or drops the spread and exits 0. Renaming `encodeBytesPerPacket` and `up.decodeBytesLow` in a scratch copy: every encode cell `—`, every decode cell a bare median, exit 0. A degraded table looks like an old one.
- Evidence: measured.

### [경고] The framerate column has no spread and no sample count anywhere — and it is the column criterion 5 is judged on
- Location: `bench/report.luau:85` (p50 only); `bench/src/shared/Metrics.luau:21-27` (`Summary` carries p0..p100, no `n`)
- Problem: after the M3 incident the allocation column gained a range and a survivor count; the framerate column did not. The p0/p100 are in the JSON and are tight (netweave ±1–2 FPS on every run), so the instrument is better than the report. `RESULTS.md` quotes the spread once, by hand.
- Evidence: measured.

### [경고] Two of three directions have no drop rate, and correctness is one packet per cell that `report.luau` never prints
- Location: `bench/src/client/init.client.luau:326` (`sent = 0`), `:226-232`; `bench/src/server/init.server.luau:170-177, :205-243`; `bench/report.luau` (no reference to `correct`)
- Problem: CLAUDE.md §5 — "always report correctness and drop rate alongside throughput". `runDown` returns `sent = 0` unconditionally, so Down and FireAll have no denominator in any artifact; correctness is `if not cell.validated` — one packet per (cell, direction) out of ~170,000, and "45 of 45" at `RESULTS.md:12` reads as if the traffic were validated.
- Evidence: measured (all eight full runs: `down.sent == 0`, `fireAll.sent == 0`).

### [경고] `bench/envelope.luau` re-implements the framing rather than calling `Batch`, and its docstring says otherwise
- Location: `bench/envelope.luau:118-137, :141-202, :1-15`
- Problem: the docstring says the envelope is "asserted against the same channel declarations the adapter uses, not a copy of them"; the file never requires `Batch`, hand-writes the frame, and re-declares the channels with a different rate. The real writer has since grown an instance-count reservation and a two-byte widening path the model lacks. Fidelity today (602 / 9 / 626 both ways) is coincidence — `codec.instances == 0` for both schemas — not construction; it would keep passing after a framing change.
- Evidence: measured.

### [경고] Smaller fairness and record defects
- No warm-up for `Down`/`FireAll` (`init.client.luau:237-246` applies `WARMUP_SECONDS` to Up only; `runDown` opens its window immediately); mode order is a hash iteration (`:391`) while `Modes.availableNames` is deterministic and unused by the client. inferred magnitude, bounded.
- The surviving-window range quoted for phase 0 (`RESULTS.md:362` "276–385 of 400", `README.md:86` "280–373") is wrong: the true `ArrayHeavy` encode range is **196–373**; 385 is a FlagIdiomatic cell, and `raw` swung 302 → 196 between the two runs. measured.
- The lune probes drift ~5% between sessions on the same machine (four `bench/profile` runs: 13,315–13,601 vs the recorded 12,711; `bench/decode` +4.4%; `bench/tick` +4.2% — uniform across three probes and two trees, so the session, not the code), while `PLAN-M4:792` rejects a design on a 6.7% single reading and the `put` rung moved 20.8% between two runs. measured.
- `Alloc`'s stated filter ("every window the collector visited is discarded", `RESULTS.md:402`, `server/init.server.luau:129`) is not the implemented one (`delta <= 0` only, `Alloc.luau:127-129`); a collection that freed less than the window allocated is kept, under-counted. The "lower bound" reading is the true one. measured.
- ByteNet's provenance is unrecorded: `Modes/bytenet.luau:7-9` says the tag is "recorded in `_refsrc/README.md`", which records `fbdb156` on `master`, not the tag; `README.md:168` says nothing under `vendor/` is hand-written, and `generate.luau` regenerates only Blink and Zap. The tree is correct (`diff -r` against `git archive v0.4.3` is identical; `v0.4.3 = d826282`), the record is not. measured.

### [미미] Six smaller defects
- `bench/RESULTS.md:517` "6.27 ms over 200 packets is **31.4 ns** per packet" — 31.35 **µs**; off by 1000× in the sentence that concludes "the framing costs the difference".
- `bench/envelope.luau:1-2` has `--!strict` but no `--!optimize 2`, the only bench module missing it (CLAUDE.md §4).
- `bench/README.md:45` "Twelve cells (four modes x three schemas)" — fifteen; `:47` "about 12 minutes" vs `Config.luau:21` "a quarter of an hour" vs `:45` "fifteen minutes".
- `Alloc.measure` (`Alloc.luau:108-143`) has no caller; `Config.ALLOC_ITERATIONS`/`ALLOC_REPEATS` exist only for it; `heapBytes` is duplicated at `Alloc.luau:72-74` and `server/init.server.luau:91-93`.
- Moonwave coverage is one function (`Alloc.frames`) across the folder; CLAUDE.md §4 names `bench/` explicitly.
- `RESULTS.md:438` labels the `inline` rung "what Blink and Zap generate"; Zap's output is that shape, Blink's wraps every one of the 600 writes in a `typeof` check.

## Checkers and Configuration (`tools/`, `analyze.luau`, root)

Audited for the first time, by mutation in a private copy. All three checkers exist, run, exit non-zero
on failure, and catch the drift they were written for: 15 of 15 "obvious" mutations caught, including
reconstructing the three M4 originals against the `15f74f2` tree (no `_ok` file wrote `nw.Views`,
`nw.Settings` or `t.PayloadOf`; the current `exports.luau` names all three). `UNCOVERED` fails in both
directions as claimed. The worked-example equality is byte-exact. `.luaurc` is load-bearing and
correctly placed. `.gitignore`'s negation works. `default.project.json` builds the package shape §2
requires; `test.project.json` emits the runner as a `Script` with `RunContext = Server`. `stylua`'s
`syntax = "Luau"` is load-bearing. `globalTypes.d.luau` is byte-identical to luau-lsp `main` today. What
follows is what the checkers do not catch.

### [위험] A `--!nonstrict` or `--!nocheck` header anywhere under `src/` silently disables type checking, and nothing notices
- Category: Checker-gap
- Location: `analyze.luau:24` (`ROOTS`), `.luaurc:1-3`; CLAUDE.md §4 states the requirement
- Problem: `.luaurc` sets `languageMode: "strict"`, but a file-level hot comment wins over it (`mode = sourceModule.mode.value_or(config.mode)` in `Analysis/src/Frontend.cpp`, luau 0.737; no prose page documents this). Changing line 1 of `src/codec/Buffer.luau` to `--!nonstrict` and running the full documented check set: `analyze` → `OK 52 files clean`, `selene` 0 errors, `stylua --check` exit 0, `tools/messages` OK, `tools/exports` OK. A new file with the header and a function returning `"str"` as `number` gave `OK 53 files clean`.
- Impact: the Q5 class in one line of diff — a change that removes every diagnostic from a module while every gate stays green, and the cheapest way to "fix" a stubborn analyzer complaint. Fix: two lines in `analyze.luau`'s `collect` — refuse any file under `src/` whose first non-empty line is not `--!strict`.
- Evidence: measured.

### [위험] `analyze` prints a green "N files clean" whenever luau-lsp fails to run
- Category: Checker-bug
- Location: `analyze.luau:91-102` (counts lines matching `^%S+%(%d+,%d+%):`; `result.code` never read), `:121-131`
- Problem: adding `--totally-unknown-option` to the argument list produced a usage banner on stderr and the `_ok` half printed `OK 52 files clean`; the run went red only because the three `_reject` files then reported 0 — the must-be-clean half is protected by accident. luau-lsp's exit code is 0 for lint-only files (measured; `AnalyzeCli.cpp` @1.69.0), so the line-counting is correct and must stay; the missing condition is `result.code ~= 0 and diagnostics == 0`. `--no-strict-dm-types` is marked deprecated in luau-lsp's own source at 1.69.0.
- Evidence: measured.

### [위험] `-- netweave:expect N` counts diagnostics, not guarantees — a case can be swapped for junk and the run stays green
- Category: Checker-gap
- Location: `analyze.luau:70-73, :133-145`; `tests/api_reject.luau:2`
- Problem: deleting case 12 of `api_reject` — the negative control for G3 (`broadcast` absent off a non-everyone audience) — and adding `local _junk: number = "not a number"` reports `OK tests/api_reject.luau rejected 24 as declared`. §9's own incident ("the two covered for each other") generalised to every case in every reject file. The diagnostics carry line numbers; declaring the expected lines is the same instrument at one more digit.
- Evidence: measured.

### [위험] `tools/exports.luau` accepts a string literal as coverage — the hole it was patched to close for comments
- Category: Checker-bug
- Location: `tools/exports.luau:117-144` (`stripComments`), `:170-174`
- Problem: the checker strips comments from `_ok` files (its header explains why) but not string literals. Removing the `t.Ranged` entry and adding a file containing `local _note = "t.Ranged is what t.u8 returns"` reports `OK exports — 20 public types written in an _ok file, 6 known gaps`, with `analyze` green. A bare unused alias (`type _NeverUsed = nw.Views<{}>`) also counts. All three M4 failure modes *remove* diagnostics; a string satisfies the checker and removes nothing.
- Evidence: measured. Fix: skip string bodies in the same character walk, or require an annotation position.

### [경고] The repair-marker list is satisfiable by ordinary English
- Location: `tools/messages.luau:52-79` (`call `, `instead`, `Use `, `Remove`, `Attach`, `Declare`), header `:22-25`
- Problem: two replacement messages that name the rule and offer no fix passed unchanged, e.g. "a timeout is required on this class; the declaration was rejected instead of being accepted, and that is all this message is going to tell you today." Both clear the 80-character floor, so nothing else fires; the 75-character version was caught by the length rule, not the marker rule. The netweave spellings cannot be satisfied vacuously; the two generic verbs are the whole problem.
- Evidence: measured.

### [경고] The checker's stated rationale covers `src/types/init.luau`'s four `export type function`s, which it does not scan, and all six of their messages fail both of its rules
- Location: `tools/messages.luau:204` (`fs.readDir("src/api")`); `src/types/init.luau:226, :232, :277, :283, :294, :308`
- Problem: the header's argument is specifically about type-function errors printing verbatim at the call site; `PayloadOf`, `StructPayload`, `UnionPayload`, `EnumPayload` do exactly that and are outside the scan. `"a struct field is not a netweave type"` (37 chars, no marker, the key available as `key:value()` and not printed) ×2, the union pair, and the two "needs at least one" all fail. Over all of `src/`, 41 non-`api` calls, 38 would fail; the `Serdes` runtime-encode group is a different case and not proposed for the sweep.
- Evidence: measured.

### [경고] `findLuauLsp` sorts version directories as strings and ignores the `rokit.toml` pin
- Location: `analyze.luau:30-45` (`table.sort(versions)`, `versions[#versions]`)
- Problem: `{"1.69.0","1.7.0"}` sorts to pick `1.7.0`, the older build; the pin `rokit.toml` calls load-bearing is never read. Correct today by accident (one version installed); the multi-version condition is live for stylua, selene and rojo on this machine and they resolve correctly because the rokit shim honours the pin. `process.exec("luau-lsp", …)` resolves through the shim from lune (measured `1.69.0`), so the scan can go.
- Evidence: measured.

### [경고] `tools/messages.luau` extraction has three ways to lose a call silently
- Location: `tools/messages.luau:127-141` (paren balance), `:204` (non-recursive, `.luau` only), `:190` (first `local <name> =` in file), `:251` (`checked < 60`)
- Problem: an unbalanced parenthesis inside a message string makes the depth loop consume following lines (73 → 74 with two calls added, the second never checked); `src/api/sub/Extra.luau` and `src/api/Extra.lua` are not scanned; the floor at 60 is 13 below the current count and cannot catch any of these. Latent: a second `local advice =` in a module would be scored against the first.
- Evidence: measured.

### [경고] selene *does* support block-scoped lint allows, so `netweave.toml`'s hand-kept global list is not the narrowest option
- Category: Config / Doc-mismatch
- Location: `netweave.toml:4-5, :65-66`; `CLAUDE.md:211`
- Problem: both justify declaring `types`, `forbid`, `payloadOf`, `branded` and six others as globals with "selene has no scoped lint filters". Selene's docs: `-- selene: allow(lint_name)` applies to the block it is near; `--#` is the file-global form. Measured: with the netweave globals removed, `Trust.luau` reports 11 errors; one `-- selene: allow(undefined_variable)` before `export type function Trusted` drops it to 10 and a typo'd global elsewhere in the file is still reported. `netweave.toml:60-64` records the list drifting once already (`branded` undeclared from M4 phase 6 to phase 8). The TOML std format is officially deprecated (`selene upgrade-std`).
- Evidence: measured.

### [경고] The checkers, `analyze.luau`, `bench/` and `spike/` are the Luau nothing checks
- Location: `analyze.luau:24`, `.styluaignore:4` (`tools/`), `CLAUDE.md:236` (`selene src tests`), `bench/check.luau:24`
- Problem: `tools/*.luau` and `analyze.luau` are neither type-checked, linted nor (for `tools/`) formatted; `bench/` and `spike/` are formatted only. Running luau-lsp over the checkers reports three genuine strict-mode diagnostics in `tools/exports.luau:158, :164` (`string.find`'s second return unnarrowed). There is no tracked editor configuration, so `--definitions`, `--flag:LuauSolverV2=true` and `--no-strict-dm-types` — CLI-only — have no editor equivalent; the guarantees that exist only under the new solver are absent in an unconfigured editor.
- Evidence: measured.

### [미미] Assorted
- `tools/messages.luau:6` tells the reader to run `lune run tests/messages`; `prose()` at `:155-167` counts backtick-quoted fragments twice against the 80-character floor (`Channel.luau:330` clears it at 86 only because `timeout` is counted twice); the 60-line cap at `:328/:338` applies to the first worked example only (the replication example grown to 100 lines passed, visibly).
- `tools/exports.luau:170` reads `tests/` non-recursively while `analyze.luau:47-62` recurses (fails safe); an `export type` inside a comment in a surface module is demanded as real (fails safe); an `UNCOVERED` entry with `""` as its reason passes; `:77` says `t.Encoding` "names the eight storages" — ten.
- `tools/README.md` documents `globalTypes.d.luau` only; its download URL works but is not the one luau-lsp recommends (a CDN, which serves the `.None` security-context variant — not necessarily the same file).
- `LuauSolverV2` is still an opt-in FFlag in open-source Luau 0.737 (`isAnalysisFlagExperimental`), so `--flag:LuauSolverV2=true` remains required; the general-release announcement commit faf2d4c cites is a Studio announcement, and no non-devforum official page was found.

## Suggested Types

Re-assessed against what landed since the previous list. **Added as listed:** `t.union`, `t.quantized`,
`t.u53`/`t.i53`, `t.string(min, max, { utf8, pattern })`, `t.vector3(component)`, `t.instance(class,
{ descendantOf })`, `t.player`, the map-key restriction, integrality and f32 snapping, the `PayloadOf`
instantiation, `CheckedSettings` over optionals, component-wise brands. **Added differently:** `nw.Views`
— canaried, not changed. **Still open from the previous list:** thread `Context.Ctx` into the views
(measured working in a private copy this pass: six lines in `View.luau`, `player: Player`, suite
unchanged); `read` modifiers on `Type<T>`/`Descriptor` with clone-then-freeze of `fields` (now
`branches` too); a private brand on descriptors for `isType`/`requireType`/`validate`; freeze the
channel record at seal; refuse unknown spec keys per class; bind `Policy<T>` to the projected payload;
a real `Channel` record at the transport boundary and typed `Tick.Config`/`Baseline`/`Store`; `Stage`
shared below `Observer`; `{ [Encoding]: … }` tables; `Framing`, exported `Flags`/`Writer`/`Reader`;
`Sidecar = { unknown }`, `Sender`, `Destination`.

### Should add (new this pass)

| Type or change | Closes | Cost |
|---|---|---|
| `MapPayload(key, value)` type function for `t.map`, reading both `__payload`s the way `t.struct` does; `t.map(t.u16, Entity)` written into `types_ok` | struct/enum/union map payloads refused; `t.optional(struct)` unbound outside a spec | one type function, one `_ok` line |
| `Ranged<T>`/`Text`/`Componented<T>`/`Classed` as `Type<T> & ((…) -> Type<T>)`, with `PayloadOf`/`StructPayload`/`UnionPayload` accepting `is("intersection")` | `__call` arguments unchecked | measured working for arguments; the three type functions and `Trust`/`Channel`/`View`'s `readproperty` sites must look through an intersection |
| A pattern scanner in `refineText` (refuse `%b`, `%f`, `%<digit>`, unbalanced `(`/`[`, trailing `%`; refuse more than one unbounded item or cap `max` for patterned strings), or a character-class-only `{ charset = … }` constraint that is linear by construction | reader raise on wire data; polynomial cost | definition-time only |
| `t.unitVector3` requiring a fractional component whose range covers `[-1, 1]` | every direction refused | one `check()` |
| `whole` (and any future reader-side attribute) in `Protocol.ATTRIBUTES` | `u53` vs `f64` identical hash | one entry, one protocol test |
| Re-export `Policy<T>`, `Check<T>`, `Snapshot`, `Described`, `Rules`, `Limits`, `Audience<S>`, `Observer` from `nw`, and teach `tools/exports` to demand a type for every public value family, not only coverage for every exported type | public values with no nameable type | zero runtime cost |
| `Tick.Config = { outbound: Outbound.Outbound, baselines: Baseline.Baseline, roster: Recipients.Roster, channels: () -> { ReplicatedChannel } }`; `Baseline` with `value: {}` (non-nil) | five wrong-shape calls analyzing clean; `keep(nil)` drift | none |
| `Delta.apply: (base) -> (value: {}?, reason: string?)` with the removal/refusal rule in the moonwave block | contract in a `--[[ ]]` | none |
| `Roster.has` required | the degraded kind test | the one `lenient` test section |
| A key-kind check before `sortedKeys` in `struct`/`enum`/`union`, and numeric-type checks in `t.array` | VM messages; number keys | trivial |
| `--[=[ ]=]` on the ten exports at `netweave.luau:360-369`, with the `Views` caution on the alias itself | nowhere a game reads it | prose |

### Nice to have
Unchanged from the previous report (`t.literal`, `t.set`, `t.optional(x, default)`, explicit enum ids,
compact `cframe`, per-element array deltas via `t.map`, per-kind `Node` shapes, `Codec<T>`, `Store<S, V>`
with its own `_ok`/`_reject` pair), plus a typed run document for `bench/report.luau` so a renamed
field is a diagnostic rather than a `—`.

### Do not add
The previous reasoning holds for `t.refine`, `t.id`, `t.timestamp`, `t.recursive`, `t.tuple`,
`t.buffer(n)`, `nw.untrust`/`nw.trust`, a discriminated `Verdict` while the record is shared, a wrapper
`Trusted<T>`, a `changed` signal on `Store`. Two additions: do not add analysis-time bound checks via
type functions for numeric literals — the solver widens literals so `t.u8(10, 0)` cannot be seen there;
and do not add a per-destination packet ceiling in `Outbound.flush` typed into `Config` — the
client-side ceiling was the livelock, and the server-side bound belongs to `Tick`.

## What the auditors would block a release on

Each auditor ranked three. Consolidated and ranked across scopes:

1. **The `replicate`-before-`listen` loss** (transport, 중대): the join path loses static subjects for the session and reports the loss as the game's own handler crashing; the fix allocates nothing.
2. **The pattern cost and the malformed-pattern raise** (codec, types): the only new items a client can trigger with no game bug; a one-line classifier in `t.string` plus a docstring sentence.
3. **`t.map` with a struct payload does not compile** (types, 중대): the schema every replicated-entities game writes first has never been in an `_ok` file.
4. **`RESULTS.md` versus `bench/runs/`** (bench, three 중대): the newest committed artifact meets criterion 5 and reverses the decode claim, the report-generated tables are two milestones old, and the phase-7/8 conclusions have no script behind them.
5. **The `--!strict` header, `analyze`'s green-on-failure, `expect N` counting diagnostics, and string literals as coverage** (tools, four 위험): each is one line, and together they are the difference between a checked tree and a tree that looks checked.
6. **The harness floors** (tests): the instrument §9 relies on is met by relabelling; `replication_runtime`'s honest share is ~13%, and the transport fuzzer cannot see the M4 surface.
7. **The declaration surface's type holes** (api): misspelt keys, unbound `Policy<T>`, a hand-built audience that erases a namespace, and G1/G2 switchable by one typed line — all open since M4, with the `CheckedSettings` shape already in the tree.
8. **The tick's unguarded calls into game code and its schema-unaware compare** (replication): a cycle through a non-schema key overflows the stack and stalls every channel; a changing non-schema key returns the 22 ms tick.
9. **The documents a game author copies from** (docs): DESIGN-API §3's `replicate` row, sequence number and shallow `table.clone` escape; §7's "G6 is a compile-time guarantee" with no `Views` caution; WIRE-FORMAT's missing offset-binary statement and six undocumented kinds; and no disposition of the previous 78.

## Null results

Recorded so the next reader can see these were checked, not skipped.

- **Codec.** `maxSize` is an upper bound over 3,000 random schemas including every new kind (6,000 encodes, 0 over) and every patch layout derived from them; 27 static unions byte-exact. `cloneNode` complete against `Node` over 41 nodes of every kind. Fused reader: 964 truncations, 0 raises, 0 short packets accepted. Union: tag past the last branch, non-chosen branch flags, truncated branch, zero-byte branch in a dynamic array — all refused, +0 KB. Quantized, u53/i53, strings (invalid UTF-8, surrogates, overlong), componented vectors: every bound probed refuses as documented; `-0` round-trips. `assert` appears nowhere in `src/codec`.
- **Transport.** Non-LIFO: three and six batches in two orders with a 12-packet batch mid-park, exactly-once, 0 reports. Direction: all seven classes, both endpoints. Hostile call ids 0, 16,384, 2^32−1 answered and released. A protocol-refused peer's `HELLO+RESYNC` clears nothing; its 50 unknown control kinds → 50 `parse` reports, no work. Server `pendingPerBatch` 1,000 → 256 + 744 `budget`; client 1,000 → 1,000. `flush` after a raising send: no retry. `_refsrc` citations in the folder (Blink `Generator/init.luau:413-418, :723-745`, Zap `client.rs:1329`, Warp `Server/init.luau:196-200`) all match. No server-side per-destination bound exists (5,000 subjects → one 30,001 B batch accepted whole); creator-docs documents no `RemoteEvent` size limit, so recorded and not filed.
- **Replication.** Livelock at 256/257/300: converges frame 1, 0 resyncs. RESYNC resends on frames 2/31/61 only, honest mirror intact, tick ms flat (n = 90). Frozen value: deep, untouched subtrees shared, merger folds into a frozen base. `t.union` in a replicated struct end to end. Same-frame ordering: an owed resync honoured in `inbound.tick()` is resent by the tick of the same frame. `bench/tick` reproduces PLAN-M4's numbers with spread. `_refsrc` citations for charm-sync and ReplicaService hold.
- **api.** All 23 `api_reject` cases fire (24 with the union case). `replicate` views correct for every data shape. Every `export type function` in the folder reduces across a require, confirmed by rejection. Laundering routes closed: field rebuild, `table.clone`, array element, map, intent payload, state client value, boolean-typed tag. `CheckedSettings` knows `direction`, `replicate`, `baselinesPerClient`. `Observer`: 2,000 refusals → 3 sink lines, 1 rejection record, 2,000 counted. The folder's receive-path cost is O(1) per packet with no allocation; every optimisation its comments claim was found to fire.
- **types.** Nothing in `types/` runs per packet. Declaration cost: a 200-branch union 0.047 ms, a 1,000-field struct 0.31 ms, `fromSchema` of each under 0.8 ms. `PayloadOf<number>` prints the advice; union payloads narrow on `tag`. faf2d4c's devforum quote is verbatim (2025-11-20).
- **docs.** Every WIRE-FORMAT byte-level claim other than §6 "clamped" and the offset-binary omission dumps as specified, including the tagged-union layout as §5 designed it and the 30-tick resync. Every `~~strikethrough~~` in DESIGN-API and WIRE-FORMAT is true today. Every `RESEARCH §` citation in PLAN-M4 says what is attributed; `_refsrc/README.md` pins match. CLAUDE.md §9's incident numbers (690x, ten of eleven, 1,994 → 3, 19/21/37/86%, 67%, four Studio suites, 2,000 refusals, fourteen lune runs) all verified against PLAN-M3 except 39/40 and "9%". Nine regression tests fail against their pre-fix trees.
- **tests.** No evasive weakening; no cross-file state leakage in either order; the analyzer instruments (`Views` canary 24 → 26, `PayloadOf` 11 → 8, `CheckedSettings`) work exactly as their comments say; every double differs from production only in dimensions the code under test does not read, except the two rigs that omit `has` and use no `select` audience.
- **bench.** All eleven runs regenerate through `report.luau`; every figure in the M2/M3/M4-p0/M4-p7 sections and in PLAN-M3 reconciles; correctness 45/45 in every full run; the vendored codegen regenerates; the suite's resets before the matrix are guarded (with one gap: the adapter does not `Config.reset()` before its own `nw.configure`, so a limit a test left set carries into the matrix — Studio-only to confirm).
- **tools.** The three M4 originals reconstructed; `UNCOVERED` bidirectional; worked-example byte-exact; milestone check both directions; lints counted; `expect` parsing edge cases loud; `analyze` fails hard on a missing definitions file or binary; `.gitignore` negation, package shape, `RunContext`, `syntax = "Luau"`, `globalTypes.d.luau` currency all verified.

## Summary
- 심각: 0
- 중대: 6
- 위험: 6
- 경고: 56
- 미미: 16

Total: 84 new findings, on top of the 51 previous findings that remain open (table above). The six
`중대` split three ways. Two are in the library and were not there before: the `replicate` join path
and the `t.map` type error, both in shapes no test had ever written. One is in the suite: a guard whose
test passes with the guard removed. Three are in the record: the benchmark's newest artifact contradicts
its own document three times over — and the checkers that would have caught the rest have four
one-line holes, each rated 위험. The pattern across all nine scopes is the one §9 already names — a probe that was never
written — with a second one beside it this pass: **a fix recorded in a commit message and nowhere a
reader looks.** Six of the eighteen closures, three overturned plan decisions, and the criterion-5
result all exist only in `git log`.

## Appendix — probes and how to re-run them

The auditors' probes live in the session scratchpad under their prefixes (`api_m41_*`, `codec_m41_*`,
`transport_*`, `repl_*`, `types_*`, `docs_*`, `tests_*`, `bench_*`, `tools_*`) and are not committed;
each finding's Evidence quotes enough of the probe to reconstruct it. Every lune probe was run with cwd =
the snapshot root and `local R = "./snap-7737e09/src/"`; from `spike/` in the repository the prefix is
`"../src/"`. Analyzer probes used exactly the invocation `analyze.luau` uses:

```
luau-lsp analyze --platform=roblox --definitions=tools/globalTypes.d.luau --flag:LuauSolverV2=true --no-strict-dm-types <file>
```

Pre-fix trees were extracted with `git archive <commit>~1 src | tar -x -C <scratch>` and the at-commit
test run over them. Mutations were made only in private copies of the snapshot and each copy was diffed
back to the snapshot afterwards; the repository working tree was clean before and after the audit.

The two compact probes that reproduce the two new library `중대`:

```lua
-- t.map with a struct payload (analyzer; must produce a TypeError today)
--!strict
local nw = require("../src/netweave")
local t = nw.types
local Entity = t.struct({ hp = t.u8 })
local _m = t.map(t.u16, Entity)
```

```lua
-- replicate before listen (lune; the loopback rig from tests/replication_runtime.luau)
-- 1. build server and client Inbound/Outbound/Baseline/Tick over a fake Link, two subjects in the store
-- 2. leave channel.handler = nil on the client; run one server tick and flush; deliver to the client
-- 3. assert: client reports [handler=2] "attempt to call a nil value"; client baseline holds 2; mirror 0
-- 4. attach :listen and drain; assert mirror still 0
-- 5. change subject 1 on the server; run 100 idle frames; assert subject 2 was never delivered
```
