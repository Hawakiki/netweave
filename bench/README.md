# netweave benchmark harness

Measures Blink, Zap, ByteNet and raw `RemoteEvent` under identical load, so every performance
claim in this project has a number behind it. See `docs/milestone/PLAN-M0.md` for the design
and `docs/RESEARCH-AND-PLAN.md` for why each measurement is shaped the way it is.

## Running

From the repository root:

```sh
# 1. Regenerate the vendored codegen output from bench/schemas/*.
lune run bench/schemas/generate

# 2. Sanity: every file under bench/ parses.
lune run bench/check

# 3. Build the place, with the commit it was built from written into it.
lune run bench/build
```

`bench/build` writes `bench/src/shared/Tree.luau` (ignored by git) and then runs `rojo build`; the
run document records that commit as `tree`, so an archived run can be attributed. A plain
`rojo build bench/default.project.json -o bench/Benchmark.rbxl` works too and records `unknown`.

Then open `bench/Benchmark.rbxl` in Roblox Studio and start a play session. The client script
drives the whole matrix and prints the result document to the output window between
`--RESULTS JSON--` and the end of output. It is also parked in `ReplicatedStorage.Results`.

### Driving Studio from the terminal

With the Roblox Studio MCP connected, the run is started and read without touching the Studio
UI (`start_stop_play`, then `get_console_output` or a `execute_luau` read of
`ReplicatedStorage.Results`). This is how the committed baseline was produced. It is the
convenient path, not the correct one — the harness does not depend on it.

With the Rojo plugin connected instead, `rojo serve bench/default.project.json` syncs edits
live; restart the server after changing `default.project.json` itself, and delete any instance
the project file no longer declares (Rojo does not remove them).

### Manual fallback

If the MCP connection is unavailable: open the place, press **F5**, wait for `[bench] done`,
then copy the JSON after `--RESULTS JSON--` from the output window into `bench/runs/<date>.json`
and run the report generator over it.

## Expected runtime

Fifteen cells (five modes x three schemas), each with an allocation probe and three 10 s runs
(`Up`, `Down`, `FireAll`) with a warm-up each, separated by drain waits. A full run takes about
**fifteen minutes**.

`PACKETS_PER_FRAME` in `src/shared/Config.luau` is 200. Blink uses 1000, which assumes ~60 FPS;
Studio runs uncapped and measured 200-240 FPS, where 1000/frame is ~138 MB/s of offered load on
`ArrayHeavy` and measures the send queue rather than the library. Bytes are counted exactly at
the remote and do not depend on load, so the load only has to separate the libraries on
framerate. Change it for every mode or not at all.

## Reading the allocation numbers

`encodeBytesPerPacket` and `decodeBytesPerPacket` are medians over sample windows, and each is
recorded with `...BytesLow`, `...BytesHigh` and `...AllocSamples` beside it. **Read those three
before quoting the median.**

The collector cannot be stopped in Roblox, so a window it runs inside is discarded, and on a large
schema most windows are. Measured in M3 phase 9: the `ArrayHeavy` cells survive three to seven
windows out of twenty-five, and between two runs of the same matrix, libraries whose code had not
changed by a line moved **19% and 21%** on encode and **37% and 86%** on decode. Every flag cell in
both runs agreed to the decimal, because their windows are small enough that all of them survive.

So a cell with four samples and a low-to-high spread of a factor is not a number. It was written
into a milestone plan as a netweave regression before anyone looked at the control group, and the
same comparison run under lune with one *frame* per window — four hundred usable windows out of four
hundred, spread of zero — showed the two trees identical to the decimal.

### What M4 phase 0 changed, and what it deliberately did not

**The send side measures one frame per window now** (`Alloc.frames`). The old probe called `fire`
five thousand times back to back and never let a frame end, so for a batching library nothing was
ever flushed and the payloads piled into one outgoing buffer that grows by **doubling** — most calls
allocating nothing and a handful allocating a block the size of everything before them. That is
bursty by construction, and the median of twenty-five windows over it was a lottery on where the
doublings landed.

The caller's frame function now ends in `PostSimulation:Wait()`, so every library's own scheduler
flushes inside the measured window. What that bought:

| `ArrayHeavy` encode | before | after |
|---|---|---|
| surviving windows | 4-8 of 25 | **280-373 of 400** |
| netweave median, range | 3932.2 `[1311 .. 20972]` | **1909.8 `[1884 .. 1925]`** |
| `raw` | no usable window, ever | **10.2 `[5 .. 31]`** |

