--!strict

--[[
	Rate budgets and byte accounting, under lune.

		lune run tests/budget_runtime

	Guarantee G2 says every inbound channel declares a rate and there is no unlimited. M1 made the
	declaration a type error; this is the half that has to hold at runtime.

	Warp is the only surveyed library that attempts any of this and gets all three parts wrong
	(`RESEARCH §3.7-K`). Its three bugs are three tests here, because a check written against a
	known failure and not tested against it is a check nobody has run.

	The clock is injected. A window is a second long, and a test that has to wait one is a test
	nobody runs — which is close to why Warp's version was never caught.
]]

local Budget = require("../src/transport/Budget")

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

local clock = 0

local function now(): number
	return clock
end

local alice = { name = "alice" }
local bob = { name = "bob" }

local function channelOf(name: string, rate: number?): any
	return { qualified = name, rate = rate }
end

-- ---------------------------------------------------------------------------------------------
-- The declared rate is the rate
-- ---------------------------------------------------------------------------------------------

do
	clock = 0

	local budget = Budget.new(now)
	local channel = channelOf("test.limited", 3)

	equals("the first is admitted", budget.admit(channel, alice, 10), nil)
	equals("the second", budget.admit(channel, alice, 10), nil)
	equals("the third", budget.admit(channel, alice, 10), nil)

	--[[ Acceptance criterion 1: a channel declared `rate = n` refuses packet n + 1 inside its
	     window. ]]
	local denial = budget.admit(channel, alice, 10)
	check("and the fourth is refused", denial ~= nil)
	check("saying what the limit was", string.find(tostring(denial), "3", 1, true) ~= nil)

	local packets, bytes, refused = budget.usage(alice, channel)
	equals("three were charged", packets, 3)
	equals("and the refused one's bytes were counted too", bytes, 40)
	equals("with the refusal recorded", refused, 1)
end

do
	clock = 0

	--[[ Budgets are per player. One player exhausting a channel must not refuse another's traffic
	     on it, which would turn a rate limit into a denial of service anyone could trigger. ]]
	local budget = Budget.new(now)
	local channel = channelOf("test.shared", 2)

	budget.admit(channel, alice, 1)
	budget.admit(channel, alice, 1)

	check("alice is out", budget.admit(channel, alice, 1) ~= nil)
	equals("bob is not", budget.admit(channel, bob, 1), nil)
end

do
	clock = 0

	--[[ And per channel. A player at their limit on one channel still has their budget on another,
	     because the rates were declared separately. ]]
	local budget = Budget.new(now)
	local busy = channelOf("test.busy", 1)
	local quiet = channelOf("test.quiet", 1)

	budget.admit(busy, alice, 1)

	check("the busy channel is out", budget.admit(busy, alice, 1) ~= nil)
	equals("the quiet one is not", budget.admit(quiet, alice, 1), nil)
end

-- ---------------------------------------------------------------------------------------------
-- Warp's three bugs, as three tests
-- ---------------------------------------------------------------------------------------------

do
	clock = 0

	--[[
		**Real bytes.** Warp charges `math.max(buffer.len(b), 800)`, so a one-byte packet costs 800
		and the whole thing is a packet counter wearing a byte counter's name
		(`RESEARCH §3.7-K`).
	]]
	local budget = Budget.new(now)
	local channel = channelOf("test.bytes", 100)

	budget.admit(channel, alice, 1)
	budget.admit(channel, alice, 2)
	budget.admit(channel, alice, 600)

	local packets, bytes = budget.usage(alice, channel)
	equals("three packets", packets, 3)
	equals("and their real size", bytes, 603)
end

do
	clock = 0

	--[[
		**A reset that cannot fail to run.** Warp resets its counter inside a send loop that begins
		with `if #content == 0 then continue`, so a player the server has nothing to say to is never
		reset — they send ten packets and are blackholed for the rest of the session, silently.

		The window here resets on the charge itself. There is no separate path, so there is nothing
		to skip. This test never lets the budget do anything *except* refuse, which is exactly the
		state Warp cannot recover from.
	]]
	local budget = Budget.new(now)
	local channel = channelOf("test.reset", 2)

	budget.admit(channel, alice, 1)
	budget.admit(channel, alice, 1)
	check("the window is exhausted", budget.admit(channel, alice, 1) ~= nil)

	--[[ Still inside the window. ]]
	clock = 0.9
	check("and still exhausted just before it closes", budget.admit(channel, alice, 1) ~= nil)

	--[[ Past it, with nothing else having happened in between: no send, no flush, no tick. ]]
	clock = 1.0
	equals("the window reopens on its own", budget.admit(channel, alice, 1), nil)
	equals("and again", budget.admit(channel, alice, 1), nil)
	check("up to the same limit", budget.admit(channel, alice, 1) ~= nil)
