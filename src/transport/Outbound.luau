--!strict
--!optimize 2

--[=[
	@class Outbound

	The send half. Accumulates a frame's packets per recipient and flushes them as one call each.

	Internal.
]=]

--[[
	Three decisions here are the M2 roadmap's, and each is a competitor's behaviour adopted or
	refused on purpose.

	**Serialize once, memcpy N times** (`RESEARCH §3.7-E`). Blink's `RELIABLE_BODY` and Zap's
	`push_return_fire_all` both save the buffer, serialise once into a scratch, then per player
	load, allocate and copy. It is the universal idiom and netweave takes it. The M1 benchmark's
	stand-in re-encoded per recipient, so its fan-out numbers are a floor rather than a forecast.

	**One `FireAllClients` where the audience is everyone** (`RESEARCH §3.7-E`). This is the single
	axis where ByteNet beats both code generators: Blink and Zap issue 100 memcpys and 100 remote
	calls for 100 players; ByteNet issues one. netweave already knows which channels qualify,
	because `nw.audience.everyone` is a singleton in the type and the same tag decides whether
	`broadcast` exists at all.

	**Unreliable is not batched** (`RESEARCH §3.7-E`). Batching unreliable traffic is a semantic
	error rather than an optimisation: one lost datagram becomes N lost events instead of one.
	Blink not batching unreliable looks like a choice, not an omission, and netweave makes the same
	one — an unreliable packet is its own batch and goes out immediately.
]]

local Batch = require("./Batch")
local Buffer = require("../codec/Buffer")
local Link = require("./Link")
local Config = require("../api/Config")
local Observer = require("../api/Observer")
local Recipients = require("./Recipients")

--[[
	`pcall` of a function whose return pack is empty is typed as returning `boolean` alone, so the
	error cannot be destructured out of it. The alias widens the pack without changing what runs.
]]
local attempt: (...any) -> ...any = Batch.writeBody
local attemptPacket: (...any) -> ...any = Batch.writePacket
local attemptRequest: (...any) -> ...any = Batch.writeRequest
local attemptReply: (...any) -> ...any = Batch.writeReply

local Outbound = {}

--[[
	Roblox drops an unreliable payload past this size **silently** — no error, no warning, nothing
	on either side. `grep` for `900|908|buffer.len` across `blink/src` and `zap/src/output/luau`
	returns nothing, so all three surveyed libraries are exposed to it (`RESEARCH §3.7-F`).

	908 is the documented limit for an `UnreliableRemoteEvent`'s payload. The instance sidecar adds
	overhead this number does not model, so the check is a floor rather than an exact boundary; a
	packet that passes it can still be dropped if it carries many instances, and that is stated
	rather than papered over.
]]
--[[ Roblox refuses an unreliable payload over 908 bytes, so this is a ceiling rather than a
     preference: `nw.configure` can only lower it. `RESEARCH §3.7-F` records that none of the four
     surveyed libraries checks it at all. ]]
local UNRELIABLE_CEILING = 908

--[=[
	@prop EVERYONE any
	@within Outbound

	The destination a broadcast is parked under.
]=]
--[[
	Two sentinels, and they have to be values a `Player` can never be — `false` and `0` are both
	safe as table keys and neither can collide with a real recipient.

	`nil` would not do for either. A destination of `nil` is indistinguishable from "no destination
	loaded", so the swap would think it was already there and write the packet into whichever
	buffer happened to be current — a client's traffic landing in another player's batch, silently.
]]
local EVERYONE = false

--[=[
	@prop SERVER any
	@within Outbound

	The destination a client sends to. There is only one, and it is not addressable by name.
]=]
local SERVER = 0

Outbound.EVERYONE = EVERYONE
Outbound.SERVER = SERVER

export type Outbound = {
	push: (channel: any, destination: any, value: any) -> (),
	publish: (channel: any, subject: any, value: any) -> (),
	broadcast: (channel: any, value: any) -> (),
	request: (channel: any, call: number, value: any) -> (),
	reply: (channel: any, destination: any, call: number, status: number, value: any?) -> (),
	flush: () -> (),
	forget: (destination: any) -> (),
}

