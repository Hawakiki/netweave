--!strict
--!optimize 2

--[=[
	@class Context

	What a policy and a handler are told about the request they are looking at.

	```lua
	combat.fireWeapon:listen(function(ctx, shot)
		if (shot.origin - ctx.character.PrimaryPart.Position).Magnitude > 8 then
			return
		end
	end)
	```

	:::caution
	**A `ctx` is valid only for the synchronous duration of the handler.** There is one per player
	and its fields are refreshed in place; retaining it across a yield hands you the next packet's
	context, or another channel's. In Studio that is an error rather than a silent wrong answer.
	:::
]=]

--[[
	`ctx` reaches every policy and every handler, so allocating one per packet would break the
	zero-hot-path-allocation criterion on the first packet (`RESEARCH §3.6-A4`, `§3.6-B4`,
	`PLAN-M1` acceptance 7). One per player, refreshed, is the only shape that costs nothing.

	The cost of that choice is a real footgun, so it is guarded rather than documented and hoped
	about: in Studio the handler receives a proxy that compares a generation counter before every
	read, and a fresh one per acquisition so it can tell which acquisition the holder has. Production
	hands over the record itself — no proxy, no comparison, nothing allocated.
]]

local Context = {}

--[=[
	@interface Ctx
	@within Context
	.player Player -- the sender, on the server; the local player on the client
	.channel string -- the qualified channel name this request arrived on
	.character Model? -- refreshed per request, nil if the player has none
	.humanoid Humanoid? -- refreshed per request, nil if the character has none
	.now number -- `os.clock()` at the moment the packet was dispatched
]=]
export type Ctx = {
	player: Player,
	channel: string,
	character: Model?,
	humanoid: Humanoid?,
	now: number,
}

type Record = {
	live: Ctx,
	generation: number,
	--[[ Whether this acquisition has already gone and looked the character up. A boolean rather than
	     testing the field, because "this player has no character" is a real answer and `nil` cannot
	     tell it apart from "nobody has asked yet". ]]
	looked: boolean,
}

--[[
	`RunService` does not exist under lune, where the tests run, and neither does `game`. A pcall
	is the only detection that works in both places; it runs once at load, not per request.
]]
local function detectStudio(): boolean
	local ok, studio = pcall(function()
		return game:GetService("RunService"):IsStudio()
	end)

	return ok and studio == true
end

local GUARDED = detectStudio()

local records: { [any]: Record } = {}

--[[
	One proxy per *acquisition*, not per player, and only in Studio.

	A single proxy per player cannot work, and the first version of this file shipped that bug: the
	closure captures `generation` when the proxy is built, so the first `release` expires it
	permanently and every handler from the second packet onward raises. Caught by running
	`tests/api_runtime.luau` in Studio, which is the only place the guard is even on.

	Nor is a plain `active` boolean enough. It answers "is some handler running", so it catches a
	`ctx` read after its handler returned — and misses the worse case, a `ctx` retained and read
	during a *later* packet's handler, where it would quietly hand over another request's data.
	Distinguishing those needs the holder's acquisition to be identifiable, which means a distinct
	object per acquisition.

	Studio pays two allocations per packet for that, and Studio is not where throughput is
	measured. Production never calls this: `acquire` hands back the record itself.
]]
local function guard(record: Record): Ctx
	local generation = record.generation
	local live = record.live

	--[[
		A metatable, not a copy: copying the fields per request would make the stale value
		*readable*, which is worse than an error because it looks like it worked.
	]]
	return (
		setmetatable({}, {
			__index = function(_, key: any): any
				if record.generation ~= generation then
					error(
						`this ctx expired. It belonged to a handler that has already returned; a ctx is `
							.. `valid only for the synchronous duration of the handler that received it `
							.. `(netweave DESIGN-API §8). Copy the fields you need instead: `
							.. `local player = ctx.player`,
						2
					)
				end

				return (live :: any)[key]
			end,

			__newindex = function(_, key: any)
				error(
					`a ctx is read-only, so ctx.{tostring(key)} = ... is not a place to keep anything: `
						.. `the record is reused for this player's next packet and the write would leak `
						.. `into it. Keep per-request state in your own table, keyed by ctx.player.`,
					2
				)
			end,

			__metatable = "netweave.Ctx",
		}) :: any
	) :: Ctx
end

--[[
	**The character is looked up when something reads it, and not before.**

	It used to be refreshed in `acquire`, which runs per packet — two property reads and a
	`FindFirstChildOfClass` for every packet of every batch, whether or not anything on that channel
	was ever going to ask. A `signal` or `intent` with no policy needs it from nobody, and a batch of
	twenty packets from one player paid twenty tree searches (M4 report).

	Deferring it is not a caching window: each acquisition still gets that packet's answer, computed
	fresh the first time it is read. What goes away is the packet that never reads it at all, which
	is most of them.

	Both fields are computed together on either one's first read, because `humanoid` is found through
	`character` and a policy that asks for one has already paid for the other. `rawset` for the
	caching so the metatable does not re-enter, and a `nil` character simply leaves the key absent —
	`looked` is what stops it being looked up twice.
]]
local function recordFor(player: any): Record
	local existing = records[player]

	if existing then
		return existing
	end

	local record: Record = {
		live = nil :: any,
		generation = 0,
		looked = false,
	}

	local live: any = setmetatable({
		player = player,
		channel = "",
		now = 0,
	}, {
		__index = function(self: any, key: any): any
			if key ~= "character" and key ~= "humanoid" then
				return nil
			end

			if not record.looked then
				record.looked = true

				local character = (player :: any).Character

				rawset(self, "character", character)
				rawset(
					self,
					"humanoid",
					if character then character:FindFirstChildOfClass("Humanoid") else nil
				)
			end

			return rawget(self, key)
		end,

		--[[
			The production record refuses a write, not only the Studio guard. Before M4 phase 8
			every `acquire` overwrote `character` and `humanoid`, so a handler that wrote into
			`ctx` was corrected on the next packet; the lazy lookup above fires only while the key
			is absent, so a write sat in the shared record and was handed to every later policy
			and handler for that player until `forget` — `ctx.character = …` believed by
			`originNearCharacter`, with no message in production (M4-1). A key that exists is
			still assignable, and `acquire` resets each of those every packet.
		]]
		__newindex = function(_, key: any)
			error(
				`a ctx is read-only, so ctx.{tostring(key)} = ... is not a place to keep anything: `
					.. `the record is reused for this player's next packet and the write would leak `
					.. `into it. Keep per-request state in your own table, keyed by ctx.player.`,
				2
			)
		end,
	})

	record.live = live :: Ctx
	records[player] = record

	return record
