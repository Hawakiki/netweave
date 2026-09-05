--!strict

--[[
	Baselines, under lune.

		lune run tests/baseline_runtime

	What each client already has is the piece neither Charm nor Replica holds, and it is memory
	sized by how many people join — so most of this file is the three ways it has to stop existing:
	a subject leaving an audience, a client leaving the game, and a limit saying no.

	The last section is `PLAN-M4` D-4, moved here from phase 2 because it needed baselines to exist.
	A subject walks in and out of a `nearby` radius while its state changes, and the client's view
	is checked at every step — including that **a join, a netweave-side drop and an audience entry
	all take the same path**, because if they did not there would be three chances to get one of
	them wrong.
]]

local Baseline = require("../src/replication/Baseline")
local Buffer = require("../src/codec/Buffer")
local Config = require("../src/api/Config")
local Delta = require("../src/replication/Delta")
local Ir = require("../src/codec/Ir")
local Observer = require("../src/api/Observer")
local harness = require("./harness")
local t = require("../src/types")

local suite = harness.suite("baseline_runtime", 0.5)
local check, equals = suite.check, suite.equals

local alice = { name = "alice" }
local bob = { name = "bob" }

local function channelOf(name: string): any
	return { qualified = name }
end

local combat = channelOf("game.combat")
local inventory = channelOf("game.inventory")

local reported: { string } = {}

local function watch()
	table.clear(reported)
	Observer.reset()
	Observer.setSink(function() end)
	Observer.observe(function(rejection)
		table.insert(reported, `{rejection.stage}:{rejection.channel}`)
	end)
end

-- ---------------------------------------------------------------------------------------------
-- What it holds, and for whom
-- ---------------------------------------------------------------------------------------------

suite.passing()

do
	local store = Baseline.new()

	equals("nothing is held to begin with", store.held(alice), 0)
	equals("and nothing is remembered", store.of(alice, combat, "sword"), nil)

	check("a first baseline is kept", store.keep(alice, combat, "sword", { hp = 10 }))
	equals("and comes back", store.of(alice, combat, "sword").hp, 10)
	equals("counted once", store.held(alice), 1)

	--[[ Replacing is the common case and must not count twice, or the limit would be reached by a
	     single subject that keeps changing. ]]
	check("replacing it is kept too", store.keep(alice, combat, "sword", { hp = 4 }))
	equals("with the new value", store.of(alice, combat, "sword").hp, 4)
	equals("and still counted once", store.held(alice), 1)

	--[[ The same subject name on two channels is two baselines, because a subject is only a subject
	     within the channel that replicates it. ]]
	check("the same name on another channel is its own", store.keep(alice, inventory, "sword", { n = 1 }))
	equals("counted separately", store.held(alice), 2)
	equals("and does not shadow", store.of(alice, combat, "sword").hp, 4)

	--[[ And two clients do not share one. This is the whole reason the store is per client: bob
	     walking into a radius must not inherit what alice has already seen. ]]
	equals("another client has nothing", store.of(bob, combat, "sword"), nil)
	equals("and is counted from zero", store.held(bob), 0)
end

-- ---------------------------------------------------------------------------------------------
-- The three ways a baseline stops existing
-- ---------------------------------------------------------------------------------------------

suite.failing()

