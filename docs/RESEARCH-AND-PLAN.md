# netweave — 경쟁 조사 및 포지셔닝 계획
조사일: 2026-09-02

## 1. 생태계 지도 (4세대 + 인접 영역)

### Gen 0 — 편의 래퍼 (성능 무관심)
RbxUtil `Net`, `Comm` (sleitnick), `Red` (red-blox), `EasyNetwork`, `Netv2` (2025-10, Net 기반 + 토큰버킷 레이트리밋 / 55+ validator / 미들웨어 / 지수백오프 재시도)

- 장점: 러닝커브 ~0, 리모트 인스턴스 관리 자동화, RemoteFunction 자연스럽게 지원, 문서 좋음
- 단점: 페이로드는 여전히 Roblox 기본 직렬화 → **대역폭 이득 0**, 배칭 없음. Netv2는 "문법이 별로다" + `t` 대신 자체 validator 만든 점 비판.

### Gen 1 — 배칭/추상화 세대 (거의 전멸)
BridgeNet / BridgeNet2, FastNet2(아카이브됨), NetRay("더 이상 유지보수 안 함" 명시)

- 교훈: buffer 시대 오면서 전부 도태. 그리고 **전부 1인 프로젝트라 유지보수가 끊김** — 이게 시장의 최대 불신 요인.

### Gen 2 — 런타임 스키마 + buffer SerDes
| 라이브러리 | 상태 | 장점 | 단점 |
|---|---|---|---|
| ByteNet (~177★) | 릴리스 0.4.3이 실사용본. **master(2025-08-01)는 미완성 리라이트 — `require("../a")` / `readRefs` / `buffer_writer` 3개 대상 파일이 저장소에 아예 없어 resolve조차 안 됨** | 미니멀 API, strict Luau, rbxts, 버퍼 직렬화, **Heartbeat 배칭 + 리모트 2개 멀티플렉싱** (§3.6) | **RemoteFunction 미지원**(ByteNet Max 포크가 메움), 네임스페이스마다 별도 모듈 강요, CFrame 이슈 보고, 리라이트 방치 |
| Warp 1.1.0-pre7 (HEAD 2026-05-05) | **깨짐** | reliable/unreliable 단일 API, dynamic + schema 두 모드, 플레이어별 XOR 난독화, 레이트리밋 시도 | **master가 Luau 구문 오류로 컴파일 불가**(`const` 키워드, §3.7-J [검증]). 레이트리밋도 결함(§3.7-K). Blink 벤치 하네스에서도 비활성. 커밋은 계속 있으나 검증이 없음 |
| Packet (2025-03) | 활발했음 | **배칭**, float16/24, 문자열 비트팩(1~8bit/char), CFrame 12~18B, RemoteFunction, DDoS 방어 표방 | 출시 직후 보안 취약점 다수 지적: 클라가 대기 스레드 조기 resume 유발, 버퍼 오버플로로 레이트리밋 우회, 패킷 검증 미흡으로 OOB 읽기 |
| Squash | 유지됨 | 모든 Luau/Roblox 타입 SerDes, DataStore에도 사용 | 네트워크 전용 아님, 전송 계층 없음 |

- 공통 장점: **빌드 스텝 없음**, Luau 안에서 스키마 정의, Rojo/CI 불필요
- 공통 단점: 코드젠 대비 CPU 오버헤드 — 진짜 성분은 타입 분기보다 **할당 병합 불가**다(§3.7-D). **배칭은 라이브러리마다 다름 — ByteNet(Heartbeat 4채널)·Warp(1/61s 누산기, 플레이어별 큐)는 있고 Squash는 없다**(소스 확인, §3.6·§3.7).

### Gen 3 — IDL + 코드젠 (현 성능 챔피언)
| 라이브러리 | 상태 | 장점 | 단점 |
|---|---|---|---|
| Zap (187★) | **활발** — 기본 브랜치 `0.6.x`, 최신 커밋 2026-06-23 `0.6.29`. v1 리라이트는 별도 브랜치에서 미완, 0.6.x는 커뮤니티 컨트리뷰터가 유지 | 배우기 쉬운 IDL, Luau+TS 타입세이프 출력, 서버측 검증 자동, 버퍼 난독화, Instance/숫자 키 맵 지원, **비트패킹(bool·optional·작은 enum → 비트)**, 범위 오프셋 길이 인코딩,  | **Rust 컴파일러 → 바이너리 툴체인 필요**, 원저자 이탈 리스크, 빌드 스텝, **할당 병합 없음(필드당 `alloc` — §3.9-V1 실측)**, **명명 타입·고정 길이 배열 완전 인라인/언롤 → 생성 파일 폭증**(`Entity[100]` 하나로 45KB, §3.9-X), 역직렬화 실패가 배치 전체를 죽임(§3.8-R) |
| Blink (181★, 486커밋) | 활발 — 기본 브랜치 최신 커밋 2026-04-11 `0.18.8`, 1.0.0-pre 계열은 별도 진행(pre.7 2026-08) | **Luau로 쓰인 IDL 컴파일러 → Studio 플러그인 에디터로 바이너리 없이 사용 가능**, 저장소에 `benchmark/`·`test/` 동봉, 스코프, **할당 병합**(블록당 `Allocate` 1회), 1.0에서 유니온·리터럴·재귀타입·제네릭 | 이벤트 추가마다 재생성, 생성 모듈이 소스 트리에 들어감, 핫리로드 불가, **`boolean` 필드는 바이트당 1개** — 자동 비트패킹 없음. 명시적 `set` 타입을 알아야 압축된다(§3.9-AA), **명명 타입을 참조마다 인라인 → 생성 파일 폭증**(§3.8-T), 수신 큐 무한 증가, Invoke 타임아웃 없음 |

- 공통 단점: **빌드 스텝**. 팀/CI 세팅 필요, 반복 주기 느림. 그리고 **908B 무방비**(§3.7-F), **Invoke 동시 256개 상한 + 타임아웃 부재**(§3.7-G), **역직렬화 실패 격리 없음**(§3.8-R) — 셋 다 공통.
- **두 챔피언의 최적화가 엇갈린다**: Blink = 할당 병합(CPU), Zap = 비트패킹(바이트). **둘 다 하는 곳은 없다**(§3.8-O). 이게 §3.5 2차원 지도의 오른쪽 위가 코드젠 진영 안에서도 비어 있다는 뜻.

### 인접 영역 — 상태 복제 (이벤트 라이브러리와 분리돼 있음)
ReplicaService/Replica, Charm Sync(재귀 델타 압축, 삭제는 `__none` 센티널), DeltaCompress(nezuo, 테이블 diff → buffer), YetAnotherNet(Rewire 핫리로드 지원)

→ 실제 게임은 **이벤트 라이브러리 + 복제 라이브러리를 둘 다** 붙이고 있음. 통합된 게 없음.

#### 실제로 읽고 나서 (M4 페이즈 1, 2026-09-05)
위 한 줄은 M0 때 이름만 적은 것이었다. `_refsrc/`에 셋을 받아 소스를 읽었고, **세 라이브러리가 서로 다른
세 가지 일을 한다**는 것이 첫 번째 정정이다. "복제 라이브러리"라는 하나의 범주가 아니다.

| | 무엇을 하는가 | 델타를 만드는가 | 무엇을 전송에 요구하는가 |
|---|---|---|---|
| **Charm Sync** | 상태를 들고, **자기가 diff한다** | O — 재귀 구조 diff | 콜백 하나. `connect(onSync)` |
| **ReplicaService** | 상태를 들고, **게임이 변경을 선언한다** | X — diff 자체가 없다 | RemoteEvent 여섯 개 |
| **delta-compress** | 상태를 들지 않는다. diff만 | O — 스키마 없는 buffer | 아무것도 |

**Charm Sync** (`charm/packages/charm-sync/`, `b05f3a9`)
- 페이로드는 `{ type: "init" | "patch", data: {...} }` 둘뿐이다 — `src/types.luau:5-13`.
- diff는 `src/patch.luau:59-89`. `oldState == newState`면 `nil`, 새 값이 `nil`이면 `None`, 테이블이 아니면
  새 값 그대로, 테이블이면 재귀. 삭제 센티널은 `None = { __none = "__none" }` — `patch.luau:10`.
- 서버 seam은 `addSignalsToClient(client, { key = atom })` + `connect(onSync)` — `src/server.luau:284, 381`.
  **netweave가 붙을 자리는 `onSync`이고, 그건 diff 엔진이 아니라 전송이다.**
- `Heartbeat` 인터벌로 flush — `server.luau:263`. 배칭이라기보다 폴링이다.
- `stringifySparseArray` (`patch.luau:32-57`)가 숫자 키를 문자열로 바꾼다. **JSON이 희소 배열의 꼬리 nil을
  떨어뜨리기 때문**이라고 주석이 직접 말한다. 이건 Roblox 기본 직렬화를 타는 라이브러리만 겪는 문제이고,
  버퍼 코덱에는 존재하지 않는다.

**ReplicaService** (`ReplicaService/src/ServerScriptService/ReplicaService.lua`, `aaeb1c6`)
- 델타 압축 라이브러리가 **아니다.** 게임이 변경을 이름으로 선언한다: `SetValue(path, value)`, `SetValues`,
  `ArrayInsert`, `ArraySet`, `ArrayRemove`, `Write(function_name, ...)` — `:403, 426, 452, 476, 503, 528`.
- 변경 종류마다 전용 RemoteEvent가 있고 **플레이어마다 한 번씩 발사한다** — `:416`
  `rev_ReplicaSetValue:FireClient(player, id, path_array, value)`. 배칭이 없다. §3.6-B1의 60Hz 상한과
  §3.7-E의 "직렬화 1회 + memcpy N회"가 둘 다 해당되지 않는 설계다.
- 경로가 매번 문자열 배열로 나간다. 유일하게 압축되는 자리는 write lib으로, 함수 이름이 `func_id` 정수가
  된다 — `:541`.
- 대상은 생성 시 고정: `Replication = "All" or {[Player] = true, ...} or [Player]` — `:46`.

**delta-compress** (`delta-compress/src/`, `46f0831`)
- `diffImmutable(old, new) -> buffer?` — `Diff.luau:312`. 변한 게 없으면 `nil`.
- **스키마가 없어서 값마다 타입 태그를 쓴다.** `TypeId.luau:3-22`에 21개 — `nil/string/number/boolean/
  Vector2/Vector3/Vector2int16/Vector3int16/CFrame`와 `array/dictionary`, 그리고 `arrayRemovals`,
  `arrayAdditions`, `arrayChanges`, `dictionaryChanges`, `dictionaryRemovals` 같은 **diff 연산 태그**.
- 지원 타입이 그 목록으로 닫혀 있다. Color3도 CFrame 배열도 없다.

#### netweave에 대한 함의 — 이게 페이즈 1의 결론이다
1. **netweave는 store를 감싸는 diff 엔진이 아니라, 복제 라이브러리의 전송이다.** Charm은 이미 diff를
   하고 콜백만 원하고, Replica는 diff를 아예 안 하고 RemoteEvent 대체를 원한다. 둘 다 "`read()` +
   `changed()`를 주면 netweave가 diff한다"는 모양이 아니다.
2. **바이트 우위가 어디 있는지가 분명해졌다.** delta-compress는 값마다 타입 태그를 쓴다 — 스키마가 없으니
   달리 방법이 없다. netweave는 스키마가 있으므로 **"어떤 필드가 바뀌었는가"를 비트필드로 쓰고 바뀐 값만
   스키마 순서로** 쓰면 된다. 필드 정체성이 직렬화된 키가 아니라 위치다. 12필드 구조체에서 한 필드가
   움직이면 delta-compress는 키 + 타입 태그 + 값을 쓰고, netweave는 12비트 + 값을 쓴다.
3. **삭제 센티널은 netweave에 필요 없다.** Charm이 `__none` 테이블을 쓰는 건 JSON을 타기 때문이다.
   netweave에는 이미 플래그 스코프가 있으므로 "제거됨"은 1비트다. `PLAN-M4` 페이즈 3의 열린 질문 하나가
   여기서 닫힌다.
4. **패치는 상태와 모양이 다르다는 것이 진짜 문제다.** netweave의 코덱은 스키마 구동인데 `PlayerState`의
   *패치*는 그 스키마가 기술하지 않는다. 상태 스키마에서 **패치 스키마를 파생**해야 한다 — 모든 필드를
   optional로 만들고 삭제 비트를 더한 것. 이건 `Ir`이 이미 할 수 있는 일이고, 안 하면 패치를 불투명
   페이로드로 나르게 되어 요점이 사라진다. `PLAN-M4` D-3에 적었다.

## 2. 플랫폼 제약 (설계 입력값)
- `UnreliableRemoteEvent` 실제 상한 약 **908바이트**(문서는 900), 초과 시 **조용히 드랍**. 버퍼는 내부 압축까지 되어 사전 크기 예측이 어려움.
- 리모트를 **60Hz 초과**로 발사하면 서버 네트워크 응답시간이 폭증 → 배칭은 선택이 아니라 필수.
- 2026 변화: `Workspace.ImprovedPhysicsReplication`(6/15 롤아웃), 백엔드 replication eventual consistency, Studio **Advanced Network Simulation**.

## 3. 빈틈 (공략 지점)
- **G1 지속성 신뢰** — 시장이 "sustainable" 을 명시적으로 요구. 대부분 2년 내 정지.
- **G2 이분법** — 지금은 "편하지만 느린 런타임" 또는 "빠르지만 빌드 필요한 코드젠" 양자택일.
- **G3 전송 계층 부재** — 배칭 / 우선순위 / 대역폭 예산 / 신뢰도 티어 / 908B 자동 분할·드랍 정책을 종합적으로 하는 게 없음.
- **G4 이벤트 ↔ 상태 복제 분리**
- **G5 보안이 애드온** — 검증·레이트리밋·백프레셔가 코어에 없음(Packet 사례).
- **G6 관측성 부재** — 이벤트별 바이트/초, 상위 소비자, 예산 초과 경고. (§3.7-K 정정: Warp에 시도가 있으나 800B 하한·리셋 결함·Studio 제외로 오작동. 제대로 하는 곳은 여전히 없음)
- **G7 roblox-ts 지원 불균등.**

## 3.5 심화 참고: Flamework Networking — "구조 축"의 챔피언

Flamework(Fireboltofdeath)은 roblox-ts용 프레임워크(싱글톤 / DI / 컴포넌트 / 네트워킹)이고, 패키지가 쪼개져 있어 networking만 골라 쓸 수 있다.
**성능 라이브러리가 아니다.** 버퍼 직렬화가 없어서 페이로드는 Roblox 기본 직렬화 = Gen 0 수준. 그런데 **구조 설계는 이 생태계에서 가장 앞서 있다.** 훔쳐올 것 6가지:

