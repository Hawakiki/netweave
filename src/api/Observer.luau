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
	@type Stage "parse" | "budget" | "authorize" | "handler" | "queue" | "send"
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

	The first three are worth separating because they mean different things about the sender.
	`parse` is a stale client or an attacker; `budget` is a flood; `authorize` is a player asking
	for something they are not entitled to.

	`handler` and `queue` are about this game rather than the sender: one says a handler threw, the
	other that no handler is attached and the backlog has started dropping. Both are the kind of
	thing that is otherwise noticed as "some packets do not seem to arrive".

	`send` points the other way entirely — netweave refusing *this* game's own outgoing packet. The
	only case in M2 is an unreliable payload over Roblox's size limit, which Roblox enforces by
	dropping silently, so without a signal here it is invisible from both ends (`RESEARCH §3.7-F`).
]=]
export type Stage = "parse" | "budget" | "authorize" | "handler" | "queue" | "send"

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
				table.remove(observers, index)
				count -= 1
				break
			end
		end
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

	for index = 1, count do
		xpcall(observers[index], report, record)
	end

	announce(channel, stage, reason, player)
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
	count = 0
	sink = warn
end

return Observer
