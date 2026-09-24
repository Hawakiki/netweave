--!strict
-- netweave:expect 24

--[[
	Every assignment here must be rejected. `lune run analyze` fails if the count on line 1 stops
	matching, in either direction: a rejection that starts passing means a guarantee has quietly
	stopped being enforced, which is worse than a build break because nothing announces it.

	`tests/types_ok.luau` is the positive half. Neither is useful without the other — a type
	system that accepts everything passes every positive test.
]]

local t = require("../src/types")

type Type<T> = t.Type<T>

local entity = t.struct({
	id = t.u8,
	name = t.string,
})

--[[ 1. A struct field's type is not interchangeable with another. ]]
local _wrongField: Type<{ id: string, name: string }> = entity -- netweave:reject 'Type<{ id: string, name: string }>'

--[[ 2. A field cannot be dropped from the payload. ]]
local _missingField: Type<{ id: number }> = entity -- netweave:reject 'Type<{ id: number }>'

--[[ 3. A field cannot be invented. ]]
local _extraField: Type<{ id: number, name: string, health: number }> = entity -- netweave:reject 'Type<{ health: number, id: number, name: string }>'

--[[ 4. An array's element type is checked. ]]
local _wrongElement: Type<{ string }> = t.array(t.u8) -- netweave:reject 'Type<{string}>'

--[[ 5. An optional is not the same type as its inner. ]]
local _optionalDropped: Type<number> = t.optional(t.u16) -- netweave:reject 'Type<number>'

--[[ 6. An enum only admits the variants that were declared. ]]
local weapon = t.enum({ primary = true, secondary = true })
local _undeclaredVariant: Type<"primary" | "grenade"> = weapon -- netweave:reject 'Type<"grenade" | "primary">'

--[[ 7. Nesting is checked all the way down. ]]
local nested = t.struct({ entities = t.array(entity, 4) })
local _wrongNested: Type<{ entities: { { id: string, name: string } } }> = nested -- netweave:reject 'Type<{ entities: {{ id: string, name: string }} }>'

--[[ 8. A struct field has to be a netweave type at all. ]]
local _notAType = t.struct({ id = 5 }) -- netweave:reject a struct field is not a netweave type

--[[
	9 and 10. **`PayloadOf` has to reduce**, and only a rejection can say whether it does.

	It is the one `export type function` in `src/types/init.luau` that the module never referenced,
	and per `spike/declare/README.md` Q5 that means it silently became an error type for anyone
	requiring the module. `tests/types_ok.luau` writes the alias and cannot see the difference: an
	error type accepts everything, so the positive half passes either way. What changes is *here* —
	when the reduction is gone these two stop erroring and the count drops to 8.

	9 is a payload that does not match the schema. 10 is the message the docstring promises for
	something that is not a netweave type at all. 11 is the one below, and it is written beside its
	own case because it belongs to `t.union` rather than to `PayloadOf`.
]]
--[[ Underscored because `typeof` in a type position is a use selene does not scan, and a warning
     there fails `selene src tests`. It is declared for the analyzer, which is what the prefix means
     everywhere else in this file. ]]
local _shot = t.struct({ seq = t.u16 })

local _mistypedPayload: t.PayloadOf<typeof(_shot)> = { seq = "not a number" } -- netweave:reject but got '"not a number"'
type _notASchema = t.PayloadOf<number> -- netweave:reject PayloadOf takes a netweave type

--[[
	11. **A union branch's value has to match its tag.** The pattern this replaces — one optional
	field per case — cannot say that: `{ move = { x = 1 }, attack = { target = 2 } }` is a legal
	value of it, and so is `{}`. Here the tag selects the component and the value has to be that
	component's.
]]
local _action = t.union({ move = t.struct({ x = t.u8 }), wait = t.u8 })
local _crossed: t.PayloadOf<typeof(_action)> = { tag = "wait", value = { x = 1 } } -- netweave:reject but got '"move" | "wait"'

--[[ 12. A `charset` is a string. Annotated for the same reason `types_ok` annotates its options:
     an unannotated literal is any table, and a wrong field in one is not a diagnostic. ]]
local _badSet: t.TextOptions = { charset = 5 } -- netweave:reject Expected this to be 'string?', but got 'number'

--[[ 13. A literal is a string, a boolean or a number; a table is refused at the call. ]]
local _tableLiteral = t.literal({}) -- netweave:reject is not a subtype of

--[[ 14. A literal carries its singleton, so another singleton is not the same type. ]]
local _otherVersion: Type<"v4"> = t.literal("v3") -- netweave:reject Type<"v4">

--[[ 15. A set's entries are `true`, not `boolean`. ]]
local _looseSet: Type<{ [string]: boolean }> = t.set(t.string(1, 8)) -- netweave:reject Type<{ [string]: boolean }>

--[[ 16. A default has to be a value of the inner type. ]]
local _wrongDefault = t.optional(t.u8, "fast") -- netweave:reject default of the wrong kind

--[[ 17. And a table field takes no default at all: a table default would be a fresh table on every
     read and no two of them equal. ]]
local _tableDefault = t.optional(t.struct({ x = t.u8 }), 5) -- netweave:reject takes a default only for

--[[
	18-24. **A constructor's arguments are checked by type, not only by count** (`PLAN-M5` D-1).

	`Ranged<T>`, `Text`, `Componented<T>` and `Classed` were `typeof(setmetatable(…))` aliases,
	which enforce how many arguments a call passes and nothing about what they are: `t.u8(0, "b")`
	was accepted and declared a storage nobody asked for, and `t.vector3(t.boolean)` produced no
	diagnostic at all (M4-1). They are intersections now — `Type<T> & ((…) -> Type<T>)` — which
	checks both halves and is still usable bare, the bare spellings being in `types_ok`.
]]
local _wrongBound = t.u8(0, "b") -- netweave:reject Expected this to be 'number', but got 'string'
local _wrongLow = t.u8("a", 3) -- netweave:reject Expected this to be 'number', but got 'string'
local _wrongLength = t.buffer(0, "x") -- netweave:reject Expected this to be 'number', but got 'string'
local _wrongOption = t.string(0, 5, { utf8 = 1 }) -- netweave:reject Expected this to be 'boolean?', but got 'number'
local _wrongComponent = t.vector3(t.boolean) -- netweave:reject 'Type<boolean>'
local _wrongPose = t.cframe(t.boolean) -- netweave:reject 'Type<boolean>'
local _wrongClass = t.instance(5) -- netweave:reject Expected this to be 'string', but got 'number'

return nil
