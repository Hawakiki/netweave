--!strict

--[=[
	@class Harness

	Assertions, and the count of which kind they were.

	```lua
	local suite = require("./harness").suite("hostile_runtime", 0.9)
	local check, equals = suite.check, suite.equals

	suite.failing()
	check("a truncated length is refused", ...)

	suite.finish()
	```

	Not shipped. This lives in `tests/` and nothing under `src/` requires it.
]=]

--[[
	`PLAN-M3` D-10, made into code.

	The rule is that a security layer's failure-path tests must outnumber its success-path tests,
	because such a layer has one way to succeed and many ways to fail — and a suite whose ratio says
	otherwise has tested the happy path and called it done. Measured before this file existed,
	`transport_runtime` was at 14% and `ir_runtime` at 13%.

	**A rule nobody counts is a rule nobody keeps**, so the counting is here and the suite fails on
	it rather than a reviewer noticing.

	The tag is per **section**, not per assertion, and that is deliberate. A hostile case is written
	as a block: craft the bytes, feed them in, then assert several things about what came back — how
	many were refused, at which stage, *and that the packets behind it still arrived*. That last one
	is a failure-path assertion even though it asserts a success, because what it tests is failure
	isolation. Tagging it per line would invite arguing each one, and per line is also the
	granularity at which a ratio can be gamed by relabelling.

	The floor is declared by the file, in the same spirit as `-- netweave:expect N` on a rejection
	file: a number someone lowered is a number in the diff.
]]

local Harness = {}

export type Suite = {
	--[[ Success-path assertions. ]]
	check: (name: string, condition: boolean) -> (),
	equals: (name: string, actual: any, expected: any) -> (),
	--[[ Fails the suite outright, for a case that cannot be expressed as a comparison. ]]
	fail: (message: string) -> (),

	--[[ Everything after this counts as failure-path, until `passing`. ]]
	failing: () -> (),
	--[[ And back. This is the state a suite starts in. ]]
	passing: () -> (),

	--[[ How many of each have run, for a suite that wants to assert on its own shape. ]]
	tally: () -> (number, number),

	finish: () -> (),
}

--[=[
	@within Harness
	@function suite
	@param name string -- the file, without the extension
	@param floor number? -- the least fraction of assertions that must be failure-path
	@return Suite

	Opens a suite. `floor` is enforced by [Suite.finish]; a suite that declares none is counted and
	reported but not held to a ratio.
]=]
function Harness.suite(name: string, floor: number?): Suite
	local failures = 0
	local passes = 0
	local refusals = 0
	local counting = false

	local function record()
		if counting then
			refusals += 1
		else
			passes += 1
		end
	end

	local function fail(message: string)
		failures += 1
		print(`FAIL  {message}`)
	end

	local self: Suite

	self = {
		fail = fail,

		check = function(label: string, condition: boolean)
			record()

			if not condition then
				fail(label)
			end
		end,

		equals = function(label: string, actual: any, expected: any)
			record()

			if actual ~= expected then
				fail(`{label}: expected {tostring(expected)}, got {tostring(actual)}`)
			end
		end,

		failing = function()
			counting = true
		end,

		passing = function()
			counting = false
		end,

		tally = function(): (number, number)
			return refusals, passes
		end,

		finish = function()
			local total = passes + refusals
			local share = if total == 0 then 0 else refusals / total

			if failures > 0 then
				error(`{failures} of {total} assertions failed in {name}`)
			end

			--[[ Reported whether or not there is a floor, because the number is the point: a file
			     drifting toward the happy path is visible long before it crosses a threshold. ]]
			local summary = `{total} assertions, {refusals} failure-path ({math.floor(share * 100 + 0.5)}%)`

			if floor and share < floor then
				error(
					`{name}: {summary}, under the {math.floor(floor * 100 + 0.5)}% this file declares. `
						.. `A security-relevant suite whose success paths outnumber its failure paths `
						.. `has tested the happy path and stopped (PLAN-M3 D-10). Write the missing `
						.. `refusal cases rather than lowering the floor.`
				)
			end

			print(`OK      {name} — {summary}`)
		end,
	}

	return self
end

return Harness
