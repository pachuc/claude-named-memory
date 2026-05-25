# named-memory

A Claude Code plugin that adds **named memory profiles**: invoke `claude` plain for a clean slate, or `claude-<name>` for an agent that loads a persistent per-name `memory.md` at startup, updates it organically during the session, and extracts/compacts it at session end.

## What it does

- **`/named-memory:name <profile>`** — create or update a named profile from the current session's context. Synthesizes a `memory.md` and installs a `claude-<profile>` shell alias.
- **`/named-memory:install`** — one-time step that drops a `~/.claude/commands/name.md` shortcut so you can use `/name <profile>` instead of `/named-memory:name <profile>`.
- **Memory lifecycle**:
  - At session start, the profile's `memory.md` is appended to Claude's system prompt.
  - During the session, Claude organically reads/writes `memory.md` via `Write`/`Edit`.
  - At session end, a hook spawns a headless `claude -p` in the background to extract anything that wasn't captured organically and to compact the file if it exceeds 20,000 characters.

## Install

### Via marketplace (after publishing)

```
/plugin marketplace add <github-user>/claude-named-memory
/plugin install named-memory@pachu-plugins
/named-memory:install
```

### Local development

```
claude --plugin-dir ~/code/claude-named-memory
```

Then in that session:

```
/named-memory:install
```

After install, `/name <profile>` works in any session.

## Usage

In a session where you've done useful work and want to spin off a named agent:

```
/name myproject
```

Open a new shell (or, for fish, call the function immediately — fish autoloads functions on demand):

```
claude-myproject
```

You'll be in a Claude session with the profile's `memory.md` loaded as system prompt context.

## File layout

The plugin ships:

```
.claude-plugin/plugin.json     # manifest
commands/name.md               # /named-memory:name
commands/install.md            # /named-memory:install
bin/setup-profile.sh           # creates profile dir + alias (on PATH when plugin enabled)
bin/compact-on-exit.sh         # SessionEnd hook (on PATH when plugin enabled)
```

User data (created on first run, persists across plugin updates/uninstalls):

```
~/.claude/scripts/profile-config.sh         # shell type + alias install path
~/.claude/profiles/<name>/memory.md         # the persistent memory
~/.claude/profiles/<name>/settings.json     # registers SessionEnd hook
~/.claude/profiles/<name>/extract.log       # background-process output
~/.claude/commands/name.md                  # /name shortcut (from /named-memory:install)
```

## Configuration

`~/.claude/scripts/profile-config.sh` is auto-created on first profile setup. Defaults are detected from `$SHELL`. Edit it to change shell or alias install path:

```bash
# fish | bash | zsh
SHELL_TYPE="fish"

# fish: directory for function files
# bash/zsh: file to append `alias` lines to
ALIAS_INSTALL_PATH="$HOME/.config/fish/functions"
```

## How memory works

Each profile's `memory.md` has a fixed header that explains the contract to Claude:

```
# Memory for agent: <name>

This file is your persistent memory across sessions.
- Read it at session start (it's already in your system prompt).
- Update it with Write/Edit as you learn things worth keeping.
- A SessionEnd hook extracts anything you missed and compacts if this file exceeds 20,000 characters.
- Don't worry about terseness mid-session — compaction is automatic.

---

(agent-managed content below)
```

Everything below the `---` is freely agent-managed. No prescribed schema.

## Tuning

The 20,000-character compaction threshold is in `bin/compact-on-exit.sh`. Change `CHARS -gt 20000` if you want a different cap. Lower threshold → more aggressive compaction → terser memory. Higher → more retention → slower context load.

## Troubleshooting

- **`claude-<name>` not found** — open a new shell. For fish, the function is auto-loaded from `~/.config/fish/functions/`; for bash/zsh, source your rc file.
- **SessionEnd hook didn't run** — check `~/.claude/profiles/<name>/extract.log` for errors. The hook requires `jq` and `claude` on PATH. The named-memory plugin must be enabled for `compact-on-exit.sh` to be on PATH.
- **`/name` not working but `/named-memory:name` works** — re-run `/named-memory:install` to drop the shortcut.

## License

MIT
