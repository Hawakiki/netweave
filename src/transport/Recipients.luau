--!strict
--!optimize 2

--[=[
	@class Recipients

	Turns a declared audience into the players it reaches.

	Guarantee G3 is half type and half this file. The type makes the audience impossible to omit
	and makes `broadcast` exist only where the audience is everyone; this decides, per publish, who
	`nearby(120)` actually means.

	Internal.
]=]

--[[
	Geometry is behind a `Roster` for the same reason the remotes are behind a `Link`: it is the
	only Roblox-shaped part, and putting it behind an interface is what lets the audience rules be
	tested in-process rather than by watching who received what in Studio.

	`DESIGN-API.md` §10.4 left open whether `nearby` is evaluated per subject or cached per tick.
	It is per subject here, and that is a decision this milestone is allowed to revisit once phase
	5 measures it — at 100 players and a 60 Hz state channel the difference is four orders of
	magnitude, and guessing which way is the risk `PLAN-M2` R-3 names.
]]

local Observer = require("../api/Observer")

local Recipients = {}

--[[
	Whether a value could be a recipient at all, asked the way `Serdes.isInstance` asks its own
	question and for the same reason: inside Roblox it is exact, and under lune there are no
	Instances and the suite stands players in with tables.

	It is deliberately a *shape* test rather than an identity one. Whether a particular player is
	still connected is the roster's question — `has` above — and a roster that does not answer it
	still gets the values that could never have been a recipient at all refused here.
]]
local ROBLOX = typeof(game) == "Instance"

local function isRecipient(who: any): boolean
	if ROBLOX then
		return typeof(who) == "Instance" and (who :: Instance):IsA("Player")
	end

	return type(who) == "table"
end

--[[
	Said once per audience, not once per publish.

	A selector that returns rubbish returns it every tick, and a `state` channel publishes per
	subject per tick — so reporting each one would be thousands of copies of one unchanging fact a
	second, which is the mistake `Baseline` made with `baselinesPerClient` and the same lesson
	(`CLAUDE.md` §9). Weak keys so a namespace that is reset does not pin its audiences here.
]]
local announced: { [any]: { dropped: boolean, duplicated: boolean } } = setmetatable({}, { __mode = "k" }) :: any

local NOT_A_RECIPIENT = "an audience.select returned something that is not a player who is here — a "
	.. "nil, a value of another type, or somebody who has left. It was not sent to. Return only "
	.. "players from Players:GetPlayers(), and rebuild the list rather than keeping one across "
	.. "frames: a stale entry is a send buffer this server holds until it shuts down"

local DUPLICATED = "an audience.select returned the same player more than once, and the extra copies "
	.. "were dropped. A recipient receives a packet or does not; listing one twice put the packet in "
	.. "that player's batch twice, which is bandwidth nothing asked for"

local function announce(audience: any, channel: any, dropped: boolean, duplicated: boolean)
	local said = announced[audience]

	if not said then
		said = { dropped = false, duplicated = false }
		announced[audience] = said
	end

	--[[ `Observer` keys its counters by name, so an unnamed channel is `"?"` — the same stand-in
	     `Inbound.report` uses for a packet whose id resolved to nothing. ]]
	local named = if channel then channel.qualified else "?"

	if dropped and not said.dropped then
		said.dropped = true
		Observer.emit(named, nil, "send", NOT_A_RECIPIENT, 0)
	end

	if duplicated and not said.duplicated then
		said.duplicated = true
		Observer.emit(named, nil, "send", DUPLICATED, 0)
	end
end

--[=[
	@interface Roster
	@within Recipients
	.all () -> { any } -- every connected player
	.owner (subject: any) -> any? -- the player the subject belongs to, or nil
	.within (subject: any, studs: number, out: { any }) -> number -- fills `out`, returns how many
	.has ((who: any) -> boolean)? -- whether this is someone the endpoint can send to right now

	Everything the audience rules need to know about the world.

	`within` fills a caller-owned array rather than returning a fresh one, because it runs per
	publish and a `state` channel publishes per subject per tick. Returning a table there would
	allocate once per subject per frame for the life of the server.

	`has` is optional and only `select` consults it. The other three rules build their answers out of
	the roster itself, so what they return is a recipient by construction; `select` is the one that
	hands the decision to the game and gets a table back.
]=]
export type Roster = {
	all: () -> { any },
	owner: (subject: any) -> any?,
	within: (subject: any, studs: number, out: { any }) -> number,

	--[[ Optional so a rig that stands players in with tables need not answer it — under lune the
	     shape test cannot tell a stand-in from a stray table, and only `select` asks. ]]
	has: ((who: any) -> boolean)?,
}

