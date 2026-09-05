--!strict
--!optimize 2

--[=[
	netweave adapter.

	Unlike the other four modes this one is not vendored — it is the working tree, mapped into the
	bench place by `bench/default.project.json`. There is no version to pin because there is no
	release yet; what is measured is whatever `src/` currently says.
]=]

--[[
	**M2 removed the stand-in.** M1 measured netweave behind a transport this file implemented,
	because batching, budgets, audience evaluation and coalescing were a milestone away and Blink,
	Zap and ByteNet all batch — so measuring netweave unbatched would have measured the absence of
	a milestone rather than a library. Every netweave number in the 2026-09-04 runs carries that
	asterisk.

	What is left here is an adapter and nothing else: the channels declared the way
	`docs/DESIGN-API.md` §4 says to declare them, and calls into the views. Requiring netweave
	installs the transport, so there is nothing to wire.

	The channels are `command`s with a real policy attached rather than bare ones, because
	`PLAN-M1` R-3 says the risk is that authorization costs more than the codec saves and a
	benchmark of an unauthorized channel would not answer that.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modes = require(script.Parent)
local Payloads = require(script.Parent.Parent.Payloads)

type Adapter = Modes.Adapter
type SchemaName = Modes.SchemaName
type Direction = Modes.Direction

local WAIT_TIMEOUT = 30

--[[
	`rate` is enforced from M2 on, so it has to be above what the harness offers or the run would
	measure the budget rather than the library. `Config.PACKETS_PER_FRAME` at a few hundred steps a
	second is far past anything a game would declare; this is the budget that load implies, written
	down rather than fudged.
]]
local BENCH_RATE = 1e6

return function(canonical): Adapter
	local package = ReplicatedStorage:WaitForChild("netweave", WAIT_TIMEOUT) :: Folder
	assert(package, "netweave is not in the bench place; check bench/default.project.json")

	local src = package:WaitForChild("src", WAIT_TIMEOUT) :: Folder
	local nw = require(src:WaitForChild("netweave")) :: any
	local t = nw.types

	local isServer = RunService:IsServer()

	--[[
		The expired-context guard is Studio-only and allocates two tables per packet, and the
		benchmark runs in Studio. Leaving it on charges netweave for a debug facility no competitor
		has and no live server pays, inside the one number — decode allocation per packet — where
		two tables are the whole measurement.
	]]
	nw.internal.context.setGuarded(false)

	--[[
		The rate below is a million packets a second, which is exactly what `rules.rateUnbounded`
		exists to warn about — and here it is correct: the harness offers hundreds of packets per
		step and a budget that bound them would make this a measurement of the budget. Turning the
		rule off beside the declaration it is about is the intended shape, and is why the rule is a
		lint rather than a refusal.
	]]
	--[[
		And the batch ceiling, for the same kind of reason and with the same shape.

		`pendingPerBatch` bounds how many decoded payloads one batch may hold live at once (D-6).
		The harness pushes two hundred packets per step into one batch on purpose — that is the
		load it exists to apply — so the default ceiling refuses the tail of every warm-up batch and
		the console fills with `budget` reports before the measured window opens. Raising it here
		measures the codec rather than the limit, which is what this file is for.

		Written beside `rateUnbounded` rather than in a config file, because both are the same
		admission: the harness is not a game, and each exception has to say why in the place a
		reader will be standing when they ask.
	]]
	nw.configure({
		rules = { rateUnbounded = "off" },
		limits = { pendingPerBatch = 4096 },
	})

	-- -----------------------------------------------------------------------------------------
	-- Schemas
	-- -----------------------------------------------------------------------------------------

	--[[
		`t.array(Entity, 100, 100)` — an exact length, so the count is not written at all and the
		schema is `static`: no length prefix, and the payload is claimed in one allocation.
		Declaring the bound is what buys that, which is the incentive the bound exists to create.
	]]
	local ArrayHeavy = t.array(
		t.struct({
			id = t.u8,
			x = t.u8,
			y = t.u8,
			z = t.u8,
			orientation = t.u8,
			animation = t.u8,
		}),
		Payloads.ENTITY_COUNT,
		Payloads.ENTITY_COUNT
	)

	--[[
		Twelve booleans, two enums and two optionals. netweave packs all of it — flags, enum tags
		and presence bits alike — into the fewest whole bytes automatically, so there is no
		idiomatic-versus-naive distinction to draw: the two columns use the same schema and must
		produce the same bytes.

		That is the D-3 claim stated as a measurement. Blink's spread between those two columns is
		self-inflicted by whether its author reached for `set`; Zap and netweave have no such
		choice to get wrong.
	]]
	local Flags = t.struct({
		f1 = t.boolean,
		f2 = t.boolean,
		f3 = t.boolean,
		f4 = t.boolean,
		f5 = t.boolean,
		f6 = t.boolean,
		f7 = t.boolean,
		f8 = t.boolean,
		f9 = t.boolean,
		f10 = t.boolean,
		f11 = t.boolean,
		f12 = t.boolean,
		weapon = t.enum({ primary = true, secondary = true, melee = true, grenade = true }),
		team = t.enum({ red = true, blue = true }),
		targetId = t.optional(t.u16),
		combo = t.optional(t.u8),
	})

	-- -----------------------------------------------------------------------------------------
	-- Declaration
	-- -----------------------------------------------------------------------------------------

	--[[
		A policy that always allows, so the measurement is the *cost* of running one rather than the
		cost of a particular check. It still pays for everything a real policy pays for: the context
		acquisition, the call, and the shared verdict.
	]]
	local accept = nw.policy(function()
		return function()
			return nw.allow()
		end
	end)

	--[[
		Written out one by one rather than built in a loop. A computed declaration table is `any`,
		and the whole point of the surface is that the views are typed — a benchmark that bypassed
		that would not be exercising what the milestones shipped.
	]]
	local bench = nw.namespace("bench", {
		ArrayHeavyUp = nw.command({ data = ArrayHeavy, rate = BENCH_RATE, authorize = accept }),
		FlagIdiomaticUp = nw.command({ data = Flags, rate = BENCH_RATE, authorize = accept }),
		FlagNaiveUp = nw.command({ data = Flags, rate = BENCH_RATE, authorize = accept }),

		--[[
			Two sets of server-to-client channels, because in netweave the audience is a *declaration*
			rather than a call-site choice (G3). The other libraries pick between `Fire(player, ...)`
			and `FireAll(...)` on the same event; the equivalent here is two channels, and declaring
			both is what makes the harness measure the two paths it means to.

			Collapsing them would have made the `Down` cell secretly a `FireAll` cell: an audience of
			everyone resolves to one broadcast whatever subject is handed to `publish`.
		]]
		ArrayHeavyOwn = nw.event({ data = ArrayHeavy, audience = nw.audience.owner }),
		FlagIdiomaticOwn = nw.event({ data = Flags, audience = nw.audience.owner }),
		FlagNaiveOwn = nw.event({ data = Flags, audience = nw.audience.owner }),

		ArrayHeavyDown = nw.event({ data = ArrayHeavy, audience = nw.audience.everyone }),
		FlagIdiomaticDown = nw.event({ data = Flags, audience = nw.audience.everyone }),
		FlagNaiveDown = nw.event({ data = Flags, audience = nw.audience.everyone }),
	})

	local protocol = nw.protocol()

	-- -----------------------------------------------------------------------------------------
	-- Payload shaping, once at load
	-- -----------------------------------------------------------------------------------------

	--[[ `Payloads` carries enum choices as 0-based integers because ByteNet has no enum type.
	     netweave's enum payload is a union of string singletons, so convert here rather than in the
	     measured loop (`PLAN-M0` R-3). ]]
	local function toNetweaveFlags(flags: Payloads.Flags): any
		local shaped = table.clone(flags) :: any
		shaped.weapon = Payloads.WEAPONS[flags.weapon + 1]
		shaped.team = Payloads.TEAMS[flags.team + 1]
		return shaped
	end

	local payloads = {
		ArrayHeavy = canonical.ArrayHeavy,
		FlagIdiomatic = toNetweaveFlags(canonical.FlagIdiomatic),
		FlagNaive = toNetweaveFlags(canonical.FlagNaive),
	}

	-- -----------------------------------------------------------------------------------------
	-- The adapter
	-- -----------------------------------------------------------------------------------------

	local server = bench.server :: any
	local client = bench.client :: any

	--[[ Indexed by a computed name, which the typed views cannot express — the harness asks for a
	     channel by string. The side is chosen by where this code runs, never by the direction: the
	     client half of an `Up` channel is the only half that can send, and the server half is the
	     only half that can listen. That is guarantee G6, and it is why there is no branch here. ]]
	local function named(name: string): any
		local handle = (if isServer then server else client)[name]
		assert(handle, `netweave has no channel "{name}"`)
		return handle
	end

	local function view(schema: SchemaName, direction: Direction): any
		return named(`{schema}{direction}`)
	end

	return {
		name = "netweave",
		--[[ Read from the library rather than typed, so a run document cannot misattribute its own
		     subject. It said `M2` through the whole of M3 (M3 phase 9). ]]
		version = `{nw.milestone} (protocol {protocol.hash})`,
		payloads = payloads,

		bindFire = function(schema, direction, player)
			if isServer then
				assert(player, "server-side netweave fire needs a recipient")

				--[[ The owner-audience twin, so one named recipient means one recipient. ]]
				local handle = named(`{schema}Own`)

				return function(payload)
					handle:publish(player, payload)
				end
			end

			local handle = view(schema, direction)

			return function(payload)
				handle:send(payload)
			end
		end,

		bindFireAll = if isServer
			then function(schema, direction)
				local handle = view(schema, direction)
				return function(payload)
					handle:broadcast(payload)
				end
			end
			else nil,

		onReceive = function(schema, direction, callback)
			if isServer then
				view(schema, direction):listen(function(ctx: any, payload: any)
					callback(payload, ctx.player)
				end)

				return
			end

			local function receive(payload: any)
				callback(payload, nil)
			end

			--[[ Both halves of the pair feed the harness's one counter for this cell, the way one
			     event with two send methods does for the other libraries. ]]
			view(schema, direction):listen(receive)
			named(`{schema}Own`):listen(receive)
		end,

		--[[ Nil, like every other adapter: the harness declares the hook but never calls it, and
		     netweave flushes on its own `PostSimulation` connection the way Blink and Zap flush on
		     `Heartbeat`. All three are measured under the same batching behaviour. ]]
		flush = nil,
	}
end
