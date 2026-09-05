--!strict
--!optimize 2

--[=[
	@class Query

	Request and response: the call ids, the deadlines, and the accounting that keeps a slow handler
	from becoming a way to hold the server.

	Internal.
]=]

--[[
	This module exists because of one measured gap. Blink (`Generator/init.luau:723-745`) and Zap
	(`client.rs:1329`) both key their pending calls by a **u8**, so 256 unanswered calls is a hard
	ceiling and the 257th is dropped with a raise — and neither has a timeout at all
	(`grep -ri timeout blink/src` returns nothing). The pattern in both is `Calls[id] =
	coroutine.running()` then `coroutine.yield()`, so a peer that never answers parks the caller's
	thread for the lifetime of the session. `RESEARCH §3.7-G`.

	Flamework, from the other side of the ecosystem, has the timeouts and the typed failures and
	pays for them with a Promise per call (`RESEARCH §3.6-A`). §3.7-G calls that "the clearest
	evidence that the structure axis and the byte axis fail in exactly opposite directions".

	netweave takes the resume-the-thread-directly shape from Blink, the deadlines and the
	per-player cleanup from Flamework, and a **varint** call id from neither, which removes the
	ceiling both of them have.

	Three bounds live here, and all three are resources an untrusted peer can spend:

	  1. **In flight, per player.** A query handler is the one handler netweave lets yield, so a
	     player whose handler blocks on a datastore holds a thread until it returns. `callsInFlight`
	     bounds how many they may hold at once.
	  2. **Outstanding, on the caller.** The same number from the other end: how many answers one
	     game may be waiting for.
	  3. **The deadline.** `timeout` is required on the declaration, so there is no unlimited to
	     forget to set.
]]

local Batch = require("./Batch")
local Config = require("../api/Config")
local Observer = require("../api/Observer")

local Query = {}

--[[
	Two varint bytes, and the wrap is what keeps it there.

	A call id is only ever meaningful while its call is outstanding, and `callsInFlight` caps that
	at 4096 — well under this — so the search for a free id below always terminates and two live
	calls can never collide. Blink and Zap's u8 is the same idea with the ceiling set three orders
	of magnitude lower, and theirs is a hard failure rather than a wrap.
]]
local CALL_MAX = 16383

--[[
	What the caller is told, per status code. Deliberately short and deliberately netweave's own
	words: the server's reason for refusing never crosses the wire (`src/transport/Batch.luau`,
	`PLAN-M3` D-12), so there is nothing here to interpolate a policy's message into.
]]
local REASON: { [number]: string } = {
	[Batch.REFUSED] = "the server refused it",
	[Batch.FAILED] = "the handler failed",
	[Batch.UNHANDLED] = "no handler is attached on the server",
	[Batch.BUSY] = "the server is already holding this player's call limit",
}
table.freeze(REASON)

--[[ One record per outstanding call, on the calling side.

     This allocates, and it is the same argument `Context.detached` makes: a query has already paid
     for a round trip and a parked thread, so a table to remember what is parked is not the cost
     that matters. The per-packet paths above this one still allocate nothing. ]]
type Call = {
	thread: thread,
	channel: any,
	deadline: number,
	--[[ Set by `abandon` when the answer arrived and could not be kept. Without it the caller waits
	     out the whole timeout and is then told nothing answered, which is a lie about a packet that
	     was decoded and discarded. ]]
	reason: string?,
}

--[[ One record per player with a call in flight, on the answering side. The call ids are kept as a
     set rather than a count alone, so that a client repeating an id cannot make the count and the
     reality disagree — see `enter`. ]]
type Slots = {
	count: number,
	calls: { [number]: true },
}

