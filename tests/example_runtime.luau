--!strict

--[[
	The worked example, executed.

		lune run tests/example_runtime

	`docs/DESIGN-API.md` quotes the region between the markers below, and `tests/messages.luau`
	asserts the two are the same text. A document quoting code it does not run rots on the first
	rename; an example nobody can find is not an example. This is both halves at once.

	Everything above and below the region is the loopback that stands in for two Roblox peers —
	`src/transport/Link.luau` is where the real remotes live, and the point of that seam is that the
	example above it is the same code either way.
]]

local Baseline = require("../src/replication/Baseline")
local Budget = require("../src/transport/Budget")
local Inbound = require("../src/transport/Inbound")
local Link = require("../src/transport/Link")
local Namespace = require("../src/api/Namespace")
local Observer = require("../src/api/Observer")
local Outbound = require("../src/transport/Outbound")
local Recipients = require("../src/transport/Recipients")
local Tick = require("../src/replication/Tick")
local Transport = require("../src/api/Transport")
local harness = require("./harness")
local nw = require("../src/netweave")

local suite = harness.suite("example_runtime")
local check, equals = suite.check, suite.equals

-- ---------------------------------------------------------------------------------------------
-- Two peers, in one process
-- ---------------------------------------------------------------------------------------------

--[[ A player with a humanoid, because the example's first policy asks for one. Roblox supplies
     these; under lune the shape is all that matters. ]]
local alice: any = {
	Name = "alice",
	Character = {
		FindFirstChildOfClass = function(): any
			return { Health = 100 }
		end,
	},
}

--[[ `{ unknown }` on the way in: a frame is queued on the send side and delivered on the receive
     side, and the receive path is typed for what a peer may have put there (M4 report finding 50). ]]
type Frame = { packed: buffer, instances: { unknown } }

local toServer: { Frame } = {}
local toClient: { Frame } = {}
local carried: { Frame } = {}

local function linkInto(queue: { Frame }): Link.Link
	return {
		send = function(_reliable, _destination, packed, instances)
			table.insert(queue, { packed = packed, instances = instances :: { unknown } })
		end,

		sendAll = function(_reliable, packed, instances)
			table.insert(queue, { packed = packed, instances = instances :: { unknown } })
		end,

		receive = function() end,
	}
end

local roster: Recipients.Roster = {
	all = function()
		return { alice }
	end,

	owner = function(subject: any): any?
		return subject
	end,

	within = function(_subject: any, _studs: number, out: { any }): number
		out[1] = alice
		return 1
	end,
}

local clientOut = Outbound.new(linkInto(toServer), roster)
local serverOut = Outbound.new(linkInto(toClient), roster)

local at = 0
local budget = Budget.new(function(): number
	return at
end)

