--!strict
--!optimize 2

--[=[
	@class Store

	Where the game keeps the state netweave replicates.

	netweave does not own the truth and does not want to. A game already has Charm, or Replica, or a
	table it wrote itself, and a library that demands those be torn out to get delta compression
	will not be adopted (`RESEARCH §4`). This is the narrowest thing netweave needs from whichever
	one it is.

	Internal. `nw.replicate` takes one.
]=]

--[[
	`PLAN-M4` D-3, refined by building phases 3 and 4.

	Phase 1 read both neighbours and concluded "netweave is the transport a replication library
	plugs into", because Charm Sync already diffs and wants a `connect(onSync)` callback. That was
	one step too far, and the step is worth naming: **netweave adapts the store, not the store's
	replication layer.**

	`charm-sync` is Charm's own answer to the same problem, and carrying its `SyncPayload` would
	mean moving an arbitrarily shaped patch table through a schema-driven codec — which is to say,
	as an opaque blob, which is exactly what phase 1 warned throws the byte case away. `charm`
	underneath it is an `atom` and a `subscribe`, which is a value and a signal, and that is all the
	baseline in `Baseline.luau` and the diff in `Delta.luau` need. So netweave **replaces**
	`charm-sync` rather than riding it, and the same is true of ReplicaService's six RemoteEvents.

	What that leaves is two functions, and one of them is optional:

	  * `subjects` and `read`, because a diff needs the current value;
	  * `changed`, because Charm can say when something moved (`charm/packages/charm/src/init.luau:821`)
	    and ReplicaService cannot — the game calls `SetValue` and nothing observes it server-side
	    (`ReplicaService/src/ServerScriptService/ReplicaService.lua:403`). A store that cannot say is
	    polled once a tick, which is what the transport does anyway.

	A seam that required `changed` would have supported one of the two libraries it was designed for.
]]

local Store = {}

--[=[
	@interface Store
	@within Store
	.subjects () -> { any } -- every subject that exists right now
	.read (subject: any) -> any -- the current value, or nil if it is gone
	.changed ((callback: () -> ()) -> () -> ())? -- optional; returns a function that stops listening

	`subjects` is called once a tick and its result is not retained, so a store may return the same
	table every time.
]=]
export type Store = {
	subjects: () -> { any },
	read: (subject: any) -> any,
	changed: ((callback: () -> ()) -> () -> ())?,
}

--[=[
	@within Store
	@function of
	@param source { [any]: any } -- subject to value
	@return Store

	A plain table. The store for a game that has no state library, and the one every test uses.

	```lua
	local world = { [1] = { hp = 10 }, [2] = { hp = 4 } }
	local store = Store.of(world)
	```

	:::note
	The table is read live rather than copied, so mutating a value in place is visible to the next
	tick. That is deliberate — `Delta` compares by reference first, so a game that replaces a
	subject's table pays a pointer comparison and one that mutates in place pays the walk.
	:::
]=]
function Store.of(source: { [any]: any }): Store
	--[[ Rebuilt per call rather than cached, because a cached list would go stale exactly when a
	     subject appeared — which is the tick that matters most. It is one table a tick against a
	     diff of every subject in it. ]]
	local function subjects(): { any }
		local out = {}

		for subject in source do
			table.insert(out, subject)
		end

		return out
	end

	return {
		subjects = subjects,

		read = function(subject: any): any
			return source[subject]
		end,
	}
end

--[=[
	@within Store
	@function charm
	@param getter () -> { [any]: any } -- an atom, or any Charm getter, holding subject to value
	@param subscribe ((getter: any, callback: (state: any, last: any) -> ()) -> () -> ())? -- Charm's own
	@return Store

	Charm, adapted at the **atom** rather than at `charm-sync`.

	```lua
	local world = Charm.atom({})
	local store = Store.charm(world, Charm.subscribe)
	```

	netweave never requires Charm — there is no package path for it (`CLAUDE.md` §8) and it should
	not need one. The game passes its own `subscribe`, so the adapter is a shape rather than a
	dependency, and a store that happens to have the same shape works without being Charm at all.

	:::caution
	Pass `subscribe` if you have it. Without it netweave diffs every subject every tick; with it,
	a tick where nothing moved costs one branch. Charm's `subscribe` is at
	`charm/packages/charm/src/init.luau:821`.
	:::
]=]
function Store.charm(getter: () -> { [any]: any }, subscribe: any?): Store
	local function subjects(): { any }
		local out = {}

		for subject in getter() do
			table.insert(out, subject)
		end

		return out
	end

	local changed: ((callback: () -> ()) -> () -> ())? = nil

	if subscribe then
		changed = function(callback: () -> ()): () -> ()
			--[[ Charm hands the callback the new and previous states; netweave wants neither,
			     because it diffs per client against what that client has rather than against what
			     the server last held. Dropping both arguments here is the whole difference between
			     this and `charm-sync`. ]]
			return (subscribe :: any)(getter, function()
				callback()
			end)
		end
	end

	return {
		subjects = subjects,

		read = function(subject: any): any
			return getter()[subject]
		end,

		changed = changed,
	}
end

--[=[
	@within Store
	@function replica
	@param replicas { [any]: { Data: any } } -- subject to Replica
	@return Store

	ReplicaService, adapted at `Replica.Data`.

	```lua
	local store = Store.replica(byPlayer)
	```

	There is no change signal, and that is ReplicaService's design rather than an omission: the
	game names the mutation — `SetValue`, `ArrayInsert`, `Write` — and each fires its own
	RemoteEvent per player at the moment it is called
	(`ReplicaService/src/ServerScriptService/ReplicaService.lua:403-541`). Nothing observes `Data`
	on the server, so netweave reads it once a tick.

	:::note
	That polling is also the win. Six mutations to one replica in one frame are six RemoteEvent
	calls per player under ReplicaService and one batched patch under netweave, because the tick
	sees the state after all six rather than each of them in turn.
	:::
]=]
function Store.replica(replicas: { [any]: { Data: any } }): Store
	local function subjects(): { any }
		local out = {}

		for subject in replicas do
			table.insert(out, subject)
		end

		return out
	end

	return {
		subjects = subjects,

		read = function(subject: any): any
			local replica = replicas[subject]
			return if replica then replica.Data else nil
		end,
	}
end

return Store