--[=[
	@interface Config
	@within Query
	.request (channel: any, call: number, value: any) -> () -- put a request on the wire
	.reply (channel: any, who: any, call: number, status: number, value: any?) -> () -- put an answer on the wire
	.spawn (target: any, ...any) -> () -- run a function, or resume a thread
	.clock (() -> number)? -- defaults to `os.clock`

	`spawn` is injected rather than reached for, because `task` does not exist under lune and this
	module has to be testable there — the same reason `Budget` takes its clock. Roblox passes
	`task.spawn`, which both starts a function on a fresh thread and resumes a parked one; a test
	passes something it can drive by hand.
]=]
export type Config = {
	request: (channel: any, call: number, value: any) -> (),
	reply: (channel: any, who: any, call: number, status: number, value: any?) -> (),
	spawn: (target: any, ...any) -> (),
	clock: (() -> number)?,
}

--[=[
	@interface Queries
	@within Query

	The half of this module `Inbound` needs. Passed to `Inbound.new` as one record rather than four
	callbacks, so an endpoint either serves queries or does not.
]=]
export type Queries = {
	spawn: (target: any, ...any) -> (),
	enter: (channel: any, who: any, call: number) -> boolean,
	answer: (channel: any, who: any, call: number, status: number, value: any?) -> (),
	refuse: (channel: any, who: any, call: number, status: number) -> (),
	answered: (channel: any, call: number, status: number, value: any?) -> (),
	abandon: (channel: any, call: number, reason: string) -> (),
}

export type Query = {
	spawn: (target: any, ...any) -> (),
	enter: (channel: any, who: any, call: number) -> boolean,
	answer: (channel: any, who: any, call: number, status: number, value: any?) -> (),
	refuse: (channel: any, who: any, call: number, status: number) -> (),
	answered: (channel: any, call: number, status: number, value: any?) -> (),

	abandon: (channel: any, call: number, reason: string) -> (),

	invoke: (channel: any, args: any) -> (any?, string?),
	tick: () -> (),
	forget: (who: any) -> (),

	outstanding: () -> number,
	inflight: (who: any) -> number,
}

