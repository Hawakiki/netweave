--!strict

local t = require("../../src/types")

local Shot = t.struct({ origin = t.vector3, seq = t.u16 })

--[[ A: the full `Type<T>`, which is what `src/api/Channel.luau` uses today. ]]
local function full<T>(_spec: { data: t.Type<T>, rate: number }): T
	return (nil :: any) :: T
end

local _a: number = full({ data = Shot, rate = 1 })

--[[ B: a minimal structural type carrying only the phantom. ]]
local function minimal<T>(_spec: { data: { __payload: T }, rate: number }): T
	return (nil :: any) :: T
end

local _b: number = minimal({ data = Shot, rate = 1 })

--[[ C: the phantom read through a type function off the whole spec. ]]
export type function DataPayload(spec)
	local descriptor = types.copy(spec):readproperty(types.singleton("data"))

	if not descriptor then
		error("this channel needs `data`")
	end

	local payload = descriptor:readproperty(types.singleton("__payload"))

	if not payload then
		error("`data` must be a netweave type")
	end

	return payload
end

local function projected<S>(_spec: S): DataPayload<S>
	return (nil :: any) :: DataPayload<S>
end

local _c: number = projected({ data = Shot, rate = 1 })

--[[ D: does a type function's own error() reach the call site as a diagnostic? ]]
local _d = projected({ rate = 1 })
