--!strict
--!optimize 2

--[[
	Sampling and summary statistics for the benchmark.

	The one non-obvious rule here is bandwidth normalization. `Stats.DataSendKbps` is measured
	per wall-clock second, so a library that drops the client to 20 FPS gets to send a third as
	many packets and therefore looks bandwidth-efficient. Scaling by `TARGET_FRAMERATE / frames`
	converts every sample to "what this would cost at a locked 60 FPS" and removes that
	inversion. Adopted from Blink's harness (RESEARCH §3.7-L).
]]

local Metrics = {}

local TARGET_FRAMERATE = 60

Metrics.TARGET_FRAMERATE = TARGET_FRAMERATE
Metrics.PERCENTILES = { 0, 50, 90, 95, 100 }

export type Summary = {
	p0: number,
	p50: number,
	p90: number,
	p95: number,
	p100: number,
}

--[[
	Nearest-rank percentile over an already-sorted ascending array. Deliberately not
	interpolating: with ten one-second samples, interpolation invents precision the
	measurement does not have.
]]
function Metrics.percentile(sorted: { number }, percent: number): number
	local count = #sorted
	if count == 0 then
		return 0
	end

	local index = math.floor(count * (percent / 100))
	return sorted[math.clamp(index, 1, count)]
end

function Metrics.summarize(samples: { number }): Summary
	local sorted = table.clone(samples)
	table.sort(sorted)

	return {
		p0 = Metrics.percentile(sorted, 0),
		p50 = Metrics.percentile(sorted, 50),
		p90 = Metrics.percentile(sorted, 90),
		p95 = Metrics.percentile(sorted, 95),
		p100 = Metrics.percentile(sorted, 100),
	}
end

--[[
	`kbps` as reported over a window in which `frames` frames elapsed, rescaled to
	`TARGET_FRAMERATE`. See the module comment for why this is mandatory.
]]
function Metrics.normalizeBandwidth(kbps: number, frames: number): number
	if frames <= 0 then
		return 0
	end

	return kbps * (TARGET_FRAMERATE / frames)
end

--[[
	Bytes on the wire per logical packet.

	~~Derived from normalized bandwidth and the fire rate.~~ **Replaced after the first smoke run.**
	That derivation depended on `Stats`, which under-reported buffer payloads in Studio by roughly
	280x while measuring raw table traffic correctly. `wireBytes` now comes from `WireTap`, which
	sums `buffer.len` straight off each library's own remote, and `packets` is the receiver's own
	logical count over the same window. No `Stats`, no framerate assumption.
]]
function Metrics.bytesPerPacket(wireBytes: number, packets: number): number
	if packets <= 0 then
		return 0
	end

	return wireBytes / packets
end

return Metrics
