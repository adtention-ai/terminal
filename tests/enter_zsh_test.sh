#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/shell-integration.zsh"

fail() {
  echo "not ok - $1" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"

  [[ -f "$file" ]] || fail "$label: missing file $file"
  grep -Fq -- "$needle" "$file" || fail "$label: expected $file to contain $needle"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  [[ "$haystack" == *"$needle"* ]] || fail "$label: expected output to contain $needle"
}

wait_for_file_text() {
  local file="$1"
  local needle="$2"

  for _ in {1..50}; do
    if [[ -f "$file" ]] && grep -Fq -- "$needle" "$file"; then
      return 0
    fi
    sleep 0.05
  done

  return 1
}

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

FAKE_BIN="$TMPDIR/bin"
FAKE_LOG="$TMPDIR/client.log"
FAKE_STDIN="$TMPDIR/client.stdin"
HOME_DIR="$TMPDIR/home"
CACHE_DIR="$TMPDIR/cache"

mkdir -p "$FAKE_BIN" "$HOME_DIR" "$CACHE_DIR"

cat >"$FAKE_BIN/adtention-terminal" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${ADTENTION_FAKE_SLEEP:-}" != "" ]]; then
  sleep "$ADTENTION_FAKE_SLEEP"
fi

{
  printf 'argv:'
  for arg in "$@"; do
    printf ' <%s>' "$arg"
  done
  printf '\n'
} >>"$ADTENTION_FAKE_LOG"

cat >>"$ADTENTION_FAKE_STDIN"
printf '\n---stdin-end---\n' >>"$ADTENTION_FAKE_STDIN"
FAKE
chmod +x "$FAKE_BIN/adtention-terminal"

test_pure_helpers_and_async_refresh() {
  ADTENTION_CACHE_DIR="$CACHE_DIR" \
  ADTENTION_FAKE_LOG="$FAKE_LOG" \
  ADTENTION_FAKE_STDIN="$FAKE_STDIN" \
  HOME="$HOME_DIR" \
  PATH="$FAKE_BIN:$PATH" \
  SCRIPT="$SCRIPT" \
  zsh -f <<'ZSH'
set -e
source "$SCRIPT"

expect_skip() {
  if __adtention_should_trigger_enter "$1"; then
    print -u2 -- "expected skip for: <$1>"
    exit 10
  fi
}

expect_trigger() {
  if ! __adtention_should_trigger_enter "$1"; then
    print -u2 -- "expected trigger for: <$1>"
    exit 11
  fi
}

expect_skip ""
expect_skip "   "
expect_skip "# comment"
expect_skip "   # comment"
expect_skip "adtention-open"
expect_skip "adtention-refresh --now"
expect_skip "adtention-terminal refresh ."
expect_trigger "npm test"

event="$(__adtention_build_enter_event "npm test")"
[[ "$event" == *'"source"'* ]] || exit 20
[[ "$event" == *'terminal-enter'* ]] || exit 21
[[ "$event" == *'"shell"'* ]] || exit 22
[[ "$event" == *'zsh'* ]] || exit 23
[[ "$event" == *'"command"'* ]] || exit 24
[[ "$event" == *'npm test'* ]] || exit 25
[[ "$event" == *'"cwd"'* ]] || exit 26
[[ "$event" == *"$PWD"* ]] || exit 27

__adtention_enter_refresh_async "npm test"
ZSH

  wait_for_file_text "$FAKE_LOG" "argv: <refresh>" || fail "async refresh did not call fake client"
  assert_file_contains "$FAKE_LOG" "argv: <refresh> <$ROOT>" "refresh cwd argument"
  assert_file_contains "$FAKE_STDIN" "terminal-enter" "refresh event source"
  assert_file_contains "$FAKE_STDIN" "npm test" "refresh event command"
}

test_async_refresh_does_not_block() {
  : >"$FAKE_LOG"
  : >"$FAKE_STDIN"

  ADTENTION_CACHE_DIR="$CACHE_DIR" \
  ADTENTION_FAKE_LOG="$FAKE_LOG" \
  ADTENTION_FAKE_SLEEP="1" \
  ADTENTION_FAKE_STDIN="$FAKE_STDIN" \
  HOME="$HOME_DIR" \
  PATH="$FAKE_BIN:$PATH" \
  SCRIPT="$SCRIPT" \
  zsh -f <<'ZSH'
set -e
zmodload zsh/datetime
source "$SCRIPT"

start="$EPOCHREALTIME"
__adtention_enter_refresh_async "npm test"
elapsed=$(( EPOCHREALTIME - start ))

if (( elapsed > 0.5 )); then
  print -u2 -- "refresh blocked for $elapsed seconds"
  exit 30
fi
ZSH

  wait_for_file_text "$FAKE_LOG" "argv: <refresh>" || fail "sleeping async refresh never completed"
}

test_zle_wrapper_accepts_line_and_skips_refresh_when_needed() {
  local zle_calls="$TMPDIR/zle.calls"
  : >"$FAKE_LOG"
  : >"$FAKE_STDIN"

  ADTENTION_CACHE_DIR="$CACHE_DIR" \
  ADTENTION_FAKE_LOG="$FAKE_LOG" \
  ADTENTION_FAKE_STDIN="$FAKE_STDIN" \
  HOME="$HOME_DIR" \
  PATH="$FAKE_BIN:$PATH" \
  SCRIPT="$SCRIPT" \
  ZLE_CALLS="$zle_calls" \
  zsh -f <<'ZSH'
set -e

zle() {
  print -r -- "$*" >>"$ZLE_CALLS"
}

source "$SCRIPT"

BUFFER="npm test"
__adtention_accept_line

BUFFER="   # comment"
__adtention_accept_line
ZSH

  assert_file_contains "$zle_calls" "-N accept-line __adtention_accept_line" "zle wrapper registration"
  [[ "$(grep -Fc -- ".accept-line" "$zle_calls")" -eq 2 ]] || fail "wrapper must call zle .accept-line for both commands"

  wait_for_file_text "$FAKE_LOG" "argv: <refresh>" || fail "wrapper did not refresh for real command"
  [[ "$(grep -Fc -- "argv: <refresh>" "$FAKE_LOG")" -eq 1 ]] || fail "wrapper should not refresh skipped command"
}

test_precmd_displays_cache_without_refresh() {
  local output
  : >"$FAKE_LOG"
  rm -f "$CACHE_DIR/last_render_seen"
  printf 'title attention line\nprompt attention line\n' >"$CACHE_DIR/terminal.txt"

  output="$(
    ADTENTION_CACHE="$CACHE_DIR" \
    ADTENTION_FAKE_LOG="$FAKE_LOG" \
    ADTENTION_FAKE_STDIN="$FAKE_STDIN" \
    HOME="$HOME_DIR" \
    PATH="$FAKE_BIN:$PATH" \
    SCRIPT="$SCRIPT" \
    zsh -f <<'ZSH'
set -e
source "$SCRIPT"
for hook in $precmd_functions; do
  "$hook"
done
ZSH
  )"

  assert_contains "$output" "prompt attention line" "precmd cache display"
  [[ "$output" != *$'title attention line\n'* ]] || fail "precmd must not print title line as prompt text"
  [[ -f "$CACHE_DIR/last_render_seen" ]] || fail "precmd must write render heartbeat"
  [[ ! -s "$FAKE_LOG" ]] || fail "precmd display must not call refresh client"
}

test_pure_helpers_and_async_refresh
test_async_refresh_does_not_block
test_zle_wrapper_accepts_line_and_skips_refresh_when_needed
test_precmd_displays_cache_without_refresh

echo "ok - zsh enter wrapper"
