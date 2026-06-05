#!/bin/bash
# Deterministic profile setup: creates ~/.claude/profiles/<name>/memory.md.
#
# This is the MINIMAL operation — it never touches the user's shell rc. The
# shell alias (claude-<name>) is installed separately by install-alias.sh, and
# only when the extra experience is enabled via /install-extra.
#
# Idempotent: re-running on an existing profile preserves memory.md.

set -euo pipefail

NAME="${1:-}"
if [ -z "$NAME" ]; then
  echo "Usage: setup-profile.sh <name>" >&2
  exit 1
fi

if ! [[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "Error: name must contain only letters, numbers, dashes, underscores" >&2
  exit 1
fi

PROFILE_DIR="$HOME/.claude/profiles/$NAME"

if [ -d "$PROFILE_DIR" ]; then
  echo "Profile '$NAME' already exists at $PROFILE_DIR — preserving memory.md."
else
  mkdir -p "$PROFILE_DIR"
  cat > "$PROFILE_DIR/memory.md" <<EOF
# Memory for agent: $NAME

This file is your persistent memory across sessions.
- Load it into context with /load $NAME, or (with the extra experience) it is
  auto-loaded when you run claude-$NAME.
- Update it during a session, then persist with /save.
- With the extra experience enabled, a SessionEnd hook also extracts anything you
  missed and compacts if this file exceeds 20,000 words.
- Don't worry about terseness mid-session — compaction is automatic.

---

EOF
  echo "Created profile dir: $PROFILE_DIR"
fi
