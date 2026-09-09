--!strict
--!optimize 2

--[=[
	@class Delta

	What changed, on the wire, against what the receiver already has.

	A patch is the state layout with every field wrapped in one more presence bit — see
	[Ir.patch], which derives it. This module is the pair of walks over that shape: one that
	compares two values and writes the difference, and one that reads a difference and folds it
	into a baseline.

	**Why this belongs inside the codec rather than beside it.** `delta-compress` writes a type tag
	per value — nineteen ids covering datatypes and diff operations
	(`_refsrc/delta-compress/src/TypeId.luau:4-22`) — because it has no schema
	and cannot do otherwise (`RESEARCH §1`, M4 phase 1). netweave has one, so a patch of a
	twelve-field struct is *twelve bits saying which moved, then the moved values in schema order*.
	Field identity is a position, not a serialised key. Measured on that schema: three bytes against
	twelve for a resend.

	Internal. `nw.replicate` is the public read of it.
]=]

--[[
	Two walks rather than one codec, and the reason is allocation.

	The obvious shape is `diff(old, new) -> patchTable` followed by an ordinary encode, and a decode
	followed by `apply(baseline, patchTable)`. That builds a table per patch on each side — the
	decode-then-rehash cost `RESEARCH §3.8-S` measures in Blink's and Zap's readers, and that
	`Serdes`'s template clone (ByteNet's trick, the one axis where it beat both) exists to avoid.

	It is also *wrong* on the receive side, not merely wasteful. A patch table cannot express "this
	optional field changed to nil": an absent key and a key set to nil are the same table. Charm
	Sync spends a `__none` sentinel table on exactly that problem (`charm-sync/src/patch.luau:10`)
	because it rides Roblox's default serialisation. Reading the bit and folding it into the
	baseline in the same pass has no intermediate to lose the distinction in.
]]

local Buffer = require("../codec/Buffer")
local Ir = require("../codec/Ir")
local Serdes = require("../codec/Serdes")

type Node = Ir.Node
type Field = Ir.Field
type Scope = Ir.Scope
type Flags = { number }

local band = bit32.band
local bor = bit32.bor

--[[
	A patch whose bits say "these fields did not move" is only readable against a value that has
	them. With no baseline it merges into a value missing whatever the patch did not carry, and that
	value reaches the handler as a `t.struct` with a field absent — the one thing every declaration
	promises cannot happen.

	It is not a hostile case. A client that refuses one change holds a baseline the server has
	already moved past, so the next honest patch is computed against something the reader no longer
	has; the fuzzer produced it in 8 of 4,000 mutated rounds without ever having to aim at it
	(`PLAN-M4` phase 6). The recovery already exists — a refused change desyncs the channel and asks
	for it again — and this is what makes the refusal happen instead of the merge.

	One shared string rather than a built one: a reason that allocates per packet is the property
	`CLAUDE.md` §9 says the rejection path has to keep, and a flood of short patches is exactly the
	shape that would exercise it.
]]
local NO_BASELINE = "a change patched a subject this endpoint has no baseline for"

local PATCH_CHUNK: { [number]: (offset: number, value: number) -> () } = {
	[1] = Buffer.patchU8,
	[2] = Buffer.patchU16,
	[4] = Buffer.patchU32,
}

local READ_CHUNK: { [number]: () -> number } = {
	[1] = Buffer.readU8,
	[2] = Buffer.readU16,
	[4] = Buffer.readU32,
}

local function sized(count: number): any
	return table.create(count)
end

-- -------------------------------------------------------------------------------------------
-- Equality, guided by the node
-- -------------------------------------------------------------------------------------------

