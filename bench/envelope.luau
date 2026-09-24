--!strict
--!optimize 2

--[[
	The batch envelope `bench/src/shared/Modes/netweave.luau` builds, checked without Studio.

		lune run bench/envelope

	Two jobs. The first is a fast failure: a Studio round trip reports a framing bug a minute later
	as "the payload garbled", and this reports it in a second with the offending byte count.

	The second is `CLAUDE.md` §5 — never report a number that was not produced by a committed,
	re-runnable script. The bytes per packet that `bench/RESULTS.md` prints for netweave are the
	ones asserted here, and they are asserted against the same channel declarations the adapter
	uses, not a copy of them — ~~and written and read by a copy of the framing.~~ **Written and read
	by `Batch` itself** since PLAN-M4-BUG phase 7: the copy this file carried had drifted from the
	real writer's instance-count reservation and two-byte widening, and matched the real bytes only
	because neither schema carries an instance (M4-1). A model that would keep passing after a
	framing change is not a check of the framing.
]]

local Batch = require("../src/transport/Batch")
local Buffer = require("../src/codec/Buffer")
local nw = require("../src/netweave")
local t = require("../src/types")
local failures = 0

local function check(name: string, condition: boolean)
	if not condition then
		failures += 1
		print(`FAIL  {name}`)
	end
end

local function equals(name: string, actual: any, expected: any)
	if actual ~= expected then
		failures += 1
		print(`FAIL  {name}: expected {tostring(expected)}, got {tostring(actual)}`)
	end
end

local accept = nw.policy(function()
	return function()
		return nw.allow()
	end
end)

local Entity = t.struct({
	id = t.u8,
	x = t.u8,
	y = t.u8,
	z = t.u8,
	orientation = t.u8,
	animation = t.u8,
})

local Flags = t.struct({
	f1 = t.boolean,
	f2 = t.boolean,
	f3 = t.boolean,
	f4 = t.boolean,
	f5 = t.boolean,
	f6 = t.boolean,
	f7 = t.boolean,
	f8 = t.boolean,
	f9 = t.boolean,
	f10 = t.boolean,
	f11 = t.boolean,
	f12 = t.boolean,
	weapon = t.enum({ primary = true, secondary = true, melee = true, grenade = true }),
	team = t.enum({ red = true, blue = true }),
	targetId = t.optional(t.u16),
	combo = t.optional(t.u8),
})

local ArrayHeavy = t.array(Entity, 100, 100)

local bench = nw.namespace("bench", {
	ArrayHeavyUp = nw.command({ data = ArrayHeavy, rate = 60000, authorize = accept }),
	FlagIdiomaticUp = nw.command({ data = Flags, rate = 60000, authorize = accept }),
	FlagNaiveUp = nw.command({ data = Flags, rate = 60000, authorize = accept }),
	ArrayHeavyDown = nw.event({ data = ArrayHeavy, audience = nw.audience.everyone }),
	FlagIdiomaticDown = nw.event({ data = Flags, audience = nw.audience.everyone }),
	FlagNaiveDown = nw.event({ data = Flags, audience = nw.audience.everyone }),

	--[[
		Not a benchmark channel. The six above cannot fail to decode: every bit pattern of twelve
		booleans, a four-variant enum, a two-variant enum and two presence flags is a *valid*
		payload, and every byte of a `u8` entity field is in range. That is worth knowing on its
		own — corrupting those schemas produces wrong data, not rejected data — but it leaves
		nothing to test G5 against, so this channel exists to carry a value the decoder can refuse.
	]]
	BoundedUp = nw.command({
		data = t.struct({ n = t.u8(0, 200), maybe = t.optional(t.u8) }),
		rate = 60000,
		authorize = accept,
	}),
})

local protocol = nw.protocol()
local channels = bench.channels :: any
local byId: { [number]: any } = {}

for _, channel in channels do
	byId[channel.id] = channel
end

equals("seven channels are numbered", protocol.count, 7)

-- ---------------------------------------------------------------------------------------------
-- Framing, per schema
-- ---------------------------------------------------------------------------------------------

equals("ArrayHeavy is static", channels.ArrayHeavyUp.codec.framing, "static")
equals("and its size is fixed", channels.ArrayHeavyUp.codec.fixedSize, 600)
equals("FlagIdiomatic is counted", channels.FlagIdiomaticUp.codec.framing, "counted")

-- ---------------------------------------------------------------------------------------------
-- Writing and reading, through the real envelope
-- ---------------------------------------------------------------------------------------------

local function write(channel: any, value: any)
	Batch.writePacket(channel, value)
end

local received: { { name: string, value: any } } = {}

--[[ The sink `Batch.read` calls, collecting what arrived and what was refused in one list so the
     order across both is asserted. Everything else is a server that admits everything and serves
     nothing: the envelope is what is under test, not the transport around it. ]]
local sink: Batch.Sink = {
	resolve = function(id: number): any
		return byId[id]
	end,

	answers = true,

	admit = function(): (string?, Batch.Stage?)
		return nil, nil
	end,

	deliver = function(channel: any, value: any)
		table.insert(received, { name = channel.qualified, value = value })
	end,

	change = function() end,
	reply = function() end,
	hello = function() end,
	resync = function() end,

	refuse = function(channel: any?, _stage: string, reason: string)
		table.insert(received, { name = if channel then channel.qualified else "?", value = reason })
	end,
}

