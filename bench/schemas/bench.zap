-- netweave benchmark schema, Zap 0.6.29 dialect.
-- Regenerate with: lune run bench/schemas/generate.luau
-- Zap packs booleans, optional presence flags and small enum tags automatically
-- (RESEARCH §3.9-V2), so the idiomatic and naive variants are written identically here.
-- Both are kept so the cell-by-cell comparison against Blink stays aligned.

opt server_output = "../vendor/zap/Server.luau"
opt client_output = "../vendor/zap/Client.luau"
opt casing = "PascalCase"
opt write_checks = true

type Entity = struct {
	id: u8,
	x: u8,
	y: u8,
	z: u8,
	orientation: u8,
	animation: u8,
}

type FlagIdiomatic = struct {
	f1: boolean,
	f2: boolean,
	f3: boolean,
	f4: boolean,
	f5: boolean,
	f6: boolean,
	f7: boolean,
	f8: boolean,
	f9: boolean,
	f10: boolean,
	f11: boolean,
	f12: boolean,
	weapon: enum { primary, secondary, melee, grenade },
	team: enum { red, blue },
	targetId: u16?,
	combo: u8?,
}

type FlagNaive = FlagIdiomatic

event ArrayHeavyUp = {
	from: Client,
	type: Reliable,
	call: SingleSync,
	data: Entity[100],
}

event ArrayHeavyDown = {
	from: Server,
	type: Reliable,
	call: SingleSync,
	data: Entity[100],
}

event FlagIdiomaticUp = {
	from: Client,
	type: Reliable,
	call: SingleSync,
	data: FlagIdiomatic,
}

event FlagIdiomaticDown = {
	from: Server,
	type: Reliable,
	call: SingleSync,
	data: FlagIdiomatic,
}

event FlagNaiveUp = {
	from: Client,
	type: Reliable,
	call: SingleSync,
	data: FlagNaive,
}

event FlagNaiveDown = {
	from: Server,
	type: Reliable,
	call: SingleSync,
	data: FlagNaive,
}
