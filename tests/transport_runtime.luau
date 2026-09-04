--!strict

--[[
	The transport, under lune.

		lune run tests/transport_runtime

	Everything here runs without Roblox, which is the point: the batch envelope, the failure
	isolation that guarantee G5 rests on, the outbound fan-out and the inbound dispatch are all
	plain Luau, and a bug in any of them would otherwise surface as "the payload garbled" a Studio
	run later.

	The link between the two halves is injected (`src/transport/Link.luau`), so a loopback pair of
	tables stands in for the `RemoteEvent`s and both directions run in-process.
]]

local Batch = require("../src/transport/Batch")
local Buffer = require("../src/codec/Buffer")
local Serdes = require("../src/codec/Serdes")
local t = require("../src/types")

local failures = 0

local function fail(message: string)
	failures += 1
	print(`FAIL  {message}`)
end

local function check(name: string, condition: boolean)
	if not condition then
		fail(name)
	end
end

local function equals(name: string, actual: any, expected: any)
	if actual ~= expected then
		fail(`{name}: expected {tostring(expected)}, got {tostring(actual)}`)
	end
end

--[[ A channel is a plain record to this layer: an id and a codec. Building them by hand rather
     than through `nw.namespace` keeps these tests about the envelope. ]]
local function channelOf(id: number, descriptor: any): any
	return {
		id = id,
		qualified = `test.c{id}`,
		codec = Serdes.fromSchema(descriptor),
	}
end

local Fixed = channelOf(1, t.struct({ a = t.u8, b = t.u16 }))
local Counted = channelOf(2, t.struct({ n = t.u8, maybe = t.optional(t.u8) }))
local Big = channelOf(3, t.array(t.u8))
local Bounded = channelOf(4, t.struct({ n = t.u8(0, 200), maybe = t.optional(t.u8) }))

local byId: { [number]: any } = {}

for _, channel in { Fixed, Counted, Big, Bounded } do
	byId[channel.id] = channel
end

--[[ A sink that records, so a test can assert on order as well as content. ]]
type Record = { channel: string?, stage: string?, value: any, bytes: number }

local seen: { Record } = {}
local denyOn: { [string]: string } = {}

local sink: Batch.Sink = {
	resolve = function(id: number): any
		return byId[id]
	end,

	admit = function(channel: any, _bytes: number): string?
		return denyOn[channel.qualified]
	end,

	deliver = function(channel: any, value: any, bytes: number)
		table.insert(seen, { channel = channel.qualified, value = value, bytes = bytes })
	end,

	refuse = function(channel: any?, stage: string, reason: string, bytes: number)
		table.insert(seen, {
			channel = if channel then channel.qualified else nil,
			stage = stage,
			value = reason,
			bytes = bytes,
		})
	end,
}

local function reset()
	table.clear(seen)
	table.clear(denyOn)
	Buffer.take()
end

-- ---------------------------------------------------------------------------------------------
-- Framing
-- ---------------------------------------------------------------------------------------------

do
	equals("a fixed schema frames statically", Fixed.codec.framing, "static")
	equals("and knows its size", Fixed.codec.fixedSize, 3)
	equals("and its instance count", Fixed.codec.instances, 0)

	equals("an optional field forces a length", Counted.codec.framing, "counted")
	equals("a dynamic array does too", Big.codec.framing, "counted")
end

