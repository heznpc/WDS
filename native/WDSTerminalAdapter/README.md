# WDS terminal adapter

이 패키지는 최종적으로 `WDS.app` 안에 번들할 터미널 입력 어댑터의 첫 안전한 경계입니다. 전역 키 이벤트를 읽지 않고, 셸 설정 파일을 수정하지 않으며, 원문을 로그나 파일에 저장하지 않습니다.

현재 구현물은 ZLE 클라이언트, 검증 로직, WDS.app의 인증 소켓 서버까지입니다. 앱의 터미널 후보·수락 UI는 아직 연결되지 않았으므로 서버 응답은 항상 원문 유지이며, end-to-end 터미널 삭제가 완성된 것은 아닙니다.

## 현재 지원 범위

- 일반 Zsh 프롬프트: 명시적 검토 위젯에서 ZLE의 완성된 `BUFFER`와 `CURSOR`를 전달할 수 있습니다.
- 대화형 CLI: 대상 프로그램이 아래의 의미적 버퍼 계약을 직접 호출하는 경우에만 지원합니다.
- Claude Code/Codex CLI 내부 프롬프트: 아직 지원하지 않습니다. 이 패키지는 지원한다고 가장하지 않습니다.

`forkpty` 기반 `wds-run`은 의도적으로 만들지 않았습니다. PTY에서 보이는 것은 바이트 스트림뿐이며, raw mode를 사용하는 line editor/TUI에서는 escape sequence, bracketed paste, IME, 화면 갱신, 실제 제출을 의미적 편집 버퍼로 무손실 복원할 수 없습니다. 불완전한 복원은 엉뚱한 범위를 삭제하거나 Enter의 의미를 바꿀 수 있습니다.

## Zsh ZLE 사용

빌드한 뒤, 사용할 현재 셸에서만 플러그인을 명시적으로 source합니다. 이 명령은 `.zshrc`를 변경하지 않습니다.

```zsh
swift build -c release --package-path /absolute/path/to/WDSTerminalAdapter
source /absolute/path/to/WDSTerminalAdapter/Integration/wds-zle.plugin.zsh
```

플러그인은 키를 자동으로 바인딩하지 않습니다. 검토 위젯을 현재 세션에서 원하는 키에만 바인딩합니다.

```zsh
# 현재 버퍼를 검토하고, 승인된 삭제가 있으면 적용만 합니다. 전송하지 않습니다.
bindkey '^[W' wds-review-buffer
```

이 플러그인은 Enter 바인딩을 만들거나 바꾸지 않습니다. 검토 후 사용자가 기존 Enter를 직접 눌러 제출합니다. 앱의 응답이 `accepted_deletion`이더라도 전체 버퍼 SHA-256, 커서, 삭제 범위, 삭제 대상 SHA-256, 명시적 수락 플래그를 모두 다시 확인한 뒤에만 로컬 코드가 정확한 한 범위를 삭제합니다. 하나라도 다르면 원문을 그대로 유지합니다.

좌표 단위는 ZLE와 맞춘 Unicode scalar offset입니다. UTF-8이 아닌 locale에서는 ZLE 커서가 byte offset이 될 수 있으므로 위젯은 추측하지 않고 원문 유지로 종료합니다.

개발 기본 소켓은 다음 경로입니다.

```text
~/Library/Application Support/WDS/terminal.sock
```

다른 경로는 현재 셸의 `WDS_TERMINAL_SOCKET`으로 지정할 수 있습니다. 클라이언트는 절대 경로인 Unix domain socket만 허용하고, 현재 사용자 소유가 아니거나 group/other 권한이 열린 소켓, 쓰기 가능한 부모 디렉터리는 거부합니다. TCP fallback은 없습니다.

소켓 경로만으로 서버를 신뢰하지 않습니다. WDS.app은 실행할 때마다 32-byte 임시 비밀값을 회전하고 owner-only `terminal.auth` 파일에 `0600`으로 둡니다. 번들 플러그인은 이 파일을 현재 review 호출에서만 읽어 helper의 `WDS_TERMINAL_AUTH_TOKEN` 환경에 전달하며, 명령행 인자·로그·UserDefaults에는 넣지 않습니다. 앱이 종료되면 토큰과 소켓 파일을 제거합니다. 값이 없거나 잘못되면 helper는 stdin을 읽기 전에 `pass_through`로 종료합니다.

## WDS.app 콜백 계약

