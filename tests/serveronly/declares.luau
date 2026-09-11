--!strict

--[[
	A namespace declared from the wrong place, on purpose.

	`test.project.json` and `bench/default.project.json` map this directory a second time, under
	`ServerScriptService`, so that `tests/roblox_runtime.luau` can require it from there and watch
	`nw.namespace` refuse the declaration by its source: on Roblox `debug.info(2, "s")` inside
	`nw.namespace` is this module's full name, `ServerScriptService.netweaveServerOnly.declares`, and
	that is the one prefix the client can never require (`PLAN-M5` D-7, `docs/tutorial/mistakes.md` 1).

	Handed `nw` and `t` rather than requiring them, because from `ServerScriptService` there is no
	relative path to `src/`, and a Roblox-instance require would be a line the analyzer cannot follow.
	The copy under `ReplicatedStorage.netweave.tests` is never required; the runner lists the folder
	under "not run".
]]

return function(nw: any, t: any)
	return nw.namespace("serverOnly", {
		kick = nw.signal({ data = t.u8, rate = 1 }),
	})
end
