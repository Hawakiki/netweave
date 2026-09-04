--!strict
--!optimize 2

--[=[
	@class Batch

	The envelope from `docs/WIRE-FORMAT.md`, and the only place that knows it.

	```
	batch  := version:u8  packet*
	packet := id:varint  frame  payload
	frame  := [length:varint if counted]  [instances:varint if variable]
	```

	One version byte per batch rather than per packet: at 200 packets a batch it costs 0.005 bytes
	each, and it is what lets the format have a v2 (§1).

	Internal.
]=]

--[[
	This file is guarantee G5. Everything else in the transport can be rewritten around it; the
	length prefix is the thing that lets a refused packet be stepped over instead of taking the
	rest of the batch with it. Blink and Zap have no length field, so one bad packet costs
	everything behind it (`RESEARCH §3.8-R`).

	**Both framing modes resynchronise, not just `counted`.** A `static` channel's size is fixed at
	definition time and the id names the channel, so once the id resolves the reader already knows
	where the packet ends — no prefix needed to skip it. `bench/src/shared/Modes/netweave.luau`
	said otherwise and stopped the batch on a refused `static` packet; that was a limitation of the
	stand-in, not of the format.

	What genuinely cannot be recovered is an **unresolvable id**. Without a channel there is no
	framing, so there is no way to know where the packet ends, and the batch stops. That is the one
	honest limit and it is reported rather than hidden.
]]

local Buffer = require("../codec/Buffer")

local Batch = {}

--[=[
	@prop VERSION number
	@within Batch

	Wire format v1. A batch whose first byte is anything else is refused whole — a peer speaking a
	different version is a deploy problem, not a packet problem.
]=]
Batch.VERSION = 1

--[[
	One byte holds a varint up to 127. A `counted` payload longer than that needs the reservation
	widened after the fact, which is what `Buffer.shift` is for; it happens only on large payloads
	and never on the small ones that dominate.
]]
local ONE_BYTE_MAX = 127
local TWO_BYTE_MAX = 16383

--[=[
	@interface Sink
	@within Batch
	.resolve (id: number) -> any -- the channel with that wire id, or nil
	.admit (channel: any, bytes: number) -> string? -- nil to decode it, or a reason to refuse
	.deliver (channel: any, value: any, bytes: number) -> ()
	.refuse (channel: any?, stage: string, reason: string, bytes: number) -> ()

	What [Batch.read] calls as it walks a batch. Every member is resolved once by the caller and
	held, so nothing here allocates per packet.

	`admit` runs **before** the payload is decoded. That ordering is the point: a packet over its
	budget costs an id read and a seek rather than a full deserialisation, so refusing is cheaper
	than accepting and a flood cannot be amplified into work (`PLAN-M2` R-2).
]=]
export type Sink = {
	resolve: (id: number) -> any,
	admit: (channel: any, bytes: number) -> string?,
	deliver: (channel: any, value: any, bytes: number) -> (),
	refuse: (channel: any?, stage: string, reason: string, bytes: number) -> (),
}

-- ---------------------------------------------------------------------------------------------
-- Writing
-- ---------------------------------------------------------------------------------------------

--[=[
	@within Batch
	@function begin

	Writes the version byte if this buffer has not been started yet. Called before every packet;
	the emptiness check is what makes it once per batch rather than once per packet.
]=]
function Batch.begin()
	if Buffer.used() == 0 then
		Buffer.writeU8(Batch.VERSION)
	end
end

