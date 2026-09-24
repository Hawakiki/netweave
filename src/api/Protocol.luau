--!strict
--!optimize 2

--[=[
	@class Protocol

	What two peers must agree on before a single packet between them means anything, and a record of
	who has agreed.

	Internal. `nw.protocol()` is the public read of it.
]=]

--[[
	The hash covers the lowered IR, not the channel names — corrected in M3 phase 5 (`PLAN-M3` D-7).

	Until then it was FNV-1a over the sorted qualified names, which catches a channel added, removed
	or renamed and misses the change that actually bites: a **field's type**. Changing `seq` from
	`t.u8` to `t.u16` left the hash identical, so a stale client connected successfully and was then
	refused on every packet for the rest of the session, with nothing anywhere saying why. That is
	the failure this file exists to convert into one legible line at join.

	What goes in is everything both peers need in order to read each other's bytes:

	  * the qualified name, because that is what the id is sorted from
	  * the class, because a peer that thinks a channel is a `signal` where this one thinks it is a
	    `command` is running a different program
	  * the lowered node tree of every schema the channel carries — `data`, or `args` and `returns`,
	    and for `replicate` the **`subject`** as well as the patch layout derived from `data`. That
	    sentence was true of the code for every class but the seventh: `subject` was left out for the
	    whole of M4, so two builds differing only in it hashed identically while one of them read a
	    change one byte short (M4 phase 8, and `Protocol.signatureOf`)
	  * the derived layout numbers, which are a cross-check: if two peers' node trees somehow agree
	    while their framing or their maximum size does not, the lowering itself has diverged

	What stays out is everything only one side enforces: `rate`, `burst`, `maxBytes`, `authorize`,
	`audience`, `unreliable`. Those are the server's policy, and putting them in the hash would make
	tuning a rate limit on the server force every client to redeploy — which would teach games to
	stop tuning rate limits.

	**32 bits, and that is a deploy-skew detector rather than a cryptographic claim.** Two genuinely
	different protocols collide with probability 2^-32. Nothing here resists an adversary choosing a
	collision, and nothing needs to: a client that forges a matching hash still has every field of
	every packet validated against the schema it claims to share.
]]

local Ir = require("../codec/Ir")

local Protocol = {}

--[=[
	@interface Protocol
	@within Protocol
	.hash number -- FNV-1a over the lowered IR of every channel
	.count number -- how many channels were numbered
	.names { string } -- sorted, so `names[id]` is the channel with that id

	What both peers must agree on before any packet is meaningful.
]=]
export type Protocol = {
	hash: number,
	count: number,
	names: { string },
	--[[ One entry per namespace in name order, each hashing that namespace's channels alone, so a
	     mismatch can be named (`PLAN-M5` D-7). The whole `hash` still decides. ]]
	namespaces: { NamespaceDigest },
}

--[=[
	@interface NamespaceDigest
	@within Protocol
	.name string
	.hash number -- FNV-1a over the signatures of that namespace's channels, in id order
]=]
export type NamespaceDigest = { name: string, hash: number }

--[[
	The node attributes that reach the wire, listed rather than walked.

	A `Node` also carries `offset`, `chunkIndex`, `mask` and the rest of the bit-packing positions.
	Those are derived deterministically from everything below, so two peers whose trees agree have
	the same offsets, and including them would be noise. What is here is the set that *decides* the
	bytes.

	It is a hand-kept list, which is the shape that drifts — the phase 4 audit found `limitNames` in
	`Config` missing an entry for exactly that reason. `tests/protocol_runtime.luau` is the guard: it
	changes each attribute in turn and asserts the hash moves.
]]
local ATTRIBUTES: { string } = {
	"bits",
	"fixedSize",
	"instances",
	"storage",
	"min",
	"max",
	--[[ `t.string(1, 20, { pattern = "%d+" })` and a plain `t.string(1, 20)` are the same bytes and
	     different protocols: a peer without the pattern accepts what a peer with it refuses. Same
	     argument as `unit` on a vector, which has always been here. ]]
	"utf8",
	"pattern",
	--[[ `t.quantized(-1, 1, 2 / 254)` and `t.quantized(-1, 1, 2 / 200)` lower to the same storage,
	     the same bounds and different meanings for every byte on the wire. Without this they hashed
	     identically and printed byte-identical signatures — the `subject` failure below, in a third
	     place. ]]
	"step",
	--[[ `t.u53` is an f64 on the wire with a wholeness check; `t.f64(0, 2^53)` is the same storage
	     without it. Same bytes, different protocols — one peer refuses 1.5 and the other delivers
	     it — and until M4-1 they hashed identically, the `step` failure above in a fourth place.
	     Every reader-side attribute belongs here for the same reason. ]]
	"whole",
	"unit",
	"class",
	"lengthStorage",
	"count",
}
table.freeze(ATTRIBUTES)

