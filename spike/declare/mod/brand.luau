--!strict

local M = {}

type Ty<T> = { kind: string, __payload: T }

--[[ Never referenced inside this module. ]]
export type function Lonely(payload)
	local value = types.copy(payload)
	local tag = types.newtable()
	tag:setproperty(types.singleton("__lonely"), types.optional(types.singleton(true)))
	return types.intersectionof(value, tag)
end

--[[ Referenced only by a plain type alias in this module. ]]
export type function ViaAlias(payload)
	local value = types.copy(payload)
	local tag = types.newtable()
	tag:setproperty(types.singleton("__viaAlias"), types.optional(types.singleton(true)))
	return types.intersectionof(value, tag)
end

export type Wrapped<T> = { held: ViaAlias<T> }

--[[ Referenced by a local type alias that nothing else uses. ]]
export type function ViaLocal(payload)
	local value = types.copy(payload)
	local tag = types.newtable()
	tag:setproperty(types.singleton("__viaLocal"), types.optional(types.singleton(true)))
	return types.intersectionof(value, tag)
end

type _LocalUse = ViaLocal<{ probe: boolean }>

--[[ Referenced by a function signature. ]]
export type function ViaSignature(payload)
	local value = types.copy(payload)
	local tag = types.newtable()
	tag:setproperty(types.singleton("__viaSignature"), types.optional(types.singleton(true)))
	return types.intersectionof(value, tag)
end

function M.make<T>(_schema: Ty<T>): ViaSignature<T>?
	return nil
end

return M