### S1. 타입이 곧 스키마 — 단일 진실 공급원
```ts
interface ClientToServerEvents { event(param1: string): void }
interface ServerToClientEvents { event(param1: string): void }
export const GlobalEvents = Networking.createEvent<ClientToServerEvents, ServerToClientEvents>();
```
별도 IDL 파일이 없다. **호스트 언어의 타입이 스키마**고, TS 컴파일러 트랜스포머(`rbxts-transformer-flamework`)가 그 타입에서 **런타임 타입가드를 자동 생성**한다. 스키마와 검증이 구조적으로 어긋날 수 없다.

> netweave 적용: Luau엔 트랜스포머가 없으니 **역방향**으로 같은 성질을 얻는다. 스키마 *값*을 정의하면 → 거기서 Luau 타입을 추론(`typeof(codec:read(...))`)하고, 검증기와 serdes 클로저도 같은 값에서 파생. 정의 1개 → 타입 + 검증 + serdes. Zap/Blink는 이걸 코드젠으로 푸는데, 우리는 값 수준에서 푼다.

### S2. 방향성(direction)을 1급으로 모델링 — 보안이 API 모양에서 나온다
C→S와 S→C 인터페이스가 **분리**돼 있고, 환경별 네임스페이스를 만들어 re-export 한다:
```ts
// server/networking.ts
export const Events = GlobalEvents.createServer({ /* middleware, guards */ });
// client/networking.ts
export const Events = GlobalEvents.createClient({ /* ... */ });
```
효과: 클라이언트 번들에 **서버 설정(생성된 타입가드·미들웨어)이 아예 포함되지 않는다.** 잘못된 방향으로 fire 하면 컴파일 에러. 발사 API도 방향에 맞게 갈라져 있음 — 서버는 `fire(player | player[])` / `except(player)` / `broadcast()`, 클라는 `fire(...)`, 수신은 `connect((player, ...args) => ...)`.

> ByteNet이 "네임스페이스마다 모듈 분리"를 강요하는 건 방향성 모델링이 아니라 그냥 불편함이다. 둘은 다르다.
> netweave 적용: `net.channel{ toServer = {...}, toClient = {...} }` → `:server()` / `:client()` 두 뷰를 반환. 방향 위반은 타입 에러, 서버 전용 설정은 클라 뷰에 존재하지 않음.

### S3. 미들웨어를 코어 확장점으로 — 2단계 커링
```ts
function randomChanceMiddleware<I extends Array<unknown>>(chances: number): Networking.EventMiddleware<I> {
	return (processNext, event) => {          // ① 로드 시 1회 — event.name 등 메타데이터 접근
		return (player, ...args) => {          // ② 요청마다
			if (math.random() < chances / 100) processNext(player, ...args);
		};
	};
}
export const Events = GlobalEvents.createServer({
	middleware: { myServerEvent: [randomChanceMiddleware(50)] }
});
```
①/② 분리가 핵심이다 — 이벤트별 상태(토큰 버킷, 카운터, 링버퍼)를 ① 클로저에 잡아둘 수 있다. drop / delay / 인자 변조 / `Networking.Skip`(응답 취소) 전부 이 한 형태로 표현된다.

**그런데 Flamework은 미들웨어를 하나도 기본 제공하지 않는다.** 레이트리밋·로깅·계측 전부 사용자가 직접 짜야 함.
> netweave 적용: **확장점은 그대로 베끼고, 배터리는 포함한다.** 토큰버킷 레이트리밋 / 대역폭 계측 / 스키마 검증 / 백프레셔를 기본 미들웨어로 제공 → §3의 G5·G6를 그대로 메움.

### S4. 실패 모드를 타입화 (RemoteFunction)
Promise 기반 + 타임아웃 기본값 **클라 30초 / 서버 10초**(`defaultTimeout`, `invokeWithTimeout`로 조정 가능 — 공식 문서의 "10초 고정" 서술은 부정확, 소스 기준). 그리고 실패가 문자열이 아니라 enum이다:
`NetworkingFunctionError` = `Timeout` / `Cancelled` / `BadRequest` / `InvalidResult` / `Unprocessed`
`predict()`로 전송 없이 시뮬레이션도 가능. 핸들러는 함수당 1개만(중복 `setCallback` 시 경고).

> 이게 이 조사에서 가장 저평가된 아이디어다. Roblox 네트워크 라이브러리 대부분이 실패를 `nil`이나 에러 문자열로 뭉갠다 — 호출자가 "타임아웃"과 "악의적 입력 거부"와 "핸들러 없음"을 구분할 수 없다.
> netweave 적용: `Result<T, NetError>` 형태로 실패를 열거형화. 최소 `Timeout / Rejected(검증 실패) / RateLimited / Dropped(908B 초과) / NoHandler / Cancelled`.

### S5. 전송 특성을 스키마에 넣는다
```ts
interface ClientToServerEvents {
	myUnreliableEvent: Networking.Unreliable<(param1: string) => void>;
}
```
unreliable이 **별도 API가 아니라 타입 래퍼**다. 반면 Warp의 `:Fires(true, ...)` / `:Fires(false, ...)` 불린 인자 방식은 호출부마다 실수 가능 — 나쁜 예.
단, Flamework도 900B 한계는 그냥 "사용자가 지켜라"로 넘긴다.

> netweave 적용: 전송 특성을 스키마에 넣는 건 그대로 채택하고, **908B는 라이브러리가 책임진다** — 스키마에서 정적 최대 크기를 계산해 정의 시점에 경고, 가변 길이는 런타임 자동 분할 또는 명시적 드랍 정책. 조용한 드랍 0건(§6 판정 기준).

### S6. 모듈 분해
패키지가 쪼개져 있어 networking만 설치 가능 → netweave도 L1(codec) / L2(transport) / L3(replication)을 **별도 Wally 패키지**로.

### 따라가면 안 되는 것
- **roblox-ts 전용.** TS 트랜스포머 + `experimentalDecorators` + tsconfig 플러그인 필요 → **순수 Luau 사용자는 아예 접근 불가.** 로블록스 개발자 대다수가 여기 해당한다. netweave는 Luau 퍼스트, rbxts는 타이핑 제공.
- **버퍼 직렬화 없음** → 대역폭 이득 0.
- **배칭 없음** (§2의 60Hz 문제 그대로 노출).
- 미들웨어 배터리 없음, 함수당 핸들러 1개 제한.

### 이 조사가 바꾸는 것: 경쟁 지도는 2차원이다
```
구조적 엄격함 ↑
              │  Flamework            ★ netweave 목표
              │  (타입=스키마,          (Flamework 구조
              │   방향성, 미들웨어,        + Blink 바이트,
              │   에러 enum)              순수 Luau)
              │
              │        Zap / Blink
              │        (IDL·검증 강함, 방향성/미들웨어 약함)
              │
              │   Net/Comm/Red   ByteNet   Packet
              └────────────────────────────────────→ 바이트·CPU 효율
```
**오른쪽 위가 비어 있다.** 성능 진영(Blink/Packet)은 구조가 얇고, 구조 진영(Flamework)은 바이트를 포기했으며 rbxts에 갇혀 있다. §4의 포지셔닝은 이 빈칸을 노리는 것으로 재정의한다.

## 3.6 소스 코드 분석 (git clone 후 직접 확인)

`rbxts-flamework/networking`(1,636 LOC TS) · `ffrostflame/ByteNet`(1,054 LOC Luau) · `1Axen/blink` · `red-blox/zap` 을 shallow clone 해서 읽음. 아래는 **문서가 아니라 소스에서 확인한 사실**이며, §1·§3.5의 일부 서술을 정정한다.

### A. Flamework networking — 실제 구조

**A1. RemoteFunction을 쓰지 않는다.** `createFunctionSender.ts` + `createFunctionReceiver.ts`는 **RemoteEvent 2개 위에 요청/응답 프로토콜을 직접 구현**한다.
- 송신: `nextId++` 로 요청 id 발급 → `event.fireServer(id, ...args)` → `requests: Map<number, resolver>` 에 resolver 등록
- 서버는 플레이어별로 `Map<Player, RequestInfo>` 를 들고, `Players.PlayerRemoving` 시 그 플레이어의 **모든 대기 요청을 `Cancelled`로 reject** 한다 (누수/영구대기 차단)
- 응답 와이어 포맷: `fireEither(player, id, processResult, value)` — `processResult`는 `true` | 에러 문자열 | `false`(=`Unprocessed`)
- `Promise.race([timeoutPromise(t, Timeout), sender.invokeClient(...)])`

→ **RemoteFunction의 yield·에러 전파·무한대기 문제를 아예 회피하는 방식.** netweave도 RemoteFunction을 쓰지 말고 이 패턴을 채택할 것.

**A2. 타임아웃 기본값은 클라 30초 / 서버 10초** (`createNetworkingFunction.ts`: `config.defaultTimeout ?? (RunService.IsClient() ? 30 : 10)`). 공식 문서의 "모든 요청 10초"는 부정확하다. `invokeWithTimeout(player, timeout, ...)`로 호출 단위 조정 가능.

**A3. 미들웨어 체인은 정의 시점에 1번만 조립된다.**
```ts
for (let i = factories.size() - 1; i >= 0; i--) {
    const processNext = middleware[i + 1] ?? finalize;
    middleware[i] = factory(async (player, ...args) => processNext(player, ...args), networkInfo);
}
return async (player?, ...args) => middleware[0](player, ...args);
```
뒤에서 앞으로 감아 클로저 체인을 만든다 → **요청당 비용은 클로저 호출뿐, 배열 순회 없음.** 이건 그대로 베낀다.

**A4. 그런데 요청당 Promise를 할당한다.** `MiddlewareProcessor = (player?, ...args) => Promise<O>` 이고 `createEvent`의 `invoke`도 async다. 이벤트 하나 받을 때마다 Promise 1개 생성 + resolve. `createEvent`는 여기에 더해 **수신을 BindableEvent로 한 번 더 통과**시킨다(다중 리스너 팬아웃용). BindableEvent는 테이블 인자를 복사하므로 **패킷당 Promise 할당 + 테이블 딥카피**가 붙는다.
→ netweave 결론: **핫패스에 Promise를 쓰지 말 것.** 팬아웃은 BindableEvent 대신 리스너 배열 직접 순회 + ByteNet식 스레드 재사용(§B4).

**A5. 가드 미들웨어는 항상 체인 맨 앞.** `createGenericHandler.ts`에서 `incomingMiddleware.unshift(createGuardMiddleware(...))` → 사용자 미들웨어보다 **검증이 먼저** 돈다. `warnOnInvalidGuards` 기본값은 `RunService.IsStudio()` — **가드는 프로덕션에서도 돌고, 경고만 Studio 한정.** 좋은 기본값이다.

**A6. 관측성 훅이 실제로 있다** (§3의 G6을 일부 정정). `handlers.d.ts`:
```ts
onBadRequest: (player, { networkInfo, argIndex, argValue }) => void
onBadResponse: (player, { networkInfo, value }) => void
```
`registerHandler("onBadRequest", cb)` 로 구독. **단, 대역폭·바이트 계측은 여전히 전무** — G6은 "검증 실패 훅은 있으나 바이트 회계는 없음"으로 좁혀 읽어야 한다.

**A7. 난독화는 타입 레벨 인트린식.** `types.d.ts`에 `Modding.Obfuscate<T & string, "remotes">`, `IntrinsicObfuscateArray<T, "shuffle-array">`. 그리고 `createRemoteInstance.ts`는 리모트를 **Name이 아니라 `id` 어트리뷰트로 조회**한다(Name은 debugName일 뿐). 클라는 `waitByAttribute`로 대기하며 5초 지나면 경고.

**A8. 리모트 인스턴스 개수 = 이벤트 수.** `createGenericHandler`가 이벤트마다 `createEvent`를 부르고, 수/발신 신뢰도가 다르면 `unreliable:` 접두어로 **하나 더** 만든다(같으면 인스턴스 공유). 함수는 `$`(서버)·`@`(클라) 접두어로 sender/receiver를 분리. → 이벤트 200개면 리모트 200개+.

**A9. 배칭·레이트리밋·버퍼는 코드에 존재하지 않는다.** `grep -rni "buffer|ratelimit|batch" src` 결과 0건. `createServerMethod.except()`는 `Players.GetPlayers()`를 돌며 **플레이어마다 개별 `FireClient`** 를 호출한다.

**A10. `predict()`는 전송 없이 로컬 체인만 실행한다** (`receiver.invoke(player, ...args)`). 클라 예측·테스트에 유용한 아이디어 — 채택.

**A11. `Skip` 센티널의 정밀함.** `skip.ts`는 `__index`/`__newindex`가 `undefined`를 반환하는 메타테이블 객체다. `SkipBadRequest`는 별도 nominal 타입이고, 주석에 *"동등성에 영향을 주므로 맨 앞 미들웨어에서만 반환 가능 — 다른 미들웨어가 들여다보지 못하게"* 라고 명시. `getProcessResult`가 `Skip → Cancelled`, `SkipBadRequest → BadRequest`로 매핑.

### B. ByteNet — 전송 계층은 이미 잘 만들어져 있다 (§1 정정)

**B1. 배칭이 있다.** `process/server.luau`는 `RunService.Heartbeat`마다 채널 버퍼를 flush 한다:
- 채널 4종: `globalReliable`, `globalUnreliable`, `per_player_reliable[plr]`, `per_player_unreliable[plr]`
- `cursor > 0`일 때만 `dump()` → `FireAllClients(b, refs)` / `FireClient(player, b, refs)` → `cursor = 0`, `table.clear(references)`
- **리모트는 전체 2개뿐** (`ByteNetReliable`, `ByteNetUnreliable`). Flamework의 "이벤트당 리모트 1개"(A8)와 정반대.

**B2. 패킷 다중화는 u8 id 프리픽스.** `process/read.luau`:
```lua
while read_cursor < length do
    local packet = ref[buffer.readu8(incoming_buff, read_cursor)]
    read_cursor += 1
    local value, value_len = packet.reader(incoming_buff, read_cursor)
    read_cursor += value_len
    ...
end
```
→ **패킷 타입 상한 256개**. netweave는 varint id로 열어둘 것.

**B3. 버퍼에 못 담는 값은 사이드카 배열로.** Instance 등은 `references: { [number]: unknown }` 에 담아 리모트 2번째 인자로 함께 전송. **버퍼 + ref 배열**이 Roblox에서 사실상 유일한 해법이다 — netweave L1도 이 구조를 그대로 가져간다.

**B4. 리스너 호출에 스레드 풀을 쓴다.**
```lua
local function run_listener(fn, ...)
    free_thread = task.spawn(free_thread or task.spawn(coroutine.create(yielder)), fn, ...)
end
```
`task.spawn(fn, ...)`이 매번 코루틴을 새로 만드는 비용을 없애는 고전 패턴. 이벤트 수신 핫패스에 필수 — 채택.

