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
	if count == 0 then
		return
	end

	record.channel = channel
	record.player = player
	record.stage = stage
	record.reason = reason
	record.bytes = bytes

	for index = 1, count do
		xpcall(observers[index], report, record)
	end
end

--[=[
	@within Observer
	@function reset
	@private

	Drops every observer. Exists for tests; a game has no reason to call it.
]=]
function Observer.reset()
	table.clear(observers)
	count = 0
end

return Observer
