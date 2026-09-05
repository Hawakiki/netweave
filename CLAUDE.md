# netweave — Repository Rules

A Roblox networking library. Runtime Luau schemas, no build step, three layers:
**L1 Codec** (schema → buffer serdes) / **L2 Transport** (batching, channels, budgets) /
**L3 Replication** (delta state, adapter over existing state libraries).

Design rationale lives in `docs/RESEARCH-AND-PLAN.md`. Every non-obvious decision in this
repo should trace back to a section there (`§3.7-D`, `§3.9-X`, …). If a plan or a code
comment asserts something about a competing library, it must cite that section — and that
section must cite a file and line in `_refsrc/`.

---

## 1. Language policy

**English is the repository language.** This is not a stylistic preference; it is so the
library can be published and read by the Roblox community without translation.

| Artifact | Language |
|---|---|
| `CLAUDE.md`, `README.md` | **English** |
| `docs/milestone/PLAN-M*.md` | **English** |
| All Luau source, comments, identifiers, error messages | **English** |
| All TypeScript definitions and JSDoc | **English** |
| Commit messages, PR descriptions | **English** |
| `docs/RESEARCH-AND-PLAN.md` | **Korean** (existing research log — keep as is, keep appending in Korean) |
| Conversation with the user | **Korean** |

Do not mix languages inside one file. A Korean comment in a `.luau` file is a defect.

---

## 2. Layout

```
CLAUDE.md                     this file
default.project.json          the library as a package: rojo build -o netweave.rbxm
test.project.json             a Studio place for tests that need Roblox datatypes
analyze.luau                  type checking, which is part of the test suite
src/                          netweave itself
  netweave.luau               the public surface: `nw`
  types/                      the type vocabulary
  codec/                      Buffer (bytes), Ir (lowering + layout), Serdes (closures)
  replication/                Delta (what changed, against what the receiver has)
  api/                        channel classes, policies, trust, context, views, namespaces
  transport/                  the wire: batching, budgets, audience evaluation, dispatch
tests/                        *_ok / *_reject / *_runtime, plus run.server.luau
spike/                        throwaway experiments; nothing here ships
  inference/                  can Luau infer a payload from a schema? (phase 1)
  declare/                    what the declaration surface can and cannot enforce (phase 5)
docs/
  RESEARCH-AND-PLAN.md        research log + roadmap (Korean, append-only in spirit)
  DESIGN-API.md               the agreed API shape and the guarantees behind it
  WIRE-FORMAT.md              frozen wire format, v1
  milestone/
    PLAN-M0.md                one file per milestone, English
    PLAN-M1.md
    PLAN-M2.md
bench/                        the benchmark harness, with its own project file
  default.project.json
  envelope.luau               the netweave batch envelope, checked under lune
  report.luau                 a run document to the tables in RESULTS.md
tools/                        globalTypes.d.luau for the analyzer
_refsrc/                      READ-ONLY vendored competitor sources — never edit
  _generated/                 codegen output used as evidence in the research log
```

### Requires are relative strings, everywhere

`require("../types")` and `require("./Buffer")` **work in both Roblox and lune** — verified in
Studio, not assumed. So `src/` needs no build step, no `script.Parent` chains, and no darklua
pass, and the same test file runs in either place.

Two consequences:

- **`test.project.json` mirrors the repository root** under one folder, so `tests/x.luau` asking
  for `../src/types` resolves identically in Studio and under lune. Do not flatten it.
- `@self/...` aliases do **not** resolve in Roblox. Relative paths only.
- **A module beside its sibling directories reaches them.** `src/netweave.luau` requiring
  `./api/Context` resolves in Studio — measured, by running `tests/api_runtime.luau` there.
