#!/bin/bash
# Session-scoped "active profile" marker for named-memory.
#
# Records which profile is active for the CURRENT Claude Code session so that:
#   - /load can enforce one-load-per-session (and detect a re-load of the same one)
#   - /save knows which profile to write back to
# deterministically — without relying on the model to remember across the
# conversation (which is lost on context compaction).
#
# TIER INTERACTION (important): the EXTRA tier launches `claude-<name>`, which
# exports CLAUDE_NM_PROFILE=<name> for the whole session. That env var is the
# authoritative active profile when present, so `get` returns it directly and the
# marker file is ignored. In the MINIMAL tier there is no such env var, so `get`
# falls back to a session-keyed marker file written by /load and /name. This keeps
# the extra tier's behavior unchanged (and, as a bonus, lets /save resolve its
# target from CLAUDE_NM_PROFILE instead of trusting the model's memory).
#
# The marker file is keyed by $CLAUDE_CODE_SESSION_ID and lives in a host-local
# temp dir, so it never syncs across hosts and is cleaned up with the temp dir.
# The session id is fixed for a session's lifetime, so the marker survives
# compaction. A fresh session (or resume) gets a new id and therefore a clean
# slate, which is the desired behavior.
#
# Usage:
#   session-marker.sh get          # prints the active profile name, or nothing
#   session-marker.sh set <name>   # records <name> as active for this session
#   session-marker.sh clear        # forgets the active profile for this session

set -euo pipefail

# Prefer the standard session id; fall back through known aliases, then to a
# fixed token so the marker still works (single shared slot) if none is set.
SID="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_CODE_CURRENT_SESSION_ID:-${CC_SESSION_ID:-nosession}}}"

MARKER_DIR="${CLAUDE_CODE_TMPDIR:-${TMPDIR:-/tmp}}/named-memory"
MARKER="$MARKER_DIR/active-$SID"

CMD="${1:-}"
case "$CMD" in
  get)
    # Extra tier: the launch alias exported CLAUDE_NM_PROFILE — it wins.
    if [ -n "${CLAUDE_NM_PROFILE:-}" ]; then
      printf '%s\n' "$CLAUDE_NM_PROFILE"
    elif [ -f "$MARKER" ]; then
      cat "$MARKER"
    fi
    ;;
  set)
    NAME="${2:-}"
    if [ -z "$NAME" ]; then
      echo "Usage: session-marker.sh set <name>" >&2
      exit 1
    fi
    if ! [[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      echo "Error: name must contain only letters, numbers, dashes, underscores" >&2
      exit 1
    fi
    mkdir -p "$MARKER_DIR"
    printf '%s\n' "$NAME" > "$MARKER"
    ;;
  clear)
    rm -f "$MARKER"
    ;;
  *)
    echo "Usage: session-marker.sh {get|set <name>|clear}" >&2
    exit 1
    ;;
esac
