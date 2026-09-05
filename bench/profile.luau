--!strict
--!optimize 2

--[[
	Where an `ArrayHeavy` encode spends its time, layer by layer, without Studio.

		lune run bench/profile

	`PLAN-M4` D-5: the framerate gap is measured before it is chased. The matrix says netweave
	encodes 100 entities at 84 FPS against Blink's 130 and offers no way to ask *why* — a frame
	contains rendering, physics and replication as well as the codec, and one number over all of it
	cannot be attributed. This is the same encode with the frame taken away.

	**Every rung writes the same 600 bytes from the same payload**, and each differs from its
	neighbour by one thing:

	  1. `inline` — offsets precomputed, no calls, no checks. What Blink and Zap generate, and the
	     ceiling nothing schema-driven can beat.
	  2. `inline + range` — the same, plus netweave's two per-value guards written out. The cost of
	     answering "is this value in the range the schema declared".
	  3. `put` — one call per value into `Buffer.putU8`, inside a claimed block.
	  4. `write` — one call per value into `Buffer.writeU8`, which allocates its own bytes. **This
	     rung prices a hypothesis rather than a design**: M1 blamed the gap on 600 `allocate` calls
	     per packet, M2 phase 0 removed them, and the framerate did not move. The difference between
	     rungs 4 and 3 is the whole of what that fix could ever have bought.
	  5. `netweave` — the real `Serdes` codec.
	  6. `dispatched` — netweave's own struct writer with one line changed: the raw writer comes out
	     of a table instead of being named. See below; this is the most important rung in the file.
	  7. `rows` — the same claim, but a loop reading each field's offset out of a parallel array.

	### What it found, and what it got wrong first

	The attribution said 10% checks, 30% one call per value, and **52% the closure per value and the
	struct walk that finds the field to hand it** — seven calls for a six-field struct before a byte
	is written. So the fix was to claim the struct's bytes once and write them all, with the offsets
	computed at declaration time.

	~~Priced at 2.7x.~~ **Wrong, and the way it was wrong is the finding.** The candidate rungs were
	hand-written, so they said `buffer.writeu8(...)` — and Luau compiles a *named* builtin to a
	fastcall, performed inline with no call frame. A builder driven by a schema reaches for
	`RAW_NUMBER[storage]` instead, and that is an ordinary call. The first implementation did exactly
	that and delivered 10%, against a probe promising 170%.

	`dispatched` is that version, kept as the control. The difference between it and `netweave` is
	one table lookup moved from run time to build time, and it is worth **2x on the whole packet** —
	more than every other layer put together. `Serdes.fusedStructWriter` therefore names all five
	primitives in a branch chain rather than holding one in an upvalue.

	That is also the honest answer to why code generators win here. It is not that they avoid
	closures — netweave can too. It is that they emit the *name* of the primitive.

	`rows` is the shape that was tried before either: keep the loop, read each field's offset and
	bounds out of arrays. It is **slower than doing nothing**, which is why the unroll is not a
	matter of taste.

	:::caution
	This runs under lune, so the absolute nanoseconds are not Studio's and are not comparable to a
	framerate. What transfers is the **ratio between rungs**, because every rung runs on the same VM
	in the same run. The number of record for the gap itself stays the Studio one in
	`bench/RESULTS.md`.
	:::

	`CLAUDE.md` §9: a measurement is not a number until it survives re-running, so every rung reports
	its spread and the reader is expected to look at it before quoting anything.
]]

local Buffer = require("../src/codec/Buffer")
local Ir = require("../src/codec/Ir")
local Serdes = require("../src/codec/Serdes")
local t = require("../src/types")

--[[ Cached the way `CLAUDE.md` §4 asks of a hot file. `writeu8` is the alias the ceiling rungs use,
     and it stays a fastcall — the alias is resolved by the compiler, the table lookup in
     `dispatched` is not. ]]
local writeu8 = buffer.writeu8
local putU8 = Buffer.putU8
local writeU8 = Buffer.writeU8
local claim = Buffer.claim

--[[ `bench/src/shared/Payloads.luau` and `Config.luau`, restated rather than required: those modules
     are Roblox-only (`Random`, `RunService`) and this file has to run under lune. The three numbers
     are the ones the matrix uses, and a change to them there without a change here shows up as this
     probe describing a payload the benchmark no longer sends. ]]
