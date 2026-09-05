--!strict
--!optimize 2

--[=[
	@class Namespace

	A group of channels declared together, and the two directional views over it.

	```lua
	-- shared/Combat.luau
	return nw.namespace("combat", {
		fireWeapon = nw.command({ data = ShotSchema, rate = 20, authorize = policy.canFire }),
		playerState = nw.state({ data = StateSchema, audience = nw.audience.nearby(120) }),
	})
	```

	```lua
	local combat = require(Shared.Combat)

	combat.server.fireWeapon:listen(function(ctx, shot) end)  -- server.luau
	combat.client.fireWeapon:send(shot)                       -- client.luau
	```

	One file per namespace, required by both sides. That is what makes the security model
	reviewable: the declaration is the only place a channel's budget, audience and policy are
	written, and it is a file a reviewer can open.
]=]

--[[
	Ids are not assigned here, and cannot be.

	`WIRE-FORMAT.md` §3 assigns them by sorting *every* qualified name in the program and numbering
	from 1, so an id depends on namespaces this one has never heard of. Declaring one more channel
	anywhere renumbers everything, which is fine — both peers recompute the same list — but it
	means a namespace can only register its channels and wait.

	The alternative, per-namespace numbering with a namespace prefix on the wire, costs a byte per
	packet forever to save one sort at startup.
]]

local Channel = require("./Channel")
local Protocol = require("./Protocol")
local View = require("./View")

local Namespace = {}

--[=[
	@interface Namespace
	@within Namespace
	.name string
	.server { [string]: any } -- `ServerView<D>` once the declaration's type is known
	.client { [string]: any } -- `ClientView<D>`
	.channels { [string]: Channel }
]=]
export type Namespace = {
	name: string,
	server: { [string]: any },
	client: { [string]: any },
	channels: { [string]: any },
}

local namespaces: { [string]: Namespace } = {}
local order: { string } = {}
local sealed = false

local function checkName(name: string)
	if type(name) ~= "string" or name == "" then
		error(
			`nw.namespace takes the name first and the channels second, got {typeof(name)}. Write it `
				.. `as nw.namespace("combat", \{ fireWeapon = nw.command(\{ ... }) }) — the name is half `
				.. `of every channel id on the wire, so it cannot be left out.`,
			3
		)
	end

	--[[ The name is half of every qualified id, and a dot in it would make `combat.fire.weapon`
	     ambiguous about where the namespace ends. ]]
	if string.find(name, ".", 1, true) then
		error(
			`the namespace name "{name}" contains a dot, and a channel id is namespace .. "." .. key. `
				.. `Rename it without one — nw.namespace("combatRanged", ...) rather than `
				.. `"combat.ranged" — or "combat.ranged.fire" would be ambiguous about where the `
				.. `namespace ends.`,
			3
		)
	end

	if namespaces[name] then
		error(
			`the namespace {name} is already declared. Two namespaces with one name would collide `
				.. `on the wire, because a channel id is derived from namespace .. "." .. key. Give `
				.. `this one a different name, or require the existing module instead of declaring a `
				.. `second copy — nw.namespace is called once per namespace, at load.`,
			3
		)
	end
end

