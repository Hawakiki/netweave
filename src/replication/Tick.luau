--!strict
--!optimize 2

--[=[
	@class Tick

	Once a frame: what each client should see, against what it already has.

	Everything else in `src/replication/` is a piece — the diff, the baselines, the seam. This is
	the loop that uses them, and it is the only place that knows a replicated channel is *driven*
	rather than called.

	Internal. `Driver` runs it between the intent dispatch and the flush, so a change rides the same
	batch as everything else the frame produced.
]=]

--[[
	Subject-major, and the alternative is written down rather than left to be rediscovered.

	Each recipient's change is computed against *that recipient's* baseline, so there is nothing to
	serialise once and copy — which is the trick `Outbound.publish` uses and the reason it does not
	apply here. What is left is a `switchTo` per recipient per subject, where a recipient-major loop
	would switch once per recipient and pay a table of recipients per subject instead.

	~~Which is cheaper depends on the ratio of subjects to players and on what `switchTo` costs, and
	the benchmark cannot see either yet.~~ **`bench/tick.luau` sees it now**, and it narrows the
	question rather than answering it: since phase 8 a pair with nothing to send does not reach
	`switchTo` at all, so the trade only exists for the subjects that moved. Fifty players and five
	hundred subjects with everything moving is 33.99 ms a tick and every bit of that is pairs with
	something to write — which a recipient-major loop would still have to write, one buffer switch
	cheaper each. That is the version worth building if this ever needs building; a world at rest
	costs 1.63 ms and has nothing left to win.
]]

local Baseline = require("./Baseline")
local Ir = require("../codec/Ir")
local Observer = require("../api/Observer")
local Outbound = require("../transport/Outbound")
local Recipients = require("../transport/Recipients")

local Tick = {}

type Slot = {
	--[[ Which subjects the store listed last time. A subject that was there and is not any more has
	     to be taken off every client that has it, and nothing else would notice — it is absent from
	     the store, so the loop below never reaches it. ]]
	held: { [any]: boolean },
	scratch: { [any]: boolean },

	--[[ The snapshot most recently handed out for each subject, kept across ticks rather than
	     rebuilt per tick. It is the same table every up-to-date recipient's baseline points at,
	     which is what makes the gate below a pointer comparison. Cleared with `held`, so it holds
	     nothing the store has stopped listing. ]]
	kept: { [any]: any },

	--[[ Subjects whose last change could not be written to anyone, keyed to the snapshot that
	     failed, so they are not attempted again until the value moves. ]]
	stuck: { [any]: any },

	--[[ The schema's shape, from the channel's layout: which keys `snapshot` and `moved` read. ]]
	shape: any,
}

--[=[
	@interface Config
	@within Tick
	.outbound Outbound
	.baselines Baseline
	.roster Roster
	.channels () -> { any } -- the replicated channels, read late because ids are assigned late
]=]
--[[
	The three collaborators were `any`, so a renamed method or a wrong argument order was not a
	diagnostic and `lune run analyze` was clean because there was nothing to check (M4 report
	finding 46). `channels` stays `{ any }`: a channel record is `any` across the whole transport
	boundary and typing it here alone would be a fence with one post.
]]
export type Config = {
	outbound: Outbound.Outbound,
	baselines: Baseline.Baseline,
	roster: Recipients.Roster,
	channels: () -> { any },
}

