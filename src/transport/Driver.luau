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

local Baseline = require("../replication/Baseline")
local Budget = require("./Budget")
local Inbound = require("./Inbound")
local Link = require("./Link")
local Namespace = require("../api/Namespace")
local Outbound = require("./Outbound")
local Pacer = require("./Pacer")
local Protocol = require("../api/Protocol")
local Query = require("./Query")
local Recipients = require("./Recipients")
local Tick = require("../replication/Tick")
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

	--[[ A client's intent sends, held to the declared rate (`PLAN-M5` D-6). Built on the server too,
	     where nothing ever calls `send`, because one code path is cheaper to be right about than
	     two; an empty pacer's tick is one `#` on an empty array. ]]
	local pacer = Pacer.new(function(channel: any, value: any)
		outbound.push(channel, Outbound.SERVER, value)
	end)

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

	--[[ Read late, and through a function, because the protocol does not exist until every
	     namespace has been declared — see `ensure` below. ]]
	local agreement = Protocol.new({
		hash = function(): number
			return Namespace.protocol().hash
		end,

		announce = function(who: any?)
			local protocol = Namespace.protocol()
			outbound.hello(if who == nil then Outbound.SERVER else who, protocol.hash, protocol.namespaces)
		end,

		--[[ Read late like `hash`, and for the same reason. ]]
		namespaces = function()
			return Namespace.protocol().namespaces
		end,

		isServer = isServer,
	})

	--[[
		What the other end has, per replicated subject.

		**Bounded on the server and not on the client**, and the asymmetry is the point. On the
		server this is memory sized by how many people join, which is `PLAN-M3` D-6 territory and
		what `baselinesPerClient` exists for. On the client it is what the server chose to send —
		already bounded, by that limit, at the other end — and refusing to remember one here would
		make the next change unreadable rather than saving anything.
	]]
	local baselines = Baseline.new(isServer)

	local inbound = Inbound.new({
		resolve = Namespace.channelById,
		admit = budget.admit,
		isServer = isServer,
		queries = query,
		agreement = agreement,
		baselines = baselines,

		--[[ A change this endpoint could not read means every change after it is unreadable, so it
		     asks for the channel again. Only a client can: the server is the sender, and a server
		     that lost track of what a client has simply sends everything next tick. ]]
		desynced = if isServer
			then nil
			else function(channel: any)
				outbound.resync(channel)
			end,
	})

	--[[ Server-side only. A replicated channel is driven from the store, and the store is the
	     server's. ]]
	local replicate = if isServer
		then Tick.new({
			outbound = outbound,
			baselines = baselines,
			roster = roster,
			channels = Namespace.replicated,
		})
		else nil

	--[[
		Ids cannot be assigned until every namespace has been declared, because an id depends on
		every other channel in the program (`docs/WIRE-FORMAT.md` §3). The first send is the latest
		moment that can be deferred to, and one branch per send is what deferring costs.

		The receive path seals through `Namespace.channelById` for the same reason.
	]]
	--[[
		Asked of `Namespace` rather than remembered here. A flag of this driver's own stayed true
		across `Namespace.reset()`, so a suite that had sent one packet through the real transport
		left every namespace declared after it unsealed and unnumbered — found writing the Studio
		half of the suite, where the benchmark declares its channels after the tests have run
		(`PLAN-M4-BUG` phase 6).
	]]
	local function ensure()
		--[[ After the seal, and on the server only: every policy's server stage, once. Asked on
		     every send and receive because `Namespace.protocol()` seals too, from a game that
		     prints its hash before its first packet, and a seal that ran there must not leave the
		     stages unrun; the second and every later call is one boolean (`PLAN-M5` D-5). ]]
		if Namespace.sealed() then
			if isServer then
				Namespace.runStages()
			end

			return
		end

		Namespace.seal()

		if isServer then
			Namespace.runStages()
		end

		--[[
			The client's hello goes out here, the moment the protocol is real and before anything
			else this peer will ever send.

			`ensure` is the only place that knows when the numbering is fixed, and being first in the
			buffer is what makes the hash the first packet of the first batch — so a server that
			disagrees can refuse the rest of that same batch rather than accepting one batch of
			payloads that decode as the wrong channels.

			The server does not announce unprompted, because at install there is nobody to announce
			to. It answers on a mismatch instead (`src/api/Protocol.luau`).
		]]
		if not isServer then
			local protocol = Namespace.protocol()
			outbound.hello(Outbound.SERVER, protocol.hash, protocol.namespaces)
		end
	end

	--[[ Sealing on the way in as well as on the way out. A client that only listens never sends, so
	     `ensure` would never run and its hello would never leave — and a listen-only client on a
	     stale build is exactly the one whose mis-decodes are hardest to explain. ]]
	link.receive(function(packed: buffer, instances: { Instance }, sender: any?)
		ensure()
		inbound.receive(packed, instances, sender)
	end)

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

		--[[ After the handlers have run, so a change provoked by this frame's traffic goes out in
		     this frame's batch rather than the next one — and before the flush, for the same
		     reason. ]]
		if replicate then
			replicate()
		end

		--[[ Held intent values whose channel has a token again go out in this frame's batch. ]]
		pacer.tick()

		outbound.flush()
	end)

	if isServer then
		Players.PlayerRemoving:Connect(function(player)
			--[[ Six places hold something per player: an unsent batch, a pending intent, a context
			     record, a rate window, the call slots of any query still running for them, and
			     the replication baselines. None of them mean anything once the player is gone, and
			     every one would
			     otherwise grow with every join.

			     `query.forget` releases the accounting and nothing else — a handler already parked
			     inside a yield cannot be cancelled, because a yielded Luau coroutine cannot be. It
			     returns when it returns, finds its slot gone, and writes no reply. ]]
			outbound.forget(player)
			inbound.forget(player)
			baselines.forget(player)
			budget.forget(player)
			query.forget(player)
			agreement.forget(player)
		end)
	end

	Transport.install({
		send = function(channel: any, value: any)
			ensure()

			--[[ An intent is the newest value at the declared rate, and nothing else is: a signal
			     or a command sent past its rate is the server's refusal to make. ]]
			if channel.class == "intent" then
				pacer.send(channel, value)
			else
				outbound.push(channel, Outbound.SERVER, value)
			end
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
