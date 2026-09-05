--!strict

--[[
	The receive path, driven by bytes nobody would send.

		lune run tests/hostile_runtime

	Every other suite reaches the transport through its own API, which means every batch it tests
	was written by the same code that reads it. That is the wrong shape for a security layer: an
	encoder cannot produce the packet an attacker sends, so a suite built out of encoder calls tests
	the paths a friendly peer takes and calls it coverage.

	Everything here is written byte by byte into the buffer. `Batch.writePacket` appears only where
	a case needs a *valid* packet to sit behind the hostile one.

	Two invariants hold across the whole file.

	  1. **Nothing raises.** The bytes came off a wire, so `DESIGN-API.md` G4 says every failure is a
	     value. Every case runs under `pcall` and asserts it came back true.
	  2. **Nothing is lost silently.** For a recoverable refusal, every packet written is either
	     delivered or reported — `delivered + reported == written`. For the three failures that stop
	     a batch, the single report's byte count covers everything from the bad packet to the end,
	     so the loss is measured rather than merely admitted.
]]

local Batch = require("../src/transport/Batch")
local Budget = require("../src/transport/Budget")
local Buffer = require("../src/codec/Buffer")
local Config = require("../src/api/Config")
local Inbound = require("../src/transport/Inbound")
local Namespace = require("../src/api/Namespace")
local Observer = require("../src/api/Observer")
local Protocol = require("../src/api/Protocol")
local Policy = require("../src/api/Policy")
local Query = require("../src/transport/Query")
local harness = require("./harness")
local nw = require("../src/netweave")
local t = require("../src/types")

local suite = harness.suite("hostile_runtime", 0.9)
local check, equals, fail = suite.check, suite.equals, suite.fail

-- ---------------------------------------------------------------------------------------------
-- The peer under attack
-- ---------------------------------------------------------------------------------------------

local mallory = { name = "mallory" }

local allows = nw.policy(function()
	return function()
		return nw.allow()
	end
end)

--[[ Every verdict shape a policy can return, including the four that are not verdicts. `PLAN-M3`
     D-2: a shrug must not mean yes. ]]
local verdicts: { [string]: any } = {}

local function policyReturning(key: string): any
	return nw.policy(function()
		return function(): any
			return verdicts[key]
		end
	end)
end

Namespace.reset()

local declared = Namespace.declare("h", {
	--[[ Names are chosen for what they do, and ids are read back after sealing rather than assumed:
	     an id depends on every other channel in the program (`WIRE-FORMAT.md` §3). ]]
	fixed = nw.signal({ data = t.struct({ a = t.u8, b = t.u16 }), rate = 1000 }),
	counted = nw.signal({ data = t.struct({ s = t.string(0, 64) }), rate = 1000 }),
	bounded = nw.signal({ data = t.struct({ n = t.u8(10, 20) }), rate = 1000 }),
	--[[ Three variants, not two. Two need one bit and every value of that bit names a variant, so
	     there is no unrepresentable tag to write — the extra bits a hostile peer sets are masked off
	     and the value that comes out is legal. Three need two bits, and index 3 is the tag with no
	     name behind it. ]]
	choice = nw.signal({
		data = t.struct({ e = t.enum({ red = true, green = true, blue = true }) }),
		rate = 1000,
	}),
	listed = nw.signal({ data = t.array(t.u8), rate = 1000, maxBytes = 32 }),
	carried = nw.signal({ data = t.struct({ who = t.instance, n = t.u8 }), rate = 1000 }),
	trickle = nw.signal({ data = t.struct({ n = t.u8 }), rate = 2, burst = 2 }),
	guarded = nw.command({
		data = t.struct({ n = t.u8 }),
		rate = 1000,
		authorize = policyReturning("verdict"),
	}),
	asked = nw.query({
		args = t.struct({ n = t.u8 }),
		returns = t.struct({ v = t.u8 }),
		rate = 1000,
		timeout = 5,
		authorize = allows,
	}),
	silent = nw.signal({ data = t.struct({ n = t.u8 }), rate = 1000 }),
})

