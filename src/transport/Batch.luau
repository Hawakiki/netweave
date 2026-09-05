--!strict
--!optimize 2

--[=[
	@class Batch

	The envelope from `docs/WIRE-FORMAT.md`, and the only place that knows it.

	```
	batch       := version:u8  packet*
	packet      := id:varint  [correlation if query]  frame  payload
	frame       := [length:varint if counted]  [instances:varint if variable]

	correlation := call:varint                -- a request, read by the side that answers
	             | call:varint  status:u8     -- a reply, read by the side that called
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
	.answers boolean -- true where a query packet is a request: the server
	.admit (channel: any, bytes: number) -> (string?, string?) -- nil to decode it, or a reason and its stage
	.deliver (channel: any, value: any, bytes: number, call: number?) -> ()
	.reply (channel: any, call: number, status: number, value: any?, bytes: number) -> ()
	.hello (hash: number) -> () -- a peer's protocol hash, off a control packet
	.refuse (channel: any?, stage: string, reason: string, bytes: number, call: number?) -> ()

	What [Batch.read] calls as it walks a batch. Every member is resolved once by the caller and
	held, so nothing here allocates per packet.

	`admit` runs **before** the payload is decoded. That ordering is the point: a packet over its
	budget costs an id read and a seek rather than a full deserialisation, so refusing is cheaper
	than accepting and a flood cannot be amplified into work (`PLAN-M2` R-2).
]=]
export type Sink = {
	resolve: (id: number) -> any,
	--[[ Whether a query packet arriving here is a **request**. True on the server, false on the
	     client, and a property of the endpoint rather than of the packet — which is what lets one
	     wire id carry both directions of a query without a byte to say which. ]]
	answers: boolean,
	--[[ nil to decode the packet, or a reason and the stage to report it at. The stage is the
	     sink's to choose because the same refusal point serves two of them: over the rate is
	     `budget`, and a peer on a protocol this one does not share is `protocol`. ]]
	admit: (channel: any, bytes: number) -> (string?, string?),
	deliver: (channel: any, value: any, bytes: number, call: number?) -> (),
	reply: (channel: any, call: number, status: number, value: any?, bytes: number) -> (),
	--[[ A peer's protocol hash, off a control packet. Once per session per peer, in the first batch
	     it sends. ]]
	hello: (hash: number) -> (),
	refuse: (channel: any?, stage: string, reason: string, bytes: number, call: number?) -> (),
}

--[=[
	@prop HELLO number
	@within Batch

	The control kinds carried on channel id 0, which is reserved (`WIRE-FORMAT.md` §3).

	`HELLO` is a peer announcing the hash of its own declarations, once, in its first batch.
]=]
--[[
	A control packet carries its body length, and an unknown kind is skipped rather than fatal.

	Id 0 is reserved "for the handshake, and anything v2 needs", and a reserved slot that cannot be
	extended without breaking every v1 reader is not reserved for anything. The length is what makes
	a kind this build has never heard of steppable — three bytes of overhead, once per session,
	against having to bump the batch version to add a control message.
]]
local HELLO = 1

Batch.HELLO = HELLO

--[=[
	@prop OK number
	@within Batch

	The reply statuses. `OK` carries an answer behind it; every other code ends the packet at the
	status byte.

	| Code | Meaning | What the caller can do |
	|---|---|---|
	| `OK` | the answer follows | use it |
	| `REFUSED` | a policy said no, or the rate budget did | do not retry with the same input |
	| `FAILED` | the handler raised, or the answer did not encode | report a bug |
	| `UNHANDLED` | nothing is attached to answer this channel | wire up `:handle` |
	| `BUSY` | this player already holds every call slot the server will | back off and retry |
]=]
--[[
	Codes, not the server's reason string.

	A refusal's reason is written for the game that owns the server: it names the policy, the field,
	sometimes the player. Sending it to the client would publish the authorization model to the
	machine that model exists to distrust, one denied request at a time. The caller learns *that* it
	was refused and which class of thing went wrong, which is all it can act on; the reason itself
	goes to the observer on the server, where the game can read it (`PLAN-M3` D-12).
]]
local OK = 0

Batch.OK = OK
Batch.REFUSED = 1
Batch.FAILED = 2
Batch.UNHANDLED = 3
Batch.BUSY = 4

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
--[[
	The frame and the payload, for whichever codec the direction calls for.

	A query writes its `args` codec one way and its `returns` codec the other, and everything from
	the frame down is identical between them — so it is written once here rather than twice, which
	is also what stops the two from drifting apart.
]]
local function writeFramed(codec: any, value: any)
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

function Batch.writeBody(channel: any, value: any)
	--[[
		A packet boundary is where a block left open by a raising encode gets cleaned up. Without
		this, the length byte reserved below would be taken from that block's stale cursor — and
		`Buffer.reserve` is block-aware precisely so that a bitfield inside a block works, so the one
		that leaks is the one that matters.
	]]
	Buffer.discardBlock()
	Buffer.writeVarint(channel.id)
	writeFramed(channel.codec, value)
end

--[=[
	@within Batch
	@function writeRequest
	@param channel Channel
	@param call number -- the caller's id for this call, echoed back in the reply
	@param value any

	A query going out from the side that called. The same packet as any other but for the call id,
	which sits between the channel id and the frame.

	The id is framing rather than payload on purpose. A `counted` channel's length prefix counts the
	bytes the schema produced, so the derived byte ceiling stays a statement about the schema and
	does not have to be adjusted by however many bytes this particular call id took to write.
]=]
function Batch.writeRequest(channel: any, call: number, value: any)
	Batch.begin()
	Buffer.discardBlock()
	Buffer.writeVarint(channel.id)
	Buffer.writeVarint(call)
	writeFramed(channel.codec, value)
end

--[=[
	@within Batch
	@function writeReply
	@param channel Channel
	@param call number -- the id the caller sent
	@param status number -- `Batch.OK`, and the answer follows; anything else ends the packet
	@param value any? -- the answer, when the status is `Batch.OK`

	The answer going back. A non-`OK` status ends the packet at the status byte: no frame, no
	payload.

	The alternative was a zero-length payload, which a `counted` schema can express and a `static`
	one cannot — a refused reply on a schema fixed at forty bytes would have had to carry forty
	bytes of nothing. Ending the packet is uniform across both framings and stays resynchronisable,
	because by then the reader has already read everything it needs to know where the packet ends.
]=]
function Batch.writeReply(channel: any, call: number, status: number, value: any?)
	Batch.begin()
	Buffer.discardBlock()
	Buffer.writeVarint(channel.id)
	Buffer.writeVarint(call)
	Buffer.writeU8(status)

	if status == Batch.OK then
		writeFramed(channel.responseCodec, value)
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

--[=[
	@within Batch
	@function writeHello
	@param hash number -- this peer's protocol hash

	The handshake packet, on reserved channel id 0.

	Written once per session, as the first packet this peer sends, so the peer on the other end
	learns whether it is talking to a build it agrees with before it has read anything else in the
	batch (`WIRE-FORMAT.md` §4).
]=]
function Batch.writeHello(hash: number)
	Batch.begin()
	Buffer.discardBlock()
	Buffer.writeVarint(0)
	Buffer.writeU8(HELLO)
	Buffer.writeVarint(4)
	Buffer.writeU32(hash)
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
	local answers = sink.answers
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

		--[[
			Id 0 is control traffic and has no channel behind it (`WIRE-FORMAT.md` §3).

			It is read before `resolve` because resolving 0 would fail, and the failure would be the
			unrecoverable one: the batch would stop on the very packet that exists to explain why the
			two peers disagree.
		]]
		if id == 0 then
			local kind = Buffer.readU8()
			local length = if Buffer.rejected() then 0 else Buffer.readVarint()

			if Buffer.rejected() then
				sink.refuse(nil, "parse", "truncated control packet", size - packetStart)
				return
			end

			local bodyStart = Buffer.cursor()
			local bodyEnd = bodyStart + length

			if bodyEnd > size then
				sink.refuse(nil, "parse", "control body runs past the batch", size - packetStart)
				return
			end

			--[[
				Only the kinds this build knows are read. Anything else is stepped over — that is what
				the length is for — and **said out loud**, which is a separate decision.

				The forward-compatibility argument says stay quiet: a v1 reader meeting a v2 control
				message should carry on, not complain. The argument that wins is this milestone's:
				nothing on the receive path is silent, because a peer sending bytes this build cannot
				act on is exactly the skew a future deploy will need to diagnose, and the repeat
				suppression already caps what it costs at three lines per stage. Found by
				`tests/fuzz_runtime.luau`, whose "nothing vanishes" invariant this was the only
				exception to.
			]]
			if kind == HELLO and length >= 4 then
				Buffer.setLimit(bodyEnd)

				local hash = Buffer.readU32()

				if not Buffer.rejected() then
					sink.hello(hash)
				end
			else
				sink.refuse(nil, "parse", `control kind {kind} is not one this build reads`, length)
			end

			--[[ The same tail every other packet takes, written out rather than jumped over. A
			     control packet carries no instances, so the sidecar cursor stands still — which is
			     a claim, not an omission, and is why the seek is here at all. ]]
			Buffer.setLimit(size)
			Buffer.seek(bodyEnd)
			Buffer.seekInstances(Buffer.instanceCursor())
			Buffer.clearRejection()
			continue
		end

		local channel = sink.resolve(id)

		if not channel then
			--[[ The one unrecoverable case. Without a channel there is no framing, so the end of
			     this packet is unknowable and everything behind it is unreachable. ]]
			sink.refuse(nil, "parse", `unknown channel id {id}`, size - packetStart)
			return
		end

		--[[
			Which half of a query this is comes from the endpoint, not from the packet. The server
			only ever receives requests on a query id and the client only ever receives replies, so
			one wire id carries both directions and neither peer has to be told which it is holding.

			A malicious client cannot exploit that by "sending a reply": the server reads what it is
			given as a request, and it decodes against the args schema or it is refused like anything
			else.
		]]
		local query = channel.class == "query"
		local codec = channel.codec
		local ceiling = channel.maxBytes
		local call: number? = nil
		local status = OK

		if query then
			call = Buffer.readVarint()

			if Buffer.rejected() then
				--[[ Unrecoverable for the same reason a truncated id is: the varint ran off the end
				     of the batch, so there is nothing behind it to resynchronise on. ]]
				sink.refuse(channel, "parse", "truncated call id", size - packetStart)
				return
			end

			if not answers then
				--[[ The reply is framed by the `returns` schema, and it has a ceiling of its own —
				     using the request's would police an answer against the size of the question. ]]
				codec = channel.responseCodec
				ceiling = channel.replyMaxBytes
				status = Buffer.readU8()

				if Buffer.rejected() then
					sink.refuse(channel, "parse", "truncated reply status", size - packetStart)
					return
				end
			end
		end

		local instanceCount = codec.instances
		local payloadLength

		if status ~= OK then
			--[[ A refused reply is the status byte and nothing behind it (`Batch.writeReply`), so
			     the packet ends at the cursor and the loop's tail steps over zero bytes. Both of
			     these are read by that tail, which is why they are set rather than skipped. ]]
			payloadLength = 0
			instanceCount = 0
		elseif codec.framing == "counted" then
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

		if status ~= OK then
			--[[
				A reply the answering side already refused. There is nothing here to decode and
				nothing to admit: the caller is sitting on a yielded thread and this *is* the answer,
				arriving now rather than after the timeout — which is the whole reason the status
				byte exists instead of a silence the caller has to wait out.

				It falls through to the same tail as every other packet. An earlier version skipped
				the tail with `continue` on the grounds that a status-only packet has nothing to step
				over; the same shortcut in this loop once skipped the sidecar cursor and reattributed
				instances, so there is exactly one exit from a packet here and this is not an
				exception to it.
			]]
			sink.reply(channel, call :: number, status, nil, bytes)
		else
			--[[ Everything from here is recoverable: the packet's end is known, so whatever happens
			     the loop can step over it and carry on. ]]
			local denial, stage = sink.admit(channel, bytes)

			--[[
				The declared length against the channel's ceiling, before a byte of the payload is
				decoded.

				The ceiling comes from the schema rather than from the game: every netweave type is
				bounded, so `t.struct({ origin = t.vector3, seq = t.u16 })` can never be more than
				fourteen bytes and a packet claiming more is provably a lie. `RESEARCH §3.7-F` records
				that no surveyed library checks a payload size at all, and the reason is that they
				would have to ask the author for the number — here the schema already knows it
				(`PLAN-M3` D-5).

				After `admit`, not before. An oversized packet still crossed the wire and still cost
				the server a read, so it spends the sender's budget like any other; checking first
				would let a flood of provably invalid packets run free of the limiter built to stop
				floods.
			]]
			if not denial and ceiling and payloadLength > ceiling then
				denial = `payload claims {payloadLength} bytes, over the {ceiling} this channel can hold`
			end

			if denial then
				sink.refuse(channel, stage or "budget", denial, bytes, call)
			else
				Buffer.setLimit(payloadEnd)

				local value, failure = codec.read()

				if failure then
					sink.refuse(channel, "parse", failure, bytes, call)
				elseif query and not answers then
					sink.reply(channel, call :: number, OK, value, bytes)
				else
					sink.deliver(channel, value, bytes, call)
				end
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
