--!strict

--[[
	Every public type, checked against the half of the suite that must compile.

		lune run tools/exports

	Not a `*_runtime` file, for the same reason `tools/messages.luau` is not: it reads source off
	disk, so it cannot run in Studio and the runner there must not pick it up.

	### Why this exists

	`CLAUDE.md` §9 already says it in one line — **write the `_ok` half** — and the incident behind
	that line was `nw.configure`, which shipped typed so that Luau rejected every call while
	`tests/config_reject.luau` counted nine of those rejections as its own cases passing.

	The M4 security report found the same shape three more times, and all three are *exported types
	nothing in `tests/` ever wrote down*:

	  * `nw.Views<D>` — annotating a namespace with it erases G3, G6 and every payload type for that
	    value, retroactively, for the whole file. `tests/api_reject.luau`'s count cannot see it,
	    because the erasure removes diagnostics from code that is *supposed* to produce them and no
	    file ever wrote `Views<`.
	  * `nw.Settings` — `CheckedSettings` refuses any argument typed with it, because every field is
	    optional and the check tests for the bare tag. The exported type cannot build the argument it
	    names.
	  * `t.PayloadOf` — never reduces across a `require`, so a payload alias built from it is an
	    error type and every annotation using it is unchecked (`spike/declare/README.md` Q5).

	A rejection file cannot catch any of these: in a `_reject` file a diagnostic is what success
	looks like, and all three failure modes *remove* diagnostics. Only a file that must compile can.

	### What it checks

	Every `export type` in the two public modules — `src/netweave.luau` (`nw.`) and
	`src/types/init.luau` (`t.`) — has to appear in at least one `tests/*_ok.luau`. Not merely be
	mentioned: written as `nw.Name` or `t.Name`, which is how a game reaches it.

	An export that is not covered has to be named in `UNCOVERED` below with a reason. That list is
	the same instrument as `-- netweave:expect N` and the harness floors: **a number someone changed
	is a number in the diff.** It fails in both directions — an uncovered export missing from the
	list, and a listed export that is now covered — so the list shrinks as the gaps are closed and
	cannot quietly grow.
]]

local fs = require("@lune/fs")

local failures = 0

local function fail(message: string)
	failures += 1
	print(`FAIL  {message}`)
end

--[[
	The public modules and the prefix a game reaches them through.

	`src/api/` and `src/transport/` export plenty of types too, and none of them are here: they are
	internal, `nw` does not re-export them, and requiring them directly is not a supported path
	(`CLAUDE.md` §2). What `nw` re-exports is exactly what this list has to cover.
]]
local SURFACES = {
	{ path = "src/netweave.luau", prefix = "nw" },
	{ path = "src/types/init.luau", prefix = "t" },
}

--[[
	Known gaps, each with the reason it is still a gap.

	Every entry here is a finding in `docs/SECURITY-REPORT-M4.md` or a type whose `_ok` half has not
	been written yet. An entry is removed by writing the coverage, not by editing this table — the
	check below fails if a listed name turns out to be covered, so the list cannot outlive the gap.
]]
--[[ Empty since PLAN-M4-BUG phase 6. The seven entries it held — `t.Ranged`, `t.Classed`,
     `t.Encoding`, `t.Kind` and the three payload type functions — were all "never written by hand",
     and the M4-1 report measured every one annotating cleanly with an annotation that really checks.
     A habit is not an inability, and this list is for inabilities. ]]
local UNCOVERED: { [string]: string } = {}

--[[
	A public value gets a public type (`PLAN-M5` D-3).

	The check above enumerates `export type` declarations, so it could never see a public *value*
	with no type at all — which is how `nw.policy`'s return, `nw.audience.nearby`'s return and
	`nw.configure`'s snapshot went three milestones with no name a game could write through `nw`
	(M4-1). This table is the other half: every top-level value on `nw` is either a family whose
	type is named here, or is listed in `UNTYPED` with the reason a type would be the wrong tool.

	Both lists are tested against `src/netweave.luau` in both directions — a value on `nw` that is
	in neither list fails, and an entry naming a value `nw` no longer has fails — so neither can
	drift from what it lists (`CLAUDE.md` §9).
]]
local FAMILIES: { { values: { string }, type: string } } = {
	{ values = { "policy", "all" }, type = "Policy" },
	{ values = { "allow", "deny" }, type = "Verdict" },
	{ values = { "validate" }, type = "Trusted" },
	{ values = { "observe" }, type = "Observer" },
	{ values = { "diagnostics" }, type = "Diagnostics" },
	{ values = { "configure" }, type = "Snapshot" },
	{ values = { "namespace" }, type = "Views" },
	{ values = { "protocol" }, type = "Protocol" },
}

