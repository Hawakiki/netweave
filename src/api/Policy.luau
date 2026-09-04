--!strict
--!optimize 2

--[=[
	@class Policy

	What a channel is allowed to do, written once and attached to the declaration.

	```lua
	-- shared/Policies.luau
	local policy = {}

	policy.alive = nw.policy(function()
		return function(ctx)
			if not ctx.humanoid or ctx.humanoid.Health <= 0 then
				return nw.deny("dead")
			end
			return nw.allow()
		end
	end)

	policy.originNearCharacter = nw.policy(function(config)
		local maxStuds = config.maxStuds or 8

		return function(ctx, shot)
			local root = ctx.character and ctx.character.PrimaryPart
			if not root then
				return nw.deny("no character")
			end
			if (shot.origin - root.Position).Magnitude > maxStuds then
				return nw.deny("origin detached")
			end
			return nw.allow(shot)
		end
	end)

	return policy
	```

	Two stages: the outer function runs once at load, the inner runs per request. The structural
	idea comes from Flamework (`RESEARCH §3.5-S3`); what differs is the attachment point. Flamework
	spreads the guard over a decorator and a registry, so answering "what is enforced here" means
	reading two files. netweave attaches it to the channel declaration, so the answer is one line.
]=]

--[[
	R-3 is the risk this module is written against: an authorization callback per packet, plus
	context setup, could erase the codec's advantage entirely and hand the argument to "just use a
	RemoteEvent" — which M0 already showed is faster for small payloads.

	So nothing here allocates per request. The verdict is a single shared record (see `allow`),
	`all` resolves its members at declaration time into a flat array, and the context is the
	reused per-player one from `Context`.
]]

local Context = require("./Context")

local Policy = {}

--[=[
	@interface Verdict
	@within Policy
	.ok boolean
	.value any -- what the handler receives, when a policy narrowed or replaced the payload
	.reason string? -- why, when refused. Reaches `nw.observe` as `Rejection.reason`

	:::caution
	The verdict is a **shared record**, refilled by every `allow` and `deny`. It is read
	immediately by whatever called the policy and is invalid once the next policy runs. Never
	retain it, and never yield inside a policy.
	:::
]=]
export type Verdict = {
	ok: boolean,
	value: any,
	reason: string?,
}

--[=[
	@type Check<T> (ctx: Ctx, payload: T) -> Verdict
	@within Policy

	The per-request half of a policy: the function the outer stage returns.
]=]
export type Check<T> = (ctx: Context.Ctx, payload: T) -> Verdict

--[=[
	@type Factory<T> (config: any) -> Check<T>
	@within Policy

	The load-time half. Receives whatever the policy was configured with, or an empty table when
	it was used bare.
]=]
export type Factory<T> = (config: any) -> Check<T>

--[=[
	@type Policy<T> Check<T>
	@within Policy

	A policy is usable in two forms, and both appear in real declarations:

	```lua
	authorize = policy.alive,                                  -- bare, default configuration
	authorize = policy.originNearCharacter({ maxStuds = 12 }), -- reconfigured
	```

	Bare, it already is the per-request check. Called, it produces a differently configured one.
]=]
export type Policy<T> = typeof(setmetatable(
	{} :: { __nwCheck: (ctx: Context.Ctx, payload: T) -> Verdict },
	{} :: { __call: (self: any, config: any) -> Policy<T> }
))

--[[
	One record for every verdict in the process. A policy returns it, the caller reads `ok`,
	`value` and `reason` into locals before doing anything else, and the next policy overwrites it.

	The alternative — a fresh table per verdict — is one allocation per policy per packet, which on
	a `command` at 20 Hz across 50 players is a thousand tables a second doing nothing.
]]
local VERDICT: Verdict = {
	ok = true,
	value = nil,
	reason = nil,
}

--[=[
	@within Policy
	@function allow
	@param value any? -- the payload to hand onward, if this policy narrowed it
	@return Verdict

	Approves the request.

	```lua
	return nw.allow()          -- unchanged
	return nw.allow(clamped)   -- the handler receives `clamped`
	```

	Passing a value is how a policy becomes a *narrowing* step rather than only a gate: clamp a
	number, resolve an id to the object it names, drop a field the caller must not set.
]=]
function Policy.allow(value: any?): Verdict
	VERDICT.ok = true
	VERDICT.value = value
	VERDICT.reason = nil
	return VERDICT
end

