--!strict
--!optimize 2

--[=[
	@class Ir

	Lowers a schema to a node tree annotated with everything the compiler needs to know *before*
	it sees a value: how many bytes a subtree always takes, which flag bits it owns, and what
	shape its result table has.

	This pass is the reason netweave is not ByteNet with different names. ByteNet builds closures
	straight from the schema, so a closure can never see its siblings — it cannot know that six
	`u8` fields are six contiguous bytes, or that four booleans share one. Lowering first creates
	the window in which those facts exist.

	Internal. Schemas and channels are the public surface.
]=]

--[[
	Three facts, computed once at definition time, each paying for a different competitor's
	weakness:

	  `fixedSize`   a statically sized packet needs no length prefix, so the framing guarantee
	                costs it nothing (`docs/WIRE-FORMAT.md` §2), and one bounds check covers a
	                whole run rather than one per field.
	  `bits`        booleans, optional presence and small enum tags share a bitfield. Blink spends
	                a byte on each unless the author reaches for `set` (`RESEARCH §3.9-AA`).
	  `template`    a pre-sized table for `table.clone`, so decode never rehashes. ByteNet does
	                this and it is the one axis where it beat both code generators in M0
	                (389 B/packet against 641 and 1474).
]]

local Types = require("../types")

type Descriptor = Types.Descriptor
type Encoding = Types.Encoding

local Ir = {}

local MAX_CHUNK_BITS = 32
local CHUNK_WIDTHS = { 4, 2, 1 }

local ENCODING_SIZE: { [string]: number } = {
	u8 = 1,
	u16 = 2,
	u32 = 4,
	i8 = 1,
	i16 = 2,
	i32 = 4,
	f32 = 4,
	f64 = 8,
}

--[=[
	@interface Chunk
	@within Ir
	.width number -- 1, 2 or 4 bytes
	.capacity number -- bits this chunk holds
	.offset number -- byte offset within the bitfield

	One integer of a bitfield. A bitfield is a list of these rather than a single value because
	there is no 24-bit write: 17 bits is three bytes as `u16 + u8`, and four bytes as `u32`.
]=]
export type Chunk = {
	width: number,
	capacity: number,
	offset: number,
}

--[=[
	@interface Scope
	@within Ir
	.bits number -- total flags in this scope
	.bytes number -- what those flags cost, `ceil(bits / 8)`
	.chunks { Chunk }

	A bitfield. Opened at the root of a payload and at each element of a dynamic array or map,
	because those are the only places where the number of flags is not known until runtime.

	A struct does **not** open one: its flags fold into the enclosing scope, so twelve booleans
	nested one struct deep still cost twelve bits rather than a fresh byte.
]=]
export type Scope = {
	bits: number,
	bytes: number,
	chunks: { Chunk },
}

--[=[
	@interface Field
	@within Ir
	.name string
	.node Node
]=]
export type Field = {
	name: string,
	node: Node,
}

--[=[
	@interface Node
	@within Ir
	.kind Kind
	.bits number -- flag bits contributed to the enclosing bitfield
	.fixedSize number? -- bytes always consumed, or nil when it depends on the data
	.instances number? -- instances always consumed, or nil when it depends on the data
	.storage Encoding? -- the narrowed encoding a number is actually written at
	.offset number? -- subtracted before writing, added back on read
	.min number? -- a value bound for numbers, a length bound for strings, arrays and maps
	.max number? -- the same, and what the decoder rejects against
	.unit boolean?
	.class string?
	.lengthStorage Encoding? -- how a variable length is written; nil when the length is fixed
	.lengthOffset number?
	.count number? -- exact length, when the schema fixed one
	.variants { string }?
	.lookup { [string]: number }? -- variant name to wire index
	.inner Node?
	.element Node?
	.elements { Node }? -- one per position, when an exact-length array's element carries flags
	.key Node?
	.value Node?
	.fields { Field }?
	.template { [string]: boolean }? -- cloned on decode so the result table never rehashes
	.chunkIndex number? -- which bitfield chunk this node's flag lives in
	.mask number? -- its bit within that chunk
	.tagChunks { number }? -- an enum's tag bits may straddle a chunk boundary
	.tagMasks { number }?
	.scope Scope? -- set when this node opens a bitfield of its own
]=]
export type Node = {
	kind: Types.Kind,
	bits: number,
	fixedSize: number?,
	instances: number?,
	storage: Encoding?,
	offset: number?,
	min: number?,
	max: number?,
	unit: boolean?,
	class: string?,
	lengthStorage: Encoding?,
	lengthOffset: number?,
	count: number?,
	variants: { string }?,
	lookup: { [string]: number }?,
	inner: Node?,
	element: Node?,
	elements: { Node }?,
	key: Node?,
	value: Node?,
	fields: { Field }?,
	template: { [string]: boolean }?,
	chunkIndex: number?,
	mask: number?,
	tagChunks: { number }?,
	tagMasks: { number }?,
	scope: Scope?,
}