local ENTITY_COUNT = 100
local FIELD_COUNT = 6
local PACKETS = 200

local PACKET_BYTES = ENTITY_COUNT * FIELD_COUNT
local VALUES = ENTITY_COUNT * FIELD_COUNT

local REPEATS = 51
local WARMUP = 5

--[[
	The Studio numbers, from `bench/runs/2026-09-05-m4p7.json` — the matrix run *after* the fused
	writer landed. They are constants here so the arithmetic at the bottom is re-runnable rather than
	done by hand in a commit message.

	They are also the reason that arithmetic no longer predicts anything. See the bottom of the file.
]]
local NETWEAVE_FPS = 85
local RIVAL_FPS = 133

--[[
	The same encode, timed inside Studio in the same session, so the ratio between this file's VM and
	the one the framerate came from is on record rather than assumed.

	`STUDIO_BEFORE` is measured with the **real** pre-phase-7 writer rather than a stand-in: past
	eight fields `fusedStructWriter` hands back to the loop `structWriter` that preceded it, and the
	loop costs 64.9 ns a value there (58,891 ns at nine fields, 77,277 at twelve). Six fields of it
	is 38,940. The hand-built reconstruction that first answered this said 38,434 — faithful to 1.3%,
	which is worth recording because the reconstruction was the part of this file most likely to be
	wrong and turned out not to be.
]]
local STUDIO_NOW = 29314
local STUDIO_BEFORE = 38940

--[[ What this file printed for the `netweave` rung on the tree before `Serdes.fusedStructWriter`
     existed — the same script, one commit earlier, which is what makes it a number rather than a
     memory (`CLAUDE.md` §5). Check out the parent of the phase 7 commit and run this to reproduce
     it. ]]
local BEFORE = 23992

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

--[[ Deterministic rather than random: `Random` does not exist under lune, and the values only have
     to be in range — nothing here branches on them. ]]
local payload: { Entity } = table.create(ENTITY_COUNT)

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

local FIELDS = { "id", "x", "y", "z", "orientation", "animation" }

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

-- ---------------------------------------------------------------------------------------------
-- The rungs
-- ---------------------------------------------------------------------------------------------

