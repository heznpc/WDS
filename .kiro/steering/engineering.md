# WDS Mac 엔지니어링

이 문서는 현재 기본 브랜치의 Mac 구현 규칙이다. WDS 전체의 플랫폼 범위는 [제품 방향](../../docs/product.md), 작업 브랜치 구현은 [README](../../README.md#현재-구현-상태)에서 구분한다. 공통 코어·브라우저 확장은 아직 구현되지 않았다.

## 저장소 구조

워크스페이스 루트가 단일 git 저장소다 (`github.com/heznpc/WDS`). `.claude/worktrees/`는 중복 worktree이므로 **모든 탐색·검색에서 제외**할 것. `.build/`, `dist/`도 제외.

Swift 패키지 5개가 하나의 `.app`으로 조립된다.

| 패키지 | 산출물 | 역할 |
| --- | --- | --- |
| `native/WDSApp` | `WDSApp` → `Contents/MacOS/WDS` | 메뉴바 앱, 조율자 |
| `native/WDSAxBridge` | `wds-ax-bridge` | AX 읽기·정확 범위 삭제 |
| `native/WDSSensor` | `wds-sensor` | AX 텍스트 + 마우스 센서 |
| `native/WDSWhack` | `wds-whack` | 오버레이 효과 |
| `native/WDSTerminalAdapter` | `wds-terminal-adapter` | Zsh ZLE 어댑터 + 인증 소켓 |

helper 4개는 `Contents/Helpers/`, zsh 플러그인은 `Contents/Resources/Shell/`.

`scripts/native-whack.mjs`는 helper들을 조율하는 Node 오케스트레이터로 **현역**이다. 은퇴한 웹 프로토타입과 혼동하지 말 것.

## 빌드와 테스트

```bash
./script/build_and_run.sh          # 실행 중 WDS 종료 → 빌드·서명 → 새 번들 실행
./script/build_and_run.sh --verify # 실행 후 2초 생존 확인
./scripts/build-wds-app.sh         # 번들만 빌드 (dist/WDS.app)
npm test                           # native-whack.mjs 검증 (14건)
```

Swift 테스트는 패키지별로 돌린다. 테스트 수와 성공 여부는 해당 커밋의 실행 결과로 확인한다.

```bash
for pkg in native/WDSApp native/WDSAxBridge native/WDSSensor native/WDSWhack native/WDSTerminalAdapter; do
  swift test --package-path "$pkg"
done
```

CI(`.github/workflows/ci.yml`)가 위 전부 + 번들 레이아웃 + `codesign --verify --deep --strict`를 검사한다.

## 절대 깨면 안 되는 불변식

현재 구현이 유지해야 할 기준이다. 리팩터링 시 테스트와 실제 입력창에서 다시 확인한다.

1. **Enter·Return·전송 버튼을 누르지 않는다.** 어느 경로에서도. 이게 깨지면 제품이 아니다.
2. **쓰기 직전 재검증.** 초안 SHA-256 + 대상 PID + focus epoch + UTF-16 범위 + frontmost 상태를 다시 확인하고 전부 일치할 때만 삭제한다. 하나라도 다르면 원문 유지. fail-closed 4종(digest / pid / range location / range length 불일치)이 실제로 거부하는 것을 확인했다.
3. **원문은 stdin으로만 전달.** 자식 프로세스 인자(argv)에 넣지 않는다. `ps`로 노출되기 때문이다.
4. **초안 원문을 디스크·UserDefaults·로그·네트워크에 저장하지 않는다.** 메모리에만 두고 수명 경계에서 참조를 해제한다. 초안과 별도로 기능 설정·bundle ID·터미널 인증 상태를 유지한다.
5. **보안 입력칸은 값을 읽기 전에 제외한다** (`AXSecureTextField`).
6. **위험한 작업은 short-lived helper 프로세스로 격리한다.** 권한 최소화가 아키텍처로 강제돼 있다.
7. **자동 삭제 없음.** 후보는 항상 명시적 승인 제안이며 편집 허가가 아니다.
8. **기본 센서는 redacted.** 원문 방출은 명시적 `--emit-text`에서만.

## 코드 배치 규칙

**순수 판단 로직은 `*Core` 타깃에, AppKit·AX·프로세스 I/O는 executable 타깃에 둔다.** 테스트는 전부 `*Core`에 있다.

`WDSAppCore` 구성:

- `CurrentDraftAnalyzer` — 무상태 후보 탐지. 학습·영속·네트워크 없음. 같은 입력에 항상 같은 출력.
- `CurrentDraftCandidateTracker` — 후보 상태, 디바운스 세대, 억제 상태(유지/타이핑으로 숨김), 재검증 판단
- `CandidateHotKeyLifecycle` — 패널 표시와 핫키 등록의 짝. `hasOrphanedRegistration`이 항상 false여야 한다
- `InteractionState` — 상호배타 작업 토큰
- `CandidateCommandGate` — 핫키 1회성 소비
- `SafeDelete` — 삭제 응답 검증
- `OverlayGeometryResolver`, `SessionPatternDetector`

### 디바운스는 단조 증가 세대 카운터다

`CurrentDraftCandidateTracker`의 `generation`은 **`reset()`에서도 되돌리지 않는다.** 되돌리면 초안 해제 전에 걸린 타이머가 이후 새 티켓과 같은 값이 되어 죽은 scope의 후보를 검사한다. 테스트로 고정돼 있다.

### 재검증 API 두 개를 구분할 것

- `approval(...)` — `engineEnabled`, `isIdle` 게이트 **포함**. 승인 진입점에서 쓴다.
- `stillMatches(...)` — 재파생만. 삭제 중간 재확인처럼 **이미 interaction을 점유해 `isIdle`이 false인** 지점에서 쓴다.

`isIdle`이 false인 곳에서 `approval()`을 쓰면 항상 `.stale`이 되어 삭제가 전혀 안 된다. 실제로 밟은 함정이다.

## 관례

- pid는 `Int32`로 쓴다 (`pid_t` 아님). 기존 `SafeDeleteInspection`과 맞춘다.
- 서드파티 의존성 0. Swift는 path 기반 SPM만, Node는 의존성 없음. 새로 추가하지 말 것.
- 테스트 프레임워크가 이중화돼 있다. `WDSApp`·`WDSWhack`은 XCTest(swift-tools 5.9), `WDSAxBridge`·`WDSSensor`·`WDSTerminalAdapter`는 swift-testing(6.2). 해당 패키지의 기존 방식을 따를 것.
- 사용자 노출 문자열은 한국어, 코드 식별자·주석은 영어.
- 주석은 무엇을 하는지가 아니라 **왜 그렇게 해야 하는지**(어떤 실패를 막는지)를 쓴다. 기존 코드가 그렇게 돼 있다.
- TODO/FIXME 마커를 쓰지 않는다. 미완성은 산문으로 명시한다. 대신 grep으로 미완성을 못 찾으니 문서를 먼저 읽을 것.

## 테스트 사각지대

순수 로직 테스트는 `*Core` 대상이며 실제 AX·창·프로세스 실행을 대신하지 않는다. `WDSApp/main.swift`의 `AppDelegate`에 상태 변수와 메서드가 몰려 있다. **여기를 만질 때는 로직을 `WDSAppCore`로 빼서 테스트를 붙이는 방향으로 작업할 것.** 후보 생명주기는 이미 그렇게 처리했다.

## 검증 방법

helper는 앱 없이 단독 실행할 수 있어서 실제 검증이 가능하다. 터미널에 손쉬운 사용 권한이 있으면 AX 경로도 된다.

```bash
# 오버레이 (권한 불필요)
printf '날려!' | ./dist/WDS.app/Contents/Helpers/wds-whack \
  --x 600 --y 400 --width 240 --height 56 --duration-ms 900 \
  --motion-direction north --motion-speed 1800 --motion-distance 240 \
  --text-stdin --report-json

# AX 읽기 (대상 앱이 frontmost여야 함)
printf '씨발 ' | ./dist/WDS.app/Contents/Helpers/wds-ax-bridge \
  inspect --target-stdin --bundle-id com.apple.TextEdit
```

`delete`는 `inspect`가 준 `valueSHA256`, `targetProcessIdentifier`, `utf16Range`를 `--expected-*`로 넘겨야 한다. TextEdit 새 문서가 안전한 실험 대상이다.

기본 브랜치의 로컬 빌드 스크립트는 ad-hoc 서명을 사용한다. 배포용 Developer ID 서명·공증·staple·DMG 생성은 `scripts/package-macos.sh`에 구현돼 있다. 패키징 코드의 존재와 공개 Release 제공은 별개이며, 현재 공개 Release 다운로드는 없다.
