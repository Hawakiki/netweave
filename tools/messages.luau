--!strict

--[[
	Every `error(` in `src/api/`, read as prose.

		lune run tests/messages

	Not a `*_runtime` file, and that is deliberate: this one reads the source off disk, so it cannot
	run in Studio and the runner there must not pick it up. The other checks that read files —
	`analyze`, `bench/check` — have the same shape.

	`PLAN-M3` acceptance 13: every error reachable from `src/api/` names what was written and what to
	write instead. The reason it is worth a check rather than a review habit is where these messages
	land. Half of netweave's guarantees are `type function` errors, and a type function's `error()` is
	printed **verbatim at the call site** — in the declaration file, next to the line that is wrong,
	which is exactly where somebody learning the library is looking. A message that names the rule
	and stops ("`rate` is a number of packets per second") tells that reader what netweave wanted and
	not what to type.

	Two things are checked, and neither can prove a message is *good*:

	  1. It carries a **repair marker** — a netweave spelling to write, or an imperative naming an
	     action. The list is below and is short on purpose: a marker added to get a message through
	     is a marker in the diff.
	  2. It **shows what was written**, or it takes at least 80 characters not to. A message that
	     does neither has named the rule and stopped, whatever words it used.

	The second rule started as a bare length floor and that was the wrong tool: it flagged
	`nw.configure: limit \`queueCapacity\` is 0, outside 1..65536`, which names the field, the value
	and the range in sixty characters, while passing nothing it should have caught. Written this way
	it is exact. Every message that survives phase 7 either interpolates the offending value or
	spends the words to explain a mistake that has no value to show — "nw.all composes policies and
	was given none" is the shape of the second kind.
]]

local fs = require("@lune/fs")

local failures = 0

local function fail(message: string)
	failures += 1
	print(`FAIL  {message}`)
end

--[[
	A message qualifies if it contains one of these.

	They fall into two groups. A netweave spelling — `nw.`, `t.`, `policy.` — means the message
	shows the reader something to type. An imperative means it names an action. Both answer "what do
	I do now"; the rule is that a message has to do one of them.
]]
local REPAIRS: { string } = {
	"nw.",
	"t.struct",
	"t.u8",
	"t.array",
	"policy.",
	"Transport.install",
	"rules.",
	"limits.",
	"instead",
	"Write it",
	"Write the",
	"Declare",
	"declare it",
	"Use ",
	"Remove",
	"Wrap it",
	"Raise the",
	"lower the",
	"Keep per-request",
	"Attach",
	"Copy the fields",
	"Fan out",
	"Require all",
	"Pass the",
	"call ",
	"returns = ",
}

