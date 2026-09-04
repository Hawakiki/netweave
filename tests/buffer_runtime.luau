--!strict

--[[
	Byte-layer behaviour.

		lune run tests/buffer_runtime

	The two things worth being paranoid about are here: that a read past the end returns a value
	instead of throwing, and that a `save`/`load` swap really does keep two buffers apart.
]]

local Codec = require("../src/codec/Buffer")

local failures = 0

local function check(name: string, condition: boolean)
	if not condition then
		failures += 1
		print(`FAIL  {name}`)
	end
end

local function roundTrip(name: string, write: () -> (), read: () -> boolean)
	Codec.load(nil)
	write()

	local packed = Codec.take()
	Codec.beginRead(packed, {})

	check(name, read())
	check(`{name} consumed everything`, Codec.cursor() == buffer.len(packed))
	check(`{name} was not rejected`, Codec.rejected() == nil)
end

-- ---------------------------------------------------------------------------------------------
-- Every primitive round-trips at its boundaries
-- ---------------------------------------------------------------------------------------------

roundTrip("u8 bounds", function()
	Codec.writeU8(0)
	Codec.writeU8(255)
end, function()
	return Codec.readU8() == 0 and Codec.readU8() == 255
end)

roundTrip("u16 bounds", function()
	Codec.writeU16(0)
	Codec.writeU16(65535)
end, function()
	return Codec.readU16() == 0 and Codec.readU16() == 65535
end)

roundTrip("u32 bounds", function()
	Codec.writeU32(0)
	Codec.writeU32(4294967295)
end, function()
	return Codec.readU32() == 0 and Codec.readU32() == 4294967295
end)

roundTrip("i8 bounds", function()
	Codec.writeI8(-128)
	Codec.writeI8(127)
end, function()
	return Codec.readI8() == -128 and Codec.readI8() == 127
end)

roundTrip("i16 bounds", function()
	Codec.writeI16(-32768)
	Codec.writeI16(32767)
end, function()
	return Codec.readI16() == -32768 and Codec.readI16() == 32767
end)

roundTrip("i32 bounds", function()
	Codec.writeI32(-2147483648)
	Codec.writeI32(2147483647)
end, function()
	return Codec.readI32() == -2147483648 and Codec.readI32() == 2147483647
end)

roundTrip("f32", function()
	Codec.writeF32(0.5)
end, function()
	return Codec.readF32() == 0.5
end)

roundTrip("f64", function()
	Codec.writeF64(1 / 3)
end, function()
	return Codec.readF64() == 1 / 3
end)

roundTrip("string", function()
	Codec.writeString("netweave", 8)
end, function()
	return Codec.readString(8) == "netweave"
end)

roundTrip("buffer", function()
	local payload = buffer.create(3)
	buffer.writeu8(payload, 0, 7)
	buffer.writeu8(payload, 1, 8)
	buffer.writeu8(payload, 2, 9)
	Codec.writeBuffer(payload, 3)
end, function()
	local value = Codec.readBuffer(3)
	return buffer.len(value) == 3 and buffer.readu8(value, 0) == 7 and buffer.readu8(value, 2) == 9
end)

-- ---------------------------------------------------------------------------------------------
-- Varint, including the byte-count boundaries the wire format promises
-- ---------------------------------------------------------------------------------------------

local function varintBytes(value: number): number
	Codec.load(nil)
	Codec.writeVarint(value)
	return Codec.used()
end

check("varint 0 is one byte", varintBytes(0) == 1)
check("varint 127 is one byte", varintBytes(127) == 1)
check("varint 128 is two bytes", varintBytes(128) == 2)
check("varint 16383 is two bytes", varintBytes(16383) == 2)
check("varint 16384 is three bytes", varintBytes(16384) == 3)

roundTrip("varint round trip", function()
	Codec.writeVarint(0)
	Codec.writeVarint(127)
	Codec.writeVarint(128)
	Codec.writeVarint(4294967295)
end, function()
	return Codec.readVarint() == 0
		and Codec.readVarint() == 127
		and Codec.readVarint() == 128
		and Codec.readVarint() == 4294967295
end)

--[[ A run of continuation bytes must terminate rather than spin. ]]
do
	local hostile = buffer.create(8)
	for offset = 0, 7 do
		buffer.writeu8(hostile, offset, 0xFF)
	end

	Codec.beginRead(hostile, {})
	Codec.readVarint()
	check("varint of continuation bytes is rejected", Codec.rejected() == "varint too long")
end

-- ---------------------------------------------------------------------------------------------
-- Reading past the end returns a value, never an error
-- ---------------------------------------------------------------------------------------------

do
	local empty = buffer.create(0)

	Codec.beginRead(empty, {})
	local ok, result = pcall(Codec.readU8)
	check("read past the end does not throw", ok)
	check("read past the end yields zero", result == 0)
	check("read past the end is recorded", Codec.rejected() == "truncated")
