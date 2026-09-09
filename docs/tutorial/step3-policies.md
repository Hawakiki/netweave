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

A check returns a verdict: `nw.allow(value)` or `nw.deny(reason)`. `nw.allow()` with no value
passes the request through as it was; `nw.allow(request)` with a value hands that value on, so a
policy can narrow or rewrite what the handler receives. `nw.deny(reason)` refuses, and the reason is
what the observer sees in Step 5 — it is never sent back to the client, because the authorization
model is not the client's to learn.

## What a check can see

`ctx` is the context for this request. It carries `player`, the sender; `channel`, the qualified
name; `now`, the clock at receipt; and `character` and `humanoid`, looked up from the player the
first time something reads them and not before, so a channel whose policies never ask pays nothing.
It is valid only for the synchronous duration of the handler that received it: a `ctx` kept in an
upvalue and read on the next packet raises in Studio and is refused in production, because the
record is reused per player and the read would hand over another request's data
(`docs/DESIGN-API.md` §8).

`ctx` is read-only. `ctx.cooldown = 42` raises, in production as well as in Studio, with a message
that says to keep per-request state in your own table keyed by `ctx.player`.

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