local protocol = Namespace.seal()

local Fixed = declared.channels.fixed
local Counted = declared.channels.counted
local Bounded = declared.channels.bounded
local Choice = declared.channels.choice
local Listed = declared.channels.listed
local Carried = declared.channels.carried
local Trickle = declared.channels.trickle
local Guarded = declared.channels.guarded
local Asked = declared.channels.asked
local Silent = declared.channels.silent

--[[ An id past the last one assigned. Nothing resolves it, which is the one failure the format
     cannot isolate. ]]
local UNKNOWN_ID = protocol.count + 1

-- ---------------------------------------------------------------------------------------------
-- The rig
-- ---------------------------------------------------------------------------------------------

local delivered = 0
local reports: { { stage: string, reason: string, bytes: number, channel: string? } } = {}
local replies: { { call: number, status: number } } = {}

local at = 0

local function clock(): number
	return at
end

local budget = Budget.new(clock)

local queries = Query.new({
	request = function() end,

	reply = function(_channel: any, _who: any, call: number, status: number)
		table.insert(replies, { call = call, status = status })
	end,

	spawn = function(target: any, ...: any)
		local thread = if type(target) == "thread" then target else coroutine.create(target)
		local ok, err = coroutine.resume(thread, ...)

		if not ok then
			fail(`a spawned thread raised: {tostring(err)}`)
		end
	end,

	clock = clock,
})

local agreement = Protocol.new({
	hash = function(): number
		return protocol.hash
	end,

	announce = function() end,
	isServer = true,
})

local inbound = Inbound.new({
	resolve = Namespace.channelById,
	admit = budget.admit,
	isServer = true,
	queries = queries,
	agreement = agreement,
})

Observer.reset()
Observer.observe(function(rejection)
	table.insert(reports, {
		stage = rejection.stage,
		reason = rejection.reason,
		bytes = rejection.bytes,
		channel = rejection.channel,
	})
end)

local function handler()
	delivered += 1
end

for _, channel in declared.channels do
	if channel.class ~= "query" and channel.key ~= "silent" then
		channel.handler = handler
	end
end

Asked.handler = function()
	delivered += 1
	return { v = 1 }
end

local function reset()
	delivered = 0
	table.clear(reports)
	table.clear(replies)
	Buffer.take()
	Buffer.load(nil)
end

--[[ Feed the current buffer in as one batch, and answer the two questions every case asks: did it
     raise, and did anything vanish. ]]
local function feed(instances: { any }?): (boolean, buffer)
	local packed, carried = Buffer.take()
	local survived = pcall(inbound.receive, packed, instances or carried, mallory)

	return survived, packed
end

local function reportedAt(stage: string): number
	local count = 0

	for _, entry in reports do
		if entry.stage == stage then
			count += 1
		end
	end

	return count
end

--[[ Everything written is either delivered or reported. This is the half of G5 that is easy to
     lose: a packet quietly dropped looks identical to one that was never sent. ]]