**B5. 코덱은 이미 "클로저 특수화"다** — §4에서 내가 제안한 L1 설계가 ByteNet에 이미 있다.
```lua
export type DataType<T> = {
    write: (value: T) -> (),
    read:  (b: buffer, cursor: number) -> (T, number),
}
```
- `struct.luau`: 정의 시점에 `index_value_type_pairs` / `index_key_pairs` 배열을 미리 만들고, read/write는 그 배열만 순회 → **런타임에 키 순회·타입 분기 없음**
- `optional.luau`: `local value_read = value_type.read` 로 **클로저에 미리 캡처**해 호출당 테이블 인덱싱 제거
- `packet.luau`: `local writer = props.value.write` (주석: *"shortcut to avoid indexxing"*), 신뢰도에 따라 `serverSendFunction`을 **정의 시점에 바인딩**
- 파일 전반에 `--!native --!optimize 2` 와 `@native` 어트리뷰트
- `packet.luau` 주석: *"We use closures here instead of metatables for performance"*

> **이게 §7 리스크에 대한 답이다.** "클로저 특수화가 코드젠에 붙을 수 있나?"는 이제 미지수가 아니다 — ByteNet이 이미 그 방식으로 Blink와 벤치마크 경쟁권에 있다. netweave의 M0는 "가능한가"가 아니라 **"얼마나 붙는가"를 재는 것**으로 바뀐다.

**B6. 런타임 컨텍스트 검사에 비용을 안 쓴다.** `packet.luau`는 서버/클라 전용 메서드를 **아예 정의하지 않고**, 없는 키 접근 시에만 `__index` 메타메서드가 에러를 던진다(주석: *"RunContext error checking that doesn't have performance drawbacks"*). §3.5-S2의 "방향 분리"를 Luau에서 구현하는 실전 기법.

**B7. write API가 암묵적 전역 상태에 의존한다 (안티패턴).** `string.luau`의 `write`는 `writeu16(length)`, `dyn_alloc(length)`, `writestring(data)` 같은 **모듈 스코프 전역**을 호출한다. read는 `(b, cursor)`를 명시적으로 받는데 write만 암묵적 — 비대칭이고 재진입 불가. netweave는 **write도 `(state, value)` 명시 전달**로 대칭을 유지할 것.

**B8. master 브랜치가 깨져 있다.** `require("../a")`, `require("./readRefs")`, `require("./buffer_writer")` — **세 대상 파일 모두 저장소에 없다.** `types.ChannelState`는 `ref_map`을 선언하는데 `server.luau`의 `create()`는 `references`/`size`를 반환해 타입도 안 맞는다. API도 `define_packet`/`t` 로 0.4.3의 `defineNamespace`와 다르다 → **미완성 v0.5 리라이트가 2025-08-01 이후 방치된 상태.** 실사용본은 릴리스 0.4.3.

### C. 종합 — 이번 분석이 계획에 미치는 영향

| 이전 판단 | 소스 확인 후 |
|---|---|
| Gen2는 배칭이 없다 | **틀림.** ByteNet은 Heartbeat 배칭 + 4채널 + 2리모트 멀티플렉싱을 이미 갖췄다 |
| 클로저 특수화가 코드젠급 성능을 낼지 미지수 (§7 최대 리스크) | ByteNet이 이미 그 방식 → **리스크가 "가능성"에서 "격차 측정"으로 하향** |
| Flamework은 구조만 좋다 | 맞지만, **요청당 Promise 할당 + BindableEvent 딥카피**라는 구조적 비용이 있다. 구조는 베끼되 이 두 개는 버린다 |
| 관측성 전무(G6) | Flamework에 `onBadRequest`/`onBadResponse` 훅 존재. **바이트 회계만 여전히 공백** |
| Zap 정체 | **틀림.** 기본 브랜치 0.6.x가 2026-06-23 `0.6.29`까지 릴리스 중 |
| ByteNet 정체 | **더 심각.** master가 resolve조차 안 되는 미완성 리라이트 |

**netweave의 진짜 차별점은 이제 이 셋으로 좁혀진다:**
1. **ByteNet의 전송 계층 + Flamework의 구조 계약**을 한 라이브러리에서 — 지금 둘은 서로를 모른다
2. **핫패스 제로 할당** — Promise·BindableEvent·`task.spawn` 없이 (A4를 피하고 B4를 채택)
3. **바이트 회계 + 908B 책임** — 아무도 안 하는 영역 (G6, S5)


## 3.7 2차 소스 리뷰 — Blink / Zap / Warp 코드젠·런타임 해부

> 저장소를 `_refsrc/`에 clone(전체 히스토리)해서 직접 읽음. 커밋 기준:
> `networking 3bd58cd (2025-09-03)` / `ByteNet fbdb156 (2025-08-01)` /
> `blink 73695d1 (2026-04-11, v0.18.8)` / `zap 8cd17ab (2026-06-23, 0.6.29)` /
> `Warp a27067c (2026-05-05, 1.1.0-pre7)`.
> Luau 컴파일러(lune 0.10.5 `luau.compile`)로 구문 검증까지 돌린 항목은 **[검증]** 표시.

### D. 코드젠이 런타임 스키마보다 빠른 진짜 이유 — 할당 병합(allocation coalescing)

지금까지 "코드젠이 빠르다"를 막연히 받아들였는데, Blink `src/Generator/Blocks.luau`의
`Block:_operation()`이 그 격차의 정체를 드러낸다.
한 블록 안의 **고정 크기 쓰기를 전부 합산**해서, 블록 맨 앞에 `Allocate(N)` **한 번**을
호이스팅하고(`_appendOperations`), 각 필드는 그 오프셋에서 쓴다. 실제로 뽑아본 출력
(`_refsrc/_generated/_gen_blink_reuse.luau`, `struct { a: boolean, b: boolean, c: u8?, d: boolean }`):

```lua
-- Read BLOCK: 4 bytes
local BLOCK_START = Read(4)
local Value = {} :: any
Value.a = (buffer.readu8(RecieveBuffer, BLOCK_START + 0) == 1)
Value.b = (buffer.readu8(RecieveBuffer, BLOCK_START + 1) == 1)
if buffer.readu8(RecieveBuffer, BLOCK_START + 2) == 1 then
	-- Read BLOCK: 1 bytes
	local BLOCK_START = Read(1)
	Value.c = buffer.readu8(RecieveBuffer, BLOCK_START + 0)
end
Value.d = (buffer.readu8(RecieveBuffer, BLOCK_START + 3) == 1)
```

배열은 `Allocate(Bytes * Count)`로 루프 전체를 한 번에 잡는다(`Operation.Variable`).
가변 길이 타입이 끼면 `DisableOperationOptimisations()`로 필드별 `Allocate`로 되돌린다.

**단, 상수 오프셋 폴딩은 최상위 블록에서만 된다.** `_operation()`이
`self.Unique ~= DEFAULT_UNIQUE`(= 루프 안)일 때는 상수 오프셋 대신 **러닝 커서**를 뽑는다.
`Entity[100]` 실제 출력:

```lua
-- Read BLOCK: 6 bytes
local ARRAY_START_1 = Read(6 * Length)   -- 배열 전체 1회 (여기까지는 병합 성공)
for Index = 1, Length do
	local Item_1 = {} :: any
	local OPERATION_OFFSET_0 = ARRAY_START_1   -- 필드마다 local 선언 +
	ARRAY_START_1 += 1                          -- 증가 +
	Item_1.id = buffer.readu8(RecieveBuffer, OPERATION_OFFSET_0)   -- 읽기
	... (x, y, z, orientation, animation 동일) ...
	table.insert(Value, Item_1)
end
```

즉 **alloc/read 호출 병합은 전 구간에서 되지만, 상수 오프셋 폴딩은 최상위에서만 된다.**
루프 내부는 필드당 `local` 1개 + `+=` 1개가 추가로 붙는다. 격차를 추정할 때 이 구분이 중요하다.

**이게 ByteNet식 "타입당 클로저"가 구조적으로 못 하는 일이다.** 클로저는 형제 필드의
크기를 모르므로 각자 alloc을 호출해야 한다. 6필드 struct = alloc 6회 + 클로저 호출 6회 vs
alloc 1회 + 인라인 쓰기 6회. **§7에서 "격차가 몇 %인가"라고 했던 그 격차의 주요 성분이 여기다.**

**→ netweave 설계 결론 (M1 수정):** 런타임 스키마여도 정의 시점에 스키마 트리를 훑어
**고정 크기 프리픽스를 미리 계산**하고, 최상위 write에서 한 번 alloc한 뒤 클로저에
`base_offset`을 넘기면 병합의 상당 부분을 회수할 수 있다. 완전 가변 구간부터만
per-node alloc으로 전환. 루프 내부는 Blink조차 러닝 커서를 쓰므로 **거기서는 격차가 더 좁다.**
이게 M0에서 측정해야 할 핵심 가설이다.

### E. 전송 계층 — 세 라이브러리가 서로 다른 선택을 했다

| 항목 | Blink 0.18.8 | Zap 0.6.29 | ByteNet 0.4.3 |
|---|---|---|---|
| 신뢰(reliable) 리모트 | 1개 공유, u8 id 프리픽스 | 1개 공유, u8/u16 id | 1개 공유, u8 id |
| 비신뢰(unreliable) 리모트 | 1개 공유 | **이벤트당 1개 인스턴스** (`{scope}_UNRELIABLE_{id}`) | 1개 공유 |
| 비신뢰 배칭 | **없음. 호출마다 즉시 발사** | 없음(FireAllClients 직행) | **있음(Heartbeat)** |
| 신뢰 flush | `RunService.Heartbeat` | `RunService.Heartbeat` | `RunService.Heartbeat` |
| 진짜 브로드캐스트 | 없음 — 플레이어별 버퍼에 memcpy N회 + `FireClient` N회 | 동일 | **`globalReliable` 채널 → `FireAllClients` 1회** |

세 가지 다 뜯어낼 가치가 있다:

- **"직렬화 1회 + memcpy N회"는 전원 공통 관용구다.** Blink `RELIABLE_BODY`, Zap
  `push_return_fire_all` 둘 다 `save()` → 스크래치 버퍼에 1회 직렬화 → 플레이어별로
  `load(player_map[p])`, `alloc(len)`, `buffer.copy`, `save()`. 표준으로 채택.
- **ByteNet의 `globalReliable` + `FireAllClients`가 진짜 브로드캐스트에서 유일하게 우월하다.**
  Blink/Zap은 100명이면 memcpy 100회 + 리모트 호출 100회. netweave는 "전원 동일 페이로드"를
  별도 채널로 분리해야 한다.
- **비신뢰 배칭은 의미론 충돌이다.** 배칭하면 데이터그램 1개 유실 = 이벤트 N개 유실.
  Blink가 배칭을 안 하는 건 게으름이 아니라 선택으로 보인다. netweave는 **패킷 단위 opt-in**
  (`unreliable { batch = false }`)으로 사용자에게 넘기는 게 맞다.

### F. 908바이트 — 셋 다 아무도 안 막는다 [검증]

`blink/src`, `zap/src/output/luau` 전체에서 `900|908|buffer.len` 상한 검사 **grep 0건**.
비신뢰 페이로드가 한계를 넘으면 Roblox가 **조용히 버린다**. 코드젠이라 스키마의 최대 크기를
컴파일 타임에 계산할 수 있는데도 안 한다.
**→ §3-G와 §4 차별점 ③ 확정. 여기는 비어 있다.**

### G. 요청/응답(Invoke) — 코드젠 진영의 공통 약점

Blink `Generator/init.luau:723-745`, Zap `client.rs:1329` 둘 다:

- 호출 id가 **u8** → **동시 미응답 호출 256개가 하드 상한**. 넘으면
  `error("More than 256 calls are awaiting a response, this packet has been dropped.")`
- **타임아웃이 아예 없다** [검증: `grep -ri timeout blink/src` → 0건].
  `Calls[id] = coroutine.running()` 후 `coroutine.yield()`. 상대가 응답을 안 주면
  **스레드가 영구히 매달린다.** Promise 변형에도 자동 취소가 없고 `OnCancel`만 있다.

반대로 Flamework는 Promise 할당 비용을 내는 대신 **클라 30초 / 서버 10초 타임아웃 + `Cancelled` /
`Unprocessed` / `InvalidResult` 타입화된 실패 + `PlayerRemoving` 시 해당 플레이어 대기 요청 일괄 reject**를
갖는다(§3.6-A). **구조 축과 바이트 축이 정확히 반대 방향으로 실패하고 있다는 가장 선명한 증거.**

netweave: Blink식 코루틴 직접 resume(할당 0) + Flamework식 타임아웃·실패 타입 + **varint 호출 id**.

### H. 수신 큐 — Zap이 이겼다

- **Blink**: 리스너 없는 이벤트는 `table.insert(Queue, {...})`로 **무한 적재**.
  256 초과 시 `warn`이 뜨지만 **삽입은 계속된다** → warn 스팸 + 메모리 증가
  (`Generator/init.luau:413-418`).
- **Zap**: `read_cursor`/`write_cursor` **링 버퍼**, 가득 차면 `queue_size * 2`로
  재할당하며 `table.move` 두 번으로 언랩(`server.rs:287-362`). 명백히 더 낫다.

netweave는 Zap의 링 버퍼 + **상한 도달 시 drop-oldest + 계측 카운터**(경고 스팸 대신).

### I. 전역 쓰기 상태는 안티패턴이 아니라 이 바닥의 표준이다 — §5-M1 정정

§3.6-B7에서 ByteNet의 모듈 전역 `write` 상태를 안티패턴으로 지목하고
"netweave는 `(state, value)` 명시 전달로"라고 적었는데, **틀렸다.**

Blink `Templates/Base.luau`, Zap `output/luau/base.luau` **둘 다 똑같이** 모듈 전역
(`SendBuffer/SendCursor/SendOffset/SendInstances`, `outgoing_buff/outgoing_used/...`)을 쓰고,
재진입은 **`Save()` / `Load(save)` 쌍**으로 해결한다. 플레이어별 버퍼 멀티플렉싱 자체가
이 save/load 스왑 위에 서 있다.

이유는 명확하다. 쓰기 한 줄이 `buffer.writeu8(SendBuffer, BLOCK+0, v)` — **업밸류 접근 1회**로
끝난다. state를 넘기면 매 쓰기마다 **인자 푸시 + 테이블 필드 인덱싱**이 추가된다.
핫패스에서 이건 공짜가 아니다.

**→ 정정: netweave도 전역 + save/load 스왑을 채택한다.** 대신 ByteNet이 놓친 것
(read는 인자 전달, write는 전역이라 **비대칭**)만 고쳐서 **양방향 모두 전역 + save/load**로 통일한다.

### J. Warp — master가 컴파일되지 않는다 [검증]

