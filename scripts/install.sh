#!/usr/bin/env bash
#
# Mount dsh-status in the DSH Desktop profile patch layer.
#
#   ./scripts/install.sh              mount it
#   ./scripts/install.sh --print      show the row, touch nothing
#   ./scripts/install.sh --uninstall  restore the newest backup
#
# The patch layer is *live config*: a malformed file can stop DSH from
# starting. So this script refuses to run twice, backs the file up before
# touching it, and parses the result when pyyaml is available.
#
# Override the target with DSH_PATCH=/path/to/cordis.patch.yml, or the harness
# home with DSH_HOME=/path/to/harness.
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY="$PLUGIN_DIR/lib/index.js"
ROW_ID="dsh-status"

if [ -n "${DSH_PATCH:-}" ]; then
  PATCH="$DSH_PATCH"
else
  PATCH="${DSH_HOME:-$HOME/Library/Application Support/dsh-desktop/harness}/profiles/web/cordis.patch.yml"
fi

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

row() {
  cat <<YAML

# dsh-status — publishes this session's turn state for a native indicator.
# Remove this block, or run scripts/install.sh --uninstall, to unmount.
- insert:
    - id: $ROW_ID
      name: '$ENTRY'
YAML
}

case "${1:-}" in
  --print)
    row
    exit 0
    ;;
  --uninstall)
    [ -f "$PATCH" ] || die "profile patch not found at $PATCH"
    newest="$(ls -1t "$PATCH".bak-* 2>/dev/null | head -1 || true)"
    [ -n "$newest" ] || die "no backup next to $PATCH — restore it by hand"
    cp "$newest" "$PATCH"
    printf 'restored %s\n  from %s\n\nRestart DSH Desktop to apply.\n' "$PATCH" "$newest"
    exit 0
    ;;
  -h|--help)
    sed -n '2,14p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
esac

[ -f "$ENTRY" ] || die "plugin entry not found at $ENTRY"
[ -f "$PATCH" ] || die "profile patch not found at $PATCH — set DSH_PATCH to override"

if grep -q "id: $ROW_ID" "$PATCH"; then
  printf 'already mounted in:\n  %s\n\nNothing to do.\n' "$PATCH"
  exit 0
fi

backup="$PATCH.bak-$(date +%Y%m%d%H%M%S)"
cp "$PATCH" "$backup"
row >> "$PATCH"

if python3 -c 'import yaml' 2>/dev/null; then
  python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$PATCH" \
    || die "the patched file no longer parses — restore $backup"
  printf 'patch file parses cleanly.\n'
else
  printf 'note: pyyaml is unavailable, so the patched file was not parsed.\n'
  printf '      If DSH will not start, restore the backup at:\n        %s\n' "$backup"
fi

cat <<EOF

mounted '$ROW_ID'
  patch:  $PATCH
  entry:  $ENTRY
  backup: $backup

Next:
  1. restart DSH Desktop — the profile patch layer is applied at boot
  2. watch the state file in another terminal:
       watch -n1 cat "\$HOME/Library/Application Support/dsh-status/state.json"
  3. send a prompt and expect: unknown -> working -> waiting
EOF
