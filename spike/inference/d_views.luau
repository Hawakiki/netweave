--!strict

--[[
	Candidate D — directional views, the problem `DESIGN-API.md` §7 left open.

	`.server` and `.client` have to map each key of a declaration table to a *different* channel
	type: a `command` gets `listen` on the server and `send` on the client, a `state` gets
	`publish` on the server and `listen` on the client. That is a mapped type, and §7 assumed
	Luau could not express one.

	Candidate C showed `type function` can map. This asks the harder question: can a type
	function *branch* on which class a channel was declared as, and build a different result type
	per branch? If yes, G6 is a compile-time guarantee after all and §7's fallback is unnecessary.

	Channels carry a singleton `__class` tag so the type function has something to switch on.
]]

export type Command<T> = { __class: "command", __payload: T }
export type State<T> = { __class: "state", __payload: T }

type function channelView(channel, context)
	local class = channel:readproperty(types.singleton("__class")):value()
	local payload = channel:readproperty(types.singleton("__payload"))
	local view = types.newtable()

	local function listener(withCtx)
		--[[ `types.unknown` stands in for the real `Ctx` type; the spike only needs the shape. ]]
		local head = if withCtx then { types.unknown, payload } else { payload }
		local handler = types.newfunction({ head = head }, { head = {} })
		return types.newfunction({ head = { handler } }, { head = {} })
	end

	if class == "command" then
		if context == "server" then
			view:setproperty(types.singleton("listen"), listener(true))
		else
			view:setproperty(
				types.singleton("send"),
				types.newfunction({ head = { payload } }, { head = {} })
			)
		end
	elseif class == "state" then
		if context == "server" then
			view:setproperty(
				types.singleton("publish"),
				types.newfunction({ head = { types.unknown, payload } }, { head = {} })
			)
		else
			view:setproperty(types.singleton("listen"), listener(false))
		end
	end

	return view
end

type function ServerView(decl)
	local result = types.newtable()
	for key, property in decl:properties() do
		result:setproperty(key, channelView(property.read, "server"))
	end
	return result
end

type function ClientView(decl)
	local result = types.newtable()
	for key, property in decl:properties() do
		result:setproperty(key, channelView(property.read, "client"))
	end
	return result
end

local declaration = {
	fireWeapon = (nil :: any) :: Command<{ origin: number, seq: number }>,
	playerState = (nil :: any) :: State<{ health: number }>,
}

type Decl = typeof(declaration)

local server = (nil :: any) :: ServerView<Decl>
local client = (nil :: any) :: ClientView<Decl>

--[[ ASSERTION 1: the server view can listen to a command, with the payload type intact. ]]
server.fireWeapon.listen(function(_ctx, shot)
	local _seq: number = shot.seq
end)

--[[ ASSERTION 2: the client view can send a command. ]]
client.fireWeapon.send({ origin = 1, seq = 2 })

--[[ ASSERTION 3: the client view can listen to state. ]]
client.playerState.listen(function(state)
	local _health: number = state.health
end)

--[[ ASSERTION 4: direction violations must error. Both of these should fail. ]]
server.fireWeapon.send({ origin = 1, seq = 2 })
client.playerState.publish(nil, { health = 1 })

return nil
