#!/bin/bash
# Delete a named-memory profile: remove the profile directory and the
# associated shell alias. Requires --yes to actually delete; the slash
# command handles the user-facing confirmation prompt.

set -euo pipefail

YES=0
NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1; shift ;;
    -*)    echo "Unknown flag: $1" >&2; exit 1 ;;
    *)     NAME="$1"; shift ;;
  esac
done

if [ -z "$NAME" ]; then
  echo "Usage: delete-profile.sh --yes <name>" >&2
  exit 1
fi
if [ "$YES" -ne 1 ]; then
  echo "Refusing to delete without --yes. Confirm with the user first, then pass --yes." >&2
  exit 1
fi
if ! [[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "Error: name must contain only letters, numbers, dashes, underscores" >&2
  exit 1
fi

PROFILE_DIR="$HOME/.claude/profiles/$NAME"
if [ ! -d "$PROFILE_DIR" ]; then
  echo "Error: profile '$NAME' not found at $PROFILE_DIR" >&2
  exit 1
fi

CONFIG="$HOME/.claude/scripts/profile-config.sh"
SHELL_TYPE=""
ALIAS_INSTALL_PATH=""
if [ -f "$CONFIG" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG"
fi

rm -rf "$PROFILE_DIR"
echo "Removed profile dir: $PROFILE_DIR"

case "${SHELL_TYPE:-}" in
  fish)
    FN_FILE="${ALIAS_INSTALL_PATH:-}/claude-$NAME.fish"
    if [ -n "${ALIAS_INSTALL_PATH:-}" ] && [ -f "$FN_FILE" ]; then
      rm "$FN_FILE"
      echo "Removed fish function: $FN_FILE"
    fi
    ;;
  bash|zsh)
    if [ -n "${ALIAS_INSTALL_PATH:-}" ] && [ -f "$ALIAS_INSTALL_PATH" ]; then
      tmp=$(mktemp)
      grep -vE "^alias claude-$NAME=" "$ALIAS_INSTALL_PATH" > "$tmp" || true
      mv "$tmp" "$ALIAS_INSTALL_PATH"
      echo "Removed alias claude-$NAME from $ALIAS_INSTALL_PATH"
    fi
    ;;
esac

echo "Deleted profile: $NAME"
echo "(If a shell has the old alias loaded, open a new one to refresh.)"
