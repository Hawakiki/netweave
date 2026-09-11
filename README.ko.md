# netweave

*[English](README.md) · [튜토리얼](docs/tutorial/README.md) · [API 설계](docs/DESIGN-API.md) · [와이어 포맷](docs/WIRE-FORMAT.md) · [벤치마크](bench/RESULTS.md)*

netweave는 선언 파일이 곧 보안 리뷰가 되는 Roblox 네트워킹 라이브러리입니다. 모든 채널은 자신을
선언하는 그 줄에서 누가 보낼 수 있는지, 얼마나 자주인지, 누구에게 가는지, 그리고 핸들러가 페이로드를
보기 전에 무엇이 참이어야 하는지를 말합니다. 그 절반은 게임이 실행되기 전에 타입 체커가 강제합니다.
나머지 절반은 전선 위에서 강제됩니다. 악의적인 클라이언트는 `error()`에 닿을 수 없고, 자기 뒤에 있는
패킷들을 멈출 수 없고, 자기가 받아야 할 채널로 보낼 수 없습니다. 스키마는 런타임 Luau이고, 코드
생성도 빌드 단계도 없으며, 바이트는 코드 생성기만큼 촘촘하게 묶입니다.

```lua
local combat = nw.namespace("combat", {
	equip = nw.command({
		data = t.struct({ slot = t.u8(0, 9) }),
		rate = 5,
		authorize = nw.all(policy.alive, policy.ownsSlot({ slots = 3 })),
	}),
})
```

`authorize`를 빼면 파일이 타입 체크를 통과하지 못합니다. `rate`를 빼도 통과하지 못합니다. 대신
`signal`로 선언하면 핸들러는 `Untrusted<T>`를 받는데, `Trusted<T>`로 주석된 함수는 그 값을 받지
않습니다. 이것이 제품입니다. 이 페이지의 나머지는 그 비용과 이 라이브러리가 거부하는 것들이고,
[튜토리얼](docs/tutorial/README.md)은 같은 내용을 빈 place에서 따라 할 수 있는 아홉 단계로 나눈
것입니다.

## 누구를 위한 것인가

netweave는 `--!strict`를 쓰고 ByteNet, Blink, Zap을 써 본 사람을 위한 것입니다. 선언은 ByteNet보다
길지 않고, 그 라이브러리들이 손으로 흩어 놓게 만드는 속도 제한과 인가 검사가 리뷰어가 열어볼 수 있는
한 곳으로 모입니다. 코드 생성기가 섬기는 생태계보다 일부러 좁은 조각을 골랐습니다.

새 Luau 타입 솔버가 필요합니다. 보장의 절반이 `type function` 오류이고, 옛 솔버는 그 문법 자체를
거부합니다. 솔버 정식 릴리스 기준으로 `--!strict` 프로젝트는 기본으로 옛 솔버에 남으며, 프로젝트마다
**Workspace Properties → Scripting**에서 켭니다. 켜지 않아도 선언 표면은 동작하지만, 아래 보장 중
타입 오류로 강제되는 것들은 검사되지 않습니다. 왜 우회하지 않고 이렇게 결정했는지는
`docs/DESIGN-API.md` §0과 §7에 있습니다.

## 무엇을 보장하는가

여섯 가지이고, 각각 관습이 아니라 메커니즘이 뒤에 있습니다. 권위 있는 상태를 바꾸는 인바운드 채널은
정책이 붙기 전까지 리스너를 가질 수 없고, 모든 인바운드 채널은 속도 예산을 선언하며 "무제한"이라는
표기는 없습니다. 둘 다 빠지면 타입 오류입니다. 모든 서버→클라이언트 채널은 청중을 선언하고,
`broadcast`는 청중이 모두인 곳에만 존재하며, 이것도 타입 오류입니다. 전선에서 온 데이터는 `error()`에
닿지 않습니다. 거부는 값이며 옵저버로 전달되고, 수신 경로는 배치마다 가드 아래에서 돌아서 raise 하나가
세션이 아니라 패킷 하나를 비용으로 치릅니다. 프레이밍은 길이 접두사를 가지므로 잘못된 패킷 하나가 그
배치의 나머지를 멈출 수 없습니다. 그리고 방향은 문자열 필드가 아니라 클래스이며 두 번 검사됩니다.
분석 시점에 뷰가 한 번, 도착 시점에 한 번. 이 쪽이 보내는 채널로 도착한 패킷은 한 바이트도 디코드되기
전에 거부됩니다.

