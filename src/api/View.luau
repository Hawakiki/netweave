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
type function brandedAs(payload, name)
	local value = types.copy(payload)

	if not value:is("table") then
		return value
	end

	local tag = types.newtable()
	tag:setproperty(types.singleton(name), types.singleton(true))

	return types.intersectionof(value, tag)
end

type function channelView(channel, side)
	if not channel:is("table") then
		error(
			"a namespace holds channels, declared with nw.command, nw.intent, nw.signal, nw.query, "
				.. "nw.state or nw.event"
		)
	end

	local class = channel:readproperty(types.singleton("__class")):value()
	local audience = channel:readproperty(types.singleton("__audience")):value()
	local payload = channel:readproperty(types.singleton("__payload"))
	local response = channel:readproperty(types.singleton("__response"))

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

	local function listener(seen, withContext)
		local handler = if withContext
			then types.newfunction({ head = { types.unknown, seen } }, { head = {} })
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
				{ head = { types.unknown, brandedAs(payload, "__nwTrusted") } },
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
			error("a channel in this namespace has no readable type")
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
			error("a channel in this namespace has no readable type")
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
		error(`{what} needs a function, got {typeof(handler)}`, 3)
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