--[[ How long a message has to be when it shows nothing of what was written. Calibrated against the
     messages phase 7 replaced: the longest of them was 53 characters ("a policy factory must return
     the per-request function"), and no message that explains a valueless mistake properly comes in
     under this. ]]
local FLOOR = 80

--[[
	Pull every `error(` call out of a file, as source text.

	Parenthesis balance rather than a pattern, because these calls span lines and carry parentheses
	of their own. What comes back is the whole call, which is what has to be searched: a message
	built by concatenation has its repair in a later fragment.
]]
local function callsIn(source: string): { { line: number, text: string } }
	local lines = string.split(source, "\n")
	local found: { { line: number, text: string } } = {}
	local index = 1
	local inBlock = false

	while index <= #lines do
		local line = lines[index]
		local trimmed = string.gsub(line, "^%s+", "")

		--[[
			`error(` inside a comment is prose *about* errors, not one — and this file's own header is
			full of it, as is `src/api/Observer.luau`, which explains G4 by naming the function it
			forbids. Both comment forms open at the start of a line here, which `stylua` enforces, so
			tracking the block form takes one flag rather than a parser.
		]]
		local opened = string.match(trimmed, "^%-%-%[=*%[") ~= nil
		local closed = string.match(line, "%]=*%]") ~= nil
		local wasInBlock = inBlock

		if opened and not closed then
			inBlock = true
		elseif inBlock and closed then
			inBlock = false
		end

		local isComment = wasInBlock or inBlock or opened or string.sub(trimmed, 1, 2) == "--"

		if not isComment and string.find(line, "error(", 1, true) then
			local depth = 0
			local parts: { string } = {}
			local cursor = index

			repeat
				local text = lines[cursor]

				if not text then
					break
				end

				table.insert(parts, text)

				for character in string.gmatch(text, "[%(%)]") do
					depth += if character == "(" then 1 else -1
				end

				cursor += 1
			until depth <= 0

			table.insert(found, { line = index, text = table.concat(parts, " ") })
			index = cursor
		else
			index += 1
		end
	end

	return found
end

--[[ The quoted text of a call, with the code around it removed, so the length floor measures the
     sentence rather than the indentation and the concatenation operators. ]]
local function prose(text: string): string
	local out: { string } = {}

	for fragment in string.gmatch(text, '"([^"]*)"') do
		table.insert(out, fragment)
	end

	for fragment in string.gmatch(text, "`([^`]*)`") do
		table.insert(out, fragment)
	end

	return table.concat(out, " ")
end

--[[
	A message can be held in a local and raised twice, which is the right shape when two failures are
	the same mistake seen from either side (`src/api/Trust.luau`, `src/api/Channel.luau`). The call
	then carries no quotes at all, and reading only the call would score it zero.

	One level of indirection is followed, and one is enough: a message assembled through two locals
	is a message nobody can read at the raise site either.
]]
local function resolve(source: string, text: string): string
	local said = prose(text)

	if said ~= "" then
		return said
	end

	local name = string.match(text, "error%(%s*([%a_][%w_]*)")

	if not name then
		return said
	end

	local start = string.find(source, `local {name} =`, 1, true)

	if not start then
		return said
	end

	--[[ From the assignment to the first line that is not a continuation of it. A concatenated
	     message ends where the indentation stops running on. ]]
	local block = string.sub(source, start)
	local finish = string.find(block, "\n\n", 1, true) or #block

	return prose(string.sub(block, 1, finish))
end

local files = fs.readDir("src/api")
table.sort(files)

local checked = 0

for _, name in files do
	if not string.match(name, "%.luau$") then
		continue
	end

	local source = fs.readFile(`src/api/{name}`)

	for _, call in callsIn(source) do
		checked += 1

		local text = call.text
		local said = resolve(source, text)
		local repaired = false

		for _, marker in REPAIRS do
			if string.find(said, marker, 1, true) then
				repaired = true
				break
			end
		end

		if not repaired then
			fail(
				`src/api/{name}:{call.line} names the rule and not the fix. Say what to write: `
					.. `{string.sub(said, 1, 70)}`
			)
		end

		--[[ An interpolation is the message showing what it was handed. Where there is nothing to
		     show, the words have to do the whole job, and there is a length that takes. ]]
		local shows = string.find(said, "{", 1, true) ~= nil

		if not shows and #said < FLOOR then
			fail(
				`src/api/{name}:{call.line} shows nothing of what was written and takes only {#said} `
					.. `characters to explain it. Interpolate the offending value, or spend the words: `
					.. `{said}`
			)
		end
	end
end

if checked < 60 then
	fail(`only {checked} error calls were found in src/api, which means the scan is broken`)
end

-- ---------------------------------------------------------------------------------------------
-- The worked example, and the copy of it in the design document
-- ---------------------------------------------------------------------------------------------

--[[
	`DESIGN-API.md` shows the example and `tests/example_runtime.luau` runs it, and the two are
	asserted to be the same text. A document quoting code it does not execute is a document that
	rots on the first rename; a test nobody reads is an example nobody finds.
]]
local function region(source: string, opening: string, closing: string, from: string): string
	local start = string.find(source, opening, 1, true)

	if not start then
		fail(`{from} has no {opening} marker`)
		return ""
	end

	--[[ From *after* the opening marker. Searching from `start` finds the marker's own closing
	     characters — the ``` that ends a fence is also in the ```lua that opens it — and the region
	     comes back empty, which the comparison below then reads as "nothing to compare". The check
	     passed a deliberately corrupted document until this line was fixed. ]]
	local body = start + #opening
	local finish = string.find(source, closing, body, true)

	if not finish then
		fail(`{from} has no {closing} marker`)
		return ""
	end

	return string.sub(source, body, finish - 1)
end

local example = region(
	fs.readFile("tests/example_runtime.luau"),
	"--#region example\n",
	"--#endregion",
	"tests/example_runtime.luau"
)

local quoted = region(
	fs.readFile("docs/DESIGN-API.md"),
	"<!-- example: tests/example_runtime.luau -->\n```lua\n",
	"```",
	"docs/DESIGN-API.md"
)

--[[ The second worked example, added in M4 phase 5b. Two regions rather than one longer one: the
     sixty-line cap is a statement about how much a reader has to hold in their head to understand
     the declaration surface, and replication is a separate thing to understand. ]]
local replication = region(
	fs.readFile("tests/example_runtime.luau"),
	"--#region replication\n",
	"--#endregion",
	"tests/example_runtime.luau"
)

local quotedReplication = region(
	fs.readFile("docs/DESIGN-API.md"),
	"<!-- example: tests/example_runtime.luau replication -->\n```lua\n",
	"```",
	"docs/DESIGN-API.md"
)

if replication == "" then
	fail("tests/example_runtime.luau has no replication example between its markers")
elseif quotedReplication == "" then
	fail("docs/DESIGN-API.md quotes nothing between its replication markers")
elseif replication ~= quotedReplication then
	fail("the replication example in DESIGN-API.md is not the one tests/example_runtime.luau runs")
	print(`  document: {#quotedReplication} characters`)
	print(`  test:     {#replication} characters`)
end

--[[ The README quotes both examples too, and rots the same way. Same fence markers, same rule. ]]
local readme = fs.readFile("README.md")

local quotedInReadme =
	region(readme, "<!-- example: tests/example_runtime.luau -->\n```lua\n", "```", "README.md")
local quotedReplicationInReadme =
	region(readme, "<!-- example: tests/example_runtime.luau replication -->\n```lua\n", "```", "README.md")

if quotedInReadme ~= example then
	fail("the example in README.md is not the one tests/example_runtime.luau runs")
end

if quotedReplicationInReadme ~= replication then
	fail("the replication example in README.md is not the one tests/example_runtime.luau runs")
end

local lines = #string.split(example, "\n") - 1

if example == "" then
	fail("tests/example_runtime.luau has no example between its markers")
elseif quoted == "" then
	fail("docs/DESIGN-API.md quotes nothing between its markers")
elseif example ~= quoted then
	fail("the example in DESIGN-API.md is not the one tests/example_runtime.luau runs")
	print(`  document: {#quoted} characters`)
	print(`  test:     {#example} characters`)
elseif lines > 60 then
	fail(`the worked example is {lines} lines, over the 60 the plan asks for`)
end

--[[
	`nw.milestone` against the plan directory.

	It is a typed string wherever it lives, and a typed string drifts — the benchmark's copy said
	`M2` for the whole of M3 and wrote it into every run document (M3 phase 9). Moving it to one
	place stops the two from disagreeing; this stops the one from going stale, at the moment it
	matters, which is when the next milestone's plan appears and this one still claims the last.

	`CLAUDE.md` §9: a hand-kept value is tested against what it names.
]]
local milestone = string.match(fs.readFile("src/netweave.luau"), 'nw%.milestone = "([^"]+)"')

if not milestone then
	fail("src/netweave.luau does not declare nw.milestone")
elseif not fs.isFile(`docs/milestone/PLAN-{milestone}.md`) then
	fail(`nw.milestone is "{milestone}" and docs/milestone/PLAN-{milestone}.md does not exist`)
else
	local plans = {}

	for _, entry in fs.readDir("docs/milestone") do
		local named = string.match(entry, "^PLAN%-M(%d+)%.md$")

		--[[ A plan may be written before its milestone opens — PLAN-M5 was, to hold what
		     PLAN-M4-BUG deferred — and says so under its title. It is not the newest until the
		     marker comes off, which is the same act as opening the milestone (CLAUDE.md §3). ]]
		if named then
			local head = string.sub(fs.readFile(`docs/milestone/{entry}`), 1, 600)

			if not string.find(head, "Status: not opened", 1, true) then
				table.insert(plans, tonumber(named))
			end
		end
	end

	table.sort(plans)

	--[[ The newest plan, because a milestone that has started is a milestone this build is in.
	     Sub-milestone files (`PLAN-M1a.md`) are deliberately not counted: they gate another rather
	     than being one. ]]
	local newest = `M{plans[#plans]}`

	if milestone ~= newest then
		fail(`nw.milestone is "{milestone}" and the newest plan is {newest}`)
	end
end

if failures > 0 then
	error(`{failures} message checks failed`)
end

print(
	`OK      messages — {checked} error calls in src/api, worked examples {lines} and `
		.. `{#string.split(replication, "\n") - 1} lines, milestone {milestone}`
)

return true
