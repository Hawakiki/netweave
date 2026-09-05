--!strict
--!optimize 2

--[[
	Turns a run's result document into the tables in `bench/RESULTS.md`.

	Usage, from the repository root:
		lune run bench/report bench/runs/<file>.json

	The run document is produced by the client driver and parked in
	`ReplicatedStorage.Results` as JSON; copy it out of Studio into `bench/runs/` first. The
	prose around the tables in `RESULTS.md` is written by hand — this script only regenerates
	the numbers, so a stale narrative next to fresh numbers stays visible rather than being
	silently overwritten.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

--[[ netweave first, because the tables exist to answer what it costs. `raw` last, because it is
     the floor rather than a competitor. ]]
local MODES = { "netweave", "blink", "zap", "bytenet", "raw" }
local SCHEMAS = { "ArrayHeavy", "FlagIdiomatic", "FlagNaive" }

local path = process.args[1]
if not path or not fs.isFile(path) then
	error("usage: lune run bench/report <run.json>")
end

local run = serde.decode("json", fs.readFile(path))

local function cell(mode: string, schema: string): any
	return run.cells[`{mode}|{schema}`]
end

local function round(value: number?, places: number): string
	if value == nil then
		return "—"
	end

	local scale = 10 ^ places
	local rounded = math.floor(value * scale + 0.5) / scale
	return if places == 0 then tostring(math.floor(rounded)) else string.format(`%.{places}f`, rounded)
end

local lines = {}

local function push(text: string)
	table.insert(lines, text)
end

push(`Run: {os.date("!%Y-%m-%d", run.generatedAt)}`)
push(`Load: {run.config.packetsPerFrame} packets/frame, {run.config.runSeconds} s window`)

if run.config.smoke then
	push("")
	push("**SMOKE RUN — not a measurement.** Short windows and few samples; kept only to show an")
	push("adapter round-trips. Re-run with `Config.SMOKE = false` before quoting anything here.")
end
push("")

push("## Bytes on the wire")
push("")
push(`| Schema | {table.concat(MODES, " | ")} |`)
push(`|---|{string.rep("---|", #MODES)}`)
for _, schema in SCHEMAS do
	local row = { schema }
	for _, mode in MODES do
		local data = cell(mode, schema)
		table.insert(row, if data and data.up.bytesPerPacket then round(data.up.bytesPerPacket, 0) else "n/a")
	end
	push(`| {table.concat(row, " | ")} |`)
end
push("")

push("## Framerate under load (client to server, p50)")
push("")
push(`| Schema | {table.concat(MODES, " | ")} |`)
push(`|---|{string.rep("---|", #MODES)}`)
for _, schema in SCHEMAS do
	local row = { schema }
	for _, mode in MODES do
		local data = cell(mode, schema)
		table.insert(row, if data then round(data.up.framerate.p50, 0) else "—")
	end
	push(`| {table.concat(row, " | ")} |`)
end
push("")

push("## Delivery (client to server)")
push("")
push("| Cell | Sent | Received |")
push("|---|---|---|")
for _, schema in SCHEMAS do
	for _, mode in MODES do
		local data = cell(mode, schema)
		if data then
			push(`| {mode} {schema} | {data.up.sent} | {data.up.received} |`)
		end
	end
end
push("")

--[[
	A median with its spread, or the median alone when the run predates the spread being recorded.

	Printed together rather than in separate columns because they are one fact: M3 phase 9 found a
	cell surviving four windows out of twenty-five whose low and high were a factor apart, quoted as
	a single number in a milestone plan and read as a regression. A table that shows only the median
	invites exactly that, so the table shows the range.
]]
local function spread(median: number?, low: number?, high: number?): string
	if median == nil then
		return "—"
	end

	if low == nil or high == nil then
		return round(median, 1)
	end

	return `{round(median, 1)} <sub>[{round(low, 1)} .. {round(high, 1)}]</sub>`
end

push("## Allocation per packet")
push("")
push("`n` is how many sample windows survived the collector, and the bracketed range is the lowest")
push("and highest of those windows. **A median whose range is a factor wide is not a number** — see")
push('`bench/README.md`, "Reading the allocation numbers".')
push("")

--[[ The control group first, because every encode cell below contains one engine frame and this is
     how much of the number that is. A run from before M4 phase 0 has no `idle` block and says so
     rather than printing a zero. ]]
if run.idle and run.idle.bytesPerPacket then
	push(
		`**Idle frame: {round(run.idle.bytesPerPacket, 1)} B `
			.. `<sub>[{round(run.idle.bytesLow, 1)} .. {round(run.idle.bytesHigh, 1)}]</sub>`
			.. `, {run.idle.allocSamples}/{run.idle.allocWindows} windows.** A frame that sends`
	)
	push("nothing, in the same units. Every encode cell below contains one engine frame; this is how")
	push("much of it is Studio. A cell near this figure is measuring the engine, not the library.")
	push("")
else
	push("_This run predates the idle control group (M4 phase 0), so the engine's share of each")
	push("encode cell is unknown._")
	push("")
end
push("| Cell | Encode B/call | n | Decode B/packet | n |")
push("|---|---|---|---|---|")
for _, schema in SCHEMAS do
	for _, mode in MODES do
		local data = cell(mode, schema)
		if data then
			push(
				`| {mode} {schema} `
					.. `| {spread(data.encodeBytesPerPacket, data.encodeBytesLow, data.encodeBytesHigh)} `
					.. `| {data.encodeAllocSamples} `
					.. `| {spread(
						data.up.decodeBytesPerPacket,
						data.up.decodeBytesLow,
						data.up.decodeBytesHigh
					)} `
					.. `| {data.up.decodeAllocSamples} |`
			)
		end
	end
end
push("")

for mode, reason in run.unavailable do
	push(`Unavailable: {mode} — {reason}`)
end

print(table.concat(lines, "\n"))
