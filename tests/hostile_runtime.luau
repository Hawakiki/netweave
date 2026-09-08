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

local Baseline = require("../src/replication/Baseline")
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
	carried = nw.signal({ data = t.struct({ who = t.instance("Part"), n = t.u8 }), rate = 1000 }),
	--[[ The same field with no class declared, which is the worse half of the sidecar defect: with
	     nothing to test against there was nothing to fail on. ]]
	bare = nw.signal({ data = t.struct({ who = t.instance, n = t.u8 }), rate = 1000 }),
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
	--[[ Server to client, so nothing may arrive on it here — and it declares no rate, which is why
	     nothing could refuse it before M3 phase 9. ]]
	broadcast = nw.event({ data = t.struct({ n = t.u8 }), audience = nw.audience.everyone }),
	--[[ A second listener-less channel, because a queue keeps the depth it was built with and the
	     one above has already been filled by the case that tests overflow. ]]
	hushed = nw.signal({ data = t.struct({ n = t.u8 }), rate = 1000 }),
	--[[ Server to client and driven by a store, so a client's packet on it is doubly illegitimate:
	     wrong direction, and a class whose only way in is a store this peer cannot reach. ]]
	mirrored = nw.replicate({
		subject = t.u16,
		data = t.struct({ n = t.u8 }),
		audience = nw.audience.everyone,
		store = nw.store.of({}),
	}),
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
local Broadcast = declared.channels.broadcast
local Hushed = declared.channels.hushed
local Replicated = declared.channels.mirrored :: any

--[[ An id past the last one assigned. Nothing resolves it, which is the one failure the format
     cannot isolate. ]]
local UNKNOWN_ID = protocol.count + 1

-- ---------------------------------------------------------------------------------------------
-- The rig
-- ---------------------------------------------------------------------------------------------

local delivered = 0
type Report = { stage: string, reason: string, bytes: number, channel: string? }

local reports: { Report } = {}
local replies: { { call: number, status: number } } = {}

--[[
	The first report, or a stand-in that fails every assertion about one. Indexing `reports[1]`
	directly raised `attempt to index nil with 'reason'` the moment a stage was disabled, which
	aborted the file and hid every section after it — a §9 "break the guard, watch the test fail"
	run read as one failure instead of the true count (M4-1, tests). A refusal that never happened
	has to fail the assertions written for it, not the file.
]]
local NO_REPORT: Report = { stage = "(no report)", reason = "(no report)", bytes = -1 }

local function first(): Report
	return reports[1] or NO_REPORT
end

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

local announced = 0

