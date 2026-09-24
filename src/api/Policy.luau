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
	declares the guard as middleware in `createServer({ middleware })`, so answering "what is enforced
	here" means reading the server setup rather than the handler. netweave attaches it to the channel
	declaration, so the answer is one line.
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
	@type Stage () -> ()
	@within Policy

	The server-only half a factory may return second. Runs once, on the server, when the protocol
	is sealed — before any packet decodes, and never on a client — so it is where a policy reaches
	the module that exists on one side only (`PLAN-M5` D-5).
]=]
export type Stage = () -> ()

--[=[
	@type Factory<T> (config: any) -> (Check<T>, Stage?)
	@within Policy

	The load-time half. Receives whatever the policy was configured with, or an empty table when
	it was used bare, and returns the per-request check — and, optionally, the server stage.
]=]
--[[ A variadic tail rather than `(Check<T>, Stage?)`: a return pack of one value is not a subtype
     of a pack of two, so the fixed spelling refused every factory that returns the check alone —
     measured as 35 diagnostics across `api_ok` and `api_reject` the moment it was written. ]]
export type Factory<T> = (config: any) -> (Check<T>, ...Stage?)

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
--[[
	Two aliases rather than one recursive intersection.

	`Policy<T>` used to be a `typeof(setmetatable(…))` alias, which enforces the argument *count* of a
	reconfiguration and nothing about variance — so `nw.all(alive, ownsSlot)`, one payload-agnostic
	policy composed with one that names its request, was refused in every spelling (M4 report finding
	43; `PLAN-M5` phase 3). An intersection fixes that, because a function type is contravariant in
	its parameters and `Check<any>` is then usable where `Check<Equip>` is wanted.

	Written recursively — `Record<T> & ((config: any) -> Policy<T>)` — it takes `Channel`'s type
	functions down with `type functions do not currently support types of the form '*error-type*'`,
	measured. So the call returns the record: a *reconfigured* policy is a `Configured<T>`, which is
	what everything here accepts, and `Policy<T>` is that record plus the one call that produces one.
	Calling a configured policy again was never a shape anyone wrote.
]]
export type Configured<T> = {
	__nwCheck: (ctx: Context.Ctx, payload: T) -> Verdict,
	__nwStages: { Stage },
}

export type Policy<T> = Configured<T> & ((config: any) -> Configured<T>)

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

--[[
	Runs a factory and checks the shape of what came back. Shared by the bare form and the
	configured one, so the two cannot drift on what a second return means.
]]
local function build<T>(factory: Factory<T>, config: any): (Check<T>, { Stage })
	local check, stage = factory(config)

	if type(check) ~= "function" then
		error(
			`a policy factory returns the per-request function, and this one returned {typeof(check)}. `
				.. `The two stages are the point: nw.policy(function(config) --[[ once ]] return `
				.. `function(ctx, value) --[[ per request ]] return nw.allow() end end).`,
			3
		)
	end

	if stage ~= nil and type(stage) ~= "function" then
		error(
			`a policy factory's second return is its server stage, a function run once on the server `
				.. `when the protocol is sealed, and this one returned {typeof(stage)}. Write it as `
				.. `return check, function() --[[ server only, once ]] end — or return the check alone.`,
			3
		)
	end

	return check, if stage then { stage } else {}
end