local function receive(packed: buffer)
	Batch.read(packed, nil, sink)
end

local entities = {}

for index = 1, 100 do
	entities[index] = {
		id = index % 256,
		x = 1,
		y = 2,
		z = 3,
		orientation = 4,
		animation = 5,
	}
end

local flags: any = {
	weapon = "melee",
	team = "blue",
	targetId = 4321,
	combo = 7,
}

for index = 1, 12 do
	flags[`f{index}`] = index % 2 == 0
end

-- ---------------------------------------------------------------------------------------------
-- One packet of each, in one batch
-- ---------------------------------------------------------------------------------------------

do
	write(channels.FlagIdiomaticUp, flags)
	local packed = Buffer.take()

	--[[ 1 version + 1 id + 1 length + 6 payload. `WIRE-FORMAT.md` §2 claims 8 bytes per packet,
	     which is the id, the length and the payload; the version byte is per batch. ]]
	equals("a single counted packet is nine bytes", buffer.len(packed), 9)

	table.clear(received)
	receive(packed)
	equals("one packet arrived", #received, 1)
	equals("on the right channel", received[1].name, "bench.FlagIdiomaticUp")
	equals("with its enum intact", received[1].value.weapon, "melee")
	equals("and its optional", received[1].value.targetId, 4321)
	equals("and a flag", received[1].value.f2, true)
end

do
	write(channels.ArrayHeavyUp, entities)
	local packed = Buffer.take()

	--[[ 1 version + 1 id + 600 payload, and no length prefix because the schema is static. ]]
	equals("a single static packet is 602 bytes", buffer.len(packed), 602)

	table.clear(received)
	receive(packed)
	equals("one packet arrived", #received, 1)
	equals("with all its entities", #received[1].value, 100)
	equals("and the last one intact", received[1].value[100].id, 100)
end

do
	--[[ The case the envelope exists for: several packets, mixed framing, one batch. ]]
	write(channels.FlagIdiomaticUp, flags)
	write(channels.ArrayHeavyUp, entities)
	write(channels.FlagNaiveUp, flags)
	write(channels.FlagIdiomaticUp, flags)

	local packed = Buffer.take()
	equals("the batch is one version byte plus four packets", buffer.len(packed), 1 + 8 + 601 + 8 + 8)

	table.clear(received)
	receive(packed)

	equals("four packets arrived", #received, 4)
	equals("in order 1", received[1].name, "bench.FlagIdiomaticUp")
	equals("in order 2", received[2].name, "bench.ArrayHeavyUp")
	equals("in order 3", received[3].name, "bench.FlagNaiveUp")
	equals("in order 4", received[4].name, "bench.FlagIdiomaticUp")
	equals("the array survived being in the middle", #received[2].value, 100)
	equals("and the packet after it", received[3].value.combo, 7)
end

do
	--[[
		G5: a packet the decoder refuses must not stop the ones behind it. The length prefix is what
		makes that possible, and it is the entire argument for paying a byte for it — Blink and Zap
		have no length field, so one bad packet costs the rest of the batch (`RESEARCH §3.8-R`).
	]]
	write(channels.BoundedUp, { n = 5, maybe = 9 })
	write(channels.FlagNaiveUp, flags)
	local packed = Buffer.take()

	--[[
		version, id, length, then the payload — and inside it the presence bitfield, then the fields
		in sorted name order, `maybe` before `n` (`WIRE-FORMAT.md` §5). So `n` is the sixth byte,
		not the fourth, and asserting that before corrupting it is the point: a layout change would
		otherwise turn this into a test that corrupts nothing and passes.

		`t.u8(0, 200)` narrows to one byte and leaves slack above 200, so 255 is a value the schema
		forbids and the decoder can see that it does.
	]]
	equals("the presence bitfield is first", buffer.readu8(packed, 3), 1)
	equals("then the optional", buffer.readu8(packed, 4), 9)
	equals("then the bounded field", buffer.readu8(packed, 5), 5)

	buffer.writeu8(packed, 5, 255)

	table.clear(received)
	receive(packed)

	equals("both packets were visited", #received, 2)
	check("the first was rejected", type(received[1].value) == "string")
	check("the second decoded anyway", type(received[2].value) == "table")
	equals("and arrived intact", received[2].value.combo, 7)
end

do
	--[[ Both flag columns use one schema, so they must produce identical bytes. That is the
	     automatic-packing claim (`PLAN-M1` D-3) stated as a measurement rather than an assertion. ]]
	write(channels.FlagIdiomaticUp, flags)
	local idiomatic = buffer.len((Buffer.take()))

	write(channels.FlagNaiveUp, flags)
	local naive = buffer.len((Buffer.take()))

	equals("idiomatic and naive cost the same", idiomatic, naive)
end

if failures > 0 then
	error(`{failures} envelope assertions failed`)
end

print("OK      envelope")
