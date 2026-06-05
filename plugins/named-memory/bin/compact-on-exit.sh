#!/bin/bash
# SessionEnd hook: spawns a headless `claude -p` to update/compact the
# profile's memory.md, via the tmp+install pattern:
#   1. Shell copies memory.md -> tmpfile
#   2. Agent reads transcript, updates the tmpfile in place
#   3. Shell installs tmpfile back to memory.md (atomic same-dir rename)
#
# The agent never touches ~/.claude/ — the protected-paths gate doesn't
# fire because all writes to memory.md happen via shell, not via Claude
# tools. See DESIGN.md §3 for the rationale.
#
# Reads profile name from $CLAUDE_NM_PROFILE (set by the per-profile alias).
# Fast-fails silently in vanilla `claude` sessions (no profile active).

set -euo pipefail

# Dormant unless the extra (automatic) experience is enabled via /install-extra.
# The marker lives outside the version-stamped plugin cache so it survives upgrades.
[ -f "$HOME/.claude/named-memory/extra-enabled" ] || exit 0

# Fast-fail in vanilla sessions — no named profile active.
[ -z "${CLAUDE_NM_PROFILE:-}" ] && exit 0
NAME="$CLAUDE_NM_PROFILE"

if ! [[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  exit 0
fi

PROFILE_DIR="$HOME/.claude/profiles/$NAME"
MEMORY_FILE="$PROFILE_DIR/memory.md"
LOG="$PROFILE_DIR/extract.log"
AUDIT="$PROFILE_DIR/audit.log"

[ -f "$MEMORY_FILE" ] || exit 0

audit() {
  printf '%s\t%s\t%s\t%s\n' "$(date -Iseconds)" "$1" "$2" "$3" >> "$AUDIT"
}

PAYLOAD=$(cat)
TRANSCRIPT=$(echo "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  audit hook error "reason=no_transcript_path"
  echo "$(date -Iseconds) [skip] No usable transcript_path in payload" >> "$LOG"
  exit 0
fi

INITIAL_WORDS=$(wc -w < "$MEMORY_FILE")
audit hook start "transcript=$TRANSCRIPT size=$INITIAL_WORDS"

INSTR="Read the session transcript at $TRANSCRIPT (JSONL format, one message per line). The current named-memory file has been copied to a tmpfile (path provided below). Update the tmpfile in place with any important information about the task or tasks worked on in this session: important things that were built, key insights, any overall plan or project to track, reference filepaths or documents, and notes that may be helpful for future iterations on the work. Avoid duplicating content already present. Keep the existing header intact — only modify content below the '---' divider."

if [ "$INITIAL_WORDS" -gt 20000 ]; then
  INSTR="$INSTR The memory file is currently $INITIAL_WORDS words, over the 20,000 threshold. After updating, also compact: merge duplicates, drop outdated or contradicted entries, consolidate redundancy. Aim to bring it back under 20,000 words while keeping the important content."
fi

# Backgrounded extractor — SessionEnd hooks can't block exit.
# An EXIT trap inside the subshell pairs every `start` with a terminal event.
(
  TMP_NEW=$(mktemp /tmp/nm-extract-${NAME}.XXXXXX.md)
  MTIME_BEFORE=$(stat -c %Y "$MEMORY_FILE")
  SHA_BEFORE=$(sha256sum "$MEMORY_FILE" | cut -d' ' -f1)
  RC_REASON="claude_p_failed"

  finish() {
    local rc=$?
    local final_words
    final_words=$(wc -w < "$MEMORY_FILE" 2>/dev/null || echo 0)
    local delta=$((final_words - INITIAL_WORDS))
    if [ "$rc" -eq 0 ]; then
      audit hook complete "exit=0 size=$final_words delta=$delta transcript=$TRANSCRIPT"
    else
      audit hook error "exit=$rc size=$final_words delta=$delta transcript=$TRANSCRIPT reason=$RC_REASON"
    fi
    echo "$(date -Iseconds) [done exit=$rc delta=$delta]" >> "$LOG"
    rm -f "$TMP_NEW"
  }
  trap finish EXIT

  echo "$(date -Iseconds) [start] memory=${INITIAL_WORDS}w tmp=$TMP_NEW transcript=$TRANSCRIPT" >> "$LOG"

  # Step 1: shell copies memory.md -> tmpfile (deterministic)
  cp "$MEMORY_FILE" "$TMP_NEW"

  # Step 2: agent edits the tmpfile in place
  FULL_INSTR="$INSTR

The tmpfile is at: $TMP_NEW

Use Read, Edit, Write, and MultiEdit tools on $TMP_NEW only. Do NOT read or modify any file under ~/.claude/."

  # Strip CLAUDE_NM_PROFILE from the extractor's env so its own SessionEnd
  # hook hits the fast-fail guard and exits — otherwise each extractor
  # would spawn another extractor on exit, recursively.
  if ! timeout 600 env -u CLAUDE_NM_PROFILE claude -p "$FULL_INSTR" \
    --permission-mode acceptEdits \
    --add-dir "$(dirname "$TMP_NEW")" \
    --add-dir "$(dirname "$TRANSCRIPT")" \
    >> "$LOG" 2>&1; then
    exit $?
  fi

  # Step 3: detect changes via SHA
  SHA_AFTER=$(sha256sum "$TMP_NEW" | cut -d' ' -f1)
  if [ "$SHA_BEFORE" = "$SHA_AFTER" ]; then
    echo "$(date -Iseconds) [no-op] agent made no changes to tmp" >> "$LOG"
    exit 0
  fi

  # Sanity: non-empty file with header intact
  if [ ! -s "$TMP_NEW" ] || ! head -1 "$TMP_NEW" | grep -q "^# Memory for agent:"; then
    RC_REASON="invalid_tmp_content"
    exit 2
  fi

  # Race check: memory.md must not have been modified by another writer
  MTIME_NOW=$(stat -c %Y "$MEMORY_FILE")
  if [ "$MTIME_NOW" != "$MTIME_BEFORE" ]; then
    RC_REASON="race_detected"
    exit 3
  fi

  # Step 4: install via atomic same-dir rename
  STAGING="$MEMORY_FILE.staging.$$"
  if ! cp "$TMP_NEW" "$STAGING"; then
    RC_REASON="install_failed_copy"
    exit 4
  fi
  if ! mv "$STAGING" "$MEMORY_FILE"; then
    rm -f "$STAGING"
    RC_REASON="install_failed_mv"
    exit 5
  fi
) &

exit 0
