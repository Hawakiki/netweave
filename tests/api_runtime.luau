--!strict

--[[
	The declaration surface, under lune.

		lune run tests/api_runtime

	Half of what this milestone promises is a type error and lives in `tests/api_ok.luau` and
	`tests/api_reject.luau`; a type error cannot be tested by running code. What runs here is the
	other half: the checks that survive into a build with the solver switched off, the ones that
	catch a declaration coming through an `any`, and the behaviour — policy composition, the
	shared verdict, the recycled context, rejection routing, id assignment.
]]

local nw = require("../src/netweave")
local t = require("../src/types")

local Namespace = nw.internal.namespaces
local Observer = nw.internal.observer
local Context = nw.internal.context
local Transport = nw.internal.transport

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

--[[ Every declaration guard raises, because every one of them is a programmer error found at
     load. Nothing here is on the receive path, so G4 is not in play. ]]
local function refuses(name: string, fn: () -> (), fragment: string?)
	local ok, err = pcall(fn)

	if ok then
		fail(`{name}: expected a refusal, got none`)
		return
	end

	if fragment and not string.find(tostring(err), fragment, 1, true) then
		fail(`{name}: refusal did not mention "{fragment}": {tostring(err)}`)
	end
end

local alwaysAllows = nw.policy(function()
	return function()
		return nw.allow()
	end
end)

-- ---------------------------------------------------------------------------------------------
-- Classes: what each one requires, and what it forbids
-- ---------------------------------------------------------------------------------------------

do
	local Shot = t.struct({ origin = t.vector3, seq = t.u16 })

	refuses("a command with no rate", function()
		(nw.command :: any)({ data = Shot, authorize = alwaysAllows })
	end, "G2")

	refuses("a command with no authorize", function()
		(nw.command :: any)({ data = Shot, rate = 20 })
	end, "authorize")

	--[[ G2 says there is no unlimited, and `math.huge` is exactly that written in a way the type
	     system cannot see. ]]
	refuses("a command with an infinite rate", function()
		(nw.command :: any)({ data = Shot, rate = math.huge, authorize = alwaysAllows })
	end, "G2")

	refuses("a command with a negative rate", function()
		(nw.command :: any)({ data = Shot, rate = -1, authorize = alwaysAllows })
	end, "G2")

	refuses("an intent that authorizes", function()
		(nw.intent :: any)({ data = Shot, rate = 60, authorize = alwaysAllows })
	end, "forbids")

	refuses("a signal that authorizes", function()
		(nw.signal :: any)({ data = Shot, rate = 2, authorize = alwaysAllows })
	end, "forbids")

	refuses("a state with no audience", function()
		(nw.state :: any)({ data = Shot })
	end, "G3")

	refuses("a state that budgets", function()
		(nw.state :: any)({ data = Shot, audience = nw.audience.owner, rate = 10 })
	end, "forbids")

	refuses("a query with no timeout", function()
		(nw.query :: any)({
			args = t.u8,
			returns = Shot,
			rate = 2,
			authorize = alwaysAllows,
		})
	end, "timeout")

	refuses("a query with data instead of args", function()
		(nw.query :: any)({
			data = Shot,
			returns = Shot,
			rate = 2,
			timeout = 5,
			authorize = alwaysAllows,
		})
	end, "forbids")

	refuses("a channel whose data is not a netweave type", function()
		(nw.signal :: any)({ data = { origin = 1 }, rate = 2 })
	end, "netweave type")

	refuses("authorize that is not a policy", function()
		(nw.command :: any)({ data = Shot, rate = 20, authorize = function() end })
	end, "authorize")
end

--[[ The message an author actually needs is the one that names the alternative. A command with
     no policy is the single likeliest mistake, so it says what to write instead. ]]
do
	local ok, err = pcall(function()
		(nw.command :: any)({ data = t.u8, rate = 5 })
	end)

	check(
		"the missing-policy message names nw.policy",
		not ok and string.find(tostring(err), "nw.policy", 1, true) ~= nil
	)
	check(
		"and names signal as the honest alternative",
		not ok and string.find(tostring(err), "signal", 1, true) ~= nil
	)
