#!/usr/bin/env sh
set -eu

REPO="adtention-ai/terminal"
DEFAULT_INSTALL_ROOT="$HOME/.adtention-terminal"
RUNTIME_ASSET="adtention-terminal-runtime.tar.gz"
SUMS_ASSET="SHA256SUMS"

log() {
  printf 'adtention-terminal: %s\n' "$*"
}

fail() {
  printf 'adtention-terminal: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

checksum_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

latest_version() {
  if [ -n "${ADTENTION_VERSION:-}" ]; then
    printf '%s\n' "$ADTENTION_VERSION"
    return
  fi

  curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1
}

platform_asset_name() {
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"

  case "$os" in
    darwin) os="darwin" ;;
    linux) os="linux" ;;
    *) fail "unsupported OS: $os" ;;
  esac

  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) fail "unsupported CPU architecture: $arch" ;;
  esac

  printf 'adtention-terminal-%s-%s\n' "$os" "$arch"
}

asset_url() {
  name="$1"
  if [ -n "${ADTENTION_RELEASE_BASE:-}" ]; then
    printf '%s/%s\n' "${ADTENTION_RELEASE_BASE%/}" "$name"
  else
    printf 'https://github.com/%s/releases/download/%s/%s\n' "$REPO" "$version" "$name"
  fi
}

download_asset() {
  name="$1"
  dest="$2"
  curl -fsSL "$(asset_url "$name")" -o "$dest"
}

expected_checksum() {
  name="$1"
  awk -v f="$name" '
    {
      file = $2
      sub(/^\*/, "", file)
      n = split(file, parts, "/")
      if (parts[n] == f) {
        print tolower($1)
        exit
      }
    }
  ' "$tmp/$SUMS_ASSET"
}

verify_asset() {
  name="$1"
  path="$2"
  expected="$(expected_checksum "$name")"
  [ -n "$expected" ] || fail "$SUMS_ASSET does not list $name"
  actual="$(checksum_file "$path" | tr '[:upper:]' '[:lower:]')"
  [ "$expected" = "$actual" ] || fail "checksum mismatch for $name"
}

need curl
need tar
need awk
need sed
need uname
need tr

version="$(latest_version)"
[ -n "$version" ] || fail "could not resolve latest release version"

install_root="${ADTENTION_INSTALL_ROOT:-$DEFAULT_INSTALL_ROOT}"
asset="$(platform_asset_name)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

log "installing $version into $install_root"

download_asset "$SUMS_ASSET" "$tmp/$SUMS_ASSET"
download_asset "$RUNTIME_ASSET" "$tmp/$RUNTIME_ASSET"
download_asset "$asset" "$tmp/$asset"

verify_asset "$RUNTIME_ASSET" "$tmp/$RUNTIME_ASSET"
verify_asset "$asset" "$tmp/$asset"

mkdir -p "$install_root/bin"
tar -xzf "$tmp/$RUNTIME_ASSET" -C "$install_root"
cp "$tmp/$asset" "$install_root/bin/$asset"
cp "$tmp/$SUMS_ASSET" "$install_root/bin/$SUMS_ASSET"
chmod +x "$install_root/bin/$asset" "$install_root/bin/adtention-terminal"

export ADTENTION_INSTALL_ROOT="$install_root"
export PATH="$install_root/bin:$PATH"

"$install_root/scripts/install-shell-integration.sh"

log "installed. Open a new terminal, or run: export PATH=\"$install_root/bin:\$PATH\""
