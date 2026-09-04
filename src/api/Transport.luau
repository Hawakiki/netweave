--!strict
--!optimize 2

--[=[
	@class Transport

	The seam between the declaration surface and the thing that actually moves bytes.

	M1 defines what a channel *is*: its schema, its budget, its audience, its policy, its wire id.
	M2 defines what happens when you send on one — batching, flush scheduling, budget enforcement,
	audience evaluation, intent coalescing. This module is where the second half attaches.
]=]

--[[
	Written as a hole rather than as a stub that pretends to work.

	A `send` that silently did nothing would make the M1 test suite pass and every M1 integration
	fail in a way that looks like packet loss. Raising names the milestone instead, so the failure
	says what is missing rather than leaving it to be inferred from a game that does not respond.

	This is a programmer error — the game called `send` in a build with no transport — so raising
	is correct. It is not wire data, and G4 is not in play.
]]

local Transport = {}

--[=[
	@interface Driver
	@within Transport
	.send (channel: any, value: any) -> ()
	.publish (channel: any, subject: any, value: any) -> ()
	.broadcast (channel: any, value: any) -> ()
	.invoke (channel: any, args: any) -> (any?, string?)
	.dispatch (channel: any, handler: any) -> () -- called when a handler is attached

	What M2 installs. Every method receives the channel record, so the driver reads the rate,
	audience, policy and codec off the declaration rather than being told them again.
]=]
export type Driver = {
	send: (channel: any, value: any) -> (),
	publish: (channel: any, subject: any, value: any) -> (),
	broadcast: (channel: any, value: any) -> (),
	invoke: (channel: any, args: any) -> (any?, string?),
	dispatch: (channel: any, handler: any) -> (),
}

local driver: Driver? = nil

--[=[
	@within Transport
	@function install
	@param installed Driver
	@private

	Attaches the transport. Called once, by M2.
]=]
function Transport.install(installed: Driver)
	if driver ~= nil then
		error("a transport is already installed", 2)
	end

	driver = installed
end

--[=[
	@within Transport
	@function installed
	@return boolean

	Whether anything can actually be sent yet.
]=]
function Transport.installed(): boolean
	return driver ~= nil
end

--[=[
	@within Transport
	@function driver
	@param operation string -- what was attempted, for the message
	@return Driver
	@private
]=]
function Transport.driver(operation: string): Driver
	local installed = driver

	if not installed then
		error(
			`{operation} needs a transport, and none is installed. The declaration surface is `
				.. `netweave M1; batching, budgets and audience evaluation are M2. Until then a `
				.. `channel can be declared, its schema exercised and its handlers attached, but `
				.. `nothing crosses the wire.`,
			3
		)
	end

	return installed
end

--[=[
	@within Transport
	@function uninstall
	@private

	Detaches the transport. Exists so a test can install a fake one and put things back.
]=]
function Transport.uninstall()
	driver = nil
end

return Transport
