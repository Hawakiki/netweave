--!strict

--[[
	The store seam, under lune.

		lune run tests/store_runtime

	`PLAN-M4` phase 5 asked for "a runtime test that replicates a real change through the real
	library", and that is not a test this repository can have. Charm and ReplicaService live in
	`_refsrc/`, which is read-only research material, gitignored, and which `CLAUDE.md` §2 forbids
	importing from — and there is no package path to depend on them properly either (`CLAUDE.md`
	§8). A test that required them would run on one machine and nowhere else, which is worse than
	not having it, because it would look like coverage.

	What is here instead is the same discipline `tests/harness.luau` uses for Instances under lune:
	**a stand-in that answers exactly what the code under test asks**, with the real library's file
	and line beside each one so the shape can be checked against the source rather than against
	memory. `Store.charm` calls a getter and a `subscribe` with Charm's own signature
	(`charm/packages/charm/src/init.luau:519, 821`); `Store.replica` reads `.Data`
	(`ReplicaService/src/ServerScriptService/ReplicaService.lua:403`). Those are the whole surfaces.

	The part that is a real test rather than a shape check is the last section: the seam driving an
	actual diff against actual baselines, which is what the adapters exist for.
]]

local Baseline = require("../src/replication/Baseline")
local Buffer = require("../src/codec/Buffer")
local Delta = require("../src/replication/Delta")
local Ir = require("../src/codec/Ir")
local Store = require("../src/replication/Store")
local harness = require("./harness")
local t = require("../src/types")

local suite = harness.suite("store_runtime", 0.25)
local check, equals = suite.check, suite.equals