end

--[=[
	@within Context
	@function acquire
	@param player Player
	@param channel string -- the qualified channel name
	@return Ctx
	@private

	Refreshes this player's context and hands it out. Called by the transport per packet.
]=]
function Context.acquire(player: any, channel: string): Ctx
	local record = recordFor(player)
	local live = record.live

	--[[ `player` too, though it never changes: it is the one key a handler can overwrite without
	     `__newindex` noticing, because it exists. Three plain stores per packet. ]]
	live.player = player
	live.channel = channel
	live.now = os.clock()

	--[[
		~~Character and humanoid are refreshed here rather than looked up by each policy, because
		`policy.alive` and `policy.originNearCharacter` would otherwise each pay for the same two
		property reads on every packet.~~

		**That argument is about policies and this function runs per packet.** Sharing one lookup
		between the policies of one request is right and still happens; paying for it on a request
		where no policy and no handler will read it is what the M4 report found, and it is most
		requests. The lookup moved to `recordFor`'s `__index`, and what is left here is dropping the
		previous acquisition's answer — one branch when nothing looked, which is the common case.
	]]
	if record.looked then
		record.looked = false

		rawset(live :: any, "character", nil)
		rawset(live :: any, "humanoid", nil)
	end

	if GUARDED then
		return guard(record)
	end

	return live
end

--[=[
	@within Context
	@function release
	@param player Player
	@private

	Ends the context's validity. Every read through a retained `ctx` after this point is an error
	in Studio, and reads a later packet's data in production.
]=]
function Context.release(player: any)
	local record = records[player]

	if record then
		record.generation += 1
	end
end

--[=[
	@within Context
	@function generation
	@param player Player
	@return number
	@private

	How many times this player's context has been released. The transport reads it before it runs a
	handler or a policy and compares after: a value that moved means another packet of the same
	player was dispatched while that code was parked on a yield, so the `ctx` it held was refreshed
	under it — the case the Studio guard raises on, made reportable in production for the cost of
	one integer compare (`PLAN-M5` D-5).
]=]
function Context.generation(player: any): number
	local record = records[player]

	return if record then record.generation else 0
end

--[=[
	@within Context
	@function detached
	@param player Player
	@param channel string -- the qualified channel name
	@return Ctx
	@private

	A context of its own, for a handler that is allowed to yield.

	`nw.query` is the only class where that is true, and it is true by design: a query exists to
	fetch something, and fetching means a datastore, a `WaitForChild`, an HTTP call. So a query's
	handler gets a record nobody else will touch, frozen, valid for as long as it holds it.
]=]
--[[
	One allocation per call, and it is the right trade here rather than an exception to the rule.

	The shared per-player record exists because `ctx` reaches every policy and every handler on
	every packet, and a table per packet would have broken the zero-allocation criterion on the
	first one. A query is not that: it has already cost a coroutine, a round trip and a reply
	packet, and the alternative to allocating is a record whose `channel`, `now` and `character`
	are refreshed out from under a handler that yielded — which in Studio raises through the guard
	above, and in production hands back another packet's context. The optimisation and the class
	are incompatible, so the class pays.

	Frozen, so the one thing a detached context and a live one still have in common is that neither
	can be written to.
]]
function Context.detached(player: any, channel: string): Ctx
	local character = (player :: any).Character

	return table.freeze({
		player = player,
		channel = channel,
		character = character,
		humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil,
		now = os.clock(),
	}) :: any
end

--[=[
	@within Context
	@function forget
	@param player Player
	@private

	Drops the player's context entirely. Called when they leave, so the record does not outlive them.
]=]
function Context.forget(player: any)
	records[player] = nil
end

--[=[
	@within Context
	@function guarded
	@return boolean

	Whether expired-context access is being checked. True in Studio, false in a live server.

	Exposed so a test can assert which mode it is running in rather than infer it — the guard is
	the kind of thing that quietly stops working.
]=]
function Context.guarded(): boolean
	return GUARDED
end

--[=[
	@within Context
	@function setGuarded
	@param enabled boolean
	@private

	Turns the expired-context check off, or back on.

	The only reason this exists is measurement. The guard allocates two tables per packet, in
	Studio, and Studio is where the benchmark runs — so a run with it on charges netweave for a
	debug facility no competitor has and no live server pays. `bench/` turns it off for the
	comparison and reports its cost as a line of its own.

	:::caution
	This is not a performance knob for a game. Studio is not where throughput is decided, and the
	guard is the only thing standing between a retained `ctx` and a handler quietly reading another
	player's request.
	:::
]=]
function Context.setGuarded(enabled: boolean)
	GUARDED = enabled
end

return Context
