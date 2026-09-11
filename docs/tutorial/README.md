# Tutorial

Nine steps, in an empty place, from a fresh `require` to a replicated inventory and the types to
name it with. Each step ends with something you can run and something that refuses to compile,
because half of netweave is what it refuses to let you write.

The code here is written against the library as it stands at the close of M4. Where a step shows a
type error, the error text is what the analyzer prints; where it shows a refusal, the line is what
the console prints. `docs/DESIGN-API.md` is the contract behind every step, and each step names the
section it draws on. Every declaration and call in the nine steps is also in
`tests/tutorial_ok.luau`, which the analyzer has to accept, so a spelling here cannot drift from the
library without the build saying so.

1. [Install, and turn the solver on](step1-install.md)
2. [Declare a namespace](step2-declare.md)
3. [Write a policy](step3-policies.md)
4. [Send, listen, publish](step4-send-and-listen.md)
5. [Read the refusals](step5-refusals.md)
6. [Replicate a store](step6-replicate.md)
7. [The other classes: intent, signal, query, state](step7-the-other-classes.md)
8. [Types, bytes, and what the decoder refuses](step8-types-and-bytes.md)
9. [Naming the types in your own code](step9-naming-the-types.md)

## The vocabulary on one card

Seven classes, and which method each side has. The first time through you will look this up;
after that the class name says it.

| Class | Goes | Declares | Server view | Client view | The handler receives |
|---|---|---|---|---|---|
| `command` | client → server | `data`, `rate`, `authorize` | `:listen(function(ctx, value))` | `:send(value)` | `Trusted<T>` |
| `intent` | client → server | `data`, `rate`, `unreliable?` | `:listen(function(ctx, value))` | `:send(value)` | `T`, the newest per player per tick |
| `signal` | client → server | `data`, `rate`, `unreliable?` | `:listen(function(ctx, value))` | `:send(value)` | `Untrusted<T>` |
| `query` | client → server → client | `args`, `returns`, `rate`, `timeout`, `authorize` | `:handle(function(ctx, args) return answer end)` | `:invoke(args)` → `(answer?, reason?)`, yields | `Trusted<T>` |
| `state` | server → client | `data`, `audience`, `unreliable?` | `:publish(subject, value)`, and `:broadcast(value)` only under `everyone` | `:listen(function(value))` | `T` |
| `event` | server → client | `data`, `audience`, `unreliable?` | the same two | `:listen(function(value))` | `T` |
| `replicate` | server → client | `subject`, `data`, `audience`, `store` | nothing: the store is the only way in | `:listen(function(subject, value))` | `T`, or `nil` for a subject going away |

Every inbound class may also declare `burst` and, where its payload has a length prefix, `maxBytes`.
`ctx` is `player`, `channel`, `now`, `character`, `humanoid`; a policy check receives it typed, a
handler receives `player` as `unknown` and casts. Schemas come from `t`, and the payload type of any
schema is `t.PayloadOf<typeof(schema)>` — written by hand only in a policy's parameter, and Step 3
says why.

Two rules that hold through all nine steps. Every namespace is declared before the first packet
moves, on both sides, because each channel's wire id depends on every other channel in the program.
And the `--!strict` header is not optional: the guarantees the tutorial leans on are type errors,
and a file that does not type-check is a file where they are not being checked.
