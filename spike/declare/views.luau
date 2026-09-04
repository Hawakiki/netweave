--!strict

--[[
	Spike — the six classes as directional views, and the brand applied only where it binds.

	`spike/inference/d_views.luau` proved a type function can branch on `__class` for two classes.
	This asks for the whole taxonomy plus the two things that turned out to be load-bearing:
	`query` carries two payloads, and `broadcast` must exist only where the audience is everyone.
]]

export type Channel<C, A, T, R> = {
	__class: C,
	__audience: A,
	__payload: T,
	__response: R,
}

type function brand(input, name)
	--[[
		Measured in `spike/declare/brand.luau`: `number & { tag }` normalises to `never`, which is
		a subtype of everything, so branding a scalar removes every legitimate use of the value and
		blocks nothing. Tables only.
	]]
	local payload = types.copy(input)

	if not payload:is("table") then
		return payload
	end

	local tag = types.newtable()
	tag:setproperty(types.singleton(name), types.optional(types.singleton(true)))
	return types.intersectionof(payload, tag)
end

type function view(channel, side)
	local class = channel:readproperty(types.singleton("__class")):value()
	local audience = channel:readproperty(types.singleton("__audience")):value()
	local payload = channel:readproperty(types.singleton("__payload"))
	local response = channel:readproperty(types.singleton("__response"))
	local out = types.newtable()

	local ctx = types.unknown

	local function inbound(seen)
		local handler = types.newfunction({ head = { ctx, seen } })
		out:setproperty(types.singleton("listen"), types.newfunction({ head = { handler } }))
	end

	if class == "command" or class == "intent" or class == "signal" then
		if side == "server" then
			if class == "command" then
				inbound(brand(payload, "__nwTrusted"))
			elseif class == "signal" then
				inbound(brand(payload, "__nwUntrusted"))
			else
				inbound(payload)
			end
		else
			out:setproperty(types.singleton("send"), types.newfunction({ head = { payload } }))
		end
	elseif class == "query" then
		if side == "server" then
			local handler = types.newfunction(
				{ head = { ctx, brand(payload, "__nwTrusted") } },
				{ head = { response } }
			)
			out:setproperty(types.singleton("handle"), types.newfunction({ head = { handler } }))
		else
			out:setproperty(
				types.singleton("invoke"),
				types.newfunction(
					{ head = { payload } },
					{ head = { types.optional(response), types.optional(types.string) } }
				)
			)
		end
	else
		if side == "server" then
			out:setproperty(
				types.singleton("publish"),
				types.newfunction({ head = { types.unknown, payload } })
			)
			if audience == "everyone" then
				out:setproperty(types.singleton("broadcast"), types.newfunction({ head = { payload } }))
			end
		else
			inbound(payload)
			out:setproperty(
				types.singleton("listen"),
				types.newfunction({ head = { types.newfunction({ head = { payload } }) } })
			)
		end
	end

	return out
end

type function ServerView(decl)
	local result = types.newtable()
	for key, property in decl:properties() do
		result:setproperty(key, view(property.read, "server"))
	end
	return result
end

type function ClientView(decl)
	local result = types.newtable()
	for key, property in decl:properties() do
		result:setproperty(key, view(property.read, "client"))
	end
	return result
end

type Shot = { origin: number, seq: number }

local declaration = {
	fireWeapon = (nil :: any) :: Channel<"command", "none", Shot, nil>,
	aim = (nil :: any) :: Channel<"intent", "none", { pitch: number }, nil>,
	openedMenu = (nil :: any) :: Channel<"signal", "none", { id: number }, nil>,
	getLoadout = (nil :: any) :: Channel<"query", "none", number, { primary: number }>,
	playerState = (nil :: any) :: Channel<"state", "nearby", { health: number }, nil>,
	roundOver = (nil :: any) :: Channel<"event", "everyone", { winner: number }, nil>,
}

type Decl = typeof(declaration)

local server = (nil :: any) :: ServerView<Decl>
local client = (nil :: any) :: ClientView<Decl>

-- CONTROLS ------------------------------------------------------------------------------------

server.fireWeapon.listen(function(_ctx, shot)
	local _seq: number = shot.seq
end)

server.aim.listen(function(_ctx, look)
	local _pitch: number = look.pitch
end)

server.getLoadout.handle(function(_ctx, slot)
	local _n: number = slot
	return { primary = 1 }
end)

server.playerState.publish(nil, { health = 1 })
server.roundOver.broadcast({ winner = 2 })

client.fireWeapon.send({ origin = 1, seq = 2 })
client.playerState.listen(function(state)
	local _h: number = state.health
end)
local _loadout, _failure = client.getLoadout.invoke(0)

--[[ The brand reaches the handler parameter. ]]
local function applyDamage(_shot: Shot & { __nwTrusted: true? }) end
server.fireWeapon.listen(function(_ctx, shot)
	applyDamage(shot)
end)

-- MUST FAIL -----------------------------------------------------------------------------------

--[[ Direction: the server does not send, the client does not publish. ]]
server.fireWeapon.send({ origin = 1, seq = 2 })
client.playerState.publish(nil, { health = 1 })

--[[ G3: `broadcast` exists only where the audience is everyone. ]]
server.playerState.broadcast({ health = 1 })

--[[ A signal payload is branded untrusted, so it cannot reach an authoritative function. ]]
local function grantMenu(_id: { id: number } & { __nwTrusted: true? }) end
server.openedMenu.listen(function(_ctx, id)
	grantMenu(id)
end)

return nil
