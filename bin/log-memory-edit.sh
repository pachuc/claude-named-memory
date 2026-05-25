#!/bin/bash
# PostToolUse hook: appends an `agent wrote` event to audit.log when the
# agent writes or edits this profile's memory.md. Silent no-op for edits
# targeting any other file.
#
# Wired up alongside a matcher of "Write|Edit|MultiEdit" — this script does
# the path check itself since Claude Code matchers filter by tool name, not
# by tool_input.file_path.

set -euo pipefail

# Fast-fail in vanilla sessions — no named profile active.
[ -z "${CLAUDE_NM_PROFILE:-}" ] && exit 0
NAME="$CLAUDE_NM_PROFILE"
[[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 0

PROFILE_DIR="$HOME/.claude/profiles/$NAME"
MEMORY_FILE="$PROFILE_DIR/memory.md"
AUDIT="$PROFILE_DIR/audit.log"

[ -f "$MEMORY_FILE" ] || exit 0

PAYLOAD=$(cat)
FILE_PATH=$(echo "$PAYLOAD" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")

# Compare canonical paths — the agent may pass MEMORY_FILE via a symlink or
# with a trailing slash quirk; readlink normalizes both sides.
canon() { readlink -f "$1" 2>/dev/null || echo "$1"; }
[ "$(canon "$FILE_PATH")" = "$(canon "$MEMORY_FILE")" ] || exit 0

SIZE=$(wc -c < "$MEMORY_FILE")
TOOL=$(echo "$PAYLOAD" | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")

printf '%s\t%s\t%s\t%s\n' "$(date -Iseconds)" "agent" "wrote" "tool=$TOOL size=$SIZE" >> "$AUDIT"
