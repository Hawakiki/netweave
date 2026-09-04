--!strict
--!optimize 2

--[=[
	@class CodecBuffer

	The byte layer. Everything netweave sends passes through one outgoing buffer and everything it
	receives through one incoming cursor.

	This is internal — schemas and channels are the public surface — but it is documented because
	its two rules explain shapes that look strange from the outside.

	**Nothing here throws on incoming data.** A read past the end of the packet returns a zero and
	records a rejection; the caller checks once at the packet boundary rather than after every
	field. A malicious client must not be able to abort a batch by sending a short packet
	(`docs/DESIGN-API.md` G4).

	**Outgoing state is global, with an explicit save/load swap.** That is not an accident of
	convenience: it is how per-player multiplexing works, and it is what Blink and Zap both do.
]=]

--[[
	Global rather than threaded through every call: a write is then one upvalue access instead of a
	parameter push plus a field index, and per-player buffers are a `save`/`load` swap rather than
	a parameter everything has to carry (`RESEARCH §3.7-I`).

	ByteNet's mistake was doing this asymmetrically — global on write, cursor-passing on read — so
	the two halves of its codec do not resemble each other. Both halves here are global.

	Consequence: the compiled closures live in a *different* module and reach these through
	function calls, so each primitive costs one call. ByteNet pays the same and M0 measured it
	competitive.

	**M1 phase 6 measured it and the call was not competitive on large payloads.** netweave encoded
	`ArrayHeavy` at 85 FPS against Blink's 144, and the cause was one level below this note: every
	primitive called `allocate` as well, so a 600-byte packet paid 1,200 calls rather than 600. The
	`put*` family below removes the second one. Moving closure synthesis into this module, so the
	buffer state becomes an upvalue and the first call goes too, remains available and remains a
	measurement away rather than a guess away.
]]

local Codec = {}

local INITIAL_SIZE = 64
local VARINT_MAX_BYTES = 5

local outgoing = buffer.create(INITIAL_SIZE)
local outgoingSize = INITIAL_SIZE
local outgoingUsed = 0
local outgoingInstances: { Instance } = {}
local outgoingInstanceCount = 0

