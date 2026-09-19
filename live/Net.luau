--!strict

--[[
	The declaration for the live probe, required by both sides.

		rojo build live.project.json -o netweave-live.rbxl

	Then, in Studio: Test → Clients and Servers → 2 (or more) players → Start. Nothing in the suite or
	the benchmark has ever run with two real clients on real remotes; this place is where that happens.
	The server script prints a line every five seconds and the clients print theirs, and the console
	of each is the measurement.

	First run, 2026-09-19, two players, Studio uncapped at ~230 server frames a second: whisper 5/5
	mine and 0 not mine on both clients; scores 50 subjects and ~11,000 changes per five seconds on
	both; hover 300 per five seconds on the wire per client with the rest paced and nothing refused;
	markers 23,000 a second per client on the unreliable path and the same on the reliable one, no
	second missed; the stage ran once; two leaves with no error line. Two probe bugs on the way, both
	caught by the library's own reports: `t.u53` for a UserId that is negative in a local test, and a
	place with no floor, so the characters fell and respawned and `nearby` honestly found nobody.

	Every class the transport treats differently is here once, so a real multi-client session
	exercises all of them: an intent sent every frame (the client pacer), a command with a policy (the
	server stage), an owner event (per-recipient buffers), a replicated table (baselines per client,
	forgotten on leave), and a state channel with a `nearby` audience published for many subjects a
	frame (the recipient walk that has never been measured with more than one player).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local nw = require(ReplicatedStorage.netweave.src.netweave)
local t = require(ReplicatedStorage.netweave.src.types)

type Score = { kills: number, deaths: number, streak: number }

local scores: { [number]: Score } = {}

--[[ A policy with a server stage, so a live session shows the stage running once on the server
     and never on a client: the client console would raise at load if it ran there. ]]
local greeted = nw.policy(function()
	local banner: string? = nil

	return function(_ctx: nw.Ctx, _request: { seq: number })
		return if banner then nw.allow() else nw.deny("the stage did not run")
	end, function()
		banner = "the stage ran on the server"
		print(`[live] {banner}`)
	end
end)

local live = nw.namespace("live", {
	--[[ Sent every RenderStepped by the client, against a rate of 30: the pacer's live test. ]]
	hover = nw.intent({
		data = t.struct({ slot = t.u8(0, 7), x = t.f32(-512, 512), z = t.f32(-512, 512) }),
		rate = 30,
		unreliable = true,
	}),

	ping = nw.command({
		data = t.struct({ seq = t.u16 }),
		rate = 5,
		authorize = greeted,
	}),

	--[[ `i53`, not `u53`: the players a local server test creates have UserIds -1 and -2, and the first
	     two-player run refused every whisper inside the handler for exactly that — reported at
	     `handler`, as G4 says, and a probe bug rather than a library one. ]]
	whisper = nw.event({
		data = t.struct({ seq = t.u16, to = t.i53 }),
		audience = nw.audience.owner,
	}),

	scores = nw.replicate({
		subject = t.u16,
		data = t.struct({ kills = t.u16, deaths = t.u16, streak = t.u8 }),
		audience = nw.audience.everyone,
		store = nw.store.of(scores),
	}),

	--[[ Published for every marker part in the workspace, every frame, to players within fifty studs
	     of it. The server prints what that loop costs per frame; it is the number nobody has. ]]
	marker = nw.state({
		data = t.struct({ id = t.u16, heat = t.u8 }),
		audience = nw.audience.nearby(50),
		unreliable = true,
	}),

	--[[ The same publish on the reliable path, which is batched into one remote call per client per
	     frame where the unreliable one is a call per subject. The first two-player run saw the
	     unreliable markers arrive in bursts with whole five-second windows of nothing; this is the
	     control that says whether that is the unreliable path or the probe. ]]
	markerReliable = nw.state({
		data = t.struct({ id = t.u16, heat = t.u8 }),
		audience = nw.audience.nearby(50),
	}),
})

return {
	ns = live,
	scores = scores,
}
