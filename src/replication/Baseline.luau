--!strict
--!optimize 2

--[=[
	@class Baseline

	What each client already has, per subject, so the next packet can be a difference rather than
	the whole thing.

	This is the piece neither neighbour holds. Charm Sync keeps one `lastSyncedValue` per *key* and
	diffs everyone against it; ReplicaService keeps no baseline at all, because the game names the
	mutation. Per client per subject is what a **dynamic audience** needs (`PLAN-M4` D-4): a player
	who walks into a `nearby` radius has never seen that subject, and a player who walks out has to
	stop being remembered.

	Internal. `nw.replicate` is the public read of it.
]=]

--[[
	Three levels of table — client, channel, subject — rather than one keyed on a composite.

	Every operation that matters is "everything for this client" (a disconnect) or "everything for
	this client on this channel" (a resync), and both are one `nil` assignment on a nested table and
	a walk on a flat one. The one that is not — "everything for this subject, across clients" — is
	rare and is paid for with the walk.

	The principle `PLAN-M3` D-6 applied to the pending set applies unchanged: this is memory sized by
	how many people join, so it is bounded, and the bound reports rather than grows.
]]

local Observer = require("../api/Observer")
local Settings = require("../api/Config")

local Baseline = {}

--[[
	Constant, because the condition behind it is constant: a game over the limit is over it on every
	tick, and a reason built per report would be `CLAUDE.md` §9's "count it instead of weighing it"
	broken on exactly the shape that taught it.

	It says what it costs rather than what it is. "Sent whole instead of as a change" was the old
	wording and it understates by a factor of the framerate: the subject is sent whole **every tick**,
	for a world that is not moving, for as long as the game stays over the line.
]]
local REFUSED = "this client is already holding the most replication baselines the "
	.. "baselinesPerClient limit allows, so every subject past it is encoded and sent whole on "
	.. "every tick, changed or not — which costs more bandwidth than replicating it would. Raise "
	.. "the limit, or narrow the audience so each player sees fewer subjects"

--[[ The peer on the other end of a client's connection has no `Player` to be keyed by, and `nil` is
     not a table key. This stands in for "the server" on the client's side and cannot collide with a
     `Player` — the same sentinel, for the same reason, as `src/api/Protocol.luau`. ]]
local SERVER: any = table.freeze({})

local function keyOf(who: any?): any
	return if who == nil then SERVER else who
end

type Subjects = { [any]: any }
type Channels = { [any]: Subjects }

--[=[
	@interface Baseline
	@within Baseline
	.of (who: any, channel: any, subject: any) -> any -- what they have, or nil
	.keep (who: any, channel: any, subject: any, value: any) -> boolean -- false when the limit refused it
	.drop (who: any, channel: any, subject: any) -> ()
	.desync (who: any, channel: any) -> () -- everything this client had on this channel is gone
	.forget (who: any) -> () -- they left
	.held (who: any) -> number
	.each (who: any, channel: any, visit: (subject: any, value: any) -> ()) -> () -- every subject they hold on this channel
	.reset () -> ()
]=]
export type Baseline = {
	of: (who: any, channel: any, subject: any) -> any,
	keep: (who: any, channel: any, subject: any, value: any) -> boolean,
	drop: (who: any, channel: any, subject: any) -> (),
	desync: (who: any, channel: any) -> (),
	forget: (who: any) -> (),
	held: (who: any) -> number,
	each: (who: any, channel: any, visit: (subject: any, value: any) -> ()) -> (),
	reset: () -> (),
}