- **There is no `src/init.luau`, and there must not be.** For an init file `./` means *sibling of
  the directory*, so an init module cannot reach its own children — and with `@self` unavailable
  it has no way to. The public surface is therefore `src/netweave.luau`, a sibling of `api/`,
  `codec/` and `types/`, and `default.project.json` builds `src` as a **Folder**. A consumer
  writes `require(Packages.netweave.netweave)`. Making that `require(Packages.netweave)` needs
  `@self` to work in Roblox, which the note above says it does not; re-verify before changing the
  package shape.

### `_refsrc/` is read-only
Cloned competitor repositories, kept until the user says to delete them. Never edit,
never `git add`, never import from `src/`. Read them, cite them, leave them alone.
`_refsrc/README.md` records the exact commit each was cloned at.

---

## 3. Milestone documents

One file per milestone: `docs/milestone/PLAN-M<n>.md` (`PLAN-M0.md`, `PLAN-M1.md`,
`PLAN-M1a.md` for a sub-milestone that gates another).

Required sections, in order:

1. **Goal** — one paragraph. What is true when this milestone is done that was not true before.
2. **Why now** — what this unblocks, and which research sections motivate it.
3. **Scope** — a table of deliverables, each with a concrete artifact path.
4. **Non-goals** — what is explicitly deferred, and to which milestone.
5. **Design decisions** — each with a `§` citation into `docs/RESEARCH-AND-PLAN.md`.
6. **Tasks** — checkboxed, ordered, each small enough to finish in one sitting.
7. **Acceptance criteria** — objectively checkable. No "works well".
8. **Risks** — what could make this milestone worthless, and the mitigation.

Rules:

- Update the task checkboxes in place as work lands. The file is a live document, not a snapshot.
- When a milestone finishes, add a **Result** section at the end with the measured numbers
  or the shipped API — never delete the original plan to make it look right in hindsight.
- If reality contradicts the plan, **write the correction into the plan** with a strikethrough
  on the old claim. Same discipline as `docs/RESEARCH-AND-PLAN.md`.

---

## 4. Luau conventions

Target: Roblox Luau. Every module in `src/` and `bench/` starts with:

```lua
--!strict
--!optimize 2
```

Add `--!native` only on hot serdes paths, and only when a benchmark shows it helps.
Native codegen has a compile-time cost and is not free on every module.

- **Naming**: `PascalCase` for modules and types, `camelCase` for locals and functions,
  `SCREAMING_SNAKE_CASE` for module-level constants. Match the file to its main export.
- **No globals.** Every dependency is an explicit `require` bound to a local.
- **Hot paths allocate nothing.** No Promise, no `BindableEvent` fan-out, no fresh
  coroutine per packet. Reuse a thread pool. See `§3.6-A4` (what to avoid) and `§3.6-B4`
  (what to adopt).
- **Cache module functions into locals** at the top of hot files
  (`local writeu8 = buffer.writeu8`).
- **Errors are values on the receive path.** Never `error()` on data that came off the wire —
  a malicious client must not be able to abort a batch. See `§3.8-R`.
- **`assert` is for programmer error only**, never for wire data.

### Comments

Two kinds, with different jobs. Do not blur them.

**`--[=[ ]=]` — moonwave, the public contract.** Every exported value, function and type gets
one. This is the only place where describing *what* something does is correct, because the
reader has not seen the code. Write for someone deciding whether to use it: what it is, a short
example, and the one caveat that will bite them. Tag with ``, ``, ``,
``, ``, ``, ``, ``, ``. Use `:::note` / `:::caution`
for the caveats.

**`--[[ ]]` — why, for whoever changes this next.** Never restate the line below it. Record the
constraint that forced the shape, the alternative that was tried and failed, or the competitor
mistake being avoided — with the section that documents it:

```lua
--[[
	Length prefix lets a failed decode skip to the next packet boundary. Blink and Zap have no
	length field, so one bad packet kills the whole batch (`RESEARCH §3.8-R`).
]]
```

