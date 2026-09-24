--!strict

--[[
	The smallest-three quaternion packing, without Roblox.

		lune run spike/additions/f_quaternion

	`t.cframe(component)` writes its rotation as a unit quaternion with the largest component
	dropped: three `i16` scaled to 1/sqrt(2), and a two-bit index saying which one was left out.
	`CFrame` does not exist under lune, so `src/codec/Serdes.luau`'s own closures cannot be run
	here — but the arithmetic can, and a sign or an index bug is arithmetic. This mirrors the two
	bodies line for line and reports the worst error over random rotations.

	The axis and angle are random, so this is one number per run and the spread is what to quote.
	Five runs of 200,000 rotations on `3238687` + the compact cframe:

		max component error 2.57e-05 .. 2.68e-05   (one step is 2.16e-05)
		max angle error     6.12e-05 .. 6.40e-05 rad
		max rest            0.7415 .. 0.7467       (the bound is 0.75)
		index histogram     0 ~28k  1 ~28k  2 ~28k  3 ~115k

	Two things came out of running it, and neither was reasoned about first:

	  * **The honest sum is bounded by 3/4, not by 1.** The dropped component is the largest, so it
	    is at least 1/2 and the three kept ones carry at most 3/4. The reader was written to refuse
	    above 1, which would have accepted a packing whose "largest" was not the largest; it refuses
	    above 3/4 now.
	  * **The dropped component's error exceeds one step**, because it is reconstructed from the
	    other three and inherits all of their rounding. 2.68e-05 against a step of 2.16e-05.

	The index histogram is not uniform and should not be: `w` is the largest whenever the angle is
	under 2*pi/3, which is most of a uniform angle range.
]]

local SCALE = 32767 * math.sqrt(2)
local MAX_REST = 0.75 + 3 * (1 / SCALE)

local function pack(qx: number, qy: number, qz: number, qw: number): (number, number, number, number)
	local ax, ay, az, aw = math.abs(qx), math.abs(qy), math.abs(qz), math.abs(qw)
	local largest = 0
	local magnitude = ax

	if ay > magnitude then
		largest, magnitude = 1, ay
	end

	if az > magnitude then
		largest, magnitude = 2, az
	end

	if aw > magnitude then
		largest = 3
	end

	local sign = if (largest == 0 and qx < 0)
			or (largest == 1 and qy < 0)
			or (largest == 2 and qz < 0)
			or (largest == 3 and qw < 0)
		then -1
		else 1

	local kept: { number } = {}

	if largest ~= 0 then
		table.insert(kept, math.clamp(math.round(qx * sign * SCALE), -32767, 32767))
	end

	if largest ~= 1 then
		table.insert(kept, math.clamp(math.round(qy * sign * SCALE), -32767, 32767))
	end

	if largest ~= 2 then
		table.insert(kept, math.clamp(math.round(qz * sign * SCALE), -32767, 32767))
	end

	if largest ~= 3 then
		table.insert(kept, math.clamp(math.round(qw * sign * SCALE), -32767, 32767))
	end

	return largest, kept[1], kept[2], kept[3]
end

local function unpack(
	largest: number,
	first: number,
	second: number,
	third: number
): (number, number, number, number, number)
	local a, b, c = first / SCALE, second / SCALE, third / SCALE
	local rest = a * a + b * b + c * c
	local d = math.sqrt(math.max(0, 1 - rest))

	if largest == 0 then
		return d, a, b, c, rest
	elseif largest == 1 then
		return a, d, b, c, rest
	elseif largest == 2 then
		return a, b, d, c, rest
	end

	return a, b, c, d, rest
end

local REPEATS = 200000
local used = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }
local worstComponent = 0
local worstAngle = 0
local worstRest = 0

for _ = 1, REPEATS do
	--[[ A random axis and a random angle, which is what a game sends; the components come out
	     covering every case including the near-degenerate ones. `Vector3` is Roblox's too, so the
	     axis is normalised by hand. ]]
	local ux, uy, uz = math.random() * 2 - 1, math.random() * 2 - 1, math.random() * 2 - 1
	local length = math.sqrt(ux * ux + uy * uy + uz * uz)

	if length < 1e-6 then
		continue
	end

	ux, uy, uz = ux / length, uy / length, uz / length
	local angle = (math.random() * 2 - 1) * math.pi
	local half = angle / 2
	local s = math.sin(half)
	local qx, qy, qz, qw = ux * s, uy * s, uz * s, math.cos(half)

	local largest, first, second, third = pack(qx, qy, qz, qw)
	used[largest] += 1

	local rx, ry, rz, rw, rest = unpack(largest, first, second, third)
	worstRest = math.max(worstRest, rest)

	--[[ q and -q are the same rotation, and the packing normalises the dropped component to
	     positive, so the comparison is against whichever sign the reconstruction chose. ]]
	local dot = qx * rx + qy * ry + qz * rz + qw * rw

	if dot < 0 then
		rx, ry, rz, rw = -rx, -ry, -rz, -rw
		dot = -dot
	end

	worstComponent =
		math.max(worstComponent, math.abs(qx - rx), math.abs(qy - ry), math.abs(qz - rz), math.abs(qw - rw))

	worstAngle = math.max(worstAngle, 2 * math.acos(math.min(1, dot)))
end

print(
	string.format(
		"        max component error %.2e, max angle error %.2e rad, max rest %.4f",
		worstComponent,
		worstAngle,
		worstRest
	)
)
print(`        every index used: 0 {used[0]}  1 {used[1]}  2 {used[2]}  3 {used[3]}`)

--[[ A kept component is within half a step; the dropped one is reconstructed from the other
     three, so it inherits their error and is bounded by the whole of it rather than by one step. ]]
assert(
	worstComponent < 4 * (1 / SCALE),
	"a component should be within the rounding the reconstruction inherits"
)
assert(worstRest <= MAX_REST, "an honest rotation must pass the reader's rest check")
assert(worstAngle < 1e-4, "a rotation should come back within 1e-4 radians")

for index = 0, 3 do
	assert(used[index] > 0, `index {index} was never the largest component`)
end

print("OK      quaternion")

return true