`Warp/src/Util/Identifier.luau:4`, `Warp/src/Util/Xor.luau:13`이
`const BITS: number = 8` 을 쓴다. **Luau에 `const` 선언 키워드는 없다.**
lune 0.10.5의 `luau.compile`로 확인:

```
Warp/src/Util/Identifier.luau  FAIL: syntax error: 4: Incomplete statement
Warp/src/Util/Xor.luau         FAIL: syntax error: 13: Incomplete statement
(나머지 6개 파일은 OK)
```

`Server/init.luau`가 둘 다 require하므로 **라이브러리 전체가 로드되지 않는다.**
트랜스파일 단계도 없다 — `aftman.toml`은 rojo/wally뿐이고 `pesde.toml`은
`build_files = ["src"]`로 **원본 `.luau`를 그대로 배포**한다.
`git log -S` 기준 도입 커밋은 `847b769 (2026-04-16)`, HEAD가 `2026-05-05`이므로
**최소 3주 이상 방치**. 참고로 Blink 벤치마크 하네스도 `modes/init.luau`에서
`DISABLED_MODES = { warp = true }`로 Warp를 꺼놨다.

**ByteNet master(요구 모듈 3개 부재) + Warp master(구문 오류) — Gen 2 런타임 스키마 진영의
상위 2개가 동시에 깨진 채로 있다.** §7의 "Gen 1이 죽은 원인은 성능이 아니라 유지보수"가
Gen 2에서 재현되는 중이다. **이게 netweave의 실제 기회다.**

### K. Warp의 레이트 리밋 — "바이트 회계 전무" 정정 + 반면교사

§3-G6에서 "바이트 회계는 아무도 안 한다"고 썼는데 Warp는 한다. 다만 **틀리게** 한다
(`Server/init.luau:196-200`):

```lua
local bytes = (player_bytes[player] or 0) + math.max(buffer.len(b), 800)
if bytes > 8e3 then return end   -- 조용히 폐기, 에러도 로그도 없음
player_bytes[player] = bytes
```

세 가지 문제:
1. `math.max(len, 800)` — **1바이트 패킷도 800으로 계산**된다. 실질적으로 "플러시 창당 10패킷"
   고정 상한이고 바이트 회계가 아니다.
2. 카운터 리셋(`player_bytes[player] = 0`)이 **송신 루프 안**에 있고, 그 루프는
   `if #content == 0 then continue`로 시작한다 → **서버가 그 플레이어에게 보낼 게 없으면
   리셋이 영원히 안 된다.** 클라가 10패킷 보낸 뒤 조용히 블랙홀.
3. `if not RunService:IsStudio()` 로 감싸서 **Studio에서는 아예 안 돈다** → 테스트에서 절대 안 잡힘.

**→ G6 정정: "바이트 회계 전무" → "시도는 있으나 계측이 아니라 조잡한 패킷 카운터이고,
리셋 경로 결함으로 오탐한다."** netweave의 요구사항이 더 뾰족해진다:
실제 `buffer.len` 누적, 시간 기준 윈도우(플러시 이벤트가 아니라), 폐기 시 관측 가능한 신호,
**Studio 포함 항상 동작**.

### L. Blink 벤치마크 하네스 — M0에 그대로 포크한다

`blink/benchmark/`는 blink/zap/bytenet/roblox 순정을 **동일 조건에서 붙이는 완성된 하네스**다
(`run-in-roblox` + lune). 방법론에서 배울 점:

- 지표가 **직렬화 마이크로벤치가 아니라 `Stats.DataSendKbps` + 실측 프레임레이트**다.
  실제로 중요한 두 축을 직접 잰다.
- **대역폭을 프레임레이트로 정규화**한다: `Stats.DataSendKbps * (60 / Frames)`.
  안 그러면 **FPS를 떨어뜨린 라이브러리가 대역폭을 적게 쓴 것처럼 보인다.** 중요한 보정.
- 도구 전환 사이에 `while Stats.DataSendKbps > 0.5 do Heartbeat:Wait() end` + `task.wait(5)`.
- `Camera.FieldOfView = 1` + CoreGui 전체 비활성화로 렌더 비용 제거.
- 서버에서 `CompareValues`로 **정확성 검증**과 **수신 카운트**를 같이 재서
  `1 - Recieve/Sent` = 유실률이 나온다.
- 부하는 `PostSimulation`마다 1000회 발사 × 10초. 60Hz 권고를 의도적으로 짓밟는 포화 테스트.

한계(=우리가 보강할 것): **클라→서버 단방향만** 잰다. 서버→클라, FireAll, 플레이어 N 스케일링,
**패킷당 할당 횟수**(`collectgarbage("count")` 델타)가 없다.

**→ M0 = 이 하네스 포크 + `netweave` 모드 추가 + 위 4개 축 보강.** 처음부터 짜지 않는다.

### M. 이번 라운드 정정 요약

| 이전 판단 | 소스 확인 후 |
|---|---|
| §3.6-B7 "전역 쓰기 상태는 ByteNet의 안티패턴, netweave는 명시 전달" | **정정.** Blink·Zap도 전역 + `Save/Load` 스왑. 성능상 의도된 표준. netweave도 채택하되 read/write 양방향 통일 |
| §3-G6 "바이트 회계 전무" | **정정.** Warp에 있으나 800B 하한 + 리셋 경로 결함 + Studio 제외로 사실상 오작동 (§3.7-K) |
| "코드젠 우위 = 타입 분기 제거" | **불완전.** 진짜 성분은 **할당 병합 + 상수 오프셋**(§3.7-D). 런타임에서도 부분 회수 가능. **M1에서 재정정: 인코드에 한정된다** — 같은 페이로드·같은 런에서 디코드는 런타임 스키마가 이긴다(§3.10-BB) |
| "Gen 3는 성숙해서 빈틈이 적다" | **정정.** 908B 무방비(F), 호출 타임아웃 부재·256 상한(G), Blink 수신 큐 무한 증가(H) |
| "Warp = 살아있는 Gen 2 대안" | **정정.** master 구문 오류로 로드 불가(J). Blink 벤치에서도 비활성 |
| "M0 하네스를 직접 짠다" | **정정.** Blink `benchmark/`를 포크한다(L) |

## 3.8 Zap `irgen` 해부 — 바이트 챔피언과 CPU 챔피언은 다른 라이브러리다

> `zap/zap/src/irgen/{mod,ser,des}.rs` (2,065 LOC Rust) + `output/luau/mod.rs` 정독.
> Rust 툴체인이 없어 직접 빌드는 못 했으므로 **Zap 쪽은 IR 코드 리딩 기반**이고,
> Blink 쪽은 `lune`으로 **실제 생성 출력을 뽑아 대조**했다
> (`_refsrc/_generated/`). 추정과 실측을 섞지 않기 위해 아래에 구분해 둔다.

### N. Zap의 IR 구조

`irgen`은 Luau 문자열을 직접 뱉지 않고 **작은 IR을 거친다**:

- `Stmt` = `Local / LocalTuple / Assign / Error / Assert / Call / NumFor / GenFor / If / ElseIf / Else / End`
- `Expr` = 리터럴 + `Call` + `Table` + Roblox 타입(`Color3` / `Vector3` / `Vector`) + 연산자
- `Var` = `Name` / `NameIndex`(`a.b`) / `ExprIndex`(`a[b]`)
- `Gen` 트레이트가 `push_writeu8` / `readu16` 같은 **프리미티브 헬퍼**를 제공하고,
  `ser.rs`(`impl Gen for Ser`)와 `des.rs`(`impl Gen for Des`)가 이를 공유한다.

`output/luau/mod.rs`가 `Stmt`를 Luau 텍스트로 찍는다. **IR은 최적화 패스가 아니라 공유 어휘다** —
아래 O에서 보듯 Zap에는 할당 병합 패스가 없다.

**→ netweave 시사점:** IDL이 없어도 이 분해는 유효하다. "타입 → 연산 시퀀스"를 값으로 만들어
두면 정의 시점에 **크기 계산·병합·비트 배치**를 값 위에서 돌릴 수 있다. ByteNet처럼
곧바로 클로저를 만들어버리면 그 최적화 창이 닫힌다. **M1은 "스키마 → IR → 클로저" 2단계로 간다.**

### O. Zap은 할당을 병합하지 않는다 — 두 챔피언의 최적화가 정확히 엇갈린다

`Gen::push_writeu8` 등이 예외 없이 이렇게 찍는다:

```rust
fn push_writeu8(&mut self, expr: Expr) {
    self.push_alloc(1.0.into());                       // alloc(1)
    self.push_stmt(Stmt::Call(buffer.writeu8, ...));   // buffer.writeu8(outgoing_buff, outgoing_apos, v)
}
```

즉 **필드마다 `alloc(n)` 호출 1회**다. `outgoing_apos`(직전 alloc이 남긴 전역 위치)를 바로
읽어 쓰는 구조라 병합할 자리가 없다. `OutputBuffer(Rc<RefCell<Vec<OutputEntry>>>)`가
"나중에 앞쪽에 끼워넣기"를 지원하지만 그 용도는 P의 비트팩 슬롯 예약이지 할당 병합이 아니다.

정리하면 두 코드젠 챔피언의 최적화가 **서로 반대**다:

| | Blink 0.18.8 | Zap 0.6.29 |
|---|---|---|
| 할당 병합 | **있음** (블록당 `Allocate(N)` 1회, 최상위는 상수 오프셋) | **없음** (필드당 `alloc(n)`) |
| bool 인코딩 | `boolean`은 **1바이트**, 명시적 `set` 타입이면 **1비트**(§3.9-AA) | **1비트** (자동 비트팩) |
| optional 존재 플래그 | **1바이트** (`set`도 못 흡수) | **1비트** (같은 비트팩에 합류) |
| 작은 enum 태그 | 별도 정수 | 남는 비트에 합류 / 변형 1개면 **0비트** |
| 배열 길이 타입 | 상한만 보고 `u8/u16/u32` | **범위 오프셋까지** (`u8[10..20]` → `len - 10`) |
| 명명 타입 참조 | **인라인 전개** | **인라인 전개** (재귀 타입만 공유 함수 — §3.9-W 정정) |
| 고정 길이 배열 | 루프 (러닝 커서, `Read(N*len)` 1회) | **완전 언롤** + 비트팩 이월 — 코드 크기 4.5배(§3.9-X) |

**"Blink가 CPU, Zap이 바이트"** — 이게 §3.5에서 그린 2차원 지도의 오른쪽 위 구석이
실은 **코드젠 진영 안에서도 비어 있다**는 뜻이다. 둘 다 하는 건 아무도 안 했다.

### P. 비트패킹 — Zap이 가진 진짜 바이트 우위

`irgen/mod.rs`의 `get_bitpack()` / `Scope::bitpack_budget` / `ser.rs::end_scope()`:

1. 스코프 진입 시 `OutputBuffer`(=삽입 지점)를 잡아둔다(`new_scope`).
2. bool·optional 존재 플래그·작은 enum 태그를 만날 때마다 `get_bitpack()`이
   현재 누산기의 다음 비트를 배정한다. 값 쓰기는 `bit32.bor(acc, 1<<n)` **로컬 변수 연산**이다.
3. 누산기가 `BitpackMask::BITS`(= `u16`, 16비트)를 채우면 새 누산기를 push.
4. `end_scope()`에서 **거꾸로 스코프 맨 앞에** `local acc = 0` 과
   `local acc_pos = alloc(size)` 를 끼워넣고, 스코프 끝에서
   `buffer.write{numty}(outgoing_buff, acc_pos, acc)` 를 찍는다.
   `numty`는 **실제로 쓴 비트 수**로 결정된다(`NumTy::from_f64(0, 2^(shift+1) - 1)` → ≤8비트면 `u8`).

즉 **"슬롯 예약 → 로컬에 누적 → 마지막에 백필"** 패턴. 디코드는 `bit32.btest(acc, mask)`.

`variant_storage()`는 한술 더 뜬다 — 변형이 **1개면 0비트**, 2개면 **1비트**,
남은 비트 예산 안에 들어가면 **비트팩**, 아니면 그때만 정수 태그.

실측 대조 (Blink는 생성 출력 확인, Zap은 IR에서 계산):

| 스키마 | Blink (실측) | Zap (IR 계산) |
|---|---|---|
| `boolean[8]` | **8 B** | **1 B** (u8 누산기 1개) |
| `struct { a: bool, b: bool, c: u8?, d: bool }` | **4 B** (+c 있으면 5 B) | **1 B** (4비트) + c 있으면 2 B |
| `boolean[17]` | 17 B | 3 B (u16 + u8) |

**한계도 명확하다.** 가변 길이 배열은 원소마다 `new_scope()`를 하므로 **비트팩이 원소 경계에서
초기화된다** — `bool[]` 동적 배열은 Zap도 원소당 1바이트다. 이득은 **struct 필드와
고정 길이 배열**에서만 나온다.

**→ netweave: 비트팩은 반드시 넣는다.** 런타임 스키마에서도 가능하다. 정의 시점에 스키마를
훑어 "이 노드 그룹의 불리언/옵셔널 플래그 개수"를 세고, 슬롯 예약 + 백필을 하는 write
클로저를 합성하면 된다. §3.7-D의 고정 크기 프리픽스 계산과 **같은 사전 패스에서 같이 처리**된다.
그리고 Zap이 못 한 것 — **동적 배열의 원소 간 비트팩 이월** — 은 우리가 가져갈 수 있는 자리다.

### Q. 검증 비대칭 — 이건 둘 다 제대로 한다

`des::generate(...)` 호출부는 전부 `checks` 인자에 **리터럴 `true`** 를 넘긴다
(`output/luau/server.rs:178`, `:401` 등). 반면 `ser::generate(...)` 는
`self.config.write_checks`(기본 `true`, 사용자가 끌 수 있음)를 넘긴다.

**들어오는 데이터의 검증은 끌 수 없고, 나가는 데이터의 검증만 끌 수 있다.** 올바른 비대칭이다.
Blink도 동일하다 — `WriteValidations` 플래그는 쓰기 쪽에만 걸리고
`GenerateValidation(Read, ...)` 는 무조건 실행된다. netweave도 이 규칙 그대로.

### R. 그런데 검증 실패가 배치 전체를 죽인다 [검증]

Zap의 검증은 `Stmt::Assert` → `assert(cond, "value is more than 255!")` 로 찍힌다
(`output/luau/mod.rs:50`). 그리고 수신 핸들러에는 **`pcall`이 없다**
[검증: `grep -n "pcall" zap/zap/src/output/luau/server.rs` → 0건]:

```lua
reliable.OnServerEvent:Connect(function(player, buff, inst)
	incoming_buff = buff; incoming_read = 0
	local len = buffer.len(buff)
	while incoming_read < len do       -- 배치 디멀티플렉싱 루프
		local id = buffer.readu8(buff, read(1))
		... assert(...) ...             -- 여기서 실패하면
	end                                 -- 루프 전체가 중단된다
end)
```