--[=[
	@within Outbound
	@function new
	@param link Link
	@param roster Roster
	@param isServer boolean
	@return Outbound
]=]
function Outbound.new(link: Link.Link, roster: Recipients.Roster): Outbound
	--[[
		One parked buffer per destination, swapped rather than reallocated (`PLAN-M1` D-4). The
		outgoing buffer is global and the swap is how per-player multiplexing works; a second buffer
		implementation here would be measuring something netweave does not do.

		The records are owned here and refilled with `Buffer.saveInto`, never rebuilt. One table per
		destination for the life of the connection, rather than one per packet — M1's benchmark
		measured what the other way costs and it was the largest single number in the run.
	]]
	local parked: { [any]: Buffer.Save } = {}

	--[[
		Which destination is currently loaded, and its record.

		Consecutive sends to one destination are the common case — a fan-out loop, a player's own
		batch — so tracking this removes the swap from the path entirely rather than paying for one
		per packet.
	]]
	local loaded: any = nil
	local loadedRecord: Buffer.Save? = nil

	--[[ Filled per publish by `Recipients.of` and reused, so an audience costs no allocation. ]]
	local recipients: { any } = {}

	--[[ Where a fan-out serialises once before copying. Owned here for the same reason as the
	     parked records: it is touched once per publish. ]]
	local scratch: Buffer.Save = Buffer.emptySave()

	local function park()
		if loadedRecord then
			Buffer.saveInto(loadedRecord)
			loaded = nil
			loadedRecord = nil
		end
	end

	local function switchTo(destination: any)
		if loaded == destination then
			return
		end

		park()

		local record = parked[destination]

		if record then
			Buffer.load(record)
		else
			Buffer.load(nil)

			record = Buffer.emptySave()
			Buffer.saveInto(record)
			parked[destination] = record
		end

		loaded = destination
		loadedRecord = record
	end

	--[[
		A packet whose value the schema forbids raises, and that is the encode-side posture. What it
		must not do is leave the half-written packet in the batch: the bytes behind it are another
		player's real traffic, and a partial packet in front of them makes the whole batch
		undecodable — the framing after it would be read from the wrong offsets.

		The rewind is two numbers rather than a saved record, so the guard costs no allocation.
	]]
	local function guarded(writer: (...any) -> ...any, ...: any)
		local used, instances = Buffer.mark()
		local ok, failure = pcall(writer, ...)

		if not ok then
			Buffer.rollback(used, instances)

			--[[ Re-raised rather than swallowed: this is game code passing a value game code
			     produced, and dropping it silently would hide the bug that produced it. The batch
			     is intact by the time this leaves. ]]
			error(failure, 0)
		end
	end

	local function isUnreliable(channel: any): boolean
		return channel.unreliable == true
	end

	--[[
		An unreliable packet is a batch of one, written into a buffer nobody else is using so that
		taking it cannot disturb a reliable batch mid-accumulation.
	]]
	local function pushUnreliable(channel: any, destination: any, value: any, all: boolean)
		park()
		Buffer.load(nil)

		local ok, failure = pcall(attemptPacket, channel, value)

		if not ok then
			Buffer.take()
			error(failure, 0)
		end

		local packed, instances = Buffer.take()
		local size = buffer.len(packed)

		local ceiling = math.min(Config.limitOf("unreliableBytes") or UNRELIABLE_CEILING, UNRELIABLE_CEILING)

		if size > ceiling then
			--[[ Refused here rather than dropped by Roblox there. A payload over the limit
			     disappears silently on the wire, and none of the three surveyed libraries checks
			     for it (`RESEARCH §3.7-F`). ]]
			Observer.emit(
				channel.qualified,
				if all or destination == SERVER then nil else destination,
				"send",
				`unreliable payload is {size} bytes, over the {ceiling} byte limit`,
				size
			)
			return
		end

		if all then
			link.sendAll(false, packed, instances)
		elseif destination == SERVER then
			link.send(false, nil, packed, instances)
		else
			link.send(false, destination, packed, instances)
		end
	end

	local self: Outbound

	self = {
		--[[ One recipient, named. A client's `send` and a single-recipient `publish` both land
		     here. ]]
		push = function(channel: any, destination: any, value: any)
			if isUnreliable(channel) then
				pushUnreliable(channel, destination, value, false)
				return
			end

			switchTo(destination)
			guarded(attemptPacket, channel, value)
		end,

		--[[ A publish resolves its audience and fans out. `everyone` takes the one-call path;
		     everything else is serialised once and copied per recipient. ]]
		publish = function(channel: any, subject: any, value: any)
			local count = Recipients.of(channel.audience, subject, roster, recipients)

			if count == -1 then
				self.broadcast(channel, value)
				return
			end

			if count == 0 then
				return
			end

			if count == 1 then
				--[[ Serialising and copying to reach one buffer is strictly more work than writing
				     into it. ]]
				self.push(channel, recipients[1], value)
				return
			end

			if isUnreliable(channel) then
				for index = 1, count do
					pushUnreliable(channel, recipients[index], value, false)
				end

				return
			end

			--[[
				Serialise once into a buffer of its own, then copy the bytes into each recipient's
				batch (`RESEARCH §3.7-E`). `writeBody`, not `writePacket`: the version byte belongs
				to the recipient's buffer, which may already have one, and a scratch carrying its own
				would have to be copied from an offset — an offset to get wrong on every broadcast.
			]]
			park()
			Buffer.load(scratch)
			Buffer.rollback(0, 0)

			local ok, failure = pcall(attempt, channel, value)

			Buffer.saveInto(scratch)

			if not ok then
				error(failure, 0)
			end

			local source = scratch.buffer
			local body = scratch.used
			local carried = scratch.instances
			local instanceCount = scratch.instanceCount

			for index = 1, count do
				switchTo(recipients[index])
				Batch.begin()
				Buffer.writeBuffer(source, body)

				for entry = 1, instanceCount do
					Buffer.writeInstance(carried[entry])
				end
			end
		end,

		--[[ Every player, in one call. Parked like any other destination so it batches with the
		     rest of the frame rather than going out alone. ]]
		broadcast = function(channel: any, value: any)
			if isUnreliable(channel) then
				pushUnreliable(channel, nil, value, true)
				return
			end

			switchTo(EVERYONE)
			guarded(attemptPacket, channel, value)
		end,

		--[[
			A query going out from the client. There is one destination and it is not addressable, so
			this is `push` with a call id — batched with the frame's other traffic rather than sent
			alone, because a request that leaves early still waits a frame for the answer.
		]]
		request = function(channel: any, call: number, value: any)
			switchTo(SERVER)
			guarded(attemptRequest, channel, call, value)
		end,

		--[[
			The answer, back to the one player who asked.

			It is not budgeted, and that is an argument rather than an omission: a reply is
			one-for-one with a request, and the request already spent that player's rate budget on
			the way in. A second budget here would police the server's own answers to questions it
			had already agreed to answer, and the only way to overrun it would be to have accepted
			too many requests — which is what `rate` is for.
		]]
		reply = function(channel: any, destination: any, call: number, status: number, value: any?)
			switchTo(destination)
			guarded(attemptReply, channel, call, status, value)
		end,

		--[[ Once a frame. Everything accumulated goes out as one call per destination, which is the
		     difference between a batching library's ~126 remote invocations a second and raw's
		     ~6,400 (`bench/RESULTS.md`). ]]
		flush = function()
			park()

			for destination, record in parked do
				if record.used > 0 then
					Buffer.load(record)

					local packed, instances = Buffer.take()

					if destination == EVERYONE then
						link.sendAll(true, packed, instances)
					elseif destination == SERVER then
						link.send(true, nil, packed, instances)
					else
						link.send(true, destination, packed, instances)
					end

					--[[ `take` left a fresh empty buffer behind; the record keeps it so the
					     destination does not have to allocate one again next frame. ]]
					Buffer.saveInto(record)
				end
			end
		end,

		--[[ A player who left. Their parked batch is bytes nobody will receive, and holding it
		     holds the buffer behind it. ]]
		forget = function(destination: any)
			if loaded == destination then
				loaded = nil
				loadedRecord = nil
				Buffer.load(nil)
			end

			parked[destination] = nil
		end,
	}

	return self
end

return Outbound
