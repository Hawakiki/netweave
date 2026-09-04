--!strict

--[[
	Layout arithmetic.

		lune run tests/ir_runtime

	The numbers asserted here are the ones `bench/RESULTS.md` will be compared against, so they
	are written as the byte counts a competitor produces rather than as whatever this code
	happens to compute.
]]

local Ir = require("../src/codec/Ir")
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

-- ---------------------------------------------------------------------------------------------
-- Bitfield chunking: the fewest bytes, never the widest accumulator
-- ---------------------------------------------------------------------------------------------

local function chunkBytes(bits: number): number
	local total = 0
	for _, chunk in Ir.bitChunks(bits) do
		total += chunk.width
	end
	return total
end

equals("0 bits costs nothing", chunkBytes(0), 0)
equals("1 bit is one byte", chunkBytes(1), 1)
equals("8 bits is one byte", chunkBytes(8), 1)
equals("9 bits is two bytes", chunkBytes(9), 2)
equals("17 bits is three bytes", chunkBytes(17), 3)
equals("32 bits is four bytes", chunkBytes(32), 4)
equals("33 bits is five bytes", chunkBytes(33), 5)
equals("56 bits is seven bytes", chunkBytes(56), 7)

do
	--[[ 17 bits must be `u16 + u8`, not a single `u32` that wastes fifteen. ]]
	local chunks = Ir.bitChunks(17)
	equals("17 bits uses two chunks", #chunks, 2)
	equals("first chunk is u16", chunks[1].width, 2)
	equals("second chunk is u8", chunks[2].width, 1)
	equals("second chunk starts at byte 2", chunks[2].offset, 2)
end

-- ---------------------------------------------------------------------------------------------
-- Numbers narrow to their range
-- ---------------------------------------------------------------------------------------------

do
	local layout = Ir.lower(t.u16(1000, 1255))
	equals("a 255-wide u16 range fits a byte", layout.root.storage, "u8")
	equals("the lower bound is subtracted", layout.root.offset, 1000)
	equals("and it is one byte", layout.fixedSize, 1)
end

do
	local layout = Ir.lower(t.i16(-100, 100))
	equals("a signed range travels unsigned", layout.root.storage, "u8")
	equals("offset is the signed minimum", layout.root.offset, -100)
end

do
	local layout = Ir.lower(t.f32(-90, 90))
	equals("floats keep their encoding", layout.root.storage, "f32")
	equals("floats are not narrowed", layout.fixedSize, 4)
end

-- ---------------------------------------------------------------------------------------------
-- The M0 benchmark schemas, in the byte counts the competitors produced
-- ---------------------------------------------------------------------------------------------

local entity = t.struct({
	id = t.u8,
	x = t.u8,
	y = t.u8,
	z = t.u8,
	orientation = t.u8,
	animation = t.u8,
})

do
	local layout = Ir.lower(entity)
	equals("Entity is six bytes", layout.fixedSize, 6)
	equals("Entity has no flags", layout.root.bits, 0)
	equals("Entity is statically framed", layout.framing, "static")
end

do
	--[[ Blink and Zap both put 601 B on the wire for this, one of which is the packet id. ]]
	local layout = Ir.lower(t.array(entity, 100))
	equals("ArrayHeavy is 600 bytes", layout.fixedSize, 600)
	equals("ArrayHeavy needs no length prefix", layout.framing, "static")
end

do
	--[[
		FlagIdiomatic: 12 booleans, a three-variant enum, a two-variant enum, and two optionals.
		12 + 2 + 1 + 1 + 1 = 17 bits, so three bytes of flags plus the two present values.
		Zap reaches 6 B on this payload; Blink reaches 9 B with `set` and 19 B without.
	]]
	local flags = t.struct({
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
		weapon = t.enum({ primary = true, secondary = true, melee = true }),
		team = t.enum({ red = true, blue = true }),
		targetId = t.optional(t.u16),
		combo = t.optional(t.u8),
	})

	local layout = Ir.lower(flags)
	equals("FlagIdiomatic packs into 17 bits", layout.root.bits, 17)
	equals("which is three bytes", (layout.scope :: Ir.Scope).bytes, 3)
	equals("optionals make it counted", layout.framing, "counted")
end

-- ---------------------------------------------------------------------------------------------
-- Flags fold upward through structs, and an exact array unrolls
-- ---------------------------------------------------------------------------------------------

do
	--[[ Eight booleans are one byte. Blink spends eight unless the author reaches for `set`. ]]
	local layout = Ir.lower(t.array(t.boolean, 8))
	equals("boolean[8] is eight bits", layout.root.bits, 8)
	equals("boolean[8] is one byte", layout.fixedSize, 1)
	equals("boolean[8] is statically framed", layout.framing, "static")
	equals("each position got its own slot", #(layout.root.elements :: { Ir.Node }), 8)

	local masks = {}
	for _, element in layout.root.elements :: { Ir.Node } do
		masks[element.mask :: number] = true
	end

	local distinct = 0
	for _ in masks do
		distinct += 1
	end
	equals("the eight slots are distinct", distinct, 8)
end

do
	--[[ A nested struct does not open a bitfield of its own; its flags belong to the parent. ]]
	local layout = Ir.lower(t.struct({
		a = t.boolean,
		nested = t.struct({ b = t.boolean, c = t.boolean }),
	}))

	equals("nested flags fold up", layout.root.bits, 3)
	equals("into a single byte", layout.fixedSize, 1)
end

do
	--[[ An optional boolean is two bits and no bytes, so a struct of them stays static. ]]
	local layout = Ir.lower(t.struct({ a = t.optional(t.boolean), b = t.optional(t.boolean) }))
	equals("optional booleans are two bits each", layout.root.bits, 4)
	equals("and cost no data bytes", layout.fixedSize, 1)
	equals("so the packet is statically framed", layout.framing, "static")
end

do
	--[[ A dynamic array cannot fold its elements' flags, so each element opens its own byte. ]]
	local layout = Ir.lower(t.array(t.boolean))
	equals("a dynamic array contributes no flags", layout.root.bits, 0)
	equals("its element carries its own scope", (layout.root.element :: Ir.Node).scope ~= nil, true)
	equals("which is one byte", ((layout.root.element :: Ir.Node).scope :: Ir.Scope).bytes, 1)
	equals("and the packet is counted", layout.framing, "counted")
end

-- ---------------------------------------------------------------------------------------------
-- Enums cost bits, not bytes
-- ---------------------------------------------------------------------------------------------

do
	equals("one variant is free", Ir.lower(t.enum({ only = true })).root.bits, 0)
	equals("two variants cost a bit", Ir.lower(t.enum({ a = true, b = true })).root.bits, 1)
	equals("three cost two", Ir.lower(t.enum({ a = true, b = true, c = true })).root.bits, 2)
	equals("four cost two", Ir.lower(t.enum({ a = true, b = true, c = true, d = true })).root.bits, 2)
	equals(
		"five cost three",
		Ir.lower(t.enum({ a = true, b = true, c = true, d = true, e = true })).root.bits,
		3
	)
end

do
	local layout = Ir.lower(t.enum({ melee = true, primary = true, secondary = true }))
	local lookup = layout.root.lookup :: { [string]: number }
	equals("variants are indexed in sorted order", lookup.melee, 1)
	equals("primary is second", lookup.primary, 2)
	equals("secondary is third", lookup.secondary, 3)
end

-- ---------------------------------------------------------------------------------------------
-- Lengths, strings and instances
-- ---------------------------------------------------------------------------------------------

do
	local layout = Ir.lower(t.string(8, 8))
	equals("a fixed-length string has no prefix", Ir.lengthSize(layout.root), 0)
	equals("and is statically framed", layout.framing, "static")
	equals("at exactly its length", layout.fixedSize, 8)
end

do
	local layout = Ir.lower(t.string(0, 200))
	equals("a short string's prefix is one byte", Ir.lengthSize(layout.root), 1)
	equals("and it is counted", layout.framing, "counted")
end

do
	local layout = Ir.lower(t.array(t.u8, 10, 20))
	equals("a bounded array narrows its prefix", layout.root.lengthStorage, "u8")
	equals("and subtracts the lower bound", layout.root.lengthOffset, 10)
end

do
	local layout = Ir.lower(t.struct({ a = t.instance, b = t.instance("Sound") }))
	equals("instances are counted", layout.root.instances, 2)
	equals("and take no buffer bytes", layout.fixedSize, 0)
	equals("the class is carried through", (layout.root.fields :: any)[2].node.class, "Sound")
end

do
	local layout = Ir.lower(t.struct({ a = t.optional(t.instance) }))
	equals("an optional instance count is not static", layout.root.instances, nil)
end

-- ---------------------------------------------------------------------------------------------
-- Templates exist so decode never rehashes
-- ---------------------------------------------------------------------------------------------

do
	local layout = Ir.lower(entity)
	local template = layout.root.template :: { [string]: boolean }

	local keys = 0
	for _ in template do
		keys += 1
	end

	equals("the template has every field", keys, 6)
	check("the template is frozen", table.isfrozen(template))
	check("cloning it yields a mutable table", not table.isfrozen(table.clone(template)))
end

-- ---------------------------------------------------------------------------------------------
-- The same schema used twice gets independent bit slots
-- ---------------------------------------------------------------------------------------------

do
	local shared = t.boolean
	local layout = Ir.lower(t.struct({ a = shared, b = shared }))
	local fields = layout.root.fields :: any

	equals("both fields are lowered", #fields, 2)
	check("their slots differ", fields[1].node.mask ~= fields[2].node.mask)
end

-- ---------------------------------------------------------------------------------------------

if failures > 0 then
	error(`{failures} layout assertions failed`)
end

print("OK      ir_runtime")

return true
