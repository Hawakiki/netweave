--!strict

--[[
	Patches, under lune.

		lune run tests/delta_runtime

	One property carries this file: **`apply(base, diff(base, next))` is `next`**, over the same
	sixteen schemas `ir_runtime` uses for the ceiling — chosen because between them they open a
	bitfield everywhere a bitfield can open, which is where a derived layout is most likely to
	number something wrong.

	The rest is the two things a property test of a diff cannot see. That an unchanged value writes
	**nothing**, because a patch of nothing is the absence of a packet rather than an empty one. And
	that the bytes are actually fewer, because a delta that is correct and larger than a resend is a
	delta nobody should send.

	**The failure-path floor is low here on purpose, and `CLAUDE.md` §9 is the reason rather than the
	excuse.** Computing a difference between two values the game already owns has one correct answer
	and no adversary — the same shape as `ir_runtime`, which sits at 13% and is right to. Nothing in
	this file reads a byte a peer chose. The adversarial half of replication is a malformed or
	replayed *patch* on the receive path, which is `tests/replication_runtime.luau` in phase 6 and
	where `PLAN-M4` acceptance 11 applies. Padding this file to a number would be the failure mode
	§9 names.
]]

local Buffer = require("../src/codec/Buffer")
local Delta = require("../src/replication/Delta")
local Ir = require("../src/codec/Ir")
local Serdes = require("../src/codec/Serdes")
local harness = require("./harness")
local t = require("../src/types")

--[[
	~~0.1~~ **0.03, which is the honest share.** M4-1 re-read every failure-path tag in this file and found
	the floor met by tagging removal packets and "an equal union writes nothing" as failure-path. PLAN-M4-BUG D-5: a floor met by relabelling is lowered
	to what the file measures, not defended; the number here is what counting only refusals, bounds,
	hostile input and failure isolation gives, and it moves up when real refusal cases are written.
]]
local suite = harness.suite("delta_runtime", 0.03)
local check, equals = suite.check, suite.equals

--[[ Structural equality, because a merged value shares subtrees with its baseline and is a fresh
     table wherever the patch touched. Identity is exactly what must not be asserted. ]]
local function deepEquals(a: any, b: any): boolean
	if a == b then
		return true
	end

	if typeof(a) == "buffer" and typeof(b) == "buffer" then
		local length = buffer.len(a)
		return length == buffer.len(b) and buffer.readstring(a, 0, length) == buffer.readstring(b, 0, length)
	end

	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end

	for key, value in a do
		if not deepEquals(value, b[key]) then
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

--[[ A value for this schema. `variant` picks between two shapes so a pair differs everywhere it
     can — a diff that only ever sees one field move would not exercise the numbering. ]]
