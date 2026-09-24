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

	`DESIGN-API.md` §11 (Open) left open whether `nearby` is evaluated per subject or cached per tick.
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
--[[
	~~Asked the way `Serdes.isInstance` asks its own question: exact inside Roblox, and a table under
	lune where the suite stands players in.~~ **That split was wrong here, and the way it was wrong is
	the finding.**

	`Serdes.isInstance` can branch on the runtime because the Studio suite hands it a **real
	Instance** — the double matches the real thing in the dimension the code checks, which is
	`CLAUDE.md` §9's rule for doubles. A `Player` cannot be constructed, so no suite can do the same
	here: `replication_runtime` needs two of them and Play mode has one. The branch therefore made
	every table stand-in a recipient under lune and none in Studio, and two suites that pass on every
	lune run went red the moment the place was opened — which is §9's "the half that cannot run under
	lune is the half that goes red quietly", reproduced by the commit that quoted it.

	So the two questions are separated instead of merged:

	  * **kind**, here — could this ever be addressed at all. A number, a string or a boolean cannot
	    be a table key the send buffers are parked under, let alone reach `FireClient`. That is true
	    in both runtimes and needs no branch.
	  * **identity**, `has` below — is this someone this endpoint can send to *right now*.
	    `Recipients.roblox` answers it with `typeof(who) == "Instance"`, `IsA("Player")` and
	    `Parent == Players`, which is strictly more than the kind test and is what production runs.

	A roster that answers `has` is therefore the whole test, and this is the floor for one that does
	not. What that floor gives up is a plain table: `{ 5, "text", {} }` was three parked send buffers
	before M4 phase 8 and is one now rather than zero — and zero everywhere `has` exists, which is
	every path netweave builds itself.
]]
local function isRecipient(who: any): boolean
	return type(who) == "table" or typeof(who) == "Instance"
end

--[[
	Said once per audience, not once per publish.

	A selector that returns rubbish returns it every tick, and a `state` channel publishes per
	subject per tick — so reporting each one would be thousands of copies of one unchanging fact a
	second, which is the mistake `Baseline` made with `baselinesPerClient` and the same lesson
	(`CLAUDE.md` §9). Weak keys so a namespace that is reset does not pin its audiences here.
]]
local announced: { [any]: { dropped: boolean, duplicated: boolean } } = setmetatable({}, { __mode = "k" }) :: any

--[[ Which players a `select` has already admitted this call, so a duplicate is one lookup rather
     than a scan of everything admitted so far. Module-owned and cleared after each call: one table
     for the life of the process, nothing per publish. ]]
local chosenSet: { [any]: boolean } = {}

--[[
	Who is here this frame, as a set, built from the frame's player list the first time a call
	brings that list and kept while calls keep bringing the same one. The tick takes `roster.all()`
	once and hands it to every subject (finding 77), so the set is built once a tick and every
	membership question after — one per recipient per subject, S × P of them — is a lookup rather
	than `has`, which on Roblox is three engine calls (`typeof`, `IsA`, `Parent`). A fresh list, as
	a lone `publish` brings, rebuilds it: P writes, against the P `has` calls it replaces.

	The list is the roster's own answer to who is here, so it is at least the answer `has` gives,
	and a member of it cannot have left inside the tick that holds it — nothing yields there.
]]
local presentFor: { any }? = nil
local present: { [any]: true } = {}

local function presence(players: { any }): { [any]: true }
	if presentFor ~= players then
		table.clear(present)

		for _, who in players do
			present[who] = true
		end

		presentFor = players
	end

	return present