**배칭 + assert 기반 검증 + 격리 없음** = 악의적 클라이언트가 한 프레임 배치의 **두 번째 패킷만
망가뜨리면 그 뒤 패킷 전부가 처리되지 않는다.** 게다가 `incoming_read`가 전역이라 다음
이벤트 처리 시작까지 오염된 상태로 남는다. 훅도 없어서 서버 로그에 원시 Luau 에러만 남고
**어느 플레이어인지도 자동으로는 안 붙는다.**

Blink는 `pcall`을 **Invoke 반환 경로에만** 쓴다(`Generator/init.luau:686, 717`).
이벤트 역직렬화 경로는 Zap과 동일하게 무보호다.

대조 — Flamework는 인자별 가드가 실패하면 그 호출 하나만 건너뛰고
`onBadRequest(player, { networkInfo, argIndex, argValue })` 를 발화한다(§3.6-A).
**§3.7-G에 이어 "구조 축과 바이트 축이 정확히 반대로 실패한다"는 두 번째 증거.**

**→ netweave 필수 요건 (M2/M3):** 배치 디멀티플렉싱 루프에서 **패킷 경계마다 커서를 복구
가능하게** 유지하고, 역직렬화 실패는 (a) 그 패킷만 폐기, (b) `onBadRequest` 계열 훅 발화,
(c) 커서를 다음 패킷 시작으로 스킵 — 이를 위해 **패킷 헤더에 길이 필드**가 필요하다.
Blink/Zap은 길이 필드가 없어서 애초에 스킵이 불가능하다. 이건 와이어 포맷 설계 결정이므로
M2가 아니라 **M1 와이어 포맷 확정 시점에 못 박아야 한다.**

### S. 양쪽 다 놓친 것 — 디코드 시 테이블 리해시

Blink 실측:

```lua
local Value = {} :: any
Value.a = ...   -- 해시 파트 0 → 1 → 2 → 4 로 재할당
Value.b = ...
Value.c = ...
Value.d = ...
```

Zap도 동일하다 — `des.rs:466` `Ty::Struct` → `push_assign(into, Expr::Table(Default::default()))`
(= `{}`) 후 필드별 대입.

빈 테이블 `{}`은 해시 파트가 0칸이라 **키를 넣을 때마다 1→2→4→8로 리해시**한다.
6필드 struct 100개짜리 배열이면 **원소당 3~4회 재할당 × 100**.

Luau에는 해시 파트 크기를 직접 예약하는 API가 없지만 **`table.clone(TEMPLATE)`** 이 있다.
스키마별로 모든 키를 가진 템플릿 테이블을 정의 시점에 한 번 만들어두고
`local Value = table.clone(TEMPLATE)` 로 시작하면 해시 파트가 처음부터 정확한 크기로 잡힌다.
**런타임 스키마 라이브러리가 코드젠보다 유리한 드문 지점이다** — 템플릿을 클로저에 캡처해두면 되고,
코드젠은 템플릿을 모듈 상수로 따로 뽑아야 해서 잘 안 한다.

배열도: Blink는 `table.create(Length)` 후 **`table.insert`** (호출마다 길이 조회),
Zap 고정 배열은 `table.create(len)` 후 **`into[i] = v`** — 여기선 Zap이 맞다.

**→ M0 벤치에 "역직렬화 시 테이블 할당 횟수"를 별도 축으로 넣는다. §3.7-L에서 보강하기로 한
"패킷당 할당수"가 실제로 여기서 가장 크게 벌어질 가능성이 높다.**

### T. 명명 타입: 코드젠은 둘 다 인라인한다 [검증] (§3.9-W에서 재정정)

동일 struct를 이벤트 2개에서 재사용하는 스키마를 Blink로 실제 생성해봤다
(`_refsrc/_generated/_gen_blink_reuse.luau`):

```
function SerdesFunctions.ReadEVENT_A(): ({ id: number, ... })   -- Entity 필드 전개
function SerdesFunctions.ReadEVENT_B(): ({ id: number, ... })   -- 같은 코드 또 전개
```

**Blink는 명명 타입을 참조할 때마다 통째로 인라인한다.** 이벤트 3개짜리 최소 스키마가
11,113바이트. 호출 1회를 아끼는 대신 **스키마가 커질수록 생성 파일이 제곱으로 부푼다.**

~~Zap은 `Ty::Ref(name)` → `types.write_{name}()` 공유 함수라 코드 크기가 선형이다~~
→ **§3.9-W에서 정정. 틀렸다.** `parser/convert.rs:729`가 `inline: recursion_type == TyRecursionKind::None`
이라 **재귀 타입이 아니면 Zap도 전부 인라인한다.** 실측에서 `local types = {}` 는 끝까지 비어 있었다.
게다가 Zap은 고정 길이 배열까지 완전 언롤해서 `Entity[100]` 하나로 서버 출력이 **45,635바이트**다(§3.9-X).

netweave는 런타임이라 이 축에서 **자동으로 유리하다** — 타입은 값이므로 참조가 곧 공유다.
코드 크기 폭발이 없고, 대신 클로저 호출 비용을 낸다. **코드젠 진영 전체가 이 문제를 갖는다.**
**"스키마가 커져도 클라이언트 스크립트 용량이 안 늘어난다"는 §4에 넣을 만한 판매 포인트다.**

### U. 이번 라운드 추가 정정

| 이전 판단 | 소스 확인 후 |
|---|---|
| §3.7-D "Blink는 필드를 컴파일 타임 상수 오프셋으로 쓴다" | **부분 정정.** 상수 오프셋 폴딩은 **최상위 블록에서만**. 루프 안은 필드마다 `local` + `+=` 러닝 커서 (생성 출력 실측). alloc/read 호출 병합 자체는 전 구간 유효 |
| "Zap도 Blink와 비슷한 최적화를 할 것" | **정정.** Zap은 **할당 병합을 아예 안 한다**(필드당 `alloc`). 대신 **비트패킹**이 있고 Blink엔 없다. 최적화가 정확히 엇갈림(§3.8-O) |
| "Gen 3는 바이트를 짜낼 만큼 짜냈다" | **정정.** Blink는 `boolean` 필드를 **바이트당 1개**로 낭비한다. `boolean[8]`에서 8배 차이(§3.8-P). 단 §3.9-AA에서 재정정 — 명시적 `set` 타입을 쓰면 워드당 32비트로 압축된다. **자동이 아닐 뿐** |
| "코드젠은 검증도 잘 돼 있다" | **불완전.** 검증 비대칭은 맞지만(Q) **격리가 없어 실패 시 배치 전체가 죽는다**(R). 와이어에 길이 필드가 없어 복구 자체가 불가능 |

## 3.9 Zap 실제 빌드·생성 검증 — §3.8 추정치 대조

> Rust GNU 1.98.0 설치(`winget install Rustlang.Rust.GNU` — MSVC 빌드툴 없이 자체 링커 포함) 후
> `cargo build --release -p cli` → `zap.exe 0.6.29`. §3.8은 IR 코드 리딩 기반 **추정**이었고,
> 여기부터는 **실측**이다. §3.7-D의 Blink 샘플과 **완전히 동일한 스키마**로 뽑아 1:1 대조했다.
> 산출물: `_refsrc/_generated/zap/{a,b,bp}.zap` + `out_*.luau`.

### V. 추정이 맞은 것 (전부 실측 확인)

**V1. 필드마다 `alloc(1)` — 할당 병합 없음** (`out_b_client.luau`, `Entity` 7바이트 페이로드):

```lua
alloc(1)  buffer.writeu8(outgoing_buff, outgoing_apos, 0)              -- 이벤트 id
alloc(1)  buffer.writeu8(outgoing_buff, outgoing_apos, Value["id"])
alloc(1)  buffer.writeu8(outgoing_buff, outgoing_apos, Value["x"])
... 총 alloc 7회 ...
```

Blink 같으면 `local BLOCK = Allocate(7)` 1회 + 상수 오프셋 7개. **§3.8-O 확정.**

**V2. 비트팩은 "슬롯 예약 → 로컬 누적 → 백필"** — 예측한 그대로:

```lua
local bool_1 = 0
local bool_1_pos_1 = alloc(1)          -- 슬롯 예약 (스코프 맨 앞)
if Value["a"] then bool_1 = bit32.bor(bool_1, 0b0000000000000001) end
if Value["b"] then bool_1 = bit32.bor(bool_1, 0b0000000000000010) end
if Value["c"] ~= nil then
    bool_1 = bit32.bor(bool_1, 0b0000000000000100)
    alloc(1)  buffer.writeu8(outgoing_buff, outgoing_apos, Value["c"])
end
if Value["d"] then bool_1 = bit32.bor(bool_1, 0b0000000000001000) end
buffer.writeu8(outgoing_buff, bool_1_pos_1, bool_1)   -- 백필
```

디코드는 `bit32.btest(bool_1, 0b...)`.

**V3~V7. 바이트 수 — 예측과 실측이 전부 일치**

| 스키마 | Blink (실측) | Zap 예측 | **Zap 실측** |
|---|---|---|---|
| `boolean[8]` | 8 B | 1 B | **1 B** (`readu8` 1회 + `btest` 8회) |
| `struct { a,b: bool, c: u8?, d: bool }` | 4 B (+c 1 B) | 1 B (+1) | **1 B (+1)** |
| `boolean?[17]` | 34 B 추정 | — | **5 B** (u16+u16+u8, 원소당 존재 1비트 + 값 1비트) |
| `bool[14]` + `enum{hello,world}` | 15 B 추정 | — | **2 B** (2변형 enum = **1비트**, 같은 u16에 합류) |
| `bool[14]` + `enum{hello,there,world}` | 15 B 추정 | — | **3 B** (남은 예산 2비트 < 3변형 → 별도 `u8` 태그) |

마지막 두 줄이 `variant_storage()`의 분기(`amount == 2` → `Bit`,
`remaining_bitpack_budget() >= amount` → `Bitpack`, 아니면 `Full`)를 정확히 재현한다.
**`bool[14] + 2변형 enum`이 2바이트**라는 건 Blink 대비 7.5배다.

**V8. 디코드 리해시 확인** — `value = {  }` 후 키 대입. §3.8-S 근거 확정.
단, 태그드 enum만은 생성자를 쓴다: `value = { ["type"] = "a" }`. **일관성이 없다.**

**V9. 알 수 없는 id는 배치를 죽인다** — 디멀티플렉싱 `if/elseif` 사슬의 마지막이
`else error("Unknown event id") end`. `pcall` 없음. **§3.8-R 확정.**

### W. §3.8-T 정정 — Zap도 명명 타입을 인라인한다

§3.8-T에서 "Zap은 `types.write_X()` 공유 함수를 쓴다"고 썼는데 **틀렸다.**
`parser/convert.rs:729`:

```rust
inline: recursion_type == TyRecursionKind::None,
```

**재귀 타입이 아니면 전부 인라인 치환된다.** `Ty::Ref` → `types.read_X` 경로는
**재귀 타입에만** 발생한다. 실측: `type Entity`를 이벤트 2개가 참조하는 `b.zap` 출력에서
`local types = {}` 는 **끝까지 비어 있고**, 이벤트 A와 B가 각각 6필드를 그대로 전개한다.

**→ Blink와 Zap 둘 다 인라인한다.** §4에 적은 "런타임 스키마는 코드 크기가 안 늘어난다"는
장점은 **그대로 유효하고, 오히려 더 강해진다** (한쪽이 아니라 코드젠 진영 전체가 이 문제를 갖는다).

### X. 새 발견 — Zap은 고정 길이 배열을 완전히 언롤한다

`Entity[100]` (= 600바이트 페이로드) 생성 결과:

```lua
value = table.create(100)
value[1] = {  }
value[1]["id"] = buffer.readu8(incoming_buff, read(1))
value[1]["x"]  = buffer.readu8(incoming_buff, read(1))
... (6필드) ...
value[2] = {  }
... 100번 반복 ...
```

**`read(1)` 호출 600개, 테이블 생성자 100개가 소스에 그대로 박힌다.**

| 동일 스키마 서버 출력 크기 | Blink 0.18.8 | Zap 0.6.29 |
|---|---|---|
| `Entity[100]` + `boolean[8]` | **10,067 B** | **45,635 B** (4.5배) |
| `Entity` × 2 이벤트 + 소형 struct | 11,113 B | **8,084 B** |

배열에서는 **Blink가 코드 크기·호출 횟수 양쪽 다 이긴다** (`Read(6*100)` 1회 + 루프).
Zap의 우위는 **비트팩 가능한 필드에 한정**된다.

§3.8-O 표를 이렇게 고친다:

| | Blink 0.18.8 | Zap 0.6.29 |
|---|---|---|
| 할당 병합 | **있음** | 없음 (필드당 `alloc`) — **실측 확인** |
| bool / optional 플래그 / 소형 enum | `boolean`은 각 1바이트, **`set` 타입은 워드당 32비트**(§3.9-AA) | **전부 자동 비트팩**, 누산기 16비트 — **실측 확인** |
| 고정 길이 배열 | 루프 (`Read(N*len)` 1회) | **완전 언롤** — 코드 크기 4.5배 |
| 명명 타입 참조 | 인라인 | **인라인** (재귀 타입만 공유 함수) — **§3.8-T 정정** |
| 디코드 테이블 | `{}` + 키 대입 | `{}` + 키 대입 (태그드 enum만 생성자) |
| 배열 원소 대입 | `table.insert` | `value[i] =` (이쪽이 맞다) |

### Y. Zap이 놓친 미세 손실 하나

태그드 enum `enum "type" { a { value: boolean }, b { value: boolean } }` 실측:

```lua
local bool_1 = buffer.readu8(incoming_buff, read(1))
if bit32.btest(bool_1, 0b0000000000000001) then
    value = { ["type"] = "a" }
    value["value"] = bit32.btest(bool_1, 0b0000000000000010)   -- 비트 1
else
    value = { ["type"] = "b" }
    value["value"] = bit32.btest(bool_1, 0b0000000000000100)   -- 비트 2
end
```

변형 a와 b는 **동시에 존재할 수 없는데도 서로 다른 비트를 먹는다.** 비트 예산이
분기별로 합산되므로 변형이 많은 태그드 enum은 예산을 빠르게 소진한다.
**netweave는 분기별로 비트 예산을 포크해서 최댓값만 쓰면 된다** — 작지만 확실한 개선점.

### Z. 이번 검증이 계획에 미치는 영향

1. **§3.8의 IR 기반 추정은 바이트 수치에서 전부 맞았다.** 이후 Zap 관련 판단은 실측 근거로 승격.
2. **§3.8-T만 틀렸고, 정정 방향이 netweave에 유리하다** — 코드 크기 문제는 Blink만이 아니라
   **코드젠 진영 공통**이다. §4 판매 포인트를 그대로 두되 근거를 "Blink" → "코드젠 전반"으로 확대.