local incoming = buffer.create(0)
local incomingCursor = 0
--[[ The end of the *packet*, not of the batch. A corrupt inner length must not read into the
     next packet's bytes, let alone off the end of the buffer. ]]
local incomingLimit = 0
local incomingInstances: { Instance } = {}
local incomingInstanceCursor = 0
local rejection: string? = nil

--[=[
	@interface Save
	@within CodecBuffer
	.buffer buffer
	.size number
	.used number
	.instances { Instance }
	.instanceCount number

	A parked outgoing buffer. The server keeps one of these per player and swaps between them.
]=]
export type Save = {
	buffer: buffer,
	size: number,
	used: number,
	instances: { Instance },
	instanceCount: number,
}

-- ---------------------------------------------------------------------------------------------
-- Outgoing
-- ---------------------------------------------------------------------------------------------

--[=[
	@within CodecBuffer
	@function allocate
	@param length number
	@return number -- the offset the caller may write at

	Reserves `length` bytes and returns where they start.

	:::caution
	Allocate before you touch the buffer. `buffer.writeu16(outgoing, allocate(2), value)` evaluates
	`outgoing` before the call that may replace it with a larger one, and then writes into the old
	buffer — silently, until a growth happens to land mid-packet.
	:::

	Growth doubles. Blink grows by 1.5x and Zap by 2x; doubling costs at most one wasted copy per
	frame and keeps the amortised cost flat under the saturation loads the benchmark applies.
]=]
local function allocate(length: number): number
	local offset = outgoingUsed
	local needed = offset + length

	if needed > outgoingSize then
		local size = outgoingSize
		repeat
			size *= 2
		until size >= needed

		local grown = buffer.create(size)
		buffer.copy(grown, 0, outgoing, 0, offset)

		outgoing = grown
		outgoingSize = size
	end

	outgoingUsed = needed
	return offset
end

Codec.allocate = allocate

-- ---------------------------------------------------------------------------------------------
-- Blocks
-- ---------------------------------------------------------------------------------------------

--[[
	A block is a run of bytes whose total size is known before the first one is written, claimed in
	one `allocate` so that everything inside it can skip the bookkeeping.

	This is `PLAN-M1` D-2's first layout pass, and it was missing until M2. `Ir.lower` has always
	computed `fixedSize`; nothing read it, so a 100-entity `ArrayHeavy` packet made **600 separate
	allocations** — six hundred bounds checks, growth checks and cursor stores for six hundred
	bytes, and 120,000 of them a frame at the benchmark's load. Blink and Zap emit one allocation
	for a block and then write at `offset + k` (`RESEARCH §3.7-D`, §3.8-T).

	Inside a block the buffer cannot grow, because the space is already claimed. That is what makes
	the `put*` writers below safe without a bounds check.

	**A block does not survive an error, and it must not.** Encode raises on a value the schema
	forbids — that is the security posture, not an exception — and a raise between `openBlock` and
	`closeBlock` leaves the block open with no one to close it. Every later payload would then write
	through a stale cursor into space nobody claimed. So the state is self-healing: `openBlock`
	starts fresh rather than nesting, and `load` and `take` clear it, which covers the transport
	because both are how a payload boundary is crossed. Found by `tests/serdes_runtime.luau`, which
	has a refusal test immediately before a byte-count assertion.
]]
local blockCursor = 0
local blockDepth = 0

--[=[
	@within CodecBuffer
	@function openBlock
	@param length number -- exact bytes the block will contain
	@return number -- the offset the block starts at

	Claims `length` bytes and switches the `put*` writers on. Every write until the matching
	[CodecBuffer.closeBlock] lands inside the claim, in order, with no further allocation.

	Blocks do not nest. Opening one starts it fresh, which is what makes a block left open by a
	raising encode harmless rather than corrupting.

	:::caution
	A block must be filled **exactly**. `closeBlock` raises if it was not, because a short block
	leaves the cursor before the end of the claim and every subsequent byte lands one place too
	early — which a symmetric reader would read back without complaint.
	:::
]=]
function Codec.openBlock(length: number): number
	local base = allocate(length)
	blockCursor = base
	blockDepth = 1

	return base
end

--[=[
	@within CodecBuffer
	@function closeBlock

	Ends the innermost block, and checks that it was filled exactly.
]=]
function Codec.closeBlock()
	blockDepth = 0

	--[[
		`allocate` already moved `outgoingUsed` to the end of the claim, so the two agreeing is the
		whole invariant. They disagree only if a writer wrote fewer bytes than the layout said it
		would, which is a codec bug that corrupts the wire silently — the reader is symmetric and
		would read the wrong bytes back from the same wrong place without failing (`PLAN-M2` R-4).
	]]
	if blockCursor ~= outgoingUsed then
		local shortfall = outgoingUsed - blockCursor
		blockCursor = outgoingUsed
		error(`[netweave] a fixed-size block was short by {shortfall} bytes; this is a codec bug`)
	end
end

--[=[
	@within CodecBuffer
	@function discardBlock

	Forgets any open block without checking that it was filled.

	[CodecBuffer.closeBlock] is the ordinary way out and it verifies the claim; this is for the
	other way out. An encode that raises on a value the schema forbids — the ordinary posture, not
	an exception — leaves a block open with nobody to close it, and the next thing to call
	[CodecBuffer.reserve] would then take its bytes from a stale cursor. A packet boundary is where
	that gets cleaned up.
]=]
function Codec.discardBlock()
	blockDepth = 0
end

--[=[
	@within CodecBuffer
	@function writeU8
	@param value number
]=]
local function writeU8(value: number)
	local offset = allocate(1)
	buffer.writeu8(outgoing, offset, value)
end

Codec.writeU8 = writeU8

--[=[
	@within CodecBuffer
	@function writeU16
	@param value number
]=]
function Codec.writeU16(value: number)
	local offset = allocate(2)
	buffer.writeu16(outgoing, offset, value)
end

--[=[
	@within CodecBuffer
	@function writeU32
	@param value number
]=]
function Codec.writeU32(value: number)
	local offset = allocate(4)
	buffer.writeu32(outgoing, offset, value)
end

--[=[
	@within CodecBuffer
	@function writeI8
	@param value number
]=]
function Codec.writeI8(value: number)
	local offset = allocate(1)
	buffer.writei8(outgoing, offset, value)
end

--[=[
	@within CodecBuffer
	@function writeI16
	@param value number
]=]
function Codec.writeI16(value: number)
	local offset = allocate(2)
	buffer.writei16(outgoing, offset, value)
end

--[=[
	@within CodecBuffer
	@function writeI32
	@param value number
]=]
function Codec.writeI32(value: number)
	local offset = allocate(4)
	buffer.writei32(outgoing, offset, value)
end

--[=[
	@within CodecBuffer
	@function writeF32
	@param value number
]=]
function Codec.writeF32(value: number)
	local offset = allocate(4)
	buffer.writef32(outgoing, offset, value)
end

--[=[
	@within CodecBuffer
	@function writeF64
	@param value number
]=]
function Codec.writeF64(value: number)
	local offset = allocate(8)
	buffer.writef64(outgoing, offset, value)
end

--[=[
	@within CodecBuffer
	@function writeString
	@param value string
	@param length number -- byte count, already known to the caller

	Writes the bytes only. The length prefix is the schema's business, because its width depends on
	the declared bound.
]=]
function Codec.writeString(value: string, length: number)
	local offset = allocate(length)
	buffer.writestring(outgoing, offset, value, length)
end

--[=[
	@within CodecBuffer
	@function writeBuffer
	@param value buffer
	@param length number
]=]
function Codec.writeBuffer(value: buffer, length: number)
	local offset = allocate(length)
	buffer.copy(outgoing, offset, value, 0, length)
end

--[=[
	@within CodecBuffer
	@function writeVarint
	@param value number -- a non-negative integer below 2^32

	LEB128. One byte below 128, two below 16384.

	Used for channel ids and packet lengths, which is what removes the 256-channel ceiling both
	Blink and Zap have (`docs/WIRE-FORMAT.md` §3).
]=]
function Codec.writeVarint(value: number)
	while value >= 0x80 do
		writeU8(bit32.bor(bit32.band(value, 0x7F), 0x80))
		value = bit32.rshift(value, 7)
	end

	writeU8(value)
end

--[=[
	@within CodecBuffer
	@function writeInstance
	@param value Instance

	Appends to the sidecar array. Instances cannot live in a buffer, so they travel as the remote's
	second argument and their position is implied by write order (`RESEARCH §3.6-B3`).
]=]
function Codec.writeInstance(value: Instance)
	outgoingInstanceCount += 1
	outgoingInstances[outgoingInstanceCount] = value
end

-- ---------------------------------------------------------------------------------------------
-- Block writers
-- ---------------------------------------------------------------------------------------------

--[=[
	@within CodecBuffer
	@function putU8
	@param value number

	Writes at the block cursor. Valid only between [CodecBuffer.openBlock] and
	[CodecBuffer.closeBlock], where the space is already claimed.

	There is one of these for every `write*` that takes a fixed number of bytes. They exist to
	remove a call, not a branch: `writeU8` costs a call into `allocate` on top of its own, and that
	second call is charged six hundred times for one `ArrayHeavy` packet. `Serdes` picks between the
	two families once, at closure-build time, from the layout.
]=]
local function putU8(value: number)
	local offset = blockCursor
	blockCursor = offset + 1
	buffer.writeu8(outgoing, offset, value)
end

Codec.putU8 = putU8

--[=[
	@within CodecBuffer
	@function putU16
	@param value number
]=]
function Codec.putU16(value: number)
	local offset = blockCursor
	blockCursor = offset + 2
	buffer.writeu16(outgoing, offset, value)
end

--[=[
	@within CodecBuffer
	@function putU32
	@param value number
]=]
function Codec.putU32(value: number)
	local offset = blockCursor
	blockCursor = offset + 4
	buffer.writeu32(outgoing, offset, value)
end

--[=[
	@within CodecBuffer
	@function putI8
	@param value number
]=]
function Codec.putI8(value: number)
	local offset = blockCursor
	blockCursor = offset + 1
	buffer.writei8(outgoing, offset, value)
end

--[=[
	@within CodecBuffer
	@function putI16
	@param value number
]=]
function Codec.putI16(value: number)
	local offset = blockCursor
	blockCursor = offset + 2
	buffer.writei16(outgoing, offset, value)
end

--[=[
	@within CodecBuffer
	@function putI32
	@param value number
]=]
function Codec.putI32(value: number)
	local offset = blockCursor
	blockCursor = offset + 4
	buffer.writei32(outgoing, offset, value)
end

--[=[
	@within CodecBuffer
	@function putF32
	@param value number
]=]
local function putF32(value: number)
	local offset = blockCursor
	blockCursor = offset + 4
	buffer.writef32(outgoing, offset, value)
end

Codec.putF32 = putF32

--[=[
	@within CodecBuffer
	@function putF64
	@param value number
]=]
function Codec.putF64(value: number)
	local offset = blockCursor
	blockCursor = offset + 8
	buffer.writef64(outgoing, offset, value)
end

--[=[
	@within CodecBuffer
	@function putString
	@param value string
	@param length number
]=]
function Codec.putString(value: string, length: number)
	local offset = blockCursor
	blockCursor = offset + length
	buffer.writestring(outgoing, offset, value, length)
end

--[=[
	@within CodecBuffer
	@function putBuffer
	@param value buffer
	@param length number
]=]
function Codec.putBuffer(value: buffer, length: number)
	local offset = blockCursor
	blockCursor = offset + length
	buffer.copy(outgoing, offset, value, 0, length)
end

--[=[
	@within CodecBuffer
	@function reserve
	@param length number
	@return number -- the offset to patch later

	Claims bytes now to fill in later. A bitfield's value is not known until every flag in its
	scope has been visited, so its slot is reserved on the way in and written on the way out
	(`docs/WIRE-FORMAT.md` §5).
]=]
function Codec.reserve(length: number): number
	if blockDepth > 0 then
		--[[ Inside a block the space is already claimed, so a reservation is a cursor step. One
		     branch per scope rather than per field: scopes open at a payload root and at dynamic
		     array elements, never at a value. ]]
		local offset = blockCursor
		blockCursor = offset + length
		return offset
	end

	return allocate(length)
end

--[=[
	@within CodecBuffer
	@function patchU8
	@param offset number
	@param value number
]=]
function Codec.patchU8(offset: number, value: number)
	buffer.writeu8(outgoing, offset, value)
end

--[=[
	@within CodecBuffer
	@function patchU16
	@param offset number
	@param value number
]=]
function Codec.patchU16(offset: number, value: number)
	buffer.writeu16(outgoing, offset, value)
end

--[=[
	@within CodecBuffer
	@function patchU32
	@param offset number
	@param value number
]=]
function Codec.patchU32(offset: number, value: number)
	buffer.writeu32(outgoing, offset, value)
end

--[=[
	@within CodecBuffer
	@function shift
	@param from number -- absolute offset of the first byte to move
	@param by number -- how many bytes to open up

	Opens `by` bytes at `from`, moving everything after it along.

	This exists for one case and should stay that way: a `counted` packet reserves one byte for its
	length before the payload is written, and a payload of 128 bytes or more needs two. Widening
	the reservation after the fact is cheaper than the alternatives — serialising into a scratch
	buffer and copying costs a move on **every** counted packet, while this costs one only on the
	large ones.

	:::caution
	Absolute offsets taken before the shift are stale afterwards if they sit at or past `from`.
	:::
]=]
function Codec.shift(from: number, by: number)
	local moving = outgoingUsed - from

	--[[ Grows first, so the destination exists before anything is moved into it. `buffer.copy`
	     handles an overlapping move on one buffer — verified under lune, not assumed. ]]
	allocate(by)

	if moving > 0 then
		buffer.copy(outgoing, from + by, outgoing, from, moving)
	end
end

--[=[
	@within CodecBuffer
	@function instancesWritten
	@return number

	How many instances the outgoing sidecar holds. A packet that wants to record its own instance
	count reads this before and after writing its payload.
]=]
function Codec.instancesWritten(): number
	return outgoingInstanceCount
end

--[=[
	@within CodecBuffer
	@function seekInstances
	@param position number

	Moves the incoming sidecar cursor, the way [CodecBuffer.seek] moves the byte cursor. A refused
	packet has to take its instances with it, or every instance after it is read against the wrong
	field.
]=]
function Codec.seekInstances(position: number)
	incomingInstanceCursor = position
end

--[=[
	@within CodecBuffer
	@function used
	@return number -- bytes written so far
]=]
function Codec.used(): number
	return outgoingUsed
end

--[=[
	@within CodecBuffer
	@function save
	@return Save

	Parks the outgoing buffer so another can take its place. The server serialises a broadcast once
	and then swaps between per-player buffers to copy it (`RESEARCH §3.7-E`).
]=]
function Codec.save(): Save
	return {
		buffer = outgoing,
		size = outgoingSize,
		used = outgoingUsed,
		instances = outgoingInstances,
		instanceCount = outgoingInstanceCount,
	}
end

--[=[
	@within CodecBuffer
	@function load
	@param saved Save? -- nil starts a fresh, empty buffer
]=]
function Codec.load(saved: Save?)
	blockDepth = 0

	if saved then
		outgoing = saved.buffer
		outgoingSize = saved.size
		outgoingUsed = saved.used
		outgoingInstances = saved.instances
		outgoingInstanceCount = saved.instanceCount
		return
	end

	outgoing = buffer.create(INITIAL_SIZE)
	outgoingSize = INITIAL_SIZE
	outgoingUsed = 0
	outgoingInstances = {}
	outgoingInstanceCount = 0
end

--[=[
	@within CodecBuffer
	@function take
	@return buffer -- an exact-size copy
	@return { Instance }

	Hands over what has been written and resets. The copy is unavoidable: the growable buffer is
	larger than its contents, and a remote must not carry the slack.
]=]
function Codec.take(): (buffer, { Instance })
	blockDepth = 0

	local packed = buffer.create(outgoingUsed)
	buffer.copy(packed, 0, outgoing, 0, outgoingUsed)

	--[[ `table.create` yields `{unknown}`, and Luau arrays are invariant, so the cast is the only
	     way to pre-size the destination rather than growing it element by element. ]]
	local instances = (table.create(outgoingInstanceCount) :: any) :: { Instance }
	table.move(outgoingInstances, 1, outgoingInstanceCount, 1, instances)

	Codec.load(nil)
	return packed, instances
end

-- ---------------------------------------------------------------------------------------------
-- Incoming
-- ---------------------------------------------------------------------------------------------

--[=[
	@within CodecBuffer
	@function beginRead
	@param source buffer
	@param instances { Instance }?

	Points the reader at a freshly arrived batch and clears any previous rejection.
]=]
function Codec.beginRead(source: buffer, instances: { Instance }?)
	incoming = source
	incomingCursor = 0
	incomingLimit = buffer.len(source)
	incomingInstances = instances or {}
	incomingInstanceCursor = 0
	rejection = nil
end

--[=[
	@within CodecBuffer
	@function setLimit
	@param position number

	Bounds every subsequent read at `position`, which is where the current packet ends.

	Without this a corrupt inner length reads into the next packet — or past the buffer, where
	`buffer.readu8` throws and takes the whole batch with it.
]=]
function Codec.setLimit(position: number)
	incomingLimit = math.min(position, buffer.len(incoming))
end

--[=[
	@within CodecBuffer
	@function limit
	@return number
]=]
function Codec.limit(): number
	return incomingLimit
end

--[=[
	@within CodecBuffer
	@function cursor
	@return number
]=]
function Codec.cursor(): number
	return incomingCursor
end

--[=[
	@within CodecBuffer
	@function seek
	@param position number

	Moves the cursor, clamped to the buffer. Used to skip a packet that failed to decode.
]=]
function Codec.seek(position: number)
	incomingCursor = math.clamp(position, 0, buffer.len(incoming))
end

--[=[
	@within CodecBuffer
	@function remaining
	@return number -- readable bytes before the limit
]=]
function Codec.remaining(): number
	return incomingLimit - incomingCursor
end

--[=[
	@within CodecBuffer
	@function reject
	@param reason string

	Records that the packet being read is not decodable. The first reason wins, because it is the
	one that describes what actually went wrong; everything after it is a consequence.
]=]
function Codec.reject(reason: string)
	if not rejection then
		rejection = reason
	end
end

--[=[
	@within CodecBuffer
	@function rejected
	@return string? -- the reason, or nil if the packet is still good
]=]
function Codec.rejected(): string?
	return rejection
end

--[=[
	@within CodecBuffer
	@function clearRejection
]=]
function Codec.clearRejection()
	rejection = nil
end

--[=[
	@within CodecBuffer
	@function ensure
	@param length number
	@return boolean

	True if `length` more bytes are readable. Records a rejection and returns false otherwise.

	Call this once for a statically sized run rather than once per field — knowing a subtree's
	exact size up front is the whole point of the layout pass.
]=]
function Codec.ensure(length: number): boolean
	if incomingCursor + length > incomingLimit then
		Codec.reject("truncated")
		return false
	end

	return true
end

--[=[
	@within CodecBuffer
	@function readU8
	@return number -- 0 if the read would run past the limit
]=]
function Codec.readU8(): number
	if incomingCursor + 1 > incomingLimit then
		Codec.reject("truncated")
		return 0
	end

	local value = buffer.readu8(incoming, incomingCursor)
	incomingCursor += 1
	return value
end

--[=[
	@within CodecBuffer
	@function readU16
	@return number
]=]
function Codec.readU16(): number
	if incomingCursor + 2 > incomingLimit then
		Codec.reject("truncated")
		return 0
	end

	local value = buffer.readu16(incoming, incomingCursor)
	incomingCursor += 2
	return value
end

--[=[
	@within CodecBuffer
	@function readU32
	@return number
]=]
function Codec.readU32(): number
	if incomingCursor + 4 > incomingLimit then
		Codec.reject("truncated")
		return 0
	end

	local value = buffer.readu32(incoming, incomingCursor)
	incomingCursor += 4
	return value
end

--[=[
	@within CodecBuffer
	@function readI8
	@return number
]=]
function Codec.readI8(): number
	if incomingCursor + 1 > incomingLimit then
		Codec.reject("truncated")
		return 0
	end

	local value = buffer.readi8(incoming, incomingCursor)
	incomingCursor += 1
	return value
end

--[=[
	@within CodecBuffer
	@function readI16
	@return number
]=]
function Codec.readI16(): number
	if incomingCursor + 2 > incomingLimit then
		Codec.reject("truncated")
		return 0
	end

	local value = buffer.readi16(incoming, incomingCursor)
	incomingCursor += 2
	return value
end

--[=[
	@within CodecBuffer
	@function readI32
	@return number
]=]
function Codec.readI32(): number
	if incomingCursor + 4 > incomingLimit then
		Codec.reject("truncated")
		return 0
	end

	local value = buffer.readi32(incoming, incomingCursor)
	incomingCursor += 4
	return value
end

--[=[
	@within CodecBuffer
	@function readF32
	@return number
]=]
function Codec.readF32(): number
	if incomingCursor + 4 > incomingLimit then
		Codec.reject("truncated")
		return 0
	end

	local value = buffer.readf32(incoming, incomingCursor)
	incomingCursor += 4
	return value
end

--[=[
	@within CodecBuffer
	@function readF64
	@return number
]=]
function Codec.readF64(): number
	if incomingCursor + 8 > incomingLimit then
		Codec.reject("truncated")
		return 0
	end

	local value = buffer.readf64(incoming, incomingCursor)
	incomingCursor += 8
	return value
end

--[=[
	@within CodecBuffer
	@function readString
	@param length number
	@return string -- empty if the read would run past the limit
]=]
function Codec.readString(length: number): string
	if incomingCursor + length > incomingLimit then
		Codec.reject("truncated")
		return ""
	end

	local value = buffer.readstring(incoming, incomingCursor, length)
	incomingCursor += length
	return value
end

--[=[
	@within CodecBuffer
	@function readBuffer
	@param length number
	@return buffer
]=]
function Codec.readBuffer(length: number): buffer
	if incomingCursor + length > incomingLimit then
		Codec.reject("truncated")
		return buffer.create(0)
	end

	local value = buffer.create(length)
	buffer.copy(value, 0, incoming, incomingCursor, length)
	incomingCursor += length
	return value
end

--[=[
	@within CodecBuffer
	@function readVarint
	@return number

	Rejects rather than looping forever on a run of continuation bytes: five is all a 32-bit value
	can need, and a sixth means the stream is not what it claims to be.
]=]
function Codec.readVarint(): number
	local result = 0
	local shift = 0

	for _ = 1, VARINT_MAX_BYTES do
		local byte = Codec.readU8()
		result = bit32.bor(result, bit32.lshift(bit32.band(byte, 0x7F), shift))

		if bit32.band(byte, 0x80) == 0 then
			return result
		end

		shift += 7
	end

	Codec.reject("varint too long")
	return 0
end

--[=[
	@within CodecBuffer
	@function readInstance
	@return Instance? -- nil when the sidecar is exhausted

	Consumes the next instance in write order. A packet that is skipped must skip its instances
	too, or every later packet reads the wrong ones.
]=]
function Codec.readInstance(): Instance?
	incomingInstanceCursor += 1
	return incomingInstances[incomingInstanceCursor]
end

--[=[
	@within CodecBuffer
	@function skipInstances
	@param count number
]=]
function Codec.skipInstances(count: number)
	incomingInstanceCursor += count
end

--[=[
	@within CodecBuffer
	@function instanceCursor
	@return number
]=]
function Codec.instanceCursor(): number
	return incomingInstanceCursor
end

return Codec
