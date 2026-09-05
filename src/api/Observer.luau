--!strict
--!optimize 2

--[=[
	@class Observer

	Where rejections go. Nothing in netweave is thrown at the game: a packet that fails to parse,
	exceeds its budget or fails authorization is delivered here as a value.

	```lua
	nw.observe(function(rejection)
		Analytics:report(rejection.channel, rejection.stage, rejection.reason)
	end)
	```

	This is also what makes rejection rates *measurable*. `RESEARCH §3-G6` records that no surveyed
	library reports them, and `§3.7-K` records what that costs: Warp blackholes a player whose
	packet fails and nothing anywhere says so.
]=]

--[[
	Guarantee G4 lives here. Wire data must never reach `error()`, so every receive-path failure
	has to have somewhere to go that is not the call stack — otherwise one hostile packet aborts
	the batch, which is the failure Blink and Zap both have (`RESEARCH §3.8-R`).
]]

local Config = require("./Config")

local Observer = {}

--[=[
	@type Stage "parse" | "budget" | "authorize" | "handler" | "queue" | "send" | "protocol" | "query"
	@within Observer

	How far a packet got before it was refused.

	| Stage | Meaning |
	|---|---|
	| `parse` | the bytes did not decode against the channel's schema |
	| `budget` | the sender is over the channel's declared `rate` |
	| `authorize` | the payload decoded and was in budget, and a policy said no |
	| `handler` | the packet was delivered and the game's own handler threw |
	| `queue` | nothing is listening on that channel yet, and the backlog is full |
	| `send` | netweave refused to put a packet on the wire |
	| `protocol` | the peer is on a different set of channel definitions |
	| `query` | a `nw.query` call came back without an answer |

	The first three are worth separating because they mean different things about the sender.
	`parse` is a stale client or an attacker; `budget` is a flood; `authorize` is a player asking
	for something they are not entitled to.

	`handler` and `queue` are about this game rather than the sender: one says a handler threw, the
	other that no handler is attached and the backlog has started dropping. Both are the kind of
	thing that is otherwise noticed as "some packets do not seem to arrive".

	`send` points the other way entirely — netweave refusing *this* game's own outgoing packet. The
	only case in M2 is an unreliable payload over Roblox's size limit, which Roblox enforces by
	dropping silently, so without a signal here it is invisible from both ends (`RESEARCH §3.7-F`).

	`protocol` is the odd one: it fires once when a peer joins on a hash that does not match, not per
	packet. No surveyed library checks this at all, so the failure it replaces is a stale client that
	connects successfully and is then refused on every packet forever, with nothing saying why.

	`query` is the caller's side of a request that produced no answer — a timeout, or a refusal the
	server sent back as a code. The refusal itself was already reported on the server at whichever
	stage made it, so this is not a duplicate: it is the same event seen from the end that was
	waiting, which is the end that has to decide what to do about it.
	`direction` is guarantee G6 arriving on the wire. The declaration makes a direction violation an
	analysis error in the game's own code, which is where it belongs and where it stops nothing a
	*peer* does — a client can put any id in a packet it writes. Until M3 phase 9 the server decoded
	and queued those, and could not budget them either, because the classes they name declare no
	rate.
]=]
export type Stage =
	"parse"
	| "budget"
	| "authorize"
	| "handler"
	| "queue"
	| "send"
	| "protocol"
	| "query"
	| "direction"

--[=[
	@interface Rejection
	@within Observer
	.channel string -- the qualified name, `"combat.fireWeapon"`
	.player Player? -- nil for a rejection on the client, or before the sender is known
	.stage Stage
	.reason string
	.bytes number -- payload size, for attributing bandwidth to traffic that was thrown away

	:::caution
	The record is **reused**. Read what you need inside the observer; do not retain it. Under a
	flood the rejection path is the hot path, and allocating one table per refused packet would
	hand an attacker a way to make refusing cost more than accepting.
	:::
]=]
export type Rejection = {
	channel: string,
	player: Player?,
	stage: Stage,
	reason: string,
	bytes: number,
}

export type Observer = (rejection: Rejection) -> ()

local observers: { Observer } = {}
local count = 0

