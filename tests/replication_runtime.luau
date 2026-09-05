--!strict

--[[
	Replication end to end, under lune.

		lune run tests/replication_runtime

	Two peers in one process, the way `tests/query_runtime.luau` does it: the server's `Outbound`
	writes into a queue the client's `Inbound` reads from, so a change goes out over the real
	envelope, through the real ceiling, and is folded into a real baseline on the other side. None
	of that needs Roblox.

	The tick is the real one. What the driver supplies and this file stands in for is only the
	frame: `Tick.new` is handed an outbound, a baseline store, a roster and the channel list, and
	called by hand instead of by `PostSimulation`.

	What is asserted throughout is **the client's view against the server's store**, never the
	packet shape that got it there. A replication layer that is correct only when you know which
	packet it chose is not correct.
]]

local Baseline = require("../src/replication/Baseline")
local Buffer = require("../src/codec/Buffer")
local Config = require("../src/api/Config")
local Inbound = require("../src/transport/Inbound")
local Link = require("../src/transport/Link")
local Namespace = require("../src/api/Namespace")
local Observer = require("../src/api/Observer")
local Outbound = require("../src/transport/Outbound")
local Recipients = require("../src/transport/Recipients")
local Tick = require("../src/replication/Tick")
local nw = require("../src/netweave")
local t = require("../src/types")

local harness = require("./harness")

local suite = harness.suite("replication_runtime", 0.3)
local check, equals = suite.check, suite.equals

-- ---------------------------------------------------------------------------------------------

local alice = { name = "alice" }
local bob = { name = "bob" }

--[[ The world the game owns. netweave reads it and never writes it. ]]
local world: { [number]: any } = {}

