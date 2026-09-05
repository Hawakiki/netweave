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
