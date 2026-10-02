#!/usr/bin/env bash
#
# Build DSHLight.app: a universal, ad-hoc signed bundle with no dependencies.
#
#   ./mac/build.sh          build into ./build
#   ./mac/build.sh --run    build, then follow the light in this terminal
#   ./mac/build.sh --open   build, then draw the window
#
# No Apple Developer account is needed. An ad-hoc signature is enough for the
# kernel to run the binary, and a package manager install does not set the
# quarantine flag, so Gatekeeper is not in the path either.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC="$ROOT/mac"
OUT="$ROOT/build"
APP="$OUT/DSHLight.app"
BINARY="$APP/Contents/MacOS/DSHLight"
SOURCE="$MAC/Sources/DSHLight.swift"
PLIST="$MAC/Resources/Info.plist"

# macOS 11 is the floor for Apple Silicon; both slices are built from it so the
# universal binary has one deployment target.
DEPLOYMENT="11.0"

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

command -v swiftc >/dev/null 2>&1 || die "swiftc not found — install Xcode or the Command Line Tools"
[ -f "$SOURCE" ] || die "source not found at $SOURCE"
[ -f "$PLIST" ] || die "Info.plist not found at $PLIST"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/slices" "$OUT/module-cache"
cp "$PLIST" "$APP/Contents/Info.plist"

build_slice() {
  local arch="$1"
  # The module cache is pinned inside the build directory: its default lives in
  # the user's shared clang cache, which a confined shell cannot write to.
  swiftc \
    -O \
    -target "${arch}-apple-macos${DEPLOYMENT}" \
    -module-cache-path "$OUT/module-cache" \
    -framework Cocoa \
    -o "$OUT/slices/DSHLight-$arch" \
    "$SOURCE"
}

echo "compiling arm64…"
build_slice arm64

slices=("$OUT/slices/DSHLight-arm64")
if build_slice x86_64 2>"$OUT/slices/x86_64.log"; then
  slices+=("$OUT/slices/DSHLight-x86_64")
else
  # An Intel slice is a courtesy, not a requirement: this is a helper for a
  # Mac-only host, and it runs on whatever Mac the harness runs on.
  echo "note: the x86_64 slice did not build; producing arm64 only"
  sed 's/^/      /' "$OUT/slices/x86_64.log" | tail -5
fi

lipo -create -output "$BINARY" "${slices[@]}"
chmod +x "$BINARY"

# Ad-hoc signing: no identity, no account, but a valid signature for the kernel.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
  || echo "note: ad-hoc signing failed; the binary may not run on Apple Silicon"

rm -rf "$OUT/slices"

echo
echo "built $APP"
lipo -archs "$BINARY" | sed 's/^/  architectures: /'
echo
echo "  follow the light:  $APP/Contents/MacOS/DSHLight --print"
echo "  draw the light:    open '$APP'"
echo "  stop the light:    pkill -f DSHLight"

case "${1:-}" in
  --run) exec "$BINARY" --print ;;
  --open) exec open "$APP" ;;
esac
