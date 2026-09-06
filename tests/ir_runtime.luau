--!strict

--[[
	Layout arithmetic.

		lune run tests/ir_runtime

	The numbers asserted here are the ones `bench/RESULTS.md` will be compared against, so they
	are written as the byte counts a competitor produces rather than as whatever this code
	happens to compute.
]]

local Buffer = require("../src/codec/Buffer")
local Ir = require("../src/codec/Ir")
local Serdes = require("../src/codec/Serdes")
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

do
	--[[ A quantised number carries no encoding of its own — the storage is chosen here, from how
	     many steps the range holds, which is the only place that knows. That is the whole difference
	     from `t.f32`, whose range validates and never narrows. ]]
	local byte = Ir.lower(t.quantized(-1, 1, 2 / 254))
	equals("254 levels fit a byte", byte.root.storage, "u8")
	equals("the lower bound is the offset", byte.root.offset, -1)
	equals("and the step travels with the node", byte.root.step, 2 / 254)
	equals("one byte", byte.fixedSize, 1)

	local pair = Ir.lower(t.quantized(-180, 180, 0.25))
	equals("1440 levels take two", pair.root.storage, "u16")
	equals("two bytes", pair.fixedSize, 2)

	local wide = Ir.lower(t.quantized(0, 1, 1 / 100000))
	equals("100,000 of them take four", wide.root.storage, "u32")
	equals("four bytes", wide.fixedSize, 4)

	--[[ The bound the *reader* is held to is the top level it can reconstruct, not the declaration —
	     for 2.8% of evenly-dividing ranges the two differ by a rounding, and the declaration is the
	     smaller one. `tests/serdes_runtime.luau` has the case that proves it matters. ]]
	local eleven = Ir.lower(t.quantized(0, 100, 100 / 11))
	check("the node's ceiling is the top level, not the declared maximum", (eleven.root.max :: number) >= 100)
end

do
	--[[
		`u53` and `i53` are the only declared encodings with no storage of their own: a span that
		fits four bytes narrows exactly like `u32`, and one that does not is carried in an `f64`,
		where every integer to 2^53 is exact.

		**`offset` is zero on the wide path and has to be.** `value - min` for a bare `t.i53` spans
		2^54, and an odd integer above 2^53 is not representable as a double — so subtracting the
		bound would round the very values the encoding exists to carry.
	]]
	local wide = Ir.lower(t.u53)
	equals("a bare u53 is carried in a double", wide.root.storage, "f64")
	equals("eight bytes", wide.fixedSize, 8)
	equals("with no offset subtracted", wide.root.offset, 0)
	check("and it is a whole number", wide.root.whole == true)

	local signed = Ir.lower(t.i53)
	equals("so is a bare i53", signed.root.storage, "f64")
	equals("and it subtracts nothing either", signed.root.offset, 0)

	local narrow = Ir.lower(t.u53(1, 1000))
	equals("a narrowed u53 takes the storage its span needs", narrow.root.storage, "u16")
	equals("the lower bound is subtracted there", narrow.root.offset, 1)
	equals("two bytes", narrow.fixedSize, 2)

	--[[ The distinction the node has to carry and the storage cannot: both of these are `f64` on the
	     wire, and only one of them is a whole number. ]]
	check("a float is not whole", Ir.lower(t.f64).root.whole == false)
	check("and a quantised number is not either", Ir.lower(t.quantized(-1, 1, 0.5)).root.whole == false)
	check("while an ordinary integer is", Ir.lower(t.u16).root.whole == true)
end

-- ---------------------------------------------------------------------------------------------
-- A union forks the bit budget and takes the widest branch
-- ---------------------------------------------------------------------------------------------

do
	--[[ One tag bit and five flags, forked: `1 + 5`. Summed it would be `1 + 10`, which is the extra
	     byte `tests/serdes_runtime.luau` measures. Zap sums (`RESEARCH §3.9-Y`). ]]
	local forked = Ir.lower(t.union({
		a = t.struct({ p = t.boolean, q = t.boolean, r = t.boolean, s = t.boolean, u = t.boolean }),
		b = t.struct({ v = t.boolean, w = t.boolean, x = t.boolean, y = t.boolean, z = t.boolean }),
	}))

	equals("a tag bit plus the widest branch", forked.root.bits, 6)
	equals("and the flags are one byte", forked.maxSize, 1)

	--[[ Both branches numbered from the same slot, which is what "forked" means where it can be
	     read: the first flag of either branch is the bit after the tag. ]]
	local branches = forked.root.branches :: { Ir.Field }
	local first = (branches[1].node.fields :: { Ir.Field })[1].node
	local second = (branches[2].node.fields :: { Ir.Field })[1].node

	equals("the two branches share their first bit", first.mask, second.mask)
	equals("in the same chunk", first.chunkIndex, second.chunkIndex)

	--[[ Bytes cannot fork, because a byte offset is a position in a run rather than a slot in a
	     bitfield. So a fixed size survives only where every branch agrees on one. ]]
	local same = Ir.lower(t.union({ a = t.u16, b = t.i16 }))
	equals("branches of one width keep a fixed size", same.root.fixedSize, 2)
	equals("and the payload stays static", same.framing, "static")

	local mixed = Ir.lower(t.union({ a = t.u8, b = t.u16 }))
	equals("branches of two widths do not", mixed.root.fixedSize, nil)
	equals("and the ceiling is the widest, not the sum", mixed.maxSize, 3)
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
-- The ceiling against the encoder that has to fit under it
-- ---------------------------------------------------------------------------------------------