--[=[
	@within Query
	@function new
	@param config Config
	@return Query
]=]
function Query.new(config: Config): Query
	local request = config.request
	local reply = config.reply
	local spawn = config.spawn
	local now = config.clock or os.clock

	--[[ The calling side. ]]
	local pending: { [number]: Call } = {}
	local outstanding = 0
	local nextCall = 0

	--[[ The answering side. ]]
	local slots: { [any]: Slots } = {}

	--[[ Reused by `tick`, which cannot resume a thread while it is walking `pending` — see there. ]]
	local expired: { number } = {}

	local function report(channel: any, who: any?, reason: string)
		--[[ Zero bytes, and that is honest rather than lazy: a timeout is the absence of a packet
		     and a refusal code arrived as a packet the reader already counted. Charging either to
		     this channel's byte tally would double-count the one and invent the other. ]]
		Observer.emit(channel.qualified, who, "query", reason, 0)
	end

	--[[
		Put an answer on the wire, whatever happens.

		`reply` reaches `Batch.writeReply`, which encodes the handler's return value — and a handler
		returning something the `returns` schema forbids raises there, the same as any other encode.
		That raise is on a thread this module spawned, inside the receive path's blast radius, so it
		is caught and converted into the status the caller was going to need anyway.
	]]
	local function send(channel: any, who: any, call: number, status: number, value: any?)
		if status == Batch.OK then
			local ok, failure = pcall(reply, channel, who, call, Batch.OK, value)

			if ok then
				return
			end

			Observer.emit(
				channel.qualified,
				who,
				"handler",
				`the answer did not encode: {tostring(failure)}`,
				0
			)

			status = Batch.FAILED
		end

		--[[ A status-only reply has no payload to encode, so this cannot fail for a reason the game
		     caused. It is still guarded: this runs on the receive path's behalf and G4 says nothing
		     there raises, so a surprise here has to become a report rather than an error. ]]
		local ok, failure = pcall(reply, channel, who, call, status, nil)

		if not ok then
			Observer.emit(channel.qualified, who, "send", `the reply did not go out: {tostring(failure)}`, 0)
		end
	end

	local self: Query

	self = {
		spawn = spawn,

		--[=[
			@within Query
			@function enter

			Take a call slot for this player, or refuse the call and say so.

			Called on the receive path, synchronously, before anything is spawned — so a player over
			the limit costs a reply and nothing else.
		]=]
		enter = function(channel: any, who: any, call: number): boolean
			local record = slots[who]

			if not record then
				record = { count = 0, calls = {} }
				slots[who] = record
			end

			--[[
				A repeated call id from the same player, refused.

				Without this the count and the set disagree: two entries increment `count` twice and
				set one key, the first answer clears that key, and the second finds nothing to clear
				and never gives the slot back. Sixteen repeats of one id would retire this player's
				call budget permanently, which is a denial of service a client writes in one line.
			]]
			if record.calls[call] then
				report(channel, who, `call id {call} is already in flight`)
				send(channel, who, call, Batch.REFUSED, nil)
				return false
			end

			local ceiling = Config.limitOf("callsInFlight")

			if record.count >= ceiling then
				--[[ The bound is per player rather than per channel. The resource is a thread parked
				     inside a handler, and a thread does not become cheaper because it is parked in a
				     different handler — so one player's slow query cannot be paid for out of their
				     own budget on another channel, which is the point. ]]
				report(channel, who, `{record.count} calls already in flight, the limit is {ceiling}`)
				send(channel, who, call, Batch.BUSY, nil)
				return false
			end

			record.count += 1
			record.calls[call] = true

			return true
		end,

		--[=[
			@within Query
			@function answer

			The end of a handler that took a slot. Releases it and replies.

			A call whose player has left is dropped here rather than written: `Outbound.forget` has
			already discarded their parked batch, and `switchTo` would build a new one for a
			destination that will never be flushed to anyone.
		]=]
		answer = function(channel: any, who: any, call: number, status: number, value: any?)
			local record = slots[who]

			if not record or not record.calls[call] then
				return
			end

			record.calls[call] = nil
			record.count -= 1

			if record.count == 0 then
				slots[who] = nil
			end

			send(channel, who, call, status, value)
		end,

		--[=[
			@within Query
			@function refuse

			An answer for a call that never took a slot — refused while the batch that carried it was
			still being read, so the player is by definition still here.
		]=]
		refuse = function(channel: any, who: any, call: number, status: number)
			send(channel, who, call, status, nil)
		end,

		--[=[
			@within Query
			@function invoke
			@param channel Channel
			@param args any
			@return (any?, string?)

			Send a request and park this thread until the answer, the refusal, or the deadline.
		]=]
		invoke = function(channel: any, args: any): (any?, string?)
			--[[ Checked before anything is written. The alternative is a request on the wire that
			     nobody is waiting for, answered into a pending table that has no entry for it. ]]
			if not coroutine.isyieldable() then
				error(
					`{channel.qualified}:invoke waits for the answer, so it has to be called from a `
						.. `thread that can yield. Wrap the call: task.spawn(function() ... end).`,
					3
				)
			end

			local ceiling = Config.limitOf("callsInFlight")

			if outstanding >= ceiling then
				--[[ The caller's own bound, and it is the same number as the server's because it
				     counts the same thing from the other end: this player's unanswered calls. A game
				     that trips it is issuing requests faster than the server answers them, and the
				     honest thing is to say so now rather than at the deadline. ]]
				local reason = `{outstanding} calls already waiting, the limit is {ceiling}`
				report(channel, nil, reason)
				return nil, reason
			end

			local call = nextCall

			--[[ Wrapping, and skipping anything still outstanding. `callsInFlight` caps at 4096 and
			     the id space is 16383, so this terminates on the first or second try and can never
			     hand out an id another call is still waiting on. ]]
			repeat
				call = if call >= CALL_MAX then 1 else call + 1
			until pending[call] == nil

			nextCall = call

			--[[ The request goes out before the record exists. A value the schema forbids raises
			     here, the same as `send` on any other class does — and this order is what makes that
			     raise leave nothing behind: no pending entry, no slot, no id to reclaim. ]]
			request(channel, call, args)

			pending[call] = {
				thread = coroutine.running(),
				channel = channel,
				deadline = now() + channel.timeout,
				reason = nil,
			}

			outstanding += 1

			return coroutine.yield()
		end,

		--[=[
			@within Query
			@function answered

			A reply arrived. Resumes whoever is waiting for it.
		]=]
		answered = function(channel: any, call: number, status: number, value: any?)
			local record = pending[call]

			--[[ A reply nobody is waiting for: the call already timed out, or the server answered
			     it twice. Dropped without a report — the timeout was reported when it fired, and
			     saying so a second time would make a channel that recovered look like one that
			     failed twice. ]]
			if not record then
				return
			end

			--[[ The id is the caller's own and the channel came off the wire, so this pairs them
			     before resuming. It is not a hostile case — only the server sends replies — but a
			     resumed thread receiving another channel's answer is the kind of wrong that would
			     be diagnosed as a codec bug. ]]
			if record.channel ~= channel then
				return
			end

			pending[call] = nil
			outstanding -= 1

			if status == Batch.OK then
				spawn(record.thread, value, nil)
				return
			end

			local reason = REASON[status] or `refused with status {status}`
			report(channel, nil, reason)
			spawn(record.thread, nil, reason)
		end,

		--[=[
			@within Query
			@function abandon
			@param channel Channel
			@param call number
			@param reason string

			Give up on a call whose answer arrived and could not be kept.

			The only caller is the pending-set ceiling: a batch past `pendingPerBatch` stops, and if
			one of the packets it stopped on was a reply then the answer was decoded and thrown away
			with a caller still parked on it.
		]=]
		--[[
			The thread is **not** resumed here, and that is the whole reason this function exists
			rather than a call to `answered`.

			`abandon` runs inside the read phase, where resuming means running game code that is free
			to yield — the corruption `Inbound`'s read-then-dispatch split exists to prevent. Moving
			the deadline into the past hands the resume to `tick`, which runs later in the same frame
			(`src/transport/Driver.luau`), so the caller still gives up in a frame rather than at its
			timeout, and the reason it is given is what actually happened.
		]]
		abandon = function(channel: any, call: number, reason: string)
			local record = pending[call]

			if not record or record.channel ~= channel then
				return
			end

			record.deadline = -math.huge
			record.reason = reason
		end,

		--[=[
			@within Query
			@function tick

			Resolve every call whose deadline has passed, and every call that was abandoned. Called
			once a frame.
		]=]
		tick = function()
			if outstanding == 0 then
				return
			end

			local at = now()
			local count = 0

			--[[
				Collected first, resumed second, and the two halves cannot be merged.

				A resumed thread is game code, and the first thing a game does with a timed-out query
				is often to retry it — which inserts into `pending` from inside the loop that is
				walking `pending`. Adding a key to a table being iterated is undefined in Luau, so
				the resume has to happen after the walk has finished.
			]]
			for call, record in pending do
				if at >= record.deadline then
					count += 1
					expired[count] = call
				end
			end

			if count == 0 then
				return
			end

			for index = 1, count do
				local call = expired[index]
				expired[index] = nil

				local record = pending[call]

				if record then
					pending[call] = nil
					outstanding -= 1

					local reason = record.reason or `no answer within {record.channel.timeout}s`
					report(record.channel, nil, reason)
					spawn(record.thread, nil, reason)
				end
			end
		end,

		--[=[
			@within Query
			@function forget

			A player who left. Their call slots are released so the budget does not leak, and any
			answer their handlers eventually produce is dropped by [Query.answer].

			:::caution
			A handler already parked inside a yield is **not** cancelled, because a yielded Luau
			coroutine cannot be. What is released is the accounting; the thread itself returns when
			whatever it is waiting on returns, finds its slot gone, and writes nothing.
			:::
		]=]
		forget = function(who: any)
			slots[who] = nil
		end,

		--[=[
			@within Query
			@function outstanding
			@return number
			@private

			Calls this peer is waiting on. Exposed so a test can assert the count rather than infer
			it from behaviour.
		]=]
		outstanding = function(): number
			return outstanding
		end,

		--[=[
			@within Query
			@function inflight
			@param who Player
			@return number
			@private

			Calls this player is holding open on this peer.
		]=]
		inflight = function(who: any): number
			local record = slots[who]
			return if record then record.count else 0
		end,
	}

	return self
end

return Query
