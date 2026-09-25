# `bench/vendor` — the libraries netweave is measured against

Three competitors, so the benchmark can run all four in one place and one session. **None of this is
netweave's code**, and none of it reaches a consumer: `default.project.json` builds `src` alone, so
`netweave.rbxm` contains nothing from this directory.

All three are MIT, and each directory carries its upstream `LICENSE` beside the code — which is what
MIT asks for and the reason these files are here rather than only the code.

| Directory | What it is | Version | Upstream |
|---|---|---|---|
| `blink/` | **generated output**: `Server.luau` and `Client.luau`, emitted by Blink's compiler from the benchmark's own schema | v0.18.8 | [1Axen/blink](https://github.com/1Axen/Blink), MIT, © 2024 Axen |
| `zap/` | **generated output**, the same two files from Zap's compiler | v0.6.29 | [red-blox/zap](https://github.com/red-blox/zap), MIT, © 2023 The Redblox Authors |
| `bytenet/` | **a source copy**, 36 files including ByteNet's own `dataTypes/README.md` — ByteNet has no code generator, so the library itself is vendored | `fbdb156`, 2025-08-01 | [ffrostfall/ByteNet](https://github.com/ffrostfall/ByteNet), MIT, © 2025 ffrostfall |

The two generated families still embed their generator's runtime, which is why they carry a licence
too: what is here is a substantial portion of somebody else's software whichever way it arrived.

## Why they are committed rather than fetched

`CLAUDE.md` §5: never report a number that was not produced by a committed, re-runnable script, and
never benchmark against a moving target. A version pinned in a table is a claim about a version;
these files *are* that version, so a run from this tree in a year measures what the results file says
it measured. The schemas they were generated from are in `bench/schemas/`, and
`_refsrc/_generated/zap/bin/zap.exe` is the pinned Zap build that regenerates them.

## Not to be confused with `_refsrc/`

`_refsrc/` holds full clones of these repositories plus Flamework's networking, for reading and
citing in `docs/RESEARCH-AND-PLAN.md`. It is **not** committed — `.gitignore` excludes everything
under it except its own `README.md`, which records the commit each clone was taken at. That
directory is research material; this one is a dependency of the harness.
