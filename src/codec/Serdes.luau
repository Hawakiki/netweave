--!strict
--!optimize 2

--[=[
	@class Serdes

	Turns an [Ir.Layout] into a pair of closures that write and read one payload.

	**Closure synthesis, not code generation.** netweave has no build step and emits no source.
	Every decision a layout already made — which encoding a number narrowed to, which bit of which
	chunk a boolean owns, whether a length needs a prefix at all — is bound into a function once,
	at definition time, so nothing is re-decided per packet (`RESEARCH §3.6-B5`).

	Internal. Schemas and channels are the public surface.
]=]

--[[
	The asymmetry in this file is deliberate and is the whole security posture:

	  encode  errors loudly. The value came from the game's own code, so a number outside its
	          declared range is a bug, and the alternative is silent wraparound on the wire.
	  decode  never errors. The value came off the wire, and a malicious client must not be able
	          to abort a batch by sending a byte (`RESEARCH §3.8-R`, `DESIGN-API` G4). Every
	          failure is routed through `Buffer.reject` and surfaces as a value from `read`.

	`assert` appears nowhere below. CLAUDE.md §4 reserves it for programmer error, and on this
	path programmer error is already covered by `error` with a message naming the field.
]]

local Buffer = require("./Buffer")
local Ir = require("./Ir")
local Types = require("../types")

type Node = Ir.Node
type Field = Ir.Field
type Scope = Ir.Scope
type Encoding = Types.Encoding

--[[
	Flags are threaded as a parameter rather than held in module state so that a scope is entered
	and left by an ordinary call, and so nothing has to be unwound when a decode is abandoned.
]]
type Flags = { number }
type Writer = (value: any, flags: Flags) -> ()
type Reader = (flags: Flags) -> any

local bor = bit32.bor
local band = bit32.band
local rshift = bit32.rshift

--[[ A node with no flags still takes the parameter; it is cheaper than branching on nil. ]]
local NO_FLAGS: Flags = table.freeze({}) :: any

local UNIT_TOLERANCE = 1e-3

--[[ `table.create` is `{unknown}`, and Luau arrays are invariant. Centralised so the cast is
     written once rather than at every call site. Same helper as `Ir.sized`. ]]
local function sized(count: number): any
	return table.create(count)
end

local function isFinite(value: number): boolean
	--[[ `value == value` is the NaN test; a rejected NaN would otherwise pass a range check by
	     failing every comparison in the wrong direction. ]]
	return value == value and value ~= math.huge and value ~= -math.huge
end

local WRITE_NUMBER: { [string]: (value: number) -> () } = {
	u8 = Buffer.writeU8,
	u16 = Buffer.writeU16,
	u32 = Buffer.writeU32,
	i8 = Buffer.writeI8,
	i16 = Buffer.writeI16,
	i32 = Buffer.writeI32,
	f32 = Buffer.writeF32,
	f64 = Buffer.writeF64,
}

--[[
	The same eight writers, for bytes an enclosing block has already claimed. `Serdes` chooses
	between the two families once per node at closure-build time, from the layout, so nothing
	branches per packet (`src/codec/Buffer.luau`, Blocks).
]]
local PUT_NUMBER: { [string]: (value: number) -> () } = {
	u8 = Buffer.putU8,
	u16 = Buffer.putU16,
	u32 = Buffer.putU32,
	i8 = Buffer.putI8,
	i16 = Buffer.putI16,
	i32 = Buffer.putI32,
	f32 = Buffer.putF32,
	f64 = Buffer.putF64,
}

local READ_NUMBER: { [string]: () -> number } = {
	u8 = Buffer.readU8,
	u16 = Buffer.readU16,
	u32 = Buffer.readU32,
	i8 = Buffer.readI8,
	i16 = Buffer.readI16,
	i32 = Buffer.readI32,
	f32 = Buffer.readF32,
	f64 = Buffer.readF64,
}

--[[ Bitfield chunks are patched after the fact, so they need the by-width dispatch too. ]]
local PATCH_CHUNK: { [number]: (offset: number, value: number) -> () } = {
	[1] = Buffer.patchU8,
	[2] = Buffer.patchU16,
	[4] = Buffer.patchU32,
}

local READ_CHUNK: { [number]: () -> number } = {
	[1] = Buffer.readU8,
	[2] = Buffer.readU16,
	[4] = Buffer.readU32,
}

local claim = Buffer.claim
local reserve = Buffer.reserve
local reject = Buffer.reject
local remaining = Buffer.remaining
local rejected = Buffer.rejected
local openBlock = Buffer.openBlock
local closeBlock = Buffer.closeBlock
local writeString = Buffer.writeString
local readString = Buffer.readString
local writeBuffer = Buffer.writeBuffer
local readBuffer = Buffer.readBuffer
local writeInstance = Buffer.writeInstance
local readInstance = Buffer.readInstance

--[[
	Is this sidecar entry an Instance, asked in a way that works in both places this code runs.

	Inside Roblox the question is exact: `typeof` separates an Instance from a table, and a table is
	precisely what a hostile `FireServer(buffer, { {} })` puts in the slot. Under lune there are no
	Instances at all and the suite stands them in with tables (`CLAUDE.md` §6 on why
	`roblox_runtime` exists), so the strict question would refuse every test that carries one.

	The lune half asks the only thing this reader ever asks of an Instance: **does it answer
	`:IsA`.** That is not an approximation chosen for convenience — it is the exact precondition the
	line below needs, so a stand-in that satisfies it is a stand-in the reader cannot tell from the
	real thing, and a hostile bare table fails it in both places rather than only in Studio.
	`tests/harness.luau` builds the stand-ins so the suite cannot drift from that contract.
]]
local ROBLOX = typeof(game) == "Instance"

local function isInstance(value: any): boolean
	if ROBLOX then
		return typeof(value) == "Instance"
	end

	return type(value) == "table" and type((value :: any).IsA) == "function"
end
local putU8 = Buffer.putU8
local putF32 = Buffer.putF32
local putString = Buffer.putString
local putBuffer = Buffer.putBuffer
local writeF32 = Buffer.writeF32
local readF32 = Buffer.readF32
local writeU8 = Buffer.writeU8
local readU8 = Buffer.readU8

--[[
	Whether the subtree currently being built sits inside a claimed block.

	A build-time flag rather than a parameter threaded through nine builders, and safe because
	synthesis is synchronous: `Serdes.build` runs to completion before anything else can call it. It
	selects `PUT_NUMBER` over `WRITE_NUMBER` and `putString` over `writeString`, and is read only
	while closures are being made — never while one runs.
]]
local blocked = false

