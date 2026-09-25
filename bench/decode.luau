--!strict
--!optimize 2

--[[
	Where an `ArrayHeavy` **decode** spends its time, layer by layer, without Studio.

		lune run bench/decode

	`bench/profile.luau`'s mirror. That file took the encode apart and M4 phase 7 acted on it; the
	M4 report then pointed out that everything it found stops at the send path — M2's block
	optimisation and phase 7's fused writer are both encode-side — and that decode is what a server
	pays per client, per packet, for the whole session.

	Every rung reads the same 600 bytes the encoder produced, into the same shape, and differs from
	its neighbour by one thing:

	  1. `inline` — offsets precomputed, `buffer.readu8` named, no checks. What a generator emits,
	     and the ceiling nothing schema-driven can beat.
	  2. `inline + range` — the same, plus the one guard netweave's reader owes every value: is what
	     arrived inside the range the schema declared. This is the honest ceiling, because netweave
	     cannot drop that check and stay netweave.
	  3. `dispatched` — rung 1 with the primitive fetched from a table instead of named. On the
	     write side that single change was worth 1.6x on the whole packet (`RESEARCH §3.11-GG`), and
	     the question is whether the read side behaves the same way. It is the reason the reader
	     below is a branch chain rather than a lookup.
	  4. `per value` — one call per value into `Buffer.readU8`, which bounds-checks each read
	     against the packet limit. What netweave's primitives cost before any of the walk above
	     them.
	  5. `netweave` — the real `Serdes` reader.

	:::caution
	This runs under lune, so the absolute nanoseconds are not Studio's and are not comparable to a
	framerate. What transfers is the **ratio between rungs**, because every rung runs on the same VM
	in the same run — and `bench/profile.luau`'s own history is the reason that caveat is here in as
	many words: a component benchmark cannot say what fraction of a frame it owns.
	:::

	`CLAUDE.md` §9: a measurement is not a number until it survives re-running, so every rung reports
	its spread and the reader is expected to look at it before quoting anything.
]]

local Buffer = require("../src/codec/Buffer")
local Ir = require("../src/codec/Ir")
local Serdes = require("../src/codec/Serdes")
local t = require("../src/types")

--[[ Cached the way `CLAUDE.md` §4 asks of a hot file. `readu8` stays a fastcall — the alias is
     resolved by the compiler, the table lookup in `dispatched` is not. ]]
local readu8 = buffer.readu8
local readU8 = Buffer.readU8

--[[ The same three numbers `bench/profile.luau` restates, and for the same reason: the modules that
     own them are Roblox-only and this file has to run under lune. A change there without a change
     here shows up as this probe describing a payload the benchmark no longer sends. ]]
local ENTITY_COUNT = 100
local FIELD_COUNT = 6
local PACKETS = 200

local PACKET_BYTES = ENTITY_COUNT * FIELD_COUNT
local VALUES = ENTITY_COUNT * FIELD_COUNT

local REPEATS = 51
local WARMUP = 5

--[[ What this file printed on the tree before `Serdes.fusedStructReader` existed — the same script,
     one commit earlier, which is what makes it a number rather than a memory (`CLAUDE.md` §5).
     This file did not exist on that tree, so to reproduce them copy it there: `git worktree add
     ../before db49ca5~1`, copy this file into that tree's `bench/`, and run it. M4-1 did, and got
     32,740 against the 32,731 here. ]]
local BEFORE: { [string]: number } = {
	["inline"] = 6369,
	["inline + range"] = 8100,
	["dispatched"] = 16633,
	["per value"] = 17453,
	["netweave"] = 32731,
}

-- ---------------------------------------------------------------------------------------------
-- The payload, and the codec under test
-- ---------------------------------------------------------------------------------------------

type Entity = {
	id: number,
	x: number,
	y: number,
	z: number,
	orientation: number,
	animation: number,
}

local payload: { Entity } = (table.create(ENTITY_COUNT) :: any) :: { Entity }

for index = 1, ENTITY_COUNT do
	payload[index] = {
		id = (index * 7) % 256,
		x = (index * 13) % 256,
		y = (index * 29) % 256,
		z = (index * 31) % 256,
		orientation = (index * 37) % 256,
		animation = (index * 41) % 256,
	}
end

--[[ `t.array(Entity, 100, 100)` — the exact bound the adapter declares, which is what makes the
     payload statically sized. A bounded-but-not-exact array would be measuring a different schema
     than the matrix sends. ]]
