#!/bin/bash
# Deterministic profile setup: creates ~/.claude/profiles/<name>/ with memory.md
# and settings.json, then installs a shell alias (claude-<name>) per the
# user's profile-config.sh.
#
# Idempotent: re-running on an existing profile preserves memory.md and only
# refreshes the alias + settings.json.

set -euo pipefail

NAME="${1:-}"
if [ -z "$NAME" ]; then
  echo "Usage: setup-profile.sh <name>" >&2
  exit 1
fi

if ! [[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "Error: name must contain only letters, numbers, dashes, underscores" >&2
  exit 1
fi

CONFIG_DIR="$HOME/.claude/scripts"
CONFIG="$CONFIG_DIR/profile-config.sh"

# Detect the user's login shell from passwd, not $SHELL. $SHELL reflects the
# environment of the calling process — when invoked from Claude Code's Bash
# tool, that's often the system default (e.g. zsh) even if the user's
# interactive shell is fish.
detect_login_shell() {
  local s=""
  if command -v getent >/dev/null 2>&1; then
    s=$(getent passwd "$USER" 2>/dev/null | cut -d: -f7)
  fi
  if [ -z "$s" ] && [ -r /etc/passwd ]; then
    s=$(awk -F: -v u="$USER" '$1 == u { print $7; exit }' /etc/passwd)
  fi
  if [ -z "$s" ] && command -v dscl >/dev/null 2>&1; then
    s=$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}')
  fi
  if [ -z "$s" ]; then
    s="${SHELL:-}"
  fi
  echo "$s"
}

# Bootstrap config on first run based on detected login shell
if [ ! -f "$CONFIG" ]; then
  mkdir -p "$CONFIG_DIR"
  LOGIN_SHELL=$(detect_login_shell)
  case "$LOGIN_SHELL" in
    *fish*)
      cat > "$CONFIG" <<'EOF'
# named-agents shell config. Edit to switch shells or relocate aliases.
# SHELL_TYPE: fish | bash | zsh
SHELL_TYPE="fish"
# fish: directory for function files. bash/zsh: file to append `alias` lines.
ALIAS_INSTALL_PATH="$HOME/.config/fish/functions"
EOF
      ;;
    *zsh*)
      cat > "$CONFIG" <<'EOF'
SHELL_TYPE="zsh"
ALIAS_INSTALL_PATH="$HOME/.zshrc"
EOF
      ;;
    *)
      cat > "$CONFIG" <<'EOF'
SHELL_TYPE="bash"
ALIAS_INSTALL_PATH="$HOME/.bashrc"
EOF
      ;;
  esac
  echo "Created default config: $CONFIG (detected login shell: ${LOGIN_SHELL:-unknown})"
fi

# shellcheck source=/dev/null
source "$CONFIG"
: "${SHELL_TYPE:?SHELL_TYPE not set in $CONFIG}"
: "${ALIAS_INSTALL_PATH:?ALIAS_INSTALL_PATH not set in $CONFIG}"

# Hook scripts run under /bin/sh, which doesn't inherit Claude Code's
# plugin PATH. Symlink the hook to a stable location and reference that
# absolute path in settings.json so SessionEnd can actually find it.
HOOK_SRC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/compact-on-exit.sh"
HOOK_LINK_DIR="$HOME/.claude/scripts"
HOOK_LINK="$HOOK_LINK_DIR/compact-on-exit.sh"
mkdir -p "$HOOK_LINK_DIR"
ln -sfn "$HOOK_SRC" "$HOOK_LINK"

PROFILE_DIR="$HOME/.claude/profiles/$NAME"
ALIAS_REFRESH_ONLY=0

if [ -d "$PROFILE_DIR" ]; then
  echo "Profile '$NAME' already exists at $PROFILE_DIR — preserving memory.md, refreshing settings.json and alias."
  ALIAS_REFRESH_ONLY=1
else
  mkdir -p "$PROFILE_DIR"
  cat > "$PROFILE_DIR/memory.md" <<EOF
# Memory for agent: $NAME

This file is your persistent memory across sessions.
- Read it at session start (it's already in your system prompt).
- Update it with Write/Edit as you learn things worth keeping.
- A SessionEnd hook extracts anything you missed and compacts if this file exceeds 20,000 characters.
- Don't worry about terseness mid-session — compaction is automatic.

---

EOF
fi

# Always (re)write settings.json so hook command stays current
cat > "$PROFILE_DIR/settings.json" <<EOF
{
  "hooks": {
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOOK_LINK $NAME"
          }
        ]
      }
    ]
  }
}
EOF

# Install/refresh shell alias
case "$SHELL_TYPE" in
  fish)
    mkdir -p "$ALIAS_INSTALL_PATH"
    FN_FILE="$ALIAS_INSTALL_PATH/claude-$NAME.fish"
    cat > "$FN_FILE" <<EOF
function claude-$NAME
    claude --append-system-prompt (cat $PROFILE_DIR/memory.md | string collect) --settings $PROFILE_DIR/settings.json --add-dir $PROFILE_DIR \$argv
end
EOF
    echo "Installed fish function: $FN_FILE"
    ;;
  bash|zsh)
    ALIAS_LINE="alias claude-$NAME='claude --append-system-prompt \"\$(cat $PROFILE_DIR/memory.md)\" --settings $PROFILE_DIR/settings.json --add-dir $PROFILE_DIR'"
    touch "$ALIAS_INSTALL_PATH"
    if grep -qE "^alias claude-$NAME=" "$ALIAS_INSTALL_PATH"; then
      # Replace existing line
      tmp=$(mktemp)
      grep -vE "^alias claude-$NAME=" "$ALIAS_INSTALL_PATH" > "$tmp"
      mv "$tmp" "$ALIAS_INSTALL_PATH"
    fi
    echo "$ALIAS_LINE" >> "$ALIAS_INSTALL_PATH"
    echo "Installed alias claude-$NAME in $ALIAS_INSTALL_PATH"
    ;;
  *)
    echo "Unknown SHELL_TYPE '$SHELL_TYPE' in $CONFIG" >&2
    exit 1
    ;;
esac

if [ "$ALIAS_REFRESH_ONLY" -eq 0 ]; then
  echo "Profile dir: $PROFILE_DIR"
fi

case "$SHELL_TYPE" in
  fish)
    echo "Ready: open a new fish shell (or call the function immediately — fish autoloads functions/) and run: claude-$NAME"
    ;;
  *)
    echo "Ready: reload your shell config (source $ALIAS_INSTALL_PATH) or open a new shell, then run: claude-$NAME"
    ;;
esac
