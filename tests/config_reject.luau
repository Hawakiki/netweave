--!strict
-- netweave:expect 8

--[[
	Settings that must not type-check.

		lune run analyze

	Half of what `nw.configure` refuses at runtime should never reach runtime. A misspelled rule is
	the case that matters: it reads as "I configured this" while the default stays in force, and
	the author finds out from a support thread rather than from the analyzer.

	~~Twelve diagnostics for nine mistakes: three of them fail the value layer (`Settings`) and the
	name layer (`CheckedSettings`) at once.~~ **One per mistake, since M3 phase 4.**

	The doubling was not a design; it was a bug wearing one. `nw.configure` was typed
	`<S>(settings: S & Settings)`, and Luau rejects *every* argument to that — so nine of the twelve
	were the value layer refusing correct settings, and this file counted them as evidence that its
	own cases worked. Both halves of the check now live in `CheckedSettings`, which says what is
	wrong in one line (`src/api/Config.luau`), and `tests/config_ok.luau` is the positive half that
	was missing and that would have caught it.
]]

local nw = require("../src/netweave")

-- A rule that does not exist.
nw.configure({ rules = { handlers = "warn" } })

--[[ A severity that is not one of the three is *not* here, and that is the one thing the analyzer
     cannot see. A bare `S` parameter gives a config block's severities no expected type, so
     `"loud"` reaches `CheckedSettings` widened to `string` with no literal left to compare.
     `Config.configure` refuses it at startup instead, and `tests/config_runtime.luau` pins that. ]]

-- A severity that is not a string at all.
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
