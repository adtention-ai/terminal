#!/bin/sh
# Release build of the ADtention Terminal client binaries.
#
# This follows the same release shape as ADtention Codex: one root build script
# writes platform binaries into bin/, and CI/release use this script as the
# source of truth. Rust needs a linker for each target, so the release path uses
# a pinned Docker builder with Zig through cargo-zigbuild.
set -eu

cd "$(dirname "$0")"

CLIENT_DIR="client"
BIN_DIR="bin"
VERSION="v$(grep '^version[[:space:]]*=' "$CLIENT_DIR/Cargo.toml" | head -1 \
  | sed -E 's/.*"([^"]+)".*/\1/')"

echo "Building adtention-terminal $VERSION"

write_launcher() {
  mkdir -p "$BIN_DIR"
  cat > "$BIN_DIR/adtention-terminal" <<'SH'
#!/bin/sh
set -eu

d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)

case "$os" in
  darwin) os=darwin ;;
  linux) os=linux ;;
esac

case "$arch" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
esac

exec "$d/adtention-terminal-$os-$arch" "$@"
SH
  chmod +x "$BIN_DIR/adtention-terminal"
}

if [ "${ADTENTION_BUILD_LOCAL_ONLY:-0}" = "1" ]; then
  cargo build --release --locked --manifest-path "$CLIENT_DIR/Cargo.toml"
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  case "$os" in
    darwin) os=darwin ;;
    linux) os=linux ;;
  esac
  case "$arch" in
    x86_64|amd64) arch=amd64 ;;
    arm64|aarch64) arch=arm64 ;;
  esac
  mkdir -p "$BIN_DIR"
  cp "$CLIENT_DIR/target/release/adtention-terminal" "$BIN_DIR/adtention-terminal-$os-$arch"
  chmod +x "$BIN_DIR/adtention-terminal-$os-$arch"
  write_launcher
  echo "Wrote $BIN_DIR/adtention-terminal-$os-$arch"
  exit 0
fi

docker run --rm --platform linux/amd64 \
  -e CLIENT_DIR="$CLIENT_DIR" \
  -e ZIG_VERSION="${ZIG_VERSION:-0.13.0}" \
  -e CARGO_ZIGBUILD_VERSION="${CARGO_ZIGBUILD_VERSION:-0.20.1}" \
  -v "$PWD":/w \
  -w /w \
  rust:1.83.0-bookworm sh -euc '
    zig_dir="/tmp/zig-linux-x86_64-$ZIG_VERSION"
    curl -fsSL "https://ziglang.org/download/$ZIG_VERSION/zig-linux-x86_64-$ZIG_VERSION.tar.xz" \
      | tar -xJ -C /tmp
    export PATH="$zig_dir:$PATH"

    cargo install --locked --version "$CARGO_ZIGBUILD_VERSION" cargo-zigbuild >/dev/null
    rustup target add \
      x86_64-apple-darwin \
      aarch64-apple-darwin \
      x86_64-unknown-linux-gnu \
      aarch64-unknown-linux-gnu \
      x86_64-pc-windows-gnu >/dev/null

    bin="bin"
    mkdir -p "$bin"
    rm -f "$bin"/adtention-terminal-* "$bin/SHA256SUMS"

    normalize_windows_pe() {
      file="$1"
      pe_offset="$(od -An -t u4 -j 60 -N 4 "$file" | tr -d "[:space:]")"
      timestamp_offset="$((pe_offset + 8))"
      printf "\000\000\000\000" | dd of="$file" bs=1 seek="$timestamp_offset" conv=notrunc >/dev/null 2>&1
    }

    build_one() {
      target="$1"
      asset="$2"
      exe="${3:-}"
      strip_config=""
      case "$target" in
        *-apple-darwin) strip_config="--config profile.release.strip=false" ;;
      esac
      cargo zigbuild --release --locked $strip_config \
        --manifest-path "$CLIENT_DIR/Cargo.toml" --target "$target" >/dev/null
      cp "$CLIENT_DIR/target/$target/release/adtention-terminal$exe" "$bin/$asset$exe"
      case "$target" in
        *-windows-*) normalize_windows_pe "$bin/$asset$exe" ;;
      esac
      chmod +x "$bin/$asset$exe" 2>/dev/null || true
      echo "  built $asset$exe"
    }

    build_one x86_64-apple-darwin adtention-terminal-darwin-amd64
    build_one aarch64-apple-darwin adtention-terminal-darwin-arm64
    build_one x86_64-unknown-linux-gnu adtention-terminal-linux-amd64
    build_one aarch64-unknown-linux-gnu adtention-terminal-linux-arm64
    build_one x86_64-pc-windows-gnu adtention-terminal-windows-amd64 .exe

    cd "$bin"
    sha256sum \
      adtention-terminal-darwin-amd64 \
      adtention-terminal-darwin-arm64 \
      adtention-terminal-linux-amd64 \
      adtention-terminal-linux-arm64 \
      adtention-terminal-windows-amd64.exe > SHA256SUMS
  '

write_launcher
rm -f .intentionally-empty-file.o
echo "Wrote $BIN_DIR/SHA256SUMS"
