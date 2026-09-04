--!strict
-- netweave:expect 12

--[[
	Settings that must not type-check.

		lune run analyze

	Half of what `nw.configure` refuses at runtime should never reach runtime. A misspelled rule is
	the case that matters: it reads as "I configured this" while the default stays in force, and
	the author finds out from a support thread rather than from the analyzer.

	Twelve diagnostics for nine mistakes: three of them fail the value layer (`Settings`) and the
	name layer (`CheckedSettings`) at once, and both are worth keeping — the first says what the
	field should hold, the second says the field does not exist.
]]

local nw = require("../src/netweave")

-- A rule that does not exist.
nw.configure({ rules = { handlers = "warn" } })

-- A severity that is not one of the three.
nw.configure({ rules = { parse = "loud" } })

-- A severity that is not a string.
nw.configure({ rules = { parse = 2 } })

-- A limit that does not exist.
nw.configure({ limits = { queueCapacitiy = 8 } })

-- A limit that is not a number.
nw.configure({ limits = { queueCapacity = "512" } })

-- A top-level setting that does not exist.
nw.configure({ rule = {} })

-- `contextGuard` is a boolean.
nw.configure({ contextGuard = "on" })

-- Settings are a table.
nw.configure(7)

-- The snapshot is not a way to set anything.
nw.config.snapshot().rules.parse = "off"

return true