A rule of thumb: if deleting the comment would make a future reader repeat a mistake, it is a
`--[[ ]]`. If deleting it would make a user unable to call the function, it is a `--[=[ ]=]`.

---

## 5. Benchmarking

The harness is the product's only credible argument. Treat its correctness as
higher-priority than netweave's own performance.

- **Never report a number that was not produced by a committed, re-runnable script.**
- Normalize bandwidth by observed framerate (`Stats.DataSendKbps * 60 / frames`). Without
  this, a library that tanks FPS looks like it uses less bandwidth (`§3.7-L`).
- Always measure **two schema families** — array-heavy and flag-heavy. The winner flips
  between them (`§3.9-Z`). A single blended number is meaningless.
- Always report **correctness and drop rate** alongside throughput. A fast library that
  silently drops packets is not fast.
- Competitor versions are pinned and recorded in the results file. Never benchmark against
  a moving target.
- Studio Play mode is **loopback**. Results are valid for relative comparison only; do not
  present them as real-network bandwidth or latency.

Run benchmarks through the **Roblox Studio MCP** (`start_stop_play`, `run_as_job`,
`get_console_output`). `run-in-roblox` is not needed and is not a dependency.

---

## 6. Tooling

Managed by `rokit` (`rokit.toml`). Rokit shims resolve only inside a directory with a manifest —
if a tool "is not found", check the manifest before assuming it is not installed.

- `rojo` — build/serve places
- `lune` — scripts, codegen, report generation, test runners
- `stylua` — formatting; `stylua.toml` sets `syntax = "Luau"`, without which nested generics fail
  to parse. `.styluaignore` excludes vendored sources.
- `selene` — linting; `netweave.toml` declares the `types` global that exists only inside a
  `type function` body, because selene has no scoped lint filters
- `luau-lsp` — **type checking, which is part of the test suite**, not a convenience

### Checks

```sh
lune run analyze              # type checking, both halves (see below)
lune run tests/types_runtime  # runtime behaviour, one module per file
lune run tests/buffer_runtime
lune run tests/ir_runtime
lune run tests/serdes_runtime
lune run tests/api_runtime
lune run tests/transport_runtime
lune run tests/budget_runtime
lune run tests/config_runtime
lune run tests/observer_runtime
lune run tests/query_runtime
lune run tests/protocol_runtime
lune run tests/hostile_runtime
lune run tests/fuzz_runtime
lune run tests/example_runtime
lune run tests/delta_runtime
lune run tools/messages       # every error( in src/api names the fix, not the rule
lune run bench/envelope        # the netweave batch envelope, without Studio
lune run bench/check          # everything under bench/ parses
stylua --check src tests analyze.luau bench spike
selene src tests
```

### Places

```sh
rojo build default.project.json -o netweave.rbxm   # the library, as a package
rojo build test.project.json -o netweave-test.rbxl # tests that need Roblox datatypes
rojo serve test.project.json                       # live-sync the same place
rojo serve bench/default.project.json              # the M0 harness
```

`test.project.json` exists because `Vector3`, `CFrame`, `Color3` and `Instance` do not exist
under lune, and the codec has to round-trip all four. Everything that *can* run under lune
should — it is faster and needs no Studio — but a codec test that skips those types is not
testing the codec.

**The benchmark place runs the test suite too.** `bench/default.project.json` maps `tests/` in
beside `src/`, so one Play produces the suite and then the matrix — the suite installs and
uninstalls transports and declares and resets namespaces, so both bench drivers wait on the
`netweaveTests` marker before loading any mode.

`tests/roblox_runtime.luau` is the file that cannot: it is the only test not in the lune list
above. The Studio runner only picks up `*_runtime` modules, and each of those returns `true`,
because Roblox rejects a module that does not return exactly one value.

