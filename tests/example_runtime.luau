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

local Budget = require("../src/transport/Budget")
local Inbound = require("../src/transport/Inbound")
local Link = require("../src/transport/Link")
local Namespace = require("../src/api/Namespace")
local Observer = require("../src/api/Observer")
local Outbound = require("../src/transport/Outbound")
local Recipients = require("../src/transport/Recipients")
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

type Frame = { packed: buffer, instances: { Instance } }

local toServer: { Frame } = {}
local toClient: { Frame } = {}
local carried: { Frame } = {}

local function linkInto(queue: { Frame }): Link.Link
	return {
		send = function(_reliable, _destination, packed, instances)
			table.insert(queue, { packed = packed, instances = instances })
		end,

		sendAll = function(_reliable, packed, instances)
			table.insert(queue, { packed = packed, instances = instances })
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

local serverIn = Inbound.new({
	resolve = Namespace.channelById,
	admit = budget.admit,
	isServer = true,
})

local clientIn = Inbound.new({
	resolve = Namespace.channelById,
	admit = function(): string?
		return nil
	end,
	isServer = false,
})

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

	serverOut.flush()
	drain(toClient, clientIn, nil)
end

local refusals: { string } = {}
local equipped: { number } = {}

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

Transport.uninstall()
Namespace.reset()
Observer.reset()

suite.finish()

return true
