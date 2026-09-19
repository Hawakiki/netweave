--!strict
--!optimize 2

--[[
	The optimisation residue M4 and M4-1 left open, one rung per finding, each printing what the
	finding said was there so a fix can be seen to remove it (`PLAN-M5` phase 4, D-4).

		lune run bench/residue

	Every rung counts where it can and weighs only where it must (`CLAUDE.md` §9, "count it instead
	of weighing it"): a distinct-string set, a table identity, a call counter, a record's size. The
	rungs that have to weigh — bytes per call — read `collectgarbage("count")` across short windows,
	throw away the windows the collector stepped inside, and print the median with the spread and how
	many windows survived, so the reader can see how much to trust the number.

	Each rung's header records the BEFORE, measured on the parent tree of the commit that fixed it,
	because a number is not a number until it survives being re-run.
]]

local Audience = require("../src/api/Audience")
local Batch = require("../src/transport/Batch")
local Buffer = require("../src/codec/Buffer")
local Channel = require("../src/api/Channel")
local Delta = require("../src/replication/Delta")
local Ir = require("../src/codec/Ir")
local Namespace = require("../src/api/Namespace")
local Outbound = require("../src/transport/Outbound")
local Recipients = require("../src/transport/Recipients")
local t = require("../src/types")

--[[ `gcinfo` is the heap in whole kilobytes — the analyzer deprecates `collectgarbage("count")`
     in its favour — so a window has to allocate enough for one call's share of a kilobyte to be
     below the noise, and be small enough that a full collection does not always land inside it.
     At 1,024 calls a window a kilobyte is one byte a call. ]]
local WINDOW = 1024
local WINDOWS = 64

type Weighed = { median: number, low: number, high: number, survived: number }

local function weigh(step: () -> (), window: number?): Weighed
	local perCall: { number } = {}
	local calls = window or WINDOW

	for _ = 1, WINDOWS do
		local before = gcinfo()
		for _ = 1, calls do
			step()
		end
		local delta = (gcinfo() - before) * 1024 / calls

		--[[ A window the collector stepped inside reads low or negative, and there is no way to
		     tell a small step from a small allocation, so a window is kept only when nothing was
		     freed — which biases towards the true number, never away from it. ]]
		if delta >= 0 then
			table.insert(perCall, delta)
		end
	end

	table.sort(perCall)

	if #perCall == 0 then
		return { median = 0 / 0, low = 0 / 0, high = 0 / 0, survived = 0 }
	end

	return {
		median = perCall[math.ceil(#perCall / 2)],
		low = perCall[1],
		high = perCall[#perCall],
		survived = #perCall,
	}
end

--[[ What the fixed tree has to show, checked at the end so every rung prints first: on the parent
     tree this file is the BEFORE and should say so in full, not stop at the first rung. ]]
local failures: { string } = {}

local function expect(condition: boolean, message: string)
	if not condition then
		table.insert(failures, message)
	end
end

local function bytes(label: string, weighed: Weighed)
	print(
		string.format(
			"        %-44s %6.1f B/call  [%5.1f–%5.1f]  n = %d",
			label,
			weighed.median,
			weighed.low,
			weighed.high,
			weighed.survived
		)
	)
end

--[[ "Allocates nothing" is the one weighed claim that can be checked like a count: with nothing
     allocated the collector never steps, so every window survives and every one reads zero. ]]
local function nothing(label: string, weighed: Weighed)
	bytes(label, weighed)
	expect(
		weighed.survived == WINDOWS and weighed.high == 0,
		`{label}: expected 0 B/call in all {WINDOWS} windows`
	)
end

-- -------------------------------------------------------------------------------------------
-- 73 — Delta.write's commit closure
-- -------------------------------------------------------------------------------------------

--[[
	M4 finding 73: `write` defined `commit` inside itself, capturing `base`, a per-call local, so
	Luau built a closure per call — on the path `Tick` runs once per subject per recipient per
	frame. M4-1 measured 112 B a call; this rung measures both of `write`'s paths, since the
	"nothing changed" path built it too, for nothing to call it with.

	BEFORE (bea4631): changed 112.0 B/call [67–112, n = 45], unchanged 112.0 B/call [84–112, n = 46].
	AFTER: 0.0 in all 64 windows on both paths.
]]
local function rung73()
	print("73      Delta.write, bytes per call")

	local delta = Delta.build(Ir.lower(t.struct({ x = t.u16, y = t.u16, hp = t.u8 })))
	local record = Buffer.emptySave()
	local old = { x = 1, y = 2, hp = 3 }
	local new = { x = 1, y = 5, hp = 3 }

	--[[ The record is grown once, outside the windows, so a doubling never lands inside one. ]]
	Buffer.load(record)
	delta.write(old, new)
	Buffer.saveInto(record)

	nothing(
		"changed (a patch is written)",
		weigh(function()
			Buffer.load(record)
			delta.write(old, new)
		end)
	)

	nothing(
		"unchanged (nothing written)",
		weigh(function()
			Buffer.load(record)
			delta.write(old, old)
		end)
	)
end

rung73()

-- -------------------------------------------------------------------------------------------
-- 74 — Batch.read's oversize-claim reason
-- -------------------------------------------------------------------------------------------

--[[
	M4 finding 74: a payload claiming more than its channel's ceiling was refused with a reason that
	quoted the claim, so a peer choosing a fresh length per packet got a fresh string per packet —
	past the observer's repeat suppression, which keys on the reason, and onto the heap on a stage
	whose rate the peer chooses. The ceiling is fixed per channel, so the reason can be too. M4-1
	measured 500 claims across 50 distinct lengths as 50 distinct strings; this rung sends the same.

	BEFORE (d98e91d): 50 distinct reasons for 500 claims. AFTER: 1.
]]
local function rung74()
	print("74      Batch.read, distinct reasons for oversize claims")

	local CLAIMS = 500
	local LENGTHS = 50

	Namespace.reset()

	local declared = Namespace.declare("residue", {
		listed = Channel.signal({ data = t.array(t.u8), rate = 1000, maxBytes = 32 }),
	})
	local protocol = Namespace.seal()
	local listed = declared.channels.listed

	Buffer.load(nil)
	Batch.begin()

	for claim = 1, CLAIMS do
		local length = listed.maxBytes + 1 + (claim % LENGTHS)
		Buffer.writeVarint(listed.id)
		Buffer.writeVarint(length)

		for _ = 1, length do
			Buffer.writeU8(0)
		end
	end

	local packed = Buffer.take()
	local reasons: { [string]: true } = {}
	local refused = 0
	local delivered = 0

	Batch.read(packed, nil, {
		resolve = Namespace.channelById,
		answers = true,
		admit = function()
			return nil, nil
		end,
		deliver = function()
			delivered += 1
		end,
		change = function() end,
		reply = function() end,
		hello = function() end,
		resync = function() end,
		refuse = function(_channel, _stage, reason: string)
			refused += 1
			reasons[reason] = true
		end,
	})

	local distinct = 0
	for _ in reasons do
		distinct += 1
	end

	print(
		string.format(
			"        %-44s %6d refused  %6d delivered  %6d distinct reasons  (%d channels)",
			`{CLAIMS} claims over {LENGTHS} lengths`,
			refused,
			delivered,
			distinct,
			protocol.count
		)
	)

	expect(refused == CLAIMS and delivered == 0, "74: every oversize claim is refused, none delivered")
	expect(distinct == 1, `74: expected 1 distinct reason for {CLAIMS} claims, got {distinct}`)

	Namespace.reset()
end

rung74()

-- -------------------------------------------------------------------------------------------
-- 76 — Buffer.take and the record it leaves behind
-- -------------------------------------------------------------------------------------------

--[[
	M4 finding 76: `take` handed back an exact copy and then loaded a fresh 64-byte buffer, so the
	parked record `Outbound.flush` saved afterwards started every frame at 64 bytes and regrew
	through every doubling to reach what it had reached the frame before — five doublings per
	destination per frame at 1.5 KB, each a `buffer.create` and a copy, while the comment beside
	the call said the record kept what it had. M4-1 measured the record's size as 64 → 2048 → 64
	across one write and a take. This rung watches the same record across two frames: its size at
	each step, whether the second frame writes into the buffer the first one grew, and the bytes a
	frame costs — where the exact copy `take` returns is the floor, since the remote must not carry
	the slack.

	BEFORE (0ee4327): sizes 64 → 2048 → 64, the second frame's buffer is a new object,
	5,696 B/frame [3,008–5,760, n = 56], 768 B per unreliable packet [272–768, n = 57].
	AFTER: 64 → 2048 → 2048, the same object, 1,600 B/frame [1,536–1,600, n = 61] and 256 B per
	unreliable packet [208–272, n = 59] — the copy plus the sidecar table, both times.
]]
local function rung76()
	print("76      Buffer.take, the record across a frame")

	local PAYLOAD = 1536

	local record = Buffer.emptySave()

	local function frame(): buffer
		Buffer.load(record)

		for _ = 1, PAYLOAD do
			Buffer.writeU8(0)
		end

		local packed = Buffer.take()
		Buffer.saveInto(record)

		return packed
	end

	local sizes: { number } = { record.size }

	Buffer.load(record)
	for _ = 1, PAYLOAD do
		Buffer.writeU8(0)
	end
	Buffer.saveInto(record)
	table.insert(sizes, record.size)

	Buffer.load(record)
	local packed = Buffer.take()
	Buffer.saveInto(record)
	table.insert(sizes, record.size)

	local grown = record.buffer
	frame()
	local kept = record.buffer == grown

	print(
		string.format(
			"        %-44s %s, the next frame %s",
			`record size across write and take at {buffer.len(packed)} B`,
			table.concat(sizes, " -> "),
			if kept then "writes into the buffer it grew" else "grows a new one"
		)
	)

	--[[ A frame allocates kilobytes, not bytes, so the window is sixteen frames: enough to read
	     to the byte, small enough that a collection does not land in every one. ]]
	local perFrame = weigh(function()
		frame()
	end, 16)
	bytes(`a {PAYLOAD} B frame (the exact copy is the floor)`, perFrame)
	expect(
		perFrame.median < 2 * PAYLOAD,
		`76: expected a frame to cost under twice its {PAYLOAD} B copy, got {perFrame.median}`
	)

	expect(
		sizes[3] == sizes[2],
		`76: expected the record to keep its {sizes[2]} B after a take, got {sizes[3]}`
	)
	expect(kept, "76: expected the next frame to write into the buffer the last one grew")

	--[[ The same finding on the unreliable path, through a real `Outbound`: a packet there is a
	     batch of one, written where nothing else is accumulating, and that used to be a fresh
	     buffer per packet. The link swallows the send, so what is weighed is the write, the exact
	     copy and the sidecar table — the copy is the floor again. ]]
	local UNRELIABLE = 200

	local link = {
		send = function() end,
		sendAll = function() end,
		receive = function() end,
	}
	local roster: Recipients.Roster = {
		all = function(): { any }
			return {}
		end,
		owner = function(_subject: any): any?
			return nil
		end,
		within = function(_subject: any, _studs: number, _out: { any }): number
			return 0
		end,
	}
	local out = Outbound.new(link, roster)
	local marker = Channel.event({
		data = t.struct({ tag = t.u8, body = t.buffer(0, 255) }),
		audience = Audience.everyone,
		unreliable = true,
	})
	marker.id = 1
	local value = { tag = 1, body = buffer.create(UNRELIABLE - 3) }
	local destination = { name = "player" }

	local perPacket = weigh(function()
		out.push(marker, destination, value)
	end, 64)
	bytes(`an unreliable packet of {UNRELIABLE} B (the exact copy is the floor)`, perPacket)
	expect(
		perPacket.median < 2 * UNRELIABLE,
		`76: expected an unreliable packet to cost under twice its {UNRELIABLE} B copy, got {perPacket.median}`
	)

	Buffer.load(nil)
end

rung76()

if #failures > 0 then
	print("")
	for _, failure in failures do
		print(`FAILED  {failure}`)
	end
	error(`{#failures} residue rung(s) still show what the finding described`)
end

print("OK      residue")

return true