그 옆에 한계 두 가지를 적어 둡니다. 라이브러리가 없는 척하지 않기 때문입니다. 안쪽 층, 즉 프레이밍,
속도, 청중, 방향은 무조건적입니다. 채널의 클래스가 정직한지는 작성자에게 달려 있습니다. 상태를 바꾸는
패킷을 `signal`로 선언하는 것을 막는 것은 없으며, `signal`은 `authorize`를 금지하니 가장 짧게 쓰는
길입니다. `Untrusted<T>`가 그 길을 막지만 `Trusted<T>`로 주석된 함수에 대해서만 그렇습니다. 두 번째
한계는 벤치마크의 모든 숫자가 Studio loopback에서 측정되었다는 것입니다. 라이브러리 간 상대 비교에는
쓸 수 있고 그 이상은 아닙니다.

## 60줄

양쪽이 함께 require하는 파일 하나에 라이브러리 전체가 있습니다. 선언하고, 보내고, 인가하고, 거부하고,
관찰합니다. 스케치가 아닙니다. `tests/example_runtime.luau`의 본문 그대로이며 스위트에서 실행되고,
이 사본과 그 파일이 달라지면 `tools/messages.luau`가 빌드를 실패시킵니다.

<!-- example: tests/example_runtime.luau -->
```lua
--[[ One file, required by both sides. Everything a reviewer needs to know about this channel's
     security is on the line that declares it. ]]
local t = nw.types

local Equip = t.struct({ slot = t.u8(0, 9) })
type Equip = { slot: number }

local policy = {}

policy.alive = nw.policy(function()
	return function(ctx: nw.Ctx, _request: Equip)
		return ctx.humanoid ~= nil and nw.allow() or nw.deny("dead")
	end
end)

policy.ownsSlot = nw.policy(function(config)
	local slots: number = config.slots or 3

	return function(_ctx: nw.Ctx, request: Equip)
		if request.slot > slots then
			return nw.deny(`slot {request.slot} is past the {slots} this player owns`)
		end
		return nw.allow(request)
	end
end)

local combat = nw.namespace("combat", {
	equip = nw.command({
		data = Equip,
		rate = 5,
		authorize = nw.all(policy.alive, policy.ownsSlot({ slots = 3 })),
	}),

	loadout = nw.event({
		data = t.struct({ primary = t.u16 }),
		audience = nw.audience.owner,
	}),
})

--[[ The server. `chosen` is `Trusted<{ slot: number }>` — it decoded, it was inside the declared
     rate, and the policy allowed it. Nothing else in the process can produce that type by
     accident, which is what makes the annotation on an authoritative function worth writing. ]]
--[[ Nothing is annotated: `chosen` is `Trusted<Equip>` and `ctx.player` is the sender, both from
     the declaration (`DESIGN-API.md` §8 on why the player is `unknown`). ]]
combat.server.equip:listen(function(ctx, chosen)
	combat.server.loadout:publish(ctx.player, { primary = 100 + chosen.slot })
end)

combat.client.loadout:listen(function(loadout)
	equipped[#equipped + 1] = loadout.primary
end)

--[[ Every refusal, whether or not anything is listening. Attaching this replaces the default
     console output; detaching it does not make the refusals stop. ]]
nw.observe(function(rejection)
	refusals[#refusals + 1] = `{rejection.channel} at {rejection.stage}: {rejection.reason}`
end)
```

