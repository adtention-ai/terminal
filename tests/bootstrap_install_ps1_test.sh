#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.ps1"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

assert_executable() {
  [ -x "$1" ] || fail "not executable: $1"
}

assert_contains() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "$file should contain: $text"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

platform_asset_name() {
  local os arch ext
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  ext=""

  case "$os" in
    darwin) os="darwin" ;;
    linux) os="linux" ;;
    mingw*|msys*|cygwin*) os="windows"; ext=".exe" ;;
    *) fail "unsupported test OS: $os" ;;
  esac

  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) fail "unsupported test architecture: $arch" ;;
  esac

  printf 'adtention-terminal-%s-%s%s\n' "$os" "$arch" "$ext"
}

if ! command -v pwsh >/dev/null 2>&1; then
  printf 'bootstrap_install_ps1_test.sh: skipped because pwsh is not installed\n'
  exit 0
fi

assert_file "$INSTALL"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

release_dir="$tmp/release"
runtime_root="$tmp/runtime"
home="$tmp/home"
install_root="$tmp/install root"
profile="$tmp/home/profile.ps1"
asset_name="$(platform_asset_name)"
runtime_asset="adtention-terminal-runtime.tar.gz"

mkdir -p "$release_dir" "$runtime_root/bin" "$runtime_root/scripts" "$home"

printf '#!/usr/bin/env sh\nprintf "fake adtention-terminal binary\\n"\n' >"$release_dir/$asset_name"
chmod +x "$release_dir/$asset_name"

cp "$ROOT/bin/adtention-terminal" "$runtime_root/bin/adtention-terminal"
cp "$ROOT/scripts/install-shell-integration.ps1" "$runtime_root/scripts/install-shell-integration.ps1"
cp "$ROOT/scripts/shell-integration.ps1" "$runtime_root/scripts/shell-integration.ps1"
cp "$ROOT/README.md" "$runtime_root/README.md"
chmod +x "$runtime_root/bin/adtention-terminal"

(
  cd "$runtime_root"
  tar -czf "$release_dir/$runtime_asset" bin scripts README.md
)

{
  printf '%s  %s\n' "$(sha256_file "$release_dir/$asset_name")" "$asset_name"
  printf '%s  %s\n' "$(sha256_file "$release_dir/$runtime_asset")" "$runtime_asset"
} >"$release_dir/SHA256SUMS"

HOME="$home" \
ADTENTION_INSTALL_ROOT="$install_root" \
ADTENTION_RELEASE_BASE="file://$release_dir" \
ADTENTION_VERSION="v9.9.9" \
ADTENTION_PS_PROFILE="$profile" \
  pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTALL"

assert_executable "$install_root/bin/$asset_name"
assert_executable "$install_root/bin/adtention-terminal"
assert_file "$install_root/bin/SHA256SUMS"
assert_file "$install_root/scripts/install-shell-integration.ps1"
assert_contains "$profile" "# >>> adtention-terminal >>>"
assert_contains "$profile" "ADTENTION_INSTALL_ROOT"
assert_contains "$profile" "\$env:Path"

output="$("$install_root/bin/adtention-terminal")"
case "$output" in
  *"fake adtention-terminal binary"*) ;;
  *) fail "launcher did not execute installed platform binary: $output" ;;
esac

printf 'bootstrap_install_ps1_test.sh: ok\n'
