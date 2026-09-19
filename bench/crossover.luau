--!strict
--!optimize 2

--[[
	Where a diff loses to a resend, in bytes, on the real writer.

		lune run bench/crossover

	`PLAN-M4` acceptance 8 asked for the crossover — the subject size below which replicating a
	change costs more than sending the value again — and M4 closed without measuring it. It was to
	be a replication mode in the Studio matrix, and it is not one, for a reason worth writing down:
	the question is bytes, both sides of it are netweave, and a byte count is exact under lune where a
	Kbps cell in Studio carries the spread `bench/RESULTS.md` records. So the two shapes a game has
	to choose between are written by `Batch` itself and measured — a `replicate` channel's change
	against an `event` carrying the subject and every field — for a struct of N `u16` fields with
	k of them moved, and the winner per cell is the finding.

	Every number here is deterministic, so there is no spread to print; the assertions at the end
	are the shape of the answer, and they fail if the wire format moves under them.
]]

local Batch = require("../src/transport/Batch")
local Buffer = require("../src/codec/Buffer")
local nw = require("../src/netweave")
local t = require("../src/types")

local FIELD_COUNTS = { 1, 2, 3, 4, 6, 8, 12, 16, 24, 32 }

local declared: { [string]: any } = {}
local worlds: { [number]: { [number]: any } } = {}

for _, count in FIELD_COUNTS do
	local fields: { [string]: any } = {}
	local carried: { [string]: any } = { id = t.u16 }

	for index = 1, count do
		fields[`f{index}`] = t.u16
		carried[`f{index}`] = t.u16
	end

	local world: { [number]: any } = {}
	worlds[count] = world

	declared[`mirror{count}`] = (nw.replicate :: any)({
		subject = t.u16,
		data = t.struct(fields),
		audience = nw.audience.everyone,
		store = nw.store.of(world),
	})
	declared[`resend{count}`] = (nw.event :: any)({
		data = t.struct(carried),
		audience = nw.audience.everyone,
	})
end

local bench = nw.namespace("crossover", declared)
nw.protocol()
local channels = bench.channels :: any

--[[ One packet in an empty batch, less the version byte the batch carries once for all of them. ]]
local function packetBytes(): number
	local packed = Buffer.take()
	Buffer.load(nil)
	return buffer.len(packed) - 1
end

local function valueOf(count: number, moved: number, generation: number): any
	local value: { [string]: any } = {}

	for index = 1, count do
		value[`f{index}`] = if index <= moved then generation else 0
	end

	return value
end

type Cell = { fields: number, moved: number, diff: number, resend: number }

local cells: { Cell } = {}

print("        a struct of N u16 fields, k of them moved since the recipient last saw it")
print("")
print("        N fields   k moved   diff bytes   resend bytes   cheaper")

for _, count in FIELD_COUNTS do
	local mirror = channels[`mirror{count}`]
	local resend = channels[`resend{count}`]

	local resendValue = valueOf(count, count, 1)
	resendValue.id = 1

	Buffer.load(nil)
	Batch.writePacket(resend, resendValue)
	local resendBytes = packetBytes()

	local moves: { number } = { 1 }

	if count >= 4 then
		table.insert(moves, count // 2)
	end

	if count >= 2 then
		table.insert(moves, count)
	end

	for _, moved in moves do
		local old = valueOf(count, 0, 0)
		local new = valueOf(count, moved, 1)

		Buffer.load(nil)
		local written = Batch.writeChange(mirror, 1, old, new)
		assert(written, "a moved field has to produce a change")
		local diffBytes = packetBytes()

		table.insert(cells, { fields = count, moved = moved, diff = diffBytes, resend = resendBytes })

		print(
			string.format(
				"        %8d   %7d   %10d   %12d   %s",
				count,
				moved,
				diffBytes,
				resendBytes,
				if diffBytes < resendBytes
					then "diff"
					elseif diffBytes > resendBytes then "resend"
					else "level"
			)
		)
	end
end

local function cell(fields: number, moved: number): Cell
	for _, entry in cells do
		if entry.fields == fields and entry.moved == moved then
			return entry
		end
	end

	error(`no cell for {fields} fields, {moved} moved`)
end

--[[ And the case the resend cannot express at all: nothing moved. ]]
Buffer.load(nil)
local idle = Batch.writeChange(channels.mirror8, 1, valueOf(8, 0, 0), valueOf(8, 0, 0))
print("")
print(
	`        8 fields, nothing moved: the diff writes {if idle then "a packet" else "nothing"}, `
		.. `the resend writes its {cell(8, 8).resend} bytes again`
)

-- ---------------------------------------------------------------------------------------------
-- The shape of the answer
-- ---------------------------------------------------------------------------------------------

local failures = 0

local function expect(condition: boolean, message: string)
	if not condition then
		failures += 1
		print(`FAIL  {message}`)
	end
end

--[[ A single field is the one subject a diff cannot win: the flag byte and the length prefix are
     the whole overhead, and there is nothing to leave out. ]]
expect(cell(1, 1).diff > cell(1, 1).resend, "one field moved of one: the resend has to win")

--[[ Two fields is level: the flag byte and the length prefix against the one field left out. From
     three up, one moved field is cheaper as a diff, and the gap is the fields it did not send. ]]
expect(cell(2, 1).diff == cell(2, 1).resend, "one field moved of two: level")

for _, count in FIELD_COUNTS do
	if count >= 3 then
		expect(cell(count, 1).diff < cell(count, 1).resend, `{count} fields, one moved: the diff has to win`)
	end
end

--[[ Half moved is a diff's ordinary day, and it wins from four fields up. ]]
for _, count in FIELD_COUNTS do
	if count >= 4 then
		expect(
			cell(count, count // 2).diff < cell(count, count // 2).resend,
			`{count} fields, half moved: the diff has to win`
		)
	end
end

--[[ And when everything moved the diff is the resend plus its flags, so it loses by the flag bytes
     and the length prefix, at every size. ]]
for _, count in FIELD_COUNTS do
	if count >= 2 then
		expect(
			cell(count, count).diff > cell(count, count).resend,
			`{count} fields, all moved: the resend has to win`
		)
	end
end

expect(not idle, "nothing moved: the diff has to write nothing")

if failures > 0 then
	error(`{failures} crossover assertion(s) failed`)
end

print("")
print("OK      crossover")

return true
