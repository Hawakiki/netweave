--!strict
--!optimize 2

--[[
	Canonical benchmark payloads.

	Both peers build these independently from a fixed seed, so the receiver can validate what
	arrived without the expected value ever crossing the wire.

	The values here are library-agnostic. Each mode adapter reshapes them once at startup into
	whatever its library expects — string enum tags for Blink and Zap, integers for ByteNet,
	a nested `flags` table for Blink's `set` type. Reshaping never happens inside the measured
	loop (PLAN-M0 R-3).
]]

local Payloads = {}

export type Entity = {
	id: number,
	x: number,
	y: number,
	z: number,
	orientation: number,
	animation: number,
}

export type Flags = {
	f1: boolean,
	f2: boolean,
	f3: boolean,
	f4: boolean,
	f5: boolean,
	f6: boolean,
	f7: boolean,
	f8: boolean,
	f9: boolean,
	f10: boolean,
	f11: boolean,
	f12: boolean,
	--[[ 0-based index into `Payloads.WEAPONS`. ]]
	weapon: number,
	--[[ 0-based index into `Payloads.TEAMS`. ]]
	team: number,
	targetId: number?,
	combo: number?,
}

local SEED = 0
local ENTITY_COUNT = 100
local FLAG_COUNT = 12

--[[
	Blink and Zap represent unit enums as string literals; ByteNet 0.4.3 has no enum type at
	all, so a ByteNet author writes an integer. Adapters index these tables to convert.
]]
Payloads.WEAPONS = { "primary", "secondary", "melee", "grenade" }
Payloads.TEAMS = { "red", "blue" }

Payloads.ENTITY_COUNT = ENTITY_COUNT
Payloads.FLAG_COUNT = FLAG_COUNT

--[[
	`Random.new(SEED)` rather than `math.randomseed` so the harness does not disturb the
	global generator that the libraries under test might also use.
]]
function Payloads.arrayHeavy(): { Entity }
	local random = Random.new(SEED)
	local entities = table.create(ENTITY_COUNT)

	for index = 1, ENTITY_COUNT do
		entities[index] = {
			id = random:NextInteger(0, 255),
			x = random:NextInteger(0, 255),
			y = random:NextInteger(0, 255),
			z = random:NextInteger(0, 255),
			orientation = random:NextInteger(0, 255),
			animation = random:NextInteger(0, 255),
		}
	end

	return entities
end

--[[
	Both optionals are present. An absent optional would shorten the payload and make the
	byte comparison depend on the seed, which would be a worse measurement.
]]
function Payloads.flags(): Flags
	local random = Random.new(SEED + 1)
	local flags = {} :: any

	for index = 1, FLAG_COUNT do
		flags[`f{index}`] = random:NextInteger(0, 1) == 1
	end

	flags.weapon = random:NextInteger(0, #Payloads.WEAPONS - 1)
	flags.team = random:NextInteger(0, #Payloads.TEAMS - 1)
	flags.targetId = random:NextInteger(0, 65535)
	flags.combo = random:NextInteger(0, 255)

	return flags :: Flags
end

--[[
	Structural equality. Used by the receiving side to prove a mode actually round-trips its
	payload; a mode that fails this is reported as failed rather than dropped from the table
	(PLAN-M0 acceptance criterion 2).
]]
function Payloads.deepEquals(a: any, b: any): boolean
	if a == b then
		return true
	end

	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end

	for key, value in a do
		if not Payloads.deepEquals(value, b[key]) then
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

return Payloads