local function describe(node: Ir.Node, out: { string })
	table.insert(out, node.kind)
	table.insert(out, "(")

	for _, name in ATTRIBUTES do
		local value: any = (node :: any)[name]

		if value ~= nil then
			table.insert(out, `{name}={tostring(value)};`)
		end
	end

	--[[ With its type, because `tostring` folds `1` and `"1"` together and a peer declaring the
	     string where this one declares the number is a peer that disagrees. ]]
	if node.literal ~= nil then
		table.insert(out, `literal={typeof(node.literal)}:{tostring(node.literal)};`)
	end

	--[[ Same again: a default is read on one side and never sent, so the two declarations meet
	     only here. ]]
	if node.default ~= nil then
		table.insert(out, `default={typeof(node.default)}:{tostring(node.default)};`)
	end

	--[[ Variant order is the wire's tag order (`WIRE-FORMAT.md` §5), so it is written in the order
	     the lowering fixed rather than re-sorted here. ]]
	if node.variants then
		table.insert(out, "variants[")

		for _, variant in node.variants :: { string } do
			table.insert(out, `{variant};`)
		end

		table.insert(out, "]")
	end

	if node.inner then
		table.insert(out, "inner:")
		describe(node.inner :: Ir.Node, out)
	end

	if node.key then
		table.insert(out, "key:")
		describe(node.key :: Ir.Node, out)
	end

	if node.value then
		table.insert(out, "value:")
		describe(node.value :: Ir.Node, out)
	end

	if node.element then
		table.insert(out, "element:")
		describe(node.element :: Ir.Node, out)
	end

	--[[ A union's branch *names* come through `variants` above, which is the tag order. These are
	     what each name carries, and two builds that agree on the names and disagree on one branch's
	     schema is the same failure as two builds disagreeing on a struct field. ]]
	if node.branches then
		table.insert(out, "branches[")

		for _, branch in node.branches :: { Ir.Field } do
			table.insert(out, `{branch.name}:`)
			describe(branch.node, out)
			table.insert(out, ";")
		end

		table.insert(out, "]")
	end

	--[[ A fixed-length array with per-position flags lowers one node per position, and those nodes
	     can differ from one another — so each is written, not just the first. ]]
	if node.elements then
		for index, positioned in node.elements :: { Ir.Node } do
			table.insert(out, `[{index}]`)
			describe(positioned, out)
		end
	end

	--[[ Fields are already in sorted name order, because that is the order they reach the wire in.
	     Re-sorting here would hide a lowering that stopped sorting. ]]
	if node.fields then
		for _, field in node.fields :: { Ir.Field } do
			table.insert(out, `{field.name}:`)
			describe(field.node, out)
		end
	end

	table.insert(out, ")")
end

local function describeLayout(label: string, layout: Ir.Layout?, out: { string })
	if not layout then
		return
	end

	local resolved = layout :: Ir.Layout

	table.insert(out, label)
	table.insert(out, "=")
	table.insert(out, `{resolved.framing}/{tostring(resolved.fixedSize)}/{resolved.maxSize}/`)
	table.insert(out, `{tostring(resolved.instances)}:`)
	describe(resolved.root, out)
	table.insert(out, "\n")
end

