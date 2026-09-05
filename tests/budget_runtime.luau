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
local harness = require("./harness")

--[[
	Every section below is failure-path, and that is not a labelling convenience — it is what this
	module is. A rate limiter's job is refusal, and an assertion that the twentieth packet was
	admitted is the near side of the boundary the twenty-first is refused at; the two are counted by
	the same loop and cannot be separated without pretending. `PLAN-M3` D-10.
]]
local suite = harness.suite("budget_runtime", 0.95)
local check, equals, fail = suite.check, suite.equals, suite.fail

suite.failing()

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

	--[[ ~~Still inside the window.~~ **Corrected in M3 phase 0.** There is no window to be inside
	     any more: a bucket refills continuously, so a rate-2 channel has earned 0.8 of a packet at
	     0.4s and a whole one at 0.5s. Recovery is gradual rather than at a boundary, which is the
	     point — a boundary is the thing that admitted 39 packets per declared 20. ]]
	clock = 0.4
	check("four tenths of a second is not yet a whole packet", budget.admit(channel, alice, 1) ~= nil)

	--[[ Past a whole token, with nothing else having happened in between: no send, no flush, no
	     tick. This is the Warp property, and it survives the change to a bucket. ]]
	clock = 0.5
	equals("half a second at rate 2 is one packet, and it is admitted", budget.admit(channel, alice, 1), nil)
	check("but only the one that was earned", budget.admit(channel, alice, 1) ~= nil)
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
		~~A clock that goes backwards reopens the window rather than closing it forever.~~
		**Corrected in M3 phase 0.** Reopening was right for a window and is wrong for a bucket: it
		would let an injected or corrected clock *mint* tokens, and a limiter that can be talked out
		of limiting is not one.

		What has to hold is the Warp property, and it still does by another route. A backwards clock
		refills nothing, but it does move `refilled` back — so the moment time goes forward again the
		elapsed span is large and the bucket fills, capped at `burst`. Nobody is refused for the rest
		of the session, and nobody is paid for the trip backwards.
	]]
	clock = 100

	local budget = Budget.new(now)
	local channel = channelOf("test.backwards", 1)

	budget.admit(channel, alice, 1)
	check("the window is exhausted", budget.admit(channel, alice, 1) ~= nil)

	clock = 5

	check("a backwards clock mints nothing", budget.admit(channel, alice, 1) ~= nil)

	clock = 6
	equals("and the sender recovers as soon as time moves forward", budget.admit(channel, alice, 1), nil)
end

-- ---------------------------------------------------------------------------------------------
-- A fixed window admits twice the declared rate, and a bucket does not (PLAN-M3 D-3)
-- ---------------------------------------------------------------------------------------------

do
	--[[
		Warp's bug was the reset path (`RESEARCH §3.7-K`), which M2 made unreachable. This is the
		other one, which M2 kept: a window that resets on a boundary admits a full allowance on each
		side of it, so a channel declared `rate = 20` passes 40 across a span of milliseconds.

		The game declared 20 and got 40, with no way to find out. Against the pre-fix code the
		figure below is 40.
	]]
	local budget = Budget.new(now)
	local channel = channelOf("game.fixedWindow", 20)

	local admitted = 0

	local function offer(count: number)
		for _ = 1, count do
			if budget.admit(channel, alice, 4) == nil then
				admitted += 1
			end
		end
	end

	--[[ The window has to be *open* before the boundary is interesting, so one packet at zero puts
	     it there. Counting starts afterwards: everything below happens inside a span of 0.01s. ]]
	clock = 0
	offer(1)
	admitted = 0

	clock = 0.99
	offer(19)

	clock = 1.0
	offer(20)

	equals("a sliding hundredth of a second admits no more than the rate", admitted, 20)
end