--[=[
	@within Namespace
	@function declare
	@param name string -- qualifies every channel id: `"combat.fireWeapon"`
	@param channels { [string]: Channel }
	@return Namespace

	Declares a namespace. Channel ids come from the string keys, never from table iteration order.

	:::caution
	Declare every namespace before the first packet moves. Adding one afterwards renumbers the
	channel ids, and the two peers would disagree — which is silent, and decodes every packet as
	the wrong type. `nw.protocol()` is what both sides compare to catch that.
	:::

	:::caution
	**On a client, "the first packet" is one that *arrives*.** Requiring netweave connects the
	receive side, and the first batch the server sends seals the numbering — so a client that yields
	between `require(netweave)` and its namespace modules (a `WaitForChild`, a deferred require) can
	be sealed by traffic it did not ask for, and the next declaration raises. Require every namespace
	in one unbroken run, before anything yields.

	This cannot be fixed by deferring the seal: decoding an inbound packet needs the id numbering,
	and the numbering needs every declaration. See `docs/WIRE-FORMAT.md` §3.
	:::
]=]
function Namespace.declare(name: string, channels: { [string]: any }): Namespace
	checkName(name)

	if type(channels) ~= "table" then
		error(`nw.namespace needs a table of channels, got {typeof(channels)}`, 2)
	end

	if sealed then
		--[[ The cause this names last is the one that is hardest to find: on a client, a *received*
		     packet seals, so a `WaitForChild` between requiring netweave and requiring this module
		     is enough. Found by an external review (M3 phase 9); it cannot be fixed by sealing
		     later, because decoding the packet that sealed it needs the numbering. ]]
		error(
			`the namespace {name} was declared after the protocol was sealed. Every channel id `
				.. `depends on every other, so a late declaration renumbers ids the other peer has `
				.. `already agreed to. Require all namespaces at startup, in one run — on a client `
				.. `the first packet to arrive seals the protocol, so a yield before this line is `
				.. `enough to lose the race.`,
			2
		)
	end

	local count = 0

	for key, channel in channels do
		if type(key) ~= "string" then
			error(
				`{name} has a non-string channel key, and ids come from the keys. Write the channels `
					.. `as named fields — \{ fireWeapon = nw.command(\{ ... }) } — rather than as an `
					.. `array, because a positional list would renumber the wire every time one is `
					.. `inserted.`,
				2
			)
		end

		if not Channel.isChannel(channel) then
			error(
				`{name}.{key} is not a channel. Declare it with nw.command, nw.intent, nw.signal, `
					.. `nw.query, nw.state or nw.event.`,
				2
			)
		end

		if channel.qualified ~= "" then
			error(
				`{name}.{key} is already declared as {channel.qualified}. A channel belongs to one `
					.. `namespace; sharing the record would give it two ids and two budgets. Declare a `
					.. `second one with its own nw.command(\{...}), or move the shared *schema* into `
					.. `a local and build both from it — a schema is reusable, a channel is not.`,
				2
			)
		end

		channel.key = key
		channel.qualified = `{name}.{key}`
		count += 1
	end

	if count == 0 then
		error(
			`the namespace {name} declares no channels, so nothing about it can reach the wire. Add `
				.. `the ones it is for — nw.namespace("{name}", \{ fireWeapon = nw.command(\{ ... }) }) `
				.. `— or delete the declaration.`,
			2
		)
	end

	local namespace: Namespace = {
		name = name,
		channels = channels,
		server = View.build(channels, "server"),
		client = View.build(channels, "client"),
	}

	namespaces[name] = namespace
	table.insert(order, name)

	return namespace
end

--[[
	~~FNV-1a over the sorted qualified names.~~ **Moved to `src/api/Protocol.luau` in M3 phase 5, and
	widened to cover the lowered IR.**

	The old note here said a field whose type changed under an unchanged name was left to the
	per-field validation, "which is the right place because it is per packet rather than per
	session". That was wrong twice over: the per-field validation refuses *every* packet for the rest
	of the session, and it never says why. `PLAN-M3` D-7.
]]

--[=[
	@interface Protocol
	@within Namespace
	.hash number -- FNV-1a over the lowered IR of every channel
	.count number -- how many channels were numbered
	.names { string } -- sorted, so `names[id]` is the channel with that id

	Re-exported from [Protocol], which is where it is computed.
]=]
export type Protocol = Protocol.Protocol

local protocol: Protocol? = nil

--[[ Wire id to channel, built when the protocol is sealed. The receive path resolves through this
     once per packet, so it is a flat array-like table rather than a search. ]]
local byId: { [number]: any } = {}

