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

## The `@lune/*` typedefs

`analyze.luau`, `bench/*.luau` and `tools/*.luau` are lune scripts, and since `PLAN-M5` phase 6 the
analyzer checks them too. Their `require("@lune/fs")` and friends resolve through an alias in
`.luaurc` that points at lune's own type definitions, which live outside the repository:

```sh
lune setup      # writes ~/.lune/.typedefs/<version>/ and the alias into .luaurc
```

The alias is committed, pinned to the lune version in `rokit.toml`, and spelled with `~` so it is
the same line on every machine. If `lune run analyze` reports `Unknown require: …@lune/fs.lua`, the
typedefs are missing on this machine and `lune setup` is the fix; if it reports a different version,
`rokit.toml` and the alias have drifted apart.