The runner sits in `ReplicatedStorage` alongside the tests, and runs there **because
`emitLegacyScripts: false` is set**: Rojo then emits a `.server.luau` as a `Script` with
`RunContext = Server`, which executes wherever it sits in the DataModel. A legacy `Script` under
`ReplicatedStorage` would not. Do not "fix" this by moving it to `ServerScriptService` while it is
still mapped through `tests/` — that runs the whole suite twice.

`analyze` requires `LuauSolverV2` and `tools/globalTypes.d.luau`. Both are set up for you; see
`tools/README.md` if the definitions file is missing.

### Test convention

Half the guarantees in `docs/DESIGN-API.md` are type errors, so a file that *must fail* is a test:

- `tests/*_ok.luau` — must produce zero diagnostics. **A feature whose only test is a rejection file
  has no test.** `nw.configure` shipped in M3 phase 0 typed so that Luau rejected every call, and
  `tests/config_reject.luau` counted nine of those rejections as its own cases passing. Write the
  `_ok` half.
- `tests/*_reject.luau` — must produce exactly the count in its `-- netweave:expect N` header
- `tests/*_runtime.luau` — executed by lune, and must also analyze clean

**A security-relevant suite counts its own shape** through `tests/harness.luau`, and refuses to pass
under the floor it declares. Currently `budget_runtime` 100%, `hostile_runtime` 99%, `fuzz_runtime`
92%, `transport_runtime` 59%, and the rule behind the number is §9.

Two checks read source off disk rather than running it, which is why they live outside `src/` and
`tests/` — the analyzer walks those two roots and cannot resolve `@lune/fs`:

- `tools/messages.luau` — every `error(` in `src/api/` names the fix, and the worked example in
  `docs/DESIGN-API.md` is the same text as the one `tests/example_runtime.luau` runs
- `bench/check.luau` — everything under `bench/` parses

A rejection file that stops erroring means a guarantee has silently stopped being enforced. That
is worse than a build break, because nothing announces it — hence the exact count.

This is not hypothetical. During M1 phase 5 the directional views and the trust brand both became
`any` — because an `export type function` that its own module never references does not reduce
across a `require`, and nothing reports that. `tests/api_ok.luau` still type-checked. What caught
it was `tests/api_reject.luau` dropping from thirteen diagnostics to eight. See
`spike/declare/README.md` Q5.

`_refsrc/_generated/zap/bin/zap.exe` is a pinned Zap 0.6.29 build used to regenerate
benchmark schemas. Do not rebuild it casually; the Rust toolchain is not part of this
project's requirements.

---

## 7. Working agreements

- **Verify before asserting.** Every factual claim about a competitor came from reading
  their source or running their compiler. Keep that bar. If something is inferred rather
  than measured, label it.
- **Correct the record.** When a previous conclusion turns out to be wrong, strike it
  through and write why — in the document where the wrong claim lives, not only in chat.
- **No scope creep between milestones.** If work belongs to a later milestone, note it in
  that milestone's plan and move on.
- ~~The project is not a git repository yet. Do not run `git init` or commit without being
  asked.~~ **Retracted.** It is one, as of M1 phase 5. See §8.

---

## 8. Version control

Git, initialised at the end of M1 phase 5 — after the milestone was green, so the first commit is
a working tree rather than a snapshot of something half-built.

### This repository has no remote, and must not get one

**The owner's GitHub account is flagged, so hosting is not available.** This is a standing
constraint, not a temporary state:

- Never run `git remote add`, `git push`, `gh repo create`, or anything else that publishes.
- Never suggest "push it to GitHub" as a next step, or treat the absence of a remote as a gap to
  be filled.
- The backup story is the filesystem, not a forge. If a backup is wanted, that is a copy of the
  directory, and it is the owner's call.

Everything git buys here is local and still worth having: a diff when `bench/RESULTS.md` changes,
a point to return to when a Studio-only regression appears, and a record of *when* a claim was
corrected to sit alongside the strikethrough saying *what* was wrong.

### Branches

