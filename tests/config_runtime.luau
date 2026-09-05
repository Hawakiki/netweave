--!strict

--[[
	Global settings, under lune.

		lune run tests/config_runtime

	The rule this file exists to hold is not "configure works". It is that **no setting turns
	enforcement off**. A severity moves output and nothing else, and the moment that stops being
	true the config block becomes a way to delete G1 through G6 from a game whose author copied it
	off a forum post without reading it.

	So the refusal cases outnumber the acceptance cases here, deliberately: one way to configure
	something correctly, many ways to be told no.
]]

local Config = require("../src/api/Config")
local Observer = require("../src/api/Observer")

local failures = 0

local function fail(message: string)
	failures += 1
	print(`FAIL  {message}`)
end

local function check(name: string, condition: boolean)
	if not condition then
		fail(name)
	end
end

local function equals(name: string, actual: any, expected: any)
	if actual ~= expected then
		fail(`{name}: expected {tostring(expected)}, got {tostring(actual)}`)
	end
end

--[[ `pcall` of a function returning nothing types as a single result, so the call is widened
     before it is made rather than cast at every site. ]]
local attempt: (...any) -> ...any = pcall

local function refuses(name: string, fn: () -> (), fragment: string?)
	local ok, err = attempt(fn)

	if ok then
		fail(`{name}: expected a refusal, got none`)
		return
	end

	if fragment and not string.find(tostring(err), fragment, 1, true) then
		fail(`{name}: message did not mention "{fragment}" — got {tostring(err)}`)
	end
end

--[[ The sink writes with `warn`, which goes somewhere no test can read back, so `Observer` takes
     an injected one for the same reason `Budget` takes an injected clock. Asserting the console
     output is the only way to test the dedup, and the dedup is the part that keeps a refusal storm
     from becoming the outage. ]]
local captured: { string } = {}

local function capture()
	table.clear(captured)
	Observer.setSink(function(line: string)
		table.insert(captured, line)
	end)
end

local function release()
	Observer.setSink(nil)
end

Config.reset()
Observer.reset()

-- ---------------------------------------------------------------------------------------------
-- Defaults
-- ---------------------------------------------------------------------------------------------

do
	equals("parse defaults to warn", Config.severityOf("parse"), "warn")
	equals("handler defaults to error", Config.severityOf("handler"), "error")
	equals("authorize defaults to off", Config.severityOf("authorize"), "off")
	equals("queueCapacity defaults to 256", Config.limitOf("queueCapacity"), 256)
	equals("unreliableBytes defaults to 908", Config.limitOf("unreliableBytes"), 908)
	equals("contextGuard is undecided by default", Config.contextGuard(), nil)
end

-- ---------------------------------------------------------------------------------------------
-- What a valid call does, and does not, touch
-- ---------------------------------------------------------------------------------------------

do
	Config.configure({ rules = { budget = "off" } })

	equals("the named rule moved", Config.severityOf("budget"), "off")
	equals("an unnamed rule did not", Config.severityOf("parse"), "warn")
	equals("an unnamed limit did not", Config.limitOf("queueCapacity"), 256)

	Config.configure({ limits = { queueCapacity = 512 } })

	equals("the limit moved", Config.limitOf("queueCapacity"), 512)
	equals("and the earlier rule survived it", Config.severityOf("budget"), "off")

	Config.configure({ contextGuard = false })
	equals("contextGuard takes a decision", Config.contextGuard(), false)

	Config.reset()
	equals("reset restores the default", Config.severityOf("budget"), "warn")
	equals("reset restores the limit", Config.limitOf("queueCapacity"), 256)
	equals("reset un-decides contextGuard", Config.contextGuard(), nil)
end

-- ---------------------------------------------------------------------------------------------
-- Every way to be told no
-- ---------------------------------------------------------------------------------------------

do
	refuses("a misspelled rule", function()
		Config.configure({ rules = { handlers = "warn" } :: any })
	end, "no such rule")

	refuses("and it lists the rules that do exist", function()
		Config.configure({ rules = { handlers = "warn" } :: any })
	end, "rateUnbounded")

	refuses("a misspelled limit", function()
		Config.configure({ limits = { queueCapacitiy = 8 } :: any })
	end, "no such limit")

	refuses("a misspelled setting", function()
		Config.configure({ rule = {} } :: any)
	end, "no such setting")

	refuses("a severity that is not one of the three", function()
		Config.configure({ rules = { parse = "loud" } :: any })
	end, `"off", "warn" or "error"`)

	refuses("a severity that is not a string", function()
		Config.configure({ rules = { parse = 2 } :: any })
	end, "number")

	refuses("a limit below its range", function()
		Config.configure({ limits = { queueCapacity = 0 } })
	end, "outside")

	refuses("a limit above its range", function()
		Config.configure({ limits = { unreliableBytes = 1200 } })
	end, "outside")

	refuses("a fractional limit", function()
		Config.configure({ limits = { queueCapacity = 12.5 } })
	end, "whole number")

	refuses("a limit that is not a number", function()
		Config.configure({ limits = { queueCapacity = "512" } :: any })
	end, "whole number")

	refuses("settings that are not a table", function()
		Config.configure(7 :: any)
	end, "table of settings")

	refuses("rules that are not a table", function()
		Config.configure({ rules = "off" :: any })
	end, "table of rule names")

	refuses("limits that are not a table", function()
		Config.configure({ limits = 512 :: any })
	end, "table of limit names")

	refuses("a contextGuard that is not a boolean", function()
		Config.configure({ contextGuard = "on" :: any })
	end, "boolean")
