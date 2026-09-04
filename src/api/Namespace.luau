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
		error(`a namespace needs a name, got {typeof(name)}`, 3)
	end

	--[[ The name is half of every qualified id, and a dot in it would make `combat.fire.weapon`
	     ambiguous about where the namespace ends. ]]
	if string.find(name, ".", 1, true) then
		error(`a namespace name cannot contain a dot: {name}`, 3)
	end

	if namespaces[name] then
		error(
			`the namespace {name} is already declared. Two namespaces with one name would collide `
				.. `on the wire, because a channel id is derived from namespace .. "." .. key.`,
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
]=]
function Namespace.declare(name: string, channels: { [string]: any }): Namespace
	checkName(name)

	if type(channels) ~= "table" then
		error(`nw.namespace needs a table of channels, got {typeof(channels)}`, 2)
	end

	if sealed then
		error(
			`the namespace {name} was declared after the protocol was sealed. Every channel id `
				.. `depends on every other, so a late declaration renumbers ids the other peer has `
				.. `already agreed to. Require all namespaces at startup.`,
			2
		)
	end

	local count = 0

	for key, channel in channels do
		if type(key) ~= "string" then
			error(`{name} has a non-string channel key; ids come from the keys`, 2)
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
					.. `namespace; sharing the record would give it two ids and two budgets.`,
				2
			)
		end

		channel.key = key
		channel.qualified = `{name}.{key}`
		count += 1
	end

	if count == 0 then
		error(`the namespace {name} declares no channels`, 2)
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
	FNV-1a, 32-bit, over the sorted qualified names joined with newlines (`WIRE-FORMAT.md` §4).

	The hash covers *names* only. A field whose type changed under an unchanged name is not caught
	here — the per-field validation catches that as a rejection instead, which is the right place
	because it is per packet rather than per session.
]]
local function fnv1a(text: string): number
	local hash = 2166136261

	for index = 1, #text do
		hash = bit32.bxor(hash, string.byte(text, index))
		hash = bit32.band(hash * 16777619, 0xFFFFFFFF)
	end

	return hash
end

--[=[
	@interface Protocol
	@within Namespace
	.hash number -- FNV-1a over the sorted qualified names
	.count number -- how many channels were numbered
	.names { string } -- sorted, so `names[id]` is the channel with that id

	What both peers must agree on before any packet is meaningful.
]=]
export type Protocol = {
	hash: number,
	count: number,
	names: { string },
}

local protocol: Protocol? = nil

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

	for id, qualified in names do
		byName[qualified].id = id
	end

	local computed: Protocol = table.freeze({
		hash = fnv1a(table.concat(names, "\n")),
		count = #names,
		names = table.freeze(names),
	}) :: any

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
	protocol = nil
	sealed = false
end

return Namespace