--[=[
	@within Protocol
	@function signatureOf
	@param channel Channel
	@return string

	One channel's contribution to the hash, as text.

	Exposed because a hash that differs tells you nothing about *why*. Two peers can print their
	signatures and diff them, and the line that differs is the declaration that differs.
]=]
function Protocol.signatureOf(channel: any): string
	local out: { string } = {}

	table.insert(out, channel.qualified)
	table.insert(out, "|")
	table.insert(out, channel.class)
	table.insert(out, "\n")

	describeLayout("data", channel.codec and channel.codec.layout, out)
	describeLayout("returns", channel.responseCodec and channel.responseCodec.layout, out)

	--[[
		**The subject is on the wire, so it is in the hash.**

		A change packet is `id length [instances] subject flags [fields]` (`WIRE-FORMAT.md` §2): the
		subject's bytes come first and the patch is read at whatever offset they end. A peer that
		reads `t.u8` where the sender wrote `t.u16` is one byte short for every change on that
		channel, forever — and for a subject id below 256 the byte it reads as the flags is `0x00`,
		which is a **removal**: a well-formed packet, delivered to the handler, saying a subject went
		away. Nothing refuses it.

		Until M4 phase 8 this walked `data` and `returns` only, so two builds differing only in
		`subject` hashed identically and printed byte-identical signatures. That is exactly the
		failure class M3 phase 5 closed for field types (`PLAN-M3` D-7), reproduced by the class M4
		added — which is the argument for describing every *layout* a channel carries rather than
		listing the ones that existed when this was written.

		`tests/protocol_runtime.luau` walks node attributes and could not see it: a second layout is
		not an attribute of the first one's nodes.
	]]
	describeLayout("subject", channel.subjectCodec and channel.subjectCodec.layout, out)

	--[[ The patch layout is derived from `data` and cannot disagree with it while the derivation is
	     the same on both peers — so this is a cross-check on the derivation rather than a second
	     schema, in the same spirit as the framing and size numbers `describeLayout` already ends
	     each line with. ]]
	describeLayout("change", channel.delta and channel.delta.layout, out)

	return table.concat(out)
end

--[[
	FNV-1a, 32-bit (`WIRE-FORMAT.md` §4).

	Chosen for being four lines that both peers can be trusted to implement identically, which is
	the only property that matters here — see the note at the top about what this is not.
]]
local function fnv1a(text: string): number
	local hash = 2166136261

	for index = 1, #text do
		hash = bit32.bxor(hash, string.byte(text, index))
		hash = bit32.band(hash * 16777619, 0xFFFFFFFF)
	end

	return hash
end

--[=[
	@within Protocol
	@function signature
	@param names { string } -- qualified names, already sorted into id order
	@param byName { [string]: any } -- the channel behind each name
	@return string

	The whole program's signature: every channel in id order, one block each.
]=]
function Protocol.signature(names: { string }, byName: { [string]: any }): string
	local out: { string } = {}

	for _, qualified in names do
		table.insert(out, Protocol.signatureOf(byName[qualified]))
	end

	return table.concat(out)
end

--[=[
	@within Protocol
	@function digest
	@param names { string } -- qualified names, already sorted into id order
	@param byName { [string]: any }
	@return Protocol
]=]
function Protocol.digest(names: { string }, byName: { [string]: any }): Protocol
	--[[
		One hash per namespace beside the whole, so a disagreement can be named (`PLAN-M5` D-7).

		`names` is sorted, and a namespace's channels sort together — `a.x` < `a.y` < `ab.x`, because
		`.` sorts before every letter — so one pass with a running group is enough, and the per-
		namespace signature is the same block per channel that the whole hash is built from.
	]]
	local namespaces: { NamespaceDigest } = {}
	local current: string? = nil
	local parts: { string } = {}

	local function close()
		if current ~= nil then
			--[[ The list is frozen below; the entries are not, because `table.freeze` gives them a
			     read-only type that is not the `NamespaceDigest` a digest packet decodes into. ]]
			table.insert(namespaces, { name = current, hash = fnv1a(table.concat(parts)) })
		end
	end

	for _, qualified in names do
		local dot = string.find(qualified, ".", 1, true)
		local space = if dot then string.sub(qualified, 1, dot - 1) else qualified

		if space ~= current then
			close()
			current = space
			parts = {}
		end

		table.insert(parts, Protocol.signatureOf(byName[qualified]))
	end

	close()

	return table.freeze({
		hash = fnv1a(Protocol.signature(names, byName)),
		count = #names,
		names = table.freeze(names),
		namespaces = table.freeze(namespaces),
	}) :: any
