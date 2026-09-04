--!strict

--[[
	Does a `type function` cross a module boundary?

	This decides the file layout of `src/types/`: if type functions cannot be exported, every
	combinator that needs one has to live in the same file as its type function.
]]

export type Type<T> = {
	kind: string,
	__payload: T,
}

export type function StructPayload(fields)
	local result = types.newtable()
	for key, property in fields:properties() do
		result:setproperty(key, property.read:readproperty(types.singleton("__payload")))
	end
	return result
end

local lib = {}

function lib.struct<F>(_fields: F): Type<StructPayload<F>>
	return (nil :: any) :: Type<StructPayload<F>>
end

lib.u8 = (nil :: any) :: Type<number>
lib.str = (nil :: any) :: Type<string>

return lib