--[=[
	@within Baseline
	@function new
	@param bounded boolean? -- whether `baselinesPerClient` applies; true unless said otherwise
	@return Baseline

	One store. The driver holds a single instance; a test holds its own.

	:::caution
	**The server's is bounded and the client's is not**, and the asymmetry is deliberate. On the
	server this is memory sized by how many people join, which is what `baselinesPerClient` exists
	for. On the client it is what the server chose to send — already bounded, by that limit, at the
	other end — and refusing to remember one here would not save anything, it would make the next
	change unreadable.

	Bounded is the default because forgetting to ask for it on the server is an unbounded leak,
	where forgetting to turn it off on the client is a loud desync.
	:::
]=]
function Baseline.new(bounded: boolean?): Baseline
	local limited = bounded ~= false
	local records: { [any]: Channels } = {}

	--[[ Counted rather than walked. The limit is read on every `keep`, so recomputing the size each
	     time would make the bound cost more than the thing it bounds. ]]
	local counts: { [any]: number } = {}

	--[[ Which clients have already been told their budget is full, per channel. A boolean rather
	     than a count: what an author needs to know is that a line was crossed, and by how much is
	     `held` minus the limit, which they can read at any time. ]]
	local announced: { [any]: { [any]: boolean } } = {}

	--[[ Back under the line, so the next crossing is worth saying again. Called from every path that
	     releases one — a subject dropped, a channel given up on, a player gone. ]]
	local function rearm(key: any)
		if announced[key] and counts[key] and counts[key] < Settings.limitOf("baselinesPerClient") then
			announced[key] = nil
		end
	end

	local function channelsOf(key: any): Channels
		local channels = records[key]

		if not channels then
			channels = {}
			records[key] = channels
			counts[key] = 0
		end

		return channels
	end

	return {
		of = function(who: any, channel: any, subject: any): any
			local channels = records[keyOf(who)]

			if not channels then
				return nil
			end

			local subjects = channels[channel]
			return if subjects then subjects[subject] else nil
		end,

		keep = function(who: any, channel: any, subject: any, value: any): boolean
			local key = keyOf(who)
			local channels = channelsOf(key)
			local subjects = channels[channel]

			if not subjects then
				subjects = {}
				channels[channel] = subjects
			end

			--[[ Replacing one costs nothing and is the common case by a wide margin — a subject
			     whose baseline is being updated was already counted. ]]
			if subjects[subject] ~= nil then
				subjects[subject] = value
				return true
			end

			if limited and counts[key] >= Settings.limitOf("baselinesPerClient") then
				--[[
					Refused, and what that costs is a full encode and a full packet for this subject
					**on every tick** rather than a patch — correct and expensive, which is the right
					way round for a bound to fail. A replication layer that answered a budget by
					dropping state would be trading the one thing it exists to get right for the one
					thing a bandwidth graph would have shown anyway.

					~~It degrades to what `nw.state` does for a living.~~ **It does not**, and the
					difference is the whole of this finding: `nw.state` sends when the game publishes,
					and this sends every tick whether anything moved or not. Measured at 300 subjects
					against a limit of 256, with the store untouched: 265 bytes and 44 refusals every
					idle frame, for ever (M4 report).

					**And the full packet every tick stands, with the argument written out** (M4-1 asked
					for a per-client "received the last snapshot" flag so an idle frame sends nothing).
					A per-client flag cannot answer for a client that *enters* a subject's audience later:
					the subject is settled, the client is over the line, and the flag would say "already
					has it" about a subject it has never seen. The record that can answer is per
					(client, subject) — and that is a baseline slot, which is exactly what this limit
					bounds. So the resend is the honest cost of being over the limit, reported once below,
					and the fix is the one the report names: raise the limit or narrow the audience.

					**Said once per client per channel, not once per subject per tick.** The condition
					is a state, not an event — 44 subjects over the line was 2,640 reports a second
					describing one unchanging fact, which is a console nobody can read and an
					`nw.observe` nobody can aggregate. It re-arms below the line, so a game that
					crosses it again is told again.
				]]
				local said = announced[key]

				if not said then
					said = {}
					announced[key] = said
				end

				if not said[channel] then
					said[channel] = true
					Observer.emit(channel.qualified, who, "replicate", REFUSED, 0)
				end

				return false
			end

			subjects[subject] = value
			counts[key] = counts[key] + 1
			return true
		end,

		drop = function(who: any, channel: any, subject: any)
			local key = keyOf(who)
			local channels = records[key]

			if not channels then
				return
			end

			local subjects = channels[channel]

			if not subjects or subjects[subject] == nil then
				return
			end

			subjects[subject] = nil
			counts[key] = counts[key] - 1
			rearm(key)
		end,

		--[[ Everything this client had on this channel, gone. The next tick therefore sends
		     snapshots, which is the resnapshot path D-2's break detector and D-4's audience entry
		     both end in — one mechanism, reached three ways. ]]
		desync = function(who: any, channel: any)
			local key = keyOf(who)
			local channels = records[key]

			if not channels then
				return
			end

			local subjects = channels[channel]

			if not subjects then
				return
			end

			local held = 0

			for _ in subjects do
				held += 1
			end

			channels[channel] = nil
			counts[key] = counts[key] - held
			rearm(key)
		end,

		--[[ They left. Tested the way `PLAN-M3` tested the queue drop, because it is the same
		     defect waiting in a different table: state that outlives the connection that justified
		     it. ]]
		forget = function(who: any)
			local key = keyOf(who)
			records[key] = nil
			counts[key] = nil
			announced[key] = nil
		end,

		held = function(who: any): number
			return counts[keyOf(who)] or 0
		end,

		--[[ A callback rather than the table, because the table is the record. The one caller is
		     `Inbound.drain`, which on a client treats these baselines as the queue for a listener
		     attached late (PLAN-M4-BUG D-3); it fills a list inside the visit and dispatches after,
		     so nothing here is mutated mid-walk. ]]
		each = function(who: any, channel: any, visit: (any, any) -> ())
			local channels = records[keyOf(who)]
			local subjects = if channels then channels[channel] else nil

			if not subjects then
				return
			end

			for subject, value in subjects do
				visit(subject, value)
			end
		end,

		reset = function()
			table.clear(records)
			table.clear(counts)
			table.clear(announced)
		end,
	}
end

return Baseline
