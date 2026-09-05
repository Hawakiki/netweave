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

	`PLAN-M3` D-6's rule applies unchanged: this is memory sized by how many people join, so it is
	bounded, and the bound reports rather than grows.
]]

local Observer = require("../api/Observer")
local Settings = require("../api/Config")

local Baseline = {}

--[[ Constant, because the refusal fires once per subject per tick for as long as the game stays
     over the limit — which is a flood in every sense that matters, and `CLAUDE.md` §9's "count it
     instead of weighing it" was learned on exactly this shape of mistake. ]]
local REFUSED = "this client is already holding the most replication baselines the "
	.. "baselinesPerClient limit allows, so this subject is sent whole instead of as a change. "
	.. "Raise the limit, or replicate fewer subjects to each player"

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
	.reset () -> ()
]=]
export type Baseline = {
	of: (who: any, channel: any, subject: any) -> any,
	keep: (who: any, channel: any, subject: any, value: any) -> boolean,
	drop: (who: any, channel: any, subject: any) -> (),
	desync: (who: any, channel: any) -> (),
	forget: (who: any) -> (),
	held: (who: any) -> number,
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
					Refused, and what that costs is a *snapshot every tick* for this subject and
					this client rather than a patch — correct and expensive, which is how a bound
					should fail. It degrades to what `nw.state` does for a living.

					Reported per channel and stage like every other refusal, so a game that crossed
					the line finds out from its console rather than from its bandwidth graph.
				]]
				Observer.emit(channel.qualified, who, "replicate", REFUSED, 0)
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
		end,

		--[[ They left. Tested the way `PLAN-M3` tested the queue drop, because it is the same
		     defect waiting in a different table: state that outlives the connection that justified
		     it. ]]
		forget = function(who: any)
			local key = keyOf(who)
			records[key] = nil
			counts[key] = nil
		end,

		held = function(who: any): number
			return counts[keyOf(who)] or 0
		end,

		reset = function()
			table.clear(records)
			table.clear(counts)
		end,
	}
end

return Baseline
