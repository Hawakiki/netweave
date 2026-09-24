--!strict
-- Can t.literal("v3") carry the singleton, and can t.optional(x, default) drop the nil by the default's type?

export type Type<T> = { kind: string, __payload: T }

-- 1. literal: does a string literal argument stay a singleton through a generic?
local function literal<V>(value: V): Type<V>
	return { kind = "literal", __payload = value }
end

local v3 = literal("v3")
local _keep: Type<"v3"> = v3 -- should pass if V is inferred as the singleton
local _widened: Type<string> = v3 -- passes either way

local flag = literal(true)
local _keepFlag: Type<true> = flag

-- 2. optional with a default: the type function reads the default's type
-- selene: allow(undefined_variable)
type function WithDefault(inner, default)
	local payload = inner:readproperty(types.singleton("__payload"))
	if not payload then
		error("no payload")
	end
	if default:is("nil") then
		return types.unionof(payload :: type, types.singleton(nil))
	end
	return payload :: type
end

local function optional<I, D>(inner: I, default: D?): Type<WithDefault<I, D>>
	return { kind = "optional", __payload = nil :: any }
end

local u8: Type<number> = { kind = "number", __payload = 0 }
local maybe = optional(u8)
local _maybe: Type<number?> = maybe
local _notPlain: Type<number> = maybe -- expect an error here: number? is not number

local defaulted = optional(u8, 5)
local _plain: Type<number> = defaulted -- should pass: the default removes the nil