local Serdes = {}

local buildWriter: (node: Node) -> Writer
local buildReader: (node: Node) -> Reader

-- -------------------------------------------------------------------------------------------------
-- Scopes
-- -------------------------------------------------------------------------------------------------

--[[
	Reserve, accumulate, backfill. The bitfield sits at the front of its scope but its bits are
	only known once every value in the scope has been visited, so the bytes are reserved first and
	patched last. Doing it the other way — a pre-pass to collect flags, then a write pass — walks
	the value twice.

	The accumulator is allocated once per scope-opening node and reused, which is safe because a
	schema is a tree: a scope is never entered while it is already open. Writers and readers get
	separate arrays anyway, so that reading a packet inside a send is not a hazard.
]]
local function scopedWriter(scope: Scope, inner: Writer): Writer
	local chunks = scope.chunks
	local count = #chunks
	local bytes = scope.bytes
	local accumulator: Flags = table.create(count, 0)

	local patches: { (offset: number, value: number) -> () } = sized(count)
	local offsets: { number } = sized(count)

	for index, chunk in chunks do
		patches[index] = PATCH_CHUNK[chunk.width]
		offsets[index] = chunk.offset
	end

	return function(value: any, _outer: Flags)
		local base = reserve(bytes)

		for index = 1, count do
			accumulator[index] = 0
		end

		inner(value, accumulator)

		for index = 1, count do
			patches[index](base + offsets[index], accumulator[index])
		end
	end
end

local function scopedReader(scope: Scope, inner: Reader): Reader
	local chunks = scope.chunks
	local count = #chunks
	local accumulator: Flags = table.create(count, 0)

	local reads: { () -> number } = sized(count)

	for index, chunk in chunks do
		reads[index] = READ_CHUNK[chunk.width]
	end

	return function(_outer: Flags): any
		--[[ Chunks are contiguous and emitted in offset order, so reading them in order leaves
		     the cursor exactly at the first value. ]]
		for index = 1, count do
			accumulator[index] = reads[index]()
		end

		return inner(accumulator)
	end
end

--[[ Wraps a child that opens a bitfield of its own: a dynamic array's element, a map's key or
     value. Everything else inherits the enclosing scope. ]]
local function writerFor(node: Node): Writer
	local writer = buildWriter(node)
	local scope = node.scope
	return if scope then scopedWriter(scope, writer) else writer
end

local function readerFor(node: Node): Reader
	local reader = buildReader(node)
	local scope = node.scope
	return if scope then scopedReader(scope, reader) else reader
end

-- -------------------------------------------------------------------------------------------------
-- Lengths
-- -------------------------------------------------------------------------------------------------

--[[
	A length that survives the round trip. The prefix is narrowed against the declared span, so a
	byte can carry a count the schema forbids; `checkLength` is where that is caught, and it is
	the single most load-bearing rejection in the codec — everything downstream of it allocates.
]]
local function lengthWriter(node: Node): (count: number, label: string) -> ()
	local exact = node.count

	if exact then
		return function(count: number, label: string)
			if count ~= exact then
				error(`[netweave] {label} must hold exactly {exact}, got {count}`)
			end
		end
	end

	local family: { [string]: (value: number) -> () } = if blocked then PUT_NUMBER else WRITE_NUMBER
	local write = family[node.lengthStorage :: Encoding]
	local offset = node.lengthOffset :: number
	local min = node.min :: number
	local max = node.max :: number

	return function(count: number, label: string)
		if count < min or count > max then
			error(`[netweave] {label} holds {count}, outside the declared {min}..{max}`)
		end

		write(count - offset)
	end
end

--[[ Returns the count, or -1 when the stream did not justify one. -1 rather than nil so callers
     stay on a single numeric path. ]]
local function lengthReader(node: Node): () -> number
	local exact = node.count

	if exact then
		return function(): number
			return exact
		end
	end

	local read = READ_NUMBER[node.lengthStorage :: Encoding]
	local offset = node.lengthOffset :: number
	local min = node.min :: number
	local max = node.max :: number

	return function(): number
		local count = read() + offset

		if count < min or count > max then
			reject("length out of range")
			return -1
		end

		return count
	end
end

-- -------------------------------------------------------------------------------------------------
-- Writers
-- -------------------------------------------------------------------------------------------------

--[[
	Which encodings cannot hold a fraction.

	`buffer.writeu8(3.7)` truncates, and with an offset it is not even truncation: `-0.4` on
	`t.i16(-100, 100)` becomes `99.6`, stores as `99` and reads back as `-1`. The range check passed
	both, so a game that sent a float where it meant an integer got a different number on the far
	side and no report — under a module header that promises the alternative to raising is "silent
	wraparound", which is exactly what it was doing (`PLAN-M3` phase 9).

	The test is captured per node rather than branched per value: a `f32` field pays one upvalue
	read, an integer field pays a modulo, and neither pays a `type()` call.
]]
local FRACTIONAL: { [string]: boolean } = { f32 = true, f64 = true }
table.freeze(FRACTIONAL)

local function numberWriter(node: Node): Writer
	local family: { [string]: (value: number) -> () } = if blocked then PUT_NUMBER else WRITE_NUMBER
	local storage = node.storage :: Encoding
	local write = family[storage]
	local offset = node.offset :: number
	local min = node.min :: number
	local max = node.max :: number
	local integral = not FRACTIONAL[storage]

	if offset == 0 then
		return function(value: any, _flags: Flags)
			if not (value >= min and value <= max) then
				error(`[netweave] {value} is outside the declared range {min}..{max}`)
			end

			if integral and value % 1 ~= 0 then
				error(`[netweave] {value} is not a whole number, and this field is stored as {storage}`)
			end

			write(value)
		end
	end

	return function(value: any, _flags: Flags)
		if not (value >= min and value <= max) then
			error(`[netweave] {value} is outside the declared range {min}..{max}`)
		end

		if integral and value % 1 ~= 0 then
			error(`[netweave] {value} is not a whole number, and this field is stored as {storage}`)
		end

		write(value - offset)
	end
end

