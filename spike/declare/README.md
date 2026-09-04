# Declaration-surface spike

Throwaway experiments behind PLAN-M1 phase 5. Nothing here ships; `src/api/` re-derives each
mechanism properly. Every finding below is cited from the source file that depends on it, so a
comment in `src/` can say *why* without restating the experiment.

## Running

```sh
LSP=~/.rokit/tool-storage/johnnymorganz/luau-lsp/1.69.0/luau-lsp.exe
FLAGS="--platform=roblox --definitions=tools/globalTypes.d.luau --flag:LuauSolverV2=true --no-strict-dm-types"

"$LSP" analyze $FLAGS spike/declare/forbidden.luau   # expect 3
"$LSP" analyze $FLAGS spike/declare/brand.luau       # expect 3, and read which 3
"$LSP" analyze $FLAGS spike/declare/views.luau       # expect 4
"$LSP" analyze $FLAGS spike/declare/infer.luau       # expect 5
"$LSP" analyze $FLAGS spike/declare/mod/use.luau     # expect 4, not 5
```

Assertions are made by assignment. A line that should type-check produces no output; a line
marked MUST FAIL that produces no output means the mechanism has silently stopped working, which
is the failure mode this whole directory exists to catch.

## Q1 — can a spec type *forbid* a field?

**Not by omitting it.** Width subtyping accepts extra properties, so `IntentSpec = { data, rate }`
does not reject `intent({ data = ..., rate = 60, authorize = f })`. Measured in `forbidden.luau`,
both for an inline table literal and for one passed through a local.

Declaring the forbidden field as `authorize: nil` does work, and was the first implementation. It
was replaced by a type function that reads the property and calls `error()`, because that also
reports *why* — see Q4.

## Q2 — does the trust brand in `DESIGN-API.md` §6 hold?

**For table payloads, yes. For scalars it is worse than nothing.** `brand.luau`:

| Claim §6 makes | Result |
|---|---|
| `Untrusted<T>` is usable as a bare `T` | **fails for scalars.** `wire + 1` does not type-check |
| a bare `T` does not satisfy `Trusted<T>` | holds |
| `Untrusted<T>` does not satisfy `Trusted<T>` | holds for tables, **fails for scalars** |

The cause is that `number & { __nwTrusted: true? }` normalises to **`never`**, and `never` is a
subtype of everything. A branded scalar therefore rejects every legitimate use of the value while
satisfying every parameter it was supposed to guard — the worst of both.

So both brands are type functions that pass non-table payloads through unchanged
(`src/api/Trust.luau`), and `DESIGN-API.md` §6 is corrected to say so. The alternative — a wrapper
table with arithmetic metamethods — was already rejected there for lying about the runtime value.

## Q3 — can one type function map six channel classes to two directional views?

**Yes,** including the two things `spike/inference/d_views.luau` did not cover: `query` carries two
payloads, and `broadcast` must exist only where the audience is `everyone`. `views.luau` produces
exactly four diagnostics — two direction violations, one missing `broadcast`, one untrusted
payload reaching a `Trusted<T>` parameter — and nothing else.

Two mechanics were needed to get there:

- **`types.copy` on an incoming type.** Calling one type function from another leaves the
  parameter generic, and `types.intersectionof` over a generic fails to reduce — reported inside
  netweave's own source, where a user cannot act on it.
- **Every `types.newfunction` argument written inline.** Hoisting `{ head = ... }` into a local
  seals it, and a sealed table with no `tail` is then rejected against
  `{ head: {type}?, tail: type? }`.

## Q4 — why is a channel's spec a free generic rather than a spec type?

Because `command<T>(spec: { data: Types.Type<T>, ... })` **does not bind `T`**. `infer.luau`
compares three encodings against the same schema:

| Encoding | Inferred payload |
|---|---|
| `data: Types.Type<T>` | `unknown` |
| `data: { __payload: T }` | `unknown` |
| a type function reading `__payload` off the whole spec | `{ origin: Vector3, seq: number }` |

Two further observations made the choice unambiguous:

- Where `T` appeared in two positions — `data` and `authorize` — an unannotated policy widened it
  to `any`, silently disabling inference for the entire channel. Projecting from `data` alone
  cannot be clobbered.
- **A type function's `error()` is reported at the call site verbatim.** That is what lets
  `nw.command({ data = ..., rate = 20 })` say *"needs `authorize` … if this channel genuinely
  carries no authority, declare it a signal"* instead of printing two structural table types and
  leaving the reader to diff them.

## Q5 — do `export type function`s survive a `require`?

**Only if the defining module references them itself.** `mod/` declares four identical brands and
uses each differently:

| Referenced in its own module by | Reduces for a requiring module |
|---|---|
| nothing | **no — becomes `any`, with no diagnostic** |
| an exported plain type alias | yes |
| a local type alias, otherwise unused | yes |
| a function signature | yes |

This is the most dangerous finding in the directory, because the failure is silent and looks like
success. `View.ServerView` and `Trust.Trusted` were both `any` for a while: `tests/api_ok.luau`
type-checked, `tests/api_reject.luau` reported eight of its thirteen cases, and the five that
vanished were exactly the direction and trust guarantees the file exists to test.

`src/api/View.luau` pins its two view mappers with the `Views<D>` alias, and `src/api/Trust.luau`
pins its two brands with local aliases — each with a comment saying what deleting the line breaks.
