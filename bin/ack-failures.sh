#!/bin/bash
# Append a `user ack` event to a profile's audit.log, dismissing any
# pending SessionStart warning banner about past hook failures. The ack
# covers everything timestamped at-or-before "now".
#
# Usage:
#   ack-failures.sh <name>   ack a single profile
#   ack-failures.sh --all    ack every profile under ~/.claude/profiles/

set -euo pipefail

ack_one() {
  local name="$1"
  local dir="$HOME/.claude/profiles/$name"
  if [ ! -d "$dir" ]; then
    echo "Profile '$name' not found at $dir" >&2
    return 1
  fi
  local now
  now=$(date -Iseconds)
  printf '%s\t%s\t%s\t%s\n' "$now" "user" "ack" "upto=$now" >> "$dir/audit.log"
  echo "Acked failures up to $now for '$name'."
}

ARG="${1:-}"
if [ -z "$ARG" ]; then
  echo "Usage: ack-failures.sh <name>|--all" >&2
  exit 1
fi

if [ "$ARG" = "--all" ]; then
  shopt -s nullglob 2>/dev/null || true
  any=0
  for d in "$HOME/.claude/profiles"/*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    case "$n" in .*) continue;; esac
    ack_one "$n" && any=1 || true
  done
  if [ "$any" -eq 0 ]; then
    echo "No profiles found under ~/.claude/profiles/"
  fi
else
  if ! [[ "$ARG" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: name must contain only letters, numbers, dashes, underscores" >&2
    exit 1
  fi
  ack_one "$ARG"
fi
