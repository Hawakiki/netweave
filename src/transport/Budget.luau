--!strict
--!optimize 2

--[=[
	@class Budget

	Guarantee G2 at runtime. Every inbound channel declares a rate, and this is what enforces it.

	Internal.
]=]

--[[
	Written against Warp, which is the only surveyed library that attempts byte accounting and gets
	all three parts wrong (`Server/init.luau:196-200`, `RESEARCH §3.7-K`). Each failure is a
	requirement here, stated in reverse.

	**Real bytes.** Warp charges `math.max(buffer.len(b), 800)`, so a one-byte packet costs 800 and
	the whole thing is a crude packet counter wearing a byte counter's name. What is charged here is
	what arrived.

	**A reset that cannot fail to run.** Warp resets its counter inside a send loop that begins with
	`if #content == 0 then continue`, so a player the server has nothing to say to is *never* reset
	— they send ten packets and are blackholed for the rest of the session, silently. The window
	here is reset lazily, on the same call that charges it: there is no separate reset path, so
	there is nothing that can fail to run.

	**It runs where it is tested.** Warp wraps the check in `if not RunService:IsStudio()`, so no
	test can ever catch it. There is no such branch below, and `tests/budget_runtime.luau` is the
	proof rather than the promise.
]]

local Budget = {}

--[[
	One second. `rate` is declared in packets per second (`DESIGN-API.md` §3), so the window is the
	unit the declaration is written in — a shorter one would refuse bursts the declaration allows,
	and a longer one would let a burst through that the declaration does not.
]]
local WINDOW = 1

type Record = {
	opened: number,
	packets: number,
	bytes: number,
	refused: number,
}

export type Budget = {
	admit: (channel: any, sender: any?, bytes: number) -> string?,
	forget: (sender: any) -> (),
	usage: (sender: any, channel: any) -> (number, number, number),
}

--[=[
	@within Budget
	@function new
	@param clock (() -> number)? -- defaults to `os.clock`
	@return Budget

	The clock is injectable because a window is a second long, and a test that has to wait one is a
	test nobody runs. `tests/budget_runtime.luau` advances it by hand.
]=]
function Budget.new(clock: (() -> number)?): Budget
	local now = clock or os.clock

	--[[
		Per sender, per channel. The records are kept and refilled rather than rebuilt, so a
		steady-state server allocates nothing here: the table for a player is made once when they
		first send, and the record for a channel once when they first use it.
	]]
	local perSender: { [any]: { [any]: Record } } = {}

	return {
		--[[
			Runs **before** the payload is decoded, which is the security property rather than an
			ordering detail. Refusing costs a lookup, a clock read and two comparisons; accepting
			costs all of that plus a full deserialisation. Denial staying cheaper than acceptance is
			what stops a flood being amplified into work (`PLAN-M2` R-2).
		]]
		admit = function(channel: any, sender: any?, bytes: number): string?
			local rate = channel.rate

			if not rate then
				--[[ Outbound classes have no budget. ]]
				return nil
			end

			if sender == nil then
				--[[
					No sender means the client side, whose peer is the server — and a server
					rate-limiting itself would be a check that means nothing.

					It is also a guard rather than only a shortcut. A crafted id can name a channel
					that *does* declare a rate, and the table below is keyed by sender: `perSender[nil]`
					is an error, thrown on the receive path, which is the one place nothing may throw
					(`DESIGN-API.md` G4). A peer could have caused it.
				]]
				return nil
			end

			local byChannel = perSender[sender]

			if not byChannel then
				byChannel = {}
				perSender[sender] = byChannel
			end

			local record = byChannel[channel]
			local at = now()

			if not record then
				byChannel[channel] = {
					opened = at,
					packets = 1,
					bytes = bytes,
					refused = 0,
				}

				return nil
			end

			--[[
				The lazy reset. It happens here, on the charge, and nowhere else — so there is no
				path that can be skipped and leave a player charged forever. That is Warp's bug
				(`RESEARCH §3.7-K`) made unreachable rather than merely fixed.

				A clock that went backwards also reopens the window. `os.clock` is monotonic so this
				cannot happen with the default, but an injected one could — and the failure it would
				cause is Warp's exact failure by another route: a window that never closes and a
				player refused for the rest of the session.
			]]
			if at - record.opened >= WINDOW or at < record.opened then
				record.opened = at
				record.packets = 0
				record.bytes = 0
				record.refused = 0
			end

			if record.packets >= rate then
				record.refused += 1

				--[[ The bytes are charged whether or not the packet is admitted. A refused packet
				     still crossed the wire, and a byte figure that only counted what was accepted
				     would understate exactly the traffic worth looking at. ]]
				record.bytes += bytes

				return `over {rate} packets per second`
			end

			record.packets += 1
			record.bytes += bytes

			return nil
		end,

		--[[ A player who left. Their records are the only thing here that grows with the player
		     count, so dropping them is what keeps a long-running server flat. ]]
		forget = function(sender: any)
			perSender[sender] = nil
		end,

		--[=[
			What this sender has spent on this channel in the current window: packets, bytes, and
			how many were refused.

			Exposed because a budget nobody can read is not a security feature. `RESEARCH §3-G6`
			records that no surveyed library reports this, and `§3.7-K` records what the absence
			costs — a player can be silently blackholed and nothing anywhere says so.
		]=]
		usage = function(sender: any, channel: any): (number, number, number)
			local byChannel = perSender[sender]
			local record = byChannel and byChannel[channel]

			if not record then
				return 0, 0, 0
			end

			--[[ Reported against the same window the charge would use, so a caller reading between
			     bursts sees zero rather than the last window's total. ]]
			local at = now()

			if at - record.opened >= WINDOW or at < record.opened then
				return 0, 0, 0
			end

			return record.packets, record.bytes, record.refused
		end,
	}
end

return Budget