--[=[
	@within Namespace
	@function seal
	@return Protocol

	Assigns every channel its wire id and freezes the set. Called automatically on the first
	`nw.protocol()`; call it yourself once every namespace has been required, if you want the
	failure for a late declaration to point at the late one.

	Ids are `1..n` over all qualified names in the program, sorted. **Id 0 is reserved** for
	control traffic — the schema handshake, and whatever v2 needs.
]=]
function Namespace.seal(): Protocol
	local existing = protocol

	if existing then
		return existing
	end

	local names: { string } = {}
	local byName: { [string]: any } = {}

	for _, name in order do
		for _, channel in namespaces[name].channels do
			table.insert(names, channel.qualified)
			byName[channel.qualified] = channel
		end
	end

	--[[ Sorted, never iterated. ByteNet assigns ids by walking its declaration table and this
	     project hit the resulting silent mis-decode during M0 phase 3: every packet decodes as the
	     wrong type, and nothing reports it. ]]
	table.sort(names)

	table.clear(byId)

	for id, qualified in names do
		local channel = byName[qualified]
		channel.id = id
		byId[id] = channel
	end

	--[[ After the ids are assigned, not before: the signature is taken in id order, and a channel
	     without an id has nothing to be in order by. ]]
	local computed = Protocol.digest(names, byName)

	protocol = computed
	sealed = true

	return computed
end

--[=[
	@within Namespace
	@function protocol
	@return Protocol

	The agreed channel numbering, sealing it if that has not happened yet.

	Both peers compute this from their own copy of the declarations. If the two hashes differ — a
	stale client, a partial deploy — every packet would decode as the wrong channel, so the
	mismatch is refused at startup rather than producing corrupt payloads for the session.
]=]
function Namespace.protocol(): Protocol
	return Namespace.seal()
end

--[=[
	@within Namespace
	@function channelById
	@param id number
	@return Channel?
	@private

	The channel a wire id names, sealing the protocol if that has not happened yet.

	Sealing here rather than at load is what lets a game declare its namespaces in any order and in
	any file: an id depends on every other channel in the program (`docs/WIRE-FORMAT.md` §3), so the
	numbering cannot be fixed until the last declaration has run. The first packet in either
	direction is the latest that can be.
]=]
--[=[
	@within Namespace
	@function replicated
	@return { Channel }
	@private

	Every declared `replicate` channel, in id order, sealing the protocol if that has not happened
	yet.

	The replication tick needs the list once a frame and nothing else needs it at all, so it is
	built on demand rather than kept — and it is short, because a game declares a handful of
	replicated channels and thousands of subjects on them.
]=]
function Namespace.replicated(): { any }
	if not protocol then
		Namespace.seal()
	end

	local out = {}

	for id = 1, #byId do
		local channel = byId[id]

		if channel and channel.class == "replicate" then
			table.insert(out, channel)
		end
	end

	return out
end

function Namespace.channelById(id: number): any?
	if not protocol then
		Namespace.seal()
	end

	return byId[id]
end

--[=[
	@within Namespace
	@function channelByName
	@param qualified string -- `"combat.fireWeapon"`
	@return Channel?
	@private

	The channel behind a qualified name, sealing the protocol if that has not happened yet.

	Exists for `nw.signature()`, which walks the protocol's own name list and needs the declaration
	behind each one. A search rather than a table, because it runs once when a human asks why two
	builds disagree.
]=]
function Namespace.channelByName(qualified: string): any?
	if not protocol then
		Namespace.seal()
	end

	for _, channel in byId do
		if channel.qualified == qualified then
			return channel
		end
	end

	return nil
end

--[=[
	@within Namespace
	@function get
	@param name string
	@return Namespace?
	@private
]=]
function Namespace.get(name: string): Namespace?
	return namespaces[name]
end

--[=[
	@within Namespace
	@function reset
	@private

	Forgets every namespace. Exists so one test file can declare a namespace and the next can too;
	a game that calls this has renumbered every channel out from under its peer.
]=]
function Namespace.reset()
	table.clear(namespaces)
	table.clear(order)
	table.clear(byId)
	protocol = nil
	sealed = false
end

return Namespace
