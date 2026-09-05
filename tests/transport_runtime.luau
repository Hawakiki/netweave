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

local Audience = require("../src/api/Audience")
local Batch = require("../src/transport/Batch")
local Buffer = require("../src/codec/Buffer")
local Config = require("../src/api/Config")
local Context = require("../src/api/Context")
local Inbound = require("../src/transport/Inbound")
local Link = require("../src/transport/Link")
local Observer = require("../src/api/Observer")
local Outbound = require("../src/transport/Outbound")
local Recipients = require("../src/transport/Recipients")
local Serdes = require("../src/codec/Serdes")
local harness = require("./harness")
local t = require("../src/types")

--[[
	The sections below are tagged failure- or success-path, and the file declares a floor
	(`PLAN-M3` D-10).

	The tag is per section because that is the granularity these tests are written at. A G5 case
	crafts one bad packet among three and then asserts three things: the bad one was refused, the
	other two arrived, and the batch did not stop. All three are assertions about **failure
	isolation** — the middle one asserts a success but tests what happens when something goes wrong,
	and calling it success-path would be reading the assertion instead of the test.

	What is genuinely success-path is here too, and is tagged so: framing arithmetic, the fan-out,
	the audience resolution, the coalescing. Those are the file's other half and the reason its floor
	is not the 0.95 `budget_runtime` declares.
]]
local suite = harness.suite("transport_runtime", 0.5)
local check, equals = suite.check, suite.equals

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
type Record = {
	channel: string?,
	stage: string?,
	value: any,
	bytes: number,
	call: number?,
	status: number?,
}

local seen: { Record } = {}
local denyOn: { [string]: string } = {}

