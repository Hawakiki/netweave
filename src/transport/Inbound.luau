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

local Baseline = require("../replication/Baseline")
local Batch = require("./Batch")
--[[ Aliased, because this module already exports a type named `Config` for its own constructor
     options and two `Config`s in one file is a reading hazard even where Luau permits it. ]]
local Settings = require("../api/Config")
local Context = require("../api/Context")
local Observer = require("../api/Observer")
local Protocol = require("../api/Protocol")
local Query = require("./Query")

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
--[[ A default rather than a constant since M3: `nw.configure` moves it, and it is read when a
     queue is first created so a game that raises it before declaring gets the queue it asked for.
     Stored on the queue itself, because changing the limit must not desynchronise the ring
     arithmetic of a queue that already exists. ]]
local DEFAULT_QUEUE_CAPACITY = 256

--[[ Constant like every other refusal reason, and reached only by an endpoint that was handed a
     replicated channel without anywhere to keep what the other end has — which is a wiring mistake
     rather than anything a peer can provoke. ]]
local NO_BASELINES = "a replicated packet arrived at an endpoint with no baseline store, so there "
	.. "is nothing to fold it into. Pass `baselines` to Inbound.new"

--[[ A peer asked for a channel that is not replicated, or is not a channel at all. Constant,
     because it is the one thing about replication a hostile peer can send at will. ]]
local NOT_REPLICATED = "a peer asked to be resynchronised on an id that is not a replicated channel"

--[[ Constant because a flood is exactly when it is said. It used to carry `dropped {n} so far`,
     which allocated a string per dropped packet to print a number three times — the repeat
     suppression caps the console at three lines per stage, and `nw.observe` sees every one and can
     count them itself (M3 phase 9). ]]
local QUEUE_FULL = "no handler is attached and the queue is full, so the oldest was dropped. "
	.. "Attach a :listen, or raise the queueCapacity limit"

type Queue = {
	values: { any },
	senders: { any },
	read: number,
	count: number,
	capacity: number,
	dropped: number,
}

export type Config = {
	--[[ The channel with that wire id, or nil. ]]
	resolve: (id: number) -> any,
	--[[ nil to accept the packet, or a reason to refuse it. Runs before the payload is decoded. ]]
	admit: (channel: any, sender: any?, bytes: number) -> string?,
	--[[ Server-side handlers receive a context; client-side ones receive the payload alone. ]]
	isServer: boolean,
	--[[ Request/response, when this endpoint does any. One record rather than four callbacks: an
	     endpoint either serves queries or refuses them, and there is no half of it that makes
	     sense on its own. Absent, a query packet is reported and dropped. ]]
	queries: Query.Queries?,
	--[[ Who has agreed on the declarations. Absent, every peer is taken at its word — which is what
	     a test that is not about the handshake wants. ]]
	agreement: Protocol.Agreement?,
	--[[ What each peer has, per replicated subject. On a client this is what arrived; on a server
	     it is what was sent, and the same store serves both because "the other end has this" is
	     one fact seen from two directions. Absent, a replicated packet is reported and dropped. ]]
	baselines: Baseline.Baseline?,
	--[[ Called when a replicated packet was refused, which means this endpoint's picture of that
	     channel is now unknowable. The driver wires it to the packet that asks for everything
	     again; a test that does not care leaves it out and the baseline is simply cleared. ]]
	desynced: ((channel: any) -> ())?,
}

export type Inbound = {
	receive: (packed: buffer, instances: { Instance }?, sender: any?) -> (),
	drain: (channel: any) -> (),
	tick: () -> (),
	forget: (sender: any) -> (),
}

--[[ `pcall` of a function whose return pack is empty is typed as returning `boolean` alone, so the
     error cannot be destructured out of it. The alias widens the pack without changing what runs,
     and is hoisted so neither guard builds one per batch. ]]
local read: (...any) -> ...any = Batch.read

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
--[[
	`calls` and `statuses` carry the query correlation through the same wait.

	A reply is delivered on the caller's side by resuming a parked thread, and that thread is game
	code that may yield — so resuming it during the read phase would reintroduce the exact bug this
	structure exists to prevent, one packet later. A reply waits its turn in the pending list like
	everything else.

	`statuses` is `-1` for anything that is not a reply, never nil: a stale positive left over from
	a previous batch would make an ordinary packet dispatch as somebody's answer.
]]
type Pending = {
	channels: { any },
	senders: { any },
	values: { any },
	--[[ Which replicated value this is. Its own array rather than packed into `values`, because
	     packing would allocate a table per packet on the one path whose whole argument is that it
	     does not. Empty for every other class. ]]
	subjects: { any },
	sizes: { number },
	calls: { number },
	statuses: { number },
	count: number,
}

