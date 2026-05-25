#!/bin/bash
# List all named-memory profiles as TSV: name<TAB>chars<TAB>mtime<TAB>preview
# Empty stdout if no profiles. Exit 0 always (absence is not an error).

set -euo pipefail

PROFILES_DIR="$HOME/.claude/profiles"

[ -d "$PROFILES_DIR" ] || exit 0

get_mtime() {
  local f="$1"
  local m
  if m=$(stat -c '%y' "$f" 2>/dev/null); then
    echo "${m:0:16}"
    return
  fi
  if m=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$f" 2>/dev/null); then
    echo "$m"
    return
  fi
  echo "unknown"
}

shopt -s nullglob 2>/dev/null || true

for dir in "$PROFILES_DIR"/*/; do
  [ -d "$dir" ] || continue
  name=$(basename "$dir")
  case "$name" in .*) continue;; esac
  memory_file="${dir}memory.md"
  if [ -f "$memory_file" ]; then
    chars=$(wc -c < "$memory_file" | tr -d ' ')
    mtime=$(get_mtime "$memory_file")
    # First non-empty line below the `---` header divider, stripped of
    # leading #/whitespace. Empty if none.
    preview=$(awk 'found && NF { sub(/^[[:space:]]*#+[[:space:]]*/, ""); print; exit } /^---$/ { found=1 }' "$memory_file")
  else
    chars=0
    mtime=""
    preview="(no memory.md)"
  fi
  printf '%s\t%s\t%s\t%s\n' "$name" "$chars" "$mtime" "$preview"
done | sort
