--!strict
--!optimize 2

--[[
	Type-checks the project, and checks that the code which is *supposed* to fail still does.

	Run from the repository root:
		lune run analyze

	This is not a lint pass. Half the guarantees in `docs/DESIGN-API.md` are type errors or they
	are nothing (PLAN-M1 D-7), so an analyzer run is part of the test suite: `tests/*_ok.luau`
	must produce no diagnostics, and each `tests/*_reject.luau` must produce exactly the number
	of diagnostics its header declares, on the lines it marks, saying what the marks say. A
	rejection file that stops erroring means a guarantee has silently stopped being enforced,
	which is worse than a build break.

	`LuauSolverV2` is required — `type function` does not exist without it.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

local DEFINITIONS = "tools/globalTypes.d.luau"
local ROOTS = { "src", "tests" }

local function color(name: stdio.Color, text: string): string
	return `{stdio.color(name)}{text}{stdio.color("reset")}`
end

local function findLuauLsp(): string
	local home = process.env.USERPROFILE or process.env.HOME
	assert(home, "cannot locate the home directory to find luau-lsp")

	local storage = `{home}/.rokit/tool-storage/JohnnyMorganz/luau-lsp`
	if not fs.isDir(storage) then
		storage = `{home}/.rokit/tool-storage/johnnymorganz/luau-lsp`
	end

	assert(fs.isDir(storage), `luau-lsp is not installed; run \`rokit install\` ({storage})`)

	local versions = fs.readDir(storage)
	table.sort(versions)

	return `{storage}/{versions[#versions]}/luau-lsp.exe`
end

local function collect(dir: string, out: { string }): { string }
	if not fs.isDir(dir) then
		return out
	end

	for _, entry in fs.readDir(dir) do
		local path = `{dir}/{entry}`
		if fs.isDir(path) then
			collect(path, out)
		elseif string.match(path, "%.luau$") then
			table.insert(out, path)
		end
	end

	return out
end

--[[
	`.luaurc` says strict, and a file-level `--!nonstrict` or `--!nocheck` wins over it — the mode
	is `sourceModule.mode.value_or(config.mode)` in luau's Frontend, and no prose page says so. So
	one changed line removes every diagnostic from a module while this file prints "clean", which is
	the cheapest way there is to make a stubborn analyzer complaint go away (SECURITY-REPORT-M4-1,
	tools 위험 1). The header is checked here, not left to the analyzer, because the analyzer is the
	thing the header switches off.
]]
local function strictHeader(path: string): boolean
	for line in string.gmatch(fs.readFile(path), "[^\n]+") do
		if string.match(line, "%S") then
			return string.match(line, "^%s*%-%-!strict%s*$") ~= nil
		end
	end

	return false
end

--[[
	A rejection file declares how many diagnostics it expects, anywhere in its header:
		-- netweave:expect 3

	and marks each line it expects one on with a fragment the diagnostic has to contain:
		local _wrong: Type<number> = t.optional(t.u16) -- netweave:reject 'Type<number>'

	Deliberately not a `--!` directive: Luau lints unknown ones, so the marker would count itself.

	The count alone was the M3 `maxBytes` shape at file scale: delete the case that pins G3, add a
	`local _: number = "x"` anywhere, and the count is still 24. Lines alone were measured next and
	are not enough either — the junk swapped onto the marked line passes. So a mark says what it
	expects, and a line carries one diagnostic: a line that produces two is split, not marked twice.
]]
type Expectation = { count: number, lines: { [number]: string } }

local function expectedFailures(path: string): Expectation?
	local source = fs.readFile(path)
	local count = string.match(source, "%-%- netweave:expect%s+(%d+)")

	if not count then
		return nil
	end

	local lines: { [number]: string } = {}
	local number = 0

	for line in string.gmatch(source .. "\n", "([^\n]*)\n") do
		number += 1
		local marked, needle = string.match(line, "%-%- netweave:reject(%s*)(.-)%s*$")
		if marked then
			--[[ A bare mark would be the line-only instrument that was measured not to bite. ]]
			lines[number] = if needle == "" then "" else needle
		end
	end

	return { count = tonumber(count) :: number, lines = lines }
end

local luauLsp = findLuauLsp()
assert(fs.isFile(DEFINITIONS), `{DEFINITIONS} is missing; see tools/README.md`)

--[[
	Returns the output, the diagnostic count, the diagnostics by line, and whether luau-lsp itself
	ran. Exit codes measured at 1.69.0: 0 clean, 1 with diagnostics, 1 on a usage error — so a
	non-zero exit with nothing counted is the tool failing, not the tree passing. Before this
	distinction a bad flag printed a usage banner to stderr and the must-be-clean half said
	"OK 52 files clean" (SECURITY-REPORT-M4-1, tools 위험 2).
]]
local function analyze(files: { string }): (string, number, { [number]: { string } }, boolean)
	local args = {
		"analyze",
		"--platform=roblox",
		`--definitions={DEFINITIONS}`,
		"--flag:LuauSolverV2=true",
		"--no-strict-dm-types",
	}

	for _, file in files do
		table.insert(args, file)
	end

	local result = process.exec(luauLsp, args)
	local output = result.stdout .. result.stderr
	local diagnostics = 0
	local byLine: { [number]: { string } } = {}
	local last: { string }? = nil

	for line in string.gmatch(output, "[^\n]+") do
		--[[ Diagnostics are `path(line,col): Kind: message`, and a message can continue over the
		     lines that follow — `Expected this to be` puts the two types on their own lines. ]]
		local at, message = string.match(line, "^%S+%((%d+),%d+%): (.*)$")
		if at then
			diagnostics += 1
			local number = tonumber(at) :: number
			local list = byLine[number] or {}
			byLine[number] = list
			table.insert(list, message)
			last = list
		elseif last then
			last[#last] ..= " " .. line
		end
	end

	local ran = result.code == 0 or diagnostics > 0

	return output, diagnostics, byLine, ran
end

--[[ Every line that expected a diagnostic and did not get one, got one without asking, got more
     than one, or got one that does not say what the mark says. Empty means the file is exactly
     what it declares. ]]
local function misplaced(expected: { [number]: string }, actual: { [number]: { string } }): { string }
	local problems: { string } = {}
	local numbers: { number } = {}
	local seen: { [number]: boolean } = {}

	for number in expected do
		table.insert(numbers, number)
		seen[number] = true
	end

	for number in actual do
		if not seen[number] then
			table.insert(numbers, number)
		end
	end

	table.sort(numbers)

	for _, number in numbers do
		local needle = expected[number]
		local got = actual[number]

		if needle == nil then
			table.insert(problems, `line {number} produced a diagnostic and is not marked netweave:reject`)
		elseif needle == "" then
			table.insert(problems, `line {number} is marked netweave:reject without saying what it expects`)
		elseif got == nil then
			table.insert(problems, `line {number} expected a diagnostic saying "{needle}" and produced none`)
		elseif #got > 1 then
			table.insert(
				problems,
				`line {number} produced {#got} diagnostics; split it so each has its own mark`
			)
		elseif not string.find(got[1], needle, 1, true) then
			local head = string.sub(got[1], 1, 90)
			table.insert(problems, `line {number} expected a diagnostic saying "{needle}"; it says "{head}"`)
		end
	end

	return problems
end

local ok: { string } = {}
local rejects: { { path: string, expected: Expectation } } = {}
local failed = false

for _, root in ROOTS do
	for _, path in collect(root, {}) do
		if not strictHeader(path) then
			failed = true
			print(
				color(
					"red",
					`FAILED  {path} does not start with --!strict; the analyzer skips what it says to`
				)
			)
		end

		local expected = expectedFailures(path)
		if expected then
			table.insert(rejects, { path = path, expected = expected })
		else
			table.insert(ok, path)
		end
	end
end

if #ok > 0 then
	local output, diagnostics, _, ran = analyze(ok)

	if not ran then
		failed = true
		print(color("red", `FAILED  luau-lsp did not run over the {#ok} files that must be clean`))
		print(output)
	elseif diagnostics > 0 then
		failed = true
		print(color("red", `FAILED  {diagnostics} diagnostics across {#ok} files that must be clean`))
		print(output)
	else
		print(color("green", `OK      {#ok} files clean`))
	end
end

for _, reject in rejects do
	local output, diagnostics, byLine, ran = analyze({ reject.path })
	local expected = reject.expected
	local declared = 0

	for _ in expected.lines do
		declared += 1
	end

	local problems = misplaced(expected.lines, byLine)

	if not ran then
		failed = true
		print(color("red", `FAILED  luau-lsp did not run over {reject.path}`))
		print(output)
	elseif declared ~= expected.count then
		failed = true
		print(
			color(
				"red",
				`FAILED  {reject.path}: the header expects {expected.count} but {declared} lines are marked netweave:reject`
			)
		)
	elseif diagnostics ~= expected.count or #problems > 0 then
		failed = true
		print(color("red", `FAILED  {reject.path}: expected {expected.count} diagnostics, got {diagnostics}`))
		for _, problem in problems do
			print(color("red", `        {problem}`))
		end
		print(output)
	else
		print(
			color("green", `OK      {reject.path} rejected {diagnostics} as declared, on the declared lines`)
		)
	end
end

if failed then
	process.exit(1)
end
