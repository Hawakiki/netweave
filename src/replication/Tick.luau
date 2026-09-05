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
}

--[=[
	@interface Config
	@within Tick
	.outbound Outbound
	.baselines Baseline
	.roster Roster
	.channels () -> { any } -- the replicated channels, read late because ids are assigned late
]=]
export type Config = {
	outbound: any,
	baselines: any,
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

	local slots: { [any]: Slot } = {}

	--[[ Reused across ticks and channels. `Recipients.of` fills a caller-owned array for exactly
	     this reason: a `state` channel resolves an audience per subject per tick, and returning a
	     table there would allocate once per subject per frame for the life of the server. ]]
	local recipients: { any } = {}

	local function slotOf(channel: any): Slot
		local slot = slots[channel]

		if not slot then
			slot = { held = {}, scratch = {}, kept = {} }
			slots[channel] = slot
		end

		return slot
	end

	--[[ Whether `who` is among the first `count` entries. A linear scan because an audience is a
	     handful of players and building a set to avoid it would allocate one per subject. ]]
	local function among(who: any, count: number): boolean
		for index = 1, count do
			if recipients[index] == who then
				return true
			end
		end

		return false
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
	]]
	local function snapshot(value: any): any
		if type(value) ~= "table" then
			return value
		end

		local out = table.clone(value)

		for key, inner in out do
			if type(inner) == "table" then
				out[key] = snapshot(inner)
			end
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
		freeze. Structural is the safe side: two values the differ would encode identically — a
		number that snaps to the same f32, a field the schema does not read — are called *moved*
		here, which costs an attempt that writes nothing. The reverse cannot happen: if every key
		compares equal then every field the schema reads compares equal.

		The one value it inherits a hole on is `buffer`, which `snapshot` carries by reference (see
		above) — so a game that mutates one in place defeats this exactly as far as it already
		defeated the baseline, and no further.
	]]
	local function moved(current: any, last: any): boolean
		if current == last then
			return false
		end

		if type(current) ~= "table" or type(last) ~= "table" then
			return true
		end

		for key, value in current do
			local other = last[key]

			if other ~= value then
				if type(value) ~= "table" or type(other) ~= "table" or moved(value, other) then
					return true
				end
			end
		end

		--[[ And the keys the baseline has that the current value does not — a field removed is a
		     change, and the loop above cannot see one. ]]
		for key in last do
			if current[key] == nil then
				return true
			end
		end

		return false
	end

	--[[ Returns the snapshot it kept, so a caller sending the same subject to several recipients
	     copies once and hands the copy on. ]]
	local function send(channel: any, who: any, subject: any, current: any, kept: any): any
		local base = baselines.of(who, channel, subject)

		--[[ `change` answers false when this recipient is already up to date, which is the common
		     case and costs nothing on the wire. The baseline is only advanced when something was
		     actually written, or a failed encode would leave the server believing it had sent
		     what it had not. ]]
		if not outbound.change(channel, who, subject, base, current) then
			return kept
		end

		if current == nil then
			baselines.drop(who, channel, subject)
			return kept
		end

		local copy = kept or snapshot(current)

		baselines.keep(who, channel, subject, copy)
		return copy
	end

	return function()
		local everyone = roster.all()

		for _, channel in channels() do
			local store = channel.store
			local slot = slotOf(channel)
			local present = slot.scratch

			table.clear(present)

			local kept = slot.kept

			for _, subject in store.subjects() do
				local current = store.read(subject)

				if current == nil then
					continue
				end

				present[subject] = true

				local count = Recipients.of(channel.audience, subject, roster, recipients, channel)
				local broadcast = count == -1

				if broadcast then
					--[[ Everyone. Copied into the array so the removal pass below can ask "was this
					     player a recipient" the same way for both branches. ]]
					count = 0

					for _, who in everyone do
						count += 1
						recipients[count] = who
					end
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
				local settled = held ~= nil and not moved(current, held)

				--[[ Seeded with the snapshot rather than nil, so a client that joins into a world
				     at rest is handed the table everyone else already holds instead of a second one
				     equal to it. Two tables would split the audience into identity classes and cost
				     every one of them the attempt above, for ever. ]]
				local copy: any = if settled then held else nil

				for index = 1, count do
					local who = recipients[index]

					if settled and baselines.of(who, channel, subject) == held then
						continue
					end

					copy = send(channel, who, subject, current, copy)
				end

				--[[ Only when something was actually sent. A subject nobody can see would otherwise
				     allocate a snapshot per tick for the life of the server, and a failed encode
				     would record a value no client has. ]]
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

					Skipped outright for a broadcast, where the recipients *are* `everyone` and the
					answer is known without asking: the pass is O(players) `among` scans over an
					array of the same players, which is O(players²) per subject to conclude nothing.
					And asked baseline-first otherwise, because a player who has never seen this
					subject is three lookups where the scan is the length of the audience.
				]]
				if not broadcast then
					for _, who in everyone do
						if baselines.of(who, channel, subject) ~= nil and not among(who, count) then
							send(channel, who, subject, nil, nil)
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

					for _, who in everyone do
						if baselines.of(who, channel, subject) ~= nil then
							send(channel, who, subject, nil, nil)
						end
					end
				end
			end

			--[[ Swapped rather than copied, so a tick allocates no table of its own. ]]
			slot.held, slot.scratch = present, slot.held
		end
	end
end

return Tick