--[=[
	@interface Layout
	@within Ir
	.root Node
	.scope Scope? -- the payload's own bitfield, if it has any flags
	.fixedSize number? -- total payload bytes, or nil when it varies
	.maxSize number -- the most bytes a payload can ever occupy; always known
	.framing "static" | "counted"

	Everything a channel needs to encode and decode one payload.
]=]
export type Layout = {
	root: Node,
	scope: Scope?,
	fixedSize: number?,
	maxSize: number,
	instances: number?,
	framing: "static" | "counted",
}

--[[ Smallest number of bits that can index `count` distinct values. One variant needs none. ]]
local function bitsToIndex(count: number): number
	local bits = 0
	local capacity = 1

	while capacity < count do
		capacity *= 2
		bits += 1
	end

	return bits
end

--[[
	Smallest unsigned encoding holding `span`. Signed ranges never reach the wire as signed: the
	lower bound is subtracted first, so `i16(-100, 100)` travels as a single unsigned byte.
]]
local function storageFor(span: number): Encoding
	if span <= 255 then
		return "u8"
	elseif span <= 65535 then
		return "u16"
	end

	return "u32"
end

--[[
	`table.create` yields `{unknown}` and Luau arrays are invariant, so pre-sizing a typed array
	needs a cast. Returning `any` keeps the cast in one place: the new solver will not push a
	call site's expected type into a generic return (`spike/inference/README.md`).
]]
local function sized(count: number): any
	return table.create(count)
end

--[[ Any unknown makes the sum unknown. ]]
local function addSize(a: number?, b: number?): number?
	if a == nil or b == nil then
		return nil
	end

	return a + b
end

--[=[
	@within Ir
	@function bitChunks
	@param bits number
	@return { Chunk }

	Splits `bits` flags into the fewest bytes that hold them, `ceil(bits / 8)`, by taking the
	widest chunk that fits the remaining bytes.

	17 bits becomes `u16 + u8`, three bytes. A single `u32` would also be legal and would waste
	one. Zap caps its accumulators at 16 bits and reaches the same total; the cap is not what
	matters, the byte count is (`docs/WIRE-FORMAT.md` §5).
]=]
function Ir.bitChunks(bits: number): { Chunk }
	local chunks: { Chunk } = {}

	if bits <= 0 then
		return chunks
	end

	local remainingBytes = math.ceil(bits / 8)
	local offset = 0
	local assigned = 0

	while remainingBytes > 0 do
		local width = 1

		for _, candidate in CHUNK_WIDTHS do
			if candidate <= remainingBytes then
				width = candidate
				break
			end
		end

		local capacity = math.min(width * 8, MAX_CHUNK_BITS, bits - assigned)

		table.insert(chunks, {
			width = width,
			capacity = capacity,
			offset = offset,
		})

		assigned += capacity
		offset += width
		remainingBytes -= width
	end

	return chunks
end

--[=[
	@within Ir
	@function lengthSize
	@param node Node
	@return number -- bytes the length prefix costs, zero when the length is fixed
]=]
function Ir.lengthSize(node: Node): number
	local storage = node.lengthStorage
	return if storage then ENCODING_SIZE[storage] else 0
