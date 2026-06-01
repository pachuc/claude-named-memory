# named-memory

A Claude Code plugin that gives `claude` named memory profiles. Run plain `claude` for a clean slate, or `claude-<name>` to launch Claude Code with a persistent per-name `memory.md` already loaded as system-prompt context. The file updates organically as you work, and a `SessionEnd` hook spawns a headless `claude -p` to extract anything the in-session model missed and compact the file when it grows past 20,000 words.

## Why named memory profiles

Claude Code's existing memory hooks bind context to two natural keys: the working directory (project memory, `CLAUDE.md`) and the user (user-level memory, preferences). Both are useful, but a lot of real work doesn't fit either shape.

- **Tasks that cut across projects.** Setting up a new Linux box, debugging a multi-repo deploy, tracking down a bug that touches your backend, frontend, and infra repos in turn — the context belongs to *the task*, not any single directory. Project memory in any one repo would either miss most of it or get polluted by content the rest of the team has no reason to see.
- **Tasks that don't have a single directory.** Anything you do from `~`, exploratory shell work, system administration, learning a new tool, or coordinating across services — there's no project root to attach memory to. User-level memory is too broad (every session would inherit the context), and ephemeral sessions throw the context away.
- **Complex features inside a single project.** Even when the work *is* in one repo, the day-to-day state of a multi-week feature — what's been tried, what the next step is, which assumptions are still load-bearing, which dead ends to avoid — is usually too feature-specific and too churn-prone to belong in the project's `CLAUDE.md`. That file should be the stable, team-shared description of the codebase, not a scratchpad for whoever's currently building feature X.
- **Long-running side concerns.** Personal infra, a hobby project, ongoing research, a writing project — things you come back to weekly for months. Each deserves its own coherent context that survives across sessions without needing to be re-explained.

Named profiles give each of these a dedicated, persistent home. `claude-linux-setup` carries the state of your machine config; `claude-feature-x` carries the in-flight design decisions for a complex feature; `claude-prod-debug` carries what you know so far about a flaky production incident. None of them clutter your project memory or user preferences. Plain `claude` stays unaffected — a clean slate when you want one.

The aim is named, human-readable memory you don't have to manage. No project- or session-keyed indexing, no per-fact files, no manual compaction — one markdown file per profile, evolved across sessions.

## Features

- **Per-name persistent memory.** Each profile gets `~/.claude/profiles/<name>/memory.md`. It's loaded into Claude's system prompt at session start so the model has the prior context immediately.
- **Organic mid-session writes.** The agent updates `memory.md` directly via Edit/Write as it learns things worth keeping — no special syntax, no "save this" command.
- **Automatic extraction + compaction at session end.** A backgrounded headless `claude -p` reads the session transcript, captures anything the in-session model didn't already write down, and compacts the file when it crosses the word threshold. Survives the parent session's exit.
- **One shell alias per profile.** `claude-<name>` is a function/alias the plugin installs in your shell. It exports `CLAUDE_NM_PROFILE=<name>` then runs `claude` — that's the entire activation mechanism.
- **Vanilla `claude` is untouched.** With no profile env var set, every hook script fast-fails in sub-millisecond time. No banners, no extra context, no behavioral difference.
- **Health banner only when something actually broke.** A `SessionStart` hook parses the per-profile audit log and emits a one-line prescriptive banner on real structural failures. Healthy sessions add zero context.
- **Append-only audit log per profile** at `~/.claude/profiles/<name>/audit.log` for debugging hook execution.

### Slash commands

All commands are namespaced under `/named-memory:` and most also have unnamespaced aliases once you run `/named-memory:install`.

