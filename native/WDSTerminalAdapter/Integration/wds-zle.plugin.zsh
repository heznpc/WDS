# WDS ZLE integration. Source this file explicitly in the current interactive
# shell. It never edits .zshrc, never installs a global event tap, and binds no
# keys on its own.

[[ -o interactive ]] || return 0

typeset -g _WDS_ZLE_PLUGIN_DIR="${${(%):-%N}:A:h}"
if [[ -z "${WDS_TERMINAL_ADAPTER_BIN:-}" ]]; then
  if [[ -x "${_WDS_ZLE_PLUGIN_DIR}/../../Helpers/wds-terminal-adapter" ]]; then
    typeset -g WDS_TERMINAL_ADAPTER_BIN="${_WDS_ZLE_PLUGIN_DIR}/../../Helpers/wds-terminal-adapter"
  else
    typeset -g WDS_TERMINAL_ADAPTER_BIN="${_WDS_ZLE_PLUGIN_DIR}/../.build/release/wds-terminal-adapter"
  fi
fi

_wds_terminal_try_accepted_deletion() {
  emulate -L zsh
  setopt localoptions noaliases pipefail extendedglob

  # ZLE's CURSOR is a byte offset in single-byte locales but this protocol uses
  # Unicode scalar offsets. Refuse non-UTF-8 locales instead of guessing.
  [[ -o multibyte ]] || return 1
  zmodload zsh/langinfo 2>/dev/null || return 1
  [[ "${${(U)langinfo[CODESET]}//-}" == UTF8 ]] || return 1

  local helper="${WDS_TERMINAL_ADAPTER_BIN}"
  [[ -x "${helper}" ]] || return 1

  local auth_file="${WDS_TERMINAL_AUTH_FILE:-${HOME}/Library/Application Support/WDS/terminal.auth}"
  [[ -f "${auth_file}" ]] || return 1
  local auth_token="$(<"${auth_file}")"
  (( ${#auth_token} == 64 )) || return 1
  [[ "${auth_token}" == [0-9a-f]## ]] || return 1

  local original_buffer="${BUFFER}"
  local original_cursor="${CURSOR}"
  local timeout_ms="${WDS_TERMINAL_TIMEOUT_MS:-15000}"
  [[ "${timeout_ms}" == <-> ]] || timeout_ms=15000

  local -a adapter_args
  adapter_args=(
    resolve
    --surface zsh-zle
    --cursor-scalar-offset "${original_cursor}"
    --timeout-ms "${timeout_ms}"
  )
  if [[ -n "${WDS_TERMINAL_SOCKET:-}" ]]; then
    adapter_args+=(--socket "${WDS_TERMINAL_SOCKET}")
  fi

  local response_fd response_kind response_cursor replacement
  exec {response_fd}< <(
    builtin print -rn -- "${original_buffer}" |
      WDS_TERMINAL_AUTH_TOKEN="${auth_token}" command "${helper}" "${adapter_args[@]}"
  )

  if ! IFS= read -r -u "${response_fd}" response_kind; then
    exec {response_fd}<&-
    return 1
  fi
  if [[ "${response_kind}" != replace ]]; then
    exec {response_fd}<&-
    return 1
  fi
  if ! IFS= read -r -u "${response_fd}" response_cursor; then
    exec {response_fd}<&-
    return 1
  fi
  if ! IFS= read -r -d '' -u "${response_fd}" replacement; then
    exec {response_fd}<&-
    return 1
  fi
  exec {response_fd}<&-

  # ZLE cannot change while this widget is running, but traps and nested widgets
  # can be surprising. Recheck the complete buffer and cursor immediately before
  # applying the helper's already-validated exact deletion.
  [[ "${BUFFER}" == "${original_buffer}" ]] || return 1
  (( CURSOR == original_cursor )) || return 1
  [[ "${response_cursor}" == <-> ]] || return 1
  (( response_cursor <= ${#replacement} )) || return 1

  BUFFER="${replacement}"
  CURSOR="${response_cursor}"
  return 0
}

_wds_terminal_review_buffer() {
  if _wds_terminal_try_accepted_deletion; then
    zle -M 'WDS: accepted deletion applied'
  else
    zle -M 'WDS: buffer unchanged'
  fi
  zle redisplay
}

zle -N wds-review-buffer _wds_terminal_review_buffer
