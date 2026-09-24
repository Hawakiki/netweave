# Step 8 — Types, bytes, and what the decoder refuses

**What you have at the end:** the whole type vocabulary, what each spelling costs on the wire, and
the list of things a peer can put in a packet that never reach your handler.

Every netweave type is bounded, and that one property is where three features come from: the byte
ceiling every channel derives for itself (Step 2), the automatic packing that makes a flag payload
six bytes, and the refusals in the last section. `docs/WIRE-FORMAT.md` §5 is the layout this step
describes; `tests/serdes_runtime.luau` and `tests/roblox_runtime.luau` measure it.

## Numbers

```lua
t.u8, t.u16, t.u32, t.i8, t.i16, t.i32      -- one, two or four bytes
t.f32, t.f64                                -- IEEE floats, never narrowed
t.u53, t.i53                                -- whole numbers past 32 bits
t.u16(1000, 1255)                           -- one byte on the wire: value - 1000
t.quantized(-1, 1, 2 / 254)                 -- 255 levels, one byte
t.quantized(-180, 180, 0.25)                -- 1441 levels, two bytes
```

A range narrows the width and subtracts the lower bound, so `t.u16(1000, 1255)` is stored as a byte
holding `value - 1000`, and a value outside the range is refused on both ends: the encoder raises at
the send, the decoder refuses the packet. `t.quantized(min, max, step)` writes a count of steps in
the narrowest storage that holds the level count and hands back `min + count × step`; it is how a
normal or a heading becomes one or two bytes. `t.u53` and `t.i53` narrow like `u32` when the range
fits four bytes and otherwise travel as an `f64` whose wholeness is checked on both sides.

## Booleans, optionals, enums, unions: the bitfield

```lua
t.boolean                                        -- one bit
t.optional(t.u16)                                -- one presence bit, then the value if present
t.optional(t.u8, 16)                             -- the same bit; absent reads as 16, and 16 is never sent
t.enum({ primary = true, secondary = true, melee = true })   -- two bits: ceil(log2 3)
t.literal("v3")                                  -- no bits, no bytes: the value is in the declaration
t.union({ move = t.struct({ x = t.u8, y = t.u8 }), wait = t.u8 })
```

None of these gets a byte of its own. Every struct opens a bitfield, and its booleans, presence
markers and enum tags accumulate into it, emitted as the fewest whole bytes that hold them. That is
why netweave's flag payload in `bench/RESULTS.md` is 8 bytes on the wire against Blink's 10 or 20:
Blink packs only when its author reaches for `set`, and netweave packs because there is no other
spelling. An enum of one variant costs nothing; two cost one bit; three or four cost two.

An optional with a default has the payload type of its inner type, not `T?`: the reader hands the
default back where the bit is clear, and the writer clears the bit for the default too, so the
common value costs a bit rather than its bytes. A literal is the one value both sides already
know — a payload version, a union branch that carries a name and nothing else — and the writer
refuses any other. Both reach the protocol hash, so two builds that disagree on a default or a
literal are refused at the first packet rather than reading each other wrongly.

A union carries a tag of `ceil(log2 n)` bits and then only the chosen branch. The branches' own
flags share the same bit positions, because only one branch is ever present, so a union of two
five-flag structs is six bits and not eleven. Its payload is a `{ tag, value }` pair, and the pair is
what lets Luau narrow:

```lua
local Action = t.union({
	move = t.struct({ x = t.u8, y = t.u8 }),
	wait = t.u8,
})

type Action = t.PayloadOf<typeof(Action)>

local function cost(action: Action): number
	if action.tag == "move" then
		return action.value.x + action.value.y   -- value is the struct here
	end

	return action.value                          -- and the number here
end
```

An enum's payload is the variant name, `"primary" | "secondary" | "melee"`, so a handler compares
strings and the wire carries bits. `t.PayloadOf` is a type, and types hang off the module rather
than off `nw.types`; Step 9 has the one-line require that reaches it.

## Strings, arrays, maps, buffers

