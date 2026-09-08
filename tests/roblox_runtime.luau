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

local Buffer = require("../src/codec/Buffer")
local Recipients = require("../src/transport/Recipients")
local Serdes = require("../src/codec/Serdes")
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

local function decode(codec: Serdes.Codec, bytes: buffer, instances: { Instance }?): (any, string?)
	Buffer.beginRead(bytes, instances)
	return codec.read()
end

--[[ Round trips one value and hands the result back, so each datatype can compare it its own way:
     `CFrame` needs a tolerance, `Color3` does not. ]]
local function roundTrip(descriptor: any, value: any, instances: { Instance }?): (any, string?, number)
	local codec = Serdes.fromSchema(descriptor)
	local packed, sidecar = encode(codec, value)
	local decoded, failure = decode(codec, packed, instances or sidecar)
	return decoded, failure, buffer.len(packed)
end

local function rejects(name: string, descriptor: any, bytes: buffer, instances: { Instance }?)
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
	local players = Players:GetPlayers()

	if #players > 0 then
		local value, failure = roundTrip(t.player, players[1], { players[1] })

		equals("a player decodes", failure, nil)
		check("and survives", value == players[1])
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
	     `nw.audience.owner` takes on a `command`'s `ctx.player`. ]]
	local players = roster.all()

	--[[ Said when it cannot run. A server-only Play has no player, and a probe that did not run and
	     printed OK is the opposite of §9's "a probe that finds nothing is written down" (M4-1). ]]
	if #players > 0 then
		equals("a player owns themselves", roster.owner(players[1]), players[1])
	else
		print("        skip: no player in this Play, so `owner(player)` was not asserted")
	end

	part:Destroy()
	folder:Destroy()
	model:Destroy()
end

-- ---------------------------------------------------------------------------------------------

if failures > 0 then
	error(`{failures} roblox assertions failed`)
end

print("OK      roblox_runtime")

return true
