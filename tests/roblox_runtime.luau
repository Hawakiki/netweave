--!strict

--[[
	The half lune cannot reach.

		rojo build test.project.json -o netweave-test.rbxl

	`Vector2`, `Vector3`, `CFrame`, `Color3` and a real `Instance` only exist inside Roblox, and a
	codec test that skips them is not testing the codec. Everything else lives in
	`tests/serdes_runtime.luau`, which runs faster and needs no Studio.

	Same rule as there: encode raises on a value the schema forbids, decode never raises.

	The last section is not the codec. `Recipients.roblox()` is the one module whose whole body is
	Roblox API calls, so lune sees an injected roster and never the real one — which is how an
	unchecked `GetPlayerFromCharacter` argument survived to an external review (M3 phase 9).
]]

--[[ Services rather than globals: `workspace` is one and `Players` and `ReplicatedStorage` are not,
     and the container checks below need a tree on both sides of the boundary. ]]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RunService = game:GetService("RunService")

local Buffer = require("../src/codec/Buffer")
local Context = require("../src/api/Context")
local Link = require("../src/transport/Link")
local Namespace = require("../src/api/Namespace")
local Observer = require("../src/api/Observer")
local Recipients = require("../src/transport/Recipients")
local Serdes = require("../src/codec/Serdes")
local Transport = require("../src/api/Transport")
local nw = require("../src/netweave")
local t = require("../src/types")

local failures = 0

local function fail(message: string)
	failures += 1
	warn(`FAIL  {message}`)
end

local function check(name: string, condition: boolean)
	if not condition then
		fail(name)
	end
end

local function equals(name: string, actual: any, expected: any)
	if actual ~= expected then
		fail(`{name}: expected {tostring(expected)}, got {tostring(actual)}`)
	end
end

local function encode(codec: Serdes.Codec, value: any): (buffer, { Instance })
	codec.write(value)
	return Buffer.take()
end

local function decode(codec: Serdes.Codec, bytes: buffer, instances: { unknown }?): (any, string?)
	Buffer.beginRead(bytes, instances)
	return codec.read()
end

--[[ Round trips one value and hands the result back, so each datatype can compare it its own way:
     `CFrame` needs a tolerance, `Color3` does not. ]]
local function roundTrip(descriptor: any, value: any, instances: { unknown }?): (any, string?, number)
	local codec = Serdes.fromSchema(descriptor)
	local packed, sidecar = encode(codec, value)
	local decoded, failure = decode(codec, packed, instances or sidecar :: { unknown })
	return decoded, failure, buffer.len(packed)
end

local function rejects(name: string, descriptor: any, bytes: buffer, instances: { unknown }?)
	local codec = Serdes.fromSchema(descriptor)
	local ok, value, failure = pcall(decode, codec, bytes, instances or {})

	if not ok then
		fail(`{name}: decode raised {tostring(value)}`)
		return
	end

	if failure == nil then
		fail(`{name}: decode accepted bytes it should have rejected`)
	end
end

--[[
	The suite runs the moment the server starts, and the player joins after it — measured: the
	first Studio pass of the roster section printed its skip line every time, with a player in the
	Play by the time anyone read the console. So the sections that need one wait for one, briefly,
	and say so once when none comes rather than once per section.
]]
local PLAYER_TIMEOUT = 15

local function waitForPlayer(): Player?
	local deadline = os.clock() + PLAYER_TIMEOUT

	while os.clock() < deadline do
		local players = Players:GetPlayers()

		if players[1] then
			return players[1]
		end

		task.wait(0.1)
	end

	return nil
end

local player = waitForPlayer()

if not player then
	print(`        skip: no player joined within {PLAYER_TIMEOUT} s, so nothing that needs one was asserted`)
end

-- ---------------------------------------------------------------------------------------------
-- Vectors
-- ---------------------------------------------------------------------------------------------

do
	local value, failure, size = roundTrip(t.vector2, Vector2.new(1.5, -2.25))
	equals("vector2 is eight bytes", size, 8)
	equals("vector2 decodes", failure, nil)
	equals("vector2 round trips", value, Vector2.new(1.5, -2.25))
end

do
	local value, failure, size = roundTrip(t.vector3, Vector3.new(1.5, -2.25, 1024))
	equals("vector3 is twelve bytes", size, 12)
	equals("vector3 decodes", failure, nil)
	equals("vector3 round trips", value, Vector3.new(1.5, -2.25, 1024))
end

do
	local direction = Vector3.new(1, 2, 3).Unit
	local value, failure = roundTrip(t.unitVector3, direction)
	equals("a unit vector decodes", failure, nil)
	check("a unit vector round trips", (value - direction).Magnitude < 1e-4)
end

do
	--[[
		A direction that is not a direction is an exploit primitive: a handler that trusts
		`t.unitVector3` and multiplies by its own range gets an arbitrary displacement out of a
		magnitude of 400. The schema said unit, so the decoder enforces unit.
	]]
	local hostile = buffer.create(12)
	buffer.writef32(hostile, 0, 0)
	buffer.writef32(hostile, 4, 0)
	buffer.writef32(hostile, 8, 400)

	rejects("a unit vector with a magnitude of 400", t.unitVector3, hostile)
end

do
	--[[ NaN passes every comparison a downstream check is likely to write, so it has to stop
	     here. ]]
	local hostile = buffer.create(12)
	buffer.writef32(hostile, 0, 0 / 0)
	buffer.writef32(hostile, 4, 0)
	buffer.writef32(hostile, 8, 0)

	rejects("a vector3 carrying NaN", t.vector3, hostile)

	local infinite = buffer.create(12)
	buffer.writef32(infinite, 0, math.huge)
	buffer.writef32(infinite, 4, 0)
	buffer.writef32(infinite, 8, 0)

	rejects("a vector3 carrying infinity", t.vector3, infinite)
