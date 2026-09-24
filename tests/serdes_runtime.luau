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
local Ir = require("../src/codec/Ir")
local Serdes = require("../src/codec/Serdes")
local harness = require("./harness")
local t = require("../src/types")

--[[ This file measures `Buffer.used()` after every write, so it starts from a buffer it knows is
     empty. Under lune each suite is its own process and that is free; in Studio they share one, and
     a suite that ran earlier can leave bytes parked in an `Outbound` — which is exactly what
     happened, and cost a run's worth of confusion before phase 8's rehearsal caught it. ]]
Buffer.take()
Buffer.load(nil)

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

local function decode(codec: Serdes.Codec, bytes: buffer, instances: { unknown }?): (any, string?)
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

	local decoded, failure = decode(codec, packed :: buffer, instances :: { unknown })

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

	--[[ The wire half of the widened float range (M4 report). Both of these were refused at `write`
	     against a bound the author never declared — `f32` at 2^24 and `f64` at 2^53, which are the
	     spans in which each encoding holds every *integer* exactly and not the values it can carry.
	     Both are exactly representable, so a round trip is the right assertion. ]]
	trip("f32 carries a number past the integer-exact span", t.f32, 1e8, 4)
	trip("f64 carries one past its own", t.f64, 1e18, 8)

	--[[ And the end that still has to refuse: past the largest finite value the encoding holds, a
	     float becomes `inf` on the wire. ]]
	refuses("f32 past its largest finite value", t.f32, 1e39)
	refuses("f64 past a double's", t.f64, math.huge)
end

