# Step 9 — Naming the types in your own code

**What you have at the end:** every type netweave hands you, written down in your own annotations,
so that the guarantees reach past the handler into the code the handler calls.

The declaration infers everything: the payload of a channel, the arguments of a policy, what a
listener receives. Inside the callbacks you never write a type. The moment a value leaves a
callback for a function of your own is the moment you do, and this is the vocabulary for it.

## `nw.Trusted<T>` and `nw.Untrusted<T>`

```lua
type Equip = { slot: number }

local function equipFor(player: Player, chosen: nw.Trusted<Equip>)
	-- changes authoritative state
end

combat.server.equip:listen(function(ctx, chosen)
	equipFor(ctx.player :: Player, chosen)      -- fine: a command handler's payload is Trusted
end)

combat.server.openedMenu:listen(function(ctx, opened)
	log(`menu {opened.screen}`)                 -- fine: Untrusted<T> is a subtype of T
	-- equipFor(ctx.player :: Player, opened)   -- type error: a signal's payload is Untrusted
end)
```

`Trusted<T>` is produced by exactly three things: a `command` handler, a `query` handler, and
`nw.validate`. Nothing else in the process can make one by accident, which is what makes writing
it on an authoritative function worth the six characters. `Untrusted<T>` is a subtype of `T`, so
arithmetic, logging and UI work on it without ceremony; the only thing it cannot do is satisfy a
parameter annotated `Trusted<T>`. That protection is exactly as wide as the annotations you write,
and deciding which of your functions carry authority is the discipline this library sells.

For server-authored data that never came off a wire, the escape is an explicit, ugly cast:
`(value :: any) :: nw.Trusted<Equip>`. There is no `nw.untrust` and there will not be one, because
a pleasant name would be reached for reflexively and the brand would become decoration.

## `nw.Ctx`

```lua
local function nearSpawn(ctx: nw.Ctx): boolean
	local character = ctx.character
	return character ~= nil and (character:GetPivot().Position - SPAWN).Magnitude < 50
end
```

The type of the context a policy or handler receives: `player`, `channel`, `now`, `character`,
`humanoid`. Inside a handler `ctx.player` is `unknown`, for the reason Step 3 gives; a helper that
takes `nw.Ctx` reads it as `Player`.

## `t.PayloadOf<typeof(schema)>`

```lua
local Shot = t.struct({ origin = t.vector3, seq = t.u16 })
type Shot = t.PayloadOf<typeof(Shot)>            -- { origin: Vector3, seq: number }
```

The payload type of any schema, so that a function which builds or inspects one is typed from the
same source as the wire. Writing `{ origin: Vector3, seq: number }` by hand works too and drifts;
this does not. It is also how a union's `tag`/`value` pair is named (Step 8). The one place not
to use it is a policy's request parameter, where `nw.all` needs two payload types to be identical
and the alias is not reliably identical to itself; Step 3 has the measurement, and until `PLAN-M5`
closes it that parameter is written by hand.

One thing the earlier steps glossed: `local t = nw.types` binds the *values*, and a value cannot
carry type names, so `t.PayloadOf`, `t.Type` and `t.InstanceOptions` are not reachable through it.
Where you need the names, require the module:

```lua
local t = require(ReplicatedStorage.netweave.types)   -- the same constructors, plus the types
```

The constructors are the same either way; only the type namespace differs.

## `nw.Views<typeof(namespace.channels)>`

```lua
-- ReplicatedStorage/Combat.luau
local combat = nw.namespace("combat", { ... })
return combat

-- somewhere that takes the namespace as a parameter
local function wire(namespace: nw.Views<typeof(combat.channels)>)
	namespace.server.equip:listen(function(ctx, chosen) end)
end

wire(combat :: nw.Views<typeof(combat.channels)>)
```

`nw.namespace` returns the two views, and `nw.Views<D>` is their type for a function that takes
one. `typeof(combat.channels)` is the declaration's own type, so the parameter carries every
channel's payload and every view's methods without a line restated.

The cast at the call is not decoration. Measured while this tutorial was written: calling
`wire(combat)` with the bare value — or typing the parameter `typeof(combat)` — turns the payloads
of every handler written on `combat` *earlier in the same file* into `unknown`, retroactively, so a
`chosen.slot` that type-checked at Step 4 stops type-checking once the namespace has been passed
to a function. It is a solver behaviour rather than a netweave one, it does not happen when the
namespace is used nowhere else, and the cast is the spelling that keeps every handler typed. The
same solver quirk is the reason `tests/api_ok.luau` pins three spellings and `tests/api_reject.luau`
pins the one that must never be used, an annotated local with the value assigned into it.

## The rest

`nw.Rejection` and `nw.Stage` type an observer's argument and the stage it switches on.
`nw.Severity` is `"error" | "warn" | "off"`, for a game that maps its own log level onto netweave's.
`nw.Verdict` is what a policy check returns. `nw.Settings` is the table `nw.configure` takes, and
`nw.Diagnostics` is what `nw.diagnostics()` returns. On the schema side, `t.Type<T>` is any schema
whose payload is `T`, and `t.Ranged<number>`, `t.Text`, `t.Componented<Vector3>` and `t.Classed`
are the callable spellings — the types that carry the `(min, max)`, the options table, the
component schema and the class name respectively, for a helper that takes a constructor rather than
a finished schema.

`tools/exports.luau` fails the build when a public type is not written in some `tests/*_ok.luau`,
so every name above has a file where it is used in anger; `tests/tutorial_ok.luau` is the one for
this tutorial.

That closes the tutorial. `docs/DESIGN-API.md` is the contract behind every step, and
`docs/WIRE-FORMAT.md` the bytes.
