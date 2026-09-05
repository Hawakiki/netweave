# netweave wire format v1

Frozen by PLAN-M1 phase 2. Changing anything here after M1 ships is a breaking change, so the
reasoning is recorded alongside each decision.

The query correlation in §2 is the one addition since the freeze, and it is a gap being filled
rather than a change: `nw.query` had no implementation until M3 phase 4, so no query packet had
ever crossed the wire and there was nothing yet to break.

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
packet := id:varint  [correlation if query]  frame  payload
```

`frame` depends on the channel's **framing mode**, which is a static property of its schema and
therefore known to both peers from the id alone. Nothing about the frame is negotiated at
runtime.

| Mode | When | `frame` |
|---|---|---|
| `static` | encoded size is known at definition time | *(empty)* |
| `counted` | size depends on data — arrays, strings, buffers, maps | `length:varint` |

**The writer frames at most 16,383 bytes**, while `t.string`, `t.buffer` and `t.array` document
65,535 and the reader accepts a five-byte varint. A `counted` frame reserves one byte for its length
and widens it to two; past that `Batch.patchVarint` raises at send time. So the type vocabulary
describes payloads the library cannot put on the wire, and it says so here rather than in a comment
calling it "a design problem, not a runtime one".

A third mode, `derived` — size computable from a fixed-position bitfield, as when the only
variability is optional presence — is described in §7. It is not part of v1.

Channels that can carry a variable number of instances also carry `instances:varint` in the
frame, for the same reason the length is there: a skipped packet must skip its instances too.

**Order within the frame: length, then instances.** Both are self-delimiting varints so either
order decodes, and this one is fixed by M2 rather than left to whoever writes the second
implementation.

A claimed instance count is bounded by what the sidecar actually holds, and a packet claiming more
stops the batch. Overstating it would move the sidecar cursor past entries belonging to the packets
behind it, and those would then decode successfully while holding **another packet's Instance** —
a wrong association rather than a failure, which neither side would see.

### Both framing modes resynchronise

~~A `static` packet cannot be skipped.~~ **Wrong, corrected in M2 phase 1.** A `static` channel's
size is fixed at definition time and the id names the channel, so once the id resolves the reader
already knows where the packet ends — no prefix is needed to step over it. The claim came from
`bench/src/shared/Modes/netweave.luau`'s stand-in, which stopped the batch there; that was a limit
of the stand-in, not of the format.

The one unrecoverable case is an **unresolvable id**. Without a channel there is no framing, so the
end of the packet is unknowable and everything behind it is unreachable. It is reported rather than
hidden.

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

### Request and response

A `query` is `C→S→C` on **one** wire id. The request and the reply travel in opposite directions
over the same number, because the side reading the packet already knows which of the two it can be:
a server never receives a reply and a client never receives a request. Spending a byte to say which
would be spending it to repeat something both peers know from the id alone.

```
request := id:varint  call:varint  frame(args)     args
reply   := id:varint  call:varint  status:u8  [ frame(returns)  returns  if status == 0 ]
```

**The call id is framing, not payload.** It sits ahead of the length prefix, so a `counted`
channel's length still counts exactly the bytes the schema produced — which keeps the derived byte
ceiling (`DESIGN-API.md` §3) a statement about the schema rather than a number that has to be
adjusted by however many bytes this particular call id took to write.

It is a **varint**. Blink (`Generator/init.luau:723-745`) and Zap (`client.rs:1329`) both use a
`u8`, so 256 unanswered calls is a hard ceiling and the 257th is dropped with a raise
(`RESEARCH §3.7-G`). netweave wraps at 16,383 and skips ids that are still outstanding, so two live
calls can never collide and the only bound is the one the game declares.

| Status | Name | Meaning |
|---|---|---|
| 0 | `OK` | the answer follows |
| 1 | `REFUSED` | a policy said no, or the rate budget did |
| 2 | `FAILED` | the handler raised, or its answer did not encode |
| 3 | `UNHANDLED` | nothing is attached to answer this channel |
| 4 | `BUSY` | this player already holds every call slot the server will |

**A non-zero status ends the packet.** There is no frame and no payload behind it. The alternative
— a zero-length payload — is expressible on a `counted` schema and not on a `static` one, where a
refused reply would have had to carry the schema's full fixed size in bytes of nothing. Ending at
the status byte is uniform across both framings and stays resynchronisable, because by the time the
reader has the status it has already read everything that tells it where the packet ends.

**A status is a code and never the server's reason.** A refusal's reason names the policy, the
field and sometimes the player; it is written for the game that owns the server. Sending it back
would publish the authorization model to the machine that model exists to distrust, one denied
request at a time. The reason goes to the observer on the server; the client gets the code.

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

Each peer computes a 32-bit FNV-1a hash over its own declarations, and the client sends it on
reserved id 0 as the **first packet of its first batch**. A peer whose hash differs is refused from
that point, before decode, at stage `protocol`.

```
control := 0:varint  kind:u8  length:varint  body
hello   := kind=1  length=4  hash:u32
```

The length is what lets id 0 hold "anything v2 needs": a kind a reader has never heard of is
stepped over rather than fatal. Three bytes of overhead, once per session, against having to bump
the batch version to add a control message.

### The hash covers the lowered IR

~~The hash covers names only, not types. A changed field type with an unchanged name is not caught
here; the per-field validation catches it as a rejection instead, which is the right place because
it is per packet rather than per session.~~ **Wrong on both counts, corrected in M3 phase 5.**

The per-field validation refuses *every* packet for the rest of the session, and it never says why.
Measured on eleven single-change pairs, the name-only hash was identical for **ten** of them —
including a field widened from `t.u8` to `t.u16`, a channel's class changed, and a query's `returns`
changed with its `args` untouched (`tests/protocol_runtime.luau`).

What goes into the hash is everything both peers need in order to read each other's bytes: the
qualified name, the class, and the lowered node tree of every schema the channel carries, plus the
derived framing and size numbers as a cross-check on the lowering itself.

What stays out is everything only one side enforces — `rate`, `burst`, `maxBytes`, `authorize`,
`audience`, `unreliable`. A hash that moved when a server tuned a rate limit would force a client
redeploy for a server-side edit, which is a good way to make sure rate limits never get tuned.

**32 bits is a deploy-skew detector, not a cryptographic claim.** Two genuinely different protocols
collide with probability 2^-32, and nothing here resists an adversary choosing a collision. Nothing
needs to: a client that forges a matching hash still has every field of every packet validated
against the schema it claims to share.

**A peer that says nothing is accepted.** The handshake diagnoses deploy skew; it is not an
authorization boundary, and treating it as one would be theatre — a hostile client omits the hello
and is then held to exactly the same per-field validation as one that sent it. Refusing a silent
peer would only turn a dropped packet into a player who cannot play.

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

Nothing on the receive path calls `error`. Guarantee G4, and since M3 phase 9 that is a guard rather
than a reading of the code: the read phase and the dispatch phase each run under a `pcall` that
restores the shared state and reports the raise, because the two paths that broke it were both ones
nobody had thought of.

**The instance sidecar is wire data too.** It arrives as the remote's second argument and a client
chooses its contents, so an entry that is not an Instance is refused where it is read, per packet,
like any other field that does not match its schema.

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
