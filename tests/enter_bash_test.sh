#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/shell-integration.bash"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_success() {
  "$@" || fail "expected success: $*"
}

assert_failure() {
  if "$@"; then
    fail "expected failure: $*"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "expected output to contain: $needle"$'\n'"actual: $haystack" ;;
  esac
}

test_should_trigger_enter() {
  # shellcheck source=/dev/null
  source "$SCRIPT"

  assert_failure __adtention_should_trigger_enter ""
  assert_failure __adtention_should_trigger_enter "   "
  assert_failure __adtention_should_trigger_enter "# comment"
  assert_failure __adtention_should_trigger_enter " adtention-open "
  assert_failure __adtention_should_trigger_enter "adtention-refresh --now"
  assert_failure __adtention_should_trigger_enter "adtention-terminal refresh ."
  assert_success __adtention_should_trigger_enter "npm test"
}

test_build_enter_event_json() {
  local tmpdir event
  tmpdir="$(mktemp -d)"

  event="$(
    cd "$tmpdir"
    # shellcheck source=/dev/null
    source "$SCRIPT"
    __adtention_build_enter_event 'npm "test"'
  )"

  assert_contains "$event" '"source":"terminal-enter"'
  assert_contains "$event" '"shell":"bash"'
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
exit "${ADTENTION_TEST_EXIT_CODE:-0}"
FAKE
  chmod +x "$bindir/adtention-terminal"

  (
    cd "$workdir"
    PATH="$bindir:$PATH"
    ADTENTION_TEST_CALL_FILE="$call_file"
    ADTENTION_TEST_STDIN_FILE="$stdin_file"
    export ADTENTION_TEST_CALL_FILE ADTENTION_TEST_STDIN_FILE
    # shellcheck source=/dev/null
    source "$SCRIPT"
    __adtention_enter_refresh_async "npm test"
    wait
  )

  assert_contains "$(cat "$call_file")" "refresh $workdir"
  assert_contains "$(cat "$stdin_file")" '"source":"terminal-enter"'
  assert_contains "$(cat "$stdin_file")" '"shell":"bash"'
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
    PATH="$bindir:$PATH"
    ADTENTION_TEST_CALL_FILE="$call_file"
    ADTENTION_TEST_STDIN_FILE="$stdin_file"
    export ADTENTION_TEST_CALL_FILE ADTENTION_TEST_STDIN_FILE
    # shellcheck source=/dev/null
    source "$SCRIPT"
    __adtention_enter_refresh_async "   "
    wait
  )

  [[ ! -e "$call_file" ]] || fail "blank input should not call adtention-terminal"
  [[ ! -e "$stdin_file" ]] || fail "blank input should not write event JSON"
}

test_refresh_async_does_not_fail_shell_when_client_fails() {
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
exit 37
FAKE
  chmod +x "$bindir/adtention-terminal"

  (
    cd "$workdir"
    PATH="$bindir:$PATH"
    ADTENTION_TEST_CALL_FILE="$call_file"
    ADTENTION_TEST_STDIN_FILE="$stdin_file"
    export ADTENTION_TEST_CALL_FILE ADTENTION_TEST_STDIN_FILE
    # shellcheck source=/dev/null
    source "$SCRIPT"
    __adtention_enter_refresh_async "npm test"
    wait || true
  )

  [[ -e "$call_file" ]] || fail "failing fake client should still have been called"
}

test_prompt_display_reads_cache_and_marks_render() {
  local tmpdir cache output
  tmpdir="$(mktemp -d)"
  cache="$tmpdir/cache"
  mkdir -p "$cache"
  printf 'title attention line\nprompt attention line\n' >"$cache/terminal.txt"

  output="$(
    ADTENTION_CACHE="$cache" bash --noprofile --norc -c "
      source '$SCRIPT'
      __adtention_prompt_display
    "
  )"

  assert_contains "$output" "prompt attention line"
  [[ "$output" != *$'title attention line\n'* ]] || fail "prompt display must not print title line as prompt text"
  [[ -f "$cache/last_render_seen" ]] || fail "prompt display should write last_render_seen"
}

test_bash_enter_binding_is_experimental_and_opt_in() {
  local default_bindings experimental_bindings

  default_bindings="$(
    bash --noprofile --norc -i -c "source '$SCRIPT'; bind -p; bind -s" 2>/dev/null || true
  )"
  case "$default_bindings" in
    *'"\C-m": "\C-x\C-a\C-j"'*) fail "bash Enter macro should not install unless ADTENTION_BASH_ENTER_EXPERIMENTAL=1" ;;
  esac

  experimental_bindings="$(
    ADTENTION_BASH_ENTER_EXPERIMENTAL=1 bash --noprofile --norc -i -c "source '$SCRIPT'; bind -p; bind -s; declare -F __adtention_bash_enter_hook" 2>/dev/null
  )"

  assert_contains "$experimental_bindings" "__adtention_bash_enter_hook"
  assert_contains "$experimental_bindings" '\C-x\C-a\C-j'
  assert_contains "$experimental_bindings" '"\C-j": accept-line'
}

test_should_trigger_enter
test_build_enter_event_json
test_refresh_async_calls_client_with_event_on_stdin
test_refresh_async_skips_non_triggering_lines
test_refresh_async_does_not_fail_shell_when_client_fails
test_prompt_display_reads_cache_and_marks_render
test_bash_enter_binding_is_experimental_and_opt_in

printf 'ok - enter_bash_test\n'
