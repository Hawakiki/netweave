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

	~~What that leaves is two functions, and one of them is optional: `subjects` and `read`, plus a
	`changed` for the store that can say when something moved. A seam that required `changed` would
	have supported one of the two libraries it was designed for.~~

	**Two functions, and neither is optional.** `changed` is gone as of M4 phase 8, and it went on a
	measurement rather than an opinion.

	It was declared here, documented as an optimisation, and checked at declaration by
	`nw.replicate` — for four phases, without one line ever reading it. `Store.charm`'s caution
	promised that passing Charm's `subscribe` made a tick where nothing moved cost one branch; the
	tick walked every subject regardless, so a game that passed it got exactly the walk it was told
	it had avoided. Both ways out were open, so the tick was built both ways and timed
	(`bench/tick.luau`, fifty players and five hundred subjects, nothing moving):

	  | idle tick | ms |
	  |---|---|
	  | before the phase 8 gate | 36.26 |
	  | comparing each subject against the snapshot its settled clients hold | 1.63 |
	  | trusting a perfect change signal instead of comparing | 1.40 |

	0.23 ms, and only while **nothing at all** is moving. A whole-store signal is set by any subject
	moving, so in a world where anything happens it reads dirty every tick and buys nothing — and a
	tick's cost only matters in a world where something happens.

	Against that: a signal that misses a mutation is a subject that stops replicating, silently and
	for ever, on every client. A game keeping a plain table inside a Charm atom and writing to it in
	place would do exactly that, and neither side would report it. `CLAUDE.md` §9's rule is that a
	claim which cannot be probed is a claim to drop — and there is no probe for "the store told the
	truth", because when it does not, the freeze is the behaviour.

	So the seam is `subjects` and `read`, which every store can answer, and netweave does the
	comparing. Charm's immutable atoms still make it cheap, for the reason they always did: a
	subject whose table was replaced fails the comparison on the first key.
]]

local Store = {}

--[=[
	@interface Store
	@within Store
	.subjects () -> { any } -- every subject that exists right now
	.read (subject: any) -> any -- the current value, or nil if it is gone

	`subjects` is called once a tick and its result is not retained, so a store may return the same
	table every time.

	:::note
	There is no change signal, and the note above says why one was removed rather than added.
	netweave compares each subject once a tick against the snapshot its up-to-date clients hold, so
	a store only has to say what it has — never when it moved.
	:::
]=]
export type Store = {
	subjects: () -> { any },
	read: (subject: any) -> any,
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
	@return Store

	Charm, adapted at the **atom** rather than at `charm-sync`.

	```lua
	local world = Charm.atom({})
	local store = Store.charm(world)
	```

	netweave never requires Charm — there is no package path for it (`CLAUDE.md` §8) and it should
	not need one. The whole adapter is one call of the getter, so it is a shape rather than a
	dependency, and anything that returns a subject-to-value table works without being Charm at all.

	:::note
	~~Pass `Charm.subscribe` if you have it: without it netweave diffs every subject every tick, and
	with it a tick where nothing moved costs one branch.~~ **There is no second parameter.** The
	signal was never read, and when it was finally measured it was worth 0.23 ms of an idle tick
	against a silent freeze if it ever missed one — see the note at the top of this file.

	Charm still gets the cheap path, from the property that makes it Charm: an atom's tables are
	replaced rather than written to, so a subject that moved differs on its first key.
	:::
]=]
function Store.charm(getter: () -> { [any]: any }): Store
	local function subjects(): { any }
		local out = {}

		for subject in getter() do
			table.insert(out, subject)
		end

		return out
	end

	return {
		subjects = subjects,

		read = function(subject: any): any
			return getter()[subject]
		end,
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
