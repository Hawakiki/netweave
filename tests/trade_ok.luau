--!strict

--[[
	`docs/tutorial/example-trade.md`, as one file the analyzer has to accept.

	The example is three scripts — the shared declaration, the server, the client — written by a
	reader following the tutorial and kept because it is the shape a real game arrives at: a
	server-only dependency behind a seam, a policy that closes over game state, a select audience
	keyed by a trade id, a replicated table, an intent sent at its declared rate. The three are
	concatenated here with the Roblox requires replaced by relative ones and the two server modules
	(`Wallet`, `Market`) stubbed, and nothing else changed; where the example says `Trade.server`
	this file says `server`, because there is no module boundary to cross.

	Analysis only, like every `_ok` file.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local nw = require("../src/netweave")
local t = require("../src/types")

-- ---------------------------------------------------------------------------------------------
-- ReplicatedStorage/Net/Trade.luau — the shared declaration
-- ---------------------------------------------------------------------------------------------

local Offer = t.struct({
	to = t.player,
	items = t.array(t.u16, 1, 8),
	gold = t.u32(0, 1_000_000),
})
local Decision = t.struct({ tradeId = t.u16, accept = t.boolean })
local Pending = t.struct({
	from = t.u53,
	to = t.u53,
	gold = t.u32(0, 1_000_000),
	state = t.enum({ offered = true, accepted = true, declined = true }),
})

type Offer = { to: Player, items: { number }, gold: number }
type Decision = { tradeId: number, accept: boolean }
type Pending = t.PayloadOf<typeof(Pending)>

local server = {} :: {
	wallet: { goldOf: (Player) -> number }?,
}

local pending: { [number]: Pending } = {}

local function playersOf(p: Pending): { Player }
	local out = {}
	for _, id in { p.from, p.to } do
		local plr = Players:GetPlayerByUserId(id)
		if plr then
			table.insert(out, plr)
		end
	end
	return out
end

local function alive<T>(_schema: t.Type<T>)
	return nw.policy(function()
		return function(ctx: nw.Ctx, _request: T)
			return if ctx.humanoid ~= nil then nw.allow() else nw.deny("dead")
		end
	end)
end

local policy = {}

policy.notSelf = nw.policy(function()
	return function(ctx: nw.Ctx, offer: Offer)
		return if offer.to == ctx.player then nw.deny("cannot trade with yourself") else nw.allow()
	end
end)

policy.canAfford = nw.policy(function()
	return function(ctx: nw.Ctx, offer: Offer)
		local wallet = server.wallet
		if not wallet then
			return nw.deny("wallet not attached")
		end
		local balance = wallet.goldOf(ctx.player)
		return if balance < offer.gold then nw.deny(`offers {offer.gold}, holds {balance}`) else nw.allow()
	end
end)

policy.party = nw.policy(function()
	return function(ctx: nw.Ctx, d: Decision)
		local p = pending[d.tradeId]
		if not p or p.to ~= ctx.player.UserId or p.state ~= "offered" then
			return nw.deny("not this player's open offer")
		end
		return nw.allow()
	end
end)

local trade = nw.namespace("trade", {
	offer = nw.command({
		data = Offer,
		rate = 1,
		authorize = nw.all(alive(Offer), policy.notSelf, policy.canAfford),
	}),
	decide = nw.command({
		data = Decision,
		rate = 2,
		authorize = nw.all(alive(Decision), policy.party),
	}),
	hover = nw.intent({
		data = t.struct({ slot = t.u8(0, 7) }),
		rate = 20,
		unreliable = true,
	}),
	wave = nw.signal({
		data = t.enum({ hello = true, thanks = true, no = true }),
		rate = 1,
	}),
	priceOf = nw.query({
		args = t.u16,
		returns = t.u32(0, 1_000_000),
		rate = 5,
		timeout = 5,
		authorize = alive(t.u16),
	}),

	incoming = nw.event({
		data = t.struct({ tradeId = t.u16, from = t.u53 }),
		audience = nw.audience.owner,
	}),
	resolved = nw.event({
		data = t.struct({ tradeId = t.u16, accepted = t.boolean }),
		audience = nw.audience.select(function(subject): { Player }
			local p = pending[subject :: number]
			return if p then playersOf(p) else {}
		end),
	}),
	pending = nw.replicate({
		subject = t.u16,
		data = Pending,
		audience = nw.audience.select(function(subject): { Player }
			local p = pending[subject :: number]
			return if p then playersOf(p) else {}
		end),
		store = nw.store.of(pending),
	}),
})

export type Trade = nw.Views<typeof(trade.channels)>

-- ---------------------------------------------------------------------------------------------
-- ServerScriptService/Trade.server.luau
-- ---------------------------------------------------------------------------------------------

local Wallet = {
	goldOf = function(_player: Player): number
		return 1000
	end,
	transfer = function(_from: number, _to: number, _gold: number) end,
}

local Market = {
	price = function(_itemId: number): number
		return 5
	end,
}

server.wallet = Wallet

local nextId = 0

local function openTrade(from: Player, offer: nw.Trusted<Offer>): number
	nextId += 1
	pending[nextId] = { from = from.UserId, to = offer.to.UserId, gold = offer.gold, state = "offered" }
	return nextId
end

trade.server.offer:listen(function(ctx, offer)
	local from = ctx.player :: Player
	local id = openTrade(from, offer)
	trade.server.incoming:publish(offer.to, { tradeId = id, from = from.UserId })
end)

trade.server.decide:listen(function(_ctx, d)
	local p = pending[d.tradeId]
	p.state = if d.accept then "accepted" else "declined"
	if d.accept then
		Wallet.transfer(p.from, p.to, p.gold)
	end
	trade.server.resolved:publish(d.tradeId, { tradeId = d.tradeId, accepted = d.accept })
end)

trade.server.hover:listen(function(_ctx, h)
	local _slot: number = h.slot
end)

trade.server.wave:listen(function(_ctx, emote)
	local _emote = emote
end)

trade.server.priceOf:handle(function(_ctx, itemId)
	return Market.price(itemId)
end)

nw.observe(function(r)
	if r.stage == "authorize" or r.stage == "budget" then
		warn(`[trade] {r.channel} refused at {r.stage}: {r.reason}`)
	end
end)

-- ---------------------------------------------------------------------------------------------
-- StarterPlayerScripts/Trade.client.luau
-- ---------------------------------------------------------------------------------------------

local held: { [number]: Pending } = {}

trade.client.incoming:listen(function(e)
	local _tradeId: number = e.tradeId
end)

trade.client.pending:listen(function(tradeId, value)
	if value == nil then
		held[tradeId] = nil
		return
	end
	held[tradeId] = table.clone(value)
end)

trade.client.resolved:listen(function(e)
	local _accepted: boolean = e.accepted
end)

local function offerTo(target: Player)
	trade.client.offer:send({ to = target, items = { 12, 40 }, gold = 500 })
end

local function decide(id: number, accept: boolean)
	trade.client.decide:send({ tradeId = id, accept = accept })
end

trade.client.wave:send("thanks")

local hoverSlot: number? = nil
local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc >= 1 / 20 and hoverSlot then
		acc = 0
		trade.client.hover:send({ slot = hoverSlot })
	end
end)

local function showPrice(itemId: number)
	task.spawn(function()
		local price, why = trade.client.priceOf:invoke(itemId)
		if price then
			print(price)
		else
			warn(why)
		end
	end)
end

local _use = { offerTo, decide, showPrice }

return true
