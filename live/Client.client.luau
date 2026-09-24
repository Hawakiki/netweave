--!strict

--[[
	The client half of the live probe. See `live/Net.luau`.

	Sends `hover` every RenderStepped against a rate of 30, which is the mistake the pacer exists for,
	and a `ping` once a second. Prints one line every five seconds:

		[live client] 5s  sent hover 300 (paced 150)  ping 5  got whisper 5 (all mine)  scores 50 subjects, 2500 changes  markers 1200  refused: {}

	`paced` is `nw.diagnostics().paced` for the hover channel: how many sends the client held back to
	the declared rate rather than putting on the wire.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local nw = require(ReplicatedStorage.netweave.src.netweave)
local Live = require(ReplicatedStorage.LiveNet)

local live = Live.ns
local me = Players.LocalPlayer

local REPORT_EVERY = 5

local hoverSent = 0
local pingSent = 0
local whispersMine = 0
local whispersOthers = 0
local scoreChanges = 0
local scoreSubjects: { [number]: boolean } = {}
local markerPackets = 0
local refusals: { [string]: number } = {}

nw.observe(function(rejection)
	refusals[rejection.stage] = (refusals[rejection.stage] or 0) + 1
end)

live.client.whisper:listen(function(whisper)
	if whisper.to == me.UserId then
		whispersMine += 1
	else
		whispersOthers += 1
	end
end)

live.client.scores:listen(function(subject, value)
	if value ~= nil then
		scoreChanges += 1
		scoreSubjects[subject] = true
	else
		scoreSubjects[subject] = nil
	end
end)

local markerReliablePackets = 0
local perSecond: { string } = {}
local secondUnreliable = 0
local secondReliable = 0

live.client.marker:listen(function(_marker)
	markerPackets += 1
	secondUnreliable += 1
end)

live.client.markerReliable:listen(function(_marker)
	markerReliablePackets += 1
	secondReliable += 1
end)

--[[ Per second, so a burst-and-silence pattern shows as one rather than averaging away. ]]
task.spawn(function()
	while true do
		task.wait(1)
		table.insert(perSecond, `{secondUnreliable}/{secondReliable}`)
		secondUnreliable, secondReliable = 0, 0
	end
end)

local frame = 0

RunService.RenderStepped:Connect(function()
	frame += 1
	hoverSent += 1
	live.client.hover:send({
		slot = frame % 8,
		x = math.sin(frame / 60) * 100,
		z = math.cos(frame / 60) * 100,
	})
end)

local seq = 0

task.spawn(function()
	while true do
		task.wait(1)
		seq += 1
		pingSent += 1
		live.client.ping:send({ seq = seq })
	end
end)

task.spawn(function()
	while true do
		task.wait(REPORT_EVERY)

		local paced = nw.diagnostics().paced["live.hover"] or 0
		local subjects = 0

		for _ in scoreSubjects do
			subjects += 1
		end

		local stages = {}

		for stage, count in refusals do
			table.insert(stages, `{stage}={count}`)
		end

		table.sort(stages)

		print(
			`[live client] {REPORT_EVERY}s  sent hover {hoverSent} (paced {paced} total)  ping {pingSent}  `
				.. `got whisper {whispersMine} mine, {whispersOthers} not mine  `
				.. `scores {subjects} subjects, {scoreChanges} changes  `
				.. `markers unreliable {markerPackets} / reliable {markerReliablePackets} `
				.. `(per second: {table.concat(perSecond, " ")})  `
				.. `refused: \{{table.concat(stages, ", ")}}`
		)

		hoverSent, pingSent, whispersMine, whispersOthers, scoreChanges = 0, 0, 0, 0, 0
		markerPackets, markerReliablePackets = 0, 0
		table.clear(perSecond)
		table.clear(refusals)
	end
end)