end

-- ---------------------------------------------------------------------------------------------
-- Vectors carried at a component schema (M4 phase 8)
-- ---------------------------------------------------------------------------------------------

--[[
	Bare, a vector is three `f32` and **unbounded**: a position of `1e38` on an `intent` passes
	`parse`, and `t.unitVector3` covers directions only (M4 report). Naming a component schema is how
	a position says where the map is, and everything a number type knows applies per axis — so this
	is also where the bytes go.

	`tests/ir_runtime.luau` has the byte counts from the layout. What only Studio can say is that the
	values survive, because a `Vector3` is what neither exists nor round-trips under lune.
]]

do
	local placed = t.vector3(t.i16(-2048, 2048))
	local value, failure, size = roundTrip(placed, Vector3.new(-2048, 0, 2048))

	equals("a narrowed vector3 is six bytes, not twelve", size, 6)
	equals("and decodes", failure, nil)
	equals("both ends of the range survive", value, Vector3.new(-2048, 0, 2048))

	local flat = t.vector2(t.i16(-1024, 1024))
	local plane, refused, planeSize = roundTrip(flat, Vector2.new(-1024, 1024))

	equals("a narrowed vector2 is four", planeSize, 4)
	equals("and decodes", refused, nil)
	equals("intact", plane, Vector2.new(-1024, 1024))

	--[[ The whole point of naming a range: off the map is a refusal at the `:send` that wrote it,
	     with the bounds in the message, rather than a legal position. ]]
	local wrote = pcall(Serdes.fromSchema(placed).write, Vector3.new(1e38, 0, 0))
	Buffer.load(nil)

	check("a position outside the declared range is refused", not wrote)

	local axis = pcall(Serdes.fromSchema(placed).write, Vector3.new(0, 4096, 0))
	Buffer.load(nil)

	check("and it is refused per axis, not only on the first", not axis)
end

do
	--[[
		The spelling the docstring recommends for a direction: three bytes where the bare one is
		twelve.

		**A quantised direction does not land on the unit sphere**, so the length check widens by
		`sqrt(3)` half-steps — derived from the step rather than guessed. Without that the compact
		spelling would be refused by its own reader on most values, which is the failure this
		assertion exists to catch: the round trip is what says the tolerance is wide enough, and the
		hostile case below is what says it is not too wide.
	]]
	local compact = t.unitVector3(t.quantized(-1, 1, 2 / 254))
	local direction = Vector3.new(1, 2, 3).Unit
	local value, failure, size = roundTrip(compact, direction)

	equals("a quantised direction is three bytes", size, 3)
	equals("and decodes", failure, nil)
	check(`and stays a direction: {tostring(value)}`, (value - direction).Magnitude < 0.02)

	--[[ Still a unit vector, still enforced. 254 levels over -1..1 puts every axis at its top, which
	     is a magnitude of sqrt(3) — well outside anything `sqrt(3)` half-steps can excuse. ]]
	local hostile = buffer.create(3)
	buffer.writeu8(hostile, 0, 254)
	buffer.writeu8(hostile, 1, 254)
	buffer.writeu8(hostile, 2, 254)

	rejects("a quantised direction with a magnitude of sqrt(3)", compact, hostile)
end

-- ---------------------------------------------------------------------------------------------
-- Colours
-- ---------------------------------------------------------------------------------------------

do
	local value, failure, size = roundTrip(t.color3, Color3.fromRGB(200, 100, 50))
	equals("color3 is three bytes", size, 3)
	equals("color3 decodes", failure, nil)
	equals("color3 round trips exactly", value, Color3.fromRGB(200, 100, 50))
end

do
	--[[ Eight bits per channel is the wire format, so a colour that was never an integer comes back
	     rounded. Recorded as a test rather than left to be discovered. ]]
	local value = roundTrip(t.color3, Color3.new(0.5, 0.5, 0.5))
	check("a fractional colour rounds to the nearest 1/255", math.abs(value.R - 0.5) < 1 / 255)
end

-- ---------------------------------------------------------------------------------------------
-- CFrames
-- ---------------------------------------------------------------------------------------------

local function cframesMatch(a: CFrame, b: CFrame): boolean
	if (a.Position - b.Position).Magnitude > 1e-3 then
		return false
	end

	return (a.LookVector - b.LookVector).Magnitude < 1e-3
		and (a.UpVector - b.UpVector).Magnitude < 1e-3
		and (a.RightVector - b.RightVector).Magnitude < 1e-3
end

do
	local value, failure, size = roundTrip(t.cframe, CFrame.identity)
	equals("cframe is twenty-four bytes", size, 24)
	equals("the identity decodes", failure, nil)
	check("the identity round trips", cframesMatch(value, CFrame.identity))
end

do
	--[[ Position and rotation are carried separately, so a translation with no rotation is the case
	     where the axis-angle vector is zero and the reconstruction has to not divide by it. ]]
	local translated = CFrame.new(10, -20, 30)
	local value = roundTrip(t.cframe, translated)
	check("a translation round trips", cframesMatch(value, translated))
end

do
	local rotated = CFrame.new(1, 2, 3) * CFrame.Angles(0.4, -1.2, 2.9)
	local value = roundTrip(t.cframe, rotated)
	check("a rotation round trips", cframesMatch(value, rotated))
