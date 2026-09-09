--!strict
--!optimize 2

--[=[
	@class View

	The two halves of a namespace. `.server` and `.client` expose the *same* declaration through
	different types: the side that may listen has `listen`, the side that may send has `send`, and
	neither has the other.

	```lua
	-- server.luau
	combat.server.fireWeapon:listen(function(ctx, shot) end)
	combat.server.playerState:publish(subject, state)

	-- client.luau
	combat.client.fireWeapon:send(shot)
	combat.client.playerState:listen(function(state) end)
	```

	Guarantee G6 — direction is a class, not a string field — is a **compile-time** guarantee
	because of this. `combat.server.fireWeapon:send(...)` is not a runtime check that fires in
	production; it is an analysis error that never ships.
]=]

--[[
	`DESIGN-API.md` §7 originally assumed this needed a fallback, because mapping each key of a
	declaration to a *different* type is a mapped type and Luau has none. `spike/inference/` and
	then `spike/declare/views.luau` showed a `type function` can both map a table and branch on a
	singleton tag, so no fallback is needed and G6 survives.

	Three things in here are the result of measurement rather than taste, and each would look
	arbitrary without the note:

	  1. `types.copy` on the incoming type. Calling one type function from another leaves the
	     parameter generic, and `types.intersectionof` on a generic fails to check — the analyser
	     reports it inside netweave's own source, where a user cannot act on it.
	  2. The brand is applied only to tables. `number & { tag }` normalises to `never`, which
	     satisfies every parameter rather than none (`src/api/Trust.luau`).
	  3. Methods take `self` as `unknown`, so they are called with `:`. The view object cannot
	     refer to its own type while it is being built, and `unknown` accepts it without needing to.
]]

local Channel = require("./Channel")
local Transport = require("./Transport")

local View = {}

--[[
	The brand is constructed here and in `src/api/Trust.luau`, because a type function body cannot
	call across modules — it has only the `types` library. The two must agree, and
	`tests/api_ok.luau` asserts they do by assigning one to the other.
]]
--[[
	The same rule as `Trust.luau`'s `branded`, and a copy rather than a call: a type function's body
	cannot reach a value from another module, so `Trust.Trusted` is not callable from in here. The
	two are held together by `tests/api_ok.luau`, which asserts a handler's parameter is assignable
	to `nw.Untrusted<Req?>` — if either copy drifts, that stops compiling.

	Why it handles a union: `T?` is one, and testing `value:is("table")` alone left an optional
	payload unbranded, so a `signal` handed its handler a value that satisfied a `Trusted<Req?>`
	parameter (M4 report). Each table component is branded and the union rebuilt, which keeps the
	brand across the `if r then` a game has to write anyway.
]]
type function brandedAs(payload, name)
	local value = types.copy(payload)

	local function tagged(inner)
		local tag = types.newtable()
		tag:setproperty(types.singleton(name), types.singleton(true))
		return types.intersectionof(inner, tag)
	end

	if value:is("table") then
		return tagged(value)
	end

	if value:is("union") then
		local rebuilt = nil
		local marked = false

		for _, component in value:components() do
			local part = component

			if component:is("table") then
				part = tagged(component)
				marked = true
			end

			rebuilt = if rebuilt then types.unionof(rebuilt, part) else part
		end

		if marked and rebuilt then
			return rebuilt
		end
	end

	return value
end

