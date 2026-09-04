--!strict
--!optimize 2

--[=[
	@class Config

	Global settings for netweave, in the shape ESLint made familiar: a rule name, and one of
	`"off"`, `"warn"` or `"error"`.

	```lua
	nw.configure({
		rules = {
			budget = "warn",
			authorize = "error",
			rateUnbounded = "off",
		},
		limits = { queueCapacity = 512 },
	})
	```

	:::caution What a severity does **not** do
	It never turns enforcement off. A packet refused at `budget` is refused whatever `budget` is
	set to; `"off"` silences the console, and nothing else. There is no setting anywhere in
	netweave that makes a refused packet arrive, a missing policy optional, or an unauthorised
	sender authorised — see [Config.rules] for why that asymmetry is deliberate.
	:::

	:::note Observers are never silenced
	Severity governs netweave's own console output. A callback attached with `nw.observe` receives
	every rejection regardless, because a metrics pipeline and a log level are different things and
	a game that turns down its logs has not asked to stop counting.
	:::
]=]

--[[
	The ESLint analogy is load-bearing for the *shape* and misleading about the *meaning*, and
	getting that wrong would have been the whole defect.

	A linter's `off` is safe: the rule stops reporting, and because a linter only ever reports,
	nothing else changes. Most of what netweave checks is not a report — it is a refusal that
	already happened, on data a hostile client sent. If `off` had meant "stop refusing", then the
	single most copy-pasted artifact in any ecosystem, a config block off a forum post, would be a
	way to remove G1 through G6 from a game whose author never read what they pasted.

	So severity is bound to output and never to enforcement, and the two are kept in different
	fields (`rules` versus `limits`) so that no future rule can quietly acquire the other meaning.

	The one place a severity does raise is a rule marked `wire = false`: those fire on the game's
	own declarations, where a raise is correct because `CLAUDE.md` §4 says `assert` is for
	programmer error. A rule marked `wire = true` can never raise at any severity — that is G4, and
	`RESEARCH §3.8-R` is what it costs to get wrong.
]]

local Config = {}

--[=[
	@type Severity "off" | "warn" | "error"
	@within Config

	| Severity | On a wire rule | On a declaration rule |
	|---|---|---|
	| `"off"` | silent | the check does not run |
	| `"warn"` | reported once per channel and stage | reported once, and execution continues |
	| `"error"` | reported **every** time, with a traceback | raised |

	`"error"` on a wire rule does not raise and cannot be made to. Wire data reaching `error()` is
	the failure G4 exists to prevent, so the strongest thing a severity can buy on the receive path
	is more output.
]=]
export type Severity = "off" | "warn" | "error"

--[=[
	@interface Rules
	@within Config
	.parse Severity? -- bytes that did not decode against the channel's schema
	.budget Severity? -- a sender over the channel's declared `rate`
	.authorize Severity? -- a policy said no
	.handler Severity? -- the game's own handler threw
	.queue Severity? -- a channel with no listener overflowed its queue
	.send Severity? -- an outgoing payload was refused before it left
	.protocol Severity? -- a peer joined on a different set of channel definitions
	.rateUnbounded Severity? -- a `rate` so large it cannot bind, declared as if it were a limit

	Seven of the eight are the stages of [Observer.Stage], because a rejection already carries the
	stage it happened at and inventing a second vocabulary for the same six things would only make
	them drift apart. `rateUnbounded` is the odd one out: it fires at declaration time, on the
	game's own code, and is the only rule here that raises at `"error"`.
]=]
export type Rules = {
	parse: Severity?,
	budget: Severity?,
	authorize: Severity?,
	handler: Severity?,
	queue: Severity?,
	send: Severity?,
	protocol: Severity?,
	rateUnbounded: Severity?,
}

--[=[
	@interface Limits
	@within Config
	.queueCapacity number? -- packets held for a channel whose listener has not attached yet
	.unreliableBytes number? -- the largest unreliable payload that will be sent
	.repeatsPerDiagnostic number? -- how many times one channel and stage prints before it goes quiet

	Numbers, not severities, and kept in their own field so that a limit can never be mistaken for
	a switch. Every one of them is read when the transport is built, so setting them after
	`require(netweave)` has no effect — configure before the first channel is declared.
]=]
export type Limits = {
	queueCapacity: number?,
	unreliableBytes: number?,
	repeatsPerDiagnostic: number?,
}

