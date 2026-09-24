--!strict

--[[
	The handshake, under lune.

		lune run tests/protocol_runtime

	Two claims are tested here and they pull in opposite directions. The hash has to **move** when
	anything that decides how bytes are read changes — that is the whole point, and it did not move
	before M3 phase 5. And it has to **stay still** when something only one side enforces changes,
	because a hash that moves when the server tunes a rate limit is a hash that forces a client
	redeploy for a server-side edit, which teaches games to stop tuning rate limits.
]]

local Batch = require("../src/transport/Batch")
local Buffer = require("../src/codec/Buffer")
local Inbound = require("../src/transport/Inbound")
local Ir = require("../src/codec/Ir")
local Namespace = require("../src/api/Namespace")
local Observer = require("../src/api/Observer")
local Protocol = require("../src/api/Protocol")
local nw = require("../src/netweave")
local t = require("../src/types")

local failures = 0

local function fail(message: string)
	failures += 1
	print(`FAIL  {message}`)
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

local function differs(name: string, a: any, b: any)
	if a == b then
		fail(`{name}: both were {tostring(a)}`)
	end
end

local allows = nw.policy(function()
	return function()
		return nw.allow()
	end
end)

--[[ Declare, seal, take the hash, reset. A channel record carries its qualified name once it is
     declared, so every case builds its own. ]]
--[[ The builder returns `any` rather than `{ [string]: any }`: a sealed table literal is not a
     subtype of an indexer type under the new solver, and every case here is a literal. ]]
local function hashOf(build: () -> any): number
	Namespace.reset()
	Namespace.declare("probe", build())

	local hash = Namespace.protocol().hash

	Namespace.reset()
	return hash
end

local function signatureOf(build: () -> any): string
	Namespace.reset()
	local declared = Namespace.declare("probe", build())
	Namespace.seal()

	local names: { string } = {}
	local byName: { [string]: any } = {}

	for _, channel in declared.channels do
		table.insert(names, channel.qualified)
		byName[channel.qualified] = channel
	end

	table.sort(names)

	local text = Protocol.signature(names, byName)

	Namespace.reset()
	return text
end

-- ---------------------------------------------------------------------------------------------
-- The change that used to be invisible
-- ---------------------------------------------------------------------------------------------

do
	--[[
		One field, `t.u8` to `t.u16`, and nothing else.

		This is D-7's case. Under the name-only hash both sides computed the same number, agreed,
		and then refused each other on every packet for the rest of the session with nothing saying
		why. The old hash is recomputed below so the correction is measured rather than asserted.
	]]
	local narrow = hashOf(function()
		return { shot = nw.signal({ data = t.struct({ seq = t.u8 }), rate = 20 }) }
	end)

	local wide = hashOf(function()
		return { shot = nw.signal({ data = t.struct({ seq = t.u16 }), rate = 20 }) }
	end)

	differs("widening one field moves the hash", narrow, wide)

	--[[ The hash netweave used to compute, rebuilt here: FNV-1a over the sorted qualified names.
	     Both declarations produce the string "probe.shot", so both produce this number. ]]
	local function overNames(names: { string }): number
		local text = table.concat(names, "\n")
		local hash = 2166136261

		for index = 1, #text do
			hash = bit32.bxor(hash, string.byte(text, index))
			hash = bit32.band(hash * 16777619, 0xFFFFFFFF)
		end

		return hash
	end

	equals(
		"and the hash it replaced could not tell them apart",
		overNames({ "probe.shot" }),
		overNames({ "probe.shot" })
	)
end

