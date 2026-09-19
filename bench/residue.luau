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
local Baseline = require("../src/replication/Baseline")
local Batch = require("../src/transport/Batch")
local Budget = require("../src/transport/Budget")
local Buffer = require("../src/codec/Buffer")
local Channel = require("../src/api/Channel")
local Delta = require("../src/replication/Delta")
local Inbound = require("../src/transport/Inbound")
local Ir = require("../src/codec/Ir")
local Link = require("../src/transport/Link")
local Namespace = require("../src/api/Namespace")
local Outbound = require("../src/transport/Outbound")
local Recipients = require("../src/transport/Recipients")
local Serdes = require("../src/codec/Serdes")
local Store = require("../src/replication/Store")
local Tick = require("../src/replication/Tick")
local t = require("../src/types")

local SILENT: Link.Link = {
	send = function() end,
	sendAll = function() end,
	receive = function() end,
}

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
	local out = Outbound.new(SILENT, roster)
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

-- -------------------------------------------------------------------------------------------
-- 77 — what the tick allocates per subject
-- -------------------------------------------------------------------------------------------

--[[
	M4 finding 77, three parts. `Namespace.replicated` built a fresh array every time it was asked
	and the tick asked once a frame; the Roblox roster's `within` called `Players:GetPlayers()`
	itself — a fresh table from the engine — once per subject per publish, when the tick had
	already taken the roster once for the frame; and the recipient scratch kept whatever a larger
	audience had left past `count`, so a player who left stayed referenced from it until a larger
	audience overwrote the slot. Each is a count: whether two asks return one table, how many times
	a tick of N `nearby` subjects asks the roster for its players and whether `within` is handed
	that list, and how many entries a one-recipient audience leaves in a scratch a fifty-recipient
	one filled.

	BEFORE (f15828a): two asks, two tables; 1 ask a tick and `within` handed no list (so the Roblox
	roster asks the engine per subject); 50 entries left after an audience of 1.
	AFTER: one table; 1 ask, handed to all 100 `within` calls; 1 entry left.
]]
local function rung77()
	print("77      the tick, per subject")

	local SUBJECTS = 100
	local PLAYERS = 50

	Namespace.reset()

	local world: { [number]: any } = {}

	for subject = 1, SUBJECTS do
		world[subject] = { x = subject }
	end

	local declared = Namespace.declare("residue", {
		spots = Channel.replicate({
			subject = t.u16,
			data = t.struct({ x = t.u16 }),
			audience = Audience.nearby(64),
			store = Store.of(world),
		}),
	})
	Namespace.seal()

	local once = Namespace.replicated() == Namespace.replicated()
	print(
		string.format(
			"        %-44s %s",
			"replicated(), asked twice",
			if once then "one table" else "two tables"
		)
	)
	expect(once, "77: expected Namespace.replicated to answer with one table")

	local players: { any } = {}

	for index = 1, PLAYERS do
		players[index] = { name = `player{index}` }
	end

	local asked = 0
	local handed = 0
	local withins = 0

	local roster: Recipients.Roster = {
		all = function(): { any }
			asked += 1
			return players
		end,
		owner = function(_subject: any): any?
			return nil
		end,
		within = function(_subject: any, _studs: number, out: { any }, list: { any }?): number
			withins += 1

			if list == players then
				handed += 1
			end

			out[1] = players[1]
			return 1
		end,
	}

	local tick = Tick.new({
		outbound = Outbound.new(SILENT, roster),
		baselines = Baseline.new(true),
		roster = roster,
		channels = Namespace.replicated,
	})

	tick()

	print(
		string.format(
			"        %-44s asked for its players %d time(s), within ran %d times and was handed the list %d times",
			`a tick of {SUBJECTS} nearby subjects`,
			asked,
			withins,
			handed
		)
	)
	expect(
		asked == 1 and withins == SUBJECTS and handed == SUBJECTS,
		`77: expected the roster asked once and within handed that list {SUBJECTS} times, got {asked} and {handed}`
	)

	local scratch: { any } = {}
	local wide = Audience.select(function(): { any }
		return players
	end)
	local narrow = Audience.select(function(): { any }
		return { players[1] }
	end)

	local spots = declared.channels.spots
	Recipients.of(wide, 1, roster, scratch, spots)
	local filled = Recipients.of(narrow, 1, roster, scratch, spots)
	local left = 0

	for _ in scratch do
		left += 1
	end

	print(
		string.format(
			"        %-44s %d filled, %d left in the scratch",
			`an audience of {PLAYERS} then one of 1`,
			filled,
			left
		)
	)
	expect(left == filled, `77: expected the scratch to hold {filled} after the narrow audience, got {left}`)

	Namespace.reset()
