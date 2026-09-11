# Step 3 — Write a policy

**What you have at the end:** the `equip` command from Step 2 checked by two real policies, composed,
with the reason for every refusal written down.

## Two stages: build once, check per request

A policy is made with `nw.policy(factory)`. The factory runs once, when the policy is attached, and
returns the function that runs per request. That split is what lets a policy take configuration
without paying for it on every packet:

```lua
--!strict
-- ReplicatedStorage/Policy.luau

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local nw = require(ReplicatedStorage.netweave.netweave)
local t = require(ReplicatedStorage.netweave.types)

local Equip = t.struct({ slot = t.u8(0, 9) })
type Equip = { slot: number }

local policy = {}

policy.alive = nw.policy(function()
	return function(ctx: nw.Ctx, _request: Equip)
		return ctx.humanoid ~= nil and nw.allow() or nw.deny("dead")
	end
end)

policy.ownsSlot = nw.policy(function(config)
	local slots: number = config.slots or 3

	return function(_ctx: nw.Ctx, request: Equip)
		if request.slot > slots then
			return nw.deny(`slot {request.slot} is past the {slots} this player owns`)
		end
		return nw.allow(request)
	end
end)

return policy
```

`type Equip = { slot: number }` is written by hand here, and it is the one place in this tutorial
where the schema's type is. `nw.all` composes two policies only when their payload types are
*identical*, and a `t.PayloadOf<typeof(Equip)>` alias is not reliably identical to itself across
two closures: measured across ten spellings while this step was written, the alias fails to compose
in most shapes a policy module takes — policies kept as fields of a table, a factory that takes
`config`, a check written with the `and … or` idiom — with a diagnostic that reads "expected Policy,
got Policy" because one side has become `Policy<unknown>`. The same shapes with a hand-written type
compose every time. So: derive payload types with `t.PayloadOf` everywhere else (Steps 8 and 9), and
write a policy's request type by hand. Making the alias compose is `PLAN-M5` phase 3, item 43.

A check returns a verdict: `nw.allow(value)` or `nw.deny(reason)`. `nw.allow()` with no value
passes the request through as it was; `nw.allow(request)` with a value hands that value on, so a
policy can narrow or rewrite what the handler receives. `nw.deny(reason)` refuses, and the reason is
what the observer sees in Step 5 — it is never sent back to the client, because the authorization
model is not the client's to learn.

## What a check can see

`ctx` is the context for this request. It carries `player`, the sender; `channel`, the qualified
name; `now`, the clock at receipt; and `character` and `humanoid`, looked up from the player the
first time something reads them and not before, so a channel whose policies never ask pays nothing.
Inside a handler `ctx.player` is typed `unknown`, because the type that builds the handler's
signature cannot name `Player`; it passes anywhere `unknown` is accepted, `publish` included, and
where you need the real type you write `ctx.player :: Player` (`docs/DESIGN-API.md` §8).
It is valid only for the synchronous duration of the handler that received it. The record is reused
per player, so a `ctx` kept in an upvalue and read during a later packet's handler would quietly
hand over *that* request's data; in Studio every acquisition is wrapped in a guard that raises on
exactly that read, with a message that says to copy the fields you need instead. Production hands
out the bare record and pays nothing, which is why the Studio pass is where this mistake is found
(`docs/DESIGN-API.md` §8).

`ctx` is read-only. `ctx.cooldown = 42` raises, in production as well as in Studio, with a message
that says to keep per-request state in your own table keyed by `ctx.player`.

## A value you already hold

Sometimes the thing to authorize did not come off the wire: a value read from a datastore, or built
by another system, that you want to hand to a function annotated `Trusted<T>`.
`nw.validate(schema, value)` is the one way to produce that type without a packet:

```lua
local trusted, reason = nw.validate(Equip, { slot = 2 })

if trusted then
	equipTrusted(trusted)   -- takes Trusted<{ slot: number }>
else
	warn(reason)
end
```

It decides by running the encoder, so it is exactly as strict as the encoder is and no stricter,
and it returns a copy rather than the table you passed in. It runs no policy: `Trusted<T>` from
`validate` means "this value fits the schema", and the `T` from a `command` handler means that
*and* "the declared policy allowed it from this player". Both are useful, and they are not the same
claim (`docs/DESIGN-API.md` §6).

## Where the two stages run, and what that means for server-only code

The outer function runs **at load**, inside `nw.policy` itself, and again whenever a configured
form like `policy.ownsSlot({ slots = 3 })` is called — which is to say, in the shared declaration
file, on whichever side is requiring it. The client requires that file too. So a factory that
reaches for `ServerStorage` breaks the client at startup, and this is the first thing a real policy
runs into: a wallet, a datastore wrapper, an inventory service, all of which exist on one side.

The inner function runs only where a packet is received, which for every inbound class is the
server. So a factory has a third piece for exactly this: a **server stage**, a second function it
may return, which netweave runs once on the server when the protocol is sealed — before any packet
decodes — and discards on the client. It is the place to reach the module that exists on one side:

