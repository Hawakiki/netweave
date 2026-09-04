--!strict
--!optimize 2

--[=[
	@class Serdes

	Turns an [Ir.Layout] into a pair of closures that write and read one payload.

	**Closure synthesis, not code generation.** netweave has no build step and emits no source.
	Every decision a layout already made — which encoding a number narrowed to, which bit of which
	chunk a boolean owns, whether a length needs a prefix at all — is bound into a function once,
	at definition time, so nothing is re-decided per packet (`RESEARCH §3.6-B5`).

	Internal. Schemas and channels are the public surface.
]=]

--[[
	The asymmetry in this file is deliberate and is the whole security posture:

	  encode  errors loudly. The value came from the game's own code, so a number outside its
	          declared range is a bug, and the alternative is silent wraparound on the wire.
	  decode  never errors. The value came off the wire, and a malicious client must not be able
	          to abort a batch by sending a byte (`RESEARCH §3.8-R`, `DESIGN-API` G4). Every
	          failure is routed through `Buffer.reject` and surfaces as a value from `read`.

	`assert` appears nowhere below. CLAUDE.md §4 reserves it for programmer error, and on this
	path programmer error is already covered by `error` with a message naming the field.
]]

local Buffer = require("./Buffer")
local Ir = require("./Ir")
local Types = require("../types")

type Node = Ir.Node
type Field = Ir.Field
type Scope = Ir.Scope
type Encoding = Types.Encoding

--[[
	Flags are threaded as a parameter rather than held in module state so that a scope is entered
	and left by an ordinary call, and so nothing has to be unwound when a decode is abandoned.
]]
type Flags = { number }
type Writer = (value: any, flags: Flags) -> ()
type Reader = (flags: Flags) -> any

local bor = bit32.bor
local band = bit32.band
local rshift = bit32.rshift

--[[ A node with no flags still takes the parameter; it is cheaper than branching on nil. ]]
local NO_FLAGS: Flags = table.freeze({}) :: any

local UNIT_TOLERANCE = 1e-3

--[[ `table.create` is `{unknown}`, and Luau arrays are invariant. Centralised so the cast is
     written once rather than at every call site. Same helper as `Ir.sized`. ]]
local function sized(count: number): any
	return table.create(count)
end

local function isFinite(value: number): boolean
	--[[ `value == value` is the NaN test; a rejected NaN would otherwise pass a range check by
	     failing every comparison in the wrong direction. ]]
	return value == value and value ~= math.huge and value ~= -math.huge
end

local WRITE_NUMBER: { [string]: (value: number) -> () } = {
	u8 = Buffer.writeU8,
	u16 = Buffer.writeU16,
	u32 = Buffer.writeU32,
	i8 = Buffer.writeI8,
	i16 = Buffer.writeI16,
	i32 = Buffer.writeI32,
	f32 = Buffer.writeF32,
	f64 = Buffer.writeF64,
}

--[[
	The same eight writers, for bytes an enclosing block has already claimed. `Serdes` chooses
	between the two families once per node at closure-build time, from the layout, so nothing
	branches per packet (`src/codec/Buffer.luau`, Blocks).
]]
local PUT_NUMBER: { [string]: (value: number) -> () } = {
	u8 = Buffer.putU8,
	u16 = Buffer.putU16,
	u32 = Buffer.putU32,
	i8 = Buffer.putI8,
	i16 = Buffer.putI16,
	i32 = Buffer.putI32,
	f32 = Buffer.putF32,
	f64 = Buffer.putF64,
}

local READ_NUMBER: { [string]: () -> number } = {
	u8 = Buffer.readU8,
	u16 = Buffer.readU16,
	u32 = Buffer.readU32,
	i8 = Buffer.readI8,
	i16 = Buffer.readI16,
	i32 = Buffer.readI32,
	f32 = Buffer.readF32,
	f64 = Buffer.readF64,
}

--[[ Bitfield chunks are patched after the fact, so they need the by-width dispatch too. ]]
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

