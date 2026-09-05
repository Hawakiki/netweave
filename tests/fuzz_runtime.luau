--!strict

--[[
	Valid batches, broken on purpose, ten thousand times.

		lune run tests/fuzz_runtime

	`hostile_runtime` writes the attacks somebody thought of. This writes the ones nobody did: it
	encodes a real batch and then damages it — a bit flipped, a length rewritten, an id swapped, the
	sidecar over- or under-stated, the whole thing truncated, replayed, or replaced with noise.

	Four invariants, checked on every iteration.

	  1. **Nothing raises.** `DESIGN-API.md` G4. The bytes came off a wire.
	  2. **Nothing arrives that the schema forbids.** A mutated batch may well decode into a
	     *different* valid value — that is unavoidable and correct, since the wire carries no
	     redundancy to catch it with. What must never happen is a value reaching a handler that its
	     own `codec.check` rejects, because that is the guarantee the whole codec exists to make.
	  3. **Nothing vanishes.** A batch with bytes in it either delivers something or reports
	     something.
	  4. **Nothing is left behind.** A valid canary batch is fed after every mutation and must
	     arrive. A sticky rejection, a stranded cursor or a half-consumed sidecar would show up here
	     and nowhere else, because every other suite starts from a clean decoder.

	And two after the run: no query slot leaked across ten thousand mutations, and every refusal
	the observer saw is in the counters.
]]

local Baseline = require("../src/replication/Baseline")
local Batch = require("../src/transport/Batch")
local Budget = require("../src/transport/Budget")
local Buffer = require("../src/codec/Buffer")
local Inbound = require("../src/transport/Inbound")
local Namespace = require("../src/api/Namespace")
local Observer = require("../src/api/Observer")
local Protocol = require("../src/api/Protocol")
local Query = require("../src/transport/Query")
local harness = require("./harness")
local nw = require("../src/netweave")
local t = require("../src/types")

local suite = harness.suite("fuzz_runtime", 0.9)
local check, equals, fail = suite.check, suite.equals, suite.fail

--[[ Seeded, and the seed is printed. A fuzz failure nobody can reproduce is an anecdote. ]]
local SEED = 20260905
local ROUNDS = 10000

--[[ Fewer rounds than the batch fuzz above, and the reason is that a change is a smaller surface:
     one channel, one packet shape, and flag bytes that are at most two. Every mutation still breaks
     something well inside this many, which is what the counters at the end check. ]]
local CHANGES = 4000

math.randomseed(SEED)

-- ---------------------------------------------------------------------------------------------
-- The corpus
-- ---------------------------------------------------------------------------------------------

local mallory = { name = "mallory" }

local allows = nw.policy(function()
	return function()
		return nw.allow()
	end
end)

Namespace.reset()

local declared = Namespace.declare("f", {
	--[[ One of each framing and each hazard: fixed size, a length prefix, a sidecar, a bitfield, an
	     unbounded array, an authorized channel and a query. A corpus that is all one shape fuzzes
	     one branch. ]]
	fixed = nw.signal({ data = t.struct({ a = t.u8, b = t.u16, c = t.i16(-100, 100) }), rate = 100000 }),
	texted = nw.signal({ data = t.struct({ s = t.string(0, 40), n = t.u8(5, 90) }), rate = 100000 }),
	flagged = nw.signal({
		data = t.struct({
			one = t.boolean,
			two = t.boolean,
			three = t.optional(t.u8),
			pick = t.enum({ red = true, green = true, blue = true }),
		}),
		rate = 100000,
	}),
	listed = nw.signal({ data = t.array(t.u16, 0, 40), rate = 100000, maxBytes = 64 }),
	carried = nw.signal({ data = t.struct({ who = t.instance, n = t.u8 }), rate = 100000 }),
	guarded = nw.command({ data = t.struct({ n = t.u8 }), rate = 100000, authorize = allows }),
	asked = nw.query({
		args = t.struct({ n = t.u8 }),
		returns = t.struct({ v = t.u8 }),
		rate = 100000,
		timeout = 5,
		authorize = allows,
	}),
	--[[ Server to client, so it is fuzzed against the endpoint that receives it — see the second
	     run at the end of this file. Its schema carries a flag, an optional and a nested struct,
	     because a change's own bitfield is the thing being mutated and a schema with one bit would
	     mutate one bit. ]]
	mirrored = nw.replicate({
		subject = t.u16,
		data = t.struct({
			n = t.u8,
			flag = t.boolean,
			maybe = t.optional(t.u16),
			pos = t.struct({ x = t.u8, y = t.u8 }),
		}),
		audience = nw.audience.everyone,
		store = nw.store.of({}),
	}),
})