do
	--[[ Every other shape of change that reaches the wire. Each pair differs in exactly one thing. ]]
	local cases: { { name: string, a: () -> any, b: () -> any } } = {
		{
			name = "a field renamed",
			a = function()
				return { s = nw.signal({ data = t.struct({ seq = t.u8 }), rate = 20 }) }
			end,
			b = function()
				return { s = nw.signal({ data = t.struct({ tick = t.u8 }), rate = 20 }) }
			end,
		},
		{
			name = "a field added",
			a = function()
				return { s = nw.signal({ data = t.struct({ seq = t.u8 }), rate = 20 }) }
			end,
			b = function()
				return { s = nw.signal({ data = t.struct({ seq = t.u8, hp = t.u8 }), rate = 20 }) }
			end,
		},
		{
			name = "a range narrowed, which narrows the storage",
			a = function()
				return { s = nw.signal({ data = t.struct({ n = t.u16 }), rate = 20 }) }
			end,
			b = function()
				return { s = nw.signal({ data = t.struct({ n = t.u16(0, 200) }), rate = 20 }) }
			end,
		},
		{
			name = "an array bound raised",
			a = function()
				return { s = nw.signal({ data = t.struct({ a = t.array(t.u8, 0, 4) }), rate = 20 }) }
			end,
			b = function()
				return { s = nw.signal({ data = t.struct({ a = t.array(t.u8, 0, 5) }), rate = 20 }) }
			end,
		},
		{
			name = "an enum variant added",
			a = function()
				return {
					s = nw.signal({ data = t.struct({ e = t.enum({ a = true, b = true }) }), rate = 20 }),
				}
			end,
			b = function()
				return {
					s = nw.signal({
						data = t.struct({ e = t.enum({ a = true, b = true, c = true }) }),
						rate = 20,
					}),
				}
			end,
		},
		{
			name = "an enum variant renamed",
			a = function()
				return {
					s = nw.signal({ data = t.struct({ e = t.enum({ a = true, b = true }) }), rate = 20 }),
				}
			end,
			b = function()
				return {
					s = nw.signal({ data = t.struct({ e = t.enum({ a = true, z = true }) }), rate = 20 }),
				}
			end,
		},
		{
			name = "a field made optional",
			a = function()
				return { s = nw.signal({ data = t.struct({ n = t.u8 }), rate = 20 }) }
			end,
			b = function()
				return { s = nw.signal({ data = t.struct({ n = t.optional(t.u8) }), rate = 20 }) }
			end,
		},
		{
			name = "a channel renamed",
			a = function()
				return { s = nw.signal({ data = t.struct({ n = t.u8 }), rate = 20 }) }
			end,
			b = function()
				return { other = nw.signal({ data = t.struct({ n = t.u8 }), rate = 20 }) }
			end,
		},
		{
			name = "a channel's class changed",
			a = function()
				return { s = nw.signal({ data = t.struct({ n = t.u8 }), rate = 20 }) }
			end,
			b = function()
				return { s = nw.intent({ data = t.struct({ n = t.u8 }), rate = 20 }) }
			end,
		},
		{
			name = "a query's returns changed, with its args untouched",
			a = function()
				return {
					q = nw.query({
						args = t.u8,
						returns = t.struct({ v = t.u8 }),
						rate = 2,
						timeout = 5,
						authorize = allows,
					}),
				}
			end,
			b = function()
				return {
					q = nw.query({
						args = t.u8,
						returns = t.struct({ v = t.u16 }),
						rate = 2,
						timeout = 5,
						authorize = allows,
					}),
				}
			end,
		},
	}

	for _, case in cases do
		differs(case.name, hashOf(case.a), hashOf(case.b))
	end
end

-- ---------------------------------------------------------------------------------------------
-- What must not move it
-- ---------------------------------------------------------------------------------------------

do
	--[[
		Server-side policy, all of it. A hash that moved for these would mean a client redeploy every
		time a rate limit is tuned, which is a good way to make sure rate limits are never tuned.
	]]
	local baseline = hashOf(function()
		return {
			s = nw.signal({ data = t.struct({ n = t.u8 }), rate = 20 }),
			e = nw.event({ data = t.struct({ n = t.u8 }), audience = nw.audience.everyone }),
		}
	end)

	equals(
		"the rate does not move the hash",
		hashOf(function()
			return {
				s = nw.signal({ data = t.struct({ n = t.u8 }), rate = 500 }),
				e = nw.event({ data = t.struct({ n = t.u8 }), audience = nw.audience.everyone }),
			}
		end),
		baseline
	)

	equals(
		"nor the burst",
		hashOf(function()
			return {
				s = nw.signal({ data = t.struct({ n = t.u8 }), rate = 20, burst = 40 }),
				e = nw.event({ data = t.struct({ n = t.u8 }), audience = nw.audience.everyone }),
			}
		end),
		baseline
	)

	equals(
		"nor the audience",
		hashOf(function()
			return {
				s = nw.signal({ data = t.struct({ n = t.u8 }), rate = 20 }),
				e = nw.event({ data = t.struct({ n = t.u8 }), audience = nw.audience.nearby(120) }),
			}
		end),
		baseline
	)

	equals(
		"nor whether the channel is unreliable",
		hashOf(function()
			return {
				s = nw.signal({ data = t.struct({ n = t.u8 }), rate = 20, unreliable = true }),
				e = nw.event({ data = t.struct({ n = t.u8 }), audience = nw.audience.everyone }),
			}
		end),
		baseline
	)

	--[[ Field order in the literal. Both peers sort before writing (`WIRE-FORMAT.md` §5), so two
	     declarations that differ only in the order they were typed are the same protocol — and if
	     they were not, the hash would be a coin flip on table iteration order. ]]
	equals(
		"nor the order the fields were written in",
		hashOf(function()
			return { s = nw.signal({ data = t.struct({ a = t.u8, b = t.u16, c = t.boolean }), rate = 20 }) }
		end),
		hashOf(function()
			return { s = nw.signal({ data = t.struct({ c = t.boolean, b = t.u16, a = t.u8 }), rate = 20 }) }
		end)
	)

	--[[ And the same declaration twice. A hash that is not reproducible is not a handshake. ]]
	local function twice()
		return {
			s = nw.signal({ data = t.struct({ n = t.u8, s = t.string(0, 32) }), rate = 20 }),
			q = nw.query({
				args = t.u8,
				returns = t.struct({ v = t.u16 }),
				rate = 2,
				timeout = 5,
				authorize = allows,
			}),
		}
	end

	equals("the same declarations hash the same", hashOf(twice), hashOf(twice))
