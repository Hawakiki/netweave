# Pattern-cost spike

The probe behind PLAN-M4-BUG phase 2, kept so the number in `t.string`'s docstring can be re-run.
Nothing here ships; the rule lives in `src/types/init.luau` (`scanPattern`, `PATTERN_STEPS`).

## Running

```sh
lune run spike/pattern/cost
```

## What it measured (2026-09-08, lune, this machine)

The reader runs `string.find(value, "^" .. pattern .. "$")` on a peer's string. With `k` unbounded
items the anchored match is about `n^k` steps in the input length `n`:

| input | `(.*)x(.*)y` on `x^n` | `(.*)@(.*)%.(.*)` on `@^n` | `[%w_]+` (control) |
|---|---|---|---|
| 1,024 B | 5.5 ms | 7.7 ms | 0.008 ms |
| 4,096 B | 88 ms | 123 ms | 0.034 ms |
| 16,384 B | 1,415–1,512 ms | 2,096–2,162 ms | 0.14 ms |

4× the input, ~16× the time — quadratic, as the item count says. SECURITY-REPORT-M4-1 measured
the three-item pattern at 65,535 bytes, the default `max`, at 34 seconds; the probe stops at 16 KB
so it finishes in seconds. Before phase 2, `t.string(0, 65535, { pattern = "(.*)@(.*)%.(.*)" })`
was accepted.

The rule admits `max^k ≤ 2^16`. At the boundary it allows:

| declaration | worst case |
|---|---|
| two items, `max = 256` | 0.38–0.40 ms |
| three items, `max = 40` | 0.014 ms |

which a `rate` can budget, and which is why the budget is on the product rather than on the item
count: a short field keeps its two `.*`.