local sink: Batch.Sink = {
	resolve = function(id: number): any
		return byId[id]
	end,

	--[[ These envelope tests are all request-shaped, so this sink reads like a server. The reply
	     direction has its own file: `tests/query_runtime.luau`. ]]
	answers = true,

	admit = function(channel: any, _bytes: number): (string?, string?)
		return denyOn[channel.qualified], "budget"
	end,

	hello = function(hash: number)
		table.insert(seen, { channel = "control", stage = "hello", value = hash, bytes = 0 })
	end,

	deliver = function(channel: any, value: any, bytes: number, call: number?)
		table.insert(seen, { channel = channel.qualified, value = value, bytes = bytes, call = call })
	end,

	reply = function(channel: any, call: number, status: number, value: any?, bytes: number)
		table.insert(seen, {
			channel = channel.qualified,
			value = value,
			bytes = bytes,
			call = call,
			status = status,
		})
	end,

	refuse = function(channel: any?, stage: string, reason: string, bytes: number, call: number?)
		table.insert(seen, {
			channel = if channel then channel.qualified else nil,
			stage = stage,
			value = reason,
			bytes = bytes,
			call = call,
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

suite.passing()

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

suite.passing()

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

suite.failing()

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

suite.failing()

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

suite.passing()

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

	suite.failing()

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

-- ---------------------------------------------------------------------------------------------
-- Outbound
-- ---------------------------------------------------------------------------------------------

suite.passing()

--[[ A loopback link. Everything the real one does to a `RemoteEvent`, recorded instead. ]]
type Sent = { reliable: boolean, destination: any, packed: buffer, instances: { any } }

local function linkOf(): (Link.Link, { Sent })
	local log: { Sent } = {}

	local link: Link.Link = {
		send = function(reliable, destination, packed, instances)
			table.insert(log, {
				reliable = reliable,
				destination = destination,
				packed = packed,
				instances = instances,
			})
		end,

		sendAll = function(reliable, packed, instances)
			table.insert(log, {
				reliable = reliable,
				destination = "everyone",
				packed = packed,
				instances = instances,
			})
		end,

		receive = function() end,
	}

	return link, log
end

local alice = { name = "alice" }
local bob = { name = "bob" }
local carol = { name = "carol" }

--[[ `nearby` returns whoever the test says is nearby. The geometry belongs to Roblox and is
     covered where Roblox is, not by pretending here. ]]
local nearbyOf: { any } = { alice }

local roster: Recipients.Roster = {
	all = function()
		return { alice, bob, carol }
	end,

	owner = function(subject: any): any?
		return subject
	end,

	within = function(_subject: any, _studs: number, out: { any }): number
		for index, player in nearbyOf do
			out[index] = player
		end

		return #nearbyOf
	end,
}

local function outboundChannel(id: number, descriptor: any, extra: { [string]: any }?): any
	local channel = channelOf(id, descriptor)

	for key, value in extra or {} do
		channel[key] = value
	end

	return channel
end

do
	reset()

	local link, log = linkOf()
	local out = Outbound.new(link, roster)
	local channel = outboundChannel(20, t.struct({ a = t.u8 }))
	byId[20] = channel

	--[[ A frame's worth of packets to one recipient is one remote call, not one per packet. That
	     ratio is the measured case for batching: raw issues ~6,400 invocations a second against a
	     batching library's ~126 (`bench/RESULTS.md`). ]]
	out.push(channel, alice, { a = 1 })
	out.push(channel, alice, { a = 2 })
	out.push(channel, alice, { a = 3 })

	equals("nothing is sent before the flush", #log, 0)

	out.flush()

	equals("one call carried all three", #log, 1)
	equals("to the right recipient", log[1].destination, alice)
	check("on the reliable channel", log[1].reliable)
	equals("with one version byte", buffer.len(log[1].packed), 1 + 3 * 2)

	Batch.read(log[1].packed, log[1].instances :: any, sink)
	equals("all three arrived", #seen, 3)
	equals("in order", seen[3].value.a, 3)

	byId[20] = nil
end

do
	reset()

	local link, log = linkOf()
	local out = Outbound.new(link, roster)
	local channel = outboundChannel(21, t.struct({ a = t.u8 }))
	byId[21] = channel

	--[[ Two recipients each get their own batch, and neither sees the other's packets. ]]
	out.push(channel, alice, { a = 1 })
	out.push(channel, bob, { a = 2 })
	out.push(channel, alice, { a = 3 })
	out.flush()

	equals("two calls", #log, 2)

	local byDestination: { [any]: buffer } = {}

	for _, entry in log do
		byDestination[entry.destination] = entry.packed
	end

	Batch.read(byDestination[alice], nil, sink)
	equals("alice got two packets", #seen, 2)
	equals("hers, in order", seen[2].value.a, 3)

	table.clear(seen)
	Batch.read(byDestination[bob], nil, sink)
	equals("bob got one", #seen, 1)
	equals("his own", seen[1].value.a, 2)

	byId[21] = nil
end

do
	reset()

	local link, log = linkOf()
	local out = Outbound.new(link, roster)

	--[[ An audience of everyone is one `FireAllClients`, not N `FireClient`s. This is the one axis
	     where ByteNet beats both code generators, and collapsing it into the fan-out path would
	     throw it away silently (`RESEARCH §3.7-E`). ]]
	local channel = outboundChannel(22, t.struct({ a = t.u8 }), {
		audience = Audience.everyone,
	})

	byId[22] = channel

	out.publish(channel, nil, { a = 7 })
	out.flush()

	equals("one call for everyone", #log, 1)
	equals("addressed to all", log[1].destination, "everyone")

	Batch.read(log[1].packed, nil, sink)
	equals("and it decodes", seen[1].value.a, 7)

	byId[22] = nil
end

do
	reset()

	local link, log = linkOf()
	local out = Outbound.new(link, roster)
	local channel = outboundChannel(23, t.struct({ a = t.u8, b = t.u16 }), {
		audience = Audience.nearby(120),
	})

	byId[23] = channel

	nearbyOf = { alice, bob, carol }

	out.publish(channel, alice, { a = 1, b = 2 })
	out.flush()

	equals("one call per recipient", #log, 3)

	--[[ Serialised once and copied, so every recipient's bytes have to be identical. A fan-out
	     that re-encoded per recipient would pass this too — what it would not pass is the encode
	     allocation, which is why the copy is the point rather than the equality. ]]
	local first = log[1].packed

	for index = 2, 3 do
		equals(`recipient {index} matches`, buffer.len(log[index].packed), buffer.len(first))
	end

	table.clear(seen)
	Batch.read(log[3].packed, nil, sink)
	equals("and it decodes", seen[1].value.b, 2)

	nearbyOf = { alice }
	byId[23] = nil
end

do
	reset()

	local link, log = linkOf()
	local out = Outbound.new(link, roster)
	local channel = outboundChannel(24, t.struct({ a = t.u8 }), {
		audience = Audience.owner,
	})

	byId[24] = channel

	--[[ One recipient takes the direct path rather than the fan-out: serialising and copying to
	     reach one buffer is strictly more work than writing into it. ]]
	out.publish(channel, bob, { a = 9 })
	out.flush()

	equals("one call", #log, 1)
	equals("to the owner", log[1].destination, bob)

	byId[24] = nil
end

do
	reset()

	local link, log = linkOf()
	local out = Outbound.new(link, roster)
	local chosen: { any } = { carol }

	local channel = outboundChannel(25, t.struct({ a = t.u8 }), {
		audience = Audience.select(function()
			return chosen :: any
		end),
	})

	byId[25] = channel

	out.publish(channel, nil, { a = 4 })
	out.flush()

	equals("the selector decided", #log, 1)
	equals("who receives", log[1].destination, carol)

	--[[ An empty selection sends nothing at all, rather than an empty batch. ]]
	chosen = {}
	out.publish(channel, nil, { a = 5 })
	out.flush()

	equals("an empty audience sends nothing", #log, 1)

	byId[25] = nil
end

do
	reset()

	local link, log = linkOf()
	local out = Outbound.new(link, roster)
	local channel = outboundChannel(26, t.struct({ a = t.u8 }), { unreliable = true })

	byId[26] = channel

	--[[ Unreliable is not batched. One lost datagram would otherwise cost N events instead of
	     one, which is a semantic error rather than a saving (`RESEARCH §3.7-E`). ]]
	out.push(channel, alice, { a = 1 })
	out.push(channel, alice, { a = 2 })

	equals("each went out on its own", #log, 2)
	check("on the unreliable channel", not log[1].reliable)

	out.flush()
	equals("and the flush had nothing to do", #log, 2)

	byId[26] = nil
end

do
	reset()
	Observer.reset()

	local reported: { string } = {}

	Observer.observe(function(rejection)
		table.insert(reported, `{rejection.stage}:{rejection.bytes}`)
	end)

	local link, log = linkOf()
	local out = Outbound.new(link, roster)

	--[[
		Roblox drops an unreliable payload past 908 bytes silently — no error, no warning, and
		nothing on either side. None of the three surveyed libraries checks for it
		(`RESEARCH §3.7-F`), so a game using them loses packets it cannot see losing.
	]]
	local channel = outboundChannel(27, t.array(t.u8), { unreliable = true })
	byId[27] = channel

	local big = table.create(1200, 1)

	out.push(channel, alice, big)

	equals("nothing went out", #log, 0)
	equals("and it was reported", #reported, 1)
	check("at the send stage", string.find(reported[1], "send:", 1, true) ~= nil)

	--[[ A payload that fits still goes. ]]
	local fits = table.create(800, 1)
	out.push(channel, alice, fits)
	equals("a payload that fits is sent", #log, 1)

	Observer.reset()
	byId[27] = nil
end

do
	reset()

	local link, log = linkOf()
	local out = Outbound.new(link, roster)
	local good = outboundChannel(28, t.struct({ a = t.u8 }))
	local narrow = outboundChannel(29, t.struct({ x = t.u8(0, 100) }))

	byId[28] = good
	byId[29] = narrow

	--[[
		A packet whose value the schema forbids raises, and that is the posture. What it must not do
		is leave the half-written packet in the batch: the bytes behind it are a real player's real
		traffic, and a partial packet in front of them makes the whole batch undecodable.
	]]
	out.push(good, alice, { a = 1 })

	local ok = pcall(out.push, narrow, alice, { x = 200 })
	check("the bad value still raises", not ok)

	out.push(good, alice, { a = 2 })
	out.flush()

	equals("one call", #log, 1)

	Batch.read(log[1].packed, nil, sink)
	equals("both good packets survived", #seen, 2)
	equals("the one before the failure", seen[1].value.a, 1)
	equals("and the one after it", seen[2].value.a, 2)

	byId[28] = nil
	byId[29] = nil
end

do
	reset()

	local link, log = linkOf()
	local out = Outbound.new(link, roster)
	local channel = outboundChannel(30, t.struct({ a = t.u8 }))
	byId[30] = channel

	--[[ A player who left. Their parked batch is bytes nobody will receive, and holding it holds
	     the buffer behind it too. ]]
	out.push(channel, alice, { a = 1 })
	out.push(channel, bob, { a = 2 })
	out.forget(alice)
	out.flush()

	equals("only the remaining player is sent to", #log, 1)
	equals("and it is the right one", log[1].destination, bob)

	byId[30] = nil
end

do
	reset()

	local link, log = linkOf()
	local out = Outbound.new(link, roster)
	local channel = outboundChannel(31, t.struct({ a = t.u8 }))
	byId[31] = channel

	--[[
		A client sends to exactly one place, and it is not addressable by name — so the destination
		is a sentinel rather than `nil`.

		`nil` is what this reached for first, and it is indistinguishable from "no destination
		loaded": the swap sees a match, skips the load, and the packet lands in whichever buffer
		happened to be current. On a server that is one player's traffic in another player's batch.
	]]
	out.push(channel, Outbound.SERVER, { a = 1 })
	out.push(channel, Outbound.SERVER, { a = 2 })
	out.flush()

	equals("one call", #log, 1)
	equals("with no named recipient", log[1].destination, nil)

	Batch.read(log[1].packed, nil, sink)
	equals("both packets arrived", #seen, 2)
	equals("in order", seen[2].value.a, 2)

	--[[ And a client's batch does not collide with a broadcast's, which is the other sentinel. ]]
	table.clear(seen)
	out.push(channel, Outbound.SERVER, { a = 3 })
	out.push(channel, Outbound.EVERYONE, { a = 4 })
	out.flush()

	equals("two separate batches", #log, 3)
end

-- ---------------------------------------------------------------------------------------------
-- Inbound
-- ---------------------------------------------------------------------------------------------

suite.passing()

local function inboundOf(isServer: boolean, deny: { [string]: string }): (Inbound.Inbound, { string })
	local reported: { string } = {}

	Observer.reset()
	Observer.observe(function(rejection)
		table.insert(reported, `{rejection.stage}:{rejection.channel}`)
	end)

	local inbound = Inbound.new({
		resolve = function(id: number): any
			return byId[id]
		end,

		admit = function(channel: any, _who: any?, _bytes: number): string?
			return deny[channel.qualified]
		end,

		isServer = isServer,
	})

	return inbound, reported
end

--[[ A policy that answers however the test says, in the shape `src/api/Policy.luau` produces. ]]
local function verdictOf(ok: boolean, reason: string?): any
	return function()
		return { ok = ok, value = nil, reason = reason }
	end
end

do
	reset()

	local channel = outboundChannel(40, t.struct({ a = t.u8 }), { class = "signal" })
	byId[40] = channel

	local got: { number } = {}
	channel.handler = function(_ctx: any, value: any)
		table.insert(got, value.a)
	end

	local inbound, reported = inboundOf(true, {})

	Batch.writePacket(channel, { a = 1 })
	Batch.writePacket(channel, { a = 2 })

	inbound.receive(Buffer.take(), nil, alice)

	equals("both were dispatched", #got, 2)
	equals("in order", got[2], 2)
	equals("and nothing was reported", #reported, 0)

	channel.handler = nil
	byId[40] = nil
	Observer.reset()
end

do
	reset()

	suite.failing()

	--[[ A policy that denies stops the handler and reports at the authorize stage. The packet
	     decoded and was in budget; what refused it was the game's own rule. ]]
	local channel = outboundChannel(41, t.struct({ a = t.u8 }), {
		class = "command",
		authorize = verdictOf(false, "not today"),
	})

	byId[41] = channel

	local called = 0
	channel.handler = function()
		called += 1
	end

	local inbound, reported = inboundOf(true, {})

	Batch.writePacket(channel, { a = 1 })
	inbound.receive(Buffer.take(), nil, alice)

	equals("the handler did not run", called, 0)
	equals("and it was reported", #reported, 1)
	check("at the authorize stage", string.find(reported[1], "authorize:", 1, true) ~= nil)

	channel.handler = nil
	byId[41] = nil
	Observer.reset()
end

do
	reset()

	--[[
		A handler is game code and can throw. If it threw into the receive loop it would abort the
		batch — the exact failure G5 exists to prevent, reintroduced by the game rather than by a
		peer. The packets behind it belong to other players.
	]]
	local channel = outboundChannel(42, t.struct({ a = t.u8 }), { class = "signal" })
	byId[42] = channel

	local survived: { number } = {}

	channel.handler = function(_ctx: any, value: any)
		if value.a == 2 then
			error("a handler that misbehaves")
		end

		table.insert(survived, value.a)
	end

	local inbound, reported = inboundOf(true, {})

	Batch.writePacket(channel, { a = 1 })
	Batch.writePacket(channel, { a = 2 })
	Batch.writePacket(channel, { a = 3 })

	local ok = pcall(inbound.receive, Buffer.take(), nil, alice)

	check("the batch did not raise", ok)
	equals("the packets around it survived", #survived, 2)
	equals("the one after the throw", survived[2], 3)
	equals("and the throw was reported", #reported, 1)
	check("at the handler stage", string.find(reported[1], "handler:", 1, true) ~= nil)

	channel.handler = nil
	byId[42] = nil
	Observer.reset()
end

do
	reset()

	--[[ Refused before the payload is decoded, so a flood costs an id read and a seek rather than
	     a deserialisation (`PLAN-M2` R-2). ]]
	local channel = outboundChannel(43, t.struct({ a = t.u8 }), { class = "signal" })
	byId[43] = channel

	local called = 0
	channel.handler = function()
		called += 1
	end

	local inbound, reported = inboundOf(true, { ["test.c43"] = "over budget" })

	Batch.writePacket(channel, { a = 1 })
	inbound.receive(Buffer.take(), nil, alice)

	equals("the handler did not run", called, 0)
	check("and it was reported at the budget stage", string.find(reported[1], "budget:", 1, true) ~= nil)

	channel.handler = nil
	byId[43] = nil
	Observer.reset()
end

-- ---------------------------------------------------------------------------------------------
-- Intent coalescing
-- ---------------------------------------------------------------------------------------------

suite.passing()

do
	reset()

	--[[
		At most one intent per player per tick. Stale input has no value, so an attacker who fills
		the rate budget cannot convert it into per-packet server work — which is what makes `rate`
		on an intent a number that means something (`DESIGN-API.md` §3).
	]]
	local channel = outboundChannel(44, t.struct({ pitch = t.u8 }), { class = "intent" })
	byId[44] = channel

	local delivered: { any } = {}

	channel.handler = function(ctx: any, value: any)
		table.insert(delivered, { who = ctx.player, pitch = value.pitch })
	end

	local inbound = inboundOf(true, {})

	for pitch = 1, 20 do
		Batch.writePacket(channel, { pitch = pitch })
	end

	inbound.receive(Buffer.take(), nil, alice)

	equals("nothing is delivered during receive", #delivered, 0)

	inbound.tick()

	equals("one value reached the handler", #delivered, 1)
	equals("and it is the newest", delivered[1].pitch, 20)

	--[[ Per player, not globally: two players' inputs do not supersede each other. ]]
	table.clear(delivered)

	Batch.writePacket(channel, { pitch = 7 })
	inbound.receive(Buffer.take(), nil, alice)
	Batch.writePacket(channel, { pitch = 9 })
	inbound.receive(Buffer.take(), nil, bob)

	inbound.tick()

	equals("both players were served", #delivered, 2)

	--[[ And a tick with nothing pending delivers nothing rather than repeating. ]]
	table.clear(delivered)
	inbound.tick()
	equals("an empty tick is empty", #delivered, 0)

	channel.handler = nil
	byId[44] = nil
	Observer.reset()
end

-- ---------------------------------------------------------------------------------------------
-- The listener-less queue
-- ---------------------------------------------------------------------------------------------

suite.failing()

do
	reset()

	--[[
		A handler attached one frame late is an ordering accident, and losing the traffic to it is a
		bug the game cannot see. The packets are kept until something listens.
	]]
	local channel = outboundChannel(45, t.struct({ a = t.u8 }), { class = "signal" })
	byId[45] = channel

	local inbound = inboundOf(true, {})

	Batch.writePacket(channel, { a = 1 })
	Batch.writePacket(channel, { a = 2 })
	inbound.receive(Buffer.take(), nil, alice)

	local got: { number } = {}
	channel.handler = function(_ctx: any, value: any)
		table.insert(got, value.a)
	end

	inbound.drain(channel)

	equals("what arrived first is delivered", #got, 2)
	equals("in arrival order", got[1], 1)
	equals("and the rest of it", got[2], 2)

	--[[ Draining twice does not deliver twice. ]]
	inbound.drain(channel)
	equals("a second drain has nothing to do", #got, 2)

	channel.handler = nil
	byId[45] = nil
	Observer.reset()
end

do
	reset()

	--[[
		Blink grows this queue without bound and warns on every insert past 256, so a forgotten
		`:listen` becomes warn spam plus a memory leak (`RESEARCH §3.7-H`). netweave keeps the
		newest, drops the oldest, and says so once per drop.
	]]
	local channel = outboundChannel(46, t.struct({ a = t.u16 }), { class = "signal" })
	byId[46] = channel

	local inbound, reported = inboundOf(true, {})

	for index = 1, 300 do
		Batch.writePacket(channel, { a = index })
		inbound.receive(Buffer.take(), nil, alice)
	end

	local got: { number } = {}
	channel.handler = function(_ctx: any, value: any)
		table.insert(got, value.a)
	end

	inbound.drain(channel)

	equals("the queue is bounded", #got, 256)
	equals("and it kept the newest", got[256], 300)
	equals("dropping the oldest", got[1], 45)
	equals("and reported every drop", #reported, 44)

	channel.handler = nil
	byId[46] = nil
	Observer.reset()
end

do
	reset()

	--[[ A client's handler takes the payload alone: its inbound is the server's outbound, and the
	     server is not a peer to be checked. ]]
	local channel = outboundChannel(47, t.struct({ a = t.u8 }), { class = "event" })
	byId[47] = channel

	local got: { number } = {}
	channel.handler = function(value: any)
		table.insert(got, value.a)
	end

	local inbound = inboundOf(false, {})

	Batch.writePacket(channel, { a = 5 })
	inbound.receive(Buffer.take(), nil, nil)

	equals("the payload arrived alone", #got, 1)
	equals("with its field", got[1], 5)

	channel.handler = nil
	byId[47] = nil
	Observer.reset()
end

do
	reset()

	--[[
		A handler is game code and may yield, and Roblox runs each remote callback on its own
		coroutine — so a yield lets the next batch in. The decoder's cursor is global state, so
		reading and dispatching in one pass would mean: handler yields, the next batch calls
		`beginRead`, and when the first resumes it walks the *second* batch's bytes while
		attributing them to the first batch's sender.

		Not a crash. One player's packets delivered as another player's, which is the worst shape a
		networking bug can take. Reading a batch to completion before dispatching any of it closes
		it structurally, and this is the case that would otherwise prove it.
	]]
	local channel = outboundChannel(48, t.struct({ a = t.u8 }), { class = "signal" })
	byId[48] = channel

	local inbound = inboundOf(true, {})
	local delivered: { string } = {}
	local suspended: thread? = nil

	channel.handler = function(ctx: any, value: any)
		table.insert(delivered, `{ctx.player.name}:{value.a}`)

		--[[ Yield on the first packet of the first batch, the way a handler that waits on anything
		     would. The interleaved batch arrives while this one is suspended. ]]
		if value.a == 1 and not suspended then
			suspended = coroutine.running()
			coroutine.yield()
		end
	end

	--[[ Alice sends two, bob sends four. The sizes matter: the pending lists are pooled, and an
	     interleaved batch shorter than the one it interrupts would not reach the entries the outer
	     dispatch has yet to visit. A first version of this test used one packet for bob and passed
	     against code that was wrong. ]]
	Batch.writePacket(channel, { a = 1 })
	Batch.writePacket(channel, { a = 2 })
	local alicePacket = Buffer.take()

	for value = 6, 9 do
		Batch.writePacket(channel, { a = value })
	end

	local bobPacket = Buffer.take()

	local first = coroutine.create(function()
		inbound.receive(alicePacket, nil, alice)
	end)

	coroutine.resume(first)

	equals("the first batch stopped inside its handler", #delivered, 1)
	equals("on alice", delivered[1], "alice:1")

	--[[ Bob's batch arrives while alice's is suspended mid-dispatch. ]]
	inbound.receive(bobPacket, nil, bob)

	equals("bob was served", #delivered, 5)
	equals("as bob", delivered[2], "bob:6")
	equals("all of him", delivered[5], "bob:9")

	--[[ And alice's second packet is still alice's, read from alice's bytes. ]]
	coroutine.resume(suspended :: thread)

	equals("alice's batch finished", #delivered, 6)
	equals("with her own second packet", delivered[6], "alice:2")

	channel.handler = nil
	byId[48] = nil
	Observer.reset()
end

-- ---------------------------------------------------------------------------------------------
-- A policy is game code, and game code does not get the batch (PLAN-M3 D-1)
-- ---------------------------------------------------------------------------------------------

suite.failing()

do
	reset()

	--[[
		M2 wrapped the handler and left `authorize` bare, so a policy that raised took every packet
		behind it — including other players', once the queue drain crosses senders. That turns the
		authorization layer into the denial-of-service surface: find one input that trips a game's
		policy and the traffic batched behind it dies.

		`RESEARCH §3.8-R` is the same failure at the codec layer, which netweave already avoids.
		This is that discipline applied to the game's own code rather than to a peer's.

		Against the pre-fix code this block reports `receive survived = false` and delivers 0 of 2.
	]]
	local channel = outboundChannel(50, t.struct({ a = t.u8 }), {
		class = "command",
		authorize = function(_ctx: any, value: any)
			if value.a == 1 then
				error("policy blew up")
			end

			return { ok = true, value = nil, reason = nil }
		end,
	})

	byId[50] = channel

	local got: { number } = {}
	channel.handler = function(_ctx: any, value: any)
		table.insert(got, value.a)
	end

	local inbound, reported = inboundOf(true, {})

	Batch.writePacket(channel, { a = 1 })
	Batch.writePacket(channel, { a = 2 })
	Batch.writePacket(channel, { a = 3 })

	local packed, instances = Buffer.take()
	local survived = pcall(function()
		inbound.receive(packed, instances, alice)
	end)

	check("a raising policy does not reach the receive loop", survived)
	equals("the packets it did not refuse were delivered", #got, 2)
	equals("and the first of those is the second packet", got[1], 2)
	equals("the raise was reported once", #reported, 1)
	check(
		"at the authorize stage",
		reported[1] ~= nil and string.find(reported[1], "authorize:", 1, true) ~= nil
	)

	channel.handler = nil
	byId[50] = nil
	Observer.reset()
end

-- ---------------------------------------------------------------------------------------------
-- A verdict is `ok == true` or it is a refusal (PLAN-M3 D-2)
-- ---------------------------------------------------------------------------------------------

suite.failing()

do
	reset()

	--[[
		Not truthy. A policy that returns nothing is a policy someone forgot to finish, and the safe
		reading of an unfinished policy is "no" — this is the one place in netweave where a shrug
		must not mean yes.

		Against the pre-fix code the `nil` case raises `attempt to index nil` on the receive path,
		which is a G4 violation reachable from a game's own bug, and `{ ok = "yes" }` is *admitted*
		because the check was `if not allowed`.
	]]
	local shrugs: { { name: string, returns: any } } = {
		{ name = "nil", returns = nil },
		{ name = "false", returns = false },
		{ name = "a number", returns = 0 },
		{ name = "an empty table", returns = {} },
		{ name = "a table with no ok", returns = { value = 1 } },
		{ name = "ok = false", returns = { ok = false } },
		{ name = "a truthy non-true ok", returns = { ok = "yes" } },
	}

	for index, shrug in shrugs do
		local id = 60 + index
		local channel = outboundChannel(id, t.struct({ a = t.u8 }), {
			class = "command",
			authorize = function()
				return shrug.returns
			end,
		})

		byId[id] = channel

		local called = 0
		channel.handler = function()
			called += 1
		end

		local inbound, reported = inboundOf(true, {})

		Batch.writePacket(channel, { a = 1 })

		local packed, instances = Buffer.take()
		local survived = pcall(function()
			inbound.receive(packed, instances, alice)
		end)

		check(`a policy returning {shrug.name} does not raise`, survived)
		equals(`a policy returning {shrug.name} refuses`, called, 0)
		equals(`and reports it`, #reported, 1)

		channel.handler = nil
		byId[id] = nil
		Observer.reset()
	end
end

-- ---------------------------------------------------------------------------------------------
-- A raising policy does not leak the context (PLAN-M3 D-1)
-- ---------------------------------------------------------------------------------------------

suite.failing()

do
	reset()

	--[[
		`Context.release` was only reached on the paths that returned normally, so a policy that
		raised left the record's generation unbumped — and a `ctx` retained from that packet stayed
		*valid* into the next one, reading the next sender's channel and clock through a proxy the
		guard should have expired.

		That is the wrong-player attribution M2 phase 3 fixed at the batch level, reintroduced one
		packet at a time by an exception path. The guard is Studio-only, so the leak is invisible in
		production, where it is also the only place it matters.

		Against the pre-fix code the retained proxy reads packet two's channel instead of raising.
	]]
	local guardWas = Context.guarded()
	Context.setGuarded(true)

	local stashed: any = nil

	local channel = outboundChannel(70, t.struct({ a = t.u8 }), {
		class = "command",
		authorize = function(ctx: any, value: any)
			if value.a == 1 then
				stashed = ctx
				error("policy blew up")
			end

			return { ok = true, value = nil, reason = nil }
		end,
	})

	byId[70] = channel
	channel.handler = function() end

	local inbound = inboundOf(true, {})

	Batch.writePacket(channel, { a = 1 })
	local first, firstInstances = Buffer.take()
	pcall(function()
		inbound.receive(first, firstInstances, alice)
	end)

	check("the policy stashed a ctx", stashed ~= nil)

	reset()
	Batch.writePacket(channel, { a = 2 })
	local second, secondInstances = Buffer.take()
	pcall(function()
		inbound.receive(second, secondInstances, bob)
	end)

	local readable = pcall(function()
		return (stashed :: any).channel
	end)

	check("the ctx the raising policy held is expired, not alive on the next packet", not readable)

	Context.setGuarded(guardWas)
	channel.handler = nil
	byId[70] = nil
	Observer.reset()
end

-- ---------------------------------------------------------------------------------------------
-- Every channel has a byte ceiling, and the game declared none of it (PLAN-M3 D-5)
-- ---------------------------------------------------------------------------------------------

suite.failing()

do
	reset()

	--[[
		The ceiling is derived from the schema, so it exists whether or not the author thought to
		ask for one. `RESEARCH §3.7-F` records that no surveyed library checks a payload size at
		all, and the reason is that they would have to ask — here the layout adds the bounds up.

		Refused before the payload is decoded, and the batch steps over it: the length prefix is
		what makes that possible, and it is the length that was wrong.
	]]
	local channel = outboundChannel(80, t.array(t.u8), { class = "signal", maxBytes = 4 })
	byId[80] = channel

	local got: { number } = {}
	channel.handler = function(_ctx: any, value: any)
		table.insert(got, #value)
	end

	local inbound, reported = inboundOf(true, {})

	Batch.writePacket(channel, { 1, 2 })
	Batch.writePacket(channel, { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 })
	Batch.writePacket(channel, { 3, 4 })

	local packed, instances = Buffer.take()
	local survived = pcall(function()
		inbound.receive(packed, instances, alice)
	end)

	check("an oversized packet does not reach the receive loop", survived)
	equals("the packets under the ceiling were delivered", #got, 2)
	equals("and the one over it was not", got[2], 2)
	equals("it was reported once", #reported, 1)
	check("at the budget stage", reported[1] ~= nil and string.find(reported[1], "budget:", 1, true) ~= nil)

	channel.handler = nil
	byId[80] = nil
	Observer.reset()
end

do
	reset()

	--[[ The layout derives a ceiling for every schema, so the transport always has one to enforce.
	     That it reaches a declared channel is `tests/api_runtime.luau`; that it is right is here. ]]
	local channel = outboundChannel(81, t.struct({ origin = t.vector3, seq = t.u16 }), { class = "signal" })

	equals("a tight schema derives an exact ceiling", channel.codec.maxSize, 14)
	equals("which is what the packet actually costs", channel.codec.fixedSize, 14)

	byId[81] = nil
end

-- ---------------------------------------------------------------------------------------------
-- A batch cannot hold more than it is allowed to (PLAN-M3 D-6)
-- ---------------------------------------------------------------------------------------------

suite.failing()

do
	reset()

	--[[
		Reading a batch to completion before dispatching any of it is not negotiable — a yielding
		handler plus a global decode cursor attributes one player's bytes to another (`PLAN-M2`
		phase 3) — and it means every decoded value in a batch is live at once.

		`bench/RESULTS.md` measured the price: `ArrayHeavy` decode allocation went 1184.8 B to
		9309.2 B on the same payload, because two hundred decoded values were alive where one had
		been. The size of that batch is chosen by an untrusted client, which makes it a resource
		limit rather than a performance note.

		Past the bound the rest of the batch is refused *before* decode, not decoded and dropped:
		refusing has to stay cheaper than accepting or the limit becomes the amplifier.
	]]
	local channel = outboundChannel(85, t.struct({ a = t.u8 }), { class = "signal" })
	byId[85] = channel

	local delivered = 0
	channel.handler = function()
		delivered += 1
	end

	Config.configure({ limits = { pendingPerBatch = 4 } })

	local inbound, reported = inboundOf(true, {})

	for index = 1, 10 do
		Batch.writePacket(channel, { a = index })
	end

	local packed, instances = Buffer.take()
	local survived = pcall(function()
		inbound.receive(packed, instances, alice)
	end)

	check("an oversized batch does not reach the receive loop", survived)
	equals("only the bound was dispatched", delivered, 4)
	equals("every packet past it was reported", #reported, 6)
	check("at the budget stage", reported[1] ~= nil and string.find(reported[1], "budget:", 1, true) ~= nil)

	Config.reset()
	channel.handler = nil
	byId[85] = nil
	Observer.reset()
end

do
	reset()

	--[[ The bound is per batch, not a running total: the next batch from the same sender starts
	     with an empty pending set. A limit that leaked across batches would blackhole a player
	     after one bad frame, which is the failure `RESEARCH §3.7-K` is about. ]]
	local channel = outboundChannel(86, t.struct({ a = t.u8 }), { class = "signal" })
	byId[86] = channel

	local delivered = 0
	channel.handler = function()
		delivered += 1
	end

	Config.configure({ limits = { pendingPerBatch = 2 } })

	local inbound = inboundOf(true, {})

	for _ = 1, 3 do
		Batch.writePacket(channel, { a = 1 })
	end

	local first, firstInstances = Buffer.take()
	inbound.receive(first, firstInstances, alice)

	equals("the first batch delivered its bound", delivered, 2)

	reset()

	for _ = 1, 2 do
		Batch.writePacket(channel, { a = 1 })
	end

	local second, secondInstances = Buffer.take()
	inbound.receive(second, secondInstances, alice)

	equals("and the next batch starts fresh", delivered, 4)

	Config.reset()
	channel.handler = nil
	byId[86] = nil
	Observer.reset()
end

do
	reset()

	--[[
		Nesting cannot evade the ceiling, because the ceiling is on bytes and nesting is paid for in
		bytes. `t.array(t.array(t.u8, 0, 1000), 0, 1000)` derives 1,002,002 — honest, and useless as
		a limit — so this is the schema a declared `maxBytes` exists for.

		The measurement that settled the shape of this check: after `PLAN-M3` D-4 bounded a claim by
		the bytes behind it, a hostile 1000x1000 packet costs **0.0238 us per byte** and an honest
		packet of the same schema costs **0.0480** — the hostile one is *cheaper per byte*. Decode
		work is proportional to payload size and no longer amplifiable, so bounding the bytes bounds
		the work, and a separate per-element counter would charge every honest packet for a threat
		that no longer exists.
	]]
	local nested = outboundChannel(87, t.array(t.array(t.u8, 0, 1000), 0, 1000), {
		class = "signal",
		maxBytes = 64,
	})

	byId[87] = nested

	local delivered = 0
	nested.handler = function()
		delivered += 1
	end

	local inbound, reported = inboundOf(true, {})

	--[[ Under the ceiling: two inner arrays of ten. ]]
	Batch.writePacket(nested, { { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, { 1, 2, 3 } })

	--[[ Over it, by nesting rather than by one long array — which is the evasion the bound has to
	     be immune to. ]]
	local wide = {}

	for outer = 1, 20 do
		wide[outer] = { 1, 2, 3, 4, 5 }
	end

	Batch.writePacket(nested, wide)

	local packed, instances = Buffer.take()
	local survived = pcall(function()
		inbound.receive(packed, instances, alice)
	end)

	check("a nested payload does not reach the receive loop", survived)
	equals("the one under the ceiling arrived", delivered, 1)
	equals("and the one that nested past it did not", #reported, 1)
	check(
		"refused at the budget stage",
		reported[1] ~= nil and string.find(reported[1], "budget:", 1, true) ~= nil
	)

	equals("the derived ceiling on that schema is honest and useless", nested.codec.maxSize, 1002002)

	nested.handler = nil
	byId[87] = nil
	Observer.reset()
end
reset()

suite.finish()

return true