local reserve = Buffer.reserve
local reject = Buffer.reject
local remaining = Buffer.remaining
local rejected = Buffer.rejected
local openBlock = Buffer.openBlock
local closeBlock = Buffer.closeBlock
local writeString = Buffer.writeString
local readString = Buffer.readString
local writeBuffer = Buffer.writeBuffer
local readBuffer = Buffer.readBuffer
local writeInstance = Buffer.writeInstance
local readInstance = Buffer.readInstance
local putU8 = Buffer.putU8
local putF32 = Buffer.putF32
local putString = Buffer.putString
local putBuffer = Buffer.putBuffer
local writeF32 = Buffer.writeF32
local readF32 = Buffer.readF32
local writeU8 = Buffer.writeU8
local readU8 = Buffer.readU8

--[[
	Whether the subtree currently being built sits inside a claimed block.

	A build-time flag rather than a parameter threaded through nine builders, and safe because
	synthesis is synchronous: `Serdes.build` runs to completion before anything else can call it. It
	selects `PUT_NUMBER` over `WRITE_NUMBER` and `putString` over `writeString`, and is read only
	while closures are being made — never while one runs.
]]
local blocked = false

local Serdes = {}

local buildWriter: (node: Node) -> Writer
local buildReader: (node: Node) -> Reader

-- -------------------------------------------------------------------------------------------------
-- Scopes
-- -------------------------------------------------------------------------------------------------

--[[
	Reserve, accumulate, backfill. The bitfield sits at the front of its scope but its bits are
	only known once every value in the scope has been visited, so the bytes are reserved first and
	patched last. Doing it the other way — a pre-pass to collect flags, then a write pass — walks
	the value twice.

	The accumulator is allocated once per scope-opening node and reused, which is safe because a
	schema is a tree: a scope is never entered while it is already open. Writers and readers get
	separate arrays anyway, so that reading a packet inside a send is not a hazard.
]]
local function scopedWriter(scope: Scope, inner: Writer): Writer
	local chunks = scope.chunks
	local count = #chunks
	local bytes = scope.bytes
	local accumulator: Flags = table.create(count, 0)

	local patches: { (offset: number, value: number) -> () } = sized(count)
	local offsets: { number } = sized(count)

	for index, chunk in chunks do
		patches[index] = PATCH_CHUNK[chunk.width]
		offsets[index] = chunk.offset
	end

	return function(value: any, _outer: Flags)
		local base = reserve(bytes)

		for index = 1, count do
			accumulator[index] = 0
		end

		inner(value, accumulator)

		for index = 1, count do
			patches[index](base + offsets[index], accumulator[index])
		end
	end
end

local function scopedReader(scope: Scope, inner: Reader): Reader
	local chunks = scope.chunks
	local count = #chunks
	local accumulator: Flags = table.create(count, 0)

	local reads: { () -> number } = sized(count)

	for index, chunk in chunks do
		reads[index] = READ_CHUNK[chunk.width]
	end

	return function(_outer: Flags): any
		--[[ Chunks are contiguous and emitted in offset order, so reading them in order leaves
		     the cursor exactly at the first value. ]]
		for index = 1, count do
			accumulator[index] = reads[index]()
		end

		return inner(accumulator)
	end
end

--[[ Wraps a child that opens a bitfield of its own: a dynamic array's element, a map's key or
     value. Everything else inherits the enclosing scope. ]]
local function writerFor(node: Node): Writer
	local writer = buildWriter(node)
	local scope = node.scope
	return if scope then scopedWriter(scope, writer) else writer
end

local function readerFor(node: Node): Reader
	local reader = buildReader(node)
	local scope = node.scope
	return if scope then scopedReader(scope, reader) else reader
end

-- -------------------------------------------------------------------------------------------------
-- Lengths
-- -------------------------------------------------------------------------------------------------