local protocol = Namespace.seal()

local Fixed = declared.channels.fixed
local Texted = declared.channels.texted
local Flagged = declared.channels.flagged
local Listed = declared.channels.listed
local Carried = declared.channels.carried
local Guarded = declared.channels.guarded
local Asked = declared.channels.asked

--[[ A stand-in that answers `:IsA`, which is the only thing the instance reader asks of one and
     therefore the only thing a stand-in has to be (`tests/harness.luau`). ]]
local part: any = harness.instance("part")

--[[ A packet of each shape, and the value that produced it, so a delivery can be checked against
     the schema that is supposed to bound it. ]]
type Shape = { channel: any, make: () -> any }

local shapes: { Shape } = {
	{
		channel = Fixed,
		make = function()
			return { a = math.random(0, 255), b = math.random(0, 65535), c = math.random(-100, 100) }
		end,
	},
	{
		channel = Texted,
		make = function()
			return { s = string.rep("x", math.random(0, 40)), n = math.random(5, 90) }
		end,
	},
	{
		channel = Flagged,
		make = function()
			return {
				one = math.random() < 0.5,
				two = math.random() < 0.5,
				three = if math.random() < 0.5 then math.random(0, 255) else nil,
				pick = ({ "red", "green", "blue" })[math.random(1, 3)],
			}
		end,
	},
	{
		channel = Listed,
		make = function()
			local values = {}

			for index = 1, math.random(0, 20) do
				values[index] = math.random(0, 65535)
			end

			return values
		end,
	},
	{
		channel = Carried,
		make = function()
			return { who = part, n = math.random(0, 255) }
		end,
	},
	{
		channel = Guarded,
		make = function()
			return { n = math.random(0, 255) }
		end,
	},
}

-- ---------------------------------------------------------------------------------------------
-- The peer under attack
-- ---------------------------------------------------------------------------------------------

local delivered = 0
local reported = 0
local greeted = 0

--[[ Values that reached a handler while failing the schema that is supposed to bound them. Kept
     apart from the run's other notes because this is the only one of the four invariants that would
     be a defect in netweave rather than in this file. ]]
local violations: { string } = {}

local at = 0

local function clock(): number
	return at
end

local budget = Budget.new(clock)

local queries = Query.new({
	request = function() end,
	reply = function() end,

	spawn = function(target: any, ...: any)
		local thread = if type(target) == "thread" then target else coroutine.create(target)
		local ok, err = coroutine.resume(thread, ...)

		if not ok then
			table.insert(violations, `a spawned thread raised: {tostring(err)}`)
		end
	end,

	clock = clock,
})

--[[ `hash` is read exactly once per hello, by `greet`, which makes it the hook for counting them.
     A batch that is nothing but a handshake delivers nothing and reports nothing, and without this
     count it would look like bytes that vanished. ]]
local agreement = Protocol.new({
	hash = function(): number
		greeted += 1
		return protocol.hash
	end,

	announce = function() end,
	isServer = true,
})

local inbound = Inbound.new({
	resolve = Namespace.channelById,
	admit = budget.admit,
	isServer = true,
	queries = queries,
	agreement = agreement,
})

Observer.reset()
Observer.observe(function()
	reported += 1
end)

--[[
	Invariant 2, enforced at the only place it can be: the handler.

	A mutated packet is allowed to decode into a different value than the one that was encoded —
	the wire carries no redundancy, so there is nothing to notice with. What it is not allowed to do
	is produce a value the channel's own schema refuses, because that is the claim every declaration
	makes to the handler behind it.
]]
local function inspect(channel: any, value: any)
	delivered += 1

	local failure = channel.codec.check(value)

	if failure and #violations < 8 then
		table.insert(violations, `{channel.qualified} delivered a value its own schema refuses: {failure}`)
	end
