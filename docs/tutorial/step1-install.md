# Step 1 — Install, and turn the solver on

**What you have at the end:** a place where both a server script and a client script can require
netweave, with the type solver that makes its guarantees checkable.

## Put the library where both sides can reach it

netweave is the `src/` directory of this repository. It has no build step: every `require` inside
it is a relative string, and that resolves the same way in Studio and under lune. So installing it
is putting that directory somewhere both peers replicate.

Either of these works:

- Copy `src/` into your project as a folder named `netweave`, under `ReplicatedStorage`. With Rojo,
  that is one line in your project file:

  ```json
  "ReplicatedStorage": {
  	"netweave": { "$path": "path/to/netweave/src" }
  }
  ```

- Or build the package once and insert it: `rojo build default.project.json -o netweave.rbxm` from
  the repository root produces a `Folder` named `netweave`, and dragging it into `ReplicatedStorage`
  is the whole install.

Either way the tree looks like this, and the module you require is the one named `netweave` inside
the folder named `netweave`:

```
ReplicatedStorage
└── netweave            (Folder)
    ├── netweave        (ModuleScript)  ← require this
    ├── api
    ├── codec
    ├── replication
    ├── transport
    └── types
```

There is no `init` module, and there must not be one: for an init file `./` means *sibling of the
directory*, so it could not reach its own children. `CLAUDE.md` §2 has the measurement.

## Turn the new solver on

Half of netweave's guarantees are `type function` errors, and the old Luau solver rejects that
syntax outright. As of the solver's general release, a `--!strict` project stays on the **old**
solver by default. Open **Workspace Properties → Scripting** and enable the new type solver for this
place. Without it, every declaration in this tutorial still runs, but the lines marked "does not
type-check" will type-check, which is the opposite of what you want from them.

`docs/DESIGN-API.md` §0 explains why the library requires the solver rather than degrading without
it. The short version: a guarantee that is only sometimes checked is a guarantee nobody can rely on.

## Require it

On the server and on the client, the first lines are the same:

```lua
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local nw = require(ReplicatedStorage.netweave.netweave)
local t = nw.types
```

Requiring it inside Roblox installs the transport. It creates a folder named `NETWEAVE` under
`ReplicatedStorage` with one `RemoteEvent` and one `UnreliableRemoteEvent`, connects a flush to
`PostSimulation`, and waits. There is nothing to configure: a game that declares its channels has
already said everything the transport needs, and the rate, the audience and the batching are not
decisions to be made per game (`docs/DESIGN-API.md` §1).

You can check it took:

```lua
print(nw.milestone)  --> "M4"
```

## What you will see when it is wrong

If the solver is off, `nw.command({ data = t.u8, rate = 5 })` — a command with no `authorize` —
analyses clean, and the first time the declaration runs it raises instead:

```
nw.command needs authorize. Build one with nw.policy, or compose several with nw.all. A command
without authorization is the shape of every Roblox exploit writeup; if this channel genuinely
carries no authority, declare it a signal.
```

With the solver on, the same declaration is refused at that line in the editor, before anything
runs. Every message in the library is written to name the fix rather than the rule, and
`tools/messages.luau` checks that they do. Step 2 declares a channel that earns a clean line.

**Next:** [Step 2 — Declare a namespace](step2-declare.md)