end

--[=[
	@within Protocol
	@function difference
	@param mine { NamespaceDigest } -- this peer's, sorted by name
	@param theirs { NamespaceDigest } -- the other peer's, as its digest packet carried them
	@return string? -- the first namespace the two disagree on, said from this peer's side; nil if none

	Which namespace a protocol mismatch is in. The whole hash says *that* two builds disagree; this
	says *where*, which is what the person at the console needs. One difference is named, the first
	in name order, because a reason is one sentence.
]=]
function Protocol.difference(mine: { NamespaceDigest }, theirs: { NamespaceDigest }): string?
	local i, j = 1, 1

	while i <= #mine or j <= #theirs do
		local a = mine[i]
		local b = theirs[j]

		if a and b and a.name == b.name then
			if a.hash ~= b.hash then
				return `the two disagree inside the namespace "{a.name}": a channel in it has another `
					.. `name, class or schema on the peer`
			end

			i += 1
			j += 1
		elseif b and (not a or b.name < a.name) then
			return `the peer declares a namespace "{b.name}" that this peer does not`
		else
			return `this peer declares a namespace "{(a :: NamespaceDigest).name}" that the peer does not`
		end
	end

	return nil
end

--[=[
	@within Protocol
	@function hex
	@param hash number
	@return string

	`0x1a2b3c4d`. Every message that names a hash uses this, so two consoles print the same eight
	characters and a human can compare them.
]=]
function Protocol.hex(hash: number): string
	return string.format("0x%08x", hash)
end

--[[
	The peer on the other end of a client's connection has no `Player` to be keyed by, and `nil` is
	not a table key. This stands in for "the server" on the client's side, and it can never collide
	with a `Player`.
]]
local SERVER: any = table.freeze({})

--[=[
	@interface Config
	@within Protocol
	.hash () -> number -- this peer's hash, read late because the protocol seals late
	.announce (who: any?) -> () -- put this peer's hello on the wire, to that peer
	.isServer boolean
]=]
export type Config = {
	hash: () -> number,
	announce: (who: any?) -> (),
	isServer: boolean,
	--[[ This peer's per-namespace digest, read late for the same reason as `hash`. Optional so a
	     rig that only tests the whole-hash verdict keeps its shape; without it a mismatch is never
	     named, only detected. ]]
	namespaces: (() -> { NamespaceDigest })?,
}

export type Agreement = {
	greet: (who: any?, hash: number) -> string?,
	verdict: (who: any?) -> string?,
	agreed: (who: any?) -> boolean,
	forget: (who: any) -> (),
	--[[ Whether a digest from this peer would change anything: refused, and not yet named. The
	     transport asks before it decodes one, so a peer sending three hundred costs a table read
	     for every one after the first (`PLAN-M5` D-7). ]]
	wants: (who: any?) -> boolean,
	--[[ The peer's per-namespace digest. Rewrites a refused peer's reason to name the namespace,
	     once, and returns the new reason so the caller can report it; nil when nothing changed. ]]
	digest: (who: any?, theirs: { NamespaceDigest }) -> string?,
}