The medians moved by a factor of two to six, so the old encode column was not merely imprecise, it
was **biased high** — which is what an unflushed doubling buffer does. Two independent checks say
the new one is right: netweave's 1909.8 B agrees with the phase 9 lune probe's 1908.4 B to 0.07%,
and `raw` — which does no serialisation at all — lands on the idle control group's figure, because
all that is left in its window is the engine.

**The receive side was moved with it and moved back.** The two costs have opposite shapes: an
outgoing buffer is still there at the frame boundary and a batch of decoded values is not.
`inbound.receive` decodes, dispatches and returns its pending list to the pool, so a
`PostSimulation` sample arrives after the peak. Measured, not argued — one decoded `ArrayHeavy`
value is **32,097 bytes** under lune, agreeing with phase 9's independent probe to 0.15%:

| `ArrayHeavy` decode, per packet | figure | against 32,097 B |
|---|---|---|
| frame boundary | 604 | out by 53x |
| packet-aligned, inside the callback | ~10,200 | out by 3.2x |

So the decode window stays where it is. **Both are lower bounds** — every window the collector
visited is discarded and the survivors are the ones where it freed the least — so read the Studio
decode column as "at least this much", and reach for a lune probe when the absolute number matters.

### Two things to know before quoting any of it

**There is an idle control group.** `idle` in the run document is a frame that sends nothing,
measured in the same units and window count. A frame window contains a real engine frame, so
Studio's own allocation is inside every encode cell; this is how much. It measures **10.2 B per
packet-equivalent**, or about 2 KB per frame. That is nothing against `ArrayHeavy` and about a third
of a flag cell, which is exactly why it is printed above the table rather than left implicit.

**The floor is 1 KB.** `collectgarbage("count")` reports kilobytes, so a frame window resolves to
±1024 B — **±5.12 B per packet** at 200 packets per frame. Every figure in these tables is a
multiple of 5.12 and differences smaller than that are quantisation, not measurement.

## What the numbers mean, and do not mean

- Studio play mode is **loopback**. The replication path is real, the network is not. These
  results support relative comparison between libraries and nothing else. Do not quote them as
  bandwidth or latency figures.
- Bandwidth is normalized to 60 FPS before it is recorded. A library that tanks the framerate
  would otherwise appear to use less bandwidth, because it gets to send fewer packets per
  wall-clock second.
- Bytes per packet is **derived** from normalized bandwidth, not counted on the wire. It is
  cross-checked against byte counts read directly out of the generated code (RESEARCH §3.9-V3,
  §3.9-AA). If the two disagree, the harness is wrong.
- Allocation figures are order-of-magnitude only. Roblox permits `collectgarbage("count")` but
  not stopping or forcing the collector, so windows the collector disturbed are discarded and
  the median of the rest is reported.
- `FlagIdiomatic` and `FlagNaive` are the same schema written two ways. They differ only for
  Blink, which has an explicit `set` bitfield type; Zap packs automatically and ByteNet has
  neither, so those two modes report identical cells. That is the finding, not a bug.

## Layout

```
schemas/          .blink and .zap sources; generate.luau compiles both
vendor/           pinned competitor artifacts (bytenet 0.4.3 by tag, blink/zap generated)
src/shared/       Payloads, Metrics, Alloc, Config, Modes + one adapter per library
src/server/       receive, count, validate, decode-side heap delta, Down-direction load
src/client/       run order, load, sampling, result document
check.luau        parses everything under bench/
envelope.luau     the netweave batch envelope, byte for byte, without Studio
profile.luau      where an ArrayHeavy encode's time goes, without Studio
```

`profile.luau` is the instrument M4 phase 7 added, and it answers a question the matrix cannot: a
framerate covers rendering, physics and replication as well as the codec, so a gap in it cannot be
attributed to anything. The probe takes one packet apart rung by rung — generated-code ceiling,
the schema's checks, one call per value, the real codec — and each rung differs from its neighbour
by one thing.

```sh
lune run bench/profile
```

Read it the way `RESULTS.md` asks you to read the allocation column: the **ratios between rungs**
transfer, the absolute nanoseconds are lune's rather than Studio's, and every rung prints its
median and its slowest pass beside the number so you can see how much of it is the machine.

Nothing under `vendor/` is hand-written. Regenerate rather than edit.

## Archived runs

`runs/` holds the JSON document each run produces. `report.luau` regenerates the tables in
`RESULTS.md` from one:

```sh
lune run bench/report bench/runs/2026-09-03.json
```

The prose in `RESULTS.md` is written by hand, so a stale narrative next to fresh numbers stays
visible instead of being silently overwritten. Copy a new run's JSON out of
`ReplicatedStorage.Results` (or from the console after `--RESULTS JSON--`) into `runs/` before
the play session ends — it does not survive stopping the game.