--[[
	A length that survives the round trip. The prefix is narrowed against the declared span, so a
	byte can carry a count the schema forbids; `checkLength` is where that is caught, and it is
	the single most load-bearing rejection in the codec — everything downstream of it allocates.
]]
local function lengthWriter(node: Node): (count: number, label: string) -> ()
	local exact = node.count

	if exact then
		return function(count: number, label: string)
			if count ~= exact then
				error(`[netweave] {label} must hold exactly {exact}, got {count}`)
			end
		end
	end

	local family: { [string]: (value: number) -> () } = if blocked then PUT_NUMBER else WRITE_NUMBER
	local write = family[node.lengthStorage :: Encoding]
	local offset = node.lengthOffset :: number
	local min = node.min :: number
	local max = node.max :: number

	return function(count: number, label: string)
		if count < min or count > max then
			error(`[netweave] {label} holds {count}, outside the declared {min}..{max}`)
		end

		write(count - offset)
	end
end

--[[ Returns the count, or -1 when the stream did not justify one. -1 rather than nil so callers
     stay on a single numeric path. ]]
local function lengthReader(node: Node): () -> number
	local exact = node.count

	if exact then
		return function(): number
			return exact
		end
	end

	local read = READ_NUMBER[node.lengthStorage :: Encoding]
	local offset = node.lengthOffset :: number
	local min = node.min :: number
	local max = node.max :: number

	return function(): number
		local count = read() + offset

		if count < min or count > max then
			reject("length out of range")
			return -1
		end

		return count
	end
end

-- -------------------------------------------------------------------------------------------------
-- Writers
-- -------------------------------------------------------------------------------------------------

local function numberWriter(node: Node): Writer
	local family: { [string]: (value: number) -> () } = if blocked then PUT_NUMBER else WRITE_NUMBER
	local write = family[node.storage :: Encoding]
	local offset = node.offset :: number
	local min = node.min :: number
	local max = node.max :: number

	if offset == 0 then
		return function(value: any, _flags: Flags)
			if not (value >= min and value <= max) then
				error(`[netweave] {value} is outside the declared range {min}..{max}`)
			end

			write(value)
		end
	end

	return function(value: any, _flags: Flags)
		if not (value >= min and value <= max) then
			error(`[netweave] {value} is outside the declared range {min}..{max}`)
		end

		write(value - offset)
	end
end

local function enumWriter(node: Node): Writer
	local lookup = node.lookup :: { [string]: number }
	local bits = node.bits

	if bits == 0 then
		--[[ One variant carries no information, so it costs no bits. The value is still checked,
		     because sending the wrong name is a bug worth naming. ]]
		return function(value: any, _flags: Flags)
			if lookup[value] == nil then
				error(`[netweave] "{tostring(value)}" is not a variant of this enum`)
			end
		end
	end

	local chunks = node.tagChunks :: { number }
	local masks = node.tagMasks :: { number }

	return function(value: any, flags: Flags)
		local index = lookup[value]

		if index == nil then
			error(`[netweave] "{tostring(value)}" is not a variant of this enum`)
		end

		local tag = index - 1

		for bit = 1, bits do
			if band(rshift(tag, bit - 1), 1) == 1 then
				local chunk = chunks[bit]
				flags[chunk] = bor(flags[chunk], masks[bit])
			end
		end
	end
end

local function structWriter(node: Node): Writer
	local fields = node.fields :: { Field }
	local count = #fields

	local names: { string } = sized(count)
	local writers: { Writer } = sized(count)
	local required: { boolean } = sized(count)

	for index, field in fields do
		names[index] = field.name
		writers[index] = buildWriter(field.node)
		required[index] = field.node.kind ~= "optional"
	end

	return function(value: any, flags: Flags)
		for index = 1, count do
			local field = value[names[index]]

			--[[ Without this the failure is a native error inside `buffer.write*` that names a
			     byte offset instead of a field, which is useless in a schema of forty fields. ]]
			if field == nil and required[index] then
				error(`[netweave] field "{names[index]}" is missing`)
			end

			writers[index](field, flags)
		end
	end