do
	--[[
		**A bound an f32 cannot hold, sent back at that bound.**

		The writer validates the double the game passed against the bounds it declared, then
		`buffer.writef32` rounds — and if the bound is not itself an f32 value the rounding can land
		outside it. `t.f32(-pi, pi)` refused pi at `parse`, against its own sender, on a value it had
		accepted one line earlier: f32(pi) is 3.14159274 and pi is 3.14159265.

		Measured before the fix: **2,054 of 4,000** random f32 ranges refused their own bounds when
		sent back. The bound is also the value a game sends most often, because it is what
		`math.clamp(yaw, -math.pi, math.pi)` produces. `trip` cannot express this case — the value
		that comes back is deliberately not the value that went in — so the assertion is that it
		arrives at all, and within a rounding of where it was sent.

		`t.f32(-90, 90)` in the section above survived only because 90 is exactly representable,
		which is why the suite never saw this: every bound it used was dyadic.
	]]
	--[[ The scalar rather than a struct around it: `t.struct` reads its fields at analysis, and a
	     schema arriving through an `any` parameter is not one it can read. ]]
	local function bound(name: string, descriptor: any, value: number)
		local codec = Serdes.fromSchema(descriptor)

		Buffer.take()
		Buffer.load(nil)

		local wrote = pcall(codec.write, value)

		if not wrote then
			Buffer.load(nil)
			fail(`{name}: the encoder refused a value inside the declared range`)
			return
		end

		Buffer.beginRead((Buffer.take()), nil)
		local back, failure = codec.read()

		if failure then
			fail(`{name}: decode rejected with "{failure}"`)
			return
		end

		check(`{name} arrives within a rounding of what was sent`, math.abs(back - value) < 1e-6)
	end

	bound("an f32 upper bound of pi", t.f32(-math.pi, math.pi), math.pi)
	bound("an f32 lower bound of -pi", t.f32(-math.pi, math.pi), -math.pi)
	bound("an f32 upper bound of 0.1", t.f32(0, 0.1), 0.1)
	bound("an f32 upper bound of 0.3", t.f32(0, 0.3), 0.3)
	bound("a dyadic bound, which always worked", t.f32(0, 1), 1)
	bound("and f64, which is exact for a double", t.f64(0, 0.1), 0.1)

	--[[ Widening the reader's bound must not widen the *writer's*: the declared range is the
	     author's contract and a value outside it is still a programmer error. ]]
	refuses(
		"a value past a non-representable bound is still refused",
		t.f32(-math.pi, math.pi),
		math.pi + 0.01
	)
	refuses("and one below it", t.f32(-math.pi, math.pi), -math.pi - 0.01)
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
	local first = harness.instance("first")
	local second = harness.instance("second")

	local codec = Serdes.fromSchema(t.struct({ a = t.instance, b = t.instance }))
	local packed, instances = encode(codec, { a = first, b = second })

	equals("instances take no buffer bytes", buffer.len(packed), 0)
	equals("and travel in the sidecar", #instances, 2)

	local decoded = decode(codec, packed, instances :: { unknown })
	check("the first instance survives", decoded.a == first)
	check("the second instance survives", decoded.b == second)
end

do
	--[[
		`check` serialises for real — that is the whole design, so that the encoder stays the only
		statement of what a value must satisfy — and then throws the result away. What it used to
		fail to throw away was the sidecar: `Buffer.load` restores the count and leaves the entries
		the trial write appended past it, so every `nw.validate` of a payload carrying an Instance
		kept a reference to it until some later write happened to reuse that slot.

		Found by an external review (M3 phase 9). `mark`/`rollback` is the pair that clears them,
		and it is the one the send path already uses for an encode that raised.
	]]
	local codec = Serdes.fromSchema(t.struct({ a = t.instance }))
	local held = harness.instance("held")

	Buffer.load(nil)

	local before = Buffer.save()
	equals("nothing is parked to begin with", before.instanceCount, 0)

	equals("the value validates", codec.check({ a = held }), nil)

	local after = Buffer.save()

	equals("and the count is back where it started", after.instanceCount, 0)
	check("with nothing left in the slot past it", after.instances[1] == nil)

	--[[ And a value that fails halfway leaves no more behind than one that passed. ]]
	check("a bad value is refused", codec.check({ a = 12345 }) ~= nil)
	check("and holds nothing either", Buffer.save().instances[1] == nil)

	Buffer.load(nil)
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

--[[
	Everything below passed the encoder until M3 phase 9, and `nw.validate` decides "this value
	conforms" by running the encoder — so each of these was a value branded `Trusted<T>` while
	failing the schema it was checked against.

	The boolean writer tested truthiness, so `"false"` went on the wire as `true`. The instance
	writer tested only non-nil. The integer writers checked the range and let `buffer.writeu8`
	truncate the fraction, which with an offset is not even truncation: `-0.4` on
	`t.i16(-100, 100)` stored as `99` and read back as `-1`.
]]
refuses("a string where a boolean was declared", t.boolean, "false")
refuses("a number where a boolean was declared", t.boolean, 0)
refuses("nil where a boolean was declared", t.boolean, nil)
refuses("a number where an instance was declared", t.instance, 12345)
refuses("a table with no IsA where an instance was declared", t.instance, {})
refuses("a fraction where a u8 was declared", t.u8, 3.7)
refuses("a fraction inside an offset range", t.i16(-100, 100), -0.4)
refuses("a fraction inside a plain range", t.u16(0, 1000), 500.5)

--[[ And the floats still take fractions, which is the whole point of declaring one. ]]
do
	local codec = Serdes.fromSchema(t.f32(-90, 90))
	local packed = encode(codec, 12.5)

	equals("a float takes a fraction", decode(codec, packed), 12.5)
end

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

-- ---------------------------------------------------------------------------------------------
-- A claim is not paid for until it is honoured (PLAN-M3 D-4)
-- ---------------------------------------------------------------------------------------------

do
	--[[
		`arrayReader` allocated `table.create(count)` from the wire's claimed count before reading a
		single element, so a two-byte packet claiming 65535 bought a 65535-slot table. The packet
		was then correctly *rejected* — the rejection was free, the allocation was not.

		A source comment on that line read "the length was already bounded, so this is a cost
		question, not a safety one". It is struck through in `PLAN-M3` D-4: a cost an attacker
		controls and does not pay for is an amplification. At 0.17 ms per hostile packet and roughly
		five bytes to express one, a single 900-byte batch bought about 31 ms of decode.

		Zap has the same shape (`_refsrc/zap/zap/src/irgen/des.rs:298`) and no bounds check on its
		buffer reads at all, so the equivalent packet there raises and takes the whole batch. The
		half netweave already had right was the recovery; this is the half it did not.
	]]
	local codec = Serdes.fromSchema(t.array(t.u8))

	local hostile = buffer.create(2)
	buffer.writeu16(hostile, 0, 65535)

	Buffer.beginRead(hostile, nil)
	local value, failure = codec.read()

	equals("a claim past the packet decodes to nothing", value, nil)
	check("and is refused", failure ~= nil)
	check(
		"naming the claim rather than the byte it died on",
		failure ~= nil and string.find(failure, "65535", 1, true) ~= nil
	)

	--[[
		The functional assertion above is the test; this is the reason the test exists. The bound is
		deliberately loose — 20x against a measured 690x — because a timing assertion that is tight
		is a timing assertion that fails on somebody else's machine.
	]]
	local honest = buffer.create(3)
	buffer.writeu16(honest, 0, 1)
	buffer.writeu8(honest, 2, 7)

	local function timed(packed: buffer, runs: number): number
		local start = os.clock()

		for _ = 1, runs do
			Buffer.beginRead(packed, nil)
			codec.read()
		end

		return os.clock() - start
	end

	timed(honest, 200)

	local honestCost = timed(honest, 2000)
	local hostileCost = timed(hostile, 2000)

	check(
		`a refused claim costs about what an honest packet costs (honest {honestCost}, hostile {hostileCost})`,
		hostileCost < honestCost * 20 + 0.05
	)
end

do
	--[[ The bound is the bytes that remain, not a constant, so a claim that *is* backed by bytes
	     still decodes. This is the case a naive cap would have broken. ]]
	local codec = Serdes.fromSchema(t.array(t.u8))

	local honest = buffer.create(302)
	buffer.writeu16(honest, 0, 300)

	for index = 0, 299 do
		buffer.writeu8(honest, 2 + index, index % 256)
	end

	Buffer.beginRead(honest, nil)
	local value, failure = codec.read()

	equals("a claim the packet can back decodes", failure, nil)
	equals("with every element", if value then #value else 0, 300)
	--[[ The three-hundredth element was written as `299 % 256`. ]]
	equals("in order", if value then value[300] else nil, 43)
end

do
	--[[ An element whose size is not known at build time cannot be bounded by multiplication, so
	     the pre-allocation is capped at the bytes available instead. The claim still fails, and it
	     still fails without buying memory for it first. ]]
	local codec = Serdes.fromSchema(t.array(t.string(0, 200)))

	local hostile = buffer.create(2)
	buffer.writeu16(hostile, 0, 65535)

	Buffer.beginRead(hostile, nil)
	local value, failure = codec.read()

	equals("a dynamic element claim decodes to nothing", value, nil)
	check("and is refused", failure ~= nil)
end

-- ---------------------------------------------------------------------------------------------
-- A struct of numbers, written in one claim (PLAN-M4 phase 7)
-- ---------------------------------------------------------------------------------------------

--[[
	`Serdes.fusedStructWriter` is a second implementation of what `structWriter` does, taken for
	every struct whose fields are all fixed-size numbers — which is most of them. It writes the same
	bytes by a different route: one claim, offsets computed at declaration, the checks unrolled, and
	the primitive named at the call site rather than looked up.

	Two implementations of one contract is the shape that drifts (`CLAUDE.md` §9), so what follows
	walks the seams between them: the arity boundary, a storage of each width, an offset field, a
	float, a dynamic array where the bytes are not claimed in advance, and each of the three
	messages. The round trips above already cover the happy path; these are the edges where the two
	writers could disagree without anything noticing.
]]

do
	--[[ One field, which is the shortest the unroll goes, and eight, which is the last arity before
	     it hands back to the loop. Nine is the loop, and it has to produce the same bytes. ]]
	trip("a one-field struct", t.struct({ a = t.u8 }), { a = 7 }, 1)

	trip(
		"eight fields, the last arity the unroll covers",
		t.struct({
			a = t.u8,
			b = t.u8,
			c = t.u8,
			d = t.u8,
			e = t.u8,
			f = t.u8,
			g = t.u8,
			h = t.u8,
		}),
		{ a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8 },
		8
	)

	trip(
		"nine, which falls back to the loop",
		t.struct({
			a = t.u8,
			b = t.u8,
			c = t.u8,
			d = t.u8,
			e = t.u8,
			f = t.u8,
			g = t.u8,
			h = t.u8,
			i = t.u8,
		}),
		{ a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8, i = 9 },
		9
	)

	--[[ One field of each width the branch chain names, in one struct, so a chain that fell through
	     to the wrong arm would put the bytes in the wrong place and the round trip would say so. ]]
	trip(
		"every storage the chain names, mixed",
		t.struct({ a = t.u8, b = t.u16, c = t.u32, d = t.f32, e = t.f64 }),
		{ a = 200, b = 60000, c = 4000000000, d = 0.5, e = 0.25 },
		19
	)

	--[[ A declared minimum is subtracted before the value is stored and added back on the way out.
	     The fused writer does that subtraction itself rather than through `numberWriter`, which is
	     exactly the kind of thing a second implementation forgets. ]]
	trip(
		"fields whose storage is narrowed against a declared minimum",
		t.struct({ a = t.i16(-100, 100), b = t.u16(1000, 1255) }),
		{ a = -100, b = 1255 },
		2
	)

	trip("and the other end of both ranges", t.struct({ a = t.i16(-100, 100), b = t.u16(1000, 1255) }), {
		a = 100,
		b = 1000,
	}, 2)

	--[[ A float is the one case where the whole-number check must *not* fire. ]]
	trip(
		"a struct of floats keeps its fractions",
		t.struct({ x = t.f32, y = t.f64 }),
		{ x = 0.5, y = 0.125 },
		12
	)

	--[[ Inside a dynamic array the payload's size is not known, so nothing is claimed in advance and
	     `Buffer.claim` has to allocate instead of stepping a cursor. Same struct, different path
	     through the primitive, and the bytes have to match. ]]
	trip(
		"a dynamic array of them, where the bytes are not claimed up front",
		t.array(t.struct({ x = t.u8, y = t.u8 }), 0, 4),
		{ { x = 1, y = 2 }, { x = 3, y = 4 }, { x = 5, y = 6 } },
		7
	)

	--[[ And nested, where the outer struct is not fusable and the inner one is. ]]
	trip(
		"a fused struct inside one that is not",
		t.struct({ tag = t.string(0, 8), pos = t.struct({ x = t.u8, y = t.u8 }) }),
		{ tag = "hi", pos = { x = 3, y = 4 } },
		5
	)
end

do
	--[[ The three refusals, which are `numberWriter`'s messages and have to stay its messages: a
	     missing field names the field, and the other two name the value. Checked as text rather than
	     as "it raised", because the reason a schema-driven encoder is worth having is that it says
	     which field. ]]
	local codec = Serdes.fromSchema(t.struct({ a = t.u8, b = t.u8 }))

	local _, missing = pcall(codec.write, { a = 1 })
	Buffer.load(nil)
	check(
		`a missing field names it, not an offset: {tostring(missing)}`,
		string.find(tostring(missing), 'field "b" is missing', 1, true) ~= nil
	)

	local _, high = pcall(codec.write, { a = 1, b = 900 })
	Buffer.load(nil)
	check(
		`a value over the range says so: {tostring(high)}`,
		string.find(tostring(high), "outside the declared range 0..255", 1, true) ~= nil
	)

	local _, fraction = pcall(codec.write, { a = 1, b = 1.5 })
	Buffer.load(nil)
	check(
		`a fraction in an integer field says so: {tostring(fraction)}`,
		string.find(tostring(fraction), "not a whole number", 1, true) ~= nil
	)

	--[[ The same three, from the sixth slot rather than the second, because the unroll writes each
	     field out separately and a check pasted eight times is eight chances to name the wrong
	     variable. ]]
	local wide = Serdes.fromSchema(t.struct({
		a = t.u8,
		b = t.u8,
		c = t.u8,
		d = t.u8,
		e = t.u8,
		f = t.u8,
	}))

	local _, sixth = pcall(wide.write, { a = 1, b = 2, c = 3, d = 4, e = 5 })
	Buffer.load(nil)
	check(
		`the sixth field is named when it is the one missing: {tostring(sixth)}`,
		string.find(tostring(sixth), 'field "f" is missing', 1, true) ~= nil
	)

	refuses("and a value under the declared minimum", t.struct({ a = t.i16(-100, 100) }), { a = -101 })
end

do
	--[[
		**The check the whole optimisation rests on**: the two writers agree, byte for byte, on a
		struct the fused one takes and one it refuses.

		`t.struct` with a boolean in it is not fusable — a flag lives in the payload's bitfield, not
		at a byte offset — so this pair runs both implementations over the same values and compares
		what came out. A divergence here is a wire that decodes to the wrong thing on a client that
		is a version behind, which is the failure mode no round trip in this file would catch,
		because both ends would be wrong together.
	]]
	local fused = Serdes.fromSchema(t.struct({ a = t.u8, b = t.u16, c = t.u8, d = t.u8, e = t.u8, f = t.u8 }))

	--[[ Nine fields is past `FUSED_MAX`, so this one is written by the loop — the same fields in the
	     same order, plus three the comparison ignores. Fields are emitted in name order, so the six
	     shared ones occupy the same first bytes in both. ]]
	local looped = Serdes.fromSchema(t.struct({
		a = t.u8,
		b = t.u16,
		c = t.u8,
		d = t.u8,
		e = t.u8,
		f = t.u8,
		g = t.u8,
		h = t.u8,
		i = t.u8,
	}))

	local sample = { a = 9, b = 4000, c = 3, d = 4, e = 5, f = 6 }

	Buffer.take()
	Buffer.load(nil)
	fused.write(sample)
	local one = (Buffer.take())

	Buffer.load(nil)
	looped.write({ a = 9, b = 4000, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8, i = 9 })
	local two = (Buffer.take())

	equals("the fused struct is seven bytes", buffer.len(one), 7)
	equals("and the looped one is those seven plus three", buffer.len(two), 10)

	local identical = true

	for offset = 0, 6 do
		if buffer.readu8(one, offset) ~= buffer.readu8(two, offset) then
			identical = false
		end
	end

	check("and the two writers produced the same bytes", identical)

	Buffer.load(nil)
end

-- ---------------------------------------------------------------------------------------------
-- A struct of numbers, read in one span (M4 phase 8)
-- ---------------------------------------------------------------------------------------------

--[[
	`Serdes.fusedStructReader` is the writer's mirror and carries the same hazard: two
	implementations of one contract, one of which is only taken for some schemas. Every `trip` above
	runs a fused struct through both halves, so the honest path is covered already.

	What is *not* covered by a round trip is bytes a peer chose rather than bytes netweave wrote —
	and that is the whole of the read side's job. The reader validates where the writer refuses, and
	it may never raise doing it (G4), so these are the seams: a value the wire put outside the
	declared range, a run that does not fit, and the bound an f32 can actually hold.

	The optimisation behind them, from `bench/decode.luau`: a 600-byte packet went **32,731 → 21,475
	ns**, against 8,193 for the same read written out by hand with the range guard kept.
]]

do
	--[[ The two readers over the same bytes. The pair above proved the first seven bytes are
	     identical whichever writer produced them; this proves the two readers make the same values
	     out of them, which is the half a wire format cares about. ]]
	local fused = Serdes.fromSchema(t.struct({ a = t.u8, b = t.u16, c = t.u8, d = t.u8, e = t.u8, f = t.u8 }))

	local looped = Serdes.fromSchema(t.struct({
		a = t.u8,
		b = t.u16,
		c = t.u8,
		d = t.u8,
		e = t.u8,
		f = t.u8,
		g = t.u8,
		h = t.u8,
		i = t.u8,
	}))

	Buffer.take()
	Buffer.load(nil)
	fused.write({ a = 9, b = 4000, c = 3, d = 4, e = 5, f = 6 })
	local one = (Buffer.take())

	Buffer.load(nil)
	looped.write({ a = 9, b = 4000, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8, i = 9 })
	local two = (Buffer.take())

	local short = decode(fused, one)
	local long = decode(looped, two)

	local agree = short ~= nil
		and long ~= nil
		and short.a == long.a
		and short.b == long.b
		and short.c == long.c
		and short.d == long.d
		and short.e == long.e
		and short.f == long.f

	check("the two readers made the same values out of the same bytes", agree)
	equals("and the widest field survived the chain", short.b, 4000)
end

do
	--[[ A declared minimum is subtracted on the way out and added back here, and the maximum is the
	     one thing the storage cannot enforce: a span of ten is carried in a byte that holds 255. So
	     this is a value only a peer can produce, which is what the reader exists for. ]]
	local narrow = Serdes.fromSchema(t.struct({ a = t.u8(10, 20) }))
	local narrowed = buffer.create(1)

	buffer.writeu8(narrowed, 0, 5)
	local honest = decode(narrow, narrowed)

	equals("a byte inside the narrowed range reads back with the minimum added", honest.a, 15)

	buffer.writeu8(narrowed, 0, 250)
	local value, failure = decode(narrow, narrowed)

	check("one past the declared maximum is refused", failure ~= nil)
	equals("and nothing is handed up", value, nil)
end

do
	--[[ From the **eighth** slot, because the range check is pasted eight times and a check pasted
	     eight times is eight chances to compare the wrong variable. Fields are emitted in name
	     order, so `h` is the last one the unroll covers. ]]
	local eight = Serdes.fromSchema(t.struct({
		a = t.u8,
		b = t.u8,
		c = t.u8,
		d = t.u8,
		e = t.u8,
		f = t.u8,
		g = t.u8,
		h = t.u8(10, 20),
	}))

	local wide = buffer.create(8)

	for at = 0, 6 do
		buffer.writeu8(wide, at, 1)
	end

	buffer.writeu8(wide, 7, 250)
	local _, eighth = decode(eight, wide)

	check("the check in the eighth slot fires as well as the first", eighth ~= nil)

	buffer.writeu8(wide, 7, 5)
	local whole = decode(eight, wide)

	check("and lets an honest value through", whole ~= nil and whole.h == 15)
	check("with the seven before it intact", whole.a == 1 and whole.g == 1)
end

do
	--[[ The span is the bounds check, so a run that does not fit is where the whole optimisation is
	     either safe or a read past the end of the buffer. Three bytes of a six-byte struct. ]]
	local six = Serdes.fromSchema(t.struct({
		a = t.u8,
		b = t.u8,
		c = t.u8,
		d = t.u8,
		e = t.u8,
		f = t.u8,
	}))

	local cut = buffer.create(3)
	local value, failure = decode(six, cut)

	check("a struct cut short is refused rather than read past", failure ~= nil)
	check(
		`and says the packet ran out: {tostring(failure)}`,
		string.find(tostring(failure), "truncated") ~= nil
	)
	equals("with nothing handed up", value, nil)

	--[[ And the packet after it still decodes, which is G5: one malformed packet must not stop the
	     rest. The rejection is cleared per payload, not per batch. ]]
	local whole = buffer.create(6)

	for at = 0, 5 do
		buffer.writeu8(whole, at, at + 1)
	end

	local after = decode(six, whole)
	check("while the next one still arrives", after ~= nil and after.a == 1 and after.f == 6)
end

do
	--[[
		**The f32 finding, through the fused path.**

		The reader compares against the bound the *encoding* can hold, not the one the game declared:
		f32(pi) is 3.14159274 against pi's 3.14159265, so a reader holding the declared bound refuses
		a value its own writer had just accepted. That was fixed in `numberReader` earlier in this
		milestone; the fused reader carries its own copy of the comparison, and a copy is a place for
		the fix to not be.
	]]
	local yaw = Serdes.fromSchema(t.struct({
		a = t.f32(-math.pi, math.pi),
		b = t.f32(-math.pi, math.pi),
	}))

	Buffer.take()
	Buffer.load(nil)
	yaw.write({ a = math.pi, b = -math.pi })
	local packed = (Buffer.take())

	local back, refused = decode(yaw, packed)

	check(`a fused struct accepts the bounds it just wrote: {tostring(refused)}`, refused == nil)
	check("both ends of them", back ~= nil and back.a > 3.1415 and back.b < -3.1415)

	Buffer.load(nil)
end

-- ---------------------------------------------------------------------------------------------
-- A float carried as a count of steps
-- ---------------------------------------------------------------------------------------------

--[[
	`t.quantized(min, max, step)` is the one range on a fractional value that narrows the storage.
	`t.f32(-1, 1)` is four bytes whatever the range, because a float is never re-encoded; this is
	the declaration that says how much precision the author needs, and the layout then spends it.

	It never round-trips exactly, which is the point and is why `trip` cannot express any of this:
	the value that comes back is the nearest step, so every assertion here is about **how far** it
	came back rather than whether it is identical.
]]

local function within(a: any, b: number, tolerance: number): boolean
	return type(a) == "number" and math.abs(a - b) <= tolerance
end

do
	local STEP = 2 / 254
	local normal = Serdes.fromSchema(t.quantized(-1, 1, STEP))

	local function roundTrip(value: number): (any, number)
		Buffer.take()
		Buffer.load(nil)
		normal.write(value)

		local packed = (Buffer.take())
		Buffer.beginRead(packed, nil)

		return (normal.read()), buffer.len(packed)
	end

	local mid, size = roundTrip(0.5)

	equals("a quantised normal is one byte, where t.f32 is four", size, 1)
	check(`and comes back within half a step: {tostring(mid)}`, within(mid, 0.5, STEP / 2))

	--[[ Both ends, because the bottom is the offset and the top is the last level — and the top is
	     the one an f32-style bound would have refused, since `254 * (2 / 254)` is not exactly 2. ]]
	local bottom = roundTrip(-1)
	local top = roundTrip(1)

	check("the declared minimum is exact", bottom == -1)
	check(`and the maximum arrives: {tostring(top)}`, within(top, 1, 1e-12))

	--[[ Two bytes buys 1,441 levels of a full turn, which is the case the docstring names. ]]
	local yaw = Serdes.fromSchema(t.quantized(-180, 180, 0.25))

	Buffer.take()
	Buffer.load(nil)
	yaw.write(90.3)

	local turned = (Buffer.take())
	Buffer.beginRead(turned, nil)

	equals("a quarter-degree turn is two bytes", buffer.len(turned), 2)
	check("and lands on the nearest quarter", within((yaw.read()), 90.25, 1e-9))
end

do
	--[[
		**The branch chain carries three more arms rather than the arithmetic being folded into every
		field.** Folding it — one multiply and one add above the chain — was measured at 6.7% on
		`bench/profile.luau`'s whole packet with the control group flat, which is a tax on every
		struct in the library for a type most of them do not use. So a quantised field takes an arm
		of its own and a plain one never reaches it.

		Which means the two have to be checked *mixed*, in one struct, through the fused path.
	]]
	local STEP = 2 / 254

	local mixed = Serdes.fromSchema(t.struct({
		a = t.u8,
		b = t.quantized(-1, 1, STEP),
		c = t.u16,
		d = t.quantized(-180, 180, 0.25),
	}))

	Buffer.take()
	Buffer.load(nil)
	mixed.write({ a = 200, b = -0.5, c = 40000, d = -90 })

	local packed = (Buffer.take())
	Buffer.beginRead(packed, nil)

	local back = mixed.read()

	equals("a mixed struct is 1 + 1 + 2 + 2 bytes", buffer.len(packed), 6)
	equals("the plain byte is untouched", back.a, 200)
	equals("and the plain u16", back.c, 40000)
	check(`the quantised normal came back: {tostring(back.b)}`, within(back.b, -0.5, STEP / 2))
	check("and the quantised angle", within(back.d, -90, 1e-9))
end

do
	--[[ Past `FUSED_MAX`, where the loop writer and the loop reader take over. Two implementations
	     of one contract again, and this is the seam between them for the new arms. ]]
	local STEP = 0.5

	local shape: { [string]: any } = {}
	local value: { [string]: number } = {}

	for index = 1, 9 do
		shape[`f{index}`] = t.quantized(0, 10, STEP)
		value[`f{index}`] = index * 0.5
	end

	local wide = Serdes.fromSchema(t.struct(shape))

	Buffer.take()
	Buffer.load(nil)
	wide.write(value)

	local packed = (Buffer.take())
	Buffer.beginRead(packed, nil)

	local back = wide.read()
	local agree = true

	for index = 1, 9 do
		if not within(back[`f{index}`], index * 0.5, STEP / 2) then
			agree = false
		end
	end

	equals("nine quantised fields are nine bytes", buffer.len(packed), 9)
	check("and the loop path carries every one of them", agree)
end

do
	--[[ And the wire, which is where the count of steps is a number a peer chose. 254 levels fit in
	     a byte that holds 255, so the last raw value is one nobody can honestly write. ]]
	local STEP = 2 / 254
	local normal = Serdes.fromSchema(t.quantized(-1, 1, STEP))

	local last = buffer.create(1)
	buffer.writeu8(last, 0, 254)

	local top, refused = decode(normal, last)

	check(`the last honest level is accepted: {tostring(refused)}`, refused == nil)
	check("and is the declared maximum", within(top, 1, 1e-12))

	local past = buffer.create(1)
	buffer.writeu8(past, 0, 255)

	local value, failure = decode(normal, past)

	check("one step past it is refused", failure ~= nil)
	equals("and nothing is handed up", value, nil)
end

do
	--[[
		**A schema refusing its own maximum**, which is the f32 bound incident in a third encoding.

		The reader reconstructs `raw * step + min`, and for some ranges that lands a rounding *above*
		the declared maximum. Measured over 2,400 (min, max, step) triples that divide evenly: **67 of
		them**, 2.8%. `t.quantized(0, 100, 100 / 11)` is one — eleven steps, and the eleventh
		reconstructs to 100.00000000000001. A reader bounded by the declaration would refuse the value
		its own writer had just accepted, on the value a game sends most: the top of the range.

		`Ir.lowerNumber` bounds the node by the arithmetic that produces the value instead of by the
		declaration, which is the same fix `numberReader` carries for `f32` and for the same reason.
	]]
	local eleven = Serdes.fromSchema(t.quantized(0, 100, 100 / 11))

	Buffer.take()
	Buffer.load(nil)
	eleven.write(100)

	local packed = (Buffer.take())
	Buffer.beginRead(packed, nil)

	local top, refused = eleven.read()

	check(`the top level is accepted: {tostring(refused)}`, refused == nil)
	check(`and is the declared maximum: {tostring(top)}`, within(top, 100, 1e-9))
end

-- ---------------------------------------------------------------------------------------------
-- Whole numbers wider than four bytes
-- ---------------------------------------------------------------------------------------------

do
	--[[ A `UserId`, a millisecond timestamp, a balance. Eight bytes bare and exact to 2^53, which is
	     the whole point: `t.f64` reaches the same values and is a float. ]]
	trip("a u53 carries a UserId", t.u53, 7594110182, 8)
	trip("and the largest integer a double holds", t.u53, 2 ^ 53, 8)
	trip("and zero", t.u53, 0, 8)
	trip("an i53 carries the bottom of its range", t.i53, -(2 ^ 53), 8)

	--[[ The value that proves the offset is not subtracted on the wide path: `value - min` here
	     would be `2^54 - 1`, which is not representable, and it would come back rounded. ]]
	trip("and an odd number just under the top", t.i53, 2 ^ 53 - 1, 8)

	--[[ Narrowed, where it behaves like any other integer and costs what its span costs. ]]
	trip("a narrowed u53 costs what its span costs", t.u53(1, 1000), 500, 2)
	trip("at the bottom of the range", t.u53(1, 1000), 1, 2)
	trip("and at the top", t.u53(1, 1000), 1000, 2)

	refuses("a fraction is refused on the way out", t.u53, 1.5)
	refuses("and so is one past the range", t.u53, 2 ^ 53 + 2)
	refuses("an i53 refuses a fraction too", t.i53, -1.5)
end

do
	--[[
		**The half `t.f64` never had.** A `UserId` declared `t.f64` was checked for wholeness by the
		writer alone, so a peer sending 1.5 on a field a game reads as an id got 1.5 delivered — and
		`Players:GetPlayerByUserId`, a table key and a datastore write all behave differently for it.

		The bytes are written by hand because no netweave writer will produce them, which is what
		makes this a receive-path test rather than a round trip.
	]]
	local id = Serdes.fromSchema(t.u53)

	local fraction = buffer.create(8)
	buffer.writef64(fraction, 0, 1.5)

	local value, failure = decode(id, fraction)

	check("a fraction on the wire is refused where the schema says whole", failure ~= nil)
	equals("and nothing is handed up", value, nil)

	local honest = buffer.create(8)
	buffer.writef64(honest, 0, 7594110182)

	local back, refused = decode(id, honest)

	check(`while a whole one arrives: {tostring(refused)}`, refused == nil)
	equals("intact", back, 7594110182)

	--[[ And the control: the same bytes through `t.f64`, which is a float and says so. A schema that
	     refused this would be refusing the type its own docstring describes. ]]
	local float = Serdes.fromSchema(t.f64)
	local fine, allowed = decode(float, fraction)

	check("the same bytes are fine on a float", allowed == nil)
	equals("and arrive as they were sent", fine, 1.5)
end

do
	--[[ A struct with a wide `u53` in it takes the loop writer rather than the unroll: the check for
	     wholeness is one the unrolled body does not make, and folding it in would be a test per
	     field on every struct in the library. `rowsOf` refuses the row, so the loop — which asks it
	     already — takes over, and what has to hold is that the answer is the same. ]]
	local mixed = Serdes.fromSchema(t.struct({ a = t.u8, owner = t.u53 }))

	Buffer.take()
	Buffer.load(nil)
	mixed.write({ a = 7, owner = 7594110182 })

	local packed = (Buffer.take())
	Buffer.beginRead(packed, nil)

	local back = mixed.read()

	equals("a struct with a wide u53 is 1 + 8 bytes", buffer.len(packed), 9)
	equals("the plain field survives", back.a, 7)
	equals("and the wide one", back.owner, 7594110182)

	local wrote = pcall(mixed.write, { a = 7, owner = 1.5 })
	Buffer.load(nil)

	check("and the loop writer still refuses a fraction", not wrote)

	--[[ The half that says the refusal in `rowsOf` is load-bearing rather than tidy. The unrolled
	     *writer* would have refused this anyway, because its integrality flag comes off the node —
	     the unrolled **reader** has no such check, so a struct that fused would take a fraction off
	     the wire and hand it to a handler expecting an id. Fields are emitted in name order, so
	     `a` is the byte and `owner` the eight after it. ]]
	local forged = buffer.create(9)
	buffer.writeu8(forged, 0, 7)
	buffer.writef64(forged, 1, 1.5)

	local value, failure = decode(mixed, forged)

	check("a fraction inside a struct is refused too", failure ~= nil)
	equals("with nothing handed up", value, nil)

	--[[ While a *narrowed* one lands on an unsigned storage, where the value is whole by
	     construction — so that struct keeps the unroll. ]]
	local fused = Serdes.fromSchema(t.struct({ a = t.u8, stamp = t.u53(1, 1000) }))

	Buffer.take()
	Buffer.load(nil)
	fused.write({ a = 7, stamp = 500 })

	local small = (Buffer.take())
	Buffer.beginRead(small, nil)

	local read = fused.read()

	equals("a narrowed one is 1 + 2", buffer.len(small), 3)
	equals("and reads back", read.stamp, 500)
end

-- ---------------------------------------------------------------------------------------------
-- A literal, a set and a default, on the wire (PLAN-M5 phase 5)
-- ---------------------------------------------------------------------------------------------

do
	--[[ A literal is nothing on the wire: a struct of a number and two literals is the number's
	     byte, and a literal alone is zero bytes. The writer still refuses another value, because
	     sending the wrong constant is a bug worth naming where it happens. ]]
	local versioned = t.struct({ version = t.literal("v3"), ready = t.literal(true), n = t.u8 })

	trip(
		"a struct with two literals costs its one number",
		versioned,
		{ version = "v3", ready = true, n = 5 },
		1
	)
	trip("a literal alone is zero bytes", t.literal("ping"), "ping", 0)
	trip("and so is a number literal", t.literal(7), 7, 0)
	refuses("another string is refused on the way out", versioned, { version = "v2", ready = true, n = 5 })
	refuses("and so is another boolean", versioned, { version = "v3", ready = false, n = 5 })
	refuses("and a missing one", versioned, { version = "v3", n = 5 })

	--[[ A set is its count and its entries: two entries of one and two bytes are seven bytes with
	     the two-byte count, where a map of booleans spends a flag byte per entry on a bit that is
	     always set. ]]
	local unlocked = t.set(t.string(1, 8))
	trip("a set round trips", unlocked, { a = true, bb = true }, 7)
	trip("and an empty one", unlocked, {}, 2)
	refuses("false is not an entry", unlocked, { a = false })

	local booleans = Serdes.fromSchema(t.map(t.string(1, 8), t.boolean))
	local _, mapped = pcall(encode, booleans, { a = true, bb = true })
	Buffer.load(nil)
	equals("the map of booleans it replaces is two bytes more", buffer.len(mapped :: buffer), 9)

	--[[ A default is never sent and always read: the value the game left out and the default it
	     could have written are the same two bytes, and a clear bit reads as the default. ]]
	local defaulted =
		t.struct({ speed = t.optional(t.u8, 16), name = t.optional(t.string(0, 8), "anon"), n = t.u8 })
	local codec = Serdes.fromSchema(defaulted)

	local _, absent = pcall(encode, codec, { n = 1 })
	Buffer.load(nil)
	local _, written = pcall(encode, codec, { speed = 16, name = "anon", n = 1 })
	Buffer.load(nil)
	local _, set = pcall(encode, codec, { speed = 20, name = "bob", n = 1 })
	Buffer.load(nil)

	equals("a left-out field costs its bit", buffer.len(absent :: buffer), 2)
	equals("and writing the default costs the same", buffer.len(written :: buffer), 2)
	equals("a value that is not the default costs its bytes", buffer.len(set :: buffer), 7)

	local read = decode(codec, absent :: buffer, {})
	equals("an absent number reads as its default", read.speed, 16)
	equals("and an absent string as its default", read.name, "anon")

	local kept = decode(codec, set :: buffer, {})
	equals("a set number reads as itself", kept.speed, 20)
	equals("and a set string", kept.name, "bob")
end

-- ---------------------------------------------------------------------------------------------
-- What a string may contain, on both sides of the wire
-- ---------------------------------------------------------------------------------------------

do
	--[[ The honest path first, because a constraint that refuses everything passes every rejection
	     test it has. Same bytes as a plain string — the checks are validation, not framing. ]]
	trip("a constrained string still round trips", t.string(1, 20, { utf8 = true }), "hello", 6)
	trip("and one with a pattern", t.string(1, 20, { pattern = "[%w_]+" }), "player_1", 9)
	trip("and multibyte text under a utf8 flag", t.string(1, 20, { utf8 = true }), "한국어", 10)

	refuses("a value the pattern does not match", t.string(1, 20, { pattern = "[%w_]+" }), "no spaces here")
	refuses("and one that is not valid UTF-8", t.string(1, 20, { utf8 = true }), "\xff\xfe")

	--[[ **Anchored, which is the whole difference.** An unanchored pattern accepts a string that
	     merely contains a match, so `"[%w_]+"` would pass `"<script>a"` — the reading that lets
	     anything through, and the reason netweave adds the anchors rather than the author. ]]
	refuses("a value that only contains a match", t.string(1, 20, { pattern = "[%w_]+" }), "<script>a")
	refuses("or one that begins with a match", t.string(1, 20, { pattern = "[%w_]+" }), "abc!!")

	--[[ The declaration's anchor check used to read the last character alone, so a pattern ending
	     in an escaped dollar was refused as "carries its own anchor" and there was no way to say a
	     value must end in `$`. Through the real reader, so the anchor netweave adds is seen to sit
	     after the escape rather than fuse with it. ]]
	trip("a pattern ending in an escaped dollar", t.string(1, 8, { pattern = "%d+%$" }), "12$", 4)
	refuses("and it still requires the dollar", t.string(1, 8, { pattern = "%d+%$" }), "12")

	--[[ A set is the same check by another spelling, so the reader is the same reader. ]]
	trip("a charset round trips", t.string(1, 20, { charset = "%w_" }), "player_1", 9)
	refuses("and refuses a byte outside the set", t.string(1, 20, { charset = "%w_" }), "player 1")
	refuses("wherever it is", t.string(1, 20, { charset = "%w_" }), "player_1!")
	trip("a negated set admits what it does not name", t.string(1, 20, { charset = "^%c" }), "a b!", 5)
	refuses("and refuses what it names", t.string(1, 20, { charset = "^%c" }), "a	b")
end

-- ---------------------------------------------------------------------------------------------
-- An exact array of optionals is never measured
-- ---------------------------------------------------------------------------------------------

do
	--[[
		`#` on a table with nils is a border the VM chooses from how the table was built, so
		`{1, 2, 3, nil}` on a length of four was refused as "got 3" while `{1, nil, nil, 4}` was
		accepted — the same shape, decided by Luau's array part (M4-1). With an exact length every
		position is written and nothing is measured; a trailing nil is a position like any other.
	]]
	local four = t.array(t.optional(t.u8), 4)

	--[[ Built by assignment so the border is 3, the case a literal cannot make. ]]
	local trailing: { any } = {}
	trailing[1] = 1
	trailing[2] = 2
	trailing[3] = 3

	local codec = Serdes.fromSchema(four)
	local ok, packed = pcall(encode, codec, trailing)
	check("a trailing nil is a position, not a short array", ok)

	if ok then
		Buffer.beginRead(packed, {})
		local back = codec.read()
		check("and comes back as absent", back[1] == 1 and back[3] == 3 and back[4] == nil)
	end

	local leading: { any } = {}
	leading[4] = 4

	local okLeading, packedLeading = pcall(encode, codec, leading)
	check("a leading run of nils is written as absent", okLeading)

	if okLeading then
		Buffer.beginRead(packedLeading, {})
		local back = codec.read()
		check("with the last position intact", back[4] == 4 and back[1] == nil)
	end

	--[[ A non-optional exact array keeps the count check, because there `#` is exact and "must
	     hold exactly 4" beats "a non-optional field is nil" three fields in. ]]
	refuses("a short array of non-optionals is still refused by its count", t.array(t.u8, 4), { 1, 2, 3 })
end

-- ---------------------------------------------------------------------------------------------
-- The instance writer asks the reader's questions
-- ---------------------------------------------------------------------------------------------

do
	--[[
		The reader has always checked the class and the container; the writer asked only "is it an
		Instance", so `nw.validate(t.instance("Sound"), part)` branded a part as conforming and the
		reader refused the same bytes (M4 report, finding 23; M4-1). Stand-ins here answer the two
		methods the writer asks; the real Instances are in `tests/roblox_runtime.luau`.
	]]
	--[[ A real Instance inside Roblox, because the writer asks `typeof(value) == "Instance"` there
	     and a table answering two methods is exactly the double §9 warns about: the first Studio
	     pass after this section was written failed on it, in the dimension the code under test
	     checks. Under lune the table is what an instance is. ]]
	local ROBLOX = typeof(game) == "Instance"
	local container: any = if ROBLOX then Instance.new("Folder") else { Name = "Workspace" }

	local function standIn(className: string, inside: boolean): any
		if ROBLOX then
			local real = Instance.new(className :: any)

			if inside then
				real.Parent = container
			end

			return real
		end

		return {
			ClassName = className,
			IsA = function(_self: any, class: string): boolean
				return class == className
			end,
			IsDescendantOf = function(): boolean
				return inside
			end,
		}
	end

	--[[ The declaration refuses a container that is not an Instance under lune, so the descriptor is
	     built by hand — the path a schema built at runtime takes, and the one the reader's own tests
	     take. ]]
	local contained: any = { kind = "instance", class = "Part", descendantOf = container }

	refuses("a wrong class on the way out", t.instance("Sound"), standIn("Part", true))
	refuses("and one outside its container", contained, standIn("Part", false))

	local right = Serdes.fromSchema(contained)
	local wrote = pcall(right.write, standIn("Part", true))
	Buffer.load(nil)
	check("while the declared class inside its container is written", wrote)
end

do
	--[[
		The half the finding is about: a **peer's** string is the one that reaches `SetAsync`,
		`Instance.Name` and chat. Refused rather than raised, because it is wire data (G4), and the
		bytes are written by hand because no netweave writer will produce them.
	]]
	local name = Serdes.fromSchema(t.string(1, 20, { utf8 = true, pattern = "[%w_]+" }))

	--[[ The length prefix is narrowed like any other range: `t.string(1, 20)` writes `length - 1` in
	     one byte, because the declared minimum is the offset. Getting that wrong here is how a
	     hand-built packet ends up testing the truncation path instead of the one it meant to. ]]
	local function wire(text: string): buffer
		local packed = buffer.create(1 + #text)
		buffer.writeu8(packed, 0, #text - 1)
		buffer.writestring(packed, 1, text)
		return packed
	end

	local honest, allowed = decode(name, wire("player_1"))

	check(`an honest name arrives: {tostring(allowed)}`, allowed == nil)
	equals("intact", honest, "player_1")

	local spaced, refusedPattern = decode(name, wire("player one"))

	check("one the pattern forbids is refused", refusedPattern ~= nil)
	equals("with nothing handed up", spaced, nil)

	--[[
		**Through a schema that declares `utf8` and nothing else**, because the pattern above refuses
		`"\xff\xfe"` too — a word-character pattern refuses every byte that is not one — so asserting
		the UTF-8 case against `name` would pass with the UTF-8 check deleted. Confirmed: it did.

		That is the two-guards-covering-for-each-other shape `CLAUDE.md` §9 records from M3's
		`maxBytes` test, and it is why every mutation in this file is run rather than reasoned about.
	]]
	local text = Serdes.fromSchema(t.string(1, 20, { utf8 = true }))

	local fine, ok = decode(text, wire("한국어"))

	check(`multibyte text arrives: {tostring(ok)}`, ok == nil)
	equals("intact", fine, "한국어")

	local broken, refusedUtf8 = decode(text, wire("\xff\xfe"))

	check("and bytes that are not valid UTF-8 are refused", refusedUtf8 ~= nil)
	equals("nothing there either", broken, nil)

	--[[ The control: the same bytes through a plain `t.string`, which promises a length and nothing
	     else. A schema that refused these would be refusing what its own docstring describes. ]]
	local plain = Serdes.fromSchema(t.string(1, 20))
	local through, unrefused = decode(plain, wire("\xff\xfe"))

	check("a plain string takes the same bytes", unrefused == nil)
	equals("and hands them over", through, "\xff\xfe")
end

-- ---------------------------------------------------------------------------------------------
-- One of several shapes, and the wire says which
-- ---------------------------------------------------------------------------------------------

do
	--[[ Both branches, so neither is the one that happens to work. Sorted names put `a` at tag 0 and
	     `b` at tag 1, and the two carry different widths on purpose — a union whose branches are the
	     same size cannot tell "wrote the right branch" from "wrote the only length". ]]
	local pair = t.union({ a = t.u8, b = t.u16 })

	trip("the first branch", pair, { tag = "a", value = 7 }, 2)
	trip("the second", pair, { tag = "b", value = 40000 }, 3)

	--[[ Three branches is two tag bits, and it is the arity where the tag has room the schema does
	     not use — the case the reader has to refuse below. ]]
	local three = t.union({ a = t.u8, b = t.u8, c = t.u8 })

	trip("one of three", three, { tag = "c", value = 5 }, 2)

	--[[ A branch that is not a scalar, and one nested in a struct beside ordinary fields. ]]
	trip(
		"a branch that is a struct",
		t.union({ move = t.struct({ x = t.u8, y = t.u8 }), wait = t.u8 }),
		{ tag = "move", value = { x = 3, y = 4 } },
		3
	)

	trip(
		"a union inside a struct",
		t.struct({ n = t.u8, action = t.union({ a = t.u8, b = t.u16 }) }),
		{ n = 9, action = { tag = "b", value = 500 } },
		4
	)

	refuses("a tag no branch names", pair, { tag = "nope", value = 1 })
	refuses("a value that is not a tagged pair", pair, 7)
	refuses("and a branch given the wrong kind of value", pair, { tag = "b", value = "text" })
end

do
	--[[
		**The fork, in bytes.**

		Only one branch is ever present, so branch A's flags and branch B's flags may occupy the same
		bits. Two branches of five booleans each fork to `1 + 5` bits — one byte — where summing them
		is `1 + 10`, which is two. Zap sums, so its variants consume separate bits even though only
		one can be there (`RESEARCH §3.9-Y`).

		Five is the width that makes the difference a *byte* rather than a bit. Three would fork to 4
		and sum to 7, and both round to one byte, so the assertion would pass either way.
	]]
	local forked = t.union({
		a = t.struct({ p = t.boolean, q = t.boolean, r = t.boolean, s = t.boolean, u = t.boolean }),
		b = t.struct({ v = t.boolean, w = t.boolean, x = t.boolean, y = t.boolean, z = t.boolean }),
	})

	local layout = Ir.lower(forked)

	equals("a tag bit plus the widest branch, not the sum", layout.root.bits, 6)

	trip(
		"and five flags and a tag are one byte",
		forked,
		{ tag = "b", value = { v = true, w = false, x = true, y = false, z = true } },
		1
	)

	--[[ The other branch through the same bits, because a fork that numbered only the first branch
	     would pass everything above. ]]
	trip(
		"the other branch reads the same bits",
		forked,
		{ tag = "a", value = { p = false, q = true, r = true, s = false, u = true } },
		1
	)
end

do
	--[[ The tag has room the schema does not use whenever the branch count is not a power of two:
	     three branches are two bits and a peer can put 3 in them. Refused rather than raised, and
	     the packet behind it still decodes. ]]
	local three = Serdes.fromSchema(t.union({ a = t.u8, b = t.u8, c = t.u8 }))

	local honest = buffer.create(2)
	buffer.writeu8(honest, 0, 2)
	buffer.writeu8(honest, 1, 5)

	local named, allowed = decode(three, honest)

	check(`tag 2 names the third branch: {tostring(allowed)}`, allowed == nil)
	check("and carries its value", named ~= nil and named.tag == "c" and named.value == 5)

	--[[ Through `rejects` rather than by hand, because what has to be asserted is all three of its
	     clauses at once: the decode did not **raise**, it reported, and it handed nothing up. Without
	     the refusal the tag indexes past the branch list and the codec calls a nil reader — wire data
	     reaching a Luau error, which is G4. ]]
	rejects("a tag past the last branch", t.union({ a = t.u8, b = t.u8, c = t.u8 }), bytes(3, 5))

	local after, again = decode(three, honest)

	check("while the next packet still decodes", again == nil)
	check("into the branch it names", after ~= nil and after.tag == "c")
end

-- ---------------------------------------------------------------------------------------------
-- A key that is not there, and a repeated thing that costs nothing (M4 report, 2 and 3)
-- ---------------------------------------------------------------------------------------------

do
	--[[
		**The one path where wire data reached a Luau error.**

		`t.map(t.optional(K), V)` used to type-check, lower and encode honestly — a Lua table has no
		nil index, so the presence bit the optional adds is dead weight only a hostile packet can
		clear. Clearing it made `readKey` answer nil with no rejection, and `result[nil] = value`
		raised: G4 broken at the codec, against the header of `Serdes.luau` in as many words.

		`t.map` refuses that key type now, so this builds the descriptor **by hand** — which is not a
		contrivance. `isType` is a duck check: any table with a string `kind` passes it, and passes
		`requireType` and `nw.validate` too (M4 report). The reader is not allowed to assume the
		constructor was used, so the reader is what this section tests.
	]]
	local hostile: any = {
		kind = "map",
		key = t.optional(t.u8),
		value = t.u8,
		min = 0,
		max = 16,
	}

	local codec = Serdes.fromSchema(hostile)

	Buffer.take()
	Buffer.load(nil)
	codec.write({ [3] = 7 })

	local packed = (Buffer.take())

	--[[ `count` in one byte because the map is bounded at 16, then the key's own scope byte, then
	     the key and the value. ]]
	equals("an optional key encodes its presence bit", buffer.len(packed), 4)

	buffer.writeu8(packed, 1, 0)
	Buffer.beginRead(packed, nil)

	local raised, value, failure = pcall(codec.read)

	check("clearing it does not raise", raised)
	equals("and decodes to nothing", value, nil)
	check(`with a reason rather than a Luau error: {tostring(failure)}`, failure == "a map key is missing")

	Buffer.load(nil)
end

do
	--[[
		The declaration side of the same finding, and of the one beside it. Both are refusals rather
		than round trips, so they are `pcall`ed for the message rather than run through `refuses`,
		which is about a *value* an encoder rejects.
	]]
	local function refusedBy(name: string, build: () -> (), needle: string)
		local ok, message = pcall(build)

		if ok then
			fail(`{name}: the declaration was accepted`)
			return
		end

		check(
			`{name}: refused, and the message says why — {tostring(message)}`,
			string.find(tostring(message), needle, 1, true) ~= nil
		)
	end

	refusedBy("an optional map key", function()
		t.map(t.optional(t.u8), t.u8)
	end, "look it up by")

	--[[ Through `any`, because a struct key does not type-check either — `{ [K]: V }` with a table
	     key is not a Luau type. That the analyzer refuses it first is the better outcome; what this
	     asserts is that the constructor still refuses when the analyzer has been bypassed, which is
	     the path a schema built at runtime takes. ]]
	local structKey: any = t.struct({ a = t.u8 })

	refusedBy("a struct map key", function()
		t.map(structKey, t.u8)
	end, "fresh value")

	refusedBy("a vector3 map key", function()
		t.map(t.vector3, t.u8)
	end, "look it up by")

	--[[
		**Two bytes for 65,535 entries.** An element that costs no bytes, no flags and no instances
		makes the honest packet and the flood the same bytes, so nothing on the receive side can tell
		them apart — measured before the refusal existed: `t.array(t.enum({ x = true }))` claiming
		65,535 built 65,535 entries in 1.7 ms and 1 MB, and a struct of one such enum cost 6 MB.
	]]
	--[[ The refusal is at lowering rather than at `t.array`, because the element's cost is what the
	     lowering pass computes and re-deriving it in the constructor would be the same walk written
	     twice. For a game that is still declaration time: `nw.signal({ data = ... })` builds the
	     codec, and the message lands on that line. ]]
	local function lowering(descriptor: any): () -> ()
		return function()
			Serdes.fromSchema(descriptor)
		end
	end

	refusedBy(
		"an array of a single-variant enum",
		lowering(t.array(t.enum({ only = true }))),
		"costs no bytes"
	)
	refusedBy("an array of empty strings", lowering(t.array(t.string(0, 0))), "costs no bytes")
	refusedBy("an array of empty buffers", lowering(t.array(t.buffer(0, 0))), "costs no bytes")

	refusedBy(
		"an array of a struct that holds only those",
		lowering(t.array(t.struct({ e = t.enum({ only = true }) }))),
		"costs no bytes"
	)

	--[[ Built by hand for the same reason the map above is: `t.map` refuses a key that costs
	     nothing to *look up by* before the lowering ever sees what it costs to *carry*. ]]
	refusedBy(
		"and a map whose entries cost nothing",
		lowering({
			kind = "map",
			key = t.enum({ only = true }),
			value = t.enum({ nothing = true }),
			min = 0,
			max = 16,
		}),
		"cost no bytes"
	)
end

do
	--[[ The other side of that line: what stays legal. An exact-length array writes no length for a
	     peer to claim, and an element that carries one bit is not free. ]]
	trip("an exact-length array of a zero-byte element", t.array(t.enum({ only = true }), 3, 3), {
		"only",
		"only",
		"only",
	}, 0)

	--[[ A dynamic array cannot fold its elements' flags into the enclosing scope, so each element
	     opens one of its own — a length byte and three scope bytes. ]]
	trip("and one whose element carries a flag", t.array(t.boolean, 0, 8), { true, false, true }, 4)

	local bounded = Serdes.fromSchema(t.array(t.u8, 0, 4))
	equals("a bounded array of real bytes is untouched", bounded.maxSize, 5)
end

if failures > 0 then
	error(`{failures} serdes assertions failed`)
end

print("OK      serdes_runtime")

return true