end

-- ---------------------------------------------------------------------------------------------
-- A refused call applies nothing
-- ---------------------------------------------------------------------------------------------

do
	Config.reset()

	--[[ The valid half of this call is read before the invalid half is reached, so a naive
	     implementation that wrote as it read would leave `parse` moved and `handlers` not — half a
	     config, with nothing saying which half. ]]
	refuses("a call with one bad rule among good ones", function()
		Config.configure({ rules = { parse = "off", handlers = "off" } :: any })
	end, "no such rule")

	equals("and the good rule in it was not applied", Config.severityOf("parse"), "warn")

	refuses("a call with a bad limit after a good rule", function()
		Config.configure({ rules = { send = "off" }, limits = { queueCapacity = -1 } })
	end, "outside")

	equals("neither was the rule beside it", Config.severityOf("send"), "warn")
	equals("nor the limit", Config.limitOf("queueCapacity"), 256)
end

-- ---------------------------------------------------------------------------------------------
-- Severity never raises on wire data
-- ---------------------------------------------------------------------------------------------

do
	Config.reset()
	Config.configure({
		rules = {
			parse = "error",
			budget = "error",
			authorize = "error",
			handler = "error",
			queue = "error",
			send = "error",
			protocol = "error",
		},
	})

	--[[ This is G4 as a table lookup rather than as a convention. Every stage that carries wire
	     data answers false at the loudest severity there is; only the declaration rule answers
	     true. A future rule that gets `wire` wrong fails here rather than in a game. ]]
	for _, stage in { "parse", "budget", "authorize", "handler", "queue", "send", "protocol" } do
		check(`{stage} at "error" still does not raise`, not Config.raises(stage))
	end

	Config.configure({ rules = { rateUnbounded = "error" } })
	check('rateUnbounded at "error" does raise', Config.raises("rateUnbounded"))

	Config.configure({ rules = { rateUnbounded = "warn" } })
	check('rateUnbounded at "warn" does not', not Config.raises("rateUnbounded"))

	Config.reset()
end

-- ---------------------------------------------------------------------------------------------
-- "off" silences the console and nothing else
-- ---------------------------------------------------------------------------------------------