local function enumWriter(node: Node): Writer
	local lookup = node.lookup :: { [string]: number }
	local bits = node.bits

	if bits == 0 then
		--[[ One variant carries no information, so it costs no bits. The value is still checked,
		     because sending the wrong name is a bug worth naming. ]]
		return function(value: any, _flags: Flags)
			if lookup[value] == nil then
				error(`[netweave] "{tostring(value)}" is not a variant of this enum`)
			end
		end
	end

	local chunks = node.tagChunks :: { number }
	local masks = node.tagMasks :: { number }

	return function(value: any, flags: Flags)
		local index = lookup[value]

		if index == nil then
			error(`[netweave] "{tostring(value)}" is not a variant of this enum`)
		end

		local tag = index - 1

		for bit = 1, bits do
			if band(rshift(tag, bit - 1), 1) == 1 then
				local chunk = chunks[bit]
				flags[chunk] = bor(flags[chunk], masks[bit])
			end
		end
	end
end

-- -------------------------------------------------------------------------------------------------
-- A struct of numbers, written in one claim
-- -------------------------------------------------------------------------------------------------

--[[
	`PLAN-M4` phase 7, and the only optimisation in this file that came from a measurement rather
	than from reading the generated output of a competitor.

	`bench/profile.luau` takes one `ArrayHeavy` packet — 100 entities of six `u8` — apart rung by
	rung. The ceiling, what Blink and Zap emit, is 2.1 us. netweave was 24.0 us, and the attribution
	is not subtle: 10% is the range and whole-number checks the schema promises, 30% is one call per
	value, and **52% is the closure per value and the struct walk that finds the field to hand it**.
	A field of a six-field struct costs seven calls before a byte is written: the struct's, the
	writer's, and the primitive's under that.

	netweave cannot answer this the way they do. `loadstring` is off in Roblox and a build step is
	the thing this library exists not to need, so there is no generated source to fall back on. What
	is left is to **make the primitive wider rather than the loop shorter**: claim the struct's bytes
	once and write them all, with the offsets computed at declaration time.

	One other shape was priced first and lost outright, and it is written down so it is not tried
	again: claim once but **keep the loop**, reading each field's offset and bounds out of parallel
	arrays. 25.5 us — slower than doing nothing, because the array reads cost more than the calls
	they save. That is what makes the unroll below non-negotiable rather than a matter of taste.

	This lands at 12.7 us against 24.0 under lune, and 29.3 against 38.4 in Studio — **1.9x and
	1.31x**, both measured on the VM they are quoted for.

	~~It predicts the `ArrayHeavy` framerate gap closing from 1.55x to 1.28x.~~ **It did not.** The
	Studio matrix that followed measured 85 FPS against Blink's 133, exactly where it was before.

	The frame probe added afterwards says the frame *is* dominated by this path — 6.27 ms of an
	11.58 ms frame is the send loop, and the whole gap against Blink lives there — and that the
	saving here is 1.96 ms of it. Those two do not add up to 0.3 ms of frame, and the probe that
	settles it has not been run on the pre-phase-7 tree yet (`bench/RESULTS.md`, M4 phase 7).

	So: this comment is a claim about **this function**, measured twice, on two VMs. It is not a
	framerate claim, and the file that is allowed to make one is `bench/RESULTS.md`.

	The unroll is eight blocks in one closure with an early return at each boundary, rather than
	eight builders selected by arity. It is the same code either way; this way it is one thing to
	read and one thing to get right.
]]
--[[
	**A storage as a number, so the write below can be a literal.**

	This is the whole reason the unrolled body reads the way it does, and it took the probe three
	tries to find it. `buffer.writeu8(out, offset, value)` written out is compiled to a *fastcall*:
	the VM performs it inline, without building a call frame. The same function reached through a
	table — held in an upvalue, which is what a schema-driven builder reaches for first — is an
	ordinary call. `bench/profile.luau` keeps that version as its `dispatched` rung, identical in
	every other respect, and prices the difference at **1.6x on the whole packet**: more than every
	other layer of the encode put together, and the reason the first implementation of this returned
	10% against a probe promising 170%.

	So the call site has to name the function, and the schema has to be a branch. Five branches, in
	the order the encodings actually occur, and each of them a fastcall.

	That is also the honest answer to why a code generator wins here at all, and it is checkable
	rather than folklore: Blink's output writes `buffer.writeu8(...)` in as many words
	(`bench/vendor/blink/Client.luau:187`) and so does Zap's (`bench/vendor/zap/Client.luau:1140`).
	It is not that they avoid closures — netweave can too, and `fusedStructWriter` does. It is that a
	generator emits the *name* of the primitive, and until this file did the same, netweave could
	not (`RESEARCH §3.11-GG`).
]]
local STORAGE_CODE: { [string]: number } = {
	u8 = 1,
	u16 = 2,
	u32 = 3,
	f32 = 4,
	f64 = 5,
}

--[[ Beyond this the unroll below stops and the general loop takes over. Eight covers an entity, a
     transform, a stat block and an inventory row; a forty-field struct is a different shape of
     problem and pays one call per field as it always did. ]]
local FUSED_MAX = 8

type Row = {
	name: string,
	at: number,
	min: number,
	max: number,
	offset: number,
	integral: boolean,
	storage: string,
	code: number,
}

local BLANK: Row = {
	name = "",
	at = 0,
	min = 0,
	max = 0,
	offset = 0,
	integral = false,
	storage = "u8",
	code = 1,
}

--[[ Every field, or nothing. A struct with one string in it is not half fusable — the offsets after
     that field are not known until it is written — so the test is over the whole struct. ]]