3. **M0 벤치 스키마를 두 종류로 나눈다.** 배열 위주 스키마(Blink 유리)와
   플래그 위주 스키마(Zap 유리)에서 승자가 뒤집히므로, 하나로 뭉뚱그리면 아무 결론도 안 나온다.
   §6의 "바이트 ≤ Zap 1.0x / CPU ≤ Blink 1.3x"도 **스키마 종류별로** 판정한다.
4. **netweave의 목표가 구체화됐다**: 배열은 Blink식 병합 루프, 플래그는 Zap식 비트팩,
   둘 다 **런타임 스키마라 코드 크기 증가 없이**. 그리고 Zap이 못 한 두 가지 —
   동적 배열 원소 간 비트팩 이월(§3.8-P), 태그드 enum 분기별 비트 예산 포크(Y) — 이 추가 여지다.
5. **재현 가능**: `_refsrc/_generated/zap/` 에 `.zap` 입력과 생성 출력이 같이 있다.
   `zap.exe <file>.zap` 로 재생성된다.

### AA. 다시 정정 — Blink에는 `set` 비트필드 타입이 있다 [검증]

M0 스키마를 짜다가 Blink 문법 예제(`test/Sources/Test.blink`)에서 발견했다.
§3.8-O와 §3.9-X 표에 "Blink는 비트패킹 없음"이라고 썼는데 **정확하지 않다.**

Blink에는 `set` 선언이 있고, `Generator/init.luau:140-175`가 이를 **비트필드로 생성한다** —
`GetTypeToUseByBits(Partition)`로 플래그 수에 맞는 정수 타입을 고르고 `bit32.btest`로 읽는다.
**워드당 32개**까지 묶는다(`math.min(Remaining, 32)`). Zap의 누산기는 `BitpackMask = u16`,
즉 **16비트**가 상한이므로 이 축만 보면 Blink 쪽이 더 넓다.

동일 의미의 페이로드(플래그 12개 + 4변형 enum + 2변형 enum + `u16?` + `u8?`)를
세 가지로 실제 생성해 비교했다:

| 작성 방식 | 실측 크기 |
|---|---|
| Blink, `boolean` 필드 12개 (순진하게) | **19 B** (블록 16 B + 옵셔널 값 3 B) |
| Blink, `set Flags12 = {...}` 사용 | **9 B** (블록 6 B + 옵셔널 값 3 B) |
| Zap, `boolean` 필드 12개 (자동) | **6 B** (`readu16` + `readu8` = 3 B + 옵셔널 값 3 B) |

산출물: `_refsrc/_generated/_gen_blink_flags.luau`, `_refsrc/_generated/zap/out_flags_server.luau`.

**정확한 진술은 이렇다:**

- Blink: **자동 비트패킹은 없다.** `boolean` 필드는 필드당 1바이트다. 대신 **명시적 `set` 타입**이
  있어서 작성자가 플래그를 묶어주면 워드당 32개까지 압축된다.
- Zap: **자동이다.** 작성자가 아무것도 안 해도 `boolean`, **옵셔널 존재 플래그**,
  **작은 enum 태그**가 전부 같은 누산기로 들어간다(§3.9-V3). 누산기는 16비트 단위.
- 격차의 실체는 **"압축 능력"이 아니라 "작성자가 알아야 하느냐"** 다. Blink는 `set`을 알고 쓰는
  사람만 9 B를 얻고, 모르면 19 B를 낸다. Zap은 몰라도 6 B다.
  그리고 `set`은 옵셔널 존재 플래그와 enum 태그는 **못 흡수한다** — 위 표에서 남은 9 B vs 6 B 차이가 그것이다.

**→ netweave 요구사항 (M1):** 자동 비트패킹을 기본값으로 하되(Zap 쪽), 누산기를
**32비트까지** 넓힌다(Blink `set` 쪽). 둘 다 취하면 위 페이로드에서 두 라이브러리보다 작아진다.

**→ M0 벤치 요구사항:** FlagHeavy 스키마를 **각 라이브러리에서 작성자가 실제로 쓸 방식대로**
작성해야 공정하다. Blink는 `set`을 쓴 버전이 정본이고, 순진한 `boolean` 12개 버전은
**"모르고 쓰면 어떻게 되는지"의 참고치**로 같이 싣는다. 한쪽만 실으면 어느 쪽으로든 왜곡이다.

---

## 3.10 M1 실측 — 코드젠 격차는 방향으로 갈린다 [실측]

M1 phase 6에서 netweave를 M0 하네스에 넣고 5모드 매트릭스를 다시 돌렸다
(`bench/runs/2026-09-04.json`, `bench/RESULTS.md`). 여기까지의 추정 중 하나가 틀렸고, 하나는
정확히 맞았다.

### BB. §3.7-D 정정 — "할당 병합 = 코드젠 우위"는 **인코드에 한정**된다

§3.7-D는 코드젠의 CPU 우위를 **할당 병합**으로 설명했고, M0(§3.9-Z, 881행)는 그것이
`ArrayHeavy` 한 셀에서만 나타난다고 좁혔다. M1은 그 셀을 **방향별로** 쪼개서 다시 쟀다.

`ArrayHeavy` 601 B, 프레임당 200패킷, p50 프레임레이트:

| 방향 | netweave | Blink | Zap | ByteNet |
|---|---|---|---|---|
| Up — 클라가 **인코드** | 85 | **139** | 116 | 120 |
| Down — 클라가 **디코드** | **80** | 71 | 70 | 55 |

**같은 페이로드, 같은 런에서 인코드는 코드젠이 이기고 디코드는 런타임 스키마가 이긴다.**
§3.7-D의 주장은 폐기가 아니라 **인코드로 범위를 좁혀야** 한다. 디코드 쪽 우위는 §3.8-S가
예측한 `table.clone(TEMPLATE)`이고, 할당량이 아니라 프레임레이트로 측정된 건 이번이 처음이다.

스키마 계열별 격차 (netweave ÷ Blink·Zap 중 우수한 쪽):

| | 인코드 | 디코드 |
|---|---|---|
| `ArrayHeavy` | **0.61x (-39%)** | 1.13x (+13%) |
| `FlagIdiomatic` | 1.00x | 0.96x |
| `FlagNaive` | 1.03x | 0.88x |

**여섯 칸 중 노이즈를 벗어나는 건 하나뿐이다.** 코드 변경 없이 하루 간격 두 런 사이에서
같은 라이브러리가 최대 10% 움직인다 — Blink `FlagNaive` 인코드 211→232, Zap `ArrayHeavy`
인코드 125→116. 즉 실제로 말할 수 있는 건 **"배열 인코드에서 39% 뒤진다"** 하나고, 나머지는
구별되지 않는다.

**§6 성공 판정 기준 "배열 위주 CPU ≤ Blink 1.3x"는 현재 1.64x로 미달이다.** 원인 하나는
식별됐다 — 벤치 어댑터의 대역 트랜스포트가 send마다 `Buffer.save()`를 두 번 불러 페이로드
크기와 무관하게 테이블 두 개를 할당했고, 인코드 할당이 세 스키마 전부 609.3 B로 평평하게
찍혔다. 페이로드 크기에 따라 변하지 않는 수치는 페이로드를 재고 있는 게 아니다. 고쳤고
재측정은 남아 있다.

### CC. §3.9-AA·D-3 확인 — 바이트는 예측한 자리에 정확히 떨어졌다

| 스키마 | netweave | Blink | Zap | ByteNet |
|---|---|---|---|---|
| `ArrayHeavy` | **601** | **601** | **601** | 603 |
| `FlagIdiomatic` | 8 | 10 | **7** | 20 |
| `FlagNaive` | 8 | 20 | **7** | 20 |

- **`ArrayHeavy`는 이론적 바닥에서 3사 동률.** 데이터 600 + 채널 id 1. static 스키마는 길이
  프리픽스가 필요 없으므로 **§3.8-R의 프레이밍 보장이 이 계열에선 공짜**다.
- **플래그에서 Zap보다 1바이트 뒤지고, 그 1바이트가 곧 프레이밍이다.** `WIRE-FORMAT.md` §2가
  종이 위에서 계산한 8 B 대 7 B가 그대로 나왔다. §3.9-AA의 "Zap에게서 뺏을 바이트는 없다"가
  확인됐다.
- **두 플래그 열이 자동 패킹의 증명이다.** netweave와 Zap은 양쪽에서 같은 값을 내고, Blink는
  *같은 스키마*를 저자가 `set`을 아느냐에 따라 10 B 또는 20 B로 보낸다. §3.9-AA가 지적한
  "Blink의 우위는 저자에게 달려 있다"가 수치로 재현됐다.

### DD. M0의 "작은 페이로드에서는 raw가 이긴다"는 약화됐다

M0에서 raw는 두 플래그 계열 모두에서 세 라이브러리를 앞섰다. 이번 런에서는
`FlagIdiomatic` 233 대 ByteNet 234로 **무승부**, `FlagNaive`에서는 208로 **꼴찌**다.
교차점이 존재한다는 것 자체는 여전하지만, 한 번의 런으로 규칙처럼 서술한 것은 과했다.

## 3.11 M4 phase 7 실측 — 코드젠 우위의 정체는 **빌트인 이름을 쓸 수 있다는 것**이다 [실측]

`bench/profile.luau`, Studio가 아니라 lune. 매트릭스는 M1부터 `ArrayHeavy` 인코드에서 84 대 130을
말해 왔지만 **왜인지는 말할 수 없었다** — 프레임 하나에는 렌더링·피직스·리플리케이션이 같이 들어
있어서 그 안의 코덱 몫을 분리할 방법이 없다. 이 프로브는 같은 페이로드를 프레임 없이 인코드하고,
사다리의 각 칸이 바로 앞 칸과 **한 가지씩만** 다르게 만들어져 있다.

### EE. ~~프레임 격차는 인코드 격차다 — 두 계기가 4% 안에서 만난다~~ → **II에서 반증됨**

프레임당 200패킷에서 코덱이 예측한 차이는 **4.38 ms**, Studio가 잰 프레임 차이는 **4.21 ms**
(84 대 130 FPS). VM이 다르므로 일치는 증명이 아니라 방증이지만, **불일치가 나왔다면 그게 더 쓸모
있는 답이었다** — 코덱 바깥의 무언가가 격차를 내고 있다는 뜻이고, `Serdes`에 쓰는 시간은 전부
엉뚱한 파일에 쓰는 시간이 됐을 것이다.

**그 불일치가 나왔다 (§3.11-II).** 인코드를 1.8 ms 줄이고 프레임은 0 움직였다. 위 문단의 일치는
우연이었고, 아래 귀속표는 **인코드 안에서** 시간이 어디 가는지에 대해서만 유효하다 — 프레임에
대해서는 아무 말도 하지 않는다.

24 µs가 어디로 가는지:

| 층 | ns/패킷 | 비중 |
|---|---|---|
| 코드젠이 하는 일 (`inline`) | 2,096 | 9% |
| 스키마가 약속한 범위·정수 검사 | +2,297 | 10% |
| 값마다 호출 하나 | +7,116 | 30% |
| **값마다 클로저 하나 + 필드를 찾는 구조체 순회** | **+12,483** | **52%** |

6필드 구조체 하나에 **호출 7번**이 바이트 하나 쓰기 전에 든다.

### FF. §3.10-BB 재정정 — M1이 지목한 원인은 M2가 이미 반증했고 아무도 돌아오지 않았다

§3.10-BB와 `bench/RESULTS.md`는 격차의 원인을 **패킷당 `allocate` 600회**로 지목했다. M2 phase 0이
그걸 없앴고(`openBlock` + `put*`), **바로 다음 매트릭스가 85 → 86 FPS를 찍었다.** 예측했고, 고쳤고,
숫자는 안 움직였는데, 그 문단으로 돌아온 사람이 없었다 — 두 마일스톤 동안.

이번에 직접 값을 매겼다: `allocate`-per-value는 **M2 이전 인코드의 45~47%**다. 즉 그 수정은 실제로
가치가 있었지만, 200패킷/프레임에서 11.9 ms 프레임 중 1.6 ms고, **애초에 1.55x를 설명할 수 있는
크기가 아니었다.** 사다리 아래에 나머지가 그대로 남아 있었다.

### GG. 진짜 원인 — `buffer.writeu8`을 **이름으로 부르면** fastcall이다

프로브가 처음 매긴 값은 2.7x였고 첫 구현은 10%를 냈다. 그 차이가 이 절의 발견이다.

**`buffer.writeu8(out, at, value)`를 소스에 그대로 쓰면 Luau가 fastcall로 컴파일해 호출 프레임 없이
인라인 수행한다. 같은 함수를 테이블에서 꺼내 쓰면 평범한 호출이다.** 스키마로 굴러가는 빌더는
`RAW_NUMBER[storage]`를 아무 생각 없이 집는다 — 프로브의 손으로 쓴 칸들은 그러지 않았고, 그래서 2배
낙관적이었다.

`dispatched` 칸이 그 통제군이다. 같은 코드에서 테이블 조회 하나를 빌드 타임에서 런타임으로 옮긴 것
뿐인데 **패킷 전체에서 1.6x** — 인코드의 나머지 모든 층을 합친 것보다 크다.

**그래서 "코드젠이 왜 빠른가"의 답은 클로저 회피가 아니다.** netweave도 클로저를 없앨 수 있고
`Serdes.fusedStructWriter`가 그렇게 한다. 차이는 **생성기는 프리미티브의 이름을 찍어낼 수 있다**는
것이다 — 그리고 검증 가능하다: Blink가 낸 코드는 `bench/vendor/blink/Client.luau:187, 194`에서,
Zap이 낸 코드는 `bench/vendor/zap/Client.luau:1073, 1140`에서 `buffer.writeu8(...)`을 글자 그대로
쓴다. §3.7-D가 "할당 병합"이라고 부른 우위의 절반은 사실 이것이었다.

netweave의 대응은 프리미티브 다섯 개를 **분기 사슬**로 전부 이름 붙여 쓰는 것이다. 스키마는 분기가
되고 호출부는 전부 fastcall이 된다. 23,992 → 12,741 ns/패킷(lune), 38,434 → 29,314(Studio 실측) —
**1.9x와 1.31x.**

~~예측 프레임레이트 84 → 약 101 FPS (Blink 대비 1.28x, §6 기준 1.3x 안쪽).~~

### HH. 진 설계 하나 — 루프를 남기면 언롤이 사는 걸 다 까먹는다

한 번 claim하되 루프는 유지하고 각 필드의 오프셋·경계를 병렬 배열에서 읽는 형태를 먼저 시도했다.
**25,490 ns — 아무것도 안 한 것보다 느리다.** 배열 읽기가 아끼는 호출보다 비싸다. 언롤이 취향
문제가 아닌 이유이고, 프로브에 그대로 남겨 뒀다.

