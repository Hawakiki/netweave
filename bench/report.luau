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

push("## Allocation per packet")
push("")
push("| Cell | Encode B/call | n | Decode B/packet | n |")
push("|---|---|---|---|---|")
for _, schema in SCHEMAS do
	for _, mode in MODES do
		local data = cell(mode, schema)
		if data then
			push(
				`| {mode} {schema} | {round(data.encodeBytesPerPacket, 1)} | {data.encodeAllocSamples} `
					.. `| {round(data.up.decodeBytesPerPacket, 1)} | {data.up.decodeAllocSamples} |`
			)
		end
	end
end
push("")

for mode, reason in run.unavailable do
	push(`Unavailable: {mode} — {reason}`)
end

print(table.concat(lines, "\n"))
