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
local UNCOVERED: { [string]: string } = {
	["t.Ranged"] = "the return of t.u8 and friends, never written by hand.",
	["t.Classed"] = "the return of t.instance, never written by hand.",
	["t.Encoding"] = "names the eight storages for internal tables; a game never writes one.",
	["t.Kind"] = "the discriminant of Descriptor, internal for the same reason.",
	["t.StructPayload"] = "reached through t.struct's signature rather than written.",
	["t.EnumPayload"] = "reached through t.enum's signature rather than written.",
	["t.UnionPayload"] = "reached through t.union's signature rather than written; a game names it "
		.. "with t.PayloadOf, which tests/types_ok.luau writes on both sides of a channel.",
}

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

if failures > 0 then
	error(`{failures} export checks failed`)
end

print(`OK      exports — {covered} public types written in an _ok file, {exempt} known gaps`)

return true