--[=[
	@interface Settings
	@within Config
	.rules Rules?
	.limits Limits?
	.contextGuard boolean? -- the Studio-only check that a `ctx` has not outlived its packet

	Every field is optional and anything omitted keeps its current value, so a call that sets one
	rule does not silently reset the rest.
]=]
export type Settings = {
	rules: Rules?,
	limits: Limits?,
	contextGuard: boolean?,
}

--[=[
	@interface Snapshot
	@within Config
	.rules { [string]: Severity }
	.limits { [string]: number }
	.contextGuard boolean?

	What [Config.snapshot] returns. Frozen at every level.
]=]
export type Snapshot = {
	read rules: { read [string]: Severity },
	read limits: { read [string]: number },
	read contextGuard: boolean?,
}

--[=[
	@interface Described
	@within Config
	.rule string
	.severity Severity
	.default Severity
	.wire boolean -- false means "error" raises; true means it never can
	.summary string

	One row of [Config.describe].
]=]
export type Described = {
	rule: string,
	severity: Severity,
	default: Severity,
	wire: boolean,
	summary: string,
}

--[[
	`wire` decides whether `"error"` may raise, and `floor` decides how far down a rule may be
	turned. Every rule here floors at `"off"` on purpose: none of them gates enforcement, so
	silencing one costs visibility and nothing else. A future rule that *does* gate something

--[[
	Width subtyping accepts extra properties, so `Settings` listing only the fields that exist
	forbids nothing: `{ rules = { handlers = "warn" } }` type-checks against a type with no
	`handlers`, and the author reads that as "configured" while the default quietly stays in force.
	It is the same hole `Channel` documents for channel specs, and it wants the same answer — a
	type function reading `properties` sees the extra key and can refuse it.

	The snapshot type is threaded through as a second argument rather than rebuilt here, because a
	type function body cannot see this module's own type aliases and a hand-built copy would drift
	from `Snapshot` the first time either changed.
]]
export type function CheckedSettings(spec, snapshot)
	local settings = types.copy(spec)

	if not settings:is("table") then
		error("nw.configure takes a table of settings: rules, limits, contextGuard")
	end

	local sections = { rules = true, limits = true, contextGuard = true }
	local ruleNames = {
		parse = true,
		budget = true,
		authorize = true,
		handler = true,
		queue = true,
		send = true,
		protocol = true,
		rateUnbounded = true,
	}
	local limitNames = { queueCapacity = true, unreliableBytes = true, repeatsPerDiagnostic = true }

	--[[ Annotated `any` throughout: inside a type function the values are the analyzer's own type
	     objects, and letting it infer them produces a cyclic type it then cannot print. ]]
	local function refuse(field: any, name: any, allowed: any)
		local names = {}

		for allowedName in allowed do
			table.insert(names, allowedName)
		end

		table.sort(names)

		error(`nw.configure: no such {field} \`{name}\`. Known {field}s: {table.concat(names, ", ")}`)
	end

	local function reject(container: any, field: any, allowed: any)
		for key in container:properties() do
			local name: any = (key :: any):value()

			if not allowed[name] then
				refuse(field, name, allowed)
			end
		end
	end

	reject(settings, "setting", sections)

	--[[ A section that is absent, or is not a table, is left to the value layer: `Settings` already
	     makes `rules = "off"` a type error, and repeating it here would produce two diagnostics for
	     one mistake. ]]
	local function section(name: any, field: any, allowed: any)
		local declared = settings:readproperty(types.singleton(name))

		if declared and (declared :: any):is("table") then
			reject(declared, field, allowed)
		end
	end

	section("rules", "rule", ruleNames)
	section("limits", "limit", limitNames)

	return types.copy(snapshot)
end

--[[
	Load-bearing. An `export type function` that its own module never references does not reduce
	across a `require` — it silently becomes `any`, and nothing reports it. M1 phase 5 lost the
	directional views and the trust brand to exactly this, and only the exact diagnostic count in
	`tests/api_reject.luau` noticed (`spike/declare/README.md` Q5).
]]
type _instantiateChecked = CheckedSettings<{ rules: { parse: "warn" } }, Snapshot>

--[[
	`wire` decides whether `"error"` may raise, and `floor` decides how far down a rule may be
	turned. Every rule here floors at `"off"` on purpose: none of them gates enforcement, so
	silencing one costs visibility and nothing else. A future rule that *does* gate something
	belongs in `limits`, not here — but if one ever lands here by mistake, `floor` is the field
	that stops it being switched off.
]]
type Rule = {
	default: Severity,
	floor: Severity,
	wire: boolean,
	summary: string,
}

local RANK: { [string]: number } = { off = 0, warn = 1, error = 2 }
table.freeze(RANK)

local RULES: { [string]: Rule } = {
	parse = {
		default = "warn",
		floor = "off",
		wire = true,
		summary = "bytes that did not decode against the channel's schema",
	},
	budget = {
		default = "warn",
		floor = "off",
		wire = true,
		summary = "a sender over the channel's declared rate",
	},
	authorize = {
		default = "off",
		floor = "off",
		wire = true,
		summary = "a policy refused the payload",
	},
	handler = {
		default = "error",
		floor = "off",
		wire = true,
		summary = "the game's own handler threw",
	},
	queue = {
		default = "warn",
		floor = "off",
		wire = true,
		summary = "a channel with no listener overflowed its queue",
	},
	protocol = {
		--[[ Every one, because a mismatch means that client cannot play at all and the rate is
		     bounded by joins rather than by packets. The repeat suppression would otherwise hide it
		     after three, and the fourth player is as stuck as the first. ]]
		default = "error",
		floor = "off",
		wire = true,
		summary = "a peer joined on a different set of channel definitions",
	},
	send = {
		default = "warn",
		floor = "off",
		wire = true,
		summary = "an outgoing payload was refused before it left",
	},
	rateUnbounded = {
		default = "warn",
		floor = "off",
		wire = false,
		summary = "a rate large enough that it cannot bind",
	},
}
table.freeze(RULES)

local LIMITS: { [string]: { default: number, min: number, max: number } } = {
	queueCapacity = { default = 256, min = 1, max = 65536 },
	unreliableBytes = { default = 908, min = 1, max = 908 },
	repeatsPerDiagnostic = { default = 3, min = 1, max = 1000 },
}
table.freeze(LIMITS)

--[[
	Two flat tables rather than one nested settings object, because the read side is
	`severity[stage]` on a rejection and `limit.queueCapacity` at construction — one index each,
	with no walk through an options tree and nothing to allocate.
]]
local severity: { [string]: Severity } = {}
local limit: { [string]: number } = {}
local contextGuard: boolean? = nil

local function restoreDefaults()
	for name, rule in RULES do
		severity[name] = rule.default
	end

	for name, bounds in LIMITS do
		limit[name] = bounds.default
	end

	contextGuard = nil
end

restoreDefaults()

local function known(set: { [string]: any }): string
	local names = {}

	for name in set do
		table.insert(names, name)
	end

	table.sort(names)

	return table.concat(names, ", ")
end

--[[
	An unknown key is an error rather than a shrug, and that is the one place this module is
	stricter than ESLint. A misspelled rule in a linter costs a rule; a misspelled rule here reads
	as "I configured this" while the default silently stays in force, and the author finds out from
	a support thread. `handler` versus `handlers` should not be a debugging session.
]]
local function reject(field: string, name: string, set: { [string]: any }): never
	error(`nw.configure: no such {field} \`{name}\`. Known {field}s: {known(set)}`, 3)
end

local function readSeverity(name: string, value: any): Severity
	local rule = RULES[name]

	if not rule then
		reject("rule", name, RULES)
	end

	if RANK[value] == nil then
		error(
			`nw.configure: rule \`{name}\` takes "off", "warn" or "error", got {typeof(value) == "string" and `"{value}"` or typeof(
				value
			)}`,
			3
		)
	end

	if RANK[value] < RANK[rule.floor] then
		error(`nw.configure: rule \`{name}\` cannot go below "{rule.floor}" — {rule.summary}`, 3)
	end

	return value
end

local function readLimit(name: string, value: any): number
	local bounds = LIMITS[name]

	if not bounds then
		reject("limit", name, LIMITS)
	end

	if type(value) ~= "number" or value ~= value or value % 1 ~= 0 then
		error(`nw.configure: limit \`{name}\` takes a whole number, got {tostring(value)}`, 3)
	end

	if value < bounds.min or value > bounds.max then
		error(`nw.configure: limit \`{name}\` is {value}, outside {bounds.min}..{bounds.max}`, 3)
	end

	return value
end

--[=[
	@within Config
	@function configure
	@param settings Settings

	Applies settings. Anything omitted keeps its current value.

	```lua
	nw.configure({ rules = { authorize = "warn" } })
	```

	Raises on an unknown rule, an unknown limit, a severity that is not one of the three, or a
	limit outside its range — all four are mistakes in the game's own source, where raising is the
	behaviour that gets them fixed.

	:::caution Configure before you declare
	Limits are read when the transport is built. Setting `queueCapacity` after the first channel
	has been declared changes the number this function reports and not the queue that already
	exists.
	:::
]=]
function Config.configure(settings: Settings)
	if type(settings) ~= "table" then
		error(`nw.configure takes a table of settings, got {typeof(settings)}`, 2)
	end

	local given = settings :: { [string]: any }

	for name in given do
		if name ~= "rules" and name ~= "limits" and name ~= "contextGuard" then
			reject("setting", name, { rules = true, limits = true, contextGuard = true })
		end
	end

	--[[
		Read everything before writing anything. A configure call that raised halfway would leave
		half a config applied and no way to tell which half, which is worse than either outcome the
		author expected.
	]]
	local rules: { [string]: Severity } = {}
	local limits: { [string]: number } = {}

	if given.rules ~= nil then
		if type(given.rules) ~= "table" then
			error(`nw.configure: \`rules\` is a table of rule names, got {typeof(given.rules)}`, 2)
		end

		for name, value in given.rules :: { [string]: any } do
			rules[name] = readSeverity(name, value)
		end
	end

	if given.limits ~= nil then
		if type(given.limits) ~= "table" then
			error(`nw.configure: \`limits\` is a table of limit names, got {typeof(given.limits)}`, 2)
		end

		for name, value in given.limits :: { [string]: any } do
			limits[name] = readLimit(name, value)
		end
	end

	if given.contextGuard ~= nil and type(given.contextGuard) ~= "boolean" then
		error(`nw.configure: \`contextGuard\` is a boolean, got {typeof(given.contextGuard)}`, 2)
	end

	for name, value in rules do
		severity[name] = value
	end

	for name, value in limits do
		limit[name] = value
	end

	if given.contextGuard ~= nil then
		contextGuard = given.contextGuard
	end
end

--[=[
	@within Config
	@function severityOf
	@param rule string
	@return Severity
	@private

	One table index. Called on the rejection path, which is cold by construction — the hot path is
	the packet that was not refused.
]=]
function Config.severityOf(rule: string): Severity
	return severity[rule] or "off"
end

--[=[
	@within Config
	@function raises
	@param rule string
	@return boolean
	@private

	Whether this rule at its current severity should raise. True only for a declaration rule set to
	`"error"`; a wire rule answers false at every severity, which is G4 expressed as a function
	rather than as a convention someone has to remember.
]=]
function Config.raises(rule: string): boolean
	local entry = RULES[rule]

	return entry ~= nil and not entry.wire and severity[rule] == "error"
end

--[=[
	@within Config
	@function limitOf
	@param name string
	@return number
	@private
]=]
function Config.limitOf(name: string): number
	return limit[name]
end

--[=[
	@within Config
	@function contextGuard
	@return boolean?
	@private

	`nil` means "decide as usual", which is Studio-only. A game that sets it explicitly gets what
	it asked for in both places.
]=]
function Config.contextGuard(): boolean?
	return contextGuard
end

--[=[
	@within Config
	@function snapshot
	@return Snapshot

	The current settings, frozen. Useful in a bug report, and safe to hand anywhere: mutating what
	comes back cannot reach the live tables, so a diagnostic screen cannot become a way to
	reconfigure the library by accident.
]=]
function Config.snapshot(): Snapshot
	local taken = {
		rules = table.clone(severity),
		limits = table.clone(limit),
		contextGuard = contextGuard,
	}

	table.freeze(taken.rules)
	table.freeze(taken.limits)
	table.freeze(taken)

	--[[ Frozen, so the value is read-only where the annotation is not; the cast says that and
	     nothing more. The tables inside are clones, so nothing here aliases the live config. ]]
	return taken :: Snapshot
end

--[=[
	@within Config
	@function describe
	@return { Described }

	Every rule, what it is set to, what it defaults to, and one line on what it reports. This is the
	list to print when someone asks what they can configure.
]=]
function Config.describe(): { Described }
	local names = {}

	for name in RULES do
		table.insert(names, name)
	end

	table.sort(names)

	local described = table.create(#names) :: { Described }

	for index, name in names do
		local rule = RULES[name]

		described[index] = {
			rule = name,
			severity = severity[name],
			default = rule.default,
			wire = rule.wire,
			summary = rule.summary,
		}
	end

	return described
end

--[=[
	@within Config
	@function reset
	@private

	Back to defaults. Exists for tests; a game has no reason to call it.
]=]
function Config.reset()
	restoreDefaults()
end

return Config