local schema = t.array(
	t.struct({
		id = t.u8,
		x = t.u8,
		y = t.u8,
		z = t.u8,
		orientation = t.u8,
		animation = t.u8,
	}),
	ENTITY_COUNT,
	ENTITY_COUNT
)

local codec = Serdes.build(Ir.lower(schema))

--[[ The bytes every rung reads, laid out as a batch of `PACKETS` identical packets so a pass calls
     `beginRead` once and then decodes forward — which is what the receive path does. Setting the
     cursor per packet would put a call netweave does not make inside the timed region. ]]
Buffer.take()
codec.write(payload)

local packed = (Buffer.take())
local stream = buffer.create(PACKETS * PACKET_BYTES)

for index = 0, PACKETS - 1 do
	buffer.copy(stream, index * PACKET_BYTES, packed, 0, PACKET_BYTES)
end

--[[ What `Serdes.structReader` clones so decode never rehashes (`RESEARCH §3.7-M`). The inline
     rungs clone the same table, or they would be measuring a cheaper allocation than netweave's. ]]
local TEMPLATE = {
	id = false,
	x = false,
	y = false,
	z = false,
	orientation = false,
	animation = false,
}

--[[ The lookup `dispatched` pays and the branch chain in `Serdes.fusedStructReader` exists to
     avoid. Keyed the way a schema-driven builder would key it. ]]
local RAW_READ: { [string]: (b: buffer, at: number) -> number } = {
	u8 = buffer.readu8,
	u16 = buffer.readu16,
	u32 = buffer.readu32,
	f32 = buffer.readf32,
	f64 = buffer.readf64,
}

-- ---------------------------------------------------------------------------------------------
-- The rungs
-- ---------------------------------------------------------------------------------------------

local function inline()
	local offset = 0

	for _ = 1, PACKETS do
		local result = table.create(ENTITY_COUNT)

		for index = 1, ENTITY_COUNT do
			local entity: any = table.clone(TEMPLATE)

			entity.id = readu8(stream, offset)
			entity.x = readu8(stream, offset + 1)
			entity.y = readu8(stream, offset + 2)
			entity.z = readu8(stream, offset + 3)
			entity.orientation = readu8(stream, offset + 4)
			entity.animation = readu8(stream, offset + 5)

			result[index] = entity
			offset += FIELD_COUNT
		end
	end
end

--[[
	The same, plus the guard `Serdes.numberReader` owes every value it hands a game: what arrived is
	inside the range the schema declared. A value that is not is `reject`ed and the declared minimum
	is returned, because wire data never reaches `error()` (G4).

	Written out six times rather than looped through a helper, because a helper is a call and the
	call is what the rungs below are for. This is the one place in the repository where repeating
	yourself is the measurement.
]]
local function inlineChecked()
	local offset = 0

	for _ = 1, PACKETS do
		local result = table.create(ENTITY_COUNT)

		for index = 1, ENTITY_COUNT do
			local entity: any = table.clone(TEMPLATE)

			local id = readu8(stream, offset)
			if not (id >= 0 and id <= 255) then
				id = 0
			end
			entity.id = id

			local x = readu8(stream, offset + 1)
			if not (x >= 0 and x <= 255) then
				x = 0
			end
			entity.x = x

			local y = readu8(stream, offset + 2)
			if not (y >= 0 and y <= 255) then
				y = 0
			end
			entity.y = y

			local z = readu8(stream, offset + 3)
			if not (z >= 0 and z <= 255) then
				z = 0
			end
			entity.z = z

			local orientation = readu8(stream, offset + 4)
			if not (orientation >= 0 and orientation <= 255) then
				orientation = 0
			end
			entity.orientation = orientation

			local animation = readu8(stream, offset + 5)
			if not (animation >= 0 and animation <= 255) then
				animation = 0
			end
			entity.animation = animation

			result[index] = entity
			offset += FIELD_COUNT
		end
	end
end

--[[ Rung 1 with one line changed: the primitive comes out of a table instead of being named. The
     most important rung in `bench/profile.luau` was this one on the write side. ]]
local function dispatched()
	local raw = RAW_READ["u8"]
	local offset = 0

	for _ = 1, PACKETS do
		local result = table.create(ENTITY_COUNT)

		for index = 1, ENTITY_COUNT do
			local entity: any = table.clone(TEMPLATE)

			entity.id = raw(stream, offset)
			entity.x = raw(stream, offset + 1)
			entity.y = raw(stream, offset + 2)
			entity.z = raw(stream, offset + 3)
			entity.orientation = raw(stream, offset + 4)
			entity.animation = raw(stream, offset + 5)

			result[index] = entity
			offset += FIELD_COUNT
		end
	end
end

--[[ One call per value into the codec's own primitive, which bounds-checks every read against the
     packet limit. The whole point of a block path is to ask that question once for a run of bytes
     whose size the layout already knows. ]]
local function perValue()
	Buffer.beginRead(stream, nil)

	for _ = 1, PACKETS do
		local result = table.create(ENTITY_COUNT)

		for index = 1, ENTITY_COUNT do
			local entity: any = table.clone(TEMPLATE)

			entity.id = readU8()
			entity.x = readU8()
			entity.y = readU8()
			entity.z = readU8()
			entity.orientation = readU8()
			entity.animation = readU8()

			result[index] = entity
		end
	end
end

local failed = false

local function netweave()
	Buffer.beginRead(stream, nil)

	for _ = 1, PACKETS do
		local value, failure = codec.read()

		if failure ~= nil or value == nil then
			failed = true
		end
	end
end

-- ---------------------------------------------------------------------------------------------
-- Measuring
-- ---------------------------------------------------------------------------------------------

type Rung = { name: string, run: () -> () }

local rungs: { Rung } = {
	{ name = "inline", run = inline },
	{ name = "inline + range", run = inlineChecked },
	{ name = "dispatched", run = dispatched },
	{ name = "per value", run = perValue },
	{ name = "netweave", run = netweave },
}

type Result = { name: string, fastest: number, median: number, high: number }

--[[ The fastest pass, for the reason `bench/profile.luau` gives at length: the work is
     deterministic, so noise only ever adds. The median and the slowest are printed beside it so
     that claim can be checked rather than taken. ]]
local function measure(rung: Rung): Result
	local samples: { number } = (table.create(REPEATS) :: any) :: { number }

	for _ = 1, WARMUP do
		rung.run()
	end

	for index = 1, REPEATS do
		local started = os.clock()
		rung.run()
		local elapsed = os.clock() - started

		samples[index] = elapsed * 1e9 / PACKETS
	end

	table.sort(samples)

	return {
		name = rung.name,
		fastest = samples[1],
		median = samples[math.ceil(REPEATS / 2)],
		high = samples[REPEATS],
	}
end

local results: { Result } = {}
local byName: { [string]: number } = {}

for _, rung in rungs do
	local result = measure(rung)

	table.insert(results, result)
	byName[result.name] = result.fastest
end

-- ---------------------------------------------------------------------------------------------
-- The report
-- ---------------------------------------------------------------------------------------------

local inlineCost = byName["inline"]
local checkedCost = byName["inline + range"]
local dispatchedCost = byName["dispatched"]
local netweaveCost = byName["netweave"]

print("")
print(
	`        {ENTITY_COUNT} entities x {FIELD_COUNT} u8 fields = {PACKET_BYTES} bytes a packet, `
		.. `{PACKETS} packets a pass, {REPEATS} passes`
)
print("")
print("        rung              ns/packet       ns/value      median      slowest")

for _, result in results do
	local before = BEFORE[result.name]
	local moved = if before > 0 then ` ({string.format("%.2f", before / result.fastest)}x)` else ""

	print(
		`        {string.format("%-14s", result.name)}  {string.format("%9.0f", result.fastest)}    `
			.. `{string.format("%9.1f", result.fastest / VALUES)}   {string.format("%9.0f", result.median)}    `
			.. `{string.format("%9.0f", result.high)}{moved}`
	)
end

print("")
print(
	`        netweave: {string.format("%.0f", netweaveCost)} ns/packet — `
		.. `{string.format("%.2f", netweaveCost / inlineCost)}x the ceiling, `
		.. `{string.format("%.2f", netweaveCost / checkedCost)}x the ceiling that checks what it reads`
)
print(
	`        naming the primitive instead of looking it up: {string.format("%.0f", dispatchedCost)} vs `
		.. `{string.format("%.0f", inlineCost)} ns/packet, {string.format("%.2f", dispatchedCost / inlineCost)}x`
)

--[[ The one number this file exists to sit beside. `bench/profile.luau` prices the encode of the
     same payload; a server pays that once per packet it sends and the decode once per packet it
     receives, and until M4 phase 8 only one of the two had ever been taken apart. ]]
print("")
print("        bench/profile prices the encode of this same payload. Read the two together.")

print("")
print(if failed then "FAIL    decode" else "OK      decode")

--[[ A module inside Roblox has to return exactly one value; under lune this is ignored. ]]
return true
