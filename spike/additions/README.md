# Additions spike (PLAN-M5 phase 5)

Two questions the nice-to-have types gated on, answered against luau-lsp 1.69.0 with
`LuauSolverV2`. Nothing here ships; `src/types/init.luau` carries the mechanism.

```sh
LSP=~/.rokit/tool-storage/johnnymorganz/luau-lsp/1.69.0/luau-lsp.exe
"$LSP" analyze --platform=standard --flag:LuauSolverV2=true spike/additions/a_literal_default.luau
"$LSP" analyze --platform=standard --flag:LuauSolverV2=true spike/additions/b_probe.luau
"$LSP" analyze --platform=standard --flag:LuauSolverV2=true spike/additions/c_literal_union.luau
```

## Does `t.literal("v3")` keep the singleton?

Not through a bare generic: `literal<V>(value: V)` called with `"v3"` infers `V = string` (file a,
line 12 errors). A boolean argument does keep `true`. **A bounded generic keeps both**:
`literal<V>(value: V & (string | boolean | number))` infers `"v3"` and `true`, widens a number to
`number` (Luau has no number singletons), and refuses a table at the call (file c: exactly one
error, on the table).

## Can `t.optional(x, default)` drop the `nil` by the default's type?

Yes. With `default: D?` and no argument, the type function receives `D` as **`unknown`**, not
`nil` (file b: `probe()` reduces to `"unknown"`), so `OptionalPayload(inner, default)` treats
`unknown` and `nil` alike as "no default" and returns `T?`, and anything else returns `T`. File a's
last two lines are the two halves: `optional(u8)` is `Type<number?>` and `optional(u8, 5)` is
`Type<number>`.