end

local function makeScope(bits: number): Scope
	return {
		bits = bits,
		bytes = math.ceil(bits / 8),
		chunks = Ir.bitChunks(bits),
	}
end

local lower: (descriptor: Descriptor) -> Node

local function lowerNumber(descriptor: Descriptor): Node
	local encoding = descriptor.encoding :: Encoding
	local min = descriptor.min :: number
	local max = descriptor.max :: number

	--[[
		Floats are validated against the range but never re-encoded. Subtracting a lower bound from
		a float and storing it narrower changes which values are representable, which is a
		different promise than the schema made.
	]]
	if encoding == "f32" or encoding == "f64" then
		return {
			kind = "number",
			bits = 0,
			fixedSize = ENCODING_SIZE[encoding],
			instances = 0,
			storage = encoding,
			offset = 0,
			min = min,
			max = max,
		}
	end

	local storage = storageFor(max - min)

	return {
		kind = "number",
		bits = 0,
		fixedSize = ENCODING_SIZE[storage],
		instances = 0,
		storage = storage,
		offset = min,
		min = min,
		max = max,
	}
end

--[[
	Length prefixes narrow the same way values do: `t.array(e, 10, 20)` writes `count - 10` in one
	byte. An exact length has no prefix at all, which is what makes `t.array(entity, 100)` a
	statically sized packet.
]]
local function lowerLength(node: Node, min: number, max: number)
	--[[
		The bounds are carried onto the node, not just consumed here, because the decoder needs
		them: a narrowed prefix admits values the schema forbids. `t.array(e, 0, 200)` writes its
		count in one byte, and a byte holds 255 — so a hostile sender can claim 255 elements
		against a schema that allows 200. The reader rejects that, and it can only do so if the
		limit survived lowering.
	]]
	node.min = min
	node.max = max

	if min == max then
		node.count = min
		return
	end

	node.lengthStorage = storageFor(max - min)
	node.lengthOffset = min
end

