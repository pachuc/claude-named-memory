#!/bin/bash
# SessionStart hook: scan the profile's audit.log tail for an unacked
# SessionEnd failure. If found, emit JSON to stdout that injects a
# warning banner into the starting session via additionalContext.
# Otherwise exit silently — the agent never reads audit.log in the
# happy path.
#
# Detected failures:
#   - `hook error` events (claude_p_failed, no_transcript_path, etc.)
#   - orphaned `hook start` events older than 5 minutes with no matching
#     complete/error (process killed before the EXIT trap could fire)
#
# An entry is "acked" if there's a later `user ack` event whose
# upto= timestamp is at or after the failure timestamp.

set -euo pipefail

# Fast-fail in vanilla sessions — no named profile active.
[ -z "${CLAUDE_NM_PROFILE:-}" ] && exit 0
NAME="$CLAUDE_NM_PROFILE"
[[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 0

PROFILE_DIR="$HOME/.claude/profiles/$NAME"
AUDIT="$PROFILE_DIR/audit.log"

[ -f "$AUDIT" ] || exit 0

ack_upto=""
error_ts=""
error_reason=""
start_ts=""

# Walk forward; track only the most recent unacked error and the most
# recent start that hasn't been matched by a complete or error.
while IFS=$'\t' read -r ts source event details || [ -n "$ts" ]; do
  case "$source $event" in
    "user ack")
      ack_upto=$(printf '%s' "$details" | grep -oE 'upto=[^[:space:]]+' | head -1 | cut -d= -f2-)
      # Everything before this ack is dismissed.
      error_ts=""
      error_reason=""
      start_ts=""
      ;;
    "hook error")
      error_ts="$ts"
      error_reason=$(printf '%s' "$details" | grep -oE 'reason=[^[:space:]]+' | head -1 | cut -d= -f2-)
      [ -z "$error_reason" ] && error_reason="unknown"
      # An error terminates whatever start preceded it.
      start_ts=""
      ;;
    "hook start")
      start_ts="$ts"
      ;;
    "hook complete")
      start_ts=""
      ;;
  esac
done < <(tail -500 "$AUDIT")

# Ignore in-flight starts (< 5 min old) — claude -p may still be running.
if [ -n "$start_ts" ]; then
  now=$(date +%s)
  start_epoch=$(date -d "$start_ts" +%s 2>/dev/null || echo "$now")
  if [ $((now - start_epoch)) -lt 300 ]; then
    start_ts=""
  fi
fi

# Pick the most recent unacked failure (orphan or error), if any.
failure_ts=""
failure_kind=""
failure_detail=""
if [ -n "$error_ts" ]; then
  failure_ts="$error_ts"
  failure_kind="error"
  failure_detail="reason=$error_reason"
fi
if [ -n "$start_ts" ] && [[ "$start_ts" > "${failure_ts:-}" ]]; then
  failure_ts="$start_ts"
  failure_kind="orphan"
  failure_detail="hook start with no terminal event — process killed or hung"
fi

[ -z "$failure_ts" ] && exit 0

if [ "$failure_kind" = "orphan" ]; then
  headline="SessionEnd hook started at $failure_ts but never finished ($failure_detail)."
else
  headline="SessionEnd hook failed at $failure_ts ($failure_detail)."
fi

context="⚠️ named-memory ($NAME): $headline
Dismiss: /named-memory:ack $NAME  (suppress this banner)
Details: ~/.claude/profiles/$NAME/extract.log"

jq -n --arg ctx "$context" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