local function valueOf(descriptor: any, variant: number): any
	local kind = descriptor.kind

	if kind == "boolean" then
		return variant == 1
	elseif kind == "number" then
		local low = descriptor.min or 0
		local high = descriptor.max or 100
		return if variant == 1 then low else high
	elseif kind == "string" then
		return string.rep(if variant == 1 then "a" else "b", math.min(descriptor.max or 3, 3))
	elseif kind == "buffer" then
		local out = buffer.create(math.min(descriptor.max or 2, 2))
		buffer.writeu8(out, 0, variant)
		return out
	elseif kind == "enum" then
		local variants = descriptor.variants
		return variants[if variant == 1 then 1 else #variants]
	elseif kind == "optional" then
		--[[ One side absent, so every optional in the list exercises removal in one direction and
		     arrival in the other. ]]
		return if variant == 1 then nil else valueOf(descriptor.inner, variant)
	elseif kind == "array" then
		local out = {}
		local low = descriptor.min or 0
		local high = descriptor.max or 3

		--[[ An exact-length array has one legal length, and it is the case whose positions unroll
		     into the enclosing scope rather than opening one each — so it has to be in the list at
		     its own length or it is not the control it was put there to be. ]]
		local count = if low == high
			then low
			else math.min(high, math.max(low, if variant == 1 then 2 else 3))

		--[[ Every element takes the array's own variant rather than alternating, because an
		     alternating `t.array(t.optional(T))` is a **sparse** array and `#` on one of those
		     depends on how it was built: `{1, nil, 3}` written as a literal is length three and the
		     same table filled by assignment is length one. The encoder handles either honestly, so
		     this is a hazard for test data rather than a defect — and generating a hole would be
		     testing Luau's array part, not the diff. ]]
		for index = 1, count do
			out[index] = valueOf(descriptor.element, variant)
		end

		return out
	elseif kind == "map" then
		local out = {}

		for index = 1, 3 do
			out[string.format("%03d", index)] = valueOf(descriptor.value, if index == 2 then 1 else variant)
		end

		return out
	elseif kind == "struct" then
		local out = {}

		for name, field in descriptor.fields do
			out[name] = valueOf(field, variant)
		end

		return out
	elseif kind == "union" then
		--[[ The first branch against the last, so a pair differs by *which branch* as well as by
		     what is in it — a union whose two sides always take the same branch would not exercise
		     the tag at all. ]]
		local variants = descriptor.variants
		local name = variants[if variant == 1 then 1 else #variants]

		return { tag = name, value = valueOf(descriptor.branches[name], variant) }
	end

	return nil
end

--[[ Write a patch and read it back against the baseline, through the real buffer. ]]
local function roundTrip(delta: Delta.Delta, base: any, next_: any): (boolean, any)
	Buffer.take()
	Buffer.load(nil)

	local wrote = delta.write(base, next_)
	local packed = Buffer.take()

	if not wrote then
		equals("a patch that changed nothing wrote nothing", buffer.len(packed), 0)
		return false, base
	end

	Buffer.beginRead(packed, nil)
	local merged = delta.apply(base)

	check("the patch was read to its end", Buffer.remaining() == 0)
	return true, merged
end

-- ---------------------------------------------------------------------------------------------
-- The property, over every place a bitfield can open
-- ---------------------------------------------------------------------------------------------

suite.passing()

do
	local schemas: { { name: string, schema: any } } = {
		{ name = "a bare number", schema = t.u8 },
		{ name = "a struct of scalars", schema = t.struct({ a = t.u8, b = t.u16 }) },
		{ name = "flags at the root", schema = t.struct({ a = t.boolean, b = t.boolean, n = t.u8 }) },
		{ name = "an optional at the root", schema = t.struct({ n = t.optional(t.u8) }) },
		{ name = "a string", schema = t.string(0, 200) },
		{ name = "an array of scalars", schema = t.array(t.u8, 0, 10) },
		{ name = "a fixed array of scalars", schema = t.array(t.u8, 10, 10) },
		{ name = "an array of booleans", schema = t.array(t.boolean, 0, 10) },
		{ name = "an array of optionals", schema = t.array(t.optional(t.u8), 10) },
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
			schema = (t.map :: any)(t.string(0, 4), t.struct({ f = t.boolean, x = t.u8 })),
		},
		{
			name = "a struct holding an array of flagged elements",
			schema = t.struct({ n = t.u8, list = t.array(t.boolean, 0, 12) }),
		},
		{ name = "a fixed array of booleans", schema = t.array(t.boolean, 8, 8) },

		--[[ A union is replaced whole by the derivation — `patchNode` recurses into structs and
		     wraps everything else in an optional — so what these check is that the whole value
		     survives the trip, tag included, through both the branch that carries flags and the one
		     that carries only bytes. ]]
		{ name = "a union of scalars", schema = t.union({ a = t.u8, b = t.u16 }) },
		{
			name = "a union of structs carrying flags",
			schema = t.union({
				a = t.struct({ f = t.boolean, x = t.u8 }),
				b = t.struct({ g = t.boolean, y = t.u16 }),
			}),
		},
		{
			name = "a struct holding a union",
			schema = t.struct({ n = t.u8, act = t.union({ a = t.u8, b = t.u16 }) }),
		},

		--[[ Not in the ceiling list, and the reason patches exist: a struct deep enough that a
		     nested bit has to mean "something below moved". ]]
		{
			name = "a nested struct",
			schema = t.struct({
				pos = t.struct({ x = t.f32, y = t.f32 }),
				hp = t.u8,
				tag = t.optional(t.string(0, 8)),
			}),
		},
	}

	for _, case in schemas do
		local delta = Delta.build(Ir.lower(case.schema))

		local a = valueOf(case.schema, 1)
		local b = valueOf(case.schema, 2)

		--[[ Forward, backward, and to itself. Backward matters because it is the direction that
		     removes: every optional in the list is present in `b` and absent in `a`. ]]
		local _, forward = roundTrip(delta, a, b)
		check(`{case.name}: base to next`, deepEquals(forward, b))

		local _, backward = roundTrip(delta, b, a)
		check(`{case.name}: next back to base`, deepEquals(backward, a))

		local moved = roundTrip(delta, b, b)
		check(`{case.name}: a value against itself is not a patch`, not moved)
	end
end

-- ---------------------------------------------------------------------------------------------
-- The bytes, which are the reason for any of it
-- ---------------------------------------------------------------------------------------------

do
	local schema = t.struct({
		a = t.u8,
		b = t.u8,
		c = t.u8,
		d = t.u8,
		e = t.u8,
		f = t.u8,
		g = t.u8,
		h = t.u8,
		i = t.u8,
		j = t.u8,
		k = t.u8,
		l = t.u8,
	})

	local delta = Delta.build(Ir.lower(schema))
	local codec = Serdes.fromSchema(schema)

	local base = valueOf(schema, 1)
	local next_ = table.clone(base)
	next_.g = 200

	Buffer.take()
	Buffer.load(nil)
	check("one field moved", delta.write(base, next_))
	local patched = buffer.len((Buffer.take()))

	Buffer.load(nil)
	codec.write(next_)
	local whole = buffer.len((Buffer.take()))

	--[[ Twelve bits of "which one" in two bytes, then the byte that moved. The claim in
	     `Ir.patch`'s docstring, asserted rather than asserted-about. ]]
	equals("a twelve-field struct with one field moved costs three bytes", patched, 3)
	equals("against twelve for the whole thing", whole, 12)
end

-- ---------------------------------------------------------------------------------------------
-- Removal, which is the case a patch table cannot express
-- ---------------------------------------------------------------------------------------------

suite.passing()

do
	local schema = t.struct({ hp = t.u8, target = t.optional(t.u16) })
	local delta = Delta.build(Ir.lower(schema))

	local held = { hp = 10, target = 900 }
	local dropped = { hp = 10 }

	local wrote, merged = roundTrip(delta, held, dropped)

	check("dropping an optional is a change", wrote)
	equals("and the key is gone rather than nil-valued", merged.target, nil)
	check("with nothing else touched", merged.hp == 10)

	--[[ The other direction, so "changed" and "present" are shown to be two bits rather than one
	     read twice. ]]
	local _, back = roundTrip(delta, dropped, held)
	equals("and it comes back", back.target, 900)

	--[[ An optional that was absent and stays absent is not a change, which is the assertion that
	     fails if the outer bit is being read as presence. ]]
	local still = roundTrip(delta, dropped, { hp = 10 })
	check("absent to absent is not a change", not still)

	local moved = roundTrip(delta, held, { hp = 11, target = 900 })
	check("and a sibling moving does not disturb it", moved)
end

do
	--[[
		An optional with a default: absent and the default are one value to the reader, so they are
		one value to the differ — a game that leaves the field out and then sets it to the default
		has not moved it — and a patch back to the default merges as the default, not as nil
		(`PLAN-M5` phase 5).
	]]
	local schema = t.struct({ hp = t.u8, speed = t.optional(t.u8, 16) })
	local delta = Delta.build(Ir.lower(schema))

	local absent = { hp = 10 }
	local written = { hp = 10, speed = 16 }
	local faster = { hp = 10, speed = 20 }

	check("absent to the default is not a change", not roundTrip(delta, absent, written))
	check("nor the default to absent", not roundTrip(delta, written, absent))

	local wrote, merged = roundTrip(delta, written, faster)
	check("the default to a value is a change", wrote)
	equals("and the value arrives", merged.speed, 20)

	local back, restored = roundTrip(delta, faster, absent)
	check("a value back to absent is a change", back)
	equals("and it merges as the default, not as nil", restored.speed, 16)

	--[[ A literal never moves, and a set replaces whole like the map it is. ]]
	local tagged = t.struct({ version = t.literal("v3"), unlocked = t.set(t.u8) })
	local tags = Delta.build(Ir.lower(tagged))

	check(
		"a literal is never a change",
		not roundTrip(
			tags,
			{ version = "v3", unlocked = { [1] = true } },
			{ version = "v3", unlocked = { [1] = true } }
		)
	)

	local grew, more = roundTrip(
		tags,
		{ version = "v3", unlocked = { [1] = true } },
		{ version = "v3", unlocked = { [1] = true, [2] = true } }
	)
	check("an entry added to a set is a change", grew)
	check("and the set arrives whole", more.unlocked[1] == true and more.unlocked[2] == true)
	equals("with the literal beside it", more.version, "v3")
end

do
	--[[ A nested struct nothing touched comes back **by reference**. That is not a micro-optimisation
	     to assert for its own sake: it is what makes a patch cheap on the receive side, and the
	     alternative — cloning every level on every patch — is the allocation this module exists to
	     avoid. ]]
	local schema = t.struct({
		left = t.struct({ x = t.u8, y = t.u8 }),
		right = t.struct({ x = t.u8, y = t.u8 }),
	})

	local delta = Delta.build(Ir.lower(schema))

	local base = { left = { x = 1, y = 2 }, right = { x = 3, y = 4 } }
	local next_ = { left = { x = 1, y = 2 }, right = { x = 3, y = 9 } }

	local _, merged = roundTrip(delta, base, next_)

	check("the merged value is correct", deepEquals(merged, next_))
	check("the untouched half is the same table", rawequal(merged.left, base.left))
	check("the touched half is a new one", not rawequal(merged.right, base.right))
	check("and the baseline was not mutated", base.right.y == 4)
end

do
	--[[ A patch is `counted` framing and its ceiling has to hold, the same as any other payload —
	     otherwise a replicated channel would refuse its own patches at stage `budget`, which is the
	     defect M3 phase 9 found in `Ir.ceiling` and the reason this is asserted here too. ]]
	local schema = t.struct({ a = t.boolean, list = t.array(t.boolean, 0, 12), n = t.u16 })
	local delta = Delta.build(Ir.lower(schema))

	local base = { a = false, list = {}, n = 0 }
	local next_ = { a = true, list = { true, false, true }, n = 65535 }

	Buffer.take()
	Buffer.load(nil)
	delta.write(base, next_)

	local size = buffer.len((Buffer.take()))
	check(
		`a maximal patch of {size} bytes fits under a ceiling of {delta.layout.maxSize}`,
		size <= delta.layout.maxSize
	)
end

-- ---------------------------------------------------------------------------------------------
-- A subject that arrived, and one that went away
-- ---------------------------------------------------------------------------------------------

suite.passing()

do
	--[[
		The two things the root bit is for, and the reason replication needs no second packet shape.

		**A snapshot is a change against nothing.** `write(nil, value)` finds every field different
		and writes all of them, which is what a client with no baseline needs — and it costs what a
		whole encode would have, because the patch's flags fit in the byte the schema's own flags
		were already using.
	]]
	local schema = t.struct({
		hp = t.u8,
		gold = t.u16,
		tag = t.optional(t.u8),
		pos = t.struct({ x = t.u8, y = t.u8 }),
	})

	local delta = Delta.build(Ir.lower(schema))
	local codec = Serdes.fromSchema(schema)
	local value = { hp = 7, gold = 900, tag = nil, pos = { x = 3, y = 4 } }

	Buffer.take()
	Buffer.load(nil)
	check("a value against nothing is a change", delta.write(nil, value))
	local arrival = buffer.len((Buffer.take()))

	Buffer.load(nil)
	codec.write(value)
	local snapshot = buffer.len((Buffer.take()))

	equals("and costs what the whole value would have", arrival, snapshot)

	--[[ It has to round-trip against nothing too, or a client's first packet would leave it with a
	     table missing whatever the differ decided was equal to nil. ]]
	Buffer.load(nil)
	delta.write(nil, value)
	local packed = Buffer.take()
	Buffer.beginRead(packed, nil)
	local arrived: any = delta.apply(nil)

	check("and rebuilds the whole value", deepEquals(arrived, value))
	equals("including an optional that is absent", arrived.tag, nil)
end

suite.passing()

do
	local schema = t.struct({ hp = t.u8, gold = t.u16 })
	local delta = Delta.build(Ir.lower(schema))
	local held = { hp = 5, gold = 10 }

	--[[ **Gone.** The root bit clear, and no body at all — which is the packet `PLAN-M4` D-4 needs
	     for "one leaving needs to be told to forget", and which would otherwise have been a second
	     shape on the wire with a discriminator in front of both. ]]
	Buffer.take()
	Buffer.load(nil)
	check("a value going away is a change", delta.write(held, nil))
	local removal = buffer.len((Buffer.take()))

	Buffer.load(nil)
	delta.write(nil, held)
	local arrival = buffer.len((Buffer.take()))

	check(`a removal of {removal} bytes is smaller than the arrival of {arrival}`, removal < arrival)

	Buffer.load(nil)
	delta.write(held, nil)
	local packed = Buffer.take()
	Buffer.beginRead(packed, nil)

	equals("and reads back as nothing", delta.apply(held), nil)

	--[[ Telling a client that nothing is gone is the same packet as telling it nothing changed, so
	     it has to be refused here rather than written — otherwise every tick would carry one
	     removal per subject no client has ever seen. ]]
	Buffer.load(nil)
	check("nothing to nothing is not a change", not delta.write(nil, nil))
	equals("and wrote nothing", buffer.len((Buffer.take())), 0)

	--[[ And the arrival of a subject whose fields are *all* absent still has to arrive, or the
	     client never learns it exists. This is the one case where the differ finds nothing and the
	     packet is sent anyway. ]]
	local sparse = t.struct({ a = t.optional(t.u8), b = t.optional(t.u8) })
	local thin = Delta.build(Ir.lower(sparse))

	Buffer.load(nil)
	check("a subject with nothing set still arrives", thin.write(nil, {}))

	local empty = Buffer.take()
	Buffer.beginRead(empty, nil)
	local seen = thin.apply(nil)

	check("and reads back as a value rather than a removal", seen ~= nil)
	equals("with nothing in it", next(seen :: any), nil)

	Buffer.load(nil)
end

do
	--[[
		**A patch against a baseline that is not there is refused.**

		The bits at the front of a patch say which fields it carries; the rest are "unchanged", which
		is only readable against a value that has them. Merging one into nothing produced a struct
		with fields missing — a value the channel's own `codec.check` refuses, handed to a handler
		that was promised it could not be.

		Nobody has to be attacking for it to happen: a client that refuses one change holds a
		baseline the server has already moved past, and the next honest patch is computed against
		something it no longer has. `PLAN-M4` phase 6 found it with the fuzzer, 8 times in 4,000
		mutated rounds, and the recovery it needs — refuse, then ask for the channel again — was
		already built.
	]]
	local schema = t.struct({ hp = t.u8, gold = t.u16 })
	local delta = Delta.build(Ir.lower(schema))

	local held = { hp = 5, gold = 10 }

	suite.failing()

	Buffer.take()
	Buffer.load(nil)
	check("one field moving is a patch", delta.write(held, { hp = 6, gold = 10 }))

	local packed = Buffer.take()

	Buffer.beginRead(packed, nil)
	local value, failure = delta.apply(nil)

	equals("and against no baseline it is nothing", value, nil)
	check("with a reason, which is what separates it from a removal", failure ~= nil)

	--[[ The same bytes against the baseline they were written for. Without this the assertion above
	     would hold for a `Delta` that refused every patch ever written. ]]
	Buffer.beginRead(packed, nil)
	local merged, refused = delta.apply(held)

	equals("the same patch against the baseline it was written for merges", refused, nil)
	check("into the value it describes", deepEquals(merged, { hp = 6, gold = 10 }))

	--[[ A nested struct the patch did not touch is the same hole one level down, and it is a
	     separate branch of the merger — the one that recurses rather than reading a value. ]]
	local nested = Delta.build(Ir.lower(t.struct({ n = t.u8, pos = t.struct({ x = t.u8, y = t.u8 }) })))

	Buffer.load(nil)
	nested.write({ n = 1, pos = { x = 1, y = 2 } }, { n = 2, pos = { x = 1, y = 2 } })

	local partial = Buffer.take()
	Buffer.beginRead(partial, nil)

	local _, missing = nested.apply(nil)
	check("a sub-struct nothing carried is refused too", missing ~= nil)

	Buffer.load(nil)
end

suite.passing()

-- ---------------------------------------------------------------------------------------------
-- What "the same" means for a union
-- ---------------------------------------------------------------------------------------------

do
	--[[
		The property above shows a changed union arrives. What it cannot show is the other half: that
		an **unchanged** one writes nothing, which is the whole economy of a patch and the one thing a
		diff can get wrong while still round-tripping perfectly.

		A union needs its own comparison because two branches share no fields: comparing them the way
		a struct is compared would read `value.x` off a branch that has no `x`, find nil on both
		sides, and call two different actions the same.
	]]
	local delta = Delta.build(Ir.lower(t.struct({
		n = t.u8,
		act = t.union({ move = t.struct({ x = t.u8, y = t.u8 }), wait = t.u8 }),
	})))

	local base = { n = 1, act = { tag = "move", value = { x = 1, y = 2 } } }

	Buffer.take()
	Buffer.load(nil)

	check("an equal union writes nothing", not delta.write(base, {
		n = 1,
		act = { tag = "move", value = { x = 1, y = 2 } },
	}))

	Buffer.load(nil)
	check(
		"a value inside the same branch is a change",
		delta.write(base, {
			n = 1,
			act = { tag = "move", value = { x = 9, y = 2 } },
		})
	)

	Buffer.load(nil)

	--[[ The case a struct-shaped comparison gets wrong: `wait` has no `x` or `y`, so a walk over the
	     move branch's field names finds nil on both sides and concludes nothing moved. ]]
	check(
		"and so is the same value in another branch",
		delta.write(base, {
			n = 1,
			act = { tag = "wait", value = 1 },
		})
	)

	Buffer.load(nil)

	--[[
		**The bit fork, pinned by an assertion rather than by a require-time self-check.** A union's
		branches share their flag bits — only one branch is ever present — so its scope is the tag
		plus the *widest* branch, not the sum. `Ir.luau` asserts that at require time, which means
		the mutation is caught by the module failing to load rather than by a test; M4-1 counted it
		among the pins that are not tests. Three flags in one branch, one in the other, one tag bit:
		four, where a summed layout says five.
	]]
	local forked = Ir.lower(t.struct({
		act = t.union({
			a = t.struct({ p = t.boolean, q = t.boolean, r = t.boolean }),
			b = t.boolean,
		}),
	}))

	equals("a union's scope is the tag plus the widest branch", (forked.scope :: any).bits, 4)
end

-- ---------------------------------------------------------------------------------------------
-- Everything a node is, carried into the layout derived from it
-- ---------------------------------------------------------------------------------------------

do
	--[[
		**The one hand-kept list nothing was testing.**

		`Ir.patch` derives a second layout from the state one, and everything that is not a struct is
		copied whole by `cloneNode`. That copy was field by field, so a property added to `Node` and
		not added there produced a patch layout that reads a *different value* than the state layout
		wrote — no compile error, no failed round trip on the state side, and a silently wrong number
		on the client.

		M4 phase 8 added four properties (`step`, `whole`, `utf8`, `pattern`) and the copy carried
		none of them. A `t.quantized` field inside `nw.replicate` lost its step on the patch side and
		was read as a raw count of levels: measured, `-0.5` sent and `-1` delivered — the count fell
		outside the declared range, so the reader refused it and handed back the minimum.

		The copy is `table.clone` now, so a property comes across by default and only the four bit
		*positions* are dropped. What follows is the assertion that would have caught it — and it
		checks the layout rather than only the round trip, because a patch that is self-consistently
		wrong round-trips fine against itself.
	]]
	local schema = t.struct({
		normal = t.quantized(-1, 1, 2 / 254),
		owner = t.u53,
		name = t.string(1, 8, { utf8 = true, pattern = "%w+" }),
	})

	local state = Ir.lower(schema)
	local patch = Ir.patch(state)

	--[[ Down through the root's own optional, then each field's. ]]
	local fields = (patch.root.inner :: Ir.Node).fields :: { Ir.Field }
	local carried: { [string]: Ir.Node } = {}

	for _, field in fields do
		carried[field.name] = field.node.inner :: Ir.Node
	end

	equals("a quantised field keeps its step through the derivation", carried.normal.step, 2 / 254)
	equals("and its offset", carried.normal.offset, -1)
	check("a u53 keeps its wholeness", carried.owner.whole == true)
	check("a string keeps its utf8 flag", carried.name.utf8 == true)
	equals("and its pattern", carried.name.pattern, "%w+")

	--[[ And end to end, because a property that reaches the node and is then not read is the same
	     defect one layer down. ]]
	local delta = Delta.build(state)

	Buffer.take()
	Buffer.load(nil)

	local base = { normal = 0, owner = 1, name = "a" }
	local next_ = { normal = -0.5, owner = 7594110182, name = "abc" }

	check("the patch was written", delta.write(base, next_))

	local packed = Buffer.take()
	Buffer.beginRead(packed, nil)

	local merged, refused = delta.apply(base)

	equals("and read back", refused, nil)
	check(
		`the quantised field is a value and not a count of levels: {tostring(merged.normal)}`,
		math.abs(merged.normal - -0.5) <= (2 / 254) / 2
	)
	equals("the wide integer survives", merged.owner, 7594110182)
	equals("and the constrained string", merged.name, "abc")

	Buffer.load(nil)
end

suite.finish()

return true
