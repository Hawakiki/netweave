--!strict

--[[
	Request and response, under lune.

		lune run tests/query_runtime

	Two peers in one process. The client's `Outbound` writes into a queue the server's `Inbound`
	reads from and back again, so a call goes out over the real envelope, through the real budget
	and policy, and comes back through the real reply framing — none of which needs Roblox.

	Most of this file is failure paths, and that is the shape a request/response layer has to be
	tested in. There is one way for a call to succeed and eight ways for it not to, and every one of
	the eight ends with the caller's thread resumed rather than parked forever, which is the
	property `RESEARCH §3.7-G` says Blink and Zap do not have.
]]

local Batch = require("../src/transport/Batch")
local Buffer = require("../src/codec/Buffer")
local Config = require("../src/api/Config")
local Inbound = require("../src/transport/Inbound")
local Link = require("../src/transport/Link")
local Observer = require("../src/api/Observer")
local Outbound = require("../src/transport/Outbound")
local Query = require("../src/transport/Query")
local Recipients = require("../src/transport/Recipients")
local nw = require("../src/netweave")
local t = require("../src/types")

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

-- ---------------------------------------------------------------------------------------------
-- The two peers
-- ---------------------------------------------------------------------------------------------

local alice = { name = "alice" }
local bob = { name = "bob" }

local allows = nw.policy(function()
	return function()
		return nw.allow()
	end
end)

local denies = nw.policy(function()
	return function()
		return nw.deny("not yours")
	end
end)

local raises = nw.policy(function()
	return function(): any
		error("the policy is broken")
	end
end)

--[[ Declared through `nw.query` rather than assembled by hand, so the reply codec, the derived
     reply ceiling and the required timeout all come from the shipped path. Only the id and the
     qualified name are filled in here; a namespace would otherwise have to be declared and sealed
     between every case. ]]
local function queryOf(id: number, spec: any): any
	--[[ Through `any`, because the declaration type functions read a *literal* table and this one
	     arrives as a parameter. The runtime checks still run, which is what these cases are about;
	     `tests/api_reject.luau` is where the type layer is pinned. ]]
	local channel = (nw.query :: any)(spec)

	channel.id = id
	channel.qualified = `test.q{id}`

	return channel
end

local Loadout = t.struct({ primary = t.u16, secondary = t.u16 })

local getLoadout = queryOf(1, {
	args = t.u8(0, 2),
	returns = Loadout,
	rate = 100,
	timeout = 5,
	authorize = allows,
})

local refused = queryOf(2, {
	args = t.u8(0, 2),
	returns = Loadout,
	rate = 100,
	timeout = 5,
	authorize = denies,
})

local broken = queryOf(3, {
	args = t.u8(0, 2),
	returns = Loadout,
	rate = 100,
	timeout = 5,
	authorize = raises,
})

--[[ A counted request and a counted reply, so the framing under a call id is exercised in both
     directions rather than only on fixed-size payloads. ]]
local lookup = queryOf(4, {
	args = t.struct({ name = t.string(0, 32) }),
	returns = t.struct({ found = t.boolean, label = t.string(0, 64) }),
	rate = 100,
	timeout = 5,
	authorize = allows,
})

local trickle = queryOf(5, {
	args = t.u8(0, 2),
	returns = Loadout,
	rate = 2,
	burst = 2,
	timeout = 5,
	authorize = allows,
})

--[[ Not a query. It shares the batch with one, to pin that a yielding handler does not hold up the
     packets behind it. ]]
local ping = nw.signal({ data = t.struct({ seq = t.u8 }), rate = 100 })
ping.id = 6
ping.qualified = "test.ping"

local byId: { [number]: any } = {}

for _, channel in { getLoadout, refused, broken, lookup, trickle, ping } do
	byId[channel.id] = channel
end

type Frame = { packed: buffer, instances: { any }, to: any }

--[[ Never reassigned: the two links close over these tables, so swapping one for a fresh table
     would leave the link filling the one nothing reads. ]]
local toServer: { Frame } = {}
local toClient: { Frame } = {}
local carried: { Frame } = {}

