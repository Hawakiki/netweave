--!strict

--[[
	Spike — does the provenance brand in `DESIGN-API.md` §6 actually hold?

	§6 declares `Untrusted<T> = T & { __nwUntrusted: true? }` and claims three things at once:
	the branded value is usable as a bare `T`, a bare `T` does not satisfy `Trusted<T>`, and an
	`Untrusted<T>` does not satisfy `Trusted<T>`. The optional `true?` is the part worth doubting:
	if an absent optional property still satisfies the type, both brands collapse.

	§6 was written before the spike existed, so nothing has checked it.
]]

export type Untrusted<T> = T & { __nwUntrusted: true? }
export type Trusted<T> = T & { __nwTrusted: true? }

local wire = (nil :: any) :: Untrusted<number>
local approved = (nil :: any) :: Trusted<number>

--[[ CONTROL 1: the whole design rests on a branded number being a number. ]]
local _arith: number = wire + 1
local _plain: number = wire

--[[ CONTROL 2: and on a trusted one being one too. ]]
local _trustedPlain: number = approved

local function giveItem(_amount: Trusted<number>) end

--[[ CONTROL 3: the legitimate call. ]]
giveItem(approved)

--[[ MUST FAIL: wire data reaching an authoritative function. This is the entire point. ]]
giveItem(wire)

--[[ MUST FAIL: an unbranded number is not evidence of anything either. ]]
giveItem(1)

--[[ The same question for a struct payload, where the brand meets a real table. ]]
type Shot = { origin: number, seq: number }

local shot = (nil :: any) :: Untrusted<Shot>
local _field: number = shot.seq

local function applyDamage(_shot: Trusted<Shot>) end

--[[ MUST FAIL: an untrusted struct is not a trusted one. ]]
applyDamage(shot)

--[[ MUST FAIL: nor is a bare table literal. ]]
applyDamage({ origin = 1, seq = 2 })

return nil
