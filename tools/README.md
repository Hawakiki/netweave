# tools

## `globalTypes.d.luau`

Roblox's global type definitions, consumed by `luau-lsp analyze` (see `analyze.luau`). Without it
the analyzer does not know `Vector3`, `CFrame` or `Instance`, and `src/types/` cannot be checked
at all.

Downloaded from luau-lsp's own repository, which regenerates it from the Roblox API dump:

```sh
curl -sL -o tools/globalTypes.d.luau \
  https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau
```

It is committed rather than fetched on demand so that `lune run analyze` works offline and gives
the same answer on every machine. Refresh it when netweave needs a Roblox API that postdates it.