| Branch | What lives here |
|---|---|
| `master` | milestone boundaries only. A commit here means every check passed and the milestone's plan says done. |
| `develop` | the working branch. Everything lands here first. |

Work on `develop`. Merge to `master` when a milestone closes, and never commit to `master`
directly.

### Commits

- English, like every other artifact in this repository (§1).
- Say what changed and *why*, in that order. The why is the part a diff cannot show.
- Commit or push only when asked. Nothing here is automatic.
- End the message with:

  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  ```

### What is not committed

`.gitignore` already covers it: build outputs (`netweave.rbxm`, `netweave-test.rbxl`,
`bench/Benchmark.rbxl`), `sourcemap.json`, and **`_refsrc/`** — 45 MB of vendored competitor
sources that are read-only research material, not this project's code (§2).

---

## 9. Verification

A security layer has one way to succeed and many ways to fail, so a suite shaped like an ordinary
one has tested the happy path and stopped. These are the rules M3 arrived at, and each is written
next to the thing that produced it — because a rule with no incident behind it is a rule the next
person will read as taste.

### Failure paths outnumber success paths, and the count is in the suite

`tests/harness.luau` tags each section failure-path or success-path and refuses to pass a file that
declares a floor and falls under it. The floors live in the files, in the same spirit as
`-- netweave:expect N`: a number someone lowered is a number in the diff.

The tag is per **section**, not per assertion. A hostile case is written as a block — craft the
bytes, feed them in, then assert the bad packet was refused *and that the ones behind it still
arrived* — and that second assertion asserts a success while testing a failure. Per section is also
the granularity at which the ratio cannot be moved by relabelling.

The rule applies to files whose job is refusal. `ir_runtime` sits at 13% and that is not a gap:
lowering a schema has one correct answer and no adversary, and padding it to reach a number is the
failure mode of every metric.

### A regression test is confirmed to fail against the pre-fix code

Not reasoned about — run. Break the guard, watch the test fail, put the guard back. Every fix in M3
was checked this way and two of them turned out to be testing nothing:

- A duplicate-call-id test passed with the guard removed, because the handler returned immediately
  and gave its slot back before the second request was dispatched. It only bites when the handler
  yields, which is the whole point of the class.
- A `maxBytes` rejection test passed for the wrong reason: it tripped the upper-bound guard instead
  of the one it was written for, so the two covered for each other.

### No security claim without a probe that demonstrates the defect it prevents

If the plan says "this prevents X", something has to have shown X happening. `PLAN-M3` D-3 measures
39 admissions in ten milliseconds against a declared `rate = 20`; D-4 measures 690x; D-7 reverts the
hash and watches ten of eleven single-change pairs collapse to the same number.

The corollary is that a claim which cannot be probed is a claim to soften, not to keep. D-5 was
written as a decode-work counter and the measurement said the hostile packet was *cheaper per byte*
than the honest one, so the decision changed rather than the wording.

### A measurement is not a number until it survives re-running

`CLAUDE.md` §5 says never report a number that was not produced by a committed, re-runnable script.
A number that does not survive *being* re-run fails the same test, and nothing was checking it: the
benchmark's allocation probe reported a median over as few as four surviving sample windows, and
between two runs of the same matrix, libraries whose code had not changed by a line moved 19%, 21%,
37% and 86%. netweave's own numbers moved 67% and 9% and were written into a milestone plan as a
regression.

So a probe reports its **spread**, not only its median, and the reader checks the spread and the
sample count before quoting anything. And when a number looks like a regression, the first question
is what the **control group** did — how far the code that did not change moved in the same run.
Chasing the difference without asking that would have "fixed" a defect that did not exist.

### Count it instead of weighing it

The rule above makes heap measurements expensive to trust, which is a problem when the claim *is*
about the heap — "under a flood the rejection path allocates nothing" is a promise `Observer` and
`Budget` both make in as many words, and `Inbound` was breaking it in four places.

Weighing it needs windows, repeats and a spread. Counting it needs neither: a reason built per
packet is a reason that **differs** per packet, so a set of the strings a flood produced answers the
question exactly, in one run, with no dependence on how fast the collector is. Two thousand refusals
across three stages: 1,994 distinct reasons before the fix, 3 after.

Before reaching for `collectgarbage`, ask what the allocation would make *observably* different.
Often there is a counter hiding inside the property.

### The half of the suite that cannot run under lune is the half that goes red quietly

`tests/roblox_runtime.luau` is the one file the lune list cannot run, and running it is a separate,
manual act. So when M3 phase 9 taught the encoder to refuse a non-Instance, four Studio suites broke
on the spot — the stand-in the suite hands to an Instance field is a table answering `:IsA`, which
is what the *reader* asks and not what the *writer* asks — and fourteen green lune runs said nothing
about it across several commits.

Two things came out of that, and the second is the one worth keeping:

- The stand-in is a real `Instance` in Studio now. A double that differs from the real thing in the
  exact dimension the code under test checks is not a double.
- **The Studio pass is where the console is.** Running it is also the only time anybody reads
  netweave's own output at volume, and that is how the `error` severity was found bypassing the
  repeat suppression: 2,000 refusals from one test, each with a `debug.traceback`, on a stage whose
  rate a hostile peer chooses. No assertion would have caught that, because nothing was wrong with
  the result — only with what it cost to say so.

So: run the Studio half before calling a milestone green, and read the console rather than only the
pass line.

### A probe that finds nothing is written down

Recording an audit's null results is what separates "checked and fine" from "never looked". `PLAN-M3`
phase 4 lists seven probes that found nothing, in a table, next to the one that found a defect. A
future reader deciding whether to re-examine the sidecar handling can see that it was examined.

### A rejection count guarding a feature with no positive test guards nothing

`nw.configure` shipped typed so that Luau rejected **every** call, including the example in its own
docstring. Nothing said so: the only file calling it was `tests/config_reject.luau`, where a
diagnostic is what success looks like, and nine of its twelve expected diagnostics were the bug. Its
header explained them as a deliberate two-layer design.

So: **write the `_ok` half.** A guarantee tested only by things that must fail has no evidence that
the thing which must work does.

### A test that avoids the hard part is a test that was never written

Every `:listen` handler in the suite was written `function(_ctx, ...)`, so nobody noticed that `ctx`
was typed `unknown` and could be neither read nor annotated. The first handler that wanted
`ctx.player` was the worked example, in phase 7, three milestones late.

When a parameter is consistently ignored, that is the coverage gap, not the convention.

### A hand-kept list drifts, so the list is tested against what it lists

`Config`'s limit names were spelled out for the analyzer and `pendingPerBatch` was missing: the
field existed, the runtime honoured it, and the one correct spelling was refused. `Protocol`'s
attribute list has the same shape, so `tests/protocol_runtime.luau` changes each entry in turn and
asserts the signature notices.

### Nothing on the receive path is silent

Every refusal reports, whether or not a game attached an observer, and the repeat suppression is
what makes that affordable. The fuzzer found the last exception — an unknown control kind stepped
over without a word — and the forward-compatibility argument for staying quiet lost to this rule.

Guarantee G4 is the other half: wire data never reaches `error()`. `tests/fuzz_runtime.luau` runs
10,000 mutated batches and asserts the receive path never throws, never loses a packet it did not
report losing, never hands a handler a value its own schema refuses, and leaves the decoder clean
enough that an honest batch behind it still arrives.

### Errors name the fix, not the rule

Checked, not reviewed: `tools/messages.luau` requires every `error(` in `src/api/` to carry a repair
marker and to either show the offending value or spend the words explaining a mistake that has none.
Half of netweave's guarantees are `type function` errors, and those print verbatim at the call site —
in the declaration file, on the line that is wrong.