전송은 4-byte big-endian 길이 뒤에 UTF-8 JSON 한 개가 오는 프레임입니다. 버퍼 및 와이어 메시지는 각각 1 MiB, 1.1 MB로 제한됩니다. 앱은 연결별 요청과 응답을 메모리에서만 처리하고 소켓 파일을 `0600`, 부모 디렉터리를 `0700`으로 만듭니다. connect부터 최종 응답까지 하나의 monotonic deadline을 사용하므로 느린 peer가 ZLE를 무기한 붙잡을 수 없습니다.

클라이언트는 원문을 보내기 전에 nonce만 담긴 인증 프레임을 보냅니다.

```json
{ "protocol_version": 1, "operation": "authenticate_server", "nonce": "..." }
```

앱은 `HMAC-SHA256(token, "wds-terminal-server-v1:" + nonce)`를 반환해야 합니다. nonce와 proof를 검증하기 전에는 buffer request를 전송하지 않습니다.

```json
{ "protocol_version": 1, "nonce": "...", "proof_hmac_sha256": "..." }
```

요청의 핵심 필드는 다음과 같습니다.

```json
{
  "protocol_version": 1,
  "request_id": "...",
  "operation": "resolve_accepted_deletion",
  "surface": { "kind": "zsh_zle" },
  "snapshot": {
    "buffer": "complete current buffer",
    "buffer_sha256": "...",
    "cursor_unicode_scalar_offset": 12
  }
}
```

거절, 취소, 후보 없음은 `pass_through`입니다.

```json
{
  "protocol_version": 1,
  "request_id": "same request id",
  "decision": "pass_through"
}
```

삭제는 사용자가 실제로 수락한 경우에만 다음처럼 응답합니다.

```json
{
  "protocol_version": 1,
  "request_id": "same request id",
  "decision": "accepted_deletion",
  "deletion": {
    "expected_buffer_sha256": "...",
    "expected_cursor_unicode_scalar_offset": 12,
    "range_start_unicode_scalar_offset": 3,
    "range_length_unicode_scalars": 4,
    "expected_target_sha256": "...",
    "acceptance_id": "opaque-nonempty-id",
    "explicitly_accepted": true
  }
}
```

콜백 시간 초과, 소켓 부재, 잘못된 프레임, stale revision, 범위 불일치 등 모든 오류는 조용히 `pass_through`로 폴백합니다. 원문은 프로세스 인자에 넣지 않으므로 `ps`에 노출되지 않습니다.

WDS 자체는 원문을 저장하지 않지만, 최종적으로 제출된 명령이 Zsh history에 기록되는지는 사용자의 기존 셸 설정을 그대로 따릅니다. 이 어댑터는 history 설정도 변경하지 않습니다.

## 대화형 CLI 어댑터 계약

대화형 프로그램이 자체 편집 버퍼를 알고 있다면 제출 직전에 같은 실행 파일을 호출할 수 있습니다.

```text
wds-terminal-adapter resolve \
  --surface interactive-cli \
  --surface-id vendor.program \
  --cursor-scalar-offset N
```

완성된 UTF-8 버퍼는 stdin으로만 보냅니다. stdout은 다음 둘 중 하나입니다.

- `pass\n`
- `replace\n<CURSOR>\n<UTF-8 BUFFER><NUL>`

프로그램은 `replace` 프레임을 완전히 읽고 현재 버퍼 revision이 아직 같을 때만 그 값을 사용해야 합니다. 그 외에는 원래 버퍼를 원래 제출 동작으로 전달해야 합니다. helper 호출에는 유효한 `WDS_TERMINAL_AUTH_TOKEN` 환경도 필요합니다. 이 계약을 대상 CLI가 제공하지 않는 동안에는 PTY wrapper만으로 안전한 내부 프롬프트 지원을 선언할 수 없습니다.

향후 `wds-run`을 추가한다면 PTY는 화면/I/O 전달만 담당하고, 대상 프로그램이 별도 Unix socket으로 의미적 `buffer snapshot`과 `submit intent`를 알려주는 경우에만 편집을 허용해야 합니다. side-channel이 없는 프로그램은 바이트를 그대로 전달하는 관찰 불가 모드여야 합니다.

## 검증

```bash
swift test --package-path native/WDSTerminalAdapter
zsh -n native/WDSTerminalAdapter/Integration/wds-zle.plugin.zsh
```
