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

	Which is cheaper depends on the ratio of subjects to players and on what `switchTo` costs, and
	the benchmark cannot see either yet — `PLAN-M4` phase 0 fixed the send-side allocation probe and
	the replication axis is phase 7's. Measuring before choosing is `CLAUDE.md` §9, so this is the
	simple one until there is a number.
]]

local Recipients = require("../transport/Recipients")

local Tick = {}

type Slot = {
	--[[ Which subjects the store listed last time. A subject that was there and is not any more has
	     to be taken off every client that has it, and nothing else would notice — it is absent from
	     the store, so the loop below never reaches it. ]]
	held: { [any]: boolean },
	scratch: { [any]: boolean },
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
			slot = { held = {}, scratch = {} }
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

			for _, subject in store.subjects() do
				local current = store.read(subject)

				if current == nil then
					continue
				end

				present[subject] = true

				local count = Recipients.of(channel.audience, subject, roster, recipients, channel)

				if count == -1 then
					--[[ Everyone. Copied into the array so the removal pass below can ask "was this
					     player a recipient" the same way for both branches. ]]
					count = 0

					for _, who in everyone do
						count += 1
						recipients[count] = who
					end
				end

				local kept: any = nil

				for index = 1, count do
					kept = send(channel, recipients[index], subject, current, kept)
				end

				--[[
					And the players who are *not* recipients but still hold a baseline for this
					subject — a player who walked out of a `nearby` radius, or whose ownership
					changed.

					`PLAN-M4` D-4 said one leaving needs to be told to forget, and this is where
					that is said. Without it the subject would sit on that client at whatever value
					it had when they left, forever, and nothing on either side would know.
				]]
				for _, who in everyone do
					if not among(who, count) and baselines.of(who, channel, subject) ~= nil then
						send(channel, who, subject, nil, nil)
					end
				end
			end

			--[[ Subjects the store no longer lists at all — a destroyed replica, a key removed from
			     the table. The loop above cannot see them, so they are found by what was there last
			     time. ]]
			for subject in slot.held do
				if not present[subject] then
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