--[[
	`maxSize` is the only thing standing between a schema and an unbounded claim, and every channel
	is refused against it before a byte is decoded (`PLAN-M3` D-5). Nothing compared it to what the
	encoder actually writes until an external review did, and it was **below** the encoder for every
	schema whose array or map element carries a flag: `t.array(t.boolean, 0, 10)` derived one byte
	where ten elements cost eleven, so an honest three-element packet was refused at stage `budget`
	against its own sender.

	A table of examples is what phase 3's audit did, and it picked ten schemas that all happened to
	work. What follows is the property instead — encode a maximal value, assert it fits — over a
	list that deliberately includes every place a scope can open.
]]
do
	local function maximal(descriptor: any, depth: number): any
		local kind = descriptor.kind

		if kind == "boolean" then
			return true
		elseif kind == "number" then
			return descriptor.max or 1
		elseif kind == "string" then
			return string.rep("x", descriptor.max or 0)
		elseif kind == "buffer" then
			return buffer.create(descriptor.max or 0)
		elseif kind == "enum" then
			--[[ `variants` is already the sorted name list; the last one has the highest tag. ]]
			return descriptor.variants[#descriptor.variants]
		elseif kind == "optional" then
			--[[ Present, because presence is the expensive branch. ]]
			return maximal(descriptor.inner, depth)
		elseif kind == "vector2" or kind == "vector3" or kind == "cframe" or kind == "color3" then
			return nil
		elseif kind == "array" then
			local out = {}

			for index = 1, descriptor.max do
				out[index] = maximal(descriptor.element, depth + 1)
			end

			return out
		elseif kind == "map" then
			--[[ `t.map` has no declared bound, so its ceiling is the 65,535 the length prefix can
			     express. Filling that many entries would measure the harness rather than the layout,
			     so this fills a handful — the property is "fits under", and a smaller value that
			     still exceeds the ceiling proves the same thing. ]]
			local out = {}

			for index = 1, 6 do
				out[string.format("%04d", index)] = maximal(descriptor.value, depth + 1)
			end

			return out
		elseif kind == "struct" then
			local out = {}

			for name, field in descriptor.fields do
				out[name] = maximal(field, depth + 1)
			end

			return out
		end

		return nil
	end

	local schemas: { { name: string, schema: any } } = {
		{ name = "a bare number", schema = t.u8 },
		{ name = "a struct of scalars", schema = t.struct({ a = t.u8, b = t.u16 }) },
		{ name = "flags at the root", schema = t.struct({ a = t.boolean, b = t.boolean, n = t.u8 }) },
		{ name = "an optional at the root", schema = t.struct({ n = t.optional(t.u8) }) },
		{ name = "a string", schema = t.string(0, 200) },
		{ name = "an array of scalars", schema = t.array(t.u8, 0, 10) },
		{ name = "a fixed array of scalars", schema = t.array(t.u8, 10, 10) },

		--[[ Every one of these opens a scope per element, which is the case the ceiling missed. ]]
		{ name = "an array of booleans", schema = t.array(t.boolean, 0, 10) },
		{ name = "an array of optionals", schema = t.array(t.optional(t.u8), 0, 10) },
		{
			name = "an array of structs carrying a flag",
			schema = t.array(t.struct({ f = t.boolean, x = t.u8 }), 0, 10),
		},
		{
			name = "an array of structs carrying an enum",
			schema = t.array(t.struct({ e = t.enum({ a = true, b = true, c = true }), x = t.u8 }), 0, 8),
		},
		{ name = "an array of arrays of booleans", schema = t.array(t.array(t.boolean, 0, 4), 0, 4) },
		{ name = "a map to booleans", schema = t.map(t.string(0, 4), t.boolean) },
		{
			name = "a map to structs carrying a flag",
			--[[ Through `any`, because a map whose value is a struct infers a payload the analyser
			     will not unify with the key type's parameter here. The schema is the same one either
			     way; what is lost is a type the test does not use. ]]
			schema = (t.map :: any)(t.string(0, 4), t.struct({ f = t.boolean, x = t.u8 })),
		},
		{
			name = "a struct holding an array of flagged elements",
			schema = t.struct({ n = t.u8, list = t.array(t.boolean, 0, 12) }),
		},

		--[[ A fixed-length array unrolls its positions into the enclosing scope rather than opening
		     one each, so this is the control that must not move. ]]
		{ name = "a fixed array of booleans", schema = t.array(t.boolean, 8, 8) },
	}

	for _, case in schemas do
		local codec = Serdes.fromSchema(case.schema)

		Buffer.take()
		Buffer.load(nil)
		codec.write(maximal(case.schema, 0))

		local actual = buffer.len((Buffer.take()))

		check(`{case.name}: {actual} bytes fits under a ceiling of {codec.maxSize}`, actual <= codec.maxSize)
	end
end

-- ---------------------------------------------------------------------------------------------

if failures > 0 then
	error(`{failures} layout assertions failed`)
end

print("OK      ir_runtime")

return true
