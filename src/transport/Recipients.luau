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

local Recipients = {}

--[=[
	@interface Roster
	@within Recipients
	.all () -> { any } -- every connected player
	.owner (subject: any) -> any? -- the player the subject belongs to, or nil
	.within (subject: any, studs: number, out: { any }) -> number -- fills `out`, returns how many

	Everything the audience rules need to know about the world.

	`within` fills a caller-owned array rather than returning a fresh one, because it runs per
	publish and a `state` channel publishes per subject per tick. Returning a table there would
	allocate once per subject per frame for the life of the server.
]=]
export type Roster = {
	all: () -> { any },
	owner: (subject: any) -> any?,
	within: (subject: any, studs: number, out: { any }) -> number,
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

		owner = function(subject: any): any?
			if typeof(subject) ~= "Instance" then
				return nil
			end

			local instance = subject :: Instance

			if instance:IsA("Player") then
				return instance
			end

			return Players:GetPlayerFromCharacter(instance :: Model)
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
	@return number -- how many recipients, or -1 for "everyone"

	Resolves an audience to recipients.

	**-1 means everyone**, and it is not the same as filling `out` with every player. A channel
	whose audience is everyone sends one `FireAllClients` instead of N `FireClient`s, which is the
	one place ByteNet beats both code generators (`RESEARCH §3.7-E`). Collapsing the two would
	throw that away silently.
]=]
function Recipients.of(audience: any, subject: any, roster: Roster, out: { any }): number
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
	]]
	local chosen = audience.select(subject)

	if type(chosen) ~= "table" then
		return 0
	end

	local count = #chosen

	for index = 1, count do
		out[index] = chosen[index]
	end

	return count
end

return Recipients
