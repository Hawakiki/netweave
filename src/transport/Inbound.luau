--!strict
--!optimize 2

--[=[
	@class Inbound

	The receive half. Walks each arriving batch, decides what to admit, and dispatches what
	survives.

	Internal.
]=]

--[[
	Four things happen to a packet here and each can refuse it, which is why `nw.observe` reports a
	stage rather than a boolean. `RESEARCH §3-G6` records that no surveyed library reports rejection
	rates at all, and `§3.7-K` records what that costs: Warp blackholes a player whose packet fails
	and nothing anywhere says so.

	Nothing on this path raises. The bytes came from a peer, so every failure — including one thrown
	by the game's own handler — is caught and reported, because a batch is other players' traffic
	and one bad packet must not take it (`DESIGN-API.md` G4, G5).
]]

local Batch = require("./Batch")
local Context = require("../api/Context")
local Observer = require("../api/Observer")

local Inbound = {}

--[[
	Blink's queue for a listener-less event is `table.insert` with no bound: past 256 it warns on
	every insert and keeps inserting, so a missing listener becomes warn spam plus unbounded memory
	(`Generator/init.luau:413-418`, `RESEARCH §3.7-H`). Zap uses read and write cursors and grows by
	doubling, which is better and is what this takes — with one change.

	**A full queue drops the oldest and says so.** Growing without bound turns a forgotten `:listen`
	into a memory leak that looks like a networking library, and the packets worth keeping when a
	handler finally attaches are the recent ones, not the ones from a minute ago.
]]
local QUEUE_CAPACITY = 256

type Queue = {
	values: { any },
	senders: { any },
	read: number,
	count: number,
	dropped: number,
}

export type Config = {
	--[[ The channel with that wire id, or nil. ]]
	resolve: (id: number) -> any,
	--[[ nil to accept the packet, or a reason to refuse it. Runs before the payload is decoded. ]]
	admit: (channel: any, sender: any?, bytes: number) -> string?,
	--[[ Server-side handlers receive a context; client-side ones receive the payload alone. ]]
	isServer: boolean,
}

export type Inbound = {
	receive: (packed: buffer, instances: { Instance }?, sender: any?) -> (),
	drain: (channel: any) -> (),
	tick: () -> (),
	forget: (sender: any) -> (),
}

--[[ `xpcall` with a shared handler allocates no closure per call. A traceback is worth the string
     because a handler error is a game bug and the line is the whole of the diagnosis. ]]
local function traceback(message: any): string
	return `{tostring(message)}\n{debug.traceback("", 2)}`
end

--[[
	A batch is read to completion **before** anything is dispatched, and that is a correctness
	requirement rather than a tidiness one.

	A handler is game code and may yield. Roblox runs each remote callback on its own coroutine, so
	a yield lets the next batch in — and the decoder's cursor is global state (`src/codec/Buffer`,
	which is global on purpose so a write costs one upvalue rather than a parameter chain). Reading
	and dispatching in one pass therefore means: handler yields, the next batch calls `beginRead`,
	and when the first resumes it walks the *second* batch's bytes while attributing them to the
	first batch's sender.

	That is not a crash. It is one player's packets delivered as another player's, which is the
	worst shape a networking bug can take.

	Reading first closes it structurally. The read phase calls no game code and therefore cannot
	yield; by the time a handler runs, this batch's bytes are already values and nothing shared is
	still being consumed. Each pending entry carries its own sender, so nothing is attributed by
	timing.
]]
type Pending = {
	channels: { any },
	senders: { any },
	values: { any },
	sizes: { number },
	count: number,
}

local function emptyPending(): Pending
	return { channels = {}, senders = {}, values = {}, sizes = {}, count = 0 }
end

