--!strict
--!optimize 2

--[=[
	@class Driver

	Assembles the transport and fills the hole M1 left.

	`src/api/Transport.luau` is the seam: every `send`, `publish`, `broadcast` and `invoke` in the
	library ends there, and until this installs itself they all raise with a message naming this
	milestone. Requiring `netweave` inside Roblox is what installs it.

	Internal.
]=]

--[[
	Nothing here is exposed on `nw`. A game that declared its channels correctly does not have a
	transport to configure — the rate is on the channel, the audience is on the channel, and the
	batching is not a decision anyone should be making per game. Adding knobs here would move the
	security model out of the declaration file, which is the whole thing this design is built to
	prevent (`DESIGN-API.md` §1).
]]

local Budget = require("./Budget")
local Inbound = require("./Inbound")
local Link = require("./Link")
local Namespace = require("../api/Namespace")
local Outbound = require("./Outbound")
local Query = require("./Query")
local Recipients = require("./Recipients")
local Transport = require("../api/Transport")

local Driver = {}

--[=[
	@within Driver
	@function install

	Builds the transport and installs it. Called once, from `src/netweave.luau`, and only inside
	Roblox — the link needs real remotes.
]=]
function Driver.install()
	local RunService = game:GetService("RunService")
	local Players = game:GetService("Players")

	local isServer = RunService:IsServer()

	local link = Link.roblox()
	local roster = Recipients.roblox()
	local outbound = Outbound.new(link, roster)
	local budget = Budget.new()

	--[[
		`task.spawn` is passed in rather than reached for inside `Query`, which keeps that module
		loadable under lune where `task` does not exist — the same shape as `Budget`'s injectable
		clock. It is the right primitive for both jobs it does here: it starts a handler on a fresh
		thread, and it resumes a parked caller *propagating* whatever that thread raises, where
		`coroutine.resume` would swallow the game's own error into a boolean nobody reads.
	]]
	local query = Query.new({
		request = function(channel: any, call: number, value: any)
			outbound.request(channel, call, value)
		end,

		reply = function(channel: any, who: any, call: number, status: number, value: any?)
			outbound.reply(channel, who, call, status, value)
		end,

		spawn = task.spawn,
	})

	local inbound = Inbound.new({
		resolve = Namespace.channelById,
		admit = budget.admit,
		isServer = isServer,
		queries = query,
	})

	link.receive(inbound.receive)

	--[[
		Ids cannot be assigned until every namespace has been declared, because an id depends on
		every other channel in the program (`docs/WIRE-FORMAT.md` §3). The first send is the latest
		moment that can be deferred to, and one branch per send is what deferring costs.

		The receive path seals through `Namespace.channelById` for the same reason.
	]]
	local ready = false

	local function ensure()
		if not ready then
			Namespace.seal()
			ready = true
		end
	end

	--[[
		Once a frame, in this order.

		Intents are delivered before the flush so that a handler's reply goes out in the same frame
		it was provoked by, rather than waiting for the next one. Reversing them would add a frame
		of latency to every response, invisibly.
	]]
	RunService.PostSimulation:Connect(function()
		inbound.tick()

		--[[ Between the dispatch and the flush, so that a call giving up this frame can retry in it
		     rather than waiting a frame to be sent. A caller resumed with a failure is game code
		     like any other and often does exactly that. ]]
		query.tick()
		outbound.flush()
	end)

	if isServer then
		Players.PlayerRemoving:Connect(function(player)
			--[[ Four places hold something per player: an unsent batch, a pending intent and a
			     context record, a rate window, and the call slots of any query still running for
			     them. None of them mean anything once the player is gone, and all four would
			     otherwise grow with every join.

			     `query.forget` releases the accounting and nothing else — a handler already parked
			     inside a yield cannot be cancelled, because a yielded Luau coroutine cannot be. It
			     returns when it returns, finds its slot gone, and writes no reply. ]]
			outbound.forget(player)
			inbound.forget(player)
			budget.forget(player)
			query.forget(player)
		end)
	end

	Transport.install({
		send = function(channel: any, value: any)
			ensure()
			outbound.push(channel, Outbound.SERVER, value)
		end,

		publish = function(channel: any, subject: any, value: any)
			ensure()
			outbound.publish(channel, subject, value)
		end,

		broadcast = function(channel: any, value: any)
			ensure()
			outbound.broadcast(channel, value)
		end,

		--[[ The timeout is the part that matters. Blink and Zap have none, so a peer that never
		     answers parks the caller's thread for the session (`RESEARCH §3.7-G`); `timeout` is a
		     required field on `nw.query` and there is no value of it meaning "wait forever". ]]
		invoke = function(channel: any, args: any): (any?, string?)
			ensure()
			return query.invoke(channel, args)
		end,

		--[[ A handler has just been attached, so anything that arrived before it did is delivered
		     now rather than lost to the order the game happened to require its modules in. ]]
		dispatch = function(channel: any)
			inbound.drain(channel)
		end,
	})
end

return Driver
