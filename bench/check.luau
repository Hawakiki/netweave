--!strict
--!optimize 2

--[[
	Compiles every Luau file under `bench/` and reports syntax errors.

	Run from the repository root:
		lune run bench/check

	This is the cheap half of "the library actually loads". Two of the five libraries surveyed
	ship a default branch that fails at this level (RESEARCH §3.6-B8, §3.7-J), so it runs on
	our own tree too, not only on vendored code.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

--[[ ~~`bench/src`, `bench/vendor`, `bench/schemas`.~~ **The whole directory**, as the line above
     always claimed. The three named subdirectories left every file that sits directly in `bench/`
     unchecked — `envelope`, `profile`, `report`, this file, and `tick.luau`, which was written for
     M4 phase 8 and reported as compiling by a check that had never opened it. ]]
local ROOTS = { "bench" }

local function color(name: stdio.Color, text: string): string
	return `{stdio.color(name)}{text}{stdio.color("reset")}`
end

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

for _, root in ROOTS do
	if fs.isDir(root) then
		walk(root)
	end
end

if failed > 0 then
	print(`{color("red", "FAILED")} {failed} of {checked} files did not compile`)
	process.exit(1)
end

print(`{color("green", "OK")} {checked} files compile`)
