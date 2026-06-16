#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$ROOT/scripts/install-shell-integration.sh"
UNINSTALL_SH="$ROOT/scripts/uninstall-shell-integration.sh"
INSTALL_PS1="$ROOT/scripts/install-shell-integration.ps1"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

assert_contains() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "$file should contain: $text"
}

assert_not_contains() {
  local file="$1"
  local text="$2"
  if grep -Fq -- "$text" "$file"; then
    fail "$file should not contain: $text"
  fi
}

assert_file "$INSTALL_SH"
assert_file "$UNINSTALL_SH"
assert_file "$INSTALL_PS1"
assert_contains "$INSTALL_SH" "ADTENTION_INSTALL_ROOT"
assert_contains "$INSTALL_SH" "ADTENTION_CACHE"
assert_contains "$INSTALL_SH" "--diagnose"
assert_contains "$UNINSTALL_SH" "ADTENTION_INSTALL_ROOT"
assert_contains "$INSTALL_PS1" "shell-integration.ps1"
assert_contains "$INSTALL_PS1" "-Diagnose"
assert_not_contains "$INSTALL_SH" "codex plugin"
assert_not_contains "$UNINSTALL_SH" "codex plugin"
assert_not_contains "$INSTALL_PS1" "codex plugin"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

profile="$tmp/.zshrc"
cache="$tmp/cache with spaces"
install_root="$tmp/custom root"
mkdir -p "$install_root/scripts" "$cache"
printf '# existing user config\n' >"$profile"

ADTENTION_PROFILE="$profile" \
ADTENTION_INSTALL_ROOT="$install_root" \
ADTENTION_CACHE="$cache" \
  "$INSTALL_SH"

ADTENTION_PROFILE="$profile" \
ADTENTION_INSTALL_ROOT="$install_root" \
ADTENTION_CACHE="$cache" \
  "$INSTALL_SH"

block_count="$(grep -c '# >>> adtention-terminal >>>' "$profile")"
[ "$block_count" -eq 1 ] || fail "installer should write one managed block, found $block_count"
assert_contains "$profile" "export ADTENTION_INSTALL_ROOT="
assert_contains "$profile" "custom root"
assert_contains "$profile" "export ADTENTION_CACHE="
assert_contains "$profile" "cache with spaces"
assert_contains "$profile" 'export PATH="$ADTENTION_INSTALL_ROOT/bin:$PATH"'
assert_contains "$profile" "shell-integration.zsh"
assert_contains "$profile" "shell-integration.bash"
assert_contains "$profile" "adtention-terminal doctor"

printf 'secret command: npm run private-project\n' >"$cache/last_skipped"
diagnose_output="$(
  ADTENTION_PROFILE="$profile" \
  ADTENTION_INSTALL_ROOT="$install_root" \
  ADTENTION_CACHE="$cache" \
    "$INSTALL_SH" --diagnose
)"
case "$diagnose_output" in
  *"integration: installed"* ) ;;
  * ) fail "diagnose should report installed integration" ;;
esac
case "$diagnose_output" in
  *"cache: $cache"* ) ;;
  * ) fail "diagnose should report cache path" ;;
esac
case "$diagnose_output" in
  *"private-project"* | *"npm run"* ) fail "diagnose should not print private command text" ;;
esac

ADTENTION_PROFILE="$profile" "$UNINSTALL_SH"
if grep -Fq '# >>> adtention-terminal >>>' "$profile"; then
  fail "uninstaller should remove managed block"
fi
assert_contains "$profile" "# existing user config"

home_both="$tmp/home-both"
mkdir -p "$home_both" "$install_root/scripts"
HOME="$home_both" \
ADTENTION_INSTALL_ROOT="$install_root" \
ADTENTION_CACHE="$cache" \
  "$INSTALL_SH" >/dev/null
assert_file "$home_both/.zshrc"
assert_file "$home_both/.bashrc"
assert_contains "$home_both/.zshrc" "shell-integration.zsh"
assert_contains "$home_both/.bashrc" "shell-integration.bash"
HOME="$home_both" "$UNINSTALL_SH" >/dev/null
assert_not_contains "$home_both/.zshrc" "# >>> adtention-terminal >>>"
assert_not_contains "$home_both/.bashrc" "# >>> adtention-terminal >>>"

if command -v pwsh >/dev/null 2>&1; then
  ps_profile="$tmp/Microsoft.PowerShell_profile.ps1"
  ADTENTION_PS_PROFILE="$ps_profile" \
  ADTENTION_INSTALL_ROOT="$install_root" \
  ADTENTION_CACHE="$cache" \
    pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTALL_PS1"

  ADTENTION_PS_PROFILE="$ps_profile" \
  ADTENTION_INSTALL_ROOT="$install_root" \
  ADTENTION_CACHE="$cache" \
    pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTALL_PS1"

  block_count="$(grep -c '# >>> adtention-terminal >>>' "$ps_profile")"
  [ "$block_count" -eq 1 ] || fail "PowerShell installer should write one managed block, found $block_count"
  assert_contains "$ps_profile" "\$env:ADTENTION_INSTALL_ROOT = '$install_root'"
  assert_contains "$ps_profile" "\$env:ADTENTION_CACHE = '$cache'"
  assert_contains "$ps_profile" "\$env:Path"
  assert_contains "$ps_profile" "shell-integration.ps1"
fi

echo "install_test.sh: ok"
