--!strict

--[[
	What a declared `t.string` pattern costs on a hostile string.

		lune run spike/pattern/cost

	The reader runs `string.find(value, "^" .. pattern .. "$")` on whatever a peer sent, and Lua's
	matcher backtracks over every repetition of an unbounded item (`.*`, `.-`, `%s+`). With one such
	item the anchored match is linear in the input; with k of them it is about `n^k`, and `n` is
	bounded only by the declared `max`, which defaults to 65,535. SECURITY-REPORT-M4-1 measured
	`(.*)@(.*)%.(.*)` at 34 seconds per packet at that size; this probe stops at 16,384 bytes so it
	finishes in seconds, and the shape of the curve is the finding: 4x the input, ~16x the time.

	The second half is the rule `t.string` applies since PLAN-M4-BUG phase 2 — `max^k` for k
	unbounded items must stay under 2^16 steps — measured at the boundary it allows, so the number
	in the docstring is a number someone can re-run.
]]

local nw = require("../../src/netweave")
local t = nw.types

local function ms(runs: number, body: () -> ()): string
	local best = math.huge
	local worst = 0

	for _ = 1, runs do
		local started = os.clock()
		body()
		local took = (os.clock() - started) * 1000
		best = math.min(best, took)
		worst = math.max(worst, took)
	end

	return string.format("%.3f–%.3f", best, worst)
end

local function anchored(pattern: string, value: string)
	return string.find(value, `^{pattern}$`)
end

print("== the cost today, ms per match (n = 3)")

for _, size in { 1024, 4096, 16384 } do
	local twice = string.rep("x", size)
	local thrice = string.rep("@", size)
	local control = string.rep("a", size)

	print(
		string.format(
			"%6d B   (.*)x(.*)y %14s   (.*)@(.*)%%.(.*) %14s   [%%w_]+ %14s",
			size,
			ms(3, function()
				anchored("(.*)x(.*)y", twice)
			end),
			ms(3, function()
				anchored("(.*)@(.*)%.(.*)", thrice)
			end),
			ms(3, function()
				anchored("[%w_]+", control)
			end)
		)
	)
end

print("== does t.string accept it at the default max?")

local accepted = pcall(function()
	return t.string(0, 65535, { pattern = "(.*)@(.*)%.(.*)" })
end)

print(if accepted then "accepted — every packet on this field can cost 34 s" else "refused")

print("== the boundary the rule allows, ms per match (n = 5)")

--[[ Two unbounded items at max 256 and three at max 40 are the largest the 2^16 budget admits. ]]
print(string.format(
	"   256 B   (.*)x(.*)y %14s      40 B   (.*)@(.*)%%.(.*) %14s",
	ms(5, function()
		anchored("(.*)x(.*)y", string.rep("x", 256))
	end),
	ms(5, function()
		anchored("(.*)@(.*)%.(.*)", string.rep("@", 40))
	end)
))
