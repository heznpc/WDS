# WDS macOS 개발 가이드

[제품 소개로 돌아가기](../README.md) · [제품 방향과 범용화 계획](product.md)

이 문서는 기본 브랜치 `main`의 Mac 구현을 설명합니다. 출처 구분·독립 스위치·교정 UI·터미널 검토 UI가 추가된 작업 브랜치와는 동작이 다릅니다. [README의 구현 상태](../README.md#현재-구현-상태)를 먼저 확인하세요.

## 빌드와 실행

실제 입력창을 대상으로 쓰는 하나의 사용자 앱은 `WDS.app`입니다. 아래 명령이 실행 중인 WDS를 종료하고 메뉴바 앱과 AX 센서·편집 브리지·오버레이·Zsh 어댑터를 한 번에 빌드·서명한 뒤 새 번들을 실행합니다.

```bash
./script/build_and_run.sh
```

현재 기본 브랜치는 macOS 소스 빌드 알파입니다. GitHub Release 다운로드는 아직 제공하지 않습니다. `./scripts/package-macos.sh`에 Developer ID 서명·공증·DMG 생성 경로가 있으며, 소스 빌드와 배포용 패키징은 별도입니다. 실행 후 먼저 메뉴바의 `효과 테스트`를 누르면 권한이나 대상 입력창 없이 화면 중앙에서 삭제 효과를 확인할 수 있습니다. 메뉴를 다시 열면 실제 창 표시·타이머 진행·렌더 프레임 검증 결과가 `최근 효과`에 남습니다.

실제 입력창에서는 메뉴바의 `WDS ○`를 누르고 맨 위 `현재 앱에서 WDS 시작…` 하나만 선택하면 권한·앱 자동 감시 허용이 순서대로 안내됩니다. 저장되는 것은 앱 식별자뿐이며, 다음 WDS 실행이나 대상 앱 재실행 뒤에도 그 앱이 전면에 오면 감시가 자동 재개됩니다. 문장을 입력하고 약 0.4초 멈춘 뒤 입력창 옆 후보에서 `날리기`를 누르거나 `⌃⌘⌫`를 눌러야 실제로 사라집니다. `⌃⌘K`는 현재 후보를 유지합니다. 두 전역 단축키는 후보가 보이는 동안에만 등록되며 WDS는 Enter나 전송 버튼을 누르지 않습니다.

마우스 궤적 연출을 원할 때만 별도의 선택적 입력 모니터링 권한과 `Use Recent Mouse Motion…`을 켭니다. 허용 목록에는 bundle ID만 저장합니다. 기본 센서는 원문을 내보내지 않는 redacted·text-only 모드이며, 명시적 미리보기·삭제 문구는 자식 프로세스 인자가 아니라 stdin으로만 전달합니다.

### 현재 초안형 Input Assistance

WDS의 기본 후보 감지는 과거 발화를 학습하지 않습니다. 현재 포커스된 초안 한 건만 보고 매번 같은 결과를 내는 무상태 로컬 분석입니다.

- 앱 허용 목록과 자동 감시 동의에는 bundle ID만 저장하고, 실제 원문 scope는 매번 전면 앱의 정확한 PID로 새로 생성
- 메뉴 맨 위 `현재 앱에서 WDS 시작…`에서 앱별 자동 감시를 명시적으로 허용하며, `중지`하면 그 지속 동의도 함께 해제
- 현재 초안 원문은 일반·비보안 입력칸에 포커스가 있는 동안 메모리에만 둠
- `AXValueChanged` 뒤 약 400ms 동안 입력이 잠잠하면 로컬 규칙으로 현재 문장만 분석
- `씨발`, `시발!`처럼 초안 전체를 차지하는 감정성 욕설·감탄사, 문장에서 분리 가능한 감정 표현, 일부 의미 보존형 감정 강조어, 짧은 도입부, 즉시 중복된 머뭇거림, 명백한 연속 쉼표만 후보화
- `존나 크게`, `개소리 말고`, 욕설 단어의 번역·인용·삭제 요청처럼 욕설 자체가 의미나 작업 대상인 문맥은 후보에서 제외
- 임의 단어의 반복 자체는 후보 근거로 쓰지 않으며 코드·URL·인용·명령·목록·짧거나 애매한 문장은 실패 폐쇄
- 후보가 있으면 해당 글자 범위 옆에 `유지 / 날리기` 패널을 표시하고, 등록에 성공한 경우 패널에 `⌃⌘K / ⌃⌘⌫` 단축키를 함께 표시
- `유지`는 현재 입력칸 세션에서 같은 후보만 다시 띄우지 않을 뿐 학습하거나 저장하지 않음
- `날리기`를 눌러도 현재 초안·앱 PID·포커스·UTF-16 범위를 새로 검사하고 모두 그대로일 때만 정확한 한 구간을 삭제
- `Stop Watching & Forget Current Draft`, 기능 끄기, 포커스 이동, 보안 입력칸 진입, 오류 또는 앱 종료 시 초안 참조 해제
- AI 문맥 판정은 기본 `Off`이므로 원격 호출과 토큰 사용은 정확히 0
- 어느 경로도 Enter, Return, 전송 버튼을 누르지 않음

Swift `String` 복사본의 물리적 zeroization까지 보장한다는 뜻은 아닙니다. WDS가 원문을 디스크·UserDefaults·로그·네트워크에 저장하지 않고 수명 경계에서 메모리 참조를 해제한다는 의미입니다.

| 입력 표면 | WDS 내부 경로 | 현재 상태 |
| --- | --- | --- |
| Claude Desktop, Codex Desktop | macOS Accessibility(AX) | 현재 초안을 로컬 분석하고 후보 패널·정확 범위 삭제·부수기 효과 사용 가능 |
| Claude/Codex 웹 등 브라우저 입력칸 | 같은 AX 경로 | 브라우저가 실제 `<textarea>`/contenteditable을 AX 편집 요소로 노출할 때 같은 현재-초안 흐름 사용 가능 |
| 일반 Zsh 프롬프트 | 번들된 ZLE 어댑터와 인증 Unix socket | **미완성.** 전송·인증·검증 계층까지만 구현. 앱의 터미널 후보 UI가 연결되지 않아 서버 응답이 항상 pass-through이므로 실제로 삭제되는 구간은 없음 |
| Claude Code/Codex CLI 내부 TUI | 대상 CLI의 의미 버퍼 훅 | 현재 미지원. PTY 바이트만으로 IME·커서·편집 버퍼를 안전하게 복원하지 않음 |

터미널 경로의 정확한 현재 상태는 다음과 같습니다. 이 경로로는 아직 어떤 글자도 지워지지 않습니다.

| 계층 | 상태 |
| --- | --- |
| ZLE 위젯 → helper → Unix socket 전송 | 구현 완료 |
| HMAC-SHA256 nonce 핸드셰이크, 소켓 소유권·권한 검사 | 구현 완료 |
| 버퍼 digest·커서·범위 재검증 후 정확한 한 구간 삭제 로직 | 구현 완료 (`BufferEdit`, 테스트 13건) |
| 앱이 삭제 여부를 판정하는 resolver | **의도적 pass-through 스텁** (`TerminalSocketServer.swift`) |
| 앱의 터미널 후보 표시·수락 UI | **미구현** |

Zsh 플러그인은 `.zshrc`를 자동 수정하거나 키를 자동 바인딩하지 않습니다. 현재 셸에서만 명시적으로 켜려면 다음처럼 source하고 review 키 하나를 정합니다.

```zsh
source "$PWD/dist/WDS.app/Contents/Resources/Shell/wds-zle.plugin.zsh"
bindkey '^[W' wds-review-buffer
```

## 테스트

Swift 패키지 5개의 순수 로직 테스트입니다.

```bash
for pkg in native/WDSApp native/WDSAxBridge native/WDSSensor native/WDSWhack native/WDSTerminalAdapter; do
  swift test --package-path "$pkg"
done
```

`npm test`는 네이티브 helper를 조율하는 `scripts/native-whack.mjs`만 검증합니다.

```bash
npm test
```

문두 학습·LLM 문맥 판정·6가지 애니메이션을 빠르게 검증했던 독립 웹 알고리즘 실험판은 `web-prototype-v0` 태그에 보존하고 main에서 제거했습니다. 현재 구현된 사용자 경로는 `WDS.app`이며, Mac 브라우저 입력칸도 이 앱의 AX 경로가 담당합니다. 공통 코어와 브라우저 확장은 [범용화 계획](product.md#범용화-구조)에 해당합니다. 은퇴한 웹 실험판을 새 범용 코어의 구현으로 간주하지 않습니다. 필요하면 다음처럼 복구할 수 있습니다.

```bash
git checkout web-prototype-v0 -- src index.html styles.css scripts/serve.mjs scripts/context-judge.mjs
```

## OpenWhip식 데스크톱 상호작용

현재 macOS 실험판은 두 층으로 동작합니다.

1. `native/WDSAxBridge`가 포커스된 입력창에서 정확히 한 번 등장하는 UTF-16 범위를 읽고 그 범위만 제거합니다.
2. `native/WDSWhack`가 삭제된 실제 문구를 stdin으로만 받아, 해당 화면 구간에서 글자 조각이 흩어져 올라가는 0.9초 투명 오버레이를 재생합니다. 파란 빛기둥·화면 균열·임의 파편은 제품 렌더 경로에서 제거했으며, 종료 시 텍스트나 좌표 없이 글자 렌더 프레임 수와 위치 추정 여부만 앱에 보고합니다.

Claude Desktop처럼 macOS 접근성 트리에 편집 가능한 입력창을 노출하는 앱에서는 다음처럼 실제 입력창을 대상으로 실험할 수 있습니다. `--delete` 또는 `--preview`를 반드시 명시해야 하며, 어떤 모드에서도 Enter나 전송 버튼은 누르지 않습니다.

```bash
npm run native:whack -- \
  --target '정확히 제거할 문자열' \
  --bundle-id com.anthropic.claudefordesktop \
  --delete
```

앱이 글자별 좌표를 제공하면 그 범위를 사용하고, Electron처럼 `AXBoundsForRange`가 비어 있으면 포커스된 입력칸의 프레임과 대상 위치로 작은 범위를 추정합니다. macOS 설정에서 이 명령을 실행하는 호스트에 손쉬운 사용 권한이 있어야 합니다.

OpenWhip식 상호작용은 `WDS.app`의 비활성 후보 패널이 담당합니다. 이 패널은 대상 앱의 포커스를 빼앗지 않고 `유지 / 날리기` 클릭과 후보가 보일 때만 유효한 전역 단축키를 받습니다. 실제 오버레이는 삭제 검증이 끝난 뒤에만 나타나는 클릭 통과형 시각 효과이며, 정확한 글자 편집은 AX 브리지가 별도로 담당합니다.

## 실시간 텍스트·마우스 센서

`native/WDSSensor`는 지정한 앱이 활성화되어 있을 때 포커스된 편집 입력창의 `AXValue` 변경을 관찰합니다. 키 이벤트를 글자로 재조립하지 않으므로 한글 IME, 붙여넣기, 자동완성으로 바뀐 현재 초안도 입력창이 노출한 최종 문자열 그대로 읽습니다. `AXSecureTextField`는 값을 읽기 전에 제외합니다.

마우스는 키보드와 분리된 listen-only `CGEventTap`으로 관찰합니다. 원시 좌표 이력은 짧고 크기가 제한된 메모리 링에만 두며, 외부에는 최근 이동 방향·속도·거리·클릭·스크롤 합계만 내보냅니다. 대상 앱이 비활성화되거나 포커스가 안전한 입력창을 벗어나면 링을 즉시 비웁니다.

기본 출력은 텍스트가 가려진 JSON Lines입니다. 실제 초안을 확인하는 명시적 실험에서만 `--emit-text`를 추가합니다. 마우스 권한 없이 텍스트만 필요하면 `--text-only`를 함께 사용합니다.

```bash
native/WDSSensor/.build/release/wds-sensor \
  --bundle-id com.anthropic.claudefordesktop \
  --duration-ms 3000 \
  --mouse-window-ms 1500 \
  --emit-text \
  --text-only
```

최근 마우스 방향과 속도를 균열·파편 궤적에 적용하는 미리보기는 다음처럼 실행합니다. 캡처가 완전히 종료된 뒤 입력값과 범위를 새로 검사하며, `--preview`에서는 텍스트를 바꾸지 않습니다.

```bash
npm run native:whack -- \
  --target '정확한 대상 문자열' \
  --bundle-id com.anthropic.claudefordesktop \
  --preview \
  --capture-mouse-ms 1200
```

`--delete` 모드에서는 별도 inspect에서 받은 전체 초안 SHA-256, 대상 PID, UTF-16 범위를 유지하고, 실제 쓰기 직전에 같은 앱이 여전히 전면·활성 상태인지까지 다시 확인합니다. 마우스 요약은 연출 인자에만 들어가며 삭제 대상이나 문맥 판정에는 들어가지 않습니다.