do
	--[[ The steady state the bucket is for: at the declared rate, forever, nothing is refused. A
	     limiter that throttles a conforming sender is a limiter nobody will declare honestly. ]]
	local budget = Budget.new(now)
	local channel = channelOf("game.steady", 20)

	clock = 0

	local refused = 0

	for step = 1, 200 do
		clock = step / 20

		if budget.admit(channel, alice, 4) ~= nil then
			refused += 1
		end
	end

	equals("a sender exactly at its rate is never refused", refused, 0)
end

do
	--[[ Burst is what a bucket buys that a window cannot: a client that has been quiet may spend
	     what it did not use, up to the declared depth and no further. Default depth is `rate`. ]]
	local budget = Budget.new(now)
	local channel = channelOf("game.burst", 10)
	channel.burst = 30

	clock = 0
	equals("the first packet is admitted", budget.admit(channel, alice, 4), nil)

	--[[ Ten seconds of silence is a hundred tokens of entitlement and a bucket thirty deep. ]]
	clock = 10

	local admitted = 0

	for _ = 1, 50 do
		if budget.admit(channel, alice, 4) == nil then
			admitted += 1
		end
	end

	equals("silence banks up to the declared depth", admitted, 30)
end

do
	--[[ Without a declared burst the depth is the rate, so the same silence buys one second's
	     worth rather than ten. ]]
	local budget = Budget.new(now)
	local channel = channelOf("game.noBurst", 10)

	clock = 0
	budget.admit(channel, alice, 4)

	clock = 10

	local admitted = 0

	for _ = 1, 50 do
		if budget.admit(channel, alice, 4) == nil then
			admitted += 1
		end
	end

	equals("burst defaults to rate", admitted, 10)
end

do
	--[[ A clock that goes backwards must not mint tokens. `os.clock` is monotonic so this cannot
	     happen with the default, but an injected one can — and the failure it would cause is the
	     limiter silently ceasing to limit. ]]
	local budget = Budget.new(now)
	local channel = channelOf("game.backwards", 5)

	clock = 100

	for _ = 1, 5 do
		budget.admit(channel, alice, 4)
	end

	check("the bucket is empty", budget.admit(channel, alice, 4) ~= nil)

	clock = 50

	check("and a clock that went backwards does not refill it", budget.admit(channel, alice, 4) ~= nil)
end
-- ---------------------------------------------------------------------------------------------

do
	--[[
		A rate below one packet per second is legal — `checkedRate` asks for positive and finite, and
		"one purchase every two seconds" is a rate a game writes on purpose.

		The bucket's depth defaults to the rate, and a depth of 0.5 can never hold a whole token: the
		refill is capped at 0.5, the admission test wants 1, and the channel is refused forever after
		its first packet. That is Warp's exact failure (`RESEARCH §3.7-K`) — a player blackholed with
		nothing saying so — reintroduced by the fix that was supposed to make it unreachable, and
		found by auditing the phase rather than by a test that already existed.

		The depth is at least one token now. Against the pre-fix code every line below refuses.
	]]
	local budget = Budget.new(now)
	local channel = channelOf("shop.purchase", 0.5)

	clock = 0
	equals("the first packet is admitted", budget.admit(channel, alice, 4), nil)

	clock = 1
	check("a second later is too soon at half a packet per second", budget.admit(channel, alice, 4) ~= nil)

	clock = 2
	equals("two seconds is one packet, and it arrives", budget.admit(channel, alice, 4), nil)

	clock = 3600
	equals("and an hour later the channel is still alive", budget.admit(channel, alice, 4), nil)
end

do
	--[[ The depth floor is a floor, not an override: a declared burst above it still stands, and a
	     rate above one still gets a depth of `rate`. ]]
	local budget = Budget.new(now)
	local channel = channelOf("shop.slowBurst", 0.25)
	channel.burst = 3

	clock = 0

	local admitted = 0

	for _ = 1, 10 do
		if budget.admit(channel, alice, 4) == nil then
			admitted += 1
		end
	end

	equals("a declared burst outranks the floor", admitted, 3)
end

suite.finish()

return true
