#!/bin/bash
# SessionEnd hook: spawns a headless `claude -p` in the background to read the
# session transcript and update the named profile's memory.md, compacting if
# it exceeds 20,000 characters. All output goes to extract.log.
#
# Invoked by Claude Code with the SessionEnd hook payload on stdin.

set -euo pipefail

NAME="${1:-}"
if [ -z "$NAME" ]; then
  # exit 0 so a missing arg doesn't break SessionEnd
  exit 0
fi

PROFILE_DIR="$HOME/.claude/profiles/$NAME"
MEMORY_FILE="$PROFILE_DIR/memory.md"
LOG="$PROFILE_DIR/extract.log"

[ -f "$MEMORY_FILE" ] || exit 0

PAYLOAD=$(cat)
TRANSCRIPT=$(echo "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  echo "$(date -Iseconds) [skip] No usable transcript_path in payload" >> "$LOG"
  exit 0
fi

CHARS=$(wc -c < "$MEMORY_FILE")

INSTR="Read the session transcript at $TRANSCRIPT (JSONL format, one message per line). Update $MEMORY_FILE with any important information about the task or tasks worked on in this session: important things that were built, key insights, any overall plan or project to track, reference filepaths or documents, and notes that may be helpful for future iterations on the work. Avoid duplicating content that is already in memory.md. Keep the existing header intact — only modify content below the '---' divider."

if [ "$CHARS" -gt 20000 ]; then
  INSTR="$INSTR The memory file is currently $CHARS characters, over the 20,000 threshold. After updating, also compact: merge duplicates, drop outdated or contradicted entries, consolidate redundancy. Aim to bring it back under 20,000 characters while keeping the important content."
fi

{
  echo "$(date -Iseconds) [start] memory=${CHARS}c transcript=$TRANSCRIPT"
  claude -p "$INSTR" --add-dir "$PROFILE_DIR" --add-dir "$(dirname "$TRANSCRIPT")"
  echo "$(date -Iseconds) [done]"
} >> "$LOG" 2>&1 &

# Detach so the SessionEnd hook returns immediately
exit 0
