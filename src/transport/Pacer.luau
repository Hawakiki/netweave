--!strict
--!optimize 2

--[=[
	@class Pacer

	A client's `intent` sends, held to the channel's declared rate.

	An intent is continuous input — aim, movement, a held button — and the class already says stale
	input has no value: the server delivers at most one value per player per tick and coalesces the
	rest. What it could not do was stop the client *sending* the rest. A `send` in every
	`RenderStepped` against `rate = 30` was forty refusals a second at stage `budget`, reported on the
	server, invisible on the client, and every one of them wasted bytes and read as an attack.

	So the client view holds the newest value per intent channel and pushes it at the declared rate,
	through the same token bucket `Budget` runs on the server, keyed by channel rather than by sender.
	A held value is superseded, never dropped and never reported; `nw.diagnostics()` counts what was
	held per channel so a game that over-sends can see it without a refusal (`PLAN-M5` D-6).

	Internal. `Driver` builds one for the client and asks it once a frame, before the flush.
]=]

--[[
	Not for `signal` or `command`, where every packet is a packet and a held one would be a lost
	one. The server's budget stays the enforcement; this is the courtesy that keeps honest traffic
	quiet on it, and a client that bypasses the view still meets the server's.
]]

local Budget = require("./Budget")
local Observer = require("../api/Observer")

local Pacer = {}

--[=[
	@interface Pacer
	@within Pacer
	.send (channel: any, value: any) -> boolean -- pushed now (true), or held for the next tick that has a token (false)
	.tick () -> () -- push every held value whose channel has a token again
	.held (channel: any) -> any? -- what is waiting on a channel, for tests
]=]
export type Pacer = {
	send: (channel: any, value: any) -> boolean,
	tick: () -> (),
	held: (channel: any) -> any?,
}

--[[ `Budget` is keyed by sender, and the client has one peer, so one sentinel is every channel's
     sender here. A table rather than `nil`, because `admit` treats a nil sender as "no budget". ]]
local SELF = table.freeze({})

--[=[
	@within Pacer
	@function new
	@param push (channel: any, value: any) -> () -- what a send that is admitted does
	@param clock (() -> number)? -- injectable for tests; `os.clock` otherwise
	@return Pacer
]=]
function Pacer.new(push: (channel: any, value: any) -> (), clock: (() -> number)?): Pacer
	local budget = Budget.new(clock)

	--[[ The newest value per channel that is waiting for a token, and the channels waiting, as an
	     array so a tick walks only those and a channel that never over-sends costs nothing here. ]]
	local held: { [any]: any } = {}
	local waiting: { any } = {}

	local function release(channel: any)
		held[channel] = nil

		local count = #waiting

		for index = 1, count do
			if waiting[index] == channel then
				waiting[index] = waiting[count]
				waiting[count] = nil
				return
			end
		end
	end

	return {
		send = function(channel: any, value: any): boolean
			if budget.admit(channel, SELF, 0) == nil then
				--[[ Admitted, so this is the newest and anything held is older than it. ]]
				if held[channel] ~= nil then
					release(channel)
				end

				push(channel, value)
				return true
			end

			if held[channel] == nil then
				table.insert(waiting, channel)
			end

			held[channel] = value
			Observer.pace(channel.qualified)
			return false
		end,

		tick = function()
			--[[ Backwards, because a channel that goes out is swap-removed from the end. ]]
			for index = #waiting, 1, -1 do
				local channel = waiting[index]

				if budget.admit(channel, SELF, 0) == nil then
					local value = held[channel]
					release(channel)
					push(channel, value)
				end
			end
		end,

		held = function(channel: any): any?
			return held[channel]
		end,
	}
end

return Pacer