local function linkInto(queue: { Frame }): Link.Link
	return {
		send = function(_reliable, destination, packed, instances)
			table.insert(queue, { packed = packed, instances = instances, to = destination })
		end,

		sendAll = function(_reliable, packed, instances)
			table.insert(queue, { packed = packed, instances = instances, to = "everyone" })
		end,

		receive = function() end,
	}
end

local roster: Recipients.Roster = {
	all = function()
		return { alice, bob }
	end,

	owner = function(): any?
		return alice
	end,

	within = function(_subject: any, _studs: number, out: { any }): number
		out[1] = alice
		return 1
	end,
}

local clientOut = Outbound.new(linkInto(toServer), roster)
local serverOut = Outbound.new(linkInto(toClient), roster)

--[[ Injected rather than read off the wall, for the same reason `Budget` injects one: a five-second
     timeout tested against `os.clock` is a five-second test. ]]
local at = 0

local function clock(): number
	return at
end

--[[ `task.spawn`'s two jobs, without `task`, which lune does not have. A raise on a spawned thread
     is a test failure here rather than a swallowed boolean — the production `task.spawn` surfaces
     it in the console, and a test that hid it would pass while the server logged an error. ]]
local function spawn(target: any, ...: any)
	local thread = if type(target) == "thread" then target else coroutine.create(target)
	local ok, failure = coroutine.resume(thread, ...)

	if not ok then
		fail(`a spawned thread raised: {tostring(failure)}`)
	end
end

local serverQuery = Query.new({
	request = function()
		fail("the server does not make requests")
	end,

	reply = function(channel: any, who: any, call: number, status: number, value: any?)
		serverOut.reply(channel, who, call, status, value)
	end,

	spawn = spawn,
	clock = clock,
})

--[[ The ids the caller allocated. A test that has to build a reply by hand needs the id the caller
     is actually waiting on, and `request` is the only place it becomes visible. ]]
local issued: { number } = {}

local clientQuery = Query.new({
	request = function(channel: any, call: number, value: any)
		table.insert(issued, call)
		clientOut.request(channel, call, value)
	end,

	reply = function()
		fail("the client does not answer")
	end,

	spawn = spawn,
	clock = clock,
})

local denyOn: { [string]: string } = {}

local serverIn = Inbound.new({
	resolve = function(id: number): any
		return byId[id]
	end,

	admit = function(channel: any): string?
		return denyOn[channel.qualified]
	end,

	isServer = true,
	queries = serverQuery,
})

local clientIn = Inbound.new({
	resolve = function(id: number): any
		return byId[id]
	end,

	admit = function(): string?
		return nil
	end,

	isServer = false,
	queries = clientQuery,
})

local reported: { string } = {}

local function watch()
	Observer.reset()
	Observer.observe(function(rejection)
		table.insert(reported, `{rejection.stage}:{rejection.channel}:{rejection.reason}`)
	end)
end

local function reportsMatching(pattern: string): number
	local count = 0

	for _, entry in reported do
		if string.find(entry, pattern, 1, true) then
			count += 1
		end
	end

	return count
end