--[=[
	@within Protocol
	@function new
	@param config Config
	@return Agreement

	Tracks which peers have agreed, and refuses the ones that have not.
]=]
function Protocol.new(config: Config): Agreement
	local ours = config.hash
	local announce = config.announce

	--[[
		nil is "has not said hello", a string is the refusal, and a peer that agreed is removed
		rather than stored as `true`.

		The asymmetry is the design. A peer whose hash **differs** is refused, because their bytes
		would decode as a different channel than the one they sent and a wrong payload delivered
		successfully is worse than no payload at all. A peer who has said **nothing** is accepted,
		and that is not an oversight:

		  * The handshake diagnoses deploy skew. It is not an authorization boundary, and treating
		    it as one would be theatre — a hostile client omits the hello, and is then held to
		    exactly the same per-field validation as one that sent it. Nothing is gained.
		  * A real client's hello can be lost. Refusing them for it would turn a dropped packet into
		    a player who cannot play, which is a worse failure than the one being prevented.

		So this table only ever holds peers that are provably wrong, which also means it stays empty
		in a healthy server.
	]]
	local refusals: { [any]: string } = {}

	--[[ Peers whose reason already names a namespace. A digest after that is not decoded. ]]
	local named: { [any]: boolean } = {}

	local function keyOf(who: any?): any
		return if who == nil then SERVER else who
	end

	return {
		greet = function(who: any?, hash: number): string?
			local mine = ours()
			local key = keyOf(who)

			if hash == mine then
				refusals[key] = nil
				named[key] = nil
				return nil
			end

			--[[
				A peer already known to be wrong is not re-judged, and that bound is the whole answer
				to a hello flood.

				Control packets are read before `sink.admit`, because resolving id 0 would fail and
				that failure would be the unrecoverable one — so nothing charges a hello a rate. What
				made that matter was here: every mismatched hello built a fresh reason string and
				answered with a hello of this peer's own. Measured before this line, 300 hellos in one
				2,101-byte batch cost 300 replies and 76 KB of garbage. The second one now costs a
				table read.

				The verdict cannot change either, because the only thing that lifts a refusal is a
				hash that **agrees**, and that is the branch above. So a peer that rotates its hash
				keeps the reason naming the first one it claimed — which is the one a real stale
				client would have sent every time.
			]]
			if refusals[key] ~= nil then
				return nil
			end

			local reason = `the peer is on protocol {Protocol.hex(hash)} and this peer is on `
				.. `{Protocol.hex(mine)}. The two disagree about a channel's name, class or schema, `
				.. `so every packet between them would decode as something else. Redeploy both `
				.. `sides from the same declarations; nw.protocol() prints what this one computed.`

			refusals[key] = reason

			--[[ Answered rather than only recorded, and only on a mismatch.

			     The failure is symmetric and the person who can act on it is usually sitting at the
			     client, watching a console that would otherwise say nothing at all. One packet per
			     mismatched peer, never on the happy path. ]]
			if config.isServer then
				announce(who)
			end

			--[[ Returned so the caller can report the hello itself. Until M3 phase 9 a mismatched
			     hello was silent here, and the disagreement first surfaced on a data packet behind
			     it — which is to say never, for a peer that sent nothing else. ]]
			return reason
		end,

		verdict = function(who: any?): string?
			return refusals[keyOf(who)]
		end,

		agreed = function(who: any?): boolean
			return refusals[keyOf(who)] == nil
		end,

		forget = function(who: any)
			refusals[who] = nil
			named[who] = nil
		end,

		wants = function(who: any?): boolean
			local key = keyOf(who)
			return refusals[key] ~= nil and not named[key]
		end,

		digest = function(who: any?, theirs: { NamespaceDigest }): string?
			local key = keyOf(who)

			if refusals[key] == nil or named[key] then
				return nil
			end

			--[[ Marked before the comparison, so a digest that names nothing — two hashes that differ
			     with every namespace agreeing cannot happen, but a malformed one can — is still the
			     last one this peer gets to send us. ]]
			named[key] = true

			local digestOf = config.namespaces

			if not digestOf then
				return nil
			end

			local where = Protocol.difference(digestOf(), theirs)

			if not where then
				return nil
			end

			local reason = `{where}. Every packet between the two would decode as something else, so `
				.. `the peer stays refused; redeploy both sides from the same declarations, and `
				.. `nw.signature() prints what this one computed.`

			refusals[key] = reason
			return reason
		end,
	}
end

return Protocol
