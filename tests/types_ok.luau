--!strict

--[[
	Every assertion here must type-check. `lune run analyze` fails if this file produces any
	diagnostic at all.

	These are type-level assertions, not runtime tests: assigning a value to an annotated local
	is how you ask Luau what it inferred. The runtime behaviour of the codec is tested in phase 4.
]]

local t = require("../src/types")

type Type<T> = t.Type<T>

-- ---------------------------------------------------------------------------------------------
-- Scalars, bare and constrained
-- ---------------------------------------------------------------------------------------------

local _u8: Type<number> = t.u8
local _u8Ranged: Type<number> = t.u8(0, 10)
local _i16: Type<number> = t.i16(-500, 500)
local _f32: Type<number> = t.f32(-90, 90)
local _bool: Type<boolean> = t.boolean
local _str: Type<string> = t.string
local _strBounded: Type<string> = t.string(0, 64)
local _buf: Type<buffer> = t.buffer(0, 900)

-- ---------------------------------------------------------------------------------------------
-- Roblox datatypes
-- ---------------------------------------------------------------------------------------------

local _vec2: Type<Vector2> = t.vector2
local _vec3: Type<Vector3> = t.vector3
local _unit: Type<Vector3> = t.unitVector3
local _cf: Type<CFrame> = t.cframe
local _color: Type<Color3> = t.color3
local _inst: Type<Instance> = t.instance
local _sound: Type<Instance> = t.instance("Sound")

-- ---------------------------------------------------------------------------------------------
-- Composites
-- ---------------------------------------------------------------------------------------------

local _array: Type<{ number }> = t.array(t.u8)
local _exact: Type<{ number }> = t.array(t.u8, 100)
local _bounded: Type<{ string }> = t.array(t.string, 0, 8)
local _optional: Type<number?> = t.optional(t.u16)
local _map: Type<{ [string]: number }> = t.map(t.string, t.u8)

local weapon = t.enum({
	primary = true,
	secondary = true,
	melee = true,
})

local _weapon: Type<"primary" | "secondary" | "melee"> = weapon

-- ---------------------------------------------------------------------------------------------
-- Structs, including the shapes `docs/DESIGN-API.md` uses
-- ---------------------------------------------------------------------------------------------

local entity = t.struct({
	id = t.u8,
	x = t.u8,
	y = t.u8,
	z = t.u8,
	orientation = t.u8,
	animation = t.u8,
})

local _entity: Type<{
	id: number,
	x: number,
	y: number,
	z: number,
	orientation: number,
	animation: number,
}> =
	entity

--[[
	**The canonical replicated-state schema, which had never been in an `_ok` file** (M4-1, 중대):
	`t.map(t.u16, Entity)` was a type error, because a `T` read out of a `Type<StructPayload<…>>`
	through a generic parameter is `unknown`. The only `t.map` this file wrote was primitive on
	both sides. The same seam, measured next, took `t.optional(entity)` and `t.array(entity)` to
	`unknown` outside a spec literal. Each is written here with the payload it has to have, and the
	one-line cases below say the constructor's payload type is nameable through `t.`.
]]
type Entity = {
	id: number,
	x: number,
	y: number,
	z: number,
	orientation: number,
	animation: number,
}

local _entities: Type<{ [number]: Entity }> = t.map(t.u16, entity)
local _byName: Type<{ [string]: Entity }> = t.map(t.string(1, 32), entity)
type Weapon = "primary" | "secondary" | "melee"
local _byWeapon: Type<{ [Weapon]: number }> = t.map(weapon, t.u8)
local _maybeEntity: Type<Entity?> = t.optional(entity)
local _maybeWeapon: Type<Weapon?> = t.optional(weapon)
local _entityList: Type<{ Entity }> = t.array(entity)
local _entityFixed: Type<{ Entity }> = t.array(entity, 100)

local _mapPayload: t.MapPayload<typeof(t.u16), typeof(entity)> =
	{ [1] = { id = 1, x = 0, y = 0, z = 0, orientation = 0, animation = 0 } }
local _optionalPayload: t.OptionalPayload<typeof(entity)> = nil
local _arrayPayload: t.ArrayPayload<typeof(weapon)> = { "primary", "melee" }