--[[
	A varint whose value is not known until the bytes it measures have been written.

	Reserve one byte, write, then patch — and widen if the value turned out not to fit. The widen
	moves everything after the reservation, so the two reservations in a frame are patched from the
	back: the instance count first, then the length, whose value counts payload bytes and is
	therefore unaffected by a shift that happens after it.
]]
local function patchVarint(at: number, value: number)
	if value <= ONE_BYTE_MAX then
		Buffer.patchU8(at, value)
		return
	end

	if value > TWO_BYTE_MAX then
		--[[ 16,383 bytes is far past a `RemoteEvent`'s useful payload and past the 908-byte
		     unreliable limit; a schema that reaches it is a design problem, not a runtime one. ]]
		error(`[netweave] a packet field of {value} does not fit two varint bytes`)
	end

	Buffer.shift(at + 1, 1)
	Buffer.patchU8(at, bit32.bor(bit32.band(value, 0x7F), 0x80))
	Buffer.patchU8(at + 1, bit32.rshift(value, 7))
end

--[=[
	@within Batch
	@function writeBody
	@param channel Channel
	@param value any

	The packet without the version byte, for a caller that is building one packet on its own rather
	than appending to a batch.

	The fan-out path needs this: it serialises once into a buffer of its own and copies the bytes
	into each recipient, and a version byte in the scratch would have to be stripped on the way in —
	an offset to get wrong on every broadcast for no gain.
]=]
function Batch.writeBody(channel: any, value: any)
	--[[
		A packet boundary is where a block left open by a raising encode gets cleaned up. Without
		this, the length byte reserved below would be taken from that block's stale cursor — and
		`Buffer.reserve` is block-aware precisely so that a bitfield inside a block works, so the one
		that leaks is the one that matters.
	]]
	Buffer.discardBlock()
	Buffer.writeVarint(channel.id)

	local codec = channel.codec
	local counted = codec.framing == "counted"
	local variable = codec.instances == nil

	local lengthAt = if counted then Buffer.reserve(1) else -1
	local instancesAt = if variable then Buffer.reserve(1) else -1

	local payloadStart = Buffer.used()
	local instancesStart = Buffer.instancesWritten()

	codec.write(value)

	local length = Buffer.used() - payloadStart

	--[[ Back to front: widening the instance count moves the payload but not the length byte in
	     front of it, and `length` counts payload bytes only, so it stays correct either way. ]]
	if variable then
		patchVarint(instancesAt, Buffer.instancesWritten() - instancesStart)
	end

	if counted then
		patchVarint(lengthAt, length)
	end
end

--[=[
	@within Batch
	@function writePacket
	@param channel Channel
	@param value any

	Appends one packet to the current outgoing buffer, version byte included if it is the first.

	Raises if the value does not satisfy the schema — that is the encode-side posture, and the
	caller owns the rewind (`Serdes.Codec.write`).
]=]
function Batch.writePacket(channel: any, value: any)
	Batch.begin()
	Batch.writeBody(channel, value)
end

-- ---------------------------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------------------------