local function rowsOf(fields: { Field }): ({ Row }?, number)
	local count = #fields

	if count == 0 or count > FUSED_MAX then
		return nil, 0
	end

	local rows: { Row } = sized(count)
	local at = 0

	for index, field in fields do
		local node = field.node
		local size = node.fixedSize
		local storage = node.storage
		local code = if storage then STORAGE_CODE[storage] else nil

		--[[ `bits ~= 0` is the flag-carrying case — a boolean, an enum, an optional's presence bit —
		     and those are written into a scope rather than into bytes, so their position here is not
		     a byte offset at all.

		     A storage with no code is one the branch chain below cannot name, and the fallback is
		     the general writer rather than a guess: `Ir.lowerNumber` produces five of the eight, and
		     a sixth arriving later must be added there deliberately or it keeps today's speed. ]]
		if node.kind ~= "number" or size == nil or size == 0 or node.bits ~= 0 or code == nil then
			return nil, 0
		end

		rows[index] = {
			name = field.name,
			at = at,
			min = node.min :: number,
			max = node.max :: number,
			offset = node.offset :: number,
			integral = not FRACTIONAL[storage :: string],
			storage = storage :: string,
			code = code,
		}

		at += size
	end

	return rows, at
end

--[[
	The cold half of every check below, so the hot half is one branch that is almost always false.

	It re-asks the question rather than being told which test failed, because getting here at all
	means an `error` is about to be raised and the answer is a string built from an interpolation.
	The messages are `numberWriter`'s, word for word: a schema that refuses a value has to say the
	same thing whichever writer refused it.
]]
local function refuseField(row: Row, value: any): ()
	if value == nil then
		error(`[netweave] field "{row.name}" is missing`)
	end

	if not (value >= row.min and value <= row.max) then
		error(`[netweave] {value} is outside the declared range {row.min}..{row.max}`)
	end

	error(`[netweave] {value} is not a whole number, and this field is stored as {row.storage}`)
end

local function fusedStructWriter(fields: { Field }): Writer?
	local rows, size = rowsOf(fields)

	if rows == nil then
		return nil
	end

	local count = #rows

	local r1, r2 = rows[1], rows[2] or BLANK
	local r3, r4 = rows[3] or BLANK, rows[4] or BLANK
	local r5, r6 = rows[5] or BLANK, rows[6] or BLANK
	local r7, r8 = rows[7] or BLANK, rows[8] or BLANK

	local n1, a1, i1, o1, s1, lo1, hi1 = r1.name, r1.at, r1.integral, r1.offset, r1.code, r1.min, r1.max
	local n2, a2, i2, o2, s2, lo2, hi2 = r2.name, r2.at, r2.integral, r2.offset, r2.code, r2.min, r2.max
	local n3, a3, i3, o3, s3, lo3, hi3 = r3.name, r3.at, r3.integral, r3.offset, r3.code, r3.min, r3.max
	local n4, a4, i4, o4, s4, lo4, hi4 = r4.name, r4.at, r4.integral, r4.offset, r4.code, r4.min, r4.max
	local n5, a5, i5, o5, s5, lo5, hi5 = r5.name, r5.at, r5.integral, r5.offset, r5.code, r5.min, r5.max
	local n6, a6, i6, o6, s6, lo6, hi6 = r6.name, r6.at, r6.integral, r6.offset, r6.code, r6.min, r6.max
	local n7, a7, i7, o7, s7, lo7, hi7 = r7.name, r7.at, r7.integral, r7.offset, r7.code, r7.min, r7.max
	local n8, a8, i8, o8, s8, lo8, hi8 = r8.name, r8.at, r8.integral, r8.offset, r8.code, r8.min, r8.max

	--[[
		The claim happens before the first check, so a struct that raises half way through has moved
		the cursor past bytes it never wrote. That is the same contract `Serdes.build` already
		documents — a write that raises leaves the buffer where it left it and the caller rewinds —
		and every caller on the send path does exactly that (`Batch.writeBody`, `Serdes.check`).
	]]
	return function(value: any, _flags: Flags)
		local out, at = claim(size)

		local v1 = value[n1]

		if v1 == nil or not (v1 >= lo1 and v1 <= hi1) or (i1 and v1 % 1 ~= 0) then
			refuseField(r1, v1)
		end

		local to1 = at + a1
		local raw1 = v1 - o1

		if s1 == 1 then
			buffer.writeu8(out, to1, raw1)
		elseif s1 == 2 then
			buffer.writeu16(out, to1, raw1)
		elseif s1 == 3 then
			buffer.writeu32(out, to1, raw1)
		elseif s1 == 4 then
			buffer.writef32(out, to1, raw1)
		else
			buffer.writef64(out, to1, raw1)
		end

		if count < 2 then
			return
		end

		local v2 = value[n2]

		if v2 == nil or not (v2 >= lo2 and v2 <= hi2) or (i2 and v2 % 1 ~= 0) then
			refuseField(r2, v2)
		end

		local to2 = at + a2
		local raw2 = v2 - o2

		if s2 == 1 then
			buffer.writeu8(out, to2, raw2)
		elseif s2 == 2 then
			buffer.writeu16(out, to2, raw2)
		elseif s2 == 3 then
			buffer.writeu32(out, to2, raw2)
		elseif s2 == 4 then
			buffer.writef32(out, to2, raw2)
		else
			buffer.writef64(out, to2, raw2)
		end

		if count < 3 then
			return
		end

		local v3 = value[n3]

		if v3 == nil or not (v3 >= lo3 and v3 <= hi3) or (i3 and v3 % 1 ~= 0) then
			refuseField(r3, v3)
		end

		local to3 = at + a3
		local raw3 = v3 - o3

		if s3 == 1 then
			buffer.writeu8(out, to3, raw3)
		elseif s3 == 2 then
			buffer.writeu16(out, to3, raw3)
		elseif s3 == 3 then
			buffer.writeu32(out, to3, raw3)
		elseif s3 == 4 then
			buffer.writef32(out, to3, raw3)
		else
			buffer.writef64(out, to3, raw3)
		end

		if count < 4 then
			return
		end

		local v4 = value[n4]

		if v4 == nil or not (v4 >= lo4 and v4 <= hi4) or (i4 and v4 % 1 ~= 0) then
			refuseField(r4, v4)
		end

		local to4 = at + a4
		local raw4 = v4 - o4

		if s4 == 1 then
			buffer.writeu8(out, to4, raw4)
		elseif s4 == 2 then
			buffer.writeu16(out, to4, raw4)
		elseif s4 == 3 then
			buffer.writeu32(out, to4, raw4)
		elseif s4 == 4 then
			buffer.writef32(out, to4, raw4)
		else
			buffer.writef64(out, to4, raw4)
		end

		if count < 5 then
			return
		end

		local v5 = value[n5]

		if v5 == nil or not (v5 >= lo5 and v5 <= hi5) or (i5 and v5 % 1 ~= 0) then
			refuseField(r5, v5)
		end

		local to5 = at + a5
		local raw5 = v5 - o5

		if s5 == 1 then
			buffer.writeu8(out, to5, raw5)
		elseif s5 == 2 then
			buffer.writeu16(out, to5, raw5)
		elseif s5 == 3 then
			buffer.writeu32(out, to5, raw5)
		elseif s5 == 4 then
			buffer.writef32(out, to5, raw5)
		else
			buffer.writef64(out, to5, raw5)
		end

		if count < 6 then
			return
		end

		local v6 = value[n6]

		if v6 == nil or not (v6 >= lo6 and v6 <= hi6) or (i6 and v6 % 1 ~= 0) then
			refuseField(r6, v6)
		end

		local to6 = at + a6
		local raw6 = v6 - o6

		if s6 == 1 then
			buffer.writeu8(out, to6, raw6)
		elseif s6 == 2 then
			buffer.writeu16(out, to6, raw6)
		elseif s6 == 3 then
			buffer.writeu32(out, to6, raw6)
		elseif s6 == 4 then
			buffer.writef32(out, to6, raw6)
		else
			buffer.writef64(out, to6, raw6)
		end

		if count < 7 then
			return
		end

		local v7 = value[n7]

		if v7 == nil or not (v7 >= lo7 and v7 <= hi7) or (i7 and v7 % 1 ~= 0) then
			refuseField(r7, v7)
		end

		local to7 = at + a7
		local raw7 = v7 - o7

		if s7 == 1 then
			buffer.writeu8(out, to7, raw7)
		elseif s7 == 2 then
			buffer.writeu16(out, to7, raw7)
		elseif s7 == 3 then
			buffer.writeu32(out, to7, raw7)
		elseif s7 == 4 then
			buffer.writef32(out, to7, raw7)
		else
			buffer.writef64(out, to7, raw7)
		end

		if count < 8 then
			return
		end

		local v8 = value[n8]

		if v8 == nil or not (v8 >= lo8 and v8 <= hi8) or (i8 and v8 % 1 ~= 0) then
			refuseField(r8, v8)
		end

		local to8 = at + a8
		local raw8 = v8 - o8

		if s8 == 1 then
			buffer.writeu8(out, to8, raw8)
		elseif s8 == 2 then
			buffer.writeu16(out, to8, raw8)
		elseif s8 == 3 then
			buffer.writeu32(out, to8, raw8)
		elseif s8 == 4 then
			buffer.writef32(out, to8, raw8)
		else
			buffer.writef64(out, to8, raw8)
		end
	end
end

local function structWriter(node: Node): Writer
	local fields = node.fields :: { Field }
	local count = #fields

	local fused = fusedStructWriter(fields)

	if fused then
		return fused
	end

	local names: { string } = sized(count)
	local writers: { Writer } = sized(count)
	local required: { boolean } = sized(count)

	for index, field in fields do
		names[index] = field.name
		writers[index] = buildWriter(field.node)
		required[index] = field.node.kind ~= "optional"
	end

	return function(value: any, flags: Flags)
		for index = 1, count do
			local field = value[names[index]]

			--[[ Without this the failure is a native error inside `buffer.write*` that names a
			     byte offset instead of a field, which is useless in a schema of forty fields. ]]
			if field == nil and required[index] then
				error(`[netweave] field "{names[index]}" is missing`)
			end

			writers[index](field, flags)
		end
	end
end

local function arrayWriter(node: Node): Writer
	local writeLength = lengthWriter(node)
	local exact = node.count
	local elements = node.elements

	if elements then
		--[[ An exact length whose element carries flags was unrolled: one node per position, each
		     owning its own bit slots, so the writers are not interchangeable. ]]
		local count = #elements
		local writers: { Writer } = sized(count)

		for index, element in elements do
			writers[index] = buildWriter(element)
		end

		return function(value: any, flags: Flags)
			writeLength(#value, "array")

			for index = 1, count do
				writers[index](value[index], flags)
			end
		end
	end

	local writeElement = writerFor(node.element :: Node)

	if exact then
		return function(value: any, flags: Flags)
			writeLength(#value, "array")

			for index = 1, exact do
				writeElement(value[index], flags)
			end
		end
	end

	return function(value: any, flags: Flags)
		local count = #value
		writeLength(count, "array")

		for index = 1, count do
			writeElement(value[index], flags)
		end
	end
end

local function mapWriter(node: Node): Writer
	local writeLength = lengthWriter(node)
	local writeKey = writerFor(node.key :: Node)
	local writeValue = writerFor(node.value :: Node)

	return function(value: any, flags: Flags)
		--[[ A map has no `#`, so the count is a pass of its own. It is written before the entries
		     because the reader has to size its loop before it sees one. ]]
		local count = 0
		for _ in value do
			count += 1
		end

		writeLength(count, "map")

		for key, entry in value do
			writeKey(key, flags)
			writeValue(entry, flags)
		end
	end
end

function buildWriter(node: Node): Writer
	local kind = node.kind

	if kind == "boolean" then
		local chunk = node.chunkIndex :: number
		local mask = node.mask :: number

		--[[
			A boolean field takes a boolean, and this used to take anything.

			`if value then` is truthiness, so `t.boolean` accepted `0`, `""` and `"false"` and put
			`true` on the wire for two of them. That is a silent type coercion across a wire whose
			whole purpose is that the type on the far side is the type that was declared — and
			`nw.validate` decides "conforms" by running this writer, so a DataStore row reading
			`{ admin = "false" }` came back branded `Trusted<T>` and truthy (`PLAN-M3` phase 9).

			Written as two comparisons rather than a `type()` call: the common path is one, `false`
			is two, and nothing else reaches the wire.
		]]
		return function(value: any, flags: Flags)
			if value == true then
				flags[chunk] = bor(flags[chunk], mask)
			elseif value ~= false then
				error(`[netweave] a boolean field was given {typeof(value)}`)
			end
		end
	elseif kind == "number" then
		return numberWriter(node)
	elseif kind == "string" then
		local writeLength = lengthWriter(node)
		local bytes: (value: string, length: number) -> () = if blocked then putString else writeString

		return function(value: any, _flags: Flags)
			local length = #value
			writeLength(length, "string")
			bytes(value, length)
		end
	elseif kind == "buffer" then
		local writeLength = lengthWriter(node)
		local bytes: (value: buffer, length: number) -> () = if blocked then putBuffer else writeBuffer

		return function(value: any, _flags: Flags)
			local length = buffer.len(value)
			writeLength(length, "buffer")
			bytes(value, length)
		end
	elseif kind == "vector2" then
		local f32: (value: number) -> () = if blocked then putF32 else writeF32

		return function(value: any, _flags: Flags)
			f32(value.X)
			f32(value.Y)
		end
	elseif kind == "vector3" then
		local f32: (value: number) -> () = if blocked then putF32 else writeF32

		return function(value: any, _flags: Flags)
			f32(value.X)
			f32(value.Y)
			f32(value.Z)
		end
	elseif kind == "color3" then
		local u8: (value: number) -> () = if blocked then putU8 else writeU8

		return function(value: any, _flags: Flags)
			u8(math.clamp(math.round(value.R * 255), 0, 255))
			u8(math.clamp(math.round(value.G * 255), 0, 255))
			u8(math.clamp(math.round(value.B * 255), 0, 255))
		end
	elseif kind == "cframe" then
		local f32: (value: number) -> () = if blocked then putF32 else writeF32

		return function(value: any, _flags: Flags)
			local position = value.Position
			f32(position.X)
			f32(position.Y)
			f32(position.Z)

			--[[ Axis times angle: one vector carries the whole rotation, and the identity falls
			     out as the zero vector rather than needing a special case on either side. ]]
			local axis, angle = value:ToAxisAngle()
			f32(axis.X * angle)
			f32(axis.Y * angle)
			f32(axis.Z * angle)
		end
	elseif kind == "instance" then
		return function(value: any, _flags: Flags)
			if value == nil then
				error("[netweave] a non-optional instance field is nil")
			end

			--[[ Anything non-nil used to go into the sidecar, so `nw.validate` said a number
			     conformed to `t.instance("Player")` and branded it. The reader refuses the same
			     shape on the way in; this is the send side of that check. ]]
			if not isInstance(value) then
				error(`[netweave] an instance field was given {typeof(value)}`)
			end

			writeInstance(value)
		end
	elseif kind == "enum" then
		return enumWriter(node)
	elseif kind == "optional" then
		local chunk = node.chunkIndex :: number
		local mask = node.mask :: number
		local writeInner = buildWriter(node.inner :: Node)

		return function(value: any, flags: Flags)
			if value == nil then
				return
			end

			flags[chunk] = bor(flags[chunk], mask)
			writeInner(value, flags)
		end
	elseif kind == "array" then
		return arrayWriter(node)
	elseif kind == "map" then
		return mapWriter(node)
	elseif kind == "struct" then
		return structWriter(node)
	end

	error(`[netweave] no writer for a "{kind}"`)
end

-- -------------------------------------------------------------------------------------------------
-- Readers
-- -------------------------------------------------------------------------------------------------

local function numberReader(node: Node): Reader
	local read = READ_NUMBER[node.storage :: Encoding]
	local offset = node.offset :: number
	local min = node.min :: number
	local max = node.max :: number
	local storage = node.storage

	if storage == "f32" or storage == "f64" then
		return function(_flags: Flags): any
			local value = read()

			--[[ A float arrives unnarrowed, so the range is a claim about the sender rather than a
			     property of the encoding. NaN fails this comparison in both directions, which is
			     the intent — it is the value that makes every downstream check pass by accident. ]]
			if not (value >= min and value <= max) then
				reject("number out of range")
				return min
			end

			return value
		end
	end

	return function(_flags: Flags): any
		--[[ Storage is unsigned and offset is the declared minimum, so the lower bound cannot be
		     violated. The upper one can: a span of 200 is carried in a byte that holds 255. ]]
		local value = read() + offset

		if value > max then
			reject("number out of range")
			return min
		end

		return value
	end
end

local function enumReader(node: Node): Reader
	local variants = node.variants :: { string }
	local bits = node.bits
	local first = variants[1]

	if bits == 0 then
		return function(_flags: Flags): any
			return first
		end
	end

	local chunks = node.tagChunks :: { number }
	local masks = node.tagMasks :: { number }

	return function(flags: Flags): any
		local tag = 0

		for bit = 1, bits do
			if band(flags[chunks[bit]], masks[bit]) ~= 0 then
				tag = bor(tag, bit32.lshift(1, bit - 1))
			end
		end

		--[[ The tag has room the schema does not use whenever the variant count is not a power of
		     two: three variants are two bits, and a sender can put 3 in them. ]]
		local name = variants[tag + 1]

		if name == nil then
			reject("unknown enum variant")
			return first
		end

		return name
	end
end

local function structReader(node: Node): Reader
	local fields = node.fields :: { Field }
	local count = #fields
	local template = node.template :: { [string]: boolean }

	local names: { string } = sized(count)
	local readers: { Reader } = sized(count)

	for index, field in fields do
		names[index] = field.name
		readers[index] = buildReader(field.node)
	end

	return function(flags: Flags): any
		--[[ Cloning a pre-sized template is why decode never rehashes. ByteNet does the same and
		     it is the one axis where it beat both code generators in M0 (`RESEARCH §3.7-M`). An
		     absent optional assigns nil, which drops the key without resizing. ]]
		local result = table.clone(template) :: any

		for index = 1, count do
			result[names[index]] = readers[index](flags)
		end

		return result
	end
end

local function arrayReader(node: Node): Reader
	local readLength = lengthReader(node)
	local elements = node.elements

	if elements then
		local count = #elements
		local readers: { Reader } = sized(count)

		for index, element in elements do
			readers[index] = buildReader(element)
		end

		return function(flags: Flags): any
			local result = sized(count)

			for index = 1, count do
				result[index] = readers[index](flags)
			end

			return result
		end
	end

	local element = node.element :: Node
	local readElement = readerFor(element)

	--[[
		The smallest number of bytes one element can occupy, when that is known at build time. A
		static element has an exact size; a dynamic one does not, and answers nil.
	]]
	local perElement = element.fixedSize

	return function(flags: Flags): any
		local count = readLength()

		if count < 0 then
			return {}
		end

		--[[
			A claim is not paid for until the bytes behind it exist.

			~~The length was already bounded, so this is a cost question, not a safety one.~~
			**Struck through in M3 phase 0.** A cost an attacker controls and does not pay for is an
			amplification: a two-byte packet claiming 65535 elements bought a 65535-slot table, at
			839x the cost of an honest packet, and *was then correctly rejected*. The rejection was
			free. The allocation was not (`PLAN-M3` D-4).

			Bounding the claim against the bytes that remain costs one comparison on the honest path
			and turns the hostile one into a refusal before anything is allocated. Zap has the same
			shape without the recovery — `_refsrc/zap/zap/src/irgen/des.rs:298` allocates from the
			claimed length too, and its generated `read` does no bounds checking at all, so the
			equivalent packet raises and takes the batch.
		]]
		local available = remaining()

		if perElement and perElement > 0 and count * perElement > available then
			reject(
				`array claims {count} elements, needing {count * perElement} bytes, and {available} remain`
			)
			return {}
		end

		--[[
			For a dynamic element there is no size to multiply by, so the *allocation* is capped at
			the bytes available instead. An element cannot be conjured from no bytes, so this never
			shortens an honest decode — and it bounds the hostile one to the packet's own length,
			which is what the amplification was.
		]]
		local result = sized(if count < available then count else available)

		for index = 1, count do
			--[[ Bail on the first rejection rather than reading `max` elements of garbage. ]]
			if rejected() then
				return result
			end

			result[index] = readElement(flags)
		end

		return result
	end
end

local function mapReader(node: Node): Reader
	local readLength = lengthReader(node)
	local key = node.key :: Node
	local value = node.value :: Node
	local readKey = readerFor(key)
	local readValue = readerFor(value)

	--[[ A map never had the allocation bug an array had — it starts from `{}` and grows — but the
	     same bound gives the same refusal, so a claim past the packet is reported the same way
	     whichever container it arrived in (`PLAN-M3` D-4). ]]
	local perEntry = if key.fixedSize and value.fixedSize then key.fixedSize + value.fixedSize else nil

	return function(flags: Flags): any
		local count = readLength()

		if count < 0 then
			return {}
		end

		local available = remaining()

		if perEntry and perEntry > 0 and count * perEntry > available then
			reject(`map claims {count} entries, needing {count * perEntry} bytes, and {available} remain`)
			return {}
		end

		local result: any = {}

		for _ = 1, count do
			if rejected() then
				return result
			end

			local entryKey = readKey(flags)
			local entryValue = readValue(flags)

			--[[ A rejected key is a default, and defaults collide: writing them would fabricate an
			     entry the sender never sent. ]]
			if not rejected() then
				result[entryKey] = entryValue
			end
		end

		return result
	end
end

function buildReader(node: Node): Reader
	local kind = node.kind

	if kind == "boolean" then
		local chunk = node.chunkIndex :: number
		local mask = node.mask :: number

		return function(flags: Flags): any
			return band(flags[chunk], mask) ~= 0
		end
	elseif kind == "number" then
		return numberReader(node)
	elseif kind == "string" then
		local readLength = lengthReader(node)

		return function(_flags: Flags): any
			local length = readLength()

			if length < 0 then
				return ""
			end

			return readString(length)
		end
	elseif kind == "buffer" then
		local readLength = lengthReader(node)

		return function(_flags: Flags): any
			local length = readLength()

			if length < 0 then
				return buffer.create(0)
			end

			return readBuffer(length)
		end
	elseif kind == "vector2" then
		return function(_flags: Flags): any
			local x, y = readF32(), readF32()

			if not (isFinite(x) and isFinite(y)) then
				reject("non-finite vector2")
				return Vector2.zero
			end

			return Vector2.new(x, y)
		end
	elseif kind == "vector3" then
		local unit = node.unit

		return function(_flags: Flags): any
			local x, y, z = readF32(), readF32(), readF32()

			if not (isFinite(x) and isFinite(y) and isFinite(z)) then
				reject("non-finite vector3")
				return Vector3.zero
			end

			local value = Vector3.new(x, y, z)

			--[[
				A direction that is not a direction is an exploit primitive: a caller that trusts
				`t.unitVector3` and multiplies by a range gets an arbitrary displacement out of a
				magnitude of 400. The schema said unit, so the decoder enforces unit.
			]]
			if unit and math.abs(value.Magnitude - 1) > UNIT_TOLERANCE then
				reject("vector3 is not a unit vector")
				return Vector3.zAxis
			end

			return value
		end
	elseif kind == "color3" then
		return function(_flags: Flags): any
			return Color3.fromRGB(readU8(), readU8(), readU8())
		end
	elseif kind == "cframe" then
		return function(_flags: Flags): any
			local px, py, pz = readF32(), readF32(), readF32()
			local ax, ay, az = readF32(), readF32(), readF32()

			if
				not (
					isFinite(px)
					and isFinite(py)
					and isFinite(pz)
					and isFinite(ax)
					and isFinite(ay)
					and isFinite(az)
				)
			then
				reject("non-finite cframe")
				return CFrame.identity
			end

			local rotation = Vector3.new(ax, ay, az)
			local angle = rotation.Magnitude

			if angle < 1e-6 then
				return CFrame.new(px, py, pz)
			end

			return CFrame.new(px, py, pz) * CFrame.fromAxisAngle(rotation / angle, angle)
		end
	elseif kind == "instance" then
		local class = node.class

		return function(_flags: Flags): any
			local value = readInstance()

			--[[
				Three failures, not one. A nil means the sidecar ran out, which is a framing problem.
				A wrong class means the sender picked an instance the schema does not admit, which
				is the whole reason `t.instance("Sound")` exists — a client can reference anything
				it can see, so the class is checked here or it is not checked at all.

				And the entry has to **be** an Instance before either of those questions can be
				asked. `FireServer(buffer, { {} })` puts a table in the slot, and `value:IsA(class)`
				on a table raises — on the receive path, out of the read phase, which is guarantee
				G4 broken by the one piece of wire data that does not travel in the buffer. The
				sidecar is a client argument like any other and had no check at all until M3 phase 9.

				A bare `t.instance` was worse: with no class to test, whatever the client sent was
				handed to the handler as an Instance. `12345` reached game code with no report.
			]]
			if value == nil then
				reject("missing instance")
				return nil
			end

			if not isInstance(value) then
				reject(`the sidecar holds a {typeof(value)} where an instance was declared`)
				return nil
			end

			if class and not value:IsA(class) then
				reject("instance is not a " .. class)
				return nil
			end

			return value
		end
	elseif kind == "enum" then
		return enumReader(node)
	elseif kind == "optional" then
		local chunk = node.chunkIndex :: number
		local mask = node.mask :: number
		local readInner = buildReader(node.inner :: Node)

		return function(flags: Flags): any
			if band(flags[chunk], mask) == 0 then
				return nil
			end

			return readInner(flags)
		end
	elseif kind == "array" then
		return arrayReader(node)
	elseif kind == "map" then
		return mapReader(node)
	elseif kind == "struct" then
		return structReader(node)
	end

	error(`[netweave] no reader for a "{kind}"`)
end

-- -------------------------------------------------------------------------------------------------

--[=[
	@interface Codec
	@within Serdes
	.framing "static" | "counted" -- whether the transport has to length-prefix this payload
	.fixedSize number? -- payload bytes, when they never vary
	.instances number? -- sidecar entries always consumed, when that never varies
	.write (value: any) -> ()
	.read () -> (any, string?)
	.check (value: any) -> string? -- nil when the value satisfies the schema
]=]
export type Codec = {
	framing: "static" | "counted",
	fixedSize: number?,
	maxSize: number,
	instances: number?,
	--[[ Kept rather than discarded, because the protocol hash is taken over the lowered tree
	     (`src/api/Protocol.luau`) and lowering a second time at seal would be the same work done
	     twice to save one field. ]]
	layout: Ir.Layout,
	write: (value: any) -> (),
	read: () -> (any, string?),
	check: (value: any) -> string?,
}

--[=[
	@within Serdes
	@function build
	@param layout Layout -- from `Ir.lower`
	@return Codec

	Binds a layout into a write/read pair. Call this once per channel, at definition time.

	```lua
	local codec = Serdes.build(Ir.lower(t.struct({ x = t.u8, y = t.u8 })))

	codec.write({ x = 1, y = 2 })
	local bytes, instances = Buffer.take()

	Buffer.beginRead(bytes, instances)
	local value, failure = codec.read()
	```

	`write` appends to the outgoing buffer and leaves framing to the transport, which is what
	`framing` and `fixedSize` are for.

	:::caution
	`write` raises on a value the schema forbids — that is game code passing a bad number, and
	silent wraparound would be worse. `read` never raises: it returns `nil` and a reason.
	:::

	:::caution
	A `write` that raises leaves behind whatever bytes it emitted before the bad field. The caller
	owns the rewind: park the buffer with `Buffer.save` first, or `take` and discard. `check` below
	does the former, and a transport must do one of them — a partial payload left in the batch is a
	packet nobody can decode.
	:::
]=]
function Serdes.build(layout: Ir.Layout): Codec
	local root = layout.root
	local scope = layout.scope
	local fixedSize = layout.fixedSize

	--[[
		A payload whose size is known claims all of it in one `allocate` and fills it with the
		`put*` writers, which skip the bounds and growth checks the space has already paid for.

		`blocked` is set for the whole of synthesis and cleared after, so every closure below this
		point is built against the right family. It is restored rather than assigned `false`
		because `Serdes.build` can be re-entered — `Trust.validate` builds a codec lazily, and a
		schema can be lowered while another is being built.
	]]
	local outer = blocked
	blocked = fixedSize ~= nil

	local write = buildWriter(root)
	local read = buildReader(root)

	if scope then
		write = scopedWriter(scope, write)
		read = scopedReader(scope, read)
	end

	blocked = outer

	if fixedSize then
		local inner = write
		local size = fixedSize

		--[[ Annotated `Writer` rather than left to inference: an anonymous function whose return
		     type is exactly `()` makes `pcall(write, ...)` in `check` below resolve to one value. ]]
		local blockWrite: Writer = function(value: any, flags: Flags)
			openBlock(size)
			inner(value, flags)
			closeBlock()
		end

		write = blockWrite
	end

	--[[
		`pcall` of a function whose return pack is empty is typed as returning `boolean` alone, so
		destructuring the error out of it does not check. The alias widens the pack without changing
		what runs, and is hoisted here so `check` does not build one per call.
	]]
	local attempt: (...any) -> ...any = write

	return {
		framing = layout.framing,
		fixedSize = layout.fixedSize,
		maxSize = layout.maxSize,
		instances = layout.instances,
		layout = layout,

		write = function(value: any)
			write(value, NO_FLAGS)
		end,

		read = function(): (any, string?)
			--[[ Cleared per payload, not per batch: G5 says one malformed packet must not stop the
			     rest, and a rejection carried forward would do exactly that. ]]
			Buffer.clearRejection()

			local value = read(NO_FLAGS)
			local failure = rejected()

			if failure then
				return nil, failure
			end

			return value, nil
		end,

		--[[
			The encoder is the only statement of what a value must satisfy, so `check` runs it rather
			than restating its rules. A second implementation drifts, and the two disagree exactly
			where it matters: on the boundary cases nobody re-tests.

			The cost is a real serialisation into a parked buffer, which is why this is not on the hot
			path. The receive path never needs it — a payload that decoded is valid by construction.
		]]
		check = function(value: any): string?
			--[[ `mark`/`rollback` rather than `save`/`load`, because only one of the two clears the
			     sidecar. `load` restores `instanceCount` and leaves the entries the trial write
			     appended past it, so validating a payload carrying an Instance kept a reference to
			     it until the next write happened to overwrite that slot — found by an external
			     review (M3 phase 9). It also stops allocating a record per call. ]]
			local used, instances = Buffer.mark()
			local ok, failure = pcall(attempt, value, NO_FLAGS)
			Buffer.rollback(used, instances)

			if ok then
				return nil
			end

			--[[ `error()` prefixes a script position; the caller wants the reason, not the line. ]]
			local reason = tostring(failure)
			return (string.gsub(reason, "^.-:%d+: ", "", 1))
		end,
	}
end

--[=[
	@within Serdes
	@function fromSchema
	@param descriptor Descriptor -- a type from `netweave.types`
	@return Codec

	`Serdes.build(Ir.lower(descriptor))`, for callers that have a schema rather than a layout.
]=]
function Serdes.fromSchema(descriptor: Types.Descriptor): Codec
	return Serdes.build(Ir.lower(descriptor))
end

--[=[
	@within Serdes
	@function nodeCodec
	@param node Node -- a node from a lowered layout, with its bits already assigned
	@return (value: any, flags: { number }) -> ()
	@return (flags: { number }) -> any
	@private

	The writer and reader for **one node**, for a caller that is assembling a payload this module
	does not know the shape of.

	`src/replication/Delta.luau` is the only such caller: a patch interleaves its own decisions —
	did this field change, is it there now — with ordinary values, so it walks the tree itself and
	asks for a codec at each leaf rather than reimplementing fourteen kinds.

	:::caution
	The block optimisation is **off** for these. `Serdes.build` turns it on when a layout is
	statically sized, because then one `allocate` covers the whole payload and every writer below it
	can skip its own bounds check. A patch is never statically sized — that is what a patch is — so
	a node built here uses the growth-checked writers, and mixing one built here into a blocked
	layout would write past the block.
	:::
]=]
function Serdes.nodeCodec(node: Ir.Node): (Writer, Reader)
	local outer = blocked
	blocked = false

	local write = writerFor(node)
	local read = readerFor(node)

	blocked = outer
	return write, read
end

return Serdes
