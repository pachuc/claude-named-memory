#!/bin/bash
# Rename a named-memory profile: move the dir, remove the old shell alias,
# install the new one. memory.md content is preserved.

set -euo pipefail

OLD="${1:-}"
NEW="${2:-}"
if [ -z "$OLD" ] || [ -z "$NEW" ]; then
  echo "Usage: rename-profile.sh <old-name> <new-name>" >&2
  exit 1
fi

for n in "$OLD" "$NEW"; do
  if ! [[ "$n" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: '$n' must contain only letters, numbers, dashes, underscores" >&2
    exit 1
  fi
done

if [ "$OLD" = "$NEW" ]; then
  echo "Error: old and new names are the same" >&2
  exit 1
fi

PROFILES_DIR="$HOME/.claude/profiles"
OLD_DIR="$PROFILES_DIR/$OLD"
NEW_DIR="$PROFILES_DIR/$NEW"

if [ ! -d "$OLD_DIR" ]; then
  echo "Error: profile '$OLD' not found at $OLD_DIR" >&2
  exit 1
fi
if [ -e "$NEW_DIR" ]; then
  echo "Error: target '$NEW' already exists at $NEW_DIR" >&2
  exit 1
fi

CONFIG="$HOME/.claude/scripts/profile-config.sh"
if [ ! -f "$CONFIG" ]; then
  echo "Error: $CONFIG not found. Run /named-memory:name first to bootstrap shell config." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG"
: "${SHELL_TYPE:?SHELL_TYPE not set in $CONFIG}"
: "${ALIAS_INSTALL_PATH:?ALIAS_INSTALL_PATH not set in $CONFIG}"

mv "$OLD_DIR" "$NEW_DIR"

case "$SHELL_TYPE" in
  fish)
    OLD_FN="$ALIAS_INSTALL_PATH/claude-$OLD.fish"
    NEW_FN="$ALIAS_INSTALL_PATH/claude-$NEW.fish"
    [ -f "$OLD_FN" ] && rm "$OLD_FN" && echo "Removed fish function: $OLD_FN"
    cat > "$NEW_FN" <<EOF
function claude-$NEW
    set -lx CLAUDE_NM_PROFILE $NEW
    claude --append-system-prompt (cat $NEW_DIR/memory.md | string collect) --add-dir $NEW_DIR \$argv
end
EOF
    echo "Installed fish function: $NEW_FN"
    ;;
  bash|zsh)
    ALIAS_LINE="alias claude-$NEW='CLAUDE_NM_PROFILE=$NEW claude --append-system-prompt \"\$(cat $NEW_DIR/memory.md)\" --add-dir $NEW_DIR'"
    touch "$ALIAS_INSTALL_PATH"
    tmp=$(mktemp)
    grep -vE "^alias claude-($OLD|$NEW)=" "$ALIAS_INSTALL_PATH" > "$tmp" || true
    mv "$tmp" "$ALIAS_INSTALL_PATH"
    echo "$ALIAS_LINE" >> "$ALIAS_INSTALL_PATH"
    echo "Replaced alias in $ALIAS_INSTALL_PATH (claude-$OLD -> claude-$NEW)"
    ;;
  *)
    echo "Unknown SHELL_TYPE '$SHELL_TYPE' in $CONFIG" >&2
    exit 1
    ;;
esac

echo "Profile renamed: $OLD -> $NEW"
echo "Profile dir: $NEW_DIR"
case "$SHELL_TYPE" in
  fish) echo "Open a new fish shell, then run: claude-$NEW" ;;
  *)    echo "Reload your shell (source $ALIAS_INSTALL_PATH) or open a new shell, then run: claude-$NEW" ;;
esac