### II. 그리고 그 예측은 틀렸다 — 컴포넌트가 빨라진 것과 프레임이 빨라지는 것은 다른 주장이다

`bench/runs/2026-09-05-m4p7.json`. 같은 장소, 같은 부하, 페이즈 7이 들어간 트리. `ArrayHeavy` Up
**85 FPS, Blink 133 — 1.56x, 안 움직였다.** netweave 자체 스프레드가 84..87이고 대조군은 2~4%
움직였으니 계기 문제도 기계 문제도 아니다.

**그런데 최적화는 Studio에서도 진짜였다.** 같은 세션에서 그 VM으로 직접 쟀다: 코덱 38,434 →
29,314 ns/패킷, 200패킷/프레임이면 11.76 ms 프레임에서 **1.8 ms를 뺀 것**이다. fastcall 발견도 그
VM에서 재현된다(11,042 대 18,186, 1.65x). 즉 **설계 결정은 살아 있고, 프레임 산술만 죽었다.**

프로브는 "코덱 격차가 4.38 ms를 예측하고 Studio가 4.21 ms를 쟀다"는 일치를 방증으로 읽었다.
**우연이었다.** 인코드가 1.8 ms 줄었는데 프레임은 0 움직였으니, 두 숫자가 한 번 맞은 건 모형이
아니다. 프로브 자신의 경고문이 이 경우를 이미 적어 뒀다 — "불일치가 나왔다면 그게 더 쓸모 있는
답이다: 코덱 바깥의 무언가가 격차를 내고 있다는 뜻."

### JJ. ~~프레임은 인코드에 안 묶여 있다~~ — 한 시간 뒤, 없던 계기가 만들어지자 뒤집혔다

II의 결론은 **프레임을 볼 수 없는 계기 두 개**에서 나온 것이었고, 틀렸다. 세 번째 계기
(`Config.FRAME_PROBE` — 같은 place, 같은 부하, 같은 서버에서 send 루프에 시계를 두른다)가 말하는
건 정반대다:

| ArrayHeavy Up | 프레임 | send 루프 | 그 밖 | 서버 |
|---|---|---|---|---|
| idle | 4.31 ms (232) | — | 4.31 | — |
| blink | 7.32 ms (137) | 1.03 (14%) | 6.29 | 137 |
| bytenet | 8.56 ms (117) | 5.43 (64%) | 3.12 | 117 |
| **netweave** | **11.58 ms (86)** | **6.27 (54%)** | **5.30** | 86 |
| raw | 33.38 ms (30) | 18.09 (54%) | 15.28 | 30 |

**격차는 전부 send 루프 안에 있다.** 프레임 격차 4.26 ms에 루프 격차 5.24 ms — 전부이고 남는다.
그리고 6.27 ms ÷ 200 = 31.4 µs는 코덱 단독 29.1 µs + 프레이밍이라, 벤치 채널이 fused 경로를 쓰고
있다는 확인이기도 하다.

**코덱도 그 VM에서 실제로 1.34x 빨라졌다** — 재구성이 아니라 실제 코드로, fused가 루프에게
넘겨주는 arity를 걸어서 쟀다: fused 48.6 ns/값, 루프 64.9 ns/값 → 6필드 루프 38.9 µs, fused
29.1 µs. 처음 38,434라고 했던 손수 만든 재구성이 **1.3% 오차로 충실했다.**

**남은 모순은 하나고, 추론으로는 못 닫는다.** 코덱은 프레임당 1.96 ms 싸졌고 프레임은 0.3 ms
줄었다(대조군 2~5%). 닫는 방법은 이제 존재하는 그 계기를 **`1ce998b`** — 페이즈 7이 적용된 대상
트리 — 에 돌리는 것뿐이다.

**그리고 caveat 없는 발견 하나:** bytenet은 send 루프 5.43 ms(netweave 6.27)인데 **루프 바깥이
3.12 ms 대 5.30 ms**고 30 FPS 빠르다. 바깥에 있는 건 flush와, 한 프로세스니까, **서버의 디코드**다.
디코드는 M2의 블록도 M4의 fused도 못 받았고 보고서가 인코드의 2.5배·손 리더의 4배로 측정해뒀다.
`Buffer.ensure`는 그 용도로 쓰였는데 `src/`에 호출자가 없다.

~~이 셀에서 원인을 지목하고 고치고 안 움직인 게 두 번째다.~~ 정확히는 **고친 것이 프레임에서 보이지
않은 게** 두 번째다(첫 번째는 §3.10-BB의 `allocate` 600회, FF에 취소선). 두 사건이 만드는 규칙은
"마이크로벤치는 거짓말한다"가 아니라 더 좁고 쓸모 있다: **부품 벤치는 그 부품이 프레임의 몇 %를
차지하는지 말해줄 수 없고, 그 비율을 재는 것이 생기기 전까지 최적화의 프레임 효과는 예측이다.**

### KK. 선언하고, 문서화하고, 검사까지 해놓고 **한 번도 읽지 않은 필드** — 그리고 지우는 쪽을 고른 이유

M4 보고서의 [경고] 두 건이 실은 한 뿌리였다. `store.changed`는 `Store` 타입에 선언돼 있고,
`Store.charm`의 `:::caution`이 "이걸 넘기면 아무것도 안 움직인 틱은 분기 하나짜리가 된다"고
약속하고, `nw.replicate`가 선언 시점에 모양까지 검사했는데 — `grep -rn "\.changed" src`가 찾는 건
그 검사뿐이다. **아무도 부르지 않았다.** 그 약속을 믿고 `subscribe`를 넘긴 게임은 피하라고 들었던
그 순회를 그대로 받았다.

**틱 자체가 그 순회였다.** (subject, recipient) 쌍마다 `switchTo` + `pcall` + `Buffer.mark` +
디퍼 전체 + `rollback`을, 아무것도 안 움직였어도. 보고서에 숫자는 있었는데 그걸 낸 스크립트가
커밋돼 있지 않았다(§5 위반이고, 고친 뒤에는 확인할 방법도 없다). 그래서 `bench/tick.luau`를 먼저
쓰고 재현부터 했다:

| 케이스 (12필드 u16 subject) | 고치기 전 | 고친 뒤 |
|---|---|---|
| idle 10x100 | 1.25 ms | 0.10 ms |
| idle 10x500 | 6.23 | 0.51 |
| idle 50x100 | 7.13 | 0.32 |
| **idle 50x500** | **36.26** | **1.63 (22x)** |
| one in ten 50x500 | 36.51 | 4.94 |
| all 50x500 | 40.24 | 33.99 |
| narrow 50x500 (제거 패스) | 1.67 | 0.97 |

`one in ten`이 `idle`과 같은 값이라는 게 이 발견의 전부다 — **값을 치른 건 답이 아니라 질문
쪽이었다.** 60 FPS 프레임이 16.7 ms인데 아무것도 안 움직이는 틱이 36 ms다.

고친 모양: 최신 상태인 수신자는 **전부 같은 테이블**(`send`가 돌려준 스냅샷)을 들고 있으므로,
subject당 구조 비교 **한 번**이 그 전부를 대답한다. 수신자당 남는 건 포인터 비교 하나다. 비교는
디퍼보다 **느슨하면 안 되고 엄격한 건 괜찮다** — "안 움직였다"고 잘못 말하면 조용히 안 보내는
쪽이고, "움직였다"고 잘못 말하면 아무것도 안 쓰는 시도 한 번이다.

그리고 subject당 복사본을 nil이 아니라 **그 스냅샷으로 시드**한다. 안 그러면 가만한 세계에 들어온
클라이언트가 값은 같고 정체가 다른 두 번째 테이블을 받고, 그 순간부터 청중이 정체 클래스로 갈려서
기존 수신자 전원이 매 틱 헛된 시도를 영원히 치른다. **게이트는 있는데 아무것도 못 버는 상태**이고,
자기 테스트는 다 통과한다. 그걸 잡는 어서션이 하나 있어야 게이트가 성립한다.

#### 그래서 `changed`는 — 소비가 아니라 삭제

보고서는 "소비하거나 지우거나"라고 했고, 둘 다 만들어서 쟀다. 완벽한 dirty 플래그는 idle 틱
1.63 → 1.40 ms. **0.23 ms이고, 그나마 아무것도 안 움직이는 동안만이다.** store 단위 신호는
subject 하나만 움직여도 켜지니까 뭔가 벌어지는 세계에선 매 틱 dirty고 — 틱 비용이 문제되는 건
정확히 그런 세계다.

반대편에 걸리는 것: 신호가 변경 하나를 놓치면 그 subject는 **모든 클라에서 조용히, 영구히**
복제가 멈춘다. Charm atom 안에 평범한 테이블을 넣고 제자리 수정하는 게임이 딱 그렇게 된다.
그리고 §9대로 "store가 진실을 말했다"는 검사할 수 있는 주장이 아니다 — 안 말했을 때의 동작이
바로 그 멈춤이기 때문이다. **검사할 수 없는 보장은 부드럽게 쓰는 게 아니라 안 하는 것이다.**

그래서 seam은 `subjects`와 `read` 둘뿐이고, 비교는 netweave가 한다. Charm은 여전히 싼 쪽이다 —
신호 때문이 아니라 atom이 테이블을 갈아끼우기 때문에, 움직인 subject는 첫 키에서 갈린다. 페이즈 1의
결론(§3.11 위쪽, "둘 다 `read()` + `changed()`를 주는 모양이 아니다")이 여기서 한 칸 더 닫힌다:
**`changed()`는 애초에 받을 필요도 없었다.**

### LL. GG는 읽는 쪽에서 **더 크다** — 그리고 디코드는 아무도 뜯어본 적이 없었다

M2의 블록 최적화도, M4 페이즈 7의 fused writer도 전부 **인코드 쪽**이다. 서버가 클라이언트마다,
패킷마다, 세션 내내 무는 비용은 디코드인데 그걸 재는 계기가 없었다. `bench/profile.luau`의 거울로
`bench/decode.luau`를 만들고 같은 600바이트를 다섯 러지로 읽었다:

| 단 (rung) | 고치기 전 | 고친 뒤 |
|---|---|---|
| `inline` (생성기가 뽑는 것, 천장) | 6,369 ns | 6,365 |
| `inline + range` (검사 남긴 정직한 천장) | 8,100 | 8,058 |
| `dispatched` (이름 대신 테이블 조회) | 16,633 | 17,044 |
| `per value` (값마다 `Buffer.readU8`) | 17,453 | 17,584 |
| **`netweave`** | **32,731** | **21,475 (1.5x)** |

정직한 천장의 **4.0배 → 2.6배**. 손 리더가 4배라던 보고서 숫자를, 인용이 아니라 커밋된 스크립트로
재현하고 나서 고쳤다.

**§3.11-GG가 읽는 쪽에서 재현되고, 더 세다.** `dispatched`는 같은 언롤에서 프리미티브만 이름 대신
테이블에서 꺼내는 것인데 **2.7배**다 — 쓰는 쪽의 1.6배보다 크다. 분기 체인은 양쪽 다 취향 문제가
아니다.

고친 모양은 writer의 거울이다. `Buffer.span`이 구조체 전체를 **레이아웃이 이미 알던 크기로 한 번**
경계 검사하고, 필드는 `buffer.readu8`을 **이름으로** 읽는다. 값마다 물던 세 가지 — 클로저 호출,
그 뒤의 `READ_NUMBER` 조회, span이 이미 답한 걸 다시 묻는 프리미티브별 경계 검사 — 가 한꺼번에
사라진다.

`Buffer.ensure`는 M2에서 **바로 이 최적화를 위해** 쓰였고 두 마일스톤 동안 호출자가 없었다. 이제
`span`이고, 불리언이 아니라 버퍼와 오프셋을 돌려준다 — 이름으로 읽으려면 둘 다 필요하고, 불리언만
줘서는 쓸 수가 없었기 때문이다. **`store.changed`와 같은 자리에 있던 두 번째 죽은 선언**이고,
이번엔 지우는 게 아니라 모양을 고쳐서 쓰는 쪽이 답이었다. 차이는 하나뿐이다: 이건 부를 이유가 실제로
있었고 저건 없었다.

**배열까지 fuse하는 건 재보고 접었다.** 구조체마다 무는 `span`을 검사 없는 커서 전진으로 바꾸면
21,960 → 20,856, 약 5%다. 270줄짜리 언롤을 하나 더 둘 값이 아니고, 천장까지 남은 격차는 원소마다의
클로저 호출과 분기 체인이라 배열 단위 span으로는 어차피 안 없어진다.

### MM. 새 타입 솔버 일반 출시 — 그리고 그게 우리 대상 독자에게 **불리한 쪽으로** 정확해졌다

