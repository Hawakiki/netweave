--!strict

--[[
	Spike — can a *forbidden* field be made a type error?

	Width subtyping accepts an extra property, so declaring only the allowed fields does not
	forbid anything (measured: the first run of this file rejected the missing field and accepted
	`authorize = 1`, both directly and through a local).

	The remaining candidate is declaring the forbidden field with a type nothing can satisfy.
]]

type Nope = nil

type IntentSpec = {
	data: string,
	rate: number,
	authorize: Nope,
}

local function intent(spec: IntentSpec): number
	return spec.rate
end

--[[ CONTROL 1: must type-check. The forbidden field is simply absent. ]]
local _ok = intent({ data = "x", rate = 60 })

--[[ CONTROL 2: explicit nil must also type-check, or the declaration is unwritable. ]]
local _explicitNil = intent({ data = "x", rate = 60, authorize = nil })

--[[ MUST FAIL: a function where the class forbids one. ]]
local _extra = intent({ data = "x", rate = 60, authorize = function() end })

--[[ MUST FAIL: the same through a local. ]]
local viaLocal = { data = "x", rate = 60, authorize = function() end }
local _indirect = intent(viaLocal)

--[[ MUST FAIL: a truthy non-function, in case the error came from the function type alone. ]]
local _scalar = intent({ data = "x", rate = 60, authorize = 1 })

return nil
