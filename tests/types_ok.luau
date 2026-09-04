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

return nil
