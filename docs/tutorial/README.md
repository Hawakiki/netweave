# Tutorial

Seven steps, in an empty place, from a fresh `require` to a replicated inventory. Each step ends
with something you can run and something that refuses to compile, because half of netweave is what
it refuses to let you write.

The code here is written against the library as it stands at the close of M4. Where a step shows a
type error, the error text is what the analyzer prints; where it shows a refusal, the line is what
the console prints. `docs/DESIGN-API.md` is the contract behind every step, and each step names the
section it draws on.

1. [Install, and turn the solver on](step1-install.md)
2. [Declare a namespace](step2-declare.md)
3. [Write a policy](step3-policies.md)
4. [Send, listen, publish](step4-send-and-listen.md)
5. [Read the refusals](step5-refusals.md)
6. [Replicate a store](step6-replicate.md)
7. [The other classes: intent, signal, query](step7-the-other-classes.md)

Two rules that hold through all seven. Every namespace is declared before the first packet moves,
on both sides, because each channel's wire id depends on every other channel in the program. And
the `--!strict` header is not optional: the guarantees the tutorial leans on are type errors, and a
file that does not type-check is a file where they are not being checked.