end

-- ---------------------------------------------------------------------------------------------
-- Policies
-- ---------------------------------------------------------------------------------------------

do
	local verdict = nw.allow(7)
	equals("allow is ok", verdict.ok, true)
	equals("allow carries its value", verdict.value, 7)

	local denied = nw.deny("dead")
	equals("deny is not ok", denied.ok, false)
	equals("deny carries its reason", denied.reason, "dead")

	--[[ The record is shared on purpose (`src/api/Policy.luau`); a test that did not say so would
	     make the next reader think the aliasing was a bug. ]]
	check("the verdict is one shared record", verdict == denied)
	equals("and the last write wins", verdict.ok, false)
end

do
	--[[ `cond and nw.allow() or nw.deny(...)` is the idiom `DESIGN-API.md` §5 uses. With a shared
	     record it has to still work, because `or` sees a truthy table either way. ]]
	local function verdictFor(alive: boolean)
		return alive and nw.allow() or nw.deny("dead")
	end

	equals("the and/or idiom allows", verdictFor(true).ok, true)
	equals("the and/or idiom denies", verdictFor(false).ok, false)
	equals("and keeps the reason", verdictFor(false).reason, "dead")
end

do
	local configured = nw.policy(function(config)
		local limit = config.limit or 3

		return function(_ctx, value: any)
			return value <= limit and nw.allow(value) or nw.deny("over limit")
		end
	end)

	local check3 = (configured :: any).__nwCheck
	equals("a bare policy uses its defaults", check3(nil, 3).ok, true)
	equals("and refuses past them", check3(nil, 4).ok, false)

	local wider = (configured :: any)({ limit = 10 })
	equals("a configured policy widens", (wider :: any).__nwCheck(nil, 9).ok, true)
	equals("and the original is unchanged", check3(nil, 9).ok, false)

	refuses("configuring with a non-table", function()
		(configured :: any)(9)
	end, "table")
end