local function lowerStruct(descriptor: Descriptor): Node
	local order = descriptor.order :: { string }
	local source = descriptor.fields :: { [string]: Descriptor }

	local fields: { Field } = sized(#order)
	local template: { [string]: boolean } = {}

	local bits = 0
	local fixedSize: number? = 0
	local instances: number? = 0

	for index, name in order do
		local child = lower(source[name])

		fields[index] = { name = name, node = child }
		template[name] = false

		bits += child.bits
		fixedSize = addSize(fixedSize, child.fixedSize)
		instances = addSize(instances, child.instances)
	end

	return {
		kind = "struct",
		bits = bits,
		fixedSize = fixedSize,
		instances = instances,
		fields = fields,
		--[[ Frozen so nothing mutates the shared template. `table.clone` of a frozen table returns
		     a mutable copy, which is the intent. ]]
		template = table.freeze(template),
	}
end

local function lowerArray(descriptor: Descriptor): Node
	local elementDescriptor = descriptor.element :: Descriptor
	local element = lower(elementDescriptor)

	local node: Node = {
		kind = "array",
		bits = 0,
		element = element,
	}

	lowerLength(node, descriptor.min :: number, descriptor.max :: number)

	local count = node.count

	if count then
		--[[
			An exact length unrolls: the element's flags repeat a known number of times, so they
			fold into the enclosing bitfield rather than costing a byte each. This is how
			`boolean[8]` becomes one byte.
		]]
		node.bits = element.bits * count
		node.fixedSize = if element.fixedSize then element.fixedSize * count else nil
		node.instances = if element.instances then element.instances * count else nil

		if element.bits > 0 then
			--[[
				Each position needs its own bit slots, and a node holds exactly one slot, so the
				element is lowered once per position. Only arrays whose element carries flags pay
				this — `Entity[100]` of plain numbers keeps a single shared node.
			]]
			local elements: { Node } = sized(count)
			elements[1] = element

			for index = 2, count do
				elements[index] = lower(elementDescriptor)
			end

			node.elements = elements
		end
	else
		--[[
			A count that varies leaves the byte size unknown, but not always the instance count: an
			element that carries no instances carries none however many times it repeats. Saying nil
			here instead would put an always-zero varint in every such packet's frame, which is a byte
			on the wire for information the schema already has (`docs/WIRE-FORMAT.md` §2).
		]]
		node.instances = if element.instances == 0 then 0 else nil

		if element.bits > 0 then
			--[[
				A dynamic array cannot fold its elements' flags into the enclosing scope, because the
				count is not known until runtime. Each element opens a scope of its own, so `boolean[]`
				costs a byte per element. Zap has the same limitation; carrying flags across elements
				is possible and deferred (`RESEARCH §3.9-P`).
			]]
			element.scope = makeScope(element.bits)
		end
	end

	return node
end

local function lowerMap(descriptor: Descriptor): Node
	local key = lower(descriptor.key :: Descriptor)
	local value = lower(descriptor.value :: Descriptor)

	if key.bits > 0 then
		key.scope = makeScope(key.bits)
	end

	if value.bits > 0 then
		value.scope = makeScope(value.bits)
	end

	local node: Node = {
		kind = "map",
		bits = 0,
		key = key,
		value = value,

		--[[ Same derivation as a dynamic array: entries that carry no instances carry none however
		     many there are, and saying nil would put an always-zero varint in the frame. ]]
		instances = if key.instances == 0 and value.instances == 0 then 0 else nil,
	}

	lowerLength(node, descriptor.min :: number, descriptor.max :: number)
	return node
end

function lower(descriptor: Descriptor): Node
	local kind = descriptor.kind

	if kind == "boolean" then
		return { kind = kind, bits = 1, fixedSize = 0, instances = 0 }
	elseif kind == "number" then
		return lowerNumber(descriptor)
	elseif kind == "string" or kind == "buffer" then
		local node: Node = { kind = kind, bits = 0, instances = 0 }
		lowerLength(node, descriptor.min :: number, descriptor.max :: number)
		node.fixedSize = node.count
		return node
	elseif kind == "vector2" then
		return { kind = kind, bits = 0, fixedSize = 8, instances = 0 }
	elseif kind == "vector3" then
		return { kind = kind, bits = 0, fixedSize = 12, instances = 0, unit = descriptor.unit }
	elseif kind == "color3" then
		return { kind = kind, bits = 0, fixedSize = 3, instances = 0 }
	elseif kind == "cframe" then
		--[[
			Position plus an axis-angle vector. Zap keeps a table of 24 common rotations and spends
			one byte when a CFrame matches one; that is a real saving and a later optimisation, not
			a correctness matter.
		]]
		return { kind = kind, bits = 0, fixedSize = 24, instances = 0 }
	elseif kind == "instance" then
		return { kind = kind, bits = 0, fixedSize = 0, instances = 1, class = descriptor.class }
	elseif kind == "enum" then
		local variants = descriptor.variants :: { string }
		local lookup: { [string]: number } = {}

		for index, name in variants do
			lookup[name] = index
		end

		return {
			kind = kind,
			bits = bitsToIndex(#variants),
			fixedSize = 0,
			instances = 0,
			variants = variants,
			lookup = lookup,
		}
	elseif kind == "optional" then
		local inner = lower(descriptor.inner :: Descriptor)

		--[[
			Presence is one bit, and the inner value's own flags are reserved whether or not it is
			present. That is what makes `optional(boolean)` cost two bits and no bytes, and
			therefore keeps a struct of them statically sized.
		]]
		return {
			kind = kind,
			bits = 1 + inner.bits,
			fixedSize = if inner.fixedSize == 0 then 0 else nil,
			instances = if inner.instances == 0 then 0 else nil,
			inner = inner,
		}
	elseif kind == "array" then
		return lowerArray(descriptor)
	elseif kind == "map" then
		return lowerMap(descriptor)
	elseif kind == "struct" then
		return lowerStruct(descriptor)
	end

	error(`[netweave] cannot lower a "{kind}"`)
end

--[[ Locates bit `index` of a scope: which chunk holds it, and its mask within that chunk. ]]
local function locate(scope: Scope, index: number): (number, number)
	local remaining = index

	for chunkIndex, chunk in scope.chunks do
		if remaining < chunk.capacity then
			return chunkIndex, bit32.lshift(1, remaining)
		end

		remaining -= chunk.capacity
	end

	error(`[netweave] bit {index} is outside a {scope.bits}-bit scope`)
end

--[[
	Hands out bit positions within one scope, depth first, in the order the encoder will visit
	them. Assignment is per *occurrence*: the same `entity` schema used in two channels gets two
	independent sets of slots, which is why lowering never shares nodes between parents.
]]
local function assignBits(node: Node, scope: Scope, next: number): number
	local kind = node.kind

	if kind == "boolean" then
		node.chunkIndex, node.mask = locate(scope, next)
		return next + 1
	elseif kind == "enum" then
		local chunks: { number } = sized(node.bits)
		local masks: { number } = sized(node.bits)

		for index = 1, node.bits do
			chunks[index], masks[index] = locate(scope, next)
			next += 1
		end

		node.tagChunks = chunks
		node.tagMasks = masks
		return next
	elseif kind == "optional" then
		node.chunkIndex, node.mask = locate(scope, next)
		next += 1

		local inner = node.inner :: Node
		if inner.bits > 0 then
			next = assignBits(inner, scope, next)
		end

		return next
	elseif kind == "struct" then
		for _, field in node.fields :: { Field } do
			if field.node.bits > 0 then
				next = assignBits(field.node, scope, next)
			end
		end

		return next
	elseif kind == "array" then
		local elements = node.elements

		if elements then
			for _, element in elements do
				next = assignBits(element, scope, next)
			end
		end

		return next
	end

	return next
end

--[[
	Elements of dynamic arrays and maps carry their own bitfield, so their slots are numbered from
	zero inside it rather than continuing the enclosing scope.
]]
local function assignNestedScopes(node: Node)
	local kind = node.kind

	if kind == "array" then
		local element = node.element :: Node

		if element.scope then
			assignBits(element, element.scope :: Scope, 0)
		end

		assignNestedScopes(element)

		if node.elements then
			for _, copy in node.elements :: { Node } do
				assignNestedScopes(copy)
			end
		end
	elseif kind == "map" then
		local key = node.key :: Node
		local value = node.value :: Node

		if key.scope then
			assignBits(key, key.scope :: Scope, 0)
		end

		if value.scope then
			assignBits(value, value.scope :: Scope, 0)
		end

		assignNestedScopes(key)
		assignNestedScopes(value)
	elseif kind == "struct" then
		for _, field in node.fields :: { Field } do
			assignNestedScopes(field.node)
		end
	elseif kind == "optional" then
		assignNestedScopes(node.inner :: Node)
	end
end

--[=[
	@within Ir
	@function ceiling
	@param node Node
	@return number
	@private

	The most bytes this node can ever consume, derived from the schema rather than declared.

	Every netweave type is bounded — a number by its encoding, a string and an array by the range
	their author gave, an unbounded array by the 65535 its length prefix can express — so a
	ceiling always exists and is often tight. `t.struct({ origin = t.vector3, seq = t.u16 })` can
	never be more than fourteen bytes, and a packet claiming more on that channel is refusable
	before a byte of it is decoded, with the game having declared nothing.

	That is the point. `RESEARCH §3.7-F` records that no surveyed library checks a payload size at
	all, and the reason is that they would have to ask the author for the number. Here the schema
	already knows it.
]=]
local function ceiling(node: Node): number
	local kind = node.kind

	--[[
		A node that opens a **scope of its own** pays for it here.

		~~Flags live in the enclosing scope's bytes, not here, so `bits` never adds to a node's own
		ceiling. The layout adds the scope once at the top.~~ **True of the root scope and false of
		every other one, and it made the ceiling smaller than the encoder** — corrected in M3 phase 9
		after an external review measured it.

		Three places open a nested scope, all for the same reason: a count that is not known until
		runtime cannot fold its elements' flags into the enclosing bitfield, so each element carries
		its own (`lowerArray`, `lowerMap` above). `t.array(t.boolean, 0, 10)` therefore costs a byte
		per element, and derived **one** byte for ten of them — so `Batch.read` refused an honest
		three-element packet at stage `budget`, against its own sender, on any channel whose element
		type contained a boolean, an enum or an optional.

		A fixed-length array is not affected and is the control: its positions unroll into the
		enclosing scope, so they have no scope of their own to add.

		The root's scope is on the `Layout` rather than on `root`, so adding it here cannot
		double-count it.
	]]
	local flags = if node.scope then (node.scope :: Scope).bytes else 0
	local prefix = if node.lengthStorage then ENCODING_SIZE[node.lengthStorage] else 0
	local max = node.max
	local body: number

	if kind == "array" then
		local element = node.element

		--[[ A fixed-length array with per-position flags lowers one node per position, so the
		     element list is the authority when it exists. ]]
		if node.elements then
			local total = 0

			for _, positioned in node.elements :: { Node } do
				total += ceiling(positioned)
			end

			body = total
		else
			body = prefix + (max :: number) * ceiling(element :: Node)
		end
	elseif kind == "map" then
		local entry = ceiling(node.key :: Node) + ceiling(node.value :: Node)
		body = prefix + (max :: number) * entry
	elseif kind == "struct" then
		local total = 0

		for _, field in node.fields :: { Field } do
			total += ceiling(field.node)
		end

		body = total
	elseif kind == "optional" then
		--[[ Presence is a bit in the enclosing scope; the inner value costs its own ceiling only
		     when it is there, and the ceiling is the worst case. ]]
		body = ceiling(node.inner :: Node)
	elseif kind == "string" or kind == "buffer" then
		body = prefix + (max :: number)
	else
		body = node.fixedSize or 0
	end

	return flags + body
end
--[=[
	@within Ir
	@function lower
	@param descriptor Descriptor -- a type from `netweave.types`
	@return Layout

	Lowers a schema and runs the layout passes over it.

	*Lower*, not *compile*: nothing is generated and there is no build step. This walks a schema
	and annotates it, so that the closure builder never has to ask a question at send time that
	could have been answered at definition time.

	```lua
	local layout = Ir.lower(t.array(t.u8, 100))
	layout.framing   --> "static"
	layout.fixedSize --> 100
	```
]=]
function Ir.lower(descriptor: Descriptor): Layout
	local root = lower(descriptor)

	local scope: Scope? = nil
	if root.bits > 0 then
		scope = makeScope(root.bits)
		assignBits(root, scope :: Scope, 0)
	end

	assignNestedScopes(root)

	local flagBytes = if scope then scope.bytes else 0
	local fixedSize = addSize(flagBytes, root.fixedSize)

	return {
		root = root,
		scope = scope,
		fixedSize = fixedSize,

		--[[
			The most bytes a payload on this schema can ever occupy. Unlike `fixedSize` it is never
			nil, because every netweave type is bounded — so every channel has a byte ceiling whether
			or not its author thought to ask for one, and an oversized packet is refusable before it
			is decoded (`PLAN-M3` D-5).
		]]
		maxSize = flagBytes + ceiling(root),

		--[[
			How many instances the payload always consumes, or nil when it depends on the data. The
			transport needs it to skip a refused packet: a packet that is discarded must take its
			sidecar entries with it, or every instance after it is read against the wrong field
			(`docs/WIRE-FORMAT.md` §2).
		]]
		instances = root.instances,

		--[[
			A statically sized packet carries no length prefix: the reader already knows where it
			ends, so the framing guarantee is free for it (`docs/WIRE-FORMAT.md` §2).
		]]
		framing = if fixedSize then "static" else "counted",
	}
end

return Ir