local function emptyPending(): Pending
	return {
		channels = {},
		senders = {},
		values = {},
		subjects = {},
		sizes = {},
		calls = {},
		statuses = {},
		count = 0,
	}
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
	local queries = config.queries
	local baselines = config.baselines
	local onDesync = config.desynced
	local agreement = config.agreement

	--[[
		The sender of the batch currently being **read**.

		Safe as shared state precisely because of the split above: the read phase runs no game code,
		so it cannot yield, so there is no window in which another batch can change this while it is
		still being used. It is never read after a handler has run.
	]]
	local sender: any = nil

	local queues: { [any]: Queue } = {}

	--[[
		Pending lists, held by whoever is walking one.

		~~Indexed by re-entrancy depth.~~ **That assumed claims and releases nest, and they do not.**
		Roblox resumes remote callbacks in whatever order their waits complete, not in nesting order,
		so a batch that yielded second and finished first put the depth back while another loop was
		still walking the list at that depth — and the next batch to arrive claimed that list out
		from under it, reset its count, and overwrote the entries it had not reached. Silent loss,
		then `attempt to index nil with 'handler'` on the receive path from ordinary traffic
		(`PLAN-M3` phase 9; found by an external review, reproduced in `transport_runtime`).

		A free list has no order to get wrong. A list is taken by a `receive`, `drain` or `tick` that
		is going to walk it, and given back when that walk ends; two overlapping walks hold different
		lists because neither has returned its own. The high-water mark is the number of dispatches
		in flight at once, which is what the depth counter was reaching for and could not express.

		At one batch a frame — every ordinary frame — this is still the same six arrays reused
		forever and still costs nothing.
	]]
	local free: { Pending } = { emptyPending() }

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

	--[[
		Everything this endpoint believed about a replicated channel, given up.

		A change is only meaningful against the value it was computed from, so a change that did not
		arrive — refused at any stage, for any reason — makes every change after it unreadable. There
		is no partial recovery and no way to notice later: the values would simply be wrong.

		So the baseline goes and the other end is asked to start again. `PLAN-M4` D-2 called this a
		break detector and expected a sequence number on the wire to find the gap; there is none,
		because **this endpoint already knows** — it is the one that refused the packet.
	]]
	local function desync(channel: any)
		--[[
			**Only the end that receives changes gives one up**, and the asymmetry is a bound rather
			than a tidiness.

			Replication flows server to client, so the client is the one that can lose a change. On
			the server a packet on a replicated id is a client sending something it must not — G6
			refuses it before decode — and the server's baseline is authoritative: nothing was lost.
			Clearing it there would let any peer force a full resend of everything it can see with
			one malformed byte, which is a cheaper amplifier than the resync packet that at least
			has to name a real channel.
		]]
		if isServer then
			return
		end

		local store = baselines

		if store then
			store.desync(sender, channel)
		end

		if onDesync then
			onDesync(channel)
		end
	end

	--[[
		The policy, and whether it said yes.

		Factored out of `call` because `serveQuery` needs the identical decision on a different
		thread, and D-1 and D-2 are exactly the kind of rule that gets one of its two copies fixed.
		The narrowed value is returned rather than assigned through, so neither caller can forget
		which of the two things a verdict carries.
	]]
	local function decide(channel: any, who: any?, ctx: any, value: any, bytes: number): (boolean, any)
		--[[ Annotated because it is read off an `any` channel and truth-tested, which narrows to a
		     type that is not callable. ]]
		local authorize: ((any, any) -> any)? = channel.authorize

		if not authorize then
			return true, nil
		end

		--[[
			A policy is game code, and game code does not get the batch.

			M2 wrapped the handler and left this call bare, which made the authorization layer a
			denial-of-service surface: one input that trips a game's policy takes every packet
			batched behind it, and the queue drain crosses senders, so those packets are not
			necessarily the same player's. `RESEARCH §3.8-R` is this failure at the codec layer,
			which netweave already avoids; `PLAN-M3` D-1 is the same discipline applied to the
			game's own code.

			`xpcall` with the module-level `traceback` handler allocates no closure per call.
		]]
		local ran, verdict = xpcall(authorize, traceback, ctx, value)

		if not ran then
			report(channel, who, "authorize", `the policy raised: {tostring(verdict)}`, bytes)
			return false, nil
		end

		--[[
			`ok == true`, not truthy, and only off a table.

			A policy that returns nothing is a policy someone forgot to finish, and the safe
			reading of an unfinished policy is "no" — this is the one place in netweave where a
			shrug must not mean yes. The pre-fix check was `if not allowed`, which admitted
			`ok = "yes"` and raised outright on `nil` (`PLAN-M3` D-2).

			Read out of the shared verdict record before anything else can overwrite it
			(`src/api/Policy.luau`).
		]]
		local shaped = if type(verdict) == "table" then verdict else nil

		if shaped == nil or shaped.ok ~= true then
			local reason = if shaped then shaped.reason else nil

			report(
				channel,
				who,
				"authorize",
				reason
					or (if shaped then "denied" else `the policy returned {typeof(verdict)}, not a verdict`),
				bytes
			)

			return false, nil
		end

		return true, shaped.value
	end

	--[[
		One request, from the policy to the answer, on a thread of its own.

		`nw.query` is the only class whose handler is allowed to yield, and that permission forces
		everything unusual here. It runs off the dispatch loop, so a datastore read does not hold up
		the rest of the batch or the frame's flush; it gets a detached context, because the shared
		per-player one is refreshed out from under a handler that yields; and every exit writes a
		reply, because the caller is parked on a deadline and silence costs it the whole timeout.

		The query record is a parameter rather than an upvalue so that the non-nil narrowing survives
		into it — this is spawned from a place where the field is still `Queries?`.
	]]
	local function serveQuery(
		serving: Query.Queries,
		channel: any,
		who: any,
		value: any,
		bytes: number,
		id: number
	)
		local ctx = Context.detached(who, channel.qualified)
		local allowed, narrowed = decide(channel, who, ctx, value, bytes)

		if not allowed then
			serving.answer(channel, who, id, Batch.REFUSED, nil)
			return
		end

		if narrowed ~= nil then
			value = narrowed
		end

		local handler: (...any) -> ...any = channel.handler

		--[[ Attached when the packet was read and gone by the time this ran. `:handle` cannot be
		     detached, but a namespace can be reset out from under an in-flight call, and calling nil
		     here would raise on a thread with nobody to catch it. ]]
		if not handler then
			serving.answer(channel, who, id, Batch.UNHANDLED, nil)
			return
		end

		local ok, result = xpcall(handler, traceback, ctx, value)

		if not ok then
			report(channel, who, "handler", tostring(result), bytes)
			serving.answer(channel, who, id, Batch.FAILED, nil)
			return
		end

		serving.answer(channel, who, id, Batch.OK, result)
	end

	local function call(channel: any, who: any?, value: any, bytes: number, id: number, subject: any?)
		--[[ Annotated so `xpcall` resolves: a handler read off an `any` channel is narrowed to "not
		     false or nil" by the caller's check, which is not a callable type. ]]
		local handler: (...any) -> ...any = channel.handler

		if not isServer then
			--[[ A client's inbound is the server's outbound, and the server is not a peer to be
			     checked. No context, no policy — the payload alone, and for a replicated channel
			     the subject in front of it, because the client keeps one value per subject and a
			     handler that could not tell them apart would be useless. A `nil` value there is the
			     subject going away. ]]
			--[[ Two statements rather than an `if` expression, which yields one value where this
			     needs two. ]]
			local ok, failure

			if channel.class == "replicate" then
				ok, failure = xpcall(handler, traceback, subject, value)
			else
				ok, failure = xpcall(handler, traceback, value)
			end

			if not ok then
				report(channel, nil, "handler", tostring(failure), bytes)
			end

			return
		end

		if channel.class == "query" then
			local serving = queries

			if not serving then
				report(channel, who, "handler", "this endpoint does not serve queries", bytes)
				return
			end

			--[[ The slot is taken here, synchronously, rather than on the spawned thread. Taking it
			     there would run the check after the thread it exists to prevent. ]]
			if serving.enter(channel, who, id) then
				serving.spawn(serveQuery, serving, channel, who, value, bytes, id)
			end

			return
		end

		local ctx = Context.acquire(who, channel.qualified)
		local allowed, narrowed = decide(channel, who, ctx, value, bytes)

		if not allowed then
			Context.release(who)
			return
		end

		if narrowed ~= nil then
			value = narrowed
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
		local taken: Pending? = table.remove(free)
		local list = taken or emptyPending()

		list.count = 0
		return list
	end

	local function walk(list: Pending)
		local channels = list.channels
		local senders = list.senders
		local values = list.values
		local subjects = list.subjects
		local sizes = list.sizes
		local calls = list.calls
		local statuses = list.statuses
		local count = list.count

		list.count = 0

		for index = 1, count do
			local channel = channels[index]
			local who = senders[index]
			local value = values[index]
			local subject = subjects[index]
			local id = calls[index]
			local status = statuses[index]

			channels[index] = nil
			senders[index] = nil
			values[index] = nil
			subjects[index] = nil

			--[[ A status of zero or more is a reply, and a reply resumes a thread instead of calling
			     a handler. Anything else — including a query *request* — goes to `call`. ]]
			if status >= 0 then
				local waiting = queries

				if waiting then
					waiting.answered(channel, id, status, value)
				end
			else
				call(channel, who, value, sizes[index], id, subject)
			end
		end

		--[[
			The list goes back **after** the loop, not before it.

			Returning it first looks harmless — the entries have already been read into locals — and
			is not: a handler that yields lets the next batch in, and that batch would then `claim`
			this very list and overwrite the entries this loop has not reached yet. The failure is
			silent and size-dependent, which is why it survived a first test: the interleaved batch
			only corrupts the outer one when it is at least as long.

			A raise inside the loop leaks one list rather than corrupting one, which is the trade the
			free list buys over the counter it replaced — and `dispatch` below takes even that back.
		]]
	end

	--[[
		Guarantee G4, structurally.

		`walk` calls game code through `call`, which `xpcall`s the policy and the handler, so the
		raises anyone thought of are already values. The two that broke G4 were the ones nobody
		thought of — a table in the sidecar, and a pooled list two loops both believed they owned —
		and both are fixed above. What is not fixed by fixing them is that the *next* one inherits
		the same shape: a raise here would leave the list unreturned and the rest of the batch
		undelivered with nothing said.

		So the claim stops resting on inspection. One `pcall` per dispatch, the list returned either
		way, and a raise that reaches here is reported like any other failure rather than escaping
		into the remote callback that called it. `PLAN-M3` phase 9.
	]]
	local attempt: (...any) -> ...any = walk

	local function dispatch(list: Pending)
		local ok, failure = pcall(attempt, list)

		table.insert(free, list)

		if not ok then
			report(nil, nil, "handler", `dispatch raised: {tostring(failure)}`, 0)
		end
	end

	--[[
		A channel nobody is listening to yet. The packets are kept rather than dropped, because a
		handler attached one frame late is an ordering accident and losing the traffic to it is a
		bug the game cannot see.
	]]
	local function enqueue(channel: any, who: any?, value: any, bytes: number)
		local queue = queues[channel]

		if not queue then
			local capacity = Settings.limitOf("queueCapacity") or DEFAULT_QUEUE_CAPACITY

			queue = {
				values = table.create(capacity),
				senders = table.create(capacity),
				capacity = capacity,
				read = 0,
				count = 0,
				dropped = 0,
			}

			queues[channel] = queue
		end

		if queue.count == queue.capacity then
			--[[ Drop the oldest and step the read cursor past it. Reported once per drop so a
			     forgotten `:listen` is visible rather than merely quiet. ]]
			queue.read = (queue.read + 1) % queue.capacity
			queue.count -= 1
			queue.dropped += 1

			report(channel, who, "queue", QUEUE_FULL, bytes)
		end

		local slot = (queue.read + queue.count) % queue.capacity
		queue.values[slot + 1] = value
		queue.senders[slot + 1] = who
		queue.count += 1
	end

	--[[ One string per class rather than one per packet.

	     This is the reason a hostile peer can provoke most cheaply — send anything at all on a
	     `state` or `event` id and every packet in the batch lands here — so building it per refusal
	     would have made the check that stops the flood the thing the flood costs. Six classes, and
	     `isServer` is fixed for the life of this `Inbound`, so the table cannot grow. ]]
	local directionReasons: { [string]: string } = {}

	local function directionReason(class: string): string
		local reason = directionReasons[class]

		if not reason then
			reason = `{class} is sent by the {if isServer then "server" else "client"}, so nothing `
				.. `may arrive on it here — netweave guarantee G6, which the declaration enforces at `
				.. `analysis and this enforces on the wire`
			directionReasons[class] = reason
		end

		return reason
	end

	--[[ The list the read phase is filling. Set for the duration of one `Batch.read`, which cannot
	     yield, for the same reason `sender` is safe. ]]
	local filling: Pending = emptyPending()

	--[[ Set when the pending set fills, cleared when a batch starts. Not a field on `Pending`
	     because a batch that arrives inside another batch's dispatch has its own, and the outer
	     one's state is restored around it the way `sender` and `filling` are. ]]
	local full = false

	--[[
		How long a peer waits between resyncs that are acted on, in `tick` calls — frames, where the
		driver runs it. Half a second at 60 Hz, which is the trade written out: an honest client's
		*first* ask is always honoured immediately, so this is only ever the gap before a *second*
		one, and a second one inside half a second is either a peer with a very bad connection or a
		peer trying to make the server work. The first gets its state a frame or two later; the
		second gets a sixtieth of what it asked for.
	]]
	local RESYNC_TICKS = 30

	local ticks = 0

	--[[ Per sender, the tick each channel's resync was last acted on; and per channel, the senders
	     who asked again too soon. Two shapes because they are walked from opposite ends: the first
	     by a packet that names a sender, the second by `tick`, which walks everything owed. ]]
	local resyncs: { [any]: { [any]: number } } = {}
	local owed: { [any]: { [any]: boolean } } = {}

	--[[ What the game configured, and what this endpoint enforces — the same number on a server and
	     no ceiling at all on a client. `refreshCeiling` below says why. Both are kept because the
	     reason strings quote the configured one, and a client that reports nothing still has to be
	     able to say what the limit was if it ever does. ]]
	local configuredCeiling = Settings.limitOf("pendingPerBatch")
	local pendingCeiling = if isServer then configuredCeiling else math.huge

	--[[
		The two reasons whose only variable is the ceiling, built when it moves rather than per
		refusal.

		An external review measured a 12,000-packet flood producing 11,744 distinct reason strings,
		against an `Observer` and a `Budget` whose comments both promise a refused packet allocates
		nothing (M3 phase 9). The promise was true of them and false here, which is the worst place
		for it to be false: the flood is the case the limit exists for, so the limit was paying
		garbage in proportion to the attack it was refusing.

		The ceiling changes only when the game reconfigures, so this is one interpolation per
		`nw.configure` rather than one per dropped packet.
	]]
	local ceilingReason = ""
	local ceilingReplyReason = ""

	--[[
		**The ceiling is the server's, and applying it on a client is what broke replication at scale.**

		The bound exists because the batch's size is chosen by an *untrusted* peer (`PLAN-M3` D-6). On
		a client the peer is the server: the batch is what this game chose to send, already bounded at
		the other end by this very limit, and refusing its tail saves no memory an attacker could have
		claimed — it drops traffic the game asked for, and reports it against a peer that cannot be
		asked to send less.

		On a replicated channel it costs more than the tail. Past the ceiling the client refuses, a
		refused change gives up the channel, and giving up clears the baselines it applied earlier in
		the same batch; the resync then makes the server clear what it believed, and the next tick
		sends the same oversized batch again. Measured with the real tick at the default limits before
		this line existed:

		  | subjects visible to one client | every frame |
		  |---|---|
		  | 256 | frame 1 converges, then 0 bytes |
		  | 257 | 1,543 B down, 5 B up, mirror stuck at 256, **both sides holding nothing** |
		  | 300 | 1,801 B down, 177 B up, 44 refusals and 44 resyncs, forever |

		One subject over the limit was a channel that never worked, and the suite could not see it
		because `tests/replication_runtime.luau` restored the limit after a single frame.

		This is the same asymmetry `Driver` already writes down for `Baseline` — bounded on the
		server, unbounded on the client — and for the same reason.
	]]
	local function refreshCeiling()
		local limit = Settings.limitOf("pendingPerBatch")

		if limit == configuredCeiling and ceilingReason ~= "" then
			return
		end

		configuredCeiling = limit
		pendingCeiling = if isServer then limit else math.huge
		ceilingReason = `batch holds more than {limit} packets; the rest were dropped`
		ceilingReplyReason = `the answer arrived in a batch holding more than {limit} packets and `
			.. `was dropped`
	end

	refreshCeiling()

	--[[ A query request that was refused before it ever reached a handler. The caller is already
	     parked on a deadline, so the refusal goes back as a code rather than being left for the
	     timeout to discover — the difference between a call that fails in a frame and one that
	     fails in five seconds.

	     Writing during the read phase is safe: `src/codec/Buffer.luau` keeps the incoming cursor and
	     the outgoing buffer in separate state, and nothing here calls game code. ]]
	local function decline(channel: any, who: any?, id: number?, status: number)
		local serving = queries

		if serving and id and isServer and channel and channel.class == "query" then
			serving.refuse(channel, who, id, status)
		end
	end

	--[[
		An answer, on the side that asked, held until dispatch.

		Resuming the parked thread here would run game code inside the read phase, and the thread it
		resumes is free to yield — which is the corruption the read-then-dispatch split exists to
		prevent, arriving through the one path that did not go through a handler.
	]]
	local function holdReply(channel: any, id: number, status: number, value: any?, bytes: number)
		local count = filling.count + 1

		if count > pendingCeiling then
			full = true
			report(channel, sender, "budget", ceilingReason, bytes)

			--[[
				A dropped *reply* is not like a dropped packet, because somebody is waiting for it.

				Reaching here needs `callsInFlight` above `pendingPerBatch`, which is a
				misconfiguration rather than a hostile peer — but what it produced before M3 phase 4's
				audit was a five second stall ending in "no answer within 5s", said about an answer
				that had arrived, decoded, and been thrown away one frame earlier. The caller is told
				what happened instead, on the next tick, which is later in this same frame.
			]]
			local waiting = queries

			if waiting and channel.class == "query" then
				waiting.abandon(channel, id, ceilingReplyReason)
			end

			return
		end

		filling.count = count
		filling.channels[count] = channel
		filling.senders[count] = sender
		filling.values[count] = value
		filling.subjects[count] = nil
		filling.sizes[count] = bytes
		filling.calls[count] = id
		filling.statuses[count] = status
	end

	local sink: Batch.Sink = {
		resolve = resolve,

		--[[ The endpoint's side of a query, not the packet's. A server reads requests, a client
		     reads replies, and neither ever reads the other (`src/transport/Batch.luau`). ]]
		answers = isServer,

		admit = function(channel: any, bytes: number): (string?, string?)
			--[[ Once the pending set is full the rest of the batch is refused here, before decode,
			     rather than decoded and then dropped. Refusing has to stay cheaper than accepting or
			     the limit becomes the amplifier. ]]
			if full then
				return ceilingReason, "budget"
			end

			--[[
				A peer whose declarations disagree with this one's is refused **before decode**, and
				that ordering is the point rather than an optimisation.

				Their ids map to different channels, so their bytes would not fail to decode — they
				would decode into whatever channel this peer has at that number, and be delivered to
				its handler as a well-formed payload. A wrong payload arriving successfully is worse
				than no payload, and it is the failure `PLAN-M3` D-7 is written against.

				Checked per packet rather than per batch because the hello is *in* the first batch:
				the packets behind it in that same batch are the first ones that must not land.
			]]
			if agreement then
				local disagreement = agreement.verdict(sender)

				if disagreement then
					return disagreement, "protocol"
				end
			end

			--[[
				Direction, on the wire rather than only in the views.

				A packet arriving on a channel this peer is the *sender* of is one nobody can
				legitimately send: `nw.state` and `nw.event` go server to client, and a client's
				packet on that id is a confused build or a hostile one. It was decoded and queued
				until M3 phase 9, and it could not be budgeted because those classes declare no rate —
				which is the argument for forbidding `rate` on them, resting on a check that was not
				there.

				Refused here, before decode, so a flood of them costs an id read and a seek. That is
				the same place and the same reason as the byte ceiling below.
			]]
			if not (if isServer then channel.fromClient else channel.fromServer) then
				return directionReason(channel.class), "direction"
			end

			--[[ The injected `admit` is the rate budget, which has one stage; naming it here rather
			     than defaulting keeps the two callers of `sink.refuse` symmetrical. ]]
			return admit(channel, sender, bytes), "budget"
		end,

		--[[ A peer announcing its own declarations. Handled here rather than routed onward, because
		     what it decides is whether the rest of this batch is admitted at all. ]]
		hello = function(hash: number, bytes: number)
			if not agreement then
				return
			end

			--[[ `greet` answers a reason only the first time a peer is found to be wrong, so this is
			     one report per mismatched peer rather than one per hello. Before M3 phase 9 the
			     mismatch was recorded and nothing was said until a data packet followed it. ]]
			local disagreement = agreement.greet(sender, hash)

			if disagreement then
				report(nil, sender, "protocol", disagreement, bytes)
			end
		end,

		--[[
			A peer asking for a replicated channel in full.

			Clearing what this endpoint believes that peer has is the whole answer: the next tick
			finds no baseline and writes a change against nothing, which is every field. There is no
			separate snapshot path to invoke because there is no separate snapshot.

			Refused rather than assumed when the id names nothing, or names something that is not
			replicated — a peer that can ask about an id it made up could otherwise make the server
			walk its channel table on demand.
		]]
		resync = function(id: number, bytes: number)
			--[[
				**A peer whose declarations disagree does not get to make this endpoint work.**

				Control packets are read before `sink.admit` because resolving id 0 would fail, and
				until M4 the verdict was consulted for `HELLO` and for data packets and not here — so
				a peer already refused at `protocol`, whose every data packet costs an id read and a
				seek, could still spend five bytes and buy a full state re-encode. `HELLO` stays
				exempt because it is how a disagreement is discovered and how it is cleared; nothing
				else is.
			]]
			if agreement then
				local disagreement = agreement.verdict(sender)

				if disagreement then
					report(nil, sender, "protocol", disagreement, bytes)
					return
				end
			end

			local channel = resolve(id)

			if not channel or channel.class ~= "replicate" then
				report(nil, sender, "replicate", NOT_REPLICATED, bytes)
				return
			end

			local store = baselines

			if not store then
				return
			end

			--[[
				**Coalesced, not refused**, and the difference is the whole design.

				What a resync costs is not the clear — that is a table drop — it is the tick after it,
				which finds no baseline and writes every subject that peer can see. One five-byte
				packet a frame therefore bought a full state re-encode a frame, measured at 601 bytes
				a frame downstream for a hundred subjects against a steady state of zero, outside
				every budget netweave has: a replicated channel declares no `rate`, so `Budget.admit`
				has nothing to charge (M4 report).

				Refusing the extra ones would be worse than it sounds. A client asks once, at the
				moment it gave up on the channel, and **nothing retries** — it has already cleared its
				own baselines, so a refused resync leaves it holding nothing while the server believes
				it holds everything, wrong for the rest of the session. A bound that can strand an
				honest client is not a bound, it is a second defect.

				So the ask is never dropped: it is honoured now if the window is open, and remembered
				and honoured by `tick` if it is not. An attacker gets one full resend per window
				however fast they send; a client that lost a change gets its resend on the next frame,
				because the window starts open.
			]]
			local seen = resyncs[sender]

			if not seen then
				seen = {}
				resyncs[sender] = seen
			end

			local honoured = seen[channel]

			if honoured and ticks - honoured < RESYNC_TICKS then
				seen[channel] = honoured
				owed[channel] = owed[channel] or {}
				owed[channel][sender] = true
				return
			end

			seen[channel] = ticks
			store.desync(sender, channel)
		end,

		deliver = function(channel: any, value: any, bytes: number, id: number?)
			--[[
				A packet with no handler is queued and does **not** count against `pendingPerBatch`,
				which an external review read as the ceiling being bypassed. Examined in M3 phase 9
				and left alone, because the two limits answer different questions and moving this one
				would break the thing the queue is for.

				What the queue holds is bounded by `queueCapacity`, per channel, and it drops the
				*oldest* — which is the right policy for its case, a `:listen` that attached a frame
				late. The batch ceiling drops the newest, so applying it here would lose exactly the
				traffic the queue exists to keep.

				What is left is decode *work*, and on an inbound class that is what `rate` licenses:
				the packets would have been decoded anyway had a handler been attached. The genuinely
				unbounded case the finding pointed at was an outbound-class id, which declares no rate
				and is now refused above, before decode.
			]]
			if not channel.handler then
				--[[
					A query nobody is answering is refused, not queued.

					The queue exists so a handler attached one frame late does not lose the traffic
					that arrived first, and for a fire-and-forget class late is better than never. A
					request is the opposite: the caller is holding a thread against a deadline, so
					keeping the request until a handler appears converts an immediate, legible
					"nothing is listening" into a timeout that says nothing at all.
				]]
				if isServer and id and channel.class == "query" then
					decline(channel, sender, id, Batch.UNHANDLED)
					return
				end

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

			--[[
				The pending set is bounded, and the bound is the price of reading a batch to completion
				before dispatching any of it.

				That order is not negotiable — a yielding handler plus a global decode cursor attributes
				one player's bytes to another (`PLAN-M2` phase 3) — but it means every decoded value in
				a batch is live at once. The benchmark measured what that costs: `ArrayHeavy` decode
				allocation went 1184.8 B to 9309.2 B on the same payload, because two hundred decoded
				values were alive where one had been. The batch's size is chosen by an untrusted client,
				which makes it a resource limit rather than a performance note (`PLAN-M3` D-6).

				Past the bound the batch stops. Dispatching early to make room is the one thing that
				cannot be done here, because it is the order the bound exists to protect.
			]]
			local count = filling.count + 1

			if count > pendingCeiling then
				full = true
				report(channel, sender, "budget", ceilingReason, bytes)
				decline(channel, sender, id, Batch.REFUSED)
				return
			end

			filling.count = count
			filling.channels[count] = channel
			filling.senders[count] = sender
			filling.values[count] = value
			filling.subjects[count] = nil
			filling.sizes[count] = bytes
			filling.calls[count] = id or 0
			filling.statuses[count] = -1
		end,

		--[[
			A replicated subject's change, folded into what this endpoint has.

			The fold happens **here, during the read**, because the bytes are here and nowhere else;
			the handler runs in the dispatch phase like every other class, so a handler that yields
			cannot let the next packet decode against a half-applied value. That is D-6's
			read-then-dispatch applied to a payload that mutates state rather than replacing it.
		]]
		change = function(channel: any, subject: any, bytes: number)
			local store = baselines

			if not store then
				report(channel, sender, "replicate", NO_BASELINES, bytes)
				return
			end

			local base = store.of(sender, channel, subject)
			local value, failure = channel.delta.apply(base)

			--[[ A change that could not be read is not a removal, and treating it as one would drop
			     a subject because a peer sent a short packet. The baseline is left exactly as it was
			     and the channel is given up on: this endpoint cannot know how much of that change it
			     took before it ran out, so every change after it is against a value that may or may
			     not be what the sender thinks. ]]
			if failure then
				report(channel, sender, "parse", failure, bytes)
				desync(channel)
				return
			end

			if value == nil then
				--[[ Gone. Dropped here rather than left for the handler, so that a handler which
				     raises cannot leave this endpoint believing it still has the subject. ]]
				store.drop(sender, channel, subject)
			else
				store.keep(sender, channel, subject, value)
			end

			local count = filling.count + 1

			if count > pendingCeiling then
				full = true
				report(channel, sender, "budget", ceilingReason, bytes)

				--[[ The change was applied and is being dropped before the handler sees it, which
				     leaves the game's own mirror behind this endpoint's baseline. Everything on this
				     channel has to be asked for again. ]]
				desync(channel)
				return
			end

			filling.count = count
			filling.channels[count] = channel
			filling.senders[count] = sender
			filling.values[count] = value
			filling.subjects[count] = subject
			filling.sizes[count] = bytes
			filling.calls[count] = 0
			filling.statuses[count] = -1
		end,

		reply = holdReply,

		refuse = function(channel: any?, stage: string, reason: string, bytes: number, id: number?)
			report(channel, sender, stage :: Observer.Stage, reason, bytes)

			--[[ Any refusal of a replicated packet is a change this endpoint will never see, and
			     every change after it is relative to one it does not have. The stage does not
			     matter — parse, budget or protocol, the consequence is the same. ]]
			if channel and channel.class == "replicate" then
				desync(channel)
			end

			--[[
				A refused query is answered rather than left hanging, in both directions.

				On the server the caller is told its request was thrown away; on the client a reply
				that would not decode resolves the parked thread as a failure instead of costing it
				the whole timeout. The rule is the same from either end: a call that cannot be
				answered gets an answer saying so.
			]]
			if not id or not channel or channel.class ~= "query" then
				return
			end

			if isServer then
				decline(channel, sender, id, Batch.REFUSED)
			else
				holdReply(channel, id, Batch.FAILED, nil, bytes)
			end
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
			local outerFull = full

			sender = from
			filling = list
			full = false
			refreshCeiling()

			--[[ The same reason as `dispatch`: the read phase calls no game code and should not be
			     able to raise, and "should not" is what the sidecar was. Restoring the three
			     upvalues on both paths is what keeps a raise from costing every batch after it. ]]
			local ok, failure = pcall(read, packed, instances, sink)

			sender = outerSender
			filling = outerFilling
			full = outerFull

			if not ok then
				report(nil, from, "parse", `the read phase raised: {tostring(failure)}`, buffer.len(packed))
			end

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
				--[[ Never a query: a request with no handler is refused rather than queued, so
				     nothing in a queue was ever waiting on an answer. ]]
				list.calls[count] = 0
				list.statuses[count] = -1

				queue.values[slot + 1] = nil
				queue.senders[slot + 1] = nil
				queue.read = (slot + 1) % queue.capacity
				queue.count -= 1
			end

			dispatch(list)
		end,

		--[[ Once a frame. Every intent that arrived since the last one is delivered, at most one
		     per player per channel. ]]
		tick = function()
			ticks += 1

			--[[ The resyncs that arrived inside a window, honoured now that one has passed. Walked
			     rather than scheduled: the table holds only peers who asked twice in half a second,
			     which in a healthy server is nobody and the loop is one `next` that finds nothing. ]]
			local store = baselines

			if store then
				for channel, senders in owed do
					for who in senders do
						local seen = resyncs[who]
						local honoured = seen and seen[channel]

						if not honoured or ticks - honoured >= RESYNC_TICKS then
							senders[who] = nil

							if seen then
								seen[channel] = ticks
							end

							store.desync(who, channel)
						end
					end
				end
			end

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
					--[[ Intents only, and an intent is not a query. ]]
					list.calls[count] = 0
					list.statuses[count] = -1

					bytes[who] = nil
				end
			end

			dispatch(list)
		end,

		--[[ A player who left. Their pending intent is input nobody is waiting for, and their
		     context record would otherwise outlive them. ]]
		forget = function(who: any)
			--[[ A departed peer's resync bookkeeping, which would otherwise hold their record for
			     the life of the server — the same leak `PLAN-M3` D-6 is about, one table over. ]]
			resyncs[who] = nil

			for _, senders in owed do
				senders[who] = nil
			end

			for _, byPlayer in coalescedValue do
				byPlayer[who] = nil
			end

			for _, bytes in coalescedBytes do
				bytes[who] = nil
			end

			--[[
				And whatever they left in a queue, which an external review found still there (M3
				phase 9).

				A queue holds packets for a channel nobody is listening to yet. Attaching the
				`:listen` afterwards used to dispatch them all, including the ones sent by a player
				who has since left — so a command ran for somebody who is gone, with
				`ctx.character == nil`, and `Context.acquire` built a fresh record for the departed
				`Player` to run it against, which nothing would ever forget again.

				Compacted in place rather than rebuilt: the ring is walked in arrival order and the
				survivors are written back from `read`, so the entry being written is always at or
				behind the entry being read and the order the queue exists to preserve is kept.
			]]
			for channel, queue in queues do
				if queue.count == 0 then
					continue
				end

				local kept = 0

				for index = 0, queue.count - 1 do
					local slot = (queue.read + index) % queue.capacity
					local from = queue.senders[slot + 1]

					if from ~= who then
						local target = (queue.read + kept) % queue.capacity
						queue.values[target + 1] = queue.values[slot + 1]
						queue.senders[target + 1] = from
						kept += 1
					end
				end

				--[[ The tail the survivors no longer reach. Nil'd rather than left, because a
				     queued value holds every table and Instance the packet decoded into. ]]
				for index = kept, queue.count - 1 do
					local slot = (queue.read + index) % queue.capacity
					queue.values[slot + 1] = nil
					queue.senders[slot + 1] = nil
				end

				local dropped = queue.count - kept
				queue.count = kept

				if dropped > 0 then
					report(channel, who, "queue", `dropped {dropped} queued packets; the sender left`, 0)
				end
			end

			Context.forget(who)
		end,
	}
end

return Inbound