| Command | What it does |
|---|---|
| `/named-memory:name <profile>` (or `/name <profile>`) | Create or update a profile from the *current* session's context. Synthesizes `memory.md` and installs the `claude-<profile>` shell alias. Re-running on an existing profile updates without clobbering. |
| `/named-memory:install` | One-time step that drops a `~/.claude/commands/name.md` shortcut so `/name` works in any session. |
| `/named-memory:list` | Table of all profiles with size (in words), last-modified time, and a preview of the first content line. Flags profiles near the compaction limit. |
| `/named-memory:view <name>` | Print the full `memory.md` for a profile. |
| `/named-memory:rename <old> <new>` | Move the profile directory and swap the shell alias atomically. |
| `/named-memory:delete <name>` | Delete a profile after a double confirmation (in-session question + script-level `--yes` enforcement). |
| `/named-memory:ack <name>` | Dismiss the SessionStart failure banner for a profile (after you've read `extract.log` and resolved the issue, or just want to silence the warning). |

### Typical workflow

```text
# 1. After some useful work in a vanilla session, spin off a named agent:
> /name myproject

# 2. In a new shell:
$ claude-myproject

# 3. Inside that session, memory.md is already loaded. Work normally —
#    the model reads/writes memory.md as it goes.

# 4. On /exit (or double Ctrl+C), the SessionEnd hook backgrounds an
#    extractor against the transcript. By the time you start your
#    next claude-myproject session, memory.md is updated and compacted.
```

### Install

Via marketplace (after publishing to GitHub):

```text
/plugin marketplace add <github-user>/claude-named-memory
/plugin install named-memory@pachu-plugins
/named-memory:install
```

Local development from this repo:

```text
claude --plugin-dir ~/code/claude-named-memory/plugins/named-memory
```

After editing plugin source, pick up changes with:

```text
/plugin marketplace update pachu-plugins
/reload-plugins
```

This refreshes the cached copy under `~/.claude/plugins/cache/pachu-plugins/named-memory/`, which is what hooks actually execute from.

### Configuration

`~/.claude/scripts/profile-config.sh` is auto-created on first profile setup; it selects the shell type (fish/bash/zsh) and the path where aliases get installed. Defaults are inferred from `getent passwd` / `/etc/passwd` / `dscl`, falling back to `$SHELL`. Edit if you need to override.

The compaction word threshold is `INITIAL_WORDS -gt 20000` in `bin/compact-on-exit.sh`. Lower → more aggressive compaction; higher → more retention but slower context load.

## Architecture

### Activation model

Plugin-level hooks are registered in `hooks/hooks.json` and reference scripts via `${CLAUDE_PLUGIN_ROOT}/bin/<script>.sh`. `CLAUDE_PLUGIN_ROOT` is a path placeholder Claude Code resolves at hook fire time, so plugin upgrades automatically resolve to the new cache path — no user-side housekeeping.

Every hook script's first executable line is:

```bash
[ -z "${CLAUDE_NM_PROFILE:-}" ] && exit 0
NAME="$CLAUDE_NM_PROFILE"
```

The per-profile shell alias `claude-<name>` exports `CLAUDE_NM_PROFILE=<name>` before invoking `claude`. Arbitrary user env vars propagate through Claude Code into the `/bin/sh -c` that runs hook commands — only `PATH` is observably tampered with. So:

- `claude-myproject` → env var set → hooks see it → real work happens
- plain `claude` → env var unset → hooks exit in microseconds → no observable behavior change

### Memory lifecycle

1. **Session start.** `claude-<name>` launches Claude Code. The profile's `memory.md` (loaded as part of the agent's system prompt) gives the model its prior context. `check-failures.sh` (`SessionStart` hook) parses the audit log and, if there's an unacked structural failure since the last ack, emits a one-line banner via `additionalContext`. Healthy = zero extra context.
2. **Mid-session.** The agent reads/writes `memory.md` directly via Read/Edit/Write as the conversation goes. `log-memory-edit.sh` (`PostToolUse` hook on `Write|Edit|MultiEdit`) records `agent wrote` events in the audit log when those writes target the profile's `memory.md`.
3. **Session end.** `compact-on-exit.sh` (`SessionEnd` hook) fires. SessionEnd cannot block exit, so it backgrounds a subshell that survives the parent's exit. The subshell:
   - Copies `memory.md` → a tmpfile in `/tmp/`
   - Spawns `timeout 600 env -u CLAUDE_NM_PROFILE claude -p '<instructions>'` against the session transcript, with `--add-dir` for the tmpfile and transcript dirs. The env-strip is critical: without it, the headless extractor's own SessionEnd would re-trigger this script, recursively. Stripped, the child hits the fast-fail guard.
   - The extractor reads the transcript via the Read tool and edits *the tmpfile* (not `memory.md`) via Edit/Write.
   - After it returns, the shell sanity-checks the tmpfile (SHA changed, non-empty, header intact, mtime race-check vs. `memory.md`), then installs it back via staged atomic rename: `cp tmp memory.md.staging.$$ && mv memory.md.staging memory.md`.
   - An `EXIT` trap pairs every `hook start` audit-log event with a terminal `hook complete` or `hook error`.

### The protected-paths workaround

Claude Code's harness blocks Edit/Write/MultiEdit to any path under `~/.claude/` via a hardcoded "protected paths" gate that fires before the usual permission flow. `--allowed-tools`, `--permission-mode acceptEdits`, `settings.allow` rules, and `PreToolUse` hooks returning `permissionDecision: "allow"` all fail to bypass it. Only `--dangerously-skip-permissions` / `--permission-mode bypassPermissions` (administratively disable-able and overly broad) or `--permission-mode auto` (research-preview, model-gated, plan-gated, non-deterministic) get through.

But **the gate only fires on the model's Edit/Write/MultiEdit tools, not on shell writes**. So the SessionEnd extractor:

- Writes to `/tmp/` (outside the gate) using Edit/Write
- The hook script (which is the user's shell, not the model's tool layer) `cp`/`mv`s the result into `~/.claude/profiles/<name>/memory.md`

The agent never touches `~/.claude/` directly. The gate never fires. No bypass flags, no research-preview features, no data migration.

Interactive `/name` is the exception: when you explicitly run that command, the in-session agent updates `memory.md` directly via Edit, and you approve the one prompt the gate produces. The friction is acceptable in interactive contexts where the user is sitting at the prompt with explicit intent.

### Audit log + banner pipeline

`~/.claude/profiles/<name>/audit.log` is append-only TSV:

