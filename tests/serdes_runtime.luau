--!strict

--[[
	Round trips, encode rejections, and a hostile decoder.

		lune run tests/serdes_runtime

	The adversarial half is the point of the file. Every case below is something a modified client
	can put on the wire, and the requirement is not that netweave produces the right answer — there
	is no right answer to a corrupt packet — but that it produces *a value*, never a raised error
	(`DESIGN-API` G4, `RESEARCH §3.8-R`). A single `error` here would let one byte from one player
	abort a batch belonging to everyone.

	`Vector3`, `CFrame`, `Color3` and classed instances are absent because they do not exist under
	lune. They are covered in the Studio place, which is what `test.project.json` is for.
]]

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

--[[ Structural comparison, because a decoded struct is a fresh table every time. ]]
local function same(a: any, b: any): boolean
	if a == b then
		return true
	end

	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end

	for key, value in a do
		if not same(value, b[key]) then
			return false
		end
	end

	for key in b do
		if a[key] == nil then
			return false
		end
	end

	return true
end

local function describe(value: any): string
	if type(value) ~= "table" then
		return tostring(value)
	end

	local parts = {}
	for key, entry in value do
		table.insert(parts, `{tostring(key)}={describe(entry)}`)
	end
	table.sort(parts)
	return `\{{table.concat(parts, ", ")}\}`
end

-- ---------------------------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------------------------

local function encode(codec: Serdes.Codec, value: any): (buffer, { Instance })
	codec.write(value)
	return Buffer.take()
end

local function decode(codec: Serdes.Codec, bytes: buffer, instances: { Instance }?): (any, string?)
	Buffer.beginRead(bytes, instances)
	return codec.read()
end

--[[ Round trips `value` and reports the byte count, so the size assertions and the equality
     assertions come from one encode rather than two. ]]
local function trip(name: string, descriptor: any, value: any, bytes: number?)
	local codec = Serdes.fromSchema(descriptor)

	local ok, packed, instances = pcall(encode, codec, value)

	if not ok then
		fail(`{name}: encode raised {tostring(packed)}`)
		Buffer.load(nil)
		return
	end

	local size = buffer.len(packed :: buffer)

	if bytes and size ~= bytes then
		fail(`{name}: expected {bytes} bytes, got {size}`)
	end

	local decoded, failure = decode(codec, packed :: buffer, instances :: { Instance })

	if failure then
		fail(`{name}: decode rejected with "{failure}"`)
		return
	end

	if not same(value, decoded) then
		fail(`{name}: {describe(value)} came back as {describe(decoded)}`)
	end
end

--[[ Encode-side failures are programmer error and must raise; a silent wraparound on the wire is
     the outcome this replaces. ]]
local function refuses(name: string, descriptor: any, value: any)
	local codec = Serdes.fromSchema(descriptor)
	local ok = pcall(codec.write, value)

	--[[ A partial write is left in the outgoing buffer, and the next test would inherit it. ]]
	Buffer.load(nil)

	if ok then
		fail(`{name}: encode accepted a value it should have refused`)
	end
end

--[[ The decoder must survive `bytes` and say so. `nil` for `reason` means any rejection will do. ]]
local function rejects(name: string, descriptor: any, bytes: buffer, reason: string?)
	local codec = Serdes.fromSchema(descriptor)

	local ok, value, failure = pcall(decode, codec, bytes, {})

	if not ok then
		fail(`{name}: decode raised {tostring(value)}`)
		return
	end

	if failure == nil then
		fail(`{name}: decode accepted {buffer.len(bytes)} bytes it should have rejected`)
		return
	end

	if reason and failure ~= reason then
		fail(`{name}: rejected with "{failure}", expected "{reason}"`)
	end

	equals(`{name}: a rejected read yields no value`, value, nil)
end