여기에 없는 것이 요점만큼 중요합니다. 미들웨어 체인이 없고, 호출마다 넘기는 옵션 테이블이 없고, 보내는
자리에서 검증기를 넘길 곳이 없으며, 다른 파일이 `equip`이 받는 것을 바꿀 방법이 없습니다. 선언이 보안
모델의 전부입니다.

일곱 번째 클래스는 상태를 나르는 대신 복제합니다. 게임은 자기 테이블을 쓰고 netweave를 다시 부르지
않습니다. 프레임마다 netweave가 스토어를 읽고 각 클라이언트가 봐야 할 것과 갖고 있는 것의 차이를
보냅니다. 들어오는 클라이언트는 값 전체를, 열두 필드 중 하나가 움직인 프레임은 3바이트를, 청중이
바뀐 클라이언트는 정확히 그 차이를 받습니다. 같은 파일이 이어집니다.

<!-- example: tests/example_runtime.luau replication -->
```lua
--[[ The server never calls this channel. `store` is the only way in, so there is no `publish` on
     the server view to be called by mistake — the absence is the guarantee. ]]
local world: { [number]: { hp: number, gold: number } } = {}

local vault = nw.namespace("vault", {
	inventory = nw.replicate({
		subject = t.u16,
		data = t.struct({ hp = t.u8, gold = t.u16 }),
		audience = nw.audience.everyone,
		store = nw.store.of(world),
	}),
})

--[[ The subject, then the value. `nil` is that subject leaving this client's audience or ceasing
     to exist — the one packet shape says both. ]]
vault.client.inventory:listen(function(subject, value)
	held[subject] = value
end)

--[[ The game writes its own state and tells netweave nothing. Once a frame netweave reads the
     store and sends each client the difference between what it should see and what it has: the
     first frame is the whole value, and a frame where one field moved is that field. ]]
world[1] = { hp = 10, gold = 500 }

--[[ Everything is declared before anything is sent, and that is a rule rather than a habit: a
     namespace declared after the first packet has moved raises, because an id depends on every
     other channel in the program (`WIRE-FORMAT.md` §3). ]]
combat.client.equip:send({ slot = 1 })
combat.client.equip:send({ slot = 7 })
```

## 클래스

채널은 전송 방식이 아니라 보안 의무로 분류되어, 클래스 이름이 곧 문서가 됩니다. `command`는 권위
있는 상태를 바꾸며 `data`, `rate`, `authorize`가 필수이고 핸들러에 `Trusted<T>`를 건넵니다.
`intent`는 이동이나 조준처럼 연속적으로 관찰되는 입력입니다. 60 Hz에서 패킷마다 승인하는 것은 틀린
모델이므로 `authorize`를 금지하고, 플레이어당 틱당 최대 한 값으로 합쳐서 폭주가 패킷당 작업이 되지
않게 합니다. `signal`은 권위를 나르지 않고, 정직함을 지키기 위해 `authorize`를 금지하며,
`Untrusted<T>`를 전달합니다. `query`는 답하는 command입니다. `args`, `returns`, `rate`,
`authorize`, 그리고 무제한 값이 없는 `timeout`이 필수이고, 핸들러가 yield할 수 있는 유일한
클래스입니다. `state`와 `event`는 반대 방향, 서버에서 클라이언트로 가며 청중을 반드시 이름 붙여야
합니다. `replicate`도 아래로 가며 선언 시 `store`를 받고 `unreliable`을 거부합니다. 델타 하나가
떨어지면 그 클라이언트는 영원히 틀린 채로 남지만 `state` 패킷 하나가 떨어지면 한 틱 비용이기
때문입니다.

모든 채널은 스키마에서 유도한 바이트 상한도 가집니다. netweave의 모든 타입이 유한하기 때문이고, 그보다
크다고 주장하는 패킷은 디코드되기 전에 거부됩니다. `rate`는 윈도우가 아니라 토큰 버킷으로 강제되는
지속 속도라서, 약속은 "netweave가 우연히 그은 초들 안에서"가 아니라 "어느 1초 안에서든 `rate` 이하"입니다.