--[[ Nesting: a struct inside an array inside a struct. ]]
local snapshot = t.struct({
	tick = t.u32,
	entities = t.array(entity, 100),
})

local _snapshot: Type<{ tick: number, entities: { { id: number, x: number, y: number, z: number, orientation: number, animation: number } } }> =
	snapshot

--[[ The `FlagIdiomatic` payload from the M0 benchmark, written the way netweave wants it. ]]
local flags = t.struct({
	f1 = t.boolean,
	f2 = t.boolean,
	weapon = weapon,
	team = t.enum({ red = true, blue = true }),
	targetId = t.optional(t.u16),
	combo = t.optional(t.u8),
})

local _flags: Type<{
	f1: boolean,
	f2: boolean,
	weapon: "primary" | "secondary" | "melee",
	team: "red" | "blue",
	targetId: number?,
	combo: number?,
}> =
	flags

--[[ The shot from `docs/DESIGN-API.md` §4. ]]
local shot = t.struct({
	origin = t.vector3,
	direction = t.unitVector3,
	seq = t.u16,
})

local _shot: Type<{ origin: Vector3, direction: Vector3, seq: number }> = shot

--[[
	`Descriptor` and `Type<T>` duplicate their fields (see `src/types/init.luau`). These two
	assignments fail the moment they drift apart, which is the only thing keeping the duplication
	honest.
]]
local _descriptorFromType: t.Descriptor = (nil :: any) :: t.Type<unknown>
local _concreteIsDescriptor: t.Descriptor = t.u8

--[[
	**`PayloadOf`, written the way its own docstring prescribes.**

	It is the one `export type function` in `src/types/init.luau` that the module never referenced,
	and per `spike/declare/README.md` Q5 that means it did not reduce for anyone requiring the
	module: the alias became an error type, silently, so every game function annotated with it was
	unchecked and `t.PayloadOf<number>` printed nothing where it should have said "expected a
	netweave type". A local instantiation in the module fixes it, and this is the half that proves
	the fix — a `_reject` file cannot, because the failure *removed* diagnostics.
]]
--[[ Underscored for the reason `tests/types_reject.luau` gives beside its own: `typeof` in a type
     position is a use selene cannot see. ]]
local _Shot = t.struct({ origin = t.vector3, seq = t.u16 })

type ShotPayload = t.PayloadOf<typeof(_Shot)>

local _shot: ShotPayload = { origin = Vector3.new(1, 2, 3), seq = 4 }