--[[
	Values on `nw` that are not a family with a type of their own, and why.

	The seven channel constructors are the deliberate one: a channel record's type is five type
	parameters of internal shape, and the name a game writes is `nw.Views<typeof(ns.channels)>`,
	which carries every channel's payload and view. A bare `nw.Channel` would be a name for a value
	no game holds alone, and a name that exists is a name that will be reached for.
]]
local UNTYPED: { [string]: string } = {
	milestone = "a string",
	signature = "returns a string",
	types = "a module; its own types are the t. surface above",
	audience = "a module; its values are nw.Audience, checked as a type",
	store = "a module; its values are nw.Store, checked as a type",
	config = "a module; its values are nw.Snapshot and nw.Described, checked as types",
	internal = "private (CLAUDE.md section 2)",
	command = "a channel record, named through nw.Views<typeof(ns.channels)>",
	intent = "a channel record, named through nw.Views<typeof(ns.channels)>",
	signal = "a channel record, named through nw.Views<typeof(ns.channels)>",
	query = "a channel record, named through nw.Views<typeof(ns.channels)>",
	state = "a channel record, named through nw.Views<typeof(ns.channels)>",
	event = "a channel record, named through nw.Views<typeof(ns.channels)>",
	replicate = "a channel record, named through nw.Views<typeof(ns.channels)>",
}

--[[ Every `nw.<name> =` and `function nw.<name>` in the public module: the values a game can reach. ]]
local function valuesOf(source: string): { string }
	local names: { string } = {}

	for name in string.gmatch(source, "\nnw%.([%a_][%w_]*)%s*=") do
		table.insert(names, name)
	end

	for name in string.gmatch(source, "\nfunction nw%.([%a_][%w_]*)") do
		table.insert(names, name)
	end

	table.sort(names)
	return names
end

-- ---------------------------------------------------------------------------------------------