local function accounts(label: string, written: number)
	equals(`{label}: every packet is delivered or reported`, delivered + #reports, written)
end

suite.failing()

-- ---------------------------------------------------------------------------------------------
-- The envelope
-- ---------------------------------------------------------------------------------------------

do
	reset()

	local survived = feed()
	check("an empty batch does not raise", survived)
	equals("and says nothing", #reports, 0)
end

do
	reset()
	Buffer.writeU8(0)

	local survived = feed()
	check("a batch on the wrong version does not raise", survived)
	equals("it is refused whole", #reports, 1)
	equals("at parse", reports[1].stage, "parse")
	check("naming the version", string.find(reports[1].reason, "version 0", 1, true) ~= nil)
end

do
	reset()
	Buffer.writeU8(Batch.VERSION)
	Buffer.writeU8(0x80)

	local survived = feed()
	check("a channel id that runs off the end does not raise", survived)
	equals("it stops the batch", #reports, 1)
	check("reported as truncated", string.find(reports[1].reason, "truncated channel id", 1, true) ~= nil)
end

do
	reset()
	Buffer.writeU8(Batch.VERSION)

	--[[ Six continuation bytes. A 32-bit value needs five, so a sixth is a stream claiming to be
	     something it is not — and a reader without this bound loops on it. ]]
	for _ = 1, 6 do
		Buffer.writeU8(0xFF)
	end

	local survived = feed()
	check("an overlong varint does not raise", survived)
	equals("it is refused", #reports, 1)
	check("without looping", true)
end

do
	reset()
	Batch.writePacket(Fixed, { a = 1, b = 2 })

	local afterGood = Buffer.used()

	Buffer.writeVarint(UNKNOWN_ID)
	Buffer.writeU8(7)
	Buffer.writeU8(7)

	local size = Buffer.used()
	local survived, _packed = feed()

	check("an unknown id does not raise", survived)
	equals("the packet in front of it arrived", delivered, 1)
	equals("and one refusal covers the rest", #reports, 1)

	--[[
		The one case the format cannot isolate, and the reason it is reported in bytes.

		Without a channel there is no framing, so the end of the packet is unknowable and everything
		behind it is unreachable. What must not happen is the loss going unmeasured: the report's
		byte count is exactly the distance from the unresolvable id to the end of the batch.
	]]
	equals("and the report measures exactly what was discarded", reports[1].bytes, size - afterGood)
end

-- ---------------------------------------------------------------------------------------------
-- The framing
-- ---------------------------------------------------------------------------------------------

do
	reset()
	Buffer.writeU8(Batch.VERSION)
	Buffer.writeVarint(Counted.id)
	Buffer.writeU8(0x80)

	local survived = feed()
	check("a truncated length does not raise", survived)
	equals("it stops the batch", #reports, 1)
	check(
		"reported as a truncated length",
		string.find(reports[1].reason, "truncated packet length", 1, true) ~= nil
	)
end

do
	reset()
	Batch.writePacket(Fixed, { a = 1, b = 2 })

	local afterGood = Buffer.used()

	Buffer.writeVarint(Counted.id)
	Buffer.writeVarint(120)
	Buffer.writeU8(1)

	local size = Buffer.used()
	local survived = feed()

	check("a length past the end of the batch does not raise", survived)
	equals("the packet in front of it arrived", delivered, 1)
	equals("and the rest is one refusal", #reports, 1)
	check("naming the overrun", string.find(reports[1].reason, "past the batch", 1, true) ~= nil)
	equals("measuring what was discarded", reports[1].bytes, size - afterGood)
end

do
	reset()
	Batch.writePacket(Carried, { who = { Name = "a" } :: any, n = 1 })

	local afterGood = Buffer.used()

	--[[
		A packet claiming more instances than the sidecar holds.

		This one is a security failure rather than a robustness one. A packet is stepped over by
		advancing the instance cursor past what it claimed, so an overstated claim moves the cursor
		past entries belonging to the packets behind it — and those decode successfully while
		holding **another packet's Instance**. A wrong association, not a failure, and invisible from
		both ends. The claim is provably a lie because the sidecar's length is known.
	]]
	Buffer.writeVarint(Carried.id)
	Buffer.writeU8(2)

	local size = Buffer.used()
	local survived = feed({ { Name = "a" } :: any })

	check("an overstated instance count does not raise", survived)
	equals("the packet in front of it arrived", delivered, 1)
	equals("and the batch stops there", #reports, 1)
	check("naming the sidecar", string.find(reports[1].reason, "sidecar", 1, true) ~= nil)
	equals("measuring what was discarded", reports[1].bytes, size - afterGood)
end

-- ---------------------------------------------------------------------------------------------
-- What the readers refuse
-- ---------------------------------------------------------------------------------------------

do
	reset()

	--[[ `t.u8(10, 20)` is stored as the offset from 10 in one byte, so 250 decodes to 260 and is
	     out of range. The packet is refused; the ones around it are not. ]]
	Batch.writePacket(Fixed, { a = 1, b = 2 })
	Buffer.writeVarint(Bounded.id)
	Buffer.writeU8(250)
	Batch.writePacket(Fixed, { a = 3, b = 4 })

	local survived = feed()

	check("a number out of its declared range does not raise", survived)
	equals("the packets around it arrived", delivered, 2)
	equals("and it alone was refused", #reports, 1)
	equals("at parse", reports[1].stage, "parse")
	accounts("out of range", 3)
end

do
	reset()

	--[[ Three variants take two bits, so index 3 is the tag with no name behind it — the shape a
	     stale client produces after a variant is removed from the schema. ]]
	Batch.writePacket(Fixed, { a = 1, b = 2 })
	Buffer.writeVarint(Choice.id)
	Buffer.writeU8(3)
	Batch.writePacket(Fixed, { a = 3, b = 4 })

	local survived = feed()

	check("an unknown enum tag does not raise", survived)
	equals("the packets around it arrived", delivered, 2)
	equals("and it alone was refused", #reports, 1)
	accounts("unknown enum tag", 3)
end

do
	reset()

	--[[
		A two-byte packet claiming 65,535 elements.

		`PLAN-M3` D-4: the reader used to allocate `table.create(count)` from the claim before
		reading an element, so this cost 690x an honest packet and was then correctly rejected. The
		rejection was free; the allocation was not. A claim is not paid for until the bytes behind it
		exist.
	]]
	Batch.writePacket(Fixed, { a = 1, b = 2 })
	Buffer.writeVarint(Listed.id)
	Buffer.writeVarint(3)
	Buffer.writeU8(0xFF)
	Buffer.writeU8(0xFF)
	Buffer.writeU8(0x03)
	Batch.writePacket(Fixed, { a = 3, b = 4 })

	local survived = feed()

	check("an array claiming more than the bytes behind it does not raise", survived)
	equals("the packets around it arrived", delivered, 2)
	equals("and it alone was refused", #reports, 1)
	check("naming the claim", string.find(reports[1].reason, "claims", 1, true) ~= nil)
	accounts("array claim", 3)
end

do
	reset()

	--[[ The declared ceiling, checked before a byte of the payload is decoded. `listed` caps at 32
	     and the schema itself allows 65,537, so this is the case a declaration exists for. ]]
	Batch.writePacket(Fixed, { a = 1, b = 2 })
	Buffer.writeVarint(Listed.id)
	Buffer.writeVarint(200)

	for _ = 1, 200 do
		Buffer.writeU8(0)
	end

	Batch.writePacket(Fixed, { a = 3, b = 4 })

	local survived = feed()

	check("a payload over the declared ceiling does not raise", survived)
	equals("the packets around it arrived", delivered, 2)
	equals("and it alone was refused", #reports, 1)
	equals("at budget, before decode", reports[1].stage, "budget")
	check("naming the ceiling", string.find(reports[1].reason, "over the 32", 1, true) ~= nil)
	accounts("over the declared ceiling", 3)
end

-- ---------------------------------------------------------------------------------------------
-- What the policy refuses
-- ---------------------------------------------------------------------------------------------

do
	--[[
		Every shape a policy can return, including four that are not verdicts.

		`PLAN-M3` D-2: `ok == true`, not truthy, and only off a table. A policy that returns nothing
		is one someone forgot to finish, and the safe reading of an unfinished policy is no. The
		pre-fix check admitted `ok = "yes"` and raised outright on `nil`.
	]]
	local shapes: { { name: string, value: any, admits: boolean } } = {
		{ name = "nil", value = nil, admits = false },
		{ name = "false", value = false, admits = false },
		{ name = "an empty table", value = {}, admits = false },
		{ name = "a table with ok = 'yes'", value = { ok = "yes" }, admits = false },
		{ name = "a table with ok = 1", value = { ok = 1 }, admits = false },
		{ name = "a number", value = 7, admits = false },
		{ name = "a string", value = "sure", admits = false },
		{ name = "ok = true", value = { ok = true }, admits = true },
	}

	for _, shape in shapes do
		reset()
		verdicts.verdict = shape.value

		Batch.writePacket(Guarded, { n = 1 })

		local survived = feed()

		check(`a policy returning {shape.name} does not raise`, survived)
		equals(
			`and {shape.name} {if shape.admits then "admits" else "refuses"}`,
			delivered,
			if shape.admits then 1 else 0
		)
		accounts(`policy returning {shape.name}`, 1)
	end
end

do
	reset()

	--[[ A policy that throws is a refusal, not a batch killer. `PLAN-M3` D-1: one input that trips a
	     game's policy must not take every packet behind it. ]]
	verdicts.verdict = nil

	local raising = nw.policy(function()
		return function(): any
			error("the policy is broken")
		end
	end)

	local previous = Guarded.authorize
	Guarded.authorize = Policy.checkOf(raising)

	Batch.writePacket(Fixed, { a = 1, b = 2 })
	Batch.writePacket(Guarded, { n = 1 })
	Batch.writePacket(Fixed, { a = 3, b = 4 })

	local survived = feed()

	check("a policy that raises does not take the batch", survived)
	equals("the packets around it arrived", delivered, 2)
	equals("and it alone was refused", #reports, 1)
	equals("at authorize", reports[1].stage, "authorize")
	check("naming the raise", string.find(reports[1].reason, "the policy raised", 1, true) ~= nil)
	accounts("a raising policy", 3)

	Guarded.authorize = previous
end

do
	reset()
	verdicts.verdict = { ok = true }

	--[[ A handler that throws is the game's own bug, and it is caught for the same reason: the batch
	     behind it is other traffic. ]]
	local previous = Guarded.handler

	Guarded.handler = function()
		error("the handler is broken")
	end

	Batch.writePacket(Fixed, { a = 1, b = 2 })
	Batch.writePacket(Guarded, { n = 1 })
	Batch.writePacket(Fixed, { a = 3, b = 4 })

	local survived = feed()

	check("a handler that raises does not take the batch", survived)
	equals("the packets around it arrived", delivered, 2)
	equals("and it alone was refused", #reports, 1)
	equals("at handler", reports[1].stage, "handler")
	accounts("a raising handler", 3)

	Guarded.handler = previous
end

-- ---------------------------------------------------------------------------------------------
-- What the budget refuses
-- ---------------------------------------------------------------------------------------------

do
	reset()
	at = 1000
	budget.forget(mallory)

	--[[ `trickle` is `rate = 2, burst = 2`. Ten packets in one batch: two admitted, eight refused,
	     and none of the eight costs a decode. ]]
	for index = 1, 10 do
		Batch.writePacket(Trickle, { n = index })
	end

	local survived = feed()

	check("a flood does not raise", survived)
	equals("the bucket admits its depth", delivered, 2)
	equals("and refuses the rest", #reports, 8)
	equals("at budget", reportedAt("budget"), 8)
	accounts("a flood", 10)
end

do
	reset()

	--[[ The window that is not a window. A fixed window admits `2n` across a boundary; the bucket
	     refills continuously, so half a second buys one token and not two. ]]
	at += 0.5

	for _ = 1, 4 do
		Batch.writePacket(Trickle, { n = 1 })
	end

	local survived = feed()

	check("a refill does not raise", survived)
	equals("half a second buys exactly one packet", delivered, 1)
	equals("and the rest are refused", #reports, 3)
	accounts("a refill", 4)
end

-- ---------------------------------------------------------------------------------------------
-- The ceilings
-- ---------------------------------------------------------------------------------------------

do
	reset()
	at += 1000
	budget.forget(mallory)
	Config.configure({ limits = { pendingPerBatch = 3 } })

	for _ = 1, 8 do
		Batch.writePacket(Fixed, { a = 1, b = 2 })
	end

	local survived = feed()

	check("a batch past the pending ceiling does not raise", survived)
	equals("the ceiling is what is delivered", delivered, 3)
	equals("and the rest are refused", #reports, 5)
	check("naming the ceiling", string.find(reports[1].reason, "more than 3 packets", 1, true) ~= nil)
	accounts("past the pending ceiling", 8)

	Config.reset()
end

do
	reset()
	at += 1000
	budget.forget(mallory)
	Config.configure({ limits = { queueCapacity = 2 } })

	--[[ `silent` has no handler. The queue keeps what arrives before one attaches, drops the oldest
	     when it is full, and says so — rather than growing forever, which is what a forgotten
	     `:listen` costs in Blink (`RESEARCH §3.7-H`). ]]
	for index = 1, 5 do
		Batch.writePacket(Silent, { n = index })
	end

	local survived = feed()

	check("an unlistened channel does not raise", survived)
	equals("nothing was delivered", delivered, 0)
	equals("and the overflow was reported", #reports, 3)
	equals("at queue", reportedAt("queue"), 3)

	Config.reset()
end

-- ---------------------------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------------------------

do
	reset()
	at += 1000
	budget.forget(mallory)
	queries.forget(mallory)

	Buffer.writeU8(Batch.VERSION)
	Buffer.writeVarint(Asked.id)
	Buffer.writeU8(0x80)

	local survived = feed()

	check("a truncated call id does not raise", survived)
	equals("it stops the batch", #reports, 1)
	check("reported as truncated", string.find(reports[1].reason, "truncated call id", 1, true) ~= nil)
end

do
	reset()
	queries.forget(mallory)

	--[[
		The same call id twice from one peer.

		The handler has to park for this to bite, and that is the shape the defect has: a handler
		that returns immediately gives its slot back before the second request is dispatched, so the
		set is empty again and there is nothing to collide with. A yielding handler is the whole
		point of the class, and it is where the slot count and the slot set can disagree — sixteen of
		these retire a player's call budget for the session, in a line.
	]]
	local parked: { thread } = {}
	local previous = Asked.handler

	Asked.handler = function()
		delivered += 1
		table.insert(parked, coroutine.running())
		coroutine.yield()
		return { v = 1 }
	end

	Batch.writeRequest(Asked, 5, { n = 1 })
	Batch.writeRequest(Asked, 5, { n = 2 })

	local survived = feed()

	check("a repeated call id does not raise", survived)
	equals("only the first was served", delivered, 1)
	equals("and the repeat was refused", #reports, 1)
	check("naming the repeat", string.find(reports[1].reason, "already in flight", 1, true) ~= nil)
	equals("the repeat was answered rather than dropped", #replies, 1)
	equals("with a refusal", replies[1].status, Batch.REFUSED)
	equals("and the first still holds its slot", queries.inflight(mallory), 1)

	for _, thread in parked do
		coroutine.resume(thread)
	end

	equals("which comes back when it returns", queries.inflight(mallory), 0)

	Asked.handler = previous
end

do
	reset()
	queries.forget(mallory)

	--[[ A request the budget refuses still answers. Silence would cost the caller its whole timeout
	     for something the server knew instantly. ]]
	at += 1000
	budget.forget(mallory)

	local previous = Asked.rate
	Asked.rate = 0.0001

	Batch.writeRequest(Asked, 6, { n = 1 })
	Batch.writeRequest(Asked, 7, { n = 1 })

	local survived = feed()

	check("a budgeted-out request does not raise", survived)
	equals("both calls were answered", #replies, 2)

	--[[ The refusal comes back **first**, and that ordering is worth pinning: it is written while the
	     batch is still being read, so a caller learns it was refused before the request in front of
	     it has even been dispatched. ]]
	equals("the refusal is answered first, from inside the read", replies[1].status, Batch.REFUSED)
	equals("and it is the one the budget stopped", replies[1].call, 7)
	equals("the admitted one answers at dispatch", replies[2].status, Batch.OK)

	Asked.rate = previous
end

-- ---------------------------------------------------------------------------------------------
-- Control traffic
-- ---------------------------------------------------------------------------------------------

do
	reset()
	Buffer.writeU8(Batch.VERSION)
	Buffer.writeVarint(0)

	local survived = feed()

	check("a control packet with no kind does not raise", survived)
	equals("it is refused", #reports, 1)
	check("as truncated", string.find(reports[1].reason, "truncated control", 1, true) ~= nil)
end

do
	reset()
	Buffer.writeU8(Batch.VERSION)
	Buffer.writeVarint(0)
	Buffer.writeU8(Batch.HELLO)
	Buffer.writeVarint(250)
	Buffer.writeU32(1)

	local survived = feed()

	check("a control body running past the batch does not raise", survived)
	equals("it is refused", #reports, 1)
	check("naming the overrun", string.find(reports[1].reason, "past the batch", 1, true) ~= nil)
end

do
	reset()
	at += 1000
	budget.forget(mallory)
	agreement.forget(mallory)

	--[[ A control kind this build has never heard of, sitting in front of a real packet. The length
	     is what makes it steppable, and reserved id 0 is worth nothing without that. ]]
	Buffer.writeU8(Batch.VERSION)
	Buffer.writeVarint(0)
	Buffer.writeU8(200)
	Buffer.writeVarint(2)
	Buffer.writeU8(1)
	Buffer.writeU8(2)
	Batch.writePacket(Fixed, { a = 1, b = 2 })

	local survived = feed()

	check("an unknown control kind does not raise", survived)
	equals("it is stepped over", delivered, 1)
	equals("and said out loud rather than skipped in silence", #reports, 1)
	check("naming the kind", string.find(reports[1].reason, "control kind 200", 1, true) ~= nil)
end

do
	reset()
	at += 1000
	budget.forget(mallory)
	agreement.forget(mallory)

	--[[ A peer on a protocol this one does not share. Their ids map to other channels, so their
	     bytes would not fail to decode — they would decode into whatever channel sits at that number
	     and reach a handler as a well-formed payload (`PLAN-M3` D-7). ]]
	Batch.writeHello(protocol.hash + 1)

	for _ = 1, 3 do
		Batch.writePacket(Fixed, { a = 1, b = 2 })
	end

	local survived = feed()

	check("a mismatched peer does not raise", survived)
	equals("nothing behind the hello was delivered", delivered, 0)
	equals("all three were refused", #reports, 3)
	equals("at protocol", reportedAt("protocol"), 3)
	check(
		"with both hashes named",
		string.find(reports[1].reason, Protocol.hex(protocol.hash), 1, true) ~= nil
	)

	agreement.forget(mallory)
end

-- ---------------------------------------------------------------------------------------------
-- One valid packet, so the rig is proved to be capable of delivering anything at all
-- ---------------------------------------------------------------------------------------------

suite.passing()

do
	reset()
	at += 1000
	budget.forget(mallory)

	Batch.writePacket(Fixed, { a = 7, b = 9 })

	local survived = feed()

	check("a well-formed packet arrives", survived and delivered == 1)
	equals("with nothing reported", #reports, 0)
end

-- ---------------------------------------------------------------------------------------------

for _, channel in declared.channels do
	channel.handler = nil
end

Namespace.reset()
Observer.reset()
Config.reset()

suite.finish()

return true
