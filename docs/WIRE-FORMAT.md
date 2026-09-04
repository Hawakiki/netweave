# netweave wire format v1

Frozen by PLAN-M1 phase 2. Changing anything here after M1 ships is a breaking change, so the
reasoning is recorded alongside each decision.

Everything is little-endian, matching Roblox's `buffer` accessors. There are no alignment
requirements.

---

## 1. Transport envelope

One `RemoteEvent` call carries one batch:

```
FireServer(batch: buffer, instances: { Instance })
```

Two remotes total per side — one reliable, one unreliable — as in every batching library
surveyed. The instance array is a sidecar because instances cannot live in a buffer
(`RESEARCH §3.6-B3`); a packet's instances appear in it in the order the packet wrote them.

```
batch := version:u8  packet*
```

The version byte is per batch, not per packet. At 200 packets per frame it costs 0.005 bytes per
packet, and it is what lets this document have a v2.

## 2. Packet

```
packet := id:varint  frame  payload
```

`frame` depends on the channel's **framing mode**, which is a static property of its schema and
therefore known to both peers from the id alone. Nothing about the frame is negotiated at
runtime.

| Mode | When | `frame` |
|---|---|---|
| `static` | encoded size is known at definition time | *(empty)* |
| `counted` | size depends on data — arrays, strings, buffers, maps | `length:varint` |

A third mode, `derived` — size computable from a fixed-position bitfield, as when the only
variability is optional presence — is described in §7. It is not part of v1.

Channels that can carry a variable number of instances also carry `instances:varint` in the
frame, for the same reason the length is there: a skipped packet must skip its instances too.

### Why the length is there at all

Blink and Zap have no length field, so a failed decode cannot find the next packet boundary and
the rest of the batch is lost (`RESEARCH §3.8-R`). Guarantee G5 says one malformed packet must
not stop the others, and a length prefix is what makes that possible.

It is not free, and the cost is not hidden:

| Schema | Payload | netweave | Zap | Blink |
|---|---|---|---|---|
| `ArrayHeavy` (`static`) | 600 B | **601 B** | 601 B | 601 B |
| `FlagIdiomatic` (`counted`) | 6 B | **8 B** | 7 B | 10 B |

`static` schemas pay nothing — the framing guarantee is free for them. `counted` schemas pay one
byte, which on a 6-byte payload is 14%. That is the price of G5, stated plainly rather than
buried; §7 describes how to get it back for the common case.

## 3. Channel ids

Ids are assigned from the declared string keys, never from table iteration order. ByteNet derives
packet ids by iterating its declaration table, and this project hit the resulting silent
mis-decode during M0 phase 3 — the failure mode is that every packet decodes as the wrong type,
with no error.

```
qualified := namespace .. "." .. key          -- "combat.fireWeapon"
```

All qualified names in the program are sorted with `table.sort`'s default string ordering and
assigned `1..n`. Both peers compute the same list from the same declarations, in any order.

**Id 0 is reserved** for control traffic — the handshake in §4, and anything v2 needs.

### Encoding

LEB128 varint: 7 bits of payload per byte, high bit set while more bytes follow.

| Channels | Bytes per id |
|---|---|
| 1-127 | 1 |
| 128-16,383 | 2 |

Identical to Blink and Zap's `u8` for any realistic project, and without their hard cap of 256
channels.

## 4. Schema agreement

Both peers derive ids from their own copy of the declarations. If those disagree — a stale client,
a partial deploy — every packet decodes as the wrong channel.

At startup each peer computes a 32-bit FNV-1a hash over the sorted qualified names joined with
`\n`, and the client sends it on channel 0. A mismatch is refused loudly at startup rather than
producing corrupt payloads for the session's lifetime.

The hash covers names only, not types. A changed field type with an unchanged name is not caught
here; the per-field validation catches it as a rejection instead.

## 5. Payload layout

Fields are written in **sorted name order**, depth first.

