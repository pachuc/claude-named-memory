#!/bin/bash
# Copies the plugin's commands/<cmd>.md to ~/.claude/commands/<cmd>.md so the
# user can invoke /<cmd> instead of /named-memory:<cmd>. Fully deterministic —
# no LLM involvement, no content drift.
#
# Usage: install-shortcut.sh <cmd> [<cmd> ...]   (defaults to "name")

set -euo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
DEST_DIR="$HOME/.claude/commands"

CMDS=("$@")
if [ "${#CMDS[@]}" -eq 0 ]; then
  CMDS=("name")
fi

mkdir -p "$DEST_DIR"

for cmd in "${CMDS[@]}"; do
  SOURCE="$PLUGIN_ROOT/commands/$cmd.md"
  if [ ! -f "$SOURCE" ]; then
    echo "Error: source command file not found at $SOURCE" >&2
    exit 1
  fi
  cp "$SOURCE" "$DEST_DIR/$cmd.md"
  echo "Installed: $DEST_DIR/$cmd.md"
done

echo "You can now use the above as /<cmd> in any session (as long as the named-memory plugin is enabled)."