type function channelView(channel, side)
	if not channel:is("table") then
		error(
			"a namespace holds channels, and this field is not one. Declare it with nw.command, "
				.. "nw.intent, nw.signal, nw.query, nw.state or nw.event — a schema on its own is "
				.. "not a channel, and neither is a function."
		)
	end

	local class = channel:readproperty(types.singleton("__class")):value()
	local audience = channel:readproperty(types.singleton("__audience")):value()
	local payload = channel:readproperty(types.singleton("__payload"))
	local response = channel:readproperty(types.singleton("__response"))
	local subject = channel:readproperty(types.singleton("__subject"))

	local view = types.newtable()
	local server = side:value() == "server"

	--[[
		Every argument to `types.newfunction` is written inline. Hoisting one into a local seals it,
		and a sealed `{ head = ... }` is then compared exactly against `{ head: {type}?, tail: type? }`
		and rejected for having no `tail` — a diagnostic inside netweave's own source, which is the
		one place a user cannot do anything about (`PLAN-M1` D-7).
	]]
	local function returns(parameters)
		return types.newfunction({ head = parameters }, { head = {} })
	end

	--[[
		The context, shaped rather than left as `unknown`.

		It was `types.unknown`, and that made `ctx` **unreadable**: a handler could not annotate it —
		`Ctx` is not a supertype of `unknown`, so `function(ctx: nw.Ctx, shot)` was rejected — and it
		could not read through it either. Every handler in the suite was written `function(_ctx, ...)`
		and nobody noticed, because none of them wanted the context. Writing the worked example was
		what noticed: `ctx.player` is the first thing a real handler reaches for.

		The fields that can be named are named, so `ctx.now` is a number and `ctx.playr` is a typo the
		analyser catches. The three Roblox-typed ones stay `unknown`, because a type function body has
		no way to reach `Player`, `Model` or `Humanoid` — they pass through anywhere `unknown` is
		accepted, which includes `publish`, and take a cast anywhere it is not. That limitation is
		written down in `DESIGN-API.md` §8 rather than left to be discovered.
	]]
	local function context()
		local ctx = types.newtable()

		ctx:setproperty(types.singleton("player"), types.unknown)
		ctx:setproperty(types.singleton("channel"), types.string)
		ctx:setproperty(types.singleton("character"), types.optional(types.unknown))
		ctx:setproperty(types.singleton("humanoid"), types.optional(types.unknown))
		ctx:setproperty(types.singleton("now"), types.number)

		return ctx
	end

	local function listener(seen, withContext)
		local handler = if withContext
			then types.newfunction({ head = { context(), seen } }, { head = {} })
			else types.newfunction({ head = { seen } }, { head = {} })

		view:setproperty(types.singleton("listen"), returns({ types.unknown, handler }))
	end

	if class == "command" or class == "intent" or class == "signal" then
		if server then
			local seen = payload

			if class == "command" then
				seen = brandedAs(payload, "__nwTrusted")
			elseif class == "signal" then
				seen = brandedAs(payload, "__nwUntrusted")
			end

			listener(seen, true)
		else
			view:setproperty(types.singleton("send"), returns({ types.unknown, payload }))
		end
	elseif class == "query" then
		if server then
			local handler = types.newfunction(
				{ head = { context(), brandedAs(payload, "__nwTrusted") } },
				{ head = { response } }
			)

			view:setproperty(types.singleton("handle"), returns({ types.unknown, handler }))
		else
			--[[
				Two returns, both optional: a query that timed out has no answer, and one that was
				refused has a reason. The failure is a value rather than something thrown because a
				refused query is an ordinary outcome, and it cannot be ignored because `R?` is not
				usable without a nil check under the solver netweave requires.

				`nil` is unambiguous here only because `nw.query` refuses a top-level `t.optional`
				`returns`, which is the one shape that would make "no answer" and "the answer is
				nothing" the same value (`DESIGN-API.md` §7, `src/api/Channel.luau`).
			]]
			view:setproperty(
				types.singleton("invoke"),
				types.newfunction(
					{ head = { types.unknown, payload } },
					{ head = { types.optional(response), types.optional(types.string) } }
				)
			)
		end
	elseif class == "replicate" then
		--[[
			The server view has **nothing on it**, and that absence is the class's argument made
			mechanical rather than documented. A replicated channel is fed by its `store`; if
			`publish` existed here there would be two ways in, and the one that skipped the baseline
			would leave clients wrong in a way nothing could detect.

			The client half is `listen`, the same as `state`, because a client that has to know
			whether it was sent a change or a whole value is a client the library has failed.
		]]
		if not server then
			--[[ Two arguments, and the subject first. A replicated client keeps one value per
			     subject, so a listener that could not tell them apart would be useless — and typing
			     it here is what stops the signature from taking one argument at analysis and two at
			     runtime, which is worse than either. ]]
			view:setproperty(
				types.singleton("listen"),
				returns({
					types.unknown,
					types.newfunction({ head = { subject, payload } }, { head = {} }),
				})
			)
		end
	else
		if server then
			view:setproperty(types.singleton("publish"), returns({ types.unknown, types.unknown, payload }))

			--[[ G3. `broadcast` is absent unless the declared audience is provably everyone, which
			     is why an audience is a value with a singleton scope and not a string. ]]
			if audience == "everyone" then
				view:setproperty(types.singleton("broadcast"), returns({ types.unknown, payload }))
			end
		else
			listener(payload, false)
		end
	end

	return view
end

--[=[
	@type ServerView<D> D
	@within View

	Maps a declaration table to what the server may do with each channel.
]=]
export type function ServerView(declaration)
	local result = types.newtable()

	for key, property in declaration:properties() do
		local channel = property.read

		if not channel then
			error(
				"a channel in this namespace has no readable type, which means it was declared "
					.. "write-only. Write the namespace as a plain table literal: "
					.. 'nw.namespace("combat", { fireWeapon = nw.command({ ... }) }), with no '
					.. "`write` or `read` modifiers on the fields."
			)
		end

		result:setproperty(key, channelView(channel, types.singleton("server")))
	end

	return result
end

--[=[
	@type ClientView<D> D
	@within View

	Maps a declaration table to what the client may do with each channel.
]=]
export type function ClientView(declaration)
	local result = types.newtable()

	for key, property in declaration:properties() do
		local channel = property.read

		if not channel then
			error(
				"a channel in this namespace has no readable type, which means it was declared "
					.. "write-only. Write the namespace as a plain table literal: "
					.. 'nw.namespace("combat", { fireWeapon = nw.command({ ... }) }), with no '
					.. "`write` or `read` modifiers on the fields."
			)
		end

		result:setproperty(key, channelView(channel, types.singleton("client")))
	end

	return result
end