--[=[
	@within Batch
	@function read
	@param packed buffer
	@param instances { Instance }?
	@param sink Sink

	Walks a batch, delivering what decodes and reporting what does not.

	Nothing here raises. Every failure is a value handed to `sink.refuse`, because the bytes came
	off the wire and a malicious client must not be able to abort the loop (`DESIGN-API.md` G4).
]=]
function Batch.read(packed: buffer, instances: { Instance }?, sink: Sink)
	local size = buffer.len(packed)

	if size == 0 then
		return
	end

	Buffer.beginRead(packed, instances)

	local sidecar = if instances then #instances else 0
	local version = Buffer.readU8()

	if Buffer.rejected() or version ~= Batch.VERSION then
		sink.refuse(nil, "parse", `batch version {version} is not {Batch.VERSION}`, size)
		return
	end

	while Buffer.cursor() < size do
		Buffer.setLimit(size)

		local packetStart = Buffer.cursor()
		local id = Buffer.readVarint()

		if Buffer.rejected() then
			sink.refuse(nil, "parse", "truncated channel id", size - packetStart)
			return
		end

		local channel = sink.resolve(id)

		if not channel then
			--[[ The one unrecoverable case. Without a channel there is no framing, so the end of
			     this packet is unknowable and everything behind it is unreachable. ]]
			sink.refuse(nil, "parse", `unknown channel id {id}`, size - packetStart)
			return
		end

		local codec = channel.codec
		local instanceCount = codec.instances
		local payloadLength

		if codec.framing == "counted" then
			payloadLength = Buffer.readVarint()

			if Buffer.rejected() then
				sink.refuse(channel, "parse", "truncated packet length", size - packetStart)
				return
			end
		else
			payloadLength = codec.fixedSize
		end

		if instanceCount == nil then
			instanceCount = Buffer.readVarint()

			if Buffer.rejected() then
				sink.refuse(channel, "parse", "truncated instance count", size - packetStart)
				return
			end
		end

		local payloadStart = Buffer.cursor()
		local payloadEnd = payloadStart + payloadLength

		if payloadEnd > size then
			--[[ A length that runs off the end of the batch. Refusing the packet is not enough:
			     the boundary it claims does not exist, so there is nothing to resynchronise on. ]]
			sink.refuse(channel, "parse", "packet length runs past the batch", size - packetStart)
			return
		end

		local instanceStart = Buffer.instanceCursor()

		--[[
			The sidecar's version of the same check, and it is a security one rather than a
			robustness one.

			A packet is stepped over by advancing the instance cursor past what it claimed, so a
			sender who overstates the claim moves the cursor past entries that belong to the packets
			behind it — and those packets then decode successfully while holding **another packet's
			instances**. Handing a handler the wrong Instance is worse than handing it nothing, and
			it would not look like a failure from either side.

			An overstated claim is provably a lie, because the sidecar's length is known. There is
			no way to recover the association from that point, so the batch stops.
		]]
		if instanceStart + instanceCount > sidecar then
			sink.refuse(channel, "parse", "instance count runs past the sidecar", size - packetStart)
			return
		end
		local bytes = payloadEnd - packetStart

		--[[ Everything from here is recoverable: the packet's end is known, so whatever happens
		     the loop can step over it and carry on. ]]
		local denial = sink.admit(channel, bytes)

		--[[
			The declared length against the channel's ceiling, before a byte of the payload is decoded.

			The ceiling comes from the schema rather than from the game: every netweave type is
			bounded, so `t.struct({ origin = t.vector3, seq = t.u16 })` can never be more than fourteen
			bytes and a packet claiming more is provably a lie. `RESEARCH §3.7-F` records that no
			surveyed library checks a payload size at all, and the reason is that they would have to ask
			the author for the number — here the schema already knows it (`PLAN-M3` D-5).

			After `admit`, not before. An oversized packet still crossed the wire and still cost the
			server a read, so it spends the sender's budget like any other; checking first would let a
			flood of provably invalid packets run free of the limiter built to stop floods.
		]]
		if not denial then
			local ceiling = channel.maxBytes

			if ceiling and payloadLength > ceiling then
				denial = `payload claims {payloadLength} bytes, over the {ceiling} this channel can hold`
			end
		end

		if denial then
			sink.refuse(channel, "budget", denial, bytes)
		else
			Buffer.setLimit(payloadEnd)

			local value, failure = codec.read()

			if failure then
				sink.refuse(channel, "parse", failure, bytes)
			else
				sink.deliver(channel, value, bytes)
			end
		end

		--[[
			Step over the packet, whatever happened to it, and clear the rejection before the next
			id is read.

			The clear is not tidiness. A rejection is sticky, so without it the *next* packet's id
			read reports the previous packet's failure and the batch stops — the exact failure the
			length prefix is paid for, reintroduced by the code meant to honour it. It was found in
			`bench/envelope.luau` first and reintroduced here on the way out of the benchmark, which
			is why `tests/transport_runtime.luau` pins it.
		]]
		Buffer.setLimit(size)
		Buffer.seek(payloadEnd)
		Buffer.seekInstances(instanceStart + instanceCount)
		Buffer.clearRejection()
	end
end

return Batch