--[[
	Removal is a tombstone, because `emit` may be walking the list when it happens.

	An observer that stops observing from inside its own call is ordinary code — "warn once, then
	detach" — and `table.remove` used to shift the observer behind it into the index the loop had
	already passed, so that one was skipped and the last index read `nil`. `xpcall(nil, ...)` does
	not raise, so the miss was silent (M3 phase 9).

	The slot is overwritten with `NOOP` instead and the list is compacted the next time nothing is
	iterating it, which is a bounded amount of work with no allocation and no ordering to get wrong.
]]
local function NOOP() end

local emitting = 0
local tombstones = false

local function compact()
	if not tombstones or emitting > 0 then
		return
	end

	local kept = 0

	for index = 1, count do
		local observer = observers[index]

		if observer ~= NOOP then
			kept += 1
			observers[kept] = observer
		end
	end

	for index = kept + 1, count do
		observers[index] = nil
	end

	count = kept
	tombstones = false
end

--[[ One record, refilled per rejection. See the caution on `Rejection`. ]]
local record: Rejection = {
	channel = "",
	player = nil,
	stage = "parse",
	reason = "",
	bytes = 0,
}

--[[
	An observer is game code and can therefore throw. If it did so straight into the receive loop
	it would abort the batch — the exact failure G4 exists to prevent, reintroduced by the
	mechanism meant to report it. `xpcall` with a shared handler allocates no closure per call.
]]
local function report(message: string): string
	return message
end

--[[
	The default sink, and the reason `nw.observe` is no longer the only way to find out.

	M2 shipped every one of these stages and then returned early when nothing was observing, so a
	game that attached no observer got silent drops at all six. That is precisely what
	`RESEARCH §3.7-K` faults Warp for — a player blackholed with nothing anywhere saying so — and
	building the signal and not raising it reproduces the fault with extra steps.

	It goes quiet on its own. One channel and stage prints `repeatsPerDiagnostic` times and then
	says it is done, because the failure mode of a default-on log is that a refusal storm becomes
	the outage. `"error"` is the opt-in to every occurrence, and even there nothing raises: these
	are rejections carrying wire data, and G4 has no exceptions.
]]
local seen: { [string]: number } = {}

--[[ Injected for the same reason `Budget` injects its clock: `warn` writes somewhere a test cannot
     read, so a sink that is only ever eyeballed is a sink nobody has asserted. Defaults to `warn`
     and is private. ]]
local sink: (string) -> () = warn

--[[
	Counters, kept because the sink deliberately goes quiet.

	A default sink that reported every refusal would become the outage under a flood, so it prints
	three times per channel and stage and then stops. That is right for a console and useless for a
	question like "is this channel refusing more than it did an hour ago" — which is the question
	that distinguishes a bug from an attack, and the one `RESEARCH §3-G6` says nobody can answer.

	Two integers per channel and stage. The table for a channel is allocated on its first refusal
	and refilled after that, so a sustained flood allocates nothing: under load the rejection path
	is the hot path, and making refusal cost more than acceptance is how a limiter becomes an
	amplifier.
]]
type Counter = { count: number, bytes: number }

local tallies: { [string]: { [string]: Counter } } = {}
local total = 0
local since = os.clock()

local function tally(channel: string, stage: Stage, bytes: number)
	local byStage = tallies[channel]

	if not byStage then
		byStage = {}
		tallies[channel] = byStage
	end

	local entry = byStage[stage]

	if not entry then
		byStage[stage] = { count = 1, bytes = bytes }
		total += 1
		return
	end

	entry.count += 1
	entry.bytes += bytes
	total += 1
end

local function announce(channel: string, stage: Stage, reason: string, player: Player?)
	local level = Config.severityOf(stage)

	if level == "off" then
		return
	end

	local who = if player then ` from {player.Name}` else ""

	if level == "error" then
		sink(`[netweave] {channel} refused at {stage}{who}: {reason}\n{debug.traceback("", 2)}`)
		return
	end

	local key = `{channel}\0{stage}`
	local times = (seen[key] or 0) + 1
	local ceiling = Config.limitOf("repeatsPerDiagnostic")

	if times > ceiling then
		return
	end

	seen[key] = times

	local suffix = if times == ceiling
		then ` (further "{stage}" reports for {channel} are suppressed; nw.observe still receives them)`
		else ""

	sink(`[netweave] {channel} refused at {stage}{who}: {reason}{suffix}`)
end

