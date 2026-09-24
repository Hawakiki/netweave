--!strict

--[[
	Q6 — what passing a namespace **bare** to a `nw.Views` parameter costs.

		LSP=~/.rokit/tool-storage/johnnymorganz/luau-lsp/1.69.0/luau-lsp.exe
		FLAGS="--platform=roblox --definitions=tools/globalTypes.d.luau --flag:LuauSolverV2=true --no-strict-dm-types"
		"$LSP" analyze $FLAGS spike/declare/passed.luau    # expect 4; with the cast, 2

	Two lines here are *meant* to error: the handler at `openedMenu` annotates a `u8` field as a
	string, and the `:send` passes a string where the schema says a number. With
	`wire(passed :: nw.Views<typeof(passed.channels)>)` at the bottom those two are the whole output.

	Passed **bare** — `wire(passed)` — the count goes to four: the two above, plus two on the
	`equip` handler written far *above* the call, whose payload has become `unknown`. That is the
	hazard: a handler that was typed stops being typed because of a call written later, and the
	same shape can remove a diagnostic instead of adding one, which no rejection count can see.

	It is not a lost brand and not the `typeof(passed.channels)` self-reference. Measured while
	closing `PLAN-M5` phase 1:

	  * extracting the channel table into its own local and typing the parameter
	    `nw.Views<typeof(channels)>` — no `passed` in the parameter's type at all — changes nothing;
	  * a namespace of five channels with four handlers does not reproduce it, and this one, with
	    nine channels and a handler doing arithmetic on a payload, does;
	  * `tests/api_ok.luau` passes its namespace bare and is fine, because that namespace has one
	    channel. Nothing there should be copied into a dense file.

	So the guard is the cast at the call, which `tests/tutorial_ok.luau` carries with the same note,
	and `docs/DESIGN-API.md` §7 says so beside the other `Views` caution. This file is the
	reproduction, kept because the failure is silent in the direction that matters.
]]

local nw = require("../../src/netweave")
local t = require("../../src/types")

local allow = nw.policy(function()
	return function()
		return nw.allow()
	end
end)

local passed = nw.namespace("passed", {
	equip = nw.command({ data = t.struct({ slot = t.u8 }), rate = 5, authorize = allow }),
	loadout = nw.event({ data = t.struct({ primary = t.u16 }), audience = nw.audience.owner }),
	aim = nw.intent({ data = t.struct({ pitch = t.f32(-90, 90) }), rate = 60 }),
	openedMenu = nw.signal({ data = t.struct({ screen = t.u8(0, 8) }), rate = 2 }),
	getLoadout = nw.query({
		args = t.u8(0, 2),
		returns = t.struct({ primary = t.u16 }),
		rate = 2,
		timeout = 5,
		authorize = allow,
	}),
	playerState = nw.state({
		data = t.struct({ hp = t.u8 }),
		audience = nw.audience.nearby(120),
	}),
	roundOver = nw.event({ data = t.struct({ winner = t.u16 }), audience = nw.audience.everyone }),
	inventory = nw.replicate({
		subject = t.u16,
		data = t.struct({ gold = t.u16 }),
		audience = nw.audience.owner,
		store = nw.store.of({}),
	}),
})

passed.server.equip:listen(function(ctx, chosen)
	passed.server.loadout:publish(ctx.player, { primary = 100 + chosen.slot })
end)

passed.server.aim:listen(function(_ctx, aim)
	local _pitch: number = aim.pitch
end)

passed.server.getLoadout:handle(function(_ctx, slot)
	local _asked: number = slot
	return { primary = 1 }
end)

--[[ The two lines that must error. ]]
passed.server.openedMenu:listen(function(_ctx, opened)
	local _one: string = opened.screen
end)

passed.client.equip:send({ slot = "two" })

local function wire(namespace: nw.Views<typeof(passed.channels)>)
	namespace.server.openedMenu:listen(function(_ctx, _opened) end)
end

wire(passed)
