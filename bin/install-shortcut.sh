#!/bin/bash
# Copies the plugin's commands/name.md to ~/.claude/commands/name.md so the
# user can invoke /name <profile> instead of /named-agents:name <profile>.
# Fully deterministic — no LLM involvement, no content drift.

set -euo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
SOURCE="$PLUGIN_ROOT/commands/name.md"
DEST_DIR="$HOME/.claude/commands"
DEST="$DEST_DIR/name.md"

if [ ! -f "$SOURCE" ]; then
  echo "Error: source command file not found at $SOURCE" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
cp "$SOURCE" "$DEST"

echo "Installed: $DEST"
echo "You can now use /name <profile> in any session (as long as the named-agents plugin is enabled)."
