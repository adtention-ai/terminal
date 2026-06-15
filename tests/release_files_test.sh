#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
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

assert_file "$ROOT/build.sh"
assert_file "$ROOT/.github/workflows/ci.yml"
assert_file "$ROOT/.github/workflows/release.yml"

assert_contains "$ROOT/build.sh" "cargo zigbuild"
assert_contains "$ROOT/build.sh" "adtention-terminal-darwin-amd64"
assert_contains "$ROOT/build.sh" "adtention-terminal-darwin-arm64"
assert_contains "$ROOT/build.sh" "adtention-terminal-linux-amd64"
assert_contains "$ROOT/build.sh" "adtention-terminal-linux-arm64"
assert_contains "$ROOT/build.sh" "adtention-terminal-windows-amd64.exe"
assert_contains "$ROOT/build.sh" "SHA256SUMS"

assert_contains "$ROOT/.github/workflows/ci.yml" "./build.sh"
assert_contains "$ROOT/.github/workflows/ci.yml" "git diff --quiet -- bin/"
assert_contains "$ROOT/.github/workflows/release.yml" "gh release create"
assert_contains "$ROOT/.github/workflows/release.yml" "Tag must match Cargo.toml version"
assert_contains "$ROOT/.github/workflows/release.yml" "bin/SHA256SUMS"

if [ -d "$ROOT/bin" ]; then
  assert_file "$ROOT/bin/adtention-terminal"
  assert_file "$ROOT/bin/SHA256SUMS"
fi

printf 'release_files_test.sh: ok\n'
