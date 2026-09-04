--!strict

local lib = require("./lib")

local shot = lib.struct({
	origin = lib.u8,
	label = lib.str,
})

--[[ ASSERTION: the payload type survives the module boundary. ]]
local _ok: lib.Type<{ origin: number, label: string }> = shot

--[[ MUST FAIL: wrong field type. ]]
local _bad: lib.Type<{ origin: string, label: string }> = shot

--[[ ASSERTION: the exported type function is usable by name from here. ]]
type Fields = { origin: lib.Type<number> }
local _direct: lib.StructPayload<Fields> = { origin = 1 }

return nil