--[=[
	@within Observer
	@function observe
	@param observer (rejection: Rejection) -> ()
	@return () -> () -- call to stop observing

	Registers a rejection observer. Several may be registered; each is called in registration
	order, and one that throws does not stop the others or the batch.

	```lua
	local stop = nw.observe(function(rejection)
		if rejection.stage == "authorize" then
			warn(`{rejection.player} was refused {rejection.channel}: {rejection.reason}`)
		end
	end)
	```
]=]
function Observer.observe(observer: Observer): () -> ()
	count += 1
	observers[count] = observer

	local removed = false

	return function()
		if removed then
			return
		end

		removed = true

		for index = 1, count do
			if observers[index] == observer then
				observers[index] = NOOP
				tombstones = true
				break
			end
		end

		compact()
	end
end

--[=[
	@within Observer
	@function emit
	@param channel string
	@param player Player?
	@param stage Stage
	@param reason string
	@param bytes number
	@private

	Fills the shared record and hands it to every observer. Called by the transport, not by games.
]=]
function Observer.emit(channel: string, player: Player?, stage: Stage, reason: string, bytes: number)
	record.channel = channel
	record.player = player
	record.stage = stage
	record.reason = reason
	record.bytes = bytes

	tally(channel, stage, bytes)

	compact()

	emitting += 1

	for index = 1, count do
		local observer = observers[index]

		if observer ~= NOOP then
			xpcall(observer, report, record)
		end
	end

	emitting -= 1

	announce(channel, stage, reason, player)
end

--[=[
	@interface Tally
	@within Observer
	.count number -- refusals at this channel and stage
	.bytes number -- their payloads, added up

	Bytes are counted whether or not the packet was ever decoded, because a refused packet still
	crossed the wire and a figure that only counted what was accepted would understate exactly the
	traffic worth looking at.
]=]
export type Tally = { read count: number, read bytes: number }

--[=[
	@interface Diagnostics
	@within Observer
	.since number -- `os.clock` when counting last started
	.total number -- refusals at every channel and stage
	.channels { [string]: { [string]: Tally } } -- qualified name, then stage

	What [Observer.diagnostics] returns. Frozen at every level.
]=]
export type Diagnostics = {
	read since: number,
	read total: number,
	read channels: { read [string]: { read [string]: Tally } },
}

--[=[
	@within Observer
	@function diagnostics
	@return Diagnostics

	Every refusal since the counters were last reset, by channel and stage.

	```lua
	local seen = nw.diagnostics()

	for channel, stages in seen.channels do
		for stage, tally in stages do
			print(channel, stage, tally.count, tally.bytes)
		end
	end
	```

	The console sink goes quiet after a few reports so a flood does not become the outage, which
	makes this the only way to answer "is this channel refusing more than it was" — the question
	that separates a bug from an attack. `RESEARCH §3-G6` records that no surveyed library can
	answer it.

	:::note Built on read, not on the rejection path
	The snapshot is assembled here rather than kept assembled, so counting a refusal stays two
	increments. Call it on a timer or when a diagnostic screen opens, not per packet.
	:::

	:::caution
	Frozen at every level, so it cannot be mutated back into the live counters — a diagnostic
	screen must not become a way to reset them by accident. [Observer.reset] is how they are
	cleared, and it drops observers too.
	:::
]=]
function Observer.diagnostics(): Diagnostics
	local channels: { [string]: { [string]: Tally } } = {}

	for channel, byStage in tallies do
		local copied: { [string]: Tally } = {}

		for stage, entry in byStage do
			copied[stage] = table.freeze({ count = entry.count, bytes = entry.bytes })
		end

		channels[channel] = table.freeze(copied)
	end

	local taken = {
		since = since,
		total = total,
		channels = table.freeze(channels),
	}

	table.freeze(taken)

	--[[ Frozen, so the value is read-only where the constructor is not; the cast says that and
	     nothing more. ]]
	return taken :: any
end

--[=[
	@within Observer
	@function setSink
	@param replacement ((line: string) -> ())?
	@private

	Replaces where the default sink writes. `nil` puts `warn` back, and so does [Observer.reset].
	Exists so the severities and the repeat suppression can be asserted rather than eyeballed.
]=]
function Observer.setSink(replacement: ((string) -> ())?)
	sink = replacement or warn
end

--[=[
	@within Observer
	@function reset
	@private

	Drops every observer. Exists for tests; a game has no reason to call it.
]=]
function Observer.reset()
	table.clear(observers)
	table.clear(seen)
	table.clear(tallies)
	count = 0
	emitting = 0
	tombstones = false
	total = 0
	since = os.clock()
	sink = warn
end

return Observer