do
	reset()
	Batch.writePacket(Fixed, { a = 1, b = 2 })
	local packed = Buffer.take()

	--[[ version 1 + id 1 + payload 3, and no length prefix: the reader knows the size from the
	     id alone, so G5's framing costs a `static` channel nothing (`WIRE-FORMAT.md` §2). ]]
	equals("a static packet is five bytes", buffer.len(packed), 5)

	Batch.read(packed, nil, sink)
	equals("one packet arrived", #seen, 1)
	equals("on the right channel", seen[1].channel, "test.c1")
	equals("with its fields", seen[1].value.b, 2)
	equals("and its byte count excludes the version", seen[1].bytes, 4)
end

do
	reset()
	Batch.writePacket(Counted, { n = 7, maybe = 9 })
	local packed = Buffer.take()

	--[[ version + id + length + payload. The payload is a presence bitfield, `maybe`, then `n`. ]]
	equals("a counted packet is six bytes", buffer.len(packed), 6)

	Batch.read(packed, nil, sink)
	equals("it decodes", seen[1].value.n, 7)
	equals("and its optional", seen[1].value.maybe, 9)
end

do
	reset()

	--[[ The version byte is per batch. Two packets must not pay for it twice. ]]
	Batch.writePacket(Fixed, { a = 1, b = 2 })
	Batch.writePacket(Fixed, { a = 3, b = 4 })
	local packed = Buffer.take()

	equals("two static packets share one version byte", buffer.len(packed), 1 + 4 + 4)

	Batch.read(packed, nil, sink)
	equals("both arrived", #seen, 2)
	equals("in order", seen[2].value.a, 3)
end

-- ---------------------------------------------------------------------------------------------
-- The length reservation, widened
-- ---------------------------------------------------------------------------------------------

do
	reset()

	--[[
		A `counted` packet reserves one byte for its length, and one byte holds 127. A payload past
		that needs the reservation widened and everything after it moved, which is the case the
		benchmark's stand-in refused to handle at all.
	]]
	local list = table.create(200)

	for index = 1, 200 do
		list[index] = index % 256
	end

	Batch.writePacket(Big, list)
	local packed = Buffer.take()

	--[[ 200 elements at one byte each, behind a two-byte count: an unbounded array's length is
	     stored against its maximum, and declaring a bound is what shrinks it. ]]
	equals("the payload is 202 bytes", 202, 202)
	equals("so the packet needs a two-byte length", buffer.len(packed), 1 + 1 + 2 + 202)

	Batch.read(packed, nil, sink)
	equals("it arrived", #seen, 1)
	equals("with every element", #seen[1].value, 200)
	equals("and the last one intact", seen[1].value[200], 200)
end

do
	reset()

	--[[ The widen moves bytes that were already written, so a packet behind one has to survive
	     it. This is the case a shift gets wrong. ]]
	local list = table.create(150, 7)

	Batch.writePacket(Fixed, { a = 11, b = 22 })
	Batch.writePacket(Big, list)
	Batch.writePacket(Fixed, { a = 33, b = 44 })

	Batch.read(Buffer.take(), nil, sink)

	equals("three packets arrived", #seen, 3)
	equals("the one before the widen", seen[1].value.a, 11)
	equals("the widened one", #seen[2].value, 150)
	equals("and the one after it", seen[3].value.a, 33)
end

-- ---------------------------------------------------------------------------------------------
-- Isolation — guarantee G5
-- ---------------------------------------------------------------------------------------------

do
	reset()

	--[[
		A refused `counted` packet is stepped over and the one behind it decodes. This is the whole
		argument for the length prefix, and the reason netweave pays a byte where Zap does not
		(`RESEARCH §3.8-R`).
	]]
	Batch.writePacket(Bounded, { n = 5, maybe = 1 })
	Batch.writePacket(Fixed, { a = 8, b = 9 })
	local packed = Buffer.take()

	--[[ version, id, length, then the presence bitfield, `maybe`, `n`. 255 is outside the
	     declared 0..200, so the decoder can see that it is wrong. ]]
	equals("the bounded field is where expected", buffer.readu8(packed, 5), 5)
	buffer.writeu8(packed, 5, 255)

	Batch.read(packed, nil, sink)

	equals("both packets were visited", #seen, 2)
	equals("the first was refused", seen[1].stage, "parse")
	equals("on its own channel", seen[1].channel, "test.c4")
	equals("the second decoded", seen[2].value.a, 8)
end

do
	reset()

	--[[
		**A refused `static` packet is stepped over too.** Its size comes from the id, so the reader
		knows where it ends without a prefix. The benchmark's stand-in stopped the batch here and
		said the format could not do better; it could.
	]]
	local Narrow = channelOf(5, t.struct({ x = t.u8(0, 100), y = t.u8 }))
	byId[5] = Narrow

	equals("the narrow channel is static", Narrow.codec.framing, "static")

	Batch.writePacket(Narrow, { x = 4, y = 5 })
	Batch.writePacket(Fixed, { a = 6, b = 7 })
	local packed = Buffer.take()

	--[[ version, id, then the payload: `x` then `y`, sorted by name. ]]
	equals("x is where expected", buffer.readu8(packed, 2), 4)
	buffer.writeu8(packed, 2, 255)

	Batch.read(packed, nil, sink)

	equals("both packets were visited", #seen, 2)
	equals("the static one was refused", seen[1].stage, "parse")
	equals("and the one behind it decoded", seen[2].value.a, 6)

	byId[5] = nil
end

do
	reset()

	--[[ An unresolvable id is the one unrecoverable case: no channel means no framing, so the end
	     of the packet is unknowable and everything behind it is unreachable. ]]
	Batch.writePacket(Fixed, { a = 1, b = 2 })
	Batch.writePacket(Fixed, { a = 3, b = 4 })
	local packed = Buffer.take()

	buffer.writeu8(packed, 1, 99)

	Batch.read(packed, nil, sink)

	equals("the batch stopped", #seen, 1)
	equals("with a refusal", seen[1].stage, "parse")
	check("naming the id", string.find(tostring(seen[1].value), "99", 1, true) ~= nil)
end

do
	reset()

	--[[ A length that claims more than the batch holds. There is no boundary to resynchronise on,
	     so the batch stops — but it stops as a value, not as an error. ]]
	Batch.writePacket(Counted, { n = 1, maybe = 2 })
	local packed = Buffer.take()

	buffer.writeu8(packed, 2, 120)

	local ok = pcall(Batch.read, packed, nil, sink)

	check("an overlong length does not raise", ok)
	equals("it is refused", seen[1].stage, "parse")
	check("saying why", string.find(tostring(seen[1].value), "past the batch", 1, true) ~= nil)
end

do
	reset()

	--[[ A batch whose version byte is not ours. A peer on another version is a deploy problem, and
	     decoding its packets against our schemas would produce garbage that looks like data. ]]
	Batch.writePacket(Fixed, { a = 1, b = 2 })
	local packed = Buffer.take()

	buffer.writeu8(packed, 0, 200)

	Batch.read(packed, nil, sink)

	equals("the whole batch is refused", #seen, 1)
	check("naming the version", string.find(tostring(seen[1].value), "200", 1, true) ~= nil)
end

do
	reset()

	--[[ Truncated mid-id. Reads past the limit are rejections rather than errors, so this has to
	     come back as a refusal (`DESIGN-API.md` G4). ]]
	Batch.writePacket(Fixed, { a = 1, b = 2 })
	local full = Buffer.take()

	local cut = buffer.create(1)
	buffer.copy(cut, 0, full, 0, 1)

	local ok = pcall(Batch.read, cut, nil, sink)
	check("a batch with nothing after the version does not raise", ok)
	equals("and reports nothing", #seen, 0)
end

-- ---------------------------------------------------------------------------------------------
-- Budget refusal happens before the payload is read
-- ---------------------------------------------------------------------------------------------

do
	reset()

	--[[
		`admit` runs before the decode. That ordering is the security property: a packet over its
		budget costs an id read and a seek rather than a deserialisation, so refusing stays cheaper
		than accepting and a flood cannot be turned into work (`PLAN-M2` R-2).
	]]
	Batch.writePacket(Counted, { n = 1, maybe = 2 })
	Batch.writePacket(Fixed, { a = 3, b = 4 })

	denyOn["test.c2"] = "over budget"

	Batch.read(Buffer.take(), nil, sink)

	equals("both were visited", #seen, 2)
	equals("the first was refused", seen[1].stage, "budget")
	equals("with the reason", seen[1].value, "over budget")
	equals("and the second still decoded", seen[2].value.a, 3)
end

-- ---------------------------------------------------------------------------------------------
-- The instance sidecar
-- ---------------------------------------------------------------------------------------------

do
	reset()

	--[[
		Instances travel beside the buffer, so a packet that is stepped over has to take its sidecar
		entries with it. Otherwise every instance after it is read against the wrong field — a
		silent mis-association rather than a failure.

		Under lune there are no Roblox instances; the sidecar holds whatever it is given, and these
		tables stand in. `tests/roblox_runtime.luau` covers the real ones.
	]]
	local WithInstance = channelOf(6, t.struct({ who = t.instance, n = t.u8 }))
	byId[6] = WithInstance

	equals("a fixed instance count is known", WithInstance.codec.instances, 1)

	local first = { name = "first" }
	local second = { name = "second" }

	Batch.writePacket(WithInstance, { who = first :: any, n = 1 })
	Batch.writePacket(WithInstance, { who = second :: any, n = 2 })

	local packed, instances = Buffer.take()
	equals("both instances are in the sidecar", #instances, 2)

	Batch.read(packed, instances, sink)
	equals("both packets arrived", #seen, 2)
	check("the first instance", seen[1].value.who == first)
	check("the second instance", seen[2].value.who == second)

	byId[6] = nil
end

do
	reset()

	local WithInstance = channelOf(7, t.struct({ who = t.instance, n = t.u8(0, 200) }))
	byId[7] = WithInstance

	local first = { name = "first" }
	local second = { name = "second" }

	Batch.writePacket(WithInstance, { who = first :: any, n = 1 })
	Batch.writePacket(WithInstance, { who = second :: any, n = 2 })

	local packed, instances = Buffer.take()

	--[[ Corrupt the first packet's `n` past its declared bound, so it is refused after having
	     been about to consume a sidecar entry. ]]
	buffer.writeu8(packed, 2, 255)

	Batch.read(packed, instances, sink)

	equals("the first was refused", seen[1].stage, "parse")
	check(
		"and the second still got its own instance, not the first's",
		seen[2].value ~= nil and seen[2].value.who == second
	)

	byId[7] = nil
end

do
	reset()

	--[[ A variable instance count is written into the frame, because the reader cannot derive it
	     from the schema and needs it to skip. ]]
	local Maybe = channelOf(8, t.struct({ who = t.optional(t.instance), n = t.u8 }))
	byId[8] = Maybe

	equals("a variable instance count is not fixed", Maybe.codec.instances, nil)

	local present = { name = "present" }

	Batch.writePacket(Maybe, { who = present :: any, n = 1 })
	Batch.writePacket(Maybe, { who = nil, n = 2 })
	Batch.writePacket(Maybe, { who = present :: any, n = 3 })

	local packed, instances = Buffer.take()
	equals("only the present ones are in the sidecar", #instances, 2)

	Batch.read(packed, instances, sink)

	equals("three packets arrived", #seen, 3)
	check("the first has its instance", seen[1].value.who == present)
	equals("the second has none", seen[2].value.who, nil)
	check("and the third is not offset by the gap", seen[3].value.who == present)
	equals("with its own field", seen[3].value.n, 3)

	byId[8] = nil
end

-- ---------------------------------------------------------------------------------------------

do
	reset()

	--[[
		A sender who overstates its instance count moves the cursor past entries that belong to the
		packets behind it, and those then decode holding **another packet's instances**. Handing a
		handler the wrong Instance is worse than handing it nothing, and neither side would see a
		failure. The claim is checkable — the sidecar's length is known — so it is checked.
	]]
	local Maybe = channelOf(9, t.struct({ who = t.optional(t.instance), n = t.u8 }))
	byId[9] = Maybe

	local mine = { name = "mine" }
	local yours = { name = "yours" }

	Batch.writePacket(Maybe, { who = mine :: any, n = 1 })
	Batch.writePacket(Maybe, { who = yours :: any, n = 2 })

	local packed, instances = Buffer.take()

	--[[
		version, id, instances, payload. There is no length: an optional instance costs no bytes, so
		the struct has a fixed size and frames statically — which is worth pinning, because it means
		a static channel can still carry a variable instance count.
	]]
	equals("the channel is static", Maybe.codec.framing, "static")
	equals("with a variable instance count", Maybe.codec.instances, nil)
	equals("the count is where expected", buffer.readu8(packed, 2), 1)
	buffer.writeu8(packed, 2, 90)

	Batch.read(packed, instances, sink)

	equals("the batch stopped", #seen, 1)
	equals("with a refusal", seen[1].stage, "parse")
	check("naming the sidecar", string.find(tostring(seen[1].value), "sidecar", 1, true) ~= nil)

	byId[9] = nil
end

do
	reset()

	--[[
		A block left open by a raising encode must not reach the next packet: the length byte is
		reserved before the payload is written, and `Buffer.reserve` takes from the block cursor
		when one is open, so the leak lands exactly on the field that frames everything else.
	]]
	local Narrow = channelOf(10, t.struct({ x = t.u8(0, 100), y = t.u8 }))
	byId[10] = Narrow

	local ok = pcall(Batch.writePacket, Narrow, { x = 200, y = 1 })
	check("an out-of-range field still refuses", not ok)

	--[[ The caller owns the rewind after a raised write; what is under test is that the block
	     state did not survive it. ]]
	Buffer.take()

	Batch.writePacket(Counted, { n = 3, maybe = 4 })
	local packed = Buffer.take()

	equals("the packet after it frames correctly", buffer.len(packed), 6)

	Batch.read(packed, nil, sink)
	equals("and decodes", seen[1].value.n, 3)

	byId[10] = nil
end

reset()

if failures > 0 then
	error(`{failures} transport assertions failed`)
end

print("OK      transport_runtime")

return true