2026-09-06 확인. [devforum 4084991](https://devforum.roblox.com/t/general-release-luau-s-new-type-solver/4084991):

> If you use `nocheck` or non-strict mode for all of your scripts, you will be automatically moved
> to the New Type Solver with nonstrict enabled. **If you use strict mode, you will remain on the
> old solver by default**, but can opt-in via Workspace Properties.

netweave는 `LuauSolverV2`를 **요구**한다(`DESIGN-API` §7). 보장 G1·G2·G3·G6이 타입 에러고,
`type function`은 구 솔버가 문법째로 거부한다. `src/`에 27개 있다.

"일반 출시"를 들으면 조건이 사라졌다고 읽기 쉬운데 **정반대다.** 자동으로 옮겨지는 건 `nocheck`/
non-strict 쪽이고, 그쪽은 netweave의 보장이 `--!strict` 주석이라 어차피 아무것도 못 받는다.
그리고 **`--!strict` 저자 — `DESIGN-API` §0이 "the target"이라고 못박은 바로 그 집단 — 은 구
솔버에 남는다.** §0의 표가 중요한 축에서 거꾸로였고, 그걸 취소선으로 고쳤다.

바뀐 게 나쁘기만 한 건 아니다. 둘 다 문서에 이득이다:

- **지시가 구체적이 됐다.** 스튜디오 베타 토글이 아니라 **Workspace Properties → Scripting**의
  프로젝트별 설정이다. 베타를 설명하는 문단이 아니라 한 문장으로 쓸 수 있다.
- **끝이 있다.** "committed to keep the old type inference engine available through 2026" — 상시
  조건이 아니라 기한 있는 마이그레이션 단계다.

`analyze.luau`는 이 발표와 무관하게 `--flag:LuauSolverV2=true`를 계속 명시한다. **도구의 기본값에
의존하는 검사는 도구가 바뀌면 같이 바뀌는 검사**라서, 발표가 기본값을 어느 쪽으로 옮기든 저 줄은
그대로 있어야 한다.

## 4. netweave 포지셔닝
> **Flamework의 구조 + Blink의 할당 병합 + Zap의 비트패킹 + 빌드 스텝 없음. 순수 Luau 퍼스트.**
> (§3.5 2차원 지도의 오른쪽 위 빈칸)

- **L1 Codec** — Luau 스키마를 **클로저 특수화**로 컴파일. 스키마 정의 시점에 타입별 read/write 클로저를 합성해 런타임 타입 분기를 제거. 목표: Blink 대비 바이트 동등, CPU 1.3배 이내.
- **L2 Transport** — 프레임당 배칭, 채널(reliable/unreliable/ordered), 우선순위 + 대역폭 예산, 908B 인식 패킹과 자동 분할/드랍 정책, 백프레셔.
- **L3 Replication** — L1 코덱을 재사용한 델타 상태 복제. Charm/Replica를 대체하지 말고 **어댑터**로 감쌈.

**구조 원칙 (Flamework에서 채택 — §3.5)**
- 정의 1개에서 타입·검증·serdes가 전부 파생 (S1)
- 방향성은 스키마에 인코딩, `:server()` / `:client()` 뷰 분리 반환 — 서버 설정은 클라 뷰에 존재하지 않음 (S2)
- 미들웨어는 2단계 커링(로드 시 1회 / 요청마다)으로 이벤트별 상태 보유 가능 (S3)
- 실패는 enum: `Timeout / Rejected / RateLimited / Dropped / NoHandler / Cancelled` (S4)
- 전송 특성(reliable·unreliable·ordered)은 스키마의 일부, 호출부 인자가 아님 (S5)
- L1/L2/L3 별도 Wally 패키지 (S6)

교차 관심사: 검증은 코덱에서 파생(중복 작성 금지), 레이트리밋은 채널 단위 토큰버킷, 계측은 기본 내장(이벤트별 바이트·CPU, Studio 오버레이).
**Flamework과 달리 이 미들웨어들은 기본 탑재한다** — 확장점만 주고 배터리를 빼는 게 Flamework의 실수(G5·G6).

**탈출구**: Blink/Zap가 생성한 serdes를 L1 코덱으로 꽂을 수 있는 인터페이스 제공 → 경쟁이 아니라 흡수.

**런타임 스키마여서 얻는 것 (§3.8-T → §3.9-W로 확대)**: 타입이 값이므로 참조가 곧 공유다. **Blink도 Zap도 명명 타입을 참조마다 인라인 전개하고**(Zap은 재귀 타입만 예외), Zap은 고정 길이 배열까지 완전 언롤한다 — `Entity[100]` 하나로 서버 출력이 45KB다(§3.9-X). netweave는 **스키마가 커져도 클라이언트 스크립트 용량이 늘지 않는다.** 그리고 `table.clone(TEMPLATE)`로 디코드 시 해시 리해시를 없앨 수 있는데(§3.8-S), 이건 템플릿을 클로저에 캡처할 수 있는 런타임 쪽이 오히려 자연스럽다.

**비목표**: 자체 IDL/컴파일러, "최소 바이트 1위" 경쟁, 프레임워크화(ECS/DI — Flamework 영역, 침범하지 않음), roblox-ts 전용화.

## 5. 로드맵
- **M0** 벤치 하네스 먼저 — **Blink `benchmark/`를 포크**(§3.7-L). `netweave` 모드 + **서버→클라 / FireAll / 플레이어 N 스케일링 / 패킷당 할당수** 4축 보강. 비교군: ByteNet 0.4.3 / Blink 0.18.8 / Zap 0.6.29 / raw Remote (Warp는 §3.7-J로 제외).
  **스키마를 두 종류로 나눈다**(§3.9-Z): ① **배열 위주**(`Entity[100]` — Blink 유리) ② **플래그 위주**(bool·optional 다수 — Zap 유리). 승자가 뒤집히므로 하나로 뭉치면 결론이 안 나온다.
  - **M0 결과 (2026-09-03 실측).** 하네스: `bench/`, 원본 런: `bench/runs/2026-09-03.json`, 표: `bench/RESULTS.md`. 4모드 × 3스키마 × 3방향 **36셀 전부 페이로드 검증 통과.** 부하 200 pkt/frame × 10초, Studio 루프백이므로 **상대 비교 전용**.
    - **바이트(와이어 탭 실측, 이벤트 id 1B 포함)** — `ArrayHeavy` blink 601 / zap 601 / bytenet 603. `FlagIdiomatic` blink **10** / zap **7** / bytenet 20. `FlagNaive` blink **20** / zap **7** / bytenet 20. **§3.9-AA를 10배 부하에서 독립적으로 재현** — 소스 리딩과 완전히 다른 경로로 같은 값이 나왔다. 이 교차검증이 없으면 나머지 숫자는 반증 불가능한 주장일 뿐이다.
    - **프레임레이트(클라→서버 p50)** — `ArrayHeavy`: blink **145** / zap 125 / bytenet 124 / raw **29**. `FlagNaive`: raw **239** / bytenet 228 / zap 226 / blink 211.
      **§3.9-Z의 "승자가 뒤집힌다"가 맞았지만 예측과 다른 방향으로 뒤집혔다** — blink↔zap이 아니라 **소형 페이로드를 raw가 가져간다.** 직렬화가 자기 값을 못 하는 구간이 실재한다. M1은 그 교차점이 어디인지 알아야 한다.
    - **배칭이 직렬화보다 값어치가 크다** — 서버→클라 `ArrayHeavy`에서 raw는 제공 ~64,000 중 **11,138만 전달**, 배칭 라이브러리 3종은 전량 전달. 같은 페이로드 크기다. 초당 리모트 호출 raw ~6,400 vs 배칭 ~126.
    - **디코드 할당(B/packet, `ArrayHeavy`)** — bytenet **389** / blink 641 / zap **1474**. ByteNet `struct.read`의 `table.clone(input)` 한 줄 때문이다. **§3.8-S가 소스만 읽고 제안한 트릭이 실측으로 검증됐고, 런타임 스키마가 코드젠 둘을 모두 이기는 유일한 축이다.**
    - **§3.7-D 할당 병합은 `ArrayHeavy` 한 셀에서만 나타난다**(blink 145 vs 125/124). 플래그 스키마에선 오히려 뒤진다. 실재하지만 좁다. **M1에서 더 좁혀짐: 그 한 셀 안에서도 인코드 방향뿐이다**(§3.10-BB).
    - **하네스 자체의 정정 3건** — ① `Stats.DataSendKbps`는 Studio에서 **buffer 페이로드를 세지 않는다**(601B를 3.97B로, 280배 낮게). 테이블 트래픽은 정확히 잰다. 리모트에 리스너를 덧붙여 `buffer.len`을 직접 합산하는 방식으로 교체. ② Roblox는 `collectgarbage("count")`만 허용하고 컬렉터를 멈출 수 없다 — 윈도우 중앙값으로 교체. ③ Blink 하네스의 1000 pkt/frame은 60 FPS 가정인데 Studio는 200~240 FPS로 돌아 138 MB/s가 된다 — 송신 큐를 재는 값이라 200으로 낮춤.
- **M1** L1 코덱 — **스키마 → IR → 클로저 2단계**(§3.8-N: ByteNet처럼 곧바로 클로저를 만들면 최적화 창이 닫힌다). IR 위에서 정의 시점에 ① **고정 크기 계산 → 1회 alloc + base_offset**(§3.7-D) ② **비트패킹: bool·optional 플래그·작은 enum 태그를 슬롯 예약 → 로컬 누적 → 백필**(§3.8-P, Zap 방식. 동적 배열 원소 간 이월까지 노림) ③ **`table.clone(TEMPLATE)`로 디코드 리해시 제거**(§3.8-S) 를 전부 처리. 여기에 버퍼/ref 사이드카(§3.6-B3) + 전역 버퍼 + Save/Load 스왑을 read/write 대칭으로(§3.7-I) + 검증 파생(쓰기만 opt-out, 읽기는 강제 — §3.8-Q) + Luau 타입 추론.
  - 추가: **태그드 enum은 분기별로 비트 예산을 포크**해 최댓값만 소비한다(§3.9-Y — Zap은 분기마다 별도 비트를 먹는다). **고정 길이 배열은 언롤하지 않고 병합 루프**로(§3.9-X — Zap 언롤은 코드 크기 4.5배, 런타임 스키마엔 애초에 해당 없음)
- **M1-a 와이어 포맷 확정 (M1과 동시, 되돌릴 수 없는 결정)** — **패킷 헤더에 길이 필드**를 넣는다. Blink·Zap은 길이가 없어서 역직렬화가 실패하면 다음 패킷 경계로 스킵할 방법이 자체가 없고, 그래서 배치 전체가 죽는다(§3.8-R). varint 패킷 id + varint 길이.
- **M2** L2 전송 — Heartbeat 배칭(§3.6-B1·B2) / **직렬화 1회 + memcpy N회**(§3.7-E) + **전원 동일 페이로드는 `FireAllClients` 전용 채널**(ByteNet만 가진 우위) / **비신뢰 배칭은 패킷 단위 opt-in** / Zap식 링 버퍼 수신 큐 + drop-oldest(§3.7-H) / **908B 검사**(§3.7-F) / **패킷 단위 실패 격리 — 폐기 + `onBadRequest` 훅 + 길이 필드로 커서 스킵**(§3.8-R) / 대역폭 예산 + 바이트 회계 + 기본 미들웨어 배터리
- **M3** 보안·신뢰성 — 레이트리밋(§3.7-K 반면교사: 실제 바이트·시간 윈도우·관측 가능한 드랍·Studio 포함), 백프레셔, **Invoke 타임아웃 + varint 호출 id**(§3.7-G: Blink/Zap은 타임아웃 없음 + 256 상한), 악성 클라 퍼징
- **M4** L3 복제 어댑터 — `docs/milestone/PLAN-M4.md`. **한 줄이었던 것을 계획으로 폈다(2026-09-05).**
  스코프는 로드맵 그대로 — Charm/Replica를 대체하지 않고 어댑터로 감싼다 — 이고, 여기 없던 것 두 개가
  M3에서 넘어왔다: **`ArrayHeavy` 프레임레이트 격차**(84 대 blink 130, `PLAN-M1` 인수기준 5)와
  **벤치 하네스의 per-frame 할당 윈도우**. 순서는 계측기가 먼저다 — M3의 두 런 사이에서 코드가 안 바뀐
  blink의 `ArrayHeavy` 디코드 할당이 76%, zap이 146% 움직였고, 그 상태로 격차를 튜닝하면 노이즈를
  상대로 최적화하는 것이 된다(`CLAUDE.md` §9).

  가장 큰 미해결 결정은 **델타와 `unreliable`의 충돌**이다(D-2). 델타는 수신자가 베이스라인을 가지고
  있다는 전제 위에서만 의미가 있고, 드랍된 델타는 그 클라이언트를 영구히·조용히 틀리게 만든다 —
  길이 접두사로는 구제할 수 없는 형태의 §3.8-R이다.
~~- **M5** roblox-ts 타이핑, Wally + npm 배포, 문서~~ **삭제.** roblox-ts는 아직 타겟층이 아니고,
  Wally·npm 배포는 경로 자체가 없다 — 소유자의 GitHub 계정이 flagged라 저장소를 만들 수 없다
  (`CLAUDE.md` §8). 이 줄은 그 제약이 정해지기 전에 쓰인 것이고, 그대로 두면 `CLAUDE.md` §8과
  정반대 말을 하는 계획이 된다. 배포 경로가 생기면 그때 다시 세운다.

## 6. 성공 판정 기준
- **스키마 종류별로 판정한다**(§3.9-Z) — 배열 위주: **CPU ≤ Blink 1.3x**, 플래그 위주: **바이트 ≤ Zap 1.0x**. 두 축의 챔피언이 다르고 스키마에 따라 뒤집히므로 단일 기준을 쓰지 않는다
- **악의적 패킷 1개가 같은 배치의 나머지 패킷 처리를 막지 않음** (§3.8-R: Blink·Zap 둘 다 실패하는 지점)
- **패킷 수신 핫패스 할당 0 — Promise 없음, BindableEvent 없음, `task.spawn` 신규 코루틴 없음**(§3.6-A4 회피 / B4 채택)
- 스키마 추가에 빌드 불필요, 핫리로드 동작
- 퍼징 테스트 100% 통과 (OOB / 조기 resume / 레이트리밋 우회)
- 908B 초과 시 조용한 드랍 0건
- 방향 위반(클라가 S→C 이벤트를 발사하는 등)이 런타임이 아니라 타입 체크에서 잡힘
- 모든 실패 경로가 enum으로 구분 가능 — 호출자가 타임아웃·검증거부·레이트리밋을 구별할 수 있음
- **CI가 매 커밋마다 라이브러리를 실제로 로드·구동한다** — ByteNet·Warp가 동시에 실패한 지점(§3.7-J). 이게 통과 못 하면 나머지 기준은 의미 없음

## 7. 최대 리스크
~~클로저 특수화가 코드젠 성능에 붙을지 미지수~~ → **§3.6-B5에서 해소.** ByteNet이 이미 그 방식으로 코드젠 진영과 경쟁권에 있다. 남은 건 "가능한가"가 아니라 **"격차가 몇 %인가"** 이고, M0가 그 숫자를 낸다.

**새 최대 리스크: 차별점이 통합(integration)에 있다는 것.** L1·L2 각각은 ByteNet이, 구조 계약은 Flamework이 이미 증명했다. netweave의 가치는 **"이 셋을 한 라이브러리에서, 순수 Luau로, 핫패스 할당 0으로"** 라는 조합뿐이다. 조합이 어설프면 "또 하나의 네트워크 라이브러리"로 §1 Gen 1의 전철을 밟는다.
~~→ 완화책: M0 벤치를 **공개 저장소 + 재현 스크립트**로 먼저 내놓고, 숫자로 존재 이유를 증명한 뒤 API를 확정한다.~~
→ **완화책 정정 (M5 삭제와 같은 이유).** 공개 저장소가 없다 — 소유자 GitHub 계정이 flagged다(`CLAUDE.md` §8).
남은 절반은 그대로 유효하고 이미 했다: **재현 스크립트**로 숫자를 먼저 내고(`bench/`, `bench/runs/`,
`bench/envelope.luau`) API를 그 위에서 확정했다(M1). 공개는 경로가 생길 때의 문제고, 그때까지
"숫자로 증명한 뒤 API 확정"이라는 순서 자체는 지켜졌다.

**그리고 이 리스크의 반대편에 기회가 있다.** §1 Gen 1이 죽은 진짜 원인은 성능이 아니라 유지보수 중단(G1)이었는데, 같은 일이 Gen 2에서 **지금 진행 중**이다 — ByteNet master는 존재하지 않는 모듈 3개를 require하고(§3.6-B8), Warp master는 아예 컴파일되지 않는다(§3.7-J, 2026-04-16 도입 후 방치). 둘 다 "커밋은 있는데 아무도 로드해보지 않는" 상태다. 즉 **CI에서 실제로 로드·구동되는 것만으로도 런타임 스키마 진영에서 즉시 1위**다. 화려한 기능보다 이게 먼저다.
