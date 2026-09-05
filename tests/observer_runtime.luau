--!strict

--[[
	Rejection counters and the diagnostics snapshot, under lune.

		lune run tests/observer_runtime

	The sink deliberately goes quiet — three reports per channel and stage, then silence, because a
	default-on log whose failure mode is a refusal storm is an outage waiting for a bad client. The
	counters are what is left, and they are the only way to answer "is this channel refusing more
	than it was an hour ago", which is the question that separates a bug from an attack.
	`RESEARCH §3-G6` records that no surveyed library can answer it at all.

	So the counters must keep counting after the console has stopped talking. That is the assertion
	this file exists for; everything else here is about not being able to break them from outside.
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

local attempt: (...any) -> ...any = pcall

local function refuses(name: string, fn: () -> ())
	if attempt(fn) then
		fail(`{name}: expected a refusal, got none`)
	end
end

local function quiet()
	Observer.setSink(function() end)
end

Config.reset()
Observer.reset()

-- ---------------------------------------------------------------------------------------------
-- Counting
-- ---------------------------------------------------------------------------------------------

do
	Observer.reset()
	quiet()

	equals("nothing has been refused yet", Observer.diagnostics().total, 0)

	Observer.emit("game.move", nil, "budget", "over rate", 12)
	Observer.emit("game.move", nil, "budget", "over rate", 8)
	Observer.emit("game.move", nil, "parse", "truncated", 4)
	Observer.emit("game.chat", nil, "authorize", "muted", 30)

	local seen = Observer.diagnostics()

	equals("four refusals in total", seen.total, 4)
	equals("two of them at one channel and stage", seen.channels["game.move"].budget.count, 2)
	equals("with their bytes added up", seen.channels["game.move"].budget.bytes, 20)
	equals("a second stage on the same channel counts apart", seen.channels["game.move"].parse.count, 1)
	equals("and a second channel apart again", seen.channels["game.chat"].authorize.count, 1)
	equals("a stage that never fired is absent", seen.channels["game.chat"].budget, nil)
	equals("so is a channel that never refused", seen.channels["game.jump"], nil)

	Observer.reset()
end

-- ---------------------------------------------------------------------------------------------
-- The counters outlive the console
-- ---------------------------------------------------------------------------------------------

do
	Observer.reset()
	Config.reset()

	local printed = 0
	Observer.setSink(function()
		printed += 1
	end)

	Config.configure({ limits = { repeatsPerDiagnostic = 3 } })

	for _ = 1, 100 do
		Observer.emit("game.move", nil, "budget", "over rate", 10)
	end

	--[[ This is the whole file in two lines. The console said three things and stopped; the
	     counters know about all hundred. A library that only had the first would report a flood as
	     three lines and then look healthy. ]]
	equals("the console went quiet after three", printed, 3)
	equals("the counters did not", Observer.diagnostics().channels["game.move"].budget.count, 100)
	equals("and the bytes are all there", Observer.diagnostics().channels["game.move"].budget.bytes, 1000)

	Observer.reset()
	Config.reset()
end

-- ---------------------------------------------------------------------------------------------
-- A silenced rule still counts
-- ---------------------------------------------------------------------------------------------

do
	Observer.reset()
	Config.reset()
	quiet()

	Config.configure({ rules = { budget = "off" } })

	Observer.emit("game.move", nil, "budget", "over rate", 10)

	--[[ `"off"` is a setting about output. If it reached the counters it would be a way to make a
	     channel's refusals *disappear* from a diagnostic screen, which is the one thing a severity
	     must never be able to do (`PLAN-M3` D-11). ]]
	equals("a rule set to off still counts", Observer.diagnostics().channels["game.move"].budget.count, 1)

	Observer.reset()
	Config.reset()
end

-- ---------------------------------------------------------------------------------------------
-- An observer that throws does not stop the counting
-- ---------------------------------------------------------------------------------------------

do
	Observer.reset()
	quiet()

	local stop = Observer.observe(function()
		error("the observer blew up")
	end)

	local survived = attempt(function()
		Observer.emit("game.move", nil, "budget", "over rate", 10)
	end)

	check("an observer that throws does not reach the caller", survived == true)
	equals("and the refusal was still counted", Observer.diagnostics().total, 1)

	stop()
	Observer.reset()
end

-- ---------------------------------------------------------------------------------------------
-- An observer that detaches itself does not take the next one with it
-- ---------------------------------------------------------------------------------------------

do
	Observer.reset()
	quiet()

	--[[
		"Warn once, then stop watching" is ordinary game code, and it used to cost the observer
		registered behind it a rejection: the remover did `table.remove` while `emit` was walking
		`1..count`, so the third shifted into the second's index — which the loop had already
		passed — and the last index read `nil`. `xpcall(nil, ...)` does not raise, so nothing said
		so. Found by an external review (M3 phase 9); before the fix `second` and `third` each saw
		one where they should each see two.
	]]
	local first = 0
	local second = 0
	local third = 0

	--[[ Annotated rather than inferred: the closure names it before the assignment, so without a
	     declared type the solver reads it as optional and refuses the call. ]]
	local stopFirst: () -> ()

	stopFirst = Observer.observe(function()
		first += 1
		stopFirst()
	end)

	local stopSecond = Observer.observe(function()
		second += 1
	end)

	local stopThird = Observer.observe(function()
		third += 1
	end)

	Observer.emit("game.move", nil, "budget", "over rate", 10)

	equals("the one that detached still saw the rejection it detached on", first, 1)
	equals("the one behind it saw it too", second, 1)
	equals("and so did the one behind that", third, 1)

	Observer.emit("game.move", nil, "budget", "over rate", 10)

	equals("the detached one is gone", first, 1)
	equals("the others carry on", second, 2)
	equals("both of them", third, 2)

	--[[ And the list really compacted rather than keeping a hole: removing the rest leaves nothing
	     for a third rejection to reach. ]]
	stopSecond()
	stopThird()

	Observer.emit("game.move", nil, "budget", "over rate", 10)

	equals("nothing is left watching", second + third, 4)
	equals("and every one of the three was still counted", Observer.diagnostics().total, 3)

	Observer.reset()
end

-- ---------------------------------------------------------------------------------------------
-- The snapshot is not a way back in
-- ---------------------------------------------------------------------------------------------

do
	Observer.reset()
	quiet()

	Observer.emit("game.move", nil, "budget", "over rate", 10)

	local taken = Observer.diagnostics()

	refuses("the snapshot is frozen", function()
		(taken :: any).total = 0
	end)

	refuses("so is the channel map", function()
		(taken.channels :: any)["game.move"] = nil
	end)

	refuses("and a channel's stages", function()
		(taken.channels["game.move"] :: any).budget = nil
	end)

	refuses("and a tally", function()
		(taken.channels["game.move"].budget :: any).count = 0
	end)

	equals("so the live counters are untouched", Observer.diagnostics().total, 1)

	--[[ A second snapshot is a second table. Handing the same frozen one back would make two
	     diagnostic screens share a moment, and the second would silently show the first's. ]]
	Observer.emit("game.move", nil, "budget", "over rate", 10)

	equals("the old snapshot still reads the old count", taken.channels["game.move"].budget.count, 1)
	equals("a new one reads the new", Observer.diagnostics().channels["game.move"].budget.count, 2)

	Observer.reset()
end

-- ---------------------------------------------------------------------------------------------
-- reset
-- ---------------------------------------------------------------------------------------------

do
	Observer.reset()
	quiet()

	local before = Observer.diagnostics().since

	Observer.emit("game.move", nil, "budget", "over rate", 10)
	equals("counted", Observer.diagnostics().total, 1)

	Observer.reset()
	quiet()

	equals("reset clears the total", Observer.diagnostics().total, 0)
	equals("and the channel it counted", Observer.diagnostics().channels["game.move"], nil)
	check("and moves the window forward", Observer.diagnostics().since >= before)
end

-- ---------------------------------------------------------------------------------------------

Observer.reset()
Config.reset()

if failures > 0 then
	error(`{failures} observer assertions failed`)
end

print("OK      observer_runtime")

return true