--[[
	One frame, in the order `Driver` runs them.

	The flushes have to alternate with the deliveries and cannot be hoisted: the outgoing buffer is
	global (`src/codec/Buffer.luau`), so two `Outbound`s in one process — which is a test artefact,
	never a real deployment — must not hold a loaded record across each other's writes.
]]
local function drain(queue: { Frame }, into: Inbound.Inbound, from: any?)
	table.clear(carried)
	table.move(queue, 1, #queue, 1, carried)
	table.clear(queue)

	for _, frame in carried do
		into.receive(frame.packed, frame.instances, from)
	end
end

local function pump()
	clientOut.flush()
	drain(toServer, serverIn, alice)

	serverOut.flush()
	drain(toClient, clientIn, nil)
end

type Answer = { value: any, reason: string?, done: boolean }

--[[ `invoke` parks the thread that called it, so a test has to call it from one it can park. ]]
local function callOn(channel: any, args: any): Answer
	local answer: Answer = { value = nil, reason = nil, done = false }

	spawn(function()
		local value, reason = clientQuery.invoke(channel, args)

		answer.value = value
		answer.reason = reason
		answer.done = true
	end)

	return answer
end

local function reset()
	table.clear(reported)
	table.clear(denyOn)
	table.clear(issued)
	table.clear(toServer)
	table.clear(toClient)
	at = 0

	for _, channel in byId do
		channel.handler = nil
	end

	clientQuery.forget(alice)
	serverQuery.forget(alice)
	serverQuery.forget(bob)
	Config.reset()
	watch()
end

-- ---------------------------------------------------------------------------------------------
-- The round trip
-- ---------------------------------------------------------------------------------------------

do
	reset()

	local seen: { number } = {}

	getLoadout.handler = function(_ctx, slot)
		table.insert(seen, slot)
		return { primary = 100 + slot, secondary = 200 + slot }
	end

	local answer = callOn(getLoadout, 2)

	check("the caller is parked until the answer arrives", not answer.done)
	equals("and the call is counted as outstanding", clientQuery.outstanding(), 1)

	pump()

	equals("the handler saw the request", #seen, 1)
	equals("with the argument the caller sent", seen[1], 2)
	check("the caller was resumed", answer.done)
	equals("with the answer", answer.value.primary, 102)
	equals("and the second field", answer.value.secondary, 202)
	equals("and no failure", answer.reason, nil)
	equals("the slot was given back", clientQuery.outstanding(), 0)
	equals("on both ends", serverQuery.inflight(alice), 0)
	equals("and nothing was reported", #reported, 0)
end

do
	reset()

	--[[ A counted schema each way. The call id sits in the frame rather than the payload, so the
	     length prefix still counts exactly the bytes the schema produced. ]]
	lookup.handler = function(_ctx, args)
		return { found = args.name == "sword", label = `a {args.name}` }
	end

	local hit = callOn(lookup, { name = "sword" })
	local miss = callOn(lookup, { name = "shield" })

	equals("two calls are outstanding", clientQuery.outstanding(), 2)

	pump()

	check("both came back", hit.done and miss.done)
	equals("the first found it", hit.value.found, true)
	equals("with its label", hit.value.label, "a sword")
	equals("the second did not", miss.value.found, false)
	equals("and both slots were released", clientQuery.outstanding(), 0)
end

-- ---------------------------------------------------------------------------------------------
-- The ceiling Blink and Zap have and netweave does not
-- ---------------------------------------------------------------------------------------------

do
	reset()

	--[[
		Three hundred calls in flight at once.

		Blink (`Generator/init.luau:723-745`) and Zap (`client.rs:1329`) key pending calls by a u8,
		so the 257th is dropped with a raise. netweave's id is a varint and the only bound is the one
		it declares, so this is the case that has to work rather than merely not crash.
	]]
	nw.configure({ limits = { callsInFlight = 400, pendingPerBatch = 1024 } })

	getLoadout.handler = function(_ctx, slot)
		return { primary = slot, secondary = 1 }
	end

	local answers: { Answer } = {}

	for _ = 1, 300 do
		table.insert(answers, callOn(getLoadout, 1))
	end

	equals("all three hundred are outstanding", clientQuery.outstanding(), 300)

	pump()

	local resolved = 0

	for _, answer in answers do
		if answer.done and answer.reason == nil then
			resolved += 1
		end
	end

	equals("every one of them was answered", resolved, 300)
	equals("and nothing is left waiting", clientQuery.outstanding(), 0)
	equals("no call was refused on the way", #reported, 0)

	Config.reset()
end

-- ---------------------------------------------------------------------------------------------
-- The timeout Blink and Zap do not have
-- ---------------------------------------------------------------------------------------------

do
	reset()

	local parked: thread? = nil

	--[[ A handler that never returns. Under Blink or Zap this is the caller's thread gone for the
	     session; `grep -ri timeout blink/src` returns nothing (`RESEARCH §3.7-G`). ]]
	getLoadout.handler = function()
		parked = coroutine.running()
		coroutine.yield()
		return { primary = 1, secondary = 2 }
	end

	local answer = callOn(getLoadout, 1)

	pump()

	check("the handler is parked", parked ~= nil)
	check("and so is the caller", not answer.done)

	at = 4.9
	clientQuery.tick()
	check("nothing fires before the deadline", not answer.done)

	at = 5.1
	clientQuery.tick()

	check("the caller was resumed at the deadline", answer.done)
	equals("with no answer", answer.value, nil)
	check("and a reason that names the wait", string.find(answer.reason or "", "5s", 1, true) ~= nil)
	equals("the slot was released", clientQuery.outstanding(), 0)
	equals("and it was reported once", reportsMatching("query:test.q1"), 1)

	--[[ The late answer, arriving after the caller gave up. It must not resume a thread that has
	     already been resumed — which under Luau is an error, not a silent double delivery. ]]
	local resumed = parked :: thread
	table.clear(reported)
	spawn(resumed)
	pump()

	check("the late answer did not resume anything twice", answer.value == nil)
	equals("and it was dropped without a second report", #reported, 0)
	equals("with the server's slot released", serverQuery.inflight(alice), 0)
end

-- ---------------------------------------------------------------------------------------------
-- Every other way a call ends
-- ---------------------------------------------------------------------------------------------

do
	reset()

	--[[ Nobody attached `:handle`. The queue that keeps a listener-less signal is deliberately not
	     used here: the caller is on a deadline, and holding the request until a handler shows up
	     turns an immediate answer into a timeout. ]]
	local answer = callOn(getLoadout, 1)

	pump()

	check("the caller was resumed rather than queued", answer.done)
	equals("with no value", answer.value, nil)
	check(
		"and a reason naming the missing handler",
		string.find(answer.reason or "", "handler", 1, true) ~= nil
	)
end

do
	reset()

	refused.handler = function()
		fail("a denied request must not reach the handler")
		return { primary = 0, secondary = 0 }
	end

	local answer = callOn(refused, 1)

	pump()

	check("a denied call comes back", answer.done)
	equals("with no value", answer.value, nil)
	check("and a reason", (answer.reason or "") ~= "")
	equals("the denial was reported on the server", reportsMatching("authorize:test.q2"), 1)

	--[[ The policy's own words stay on the server. `not yours` is written for the game that owns
	     the authorization model, and sending it back would publish that model to the machine the
	     model exists to distrust (`PLAN-M3` D-12). ]]
	check(
		"and the policy's reason did not cross the wire",
		string.find(answer.reason or "", "not yours", 1, true) == nil
	)
end

do
	reset()

	broken.handler = function()
		fail("a raising policy must not reach the handler")
		return { primary = 0, secondary = 0 }
	end

	local answer = callOn(broken, 1)

	pump()

	check("a policy that raises refuses the call rather than killing the batch", answer.done)
	equals("with no value", answer.value, nil)
	equals("reported at authorize", reportsMatching("authorize:test.q3"), 1)
	check("naming the raise", reportsMatching("the policy raised") == 1)
end

do
	reset()

	getLoadout.handler = function()
		error("the handler is broken")
	end

	local answer = callOn(getLoadout, 1)

	pump()

	check("a handler that raises still answers", answer.done)
	equals("with no value", answer.value, nil)
	equals("and it was reported at handler", reportsMatching("handler:test.q1"), 1)
	equals("the server's slot was released", serverQuery.inflight(alice), 0)
end

do
	reset()

	--[[ `secondary` is a u16 and this is not one. The raise happens inside `Batch.writeReply` on a
	     spawned thread, where nothing is left to catch it — so it is caught here and becomes the
	     status the caller was going to need anyway. ]]
	getLoadout.handler = function()
		return { primary = 1, secondary = 999999 }
	end

	local answer = callOn(getLoadout, 1)

	pump()

	check("an answer the schema forbids does not take the thread with it", answer.done)
	equals("the caller got no value", answer.value, nil)
	equals("and the encode failure was reported", reportsMatching("the answer did not encode"), 1)
	equals("with the slot released", serverQuery.inflight(alice), 0)
end

do
	reset()

	getLoadout.handler = function(_ctx, slot)
		return { primary = slot, secondary = 0 }
	end

	denyOn["test.q1"] = "over the rate"

	local answer = callOn(getLoadout, 1)

	pump()

	check("a request the budget refuses comes back at once", answer.done)
	equals("with no value", answer.value, nil)
	equals("reported at budget", reportsMatching("budget:test.q1"), 1)
end

-- ---------------------------------------------------------------------------------------------
-- The bounds
-- ---------------------------------------------------------------------------------------------

do
	reset()
	nw.configure({ limits = { callsInFlight = 2 } })

	local held: { thread } = {}

	getLoadout.handler = function()
		table.insert(held, coroutine.running())
		coroutine.yield()
		return { primary = 1, secondary = 2 }
	end

	local first = callOn(getLoadout, 1)
	local second = callOn(getLoadout, 1)

	pump()

	equals("both calls are parked in handlers", #held, 2)
	equals("and the server counts them", serverQuery.inflight(alice), 2)
	check("neither has answered", not first.done and not second.done)

	--[[ The caller's own bound trips first, because it is the same number counted from the other
	     end: two outstanding is two outstanding. ]]
	local third = callOn(getLoadout, 1)

	check("the third call is refused without leaving", third.done)
	equals("with no value", third.value, nil)
	check("naming the limit", string.find(third.reason or "", "limit is 2", 1, true) ~= nil)
	equals("and it was reported", reportsMatching("query:test.q1"), 1)

	for _, thread in held do
		spawn(thread)
	end

	pump()

	check("the parked calls still answer once their handlers return", first.done and second.done)
	equals("and the server's slots came back", serverQuery.inflight(alice), 0)

	Config.reset()
end

do
	reset()
	nw.configure({ limits = { callsInFlight = 2 } })

	--[[
		The same bound from the server's side, reached by a client that ignores its own.

		A hostile client does not run netweave's `invoke`; it writes bytes. So the request packets
		are built by hand here, which is the only way to test the server's half of a bound the
		client normally enforces first.
	]]
	local held: { thread } = {}

	getLoadout.handler = function()
		table.insert(held, coroutine.running())
		coroutine.yield()
		return { primary = 1, secondary = 2 }
	end

	Buffer.load(nil)
	Batch.writeRequest(getLoadout, 1, 1)
	Batch.writeRequest(getLoadout, 2, 1)
	Batch.writeRequest(getLoadout, 3, 1)

	local packed, instances = Buffer.take()
	serverIn.receive(packed, instances, bob)

	equals("the server took two", #held, 2)
	equals("and holds exactly the limit", serverQuery.inflight(bob), 2)
	equals("refusing the third", reportsMatching("calls already in flight"), 1)

	for _, thread in held do
		spawn(thread)
	end

	equals("and the slots come back as the handlers return", serverQuery.inflight(bob), 0)

	Config.reset()
end

do
	reset()

	--[[
		The same call id twice from one client.

		Without a check the count and the set disagree: two increments, one key, and the first answer
		releases the only slot the second could ever have released. Sixteen of these would retire a
		player's call budget for the session, which is a denial of service a client writes in one
		line.
	]]
	local held: { thread } = {}

	getLoadout.handler = function()
		table.insert(held, coroutine.running())
		coroutine.yield()
		return { primary = 1, secondary = 2 }
	end

	Buffer.load(nil)
	Batch.writeRequest(getLoadout, 7, 1)
	Batch.writeRequest(getLoadout, 7, 1)

	local packed, instances = Buffer.take()
	serverIn.receive(packed, instances, bob)

	equals("only the first was served", #held, 1)
	equals("the repeat was refused", reportsMatching("already in flight"), 1)
	equals("and the slot count matches reality", serverQuery.inflight(bob), 1)

	spawn(held[1])

	equals("so the slot is recoverable", serverQuery.inflight(bob), 0)
end

do
	reset()

	--[[ A player who leaves with a handler still parked. The thread cannot be cancelled — a yielded
	     Luau coroutine never can be — so what is released is the accounting, and the answer it
	     eventually produces is dropped rather than written to a buffer nobody will read. ]]
	local parked: thread? = nil

	getLoadout.handler = function()
		parked = coroutine.running()
		coroutine.yield()
		return { primary = 1, secondary = 2 }
	end

	Buffer.load(nil)
	Batch.writeRequest(getLoadout, 3, 1)

	local packed, instances = Buffer.take()
	serverIn.receive(packed, instances, bob)

	equals("the call is in flight", serverQuery.inflight(bob), 1)

	serverQuery.forget(bob)
	equals("and leaving releases it", serverQuery.inflight(bob), 0)

	table.clear(toClient)
	spawn(parked :: thread)
	serverOut.flush()

	equals("the answer to a departed player was not written", #toClient, 0)
	equals("and the slot did not come back twice", serverQuery.inflight(bob), 0)
end

do
	reset()

	--[[
		A refusal is written **while the batch is still being read**, and the packets behind it have
		to survive that.

		This is the interaction the whole design turns on. The refusal cannot wait for dispatch — the
		caller is on a deadline and the point of a status code is that it arrives now — so
		`Batch.writeReply` runs inside `Batch.read`'s loop. It is safe because `src/codec/Buffer.luau`
		keeps the incoming cursor and the outgoing buffer in separate state and nothing on that path
		calls game code, and "safe because I read the source" is what this case turns into a test.
	]]
	local answered: { number } = {}

	getLoadout.handler = function(_ctx, slot)
		table.insert(answered, slot)
		return { primary = slot, secondary = 9 }
	end

	--[[ Refused at admit, so the reply is written between the first packet's decode and the second
	     packet's id read. ]]
	denyOn["test.q2"] = "over the rate"

	refused.handler = function()
		fail("a budget refusal must not reach the handler")
		return { primary = 0, secondary = 0 }
	end

	Buffer.load(nil)
	Batch.writeRequest(refused, 11, 1)
	Batch.writeRequest(getLoadout, 12, 2)
	Batch.writePacket(ping, { seq = 77 })

	local pings: { number } = {}

	ping.handler = function(_ctx, value)
		table.insert(pings, value.seq)
	end

	local packed, instances = Buffer.take()
	serverIn.receive(packed, instances, bob)

	equals("the packet behind the refusal decoded", #answered, 1)
	equals("with its own argument", answered[1], 2)
	equals("and so did the one behind that", #pings, 1)
	equals("carrying its own payload", pings[1], 77)
	equals("the refusal was reported once", reportsMatching("budget:test.q2"), 1)

	serverOut.flush()

	--[[ Both replies are for the same player, so they batch into one call — the refusal written
	     mid-read and the answer written at dispatch land in the same buffer, which is the other half
	     of the claim. Eleven bytes: a version byte, then `id + call + status` for the refusal and
	     `id + call + status + 4` for the answer. ]]
	equals("both replies left in one batch", #toClient, 1)
	equals("carrying a refused reply and an answered one", buffer.len(toClient[1].packed), 11)
end

do
	reset()

	--[[
		An answer the pending ceiling threw away, and the caller told what happened.

		Found by the phase 4 audit. `pendingPerBatch` bounds the decoded values one batch may hold
		live, and a reply is one of them — so a batch past the ceiling can discard an answer with a
		caller still parked on it. Before the fix that caller waited out its entire timeout and was
		then told `no answer within 5s`, about a packet that had arrived, decoded and been dropped a
		frame earlier. The wait is wrong and the sentence is a lie.

		Reaching it needs `callsInFlight` above `pendingPerBatch`, which is a misconfiguration rather
		than a hostile peer. It is still the rule the rest of this phase keeps: a call that cannot be
		answered gets an answer saying so.
	]]
	nw.configure({ limits = { callsInFlight = 8 } })

	local first = callOn(getLoadout, 0)
	local second = callOn(getLoadout, 1)
	local third = callOn(getLoadout, 2)

	equals("three calls are waiting", #issued, 3)

	--[[ The answers are built by hand rather than round-tripped, so the ceiling applies to the reply
	     direction alone. Lowering it for a round trip would have the server drop the third *request*
	     instead, which is a different case and already covered. ]]
	nw.configure({ limits = { pendingPerBatch = 2 } })

	Buffer.load(nil)

	for index, call in issued do
		Batch.writeReply(getLoadout, call, Batch.OK, { primary = index - 1, secondary = 4 })
	end

	clientIn.receive(Buffer.take(), nil, nil)

	--[[
		**M4 phase 8 took the premise away, and the right thing to assert is what replaced it.**

		~~Two of the three answers fit under the ceiling and the third is dropped, and the caller is
		told so on the next tick rather than waiting out its timeout.~~

		The pending ceiling is the *server's* now: the batch's size is chosen by an untrusted peer
		only when the peer is a client, and applying it on a client livelocked a replicated channel at
		257 subjects (`src/transport/Inbound.luau`, `refreshCeiling`). A reply only ever arrives on a
		client — the server `handle`s a query and the client `invoke`s it, so there is no direction in
		which a server parks on an answer — which makes the defect the phase 4 audit found
		**unreachable** rather than fixed twice.

		So the assertion is the stronger one: three answers, three callers resolved, nothing parked
		and nothing reported. The `holdReply` branch that abandons a dropped answer with a reason
		stays where it is; it guards a transport that does not assume the API's directions, and
		asserting it would need a server that can `invoke`, which netweave does not have.
	]]
	check("every answer arrived", first.done and second.done and third.done)
	equals("in order", first.value.primary, 0)
	equals("and the last one is not the one that was dropped", third.value.primary, 2)
	equals("nothing was refused", reportsMatching("budget:test.q1"), 0)

	clientQuery.tick()

	check("the third stays answered across a tick", third.done)
	equals("with no reason, because nothing went wrong", third.reason, nil)
	equals("nothing is left outstanding", clientQuery.outstanding(), 0)

	Config.reset()
end

-- ---------------------------------------------------------------------------------------------
-- The framing
-- ---------------------------------------------------------------------------------------------

do
	reset()

	--[[ `id + call + status`, and nothing behind it. A refused reply on a static `returns` schema
	     would otherwise have to carry four bytes of nothing. ]]
	Buffer.load(nil)
	Batch.writeReply(getLoadout, 9, Batch.REFUSED, nil)

	local packed = Buffer.take()
	equals("a refused reply is version, id, call and status", buffer.len(packed), 4)

	Buffer.load(nil)
	Batch.writeReply(getLoadout, 9, Batch.OK, { primary = 1, secondary = 2 })

	local full = Buffer.take()
	equals("an answered one carries the payload behind it", buffer.len(full), 8)
end

do
	reset()

	--[[ A call id past 127 takes two varint bytes, which is the whole reason the id is a varint.
	     The reply has to echo the same number back through the same widening. ]]
	getLoadout.handler = function(_ctx, slot)
		return { primary = slot, secondary = 7 }
	end

	Buffer.load(nil)
	Batch.writeRequest(getLoadout, 5000, 2)

	local packed, instances = Buffer.take()
	local before = #toClient

	serverIn.receive(packed, instances, bob)
	serverOut.flush()

	equals("the server answered", #toClient - before, 1)

	local answered = false

	--[[ The client has no pending record for a call it did not make, so the reply is read, framed
	     and dropped — which is the assertion: it must not raise and must not resume anything. ]]
	clientIn.receive(toClient[#toClient].packed, toClient[#toClient].instances, nil)

	equals("a reply nobody is waiting for is dropped in silence", #reported, 0)
	check("and nothing was delivered", not answered)
end

do
	reset()

	--[[
		G5, in the reply direction.

		A refused reply is the shortest packet the format has, and the batch behind it has to survive
		it — which is what makes the status byte safe to end a packet on.
	]]
	getLoadout.handler = function(_ctx, slot)
		return { primary = slot, secondary = 3 }
	end

	local first = callOn(getLoadout, 1)
	local second = callOn(getLoadout, 2)

	pump()

	check("both answers arrived in one batch", first.done and second.done)
	equals("the first", first.value.primary, 1)
	equals("the second", second.value.primary, 2)
end

do
	reset()

	--[[
		A yielding query handler must not hold up the packets behind it.

		This is the reason a query runs on its own thread. Dispatched inline, the signal below would
		wait for a datastore read to come back — and so would the frame's flush, for every player.
	]]
	local parked: thread? = nil
	local pings: { number } = {}

	getLoadout.handler = function()
		parked = coroutine.running()
		coroutine.yield()
		return { primary = 1, secondary = 2 }
	end

	ping.handler = function(_ctx, value)
		table.insert(pings, value.seq)
	end

	Buffer.load(nil)
	Batch.writeRequest(getLoadout, 1, 1)
	Batch.writePacket(ping, { seq = 42 })

	local packed, instances = Buffer.take()
	serverIn.receive(packed, instances, bob)

	check("the query handler is still parked", parked ~= nil)
	equals("and the packet behind it was delivered anyway", #pings, 1)
	equals("with its own payload", pings[1], 42)

	spawn(parked :: thread)
end

-- ---------------------------------------------------------------------------------------------
-- The declaration
-- ---------------------------------------------------------------------------------------------

do
	reset()

	--[[ The reply's ceiling is derived from `returns`, not from `args`. Using the request's would
	     police an answer against the size of the question. ]]
	equals("the request ceiling comes from args", getLoadout.maxBytes, getLoadout.codec.maxSize)
	equals("the reply ceiling comes from returns", getLoadout.replyMaxBytes, 4)
	check("and the two are not the same number", getLoadout.maxBytes ~= getLoadout.replyMaxBytes)

	local ok, err = pcall(function()
		(nw.query :: any)({
			args = t.u8(0, 2),
			returns = t.optional(Loadout),
			rate = 2,
			timeout = 5,
			authorize = allows,
		})
	end)

	check("an optional answer is refused at the declaration", not ok)
	check(
		"and the message says what to write instead",
		not ok and string.find(tostring(err), "t.struct", 1, true) ~= nil
	)
end

do
	reset()

	--[[ `invoke` parks the caller, so it needs a frame it may park. The message has to name the fix,
	     because the raise Luau produces on its own is "attempt to yield across a C-call boundary"
	     and it points at netweave rather than at the call.

	     A metamethod is the shortest unyieldable frame there is; a comparator or a `gsub` callback
	     would do as well. What matters is that the guard fires before anything is written, so a
	     request does not leave for an answer nobody can receive. ]]
	local unyieldable = setmetatable({}, {
		__index = function()
			return clientQuery.invoke(getLoadout, 1)
		end,
	})

	local ok, err = pcall(function()
		return (unyieldable :: any).anything
	end)

	check("invoke from an unyieldable thread is refused", not ok)
	check(
		"with a message that names the wrapper",
		not ok and string.find(tostring(err), "task.spawn", 1, true) ~= nil
	)
	equals("and nothing was left outstanding", clientQuery.outstanding(), 0)
end

do
	reset()

	--[[ The rate budget is the request's, and a query is budgeted like any other inbound class. The
	     reply is not budgeted separately: it is one-for-one with a request that already spent the
	     player's tokens. ]]
	equals("a query declares a rate like every inbound class", trickle.rate, 2)
	equals("and a burst it may be declared with", trickle.burst, 2)
	equals("and a timeout, which no other class has", trickle.timeout, 5)
end

-- ---------------------------------------------------------------------------------------------

--[[ The outgoing buffer is global (`src/codec/Buffer.luau`) and an `Outbound` holds a record loaded
     into it until something flushes. The last call above is still parked in one, so this file would
     hand the next suite in the same session eight bytes it did not write — which is how
     `serdes_runtime` came to fail in Studio and nowhere else. ]]
clientOut.flush()
Buffer.take()
Buffer.load(nil)

Config.reset()
Observer.reset()

if failures > 0 then
	error(`{failures} query assertions failed`)
end

print("OK      query_runtime")

return true