local function sorted(list: { any }): { any }
	local out = table.clone(list)
	table.sort(out, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return out
end

-- ---------------------------------------------------------------------------------------------
-- A plain table
-- ---------------------------------------------------------------------------------------------

suite.passing()

do
	local world: { [any]: any } = { alpha = { hp = 10 }, beta = { hp = 4 } }
	local store = Store.of(world)

	equals("both subjects are listed", #store.subjects(), 2)
	equals("sorted, the first", sorted(store.subjects())[1], "alpha")
	equals("and its value comes back", store.read("alpha").hp, 10)

	--[[ Read live rather than copied. A subject appearing between ticks is the case a cached list
	     would miss, and it is the tick that matters most — nobody notices a stale *absence*. ]]
	world.gamma = { hp = 1 }
	equals("a subject that appeared is listed", #store.subjects(), 3)
	equals("and readable", store.read("gamma").hp, 1)
end

suite.failing()

do
	local world: { [any]: any } = { alpha = { hp = 10 }, beta = { hp = 4 } }
	local store = Store.of(world)

	equals("a subject that is not there reads nil", store.read("gamma"), nil)
	check("and a plain table offers no change signal", store.changed == nil)

	world.alpha = nil
	equals("one that went away is not listed", #store.subjects(), 1)
	equals("and reads nil rather than raising", store.read("alpha"), nil)

	world.beta = nil
	equals("an empty store lists nothing", #store.subjects(), 0)
	equals("and reads nothing", store.read("beta"), nil)
end

suite.passing()

-- ---------------------------------------------------------------------------------------------
-- Charm's shape: a getter and a subscribe
-- ---------------------------------------------------------------------------------------------

do
	--[[
		An atom, in the two lines of it netweave touches. Charm's own is a callable that returns the
		value with no arguments and sets it with one (`charm/packages/charm/src/init.luau:519`); its
		`subscribe(getter, callback)` returns a cleanup and calls back on change (`:821`). Nothing
		below depends on anything else Charm does, which is the claim this section exists to make
		checkable.
	]]
	local value: { [any]: any } = { [1] = { hp = 10 } }
	local listeners: { () -> () } = {}

	local function atom(): { [any]: any }
		return value
	end

	local function set(next_: { [any]: any })
		value = next_

		for _, listener in listeners do
			listener()
		end
	end

	local function subscribe(_getter: any, callback: (state: any, last: any) -> ()): () -> ()
		table.insert(listeners, function()
			callback(value, value)
		end)

		local index = #listeners

		return function()
			listeners[index] = function() end
		end
	end

	local store = Store.charm(atom, subscribe)

	equals("the atom's subjects are the store's", #store.subjects(), 1)
	equals("and its values", store.read(1).hp, 10)
	check("and Charm's signal is offered", store.changed ~= nil)

	local moved = 0
	local stop = (store.changed :: any)(function()
		moved += 1
	end)

	set({ [1] = { hp = 3 }, [2] = { hp = 9 } })

	equals("a change is announced once", moved, 1)
	equals("the new value is visible", store.read(1).hp, 3)
	equals("and so is the new subject", #store.subjects(), 2)

	--[[ netweave drops the two arguments Charm passes, and that is the whole difference between
	     this adapter and `charm-sync`: netweave diffs per client against what *that client* has,
	     not against what the server last held, so "the previous state" is the wrong question for it
	     to be answering. ]]
	stop()
	set({ [1] = { hp = 1 } })
	equals("and stops when told to", moved, 1)
	equals("while the value keeps moving", store.read(1).hp, 1)
end

do
	--[[ Charm without a `subscribe`, which is legal and costs a walk a tick. A game that has the
	     signal should pass it; one that does not is not locked out. ]]
	local value: { [any]: any } = { [1] = { hp = 2 } }
	local store = Store.charm(function()
		return value
	end)

	check("no signal is offered", store.changed == nil)
	equals("and the value still reads", store.read(1).hp, 2)
end

-- ---------------------------------------------------------------------------------------------
-- ReplicaService's shape: `.Data`, and no signal at all
-- ---------------------------------------------------------------------------------------------

do
	--[[
		A Replica in the one field netweave touches. `Replica.Data` is the table the game mutates
		through `SetValue` and friends (`ReplicaService.lua:403-541`), and **nothing observes it on
		the server** — each of those calls fires its own RemoteEvent per player at the moment it is
		made. So there is no change signal to adapt, and the absence is the design rather than a gap
		in this stand-in.
	]]
	local replicas: { [any]: { Data: any } } = {
		[1] = { Data = { hp = 10, gold = 5 } },
		[2] = { Data = { hp = 1, gold = 0 } },
	}

	local store = Store.replica(replicas)

	equals("both replicas are subjects", #store.subjects(), 2)
	equals("and Data is the value", store.read(1).hp, 10)
	check("with no change signal, because ReplicaService has none", store.changed == nil)

	--[[ The mutation ReplicaService would have sent as its own RemoteEvent, six times over. Under
	     netweave the tick sees the state *after* all of them, which is one batched patch instead of
	     six calls per player — the win is the polling rather than in spite of it. ]]
	replicas[1].Data.hp = 7
	replicas[1].Data.gold = 6
	equals("in-place mutation is visible", store.read(1).hp, 7)
	equals("all of it", store.read(1).gold, 6)

	replicas[3] = { Data = { hp = 3, gold = 3 } }
	equals("a replica created later is a subject", #store.subjects(), 3)
end

suite.failing()

do
	local replicas: { [any]: { Data: any } } = { [1] = { Data = { hp = 1 } }, [2] = { Data = { hp = 2 } } }
	local store = Store.replica(replicas)

	replicas[2] = nil
	equals("a destroyed replica is not a subject", #store.subjects(), 1)
	equals("reading it is nil rather than a raise", store.read(2), nil)
	equals("and one that never existed reads nil too", store.read(99), nil)

	replicas[1] = nil
	equals("an empty set lists nothing", #store.subjects(), 0)
end

suite.passing()

-- ---------------------------------------------------------------------------------------------
-- The seam driving what it is for
-- ---------------------------------------------------------------------------------------------

do
	--[[
		The adapters are shapes until something diffs through them. This is the tick phase 5 will
		hand to `Outbound`: for every subject the store lists, send whoever can see it a snapshot if
		they have no baseline and a patch if they do.

		Written against `Store.of` because the three adapters return the same interface — if this
		works for one it works for all three, and asserting it three times would be asserting that
		`Store` returns a table.
	]]
	--[[ One packet shape, as in `tests/baseline_runtime.luau`: a change against `nil` is what a
	     client with no baseline gets, and it costs what a whole encode would have. ]]
	local schema = t.struct({ hp = t.u8, gold = t.u16 })
	local delta = Delta.build(Ir.lower(schema))

	local world: { [any]: any } = { [1] = { hp = 10, gold = 5 }, [2] = { hp = 1, gold = 0 } }
	local store = Store.of(world)
	local baselines = Baseline.new()
	local channel = { qualified = "game.world" }
	local alice = { name = "alice" }

	local views: { [any]: any } = {}

	local function tick(): number
		local bytes = 0

		for _, subject in store.subjects() do
			local current = store.read(subject)
			local base = baselines.of(alice, channel, subject)

			Buffer.take()
			Buffer.load(nil)

			local sent = delta.write(base, current)
			local packed = Buffer.take()
			bytes += buffer.len(packed)

			if not sent then
				continue
			end

			Buffer.beginRead(packed, nil)
			views[subject] = delta.apply(views[subject])
			baselines.keep(alice, channel, subject, current)
		end

		--[[ A subject the store no longer lists stops being remembered, which is `drop` doing for a
		     destroyed replica what phase 4 made it do for an audience exit. ]]
		for _, subject in { 1, 2, 3 } do
			if store.read(subject) == nil then
				baselines.drop(alice, channel, subject)
				views[subject] = nil
			end
		end

		return bytes
	end

	local first = tick()
	equals("both subjects arrived", views[1].hp, 10)
	equals("both of them", views[2].gold, 0)

	--[[ One field of one subject. ]]
	world[1] = { hp = 7, gold = 5 }
	local second = tick()

	equals("the change arrived", views[1].hp, 7)
	equals("without disturbing its neighbour", views[2].hp, 1)
	check("and cost less than the first tick", second < first)

	suite.failing()
	local third = tick()
	equals("an unchanged tick sends nothing", third, 0)
	suite.passing()

	--[[ A subject appearing is a client with no baseline for it, which is the snapshot path — the
	     same one a join and a desync take. ]]
	world[3] = { hp = 2, gold = 99 }
	tick()
	equals("a new subject arrives whole", views[3].gold, 99)

	suite.failing()

	world[2] = nil
	tick()
	equals("and one that went away is forgotten", baselines.of(alice, channel, 2), nil)
	equals("with its view gone too", views[2], nil)
	equals("while the rest are untouched", views[1].hp, 7)
	equals("and it holds one fewer baseline", baselines.held(alice), 2)

	Buffer.take()
	Buffer.load(nil)
end

suite.finish()

return true
