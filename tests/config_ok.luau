--!strict

--[[
	Settings that must type-check.

		lune run analyze

	This file exists because its absence shipped a bug. `nw.configure` was typed
	`<S>(settings: S & Config.Settings)`, which Luau rejects for **every** argument — including the
	example in the function's own docstring — and nothing said so, because the only file that called
	`nw.configure` was `tests/config_reject.luau`, where a diagnostic is what success looks like.
	Nine of its twelve expected diagnostics were this bug, and the count it guarded was guarding it.

	A rejection file is only half a test. The other half is the shape that has to keep working, and
	every settings shape a game can write is below.
]]

local nw = require("../src/netweave")

-- Each section on its own, because a call that sets one thing must not have to name the rest.
nw.configure({ rules = { budget = "warn" } })
nw.configure({ limits = { queueCapacity = 512 } })
nw.configure({ contextGuard = false })

-- Several fields in one section.
nw.configure({ rules = { parse = "error", authorize = "off", handler = "warn" } })
nw.configure({ limits = { queueCapacity = 512, pendingPerBatch = 64, callsInFlight = 32 } })

-- Every rule and every limit by name, so a field added to one and not the other is a diagnostic.
nw.configure({
	rules = {
		parse = "warn",
		budget = "warn",
		authorize = "off",
		handler = "error",
		queue = "warn",
		send = "warn",
		protocol = "error",
		query = "warn",
		direction = "error",
		rateUnbounded = "warn",
	},

	limits = {
		queueCapacity = 256,
		pendingPerBatch = 256,
		unreliableBytes = 908,
		repeatsPerDiagnostic = 3,
		callsInFlight = 16,
	},

	contextGuard = true,
})

-- Nothing at all, which reads the current settings back without changing any.
nw.configure({})

--[[ A severity held in a variable rather than written at the call. It arrives as the union of the
     three singletons rather than as a literal, and that has to keep working — a game that maps its
     own log level onto netweave's is exactly the reason `Severity` is exported. ]]
local level: nw.Severity = if 1 > 0 then "warn" else "off"

nw.configure({ rules = { budget = level } })

--[[ The snapshot is readable. It is frozen and `tests/config_reject.luau` pins that writing to it
     is an error; reading it is how a game reports what it is running with. ]]
local snapshot = nw.configure({ rules = { queue = "off" } })
local _severity: string = snapshot.rules.queue
local _capacity: number = snapshot.limits.queueCapacity

--[[
	**The exported type, used to build the argument it names.**

	`nw.Settings` could not do that until M4: every field it declares is optional, `CheckedSettings`
	tested each one for a bare tag, and `:is("table")` is false for a union — so
	`local s: nw.Settings = { ... }; nw.configure(s)` was a type error reading "`rules` takes a table
	of rules, got that". The only file that called `nw.configure` at all was the rejection file,
	where a diagnostic is what success looks like: the same shape as the M3 phase 0 incident that put
	"write the `_ok` half" in `CLAUDE.md` §9, found a second time by M4's security report.

	A game writes this when its settings come from somewhere other than the call site — a module, a
	place-dependent table, a function that builds them.
]]
local declared: nw.Settings = {
	rules = { budget = "warn" },
	limits = { queueCapacity = 64 },
	contextGuard = false,
}

nw.configure(declared)

--[[ And the sections on their own, which is what a game assembling settings from parts holds. ]]
local limits: nw.Settings = { limits = { pendingPerBatch = 128, baselinesPerClient = 512 } }
nw.configure(limits)

nw.config.reset()

return true