end

-- ---------------------------------------------------------------------------------------------
-- The hand-kept attribute list
-- ---------------------------------------------------------------------------------------------

do
	--[[
		`Protocol` lists the node attributes that reach the signature rather than walking whatever a
		`Node` happens to carry, because most of what a node carries is a derived position. A list is
		the shape that drifts — the phase 4 audit found `Config`'s limit list missing an entry — so
		this changes each one in turn on a lowered node and asserts the signature notices.
	]]
	local attributes: { [string]: any } = {
		bits = 3,
		fixedSize = 99,
		instances = 7,
		storage = "u32",
		min = -5,
		max = 12345,
		unit = true,
		class = "BasePart",
		lengthStorage = "u16",
		count = 42,
		step = 0.25,
		utf8 = true,
		pattern = "%d+",
		--[[ `t.u53` against `t.f64(0, 2^53)`: same storage, one refuses a fraction (M4-1). ]]
		whole = true,
		--[[ A literal is nothing on the wire, so the signature is the only place the two peers'
		     values meet (`PLAN-M5` phase 5). ]]
		literal = "v3",
		default = 16,
	}

	--[[ The compact cframe reaches the hash through `bits`, `fixedSize` and the component walk, so
	     it needs no attribute of its own: the two declarations differ on all three. ]]
	differs(
		"a compact cframe is not a bare one",
		Protocol.signatureOf({
			qualified = "probe.s",
			class = "signal",
			codec = { layout = Ir.lower(t.cframe(t.i16(-2048, 2048))) },
		}),
		Protocol.signatureOf({
			qualified = "probe.s",
			class = "signal",
			codec = { layout = Ir.lower(t.cframe) },
		})
	)

	local function channelWith(mutate: ((Ir.Node) -> ())?): any
		local layout = Ir.lower(t.struct({ n = t.u8, s = t.string(0, 32) }))

		if mutate then
			mutate(layout.root)
		end

		return {
			qualified = "probe.s",
			class = "signal",
			codec = { layout = layout },
		}
	end

	local baseline = Protocol.signatureOf(channelWith(nil))

	for name, value in attributes do
		local moved = Protocol.signatureOf(channelWith(function(root: Ir.Node)
			(root :: any)[name] = value
		end))

		differs(`the signature covers node.{name}`, moved, baseline)
	end

	--[[ A nested node too, not only the root: the walk has to reach into `fields`. ]]
	local nested = Protocol.signatureOf(channelWith(function(root: Ir.Node)
		local fields = root.fields :: { Ir.Field }
		(fields[1].node :: any).storage = "u32"
	end))

	differs("and reaches a field's own node", nested, baseline)
end

-- ---------------------------------------------------------------------------------------------
-- The signature is readable
-- ---------------------------------------------------------------------------------------------

