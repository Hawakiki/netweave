# A worked example: trading

Three files, written by a reader who followed the nine steps and then built the thing a game
actually needs: a trade between two players, with an offer that has to be affordable, a decision
only the recipient may make, a live view of every open trade, a cursor the other party can see, a
price lookup, and an emote. It is here because it is the shape a real project arrives at, and
because each of the six places the reader got stuck is answered in it.

The code below is `tests/trade_ok.luau` with the Roblox requires put back and the two server
modules unstubbed; the analyzer accepts that file, so every spelling here is one the library
accepts. What each part demonstrates is said beside it.

## 1. The shared declaration — `ReplicatedStorage/Net/Trade.luau`

Required by both sides. Everything about who may do what is in this file, and nothing about it is
anywhere else.

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local nw = require(ReplicatedStorage.netweave.netweave)
local t = require(ReplicatedStorage.netweave.types)   -- the module, not nw.types: t.PayloadOf lives here

-- Schemas --------------------------------------------------------------------------------------

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

-- A policy's request type is written by hand (Step 3: the alias does not compose through nw.all).
type Offer = { to: Player, items: { number }, gold: number }
type Decision = { tradeId: number, accept: boolean }
-- Everything else is derived.
type Pending = t.PayloadOf<typeof(Pending)>

-- The seam the server fills at startup. Empty on the client, and never read there ---------------

local server = {} :: {
	wallet: { goldOf: (Player) -> number }?,
}

local pending: { [number]: Pending } = {}   -- filled by the server; the client's copy stays empty

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

-- Policies -------------------------------------------------------------------------------------

-- A policy that ignores the payload takes the schema as a witness, so each channel gets its own
-- Policy<T> and nw.all accepts it (Step 3).
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
			return nw.deny("wallet not attached")   -- fail closed
		end
		local balance = wallet.goldOf(ctx.player)
		return if balance < offer.gold then nw.deny(`offers {offer.gold}, holds {balance}`) else nw.allow()
	end
end)

-- Authorization that needs game state: a policy is a closure, so it closes over `pending`. The
-- check belongs on the declaration, not in the handler.
policy.party = nw.policy(function()
	return function(ctx: nw.Ctx, d: Decision)
		local p = pending[d.tradeId]
		if not p or p.to ~= ctx.player.UserId or p.state ~= "offered" then
			return nw.deny("not this player's open offer")
		end
		return nw.allow()
	end
end)

-- The namespace ---------------------------------------------------------------------------------

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
		rate = 20,             -- the client sends at this rate, not every frame
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
		audience = nw.audience.owner,          -- subject = the receiving Player
	}),
	resolved = nw.event({
		data = t.struct({ tradeId = t.u16, accepted = t.boolean }),
		-- subject = the trade id. The return is annotated because `{}` and `{ Player }` are not
		-- one type to the solver; an unknown subject returns an empty list and never raises.
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

return { ns = trade, pending = pending, server = server }
```

## 2. The server — `ServerScriptService/Trade.server.luau`

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local nw = require(ReplicatedStorage.netweave.netweave)
local Trade = require(ReplicatedStorage.Net.Trade)
local Wallet = require(ServerStorage.Wallet)
local Market = require(ServerStorage.Market)

Trade.server.wallet = Wallet          -- fill the seam, before the first packet

local trade, pending = Trade.ns, Trade.pending
local nextId = 0

type Offer = { to: Player, items: { number }, gold: number }

-- An authoritative function takes Trusted<T>. A signal's payload cannot reach it.
local function openTrade(from: Player, offer: nw.Trusted<Offer>): number
	nextId += 1
	pending[nextId] = { from = from.UserId, to = offer.to.UserId, gold = offer.gold, state = "offered" }
	return nextId
end

trade.server.offer:listen(function(ctx, offer)
	local from = ctx.player :: Player
	local id = openTrade(from, offer)
	trade.server.incoming:publish(offer.to, { tradeId = id, from = from.UserId })
	-- pending[id] reaches both parties on the next tick through `replicate`. Nothing to call here.
end)

trade.server.decide:listen(function(ctx, d)
	-- policy.party already guaranteed "the recipient, and the offer is open". Assume it here.
	local p = pending[d.tradeId]
	p.state = if d.accept then "accepted" else "declined"
	if d.accept then
		Wallet.transfer(p.from, p.to, p.gold)   -- must not yield (mistakes, 5)
	end
	trade.server.resolved:publish(d.tradeId, { tradeId = d.tradeId, accepted = d.accept })
end)

trade.server.hover:listen(function(ctx, h)
	-- once per player per tick, the newest value; show the other party the cursor
end)

trade.server.wave:listen(function(ctx, emote)
	-- Untrusted<"hello" | "thanks" | "no">. Display only.
end)

trade.server.priceOf:handle(function(ctx, itemId)
	return Market.price(itemId)   -- the one handler that may yield
end)

nw.observe(function(r)
	if r.stage == "authorize" or r.stage == "budget" then
		warn(`[trade] {r.channel} refused at {r.stage}: {r.reason}`)
	end
end)
```

## 3. The client — `StarterPlayerScripts/Trade.client.luau`

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Trade = require(ReplicatedStorage.Net.Trade)
local trade = Trade.ns

type Pending = { from: number, to: number, gold: number, state: "offered" | "accepted" | "declined" }
local held: { [number]: Pending } = {}

trade.client.incoming:listen(function(e)
	-- a popup; the details arrive in held[e.tradeId] a tick later
end)

trade.client.pending:listen(function(tradeId, value)
	if value == nil then
		held[tradeId] = nil            -- left the audience, or gone
		return
	end
	held[tradeId] = table.clone(value)  -- the value is a frozen baseline; copy before writing
end)

trade.client.resolved:listen(function(e) end)

-- buttons
local function offerTo(target: Player)
	trade.client.offer:send({ to = target, items = { 12, 40 }, gold = 500 })
end
local function decide(id: number, accept: boolean)
	trade.client.decide:send({ tradeId = id, accept = accept })
end
trade.client.wave:send("thanks")

-- an intent is sent at its declared rate, not every RenderStepped
local hoverSlot: number? = nil
local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc >= 1 / 20 and hoverSlot then
		acc = 0
		trade.client.hover:send({ slot = hoverSlot })
	end
end)

-- invoke yields: from a button handler or a task.spawn
local function showPrice(itemId: number)
	task.spawn(function()
		local price, why = trade.client.priceOf:invoke(itemId)
		if price then print(price) else warn(why) end
	end)
end
```

## What the reader changed after the analyzer saw it

Two things, both worth knowing. The two `select` functions gained a `: { Player }` return
annotation, because `if p then playersOf(p) else {}` is `{ Player } | {}` to the solver and the
audience wants `{ Player }`. And `policy.alive` became the `alive(schema)` helper, because one
`Policy<Offer>` cannot also be the policy on `decide` — Step 3 has the ten spellings that were tried.
Everything else survived contact with the analyzer as written.

[The mistakes this example avoids](mistakes.md) is the list of what went wrong on the way here,
ranked by how quietly each one fails.