```lua
-- ReplicatedStorage/Net/Trade.luau — required by both sides
local Offer = t.struct({ to = t.player, gold = t.u32(0, 1_000_000) })
type Offer = { to: Player, gold: number }

type Wallet = { goldOf: (Player) -> number }

policy.canAfford = nw.policy(function()
	local wallet: Wallet? = nil                         -- filled by the stage; nil on the client, unread there

	return function(ctx: nw.Ctx, offer: Offer)          -- per request, server only
		local held = (wallet :: Wallet).goldOf(ctx.player)
		return if held < offer.gold then nw.deny(`offers {offer.gold} gold, holds {held}`) else nw.allow()
	end, function()                                     -- once, at seal, server only
		wallet = require(game:GetService("ServerStorage").Wallet)
	end
end)
```

The check can cast `wallet` without a guard, because the stage has run before the first packet
that could reach the check: a stage that raises or yields fails the seal with the channel named,
loudly, at startup, rather than letting a check run over nothing. A policy attached to two
channels — or a member of two `nw.all` compositions — runs its stage once. A `require` inside the
stage is fine, because the stage runs synchronously at seal and never inside the receive loop.

Before `PLAN-M5` the same problem was solved by hand with a seam: an empty table the shared file
exports, the server fills at startup, and the check reads and denies when empty. That spelling
still works and is what a library older than this milestone needs; the stage is the seam folded
into the declaration, with the fail-closed behaviour enforced by the seal instead of by the game.
Either way, **a check must not yield**: it holds a `ctx` that is recycled the moment it returns,
and the loop behind it is waiting.

## A policy that needs game state

The same closure answers the other common question: a decision about a trade needs the trade. A
policy is an ordinary closure, so it can close over the table that holds the thing, and the check
then makes the authorization decision the declaration promised rather than leaving it to the
handler:

```lua
local Decision = t.struct({ tradeId = t.u16, accept = t.boolean })
type Decision = { tradeId: number, accept: boolean }

type Pending = { from: number, to: number, gold: number, state: "offered" | "accepted" | "declined" }
local pending: { [number]: Pending } = {}   -- filled by the server; the client's copy stays empty

policy.party = nw.policy(function()
	return function(ctx: nw.Ctx, decision: Decision)
		local offer = pending[decision.tradeId]

		if not offer or offer.to ~= ctx.player.UserId or offer.state ~= "offered" then
			return nw.deny("not this player's open offer")
		end

		return nw.allow()
	end
end)
```

A `decide` command declared with `authorize = nw.all(policy.alive, policy.party)` now has its
whole security condition on the declaration line, and the handler that runs after it can assume the
sender is the recipient of an open offer. Putting that check in the handler instead works, and is
the habit most code arrives with; it also means the declaration no longer says what it enforces,
which is the one thing this library asks you to give up.

## A policy that ignores the payload

`policy.alive` above reads no field of the request, and it is still annotated `_request: Equip`,
which makes it `Policy<Equip>` and nothing else: composed with a `Policy<Offer>` through `nw.all`
it is a type error, "expected Policy, got Policy". That is the first thing a second channel runs
into, and the spellings that look like the fix do not work today — an unannotated `_request` and
`unknown` fail the same way, and `any` reaches the class's type function as an error type and takes
the whole namespace's views down with it. All four were measured writing this step.

What works is to write the payload-agnostic policy as a helper that takes the schema as a witness,
so the type is inferred from the argument and each channel gets its own instance:

```lua
local function alive<T>(_schema: t.Type<T>)
	return nw.policy(function()
		return function(ctx: nw.Ctx, _request: T)
			return ctx.humanoid ~= nil and nw.allow() or nw.deny("dead")
		end
	end)
end

offer = nw.command({ data = Offer, rate = 1, authorize = nw.all(alive(Offer), policy.canAfford) }),
decide = nw.command({ data = Decision, rate = 2, authorize = nw.all(alive(Decision), policy.party) }),
priceOf = nw.query({ args = t.u16, returns = t.u32, rate = 5, timeout = 5, authorize = alive(t.u16) }),
```

The factory runs once per instance, so this costs one closure per channel at load and nothing per
request. Making `Policy<T>` compose across payloads without the witness is `PLAN-M5` phase 3.

## Compose them

`nw.all(...)` runs policies in order, threads the allowed value from each into the next, and stops
at the first denial:

```lua
local policy = require(ReplicatedStorage.Policy)

return nw.namespace("combat", {
	equip = nw.command({
		data = Equip,
		rate = 5,
		authorize = nw.all(policy.alive, policy.ownsSlot({ slots = 3 })),
	}),
	-- loadout as in Step 2
})
```

`policy.alive` is used bare, because its factory takes no configuration; `policy.ownsSlot({ slots = 3 })`
is called, because its factory does. Both spellings produce the same kind of value, and a reviewer
reading the declaration sees the whole authorization chain on one line.

## What the handler receives

Because `equip` is a `command` with a policy, its server handler receives the payload as
`Trusted<{ slot: number }>`. It decoded against the schema, it was inside the declared rate, and every
policy allowed it. Nothing else in the process can produce that type by accident, which is what makes
annotating an authoritative function with `Trusted<T>` worth doing: a value that came from a
`signal`, or from a table a script built by hand, does not fit.

## What does not type-check

`nw.all()` with no arguments is refused at declaration: it composes policies and was given none.
A factory that returns something other than a function is refused when the policy is attached. And a
`signal` with `authorize` is refused at analysis, which is the flip side of this step: if a channel
needs approving, it was a `command` (`docs/DESIGN-API.md` §5, §6).

**Next:** [Step 4 — Send, listen, publish](step4-send-and-listen.md)
