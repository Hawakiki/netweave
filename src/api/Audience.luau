--!strict
--!optimize 2

--[=[
	@class Audience

	Who a server-to-client channel reaches. Guarantee G3: every `state` and `event` declares this,
	and `broadcast` exists only where the audience is everyone.

	```lua
	playerState = nw.state({
		data = t.struct({ position = t.vector3 }),
		audience = nw.audience.nearby(120),
	}),
	```

	Making the recipient set a *declaration* rather than a call site is the point. Positional data
	leaking to players who cannot see it is how wallhacks are fed, and a call site that sends to
	everyone is invisible in review — a declaration is one reviewable line per channel.
]=]

--[[
	Evaluation belongs to M2, which owns the frame loop and can cache a recipient set per tick
	(`DESIGN-API.md` §10.4). What M1 fixes is the *shape*: an audience carries a `scope` singleton
	that the directional views branch on, which is what makes G3 a type error rather than a
	runtime check nobody runs.
]]

local Audience = {}

--[=[
	@type Scope "everyone" | "subset"
	@within Audience

	Whether the audience is provably every player. Only `everyone` gets `broadcast`.
]=]
export type Scope = "everyone" | "subset"

--[=[
	@interface Audience
	@within Audience
	.scope Scope
	.kind "everyone" | "owner" | "nearby" | "select"
	.radius number? -- `nearby`
	.select ((subject: any) -> { Player })? -- `select`

	:::caution
	`select` runs per publish. Until M2 caches it per tick, an expensive selector is charged to
	every send.
	:::
]=]
export type Audience<S> = {
	scope: S,
	kind: "everyone" | "owner" | "nearby" | "select",
	radius: number?,
	select: ((subject: any) -> { Player })?,
}

--[=[
	@prop everyone Audience<"everyone">
	@within Audience

	Every connected player. The only audience that permits `broadcast`.
]=]
Audience.everyone = table.freeze({
	scope = "everyone" :: "everyone",
	kind = "everyone" :: "everyone",
}) :: Audience<"everyone">

--[=[
	@prop owner Audience<"subset">
	@within Audience

	The player the published subject belongs to, and nobody else. The right default for anything
	that is per-player state — inventory, cooldowns, currency.
]=]
Audience.owner = table.freeze({
	scope = "subset" :: "subset",
	kind = "owner" :: "owner",
}) :: Audience<"subset">

--[=[
	@within Audience
	@function nearby
	@param studs number -- must be positive and finite
	@return Audience<"subset">

	Players within `studs` of the subject.

	```lua
	audience = nw.audience.nearby(120),
	```

	:::note
	A radius is a *replication* decision, not a security one on its own: a player who is inside
	the radius still receives the data. It narrows what an attacker can see to what they could
	plausibly see anyway.
	:::
]=]
function Audience.nearby(studs: number): Audience<"subset">
	if type(studs) ~= "number" or studs ~= studs or studs <= 0 or studs == math.huge then
		error(`audience.nearby needs a positive finite radius, got {tostring(studs)}`, 2)
	end

	return table.freeze({
		scope = "subset" :: "subset",
		kind = "nearby" :: "nearby",
		radius = studs,
	}) :: Audience<"subset">
end

--[=[
	@within Audience
	@function select
	@param chooser (subject: any) -> { Player }
	@return Audience<"subset">

	An explicit recipient list, computed per publish. The escape hatch for an audience the built-in
	kinds do not describe — a team, a party, a spectator list.

	```lua
	audience = nw.audience.select(function(match)
		return match.spectators
	end),
	```

	:::caution
	Returning every player here is not the same as `everyone`: it does not unlock `broadcast`, and
	it should not, because the type system cannot check that the list is complete.
	:::
]=]
function Audience.select(chooser: (subject: any) -> { Player }): Audience<"subset">
	if type(chooser) ~= "function" then
		error("audience.select needs a function", 2)
	end

	return table.freeze({
		scope = "subset" :: "subset",
		kind = "select" :: "select",
		select = chooser,
	}) :: Audience<"subset">
end

return table.freeze(Audience)