## 거부된 패킷은 어떻게 되는가

아무것도 던져지지 않습니다. 모든 거부는 채널, 플레이어, 단계, 이유를 가진 값입니다. 기본으로는
콘솔에 쓰이는데, 채널과 단계마다 세 번 쓴 뒤 억제되어 폭주가 장애가 되지 않습니다. 게임이
`nw.observe`로 붙인 것은 전부 받습니다. 단계는 `parse`, `budget`, `direction`, `protocol`,
`authorize`, `handler`, `queue`, `send`, `query`, `replicate`이고 각 보고는 어느 단계가 왜
거부했는지 말합니다. `nw.diagnostics()`는 카운터가 리셋된 이후 모든 거부의 수를 채널과 단계별로
돌려주며, 이것이 "이 채널이 한 시간 전보다 더 많이 거부하고 있는가"에 답합니다. 버그와 공격을 가르는
질문입니다. `nw.configure`는 규칙마다 심각도를 정하지 강제 여부를 정하지 않습니다. `"off"`로 둔
규칙도 여전히 거부하고 여전히 셉니다.

## 표면

전부 `nw`에 걸려 있습니다. `nw.namespace(name, channels)`는 채널 묶음을 한 번 선언하고 양쪽이
require합니다. 각 채널의 id가 전체에 의존하므로 모든 네임스페이스는 첫 패킷이 움직이기 전에 선언되어야
합니다. `nw.types`는 스키마 라이브러리이고 모든 타입이 유한합니다. `t.u8`, `t.u16(0, 1000)`,
`t.string(0, 32)`, `t.array(t.u8, 0, 8)`, `t.struct`, `t.enum({ a = true, b = true })`,
`t.optional`, `t.map`, `t.union`, `t.quantized`, `t.vector3`, `t.cframe`,
`t.instance("BasePart")`, `t.player`. 어떤 스키마든 그 페이로드 타입은
`t.PayloadOf<typeof(schema)>`라서 헬퍼가 스키마에 이미 적힌 타입을 다시 쓸 일이 없습니다.
`nw.policy(factory)`는 정책을 두 단계로 만듭니다. 팩토리는 한 번, 검사는 요청마다 돌고, 검사는
`nw.allow(value)`나 `nw.deny(reason)`을 돌려줍니다. `nw.all(...)`은 정책을 합성하고 첫 거부에서
멈춥니다. `nw.audience`에는 `everyone`, `owner`, `nearby(studs)`, `select(fn)`이 있습니다.
`nw.store.of(table)`, `nw.store.charm(getter)`, `nw.store.replica(replicas)`는 `replicate`가
읽는 것입니다. `nw.observe(fn)`은 모든 거부를 보고, `nw.configure(settings)`는 심각도와 한계를
정하며 잘못 쓴 이름은 호출 자리에서 거부하고, `nw.protocol()`과 `nw.signature()`는 양쪽 피어가
합의해야 하는 것이고, `nw.validate(schema, value)`는 이미 들고 있는 값을 검사해 전선 없이
`Trusted<T>`를 만들고, `nw.diagnostics()`는 카운터입니다.

`docs/DESIGN-API.md`가 전체 계약이며 그 근거와 측정이 강제한 정정까지 담고 있고,
`docs/WIRE-FORMAT.md`는 동결된 v1 와이어 포맷입니다.

## 설치