--[[ Who can see what, standing in for `nw.audience.nearby` — moving a player in or out of a
     subject's audience is one assignment here, where in a game it is a position. ]]
local visible: { [number]: { [any]: boolean } } = {}

local declared = Namespace.declare("game", {
	entities = nw.replicate({
		subject = t.u16,
		data = t.struct({
			hp = t.u8,
			gold = t.u16,
			pos = t.struct({ x = t.u8, y = t.u8 }),
			tag = t.optional(t.u8),
		}),

		--[[ `select` hands the decision back to the game, which is what lets this file move a
		     player in and out of an audience without a position or a `Vector3`. ]]
		audience = nw.audience.select(function(subject: any): { any }
			local seen = visible[subject]
			local out = {}

			for _, who in { alice, bob } do
				if seen and seen[who] then
					table.insert(out, who)
				end
			end

			return out
		end),

		store = nw.store.of(world),
	}),
})

Namespace.seal()

local channel = declared.channels.entities :: any

local function channelById(id: number): any?
	return if id == channel.id then channel else nil
end

-- ---------------------------------------------------------------------------------------------
-- The two peers
-- ---------------------------------------------------------------------------------------------

type Frame = { packed: buffer, instances: { any }, to: any }

local toClient: { Frame } = {}
local toServer: { Frame } = {}
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

local serverOut = Outbound.new(linkInto(toClient), roster)
local clientOut = Outbound.new(linkInto(toServer), roster)

local serverBaselines = Baseline.new(true)

--[[
	**Two clients, each with its own everything**, and the first draft of this file had one.

	With one, every packet in the outgoing queue was fed to it regardless of who it was addressed
	to — so a client that had been told a subject was gone was handed the *other* client's copy of
	it on the next frame and looked correct. The rig asserted nothing about audiences, which is half
	of what this milestone is.

	`mirror` is what the game on that client ended up with, built only from what its handler was
	told, so asserting on it is asserting what a player sees.
]]
type Peer = {
	who: any,
	inbound: Inbound.Inbound,
	baselines: Baseline.Baseline,
	mirror: { [number]: any },
	resyncs: number,
}

local peers: { [any]: Peer } = {}
local receiving: Peer

--[[ One handler for the channel, reading which client it is running for off `receiving`. A real
     game has one client per process and no such indirection; two peers in one process is the test
     artefact, and this is where it is paid for. ]]
channel.handler = function(subject: number, value: any)
	receiving.mirror[subject] = value
end

local function peerFor(who: any): Peer
	local peer: Peer = {
		who = who,
		inbound = nil :: any,
		baselines = Baseline.new(false),
		mirror = {},
		resyncs = 0,
	}

	peer.inbound = Inbound.new({
		resolve = channelById,

		admit = function(): string?
			return nil
		end,

		isServer = false,
		baselines = peer.baselines,

		desynced = function(lost: any)
			peer.resyncs += 1
			clientOut.resync(lost)
		end,
	})

	peers[who] = peer
	return peer
end

peerFor(alice)
peerFor(bob)

local serverIn = Inbound.new({
	resolve = channelById,

	admit = function(): string?
		return nil
	end,

	isServer = true,
	baselines = serverBaselines,
})

local tick = Tick.new({
	outbound = serverOut,
	baselines = serverBaselines,
	roster = roster,
	channels = function()
		return { channel }
	end,
})

--[[ One frame, in the order `Driver` runs it: the tick fills the outgoing batches, the flush sends
     them, the client reads and dispatches, and anything the client sent back goes the other way.
     Returns how many bytes reached the client. ]]
local function frame(): number
	tick()
	serverOut.flush()

	local bytes = 0

	table.clear(carried)
	table.move(toClient, 1, #toClient, 1, carried)
	table.clear(toClient)

	for _, sent in carried do
		--[[ Routed by who it was addressed to. Feeding every packet to every client is what the
		     first draft did, and it made an audience test pass by accident. ]]
		local peer = peers[sent.to]

		if peer then
			bytes += buffer.len(sent.packed)
			receiving = peer
			peer.inbound.receive(sent.packed, sent.instances, nil)
			peer.inbound.tick()
		end
	end

	--[[ The client's own upstream — only a resync, and only from whoever asked. Attributed to alice
	     because she is the one whose refusals this file provokes. ]]
	clientOut.flush()

	table.clear(carried)
	table.move(toServer, 1, #toServer, 1, carried)
	table.clear(toServer)

	for _, sent in carried do
		serverIn.receive(sent.packed, sent.instances, alice)
	end

	return bytes
end

local function mirrorOf(who: any): { [number]: any }
	return peers[who].mirror
end

local function sees(subject: number, ...: any)
	local seen: { [any]: boolean } = {}

	for _, who in { ... } do
		seen[who] = true
	end

	visible[subject] = seen
end

local function agrees(who: any, subject: number): boolean
	local truth = world[subject]
	local seen = mirrorOf(who)[subject]

	if truth == nil or seen == nil then
		return truth == seen
	end

	return truth.hp == seen.hp
		and truth.gold == seen.gold
		and truth.pos.x == seen.pos.x
		and truth.pos.y == seen.pos.y
		and truth.tag == seen.tag
end

-- ---------------------------------------------------------------------------------------------
-- A subject arriving, changing, and not changing
-- ---------------------------------------------------------------------------------------------

suite.passing()

do
	world[1] = { hp = 10, gold = 500, pos = { x = 1, y = 1 }, tag = nil }
	sees(1, alice)

	local first = frame()
	check("a client with no baseline is correct after one frame", agrees(alice, 1))
	check(`and it cost {first} bytes`, first > 0)

	--[[ One field. The whole point of the milestone, over the real wire. ]]
	world[1] = { hp = 7, gold = 500, pos = { x = 1, y = 1 }, tag = nil }
	local second = frame()

	check("a change arrives", agrees(alice, 1))
	equals("with the field that moved", mirrorOf(alice)[1].hp, 7)
	check(`and {second} bytes is less than the {first} the arrival cost`, second < first)

	--[[ Nothing moved. Not an empty packet — no packet. ]]
	local third = frame()
	equals("an unchanged frame sends nothing at all", third, 0)
	check("and the client is still correct", agrees(alice, 1))

	--[[ Mutating in place rather than replacing, which is what a game using ReplicaService does —
	     `Replica.Data.hp = 4` and nothing else. The diff has to notice. ]]
	world[1].pos.x = 9
	frame()

	equals("an in-place mutation arrives", mirrorOf(alice)[1].pos.x, 9)
	check("and nothing else moved with it", agrees(alice, 1))
end

-- ---------------------------------------------------------------------------------------------
-- Two clients, two baselines
-- ---------------------------------------------------------------------------------------------

do
	--[[ Bob walks in. He has never seen this subject, so he is sent all of it in the same frame
	     alice is sent nothing — which only works because the baseline is per client. ]]
	equals("the second client has seen nothing yet", mirrorOf(bob)[1], nil)

	sees(1, alice, bob)
	local arrival = frame()

	check("the arriving client is correct", agrees(bob, 1))
	check("and it cost more than a change would have", arrival > 0)
	check("the one already there is still correct", agrees(alice, 1))

	--[[ The frame that arrived for bob sent alice nothing, because her baseline was already right.
	     Two clients, two baselines, one tick — which is the whole reason the store is per client. ]]
	equals("and was sent nothing itself", mirrorOf(alice)[1].pos.x, 9)

	world[1] = { hp = 4, gold = 501, pos = { x = 9, y = 1 }, tag = 3 }
	frame()

	check("and both track the next change", agrees(alice, 1))
	check("both of them", agrees(bob, 1))
	equals("including an optional arriving", mirrorOf(alice)[1].tag, 3)
	equals("on both", mirrorOf(bob)[1].tag, 3)
end

-- ---------------------------------------------------------------------------------------------
-- Leaving, which is the case with nothing on the wire to say it until the root bit
-- ---------------------------------------------------------------------------------------------

suite.failing()

do
	--[[
		Alice walks out. `PLAN-M4` D-4: a client leaving is *told to forget*, and this is the
		assertion that the telling happens — without it the subject would sit on her client at
		whatever value it had, forever, and neither side would know.

		The mirror is what a player sees, so asserting on it rather than on the baseline is
		asserting the thing that matters.
	]]
	sees(1, bob)
	frame()

	equals("a client that left is told the subject is gone", mirrorOf(alice)[1], nil)
	equals("and the server stops remembering", serverBaselines.of(alice, channel, 1), nil)
	equals("as does the client", peers[alice].baselines.of(nil, channel, 1), nil)
	check("while the client that stayed is untouched", agrees(bob, 1))

	--[[ The subject keeps moving while she is away, and none of it reaches her. ]]
	world[1] = { hp = 1, gold = 1, pos = { x = 2, y = 2 }, tag = nil }
	frame()
	equals("and nothing reaches her while she is away", mirrorOf(alice)[1], nil)
	check("while the one who stayed keeps tracking it", agrees(bob, 1))

	--[[ Back in. If the departure had not cleared both sides, this would patch against a value
	     neither has and she would be wrong for the session — silently. ]]
	sees(1, alice, bob)
	frame()

	check("re-entering is correct", agrees(alice, 1))
	equals("with the value as it is now", mirrorOf(alice)[1].hp, 1)
end

do
	--[[ A subject the store stops listing at all — a destroyed replica, a key removed. The tick
	     cannot see it in `subjects()`, so it is found by what was there last frame. ]]
	world[2] = { hp = 3, gold = 3, pos = { x = 3, y = 3 }, tag = nil }
	sees(2, alice)
	frame()

	check("a second subject arrives", agrees(alice, 2))

	world[2] = nil
	frame()

	equals("and a destroyed one is taken off the client", mirrorOf(alice)[2], nil)
	equals("with the server forgetting it too", serverBaselines.of(alice, channel, 2), nil)
	check("while the subject beside it is untouched", agrees(alice, 1))

	--[[ Once, not every frame. A removal that repeats would cost a packet per gone subject per
	     frame for the life of the server. ]]
	local after = frame()
	equals("and it is not said twice", after, 0)
end

-- ---------------------------------------------------------------------------------------------
-- A change that does not arrive, which is the one failure this class cannot absorb
-- ---------------------------------------------------------------------------------------------

do
	Observer.reset()
	Observer.setSink(function() end)

	peers[alice].resyncs = 0

	--[[
		A change that did not arrive whole is every later change made unreadable, because each one is
		relative to a value the client no longer has. So the client notices — it is the endpoint that
		refused the packet — clears the channel, and asks for it again. `PLAN-M4` D-2 expected a
		sequence number on the wire to find the gap; there is none, because the gap does not have to
		be found.

		~~Provoked with `pendingPerBatch = 1`.~~ **That stopped being reachable in M4 phase 8**: the
		pending ceiling is the server's, because the batch's size is only chosen by an untrusted peer
		when the peer is a client, and applying it here was a livelock at 257 subjects (the section
		below). It was also the wrong provocation for this class — it set a limit no game runs, took
		one frame, and then removed the limit before asserting the recovery.

		The packet is damaged instead, which is what the failure looks like in a game: a change whose
		bytes did not all arrive. Truncation rather than a flipped bit, because a flipped bit may
		decode into a different valid value and this section is about the case that cannot.
	]]
	world[3] = { hp = 5, gold = 5, pos = { x = 5, y = 5 }, tag = nil }
	world[4] = { hp = 6, gold = 6, pos = { x = 6, y = 6 }, tag = nil }
	sees(3, alice)
	sees(4, alice)

	tick()
	serverOut.flush()

	local damaged = 0

	table.clear(carried)
	table.move(toClient, 1, #toClient, 1, carried)
	table.clear(toClient)

	for _, sent in carried do
		if peers[sent.to] == peers[alice] then
			--[[ Half the bytes, so the batch's first packet is intact and whatever follows it runs
			     off the end. ]]
			local half = buffer.create(math.floor(buffer.len(sent.packed) / 2))
			buffer.copy(half, 0, sent.packed, 0, buffer.len(half))
			damaged += 1

			receiving = peers[alice]
			peers[alice].inbound.receive(half, sent.instances, nil)
			peers[alice].inbound.tick()
		end
	end

	clientOut.flush()

	table.clear(carried)
	table.move(toServer, 1, #toServer, 1, carried)
	table.clear(toServer)

	for _, sent in carried do
		serverIn.receive(sent.packed, sent.instances, alice)
	end

	equals("the client was sent something", damaged, 1)
	check("something was refused", peers[alice].resyncs > 0)

	--[[ The resync went out and the server cleared what it believed. The next frame therefore
	     sends both in full, and the client is correct again — without the game having noticed
	     anything beyond a late value. ]]
	frame()
	frame()

	check("the first subject is correct again", agrees(alice, 3))
	check("and so is the second", agrees(alice, 4))

	Observer.reset()
end

-- ---------------------------------------------------------------------------------------------
-- More subjects than a batch may hold, at the limits a game actually runs
-- ---------------------------------------------------------------------------------------------

suite.passing()

do
	--[[
		**The section above is one frame away from this one, and that is why it passed.**

		It sets `pendingPerBatch = 1`, takes one frame, and then calls `Config.reset()`. The recovery
		it asserts is therefore a recovery *with the limit gone*. A game does not get to remove the
		limit: it is 256 by default and it is 256 on the frame after the refusal too.

		With it in force on the client the channel never converges. The client refuses past the
		ceiling, a refused change gives up the channel, giving up clears the baselines applied
		earlier in the same batch, the resync makes the server clear what it believed, and the next
		tick sends the same oversized batch. Measured before the fix, with the real tick and the
		default limits: 257 subjects → 1,543 bytes down and 5 up **every frame**, mirror stuck at
		256, both sides ending each frame holding nothing; 300 subjects → 1,801 down, 177 up, 44
		refusals and 44 resyncs a frame, forever. One subject over the limit was a channel that never
		worked.

		The fix is that the ceiling is the *server's*: the batch's size is chosen by an untrusted peer
		only when the peer is a client (`src/transport/Inbound.luau`, `refreshCeiling`).

		This section runs at the **default** configuration for that reason. It is the one thing the
		file was not doing.
	]]
	local COUNT = 300
	local before = peers[alice].resyncs

	--[[
		`pendingPerBatch` stays at its default — it is the limit under test. `baselinesPerClient` is
		raised because it is a *different* limit with a defect of its own: past it the tick re-sends
		the whole subject every frame with nothing changing, deep-clones it, throws the clone away
		and reports. Both defaults are 256, so any count that exercises the batch ceiling also
		exercises the baseline ceiling, and leaving them tangled would have this section fail for the
		other one's reason.

		That defect is real and is filed as its own finding; what it is not is this section's
		subject. Raising it is how the two are told apart.
	]]
	Config.configure({ limits = { baselinesPerClient = 1024 } })

	for subject = 100, 100 + COUNT - 1 do
		world[subject] = { hp = 1, gold = 2, pos = { x = 3, y = 4 }, tag = nil }
		sees(subject, alice)
	end

	equals("the limit this runs against is the shipped one", Config.limitOf("pendingPerBatch"), 256)

	frame()

	local arrived = 0

	for subject = 100, 100 + COUNT - 1 do
		if agrees(alice, subject) then
			arrived += 1
		end
	end

	equals(`all {COUNT} subjects arrive in the frame that sent them`, arrived, COUNT)
	equals("and nothing was given up on", peers[alice].resyncs, before)

	--[[ And it stays converged. The livelock's signature was a frame that never went quiet, so the
	     assertion that names it is a second frame carrying no change for a world that did not
	     move. ]]
	local settled = frame()

	equals("a frame that changed nothing sends no change", settled, 0)
	equals("still nothing given up on", peers[alice].resyncs, before)

	for subject = 100, 100 + COUNT - 1 do
		world[subject] = nil
		visible[subject] = nil
	end

	frame()
	Config.reset()
end

-- ---------------------------------------------------------------------------------------------

channel.handler = nil
Namespace.reset()
Buffer.take()
Buffer.load(nil)

suite.finish()

return true