--[=[
	@within Tick
	@function new
	@param config Config
	@return () -> ()

	The loop, bound to its collaborators once.
]=]
function Tick.new(config: Config): () -> ()
	local outbound = config.outbound
	local baselines = config.baselines
	local roster = config.roster
	local channels = config.channels

	--[[
		The schema's shape, read once per channel from its lowered layout: what the differ reads and
		nothing else.

		`snapshot` and `moved` below used to walk the game's whole table, which made the phase 8
		gate schema-unaware. A key the schema never reads but which changes every frame — `lastSeen =
		os.clock()`, a `Character` reference — made every subject "moved", and the per-pair attempt
		the gate removed was back: 31.02 ms a tick at 50 × 500 with nothing the schema reads moving,
		against 1.65 ms idle (`bench/tick`, `extra key`). A subtree the schema never reads — the
		inventory a `Replica.Data` carries that this channel does not replicate — was cloned into
		every baseline and walked every tick. And a cycle through such a key overflowed the stack, a
		fourth way for a game's own data to abort the frame's flush (M4-1). A walk over the shape is
		finite by construction, so that one closes with the same change.

		`false` marks a leaf — a scalar, a datatype, a buffer — so a field lookup can tell "not in
		the schema" (nil) from "in the schema and carried by value" (false).
	]]
	type Shape = {
		fields: { [string]: any }?,
		element: any,
		count: number?,
		value: any,
		branches: { [string]: any }?,
	}

	local function shapeOf(node: Ir.Node): any
		local kind = node.kind

		if kind == "struct" then
			local fields: { [string]: any } = {}

			for _, field in node.fields :: { Ir.Field } do
				fields[field.name] = shapeOf(field.node)
			end

			return { fields = fields }
		elseif kind == "array" then
			local elements = node.elements
			local element = if elements then elements[1] else node.element :: Ir.Node

			return { element = shapeOf(element), count = node.count }
		elseif kind == "map" then
			return { value = shapeOf(node.value :: Ir.Node) }
		elseif kind == "optional" then
			return shapeOf(node.inner :: Ir.Node)
		elseif kind == "union" then
			local branches: { [string]: any } = {}

			for _, branch in node.branches :: { Ir.Field } do
				branches[branch.name] = shapeOf(branch.node)
			end

			return { branches = branches }
		end

		return false
	end

	local slots: { [any]: Slot } = {}

	--[[ Reused across ticks and channels. `Recipients.of` fills a caller-owned array for exactly
	     this reason: a `state` channel resolves an audience per subject per tick, and returning a
	     table there would allocate once per subject per frame for the life of the server. ]]
	local recipients: { any } = {}

	--[[ Which players this subject reaches, as a set, so the removal pass below asks one lookup per
	     player instead of scanning the audience. `among` used to scan: O(players) per player per
	     subject, which at 50 × 500 with a `select` returning the roster was 14.32 ms a tick to
	     conclude nothing (`bench/tick`, `select-all`). One table, cleared per subject. ]]
	local marked: { [any]: boolean } = {}

	local function slotOf(channel: any): Slot
		local slot = slots[channel]

		if not slot then
			slot = {
				held = {},
				scratch = {},
				kept = {},
				stuck = {},
				shape = shapeOf(channel.codec.layout.root),
			}
			slots[channel] = slot
		end

		return slot
	end

	--[[
		A baseline must not be the store's own table.

		Found by the first end-to-end run. `Replica.Data.hp = 4` mutates in place — that is what
		ReplicaService's whole API does (`ReplicaService.lua:403`) — so a baseline holding a
		reference to it *becomes* the new value the moment the game writes, and the next diff
		compares a table against itself and finds nothing. The subject would freeze at whatever it
		was when it was first sent, silently, on every client.

		Charm does not have the problem because its atoms are immutable, which is exactly why a seam
		that only worked for Charm would have been the wrong seam (D-3).

		Copied once per subject per tick rather than once per recipient: every client that was sent
		something this tick was sent the *same* value, so they can share the snapshot. A buffer field
		is carried by reference and a game that mutates one in place would defeat this — noted rather
		than solved, because `t.buffer` is for opaque payloads a game hands over rather than edits.

		Only the schema's keys are copied (see `shapeOf`). A table where the schema says leaf is a
		game bug the differ will refuse; it is carried by reference here rather than walked.
	]]
	local function snapshot(value: any, shape: any): any
		if type(value) ~= "table" or not shape then
			return value
		end

		local out = {}
		local fields = shape.fields

		if fields then
			for name, inner in fields do
				local field = value[name]
				out[name] = if inner and type(field) == "table" then snapshot(field, inner) else field
			end

			return out
		end

		local element = shape.element

		if element ~= nil then
			for index = 1, shape.count or #value do
				local item = value[index]
				out[index] = if element and type(item) == "table" then snapshot(item, element) else item
			end

			return out
		end

		local inner = shape.value

		if inner ~= nil then
			for key, item in value do
				out[key] = if inner and type(item) == "table" then snapshot(item, inner) else item
			end

			return out
		end

		local branches = shape.branches

		if branches then
			local tag = value.tag
			local chosen = branches[tag]
			local carried = value.value

			out.tag = tag
			out.value = if chosen and type(carried) == "table" then snapshot(carried, chosen) else carried
		end

		return out
	end

	--[[
		`snapshot`'s inverse, and the reason the snapshot is worth taking at all.

		Every recipient that is up to date holds *the same table* — the one `send` below returned and
		the slot kept — so one comparison against the current value answers for all of them. That is
		the whole of the phase 8 fix: the differ used to run once per (subject, recipient) pair and
		now runs once per pair that could possibly have something to write.

		It has to be **at least as strict as the differ**, never less. Anything it calls unmoved is a
		packet that will not be sent, so an equality looser than the schema's would be a silent
		freeze. Structural over the schema's keys is the safe side: two values the differ would
		encode identically — a number that snaps to the same f32 — are called *moved* here, which
		costs an attempt that writes nothing. The reverse cannot happen: if every key the schema
		reads compares equal then every field the differ reads compares equal, because they are the
		same keys.

		The one value it inherits a hole on is `buffer`, which `snapshot` carries by reference (see
		above) — so a game that mutates one in place defeats this exactly as far as it already
		defeated the baseline, and no further.
	]]
	local function moved(current: any, last: any, shape: any): boolean
		if current == last then
			return false
		end

		if type(current) ~= "table" or type(last) ~= "table" or not shape then
			return true
		end

		local fields = shape.fields

		if fields then
			for name, inner in fields do
				local now, was = current[name], last[name]

				if
					now ~= was
					and (not inner or type(now) ~= "table" or type(was) ~= "table" or moved(now, was, inner))
				then
					return true
				end
			end

			return false
		end

		local element = shape.element

		if element ~= nil then
			--[[ An exact length is walked by position, because an exact array of optionals may have
			     holes and `#` over one is not a length. A dynamic array cannot hold optionals, so
			     there `#` is the length on both sides. ]]
			local count = shape.count

			if not count then
				count = #current

				if count ~= #last then
					return true
				end
			end

			for index = 1, count do
				local now, was = current[index], last[index]

				if
					now ~= was
					and (
						not element
						or type(now) ~= "table"
						or type(was) ~= "table"
						or moved(now, was, element)
					)
				then
					return true
				end
			end

			return false
		end

		local inner = shape.value

		if inner ~= nil then
			for key, now in current do
				local was = last[key]

				if
					now ~= was
					and (not inner or type(now) ~= "table" or type(was) ~= "table" or moved(now, was, inner))
				then
					return true
				end
			end

			--[[ And the keys the baseline has that the current value does not — an entry removed
			     is a change, and the loop above cannot see one. ]]
			for key in last do
				if current[key] == nil then
					return true
				end
			end

			return false
		end

		local branches = shape.branches

		if branches then
			if current.tag ~= last.tag then
				return true
			end

			local chosen = branches[current.tag]
			local now, was = current.value, last.value

			return now ~= was
				and (not chosen or type(now) ~= "table" or type(was) ~= "table" or moved(now, was, chosen))
		end

		return false
	end

	--[[ Returns the snapshot it kept, so a caller sending the same subject to several recipients
	     copies once and hands the copy on; and whether the attempt *failed* rather than merely
	     wrote nothing, which is the difference between a recipient who is up to date and a change
	     that cannot be written at all. ]]
	local function send(
		channel: any,
		who: any,
		subject: any,
		current: any,
		kept: any,
		shape: any
	): (any, boolean)
		local base = baselines.of(who, channel, subject)

		--[[ `change` answers false when this recipient is already up to date, which is the common
		     case and costs nothing on the wire. The baseline is only advanced when something was
		     actually written, or a failed encode would leave the server believing it had sent
		     what it had not. ]]
		local written, failure = outbound.change(channel, who, subject, base, current)

		if not written then
			return kept, failure ~= nil
		end

		if current == nil then
			baselines.drop(who, channel, subject)
			return kept, false
		end

		local copy = kept or snapshot(current, shape)

		baselines.keep(who, channel, subject, copy)
		return copy, false
	end

	local function tickChannel(channel: any, everyone: { any })
		local store = channel.store
		local slot = slotOf(channel)
		local shape = slot.shape
		local present = slot.scratch
		local population = #everyone

		table.clear(present)

		local kept = slot.kept
		local stuck = slot.stuck

		for _, subject in store.subjects() do
			local current = store.read(subject)

			if current == nil then
				continue
			end

			present[subject] = true

			local count = Recipients.of(channel.audience, subject, roster, recipients, channel, everyone)
			local broadcast = count == -1
			local audience = recipients

			if broadcast then
				--[[ Everyone: the frame's roster, read in place. It used to be copied into the
				     scratch so the loop below read both branches the same way, which was one
				     write per player per subject per tick for a list that was already in hand
				     (SECURITY-REPORT-M4 77). ]]
				audience = everyone
				count = population
			end

			--[[
				One comparison for the whole audience, in place of one encode attempt per member
				of it.

				Measured before this existed, by `bench/tick.luau`: fifty players and five
				hundred subjects with **nothing moving** cost 36.3 ms a tick — twice a frame at
				60 FPS — at 1,450 ns for every pair, whether or not there was anything to say. A
				tenth of the world moving cost the same 36.5 ms, which is the finding in one
				number: the price was the asking, not the answering.

				`held` is the snapshot every settled recipient's baseline points at, so
				`base == held` is a pointer comparison that proves the differ would write
				nothing. It is only asked when the value itself has not moved; when it has, every
				recipient is attempted as before.
			]]
			local held = kept[subject]
			local settled = held ~= nil and not moved(current, held, shape)

			--[[
				A subject no recipient could take last time — a change past the packet's two-byte
				length, which the encoder refuses — is not tried again until the value moves. It used
				to be attempted once per recipient per tick for ever, with the same report each
				time (M4 report, finding 24). `Outbound` reports the attempt through the repeat
				suppression, so the game is told once per value that cannot be sent.
			]]
			local jammed = settled and stuck[subject] == held

			--[[ Seeded with the snapshot rather than nil, so a client that joins into a world
			     at rest is handed the table everyone else already holds instead of a second one
			     equal to it. Two tables would split the audience into identity classes and cost
			     every one of them the attempt above, for ever. ]]
			local copy: any = if settled then held else nil
			local broken = false

			if not jammed then
				for index = 1, count do
					local who = audience[index]

					if settled and baselines.of(who, channel, subject) == held then
						continue
					end

					local failed
					copy, failed = send(channel, who, subject, current, copy, shape)
					broken = broken or failed
				end
			end

			if broken then
				--[[ Kept even though nothing was sent, so the next tick can see the value has not
				     moved since it could not be sent. One snapshot per subject that cannot go. ]]
				copy = copy or snapshot(current, shape)
				stuck[subject] = copy
			elseif not jammed then
				stuck[subject] = nil
			end

			--[[ Only when something was actually sent, or could not be. A subject nobody can see
			     would otherwise allocate a snapshot per tick for the life of the server, and a
			     failed encode would record a value no client has. ]]
			if copy ~= nil then
				kept[subject] = copy
			end

			--[[
				And the players who are *not* recipients but still hold a baseline for this
				subject — a player who walked out of a `nearby` radius, or whose ownership
				changed.

				`PLAN-M4` D-4 said one leaving needs to be told to forget, and this is where
				that is said. Without it the subject would sit on that client at whatever value
				it had when they left, forever, and nothing on either side would know.

				Skipped outright when the recipients are everyone — a broadcast, or a `select`
				that returned the whole roster, which after `Recipients.of` has dropped what is
				not a player and what is duplicated means the same set.
			]]
			if not broadcast and count < population then
				table.clear(marked)

				for index = 1, count do
					marked[recipients[index]] = true
				end

				--[[ Baseline first: a player who has never seen this subject answers in three lookups
				     and is most of the roster, so the set is asked only about the ones who have. ]]
				for _, who in everyone do
					if baselines.of(who, channel, subject) ~= nil and not marked[who] then
						send(channel, who, subject, nil, nil, shape)
					end
				end
			end
		end

		--[[ Subjects the store no longer lists at all — a destroyed replica, a key removed from
		     the table. The loop above cannot see them, so they are found by what was there last
		     time. ]]
		for subject in slot.held do
			if not present[subject] then
				--[[ Dropped here rather than left to be overwritten: a store that lists a
				     million subjects once and never again would otherwise keep a snapshot of
				     each of them for the life of the server. ]]
				kept[subject] = nil
				stuck[subject] = nil

				for _, who in everyone do
					if baselines.of(who, channel, subject) ~= nil then
						send(channel, who, subject, nil, nil, shape)
					end
				end
			end
		end

		--[[ Swapped rather than copied, so a tick allocates no table of its own. ]]
		slot.held, slot.scratch = present, slot.held
	end

	--[[
		One channel's tick under one `pcall`, so a raise inside game code — a store, a selector,
		a subject that is NaN — loses that channel's frame and not every channel's flush. `Driver`
		runs this before `outbound.flush`, and until PLAN-M4-BUG phase 5 a raise here stalled every
		outbound channel for every player for as long as the value persisted (M4 report, finding
		20). Per channel rather than per subject because a `pcall` with arguments costs nothing to
		set up and the loop's locals would otherwise have to be threaded through a closure.
	]]
	return function()
		local everyone = roster.all()

		for _, channel in channels() do
			local ok, failure = pcall(tickChannel, channel, everyone)

			if not ok then
				Observer.emit(
					channel.qualified,
					nil,
					"replicate",
					`the tick raised inside game code, so this channel was skipped this frame: {tostring(
						failure
					)}`,
					0
				)
			end
		end
	end
end

return Tick