end

rung77()

-- -------------------------------------------------------------------------------------------
-- Budget.admit's refusal string
-- -------------------------------------------------------------------------------------------

--[[
	M4-1, the first of three minor optimisation findings: `Budget.admit` built its refusal as an
	interpolated string, so a refusal cost 2.4x an admission — 191 ns against 80 — for a sentence
	whose one variable, the rate, is fixed per channel. Not an allocation: Luau interns short
	strings, so the same sentence built again is the same object and M4-1 measured +0 KB over 10⁶
	refusals. Time only, which is why this rung has to weigh. Each column is the median over
	repeats of a run of calls under an injected clock, with the spread; the clock never moves, so
	the admitted column drains the bucket once and the refused column is every call after.

	BEFORE (78689c7): admitted 67 ns [66–73], refused 186 ns [183–193], ratio 2.8.
	AFTER: admitted 67 ns [65–71], refused 84 ns [81–94], ratio 1.3.
]]
local function rungBudget()
	print("M4-1    Budget.admit, admitted against refused")

	local REPEATS = 21
	local CALLS = 100000

	--[[ A bucket as deep as one run, at an ordinary rate: the admitted column is the burst being
	     drained, and the refused column is what comes after with the clock stopped. ]]
	local channel = Channel.signal({ data = t.struct({ n = t.u8 }), rate = 30, burst = CALLS })
	channel.qualified = "residue.signal"
	local sender = { name = "sender" }

	local function time(refusing: boolean): (number, number, number)
		local samples: { number } = {}

		for _ = 1, REPEATS do
			local budget = Budget.new(function()
				return 0
			end)
			local admit = budget.admit

			if refusing then
				--[[ Drain the bucket first, so every timed call is a refusal. ]]
				for _ = 1, CALLS do
					admit(channel, sender, 1)
				end
			end

			local started = os.clock()
			for _ = 1, CALLS do
				admit(channel, sender, 1)
			end
			table.insert(samples, (os.clock() - started) * 1e9 / CALLS)
		end

		table.sort(samples)
		return samples[math.ceil(REPEATS / 2)], samples[1], samples[REPEATS]
	end

	local admitted, admittedLow, admittedHigh = time(false)
	local refused, refusedLow, refusedHigh = time(true)
	local ratio = refused / admitted

	print(
		string.format(
			"        %-44s admitted %4.0f ns [%3.0f–%3.0f]  refused %4.0f ns [%3.0f–%3.0f]  ratio %.1f  n = %d x %d",
			"one sender, one channel, the clock stopped",
			admitted,
			admittedLow,
			admittedHigh,
			refused,
			refusedLow,
			refusedHigh,
			ratio,
			REPEATS,
			CALLS
		)
	)
	expect(
		ratio < 1.5,
		`Budget.admit: expected a refusal under 1.5x an admission, got {string.format("%.1f", ratio)}x`
	)
end

rungBudget()

-- -------------------------------------------------------------------------------------------
-- The instance reader's refusal strings
-- -------------------------------------------------------------------------------------------