--[[ What each end believes the other has. Bounded on the server and not on the client, for the
     reason `Baseline.new` gives: the server's is memory sized by how many people join, and the
     client's is what the server already bounded at the other end. ]]
local serverBaselines = Baseline.new(true)
local clientBaselines = Baseline.new(false)

local serverIn = Inbound.new({
	resolve = Namespace.channelById,
	admit = budget.admit,
	isServer = true,
	baselines = serverBaselines,
})

local clientIn = Inbound.new({
	resolve = Namespace.channelById,
	admit = function(): string?
		return nil
	end,
	isServer = false,
	baselines = clientBaselines,
})

--[[ The replication loop, which `src/transport/Driver.luau` runs between the dispatch and the
     flush. Nothing in the example calls it: that is the point of the class. ]]
local replicate = Tick.new({
	outbound = serverOut,
	baselines = serverBaselines,
	roster = roster,
	channels = Namespace.replicated,
})

--[[ Whatever was installed goes back at the end. The benchmark place runs this suite and then the
     matrix in one session, so leaving it uninstalled would send everything after this file into a
     hole — the same reason `tests/api_runtime.luau` saves it. ]]
local previous = Transport.peek()

Transport.uninstall()
Transport.install({
	send = function(channel: any, value: any)
		Namespace.seal()
		clientOut.push(channel, Outbound.SERVER, value)
	end,

	publish = function(channel: any, subject: any, value: any)
		Namespace.seal()
		serverOut.publish(channel, subject, value)
	end,

	broadcast = function(channel: any, value: any)
		Namespace.seal()
		serverOut.broadcast(channel, value)
	end,

	invoke = function(): (any?, string?)
		return nil, "this example does not query"
	end,

	dispatch = function(channel: any)
		serverIn.drain(channel)
	end,
})

local function drain(queue: { Frame }, into: Inbound.Inbound, from: any?)
	table.clear(carried)
	table.move(queue, 1, #queue, 1, carried)
	table.clear(queue)

	for _, frame in carried do
		into.receive(frame.packed, frame.instances, from)
	end
end

--[[ One frame of the real driver, in the order `src/transport/Driver.luau` runs it. ]]
local function frame()
	clientOut.flush()
	drain(toServer, serverIn, alice)

	replicate()

	serverOut.flush()
	drain(toClient, clientIn, nil)
	clientIn.tick()
end

local refusals: { string } = {}
local equipped: { number } = {}
local held: { [number]: any } = {}

Namespace.reset()
Observer.reset()

-- ---------------------------------------------------------------------------------------------
-- The example
-- ---------------------------------------------------------------------------------------------

--#region example
--[[ One file, required by both sides. Everything a reviewer needs to know about this channel's
     security is on the line that declares it. ]]
local t = nw.types

local Equip = t.struct({ slot = t.u8(0, 9) })
type Equip = { slot: number }

local policy = {}

policy.alive = nw.policy(function()
	return function(ctx: nw.Ctx, _request: Equip)
		return ctx.humanoid ~= nil and nw.allow() or nw.deny("dead")
	end
end)

policy.ownsSlot = nw.policy(function(config)
	local slots: number = config.slots or 3

	return function(_ctx: nw.Ctx, request: Equip)
		if request.slot > slots then
			return nw.deny(`slot {request.slot} is past the {slots} this player owns`)
		end
		return nw.allow(request)
	end
end)

local combat = nw.namespace("combat", {
	equip = nw.command({
		data = Equip,
		rate = 5,
		authorize = nw.all(policy.alive, policy.ownsSlot({ slots = 3 })),
	}),

	loadout = nw.event({
		data = t.struct({ primary = t.u16 }),
		audience = nw.audience.owner,
	}),
})

--[[ The server. `chosen` is `Trusted<{ slot: number }>` — it decoded, it was inside the declared
     rate, and the policy allowed it. Nothing else in the process can produce that type by
     accident, which is what makes the annotation on an authoritative function worth writing. ]]
--[[ Nothing is annotated: `chosen` is `Trusted<Equip>` and `ctx.player` is the sender, both from
     the declaration (`DESIGN-API.md` §8 on why the player is `unknown`). ]]
combat.server.equip:listen(function(ctx, chosen)
	combat.server.loadout:publish(ctx.player, { primary = 100 + chosen.slot })
end)

combat.client.loadout:listen(function(loadout)
	equipped[#equipped + 1] = loadout.primary
end)

--[[ Every refusal, whether or not anything is listening. Attaching this replaces the default
     console output; detaching it does not make the refusals stop. ]]
nw.observe(function(rejection)
	refusals[#refusals + 1] = `{rejection.channel} at {rejection.stage}: {rejection.reason}`
end)
--#endregion

-- ---------------------------------------------------------------------------------------------
-- The replicated half
-- ---------------------------------------------------------------------------------------------

--#region replication
--[[ The server never calls this channel. `store` is the only way in, so there is no `publish` on
     the server view to be called by mistake — the absence is the guarantee. ]]
local world: { [number]: { hp: number, gold: number } } = {}

local vault = nw.namespace("vault", {
	inventory = nw.replicate({
		subject = t.u16,
		data = t.struct({ hp = t.u8, gold = t.u16 }),
		audience = nw.audience.everyone,
		store = nw.store.of(world),
	}),
})

--[[ The subject, then the value. `nil` is that subject leaving this client's audience or ceasing
     to exist — the one packet shape says both. ]]
vault.client.inventory:listen(function(subject, value)
	held[subject] = value
end)

--[[ The game writes its own state and tells netweave nothing. Once a frame netweave reads the
     store and sends each client the difference between what it should see and what it has: the
     first frame is the whole value, and a frame where one field moved is that field. ]]
world[1] = { hp = 10, gold = 500 }

--[[ Everything is declared before anything is sent, and that is a rule rather than a habit: a
     namespace declared after the first packet has moved raises, because an id depends on every
     other channel in the program (`WIRE-FORMAT.md` §3). ]]
combat.client.equip:send({ slot = 1 })
combat.client.equip:send({ slot = 7 })
--#endregion

-- ---------------------------------------------------------------------------------------------
-- What it does
-- ---------------------------------------------------------------------------------------------

frame()
frame()

suite.passing()

equals("the allowed command reached the handler and answered", #equipped, 1)
equals("with the loadout the server chose", equipped[1], 101)

suite.failing()

equals("the one the policy denied was refused", #refusals, 1)
check("at the authorize stage", string.find(refusals[1], "at authorize:", 1, true) ~= nil)
check("naming the channel", string.find(refusals[1], "combat.equip", 1, true) ~= nil)
check("and carrying the policy's own words", string.find(refusals[1], "past the 3", 1, true) ~= nil)

--[[ The refusal is the policy's, not the codec's: slot 7 is inside `t.u8(0, 9)` and decoded
     perfectly. That distinction is the example's whole point — the schema says what may arrive and
     the policy says who may ask for it, and a channel needs both. ]]
check("the denied packet decoded before it was refused", string.find(refusals[1], "parse", 1, true) == nil)

suite.passing()

--[[ And the declaration is the only place any of it is written down. ]]
local loadout: any = combat.channels.loadout

equals("the channel declares its own rate", combat.channels.equip.rate, 5)
--[[ `subset`, not `owner`: the scope is the singleton the *type* carries, and only `everyone` gets
     its own, because only `everyone` unlocks `broadcast`. Every narrower audience collapses to one
     tag, which is what keeps the type system from being asked to prove a list is complete. ]]
equals("and its audience is a subset rather than everyone", loadout.audience.scope, "subset")
check("so broadcast does not exist on it", (combat.server :: any).loadout.broadcast == nil)

-- ---------------------------------------------------------------------------------------------
-- And the replicated half
-- ---------------------------------------------------------------------------------------------

equals("the subject the store held reached the client", held[1].hp, 10)
equals("all of it", held[1].gold, 500)

--[[ One field, on a store the game mutated in place — which is what ReplicaService's whole API
     does, and what a baseline holding the store's own table would have made invisible. ]]
world[1].gold = 501
frame()

equals("a change reaches it", held[1].gold, 501)
equals("without disturbing the field beside it", held[1].hp, 10)

suite.failing()

--[[ `nil` is the subject ceasing to exist, and it is the same packet as a change — the patch's
     root bit says which. Without it a destroyed subject would sit on every client at whatever
     value it had, forever. ]]
world[1] = nil
frame()

equals("and a subject that went away is taken off it", held[1], nil)

--[[ The server never called this channel once. There is nothing on its view to call. ]]
check("the server view offers no way in", (vault.server :: any).inventory.publish == nil)
check("nor a broadcast", (vault.server :: any).inventory.broadcast == nil)

suite.passing()

-- ---------------------------------------------------------------------------------------------

Transport.uninstall()

if previous then
	Transport.install(previous)
end

Namespace.reset()
Observer.reset()

suite.finish()

return true
