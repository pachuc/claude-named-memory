#!/bin/bash
# Reverse /install-extra: disable the automatic experience.
#   - remove the extra-enabled marker (hooks go dormant again)
#   - remove claude-<name> aliases for every existing profile
#   - remove the un-namespaced /name, /load, /save command shortcuts
#
# Profile memory.md files are preserved — only the automation is removed.
# The plugin's own hooks stay registered (and dormant); /load and /save keep
# working via the namespaced commands.

set -euo pipefail

MARKER="$HOME/.claude/named-memory/extra-enabled"

# 1. Marker.
if [ -f "$MARKER" ]; then
  rm -f "$MARKER"
  echo "Disabled extra experience (removed marker: $MARKER)."
else
  echo "Extra experience was not enabled (no marker at $MARKER)."
fi

# 2. Remove aliases for known profiles, per the user's shell config.
CONFIG="$HOME/.claude/scripts/profile-config.sh"
SHELL_TYPE=""
ALIAS_INSTALL_PATH=""
if [ -f "$CONFIG" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG"
fi

remove_alias() {
  local name="$1"
  case "${SHELL_TYPE:-}" in
    fish)
      local fn="${ALIAS_INSTALL_PATH:-}/claude-$name.fish"
      if [ -n "${ALIAS_INSTALL_PATH:-}" ] && [ -f "$fn" ]; then
        rm -f "$fn"
        echo "Removed fish function: $fn"
      fi
      ;;
    bash|zsh)
      if [ -n "${ALIAS_INSTALL_PATH:-}" ] && [ -f "$ALIAS_INSTALL_PATH" ] && grep -qE "^alias claude-$name=" "$ALIAS_INSTALL_PATH"; then
        local tmp
        tmp=$(mktemp)
        grep -vE "^alias claude-$name=" "$ALIAS_INSTALL_PATH" > "$tmp" || true
        mv "$tmp" "$ALIAS_INSTALL_PATH"
        echo "Removed alias claude-$name from $ALIAS_INSTALL_PATH"
      fi
      ;;
  esac
}

shopt -s nullglob
PROFILES=("$HOME"/.claude/profiles/*/)
shopt -u nullglob
for d in "${PROFILES[@]}"; do
  remove_alias "$(basename "$d")"
done

# 3. Remove un-namespaced command shortcuts.
for cmd in name load save; do
  f="$HOME/.claude/commands/$cmd.md"
  if [ -f "$f" ]; then
    rm -f "$f"
    echo "Removed shortcut: $f"
  fi
done

cat <<'EOF'

Extra experience disabled.
- Hooks are dormant again (still registered, but they no-op without the marker).
- Profile memory.md files were preserved.
- /named-memory:load and /named-memory:save still work.
- Open a NEW shell to clear any claude-<name> aliases already loaded.
EOF
