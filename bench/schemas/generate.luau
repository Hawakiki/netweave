--!strict
--!optimize 2

--[[
	Regenerates every vendored codegen output from the schemas in this directory.

	Run from the repository root:
		lune run bench/schemas/generate

	Deliberately does no network access. Blink is compiled by requiring its Luau compiler
	straight out of `_refsrc/blink`; Zap is compiled by the pinned binary kept at
	`_refsrc/_generated/zap/bin/zap.exe`. PLAN-M0 D-1: Blink's own `download.luau` needs
	7-Zip and a GitHub token, so we vendor deterministically instead.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

-- Blink's generator stamps these into the header of every file it emits.
_G.RELEASE = true
_G.VERSION = "0.18.8"

local BlinkCompile = require("../../_refsrc/blink/src/CLI/Utility/Compile")

local ZAP_BINARY = "_refsrc/_generated/zap/bin/zap.exe"
local BLINK_SCHEMA = "bench/schemas/bench.blink"
local ZAP_SCHEMA = "bench/schemas/bench.zap"
local SCHEMA_DIR = "bench/schemas"
local VENDOR_DIR = "bench/vendor"

local function color(name: stdio.Color, text: string): string
	return `{stdio.color(name)}{text}{stdio.color("reset")}`
end

local function ensureDir(path: string)
	if not fs.isDir(path) then
		fs.writeDir(path)
	end
end

--[[
	Every vendored and generated module must parse. This is the same check that caught Warp
	shipping a syntax error on master for three weeks (RESEARCH §3.7-J); a benchmark that
	silently drops a mode because its module failed to load is worse than no benchmark.
]]
local function verifyCompiles(root: string): (number, number)
	local checked, failed = 0, 0

	local function walk(dir: string)
		for _, entry in fs.readDir(dir) do
			local path = `{dir}/{entry}`
			if fs.isDir(path) then
				walk(path)
			elseif string.match(path, "%.luau?$") then
				checked += 1
				local ok, err = pcall(luau.compile, fs.readFile(path))
				if not ok then
					failed += 1
					print(`  {color("red", "SYNTAX")} {path}`)
					print(`         {tostring(err)}`)
				end
			end
		end
	end

	walk(root)
	return checked, failed
end

if not fs.isDir(SCHEMA_DIR) then
	error(`"{SCHEMA_DIR}" not found. Run this script from the repository root.`)
end

ensureDir(VENDOR_DIR)
ensureDir(`{VENDOR_DIR}/blink`)
ensureDir(`{VENDOR_DIR}/zap`)

print(color("cyan", "Generating Blink output..."))
BlinkCompile.Compile(BLINK_SCHEMA, {
	Debug = false,
	Silent = true,
	Compact = false,
	YesToEverything = true,
	OutputAbstractSyntaxTree = false,
})

print(color("cyan", "Generating Zap output..."))
-- Zap resolves its output paths relative to the schema file, so it can be invoked from
-- the repository root without changing directory.
local zap = process.exec(ZAP_BINARY, { ZAP_SCHEMA }, { stdio = "inherit" })

if not zap.ok then
	error("Zap generation failed")
end

print(color("cyan", "Verifying every vendored module compiles..."))
local checked, failed = verifyCompiles(VENDOR_DIR)

if failed > 0 then
	print(`{color("red", "FAILED")} {failed} of {checked} modules did not compile`)
	process.exit(1)
end

print(`{color("green", "OK")} {checked} modules compile`)