local function callable<T>(check: Check<T>, factory: Factory<T>?, stages: { Stage }): Policy<T>
	local self = { __nwCheck = check, __nwStages = stages }

	return (
		setmetatable(self, {
			__call = function(_, config: any): Configured<T>
				if not factory then
					error(
						"this policy takes no configuration, so calling it with a table does nothing "
							.. "but build another one. Attach it directly — authorize = policy.alive — "
							.. "without the parentheses. A policy that should take options declares "
							.. "them in its factory: nw.policy(function(config) ... end).",
						2
					)
				end

				if config ~= nil and type(config) ~= "table" then
					error(
						"a policy is configured with a table of options, got "
							.. type(config)
							.. ". Write it as policy.originNearCharacter({ maxStuds = 12 }) — the "
							.. "table reaches the factory's `config` parameter.",
						2
					)
				end

				local configured, built = build(factory, config or {})
				return callable(configured, factory, built)
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

	Do the expensive part in the outer function: read configuration, build lookup tables. Whatever
	the inner function closes over is paid for once.

	**The outer function runs on both sides**, because the declaration file is required by both, so
	it is not where a server-only module is reached. That is the third piece, the **server stage**:
	a second function the factory may return, run once on the server when the protocol is sealed,
	before any packet decodes, and discarded on the client.

	```lua
	policy.canAfford = nw.policy(function()
		local wallet: Wallet? = nil                               -- filled by the stage, server only

		return function(ctx, offer)                               -- per request, server only
			local held = (wallet :: Wallet).goldOf(ctx.player)
			return held >= offer.gold and nw.allow() or nw.deny(`holds {held}`)
		end, function()                                            -- once, at seal, server only
			wallet = require(game:GetService("ServerStorage").Wallet)
		end
	end)
	```

	A policy attached to two channels runs its stage once. A stage that raises or yields fails the
	seal with the policy's channel in the message — a startup error, loud — because a check that runs
	before its stage did would be a policy deciding on nothing.

	:::caution
	The inner function must not yield. It runs inside the receive loop, holding a `ctx` that is
	recycled the moment it returns; since `PLAN-M5` a yield across another packet of the same player
	is reported at `authorize`.
	:::
]=]
function Policy.policy<T>(factory: Factory<T>): Policy<T>
	if type(factory) ~= "function" then
		error(
			`nw.policy takes a factory that returns the per-request check, got {typeof(factory)}. `
				.. `Write it as: nw.policy(function(config) return function(ctx, value) return `
				.. `nw.allow() end end). The outer function runs once at load; the inner one runs per `
				.. `request.`,
			2
		)
	end

	local check, stages = build(factory, {})

	return callable(check, factory, stages)
end

--[=[
	@within Policy
	@function all
	@param ... Configured<T> -- a policy, bare or reconfigured; evaluated left to right
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
function Policy.all<T>(...: Configured<T>): Policy<T>
	local count = select("#", ...)

	if count == 0 then
		error(
			"nw.all composes policies and was given none. Pass the ones this channel needs — "
				.. "nw.all(policy.alive, policy.ownsSlot) — or attach the single policy directly "
				.. "rather than wrapping it.",
			2
		)
	end

	--[[ Flattened once, at declaration time: the per-request path walks an array, never a varargs
	     pack and never a nested composition. ]]
	--[[ `table.create` yields `{unknown}` and Luau arrays are invariant, so the cast is the only
	     way to pre-size this rather than growing it element by element. ]]
	local checks: { Check<T> } = (table.create(count) :: any) :: { Check<T> }

	--[[ Every member's stages, in member order, so a composed policy's stages are the members'
	     and `Namespace.runStages` sees the same function for a member attached elsewhere too. ]]
	local stages: { Stage } = {}

	for index = 1, count do
		local member = select(index, ...) :: any

		if type(member) ~= "table" or type(member.__nwCheck) ~= "function" then
			error(
				`nw.all takes policies; argument {index} is a {type(member)}. Every argument has to come `
					.. `from nw.policy — a bare function is not one, because a policy carries the check `
					.. `netweave calls and the shape nw.all composes.`,
				2
			)
		end

		checks[index] = member.__nwCheck

		for _, stage in member.__nwStages do
			table.insert(stages, stage)
		end
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

	return callable(composed, nil, stages)
end

--[=[
	@within Policy
	@function stagesOf
	@param policy Configured<T>
	@return { Stage }
	@private

	The server stages a policy carries — its own, or for a composed one its members'. Read by the
	channel at declaration and run by `Namespace.runStages`, once per distinct function.
]=]
function Policy.stagesOf<T>(policy: Configured<T>): { Stage }
	return (policy :: any).__nwStages
end

--[=[
	@within Policy
	@function checkOf
	@param policy Configured<T>
	@return Check<T>
	@private

	Unwraps a policy to the function the transport calls. Deliberately not public: a game that
	reaches for this is running authorization somewhere other than the declaration, which is the
	thing this design exists to prevent.
]=]
function Policy.checkOf<T>(policy: Configured<T>): Check<T>
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