local function exportsOf(source: string): { string }
	local names: { string } = {}

	--[[ `export type function X` as well as `export type X`, because a type function is a public
	     type from the caller's side and two of the three findings above are type functions. ]]
	for name in string.gmatch(source, "export type function%s+([%a_][%w_]*)") do
		table.insert(names, name)
	end

	for name in string.gmatch(source, "export type%s+([%a_][%w_]*)") do
		if name ~= "function" then
			table.insert(names, name)
		end
	end

	table.sort(names)
	return names
end

--[[
	Comments are not coverage.

	Found by this file's own first run: the `_ok` file that closed three of the gaps below explains
	in a comment *which* types remain uncovered, and named them — so the check read its own
	documentation as evidence and reported `nw.Views`, `nw.Settings` and `t.PayloadOf` as covered.
	A checker that a comment can satisfy checks nothing.

	Both comment forms, and the long form at any bracket level, because `--[=[ ]=]` is the moonwave
	one and this file's siblings are full of it.

	Strings are not coverage either, for the same reason with one more step: the M4-1 report removed
	the `t.Ranged` entry and added a file holding `local _note = "t.Ranged is what t.u8 returns"`,
	and the check said covered. A string satisfies the checker and removes nothing from the
	analyzer, which is the exact hole the comment rule closed. So strings go in the same walk —
	one walk, because a `--` inside a string is not a comment and a quote inside a comment is not
	a string, and two passes would each be fooled by the other's construct.

	What still counts and should not: a bare alias nobody reads (`type _Never = nw.Views<{}>`).
	Requiring an annotation position is the fix and is not a character walk; deferred with a note
	in PLAN-M4-BUG.
]]
local function stripCommentsAndStrings(source: string): string
	local out = {}
	local at = 1
	local length = #source

	while at <= length do
		local char = string.sub(source, at, at)
		local pair = string.sub(source, at, at + 1)

		if pair == "--" then
			local _, opened, level = string.find(source, "^%[(=*)%[", at + 2)

			if opened then
				local _, finish = string.find(source, `]{level}]`, opened + 1, true)
				at = if finish then finish + 1 else length + 1
			else
				local newline = string.find(source, "\n", at, true)
				at = if newline then newline else length + 1
			end
		elseif char == '"' or char == "'" or char == "`" then
			--[[ A short string ends at the next unescaped matching quote. An interpolated one is
			     treated the same way, which misreads a quote inside `{}`; nothing in tests/ writes
			     a type name there, and the walk fails toward "not covered", which is the loud side. ]]
			local cursor = at + 1

			while cursor <= length do
				local next = string.sub(source, cursor, cursor)

				if next == "\\" then
					cursor += 2
				elseif next == char or next == "\n" then
					cursor += 1
					break
				else
					cursor += 1
				end
			end

			table.insert(out, " ")
			at = cursor
		elseif char == "[" then
			local _, opened, level = string.find(source, "^%[(=*)%[", at)

			if opened then
				local _, finish = string.find(source, `]{level}]`, opened + 1, true)
				table.insert(out, " ")
				at = if finish then finish + 1 else length + 1
			else
				table.insert(out, char)
				at += 1
			end
		else
			table.insert(out, char)
			at += 1
		end
	end

	return table.concat(out)
end

--[[ `nw.Name` followed by anything that cannot continue an identifier, so `nw.Trusted` does not
     count as covering a hypothetical `nw.Trust`. ]]
local function mentions(haystack: string, needle: string): boolean
	local at = 1

	while true do
		local start, finish = string.find(haystack, needle, at, true)

		if not start then
			return false
		end

		local following = string.sub(haystack, finish + 1, finish + 1)

		if not string.match(following, "[%w_]") then
			return true
		end

		at = finish + 1
	end
end

local ok = ""

for _, name in fs.readDir("tests") do
	if string.match(name, "_ok%.luau$") then
		ok ..= stripCommentsAndStrings(fs.readFile(`tests/{name}`))
	end
end

if ok == "" then
	fail("no tests/*_ok.luau files were found, so nothing could be checked")
end

local covered = 0
local exempt = 0
local seen: { [string]: boolean } = {}

for _, surface in SURFACES do
	for _, name in exportsOf(fs.readFile(surface.path)) do
		local qualified = `{surface.prefix}.{name}`
		seen[qualified] = true

		local reason = UNCOVERED[qualified]
		local used = mentions(ok, qualified)

		if used and reason then
			fail(
				`{qualified} is covered by an _ok file and still listed as a known gap. `
					.. `Delete its entry from UNCOVERED in tools/exports.luau.`
			)
		elseif used then
			covered += 1
		elseif reason then
			exempt += 1
		else
			fail(
				`{qualified} is exported and no tests/*_ok.luau writes it. Annotate a value with it `
					.. `in an _ok file, or add it to UNCOVERED in tools/exports.luau with the reason `
					.. `it cannot be — a guarantee tested only by things that must fail has no `
					.. `evidence that the thing which must work does (CLAUDE.md §9).`
			)
		end
	end
end

--[[ The other direction: an entry naming an export that no longer exists is a list drifting from
     what it lists, which is the failure §9 wrote the Protocol attribute test against. ]]
for qualified in UNCOVERED do
	if not seen[qualified] then
		fail(`UNCOVERED names {qualified}, which is not exported by either public module any more.`)
	end
end

-- ---------------------------------------------------------------------------------------------
-- A public value gets a public type
-- ---------------------------------------------------------------------------------------------

local surface = fs.readFile("src/netweave.luau")
local values = valuesOf(surface)
local placed: { [string]: string } = {}
local families = 0

for _, family in FAMILIES do
	if not seen[`nw.{family.type}`] then
		fail(`FAMILIES names the type nw.{family.type}, which src/netweave.luau does not export.`)
	end

	for _, value in family.values do
		if placed[value] then
			fail(`nw.{value} is listed twice, under nw.{placed[value]} and nw.{family.type}.`)
		end

		placed[value] = family.type
	end

	families += 1
end

for value, reason in UNTYPED do
	if placed[value] then
		fail(`nw.{value} is both a family (nw.{placed[value]}) and UNTYPED ("{reason}"); pick one.`)
	end

	placed[value] = "untyped"
end

local present: { [string]: boolean } = {}

for _, value in values do
	present[value] = true

	if not placed[value] then
		fail(
			`nw.{value} is a public value and neither FAMILIES nor UNTYPED in tools/exports.luau `
				.. `names it. Give it a type a game can write through nw, and list the family — or say `
				.. `why a type is the wrong tool (PLAN-M5 D-3).`
		)
	end
end

for value in placed do
	if not present[value] then
		fail(`tools/exports.luau lists nw.{value}, which src/netweave.luau no longer defines.`)
	end
end

if failures > 0 then
	error(`{failures} export checks failed`)
end

print(
	`OK      exports — {covered} public types written in an _ok file, {exempt} known gaps, `
		.. `{families} value families typed`
)

return true
