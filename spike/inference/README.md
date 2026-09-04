# Type-inference spike

Throwaway experiments answering the two questions PLAN-M1 phase 1 gates on. Nothing here ships;
`src/` will re-derive the mechanism properly.

## Running

```sh
LSP=~/.rokit/tool-storage/johnnymorganz/luau-lsp/1.69.0/luau-lsp.exe

# Candidates A and B: stock solver
"$LSP" analyze --platform=standard spike/inference/a_collapse.luau
"$LSP" analyze --platform=standard spike/inference/b_explicit.luau

# Candidates C and D: require the new solver
"$LSP" analyze --platform=standard --flag:LuauSolverV2=true spike/inference/c_typefunction.luau
"$LSP" analyze --platform=standard --flag:LuauSolverV2=true spike/inference/d_views.luau
```

Assertions are made by assignment: a line that should type-check produces no output, and a line
that *should* fail is labelled as such in the file. A clean run of C reports exactly one error
(assertion 3); a clean run of D reports exactly two (assertion 4).

## Q1 — does `t.struct({ x = t.u8 })` infer `{ x: number }`?

**Yes, using `type function`, which requires `LuauSolverV2`.**

| Candidate | Result |
|---|---|
| A — `struct<V>(fields: {[string]: Schema<V>}) -> Schema<{[string]: V}>` | **fails worse than expected.** `V` unifies across fields, so a mixed struct is not merely collapsed to `{[string]: number \| string}` — it is *rejected*: `origin = u8` fails against a `V` already bound to `string`. The naive combinator signature cannot express a heterogeneous struct at all. |
| B — payload type named by the author | **compiles, and proves nothing.** Luau has no explicit type arguments at a call site, so the type comes from an annotation on the local. `structOf({ origin = str, nothingLikeShot = u8 })` typed as `Schema<Shot>` type-checks with zero errors. This is a cast wearing a combinator's clothes. |
| C — `type function StructPayload` | **works.** `StructPayload<typeof(fields)>` reduces to `{ label: string, origin: number }`, and assigning `{ origin: string, label: string }` to it errors with exactly that expected type. |

## Q2 — which `.server` / `.client` fallback is needed?

**None. Directional views are expressible, so `DESIGN-API.md` §7's fallback is not needed.**

A `type function` can branch on a singleton `__class` tag and build a *different* result type per
channel class, then map the whole declaration table. Candidate D produces:

```
ServerView<Decl>.fireWeapon  =  { listen: ((unknown, { origin: number, seq: number }) -> ()) -> () }
ClientView<Decl>.playerState =  { listen: (({ health: number }) -> ()) -> () }
```

Payload types survive the mapping, including inside the handler's parameters. The two direction
violations in assertion 4 fail at analysis time:

```
Key 'send' not found in table '{ listen: ((unknown, { origin: number, seq: number }) -> ()) -> () }'
Key 'publish' not found in table '{ listen: (({ health: number }) -> ()) -> () }'
```

G6 is therefore a compile-time guarantee, not a load-time one.

## The constraint this buys

`type function` is rejected outright by the stock solver: `TypeError: This syntax is not
supported`, followed by `Unknown type` at every use site.

It does, however, **compile and run fine** — verified with `luau.compile` under lune, which uses
stock Luau. It is purely an analysis-time construct that the runtime compiler skips.

So the split is:

| | New solver on | New solver off |
|---|---|---|
| Library loads and runs | yes | yes |
| Payload types inferred | yes | no |
| Direction violations caught | at analysis | not at all |
| Editor shows errors in netweave's own source | no | yes |

Whether netweave *requires* the new solver or merely rewards it is a product decision, not a
technical one, and it is recorded in `docs/DESIGN-API.md` §7.

## Incidental findings

- Luau has **no explicit type arguments at a call site**. `scalar<number>()` parses as
  `scalar < number > ()` and produces comparison errors. Generic instantiation has to come from
  an annotation on the receiving binding.
- The new solver does **not** push a local's annotation into a generic call's return:
  `local u8: Schema<number> = scalar()` infers `Schema<unknown>`. This does not affect the real
  library, where `t.u8` is a concrete value rather than a generic factory call, but it rules out
  a `scalar<T>()`-style constructor.
- `types.lookup` does not exist in the type-function environment; a type alias declared in the
  same file cannot be referenced from inside a `type function`. Types have to be reconstructed
  from `types.*` primitives or threaded in as parameters.
