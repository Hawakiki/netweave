--!strict

local Brand = require("./brand")

type Shot = { origin: number }

--[[ Each must fail. Any that does not has silently become `any`. ]]
local _lonely: Brand.Lonely<Shot> = 5
local _viaAlias: Brand.ViaAlias<Shot> = 5
local _viaLocal: Brand.ViaLocal<Shot> = 5
local _viaSignature: Brand.ViaSignature<Shot> = 5
local _wrapped: Brand.Wrapped<Shot> = 5