do
	--[[ A hash that differs says nothing about why. Two peers print this and the line that differs
	     is the declaration that differs, which is the only affordance a deploy skew needs. ]]
	local text = signatureOf(function()
		return { s = nw.signal({ data = t.struct({ seq = t.u16 }), rate = 20 }) }
	end)

	check("the signature names the channel", string.find(text, "probe.s", 1, true) ~= nil)
	check("and its class", string.find(text, "signal", 1, true) ~= nil)
	check("and the field", string.find(text, "seq:", 1, true) ~= nil)
	check("and the storage that field lowered to", string.find(text, "storage=u16", 1, true) ~= nil)
	check("and the framing", string.find(text, "static", 1, true) ~= nil)

	equals("hex is eight digits and a prefix", Protocol.hex(0x1a2b3c4d), "0x1a2b3c4d")
	equals("padded", #Protocol.hex(1), 10)
end

do
	--[[ The same text, through the public surface. A signature nobody can reach from `nw` is not an
	     affordance, and "the hashes do not match" without it is a dead end. ]]
	Namespace.reset()
	Namespace.declare("probe", {
		s = nw.signal({ data = t.struct({ seq = t.u16 }), rate = 20 }),
	})

	local text = nw.signature()

	check("nw.signature names the channel", string.find(text, "probe.s|signal", 1, true) ~= nil)
	check("and the storage its field lowered to", string.find(text, "storage=u16", 1, true) ~= nil)

	Namespace.reset()
end

-- ---------------------------------------------------------------------------------------------
-- The control packet
-- ---------------------------------------------------------------------------------------------

local Ping: any = nil
local byId: { [number]: any } = {}

do
	Namespace.reset()

	local declared = Namespace.declare("probe", {
		ping = nw.signal({ data = t.struct({ seq = t.u8 }), rate = 100 }),
	})

	Namespace.seal()

	Ping = declared.channels.ping
	byId[Ping.id] = Ping
end

type Record = { kind: string, value: any }

local function sinkOf(record: { Record }): Batch.Sink
	return {
		resolve = function(id: number): any
			return byId[id]
		end,

		answers = true,

		--[[ Never reached: this file declares no replicated channel. Present because `Sink` is a
		     closed type, and a stub that raises says so louder than one that quietly does nothing. ]]
		change = function()
			error("protocol_runtime declares no replicated channel")
		end,

		resync = function()
			error("protocol_runtime declares no replicated channel")
		end,

		admit = function(): (string?, Observer.Stage?)
			return nil, "budget"
		end,

		deliver = function(_channel: any, value: any)
			table.insert(record, { kind = "deliver", value = value.seq })
		end,

		reply = function()
			table.insert(record, { kind = "reply", value = 0 })
		end,

		hello = function(hash: number)
			table.insert(record, { kind = "hello", value = hash })
		end,

		refuse = function(_channel: any?, stage: string, reason: string)
			table.insert(record, { kind = "refuse", value = `{stage}: {reason}` })
		end,
	}
end

do
	local record: { Record } = {}

	Buffer.load(nil)
	Batch.writeHello(0xdeadbeef)

	equals("a hello is a version byte, id 0, a kind, a length and four bytes", buffer.len((Buffer.take())), 8)

	Buffer.load(nil)
	Batch.writeHello(0xdeadbeef)
	Batch.writePacket(Ping, { seq = 5 })

	local packed = Buffer.take()

	equals("and it batches with what follows it", buffer.len(packed), 10)

	Batch.read(packed, nil, sinkOf(record))

	equals("two packets came out", #record, 2)
	equals("the hello first", record[1].kind, "hello")
	equals("carrying the hash", record[1].value, 0xdeadbeef)
	equals("and the packet behind it decoded", record[2].value, 5)
end

do
	--[[
		A control kind this build has never heard of.

		Reserved id 0 is meant to carry "whatever v2 needs", and a reserved slot that cannot be
		extended without breaking every v1 reader is not reserved for anything. The length prefix is
		what makes the unknown one steppable, so this writes one by hand and checks the batch
		survives it.
	]]
	local record: { Record } = {}

	Buffer.load(nil)
	Buffer.writeU8(Batch.VERSION)
	Buffer.writeVarint(0)
	Buffer.writeU8(99)
	Buffer.writeVarint(3)
	Buffer.writeU8(1)
	Buffer.writeU8(2)
	Buffer.writeU8(3)
	Batch.writePacket(Ping, { seq = 6 })

	local packed = Buffer.take()

	Batch.read(packed, nil, sinkOf(record))

	equals("the unknown kind was reported and stepped over", #record, 2)
	equals("reported", record[1].kind, "refuse")
	check("naming the kind", string.find(tostring(record[1].value), "control kind 99", 1, true) ~= nil)
	equals("and the packet behind it still arrived", record[2].value, 6)
end

do
	--[[ A control packet whose declared body runs off the end. There is nothing behind it to
	     resynchronise on, so the batch stops — the same rule as a length that overruns. ]]
	local record: { Record } = {}

	Buffer.load(nil)
	Buffer.writeU8(Batch.VERSION)
	Buffer.writeVarint(0)
	Buffer.writeU8(Batch.HELLO)
	Buffer.writeVarint(200)
	Buffer.writeU32(1)

	local packed = Buffer.take()
	local survived = pcall(Batch.read, packed, nil, sinkOf(record))

	check("an overrunning control body does not raise", survived)
	equals("it is refused", #record, 1)
	equals("at parse", record[1].kind, "refuse")
	check("naming the overrun", string.find(tostring(record[1].value), "past the batch", 1, true) ~= nil)
end

-- ---------------------------------------------------------------------------------------------
-- Agreement
-- ---------------------------------------------------------------------------------------------

do
	local alice = { name = "alice" }
	local bob = { name = "bob" }

	local announced: { any } = {}
	local mine = 0x11223344

	local agreement = Protocol.new({
		hash = function(): number
			return mine
		end,

		announce = function(who: any?)
			table.insert(announced, who)
		end,

		isServer = true,
	})

	check("a peer that has said nothing is accepted", agreement.verdict(alice) == nil)
	equals("and nothing was announced at it", #announced, 0)

	agreement.greet(alice, mine)
	check("a peer that agrees is accepted", agreement.verdict(alice) == nil)
	equals("and is not answered", #announced, 0)

	agreement.greet(bob, 0x99999999)

	local verdict = agreement.verdict(bob)
	check("a peer that disagrees is refused", verdict ~= nil)
	check("the reason carries their hash", string.find(verdict or "", "0x99999999", 1, true) ~= nil)
	check("and this one's", string.find(verdict or "", "0x11223344", 1, true) ~= nil)
	equals("the server answers a mismatch so the other console says so too", #announced, 1)
	equals("addressed to the peer that got it wrong", announced[1], bob)

	check("and the peer that agreed is untouched", agreement.verdict(alice) == nil)

	--[[
		A hello flood, which is the cheapest thing a client can send that makes the server work.

		Id 0 is read before `sink.admit` — resolving it would fail, and that failure would be the
		unrecoverable one — so nothing charges a hello a rate. Every mismatched one used to build a
		fresh reason and answer with a hello of this peer's own; an external review measured 300 in
		one 2,101-byte batch costing 300 replies and 76 KB (M3 phase 9). A peer already known to be
		wrong is not re-judged now, whether it repeats itself or rotates its hash, because the only
		thing that lifts a refusal is a hash that agrees.
	]]
	for index = 1, 300 do
		agreement.greet(bob, if index % 2 == 0 then 0x99999999 else 0x12345678 + index)
	end

	equals("three hundred more hellos are answered no more", #announced, 1)
	check("and the verdict still stands", agreement.verdict(bob) ~= nil)
	check("naming the hash they first claimed", string.find(verdict or "", "0x99999999", 1, true) ~= nil)

	--[[ A rejoin on a fixed build. The refusal is per peer and is cleared, not sticky. ]]
	agreement.greet(bob, mine)
	check("agreeing later clears the refusal", agreement.verdict(bob) == nil)
end

-- ---------------------------------------------------------------------------------------------
-- Naming the namespace a mismatch is in (PLAN-M5 D-7)
-- ---------------------------------------------------------------------------------------------

--[[
	Two hashes say that two builds disagree. The per-namespace digest beside the hello says where,
	which is what the person at the console can act on. Confirmed to fail on the pre-fix tree by
	absence: `Protocol.difference`, `namespaces` on the protocol and `digest` on the agreement did not
	exist, and the reason named two hashes and nothing else.
]]

do
	--[[ The protocol's own digest: one entry per namespace, in name order, and a change inside one
	     namespace moves that entry alone. ]]
	local function digestOf(declaration: { [string]: { [string]: any } }): Protocol.Protocol
		local names: { string } = {}
		local byName: { [string]: any } = {}

		for space, channels in declaration do
			for key, channel in channels do
				local qualified = `{space}.{key}`
				table.insert(names, qualified)
				byName[qualified] = channel
			end
		end

		table.sort(names)
		return Protocol.digest(names, byName)
	end

	local base = digestOf({
		combat = { fire = nw.signal({ data = t.u8, rate = 1 }), aim = nw.signal({ data = t.u16, rate = 1 }) },
		vault = { open = nw.signal({ data = t.u8, rate = 1 }) },
	})

	equals("one digest entry per namespace", #base.namespaces, 2)
	equals("in name order", base.namespaces[1].name, "combat")
	equals("and the second", base.namespaces[2].name, "vault")

	local widened = digestOf({
		combat = { fire = nw.signal({ data = t.u8, rate = 1 }), aim = nw.signal({ data = t.u32, rate = 1 }) },
		vault = { open = nw.signal({ data = t.u8, rate = 1 }) },
	})

	check("the whole hash moves when a channel widens", widened.hash ~= base.hash)
	check("and so does its namespace's", widened.namespaces[1].hash ~= base.namespaces[1].hash)
	equals("while the other namespace's does not", widened.namespaces[2].hash, base.namespaces[2].hash)

	--[[ The three shapes a difference takes, each said from this peer's side. ]]
	local missing = digestOf({
		combat = { fire = nw.signal({ data = t.u8, rate = 1 }), aim = nw.signal({ data = t.u16, rate = 1 }) },
	})

	local fromBase = Protocol.difference(base.namespaces, missing.namespaces) or ""
	check("a namespace only this peer declares is named", string.find(fromBase, '"vault"', 1, true) ~= nil)
	check("as this peer's", string.find(fromBase, "this peer declares", 1, true) ~= nil)

	local fromMissing = Protocol.difference(missing.namespaces, base.namespaces) or ""
	check("and from the other side it is the peer's", string.find(fromMissing, '"vault"', 1, true) ~= nil)
	check("said so", string.find(fromMissing, "the peer declares", 1, true) ~= nil)

	local inside = Protocol.difference(base.namespaces, widened.namespaces) or ""
	check(
		"a channel differing inside a shared namespace names the namespace",
		string.find(inside, '"combat"', 1, true) ~= nil
	)
	check("and says it is inside", string.find(inside, "inside the namespace", 1, true) ~= nil)

	check(
		"two identical digests differ nowhere",
		Protocol.difference(base.namespaces, base.namespaces) == nil
	)

	--[[ Through the agreement: a refused peer's reason is rewritten once, the second and the three
	     hundredth digest are not decoded, and agreeing later clears the name with the refusal. ]]
	local bob = { name = "bob" }
	local announced = 0

	local agreement = Protocol.new({
		hash = function(): number
			return base.hash
		end,

		announce = function()
			announced += 1
		end,

		namespaces = function()
			return base.namespaces
		end,

		isServer = true,
	})

	check("a peer that has not said hello is not wanted", not agreement.wants(bob))
	check("and its digest changes nothing", agreement.digest(bob, missing.namespaces) == nil)

	agreement.greet(bob, missing.hash)
	check("a refused peer's digest is wanted", agreement.wants(bob))
	check("until it arrives", string.find(agreement.verdict(bob) or "", '"vault"', 1, true) == nil)

	local named = agreement.digest(bob, missing.namespaces)
	check(
		"the first digest names the namespace",
		named ~= nil and string.find(named, '"vault"', 1, true) ~= nil
	)
	check("and the verdict is that reason from now on", agreement.verdict(bob) == named)
	check("and no further digest is wanted", not agreement.wants(bob))

	for _ = 1, 300 do
		check("nor changes anything", agreement.digest(bob, widened.namespaces) == nil)
	end

	check(
		"the reason still names the first one",
		string.find(agreement.verdict(bob) or "", '"vault"', 1, true) ~= nil
	)
	equals("and the answer was one hello, not three hundred", announced, 1)

	agreement.greet(bob, base.hash)
	check(
		"agreeing clears the name with the refusal",
		agreement.verdict(bob) == nil and not agreement.wants(bob)
	)

	--[[ On the wire: a digest beside a hello round-trips, the packet behind it decodes, and a body
	     claiming more namespaces than a declaration can hold is refused rather than allocated. ]]
	local record: { Record } = {}
	local decoded: { Protocol.NamespaceDigest }? = nil
	local sink = sinkOf(record)

	sink.digest = function()
		decoded = Batch.readDigest()
	end

	Buffer.load(nil)
	Batch.writeHello(base.hash)
	Batch.writeDigest(base.namespaces)
	Batch.writePacket(Ping, { seq = 9 })

	Batch.read(Buffer.take(), nil, sink)

	check("the digest decodes", decoded ~= nil)
	equals("with both namespaces", if decoded then #decoded else 0, 2)
	equals("their names", if decoded then decoded[2].name else "", "vault")
	equals("and their hashes", if decoded then decoded[1].hash else 0, base.namespaces[1].hash)
	equals("and the packet behind it decoded", record[#record].value, 9)

	local many: { Protocol.NamespaceDigest } = {}
	for index = 1, 1025 do
		many[index] = { name = `n{index}`, hash = index }
	end

	decoded = nil
	Buffer.load(nil)
	Batch.writeDigest(many)
	Batch.read(Buffer.take(), nil, sink)
	check("a digest past the namespace bound is refused, not decoded", decoded == nil)

	agreement.greet(bob, 0x99999999)
	agreement.forget(bob)
	check("and leaving clears it", agreement.verdict(bob) == nil)
end

do
	--[[ The client's side: one peer, no player, and `nil` is not a table key. ]]
	local agreement = Protocol.new({
		hash = function(): number
			return 7
		end,

		announce = function()
			fail("a client must not answer a mismatch; there is nobody it could tell")
		end,

		isServer = false,
	})

	agreement.greet(nil, 8)
	check("the client refuses a server it disagrees with", agreement.verdict(nil) ~= nil)

	agreement.greet(nil, 7)
	check("and accepts one it agrees with", agreement.verdict(nil) == nil)
end

-- ---------------------------------------------------------------------------------------------
-- Refusal, end to end
-- ---------------------------------------------------------------------------------------------

do
	local bob = { name = "bob" }
	local reported: { string } = {}
	local delivered: { number } = {}

	Observer.reset()
	Observer.observe(function(rejection)
		table.insert(reported, `{rejection.stage}:{rejection.reason}`)
	end)

	local mine = Namespace.protocol().hash

	local agreement = Protocol.new({
		hash = function(): number
			return mine
		end,

		announce = function() end,
		isServer = true,
	})

	local inbound = Inbound.new({
		resolve = function(id: number): any
			return byId[id]
		end,

		admit = function(): string?
			return nil
		end,

		isServer = true,
		agreement = agreement,
	})

	Ping.handler = function(_ctx, value)
		table.insert(delivered, value.seq)
	end

	--[[
		The hello and three payloads, in one batch, from a peer on the wrong build.

		The packets behind the hello are the ones that matter. They are in the same batch, so a check
		that ran per batch rather than per packet would let all three land — and they would land as
		well-formed payloads, because a wrong id resolves to a real channel whose schema happens to
		accept those bytes. That is worse than a decode failure, and it is what D-7 is written
		against.
	]]
	Buffer.load(nil)
	Batch.writeHello(mine + 1)

	for seq = 1, 3 do
		Batch.writePacket(Ping, { seq = seq })
	end

	local packed = Buffer.take()
	local survived = pcall(inbound.receive, packed, nil, bob)

	check("the batch did not raise", survived)
	equals("nothing behind the hello was delivered", #delivered, 0)
	--[[ Four, not three: the hello itself is reported now. Until M3 phase 9 a mismatch was recorded
	     silently and first surfaced on a data packet behind it, so a peer that sent a hello and
	     nothing else disagreed with this one forever without either console saying so. ]]
	equals("the hello and all three behind it were refused", #reported, 4)
	check("at stage protocol", string.find(reported[1], "protocol:", 1, true) ~= nil)
	check("with both hashes in the reason", string.find(reported[1], Protocol.hex(mine), 1, true) ~= nil)

	--[[ Once at join, not per packet: a later batch from the same peer is refused from the
	     recorded verdict, without a second hello and without re-hashing anything. ]]
	table.clear(reported)

	Buffer.load(nil)
	Batch.writePacket(Ping, { seq = 9 })

	local later = Buffer.take()
	inbound.receive(later, nil, bob)

	equals("a later batch is refused too", #reported, 1)
	equals("and still delivered nothing", #delivered, 0)

	--[[ And the peer on the right build, through the same inbound. ]]
	local alice = { name = "alice" }
	table.clear(reported)

	Buffer.load(nil)
	Batch.writeHello(mine)
	Batch.writePacket(Ping, { seq = 4 })

	inbound.receive(Buffer.take(), nil, alice)

	equals("a peer that agrees is delivered", #delivered, 1)
	equals("its payload", delivered[1], 4)
	equals("with nothing reported", #reported, 0)

	--[[ A peer that never says hello. Accepted, deliberately: the handshake diagnoses deploy skew
	     and is not an authorization boundary, so refusing a silent peer would cost a real client
	     whose hello was lost and gain nothing against one that simply omits it. ]]
	local carol = { name = "carol" }

	Buffer.load(nil)
	Batch.writePacket(Ping, { seq = 8 })
	inbound.receive(Buffer.take(), nil, carol)

	equals("a silent peer is accepted", #delivered, 2)
	equals("its payload", delivered[2], 8)

	Ping.handler = nil
	Observer.reset()
end

-- ---------------------------------------------------------------------------------------------
-- Every layout a channel carries, not every attribute of one of them
-- ---------------------------------------------------------------------------------------------

do
	--[[
		The attribute walk above changes each field of a lowered *node* and asserts the signature
		notices. It cannot notice a **second layout**, because a second layout is not an attribute of
		the first one's nodes — and that is how `nw.replicate`'s `subject` schema stayed out of the
		hash for the whole of M4.

		A change packet is `id length [instances] subject flags [fields]`. A peer reading `t.u8`
		where the sender wrote `t.u16` is one byte short for every change on that channel, and for a
		subject id below 256 the byte it takes for the flags is `0x00` — a **removal**, well formed,
		delivered to the handler. The one failure the handshake exists to catch, arriving through the
		one schema it was not reading.

		So this walks the channel rather than the node: every codec a class can carry, changed alone,
		with the hash asserted to move. A seventh class that adds an eighth codec fails here until it
		is described.
	]]
	--[[ Each declaration is written out rather than built from parameters: `nw.replicate`'s
	     `subject` and `data` are read by type functions at analysis, and a schema arriving through an
	     `any` parameter is not a schema they can read. The four cases differ by one field each. ]]
	local function shapeOf(channels: { [string]: any }): (number, string)
		Namespace.reset()

		local declared = Namespace.declare("shape", channels)
		local protocol = Namespace.seal()

		return protocol.hash, Protocol.signatureOf(declared.channels.mirrored)
	end

	local base, baseText = shapeOf({
		mirrored = nw.replicate({
			subject = t.u16,
			data = t.struct({ n = t.u8 }),
			audience = nw.audience.everyone,
			store = nw.store.of({}),
		}),
	})

	local narrowed, narrowedText = shapeOf({
		mirrored = nw.replicate({
			subject = t.u8,
			data = t.struct({ n = t.u8 }),
			audience = nw.audience.everyone,
			store = nw.store.of({}),
		}),
	})

	differs("narrowing the subject moves the hash", narrowed, base)
	differs("and the signature says so", narrowedText, baseText)

	local restructured = shapeOf({
		mirrored = nw.replicate({
			subject = t.struct({ a = t.u8, b = t.u8 }),
			data = t.struct({ n = t.u8 }),
			audience = nw.audience.everyone,
			store = nw.store.of({}),
		}),
	})

	differs("so does changing its shape entirely", restructured, base)

	--[[ The control: the schema that was always covered still moves it, so a hash that moves for
	     everything would not pass this section either. ]]
	local moved = shapeOf({
		mirrored = nw.replicate({
			subject = t.u16,
			data = t.struct({ n = t.u16 }),
			audience = nw.audience.everyone,
			store = nw.store.of({}),
		}),
	})

	differs("the data schema still moves it too", moved, base)

	local again = shapeOf({
		mirrored = nw.replicate({
			subject = t.u16,
			data = t.struct({ n = t.u8 }),
			audience = nw.audience.everyone,
			store = nw.store.of({}),
		}),
	})

	equals("and the same declarations still hash the same", again, base)

	--[[
		**Two quantised fields that lower identically and mean different things.**

		`t.quantized(-1, 1, 2 / 254)` and `t.quantized(-1, 1, 2 / 200)` both take one byte, both
		declare `-1..1`, and both lower to `storage = u8`. Every attribute the signature described
		before phase 8 was the same for the two, and every byte on the wire meant something different
		— a peer decoding with the wrong step gets a plausible number, silently, for ever.

		That is the `subject` failure in a third place, and it is why the walk above gained `step`.
		This is the end-to-end half: through `t.quantized` rather than by poking a node, so a `step`
		that stopped reaching the lowered node would fail here too.
	]]
	local coarse = shapeOf({
		mirrored = nw.replicate({
			subject = t.u16,
			data = t.struct({ n = t.quantized(-1, 1, 2 / 200) }),
			audience = nw.audience.everyone,
			store = nw.store.of({}),
		}),
	})

	local fine = shapeOf({
		mirrored = nw.replicate({
			subject = t.u16,
			data = t.struct({ n = t.quantized(-1, 1, 2 / 254) }),
			audience = nw.audience.everyone,
			store = nw.store.of({}),
		}),
	})

	differs("two steps in the same byte and the same bounds hash differently", fine, coarse)

	--[[
		**A union's branches, which the walk over `variants` alone cannot see.**

		The branch *names* reach the signature through `variants`, because that is the tag order. What
		each name carries is a second layer, and two builds agreeing on the names while disagreeing on
		one branch's schema is the same failure as two builds disagreeing on a struct field — with the
		tag reading correctly and the bytes under it read as something else.
	]]
	--[[
		The pair is `u8` against `i8` rather than `u8` against `u16`, and the difference is the point.

		A widened branch changes the union's own `fixedSize` and `maxSize`, which are on the layout
		header the signature prints before it walks a single node — so that pair moves the hash
		whether or not anything reads `branches`, and asserting it would have been asserting nothing.
		Measured: with the branch walk deleted, the widened pair still passed.

		`t.i8` and `t.u8` both narrow to one unsigned byte. Same bits, same fixed size, same ceiling;
		what differs is the branch's declared range, which is reachable only through the branch.
	]]
	local narrow = shapeOf({
		mirrored = nw.replicate({
			subject = t.u16,
			data = t.struct({ act = t.union({ move = t.u8, wait = t.u8 }) }),
			audience = nw.audience.everyone,
			store = nw.store.of({}),
		}),
	})

	local signed = shapeOf({
		mirrored = nw.replicate({
			subject = t.u16,
			data = t.struct({ act = t.union({ move = t.i8, wait = t.u8 }) }),
			audience = nw.audience.everyone,
			store = nw.store.of({}),
		}),
	})

	differs("one branch's range moves the hash, at the same size", signed, narrow)

	--[[ And a branch renamed, which moves the tag order under every other branch. ]]
	local renamed = shapeOf({
		mirrored = nw.replicate({
			subject = t.u16,
			data = t.struct({ act = t.union({ move = t.u8, zzz = t.u8 }) }),
			audience = nw.audience.everyone,
			store = nw.store.of({}),
		}),
	})

	differs("and a branch renamed moves it too", renamed, narrow)

	--[[ A vector's component schema is a node under `element`, so the walk that already reaches an
	     array's element reaches this one — and two vectors of the same kind carrying different
	     components read different bytes for the same three axes. ]]
	local loose = shapeOf({
		mirrored = nw.replicate({
			subject = t.u16,
			data = t.struct({ at = t.vector3 }),
			audience = nw.audience.everyone,
			store = nw.store.of({}),
		}),
	})

	local bounded = shapeOf({
		mirrored = nw.replicate({
			subject = t.u16,
			data = t.struct({ at = t.vector3(t.i16(-2048, 2048)) }),
			audience = nw.audience.everyone,
			store = nw.store.of({}),
		}),
	})

	local tighter = shapeOf({
		mirrored = nw.replicate({
			subject = t.u16,
			data = t.struct({ at = t.vector3(t.i16(-1024, 1024)) }),
			audience = nw.audience.everyone,
			store = nw.store.of({}),
		}),
	})

	--[[ The second pair is the one that is load-bearing, and the first would have passed without the
	     walk: naming a component takes a `vector3` from twelve bytes to six, which is on the layout
	     header the signature prints before it reaches a node. Two six-byte vectors differing only in
	     their components' range is what isolates it — measured, by deleting the walk. ]]
	differs("naming a vector's components moves the hash", bounded, loose)
	differs("and so does narrowing them further, at the same size", tighter, bounded)

	--[[ The patch layout is derived from `data`, so it cannot move on its own — what it earns is a
	     cross-check: two peers whose data schemas somehow agreed while their derivations did not
	     would differ here. Asserted as *presence* in the text rather than as a difference, because
	     an assertion that it moves alone would be asserting the derivation is not a derivation. ]]
	check("the change layout is described", string.find(baseText, "change", 1, true) ~= nil)
	check("and so is the subject", string.find(baseText, "subject", 1, true) ~= nil)

	Namespace.reset()
end

-- ---------------------------------------------------------------------------------------------

Namespace.reset()

if failures > 0 then
	error(`{failures} protocol assertions failed`)
end

print("OK      protocol_runtime")

return true