do
	local order: { string } = {}

	local function recorder(name: string, allow: boolean)
		return nw.policy(function()
			return function(_ctx, value: any)
				table.insert(order, name)
				return allow and nw.allow(value) or nw.deny(name)
			end
		end)
	end

	local composed = nw.all(recorder("first", true), recorder("second", false), recorder("third", true))
	local verdict = (composed :: any).__nwCheck(nil, 1)

	equals("all denies when a member denies", verdict.ok, false)
	equals("and reports the member's reason", verdict.reason, "second")
	equals("and stops at the first denial", #order, 2)

	--[[ Threading is what makes policies a narrowing pipeline rather than a set of gates. ]]
	local double = nw.policy(function()
		return function(_ctx, value: any)
			return nw.allow(value * 2)
		end
	end)

	local threaded = nw.all(double, double, double)
	equals("all threads the allowed value onward", (threaded :: any).__nwCheck(nil, 1).value, 8)

	refuses("all with no policies", function()
		(nw.all :: any)()
	end, "was given none")

	refuses("all with something that is not a policy", function()
		(nw.all :: any)(double, function() end)
	end, "argument 2")
end

-- ---------------------------------------------------------------------------------------------
-- Context
-- ---------------------------------------------------------------------------------------------

do
	--[[ A stand-in for a Player: `Context` only ever reads `.Character` off it, and lune has no
	     Roblox instances. `tests/roblox_runtime.luau` is where a real one would go, and does not,
	     because nothing here depends on it being real. ]]
	local player = { Name = "tester", Character = nil }

	local first = Context.acquire(player, "combat.fireWeapon")
	equals("the context knows its channel", first.channel, "combat.fireWeapon")
	equals("and its player", (first :: any).player, player)

	Context.release(player)

	local second = Context.acquire(player, "combat.aim")
	equals("a fresh acquisition is valid", second.channel, "combat.aim")
	equals("and carries the same player", (second :: any).player, player)

	if Context.guarded() then
		--[[
			Studio only — under lune the guard is off by design, and asserting an error here would
			be asserting that lune is Studio.

			The first check is the regression. One proxy per player expires permanently on the first
			`release`, so `second` raised here even though it had just been acquired: in a real game
			every handler from the second packet onward would have thrown, in Studio only. Found by
			running this file in Studio, which is the one place the guard is on at all.
		]]
		check("an acquisition after a release still reads", (pcall(function()
			return (second :: any).player
		end)))

		--[[ And the case an `active` boolean would miss: `first` belongs to a handler that has
		     returned, and reading it while a *later* one is running must raise rather than quietly
		     hand over this packet's data. ]]
		local ok, err = pcall(function()
			return (first :: any).channel
		end)

		check("a context retained from an earlier packet is refused", not ok)
		check("and says so", not ok and string.find(tostring(err), "expired", 1, true) ~= nil)

		Context.release(player)

		check("so is one whose own handler has returned", not (pcall(function()
			return (second :: any).player
		end)))
	else
		--[[ Unguarded, `acquire` hands back the record itself. That the two acquisitions are the
		     same table is the zero-allocation claim, stated as a test rather than trusted. ]]
		check("the record is reused rather than allocated", first == second)
	end

	Context.forget(player)
end

-- ---------------------------------------------------------------------------------------------
-- Rejections
-- ---------------------------------------------------------------------------------------------

do
	Observer.reset()

	local seen: { string } = {}

	local stop = nw.observe(function(rejection)
		table.insert(seen, `{rejection.channel}/{rejection.stage}/{rejection.reason}`)
	end)

	--[[ An observer that throws must not take the batch with it. That is G4 applied to the
	     mechanism that reports G4. ]]
	nw.observe(function()
		error("an observer that misbehaves")
	end)

	local tail: { number } = {}
	nw.observe(function(rejection)
		table.insert(tail, rejection.bytes)
	end)

	Observer.emit("combat.fireWeapon", nil, "authorize", "origin detached", 12)

	equals("the observer saw the rejection", seen[1], "combat.fireWeapon/authorize/origin detached")
	equals("a throwing observer does not stop the next one", tail[1], 12)

	stop()
	Observer.emit("combat.fireWeapon", nil, "parse", "truncated", 3)
	equals("a stopped observer sees nothing more", #seen, 1)
	equals("but the others still do", #tail, 2)

	Observer.reset()
end

-- ---------------------------------------------------------------------------------------------
-- Namespaces and ids
-- ---------------------------------------------------------------------------------------------

do
	Namespace.reset()

	local combat = nw.namespace("combat", {
		fireWeapon = nw.command({
			data = t.struct({ origin = t.vector3, seq = t.u16 }),
			rate = 20,
			authorize = alwaysAllows,
		}),

		aim = nw.intent({
			data = t.struct({ pitch = t.f32(-90, 90), yaw = t.f32(-180, 180) }),
			rate = 60,
		}),

		openedMenu = nw.signal({
			data = t.struct({ screen = t.u8(0, 8) }),
			rate = 2,
		}),

		getLoadout = nw.query({
			args = t.u8(0, 2),
			returns = t.struct({ primary = t.u16, secondary = t.u16 }),
			rate = 2,
			timeout = 5,
			authorize = alwaysAllows,
		}),

		playerState = nw.state({
			data = t.struct({ entityId = t.u16, grounded = t.boolean }),
			audience = nw.audience.nearby(120),
		}),

		roundOver = nw.event({
			data = t.struct({ winner = t.u16 }),
			audience = nw.audience.everyone,
		}),
	})

	check("the server view exists", combat.server ~= nil)
	check("the client view exists", combat.client ~= nil)

	local server: any = combat.server
	local client: any = combat.client

	check("a command listens on the server", type(server.fireWeapon.listen) == "function")
	check("and does not send there", server.fireWeapon.send == nil)
	check("a command sends on the client", type(client.fireWeapon.send) == "function")
	check("and does not listen there", client.fireWeapon.listen == nil)

	check("a query handles on the server", type(server.getLoadout.handle) == "function")
	check("and invokes on the client", type(client.getLoadout.invoke) == "function")

	check("a state publishes on the server", type(server.playerState.publish) == "function")
	check("and listens on the client", type(client.playerState.listen) == "function")

	--[[ G3 at runtime as well as in the type: `nearby` gets no broadcast, `everyone` does. The
	     type is the guarantee, but a `broadcast` that existed here and errored would mean the
	     type and the object disagree. ]]
	check("a scoped audience has no broadcast", server.playerState.broadcast == nil)
	check("an everyone audience has one", type(server.roundOver.broadcast) == "function")

	local ids: { [string]: number } = {}

	for key, channel in combat.channels :: any do
		equals(`{key} is qualified`, channel.qualified, `combat.{key}`)
		ids[channel.qualified] = channel.id
	end

	--[[ Ids are unassigned until the protocol is sealed, because an id depends on every channel in
	     the program (`WIRE-FORMAT.md` §3). Zero is reserved for control traffic and doubles as
	     "not yet". ]]
	equals("ids are unassigned before sealing", ids["combat.fireWeapon"], 0)

	local protocol = nw.protocol()
	equals("every channel is numbered", protocol.count, 6)

	local expected = {
		"combat.aim",
		"combat.fireWeapon",
		"combat.getLoadout",
		"combat.openedMenu",
		"combat.playerState",
		"combat.roundOver",
	}

	for index, qualified in expected do
		equals(`id {index} is {qualified}`, protocol.names[index], qualified)
		equals(`{qualified} carries id {index}`, (combat.channels :: any)[string.sub(qualified, 8)].id, index)
	end

	--[[ Sorted, never iterated. ByteNet numbers by walking its declaration table, and this project
	     hit the resulting silent mis-decode during M0 phase 3. ]]
	check("the hash is a 32-bit number", protocol.hash >= 0 and protocol.hash < 2 ^ 32)
	equals("sealing twice returns the same protocol", nw.protocol(), protocol)
end

do
	--[[ The hash exists to catch a stale peer. If two different declaration sets hashed the same,
	     it would catch nothing. ]]
	Namespace.reset()
	nw.namespace("a", { one = nw.signal({ data = t.u8, rate = 1 }) })
	local first = nw.protocol().hash

	Namespace.reset()
	nw.namespace("a", { two = nw.signal({ data = t.u8, rate = 1 }) })
	local second = nw.protocol().hash

	check("a different channel set hashes differently", first ~= second)

	Namespace.reset()
	nw.namespace("a", { one = nw.signal({ data = t.u8, rate = 1 }) })
	equals("the same declaration hashes the same", nw.protocol().hash, first)
end

do
	Namespace.reset()

	refuses("a namespace with a dot in its name", function()
		nw.namespace("a.b", { one = nw.signal({ data = t.u8, rate = 1 }) })
	end, "dot")

	refuses("a namespace with no channels", function()
		nw.namespace("empty", {})
	end, "no channels")

	--[[ Through `any`, because the type functions refuse this at analysis time. What is under test
	     is the runtime guard, which still has to hold in a build where the solver was bypassed. ]]
	refuses("a namespace holding something that is not a channel", function()
		(nw.namespace :: any)("bad", { one = t.u8 })
	end, "not a channel")

	nw.namespace("taken", { one = nw.signal({ data = t.u8, rate = 1 }) })

	refuses("a namespace declared twice", function()
		nw.namespace("taken", { one = nw.signal({ data = t.u8, rate = 1 }) })
	end, "already declared")

	--[[ Sharing a channel record across namespaces would give it two ids and two budgets, and the
	     second would silently win. ]]
	local shared = nw.signal({ data = t.u8, rate = 1 })
	nw.namespace("first", { one = shared })

	refuses("a channel reused in a second namespace", function()
		nw.namespace("second", { one = shared })
	end, "already declared as")

	nw.protocol()

	refuses("a namespace declared after sealing", function()
		nw.namespace("late", { one = nw.signal({ data = t.u8, rate = 1 }) })
	end, "sealed")
end

-- ---------------------------------------------------------------------------------------------
-- Handlers and the transport seam
-- ---------------------------------------------------------------------------------------------

do
	Namespace.reset()

	--[[ Whatever was installed goes back at the end. In a place where the real transport is running
	     — the benchmark runs this suite and the matrix in one session — leaving it uninstalled would
	     send everything after this file into a hole. ]]
	local previous = Transport.peek()
	Transport.uninstall()

	local ns = nw.namespace("handlers", {
		ping = nw.signal({ data = t.u8, rate = 4 }),
		blast = nw.event({ data = t.u8, audience = nw.audience.everyone }),
	})

	local server: any = ns.server
	local client: any = ns.client

	server.ping:listen(function() end)
	equals("listen attaches the handler", type((ns.channels :: any).ping.handler), "function")

	refuses("a second handler on one channel", function()
		server.ping:listen(function() end)
	end, "already has a handler")

	refuses("a handler that is not a function", function()
		client.blast:listen(42)
	end, "takes the function that runs per packet")

	--[[ A `send` that silently did nothing would make this file pass and every integration fail in a
	     way that looks like packet loss.

	     ~~The message named the milestone that would land the transport.~~ It named M1 and M2 until
	     M3 phase 7, which was true when it was written and a lie once the transport shipped; what is
	     left is the case that can still reach it — netweave required where `game` does not exist. ]]
	refuses("sending with no transport installed", function()
		client.ping:send(1)
	end, "needs a transport")

	refuses("broadcasting with no transport installed", function()
		server.blast:broadcast(1)
	end, "Transport.install")

	local sent: { any } = {}

	Transport.install({
		send = function(channel: any, value: any)
			table.insert(sent, `{channel.qualified}={value}`)
		end,
		publish = function() end,
		broadcast = function() end,
		invoke = function(): (any?, string?)
			return nil, "not implemented"
		end,
		dispatch = function() end,
	})

	client.ping:send(9)
	equals("an installed transport receives the send", sent[1], "handlers.ping=9")

	refuses("installing a second transport", function()
		Transport.install(nil :: any)
	end, "already installed")

	Transport.uninstall()

	if previous then
		Transport.install(previous)
	end
end

-- ---------------------------------------------------------------------------------------------
-- validate
-- ---------------------------------------------------------------------------------------------

do
	local Settings = t.struct({
		volume = t.u8(0, 100),
		name = t.string(1, 16),
		muted = t.boolean,
	})

	local value, failure = nw.validate(Settings, { volume = 40, name = "vaxze", muted = false })
	equals("a conforming value validates", failure, nil)
	check("and is handed back", value ~= nil and (value :: any).volume == 40)

	local bad, reason = nw.validate(Settings, { volume = 400, name = "vaxze", muted = false })
	equals("an out-of-range value is refused", bad, nil)
	check("with a reason", reason ~= nil)

	local missing, missingReason = nw.validate(Settings, { volume = 40, muted = false })
	equals("a missing field is refused", missing, nil)
	check("with a reason", missingReason ~= nil)

	--[[ `validate` runs the encoder against a parked buffer. If it leaked, the next validation
	     would see the previous one's bytes and a schema with a fixed size would drift. ]]
	for _ = 1, 50 do
		local repeated = nw.validate(Settings, { volume = 1, name = "a", muted = true })
		check("repeated validation stays correct", repeated ~= nil)
	end

	local scalar, scalarFailure = nw.validate(t.u8(0, 10), 5)
	equals("a scalar schema validates", scalarFailure, nil)
	equals("and returns the value", scalar, 5)

	equals("a scalar out of range is refused", (nw.validate(t.u8(0, 10), 11)), nil)

	refuses("validating against something that is not a schema", function()
		(nw.validate :: any)({ volume = 1 }, 1)
	end, "netweave type")
end

--[[ The encoder is shared between `validate` and a channel's codec, so a validation must not
     disturb an encode in progress. This is the property that makes reusing the encoder safe. ]]
do
	local Buffer = require("../src/codec/Buffer")
	local Serdes = require("../src/codec/Serdes")

	local codec = Serdes.fromSchema(t.struct({ a = t.u8, b = t.u8 }))

	codec.write({ a = 1, b = 2 })
	nw.validate(t.struct({ x = t.u32, y = t.u32 }), { x = 9, y = 9 })
	codec.write({ a = 3, b = 4 })

	local packed = Buffer.take()
	equals("a validation between two writes leaves the buffer alone", buffer.len(packed), 4)
	equals("first byte", buffer.readu8(packed, 0), 1)
	equals("fourth byte", buffer.readu8(packed, 3), 4)
end

-- ---------------------------------------------------------------------------------------------

Namespace.reset()
Observer.reset()

-- ---------------------------------------------------------------------------------------------
-- Every channel carries a byte ceiling it did not have to ask for (PLAN-M3 D-5)
-- ---------------------------------------------------------------------------------------------

do
	local allows = nw.policy(function()
		return function()
			return nw.allow()
		end
	end)

	--[[ The point of deriving it: a game that declares nothing still gets a bound, because every
	     netweave type is bounded and the layout adds them up. `RESEARCH §3.7-F` records that no
	     surveyed library checks a payload size at all — they would have to ask the author for the
	     number, and here the schema already knows it. ]]
	local tight = nw.command({
		data = t.struct({ origin = t.vector3, seq = t.u16 }),
		rate = 20,
		authorize = allows,
	}) :: any

	equals("a tight schema derives an exact ceiling", tight.maxBytes, 14)

	local loose = nw.command({ data = t.array(t.u8), rate = 20, authorize = allows }) :: any

	equals("an unbounded array derives the most its prefix can express", loose.maxBytes, 65537)

	--[[ The case a declaration is for: the type allows sixty-four kilobytes because the array has
	     no bound, and the game never sends more than three hundred. Declaring the smaller number
	     turns a theoretical ceiling into a real one. ]]
	local tightened = nw.command({
		data = t.array(t.u8),
		rate = 20,
		maxBytes = 300,
		authorize = allows,
	}) :: any

	equals("a declaration tightens it", tightened.maxBytes, 300)

	--[[ Fourteen bytes every time, and a ceiling of four is *below* that — so the upper-bound check
	     does not catch it. It is inert for a different reason: a static payload carries no length
	     prefix, so there is no claim to check and the ceiling is never consulted. Accepted and
	     silently ignored until an audit found it. ]]
	refuses("a ceiling on a statically framed channel", function()
		nw.command({
			data = t.struct({ origin = t.vector3, seq = t.u16 }),
			rate = 20,
			maxBytes = 4,
			authorize = allows,
		})
	end)

	--[[ The upper bound, on a schema where the check does run. Found by audit: the lower form of
	     the same mistake — a ceiling below what a static schema always sends — was accepted and then
	     never consulted, so the author had a limit that did nothing. ]]
	refuses("a ceiling above what a counted schema can reach", function()
		nw.command({ data = t.array(t.u8, 0, 10), rate = 20, maxBytes = 5000, authorize = allows })
	end)

	refuses("a fractional ceiling", function()
		nw.command({ data = t.array(t.u8), rate = 20, maxBytes = 12.5, authorize = allows })
	end)

	refuses("a ceiling of zero", function()
		nw.command({ data = t.array(t.u8), rate = 20, maxBytes = 0, authorize = allows })
	end)

	--[[ `maxBytes` on an outbound class is a type error, so its case lives in
	     `tests/api_reject.luau` where a file is allowed to fail analysis. ]]
end

if failures > 0 then
	error(`{failures} api assertions failed`)
end

print("OK      api_runtime")

return true