--[=[
	@within Recipients
	@function roblox
	@return Roster

	The Roblox roster. `nearby` measures from the subject to each player's character, and a player
	with no character is not near anything — which is the honest answer rather than an error.
]=]
function Recipients.roblox(): Roster
	local Players = game:GetService("Players")

	--[[ A subject is whatever the publisher passed: a player, a model, or something with a
	     position. Resolving it here keeps `publish(subject, value)` from dictating a shape. ]]
	local function positionOf(thing: any): Vector3?
		if typeof(thing) ~= "Instance" then
			return nil
		end

		--[[ Narrowing `any` by `typeof` leaves the solver with a union it cannot call `IsA` on, so
		     the cast says what the check already established. ]]
		local instance = thing :: Instance

		if instance:IsA("Player") then
			local character = (instance :: Player).Character
			local root = character and character.PrimaryPart
			return if root then root.Position else nil
		end

		if instance:IsA("Model") then
			local root = (instance :: Model).PrimaryPart
			return if root then root.Position else nil
		end

		if instance:IsA("BasePart") then
			return (instance :: BasePart).Position
		end

		return nil
	end

	return {
		all = function(): { any }
			return Players:GetPlayers() :: any
		end,

		--[[
			Whether this is somebody the server can send to *now*.

			`Parent == Players` rather than a scan of `GetPlayers()`: it is O(1), it is what the
			engine itself uses to mean "connected", and it is the half `select` could not answer for
			itself. A player who left is still a `Player` — the shape test cannot tell — and a stale
			list naming them rebuilt the send buffer `forget` had just removed, one per departed
			player, for as long as the game kept naming them (M4 report).
		]]
		has = function(who: any): boolean
			return typeof(who) == "Instance"
				and (who :: Instance):IsA("Player")
				and (who :: Player).Parent == Players
		end,

		owner = function(subject: any): any?
			if typeof(subject) ~= "Instance" then
				return nil
			end

			local instance = subject :: Instance

			if instance:IsA("Player") then
				return instance
			end

			--[[
				A real narrowing rather than the `:: Model` cast this used to carry.

				`GetPlayerFromCharacter` takes a `Model`, and anything reaching this line is whatever
				the game passed to `publish` — a `BasePart`, a `Folder`, a `Tool`. An external review
				flagged that as an unverified raise (M3 phase 9): it would have raised from inside
				`publish`, in game code, on a path whose whole contract is "or nil".

				Not verified in Studio and it does not need to be, because the check makes the answer
				the same either way. `within` above takes a `BasePart` and this deliberately does
				not: a position can be read off any part, and a part is not a character. Pass the
				character, or the `Player`.
			]]
			if not instance:IsA("Model") then
				return nil
			end

			return Players:GetPlayerFromCharacter(instance)
		end,

		within = function(subject: any, studs: number, out: { any }): number
			local origin = positionOf(subject)

			if not origin then
				return 0
			end

			local limit = studs * studs
			local count = 0

			for _, player in Players:GetPlayers() do
				local position = positionOf(player)

				if position then
					--[[ Squared distance, compared against a squared radius. `Magnitude` is a
					     square root, and this runs once per player per subject per publish — a
					     `state` channel at 60 Hz with 100 players is 600,000 of them a second. ]]
					local dx = position.X - origin.X
					local dy = position.Y - origin.Y
					local dz = position.Z - origin.Z

					if dx * dx + dy * dy + dz * dz <= limit then
						count += 1
						out[count] = player
					end
				end
			end

			return count
		end,
	}
end

--[=[
	@within Recipients
	@function of
	@param audience Audience
	@param subject any
	@param roster Roster
	@param out { any } -- caller-owned scratch array, filled in place
	@param channel any? -- named in the report when a `select` returns something that is not a recipient
	@return number -- how many recipients, or -1 for "everyone"

	Resolves an audience to recipients.

	**-1 means everyone**, and it is not the same as filling `out` with every player. A channel
	whose audience is everyone sends one `FireAllClients` instead of N `FireClient`s, which is the
	one place ByteNet beats both code generators (`RESEARCH §3.7-E`). Collapsing the two would
	throw that away silently.
]=]
function Recipients.of(audience: any, subject: any, roster: Roster, out: { any }, channel: any?): number
	local kind = audience.kind

	if kind == "everyone" then
		return -1
	end

	if kind == "owner" then
		local player = roster.owner(subject)

		if not player then
			return 0
		end

		out[1] = player
		return 1
	end

	if kind == "nearby" then
		return roster.within(subject, audience.radius, out)
	end

	--[[
		`select` hands the decision to the game, so the result is whatever it returned. It is copied
		into the caller's array rather than used directly: the selector may hand back a table it
		keeps, and writing into it later would be a bug in netweave that looks like one in the game.

		**What it returned is not trusted to be a list of recipients**, and every part of that
		sentence was a defect before M4 phase 8 (M4 report):

		  * `{ alice, nil, bob }` — `#` over a table with a hole is unspecified in Luau, so what
		    happened depended on how the game built the list. Measured: it raised
		    `Outbound:173: table index is nil`, which is `switchTo` writing `parked[nil]`, the exact
		    hazard the comment above that table names and does not guard.
		  * `{ 5, "text", {} }` — three parked send buffers, one per value, none of which will ever be
		    forgotten because `forget` runs from `PlayerRemoving` and none of these will ever leave.
		    Measured at 5,000 publishes to fresh values: **3.8 MB retained**.
		  * a player who has left, still named by a stale list, rebuilds the record `forget` just
		    removed — and `FireClient` on them is silent, so nothing says the packet went nowhere.

		So the walk is `pairs`, which cannot be fooled by a hole, and every value is checked before it
		becomes a destination. Duplicates are dropped for the same reason: a recipient receives a
		packet or does not, and `{ alice, alice }` put the packet in alice's batch **twice** — three
		bytes became five, measured.
	]]
	local chosen = audience.select(subject)

	if type(chosen) ~= "table" then
		return 0
	end

	local count = 0
	local dropped = false
	local duplicated = false

	for _, who in chosen do
		local connected = roster.has

		if not isRecipient(who) or (connected and not connected(who)) then
			dropped = true
			continue
		end

		--[[ Linear, because an audience is a handful of players and building a set to avoid it would
		     allocate one per publish — the same trade `Tick.among` makes, for the same reason. ]]
		local seen = false

		for index = 1, count do
			if out[index] == who then
				seen = true
				break
			end
		end

		if seen then
			duplicated = true
			continue
		end

		count += 1
		out[count] = who
	end

	if dropped or duplicated then
		announce(audience, channel, dropped, duplicated)
	end

	return count
end

return Recipients
