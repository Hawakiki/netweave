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
	per value — twenty-one ids covering datatypes and diff operations — because it has no schema
	and cannot do otherwise (`RESEARCH §1`, M4 phase 1). netweave has one, so a patch of a
	twelve-field struct is *twelve bits saying which moved, then the moved values in schema order*.
	Field identity is a position, not a serialised key. Measured on that schema: three bytes against
	twelve for a resend.

	Internal. `nw.replicate` is the public read of it.
]=]

--[[
	Two walks rather than one codec, and the reason is allocation.

	The obvious shape is `diff(old, new) -> patchTable` followed by an ordinary encode, and a decode
	followed by `apply(baseline, patchTable)`. That builds a table per patch on each side, which is
	the "decode into a table and then walk it" that `RESEARCH §3.8-S` criticises ByteNet for and
	that `Serdes`'s template clone exists to avoid.

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

	Reference equality first, at every level, and that is not only an optimisation: a store that
	hands back the same table has told us nothing changed, which is how Charm's immutable atoms make
	their own diff cheap (`charm-sync/src/patch.luau:60`). A game that mutates in place pays the
	deep walk; one that replaces pays a pointer compare.
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
				return base, false
			end

			return innerMerger(base, flags)
		end
	end

	local _, readInner = Serdes.nodeCodec(inner)

	return function(base: any, flags: Flags): (any, boolean)
		if band(flags[chunk], mask) == 0 then
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
	.apply (base: any) -> any -- reads a patch and folds it into `base`
]=]
export type Delta = {
	layout: Ir.Layout,
	write: (old: any, new: any) -> boolean,
	apply: (base: any) -> any,
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
	local scope = layout.scope

	local differ = buildDiffer(root)
	local merger = buildMerger(root)

	--[[ A schema with no fields derives no bits, so there is nowhere to say that anything changed.
	     Degenerate rather than impossible — `t.struct({})` is a legal schema — and answering "no"
	     is the only honest thing a patch of it can say. ]]
	if not scope then
		return {
			layout = layout,

			write = function(): boolean
				return false
			end,

			apply = function(base: any): any
				return base
			end,
		}
	end

	local chunks = (scope :: Scope).chunks
	local count = #chunks
	local bytes = (scope :: Scope).bytes
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

			if not differ(old, new, accumulator) then
				Buffer.rollback(used, instances)
				return false
			end

			for index = 1, count do
				patches[index](base + offsets[index], accumulator[index])
			end

			return true
		end,

		apply = function(base: any): any
			for index = 1, count do
				accumulator[index] = reads[index]()
			end

			local value = merger(base, accumulator)
			return value
		end,
	}
end

return Delta