local function bytes(...: number): buffer
	local values = { ... }
	local result = buffer.create(#values)

	for index, value in values do
		buffer.writeu8(result, index - 1, value)
	end

	return result
end

-- ---------------------------------------------------------------------------------------------
-- Scalars
-- ---------------------------------------------------------------------------------------------

trip("boolean true", t.boolean, true, 1)
trip("boolean false", t.boolean, false, 1)

trip("u8", t.u8, 200, 1)
trip("u16", t.u16, 40000, 2)
trip("u32", t.u32, 4000000000, 4)
trip("i8", t.i8, -100, 1)
trip("i16", t.i16, -30000, 2)
trip("i32", t.i32, -2000000000, 4)
trip("f32", t.f32, 0.5, 4)
trip("f64", t.f64, 0.1, 8)

do
	--[[ The narrowing claim, checked on the wire rather than in the layout: a 255-wide `u16` range
	     is one byte, and the value that comes back is the one that went in, not the offset. ]]
	trip("a narrowed u16 costs a byte", t.u16(1000, 1255), 1200, 1)
	trip("a narrowed u16 keeps its low bound", t.u16(1000, 1255), 1000, 1)
	trip("a narrowed u16 keeps its high bound", t.u16(1000, 1255), 1255, 1)
	trip("a signed range travels unsigned", t.i16(-100, 100), -100, 1)
	trip("and reaches its top", t.i16(-100, 100), 100, 1)
	trip("floats are not narrowed", t.f32(-90, 90), -90, 4)
end

trip("a fixed string has no prefix", t.string(4, 4), "abcd", 4)
trip("a bounded string is prefixed", t.string(0, 200), "hello", 6)
trip("an empty bounded string", t.string(0, 200), "", 1)

do
	local source = buffer.fromstring("payload")
	local codec = Serdes.fromSchema(t.buffer(0, 100))
	local packed = encode(codec, source)
	local decoded = decode(codec, packed, {})

	equals("a buffer keeps its length", buffer.len(decoded), 7)
	equals("and its contents", buffer.tostring(decoded), "payload")
end

-- ---------------------------------------------------------------------------------------------
-- Enums and optionals live in the bitfield
-- ---------------------------------------------------------------------------------------------

trip("a single-variant enum is free", t.enum({ only = true }), "only", 0)
trip("a three-variant enum is one byte", t.enum({ a = true, b = true, c = true }), "c", 1)

trip("an absent optional is one bit", t.optional(t.u8), nil, 1)
trip("a present optional adds its value", t.optional(t.u8), 7, 2)
trip("an optional boolean is two bits and no bytes", t.optional(t.boolean), false, 1)
trip("and still round trips true", t.optional(t.boolean), true, 1)
trip("and nil", t.optional(t.boolean), nil, 1)

-- ---------------------------------------------------------------------------------------------
-- Structs
-- ---------------------------------------------------------------------------------------------

local entity = t.struct({
	id = t.u8,
	x = t.u8,
	y = t.u8,
	z = t.u8,
	orientation = t.u8,
	animation = t.u8,
})

local entityValue = { id = 1, x = 2, y = 3, z = 4, orientation = 5, animation = 6 }

trip("Entity is six bytes", entity, entityValue, 6)

do
	--[[ The M0 array-heavy payload. Blink and Zap both put 601 B on the wire for this, one byte of
	     which is the packet id, so 600 is the number to match. ]]
	local values = table.create(100)
	for index = 1, 100 do
		values[index] = { id = index, x = index, y = index, z = index, orientation = 1, animation = 2 }
	end

	trip("ArrayHeavy is 600 bytes", t.array(entity, 100), values, 600)
end

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

do
	--[[
		17 bits of flags is three bytes, plus two for the present `u16` and one for the `u8`. Zap
		reaches 6 B on this payload and Blink reaches 9 B with `set`; this is the assertion that
		says netweave matched the better of them (`RESEARCH §3.9-AA`).
	]]
	trip("FlagIdiomatic is six bytes", flags, {
		f1 = true,
		f2 = false,
		f3 = true,
		f4 = false,
		f5 = true,
		f6 = false,
		f7 = true,
		f8 = false,
		f9 = true,
		f10 = false,
		f11 = true,
		f12 = true,
		weapon = "melee",
		team = "blue",
		targetId = 40000,
		combo = 9,
	}, 6)

	trip("and three bytes with both optionals absent", flags, {
		f1 = false,
		f2 = false,
		f3 = false,
		f4 = false,
		f5 = false,
		f6 = false,
		f7 = false,
		f8 = false,
		f9 = false,
		f10 = false,
		f11 = false,
		f12 = false,
		weapon = "primary",
		team = "red",
		targetId = nil,
		combo = nil,
	}, 3)
end

do
	--[[ A nested struct folds its flags into the parent, so three booleans across two levels are
	     still one byte. ]]
	trip(
		"nested flags fold up",
		t.struct({
			a = t.boolean,
			nested = t.struct({ b = t.boolean, c = t.boolean }),
		}),
		{ a = true, nested = { b = false, c = true } },
		1
	)
end

-- ---------------------------------------------------------------------------------------------
-- Arrays and maps
-- ---------------------------------------------------------------------------------------------

trip("boolean[8] is one byte", t.array(t.boolean, 8), {
	true,
	false,
	true,
	false,
	true,
	true,
	false,
	true,
}, 1)

--[[ An unbounded array declares no maximum, so its length prefix is sized for 65535 and costs
     two bytes. Declaring `t.array(t.u8, 0, 200)` halves that, which is the incentive the bound
     exists to create. ]]
trip("a dynamic array of numbers", t.array(t.u8), { 1, 2, 3 }, 5)
trip("an empty dynamic array", t.array(t.u8), {}, 2)

do
	--[[ A dynamic array cannot fold its elements' flags, so each element opens its own byte: one
	     length byte plus one per element. ]]
	trip("a dynamic array of booleans", t.array(t.boolean), { true, false, true }, 5)
end

trip("a bounded array narrows its prefix", t.array(t.u8, 10, 20), {
	1,
	2,
	3,
	4,
	5,
	6,
	7,
	8,
	9,
	10,
}, 11)

trip("a map of numbers", t.map(t.u8, t.u16), { [1] = 100, [2] = 200 }, 8)
trip("an empty map", t.map(t.u8, t.u16), {}, 2)
trip("a map with a flagged value", t.map(t.u8, t.boolean), { [7] = true }, 4)

do
	--[[ Every kind at once, so an ordering mistake between the bitfield and the values shows up as
	     a mismatch rather than as a coincidence that happens to survive a simpler schema. ]]
	local mixed = t.struct({
		alive = t.boolean,
		name = t.string(0, 32),
		team = t.enum({ red = true, blue = true, spectator = true }),
		scores = t.array(t.u16, 0, 8),
		tags = t.map(t.u8, t.boolean),
		nickname = t.optional(t.string(0, 16)),
		position = t.struct({ x = t.i16(-500, 500), y = t.i16(-500, 500) }),
	})

	trip("a schema using every lune-safe kind", mixed, {
		alive = true,
		name = "netweave",
		team = "spectator",
		scores = { 10, 20, 30 },
		tags = { [1] = true, [2] = false },
		nickname = "nw",
		position = { x = -250, y = 480 },
	})

	trip("the same schema at its empty edges", mixed, {
		alive = false,
		name = "",
		team = "red",
		scores = {},
		tags = {},
		nickname = nil,
		position = { x = -500, y = -500 },
	})
end

-- ---------------------------------------------------------------------------------------------
-- Instances travel beside the buffer, not in it
-- ---------------------------------------------------------------------------------------------

do
	--[[ `Instance.new` does not exist under lune, and the sidecar only preserves order and count,
	     so a frozen table stands in. Class checking needs a real instance and is covered in the
	     Studio place. ]]
	local first = table.freeze({}) :: any
	local second = table.freeze({}) :: any

	local codec = Serdes.fromSchema(t.struct({ a = t.instance, b = t.instance }))
	local packed, instances = encode(codec, { a = first, b = second })

	equals("instances take no buffer bytes", buffer.len(packed), 0)
	equals("and travel in the sidecar", #instances, 2)

	local decoded = decode(codec, packed, instances)
	check("the first instance survives", decoded.a == first)
	check("the second instance survives", decoded.b == second)
end

-- ---------------------------------------------------------------------------------------------
-- Encode refuses what the schema forbids
-- ---------------------------------------------------------------------------------------------

refuses("a number above its range", t.u8(0, 100), 200)
refuses("a number below its range", t.u8(10, 100), 5)
refuses("a float outside its range", t.f32(-90, 90), 91)
refuses("a NaN", t.f32(-90, 90), 0 / 0)
refuses("an unknown enum variant", t.enum({ a = true, b = true }), "c")
refuses("a missing struct field", t.struct({ a = t.u8, b = t.u8 }), { a = 1 })
refuses("an array of the wrong exact length", t.array(t.u8, 4), { 1, 2, 3 })
refuses("an array above its bound", t.array(t.u8, 0, 2), { 1, 2, 3 })
refuses("a string above its bound", t.string(0, 4), "toolong")

-- ---------------------------------------------------------------------------------------------
-- Decode survives a hostile sender
-- ---------------------------------------------------------------------------------------------

rejects("an empty buffer where a byte was promised", t.u8, bytes(), "truncated")
rejects("a truncated u32", t.u32, bytes(1, 2), "truncated")
rejects("a truncated struct", t.struct({ a = t.u8, b = t.u16 }), bytes(1, 2), "truncated")

do
	--[[
		The narrowing hole. `t.u8(0, 200)` writes its value in a byte, and a byte holds 255, so a
		modified client can put 255 into a field the schema caps at 200. Nothing in the encoding
		catches this — only the bound carried onto the node does.
	]]
	rejects("a number past a narrowed bound", t.u8(0, 200), bytes(255), "number out of range")
	--[[ `t.u16(1000, 1255)` has a span of exactly 255, so the byte is full and nothing can overflow
	     it. A span with slack is where the hole is: 200 fits in a byte that holds 255. ]]
	rejects("an offset number past its bound", t.u16(1000, 1200), bytes(255), "number out of range")
	trip("and a full span has no slack to exploit", t.u16(1000, 1255), 1255, 1)
end

do
	--[[ Same hole, on a length. This one matters more: everything downstream of a length
	     allocates. ]]
	rejects("an array length past its bound", t.array(t.u8, 0, 3), bytes(200), "length out of range")
	rejects("a string length past its bound", t.string(0, 4), bytes(200), "length out of range")
	rejects("a map length past its bound", t.map(t.u8, t.u8), bytes(255, 255, 255, 255, 255), nil)
end

do
	--[[ An honest length with nothing behind it. The reader must stop at the limit rather than
	     reading whatever the batch happens to hold next. ]]
	rejects("an array that claims more than it carries", t.array(t.u8, 0, 10), bytes(10, 1, 2), nil)
	rejects("a string that claims more than it carries", t.string(0, 10), bytes(10, 65), nil)
end

do
	--[[ Three variants occupy two bits, so a sender can put 3 in them and name a variant that does
	     not exist. Without the check the handler receives nil where it declared a string. ]]
	rejects(
		"an enum tag with no variant",
		t.enum({ a = true, b = true, c = true }),
		bytes(3),
		"unknown enum variant"
	)
end

do
	--[[ A float field is the one place a NaN can arrive, and NaN passes every comparison a
	     downstream check is likely to write. ]]
	local nan = buffer.create(4)
	buffer.writef32(nan, 0, 0 / 0)
	rejects("a NaN float", t.f32(-90, 90), nan, "number out of range")

	local infinite = buffer.create(4)
	buffer.writef32(infinite, 0, math.huge)
	rejects("an infinite float", t.f32(-90, 90), infinite, "number out of range")
end

do
	--[[ The sidecar is attacker-influenced too: a client that sends fewer instances than the
	     schema declares must not produce a nil where a handler expects an Instance. ]]
	rejects("a missing instance", t.instance, bytes(), "missing instance")
end

-- ---------------------------------------------------------------------------------------------
-- Fuzz: no byte sequence may raise
-- ---------------------------------------------------------------------------------------------

do
	--[[
		The assertions above are the failures that were thought of. This is the cheap guard against
		the ones that were not: it does not check that decoding is correct, only that it terminates
		and returns. Seeded so a failure is reproducible.
	]]
	local schemas: { any } = {
		t.u8,
		t.f32(-90, 90),
		t.string(0, 200),
		t.buffer(0, 64),
		t.enum({ a = true, b = true, c = true }),
		t.optional(t.u16),
		flags,
		entity,
		t.array(t.u8, 0, 64),
		t.array(t.boolean, 0, 32),
		t.array(entity, 0, 16),
		t.map(t.u8, t.u16),
		t.map(t.string(0, 8), t.boolean),
		t.struct({ a = t.optional(t.array(t.u8, 0, 8)), b = t.map(t.u8, t.boolean) }),
	}

	--[[ `Random` is a Roblox datatype and does not exist under lune; the seed still makes a
	     failure reproducible. ]]
	math.randomseed(20260903)
	local raised = 0
	local cases = 0

	for _, descriptor in schemas do
		local codec = Serdes.fromSchema(descriptor)

		for length = 0, 24 do
			for _ = 1, 12 do
				local corrupt = buffer.create(length)

				for offset = 0, length - 1 do
					buffer.writeu8(corrupt, offset, math.random(0, 255))
				end

				cases += 1

				local ok, err = pcall(decode, codec, corrupt, {})

				if not ok then
					raised += 1

					if raised <= 3 then
						print(`      raised on {length} bytes: {tostring(err)}`)
					end
				end
			end
		end
	end

	equals(`{cases} random payloads raised nothing`, raised, 0)
end

-- ---------------------------------------------------------------------------------------------
-- A rejection does not poison the next packet
-- ---------------------------------------------------------------------------------------------

do
	--[[ G5: one malformed packet must not stop the rest of its batch. If `read` carried a rejection
	     forward, every packet after the first bad one would fail for the wrong reason. ]]
	local codec = Serdes.fromSchema(t.u8(0, 100))

	local _, first = decode(codec, bytes(200), {})
	check("the bad packet is rejected", first ~= nil)

	local value, second = decode(codec, bytes(42), {})
	equals("the next packet is not", second, nil)
	equals("and decodes correctly", value, 42)
end

-- ---------------------------------------------------------------------------------------------
-- Fixed-size blocks
-- ---------------------------------------------------------------------------------------------

do
	--[[
		A payload whose size is known claims all of it in one allocation and fills it with writers
		that skip the bounds check (`src/codec/Buffer.luau`, Blocks). Two things about that are
		worth pinning, because both fail silently.
	]]
	local Fixed = t.struct({ a = t.u8, b = t.u16, c = t.f32 })
	local codec = Serdes.fromSchema(Fixed)

	equals("a fixed schema knows its size", codec.fixedSize, 7)
	equals("and needs no length prefix", codec.framing, "static")

	--[[
		The one that bit: **encode raises on a value the schema forbids, and a raise between
		opening a block and closing it leaves the block open.** Nothing closes it, so the next
		payload writes through a stale cursor into space nobody claimed — and produces a buffer of
		length zero, because the allocation that would have moved `used` never ran.

		This is not an edge case. Raising on bad input is the encode-side posture, so the leak is
		on the ordinary path.
	]]
	local ok = pcall(function()
		codec.write({ a = 999, b = 1, c = 1 })
	end)

	check("an out-of-range field still refuses", not ok)

	--[[ A raised write leaves the bytes it managed to emit, block or no block, so the caller
	     discards them. That part is the documented contract; what is under test is that the
	     *block state* did not survive to corrupt what comes next. ]]
	Buffer.take()

	codec.write({ a = 1, b = 2, c = 3 })
	local packed = Buffer.take()

	equals("and the payload after it is unharmed", buffer.len(packed), 7)

	Buffer.beginRead(packed, nil)
	local value, failure = codec.read()

	equals("and decodes", failure, nil)
	equals("field a", value.a, 1)
	equals("field b", value.b, 2)
	equals("field c", value.c, 3)
end

do
	--[[
		A block filled short is a codec bug that corrupts the wire *silently*: the reader is
		symmetric, so it would read the missing bytes back from the same wrong place without
		complaining. `closeBlock` compares the cursor against the claim so that it fails loudly
		instead (`PLAN-M2` R-4).
	]]
	Buffer.openBlock(4)
	Buffer.putU8(1)

	local short = pcall(Buffer.closeBlock)
	check("a block filled short is refused", not short)

	--[[ And the refusal leaves the buffer usable rather than wedged. ]]
	Buffer.take()

	local codec = Serdes.fromSchema(t.u8)
	codec.write(9)
	--[[ Parenthesised: `take` returns the buffer *and* the instance sidecar, and passing both to
	     `buffer.len` is an argument-count error rather than a truncation. ]]
	local recovered = Buffer.take()
	equals("the buffer still works afterwards", buffer.len(recovered), 1)
end

-- ---------------------------------------------------------------------------------------------

if failures > 0 then
	error(`{failures} serdes assertions failed`)
end

print("OK      serdes_runtime")

return true
