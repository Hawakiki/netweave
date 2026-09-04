--!strict
--!optimize 2

--[=[
	netweave M1 adapter.

	Unlike the other four modes this one is not vendored — it is the working tree, mapped into the
	bench place by `bench/default.project.json`. There is no version to pin because there is no
	release yet; what is measured is whatever `src/` currently says.
]=]

--[[
	The transport at the bottom of this file is the harness's stand-in for M2, not netweave.

	M1 ships the declaration surface and the codec; batching, flush scheduling, budget enforcement,
	audience evaluation and intent coalescing are M2 (`PLAN-M1` §4). But Blink, Zap and ByteNet all
	batch a frame's worth of sends into one remote call, so a netweave measured *without* batching
	would not be measuring the same thing — it would be measuring the absence of a milestone.

	So this file installs a driver through `nw.internal.transport`, which is exactly the seam M2
	attaches to, and implements the smallest thing that satisfies `docs/WIRE-FORMAT.md`: a version
	byte, varint channel ids, and a length prefix on channels whose size varies. Nothing else. What
	it deliberately does not do is written down at the point it matters, so a number produced here is
	not mistaken for a number M2 will reproduce.

	The channels are declared the way `docs/DESIGN-API.md` §4 says to declare them — `command` with
	a real policy attached, not a bare channel — because `PLAN-M1` R-3 says the risk is that
	authorization costs more than the codec saves, and a benchmark of an unauthorized channel would
	not answer that.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modes = require(script.Parent)
local Payloads = require(script.Parent.Parent.Payloads)

type Adapter = Modes.Adapter
type SchemaName = Modes.SchemaName
type Direction = Modes.Direction

local WAIT_TIMEOUT = 30
local FOLDER_NAME = "NETWEAVE"
local RELIABLE_NAME = "NETWEAVE_RELIABLE"

--[[
	Wire format v1 (`docs/WIRE-FORMAT.md` §1): one version byte per batch, not per packet.
]]
local WIRE_VERSION = 1

--[[
	A `counted` packet reserves one byte for its length before the payload is written, and the
	length is only known afterwards. One byte holds 127 in a varint, so a larger payload would need
	the reserved byte widened and everything after it shifted.

	`Buffer` exposes no shift, and adding one is M2's decision rather than the benchmark's. Every
	`counted` schema here encodes to six bytes, so the limit is never approached; a schema that
	crossed it fails loudly instead of writing a corrupt length.
]]
local MAX_COUNTED = 127

--[[
	`rate` is declarative in M1 — nothing enforces it until M2 owns the frame loop — but it is not
	optional, so it has to be a number that means something. The benchmark fires
	`Config.PACKETS_PER_FRAME` per step at a few hundred steps a second, which is far past anything
	a game would declare; this is the budget that load implies, written down rather than fudged.
]]
local BENCH_RATE = 60000

return function(canonical): Adapter
	local vendor = Modes.vendor()
	local package = vendor:WaitForChild("netweave", WAIT_TIMEOUT) :: Folder
	assert(package, "netweave is not in the bench place; check bench/default.project.json")

	local nw = require(package:WaitForChild("netweave")) :: any
	local Buffer = require(package:WaitForChild("codec"):WaitForChild("Buffer")) :: any
	local t = nw.types

	local isServer = RunService:IsServer()

	-- -----------------------------------------------------------------------------------------
	-- Schemas
	-- -----------------------------------------------------------------------------------------

	--[[
		`t.array(Entity, 100, 100)` — an exact length, so the count is not written at all and the
		schema is `static`: no length prefix, and the top level allocates once. Declaring the bound
		is what buys that, which is the incentive the bound exists to create.
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
		A policy that always allows, so the measurement is the *cost* of running one rather than
		the cost of a particular check. It still pays for everything a real policy pays for: the
		context acquisition, the call, and the shared verdict.
	]]
	local accept = nw.policy(function()
		return function()
			return nw.allow()
		end
	end)

	--[[
		Written out six times rather than built in a loop. A computed declaration table is `any`,
		and the whole point of the surface is that the views are typed — a benchmark that bypassed
		that would not be exercising what M1 shipped.
	]]
	local bench = nw.namespace("bench", {
		ArrayHeavyUp = nw.command({ data = ArrayHeavy, rate = BENCH_RATE, authorize = accept }),
		FlagIdiomaticUp = nw.command({ data = Flags, rate = BENCH_RATE, authorize = accept }),
		FlagNaiveUp = nw.command({ data = Flags, rate = BENCH_RATE, authorize = accept }),

		ArrayHeavyDown = nw.event({ data = ArrayHeavy, audience = nw.audience.everyone }),
		FlagIdiomaticDown = nw.event({ data = Flags, audience = nw.audience.everyone }),
		FlagNaiveDown = nw.event({ data = Flags, audience = nw.audience.everyone }),
	})

	--[[ Both peers number the channels from the same sorted names, so this only has to be read. ]]
	local protocol = nw.protocol()
	local byId: { [number]: any } = {}

	for _, channel in bench.channels :: any do
		byId[channel.id] = channel
	end

	-- -----------------------------------------------------------------------------------------
	-- Payload shaping, once at load
	-- -----------------------------------------------------------------------------------------

	--[[ `Payloads` carries enum choices as 0-based integers because ByteNet has no enum type.
	     netweave's enum payload is a union of string singletons, so convert here rather than in
	     the measured loop (`PLAN-M0` R-3). ]]
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
	-- The stand-in transport
	-- -----------------------------------------------------------------------------------------

	local folder: Folder
	local reliable: RemoteEvent

	if isServer then
		local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)

		if existing then
			folder = existing :: Folder
		else
			folder = Instance.new("Folder")
			folder.Name = FOLDER_NAME
			folder.Parent = ReplicatedStorage
		end

		local remote = folder:FindFirstChild(RELIABLE_NAME)

		if remote then
			reliable = remote :: RemoteEvent
		else
			local created = Instance.new("RemoteEvent")
			created.Name = RELIABLE_NAME
			created.Parent = folder
			reliable = created
		end
	else
		folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, WAIT_TIMEOUT) :: Folder
		assert(folder, "netweave remotes never replicated to the client")
		reliable = folder:WaitForChild(RELIABLE_NAME, WAIT_TIMEOUT) :: RemoteEvent
		assert(reliable, "netweave reliable remote never replicated")
	end

	--[[
		One parked buffer per destination — the client has exactly one, the server one per
		recipient. This is what `Buffer.save`/`load` were built for (`PLAN-M1` D-4): the outgoing
		buffer is global and swapping is how per-player multiplexing works, so a second buffer
		implementation here would be measuring something netweave does not do.

		Broadcast is keyed under `false` rather than serialised once and copied per player. M2
		should do the copy — `RESEARCH §3.7-E` — and until it does, the fan-out cost measured here
		is a per-recipient encode, which is worse than what M2 will produce, not better.
	]]
	local parked: { [any]: any } = {}

	local function batchFor(destination: any): any
		local existing = parked[destination]

		if existing then
			return existing
		end

		local previous = Buffer.save()
		Buffer.load(nil)
		local fresh = Buffer.save()
		Buffer.load(previous)

		parked[destination] = fresh
		return fresh
	end

	local function write(destination: any, channel: any, value: any)
		local previous = Buffer.save()
		Buffer.load(batchFor(destination))

		if Buffer.used() == 0 then
			Buffer.writeU8(WIRE_VERSION)
		end

		Buffer.writeVarint(channel.id)

		if channel.codec.framing == "counted" then
			local at = Buffer.reserve(1)
			local start = Buffer.used()

			channel.codec.write(value)

			local length = Buffer.used() - start
			assert(length <= MAX_COUNTED, `netweave bench: {channel.qualified} encoded {length} bytes`)
			Buffer.patchU8(at, length)
		else
			channel.codec.write(value)
		end

		parked[destination] = Buffer.save()
		Buffer.load(previous)
	end

	local function flush()
		local previous = Buffer.save()

		for destination, save in parked do
			Buffer.load(save)

			if Buffer.used() > 0 then
				local packed, instances = Buffer.take()

				if isServer then
					if destination == false then
						reliable:FireAllClients(packed, instances)
					else
						reliable:FireClient(destination :: Player, packed, instances)
					end
				else
					reliable:FireServer(packed, instances)
				end

				--[[ `take` resets to a fresh buffer, so this is the empty one, not the sent one. ]]
				parked[destination] = Buffer.save()
			end
		end

		Buffer.load(previous)
	end

	--[[
		Reading a batch.

		Every failure here is a value, never a raise: `docs/DESIGN-API.md` G4 and G5 say one
		malformed packet must not stop the rest of its batch, and the length prefix is what makes
		resynchronising possible. A rejected packet skips to its own end and the loop continues; a
		`static` packet cannot be skipped, so the batch stops there, which is the honest limit of
		what framing can recover.
	]]
	local function receive(packed: buffer, instances: { Instance }?, player: Player?)
		local size = buffer.len(packed)

		if size == 0 then
			return
		end

		Buffer.beginRead(packed, instances)

		local version = Buffer.readU8()

		if Buffer.rejected() or version ~= WIRE_VERSION then
			return
		end

		while Buffer.cursor() < size do
			Buffer.setLimit(size)

			local id = Buffer.readVarint()
			local channel = byId[id]

			if Buffer.rejected() or not channel then
				return
			end

			local finish = size

			if channel.codec.framing == "counted" then
				local length = Buffer.readVarint()

				if Buffer.rejected() then
					return
				end

				finish = Buffer.cursor() + length

				if finish > size then
					return
				end

				Buffer.setLimit(finish)
			end

			local value, failure = channel.codec.read()
			local recoverable = channel.codec.framing == "counted"

			if recoverable then
				--[[
					Skip to this packet's end and clear the rejection. Both halves matter: a rejection
					is sticky, so without the clear the next packet's id read reports the previous
					packet's failure and the whole batch stops — which is precisely the G5 failure the
					length prefix is paid for. Caught by `bench/envelope.luau` before Studio saw it.
				]]
				Buffer.seek(finish)
				Buffer.setLimit(size)
				Buffer.clearRejection()
			end

			if failure and not recoverable then
				--[[ A `static` packet has no length to resynchronise on, and the cursor is wherever
				     the failed read stopped. This is the honest limit of what framing recovers. ]]
				nw.internal.observer.emit(channel.qualified, player, "parse", failure, size)
				return
			end

			if failure then
				nw.internal.observer.emit(channel.qualified, player, "parse", failure, size)
			elseif channel.handler then
				--[[
					`command` is authorized per packet, which is the R-3 measurement: the harness
					sees the policy call, the context acquisition and the handler together, because
					that is what a game pays.
				]]
				if channel.authorize then
					local ctx = nw.internal.context.acquire(player, channel.qualified)
					local verdict = channel.authorize(ctx, value)

					if verdict.ok then
						channel.handler(ctx, if verdict.value ~= nil then verdict.value else value)
					else
						nw.internal.observer.emit(
							channel.qualified,
							player,
							"authorize",
							verdict.reason or "denied",
							size
						)
					end

					nw.internal.context.release(player)
				else
					channel.handler(value)
				end
			end
		end
	end

	--[[
		One flush per frame, on the same event the harness fires from. Blink and Zap batch into one
		buffer and flush on `Heartbeat` unless told otherwise, so measuring netweave without this
		would be comparing a batched library against an unbatched one.

		This connection is made at load, before the harness makes its own, so a frame's sends land in
		the *next* frame's flush. Blink and Zap have the same one-frame property for the same reason;
		it costs latency, not bytes, and the benchmark measures bytes and framerate.
	]]
	RunService.PostSimulation:Connect(flush)

	if isServer then
		reliable.OnServerEvent:Connect(function(player, packed, instances)
			receive(packed :: buffer, instances :: { Instance }, player)
		end)
	else
		reliable.OnClientEvent:Connect(function(packed, instances)
			receive(packed :: buffer, instances :: { Instance }, nil)
		end)
	end

	nw.internal.transport.install({
		send = function(channel: any, value: any)
			write("server", channel, value)
		end,

		publish = function(channel: any, subject: any, value: any)
			write(subject, channel, value)
		end,

		broadcast = function(channel: any, value: any)
			write(false, channel, value)
		end,

		invoke = function(): (any?, string?)
			return nil, "netweave queries are not part of the M1 benchmark"
		end,

		dispatch = function() end,
	})

	-- -----------------------------------------------------------------------------------------
	-- The adapter
	-- -----------------------------------------------------------------------------------------

	local server = bench.server :: any
	local client = bench.client :: any

	--[[ Indexed by a computed name, which the typed views cannot express — the harness asks for a
	     channel by string. The side is chosen by where this code runs, never by the direction: the
	     client half of an `Up` channel is the only half that can send, and the server half is the
	     only half that can listen. That is guarantee G6, and it is why there is no branch here. ]]
	local function view(schema: SchemaName, direction: Direction): any
		local name = `{schema}{direction}`
		local handle = (if isServer then server else client)[name]
		assert(handle, `netweave has no channel "{name}"`)
		return handle
	end

	return {
		name = "netweave",
		version = `M1 (protocol {protocol.hash})`,
		payloads = payloads,

		bindFire = function(schema, direction, player)
			local handle = view(schema, direction)

			if isServer then
				assert(player, "server-side netweave fire needs a recipient")
				return function(payload)
					handle:publish(player, payload)
				end
			end

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
			local handle = view(schema, direction)

			if isServer then
				handle:listen(function(ctx: any, payload: any)
					callback(payload, ctx.player)
				end)
			else
				handle:listen(function(payload: any)
					callback(payload, nil)
				end)
			end
		end,

		--[[ Nil, like every other adapter: the harness declares the hook but never calls it, and
		     Blink and Zap both flush on their own `Heartbeat` connection. netweave does the same,
		     above, so all three are measured under the same batching behaviour. ]]
		flush = nil,
	}
end
