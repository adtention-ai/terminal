#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/shell-integration.fish"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "expected output to contain: $needle"$'\n'"actual: $haystack" ;;
  esac
}

test_fish_binding_uses_native_execute_function() {
  local functions_text
  functions_text="$(cat "$SCRIPT")"

  assert_contains "$functions_text" 'bind \r __adtention_fish_accept_line'
  assert_contains "$functions_text" 'commandline -f execute'
  assert_contains "$functions_text" '__adtention_fish_prompt_display'
  assert_contains "$functions_text" 'last_render_seen'
  assert_contains "$functions_text" "sed -n '1p'"
  assert_contains "$functions_text" "sed -n '2p'"
}

test_fish_binding_uses_native_execute_function

if ! command -v fish >/dev/null 2>&1; then
  printf 'ok - enter_fish_test skipped because fish is not installed\n'
  exit 0
fi

run_fish() {
  fish --no-config -c "$1"
}

test_should_trigger_enter() {
  run_fish "
    source '$SCRIPT'
    __adtention_fish_should_trigger_enter ''
    and exit 1
    __adtention_fish_should_trigger_enter '   '
    and exit 1
    __adtention_fish_should_trigger_enter '# comment'
    and exit 1
    __adtention_fish_should_trigger_enter ' adtention-open '
    and exit 1
    __adtention_fish_should_trigger_enter 'adtention-refresh --now'
    and exit 1
    __adtention_fish_should_trigger_enter 'adtention-terminal refresh .'
    and exit 1
    __adtention_fish_should_trigger_enter 'npm test'
    or exit 1
  "
}

test_build_enter_event_json() {
  local tmpdir event
  tmpdir="$(mktemp -d)"

  event="$(
    cd "$tmpdir"
    run_fish "
      source '$SCRIPT'
      __adtention_fish_build_enter_event 'npm \"test\"'
    "
  )"

  assert_contains "$event" '"source":"terminal-enter"'
  assert_contains "$event" '"shell":"fish"'
  assert_contains "$event" '"command":"npm \"test\""'
  assert_contains "$event" "\"cwd\":\"$tmpdir\""
}

test_refresh_async_calls_client_with_event_on_stdin() {
  local tmpdir workdir bindir call_file stdin_file
  tmpdir="$(mktemp -d)"
  workdir="$tmpdir/work"
  bindir="$tmpdir/bin"
  call_file="$tmpdir/call"
  stdin_file="$tmpdir/stdin"
  mkdir -p "$workdir" "$bindir"

  cat >"$bindir/adtention-terminal" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$ADTENTION_TEST_CALL_FILE"
cat >"$ADTENTION_TEST_STDIN_FILE"
FAKE
  chmod +x "$bindir/adtention-terminal"

  (
    cd "$workdir"
    PATH="$bindir:$PATH" \
    ADTENTION_TEST_CALL_FILE="$call_file" \
    ADTENTION_TEST_STDIN_FILE="$stdin_file" \
    run_fish "
      source '$SCRIPT'
      __adtention_fish_enter_refresh_async 'npm test'
      wait
    "
  )

  assert_contains "$(cat "$call_file")" "refresh $workdir"
  assert_contains "$(cat "$stdin_file")" '"source":"terminal-enter"'
  assert_contains "$(cat "$stdin_file")" '"shell":"fish"'
  assert_contains "$(cat "$stdin_file")" '"command":"npm test"'
  assert_contains "$(cat "$stdin_file")" "\"cwd\":\"$workdir\""
}

test_refresh_async_skips_non_triggering_lines() {
  local tmpdir workdir bindir call_file stdin_file
  tmpdir="$(mktemp -d)"
  workdir="$tmpdir/work"
  bindir="$tmpdir/bin"
  call_file="$tmpdir/call"
  stdin_file="$tmpdir/stdin"
  mkdir -p "$workdir" "$bindir"

  cat >"$bindir/adtention-terminal" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$ADTENTION_TEST_CALL_FILE"
cat >"$ADTENTION_TEST_STDIN_FILE"
FAKE
  chmod +x "$bindir/adtention-terminal"

  (
    cd "$workdir"
    PATH="$bindir:$PATH" \
    ADTENTION_TEST_CALL_FILE="$call_file" \
    ADTENTION_TEST_STDIN_FILE="$stdin_file" \
    run_fish "
      source '$SCRIPT'
      __adtention_fish_enter_refresh_async '   '
      wait
    "
  )

  [[ ! -e "$call_file" ]] || fail "blank input should not call adtention-terminal"
  [[ ! -e "$stdin_file" ]] || fail "blank input should not write event JSON"
}

test_should_trigger_enter
test_build_enter_event_json
test_refresh_async_calls_client_with_event_on_stdin
test_refresh_async_skips_non_triggering_lines

printf 'ok - enter_fish_test\n'