do
	Config.reset()
	Observer.reset()

	local seen = 0
	local stop = Observer.observe(function()
		seen += 1
	end)

	Config.configure({ rules = { budget = "off" } })

	capture()
	Observer.emit("game.move", nil, "budget", "over rate", 12)
	release()

	equals("the console said nothing", #captured, 0)
	equals("the observer still heard it", seen, 1)

	stop()
	Config.reset()
	Observer.reset()
end

-- ---------------------------------------------------------------------------------------------
-- The sink goes quiet on its own
-- ---------------------------------------------------------------------------------------------

do
	Config.reset()
	Observer.reset()
	Config.configure({ rules = { budget = "warn" }, limits = { repeatsPerDiagnostic = 3 } })

	capture()

	for _ = 1, 10 do
		Observer.emit("game.move", nil, "budget", "over rate", 12)
	end

	release()

	equals("ten refusals printed three times", #captured, 3)
	check("and the last one says it is done", string.find(captured[3], "suppressed", 1, true) ~= nil)

	--[[ A different channel is a different key, so one noisy channel cannot silence a quiet one —
	     which would turn the rate limiter on the log into a way to hide a second failure behind a
	     first. ]]
	capture()
	Observer.emit("game.chat", nil, "budget", "over rate", 12)
	release()

	equals("a different channel still gets its first report", #captured, 1)

	--[[ A different stage on the same channel likewise. ]]
	capture()
	Observer.emit("game.move", nil, "parse", "truncated", 4)
	release()

	equals("a different stage on the same channel does too", #captured, 1)

	Config.reset()
	Observer.reset()
end

-- ---------------------------------------------------------------------------------------------
-- "error" adds a traceback; it does not buy an unbounded number of them
-- ---------------------------------------------------------------------------------------------

do
	Config.reset()
	Observer.reset()
	Config.configure({ rules = { budget = "error" }, limits = { repeatsPerDiagnostic = 3 } })

	capture()

	for _ = 1, 5 do
		Observer.emit("game.move", nil, "budget", "over rate", 12)
	end

	release()

	--[[
		~~Five refusals printed five times.~~ **Three**, as of M3 phase 9.

		`error` used to print and return before the suppression, and two wire stages defaulted to it
		on the argument that the fiftieth report is worth as much as the first. That is true of the
		diagnostic and false of the cost: a wire rule fires at a rate the *peer* chooses, and an
		`error` carries a stack walk. Running the Studio suite is what showed it — one test's 2,000
		`direction` refusals filled the output window, each with a traceback.
	]]
	equals("an error-level rule goes quiet like any other", #captured, 3)
	--[[ The stack is what separates "error" from "warn" here; its text is environment-specific, so
	     what is asserted is that a stack is attached at all. ]]
	check("with a stack attached", string.find(captured[1], "\n", 1, true) ~= nil)
	equals(
		"and every one of the five was counted",
		Observer.diagnostics().channels["game.move"].budget.count,
		5
	)

	Config.reset()
	Observer.reset()
end

-- ---------------------------------------------------------------------------------------------
-- The snapshot cannot be turned back into a setter
-- ---------------------------------------------------------------------------------------------

do
	Config.reset()

	local taken = Config.snapshot()

	equals("it reports what is in force", taken.rules.parse, "warn")

	refuses("the snapshot itself is frozen", function()
		(taken :: any).contextGuard = true
	end)

	refuses("so are the rules inside it", function()
		(taken.rules :: any).parse = "off"
	end)

	refuses("and the limits", function()
		(taken.limits :: any).queueCapacity = 1
	end)

	equals("so the live config is untouched", Config.severityOf("parse"), "warn")

	--[[ A second snapshot is a second table. Handing the same frozen one back would make two
	     diagnostic screens share state, and the second would silently show the first's moment. ]]
	Config.configure({ rules = { parse = "off" } })

	equals("the old snapshot still reads the old value", taken.rules.parse, "warn")
	equals("a new one reads the new", Config.snapshot().rules.parse, "off")

	Config.reset()
end

-- ---------------------------------------------------------------------------------------------

-- ---------------------------------------------------------------------------------------------
-- rateUnbounded — the one rule that fires on the game's own code
-- ---------------------------------------------------------------------------------------------

do
	Config.reset()

	local nw = require("../src/netweave")
	local t = require("../src/types")

	local allows = nw.policy(function()
		return function()
			return nw.allow()
		end
	end)

	local function declare(rate: number)
		return function()
			nw.command({ data = t.struct({ seq = t.u16 }), rate = rate, authorize = allows })
		end
	end

	--[[ `warn` rather than the injected sink: this fires from `Channel`, at declaration time, and
	     is not a rejection — so it does not travel through `Observer` and there is nothing to
	     capture. What is asserted is the decision, through `Config.raises`, plus that a declaration
	     below the threshold reaches neither path. ]]
	local ok = attempt(declare(20))
	check("a rate a client can reach declares cleanly", ok == true)

	ok = attempt(declare(1e6))
	check("and so does an unreachable one, at the default severity", ok == true)

	Config.configure({ rules = { rateUnbounded = "error" } })

	refuses('an unreachable rate at "error"', declare(1e6), "effectively unlimited")

	ok = attempt(declare(10000))
	check("the threshold itself is still reachable", ok == true)

	ok = attempt(declare(10001))
	check("one past it is not", ok == false)

	Config.configure({ rules = { rateUnbounded = "off" } })

	ok = attempt(declare(1e6))
	check('and "off" lets a benchmark declare what it needs', ok == true)

	--[[ The rule is a lint and never a substitute for G2: an infinite rate is still refused
	     outright, at every severity, because "no limit" is the thing the guarantee forbids being
	     written at all. ]]
	Config.configure({ rules = { rateUnbounded = "off" } })

	refuses("an infinite rate is refused even with the lint off", declare(math.huge), "G2")
	refuses("so is zero", declare(0), "G2")

	Config.reset()
end
-- ---------------------------------------------------------------------------------------------
-- describe
-- ---------------------------------------------------------------------------------------------

do
	Config.reset()

	local described = Config.describe()

	equals("every rule is listed", #described, 11)
	equals("sorted", described[1].rule, "authorize")

	local wire = 0

	for _, row in described do
		if row.wire then
			wire += 1
		end

		check(`{row.rule} has a summary`, #row.summary > 0)
		equals(`{row.rule} reports its live severity`, row.severity, Config.severityOf(row.rule))
	end

	--[[ `replicate` joined them in M4 phase 4. It is a wire rule in the sense that decides here —
	     it cannot raise — even though what crosses the line is the game's own volume rather than a
	     peer's; raising on the send path mid-tick would take down the frame that noticed. ]]
	equals("ten of the eleven are wire rules", wire, 10)
end

-- ---------------------------------------------------------------------------------------------

Config.reset()
Observer.reset()

if failures > 0 then
	error(`{failures} config assertions failed`)
end

print("OK      config_runtime")

return true
