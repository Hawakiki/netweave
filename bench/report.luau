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

	**A missing field is a failure, not a dash.** Every field is read by name, and the driver's
	names have drifted once already (`bench/src/client/init.client.luau`): the first version of this
	file printed `—` for a renamed field and exited 0, so a degraded table looked like an old one
	(M4-1). Fields every run has are demanded; fields a run may predate are read through `maybe`,
	which prints that the run did not record them rather than nothing.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

--[[ netweave first, because the tables exist to answer what it costs. `raw` last, because it is
     the floor rather than a competitor. ]]
local MODES = { "netweave", "blink", "zap", "bytenet", "raw" }
local SCHEMAS = { "ArrayHeavy", "FlagIdiomatic", "FlagNaive" }

--[[ Every direction the harness drives, in the order the client runs them. `up` is the client
     encoding; the other two are the client decoding what the server sent, by two send paths. The
     first version of this file tabled `up` only, and a 30% move on `down` was invisible unless
     someone opened the JSON (M4-1). ]]
local DIRECTIONS = { "up", "down", "fireAll" }

local path = process.args[1]
if not path or not fs.isFile(path) then
	error("usage: lune run bench/report <run.json>")
end

local run = serde.decode("json", fs.readFile(path))

local function cell(mode: string, schema: string): any
	return run.cells[`{mode}|{schema}`]
end

--[[ A field the document has to carry. Read by path so the message names what is missing. ]]
local function must(from: any, where: string, ...: string): any
	local value = from

	for _, key in { ... } do
		if type(value) ~= "table" or value[key] == nil then
			error(
				`{path}: {where} has no field {table.concat({ ... }, ".")}; the driver's names have drifted`
			)
		end

		value = value[key]
	end

	return value
end

--[[ A field a run may predate. The caller prints something that says so. ]]
local function maybe(from: any, ...: string): any
	local value = from

	for _, key in { ... } do
		if type(value) ~= "table" then
			return nil
		end

		value = value[key]
	end

	return value
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

local tree = maybe(run, "tree")
local commit = if tree and tree.commit then tree.commit else "unknown"
local dirty = if tree and tree.dirty then " (dirty)" else ""

push(`Run: {os.date("!%Y-%m-%d", must(run, "the run", "generatedAt"))}, tree {commit}{dirty}`)
push(
	`Load: {must(run, "config", "config", "packetsPerFrame")} packets/frame, `
		.. `{must(run, "config", "config", "runSeconds")} s window`
)

if must(run, "config", "config").smoke then
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

--[[
	A percentile with its spread and its sample count, or the reason it has neither.

	Printed together rather than in separate columns because they are one fact: M3 phase 9 found a
	cell surviving four windows out of twenty-five whose low and high were a factor apart, quoted as
	a single number in a milestone plan and read as a regression. A table that shows only the median
	invites exactly that, so the table shows the range. The framerate column got the same treatment
	only in PLAN-M4-BUG phase 7, three incidents late: it is the column criterion 5 is judged on.
]]
local function spread(median: number?, low: number?, high: number?, count: number?): string
	if median == nil then
		return "—"
	end

	if low == nil or high == nil then
		return round(median, 1)
	end

	local samples = if count then ` n={count}` else ""
	return `{round(median, 1)} <sub>[{round(low, 1)} .. {round(high, 1)}]{samples}</sub>`
end

local function framerate(summary: any): string
	if summary == nil then
		return "—"
	end

	local count = maybe(summary, "n")
	local samples = if count then ` n={count}` else ""
	return `{round(summary.p50, 0)} <sub>[{round(summary.p0, 0)} .. {round(summary.p100, 0)}]{samples}</sub>`
end

push("## Framerate under load (p50 [p0 .. p100], client frames per second)")
push("")
push("`up` is the client encoding; `down` and `fireAll` are the client decoding what the server sent,")
push("by a targeted send and by the library's broadcast primitive. `n` is how many one-second windows")
push("the percentiles were taken over; a run from before phase 7 did not record it.")
push("")

for _, direction in DIRECTIONS do
	push(`### {direction}`)
	push("")
	push(`| Schema | {table.concat(MODES, " | ")} |`)
	push(`|---|{string.rep("---|", #MODES)}`)
	for _, schema in SCHEMAS do
		local row = { schema }
		for _, mode in MODES do
			local data = cell(mode, schema)
			table.insert(
				row,
				if data then framerate(must(data, `{mode} {schema}`, direction, "framerate")) else "—"
			)
		end
		push(`| {table.concat(row, " | ")} |`)
	end
	push("")
end

push("## Delivery and correctness, every direction")
push("")
push("`sent` is counted by whichever side fired; a run from before phase 7 recorded 0 for the two")
push("server-sent directions, and says so. `correct` is the first packet of the cell checked against")
push("the payload that was sent — one packet, not the traffic.")
push("")
push("| Cell | Direction | Sent | Received | Dropped | Correct |")
push("|---|---|---|---|---|---|")

for _, schema in SCHEMAS do
	for _, mode in MODES do
		local data = cell(mode, schema)

		if data then
			for _, direction in DIRECTIONS do
				local leg = must(data, `{mode} {schema}`, direction)
				local sent = must(leg, `{mode} {schema} {direction}`, "sent")
				local received = must(leg, `{mode} {schema} {direction}`, "received")
				local correct = maybe(leg, "correct")

				local sentText = if sent == 0 and direction ~= "up" then "not recorded" else tostring(sent)
				local dropped = if sent == 0 then "—" else tostring(math.max(sent - received, 0))
				local correctText = if correct == nil then "unchecked" elseif correct then "yes" else "**no**"

				push(
					`| {mode} {schema} | {direction} | {sentText} | {received} | {dropped} | {correctText} |`
				)
			end
		end
	end
end
push("")

push("## Allocation per packet")
push("")
push("`n` is how many sample windows survived the collector, and the bracketed range is the lowest")
push("and highest of those windows. **A median whose range is a factor wide is not a number** — see")
push('`bench/README.md`, "Reading the allocation numbers".')
push("")

--[[ The control group first, because every encode cell below contains one engine frame and this is
     how much of the number that is. A run from before M4 phase 0 has no `idle` block and says so
     rather than printing a zero. ]]
local idle = maybe(run, "idle")

if idle and idle.bytesPerPacket then
	push(
		`**Idle frame: {round(idle.bytesPerPacket, 1)} B `
			.. `<sub>[{round(idle.bytesLow, 1)} .. {round(idle.bytesHigh, 1)}]</sub>`
			.. `, {idle.allocSamples}/{idle.allocWindows} windows.** A frame that sends`
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
					.. `| {spread(
						--[[ `raw` has no encoder to probe, so this one is optional by design. ]]
						maybe(data, "encodeBytesPerPacket"),
						maybe(data, "encodeBytesLow"),
						maybe(data, "encodeBytesHigh")
					)} `
					.. `| {maybe(data, "encodeAllocSamples") or "not recorded"} `
					.. `| {spread(
						maybe(data, "up", "decodeBytesPerPacket"),
						maybe(data, "up", "decodeBytesLow"),
						maybe(data, "up", "decodeBytesHigh")
					)} `
					.. `| {maybe(data, "up", "decodeAllocSamples") or "not recorded"} |`
			)
		end
	end
end
push("")

for mode, reason in must(run, "the run", "unavailable") do
	push(`Unavailable: {mode} — {reason}`)
end

print(table.concat(lines, "\n"))
