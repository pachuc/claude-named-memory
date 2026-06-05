#!/bin/bash
# Enable the EXTRA (automatic) named-memory experience:
#   - drop the extra-enabled marker (activates the dormant plugin hooks and
#     unlocks shell-alias creation)
#   - install a claude-<name> alias for every existing profile
#   - install un-namespaced /name, /load, /save command shortcuts
#
# Reverse with /uninstall-extra. Memory files are never touched here.

set -euo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"

MARKER_DIR="$HOME/.claude/named-memory"
MARKER="$MARKER_DIR/extra-enabled"

# 1. Marker — must exist before install-alias.sh will do anything.
mkdir -p "$MARKER_DIR"
if [ -f "$MARKER" ]; then
  echo "Extra experience already enabled (marker: $MARKER)."
else
  : > "$MARKER"
  echo "Enabled extra experience (marker: $MARKER)."
fi

# 2. Back-fill aliases for existing profiles.
shopt -s nullglob
PROFILES=("$HOME"/.claude/profiles/*/)
shopt -u nullglob
if [ "${#PROFILES[@]}" -eq 0 ]; then
  echo "No existing profiles to alias yet (create one with /name <name>)."
else
  for d in "${PROFILES[@]}"; do
    name="$(basename "$d")"
    "$SCRIPT_DIR/install-alias.sh" "$name" || echo "  (skipped alias for '$name')"
  done
fi

# 3. Install un-namespaced command shortcuts.
"$SCRIPT_DIR/install-shortcut.sh" name load save

cat <<'EOF'

Extra experience enabled.
- Hooks (SessionStart/SessionEnd/PostToolUse) are now active for claude-<name> sessions.
  No /reload-plugins needed — they were already registered and activate via the marker.
- Open a NEW shell (or source your rc) to pick up the claude-<name> aliases.
- Reverse anytime with /named-memory:uninstall-extra.
EOF