--[=[
	@within Policy
	@function deny
	@param reason string -- reaches `nw.observe` verbatim, so make it greppable
	@return Verdict

	Refuses the request. The handler does not run, and a rejection is emitted at stage
	`"authorize"`.

	```lua
	return nw.deny("origin detached")
	```

	:::note
	The reason is developer-facing telemetry, not a message for the player. It is never sent back
	over the wire — telling a client *why* it was refused is how an attacker maps your checks.
	:::
]=]
function Policy.deny(reason: string): Verdict
	VERDICT.ok = false
	VERDICT.value = nil
	VERDICT.reason = reason
	return VERDICT
end

local function callable<T>(check: Check<T>, factory: Factory<T>?): Policy<T>
	local self = { __nwCheck = check }

	return (
		setmetatable(self, {
			__call = function(_, config: any): Policy<T>
				if not factory then
					error("this policy takes no configuration", 2)
				end

				if config ~= nil and type(config) ~= "table" then
					error(`a policy is configured with a table, got {type(config)}`, 2)
				end

				return callable(factory(config or {}), factory)
			end,

			__metatable = "netweave.Policy",
		}) :: any
	) :: Policy<T>
end

--[=[
	@within Policy
	@function policy
	@param factory (config: any) -> (ctx: Ctx, payload: T) -> Verdict
	@return Policy<T>

	Declares a policy. The outer function runs once, now; the one it returns runs per request.

	```lua
	policy.ownsSlot = nw.policy(function(config)
		local slots = config.slots or 3           -- once
		return function(ctx, slot)                -- per request
			return slot < slots and nw.allow() or nw.deny("no such slot")
		end
	end)
	```

	Do the expensive part in the outer function: read configuration, resolve services, build lookup
	tables. Whatever the inner function closes over is paid for once.

	:::caution
	The inner function must not yield. It runs inside the receive loop, holding a `ctx` that is
	recycled the moment it returns.
	:::
]=]
function Policy.policy<T>(factory: Factory<T>): Policy<T>
	if type(factory) ~= "function" then
		error("nw.policy needs a function", 2)
	end

	local check = factory({})

	if type(check) ~= "function" then
		error("a policy factory must return the per-request function", 2)
	end

	return callable(check, factory)
end

--[=[
	@within Policy
	@function all
	@param ... Policy<T> -- evaluated left to right
	@return Policy<T>

	Every policy must allow. The first denial wins and the rest do not run.

	```lua
	authorize = nw.all(policy.alive, policy.originNearCharacter({ maxStuds = 12 })),
	```

	A value passed to [Policy.allow] is threaded onward, so policies compose as a narrowing
	pipeline: the second sees what the first approved, not what arrived.

	:::note
	Order is the cheap check first. `policy.alive` reads one property; a distance check reads a
	character, then a part, then subtracts two vectors. Under a flood that difference is the whole
	cost of the channel.
	:::
]=]
function Policy.all<T>(...: Policy<T>): Policy<T>
	local count = select("#", ...)

	if count == 0 then
		error("nw.all needs at least one policy", 2)
	end

	--[[ Flattened once, at declaration time: the per-request path walks an array, never a varargs
	     pack and never a nested composition. ]]
	--[[ `table.create` yields `{unknown}` and Luau arrays are invariant, so the cast is the only
	     way to pre-size this rather than growing it element by element. ]]
	local checks: { Check<T> } = (table.create(count) :: any) :: { Check<T> }

	for index = 1, count do
		local member = select(index, ...) :: any

		if type(member) ~= "table" or type(member.__nwCheck) ~= "function" then
			error(`nw.all takes policies; argument {index} is a {type(member)}`, 2)
		end

		checks[index] = member.__nwCheck
	end

	local function composed(ctx: Context.Ctx, payload: T): Verdict
		local current: any = payload

		for index = 1, count do
			local verdict = checks[index](ctx, current)

			--[[ Read out of the shared record before the next policy overwrites it. ]]
			if not verdict.ok then
				return Policy.deny(verdict.reason or "denied")
			end

			if verdict.value ~= nil then
				current = verdict.value
			end
		end

		return Policy.allow(current)
	end

	return callable(composed, nil)
end

--[=[
	@within Policy
	@function checkOf
	@param policy Policy<T>
	@return Check<T>
	@private

	Unwraps a policy to the function the transport calls. Deliberately not public: a game that
	reaches for this is running authorization somewhere other than the declaration, which is the
	thing this design exists to prevent.
]=]
function Policy.checkOf<T>(policy: Policy<T>): Check<T>
	return (policy :: any).__nwCheck
end

--[=[
	@within Policy
	@function isPolicy
	@param value any
	@return boolean
	@private
]=]
function Policy.isPolicy(value: any): boolean
	return type(value) == "table" and type((value :: any).__nwCheck) == "function"
end

return Policy