end

local function arrayWriter(node: Node): Writer
	local writeLength = lengthWriter(node)
	local exact = node.count
	local elements = node.elements

	if elements then
		--[[ An exact length whose element carries flags was unrolled: one node per position, each
		     owning its own bit slots, so the writers are not interchangeable. ]]
		local count = #elements
		local writers: { Writer } = sized(count)

		for index, element in elements do
			writers[index] = buildWriter(element)
		end

		return function(value: any, flags: Flags)
			writeLength(#value, "array")

			for index = 1, count do
				writers[index](value[index], flags)
			end
		end
	end

	local writeElement = writerFor(node.element :: Node)

	if exact then
		return function(value: any, flags: Flags)
			writeLength(#value, "array")

			for index = 1, exact do
				writeElement(value[index], flags)
			end
		end
	end

	return function(value: any, flags: Flags)
		local count = #value
		writeLength(count, "array")

		for index = 1, count do
			writeElement(value[index], flags)
		end
	end
end

local function mapWriter(node: Node): Writer
	local writeLength = lengthWriter(node)
	local writeKey = writerFor(node.key :: Node)
	local writeValue = writerFor(node.value :: Node)

	return function(value: any, flags: Flags)
		--[[ A map has no `#`, so the count is a pass of its own. It is written before the entries
		     because the reader has to size its loop before it sees one. ]]
		local count = 0
		for _ in value do
			count += 1
		end

		writeLength(count, "map")

		for key, entry in value do
			writeKey(key, flags)
			writeValue(entry, flags)
		end
	end
end

function buildWriter(node: Node): Writer
	local kind = node.kind

	if kind == "boolean" then
		local chunk = node.chunkIndex :: number
		local mask = node.mask :: number

		return function(value: any, flags: Flags)
			if value then
				flags[chunk] = bor(flags[chunk], mask)
			end
		end
	elseif kind == "number" then
		return numberWriter(node)
	elseif kind == "string" then
		local writeLength = lengthWriter(node)
		local bytes: (value: string, length: number) -> () = if blocked then putString else writeString

		return function(value: any, _flags: Flags)
			local length = #value
			writeLength(length, "string")
			bytes(value, length)
		end
	elseif kind == "buffer" then
		local writeLength = lengthWriter(node)
		local bytes: (value: buffer, length: number) -> () = if blocked then putBuffer else writeBuffer

		return function(value: any, _flags: Flags)
			local length = buffer.len(value)
			writeLength(length, "buffer")
			bytes(value, length)
		end
	elseif kind == "vector2" then
		local f32: (value: number) -> () = if blocked then putF32 else writeF32

		return function(value: any, _flags: Flags)
			f32(value.X)
			f32(value.Y)
		end
	elseif kind == "vector3" then
		local f32: (value: number) -> () = if blocked then putF32 else writeF32

		return function(value: any, _flags: Flags)
			f32(value.X)
			f32(value.Y)
			f32(value.Z)
		end
	elseif kind == "color3" then
		local u8: (value: number) -> () = if blocked then putU8 else writeU8

		return function(value: any, _flags: Flags)
			u8(math.clamp(math.round(value.R * 255), 0, 255))
			u8(math.clamp(math.round(value.G * 255), 0, 255))
			u8(math.clamp(math.round(value.B * 255), 0, 255))
		end
	elseif kind == "cframe" then
		local f32: (value: number) -> () = if blocked then putF32 else writeF32

		return function(value: any, _flags: Flags)
			local position = value.Position
			f32(position.X)
			f32(position.Y)
			f32(position.Z)

			--[[ Axis times angle: one vector carries the whole rotation, and the identity falls
			     out as the zero vector rather than needing a special case on either side. ]]
			local axis, angle = value:ToAxisAngle()
			f32(axis.X * angle)
			f32(axis.Y * angle)
			f32(axis.Z * angle)
		end
	elseif kind == "instance" then
		return function(value: any, _flags: Flags)
			if value == nil then
				error("[netweave] a non-optional instance field is nil")
			end

			writeInstance(value)
		end
	elseif kind == "enum" then
		return enumWriter(node)
	elseif kind == "optional" then
		local chunk = node.chunkIndex :: number
		local mask = node.mask :: number
		local writeInner = buildWriter(node.inner :: Node)

		return function(value: any, flags: Flags)
			if value == nil then
				return
			end

			flags[chunk] = bor(flags[chunk], mask)
			writeInner(value, flags)
		end
	elseif kind == "array" then
		return arrayWriter(node)
	elseif kind == "map" then
		return mapWriter(node)
	elseif kind == "struct" then
		return structWriter(node)
	end

	error(`[netweave] no writer for a "{kind}"`)
end

-- -------------------------------------------------------------------------------------------------
-- Readers
-- -------------------------------------------------------------------------------------------------

local function numberReader(node: Node): Reader
	local read = READ_NUMBER[node.storage :: Encoding]
	local offset = node.offset :: number
	local min = node.min :: number
	local max = node.max :: number
	local storage = node.storage

	if storage == "f32" or storage == "f64" then
		return function(_flags: Flags): any
			local value = read()

			--[[ A float arrives unnarrowed, so the range is a claim about the sender rather than a
			     property of the encoding. NaN fails this comparison in both directions, which is
			     the intent — it is the value that makes every downstream check pass by accident. ]]
			if not (value >= min and value <= max) then
				reject("number out of range")
				return min
			end

			return value
		end
	end

	return function(_flags: Flags): any
		--[[ Storage is unsigned and offset is the declared minimum, so the lower bound cannot be
		     violated. The upper one can: a span of 200 is carried in a byte that holds 255. ]]
		local value = read() + offset

		if value > max then
			reject("number out of range")
			return min
		end

		return value
	end
end

local function enumReader(node: Node): Reader
	local variants = node.variants :: { string }
	local bits = node.bits
	local first = variants[1]

	if bits == 0 then
		return function(_flags: Flags): any
			return first
		end
	end

	local chunks = node.tagChunks :: { number }
	local masks = node.tagMasks :: { number }

	return function(flags: Flags): any
		local tag = 0

		for bit = 1, bits do
			if band(flags[chunks[bit]], masks[bit]) ~= 0 then
				tag = bor(tag, bit32.lshift(1, bit - 1))
			end
		end

		--[[ The tag has room the schema does not use whenever the variant count is not a power of
		     two: three variants are two bits, and a sender can put 3 in them. ]]
		local name = variants[tag + 1]

		if name == nil then
			reject("unknown enum variant")
			return first
		end

		return name
	end
end

local function structReader(node: Node): Reader
	local fields = node.fields :: { Field }
	local count = #fields
	local template = node.template :: { [string]: boolean }

	local names: { string } = sized(count)
	local readers: { Reader } = sized(count)

	for index, field in fields do
		names[index] = field.name
		readers[index] = buildReader(field.node)
	end

	return function(flags: Flags): any
		--[[ Cloning a pre-sized template is why decode never rehashes. ByteNet does the same and
		     it is the one axis where it beat both code generators in M0 (`RESEARCH §3.7-M`). An
		     absent optional assigns nil, which drops the key without resizing. ]]
		local result = table.clone(template) :: any

		for index = 1, count do
			result[names[index]] = readers[index](flags)
		end

		return result
	end
end

local function arrayReader(node: Node): Reader
	local readLength = lengthReader(node)
	local elements = node.elements

	if elements then
		local count = #elements
		local readers: { Reader } = sized(count)

		for index, element in elements do
			readers[index] = buildReader(element)
		end

		return function(flags: Flags): any
			local result = sized(count)

			for index = 1, count do
				result[index] = readers[index](flags)
			end

			return result
		end
	end

	local element = node.element :: Node
	local readElement = readerFor(element)

	--[[
		The smallest number of bytes one element can occupy, when that is known at build time. A
		static element has an exact size; a dynamic one does not, and answers nil.
	]]
	local perElement = element.fixedSize

	return function(flags: Flags): any
		local count = readLength()

		if count < 0 then
			return {}
		end

		--[[
			A claim is not paid for until the bytes behind it exist.

			~~The length was already bounded, so this is a cost question, not a safety one.~~
			**Struck through in M3 phase 0.** A cost an attacker controls and does not pay for is an
			amplification: a two-byte packet claiming 65535 elements bought a 65535-slot table, at
			839x the cost of an honest packet, and *was then correctly rejected*. The rejection was
			free. The allocation was not (`PLAN-M3` D-4).

			Bounding the claim against the bytes that remain costs one comparison on the honest path
			and turns the hostile one into a refusal before anything is allocated. Zap has the same
			shape without the recovery — `_refsrc/zap/zap/src/irgen/des.rs:298` allocates from the
			claimed length too, and its generated `read` does no bounds checking at all, so the
			equivalent packet raises and takes the batch.
		]]
		local available = remaining()

		if perElement and perElement > 0 and count * perElement > available then
			reject(
				`array claims {count} elements, needing {count * perElement} bytes, and {available} remain`
			)
			return {}
		end

		--[[
			For a dynamic element there is no size to multiply by, so the *allocation* is capped at
			the bytes available instead. An element cannot be conjured from no bytes, so this never
			shortens an honest decode — and it bounds the hostile one to the packet's own length,
			which is what the amplification was.
		]]
		local result = sized(if count < available then count else available)

		for index = 1, count do
			--[[ Bail on the first rejection rather than reading `max` elements of garbage. ]]
			if rejected() then
				return result
			end

			result[index] = readElement(flags)
		end

		return result
	end
end

local function mapReader(node: Node): Reader
	local readLength = lengthReader(node)
	local key = node.key :: Node
	local value = node.value :: Node
	local readKey = readerFor(key)
	local readValue = readerFor(value)

	--[[ A map never had the allocation bug an array had — it starts from `{}` and grows — but the
	     same bound gives the same refusal, so a claim past the packet is reported the same way
	     whichever container it arrived in (`PLAN-M3` D-4). ]]
	local perEntry = if key.fixedSize and value.fixedSize then key.fixedSize + value.fixedSize else nil

	return function(flags: Flags): any
		local count = readLength()

		if count < 0 then
			return {}
		end

		local available = remaining()

		if perEntry and perEntry > 0 and count * perEntry > available then
			reject(`map claims {count} entries, needing {count * perEntry} bytes, and {available} remain`)
			return {}
		end

		local result: any = {}

		for _ = 1, count do
			if rejected() then
				return result
			end

			local entryKey = readKey(flags)
			local entryValue = readValue(flags)

			--[[ A rejected key is a default, and defaults collide: writing them would fabricate an
			     entry the sender never sent. ]]
			if not rejected() then
				result[entryKey] = entryValue
			end
		end

		return result
	end
end

function buildReader(node: Node): Reader
	local kind = node.kind

	if kind == "boolean" then
		local chunk = node.chunkIndex :: number
		local mask = node.mask :: number

		return function(flags: Flags): any
			return band(flags[chunk], mask) ~= 0
		end
	elseif kind == "number" then
		return numberReader(node)
	elseif kind == "string" then
		local readLength = lengthReader(node)

		return function(_flags: Flags): any
			local length = readLength()

			if length < 0 then
				return ""
			end

			return readString(length)
		end
	elseif kind == "buffer" then
		local readLength = lengthReader(node)

		return function(_flags: Flags): any
			local length = readLength()

			if length < 0 then
				return buffer.create(0)
			end

			return readBuffer(length)
		end
	elseif kind == "vector2" then
		return function(_flags: Flags): any
			local x, y = readF32(), readF32()

			if not (isFinite(x) and isFinite(y)) then
				reject("non-finite vector2")
				return Vector2.zero
			end

			return Vector2.new(x, y)
		end
	elseif kind == "vector3" then
		local unit = node.unit

		return function(_flags: Flags): any
			local x, y, z = readF32(), readF32(), readF32()

			if not (isFinite(x) and isFinite(y) and isFinite(z)) then
				reject("non-finite vector3")
				return Vector3.zero
			end

			local value = Vector3.new(x, y, z)

			--[[
				A direction that is not a direction is an exploit primitive: a caller that trusts
				`t.unitVector3` and multiplies by a range gets an arbitrary displacement out of a
				magnitude of 400. The schema said unit, so the decoder enforces unit.
			]]
			if unit and math.abs(value.Magnitude - 1) > UNIT_TOLERANCE then
				reject("vector3 is not a unit vector")
				return Vector3.zAxis
			end

			return value
		end
	elseif kind == "color3" then
		return function(_flags: Flags): any
			return Color3.fromRGB(readU8(), readU8(), readU8())
		end
	elseif kind == "cframe" then
		return function(_flags: Flags): any
			local px, py, pz = readF32(), readF32(), readF32()
			local ax, ay, az = readF32(), readF32(), readF32()

			if
				not (
					isFinite(px)
					and isFinite(py)
					and isFinite(pz)
					and isFinite(ax)
					and isFinite(ay)
					and isFinite(az)
				)
			then
				reject("non-finite cframe")
				return CFrame.identity
			end

			local rotation = Vector3.new(ax, ay, az)
			local angle = rotation.Magnitude

			if angle < 1e-6 then
				return CFrame.new(px, py, pz)
			end

			return CFrame.new(px, py, pz) * CFrame.fromAxisAngle(rotation / angle, angle)
		end
	elseif kind == "instance" then
		local class = node.class

		return function(_flags: Flags): any
			local value = readInstance()

			--[[
				Two failures, not one. A nil means the sidecar ran out, which is a framing problem.
				A wrong class means the sender picked an instance the schema does not admit, which
				is the whole reason `t.instance("Sound")` exists — a client can reference anything
				it can see, so the class is checked here or it is not checked at all.
			]]
			if value == nil then
				reject("missing instance")
				return nil
			end

			if class and not value:IsA(class) then
				reject("instance is not a " .. class)
				return nil
			end

			return value
		end
	elseif kind == "enum" then
		return enumReader(node)
	elseif kind == "optional" then
		local chunk = node.chunkIndex :: number
		local mask = node.mask :: number
		local readInner = buildReader(node.inner :: Node)

		return function(flags: Flags): any
			if band(flags[chunk], mask) == 0 then
				return nil
			end

			return readInner(flags)
		end
	elseif kind == "array" then
		return arrayReader(node)
	elseif kind == "map" then
		return mapReader(node)
	elseif kind == "struct" then
		return structReader(node)
	end

	error(`[netweave] no reader for a "{kind}"`)
end

-- -------------------------------------------------------------------------------------------------

--[=[
	@interface Codec
	@within Serdes
	.framing "static" | "counted" -- whether the transport has to length-prefix this payload
	.fixedSize number? -- payload bytes, when they never vary
	.instances number? -- sidecar entries always consumed, when that never varies
	.write (value: any) -> ()
	.read () -> (any, string?)
	.check (value: any) -> string? -- nil when the value satisfies the schema
]=]
export type Codec = {
	framing: "static" | "counted",
	fixedSize: number?,
	instances: number?,
	write: (value: any) -> (),
	read: () -> (any, string?),
	check: (value: any) -> string?,
}

--[=[
	@within Serdes
	@function build
	@param layout Layout -- from `Ir.lower`
	@return Codec

	Binds a layout into a write/read pair. Call this once per channel, at definition time.

	```lua
	local codec = Serdes.build(Ir.lower(t.struct({ x = t.u8, y = t.u8 })))

	codec.write({ x = 1, y = 2 })
	local bytes, instances = Buffer.take()

	Buffer.beginRead(bytes, instances)
	local value, failure = codec.read()
	```

	`write` appends to the outgoing buffer and leaves framing to the transport, which is what
	`framing` and `fixedSize` are for.

	:::caution
	`write` raises on a value the schema forbids — that is game code passing a bad number, and
	silent wraparound would be worse. `read` never raises: it returns `nil` and a reason.
	:::

	:::caution
	A `write` that raises leaves behind whatever bytes it emitted before the bad field. The caller
	owns the rewind: park the buffer with `Buffer.save` first, or `take` and discard. `check` below
	does the former, and a transport must do one of them — a partial payload left in the batch is a
	packet nobody can decode.
	:::
]=]
function Serdes.build(layout: Ir.Layout): Codec
	local root = layout.root
	local scope = layout.scope
	local fixedSize = layout.fixedSize

	--[[
		A payload whose size is known claims all of it in one `allocate` and fills it with the
		`put*` writers, which skip the bounds and growth checks the space has already paid for.

		`blocked` is set for the whole of synthesis and cleared after, so every closure below this
		point is built against the right family. It is restored rather than assigned `false`
		because `Serdes.build` can be re-entered — `Trust.validate` builds a codec lazily, and a
		schema can be lowered while another is being built.
	]]
	local outer = blocked
	blocked = fixedSize ~= nil

	local write = buildWriter(root)
	local read = buildReader(root)

	if scope then
		write = scopedWriter(scope, write)
		read = scopedReader(scope, read)
	end

	blocked = outer

	if fixedSize then
		local inner = write
		local size = fixedSize

		--[[ Annotated `Writer` rather than left to inference: an anonymous function whose return
		     type is exactly `()` makes `pcall(write, ...)` in `check` below resolve to one value. ]]
		local blockWrite: Writer = function(value: any, flags: Flags)
			openBlock(size)
			inner(value, flags)
			closeBlock()
		end

		write = blockWrite
	end

	--[[
		`pcall` of a function whose return pack is empty is typed as returning `boolean` alone, so
		destructuring the error out of it does not check. The alias widens the pack without changing
		what runs, and is hoisted here so `check` does not build one per call.
	]]
	local attempt: (...any) -> ...any = write

	return {
		framing = layout.framing,
		fixedSize = layout.fixedSize,
		instances = layout.instances,

		write = function(value: any)
			write(value, NO_FLAGS)
		end,

		read = function(): (any, string?)
			--[[ Cleared per payload, not per batch: G5 says one malformed packet must not stop the
			     rest, and a rejection carried forward would do exactly that. ]]
			Buffer.clearRejection()

			local value = read(NO_FLAGS)
			local failure = rejected()

			if failure then
				return nil, failure
			end

			return value, nil
		end,

		--[[
			The encoder is the only statement of what a value must satisfy, so `check` runs it rather
			than restating its rules. A second implementation drifts, and the two disagree exactly
			where it matters: on the boundary cases nobody re-tests.

			The cost is a real serialisation into a parked buffer, which is why this is not on the hot
			path. The receive path never needs it — a payload that decoded is valid by construction.
		]]
		check = function(value: any): string?
			local parked = Buffer.save()
			local ok, failure = pcall(attempt, value, NO_FLAGS)
			Buffer.load(parked)

			if ok then
				return nil
			end

			--[[ `error()` prefixes a script position; the caller wants the reason, not the line. ]]
			local reason = tostring(failure)
			return (string.gsub(reason, "^.-:%d+: ", "", 1))
		end,
	}
end

--[=[
	@within Serdes
	@function fromSchema
	@param descriptor Descriptor -- a type from `netweave.types`
	@return Codec

	`Serdes.build(Ir.lower(descriptor))`, for callers that have a schema rather than a layout.
]=]
function Serdes.fromSchema(descriptor: Types.Descriptor): Codec
	return Serdes.build(Ir.lower(descriptor))
end

return Serdes