end

for _, channel in declared.channels do
	if channel.class == "query" then
		channel.handler = function(_ctx: any, value: any)
			inspect(channel, value)
			return { v = 1 }
		end
	else
		channel.handler = function(_ctx: any, value: any)
			inspect(channel, value)
		end
	end
end

-- ---------------------------------------------------------------------------------------------
-- The mutations
-- ---------------------------------------------------------------------------------------------

--[[ The sidecar is typed `{ Instance }` all the way down, and under lune there are no instances —
     these tables stand in, the same way `tests/transport_runtime.luau` does it. ]]
type Sample = { packed: buffer, instances: { Instance } }

local function encode(): Sample
	Buffer.take()
	Buffer.load(nil)

	--[[ A batch is one to five packets, so both the single-packet case and the resynchronisation
	     the length prefix pays for are exercised. ]]
	for _ = 1, math.random(1, 5) do
		local roll = math.random()

		if roll < 0.1 then
			Batch.writeHello(protocol.hash)
		elseif roll < 0.2 then
			Batch.writeRequest(Asked, math.random(1, 16000), { n = math.random(0, 255) })
		else
			local shape = shapes[math.random(1, #shapes)]
			Batch.writePacket(shape.channel, shape.make())
		end
	end

	local packed, instances = Buffer.take()
	return { packed = packed, instances = instances }
end

local function copyOf(source: buffer, length: number): buffer
	local out = buffer.create(length)
	buffer.copy(out, 0, source, 0, math.min(length, buffer.len(source)))
	return out
end

type Mutation = { name: string, apply: (Sample) -> Sample }

local mutations: { Mutation } = {
	{
		name = "bit flip",
		apply = function(sample: Sample): Sample
			local length = buffer.len(sample.packed)

			if length == 0 then
				return sample
			end

			local out = copyOf(sample.packed, length)
			local offset = math.random(0, length - 1)

			buffer.writeu8(
				out,
				offset,
				bit32.bxor(buffer.readu8(out, offset), bit32.lshift(1, math.random(0, 7)))
			)

			return { packed = out, instances = sample.instances }
		end,
	},
	{
		name = "byte substituted",
		apply = function(sample: Sample): Sample
			local length = buffer.len(sample.packed)

			if length == 0 then
				return sample
			end

			local out = copyOf(sample.packed, length)
			buffer.writeu8(out, math.random(0, length - 1), math.random(0, 255))

			return { packed = out, instances = sample.instances }
		end,
	},
	{
		name = "truncated",
		apply = function(sample: Sample): Sample
			local length = buffer.len(sample.packed)
			return { packed = copyOf(sample.packed, math.random(0, length)), instances = sample.instances }
		end,
	},
	{
		name = "extended with noise",
		apply = function(sample: Sample): Sample
			local length = buffer.len(sample.packed)
			local extra = math.random(1, 8)
			local out = copyOf(sample.packed, length + extra)

			for offset = length, length + extra - 1 do
				buffer.writeu8(out, offset, math.random(0, 255))
			end

			return { packed = out, instances = sample.instances }
		end,
	},
	{
		name = "channel id substituted",
		apply = function(sample: Sample): Sample
			local length = buffer.len(sample.packed)

			if length < 2 then
				return sample
			end

			--[[ The byte after the version is the first packet's id. Swapping it for another
			     channel's number is the deploy-skew failure done deliberately: the framing that
			     follows belongs to a different schema. ]]
			local out = copyOf(sample.packed, length)
			buffer.writeu8(out, 1, math.random(0, protocol.count + 3))

			return { packed = out, instances = sample.instances }
		end,
	},
	{
		name = "sidecar overstated",
		apply = function(sample: Sample): Sample
			--[[ Fewer instances than the packets claim. The claim is provably a lie because the
			     sidecar's length is known, and believing it would hand a packet another packet's
			     Instance. ]]
			local trimmed: { Instance } = {}

			for index = 1, math.max(0, #sample.instances - 1) do
				trimmed[index] = sample.instances[index]
			end

			return { packed = sample.packed, instances = trimmed }
		end,
	},
	{
		name = "sidecar padded",
		apply = function(sample: Sample): Sample
			local padded: { Instance } = table.clone(sample.instances)
			table.insert(padded, part)

			return { packed = sample.packed, instances = padded }
		end,
	},
	{
		name = "replayed",
		apply = function(sample: Sample): Sample
			--[[ The batch concatenated with itself, version byte and all. The second version byte
			     lands where a channel id is expected, which is a wrong id rather than a wrong
			     version — and that is the point: a replayed frame is not a special case, it is
			     bytes. ]]
			local length = buffer.len(sample.packed)
			local out = buffer.create(length * 2)

			buffer.copy(out, 0, sample.packed, 0, length)
			buffer.copy(out, length, sample.packed, 0, length)

			return { packed = out, instances = sample.instances }
		end,
	},
	{
		name = "noise",
		apply = function(sample: Sample): Sample
			local length = math.random(0, 64)
			local out = buffer.create(length)

			for offset = 0, length - 1 do
				buffer.writeu8(out, offset, math.random(0, 255))
			end

			return { packed = out, instances = sample.instances }
		end,
	},
}

-- ---------------------------------------------------------------------------------------------
-- The run
-- ---------------------------------------------------------------------------------------------

local raises = 0
local silent = 0
local canaries = 0
local notes: { string } = {}
local exercised: { [string]: number } = {}
local broke: { [string]: number } = {}

for _, mutation in mutations do
	exercised[mutation.name] = 0
	broke[mutation.name] = 0
end

local function note(text: string)
	if #notes < 8 then
		table.insert(notes, text)
	end
end

local canary = (function(): Sample
	Buffer.take()
	Buffer.load(nil)
	Batch.writePacket(Fixed, { a = 1, b = 2, c = 3 })

	local packed, instances = Buffer.take()
	return { packed = packed, instances = instances }
end)()

for round = 1, ROUNDS do
	--[[ The clock moves so the bucket refills. A fuzz run against a spent budget refuses everything
	     at the first stage and never reaches the decoder, which would be ten thousand iterations of
	     one branch. ]]
	at += 1

	--[[ A mismatched hello poisons everything after it: the peer is refused at `protocol`,
	     correctly, and nothing is ever decoded for them again. Cleared before each batch so a
	     mutated hello is exercised without swallowing the run — and again before the canary, which
	     would otherwise be measuring the handshake rather than the decoder. ]]
	agreement.forget(mallory)

	local mutation = mutations[math.random(1, #mutations)]
	exercised[mutation.name] += 1

	local sample = mutation.apply(encode())
	local before = delivered + reported + greeted
	local refusedBefore = reported

	local survived = pcall(inbound.receive, sample.packed, sample.instances, mallory)

	if reported > refusedBefore then
		broke[mutation.name] += 1
	end

	if not survived then
		raises += 1
		note(`round {round}: {mutation.name} raised on the receive path`)
	end

	--[[
		Three outcomes count as "something happened", and the third is the one the first run of this
		file got wrong: a batch that is nothing but a handshake delivers nothing and reports nothing,
		and that is correct. Counting a hello was the fix; loosening the invariant would not have
		been.
	]]
	if buffer.len(sample.packed) > 1 and delivered + reported + greeted == before then
		silent += 1
		note(
			`round {round}: {mutation.name} produced {buffer.len(sample.packed)} bytes that neither `
				.. `arrived nor were reported`
		)
	end

	--[[ Invariant 4. Whatever the mutation left in the decoder — a sticky rejection, a stranded
	     cursor, a half-consumed sidecar — shows up as the next honest batch failing to arrive, and
	     it shows up nowhere else. ]]
	agreement.forget(mallory)

	local wasDelivered = delivered
	local healthy = pcall(inbound.receive, canary.packed, canary.instances, mallory)

	if healthy and delivered == wasDelivered + 1 then
		canaries += 1
	else
		note(`round {round}: the canary did not survive {mutation.name}`)
	end
end

-- ---------------------------------------------------------------------------------------------
-- What it found
-- ---------------------------------------------------------------------------------------------

suite.failing()

equals(`{ROUNDS} mutated batches raise nothing on the receive path`, raises, 0)
equals("no batch with bytes in it vanishes without a word", silent, 0)
equals("an honest batch still arrives after every one of them", canaries, ROUNDS)
equals("and nothing decoded into a value its own schema refuses", #violations, 0)

for index = 1, math.min(#notes, 8) do
	fail(`  seed {SEED}: {notes[index]}`)
end

for index = 1, math.min(#violations, 8) do
	fail(`  seed {SEED}: {violations[index]}`)
end

--[[ A fuzz run that only ever hit one mutation is not a fuzz run, and a count nobody prints is a
     count nobody checks. ]]
for _, mutation in mutations do
	check(`{mutation.name} was exercised`, exercised[mutation.name] > 0)
end

--[[
	And every mutation that damages bytes has to produce refusals, or it is not mutating anything.

	`sidecar padded` is excluded on purpose and is the interesting one: adding an entry the packets
	never claim cannot be refused, because nothing reads it. Its invariant is the opposite — that a
	padded sidecar changes *nothing* — and that is what the canary two lines below every round is
	already asserting for it.
]]
local damaging = {
	"bit flip",
	"byte substituted",
	"truncated",
	"extended with noise",
	"channel id substituted",
	"sidecar overstated",
	"replayed",
	"noise",
}

for _, name in damaging do
	check(`{name} actually broke something`, broke[name] > 0)
end

--[[ Ten thousand mutations, and not one of them left a query slot behind. `forget` is deliberately
     never called for the queries here, so a leak would accumulate rather than be swept up. ]]
equals("no query slot leaked across the whole run", queries.inflight(mallory), 0)

--[[ Every refusal the observer saw is in the counters. A diagnostic screen that undercounts is
     worse than none, because it reads as "this is fine". ]]
local diagnostics = Observer.diagnostics()
local counted = 0

for _, byStage in diagnostics.channels do
	for _, entry in byStage do
		counted += entry.count
	end
end

equals("every refusal reached the counters", counted, diagnostics.total)
check("and the run refused a great many things", reported > ROUNDS / 4)

suite.passing()

check(
	"the corpus covers every framing mode",
	Fixed.codec.framing == "static" and Texted.codec.framing == "counted"
)
equals("and a channel that carries an instance", Carried.codec.instances, 1)

print(`        seed {SEED}, {ROUNDS} rounds, {delivered} delivered, {reported} refused`)

for _, mutation in mutations do
	print(`        {mutation.name}: {exercised[mutation.name]} run, {broke[mutation.name]} refused`)
end

-- ---------------------------------------------------------------------------------------------
-- The other direction: changes, mutated, arriving at a client
-- ---------------------------------------------------------------------------------------------

--[[
	Everything above is a client attacking a server, because that is the direction every other
	channel class runs in. A replicated channel runs the other way, so the bytes that matter are the
	ones a client reads — and a client reads them *against a baseline*, which is state the sender
	chose and the reader cannot check.

	That makes the flag bytes at the front of a change the most interesting bytes in the format. They
	are not a value; they are an instruction about which values follow, and a mutated one says
	"three fields are here" over a packet carrying one. So the same mutations run again, over a
	stream of arrivals, patches and removals, against the same four invariants.
]]

local Mirrored = declared.channels.mirrored :: any

local landed = 0
local removals = 0
local desyncs = 0

--[[ Set when the reader gives up on the channel, and honoured by the encoder below. Without it this
     run would spend most of its rounds against a reader that has no baselines at all — every patch
     refused, the merge never reached — which is the fuzz equivalent of testing one branch ten
     thousand times. ]]
local resend = false

--[[ Unbounded, the way `Driver` builds a client's: what arrived is already bounded by what the
     server agreed to send (`src/transport/Driver.luau`). ]]
local baselines = Baseline.new()

local mirror = Inbound.new({
	resolve = Namespace.channelById,

	admit = function(): string?
		return nil
	end,

	--[[ The one line that makes this a client. A replicated packet is refused before decode on a
	     server (G6), so the receive path for changes can only be exercised from this side. ]]
	isServer = false,
	baselines = baselines,

	desynced = function()
		desyncs += 1
		resend = true
	end,
})

--[[ A client's handler takes the subject in front of the payload, and both are checked: the subject
     names which value this is, so one its own codec refuses is as much a violation of invariant 2 as
     a payload would be. A nil payload is the subject going away. ]]
Mirrored.handler = function(subject: any, value: any)
	if value == nil then
		removals += 1
	else
		landed += 1
	end

	local misnamed = Mirrored.subjectCodec.check(subject)

	if misnamed and #violations < 8 then
		table.insert(violations, `a change named a subject its own codec refuses: {misnamed}`)
	end

	if value == nil then
		return
	end

	local failure = Mirrored.codec.check(value)

	if failure and #violations < 8 then
		table.insert(violations, `a change decoded into a value its own schema refuses: {failure}`)
	end
end

--[[ A handful, so a patch usually lands on a subject the reader has a baseline for. Fuzzing against
     subjects that are always new would test the snapshot path four thousand times and the merge
     never. ]]
local SUBJECTS = { 1, 2, 3, 4 }

--[[ What the *sender* believes this client holds. It diverges from what the client actually holds
     the moment a mutation is refused, and that divergence is the point: a patch computed against a
     baseline the reader no longer has is what a single dropped packet produces in production, with
     no attacker anywhere. ]]
local sent: { [number]: any } = {}

local function fresh(): any
	return {
		n = math.random(0, 255),
		flag = math.random() < 0.5,
		maybe = if math.random() < 0.5 then math.random(0, 65535) else nil,
		pos = { x = math.random(0, 255), y = math.random(0, 255) },
	}
end

--[[ One field, so the change carries a bitfield with holes in it. A patch that moved everything
     would decode the same whether the flags were read or assumed. ]]
local function moved(old: any): any
	local next_ = table.clone(old)
	next_.pos = table.clone(old.pos)

	local pick = math.random(1, 4)

	if pick == 1 then
		next_.n = math.random(0, 255)
	elseif pick == 2 then
		next_.flag = not old.flag
	elseif pick == 3 then
		next_.maybe = if math.random() < 0.5 then math.random(0, 65535) else nil
	else
		next_.pos.x = math.random(0, 255)
	end

	return next_
end

local function changes(): Sample
	Buffer.take()
	Buffer.load(nil)

	--[[ The resync answered, which is the half of the recovery that lives on the server: a peer that
	     asked for a channel again is a peer whose baselines are dropped, so the next tick sends
	     snapshots (`src/transport/Outbound.luau`, `Tick.send`). Modelling it here is what keeps the
	     merge path reachable after the first refusal. ]]
	if resend then
		table.clear(sent)
		resend = false
	end

	for _ = 1, math.random(1, 5) do
		local subject = SUBJECTS[math.random(1, #SUBJECTS)]
		local old = sent[subject]
		local new: any

		if old == nil then
			new = fresh()
		elseif math.random() < 0.15 then
			--[[ Gone: the root bit clear and no body, which is the one packet on this channel that
			     carries no values at all and therefore the one whose length prefix is doing all of
			     the work. ]]
			new = nil
		else
			new = moved(old)
		end

		--[[ False is "nothing to say", and the sender's picture only advances when something was
		     written — the same rule `Tick.send` follows, for the same reason. ]]
		if Batch.writeChange(Mirrored, subject, old, new) then
			sent[subject] = new
		end
	end

	local packed, instances = Buffer.take()
	return { packed = packed, instances = instances }
end

--[[ A snapshot with every field present, on a subject nothing else touches. A patch would be a
     canary that depends on the baseline the previous mutation left behind, which is the thing being
     tested rather than the thing to measure with. ]]
local healthy = (function(): Sample
	Buffer.take()
	Buffer.load(nil)

	Batch.writeChange(Mirrored, 9000, nil, { n = 1, flag = true, maybe = 2, pos = { x = 3, y = 4 } })

	local packed, instances = Buffer.take()
	return { packed = packed, instances = instances }
end)()

local changeRaises = 0
local changeSilent = 0
local changeCanaries = 0
local changeNotes: { string } = {}
local changeExercised: { [string]: number } = {}
local changeBroke: { [string]: number } = {}

for _, mutation in mutations do
	changeExercised[mutation.name] = 0
	changeBroke[mutation.name] = 0
end

local function noteChange(text: string)
	if #changeNotes < 8 then
		table.insert(changeNotes, text)
	end
end

for round = 1, CHANGES do
	local mutation = mutations[math.random(1, #mutations)]
	changeExercised[mutation.name] += 1

	local sample = mutation.apply(changes())
	local before = landed + removals + reported
	local refusedBefore = reported

	local survived = pcall(mirror.receive, sample.packed, sample.instances, nil)

	if reported > refusedBefore then
		changeBroke[mutation.name] += 1
	end

	if not survived then
		changeRaises += 1
		noteChange(`round {round}: {mutation.name} raised on the change path`)
	end

	if buffer.len(sample.packed) > 1 and landed + removals + reported == before then
		changeSilent += 1
		noteChange(
			`round {round}: {mutation.name} produced {buffer.len(sample.packed)} bytes of change that `
				.. `neither arrived nor were reported`
		)
	end

	local wasLanded = landed
	local intact = pcall(mirror.receive, healthy.packed, healthy.instances, nil)

	if intact and landed == wasLanded + 1 then
		changeCanaries += 1
	else
		noteChange(`round {round}: the canary did not survive {mutation.name}`)
	end
end

suite.failing()

equals(`{CHANGES} mutated changes raise nothing on the receive path`, changeRaises, 0)
equals("no change with bytes in it vanishes without a word", changeSilent, 0)
equals("an honest change still arrives after every one of them", changeCanaries, CHANGES)
equals("and nothing merged into a value its own schema refuses", #violations, 0)

for index = 1, math.min(#changeNotes, 8) do
	fail(`  seed {SEED}: {changeNotes[index]}`)
end

for index = 1, math.min(#violations, 8) do
	fail(`  seed {SEED}: {violations[index]}`)
end

--[[
	The byte mutations, and **not the two sidecar ones**, which is a narrower list than the batch run
	above uses: this channel's schema carries no Instances, so neither trimming nor padding the
	sidecar changes anything a change reader can see.

	Asserting them here would have passed, and for a reason that has nothing to do with the sidecar:
	a refusal earlier in the run leaves the reader without baselines, so the *next* honest patch is
	refused too and lands in whichever round it happens to fall in. That is the shape §9 calls a test
	passing for the wrong reason, and the fix is to not make the claim rather than to make it
	loosely.
]]
local bytewise = {
	"bit flip",
	"byte substituted",
	"truncated",
	"extended with noise",
	"channel id substituted",
	"replayed",
	"noise",
}

for _, name in bytewise do
	check(`{name} broke a change too`, changeBroke[name] > 0)
end

--[[ **A refusal is a desync.** A change this endpoint could not read leaves it holding a baseline
     the sender has already moved past, so every change after it would merge into the wrong value —
     which is worse than losing one, and is why the channel is given up on rather than patched
     over. ]]
check("and gave up on the channel rather than merging into it", desyncs > 0)

suite.passing()

--[[ The canary's subject, at the end of the run, still holds what the canary says it holds. A
     mutated change that merged into somebody else's baseline would show here and in no assertion
     above, because the handler only ever sees the value one merge produced. ]]
local kept = baselines.of(nil, Mirrored, 9000)

check("the canary's baseline survived every mutation", kept ~= nil and Mirrored.codec.check(kept) == nil)
equals("with the value it was sent", if kept then kept.n else nil, 1)

print(`        {CHANGES} changes, {landed} merged, {removals} removed, {desyncs} desynced`)

for _, mutation in mutations do
	print(
		`        {mutation.name}: {changeExercised[mutation.name]} run, {changeBroke[mutation.name]} refused`
	)
end

-- ---------------------------------------------------------------------------------------------

for _, channel in declared.channels do
	channel.handler = nil
end

Namespace.reset()
Observer.reset()

suite.finish()

return true
