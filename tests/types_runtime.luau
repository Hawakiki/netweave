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
-- A float carried as a count of steps
-- ---------------------------------------------------------------------------------------------

--[[
	`t.quantized` is the one range on a fractional value that narrows the storage. `t.f32(-1, 1)`
	costs four bytes because a float is never re-encoded; this says how much precision the author
	actually needs and lets the layout spend what that costs.

	The declaration carries `step` and no `encoding` — the encoding is chosen at lowering from how
	many steps the range holds, which is the only place that knows.
]]
local normal = t.quantized(-1, 1, 2 / 254)
check("a quantised number is still a number", normal.kind == "number")
check("and carries its step", normal.step == 2 / 254)
check("with the bounds as declared", normal.min == -1 and normal.max == 1)
check("and no encoding of its own", normal.encoding == nil)

rejects("a step of zero", function()
	t.quantized(-1, 1, 0)
end)

rejects("a negative step", function()
	t.quantized(-1, 1, -0.1)
end)

rejects("a step wider than the range", function()
	t.quantized(-1, 1, 3)
end)

rejects("an inverted range", function()
	t.quantized(1, -1, 0.1)
end)

rejects("a range with no width at all", function()
	t.quantized(1, 1, 0.1)
end)

--[[ The one that is a judgement rather than a typo: 0..100 in steps of 3 is 33.3 of them, and which
     end moves is the author's call. Refusing beats rounding one of them silently. ]]
rejects("a range that is not a whole number of steps", function()
	t.quantized(0, 100, 3)
end)

--[[ And the arithmetic that produced the caution: `2 / (2 / 254)` is 254.00000000000003, so the
     check has to be relative or the declaration this type exists for would be refused by it. ]]
check("a step that divides to within a rounding is accepted", t.quantized(-1, 1, 2 / 254).step ~= nil)

rejects("more levels than a four-byte count holds", function()
	t.quantized(0, 1, 1e-11)
end)

-- ---------------------------------------------------------------------------------------------
-- Whole numbers wider than four bytes
-- ---------------------------------------------------------------------------------------------

--[[
	Until M4 phase 8 the widest integer was `t.u32`, so a `UserId` had to be declared `t.f64` — a
	float, whose wholeness only the writer refused. These are the two encodings that reach 2^53 and
	are checked on both sides.
]]
check("u53 spans every integer a double holds", t.u53.min == 0 and t.u53.max == 2 ^ 53)
check("i53 is the same with a sign", t.i53.min == -(2 ^ 53) and t.i53.max == 2 ^ 53)
check("and both are numbers", t.u53.kind == "number" and t.i53.kind == "number")

--[[ Narrowing is the ordinary path: a range whose span fits a smaller storage takes it, and the
     declaration is what says how wide the value *can* be rather than how wide it is stored. ]]
local stamp = t.u53(1, 1000)
check("a narrowed u53 keeps its encoding", stamp.encoding == "u53")
check("and its bounds", stamp.min == 1 and stamp.max == 1000)

rejects("a u53 range below zero", function()
	t.u53(-1, 10)
end)

rejects("a u53 range past what a double holds exactly", function()
	t.u53(0, 2 ^ 54)
end)

rejects("a fractional u53 bound", function()
	t.u53(0, 10.5)
end)

-- ---------------------------------------------------------------------------------------------
-- What a string may contain, not only how long it is
-- ---------------------------------------------------------------------------------------------

--[[
	Client strings reach `SetAsync` keys, `Instance.Name` and chat, where invalid UTF-8 or a control
	character surfaces as an error in game code with no packet to point at. A length bound cannot
	say any of that.
]]
local named = t.string(1, 20, { utf8 = true, pattern = "[%w_]+" })
check("a constrained string keeps its bounds", named.min == 1 and named.max == 20)
check("and records the utf8 flag", named.utf8 == true)
check("and the pattern as written", named.pattern == "[%w_]+")

--[[ `false` records nothing: a descriptor carrying its own default is one two peers can spell
     differently and hash differently for no reason. ]]
check("utf8 = false records nothing", t.string(0, 8, { utf8 = false }).utf8 == nil)
check("and no options at all records nothing", t.string(0, 8).pattern == nil)

rejects("an unknown option", function()
	t.string(0, 8, { utf8 = true, patern = "%d+" } :: any)
end)

rejects("options that are not a table", function()
	t.string(0, 8, "utf8" :: any)
end)

rejects("a utf8 flag that is not a boolean", function()
	t.string(0, 8, { utf8 = "yes" } :: any)
end)

rejects("a pattern that is not a string", function()
	t.string(0, 8, { pattern = 5 } :: any)
end)

rejects("an empty pattern", function()
	t.string(0, 8, { pattern = "" })
end)

--[[ netweave anchors the pattern, so one that carries its own anchor would match a literal caret.
     Refused rather than stripped, because stripping is a silent rewrite of what the author wrote. ]]
rejects("a pattern anchored at the front", function()
	t.string(0, 8, { pattern = "^%w+" })
end)

rejects("a pattern anchored at the back", function()
	t.string(0, 8, { pattern = "%w+$" })
end)

rejects("a pattern that is not a pattern", function()
	t.string(0, 8, { pattern = "%" })
end)

--[[ And the third argument nothing else takes. `t.u8(0, 10, { utf8 = true })` used to be accepted
     and ignored, which looks exactly like an option that worked. ]]
rejects("a third argument on a number", function()
	(t.u8 :: any)(0, 10, { utf8 = true })
end)

rejects("and on a buffer", function()
	(t.buffer :: any)(0, 10, { utf8 = true })
end)

-- ---------------------------------------------------------------------------------------------
-- One of several shapes
-- ---------------------------------------------------------------------------------------------

local action = t.union({ move = t.struct({ x = t.u8 }), attack = t.u16, wait = t.u8 })

--[[ Sorted, because the tag is a **position** and both peers have to number the branches the same
     way — the rule that already covers struct fields, enum variants and channel ids. ]]
check("branch order is sorted", table.concat(action.variants :: { string }, ",") == "attack,move,wait")
check("and the branches are kept", (action.branches :: any).attack.encoding == "u16")

rejects("a branch that is not a netweave type", function()
	invalid.union({ move = 5 })
end)

rejects("an empty union", function()
	invalid.union({})
end)

rejects("branches that are not a table", function()
	invalid.union("move")
end)

--[[ A union is a fresh table on decode, so two entries the sender wrote with equal keys arrive as
     two distinct ones — the same reason a struct, an array and a map are refused as map keys. ]]
rejects("a union as a map key", function()
	invalid.map(action, t.u8)
end)

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