~~Declared order.~~ Both peers evaluate the same table literal, so hash iteration would usually
agree — but "usually" is exactly how ByteNet's id assignment behaves, and sorting costs nothing
at definition time. The same rule covers enum variant indices and channel ids: **anywhere order
reaches the wire, it comes from sorting names.**

### Flag packing

Booleans, optional presence markers and small enum tags do not get their own bytes. Each scope
accumulates them into a bitfield whose slot is reserved when the scope opens and backfilled when
it closes — Zap's pattern (`RESEARCH §3.8-P`), which reads as
`bit32.bor` on a local and one `buffer.write` at the end.

The storage width is chosen to **minimise bytes**, not to fill an accumulator:

```
bits -> ceil(bits / 8) bytes, emitted as u32 / u16 / u8 chunks, widest first
```

| Bits | Emitted | Bytes |
|---|---|---|
| 8 | u8 | 1 |
| 17 | u16 + u8 | 3 |
| 33 | u32 + u8 | 5 |

~~Zap caps accumulators at 16 bits and Blink's `set` reaches 32, so taking the wider one wins.~~
**Corrected while writing this document.** Width is irrelevant; total bytes is what counts, and a
17-bit field is 3 bytes whether it is stored as `u32` (wasting 15 bits) or as `u16 + u8`. Zap's
16-bit cap already produces the minimal byte count. There is no byte advantage available here —
netweave reaches parity with Zap and beats Blink only when a Blink author has not reached for
`set` (`RESEARCH §3.9-AA`).

The real advantage over Blink is that packing is automatic. A Blink author who does not know
about `set` pays 19 bytes where netweave pays 6.

### Enum tags

A unit enum of `n` variants costs `ceil(log2(n))` bits in the enclosing bitfield: one variant is
free, two cost one bit, three or four cost two. Tagged enums fork the bit budget per branch and
take the maximum, rather than summing across branches — Zap sums, so its variants consume
separate bits even though only one can be present (`RESEARCH §3.9-Y`).

### Numbers

Written at their declared width. A range constraint narrows the width and subtracts the lower
bound: `u16(1000..1255)` is stored as `u8` holding `value - 1000`.

### Instances

An instance is appended to the sidecar array and nothing is written to the buffer. Its position
is implied by write order, so a decoder must consume instances in the same order — which is why
a skipped packet needs its instance count.

## 6. Decode failure

Nothing on the receive path calls `error`. Guarantee G4.

When a packet fails to decode — an out-of-range number, an unknown enum tag, a truncated string,
an unknown id — the reader:

1. Emits a rejection value (`channel`, `stage`, `reason`, `bytes`) to the observer.
2. Advances the cursor past this packet using its frame, and skips its instances.
3. Continues with the next packet.

For a `static` channel the skip distance is known from the schema. For `counted` it is the length
prefix. For an **unknown id** neither is available, because an unknown channel has no framing
mode — the batch is abandoned at that point and the rejection records how many bytes were
discarded. That is the one case netweave cannot isolate, and it means an id mismatch is a
whole-batch failure, which is exactly why §4's handshake exists.

A length that would run past the end of the batch is clamped, and the packet is rejected.

## 7. `derived` framing — not in v1

A schema whose only variability is optional presence has a size computable from its leading
bitfield: read the flags, add up the sizes of the present fields. Such a channel needs no length
prefix, which would take `FlagIdiomatic` from 8 bytes back to 7 and match Zap exactly.

It is deferred because the isolation it gives is weaker in one specific way: a corrupted bitfield
produces a wrong skip distance. The damage is bounded — the error is at most the sum of the
optional fields' widths, so the cursor lands near the true boundary rather than anywhere — but it
is not the clean guarantee `counted` gives.

Adding it later is backwards compatible only if the framing mode is part of the id-to-schema
mapping both peers already share, which it is. Gated on M1 phase 6 measuring whether one byte on
high-frequency flag packets is worth the weaker failure mode.