local agreement = Protocol.new({
	hash = function(): number
		return protocol.hash
	end,

	--[[ Counted rather than ignored: what a hello flood costs is measured in answers, and an
	     announce is one packet written into the sender's parked outbound buffer. ]]
	announce = function()
		announced += 1
	end,

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
	if channel.class ~= "query" and channel.key ~= "silent" and channel.key ~= "hushed" then
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
	equals("at parse", first().stage, "parse")
	check("naming the version", string.find(first().reason, "version 0", 1, true) ~= nil)
end

do
	reset()
	Buffer.writeU8(Batch.VERSION)
	Buffer.writeU8(0x80)

	local survived = feed()
	check("a channel id that runs off the end does not raise", survived)
	equals("it stops the batch", #reports, 1)
	check("reported as truncated", string.find(first().reason, "truncated channel id", 1, true) ~= nil)
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
	equals("and the report measures exactly what was discarded", first().bytes, size - afterGood)
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
		string.find(first().reason, "truncated packet length", 1, true) ~= nil
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
	check("naming the overrun", string.find(first().reason, "past the batch", 1, true) ~= nil)
	equals("measuring what was discarded", first().bytes, size - afterGood)
end

do
	reset()
	Batch.writePacket(Carried, { who = harness.instance("a", "Part"), n = 1 })

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
	local survived = feed({ harness.instance("a", "Part") })

	check("an overstated instance count does not raise", survived)
	equals("the packet in front of it arrived", delivered, 1)
	equals("and the batch stops there", #reports, 1)
	check("naming the sidecar", string.find(first().reason, "sidecar", 1, true) ~= nil)
	equals("measuring what was discarded", first().bytes, size - afterGood)
end

do
	reset()
	at += 1000
	budget.forget(mallory)

	--[[
		The sidecar's **contents**, which nothing checked until M3 phase 9.

		Every mutation this file and `tests/fuzz_runtime.luau` perform on the sidecar changes its
		*length* — overstated, understated, padded. Its entries were always real. A client sends
		`FireServer(buffer, { 12345 })` and the reader called `value:IsA(class)` on the number, which
		raises: on the receive path, out of the read phase, with `depth`, `filling` and `sender`
		unwound and the pooled list at that depth leaked with every value decoded so far still in it.

		That is guarantee G4 broken by the one piece of wire data that does not travel in the buffer,
		and it was found by an external review rather than by ten thousand fuzzed batches — because
		the fuzzer mutated the count and never the contents.
	]]
	Batch.writePacket(Fixed, { a = 1, b = 2 })
	Batch.writePacket(Carried, { who = harness.instance("real", "Part"), n = 1 })
	Batch.writePacket(Fixed, { a = 3, b = 4 })

	local packed, instances = Buffer.take()

	--[[ The bytes are honest and the count is honest. Only the entry is not. ]]
	instances[1] = 12345 :: any

	local survived = pcall(inbound.receive, packed, instances, mallory)

	check("a number in the sidecar does not raise", survived)
	equals("the packets around it arrived", delivered, 2)
	equals("and it alone was refused", #reports, 1)
	equals("at parse", first().stage, "parse")
	check("naming what was there instead", string.find(first().reason, "sidecar holds", 1, true) ~= nil)
	accounts("a non-instance in the sidecar", 3)
end

do
	reset()
	at += 1000
	budget.forget(mallory)

	--[[ The same on a channel that declares no class. With nothing to test against, whatever the
	     client sent used to be handed to the handler *as an Instance* — `12345` reached game code
	     with no report at all, which is worse than the raise above because nothing announces it. ]]
	local bare = declared.channels.bare

	Batch.writePacket(bare, { who = harness.instance("real"), n = 1 })

	local packed, instances = Buffer.take()
	instances[1] = "not an instance" :: any

	local survived = pcall(inbound.receive, packed, instances, mallory)

	check("a string on a class-less instance field does not raise", survived)
	equals("nothing was delivered", delivered, 0)
	equals("and it was refused", #reports, 1)
	check("naming the type", string.find(first().reason, "string", 1, true) ~= nil)
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
	equals("at parse", first().stage, "parse")
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
	check("naming the claim", string.find(first().reason, "claims", 1, true) ~= nil)
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
	equals("at budget, before decode", first().stage, "budget")
	check("naming the ceiling", string.find(first().reason, "over the 32", 1, true) ~= nil)
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
	equals("at authorize", first().stage, "authorize")
	check("naming the raise", string.find(first().reason, "the policy raised", 1, true) ~= nil)
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
	equals("at handler", first().stage, "handler")
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
	check("naming the ceiling", string.find(first().reason, "more than 3 packets", 1, true) ~= nil)
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

do
	reset()
	at += 1000
	budget.forget(mallory)

	--[[
		A client sending on a channel only the server sends on.

		`Namespace.channelById` resolves every id, and `nw.state` and `nw.event` declare no `rate` —
		so `Budget.admit` had nothing to charge and returned nil, and the packet was decoded and
		queued. Six hundred of them measured `budget=0, queue=344` before M3 phase 9: decode work and
		retained memory bounded by the client's send rate and nothing the game declared.

		Which also means the reason those classes may not declare a `rate` — "the server is the
		sender on this class, so there is nobody to budget" — was resting on a check that did not
		exist. G6 was enforced on the views, at analysis, on the game's own code, and a peer writes
		its own packets.
	]]
	Batch.writePacket(Fixed, { a = 1, b = 2 })

	for index = 1, 40 do
		Batch.writePacket(Broadcast, { n = index })
	end

	Batch.writePacket(Fixed, { a = 3, b = 4 })

	local survived = feed()

	check("a packet on a server-to-client id does not raise", survived)
	equals("the packets around them arrived", delivered, 2)
	equals("and every one of the forty was refused", #reports, 40)
	equals("at direction", reportedAt("direction"), 40)
	check("naming the class", string.find(first().reason, "event is sent by the server", 1, true) ~= nil)
	accounts("a client sending on an outbound class", 42)

	--[[ And none of them was decoded: the refusal is before `codec.read`, at the same point and for
	     the same reason as the byte ceiling. ]]
	equals("nothing reached the queue", reportedAt("queue"), 0)
end

do
	reset()
	at += 1000
	budget.forget(mallory)

	--[[ The other way round, on the client: a peer claiming to be the server on a `command` id.
	     Nothing legitimate sends that way, and the client used to decode it and run the handler. ]]
	local client = Inbound.new({
		resolve = Namespace.channelById,
		admit = function(): string?
			return nil
		end,
		isServer = false,
	})

	Batch.writePacket(Guarded, { n = 1 })

	local packed, carried = Buffer.take()
	local survived = pcall(client.receive, packed, carried, nil)

	check("a command arriving at a client does not raise", survived)
	equals("nothing was delivered", delivered, 0)
	equals("and it was refused at direction", reportedAt("direction"), 1)
end

do
	reset()
	at += 1000
	budget.forget(mallory)
	Config.configure({ limits = { pendingPerBatch = 4, queueCapacity = 4 } })

	--[[
		A handler-less channel is bounded by its **queue**, not by the batch ceiling, and that is the
		examined answer rather than an oversight.

		The two limits answer different questions. `queueCapacity` bounds what is held and drops the
		*oldest*, which is right for a `:listen` that attached a frame late — the traffic worth
		keeping is the recent traffic. The batch ceiling drops the newest, so applying it here would
		lose exactly what the queue exists to keep. What is left is decode work, and on an inbound
		class that is what `rate` licenses.
	]]
	for index = 1, 12 do
		Batch.writePacket(Hushed, { n = index })
	end

	local survived = feed()

	check("a flood at an unlistened channel does not raise", survived)
	equals("the queue reports every drop past its depth", reportedAt("queue"), 8)
	equals("and the batch ceiling does not fire on it", reportedAt("budget"), 0)

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
	check("reported as truncated", string.find(first().reason, "truncated call id", 1, true) ~= nil)
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
	check("naming the repeat", string.find(first().reason, "already in flight", 1, true) ~= nil)
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
-- G4 as a property, not as a list of paths that were fixed
-- ---------------------------------------------------------------------------------------------

do
	reset()
	at += 1000
	budget.forget(mallory)

	--[[
		Two receive-path raises reached production before an external review found them: a table in
		the sidecar, and a pooled pending list two loops both believed they owned. Both are fixed,
		and fixing them does nothing for the third.

		So the guarantee is tested as a property. Something raises where nothing should — here the
		resolver, which is netweave's own code and has no business failing — and the batch is
		expected to come back, say so, and leave a decoder the next honest batch still works
		through. That last part is what a leak looks like from outside, and it is the only way to
		see one.
	]]
	local exploding = Inbound.new({
		resolve = function(): any
			error("something inside netweave went wrong")
		end,

		admit = function(): string?
			return nil
		end,

		isServer = true,
	})

	Batch.writePacket(Fixed, { a = 1, b = 2 })

	local packed, carried = Buffer.take()
	local survived = pcall(exploding.receive, packed, carried, mallory)

	check("a raise inside the read phase does not escape the receive path", survived)
	equals("it is reported", #reports, 1)
	equals("at parse", first().stage, "parse")
	check("naming the raise", string.find(first().reason, "read phase raised", 1, true) ~= nil)
end

do
	reset()
	at += 1000
	budget.forget(mallory)

	--[[ And a raise in the dispatch phase, from something `call` does not already guard. A handler
	     is `xpcall`ed; what is not is the loop around it.

	     Read as a *client*, because a reply is what a client receives — on the server the same bytes
	     are a request and fail at parse instead, which is a different case. ]]
	local exploding = Inbound.new({
		resolve = Namespace.channelById,

		admit = function(): string?
			return nil
		end,

		isServer = false,

		queries = {
			spawn = queries.spawn,
			enter = queries.enter,
			answer = queries.answer,
			refuse = queries.refuse,
			abandon = queries.abandon,

			--[[ The one member `dispatch` calls outside `call`'s guard. ]]
			answered = function()
				error("something inside netweave went wrong")
			end,
		},
	})

	Buffer.load(nil)
	Batch.writeReply(Asked, 1, Batch.OK, { v = 1 })

	local packed = Buffer.take()
	local survived = pcall(exploding.receive, packed, nil, nil)

	check("a raise inside the dispatch phase does not escape either", survived)
	equals("it is reported", #reports, 1)
	equals("at handler", first().stage, "handler")

	--[[ The canary: whatever the raise left behind, an honest batch still arrives. A leaked pending
	     list, a stranded cursor or an unrestored sender would all show up here and nowhere else. ]]
	reset()
	at += 1000
	budget.forget(mallory)

	Batch.writePacket(Fixed, { a = 7, b = 9 })
	feed()

	equals("and an honest batch still arrives afterwards", delivered, 1)
	equals("with nothing reported", #reports, 0)
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
	check("as truncated", string.find(first().reason, "truncated control", 1, true) ~= nil)
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
	check("naming the overrun", string.find(first().reason, "past the batch", 1, true) ~= nil)
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
	check("naming the kind", string.find(first().reason, "control kind 200", 1, true) ~= nil)
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
	--[[ Four, not three: the hello itself is reported now (M3 phase 9). A peer that sends a
	     mismatched hello and nothing else used to be refused in silence. ]]
	equals("the hello and all three behind it were refused", #reports, 4)
	equals("at protocol", reportedAt("protocol"), 4)
	check("with both hashes named", string.find(first().reason, Protocol.hex(protocol.hash), 1, true) ~= nil)

	agreement.forget(mallory)
end

do
	reset()
	at += 1000
	budget.forget(mallory)
	agreement.forget(mallory)
	announced = 0

	--[[
		Three hundred hellos in one batch, every one of them wrong, no two alike.

		Id 0 is read before `sink.admit`, because resolving 0 would fail and that failure would be
		the unrecoverable one — so nothing charges a hello a rate and the pending ceiling never sees
		it. That made this the cheapest thing a client can send that makes the server work: an
		external review measured 300 mismatched hellos in one 2,101-byte batch producing 300 replies
		and 76 KB of garbage, with nothing reported at all (M3 phase 9).

		What bounds it is the verdict, not a limit: a peer already known to be wrong is not
		re-judged, so the second hello costs a table read.
	]]
	for index = 1, 300 do
		Batch.writeHello(protocol.hash + index)
	end

	local survived = feed()

	check("a batch of nothing but hellos does not raise", survived)
	equals("the first one is answered", announced, 1)
	equals("and reported", #reports, 1)
	equals("at protocol", reportedAt("protocol"), 1)
	check("the peer is refused", agreement.verdict(mallory) ~= nil)

	--[[ And the refusal still works: a payload behind them in a later batch does not land. ]]
	reset()
	at += 1000
	budget.forget(mallory)

	Batch.writePacket(Fixed, { a = 1, b = 2 })
	feed()

	equals("a payload from that peer is still refused", delivered, 0)
	equals("once", #reports, 1)

	agreement.forget(mallory)
	announced = 0
end

-- ---------------------------------------------------------------------------------------------
-- Replication, from the side that must not be able to touch it
-- ---------------------------------------------------------------------------------------------

do
	reset()
	at += 1000
	budget.forget(mallory)

	--[[
		A replicated channel is server-to-client, so **everything in this section is a client
		sending something that cannot legitimately exist**. G6 refuses it before decode, at
		`direction`, and the assertions are about what it costs rather than whether it lands.

		The baseline store is the interesting part. It is memory the server holds per client, and a
		peer that could add to it, or empty it, would have found either a leak or an amplifier.
	]]
	local held = Baseline.new(true)

	local replicated = Inbound.new({
		resolve = Namespace.channelById,

		admit = function(): string?
			return nil
		end,

		isServer = true,
		baselines = held,
	})

	--[[ Seeded the way the tick would, so there is something to lose. ]]
	held.keep(mallory, Replicated, 1, { n = 1 })
	held.keep(mallory, Replicated, 2, { n = 2 })
	equals("the server is holding two baselines", held.held(mallory), 2)

	--[[ Forty packets on the replicated id, which is the shape a client would send if it wanted to
	     be replicated *to* on its own terms. ]]
	for index = 1, 40 do
		Batch.writeChange(Replicated, index, nil, { n = index })
	end

	local changes, alsoCarried = Buffer.take()
	local stood = pcall(replicated.receive, changes, alsoCarried, mallory)

	check("a batch of well-formed changes does not raise", stood)
	equals("every one refused at direction", reportedAt("direction"), 40)
	equals("and none of them decoded", reportedAt("parse"), 0)

	--[[ **A client cannot make the server hold a baseline it did not ask for.** The only thing that
	     writes one is the tick, driven by the store and the audience; there is no packet that
	     reaches `keep`. Forty tried. ]]
	equals("the server holds exactly what it held", held.held(mallory), 2)
	equals("the first is untouched", held.of(mallory, Replicated, 1).n, 1)
	equals("and so is the second", held.of(mallory, Replicated, 2).n, 2)

	--[[
		**And it cannot make the server forget one either**, which is the half that was live until
		this section was written.

		Any refusal of a replicated packet clears the channel and asks for it again — right on the
		client, where a refusal means a change was lost. On the server it meant one malformed byte
		bought a full resend of everything that peer could see, every batch, forever. The endpoint
		that gives up a baseline is now the one that receives changes.
	]]
	equals("and did not forget one because a peer sent rubbish", held.held(mallory), 2)
end

do
	reset()
	at += 1000
	budget.forget(mallory)

	--[[
		The resync control packet, which is the one thing a client sends that makes the server do
		work it did not choose.

		It is bounded rather than refused: clearing a baseline already cleared costs a table lookup,
		and however many arrive in one tick provoke one resend in the tick that follows. The most a
		peer can extract is a whole state per tick, which is what `nw.state` sends unconditionally.
	]]
	local held = Baseline.new(true)

	local replicated = Inbound.new({
		resolve = Namespace.channelById,
		admit = function(): string?
			return nil
		end,
		isServer = true,
		baselines = held,
	})

	held.keep(mallory, Replicated, 1, { n = 1 })

	for _ = 1, 300 do
		Batch.writeResync(Replicated.id)
	end

	local packed = Buffer.take()
	local survived = pcall(replicated.receive, packed, nil, mallory)

	check("three hundred resync requests do not raise", survived)
	equals("the baseline is cleared once and stays cleared", held.held(mallory), 0)

	reset()

	--[[ A resync naming something that is not a replicated channel — an ordinary id, and one that
	     is not a channel at all. Refused rather than assumed: a peer that could ask about ids it
	     made up could otherwise walk the server's channel table on demand. ]]
	Batch.writeResync(Fixed.id)
	Batch.writeResync(60000)

	local madeUp = Buffer.take()
	local stood = pcall(replicated.receive, madeUp, nil, mallory)

	check("a resync for a channel that is not replicated does not raise", stood)
	equals("both are refused", reportedAt("replicate"), 2)
end

do
	reset()
	at += 1000
	budget.forget(mallory)

	--[[
		**One resync a frame is one full state a frame, and that was the largest amplifier here.**

		The clear is a table drop. What it costs is the *tick after it*, which finds no baseline and
		writes every subject that peer can see — measured with the real tick at a hundred subjects:
		a steady state of 0 bytes a frame became **601 bytes a frame**, bought with five bytes a
		frame, outside every budget netweave has. A replicated channel declares no `rate`, so
		`Budget.admit` has nothing to charge, and control packets are read before `admit` anyway
		(M4 report, first danger).

		The section above asserts the clear is idempotent *within one batch*. That was never the
		attack: the attacker sends one per frame and the tick repopulates in between, so every one of
		them lands on a fresh set of baselines.

		The bound is a coalesce rather than a refusal, and this asserts the difference. A refused
		resync would strand an honest client — it asks once, at the moment it gave up, and nothing
		retries — so the ask is always honoured, at most once per window, and `tick` honours what
		arrived inside one.
	]]
	local held = Baseline.new(true)

	local replicated = Inbound.new({
		resolve = Namespace.channelById,
		admit = function(): string?
			return nil
		end,
		isServer = true,
		baselines = held,
	})

	local function ask()
		Batch.writeResync(Replicated.id)
		replicated.receive((Buffer.take()), nil, mallory)
	end

	local function repopulate()
		held.keep(mallory, Replicated, 1, { n = 1 })
		held.keep(mallory, Replicated, 2, { n = 2 })
	end

	--[[ The first ask is honoured immediately: a client that just lost a change waits for nothing. ]]
	repopulate()
	ask()
	equals("the first ask clears at once", held.held(mallory), 0)

	--[[ Then the window is shut. Sixty more asks, each on a freshly repopulated set, the way a tick
	     would leave it — and none of them lands. ]]
	local cleared = 0

	for _ = 1, 60 do
		repopulate()
		ask()

		if held.held(mallory) == 0 then
			cleared += 1
		end
	end

	equals("and sixty more inside the window buy nothing", cleared, 0)

	--[[ Nothing is dropped, though. The window passes and the ask that arrived inside it is
	     honoured by the tick, without the peer asking again. ]]
	repopulate()

	for _ = 1, 30 do
		replicated.tick()
	end

	equals("what was asked for inside the window is honoured after it", held.held(mallory), 0)

	--[[ And a peer already refused at `protocol` gets nothing at all, which is the other half:
	     control packets are read before `admit`, so the verdict is the only thing standing between a
	     peer whose declarations disagree and a full state re-encode. ]]
	reset()

	local refused = Protocol.new({
		hash = function(): number
			return protocol.hash + 1
		end,

		announce = function() end,
		isServer = true,
	})

	local guarded = Inbound.new({
		resolve = Namespace.channelById,
		admit = function(): string?
			return nil
		end,
		isServer = true,
		baselines = held,
		agreement = refused,
	})

	refused.greet(mallory, protocol.hash)
	repopulate()

	Batch.writeHello(protocol.hash)
	Batch.writeResync(Replicated.id)

	local ignored = pcall(guarded.receive, (Buffer.take()), nil, mallory)

	check("a resync from a peer on another protocol does not raise", ignored)
	equals("and does not clear a thing", held.held(mallory), 2)
	check("while saying so", reportedAt("protocol") > 0)
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
