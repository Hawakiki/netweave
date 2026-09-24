# Ten mistakes, ranked by how quietly they fail

Collected from a reader who built [the trade example](example-trade.md) after the nine steps,
and checked against the source. The order is frequency times silence: the ones at the top are the
ones you make often and find late.

## 1. Declaring a namespace in a server-only script — ~~quiet~~ refused at its line since M5

```lua
-- ServerScriptService/Admin.server.luau   ← the client never sees this file
local admin = nw.namespace("admin", {
	kick = nw.command({ data = t.player, rate = 1, authorize = policy.isAdmin }),
})
```

**What happened, until `PLAN-M5` phase 8.** The protocol hash is computed over *every* declaration
on each side. The server's hash includes `admin`; the client's does not; every client that connects
is refused at stage `protocol` on its first batch, and every batch after it. The whole game stops
moving, and the only place that says why is the console line `refused at protocol from <player>: the
peer is on protocol 0x… and this peer is on 0x…`, or an observer.

**What happens now.** `nw.namespace` reads the declaring module's name and refuses one under
`ServerScriptService` or `ServerStorage` at that line, before anything else, with the message
naming the module and the fix. And for the disagreements that are a matter of degree — a stale
client, a half-deployed build — every hello now travels with a per-namespace digest, and the
refusing peer's reason names the namespace one side lacks or the one a channel differs in, on both
consoles, instead of two hashes. This entry stays at the top because it is the one the list was
ranked around; in behaviour it now belongs with the immediate failures in §10.

**The fix.** Every namespace lives in a shared module under `ReplicatedStorage`, required by both
sides. A policy that is server-only reaches its dependency through a seam (Step 3), and the
declaration still ships to the client, where the policy never runs.

## 2. Sending an intent every frame — ~~quiet~~ paced by the client since M5

```lua
RunService.RenderStepped:Connect(function()
	trade.client.hover:send({ slot = current })   -- rate = 20, at 60 frames a second
end)
```

**What happens.** The budget is counted per packet, on the server, before the coalescing. Forty
refusals a second at stage `budget`, and the client is not told; the feature looks like it "mostly
works", which is why this one lasts.

**What happens now** (`PLAN-M5` phase 7). The client view holds the newest value per intent channel
and pushes it at the declared rate, through the same bucket the server runs: thirty packets a
second on the wire, none refused, the handler seeing the newest each tick. `nw.diagnostics().paced`
counts what was held. The `Heartbeat` accumulator in the example is no longer needed and does no
harm.

**The fix, before that.** Send at the rate you declared — a `Heartbeat` accumulator — or declare
the rate you send at.

## 3. Requiring a server module inside a policy factory — ~~by hand~~ the stage, since M5

```lua
policy.canAfford = nw.policy(function()
	local Wallet = require(game:GetService("ServerStorage").Wallet)   -- the factory runs at load, both sides
	return function(ctx, offer) ... end
end)
```

**What happens.** `nw.policy` runs the factory the moment it is called, in the shared file, on
whichever side is requiring it. The client crashes at startup with `Wallet is not a valid member of
ServerStorage`.

**The fix.** ~~The seam: the shared file exports an empty `server` table, the server fills it before
any traffic, and the check reads it and denies when it is empty.~~ Since `PLAN-M5` phase 7 the
factory returns a second function, the **server stage**, and does the `require` there: netweave runs
it once on the server at seal, before any packet decodes, and never on the client, and a stage that
raises fails the seal loudly. The seam still works for a library older than that. A `require`
inside the check also works and is cached, but its first call runs the module body inside the
receive loop, and a check must not yield.

## 4. Reusing a payload-agnostic policy, then "fixing" it with `any`

```lua
policy.alive = nw.policy(function()
	return function(ctx: nw.Ctx, _: Offer) ... end   -- Policy<Offer>
end)
decide = nw.command({ data = Decision, authorize = nw.all(policy.alive, policy.party) })
--> expected Policy, got Policy

-- and then:
	return function(ctx: nw.Ctx, _: any) ... end
```

**What happens.** `any` reaches the class's type function as an error type, and the whole
namespace's views become `unknown` — every handler in the file loses its payload type to fix one
diagnostic, and nothing says which channel did it.

**The fix, since `PLAN-M5` phase 1.** Write the agnostic check's request `unknown`, and one policy
goes on every channel — `Policy<T>` is an intersection, so contravariance applies (Step 3).
~~The schema-witness helper, `alive(Offer)`, `alive(Decision)`, `alive(t.u16)`, so each channel gets
its own `Policy<T>`.~~