end

do
	--[[ Near-π is where an axis-angle encoding loses precision, so it is the case worth pinning
	     rather than the comfortable middle of the range. ]]
	local extreme = CFrame.fromAxisAngle(Vector3.new(0, 1, 0), math.pi - 1e-3)
	local value = roundTrip(t.cframe, extreme)
	check("a rotation near pi round trips", cframesMatch(value, extreme))
end

do
	local hostile = buffer.create(24)
	buffer.writef32(hostile, 0, 0 / 0)
	rejects("a cframe carrying NaN", t.cframe, hostile)
end

--[[
	The compact cframe (`PLAN-M5` phase 5): the position as three of the component, the rotation as
	a quaternion with its largest component dropped — three `i16` and a two-bit index. Thirteen
	bytes for a narrowed position against twenty-four, and a rotation within 5e-5 radians of what
	was sent, which the tolerance in `cframesMatch` is well above.
]]
do
	local posed = t.cframe(t.i16(-2048, 2048))

	local value, failure, size = roundTrip(posed, CFrame.identity)
	equals("a compact cframe is thirteen bytes", size, 13)
	equals("the identity decodes", failure, nil)
	check("and round trips", cframesMatch(value, CFrame.identity))

	local translated = roundTrip(posed, CFrame.new(10, -20, 30))
	check("a translation round trips", cframesMatch(translated, CFrame.new(10, -20, 30)))

	local rotated = CFrame.new(1, 2, 3) * CFrame.Angles(0.4, -1.2, 2.9)
	check("a rotation round trips", cframesMatch(roundTrip(posed, rotated), rotated))

	local extreme = CFrame.fromAxisAngle(Vector3.new(0, 1, 0), math.pi - 1e-3)
	check("a rotation near pi round trips", cframesMatch(roundTrip(posed, extreme), extreme))

	--[[ Every axis as the largest component, so all four index values are exercised. ]]
	for _, axis in { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis } do
		local quarter = CFrame.fromAxisAngle(axis, math.pi / 2)
		check(`a quarter turn about {axis} round trips`, cframesMatch(roundTrip(posed, quarter), quarter))
		local most = CFrame.fromAxisAngle(axis, 3)
		check(`and a wide turn about {axis}`, cframesMatch(roundTrip(posed, most), most))
	end

	--[[ Off the map is refused like a vector's position. ]]
	local far = buffer.create(13)
	buffer.writeu16(far, 1, 65535)
	rejects("a compact cframe off the map", posed, far)

	--[[ Three kept components whose squares sum past 3/4 were never a rotation: the component that
	     was dropped is the largest, so it is at least 1/2 and these three carry at most 3/4. Both
	     the gross case and one just over the bound, because the reader was written against 1 and
	     the spike measured the true limit (`spike/additions/f_quaternion.luau`). ]]
	local function bentBy(component: number): buffer
		local bent = buffer.create(13)
		buffer.writeu16(bent, 1, 2048)
		buffer.writeu16(bent, 3, 2048)
		buffer.writeu16(bent, 5, 2048)
		buffer.writei16(bent, 7, component)
		buffer.writei16(bent, 9, component)
		buffer.writei16(bent, 11, component)
		return bent
	end

	rejects("a compact cframe whose rotation is not a unit quaternion", posed, bentBy(32767))

	--[[ Each component sqrt(0.3), so the sum is 0.9: inside the old bound of 1, outside the real
	     one. 0.5477 * 32767 * sqrt(2) = 25383. ]]
	rejects("and one whose dropped component was not the largest", posed, bentBy(25383))

	--[[ The bound itself has to stay reachable: all four components 1/2 is a legal rotation whose
	     sum is exactly 3/4, and 0.5 * 32767 * sqrt(2) = 23170. ]]
	local onTheBound = buffer.create(13)
	buffer.writeu16(onTheBound, 1, 2048)
	buffer.writeu16(onTheBound, 3, 2048)
	buffer.writeu16(onTheBound, 5, 2048)
	buffer.writei16(onTheBound, 7, 23170)
	buffer.writei16(onTheBound, 9, 23170)
	buffer.writei16(onTheBound, 11, 23170)

	local _, atBound = decode(Serdes.fromSchema(posed), onTheBound, {})
	equals("while a rotation whose four components are all 1/2 is accepted", atBound, nil)

	--[[ And the float spelling, for a position with no map. ]]
	local _, _, floatSize = roundTrip(t.cframe(t.f32), rotated)
	equals("a float-positioned compact cframe is nineteen bytes", floatSize, 19)
	check("and round trips the same", cframesMatch(roundTrip(t.cframe(t.f32), rotated), rotated))
end

-- ---------------------------------------------------------------------------------------------
-- Instances
-- ---------------------------------------------------------------------------------------------

do
	local part = Instance.new("Part")
	local sound = Instance.new("Sound")

	local value, failure, size = roundTrip(t.struct({ a = t.instance, b = t.instance }), {
		a = part,
		b = sound,
	})

	equals("instances take no buffer bytes", size, 0)
	equals("instances decode", failure, nil)
	check("the first instance survives", value.a == part)
	check("the second instance survives", value.b == sound)

	part:Destroy()
	sound:Destroy()
end

do
	--[[
		A client can reference any instance it can see, so `t.instance("Sound")` is checked here or
		it is not checked at all. This is the case no surveyed library covers: they all confirm the
		reference is an Instance and stop.
	]]
	local part = Instance.new("Part")

	rejects("an instance of the wrong class", t.instance("Sound"), buffer.create(0), { part })

	--[[ The exact shape of the old double: a table answering `:IsA`. Under lune that *is* an
	     instance, which is why this case can only live here. ]]
	local impostor: any = {
		IsA = function()
			return true
		end,
	}
	rejects("a table answering IsA in the sidecar", t.instance("Part"), buffer.create(0), { impostor })
	rejects("and a bare table", t.instance("Part"), buffer.create(0), { {} :: any })

	--[[ And on the way out. The writer asked only "is it an Instance", so `nw.validate` branded a
	     part as a `Sound` and the reader refused the same bytes (M4 report, finding 23; M4-1). ]]
	local outgoing = Serdes.fromSchema(t.instance("Sound"))
	local wrote = pcall(outgoing.write, part)
	Buffer.take()
	check("and the writer refuses it too, so nw.validate cannot brand it", not wrote)

	local sound = Instance.new("Sound")
	local value, failure = roundTrip(t.instance("Sound"), sound, { sound })
	equals("an instance of the right class decodes", failure, nil)
	check("and survives", value == sound)

	--[[ A subclass satisfies its parent class, because `IsA` is what the schema means. ]]
	local mesh = Instance.new("MeshPart")
	local base, baseFailure = roundTrip(t.instance("BasePart"), mesh, { mesh })
	equals("a subclass satisfies its parent class", baseFailure, nil)
	check("and survives", base == mesh)

	part:Destroy()
	sound:Destroy()
	mesh:Destroy()
end

do
	--[[ The sidecar is attacker-influenced too: fewer instances than the schema declares must not
	     hand a handler a nil where it declared an Instance. ]]
	rejects("a missing instance", t.instance, buffer.create(0), {})
end

do
	--[[
		**Where it came from, not only what it is** (M4 phase 8).

		A class says *what* a client handed over and nothing about where it got it: the sidecar
		admits anything the sender can reference — a `BasePart` out of its own `PlayerGui`, a `Model`
		a script parented into `ReplicatedStorage` a frame ago. `descendantOf` is the container
		check, and it takes the container itself because a game declares its schema at startup, when
		`workspace` exists, and resolving a path per packet would be a tree walk on the receive path.

		`tests/types_runtime.luau` has the declaration refusals; this is the half that needs a tree.
	]]
	local holder = Instance.new("Folder")
	holder.Parent = workspace

	local inside = Instance.new("Part")
	inside.Parent = holder

	local outside = Instance.new("Part")
	outside.Parent = ReplicatedStorage

	local contained = t.instance("BasePart", { descendantOf = workspace })

	local value, failure = roundTrip(contained, inside, { inside })

	equals("a part inside the container decodes", failure, nil)
	check("and survives", value == inside)

	rejects("one of the right class from somewhere else", contained, buffer.create(0), { outside })

	local outgoing = Serdes.fromSchema(contained)
	local wrote = pcall(outgoing.write, outside)
	Buffer.take()
	check("and the writer refuses it on the way out as well", not wrote)

	--[[ A nested descendant, not only a direct child: `IsDescendantOf` is the question, and a game
	     that meant "child of" would be asking a different one. ]]
	local deep = Instance.new("Part")
	deep.Parent = holder

	local nested = Instance.new("Folder")
	nested.Parent = holder
	deep.Parent = nested

	local reached, deepFailure = roundTrip(contained, deep, { deep })

	equals("a part nested deeper still decodes", deepFailure, nil)
	check("and survives", reached == deep)

	--[[ The control: without a container the same instance from outside is accepted, so the refusal
	     above is the container check rather than something else refusing it. ]]
	local loose, looseFailure = roundTrip(t.instance("BasePart"), outside, { outside })

	equals("without a container it is accepted", looseFailure, nil)
	check("and survives", loose == outside)

	outside:Destroy()
	holder:Destroy()
end

do
	--[[ `t.player` is `t.instance("Player")` with the payload type Luau cannot get from a class
	     name. What Studio can check is the runtime half: a Player passes, and anything else does
	     not. ]]
	if player then
		local value, failure = roundTrip(t.player, player, { player })

		equals("a player decodes", failure, nil)
		check("and survives", value == player)
	end

	local part = Instance.new("Part")
	rejects("something that is not a player", t.player, buffer.create(0), { part })
	part:Destroy()
end

-- ---------------------------------------------------------------------------------------------
-- The datatypes in a schema together
-- ---------------------------------------------------------------------------------------------

do
	--[[ Datatypes carry no flags, so this is really a check that they do not disturb the bitfield
	     that surrounds them. ]]
	local shot = t.struct({
		origin = t.vector3,
		direction = t.unitVector3,
		muzzle = t.optional(t.instance),
		tracer = t.color3,
		charged = t.boolean,
		seq = t.u16,
	})

	local emitter = Instance.new("Attachment")

	local value, failure = roundTrip(shot, {
		origin = Vector3.new(4, 5, 6),
		direction = Vector3.new(0, 0, -1),
		muzzle = emitter,
		tracer = Color3.fromRGB(255, 0, 0),
		charged = true,
		seq = 4321,
	})

	equals("a mixed schema decodes", failure, nil)
	equals("its vector survives", value.origin, Vector3.new(4, 5, 6))
	equals("its colour survives", value.tracer, Color3.fromRGB(255, 0, 0))
	equals("its flag survives", value.charged, true)
	equals("its number survives", value.seq, 4321)
	check("its instance survives", value.muzzle == emitter)

	local absent = roundTrip(shot, {
		origin = Vector3.zero,
		direction = Vector3.zAxis,
		muzzle = nil,
		tracer = Color3.new(),
		charged = false,
		seq = 0,
	}, {})

	equals("an absent optional instance stays absent", absent.muzzle, nil)
	equals("and the flags beside it are unaffected", absent.charged, false)

	emitter:Destroy()
end

-- ---------------------------------------------------------------------------------------------
-- The roster, against the real Players service
-- ---------------------------------------------------------------------------------------------

do
	local roster = Recipients.roblox()

	--[[
		`owner` used to hand whatever it was given straight to `GetPlayerFromCharacter` behind a
		`:: Model` cast, so a `BasePart` or a `Folder` subject — which is what a game publishing
		from a projectile or a door passes — reached a reflected parameter typed `Model`. Whether
		Roblox raises on that was never established; the check above makes it not matter, and this
		is where the answer would show up if it ever did.
	]]
	local part = Instance.new("Part")
	local folder = Instance.new("Folder")
	local model = Instance.new("Model")

	equals("a part has no owner", roster.owner(part), nil)
	equals("nor does a folder", roster.owner(folder), nil)
	equals("nor does a model nobody is playing", roster.owner(model), nil)
	equals("nor does a value that is not an Instance at all", roster.owner(12345), nil)

	--[[ And the one that does resolve: a player is their own owner, which is the case
	     `nw.audience.owner` takes on a `command`'s `ctx.player`. Said when it cannot run: a probe
	     that did not run and printed OK is the opposite of §9's "a probe that finds nothing is
	     written down" (M4-1). ]]
	if player then
		equals("a player owns themselves", roster.owner(player), player)
		check("and the roster lists them", table.find(roster.all(), player) ~= nil)

		--[[ `within` measures the list it is handed, not the engine's: it used to call
		     `GetPlayers()` itself once per subject per publish when the tick had already taken
		     the roster for the frame (SECURITY-REPORT-M4 77; `PLAN-M5` phase 4). Handed the frame's
		     list it finds the player; handed an empty one it finds nobody — which is what shows the
		     list is the one being read. Needs a character to measure from; said when there is none. ]]
		--[[ The character spawns a moment after the player, and the suite reaches here first —
		     measured: a skip on every run without the wait. ]]
		local character = player.Character
		local characterDeadline = os.clock() + 10

		while (character == nil or character.PrimaryPart == nil) and os.clock() < characterDeadline do
			task.wait(0.1)
			character = player.Character
		end

		local root = character and character.PrimaryPart

		if root then
			local out = {}
			equals(
				"within finds the player from the frame's list",
				roster.within(root, 1e6, out, roster.all()),
				1
			)
			equals("and names them", out[1], player)
			equals("and finds nobody in an empty list", roster.within(root, 1e6, out, {}), 0)

			--[[
				What one player costs per subject, against the real engine (`PLAN-M5` phase 5).
				`within` reads a player's position once per list rather than once per subject, and
				`Recipients.of` answers membership from the list rather than asking `has` — three
				engine calls — per recipient. Both are timed over the same list the tick would hand
				every subject of a frame. A number, not an assertion: the lune half is `bench/tick`'s
				`nearby-all` and `select-all` rungs, and this is the half a stub cannot show.
			]]
			local CALLS = 20000
			local list = roster.all()
			local chosen = {
				kind = "select",
				select = function()
					return list
				end,
			}

			local started = os.clock()
			for _ = 1, CALLS do
				roster.within(root, 1e6, out, list)
			end
			local withinNs = (os.clock() - started) * 1e9 / CALLS

			started = os.clock()
			for _ = 1, CALLS do
				Recipients.of(chosen, root, roster, out, nil, list)
			end
			local selectNs = (os.clock() - started) * 1e9 / CALLS

			print(
				`        measured: with {#list} player(s) and the frame's list, within {string.format(
					"%.0f",
					withinNs
				)} ns a subject, `
					.. `a select returning the roster {string.format("%.0f", selectNs)} ns a subject ({CALLS} calls each)`
			)
		else
			print("        skip: the player has no character yet, so within was not asserted")
		end
	end

	part:Destroy()
	folder:Destroy()
	model:Destroy()
end

-- ---------------------------------------------------------------------------------------------
-- The other end of the wire (PLAN-M4-BUG phase 6)
-- ---------------------------------------------------------------------------------------------

--[[
	Everything below needs a client, and the suite has none: it runs on the server, from
	`run.server.luau`. `tests/puppet.client.luau` is the client — a script that waits for the
	`NETWEAVE_PUPPET` remote this section creates, obeys it, and echoes what it sees on the netweave
	remotes and on a probe remote of its own. The sections ask it questions the server cannot answer
	alone: did the batch arrive, at how many bytes, with how many instances, and does Roblox really
	drop an unreliable payload at 908.
]]

local PUPPET_TIMEOUT = 10

local puppet = Instance.new("RemoteEvent")
puppet.Name = "NETWEAVE_PUPPET"

local probe = Instance.new("UnreliableRemoteEvent")
probe.Name = "NETWEAVE_PUPPET_UNRELIABLE"

--[[ Everything the puppet says, in order, each as the argument list it was fired with. ]]
local said: { { any } } = {}

puppet.OnServerEvent:Connect(function(_who: Player, ...: any)
	table.insert(said, { ... })
end)

puppet.Parent = ReplicatedStorage
probe.Parent = ReplicatedStorage

--[[ Waits for a line of the puppet's that the predicate accepts, and hands it back; nil when
     nothing acceptable arrives in time. Lines are consumed from a cursor so a section cannot read
     an earlier section's answer as its own. ]]
local cursor = 0

local function hear(seconds: number, accept: ({ any }) -> boolean): { any }?
	local deadline = os.clock() + seconds

	while os.clock() < deadline do
		while cursor < #said do
			cursor += 1

			if accept(said[cursor]) then
				return said[cursor]
			end
		end

		task.wait(0.05)
	end

	return nil
end

local function heard(seconds: number, first: any): { any }?
	return hear(seconds, function(line)
		return line[1] == first
	end)
end

local function frames(count: number)
	for _ = 1, count do
		RunService.PostSimulation:Wait()
	end
end

local ready = if player then heard(PUPPET_TIMEOUT, "ready") ~= nil else false

--[[ Narrowed once: `player` is optional and the `ready` guard above does not narrow it. ]]
local client = player :: Player

if player and not ready then
	print(
		`        skip: the puppet client did not answer within {PUPPET_TIMEOUT} s; the wire sections were not asserted`
	)
end

-- ---------------------------------------------------------------------------------------------
-- Link.roblox, against the real remotes
-- ---------------------------------------------------------------------------------------------

do
	--[[ Requiring netweave inside Roblox installed the transport, and the link it built created the
	     remotes. Both are facts about `Driver.install` that lune can never see. ]]
	check("requiring netweave in Roblox installs the transport", Transport.installed())

	local folder = ReplicatedStorage:FindFirstChild("NETWEAVE")
	check("and creates the remote folder", folder ~= nil)

	if folder then
		local reliable = folder:FindFirstChild("NETWEAVE_RELIABLE")
		local unreliable = folder:FindFirstChild("NETWEAVE_UNRELIABLE")

		check("with a RemoteEvent for reliable traffic", reliable ~= nil and reliable:IsA("RemoteEvent"))
		check(
			"and an UnreliableRemoteEvent for the rest",
			unreliable ~= nil and unreliable:IsA("UnreliableRemoteEvent")
		)
		equals("and nothing else", #folder:GetChildren(), 2)

		--[[ A second link finds the remotes it already made rather than making two more, which is
		     what lets this section build one of its own beside the driver's. ]]
		local again = Link.roblox()
		equals("a second Link.roblox reuses the remotes", #folder:GetChildren(), 2)

		if ready then
			puppet:FireClient(client, "arm")
			local armed = heard(PUPPET_TIMEOUT, "armed")
			check("the puppet found the netweave remotes", armed ~= nil and armed[2] == true)

			--[[ Five bytes, reliable, to the player: the puppet reports the remote it came on, the
			     length, and how many instances the sidecar delivered. ]]
			again.send(true, player, buffer.create(5), {})
			local first = heard(2, "netweave")
			check("a reliable send reaches the client", first ~= nil)
			if first then
				equals("on the reliable remote", first[2], true)
				equals("at its length", first[3], 5)
				equals("with an empty sidecar", first[4], 0)
			end

			again.send(false, player, buffer.create(7), {})
			local second = heard(2, "netweave")
			check("an unreliable send reaches the client", second ~= nil)
			if second then
				equals("on the unreliable remote", second[2], false)
				equals("at its length", second[3], 7)
			end

			again.sendAll(true, buffer.create(6), {})
			local third = heard(2, "netweave")
			check("sendAll reaches the client", third ~= nil)
			if third then
				equals("at its length", third[3], 6)
			end

			--[[
				The sidecar, on a real remote. An instance the client can see arrives; one it cannot
				— unparented, so never replicated — arrives as **nil**, and the sidecar the client
				reads is shorter than the one the server wrote. That is the case the reader's
				"a missing instance" refusal above exists for, and this is the only place it can be
				shown to happen.
			]]
			local visible = Instance.new("Part")
			visible.Parent = workspace

			again.send(true, player, buffer.create(1), { visible })
			local carried = heard(2, "netweave")
			check("a visible instance survives the sidecar", carried ~= nil and carried[4] == 1)

			local hidden = Instance.new("Part")

			again.send(true, player, buffer.create(1), { hidden })
			local dropped = heard(2, "netweave")
			check("an instance the client cannot see arrives as nil", dropped ~= nil and dropped[4] == 0)

			visible:Destroy()
			hidden:Destroy()

			--[[
				And the way in. `Link.roblox`'s receive drops what is not a buffer before the decoder
				sees it and normalises a sidecar that is not a table; what is a buffer is handed on,
				to this section's own handler and to the driver's — whose `Inbound` refuses it and
				reports the sender by name, without raising, which is G4 on a real remote.
			]]
			local arrived: { { any } } = {}

			again.receive(function(packed: buffer, instances: { unknown }, sender: any?)
				table.insert(arrived, { buffer.len(packed), instances, sender })
			end)

			local refusals: { Observer.Rejection } = {}
			local stop = Observer.observe(function(rejection)
				table.insert(refusals, rejection)
			end)

			puppet:FireClient(client, "junk")
			local junked = heard(PUPPET_TIMEOUT, "junked")
			check("the puppet sent its junk", junked ~= nil and junked[2] == true)

			task.wait(0.5)
			stop()

			equals("a string is dropped before any handler; two buffers are handed on", #arrived, 2)

			for _, line in arrived do
				equals("each at its length", line[1], 3)
				check("with a sidecar that is a table", type(line[2]) == "table")
				check("and the sender is the player", line[3] == player)
			end

			check("the driver refused what it was handed", #refusals >= 1)
			check("and named the sender", #refusals >= 1 and refusals[1].player == player)

			puppet:FireClient(client, "disarm")
			heard(PUPPET_TIMEOUT, "disarmed")
		end
	end
end

-- ---------------------------------------------------------------------------------------------
-- The 908 limit, measured
-- ---------------------------------------------------------------------------------------------

--[[
	`Outbound` refuses an unreliable payload over 908 bytes because Roblox drops one silently, and
	`DESIGN-API.md` §9 records that Roblox's own page says 1000 while the devforum measured 908. Neither
	number had been measured by this repository. The first half sends raw buffers of several sizes over
	an `UnreliableRemoteEvent` and records which arrive; the second sends through netweave and asserts
	the refusal happens at the send, with a report, rather than on the wire, in silence.
]]

if ready then
	--[[ Past the two documented figures and well past them, because the first pass delivered every
	     size up to 1100 and the question became whether Studio's loopback drops at all. ]]
	local SIZES = { 900, 908, 909, 950, 1000, 1001, 1100, 2000, 4000, 16000, 65536 }
	local REPEATS = 3
	local arrivedAt: { [number]: number } = {}

	for _, size in SIZES do
		arrivedAt[size] = 0

		for _ = 1, REPEATS do
			probe:FireClient(client, buffer.create(size), {})
			task.wait()
		end
	end

	task.wait(1)

	while true do
		local line = heard(0.2, "got")

		if not line then
			break
		end

		local size = line[2]

		if arrivedAt[size] then
			arrivedAt[size] += 1
		end
	end

	local largestDelivered = 0
	local smallestDropped = math.huge
	local report = {}

	for _, size in SIZES do
		table.insert(report, `{size}:{arrivedAt[size]}/{REPEATS}`)

		if arrivedAt[size] > 0 then
			largestDelivered = math.max(largestDelivered, size)
		else
			smallestDropped = math.min(smallestDropped, size)
		end
	end

	print(`        unreliable payloads delivered, bytes:arrived — {table.concat(report, " ")}`)
	print(
		`        largest delivered {largestDelivered}, smallest dropped `
			.. `{if smallestDropped == math.huge then "none" else smallestDropped}`
	)

	--[[ The ceiling netweave enforces has to be deliverable, or every packet at the limit is lost
	     while the library says nothing. What Roblox does above it is recorded, not asserted: the
	     documented figure and the measured one disagree and this is the measurement. ]]
	equals("a payload at netweave's 908-byte ceiling is delivered every time", arrivedAt[908], REPEATS)

	--[[ And the sidecar's overhead, which `Outbound` says the number does not model: 908 bytes with
	     one visible instance beside them. ]]
	local visible = Instance.new("Part")
	visible.Parent = workspace

	for _ = 1, REPEATS do
		probe:FireClient(client, buffer.create(908), { visible })
		task.wait()
	end

	task.wait(0.5)

	local withInstance = 0

	while true do
		local line = heard(0.2, "got")

		if not line then
			break
		end

		if line[2] == 908 and line[3] == 1 then
			withInstance += 1
		end
	end

	print(`        908 bytes plus one instance in the sidecar: {withInstance}/{REPEATS} delivered`)
	visible:Destroy()
end

-- ---------------------------------------------------------------------------------------------
-- Driver: a declaration to a client, through the real transport, and again after a reset
-- ---------------------------------------------------------------------------------------------

--[[
	Every other test that sends installs a loopback in place of the driver, so until this section
	nothing had ever gone from `nw.event` to a `RemoteEvent` under assertion. The reset half is the
	regression: the driver kept its own "sealed" flag, and `Namespace.reset()` — which every test file
	calls — left it believing a protocol that no longer existed was still agreed, so a namespace
	declared after a real send was never numbered. Confirmed to fail before the fix by running this
	section in Studio (PLAN-M4-BUG phase 6).
]]

if ready then
	local refusals: { Observer.Rejection } = {}
	local stop = Observer.observe(function(rejection)
		table.insert(refusals, rejection)
	end)

	Namespace.reset()

	--[[ A policy with a server stage (PLAN-M5 D-5): the real driver runs it at the seal its first
	     send triggers, before that packet is written, and once for the two channels it is on. ]]
	local staged = 0
	local stagedPolicy = nw.policy(function()
		return function()
			return nw.allow()
		end, function()
			staged += 1
		end
	end)

	local studio = nw.namespace("studio", {
		hello = nw.event({ data = t.u8, audience = nw.audience.owner }),
		wide = nw.event({ data = t.array(t.u8), audience = nw.audience.owner, unreliable = true }),
		buy = nw.command({ data = t.u8, rate = 1, authorize = stagedPolicy }),
		sell = nw.command({ data = t.u8, rate = 1, authorize = stagedPolicy }),
	})

	puppet:FireClient(client, "arm")
	heard(PUPPET_TIMEOUT, "armed")

	equals("a server stage has not run before the first send", staged, 0)
	studio.server.hello:publish(player, 7)
	equals("the first send sealed and ran it, once for two channels", staged, 1)
	frames(2)

	local batch = heard(2, "netweave")
	check("a publish through the real driver reaches the client", batch ~= nil)

	local declared = Namespace.get("studio")
	local helloId = if declared then declared.channels.hello.id else nil

	if batch then
		equals("on the reliable remote", batch[2], true)
		check(`as a batch of {batch[3]} bytes`, batch[3] >= 2 and batch[3] <= 8)
		equals("starting with the version byte", batch[5], 1)
		equals("then the channel's wire id", batch[6], helloId)
		check("which is not the reserved control id", helloId ~= 0)
	end

	--[[ Under the ceiling: a batch on the unreliable remote, longer than its payload by the
	     envelope and shorter than the limit. Over it: refused at the send, reported at the `send`
	     stage with the size in the reason, and nothing on the wire. ]]
	studio.server.wide:publish(player, table.create(880, 1))
	frames(2)

	local fits = heard(2, "netweave")
	check("an unreliable payload under the ceiling arrives", fits ~= nil and fits[2] == false)

	if fits then
		check(`between its payload and the ceiling: {fits[3]} bytes`, fits[3] >= 880 and fits[3] <= 908)
	end

	local before = #refusals

	studio.server.wide:publish(player, table.create(1200, 1))
	frames(2)

	equals("an unreliable payload over the ceiling is reported", #refusals, before + 1)

	local last = refusals[#refusals]

	if #refusals > before then
		equals("at the send stage", last.stage, "send")
		check("naming the limit", string.find(last.reason, "908 byte limit", 1, true) ~= nil)
		equals("on the channel", last.channel, "studio.wide")
	end

	check("and nothing reached the client", heard(0.5, "netweave") == nil)

	--[[ The reset. A test file's tear-down, and the driver has to survive it. ]]
	Namespace.reset()

	local later = nw.namespace("later", {
		hello = nw.event({ data = t.u16, audience = nw.audience.owner }),
	})

	local sent = pcall(function()
		later.server.hello:publish(player, 300)
	end)

	check("a namespace declared after a reset can publish", sent)
	frames(2)

	--[[ The bytes arriving is not the assertion — they arrived before the fix too. What the old
	     driver sent was the packet under channel id **0**, the reserved control id, because nothing
	     had numbered the new declaration; a real client would have read it as a malformed hello.
	     The id is the observable. ]]
	local numbered = Namespace.get("later")
	local id = if numbered then numbered.channels.hello.id else nil
	local afterReset = heard(2, "netweave")

	check("and its batch reaches the client", afterReset ~= nil)

	if afterReset then
		check(
			`carrying the id the new declaration was given, {tostring(id)}, not 0: got {afterReset[6]}`,
			afterReset[6] == id and id ~= 0
		)
	end

	stop()
	puppet:FireClient(client, "disarm")
	heard(PUPPET_TIMEOUT, "disarmed")

	Namespace.reset()
	Observer.reset()
end

-- ---------------------------------------------------------------------------------------------
-- Context.acquire on a real Player
-- ---------------------------------------------------------------------------------------------

--[[
	`tests/api_runtime.luau` runs the context against a table with a `Character` field, and says so.
	What only a real `Player` can show is that `character` and `humanoid` are found through the
	real properties, that the guard is on in Studio, and that a real player's record is dropped by
	`forget` the way `Players.PlayerRemoving` calls it.
]]

if player then
	local character = (player :: any).Character
	local ctx: any = Context.acquire(player, "studio.hello")

	check("the guard is on in Studio", Context.guarded())
	check("ctx.player is the real player", ctx.player == player)
	check("ctx.character is what the player has right now", ctx.character == character)
	check(
		"and the humanoid is found through it",
		ctx.humanoid == (if character then character:FindFirstChildOfClass("Humanoid") else nil)
	)

	if character then
		print("        the player had a character; the humanoid path was asserted")
	else
		print("        the player had no character; both fields were asserted nil")
	end

	check("a write to ctx.player is refused by the guard", not (pcall(function()
		ctx.player = "impostor"
	end)))

	Context.release(player)

	check("the released ctx is refused", not (pcall(function()
		return ctx.player
	end)))

	local detached: any = Context.detached(player, "studio.hello")
	check("a detached context carries the same player", detached.player == player)
	check("and finds the same character", detached.character == character)

	Context.forget(player)

	local fresh: any = Context.acquire(player, "studio.hello")
	check("after forget, a new acquisition still works", fresh.player == player)
	Context.release(player)
	Context.forget(player)
end

-- ---------------------------------------------------------------------------------------------
-- A namespace declared where the client cannot require it (PLAN-M5 D-7)
-- ---------------------------------------------------------------------------------------------

--[[
	`tests/api_runtime.luau` proves the guard against a source it hands in. What only Studio can say is
	that `debug.info(2, "s")` inside `nw.namespace` really is the declaring module's full name, with
	the prefix the guard looks for: `tests/serveronly/declares.luau` is mapped a second time under
	`ServerScriptService` by both place files and declares a namespace when called. The namespaces
	this file and the rest of the suite declare from `ReplicatedStorage` are the other direction.
]]

do
	local ServerScriptService = game:GetService("ServerScriptService")
	local folder = ServerScriptService:FindFirstChild("netweaveServerOnly")
	local declares = if folder then folder:FindFirstChild("declares") else nil

	if declares then
		Namespace.reset()

		local ok, err = pcall(function()
			(require :: any)(declares)(nw, t)
		end)

		check("a namespace declared from ServerScriptService is refused", not ok)
		check(
			"with ReplicatedStorage named as the fix",
			not ok and string.find(tostring(err), "ReplicatedStorage", 1, true) ~= nil
		)
		check(
			`and the module named as the cause: {tostring(err)}`,
			not ok
				and string.find(tostring(err), "ServerScriptService.netweaveServerOnly.declares", 1, true)
					~= nil
		)
		check("and nothing was declared", Namespace.get("serverOnly") == nil)

		Namespace.reset()
	else
		print("        skip: ServerScriptService.netweaveServerOnly is not mapped in this place")
	end
end

puppet:Destroy()
probe:Destroy()

-- ---------------------------------------------------------------------------------------------

if failures > 0 then
	error(`{failures} roblox assertions failed`)
end

print("OK      roblox_runtime")

return true