```text
<iso8601>  <source>   <event>    <key=val space-separated>
2026-...   agent      wrote      tool=Edit size=18234
2026-...   hook       start      transcript=/path/x.jsonl size=18234
2026-...   hook       complete   exit=0 size=19081 delta=+847 transcript=...
2026-...   hook       error      exit=3 reason=race_detected transcript=...
2026-...   user       ack        upto=2026-...
```

- `source ∈ {agent, hook, user}`; `event ∈ {wrote, start, complete, error, ack}`
- Every `hook` event carries `transcript=<path>` so a potential future `/named-memory:retry` could replay extraction
- `ack` events live in the same file as failures — single source of truth

`check-failures.sh` walks `tail -500 audit.log` forward:

- Latest `user ack` clears prior errors/orphans before it
- Latest unacked `hook error` → emit prescriptive banner
- `hook start` with no following `hook complete` → orphan; ignored if <5 min old (extractor may still be running), banner if older

The agent never reads `audit.log` directly. The shell does the parsing; the agent only sees the pre-digested banner when there's something to act on.

### Shell integration

`bin/setup-profile.sh` detects the user's login shell from `getent passwd` / `/etc/passwd` / `dscl` (falling back to `$SHELL`) and writes the alias accordingly:

- **fish** — a function file at `~/.config/fish/functions/claude-<name>.fish` (autoloaded on demand)
- **bash/zsh** — an `alias` line appended to the appropriate rc file

The alias body is essentially:

```bash
CLAUDE_NM_PROFILE=<name> claude $argv
```

Shell choice and alias install path are recorded in `~/.claude/scripts/profile-config.sh` on first profile creation and reused for subsequent profiles.

### Why this design

A few constraints drove the architecture:

- **No observable behavior change in vanilla `claude` sessions.** Fast-fail guards in hook scripts satisfy this — sub-millisecond exit, no side effects.
- **No reliance on `--dangerously-skip-permissions` or research-preview features.** Plugins shouldn't break for users in managed environments where bypass is disabled, and shouldn't depend on classifier features that are model/plan/provider gated. The tmp+install pattern removes the dependency entirely.
- **Shell does the parsing; agent context stays lean.** SessionStart hooks emit pre-digested banners, not raw log dumps for the agent to interpret.
- **Banners are prescriptive and dismissable.** Every warning names the fix command and has an explicit ack path.

## Repo layout

```text
claude-named-memory/
├── README.md                              ← this file
├── plugins/
│   └── named-memory/
│       ├── .claude-plugin/
│       │   └── plugin.json                ← plugin manifest (name, version, description)
│       ├── hooks/
│       │   └── hooks.json                 ← SessionStart / SessionEnd / PostToolUse registrations,
│       │                                    each referencing ${CLAUDE_PLUGIN_ROOT}/bin/<script>.sh
│       ├── commands/                      ← slash-command markdown (frontmatter + body)
│       │   ├── name.md                    ← /named-memory:name <profile>
│       │   ├── install.md                 ← /named-memory:install
│       │   ├── list.md                    ← /named-memory:list
│       │   ├── view.md                    ← /named-memory:view <name>
│       │   ├── rename.md                  ← /named-memory:rename <old> <new>
│       │   ├── delete.md                  ← /named-memory:delete <name>
│       │   └── ack.md                     ← /named-memory:ack <name>
│       └── bin/                           ← shell scripts; on PATH for the Bash tool inside
│           │                                Claude sessions, but referenced from hooks.json via
│           │                                ${CLAUDE_PLUGIN_ROOT}, NOT via PATH
│           ├── setup-profile.sh           ← creates profile dir + memory.md header + shell alias
│           ├── compact-on-exit.sh         ← SessionEnd hook: tmp+install extractor
│           ├── check-failures.sh          ← SessionStart hook: parses audit.log, emits banner
│           ├── log-memory-edit.sh         ← PostToolUse hook: logs agent writes to memory.md
│           ├── ack-failures.sh            ← appends `user ack` to audit.log
│           ├── install-shortcut.sh        ← drops ~/.claude/commands/name.md
│           ├── list-profiles.sh           ← TSV: name<TAB>words<TAB>mtime<TAB>preview
│           ├── delete-profile.sh          ← removes profile dir + alias (after --yes guard)
│           └── rename-profile.sh          ← moves profile dir + swaps alias
└── .claude-plugin/
    └── marketplace.json                   ← marketplace registration (pachu-plugins)
```

User-side state created at runtime (lives outside the repo, persists across plugin updates):

```text
~/.claude/profiles/<name>/memory.md        ← the persistent memory
~/.claude/profiles/<name>/audit.log        ← append-only TSV
~/.claude/profiles/<name>/extract.log      ← headless-extractor stdout/stderr
~/.claude/scripts/profile-config.sh        ← shell type + alias install path
~/.claude/commands/name.md                 ← /name shortcut (from /named-memory:install)
~/.config/fish/functions/claude-<name>.fish
   or ~/.bashrc / ~/.zshrc alias line      ← the per-profile shell alias
```

## License

MIT
