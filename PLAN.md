# MacDisplay — 내장 디스플레이 On/Off 컨트롤 기획서

작성일: 2026-07-05 · 조사 방법: 멀티에이전트 리서치(11개 에이전트) + 핵심 주장 7건 적대적 검증

## 1. 목표

외장 모니터를 사용하는 동안 **MacBook 내장 디스플레이만 켜고/끄는** 개인용 토글 도구.
리드를 연 채로(발열 방지, Touch ID/카메라 사용) 내장 패널만 어둡게 유지하고, 원할 때 즉시 복귀.

- 필수: 내장 패널 off/on 토글, 외장 모니터는 영향 없음, 키 한 번으로 실행
- 보조(후순위): 외장 LG 모니터 제어 — 입력 전환은 가능, DDC 전원 off는 **비권장**(모니터가 하드 파워사이클 없이 안 깨어나는 사례 다수: ddcutil #36, BetterDisplay #1372)

## 2. 환경 (실측 확인)

| 항목 | 값 |
|---|---|
| 기기 | MacBook Pro, Apple M1 Max |
| OS | macOS 26.5.1 Tahoe (Darwin 25) |
| 외장 | LG ULTRAGEAR+ 5K@144Hz (메인), LG HDR 4K @30Hz — USB-C/DP |
| 기설치 | BetterDisplay 4.3.4 (실행 중, Pro 여부 미확인), betterdisplaycli, Karabiner-Elements |
| 현재 상태 | 내장 디스플레이 offline (클램셸 추정) |

## 3. 조사 결과 — 검증된 사실

내장 패널을 끄는 방식은 두 계열뿐이다:

### 방식 ①: 진짜 연결 해제 (private Disconnect API)
- 공개 API는 **존재하지 않음**. Lunar BlackOut / BetterDisplay / DisplayDeck 모두 사설 `CGSConfigureDisplayEnabled`(SkyLight/CoreDisplay) 사용. macOS 13+, Apple Silicon 전용. Apple 공식 클램셸 메커니즘(`SLSDisplayPowerControlClient`)은 Apple 전용 entitlement로 막혀 있어 SIP를 끄지 않는 한 사용 불가. **[검증: CONFIRMED]**
- 패널이 배치에서 완전히 사라짐 → 토글할 때마다 **윈도우가 재배치**됨.
- **신뢰성 문제(검증됨)**: macOS가 감지 이벤트마다 디스플레이를 재연결하려 해서 상태를 계속 재주장해야 하고, "끊긴 상태로 고착"되는 사례가 Sequoia~Tahoe에서 다수 보고됨. Tahoe 26.4.1에서는 **재부팅으로도 복구 안 된 사례**(BetterDisplay #5314) 존재. 리드 개폐/외장 재연결 복구는 "베스트 에포트"일 뿐 보장 아님(#1623, 미해결). **[검증: C6 정정]**
- macOS 포인트 업데이트가 사설 심볼을 깨는 전례 있음(Sequoia 15.6, BetterDisplay #4729/#4730). **[검증: CONFIRMED]**

### 방식 ②: 밝기 0 + 외장 화면 미러링 (OpenClamshell 방식)
- 백라이트를 완전히 끄고(mini-LED라 실질 검정), 내장 패널에 외장 화면을 미러링해 "보이지 않는 데스크톱에 창/커서가 숨는 문제"를 제거.
- 공개 API 수준 동작 → **고착 위험 없음. 도구가 죽어도 하드웨어 밝기 키(F2)로 즉시 복구.**
- 윈도우 재배치 없음(배치가 변하지 않으므로).
- 참조 구현 **strohsnow/OpenClamshell**: Swift 파일 1개, `swiftc`로 컴파일(Xcode 불필요), launchd 에이전트 설치 지원, **README에 macOS 26 테스트 명시**, 로컬 빌드라 공증 불필요. **[검증: CONFIRMED]**
- 한계: 패널이 논리적으로는 켜져 있음(GPU가 계속 구동, 절전 효과는 백라이트만).

### 기존 도구 비교 (재사용 후보)

| 도구 | 방식 | 비용 | 토글 수단 | 판정 |
|---|---|---|---|---|
| **OpenClamshell** (OSS) | ② | 무료 | 자동(외장 연결 감지), 수동 토글은 개조 필요 | ✅ v1 기반으로 채택 |
| **BetterDisplay Pro** | ① | $21.99 (설치됨, Pro 필요) | CLI/URL/HTTP/단축어 전부 | ✅ 유료 대안, 유지보수 최상 |
| **Lunar Pro** | ① | $23 | 핫키 ⌃⌘6, CLI, 단축어 | 중복 (BetterDisplay 보유 시 불필요) |
| **DisplayDeck** (무료 MIT) | ① | 무료 | 메뉴 클릭만 | ❌ **재활성화 실패 미해결 이슈**: 외장 연결 상태에서 재활성화 API가 `kCGErrorIllegalArgument` 반환, 복구는 로그아웃뿐 (issue #1, v2.8.2 기준) **[검증: C2 정정]** |
| DIY 사설 API 래퍼 | ① | 무료 | 자유 | ❌ DisplayDeck과 같은 문제를 그대로 상속 |

## 4. 결정 (2026-07-05, 사용자 확정)

**BetterDisplay류 소프트웨어를 직접 만든다. v1은 CLI On/Off.**
방식 ①(진짜 disconnect, 사설 `CGSConfigureDisplayEnabled`)을 자체 구현한다. 조사에서 확인된
재연결 실패 리스크(DisplayDeck issue #1, BetterDisplay #1623 등)는 회피 대상이 아니라
**v1의 핵심 설계 과제**로 삼는다 — Lunar/BetterDisplay가 실제로 쓰는 재연결 전략을 분석해 반영.
방식 ②(밝기 0 + 미러링)는 disconnect 실패 시 폴백 후보로 보류.

## 5. v1 구현 계획 — `macdisplay` CLI

스펙 (Swift 단일 파일, 외부 의존성 없음, swiftc 빌드):

```
macdisplay status   # 디스플레이 목록 + 내장 패널 연결 상태 (읽기 전용)
macdisplay off      # 내장 디스플레이 disconnect (외장이 1대 이상 켜져 있을 때만 허용)
macdisplay on       # 내장 디스플레이 reconnect (재시도 + 실패 시 복구 안내 출력)
macdisplay toggle
```

단계:
```
1. [조사·Opus] MIT 참조 구현 분석 (DisplayDeck, janten/disable-monitor, Lunar OSS 부분)
   → 산출: 사설 API 선언부, disconnect 상태에서 내장 displayID 찾는 법, 재연결 신뢰성 전략
2. [구현·Opus] macdisplay CLI 작성 + swiftc 빌드 + status 등 읽기 전용 명령 실기 검증
   → verify: 컴파일 성공, status가 실제 디스플레이 구성과 일치
3. [리뷰·Sonnet×2] 정확성/안전장치 리뷰 + 과잉설계 리뷰 → 수정 반영
4. [사용자] 리드 연 상태에서 off/on/toggle 실기 테스트 (라이브 테스트는 사용자 입회 필수)
5. Karabiner-Elements 핫키 바인딩 (v1.1)
```

## 5.1. v1.1 — 메뉴바 앱 (2026-07-05 사용자 요청으로 확정)

- 파일 분리: `core.swift`(공유 로직) + `main.swift`(CLI, 동작 불변) + `menubar.swift`(AppKit NSStatusItem 앱)
- Xcode 없이 `swiftc` + `Makefile`로 `MacDisplay.app` 번들 생성 (Info.plist LSUIElement=true)
- 메뉴: 열 때마다 CGSGetDisplayList 재조회 → 디스플레이별 체크마크 토글, 마지막 활성 디스플레이는 비활성화, 유령 슬롯(무명+오프라인) 숨김
- 로그인 자동 실행: 시스템 설정 > 로그인 항목 (코드 불필요)
- CLI에 추가된 대상 지정: `off|on|toggle [id]` (id 생략 = 내장), 이름 캐시는 status 라벨 전용

역할 분담: 설계·종합·리뷰 판정 = Fable / 코드 작성·조사 = Opus·Sonnet 에이전트.

## 6. 안전장치 (설계 원칙)

- `off`는 **외장 디스플레이가 1대 이상 온라인일 때만** 실행 (화면 전멸 방지 가드)
- `on` 실패 시: 재시도 → 그래도 실패하면 검증된 복구 절차 안내 출력 (리드 개폐 → 외장 재연결 → 로그아웃 → 재부팅 순)
- `status`로 현재 상태 항상 확인 가능
- 사설 API 심볼은 dlsym으로 런타임 로드 — 심볼이 사라진 macOS 업데이트에서 크래시 대신 명확한 에러 메시지
- 잠자기/깨어남, 리드 개폐 후 상태 재적용은 v1에서는 "다시 토글"로 충분 — 자동 재적용은 실사용 후 필요하면 추가

## 7. 미결 사항

1. ~~방식 선택~~ → 방식 ① 자체 구현으로 확정 (2026-07-05)
2. ~~토글 진입점~~ → CLI 우선으로 확정, 핫키·메뉴바는 v1.1+
3. 자동 모드(외장 연결 감지) 필요 여부 — v1 이후 판단
4. 재연결 실패가 실기에서 재현되면: 방식 ②(밝기 0+미러링) 폴백을 `--safe` 모드로 추가할지

## 부록: 주요 출처

- OpenClamshell: https://github.com/strohsnow/OpenClamshell
- DisplayDeck 재활성화 실패: https://github.com/oabdrabo/DisplayDeck (issue #1)
- BetterDisplay CLI/Pro 게이팅: https://github.com/waydabber/BetterDisplay/wiki/Integration-features,-CLI
- Disconnect 고착 사례: BetterDisplay #1623, #4288, #5314 / Tahoe 호환: discussion #4418
- Sequoia 15.6 사설 API 파손 전례: BetterDisplay #4729, #4730
- Lunar BlackOut: https://lunar.fyi/ (Pro 기능), CLI `lunar blackout`
- m1ddc (외장 DDC): https://github.com/waydabber/m1ddc — 전원 off 명령 없음, 입력 전환은 지원
