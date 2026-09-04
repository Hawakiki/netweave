--!strict
--!optimize 2

--[=[
	@class netweave

	A Roblox networking library whose first-order goals are security and structure.

	```lua
	local nw = require(Packages.netweave)
	local t = nw.types

	return nw.namespace("combat", {
		fireWeapon = nw.command({
			data = t.struct({ origin = t.vector3, direction = t.unitVector3, seq = t.u16 }),
			rate = 20,
			authorize = nw.all(policy.alive, policy.originNearCharacter),
		}),

		playerState = nw.state({
			data = t.struct({ entityId = t.u16, position = t.vector3 }),
			audience = nw.audience.nearby(120),
		}),
	})
	```

	What makes this different from the libraries surveyed in `docs/RESEARCH-AND-PLAN.md` is not
	how a packet is sent — every one of them answers that about the same way. It is **what the API
	refuses to let you write**:

	| | Guarantee | Violating code |
	|---|---|---|
	| G1 | An inbound channel that changes authoritative state has no listener until a policy is attached | type error |
	| G2 | Every inbound channel declares a rate budget. There is no unlimited | type error |
	| G3 | Every server-to-client channel declares its audience. `broadcast` exists only where the audience is everyone | type error |
	| G4 | Wire data never reaches `error()`. Rejections are values, routed to an observer | not expressible |
	| G5 | Length-prefixed framing: one malformed packet cannot stop the rest of its batch | not expressible |
	| G6 | Direction is a class, not a string field | type error |

	:::caution
	netweave **requires Luau's new type solver** (`LuauSolverV2`). Half the guarantees above are
	type errors or they are nothing, and on the stock solver you would see analysis errors inside
	code you did not write. See `docs/DESIGN-API.md` §7.
	:::
]=]

--[[
	The public surface is assembled here and nowhere else. Each module below owns one idea and is
	independently testable; this file exists so a game writes `nw.command` rather than requiring
	six paths, and so there is exactly one place to look for what netweave exposes.
]]

local Audience = require("./api/Audience")
local Driver = require("./transport/Driver")
local Channel = require("./api/Channel")
local Context = require("./api/Context")
local Namespace = require("./api/Namespace")
local Observer = require("./api/Observer")
local Policy = require("./api/Policy")
local Transport = require("./api/Transport")
local Trust = require("./api/Trust")
local Types = require("./types")
local View = require("./api/View")

--[[
	Requiring netweave inside Roblox installs the transport. There is nothing to configure and no
	step to remember: a game that declared its channels correctly has already said everything the
	transport needs, and an install call in every game would be a step to forget.

	The guard is a check rather than a `pcall`, so that a genuine failure inside `install` is loud.
	Under lune there is no `game`, and the whole transport is testable there because Roblox lives
	behind `Link` and `Recipients` (`tests/transport_runtime.luau`).
]]
if typeof(game) == "Instance" then
	Driver.install()
end

local nw = {}

--[=[
	@prop types Types
	@within netweave

	The type vocabulary. One declaration yields the payload type, the validation and the
	serialisation.
]=]
nw.types = Types

--[=[
	@prop audience Audience
	@within netweave

	Who a `state` or `event` reaches. Guarantee G3.
]=]
nw.audience = Audience

-- Channel classes -------------------------------------------------------------------------------

nw.command = Channel.command
nw.intent = Channel.intent
nw.signal = Channel.signal
nw.query = Channel.query
nw.state = Channel.state
nw.event = Channel.event

-- Policies --------------------------------------------------------------------------------------

nw.policy = Policy.policy
nw.all = Policy.all
nw.allow = Policy.allow
nw.deny = Policy.deny

-- Trust -----------------------------------------------------------------------------------------

nw.validate = Trust.validate

-- Rejections ------------------------------------------------------------------------------------

nw.observe = Observer.observe

--[=[
	@within netweave
	@function namespace
	@param name string
	@param channels D -- a table of channels
	@return Views<D> -- `.server` and `.client`, typed per channel class

	Declares a namespace and returns its two directional views.

	```lua
	local combat = nw.namespace("combat", {
		fireWeapon = nw.command({ ... }),
	})

	combat.server.fireWeapon:listen(function(ctx, shot) end)
	combat.client.fireWeapon:send(shot)
	```

	The views are typed per channel class: a `command` has `listen` on the server and `send` on the
	client, and neither has the other. `combat.server.fireWeapon:send(...)` is an analysis error,
	not a runtime check — guarantee G6.
]=]
function nw.namespace<D>(name: string, channels: D): View.Views<D>
	return (Namespace.declare(name, channels :: any) :: any) :: View.Views<D>
end

--[=[
	@within netweave
	@function protocol
	@return Protocol

	The agreed channel numbering: an FNV-1a hash over every qualified channel name, sorted, plus
	the names themselves in id order.

	Both peers compute this independently. A mismatch means a stale client or a partial deploy, and
	it is worth refusing loudly at startup — every packet in the session would otherwise decode as
	the wrong channel, silently (`docs/WIRE-FORMAT.md` §4).
]=]
nw.protocol = Namespace.protocol

--[=[
	@type Trusted<T> T
	@within netweave

	A value that has passed the checks its channel declares.
]=]
export type Trusted<T> = Trust.Trusted<T>

--[=[
	@type Untrusted<T> T
	@within netweave

	A value that arrived from a client and conforms to its schema, and nothing more.
]=]
export type Untrusted<T> = Trust.Untrusted<T>

export type Ctx = Context.Ctx
export type Verdict = Policy.Verdict
export type Rejection = Observer.Rejection
export type Stage = Observer.Stage
export type Protocol = Namespace.Protocol
export type Views<D> = View.Views<D>

--[=[
	@prop internal table
	@within netweave
	@private

	The seams M2 attaches to, and the resets the test suite needs. Not part of the public surface:
	everything here either belongs to a milestone that has not landed or exists to undo state that
	a game has no reason to undo.
]=]
nw.internal = table.freeze({
	transport = Transport,
	context = Context,
	observer = Observer,
	namespaces = Namespace,
	view = View,
})

return table.freeze(nw)
