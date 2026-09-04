--!strict
--!optimize 2

--[[
	Type-checks the project, and checks that the code which is *supposed* to fail still does.

	Run from the repository root:
		lune run analyze

	This is not a lint pass. Half the guarantees in `docs/DESIGN-API.md` are type errors or they
	are nothing (PLAN-M1 D-7), so an analyzer run is part of the test suite: `tests/*_ok.luau`
	must produce no diagnostics, and each `tests/*_reject.luau` must produce exactly the number
	of diagnostics its header declares. A rejection file that stops erroring means a guarantee
	has silently stopped being enforced, which is worse than a build break.

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
	A rejection file declares how many diagnostics it expects, anywhere in its header:
		-- netweave:expect 3

	Deliberately not a `--!` directive: Luau lints unknown ones, so the marker would count itself.
]]
local function expectedFailures(path: string): number?
	local count = string.match(fs.readFile(path), "%-%- netweave:expect%s+(%d+)")
	return if count then tonumber(count) else nil
end

local luauLsp = findLuauLsp()
assert(fs.isFile(DEFINITIONS), `{DEFINITIONS} is missing; see tools/README.md`)

local function analyze(files: { string }): (string, number)
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

	for line in string.gmatch(output, "[^\n]+") do
		--[[ Diagnostics are `path(line,col): Kind: message`; everything else is noise. ]]
		if string.match(line, "^%S+%(%d+,%d+%):") then
			diagnostics += 1
		end
	end

	return output, diagnostics
end

local ok: { string } = {}
local rejects: { { path: string, expected: number } } = {}

for _, root in ROOTS do
	for _, path in collect(root, {}) do
		local expected = expectedFailures(path)
		if expected then
			table.insert(rejects, { path = path, expected = expected })
		else
			table.insert(ok, path)
		end
	end
end

local failed = false

if #ok > 0 then
	local output, diagnostics = analyze(ok)

	if diagnostics > 0 then
		failed = true
		print(color("red", `FAILED  {diagnostics} diagnostics across {#ok} files that must be clean`))
		print(output)
	else
		print(color("green", `OK      {#ok} files clean`))
	end
end

for _, reject in rejects do
	local output, diagnostics = analyze({ reject.path })

	if diagnostics ~= reject.expected then
		failed = true
		print(
			color("red", `FAILED  {reject.path}: expected {reject.expected} diagnostics, got {diagnostics}`)
		)
		print(output)
	else
		print(color("green", `OK      {reject.path} rejected {diagnostics} as declared`))
	end
end

if failed then
	process.exit(1)
end
