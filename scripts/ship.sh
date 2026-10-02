#!/usr/bin/env bash
#
# Build the renderer and copy it into bin/, which is what ships inside the
# plugin package. Run this whenever the Swift changes: bin/ is a committed
# artifact, and nothing else will notice that it has drifted from its source.
# `npm test` fails when it has, so the drift cannot go unnoticed for long.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT/mac/build.sh"

rm -rf "$ROOT/bin/DSHLight.app"
mkdir -p "$ROOT/bin"
cp -R "$ROOT/build/DSHLight.app" "$ROOT/bin/DSHLight.app"

# The digest of the source this was built from, so a stale bin/ is detectable.
shasum -a 256 "$ROOT/mac/Sources/DSHLight.swift" | awk '{print $1}' > "$ROOT/bin/SOURCE-SHA256"

echo
echo "shipped $(lipo -archs "$ROOT/bin/DSHLight.app/Contents/MacOS/DSHLight") into bin/"
du -sh "$ROOT/bin/DSHLight.app" | awk '{print "  " $1}'