do
	local store = Baseline.new()

	store.keep(alice, combat, "sword", { hp = 1 })
	store.keep(alice, combat, "shield", { hp = 2 })
	store.keep(alice, inventory, "gold", { n = 3 })

	--[[ A subject left this client's audience. ]]
	store.drop(alice, combat, "sword")
	equals("a dropped subject is gone", store.of(alice, combat, "sword"), nil)
	equals("and uncounted", store.held(alice), 2)
	equals("its neighbour is untouched", store.of(alice, combat, "shield").hp, 2)

	--[[ Dropping the same one twice must not double-count, or the limit drifts down until a
	     healthy game is refused. ]]
	store.drop(alice, combat, "sword")
	equals("dropping it again changes nothing", store.held(alice), 2)

	--[[ A resync: everything this client had on one channel. ]]
	store.desync(alice, combat)
	equals("the channel is cleared", store.of(alice, combat, "shield"), nil)
	equals("and its count released", store.held(alice), 1)
	equals("the other channel survives", store.of(alice, inventory, "gold").n, 3)

	store.desync(alice, combat)
	equals("desyncing an empty channel changes nothing", store.held(alice), 1)
end

do
	--[[
		A client left, tested the way `PLAN-M3` tested the queued packets it forgot: interleaved
		subjects, one departure, assert nothing of theirs survives and nothing of anyone else's
		went with it. It is the same defect in a different table — state that outlives the
		connection that justified it.
	]]
	local store = Baseline.new()

	for index = 1, 4 do
		store.keep(alice, combat, `a{index}`, { n = index })
		store.keep(bob, combat, `b{index}`, { n = index })
	end

	equals("both clients are holding", store.held(alice), 4)
	equals("both of them", store.held(bob), 4)

	store.forget(alice)

	equals("the one who left holds nothing", store.held(alice), 0)
	equals("and remembers nothing", store.of(alice, combat, "a1"), nil)
	equals("the one who stayed is untouched", store.held(bob), 4)
	equals("and still remembers", store.of(bob, combat, "b3").n, 3)

	--[[ Rejoining is a fresh client as far as this is concerned, which is what makes a departed
	     player's baseline unable to be inherited by whoever the table key is reused for. ]]
	check("and can start again from nothing", store.keep(alice, combat, "a1", { n = 9 }))
	equals("counted from zero", store.held(alice), 1)
end

do
	local store = Baseline.new()
	watch()

	Config.configure({ limits = { baselinesPerClient = 3 } })

	check("the first is kept", store.keep(alice, combat, "s1", 1))
	check("and the second", store.keep(alice, combat, "s2", 2))
	check("and the third", store.keep(alice, combat, "s3", 3))
	equals("nothing reported yet", #reported, 0)

	--[[ Past the limit netweave stops holding one, which means that subject is encoded and sent
	     **whole** to this client on every tick instead of as a change — correct and expensive, which
	     is the right way round for a bound to fail. ~~It degrades to what `nw.state` does for a
	     living.~~ It does not: `nw.state` sends when the game publishes, and this sends every tick
	     whether anything moved or not. Measured at 300 subjects against a limit of 256, with the
	     store untouched: 265 bytes an idle frame, for ever. ]]
	check("the fourth is refused", not store.keep(alice, combat, "s4", 4))
	equals("and said out loud", #reported, 1)
	equals("at the replicate stage", reported[1], "replicate:game.combat")
	equals("with nothing kept", store.of(alice, combat, "s4"), nil)
	equals("and the count unmoved", store.held(alice), 3)

	--[[
		**Once, not once per subject per tick.**

		The tick asks again for every over-limit subject on every frame, so the old code said this
		44 times a frame at 300 subjects — 2,640 reports a second describing one unchanging fact,
		which is a console nobody can read and an `nw.observe` nobody can aggregate. The condition is
		a state, so it is announced when the line is crossed and not while it stays crossed (M4
		report).
	]]
	for _ = 1, 20 do
		store.keep(alice, combat, "s5", 5)
		store.keep(alice, combat, "s6", 6)
	end

	equals("and forty more refusals say nothing further", #reported, 1)

	--[[ A second channel over the same client's budget is its own line to cross, because it is its
	     own bandwidth. ]]
	check("a different channel is refused too", not store.keep(alice, inventory, "s7", 7))
	equals("and says so once of its own", #reported, 2)

	--[[ The limit is per client, so it cannot be reached by a crowd. ]]
	check("another client is unaffected", store.keep(bob, combat, "s4", 4))

	--[[ An existing baseline is still replaceable at the limit, or a full store would freeze every
	     subject it already knew about. ]]
	check("and one already held can still be updated", store.keep(alice, combat, "s2", 22))
	equals("with the new value", store.of(alice, combat, "s2"), 22)

	--[[ Releasing one makes room, which is what makes the limit a ceiling rather than a latch. ]]
	store.drop(alice, combat, "s1")
	check("dropping one makes room", store.keep(alice, combat, "s4", 4))

	--[[ And going back under the line re-arms the announcement, so a game that crosses it a second
	     time is told a second time. A latch that never re-armed would report the *first* frame of a
	     session and nothing about the hour after it. ]]
	store.drop(alice, combat, "s2")
	equals("back under the line", store.held(alice), 2)

	check("and the room is usable", store.keep(alice, combat, "s9", 9))
	check("crossing it again is refused again", not store.keep(alice, combat, "s10", 10))
	equals("and said again, because it is a new crossing", #reported, 3)

	Config.reset()
	Observer.reset()
end

-- ---------------------------------------------------------------------------------------------
-- D-4: a subject moving in and out of an audience, with its state changing underneath
-- ---------------------------------------------------------------------------------------------

suite.passing()

do
	--[[
		The rig is one channel, one subject, two clients and a real codec. `sees` stands in for the
		audience — moving a player in or out is one assignment — and the tick does what `Outbound`
		will do in phase 5: for each client who can see the subject, send a snapshot if they have no
		baseline and a patch if they do.

		The assertion at every step is that the client's view equals the server's truth. Nothing
		about how it got there is asserted, because a replication layer that is correct only when
		you know which packet shape it chose is not correct.
	]]
	local schema = t.struct({ hp = t.u8, pos = t.struct({ x = t.u8, y = t.u8 }), tag = t.optional(t.u8) })
	--[[ One codec and one packet shape. A client with no baseline is sent a change against
	     `nil`, which writes every field and costs what a whole encode would have — so the rig has
	     no snapshot branch because the transport has none either (M4 phase 5b). ]]
	local delta = Delta.build(Ir.lower(schema))

	local store = Baseline.new()
	local channel = channelOf("game.moving")

	local truth: any = { hp = 10, pos = { x = 1, y = 1 }, tag = nil }
	local sees: { [any]: boolean } = { [alice] = true, [bob] = false }
	local views: { [any]: any } = {}

	--[[ Returns how many bytes went to each client, so the shape of the traffic can be checked
	     without the correctness assertions depending on it. ]]
	local function tick(): { [any]: number }
		local bytes: { [any]: number } = {}

		for _, who in { alice, bob } do
			if not sees[who] then
				--[[
					Out of the audience. D-4 says a client leaving is *told to forget*, so the rig
					models both halves: the client discards its view and the server discards the
					baseline that described it.

					Both or neither. Keeping the server's record while the client drops its value
					means the next entry patches against something nobody has, and the client is
					silently wrong for the rest of the session — which is the failure D-2 and D-4
					are one answer to. Removing `store.drop` below makes the re-entry assertions
					fail, which is the point of writing it this way round.
				]]
				views[who] = nil
				store.drop(who, channel, "subject")
				continue
			end

			local base = store.of(who, channel, "subject")

			Buffer.take()
			Buffer.load(nil)

			local sent = delta.write(base, truth)
			local packed = Buffer.take()
			bytes[who] = buffer.len(packed)

			if not sent then
				continue
			end

			Buffer.beginRead(packed, nil)
			views[who] = delta.apply(views[who])

			--[[ The server records what it just made true for this client, which is the same value
			     the client now holds. ]]
			store.keep(who, channel, "subject", truth)
		end

		return bytes
	end

	local function agrees(who: any): boolean
		local view = views[who]

		if view == nil then
			return false
		end

		return view.hp == truth.hp
			and view.pos.x == truth.pos.x
			and view.pos.y == truth.pos.y
			and view.tag == truth.tag
	end

	--[[ First tick: alice can see it and has nothing, so she gets the whole thing. ]]
	local first = tick()
	check("a client with no baseline is correct after one tick", agrees(alice))
	equals("and bob, who cannot see it, got nothing", first[bob], nil)

	--[[ Second tick, one field moved. ]]
	truth = { hp = 7, pos = truth.pos, tag = nil }
	local second = tick()
	check("a client with a baseline stays correct", agrees(alice))
	check("and paid less than the whole thing", (second[alice] :: number) < (first[alice] :: number))

	--[[ Nothing moved: no packet at all, which is the case a patch of nothing has to be rather than
	     an empty patch. ]]
	local third = tick()
	equals("an unchanged tick sends nothing", third[alice], 0)
	check("and the client is still correct", agrees(alice))

	--[[ Bob walks in. He has never seen this subject, so he is snapshotted while alice is
	     patched — the same tick, two packet shapes, decided by what each client has. ]]
	sees[bob] = true
	truth = { hp = 7, pos = { x = 2, y = 2 }, tag = 5 }
	local fourth = tick()

	check("the arriving client is correct immediately", agrees(bob))
	check("the one already there is still correct", agrees(alice))
	check("and the arrival cost more than the patch", (fourth[bob] :: number) > (fourth[alice] :: number))

	--[[ Bob walks out while the state keeps moving. ]]
	sees[bob] = false
	truth = { hp = 3, pos = { x = 9, y = 9 }, tag = nil }
	tick()

	equals("a client who left is not remembered", store.of(bob, channel, "subject"), nil)
	check("and the one who stayed tracked the change", agrees(alice))
	check("including the optional going away", views[alice].tag == nil)

	--[[
		And back in. If leaving had not dropped the baseline, this would patch against a value bob
		no longer has and he would be wrong for the rest of the session — silently, which is the
		failure D-2 and D-4 are the same answer to.

		`hp` is deliberately back at **7**, which is what bob's stale baseline held. A patch from
		that baseline would therefore leave `hp` out, and rebuilding from nothing would produce a
		view without it. Picking a value where *everything* differed would have reconstructed the
		whole subject by accident and asserted nothing — which is what the first draft of this case
		did, and removing `store.drop` still passed it.
	]]
	sees[bob] = true
	truth = { hp = 7, pos = { x = 9, y = 9 }, tag = 8 }
	tick()

	check("re-entering is correct", agrees(bob))
	check("and so is everyone else", agrees(alice))

	--[[ The third way into the same path: netweave dropped a packet on this channel, so what the
	     client has is unknown. `desync` is the whole mechanism, and it is the one `pendingPerBatch`
	     will reach for in phase 5. ]]
	store.desync(alice, channel)
	truth = { hp = 5, pos = { x = 9, y = 9 }, tag = 8 }
	local after = tick()

	check("a desynced client is correct again", agrees(alice))
	check("having been sent the whole thing", (after[alice] :: number) > (second[alice] :: number))

	Buffer.take()
	Buffer.load(nil)
end

suite.finish()

return true
