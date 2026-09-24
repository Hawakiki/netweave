--!strict

--[[
	The server half of the live probe. See `live/Net.luau`.

	Prints one line every five seconds:

		[live] 5s  players 2  ping 10 (0 refused)  hover 297 pkts (0 refused, newest slot 6)  whisper 10 sent
		[live]     markers 200 x 300 frames: publish loop 1.84 ms/frame  refusals by stage: {}

	And on every join and leave, the count of baselines the server holds afterwards is not visible
	from here — `Baseline` lives inside the driver — so what is printed instead is that the leave ran
	without an error line above it, and that a rejoining player gets the scores snapshot again.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local nw = require(ReplicatedStorage.netweave.src.netweave)
local Live = require(ReplicatedStorage.LiveNet)

local live = Live.ns
local scores = Live.scores

local MARKERS = 200
local REPORT_EVERY = 5

local pings = 0
local hovers = 0
local newestSlot = -1
local whispers = 0
local refusals: { [string]: number } = {}
local publishSeconds = 0
local frames = 0

local everWarned: { [string]: number } = {}

nw.observe(function(rejection)
	refusals[rejection.stage] = (refusals[rejection.stage] or 0) + 1
	everWarned[rejection.stage] = (everWarned[rejection.stage] or 0) + 1

	--[[ Anything that is not a budget refusal is worth a line of its own, the first three times
	     ever per stage — the first run printed a traceback per ping for a minute. ]]
	if rejection.stage ~= "budget" and everWarned[rejection.stage] <= 3 then
		warn(
			`[live] {rejection.channel} refused at {rejection.stage} from {tostring(rejection.player)}: {rejection.reason}`
		)
	end
end)

live.server.ping:listen(function(ctx, request)
	pings += 1
	local player = ctx.player :: Player
	live.server.whisper:publish(player, { seq = request.seq, to = player.UserId })
	whispers += 1
end)

live.server.hover:listen(function(_ctx, hover)
	hovers += 1
	newestSlot = hover.slot
end)

--[[ Two hundred parts in two rings — half within fifty studs of spawn and half well outside — so a
     player standing at spawn is near a hundred of them and far from the rest; each is a subject
     the `nearby` audience is evaluated against, every frame. The first solo run put all of them at
     radius 80 and measured the no-recipient path, which is not the number. ]]
local markers: { BasePart } = {}
local folder = Instance.new("Folder")
folder.Name = "LiveMarkers"
folder.Parent = workspace

for index = 1, MARKERS do
	local part = Instance.new("Part")
	local angle = (index / MARKERS) * math.pi * 4
	local radius = if index % 2 == 0 then 30 else 120
	part.Name = `Marker{index}`
	part.Anchored = true
	part.Size = Vector3.new(2, 2, 2)
	part.Position = Vector3.new(math.cos(angle) * radius, 5, math.sin(angle) * radius)
	part.Parent = folder
	markers[index] = part
end

--[[ The scores table moves ten subjects a frame, so every client holds a baseline per subject and
     receives ten small changes a frame. ]]
for subject = 1, 50 do
	scores[subject] = { kills = 0, deaths = 0, streak = 0 }
end

local tick = 0

RunService.PostSimulation:Connect(function()
	tick += 1
	frames += 1

	for offset = 0, 9 do
		local subject = ((tick + offset) % 50) + 1
		local score = scores[subject]
		score.kills = (score.kills + 1) % 65535
		score.streak = (score.streak + 1) % 255
	end

	local started = os.clock()

	for index, marker in markers do
		live.server.marker:publish(marker, { id = index, heat = tick % 255 })
		live.server.markerReliable:publish(marker, { id = index, heat = tick % 255 })
	end

	publishSeconds += os.clock() - started
end)

Players.PlayerAdded:Connect(function(player)
	print(`[live] joined: {player.Name} ({#Players:GetPlayers()} players)`)
end)

Players.PlayerRemoving:Connect(function(player)
	print(`[live] leaving: {player.Name}; the driver forgets their baselines, budget, context and queue now`)
end)

task.spawn(function()
	while true do
		task.wait(REPORT_EVERY)

		local stages = {}

		for stage, count in refusals do
			table.insert(stages, `{stage}={count}`)
		end

		table.sort(stages)

		print(
			`[live] {REPORT_EVERY}s  players {#Players:GetPlayers()}  ping {pings}  hover {hovers} pkts `
				.. `(newest slot {newestSlot})  whisper {whispers} sent`
		)
		print(
			`[live]     markers {MARKERS} x {frames} frames, unreliable and reliable: publish loop `
				.. `{string.format("%.2f", if frames > 0 then publishSeconds / frames * 1000 else 0)} ms/frame  `
				.. `refusals by stage: \{{table.concat(stages, ", ")}}`
		)

		pings, hovers, whispers = 0, 0, 0
		publishSeconds, frames = 0, 0
		table.clear(refusals)
	end
end)