--[[
	M4-1, the second minor: the instance reader built `"instance is not a " .. class` and
	`"instance is not inside " .. root.Name` on every refusal, for two sentences that are constants
	per schema. Interned, so time only, like the rung above — and the refusal is the path a peer
	takes by handing the sidecar an instance of the wrong class, which costs it nothing. The two
	columns read the same sidecar slot through the same reader: one holds an instance of the
	declared class, the other one of another class.

	BEFORE (78689c7): admitted 111 ns [109–125], refused 159 ns [158–174], ratio 1.4.
	AFTER: admitted 112 ns [109–118], refused 125 ns [124–141], ratio 1.1.
]]
local function rungInstance()
	print("M4-1    the instance reader, admitted against refused")

	local REPEATS = 21
	local CALLS = 100000

	--[[ The lune stand-in the codec suite uses: a table answering `IsA`, which is what the reader
	     asks. In Studio it is a real Instance (`tests/roblox_runtime.luau`). ]]
	local function standIn(className: string): any
		return {
			ClassName = className,
			IsA = function(_self: any, class: string): boolean
				return class == className
			end,
		}
	end

	local codec = Serdes.fromSchema(t.instance("Sound"))
	local read = codec.read
	local empty = buffer.create(0)

	local function time(value: any): (number, number, number)
		local samples: { number } = {}
		local sidecar = { value }

		for _ = 1, REPEATS do
			Buffer.beginRead(empty, sidecar)

			local started = os.clock()
			for _ = 1, CALLS do
				Buffer.seekInstances(0)
				Buffer.clearRejection()
				read()
			end
			table.insert(samples, (os.clock() - started) * 1e9 / CALLS)
		end

		table.sort(samples)
		return samples[math.ceil(REPEATS / 2)], samples[1], samples[REPEATS]
	end

	local admitted, admittedLow, admittedHigh = time(standIn("Sound"))
	local refused, refusedLow, refusedHigh = time(standIn("Part"))
	local ratio = refused / admitted

	print(
		string.format(
			"        %-44s admitted %4.0f ns [%3.0f–%3.0f]  refused %4.0f ns [%3.0f–%3.0f]  ratio %.1f  n = %d x %d",
			't.instance("Sound") handed a Sound, then a Part',
			admitted,
			admittedLow,
			admittedHigh,
			refused,
			refusedLow,
			refusedHigh,
			ratio,
			REPEATS,
			CALLS
		)
	)
	expect(
		ratio < 1.25,
		`instance reader: expected a refusal under 1.25x an admission, got {string.format("%.1f", ratio)}x`
	)
end

rungInstance()

-- -------------------------------------------------------------------------------------------
-- The pending free list
-- -------------------------------------------------------------------------------------------

--[[
	M4-1, the third minor: `Inbound` walks each batch's pending list from a free list, and a walk
	that yields inside a handler holds its list while the next batch claims another — so the pool
	grows to the most walks ever in flight at once and stays there, each list seven arrays sized by
	the largest batch it carried. Not something a peer can drive alone: it takes a handler that
	yields, and that is game code. Counted rather than weighed, because lune cannot force a
	collection and what the pool retains is otherwise invisible: `pooled()` exists for this rung.

	BEFORE (5214fd1, with the accessor): 64 walks parked at once, 0 pooled while parked, 64 after.
	AFTER: 0 while parked, 8 after — the cap.
]]
local function rungPool()
	print("M4-1    the pending free list after a burst of parked walks")

	local WALKS = 64

	Namespace.reset()

	local declared = Namespace.declare("residue", {
		slow = Channel.signal({ data = t.struct({ n = t.u8 }), rate = 1000 }),
	})
	Namespace.seal()

	local slow = declared.channels.slow
	slow.handler = function()
		coroutine.yield()
	end

	local inbound = Inbound.new({
		resolve = Namespace.channelById,
		admit = function(): string?
			return nil
		end,
		isServer = true,
	})

	Buffer.load(nil)
	Batch.writePacket(slow, { n = 1 })
	local packed = Buffer.take()

	local parked: { thread } = {}

	--[[ A sender per walk: the same player's packet dispatched across another's yield is the
	     report `PLAN-M5` D-5 added, and this rung is about the pool, not the detector. ]]
	for index = 1, WALKS do
		local sender = { name = `player{index}` }
		local thread = coroutine.create(function()
			inbound.receive(packed, nil, sender)
		end)
		coroutine.resume(thread)
		parked[index] = thread
	end

	local inFlight = inbound.pooled()

	for _, thread in parked do
		coroutine.resume(thread)
	end

	local after = inbound.pooled()

	print(
		string.format(
			"        %-44s %d pooled while parked, %d pooled after they finished",
			`{WALKS} walks parked inside their handler`,
			inFlight,
			after
		)
	)

	expect(after <= 8, `free list: expected at most 8 lists pooled after the burst, got {after}`)

	slow.handler = nil
	Namespace.reset()
end

rungPool()

if #failures > 0 then
	print("")
	for _, failure in failures do
		print(`FAILED  {failure}`)
	end
	error(`{#failures} residue rung(s) still show what the finding described`)
end

print("OK      residue")

return true
