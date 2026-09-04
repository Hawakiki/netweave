--!strict

--[[
	Runs every test module in Studio and reports which ones failed.

		rojo build test.project.json -o netweave-test.rbxl

	Then open it and press play; the result is in Output.

	It runs from `ReplicatedStorage` alongside the tests, which only works because
	`test.project.json` sets `emitLegacyScripts: false`: Rojo then emits a `.server.luau` as a
	`Script` with `RunContext = Server`, and such a script runs wherever it sits in the DataModel.
	A legacy `Script` there would never execute.

	Most tests also run under lune, which is faster and needs no Studio. This runner exists for
	the ones that cannot: `Vector3`, `CFrame`, `Color3` and `Instance` only exist here, and the
	codec has to round-trip all four.

	Only `*_runtime` modules are run. `*_ok` and `*_reject` are analyser fixtures: a rejection file
	is full of deliberate type errors, and requiring it here would report a type error as a test
	failure. `lune run analyze` is what checks those.

	A test module asserts at require time and throws on failure, so requiring it is running it, and
	it returns `true` so Roblox accepts it as a module.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local tests = ReplicatedStorage:WaitForChild("netweave"):WaitForChild("tests")

local passed = 0
local failed = 0

local function names(modules: { ModuleScript }): { string }
	--[[ `table.create` yields `{unknown}` and Luau arrays are invariant, so the cast is the only
	     way to pre-size this rather than growing it element by element. ]]
	local list = (table.create(#modules) :: any) :: { string }

	for index, module in modules do
		list[index] = module.Name
	end

	return list
end

--[[ Alphabetical so a run is reproducible and diffable, not hash order. ]]
local modules: { ModuleScript } = {}
local skipped: { string } = {}

for _, child in tests:GetChildren() do
	if child:IsA("ModuleScript") and string.match(child.Name, "_runtime$") then
		table.insert(modules, child)
	else
		table.insert(skipped, `{child.Name} ({child.ClassName})`)
	end
end

table.sort(modules, function(a: ModuleScript, b: ModuleScript)
	return a.Name < b.Name
end)

--[[
	The runner says what it found before it runs anything.

	Without this a module that is simply *absent* — a stale place, a rename, a Rojo mapping that
	quietly dropped it — is indistinguishable from a clean run: the summary counts what it saw, and
	what it never saw leaves no trace. That is exactly how a missing `api_runtime` was mistaken for
	a passing suite once already.
]]
table.sort(skipped)
print(`[netweave] {#modules} runtime modules: {table.concat(names(modules), ", ")}`)

if #skipped > 0 then
	print(`[netweave] not run: {table.concat(skipped, ", ")}`)
end

if #modules == 0 then
	error("[netweave] no *_runtime modules found; is this place stale?")
end

for _, module in modules do
	local ok, err = pcall(require, module :: any)

	if ok then
		passed += 1
	else
		failed += 1
		warn(`[netweave] FAIL {module.Name}: {tostring(err)}`)
	end
end

local summary = if failed > 0 then `{failed} failed, {passed} passed` else `{passed} passed`

if failed > 0 then
	warn(`[netweave] {summary}`)
else
	print(`[netweave] {summary}`)
end

--[[
	A marker, so a place that runs this suite *and* something else can order the two.

	The benchmark place maps `tests/` in beside `src/` precisely so that one Play produces both the
	suite and the matrix. Its two drivers wait on this before loading their modes, because this file
	installs and uninstalls transports and declares and resets namespaces — global state the
	benchmark then depends on.

	Published on failure too. A benchmark blocked forever on a suite that threw would look like a
	hang rather than a failure.
]]
local marker = Instance.new("StringValue")
marker.Name = "netweaveTests"
marker.Value = summary
marker.Parent = ReplicatedStorage