end

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
	.within (subject: any, studs: number, out: { any }, players: { any }) -> number -- fills `out` from `players`, returns how many
	.has ((who: any) -> boolean)? -- whether this is someone the endpoint can send to right now

	Everything the audience rules need to know about the world.

	`within` fills a caller-owned array rather than returning a fresh one, because it runs per
	publish and a `state` channel publishes per subject per tick. Returning a table there would
	allocate once per subject per frame for the life of the server. It is handed the players to
	measure for the same reason: the Roblox roster used to ask the engine for `GetPlayers()`
	itself, a fresh table per call, once per subject per publish — 60,000 a second for a `nearby`
	channel of a thousand subjects — when the tick had already taken `all()` once for the frame
	(SECURITY-REPORT-M4 77; `bench/residue` rung 77).

	`has` is optional, and every rule but `everyone` consults it. ~~The other three rules build their
	answers out of the roster itself, so what they return is a recipient by construction.~~ `owner`
	and `nearby` return what the roster answers, and the roster answers for a player who left the
	tick before — a `Player` subject owns itself, connected or not (M4-1). Absent, they trust the
	answer, and a rig that leaves it out runs that degraded path.
]=]
export type Roster = {
	all: () -> { any },
	owner: (subject: any) -> any?,
	within: (subject: any, studs: number, out: { any }, players: { any }) -> number,

	--[[ Optional so a rig that stands players in with tables need not answer it — under lune the
	     shape test cannot tell a stand-in from a stray table. ]]
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

	--[[
		Every player's position, read once per list rather than once per subject. `within` runs per
		subject per publish and used to read `Character`, `PrimaryPart` and `Position` — three
		engine calls — for every player each time, S × P × 3 a tick. The tick hands every subject the
		same list, so the reads happen once a tick and the S × P distance checks are arithmetic over
		this array (`PLAN-M5` phase 5). `false` marks a player with no character, which is not near
		anything. A lone `publish` brings a fresh list and pays the P reads it always paid.
	]]
	local positionsFor: { any }? = nil
	local positions: { Vector3 | false } = {}

	local function positionsOf(players: { any }): { Vector3 | false }
		if positionsFor ~= players then
			local count = #players

			for index = 1, count do
				positions[index] = positionOf(players[index]) or false
			end

			for index = count + 1, #positions do
				positions[index] = nil
			end

			positionsFor = players
		end

		return positions
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

		within = function(subject: any, studs: number, out: { any }, players: { any }): number
			local origin = positionOf(subject)

			if not origin then
				return 0
			end

			local limit = studs * studs
			local count = 0
			local known = positionsOf(players)

			for index, player in players do
				local position = known[index]

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

--[[ Drops what an earlier, wider audience left in the scratch past `count`. The array is dense
     from 1, so this stops at the first hole and costs one write per stale entry, once — not a
     `table.clear` per subject per tick. ]]
local function trim(out: { any }, count: number)
	local index = count + 1

	while out[index] ~= nil do
		out[index] = nil
		index += 1
	end
end

--[=[
	@within Recipients
	@function of
	@param audience Audience
	@param subject any
	@param roster Roster
	@param out { any } -- caller-owned scratch array, filled in place
	@param channel any? -- named in the report when a `select` returns something that is not a recipient
	@param players { any }? -- the roster's players, when the caller already holds them for the frame
	@return number -- how many recipients, or -1 for "everyone"

	Resolves an audience to recipients.

	**-1 means everyone**, and it is not the same as filling `out` with every player. A channel
	whose audience is everyone sends one `FireAllClients` instead of N `FireClient`s, which is the
	one place ByteNet beats both code generators (`RESEARCH §3.7-E`). Collapsing the two would
	throw that away silently.

	`out` holds exactly the recipients past the call, and nothing past `count`: the scratch is
	reused per subject, and what a wider audience left behind kept a departed player referenced
	until a wider one overwrote the slot (SECURITY-REPORT-M4 77).

	With `players`, membership is answered from that list rather than by asking the roster per
	recipient (`PLAN-M5` phase 5): the tick brings the same list for every subject of the frame,
	so the set behind it is built once a tick.
]=]
function Recipients.of(
	audience: any,
	subject: any,
	roster: Roster,
	out: { any },
	channel: any?,
	players: { any }?
): number
	local kind = audience.kind

	if kind == "everyone" then
		trim(out, 0)
		return -1
	end

	--[[
		`owner` and `nearby` ask the roster the same question `select` asks of the game's list:
		is this player still here. bc35060 closed it for `select` only, and the owner of a
		`Player`-keyed subject is the instance itself, connected or not — a store that lists the
		departed player's subject for one more tick (a profile save that yields) rebuilt the
		baselines and the parked send record `forget` had just removed, for the life of the server
		(M4 report, finding 19; M4-1).
	]]
	local here = roster.has
	local listed: { [any]: true }? = if players then presence(players) else nil

	if kind == "owner" then
		local player = roster.owner(subject)

		if not player or (if listed then not listed[player] elseif here then not here(player) else false) then
			trim(out, 0)
			return 0
		end

		out[1] = player
		trim(out, 1)
		return 1
	end

	if kind == "nearby" then
		local count = roster.within(subject, audience.radius, out, players or roster.all())

		if not listed and not here then
			trim(out, count)
			return count
		end

		--[[ Compacted in place: `within` fills the caller's array, and a hole in it would be the
		     `select` defect over again. ]]
		local kept = 0

		for index = 1, count do
			local who = out[index]

			if if listed then listed[who] == true else (here :: (any) -> boolean)(who) then
				kept += 1
				out[kept] = who
			end
		end

		trim(out, kept)
		return kept
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
		trim(out, 0)
		return 0
	end

	local count = 0
	local dropped = false
	local duplicated = false

	for _, who in chosen do
		--[[ The frame's list where there is one, the roster's answer where there is one, and the
		     kind test where there is neither. `has` is strictly the stronger question —
		     `Recipients.roblox` checks the kind inside it — so asking both would be asking the
		     weaker one twice. See `isRecipient`. ]]
		local admitted = if listed then listed[who] == true elseif here then here(who) else isRecipient(who)

		if not admitted then
			dropped = true
			continue
		end

		--[[ ~~Linear, because an audience is a handful of players.~~ A `select` that returns the roster
		     is the common `select` — everyone but spectators, a team — and the scan was O(n²) per
		     subject: 500 subjects × 50 players was 1.25 million comparisons a tick, 7 ms of the
		     14 the M4-1 report measured (`bench/tick`, `select-all`). One set, module-owned and
		     cleared per call, so it still allocates nothing per publish. ]]
		if chosenSet[who] then
			duplicated = true
			continue
		end

		chosenSet[who] = true
		count += 1
		out[count] = who
	end

	table.clear(chosenSet)
	trim(out, count)

	if dropped or duplicated then
		announce(audience, channel, dropped, duplicated)
	end

	return count
end

return Recipients