패키지 레지스트리 항목은 없습니다. 라이브러리는 `src/` 디렉터리이고, 빌드 단계가 없으며, 안의 모든
require는 Studio에서든 lune에서든 같은 식으로 풀리는 상대 경로 문자열입니다. `src/`를 `netweave`라는
이름의 폴더로 프로젝트에 복사하거나, `rojo build default.project.json -o netweave.rbxm`으로
패키지를 빌드해 양쪽이 닿는 곳에 넣습니다. 양쪽 모두에서
`local nw = require(ReplicatedStorage.netweave.netweave)`와 `local t = nw.types`가 전부입니다.
Roblox 안에서 require하면 transport가 설치되고, 설정할 것도 기억할 단계도 없습니다. 채널을 선언한
게임은 transport가 필요한 모든 것을 이미 말한 셈이기 때문입니다. [튜토리얼 1단계](docs/tutorial/step1-install.md)가
빈 place에서 이 과정을 따라갑니다.

## 비용

`bench/RESULTS.md`에는 모든 숫자가 분산, 표본 수, 출처 run 문서와 함께 있고, 왜 어느 것도 대역폭
수치가 아닌지 맨 위에 적혀 있습니다. M4를 닫은 두 번의 run, Studio loopback, 프레임당 200패킷
기준으로, 6바이트 구조체 100개짜리 배열 페이로드는 이론 하한에서 3파전 동점입니다. netweave, Blink,
Zap이 601바이트, ByteNet이 603. 불리언 12개, enum 2개, optional 2개짜리 페이로드에서 netweave는
Zap의 7바이트에 대해 8바이트를 내는데, 그 1바이트가 프레이밍 보장이 필요로 하는 길이 접두사입니다.
Blink는 작성자가 스키마를 어떻게 썼느냐에 따라 10 또는 20, ByteNet은 20입니다. 배열 페이로드
인코딩에서 netweave는 두 run에서 초당 114와 115프레임을 유지했고 Blink는 131과 134, Zap과 ByteNet은
112에서 116이었습니다. 다른 두 생성기와 같은 자리이고 Blink에 1.15배 뒤집니다. 디코딩에서는 Blink에
뒤지며, 63과 54 대 78과 83입니다. 결과 파일에 무엇이 알려졌고 무엇이 아닌지 적혀 있습니다. 모든 셀이
모든 방향에서 페이로드를 전달하고 검증했고, 하네스는 처리량 옆에 드롭을 함께 셉니다. 패킷을
잃어버리는 빠른 라이브러리는 빠른 것이 아니기 때문입니다.

## 개발

도구는 [rokit](https://github.com/rojo-rbx/rokit)이 관리하고 `rokit.toml`에 고정되어 있습니다.
`rojo`, `lune`, `stylua`, `selene`, `luau-lsp`. 타입 검사는 편의가 아니라 테스트 스위트의
일부입니다. `pwsh scripts/check.ps1`이 lune 쪽 검사 전부를 한 명령으로 돌리며 pre-commit 훅이기도
합니다. `lune run analyze`는 깨끗해야 하는 파일과 실패해야 하는 파일 양쪽에 대한 타입 체커이고,
`rojo build test.project.json -o netweave-test.rbxl`은 Studio 쪽 절반을 빌드합니다. `Vector3`,
`CFrame`, `Instance`, 실제 클라이언트가 거기 있습니다. `CLAUDE.md`가 저장소의 규칙집이고,
`docs/milestone/`에는 마일스톤마다 계획이 하나씩 있으며 고쳐 쓰는 대신 정정을 취소선으로 남기는
살아 있는 문서로 유지됩니다.

## 상태

마일스톤 M4가 닫혔습니다. 코덱, transport, 복제가 구현되었고, 외부 보안 감사 두 건의 모든 발견에
처분이 적혔으며(`docs/SECURITY-REPORT*.md`, `docs/milestone/PLAN-M4.md` §9), lune 스위트와 Studio
스위트 모두 녹색입니다. `PLAN-M5.md`는 작성되었지만 열리지 않았고, 감사가 미룬 타입 계층 작업을 담고
있습니다. 이 저장소는 로컬에서 개발되며 호스팅된 원격이 없습니다.

저장소의 언어는 영어입니다(`CLAUDE.md` §1). 이 파일은 README의 한국어판이며, 코드와 문서의 원본은
영어 쪽입니다.