end

do
	local short = buffer.create(2)
	Codec.beginRead(short, {})

	local ok = pcall(function()
		Codec.readU32()
		Codec.readF64()
		Codec.readString(400)
		Codec.readBuffer(400)
	end)

	check("every oversized read is survivable", ok)
	check("cursor did not move past the limit", Codec.cursor() <= buffer.len(short))
end

--[[ The first reason is the one that explains the failure; later ones are consequences. ]]
do
	Codec.beginRead(buffer.create(0), {})
	Codec.reject("first")
	Codec.reject("second")
	check("the first rejection wins", Codec.rejected() == "first")

	Codec.clearRejection()
	check("rejection clears", Codec.rejected() == nil)
end

-- ---------------------------------------------------------------------------------------------
-- The limit is the packet end, not the buffer end
-- ---------------------------------------------------------------------------------------------

do
	local batch = buffer.create(4)
	buffer.writeu8(batch, 0, 1)
	buffer.writeu8(batch, 1, 2)
	buffer.writeu8(batch, 2, 3)
	buffer.writeu8(batch, 3, 4)

	Codec.beginRead(batch, {})
	Codec.setLimit(2)

	check("reads inside the limit succeed", Codec.readU8() == 1 and Codec.readU8() == 2)
	check("the limit is not the buffer end", Codec.readU8() == 0)
	check("crossing the limit is a rejection", Codec.rejected() == "truncated")

	Codec.clearRejection()
	Codec.setLimit(4)
	Codec.seek(2)
	check("the next packet reads fine", Codec.readU8() == 3 and Codec.readU8() == 4)
	check("no rejection after seeking", Codec.rejected() == nil)
end

-- ---------------------------------------------------------------------------------------------
-- Reserve and patch, which is how a bitfield gets written
-- ---------------------------------------------------------------------------------------------

roundTrip("reserve then patch", function()
	local slot = Codec.reserve(2)
	Codec.writeU8(42)
	Codec.patchU16(slot, 0xBEEF)
end, function()
	return Codec.readU16() == 0xBEEF and Codec.readU8() == 42
end)

-- ---------------------------------------------------------------------------------------------
-- Save and load really do keep buffers apart
-- ---------------------------------------------------------------------------------------------

do
	Codec.load(nil)
	Codec.writeU8(1)
	local first = Codec.save()

	Codec.load(nil)
	Codec.writeU8(2)
	Codec.writeU8(3)
	local second = Codec.save()

	Codec.load(first)
	check("first buffer kept its own length", Codec.used() == 1)
	local firstBytes = Codec.take()
	check("first buffer kept its own bytes", buffer.readu8(firstBytes, 0) == 1)

	Codec.load(second)
	check("second buffer kept its own length", Codec.used() == 2)
	local secondBytes = Codec.take()
	check("second buffer kept its own bytes", buffer.readu8(secondBytes, 1) == 3)
end

-- ---------------------------------------------------------------------------------------------
-- Growth
-- ---------------------------------------------------------------------------------------------

do
	Codec.load(nil)
	for index = 1, 1000 do
		Codec.writeU16(index)
	end

	check("grew to hold everything", Codec.used() == 2000)

	local packed = Codec.take()
	check("take copies to the exact size", buffer.len(packed) == 2000)

	Codec.beginRead(packed, {})
	local intact = true
	for index = 1, 1000 do
		if Codec.readU16() ~= index then
			intact = false
			break
		end
	end
	check("growth preserved the contents", intact)
end

-- ---------------------------------------------------------------------------------------------
-- Instances travel beside the buffer
-- ---------------------------------------------------------------------------------------------

do
	--[[ lune has no DataModel, and the sidecar never inspects what it holds — it only has to keep
	     order and count. Two distinct tables prove that as well as two Folders would. ]]
	local a = (table.freeze({ name = "a" }) :: any) :: Instance
	local b = (table.freeze({ name = "b" }) :: any) :: Instance

	Codec.load(nil)
	Codec.writeInstance(a)
	Codec.writeInstance(b)

	local packed, instances = Codec.take()
	check("instances are not in the buffer", buffer.len(packed) == 0)
	check("instances kept their order", instances[1] == a and instances[2] == b)

	Codec.beginRead(packed, instances)
	check("instances read back in order", Codec.readInstance() == a and Codec.readInstance() == b)
	check("running out yields nil", Codec.readInstance() == nil)

	Codec.beginRead(packed, instances)
	Codec.skipInstances(1)
	check("skipping advances the sidecar", Codec.readInstance() == b)
end

-- ---------------------------------------------------------------------------------------------

if failures > 0 then
	error(`{failures} buffer assertions failed`)
end

print("OK      buffer_runtime")

return true