--[[ And through a channel's declared schema, which is where a game actually reaches for it: the
     handler's parameter and the alias have to be the same type. ]]
local function handle(payload: ShotPayload): number
	return payload.seq
end

local _seq: number = handle({ origin = Vector3.zero, seq = 9 })

--[[ `t.quantized` carries a plain `number`, and saying so here is what makes that a checked claim
     rather than a docstring: a constructor that returned `Type<unknown>` would infer `unknown` for
     the field and every read of it downstream. ]]
local _Aim = t.struct({
	normal = t.quantized(-1, 1, 2 / 254),
	yaw = t.quantized(-180, 180, 0.25),
})

local _aim: t.PayloadOf<typeof(_Aim)> = { normal = -0.5, yaw = 90 }

local function heading(payload: { normal: number, yaw: number }): number
	return payload.yaw
end

local _heading: number = heading(_aim)

--[[ `t.string`'s third argument. Annotated rather than written inline so the options table is
     *checked* — an unannotated literal would be accepted as any table, which is the shape that let
     `nw.configure` ship refusing every call it was given. ]]
local _options: t.TextOptions = { utf8 = true, pattern = "[%w_]+" }
local _named: t.Type<string> = t.string(1, 20, _options)

--[[ And the callable itself, which is the type that carries that parameter: `Ranged<string>` does
     not, so annotating it that way would compile and then refuse the options at the call site. ]]
local _text: t.Text = t.string
local _plain: t.Type<string> = _text(0, 8)

--[[
	**`t.union` narrows**, and that is the whole reason its payload is a `tag`/`value` pair rather
	than one optional field per case.

	This has to be asserted here rather than in `types_reject.luau`, because the failure a union
	prevents is that too *much* is accepted: a struct of optionals lets a reader write
	`action.attack` on a move and get `nil` instead of a diagnostic. What a rejection file can show
	is the payload that does not fit a tag, which it does; what only this file can show is that the
	fit *works* — that `value` is the move's fields inside the branch and the wait's number outside
	it.
]]
local _Action = t.union({
	move = t.struct({ x = t.u8, y = t.u8 }),
	wait = t.u8,
})

type Action = t.PayloadOf<typeof(_Action)>

local function cost(action: Action): number
	if action.tag == "move" then
		return action.value.x + action.value.y
	end

	return action.value
end

local _cost: number = cost({ tag = "wait", value = 3 })
local _moved: number = cost({ tag = "move", value = { x = 1, y = 2 } })

--[[ Built as a local and then sent, which is the other half of how a game touches a union: the
     narrowing above is for a value that arrived, and this is one on its way out. ]]
local _wait: Action = { tag = "wait", value = 3 }
local _move: Action = { tag = "move", value = { x = 4, y = 5 } }

--[[ A vector's component schema, and the callable type that carries it. `Type<Vector3>` alone does
     not, so annotating `t.vector3` that way would compile and then refuse the component at the call
     site — the same shape as `t.Text` above, and the same reason to write it here. ]]
local _componented: t.Componented<Vector3> = t.vector3
local _narrowVector: t.Type<Vector3> = _componented(t.i16(-2048, 2048))
local _flatVector: t.Type<Vector2> = t.vector2(t.i16(-1024, 1024))
local _direction: t.Type<Vector3> = t.unitVector3(t.quantized(-1, 1, 2 / 254))

--[[ `t.player` is the payload type Luau cannot get from a class name — `t.instance("Player")` is
     `Type<Instance>`, and `UserId` is what says these are not the same annotation. ]]
local _player: t.Type<Player> = t.player

local function userIdOf(payload: t.PayloadOf<typeof(t.player)>): number
	return payload.UserId
end

local _userId: (Player) -> number = userIdOf

--[[ And the container. Annotated rather than written inline for the reason `TextOptions` is: an
     unannotated literal is accepted as any table, so a misspelt key would be an option that looks
     like it passed. This file is analysed and never run, which is why `workspace` can appear in it
     at all. ]]
local _where: t.InstanceOptions = { descendantOf = workspace }
local _contained: t.Type<Instance> = t.instance("BasePart", _where)

--[[
	**The seven `tools/exports` called known gaps, written.** Every reason in that list was "never
	written by hand" or "reached through a signature", and the M4-1 report measured all seven
	annotating cleanly with annotations that really check — five wrong values in the non-trivial
	positions produced five diagnostics. A habit is not an inability, and the list exists for
	inabilities. So they are here, and a wrong value in any of them is a build break.
]]
local _ranged: t.Ranged<number> = t.u8
local _classed: t.Classed = t.instance
local _encoding: t.Encoding = "u16"
local _kind: t.Kind = "vector3"

local _structPayload: t.StructPayload<{ hp: typeof(t.u8), name: typeof(t.string) }> = { hp = 1, name = "x" }
local _enumPayload: t.EnumPayload<{ red: true, blue: true }> = "red"

--[[
	**A union payload checks a literal only after the alias has been used as a parameter type.**
	Measured while writing this: `local _: Union = { tag = "wait", value = 3 }` as the alias's first
	use fails with `Expected '"wait"', but got '"move" | "wait"'` — the literal's tag is widened to
	every branch's — and the same line passes once a function taking the alias has been called with
	a literal, which is the order `Action` above happens to be written in. Both negative controls
	(a wrong value inside a branch, a tag that names no branch) fail either way. A solver behaviour,
	recorded here and in PLAN-M5 rather than worked around in `src/`.
]]
type UnionShape = t.UnionPayload<typeof({ move = t.struct({ x = t.u8 }), wait = t.u8 })>

local function takeUnion(action: UnionShape): number
	if action.tag == "move" then
		return action.value.x
	end

	return action.value
end

local _took: number = takeUnion({ tag = "wait", value = 3 })
local _unionPayload: UnionShape = { tag = "move", value = { x = 1 } }

return nil