--[[ One frame's worth of packets, so growth happens in the warm-up and never inside a timed pass. ]]
local scratch = buffer.create(PACKETS * PACKET_BYTES)

local function inline()
	local offset = 0

	for _ = 1, PACKETS do
		for index = 1, ENTITY_COUNT do
			local entity = payload[index]

			writeu8(scratch, offset, entity.id)
			writeu8(scratch, offset + 1, entity.x)
			writeu8(scratch, offset + 2, entity.y)
			writeu8(scratch, offset + 3, entity.z)
			writeu8(scratch, offset + 4, entity.orientation)
			writeu8(scratch, offset + 5, entity.animation)

			offset += FIELD_COUNT
		end
	end
end

--[[
	The same, plus what `Serdes.numberWriter` asks of every value: in the declared range, and whole.

	Written out six times rather than looped through a helper, because a helper is a call and the
	call is what the next rung is for. This is the one place in the repository where repeating
	yourself is the measurement.
]]
local function inlineChecked()
	local offset = 0

	for _ = 1, PACKETS do
		for index = 1, ENTITY_COUNT do
			local entity = payload[index]

			local id = entity.id
			if not (id >= 0 and id <= 255) or id % 1 ~= 0 then
				error("[netweave] out of range")
			end

			local x = entity.x
			if not (x >= 0 and x <= 255) or x % 1 ~= 0 then
				error("[netweave] out of range")
			end

			local y = entity.y
			if not (y >= 0 and y <= 255) or y % 1 ~= 0 then
				error("[netweave] out of range")
			end

			local z = entity.z
			if not (z >= 0 and z <= 255) or z % 1 ~= 0 then
				error("[netweave] out of range")
			end

			local orientation = entity.orientation
			if not (orientation >= 0 and orientation <= 255) or orientation % 1 ~= 0 then
				error("[netweave] out of range")
			end

			local animation = entity.animation
			if not (animation >= 0 and animation <= 255) or animation % 1 ~= 0 then
				error("[netweave] out of range")
			end

			writeu8(scratch, offset, id)
			writeu8(scratch, offset + 1, x)
			writeu8(scratch, offset + 2, y)
			writeu8(scratch, offset + 3, z)
			writeu8(scratch, offset + 4, orientation)
			writeu8(scratch, offset + 5, animation)

			offset += FIELD_COUNT
		end
	end
end

local function put()
	for _ = 1, PACKETS do
		Buffer.openBlock(PACKET_BYTES)

		for index = 1, ENTITY_COUNT do
			local entity = payload[index]

			putU8(entity.id)
			putU8(entity.x)
			putU8(entity.y)
			putU8(entity.z)
			putU8(entity.orientation)
			putU8(entity.animation)
		end

		Buffer.closeBlock()
	end
end

local function write()
	for _ = 1, PACKETS do
		for index = 1, ENTITY_COUNT do
			local entity = payload[index]

			writeU8(entity.id)
			writeU8(entity.x)
			writeU8(entity.y)
			writeU8(entity.z)
			writeU8(entity.orientation)
			writeU8(entity.animation)
		end
	end
end

local encode = codec.write

local function netweave()
	for _ = 1, PACKETS do
		encode(payload)
	end
end

-- ---------------------------------------------------------------------------------------------
-- The control: the same design, one lookup later
-- ---------------------------------------------------------------------------------------------

--[[
	`Serdes.fusedStructWriter` with its branch chain replaced by an upvalue holding the same
	function. Everything else — the claim, the unroll, the checks, the offsets — is identical, so
	the difference between this and the `netweave` rung is the fastcall and nothing else.

	It is kept rather than deleted because it is the only evidence for the decision the codec now
	rests on, and because a future reader looking at that branch chain will want to know what it is
	worth before simplifying it away.
]]
local DISPATCH: { [string]: (b: buffer, offset: number, value: number) -> () } = { u8 = buffer.writeu8 }

local function dispatchedWriter(names: { string }): (value: any) -> ()
	local n1, n2, n3 = names[1], names[2], names[3]
	local n4, n5, n6 = names[4], names[5], names[6]
	local a1, a2, a3, a4, a5, a6 = 0, 1, 2, 3, 4, 5
	local write1 = DISPATCH.u8
	local low, high = 0, 255

	return function(value: any)
		local out, at = claim(FIELD_COUNT)

		local v1 = value[n1]
		if v1 == nil or not (v1 >= low and v1 <= high) or v1 % 1 ~= 0 then
			error("[netweave] out of range")
		end
		write1(out, at + a1, v1)

		local v2 = value[n2]
		if v2 == nil or not (v2 >= low and v2 <= high) or v2 % 1 ~= 0 then
			error("[netweave] out of range")
		end
		write1(out, at + a2, v2)

		local v3 = value[n3]
		if v3 == nil or not (v3 >= low and v3 <= high) or v3 % 1 ~= 0 then
			error("[netweave] out of range")
		end
		write1(out, at + a3, v3)

		local v4 = value[n4]
		if v4 == nil or not (v4 >= low and v4 <= high) or v4 % 1 ~= 0 then
			error("[netweave] out of range")
		end
		write1(out, at + a4, v4)

		local v5 = value[n5]
		if v5 == nil or not (v5 >= low and v5 <= high) or v5 % 1 ~= 0 then
			error("[netweave] out of range")
		end
		write1(out, at + a5, v5)

		local v6 = value[n6]
		if v6 == nil or not (v6 >= low and v6 <= high) or v6 % 1 ~= 0 then
			error("[netweave] out of range")
		end
		write1(out, at + a6, v6)
	end
end

local writeDispatched = dispatchedWriter(FIELDS)

local function dispatched()
	for _ = 1, PACKETS do
		Buffer.openBlock(PACKET_BYTES)

		for index = 1, ENTITY_COUNT do
			writeDispatched(payload[index])
		end

		Buffer.closeBlock()
	end
end

--[[ And the shape that lost outright: one claim per struct, then a loop that reads each field's
     name, offset and bounds out of parallel arrays. It needs no unroll and no arity limit, which is
     why it was tried first. ]]
local function rowWriter(names: { string }): (value: any) -> ()
	local count = #names
	local offsets: { number } = table.create(count)
	local mins: { number } = table.create(count)
	local maxs: { number } = table.create(count)
	local writes: { (b: buffer, offset: number, value: number) -> () } = table.create(count)

	for index = 1, count do
		offsets[index] = index - 1
		mins[index] = 0
		maxs[index] = 255
		writes[index] = DISPATCH.u8
	end

	return function(value: any)
		local out, at = claim(count)

		for index = 1, count do
			local field = value[names[index]]

			if field == nil or not (field >= mins[index] and field <= maxs[index]) or field % 1 ~= 0 then
				error("[netweave] out of range")
			end

			writes[index](out, at + offsets[index], field)
		end
	end
end

local writeRow = rowWriter(FIELDS)

local function rows()
	for _ = 1, PACKETS do
		Buffer.openBlock(PACKET_BYTES)

		for index = 1, ENTITY_COUNT do
			writeRow(payload[index])
		end

		Buffer.closeBlock()
	end
end

-- ---------------------------------------------------------------------------------------------
-- Timing
-- ---------------------------------------------------------------------------------------------

type Rung = { name: string, run: () -> (), buffered: boolean }

local rungs: { Rung } = {
	{ name = "inline", run = inline, buffered = false },
	{ name = "inline + range", run = inlineChecked, buffered = false },
	{ name = "put", run = put, buffered = true },
	{ name = "write", run = write, buffered = true },
	{ name = "netweave", run = netweave, buffered = true },
	{ name = "dispatched", run = dispatched, buffered = true },
	{ name = "rows", run = rows, buffered = true },
}

type Result = { name: string, fastest: number, median: number, high: number }

--[[
	**The estimator here is the fastest pass, not the median**, and the reason is the opposite of the
	one that made `Alloc` take a median.

	An allocation figure needs the median because the collector's visit is part of what is being
	measured and a window that missed one is not representative. Elapsed CPU time is not like that:
	the work is deterministic, so noise — a scheduler slice, a collector visit, another process —
	only ever *adds*. The fastest of fifty-one passes is the closest this machine got to running the
	rung and nothing else, and the rungs differ in length by an order of magnitude, which would
	otherwise price the longest one's exposure to interruption as if it were codec work.

	The median and the slowest pass are printed beside it so that claim can be checked rather than
	taken.
]]
local function measure(rung: Rung): Result
	local samples: { number } = table.create(REPEATS)

	--[[ The cursor back to zero without giving up the capacity, which is the reset the send path
	     itself uses for a packet it decided not to keep. `take` would hand back a copy and
	     reallocate, and the allocation would land inside the next pass. ]]
	local function reset()
		if rung.buffered then
			Buffer.rollback(0, 0)
		end
	end

	for _ = 1, WARMUP do
		reset()
		rung.run()
	end

	for index = 1, REPEATS do
		reset()

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

Buffer.rollback(0, 0)

-- ---------------------------------------------------------------------------------------------
-- What it says
-- ---------------------------------------------------------------------------------------------

--[[ The probe checks itself before it reports: a codec that wrote the wrong number of bytes is a
     rung measuring something other than this packet, and a fast wrong answer is the failure mode
     every optimisation in this file could have. ]]
Buffer.take()
Buffer.load(nil)
codec.write(payload)

local produced = (Buffer.take())
local failed = false

if buffer.len(produced) ~= PACKET_BYTES then
	print(`FAIL  the codec wrote {buffer.len(produced)} bytes, not {PACKET_BYTES}`)
	failed = true
end

Buffer.beginRead(produced, nil)
local restored = codec.read()

if
	restored == nil
	or restored[1].id ~= payload[1].id
	or restored[ENTITY_COUNT].z ~= payload[ENTITY_COUNT].z
then
	print("FAIL  the packet did not round-trip")
	failed = true
end

print(
	`        ArrayHeavy encode, {ENTITY_COUNT} entities x {FIELD_COUNT} u8 = {VALUES} values, `
		.. `{PACKETS} packets a pass, {REPEATS} passes`
)
print("")
print("        rung              ns/packet       ns/value      median      slowest")

for _, result in results do
	print(
		`        {string.format("%-16s", result.name)}  {string.format("%9.0f", result.fastest)}      `
			.. `{string.format("%9.1f", result.fastest / VALUES)}   {string.format("%9.0f", result.median)}    `
			.. `{string.format("%9.0f", result.high)}`
	)
end

local inlineCost = byName["inline"]
local checkedCost = byName["inline + range"]
local putCost = byName["put"]
local writeCost = byName["write"]
local netweaveCost = byName["netweave"]
local dispatchedCost = byName["dispatched"]

print("")
print(
	`        the ceiling (generated code): {string.format("%.0f", inlineCost)} ns/packet, and with the `
		.. `schema's own checks {string.format("%.0f", checkedCost)}`
)
print(
	`        netweave: {string.format("%.0f", netweaveCost)} ns/packet — `
		.. `{string.format("%.2f", netweaveCost / inlineCost)}x the ceiling, `
		.. `{string.format("%.2f", netweaveCost / checkedCost)}x the ceiling that checks what it writes`
)

--[[ The control, and the whole reason the branch chain in `Serdes.fusedStructWriter` exists. ]]
print(
	`        naming the primitive instead of looking it up: {string.format("%.0f", dispatchedCost)} -> `
		.. `{string.format("%.0f", netweaveCost)} ns/packet, {string.format(
			"%.2f",
			dispatchedCost / netweaveCost
		)}x`
)

--[[ And the hypothesis M1 wrote down and M2 phase 0 acted on, priced after the fact. It is the only
     rung here that measures code netweave no longer runs, and it is the reason this file exists as
     well as the reason it prints this line: the fix landed, the framerate did not move, and
     `bench/RESULTS.md` still said the cause stood. ]]
print(
	`        the M1 hypothesis, priced: allocate-per-value cost {string.format("%.0f", writeCost - putCost)} `
		.. `ns/packet, {string.format("%.0f", (writeCost - putCost) / writeCost * 100)}% of the pre-M2 encode`
)

--[[
	~~The bridge from a microbenchmark to the number in `bench/RESULTS.md`, and the only reason this
	file can say anything about a framerate at all.~~

	**Withdrawn, by the run it was written to predict.** The argument was: a frame at the matrix's
	load is `PACKETS` encodes plus everything the engine does, the engine half is the same for every
	library in the same Play, so the difference between two libraries' frame times is their encode
	difference — a quantity this probe measures. It predicted a 4.38 ms gap and Studio had measured
	4.21 ms, and that was read as corroboration.

	Then the fused writer removed 1.96 ms of that encode, *measured on Studio's own VM*, and the
	framerate moved by **zero** — 85 against Blink's 133, where it was 84 against 130 before.

	~~So something outside the codec is paying for the gap.~~ **No**: `Config.FRAME_PROBE`, written
	afterwards because neither this file nor the matrix could answer it, puts **54% of that frame
	inside the send loop** and the whole gap against Blink there. The frame is encode-bound and the
	1.96 ms is real; what does not add up is that the frame moved 0.3 ms, and that is open
	(`bench/RESULTS.md`, M4 phase 7).

	The rule this file now carries is the narrow one those two mistakes produced: **a component
	benchmark cannot say what fraction of a frame it owns.** So this section reports and does not
	predict. The encode numbers are what this file is for; the fraction is what `FRAME_PROBE` is for;
	the framerate is what the matrix is for, and the three are printed rather than joined by an
	equals sign.
]]
print("")
print(
	`        on this VM: {BEFORE} -> {string.format("%.0f", netweaveCost)} ns/packet across phase 7 `
		.. `({string.format("%.2f", BEFORE / netweaveCost)}x), which at {PACKETS} packets is `
		.. `{string.format("%.2f", netweaveCost * PACKETS / 1e6)} ms a frame against generated code's `
		.. `{string.format("%.2f", inlineCost * PACKETS / 1e6)} ms`
)
print(
	`        the same encode timed inside Studio: {STUDIO_BEFORE} -> {STUDIO_NOW} ns/packet across `
		.. `phase 7 ({string.format("%.2f", STUDIO_BEFORE / STUDIO_NOW)}x, `
		.. `{string.format("%.2f", (STUDIO_BEFORE - STUDIO_NOW) * PACKETS / 1e6)} ms a frame removed)`
)
print(
	`        and the matrix that followed: {NETWEAVE_FPS} FPS against {RIVAL_FPS} — `
		.. `{string.format("%.2f", (1000 / NETWEAVE_FPS) / (1000 / RIVAL_FPS))}x, unmoved. `
		.. `The frame probe puts 54% of that frame in the send loop; see bench/RESULTS.md.`
)

print("")
print(if failed then "FAIL    profile" else "OK      profile")