end

do
	clock = 0

	--[[
		**It runs where it is tested.** Warp wraps the whole check in `if not RunService:IsStudio()`,
		so no test can ever reach it. There is no environment branch in `Budget` at all — this file
		running at all is the assertion, and it runs under lune, which is further from a live server
		than Studio is.
	]]
	local budget = Budget.new(now)
	local channel = channelOf("test.everywhere", 1)

	budget.admit(channel, alice, 1)
	check("the limit applies here too", budget.admit(channel, alice, 1) ~= nil)
end

-- ---------------------------------------------------------------------------------------------
-- Windows
-- ---------------------------------------------------------------------------------------------

do
	clock = 0

	local budget = Budget.new(now)
	local channel = channelOf("test.window", 5)

	for _ = 1, 5 do
		budget.admit(channel, alice, 2)
	end

	local packets, bytes = budget.usage(alice, channel)
	equals("the window holds what was spent", packets, 5)
	equals("in bytes", bytes, 10)

	--[[ A reader between bursts sees the current window, not the last one's total — otherwise a
	     dashboard shows traffic that stopped a minute ago. ]]
	clock = 2

	local after, afterBytes, afterRefused = budget.usage(alice, channel)
	equals("an elapsed window reads as empty", after, 0)
	equals("in bytes", afterBytes, 0)
	equals("and refusals", afterRefused, 0)
end

do
	clock = 0

	--[[ A channel with no declared rate is not budgeted. Outbound classes have none, and neither
	     does anything arriving on a client: its peer is the server, and a server rate-limiting
	     itself would be a check that means nothing. ]]
	local budget = Budget.new(now)
	local channel = channelOf("test.unbudgeted", nil)

	for _ = 1, 1000 do
		if budget.admit(channel, alice, 50) ~= nil then
			fail("an unbudgeted channel refused a packet")
			break
		end
	end

	equals("and nothing is accounted for it", (budget.usage(alice, channel)), 0)
end

do
	clock = 0

	--[[ A player who left. Their records are the only thing that grows with the player count. ]]
	local budget = Budget.new(now)
	local channel = channelOf("test.leaver", 1)

	budget.admit(channel, alice, 1)
	check("alice is out", budget.admit(channel, alice, 1) ~= nil)

	budget.forget(alice)

	equals("and a fresh player of the same name starts clean", budget.admit(channel, alice, 1), nil)
	equals("with nothing carried over", (budget.usage(alice, channel)), 1)
end

do
	clock = 0

	--[[
		A packet with no sender is the client side, whose peer is the server. That is a shortcut and
		also a guard: the accounting table is keyed by sender, and `perSender[nil]` is an error —
		thrown on the receive path, which is the one place nothing may throw (`DESIGN-API.md` G4).

		A peer could have caused it. A crafted channel id can name a channel that declares a rate,
		and a client receiving one would have gone straight into that error.
	]]
	local budget = Budget.new(now)
	local channel = channelOf("test.crafted", 1)

	local ok = pcall(function()
		for _ = 1, 5 do
			budget.admit(channel, nil, 10)
		end
	end)

	check("a rated channel with no sender does not raise", ok)
	equals("and is not budgeted", budget.admit(channel, nil, 10), nil)
end

do
	--[[
		A clock that goes backwards reopens the window rather than closing it forever. `os.clock` is
		monotonic so the default cannot do this, but the failure it would cause is Warp's exact
		failure by another route — a player refused for the rest of the session, silently.
	]]
	clock = 100

	local budget = Budget.new(now)
	local channel = channelOf("test.backwards", 1)

	budget.admit(channel, alice, 1)
	check("the window is exhausted", budget.admit(channel, alice, 1) ~= nil)

	clock = 5

	equals("a backwards clock reopens it", budget.admit(channel, alice, 1), nil)
	equals("and usage reads against the new window", (budget.usage(alice, channel)), 1)
end

-- ---------------------------------------------------------------------------------------------

if failures > 0 then
	error(`{failures} budget assertions failed`)
end

print("OK      budget_runtime")

return true