```lua
t.string(0, 32)                                  -- length prefix, then 0..32 bytes
t.string(1, 20, { utf8 = true, charset = "%w_" }) -- and only word characters
t.string(1, 20, { pattern = "%a+%d?" })          -- or a shape, when a set is not enough
t.array(t.u8, 0, 8)                              -- length prefix, then up to eight
t.array(t.u8, 100)                               -- exactly a hundred: no prefix at all
t.map(t.string(1, 16), t.u8)                     -- count, then key/value pairs
t.set(t.string(1, 16))                           -- count, then the entries: { [string]: true }
t.buffer(0, 900)                                 -- length prefix, then the bytes
```

A length bound is not decoration. It is what gives the channel its byte ceiling, and an array with
a fixed length has no length prefix at all, which is how the benchmark's array of a hundred structs
lands at exactly 601 bytes. `utf8`, `charset` and `pattern` write nothing and refuse on both sides.
A `charset` is what goes between the brackets of a Lua character class, and it is the option to
reach for first: one class, one repetition, so the check is linear in the string whatever a client
sends. A `pattern` says more, and is refused at declaration when its worst case is unbounded —
`"(.*)@(.*)%.(.*)"` against a 65,535 byte string is a way for a client to spend the server's
frame — and accepted when the number of steps it can take is bounded by the string's own length.

## Roblox datatypes

```lua
t.vector3                                        -- three f32, twelve bytes, unbounded
t.vector3(t.i16(-2048, 2048))                    -- six bytes, and off the map is refused
t.vector2(t.i16(-1024, 1024))                    -- four
t.unitVector3                                    -- twelve, and a magnitude that is not 1 is refused
t.unitVector3(t.quantized(-1, 1, 2 / 254))       -- three bytes for a direction
t.cframe                                         -- twenty-four
t.color3                                         -- three
t.instance("BasePart")                           -- zero bytes: it rides in a sidecar
t.instance("BasePart", { descendantOf = workspace })
t.player
```

A bare `t.vector3` is three floats and unbounded, so a position of `1e38` on an `intent` passes.
Naming a component schema is how a position says where the map is, and everything a number type
knows applies per axis. A direction is where the exploit lives — a handler that trusts a "unit"
vector and multiplies by its own range gets an arbitrary displacement out of a magnitude of 400 —
so `t.unitVector3` refuses a magnitude that is not one, and the quantised spelling widens the
tolerance by exactly what its step can introduce and no more.

Instances write nothing to the buffer; they travel beside it in a sidecar the engine replicates,
and an instance the receiving client cannot see arrives as `nil`, which the reader refuses as a
missing instance. `t.instance("Sound")` refuses a `Part` by class, on both ends, so `nw.validate`
cannot brand one either. `descendantOf` is the container check: a client can reference any
instance it can see, including one it parented into `ReplicatedStorage` a frame ago, and a
container declared at startup is what says "from the world, not from your own `PlayerGui`".

## Structs, and what the order is for

Fields are written in sorted name order, depth first, and so are enum variants, union branches and
channel ids. Order is never taken from table iteration, because both peers evaluate their own copy
of the declaration and hash order is exactly how ByteNet's ids drift. The protocol hash both peers
compare covers all of it: every name, every class, every field's encoding and range, `utf8`,
`pattern`, the container's presence. Change a bound and the hash moves, and a peer on the old
declaration is refused at stage `protocol` on its first batch rather than decoding every packet as
something else.

## What the decoder refuses

All of it is reported at stage `parse` with the reason, none of it raises, and the packet behind it
in the batch still arrives (Step 5, guarantees G4 and G5):

- a number outside its declared range, a `NaN` or an infinity in any float, a whole-number type
  carrying a fraction;
- a string that is not UTF-8 when `utf8` was declared, or that does not match `pattern`, or whose
  length is outside its bound; an array or map whose count is outside its bound;
- an enum or union tag that names no variant, including the spare values a non-power-of-two tag
  has room for;
- a unit vector that is not unit, a position outside its component range, a `CFrame` carrying
  `NaN`;
- an instance of the wrong class, from outside the declared container, missing from the sidecar,
  or replaced in the sidecar by something that is not an `Instance`;
- a payload that does not end where its length says, a length that runs past the batch, an
  unknown channel id, a batch with the wrong version byte.

And the two that never reach the decoder at all: a payload claiming more bytes than the schema can
produce is refused at stage `budget` before a byte of it is read, and a packet on a channel this
peer sends on is refused at stage `direction`.

**Next:** [Step 9 — Naming the types in your own code](step9-naming-the-types.md)