--[=[
	@type Views<D> { name: string, channels: D, server: ServerView<D>, client: ClientView<D> }
	@within View

	What `nw.namespace` returns: the declaration itself, and it seen from both sides.
]=]
--[[
	This alias is load-bearing beyond naming the pair, and deleting it breaks G6 silently.

	Measured in `spike/declare/mod/`: an `export type function` that its own module never references
	does **not** reduce for a module that requires it. It becomes `any`, with no diagnostic — so
	`combat.server.fireWeapon:send(...)` would compile, and every direction violation in
	`tests/api_reject.luau` would stop erroring while the file still claimed to test them.

	**And there is one way to write it down that does the same thing.** `local ns: Views<D> = <a
	namespace>` — an annotated local with a value assigned into it — makes the file stop reporting
	anything about `ns`, retroactively and to the end of the file. Measured at
	`--flag:LuauSolverV2=true` against the same declarations, counting the two diagnostics a
	direction violation and a wrong-typed handler produce:

	  | written as | diagnostics |
	  |---|---|
	  | no annotation | 2 |
	  | `type V = Views<D>`, never assigned through | 2 |
	  | `local v = ns :: Views<D>` | 2 |
	  | `local v: Views<D>` with no value | 2 |
	  | `local v: typeof(ns) = ns` | 2 |
	  | a parameter typed `Views<D>`, called with `ns` | 2 |
	  | **`local v: Views<D> = ns`** | **0** |

	Six spellings keep the guarantees and one removes them, so the answer is to write one of the six
	— a parameter, a cast, or `typeof` — and `tests/api_ok.luau` pins all three. The seventh is
	pinned as a canary at the end of `tests/api_reject.luau`: it holds two statements that should
	error, the header count says they do not, and if the count ever moves to 25 this caution can come
	off. Found by M4's security report, which also found the reason nothing had caught it: no file in
	`tests/` had ever written `Views<` at all.
]]
export type Views<D> = {
	name: string,
	channels: D,
	server: ServerView<D>,
	client: ClientView<D>,
}

--[[
	The runtime objects the types above describe.

	One table per channel per side, built once at declaration. The methods close over the channel
	record, so dispatch reads the rate, policy, audience and codec straight off the declaration —
	there is no per-packet lookup and nothing to keep in sync.
]]
local function attach(channel: any, handler: any, what: string)
	if type(handler) ~= "function" then
		error(
			`:{what}() takes the function that runs per packet, got {typeof(handler)}. Write it `
				.. `inline — combat.server.fireWeapon:{what}(function(ctx, shot) ... end) — with the `
				.. `colon, so the channel is the receiver.`,
			3
		)
	end

	if channel.handler ~= nil then
		error(
			`{channel.qualified} already has a handler. A channel has exactly one: two would `
				.. `split the authorization decision across two places, which is what this library `
				.. `exists to prevent. Fan out inside the handler instead.`,
			3
		)
	end

	channel.handler = handler

	if Transport.installed() then
		Transport.driver(what).dispatch(channel, handler)
	end
end

local function serverView(channel: any): any
	local class = channel.class

	if class == "command" or class == "intent" or class == "signal" then
		return {
			channel = channel,

			listen = function(_self: any, handler: any)
				attach(channel, handler, "listen")
			end,
		}
	end

	if class == "query" then
		return {
			channel = channel,

			handle = function(_self: any, handler: any)
				attach(channel, handler, "handle")
			end,
		}
	end

	--[[ Nothing to call. See the type function above: the store is the only way into a replicated
	     channel, so a second one would be a way to be wrong. ]]
	if class == "replicate" then
		return { channel = channel }
	end

	local view: any = {
		channel = channel,

		publish = function(_self: any, subject: any, value: any)
			Transport.driver("publish").publish(channel, subject, value)
		end,
	}

	if channel.audience.scope == "everyone" then
		view.broadcast = function(_self: any, value: any)
			Transport.driver("broadcast").broadcast(channel, value)
		end
	end

	return view
end

local function clientView(channel: any): any
	local class = channel.class

	if class == "command" or class == "intent" or class == "signal" then
		return {
			channel = channel,

			send = function(_self: any, value: any)
				Transport.driver("send").send(channel, value)
			end,
		}
	end

	if class == "query" then
		return {
			channel = channel,

			invoke = function(_self: any, args: any): (any?, string?)
				return Transport.driver("invoke").invoke(channel, args)
			end,
		}
	end

	return {
		channel = channel,

		listen = function(_self: any, handler: any)
			attach(channel, handler, "listen")
		end,
	}
end

--[=[
	@within View
	@function build
	@param channels { [string]: Channel }
	@param side "server" | "client"
	@return { [string]: any }
	@private

	Builds one side of a namespace. Called by `nw.namespace`.
]=]
function View.build(channels: { [string]: any }, side: "server" | "client"): { [string]: any }
	local built: { [string]: any } = {}

	for key, channel in channels do
		if not Channel.isChannel(channel) then
			error(
				`{key} is not a channel; declare it with nw.command, nw.intent, nw.signal, `
					.. `nw.query, nw.state or nw.event`,
				3
			)
		end

		built[key] = if side == "server" then serverView(channel) else clientView(channel)
	end

	return table.freeze(built)
end

return View
