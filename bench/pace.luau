--!strict
--!optimize 2

--[[
	What a client that sends an intent every frame costs, before and after the pacer.

		lune run bench/pace

	The BEFORE rung is the parent tree's behaviour reproduced on this one: every send pushed as it
	comes, and the server's token bucket deciding. The AFTER rung sends the same sixty a second
	through `Pacer`, which holds the newest value per channel and pushes at the declared rate through
	the same bucket. Both rungs feed what they push into a server-side `Budget.admit`, which is the
	server's decision, so the "refused" column is what `nw.observe` would have reported at `budget`.

	Three seconds at sixty sends a second against `rate = 30`, with a fresh bucket on both sides — so
	the first second includes the burst a fresh bucket admits, and the steady state is the two after.
	The numbers are deterministic under an injected clock, which is why there is no spread to print
	(`PLAN-M5` D-6, acceptance 9).
]]

local Budget = require("../src/transport/Budget")
local Channel = require("../src/api/Channel")
local Observer = require("../src/api/Observer")
local Pacer = require("../src/transport/Pacer")
local t = require("../src/types")

local RATE = 30
local FRAMES = 60
local SECONDS = 3

local hover = Channel.intent({ data = t.struct({ slot = t.u8 }), rate = RATE })

--[[ Through `any`: a channel record's fields are `read`, and this file stands in for the namespace
     that would have assigned them (`PLAN-M5` phase 3). ]]
local hoverRecord = hover :: any
hoverRecord.qualified = "bench.hover"

local client = { name = "client" }

local function rung(name: string, paced: boolean)
	local at = 0
	local clock = function()
		return at
	end

	local server = Budget.new(clock)
	local onWire = 0
	local refused = 0
	local newestSeen = 0

	local function push(_channel: any, value: any)
		onWire += 1

		if server.admit(hover, client, 0) == nil then
			newestSeen = value.slot
		else
			refused += 1
		end
	end

	local pacer = Pacer.new(push, clock)
	local sent = 0

	for second = 1, SECONDS do
		for frame = 1, FRAMES do
			at = (second - 1) + frame / FRAMES
			sent += 1

			if paced then
				pacer.send(hover, { slot = sent })
			else
				push(hover, { slot = sent })
			end
		end

		if paced then
			pacer.tick()
		end
	end

	Observer.reset()

	print(
		string.format(
			"        %-8s  sent %4d  on the wire %4d  refused at budget %4d  newest the server saw %4d",
			name,
			sent,
			onWire,
			refused,
			newestSeen
		)
	)

	return onWire, refused
end

print(`        {FRAMES} intent sends a second against rate = {RATE}, for {SECONDS} seconds`)
print("")

local beforeWire, beforeRefused = rung("BEFORE", false)
local afterWire, afterRefused = rung("AFTER", true)

print("")
print(
	`        the pacer takes {beforeWire - afterWire} packets off the wire and `
		.. `{beforeRefused - afterRefused} refusals off the server`
)

if afterRefused ~= 0 then
	error(
		`the paced rung was still refused {afterRefused} times; the client bucket disagrees with the server's`
	)
end

print("OK      pace")

return true
