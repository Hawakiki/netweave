--!strict

--[[
	Runtime behaviour of the type descriptors. The type-level half lives in `types_ok.luau` and
	`types_reject.luau`; this checks what the codec will actually read.

		lune run tests/types_runtime

	The codec itself is phase 4. Nothing here encodes anything.
]]

local t = require("../src/types")

--[[
	Deliberately invalid constructions go through this. The type functions run at analysis time, so
	`t.struct({ id = 5 })` is a type error as well as a runtime one, and this file has to analyze
	clean. Going through `any` hides it from the checker while leaving the runtime guard exposed —
	which is the thing being tested here. The type-level half is `types_reject.luau`.
]]
local invalid = t :: any

local failures = 0

local function check(name: string, condition: boolean)
	if not condition then
		failures += 1
		print(`FAIL  {name}`)
	end
end

--[[ Construction errors are programmer error and must throw, unlike anything off the wire. ]]
local function rejects(name: string, body: () -> ())
	local ok = pcall(body)
	check(name, not ok)
end

-- ---------------------------------------------------------------------------------------------
-- Descriptors carry what the codec needs
-- ---------------------------------------------------------------------------------------------

check("u8 kind", t.u8.kind == "number")
check("u8 encoding", t.u8.encoding == "u8")
check("u8 bounds", t.u8.min == 0 and t.u8.max == 255)
check("i16 bounds", t.i16.min == -32768 and t.i16.max == 32767)
check("boolean kind", t.boolean.kind == "boolean")
check("string default length", t.string.min == 0 and t.string.max == 65535)
check("unit vector flagged", t.unitVector3.unit == true and t.vector3.unit == nil)

-- ---------------------------------------------------------------------------------------------
-- Narrowing produces a new descriptor and leaves the original alone
-- ---------------------------------------------------------------------------------------------

local slot = t.u8(0, 2)
check("narrowed min", slot.min == 0)
check("narrowed max", slot.max == 2)
check("narrowed keeps encoding", slot.encoding == "u8")
check("base untouched", t.u8.max == 255)
check("descriptors are frozen", table.isfrozen(slot :: any))

local pitch = t.f32(-90, 90)
check("float range", pitch.min == -90 and pitch.max == 90)

rejects("range above the encoding", function()
	t.u8(0, 300)
end)

rejects("range below the encoding", function()
	t.u8(-1, 10)
end)

rejects("inverted range", function()
	t.u8(10, 0)
end)

-- ---------------------------------------------------------------------------------------------
-- Bounds that count in whole numbers, and floats that reach their encoding (M4 report)
-- ---------------------------------------------------------------------------------------------

--[[
	`t.u8(0.5, 2.5)` type-checked, lowered and encoded, and delivered a different number than was
	sent with no rejection anywhere: the offset became 0.5, the writer's whole-number test passed on
	the value, `buffer.writeu8(1 - 0.5)` truncated, and the reader added 0.5 back. **Sent 1, got
	0.5.** The declaration is what has to refuse it, because everything downstream was behaving
	correctly given the schema it was handed.
]]
rejects("a fractional integer bound", function()
	t.u8(0.5, 2.5)
end)

rejects("one fractional end is enough", function()
	t.i16(-100, 100.5)
end)

--[[ A string's range is a **length**, and half a byte is not one. Same for a buffer. ]]
rejects("a fractional string length", function()
	t.string(0, 8.5)
end)

rejects("a fractional buffer length", function()
	t.buffer(1.5, 8)
end)

--[[ An array's count does not go through `ranged`, so it is checked separately — and `t.array(x,
     1.5)` lowered happily and then refused every length the game could send. ]]
rejects("a fractional array count", function()
	t.array(t.u8, 1.5)
end)

rejects("and a fractional upper bound on one", function()
	t.array(t.u8, 0, 2.5)
end)

--[[ The half that must still work, which is the whole reason this is a per-encoding question rather
     than a blanket rule: a float range is fractional by nature. ]]
local half = t.f32(-0.5, 0.5)
check("a fractional float bound is what f32 is for", half.min == -0.5 and half.max == 0.5)

--[[
	~~`f32` is `-2^24..2^24` and `f64` is `-2^53..2^53`.~~ Those are the spans in which each encoding
	represents every *integer* exactly, and as a value range they refused ordinary numbers: bare
	`t.f32` refused `1e8`, bare `t.f64` refused `1e18`, and `t.f32(0, 1e9)` was refused at
	declaration — with a range the author never wrote in the message.
]]
check("f32 reaches its encoding's largest finite value", (t.f32.max :: number) > 3.4e38)
check("and f64 reaches a double's", (t.f64.max :: number) > 1.7e308)
check("neither admits infinity", (t.f32.max :: number) < math.huge and (t.f64.max :: number) < math.huge)

local scaled = t.f32(0, 1e9)
check("a range past the integer-exact span is a legal declaration", scaled.max == 1e9)

-- ---------------------------------------------------------------------------------------------
-- Wire order never comes from table iteration
-- ---------------------------------------------------------------------------------------------

local entity = t.struct({
	id = t.u8,
	x = t.u8,
	animation = t.u8,
})

check("struct order is sorted", table.concat(entity.order :: { string }, ",") == "animation,id,x")
check("struct keeps its fields", (entity.fields :: any).id.kind == "number")

local weapon = t.enum({ secondary = true, primary = true, melee = true })
check(
	"enum variants are sorted",
	table.concat(weapon.variants :: { string }, ",") == "melee,primary,secondary"
)

-- ---------------------------------------------------------------------------------------------
-- Composites
-- ---------------------------------------------------------------------------------------------

local dynamic = t.array(t.u8)
check("dynamic array bounds", dynamic.min == 0 and dynamic.max == 65535)

local exact = t.array(t.u8, 100)
check("exact array bounds", exact.min == 100 and exact.max == 100)

local bounded = t.array(t.u8, 0, 8)
check("bounded array", bounded.min == 0 and bounded.max == 8)

local sound = t.instance("Sound")
check("instance class", sound.class == "Sound")
check("bare instance has no class", t.instance.class == nil)

check("optional wraps", (t.optional(t.u16).inner :: any).encoding == "u16")

rejects("optional of optional", function()
	invalid.optional(invalid.optional(t.u8))
end)

rejects("array of a non-type", function()
	invalid.array(5)
end)

rejects("struct field that is not a type", function()
	invalid.struct({ id = 5 })
end)

rejects("empty struct", function()
	invalid.struct({})
end)

rejects("empty enum", function()
	invalid.enum({})
end)

rejects("enum variant that is not true", function()
	invalid.enum({ primary = false })
end)

rejects("array longer than the length prefix allows", function()
	t.array(t.u8, 0, 70000)
end)

-- ---------------------------------------------------------------------------------------------

if failures > 0 then
	error(`{failures} runtime type assertions failed`)
end

print("OK      types_runtime")

return true