## 5. Yielding inside a `command` handler — ~~quiet~~ reported at `handler` since M5

```lua
trade.server.decide:listen(function(ctx, d)
	local profile = DataStore:GetAsync(ctx.player.UserId)   -- yields
	pending[d.tradeId].state = ...
	trade.server.resolved:publish(d.tradeId, ...)
end)
```

**What happens.** The batch survives — reading and dispatching are separate passes for exactly this
reason — but the `ctx` you are holding is not yours after the yield: the record is reused per
player, so in Studio the next read raises and in production it hands you a later request's player.
The write to `pending` after the yield races every packet that arrived in between.

**What happens now** (`PLAN-M5` phase 7). When a handler or a policy check yields and another packet
of the same player is dispatched before it resumes, the transport notices — one integer compare
around the call — and reports it at stage `handler` or `authorize`, in production, with a reason
that spells the fix. A yield with no packet of that player in between is neither detected nor
harmed. The report comes *after* the damage, so the rest of this entry still applies; what changed
is that it is no longer silent.

**The fix.** Read values you already cached, or copy the fields you need and hand the rest to a
`task.spawn`. If the client needs the answer, it was a `query`: `:handle` is the one handler that
may yield, on a thread and a context of its own.

## 6. Declaring a state change as a `signal` to skip writing a policy

```lua
sell = nw.signal({ data = t.struct({ itemId = t.u16 }), rate = 5 }),   -- shortest thing to write

trade.server.sell:listen(function(ctx, s)
	Inventory.remove(ctx.player, s.itemId)   -- passes, if nothing is annotated
end)
```

**What happens.** This is the one thing the library cannot stop, and the README lists it as a limit.
It is caught only where `Inventory.remove` takes `nw.Trusted<T>`.

**The fix.** The discipline of writing `nw.Trusted<T>` on every function that changes authoritative
state. Then `Untrusted<T>` stops at that line, with a diagnostic.

## 7. Writing into a replicated value

```lua
trade.client.pending:listen(function(id, p)
	held[id] = p
end)
-- later
held[id].state = "accepted"   -- optimistic UI
```

**What happens.** The value is a frozen baseline, so the write raises. If it were not frozen, the
next delta would be applied to a base that no longer matches the server's, and that client would be
wrong for the rest of the session with nothing on either side saying so — which is why it is frozen.

**The fix.** `table.clone` for a flat value; copy as deep as you write for a nested one.

## 8. Keeping a `ctx` in an upvalue — reported the same way as 5 when a handler is the reader

```lua
local lastCtx
trade.server.offer:listen(function(ctx, offer)
	lastCtx = ctx
end)
task.delay(1, function() print(lastCtx.player) end)   -- a second later, a different request
```

**What happens.** The record is reused. In Studio the read raises with a message that says to copy
the fields; in production it is whichever request is live at that moment.

**The fix.** `local player = ctx.player` — copy the fields, keep the copies.

## 9. Passing a namespace to a function without the cast

```lua
local function wire(ns)   -- or ns: typeof(trade)
	ns.server.offer:listen(...)
end
wire(trade)
```

**What happens.** A solver quirk: the `offer` in `trade.server.offer:listen(function(ctx, offer)
… offer.gold … end)` written *earlier in the same file* becomes `unknown`, retroactively. The cause
is on a later line, which is what makes it hard to find.

**The fix.** `wire(trade :: nw.Views<typeof(trade.channels)>)`. The example exports
`type Trade = nw.Views<typeof(trade.channels)>` from the shared file for exactly this.

## 10. The small ones that fail immediately

```lua
local t = nw.types
type P = t.PayloadOf<typeof(X)>     -- a value table carries no types: require(…netweave.types)

t.enum({ "hello", "thanks" })       -- at load: an enum variant is named by a string key, and 1 is a number

returns = t.optional(t.u32),        -- refused at declaration: nil would be indistinguishable from failure

unreliable = true,                  -- on replicate or command: a type error

trade.server.pending:publish(...)   -- replicate has no publish; the store is the only way in

RunService.RenderStepped:Connect(function()
	local p = trade.client.priceOf:invoke(1)   -- invoke yields, and this callback cannot
end)

pos = t.vector3,                    -- 1e38 passes on an intent: t.vector3(t.i16(-2048, 2048))
```

The frightening one is the first on this page. It is common — everyone wants admin commands in a
server-only script — its symptom is "nothing works", and its cause is one word in a console line
that the default sink prints three times and then suppresses. Declare everything in shared
modules, on both sides, before the first packet moves.