--[[
	Whether two values of this node's type are the same.

	Reference equality first, at every level. ~~That is how Charm's immutable atoms make their own
	diff cheap; a game that replaces pays a pointer compare.~~ Not through the tick: the baseline it
	compares against is always `Tick.snapshot`'s copy, so the top-level compare never fires there and
	an atom costs what a plain table costs (M4 report finding 59; M4-1). What the pointer compare
	still buys is the merge — a value folded into its base shares every untouched subtree with it,
	and those compare in one step the next time round. Charm's own diff does use it that way
	(`charm-sync/src/patch.luau:60`).
]]
local function sameFor(node: Node): (a: any, b: any) -> boolean
	local kind = node.kind

	if kind == "buffer" then
		--[[ Buffers have no value equality in Luau, so this is the one leaf that has to look at
		     bytes. ]]
		return function(a: any, b: any): boolean
			if a == b then
				return true
			end

			if a == nil or b == nil then
				return false
			end

			local length = buffer.len(a)

			if length ~= buffer.len(b) then
				return false
			end

			return buffer.readstring(a, 0, length) == buffer.readstring(b, 0, length)
		end
	elseif kind == "optional" then
		local sameInner = sameFor(node.inner :: Node)

		return function(a: any, b: any): boolean
			if a == nil or b == nil then
				return a == b
			end

			return sameInner(a, b)
		end
	elseif kind == "struct" then
		local fields = node.fields :: { Field }
		local count = #fields
		local names: { string } = sized(count)
		local sames: { (a: any, b: any) -> boolean } = sized(count)

		for index, field in fields do
			names[index] = field.name
			sames[index] = sameFor(field.node)
		end

		return function(a: any, b: any): boolean
			if a == b then
				return true
			end

			if a == nil or b == nil then
				return false
			end

			for index = 1, count do
				local name = names[index]

				if not sames[index](a[name], b[name]) then
					return false
				end
			end

			return true
		end
	elseif kind == "union" then
		local branches = node.branches :: { Field }
		local lookup = node.lookup :: { [string]: number }
		local sames: { (a: any, b: any) -> boolean } = sized(#branches)

		for index, branch in branches do
			sames[index] = sameFor(branch.node)
		end

		return function(a: any, b: any): boolean
			if a == b then
				return true
			end

			--[[ A different branch is a different value whatever is inside it, and comparing across
			     branches would be comparing two shapes that share no fields. ]]
			if a == nil or b == nil or a.tag ~= b.tag then
				return false
			end

			--[[ A tag neither branch names cannot be compared, and "changed" is the safe answer: the
			     writer refuses it a moment later and says which value it was. ]]
			local index = lookup[a.tag]

			if index == nil then
				return false
			end

			return sames[index](a.value, b.value)
		end
	elseif kind == "array" then
		local sameElement = sameFor(node.element :: Node)

		return function(a: any, b: any): boolean
			if a == b then
				return true
			end

			if a == nil or b == nil or #a ~= #b then
				return false
			end

			for index = 1, #a do
				if not sameElement(a[index], b[index]) then
					return false
				end
			end

			return true
		end
	elseif kind == "map" then
		local sameValue = sameFor(node.value :: Node)

		return function(a: any, b: any): boolean
			if a == b then
				return true
			end

			if a == nil or b == nil then
				return false
			end

			for key, value in a do
				if not sameValue(value, b[key]) then
					return false
				end
			end

			--[[ The walk above misses keys present only in `b`, so count both ways. Maps are
			     bounded by their declared `max`, so this terminates in the schema's own bound. ]]
			for key in b do
				if a[key] == nil then
					return false
				end
			end

			return true
		end
	end

	--[[ Every other kind — numbers, strings, booleans, enums, instances and the Roblox datatypes —
	     has value equality that means what it says. ]]
	return function(a: any, b: any): boolean
		return a == b
	end
end

-- -------------------------------------------------------------------------------------------
-- The two walks
-- -------------------------------------------------------------------------------------------

--[[ Writes what differs and answers whether anything did. Flags are set into the accumulator
     rather than the buffer, so an outer bit can be decided after the values under it are written —
     which is what lets a nested struct's bit mean "something inside moved". ]]
type Differ = (old: any, new: any, flags: Flags) -> boolean

--[[ Folds a patch into a baseline. Returns the value and whether it is a new one, so an untouched
     sub-struct is returned by reference instead of being cloned — the result shares everything the
     patch did not touch. ]]
type Merger = (base: any, flags: Flags) -> (any, boolean)

local buildDiffer, buildMerger

function buildDiffer(node: Node): Differ
	if node.kind == "struct" then
		local fields = node.fields :: { Field }
		local count = #fields
		local names: { string } = sized(count)
		local differs: { Differ } = sized(count)

		for index, field in fields do
			names[index] = field.name
			differs[index] = buildDiffer(field.node)
		end

		return function(old: any, new: any, flags: Flags): boolean
			local changed = false

			for index = 1, count do
				local name = names[index]
				local before = if old == nil then nil else old[name]
				local after = if new == nil then nil else new[name]

				if differs[index](before, after, flags) then
					changed = true
				end
			end

			return changed
		end
	end

	--[[ Everything else in a patch tree is the presence bit `Ir.patch` put there. ]]
	local chunk = node.chunkIndex :: number
	local mask = node.mask :: number
	local inner = node.inner :: Node

	if inner.kind == "struct" then
		--[[ A nested struct, recursed into. The bit says "something below moved"; which fields
		     moved is the bits below it. ]]
		local innerDiffer = buildDiffer(inner)

		return function(old: any, new: any, flags: Flags): boolean
			if not innerDiffer(old, new, flags) then
				return false
			end

			flags[chunk] = bor(flags[chunk], mask)
			return true
		end
	end

	local same = sameFor(inner)
	local writeInner = Serdes.nodeCodec(inner)

	return function(old: any, new: any, flags: Flags): boolean
		if same(old, new) then
			return false
		end

		flags[chunk] = bor(flags[chunk], mask)

		--[[ When `inner` is itself an optional — the field was `t.optional(T)` in the state — this
		     is where removal happens and it costs nothing extra. `Serdes`' optional writer clears
		     its own bit for a nil, so the pair reads as "changed, and it is not there now". ]]
		writeInner(new, flags)
		return true
	end
end

function buildMerger(node: Node): Merger
	if node.kind == "struct" then
		local fields = node.fields :: { Field }
		local count = #fields
		local names: { string } = sized(count)
		local mergers: { Merger } = sized(count)

		for index, field in fields do
			names[index] = field.name
			mergers[index] = buildMerger(field.node)
		end

		return function(base: any, flags: Flags): (any, boolean)
			local result: any = nil

			for index = 1, count do
				local name = names[index]
				local value, changed = mergers[index](if base == nil then nil else base[name], flags)

				if changed then
					--[[ Cloned on the first change and not before, so a sub-struct nothing touched
					     comes back by reference. ]]
					result = result or (if base == nil then {} else table.clone(base))
					result[name] = value
				end
			end

			if result == nil then
				--[[
					Nothing below moved.

					Against a baseline that had this struct, that is the struct unchanged and it
					comes back by reference — which is the sharing this module exists for.

					Against **no baseline at all** it is a value whose every field is an absent
					optional, and that value still *exists*. Returning the nil baseline there would
					make it indistinguishable from a subject that was removed, which is the one
					thing the root bit is supposed to separate. Found by testing an arrival of
					`t.struct({ a = t.optional(t.u8), b = t.optional(t.u8) })` with neither set.
				]]
				if base == nil then
					return {}, true
				end

				return base, false
			end

			return result, true
		end
	end

	local chunk = node.chunkIndex :: number
	local mask = node.mask :: number
	local inner = node.inner :: Node

	if inner.kind == "struct" then
		local innerMerger = buildMerger(inner)

		return function(base: any, flags: Flags): (any, boolean)
			if band(flags[chunk], mask) == 0 then
				--[[ A sub-struct the patch did not touch, and nothing to fall back on. See
				     `NO_BASELINE`: the whole struct would be absent from the merged value. ]]
				if base == nil then
					Buffer.reject(NO_BASELINE)
				end

				return base, false
			end

			return innerMerger(base, flags)
		end
	end

	local _, readInner = Serdes.nodeCodec(inner)

	--[[ Whether the *state* said this field may be absent. An `optional` that the patch did not
	     touch is legitimately nil against no baseline; anything else is a hole. ]]
	local required = inner.kind ~= "optional"

	return function(base: any, flags: Flags): (any, boolean)
		if band(flags[chunk], mask) == 0 then
			if required and base == nil then
				Buffer.reject(NO_BASELINE)
			end

			return base, false
		end

		--[[ `readInner` returns nil for an inner optional whose bit is clear, which is the removal
		     case, and the caller assigns it — dropping the key rather than leaving a sentinel. ]]
		return readInner(flags), true
	end
end

-- -------------------------------------------------------------------------------------------

local Delta = {}

--[=[
	@interface Delta
	@within Delta
	.layout Layout -- the patch layout, derived from the state layout
	.write (old: any, new: any) -> boolean -- writes a patch, or nothing and false
	.apply (base: any) -> (any, string?) -- reads a patch and folds it into `base`, or a reason
]=]
export type Delta = {
	layout: Ir.Layout,
	write: (old: any, new: any) -> boolean,
	--[[ `(nil, nil)` is the subject going away and `(nil, reason)` is a change that could not be
	     read. A caller that treats the two the same drops a subject because a peer sent a short
	     packet, which is the difference between a removal and a lie. ]]
	apply: (base: any) -> (any, string?),
}

--[=[
	@within Delta
	@function build
	@param state Layout -- a state layout, from [Ir.lower]
	@return Delta

	The differ and merger for one schema, built once at declaration.

	```lua
	local delta = Delta.build(Ir.lower(schema))

	Buffer.load(record)
	if delta.write(baseline, current) then
		-- something moved, and the patch is in the outgoing buffer
	end
	```

	:::caution
	`write` returns **false and writes nothing** when the two values are the same. A caller that
	frames the result has to ask before it frames, because a patch of nothing is not an empty patch,
	it is the absence of a packet.
	:::
]=]
function Delta.build(state: Ir.Layout): Delta
	local layout = Ir.patch(state)
	local root = layout.root

	--[[ The root is the existence bit `Ir.patch` put on, and this reads it directly rather than
	     through `buildDiffer`'s optional case, because the two branches under it are not "changed
	     or not" — they are *gone* and *here is what moved*, and only one of them has a body. ]]
	local rootChunk = root.chunkIndex :: number
	local rootMask = root.mask :: number
	local inner = root.inner :: Node

	local differ = buildDiffer(inner)
	local merger = buildMerger(inner)

	--[[ There is always a scope now: the root's own bit guarantees at least one, so the schema with
	     no fields that used to need a degenerate branch has one too. ]]
	local scope = layout.scope :: Scope
	local chunks = scope.chunks
	local count = #chunks
	local bytes = scope.bytes
	local accumulator: Flags = table.create(count, 0)

	local patches: { (offset: number, value: number) -> () } = sized(count)
	local offsets: { number } = sized(count)
	local reads: { () -> number } = sized(count)

	for index, chunk in chunks do
		patches[index] = PATCH_CHUNK[chunk.width]
		offsets[index] = chunk.offset
		reads[index] = READ_CHUNK[chunk.width]
	end

	return {
		layout = layout,

		write = function(old: any, new: any): boolean
			--[[ Marked before the flag bytes are reserved, because "nothing changed" has to leave
			     the buffer exactly as it found it — the caller has not decided to send anything
			     yet. `rollback` is the same rewind the send path uses for an encode that raised. ]]
			local used, instances = Buffer.mark()
			local base = Buffer.reserve(bytes)

			for index = 1, count do
				accumulator[index] = 0
			end

			local function commit(): boolean
				for index = 1, count do
					patches[index](base + offsets[index], accumulator[index])
				end

				return true
			end

			if new == nil then
				--[[ Gone. The root bit stays clear and there is no body at all, so a removal is the
				     flag bytes and the subject that framed them — usually two. Telling a client
				     nothing is gone would be the same packet, so that case has to be caught here
				     rather than written. ]]
				if old == nil then
					Buffer.rollback(used, instances)
					return false
				end

				return commit()
			end

			local changed = differ(old, new, accumulator)

			--[[ `old == nil` is a subject this client has never seen, and it is sent even when the
			     differ found nothing — a struct of optionals that are all absent still has to
			     *arrive*, or the client never learns the subject exists. ]]
			if old ~= nil and not changed then
				Buffer.rollback(used, instances)
				return false
			end

			accumulator[rootChunk] = bor(accumulator[rootChunk], rootMask)
			return commit()
		end,

		apply = function(base: any): (any, string?)
			--[[ Cleared and then checked, the same two things `Serdes`' reader does and for the same
			     reason. Neither was here until M4 phase 6 went looking: a change whose flag bits
			     claim fields the packet does not carry read **past its own end**, and the values
			     came back as whatever the next packet's bytes happened to be — silently, because
			     nothing asked. G5 says one malformed packet must not stop the rest, and a rejection
			     carried forward from the packet before would do exactly that. ]]
			Buffer.clearRejection()

			for index = 1, count do
				accumulator[index] = reads[index]()
			end

			local short = Buffer.rejected()

			if short then
				return nil, short
			end

			--[[ The subject is gone. `nil` with no failure beside it, which is what separates a
			     removal from a change that could not be read. ]]
			if band(accumulator[rootChunk], rootMask) == 0 then
				return nil, nil
			end

			local value = merger(base, accumulator)
			local failure = Buffer.rejected()

			if failure then
				return nil, failure
			end

			return value, nil
		end,
	}
end

return Delta