--[=[
	@within Inbound
	@function new
	@param config Config
	@return Inbound
]=]
function Inbound.new(config: Config): Inbound
	local resolve = config.resolve
	local admit = config.admit
	local isServer = config.isServer

	--[[
		The sender of the batch currently being **read**.

		Safe as shared state precisely because of the split above: the read phase runs no game code,
		so it cannot yield, so there is no window in which another batch can change this while it is
		still being used. It is never read after a handler has run.
	]]
	local sender: any = nil

	local queues: { [any]: Queue } = {}

	--[[
		Pending lists, indexed by re-entrancy depth.

		At depth one — every ordinary frame — this is the same four arrays reused forever and costs
		nothing. A deeper entry is allocated only when a handler actually yields and another batch
		arrives inside it, which is the case that would otherwise have corrupted both.
	]]
	local pool: { Pending } = { emptyPending() }
	local depth = 0

	--[[
		At most one `intent` per player per tick reaches the handler. Stale input has no value, so an
		attacker who fills the rate budget cannot convert it into per-packet server work — and that
		is what makes `rate` on an intent a number that means something rather than a cap nobody
		hits (`DESIGN-API.md` §3).

		This is the one place merging is semantically safe. `RESEARCH §3.7-E` argues batching
		unreliable traffic is a semantic error in general, because losing one datagram loses N
		events; an intent is the exception, because losing a superseded input costs nothing.
	]]
	local coalescedValue: { [any]: { [any]: any } } = {}
	local coalescedBytes: { [any]: { [any]: number } } = {}

	local function report(channel: any, who: any?, stage: Observer.Stage, reason: string, bytes: number)
		Observer.emit(if channel then channel.qualified else "?", who, stage, reason, bytes)
	end

	local function call(channel: any, who: any?, value: any, bytes: number)
		--[[ Annotated so `xpcall` resolves: a handler read off an `any` channel is narrowed to "not
		     false or nil" by the caller's check, which is not a callable type. ]]
		local handler: (...any) -> ...any = channel.handler

		if not isServer then
			--[[ A client's inbound is the server's outbound, and the server is not a peer to be
			     checked. No context, no policy — the payload alone. ]]
			local ok, failure = xpcall(handler, traceback, value)

			if not ok then
				report(channel, nil, "handler", tostring(failure), bytes)
			end

			return
		end

		local ctx = Context.acquire(who, channel.qualified)

		--[[ Annotated for the same reason as `handler`: read off an `any` channel and truth-tested,
		     which narrows to a type that is not callable. ]]
		local authorize: ((any, any) -> any)? = channel.authorize

		if authorize then
			local verdict = authorize(ctx, value)

			--[[ Read out of the shared verdict record before anything else can overwrite it
			     (`src/api/Policy.luau`). ]]
			local allowed = verdict.ok
			local narrowed = verdict.value
			local reason = verdict.reason

			if not allowed then
				report(channel, who, "authorize", reason or "denied", bytes)
				Context.release(who)
				return
			end

			if narrowed ~= nil then
				value = narrowed
			end
		end

		local ok, failure = xpcall(handler, traceback, ctx, value)

		if not ok then
			report(channel, who, "handler", tostring(failure), bytes)
		end

		Context.release(who)
	end

	--[[
		Hand a pending list to the caller, run it dry, and give it back.

		The entries are cleared as they are dispatched rather than afterwards, so a handler that
		raises — already caught, but still — cannot leave a value referenced by a list that will be
		reused for the next frame.
	]]
	local function claim(): Pending
		depth += 1

		local list = pool[depth]

		if not list then
			list = emptyPending()
			pool[depth] = list
		end

		list.count = 0
		return list
	end

	local function dispatch(list: Pending)
		local channels = list.channels
		local senders = list.senders
		local values = list.values
		local sizes = list.sizes
		local count = list.count

		list.count = 0

		for index = 1, count do
			local channel = channels[index]
			local who = senders[index]
			local value = values[index]

			channels[index] = nil
			senders[index] = nil
			values[index] = nil

			call(channel, who, value, sizes[index])
		end

		--[[
			The depth is released **after** the loop, not before it.

			Releasing it first looks harmless — the list has already been drained into locals — and is
			not: a handler that yields lets the next batch in, and that batch would then `claim` this
			very list and overwrite the entries this loop has not reached yet. The failure is silent
			and size-dependent, which is why it survived a first test: the interleaved batch only
			corrupts the outer one when it is at least as long.
		]]
		depth -= 1
	end

	--[[
		A channel nobody is listening to yet. The packets are kept rather than dropped, because a
		handler attached one frame late is an ordering accident and losing the traffic to it is a
		bug the game cannot see.
	]]
	local function enqueue(channel: any, who: any?, value: any, bytes: number)
		local queue = queues[channel]

		if not queue then
			queue = {
				values = table.create(QUEUE_CAPACITY),
				senders = table.create(QUEUE_CAPACITY),
				read = 0,
				count = 0,
				dropped = 0,
			}

			queues[channel] = queue
		end

		if queue.count == QUEUE_CAPACITY then
			--[[ Drop the oldest and step the read cursor past it. Reported once per drop so a
			     forgotten `:listen` is visible rather than merely quiet. ]]
			queue.read = (queue.read + 1) % QUEUE_CAPACITY
			queue.count -= 1
			queue.dropped += 1

			report(
				channel,
				who,
				"queue",
				`no handler is attached and the queue is full; dropped {queue.dropped} so far`,
				bytes
			)
		end

		local slot = (queue.read + queue.count) % QUEUE_CAPACITY
		queue.values[slot + 1] = value
		queue.senders[slot + 1] = who
		queue.count += 1
	end

	--[[ The list the read phase is filling. Set for the duration of one `Batch.read`, which cannot
	     yield, for the same reason `sender` is safe. ]]
	local filling: Pending = pool[1]

	local sink: Batch.Sink = {
		resolve = resolve,

		admit = function(channel: any, bytes: number): string?
			return admit(channel, sender, bytes)
		end,

		deliver = function(channel: any, value: any, bytes: number)
			if not channel.handler then
				enqueue(channel, sender, value, bytes)
				return
			end

			if channel.class == "intent" then
				local byPlayer = coalescedValue[channel]

				if not byPlayer then
					byPlayer = {}
					coalescedValue[channel] = byPlayer
					coalescedBytes[channel] = {}
				end

				--[[ Latest wins. The superseded value is not reported: it was not refused, it was
				     replaced, and reporting it would make an intent channel look like it is
				     failing. ]]
				byPlayer[sender] = value
				coalescedBytes[channel][sender] = bytes
				return
			end

			local count = filling.count + 1
			filling.count = count
			filling.channels[count] = channel
			filling.senders[count] = sender
			filling.values[count] = value
			filling.sizes[count] = bytes
		end,

		refuse = function(channel: any?, stage: string, reason: string, bytes: number)
			report(channel, sender, stage :: Observer.Stage, reason, bytes)
		end,
	}

	return {
		receive = function(packed: buffer, instances: { Instance }?, from: any?)
			local list = claim()

			--[[ Both of these belong to the read phase only. Restored rather than cleared, so a
			     batch that arrived inside another batch's dispatch leaves the outer one as it
			     found it. ]]
			local outerSender = sender
			local outerFilling = filling

			sender = from
			filling = list

			Batch.read(packed, instances, sink)

			sender = outerSender
			filling = outerFilling

			dispatch(list)
		end,

		--[[ A handler has just been attached. Whatever arrived before it did is delivered now, in
		     arrival order. ]]
		drain = function(channel: any)
			local queue = queues[channel]

			if not queue or not channel.handler then
				return
			end

			local list = claim()

			while queue.count > 0 do
				local slot = queue.read
				local count = list.count + 1

				list.count = count
				list.channels[count] = channel
				list.senders[count] = queue.senders[slot + 1]
				list.values[count] = queue.values[slot + 1]
				list.sizes[count] = 0

				queue.values[slot + 1] = nil
				queue.senders[slot + 1] = nil
				queue.read = (slot + 1) % QUEUE_CAPACITY
				queue.count -= 1
			end

			dispatch(list)
		end,

		--[[ Once a frame. Every intent that arrived since the last one is delivered, at most one
		     per player per channel. ]]
		tick = function()
			local list = claim()

			for channel, byPlayer in coalescedValue do
				local bytes = coalescedBytes[channel]

				for who, value in byPlayer do
					byPlayer[who] = nil

					local count = list.count + 1
					list.count = count
					list.channels[count] = channel
					list.senders[count] = who
					list.values[count] = value
					list.sizes[count] = bytes[who] or 0

					bytes[who] = nil
				end
			end

			dispatch(list)
		end,

		--[[ A player who left. Their pending intent is input nobody is waiting for, and their
		     context record would otherwise outlive them. ]]
		forget = function(who: any)
			for _, byPlayer in coalescedValue do
				byPlayer[who] = nil
			end

			for _, bytes in coalescedBytes do
				bytes[who] = nil
			end

			Context.forget(who)
		end,
	}
end

return Inbound
