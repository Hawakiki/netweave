# _refsrc — 임시 참조 소스 (지우라고 할 때까지 유지)

netweave 설계 근거를 소스에서 직접 확인하기 위해 clone한 외부 저장소.
**netweave 코드가 아니며, 배포/패키징에 포함되지 않는다.** 삭제해도 `docs/RESEARCH-AND-PLAN.md`의
분석 내용은 그대로 남는다 (§3.6, §3.7이 파일·줄 번호까지 인용).

| 디렉터리 | 저장소 | clone 시점 커밋 |
|---|---|---|
| `networking/` | rbxts-flamework/networking | `3bd58cd` 2025-09-03 `master` |
| `ByteNet/`    | ffrostflame/ByteNet        | `fbdb156` 2025-08-01 `master` |
| `blink/`      | 1Axen/blink                | `73695d1` 2026-04-11 `main` (v0.18.8) |
| `zap/`        | red-blox/zap               | `8cd17ab` 2026-06-23 `0.6.x` (0.6.29) |
| `Warp/`       | imezx/Warp                 | `a27067c` 2026-05-05 `master` (1.1.0-pre7) |

M4 페이즈 1에서 추가 — **상태 복제 쪽**. 이벤트 라이브러리와 달리 이쪽은 M3까지 하나도 받아두지
않았고, `CLAUDE.md` §7이 읽지 않은 라이브러리에 대한 주장을 금지하므로 D-3을 답하기 전에 먼저 받았다.

| 디렉터리 | 저장소 | clone 시점 커밋 |
|---|---|---|
| `charm/` | littensy/charm | `b05f3a9` 2026-06-21 `main` (charm-v0.11.0) |
| `ReplicaService/` | MadStudioRoblox/ReplicaService | `aaeb1c6` 2024-10-16 `master` (태그 없음) |
| `delta-compress/` | nezuo/delta-compress | `46f0831` 2024-08-26 `main` (태그 없음) |

전체 히스토리 clone(`--depth` 없음) — `git log -S`로 회귀 도입 시점을 추적하는 데 썼다.

## 삭제
```
rm -rf _refsrc
```

## `_generated/`
Blink 컴파일러를 `lune`으로 직접 돌려 뽑은 생성 출력 샘플. §3.7-D와 §3.8-P/S/T의 근거.
- `_gen_blink_server.luau` — `Entity[100]`(할당 병합 + 루프 내 러닝 커서), `boolean[8]`(1바이트/bool)
- `_gen_blink_reuse.luau` — 명명 타입 재사용 시 인라인 전개, `struct{bool,bool,u8?,bool}` = 4바이트

재생성: `blink/` 에서 `lune run <스크립트>` — `Parser.new("./test/Sources/")` → `Generator.Generate("Server", AST)`.
Zap은 이후 실제로 빌드해서 검증했다 — 아래 `_generated/zap/` 참고.

## `_generated/zap/`
Zap 0.6.29를 실제로 빌드해서(`cargo build --release -p cli` → `zap/target/release/zap.exe`)
Blink 샘플과 **동일한 스키마**로 뽑은 출력. §3.9의 근거.
- `a.zap` → `Entity[100]` + `boolean[8]` — 완전 언롤(45KB), bool 8개 → 1바이트
- `b.zap` → `Entity` 2회 참조 + `struct{bool,bool,u8?,bool}` — 인라인 확인, 비트팩 1바이트
- `bp.zap` → Zap 자체 `tests/files/bitpacking.zap` + 출력 옵션 — 변형 저장 분기 3종 전부 재현

재생성: `_generated/zap/bin/zap.exe <file>.zap` (같은 디렉터리에 `out_*.luau` 생성). 빌드된 바이너리만 남기고
`zap/target/`(약 240MB)은 삭제했다. 재빌드가 필요하면 Rust GNU 1.98.0 설치 후
`cargo build --release -p cli`. cargo 경로: /c/Program Files/Rust stable GNU 1.98/bin (PATH에 없음).
