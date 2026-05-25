# named-memory: design notes and research log

This document captures what we learned about Claude Code's plugin ecosystem while building this plugin, the constraints that shaped the architecture, the failed paths we explored, and the design decisions we arrived at. It exists so future iterations — and anyone else trying to build a similar "per-session persistent context" tool on Claude Code — don't have to re-discover the same dead ends.

The exploration is dated **2026-05-21 through 2026-05-24**. Claude Code versions and plugin-system behavior may have changed since.

---

## 1. What this plugin is, and what the user wants

Plain `claude` should remain a clean slate.

When the user runs `claude-<name>` (a shell alias the plugin installs), Claude Code starts with:
- A per-name `memory.md` loaded into the system prompt
- Permission to update that `memory.md` mid-session, organically
- A `SessionEnd` hook that, on exit, spawns a headless `claude -p` against the session transcript to extract anything the in-session model missed and compact the file if it has grown past 20,000 characters

The aim is a memory model with:
- **Named profiles**, not project- or session-keyed memory (the user explicitly rejected the multi-file `MEMORY.md` index pattern Claude Code's built-in auto-memory uses)
- **Single `memory.md` per profile** for human readability
- **Organic writes during the session + compaction on exit**, so the user doesn't think about memory management while working

### Hard UX constraints the user set

These shaped most of the architecture and ruled out otherwise-attractive options:

1. **Zero observable behavioral difference during vanilla `claude` sessions.** A user who never touches a `claude-<name>` alias should observe no behavioral change from plain Claude Code. Initially read as "no code path runs at all" — that strict reading would have ruled out plugin-level hooks entirely. Ultimately refined (during the 2026-05-24 architecture discussion) to "no observable change," allowing plugin-level hooks IF they fast-fail in microseconds with no side effects. The fast-fail guard `[ -z "$CLAUDE_NM_PROFILE" ] && exit 0` at the top of each hook script satisfies this; see §4.2 for the implications.
2. **Banners must be prescriptive and dismissable.** If something goes wrong, the user sees the exact fix command, not a stack trace; and every banner has an explicit `ack` path so it can be silenced. No descriptive "X happened, you figure it out" warnings.
3. **Push deterministic work into shell, keep agent context lean.** SessionStart hooks should not feed the agent `audit.log` for the agent to parse — the shell script parses, the agent only sees pre-digested actionable output when there's something to act on.
4. **Only structural failures warrant banners.** The "extractor was too conservative this run" failure mode (exit=0, delta=0) was explicitly excluded from banner emission — too noisy.
5. **No mandatory approval steps for routine actions.** The plugin should not interrupt the user for permission on operations the user has authorized at install time. In particular, the headless SessionEnd extractor must not depend on a flag that may be administratively disabled.

---

## 2. Constraints we discovered in Claude Code's plugin ecosystem

This section catalogs each constraint, with the empirical evidence and where in the docs (if anywhere) it's mentioned. Some were learned by running into walls; others by reading the docs only after the wall.

### 2.1 Hook execution context

**Plugin `bin/` is on PATH for the Bash tool inside a session, but NOT for the `/bin/sh -c` that runs hook commands.** Discovered when the SessionEnd hook silently failed with status 127 (`compact-on-exit.sh: command not found`). The fix is to reference hook scripts by absolute path.

**Hook commands run under `/bin/sh -c`**, not the user's login shell. Don't rely on shell-specific features.

**`SessionEnd` hooks cannot inject work back into the dying session.** There is no `decision: "block"` return value that defers exit. The workaround is to spawn a backgrounded subprocess (`(... ) &`) and let the user's exit proceed; the subprocess outlives the parent session.

**Hooks fire reliably on both `/exit` and double Ctrl+C**, at least when claude is idle at the prompt. Both produce SessionEnd with `reason: "prompt_input_exit"`. Mid-operation Ctrl+C is untested.

### 2.2 Plugin environment variables — set only for plugin-defined hooks

Claude Code exposes path placeholders in hook commands:

- `CLAUDE_PROJECT_DIR` — the project root (always set in hook contexts)
- `CLAUDE_PLUGIN_ROOT` — the *current* plugin install directory (changes on plugin update)
- `CLAUDE_PLUGIN_DATA` — the plugin's persistent data directory, auto-created at `~/.claude/plugins/data/<plugin>[-suffix]/`

In theory, these solve two of our problems at once: scripts can self-reference (`${CLAUDE_PLUGIN_ROOT}/bin/foo.sh`), and persistent state has a plugin-scoped home.

Tested empirically:

| Hook defined in | `CLAUDE_PLUGIN_ROOT` | `CLAUDE_PLUGIN_DATA` |
|---|---|---|
| Plugin's own `hooks/hooks.json` | set to plugin install dir | set to `~/.claude/plugins/data/<name>[-suffix]/` |
| User/profile `settings.json` loaded via `--settings` | empty string | empty string |

The doc phrase "Both forms support the same path placeholders [...] regardless of how it was launched" refers to **exec form vs shell form of the command**, not **plugin-defined vs user-defined hooks**.

Originally we kept hooks in per-profile `settings.json` to honor constraint #1 strictly, which made these env vars unusable. After refining the constraint (§1) and moving hooks to plugin-level (§4.2), `CLAUDE_PLUGIN_ROOT` is now the mechanism that lets hook commands reference plugin scripts at runtime without a stable mirror. `CLAUDE_PLUGIN_DATA` is still unused — it points inside the protected-paths gate (§2.3) so we don't store anything there.

#### Arbitrary user env vars DO propagate to hook commands

A separate test (2026-05-24): custom env vars set in the shell before launching `claude` propagate through to the `/bin/sh -c` that runs hook commands. Verified with three forms:

| Form | Propagates? |
|---|---|
| Inline: `NM_PROFILE=foo OTHER=bar claude ...` | ✅ both visible to hooks |
| Exported: `export NM_PROFILE=foo; claude ...` | ✅ |
| Function wrapper: `wrapper() { NM_PROFILE=foo claude "$@"; }` | ✅ |

Only `PATH` is observably tampered with by Claude Code for hook execution (plugin `bin/` is stripped — that's the historical reason for the `~/.claude/scripts/` mirror in §4.3). Other env vars pass through cleanly.

This is what enables Plan X (§4.2): the per-profile alias sets `CLAUDE_NM_PROFILE=<name>`, hooks read it, vanilla sessions don't set it so the same hook scripts fast-fail.

### 2.3 The sensitive-file gate (`~/.claude/` is a protected directory)

This was the biggest surprise of the build, and the single largest constraint shaping our architecture.

**Claude Code blocks Write/Edit operations on any file under `~/.claude/`**, regardless of permission mode, allowlist, or settings rules. The block is implemented as a hardcoded "protected paths" classification that fires before the usual permission flow.

#### Official protected-paths list (from docs)

Per [permission-modes](https://code.claude.com/docs/en/permission-modes#protected-paths):

> Writes to a small set of paths are never auto-approved, in every mode except `bypassPermissions`. This prevents accidental corruption of repository state and Claude's own configuration.
>
> **Protected directories:**
> - `.git`
> - `.vscode`
> - `.idea`
> - `.husky`
> - `.claude`, **except for** `.claude/commands`, `.claude/agents`, `.claude/skills`, and `.claude/worktrees` where Claude routinely creates content
>
> **Protected files:**
> - `.gitconfig`, `.gitmodules`
> - `.bashrc`, `.bash_profile`, `.zshrc`, `.zprofile`, `.profile`
> - `.ripgreprc`
> - `.mcp.json`, `.claude.json`

Note that `.claude/profiles/` and `.claude/plugins/data/` are NOT in the exception list — they are subject to the gate.

#### Behavior per mode (per docs)

| Mode | Protected-path writes |
|---|---|
| `default` | Prompt (no-op in headless) |
| `acceptEdits` | Prompt (no-op in headless) |
| `plan` | Prompt (no-op in headless) |
| `auto` | Route to classifier (probabilistic) |
| `dontAsk` | Denied |
| `bypassPermissions` | Allowed (since v2.1.126) |

#### Empirical test results (2026-05-23 and 2026-05-24)

| Mechanism | Result writing to `~/.claude/profiles/<name>/memory.md` |
|---|---|
| `--allowed-tools Edit,Write,MultiEdit` | ❌ blocked |
| `--permission-mode acceptEdits` | ❌ blocked |
| `settings.json` with `permissions.allow: ["Edit(<exact path>)"]` + `defaultMode: acceptEdits` | ❌ blocked |
| `PreToolUse` hook returning `permissionDecision: "allow"` (per docs) | ❌ blocked — "Hook decisions do not bypass permission rules" |
| `--permission-mode auto` (10x stress) | ✅ 10/10 in our scenario, but classifier-based; see §2.5 |
| `--permission-mode bypassPermissions` | ✅ |
| `--dangerously-skip-permissions` | ✅ (equivalent to `bypassPermissions`) |
| Write to file outside `~/.claude/` (e.g., `/tmp/...`) | ✅ at `acceptEdits` |

Scope of the gate confirmed by writing to various paths under `~/.claude/` with `acceptEdits`:

| Target | Result |
|---|---|
| `~/.claude/profiles/<name>/memory.md` | blocked |
| `~/.claude/profiles/<name>/test-non-memory.txt` (non-suspicious filename) | blocked |
| `~/.claude/plugins/data/<plugin>/test.txt` (Claude Code's own plugin-data dir) | blocked |
| `~/.claude/test-bare.txt` (bare `~/.claude/`) | blocked |
| `/tmp/test-control.txt` | succeeded |

**Conclusion:** the gate is `~/.claude/`-prefix-wide. It is not keyed to filename, not to content, not to plugin ownership. Even `CLAUDE_PLUGIN_DATA` — Claude Code's *officially blessed* location for plugin-scoped persistent state — is inside the gate.

#### What is NOT gated

- **Reads.** Reading any file under `~/.claude/` works in every mode. The agent can `Read` memory.md, transcripts, etc., freely.
- **Bash writes.** Shell commands invoked via the Bash tool (or, more importantly, from inside a hook script) write to `~/.claude/` paths without the gate firing. The gate only applies to Claude's built-in Edit/Write/MultiEdit tools.

The second point is the architectural keystone of this plugin — see §3.

### 2.4 `--add-dir` is not a sandbox

`--add-dir` is an *allow*-list for tool access, not a write boundary. When combined with `--dangerously-skip-permissions`, the headless agent has full filesystem write access.

Tested on 2026-05-23 against a headless `claude -p` invoked with `--dangerously-skip-permissions --add-dir <profile-dir>`. The agent was asked to attempt seven escape vectors. All seven succeeded:

| Vector | Target | Result |
|---|---|---|
| `Write` tool | `/tmp/escape-test-write.txt` | ✅ escaped |
| `Edit` tool | `~/.bashrc` | ✅ escaped (agent voluntarily reverted) |
| Bash `>` redirect | `/tmp/escape-test-bash.txt` | ✅ escaped |
| Bash `tee` | `/tmp/escape-test-tee.txt` | ✅ escaped |
| Symlink through allowed dir, write through symlink | `/tmp/...` | ✅ escaped |
| `cd /tmp && touch` | `/tmp/escape-test-cd.txt` | ✅ escaped |
| Python subprocess via Bash | `/tmp/escape-test-python.txt` | ✅ escaped |

The only sandbox-like behavior observed was that Bash auto-resets `cwd` after a `cd` outside the allowed dirs — but the `touch` itself still succeeded.

**A headless extractor with `--dangerously-skip-permissions` has effective full filesystem write access.** Bounded only by user-account permissions. This eliminates one of the original arguments for migrating profile data — even after migrating, `--add-dir` doesn't actually confine an agent running with bypass.

### 2.5 Auto mode is a research preview and is non-deterministic

Per [permission-modes#eliminate-prompts-with-auto-mode](https://code.claude.com/docs/en/permission-modes#eliminate-prompts-with-auto-mode):

> Auto mode is a research preview. It reduces prompts but does not guarantee safety. Use it for tasks where you trust the general direction, not as a replacement for review on sensitive operations.

#### Availability

- **Plan**: all plans, BUT on Team and Enterprise an admin must enable it
- **Model**: Sonnet 4.6, Opus 4.6, or Opus 4.7 only (no Haiku, no Sonnet 4.5 or older)
- **Provider**: Anthropic API only — not Bedrock, Vertex, or Foundry
- **Version**: Claude Code v2.1.83+
- **Disable knob**: `permissions.disableAutoMode: "disable"` in any settings file (managed settings can lock it off org-wide)

#### How it works

A separate classifier model reviews each tool call. It auto-approves "safe" actions; routes anything that "escalates beyond your request, targets unrecognized infrastructure, or appears driven by hostile content" through a denial path. The classifier sees user messages, tool calls, and CLAUDE.md content. Tool results are stripped from the classifier's view to defend against indirect prompt injection.

Per Anthropic's own engineering blog: the classifier has a documented **~17% false-negative rate** on dangerous actions. They acknowledge it is not flawless and is "not a drop-in replacement for careful human review on high-stakes infrastructure."

#### Headless `-p` mode behavior

Critical: in `-p` mode, **repeated classifier blocks abort the session** (3-in-a-row or 20-total). There is no human to fall back to. A SessionEnd extractor that relies on auto mode must accept this risk.

#### Configurable rules

The classifier accepts custom prose rules via the `autoMode` settings block:

```json
{
  "autoMode": {
    "environment": ["$defaults", "Org: ACME ..."],
    "allow":       ["$defaults", "Writing to ~/foo/bar is allowed: ..."],
    "soft_deny":   ["$defaults", "Never run migrations outside the CLI"],
    "hard_deny":   ["$defaults", "Never exfiltrate repo to third-party APIs"]
  }
}
```

Precedence: `hard_deny` > `soft_deny` > `allow` (as exception to soft_deny) > explicit user intent. Rules are natural-language descriptions, not regex.

CLI introspection: `claude auto-mode defaults | config | critique`.

Per-invocation rules can be passed via `--settings <file>`. The classifier does NOT read `autoMode` from project-level `.claude/settings.json` — only from user settings, managed settings, `--settings` files, or the Agent SDK.

#### Empirical reliability

Two stress tests, 10 runs each:

| Configuration | Pass rate |
|---|---|
| `--permission-mode auto`, write to `~/.claude/plugins/data/<plugin>/<file>` | 10/10 |
| Same + `--settings <file with autoMode.allow rule>` | 10/10 |

For this specific scenario the classifier is consistent. But we observed one earlier instance where the same call was denied (an outlier later not reproducible). Combined with the documented 17% false-negative rate and the headless-abort behavior, **the classifier is reliable enough for development but not load-bearing enough for a SessionEnd extractor that must succeed every time**.

#### Community context

Simon Willison and others have published critiques of LLM-based safety: non-deterministic, edge-case-prone, no formal guarantees. Several GitHub issues ([#42449](https://github.com/anthropics/claude-code/issues/42449), [#33587](https://github.com/anthropics/claude-code/issues/33587), [#45885](https://github.com/anthropics/claude-code/issues/45885)) document auto-mode availability/enablement bugs.

### 2.6 Bypass options: `--dangerously-skip-permissions` ≡ `--permission-mode bypassPermissions`

The two are functionally equivalent. Both:
- Bypass the protected-paths gate
- Can be administratively disabled via `permissions.disableBypassPermissionsMode: "disable"` in managed settings
- Refuse to start as root/sudo on Linux/macOS unless in a recognized sandbox
- Do NOT bound writes by `--add-dir` (see §2.4)

The `bypassPermissions` form reads as the "official" name; `--dangerously-skip-permissions` is the same effect with a more alarming label.

### 2.7 PreToolUse hooks cannot override protected-path classification

Per [permissions](https://code.claude.com/docs/en/permissions):

> Hook decisions do not bypass permission rules. Deny and ask rules are evaluated regardless of what a PreToolUse hook returns, so a matching deny rule blocks the call and a matching ask rule still prompts even when the hook returned `"allow"` or `"ask"`. This preserves the deny-first precedence [...].

This rules out the otherwise-attractive approach of shipping a plugin-level PreToolUse hook that auto-approves writes to its own data dir.

### 2.8 No plugin install/update lifecycle hooks

The plugin docs list `skills`, `agents`, `hooks`, `mcp`, `monitors`, `lsp` — all *in-session* extension points. No "postinstall", "onUpdate", or "onActivate".

This means anything the plugin needs in the user's filesystem must be set up via:
- A user-invoked slash command (e.g., `/named-memory:install`, `/named-memory:name`)
- Or lazily-on-first-use logic embedded in a hook that runs during a real session

Combined with hard constraint #1, lazy setup via plugin-level hooks is also unavailable. All user-side state must be created or updated via explicit user-invoked commands.

### 2.9 Plugin cache pathing and versioning

Installed plugins live at a version-namespaced path under Claude Code's plugin cache (e.g., `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`). The path changes on every update. A profile's `settings.json` cannot reference plugin scripts by absolute path without being rewritten on every plugin upgrade.

In the original per-profile-settings architecture, this was the reason `refresh-copy.sh` existed: it copied the plugin's `bin/*.sh` to a stable mirror at `~/.claude/scripts/`. After moving to plugin-level hooks (see §4.2), `$CLAUDE_PLUGIN_ROOT` resolves at hook fire time and no mirror is needed.

### 2.10 Settings.json subtleties

- `--settings <file>` is **additive** to the user's default settings; it doesn't replace them. Plugin loading is unaffected.
- Plugin-side `settings.json` only supports a small key set (`agent`, `subagentStatusLine`); it is *not* a general-purpose user-settings override.
- `permissions.allow` patterns documented as `Edit(./path/**)` etc. apply to `settings.json`, **not** to the `--allowedTools` CLI flag (which is a tool-name allowlist, not a path-pattern allowlist).
- `autoMode` settings are NOT read from project `.claude/settings.json` (so a checked-in repo can't grant itself classifier exceptions). Only user settings, managed settings, or `--settings` per-invocation.
- Slash-command frontmatter `description` fields drift independently of body content — they don't auto-update when behavior changes. When changing a command's behavior, both fields need updating, and changes only take effect after `/plugin marketplace update` + `/reload-plugins`.

### 2.11 How other plugins handle persistence

Survey of existing community memory-style plugins. None hit the protected-paths gate, because none of them write to `~/.claude/` via Edit/Write tools:

| Plugin | Storage approach |
|---|---|
| [thedotmack/claude-mem](https://github.com/thedotmack/claude-mem) | SQLite database; writes through Bash, not Edit/Write |
| [coleam00/claude-memory-compiler](https://github.com/coleam00/claude-memory-compiler) | Hook scripts append to daily logs in pure shell |
| [julep-ai/memory-store-plugin](https://github.com/julep-ai/memory-store-plugin) | `.memory-queue.jsonl` in project dir (not `~/.claude/`) |
| [affaan-m/everything-claude-code](https://github.com/affaan-m/everything-claude-code) | Writes to `~/.claude/sessions/` from `sed`/redirects in bash (not Edit/Write) |
| [davegoldblatt/total-recall](https://github.com/davegoldblatt/total-recall) | Daily-log timestamp markers via shell |

The common pattern: **don't use the Edit/Write tool to touch `~/.claude/` paths. Use shell.** This is exactly the workaround we settled on (see §3).

---

## 3. The architectural keystone: shell is not gated

The protected-paths gate fires only on Claude's built-in Edit/Write/MultiEdit tools. It does NOT fire on:

- Bash commands invoked from a hook script (the hook script is the user's shell; Claude is not in the loop)
- Subprocess writes from within a shell command (e.g., `python -c 'open(x).write(y)'`)
- Direct shell redirects, `mv`, `cp`, `tee`
- Any process the user's shell spawns

Equivalently: **any write that doesn't pass through the model's tool-call layer is invisible to the gate.**

This insight unlocks the only architecture that satisfies all our constraints without `--dangerously-skip-permissions`, without auto mode, without migrating data outside `~/.claude/`, and without violating hard constraint #1:

> **Headless `claude -p` writes its proposed new memory contents to a tmpfile under `/tmp/`. The parent hook script (`compact-on-exit.sh`) then `mv`s the tmpfile into place. The agent never writes to a protected path; the gate never fires.**

The agent's reads still go through the Read tool (reads aren't gated, so memory.md and the transcript are accessible normally).

---

## 4. Design decisions

### 4.1 Single `memory.md` per profile

Rejected the built-in auto-memory `MEMORY.md` index + per-fact files pattern. The user wants memory human-readable in one place, compaction is conceptually simpler against one file, and mid-session organic writes are easier when the model maintains one document.

Cost: the file gets large. Mitigated by the 20,000-char compaction threshold and SessionEnd compaction step.

### 4.2 Hooks live in plugin's `hooks/hooks.json` with a fast-fail guard

Plugin-level hooks reference scripts via `${CLAUDE_PLUGIN_ROOT}/bin/<script>.sh` — Claude Code resolves the placeholder at hook fire time, so plugin upgrades automatically resolve to the new script paths.

Each hook script's first executable line is:

```bash
[ -z "${CLAUDE_NM_PROFILE:-}" ] && exit 0
NAME="$CLAUDE_NM_PROFILE"
```

The per-profile alias exports `CLAUDE_NM_PROFILE=<name>` before launching claude. The env var propagates through Claude Code into the `/bin/sh -c` that runs hook commands (empirically verified — see §2.2 for env-var propagation tests). Vanilla `claude` sessions don't set the env var, so hooks fast-fail in sub-millisecond time with no side effects.

This satisfies the refined form of constraint #1 (see §1) and unlocks substantial architectural simplification:
- No `~/.claude/scripts/` mirror — plugin scripts are referenced live via `$CLAUDE_PLUGIN_ROOT`
- No `refresh-copy.sh` — plugin upgrades automatically resolve to new script paths
- No `render-settings.sh` — there is no per-profile `settings.json` template anymore
- Per-profile `settings.json` files are eliminated entirely
- Plugin upgrades are pure: `/plugin marketplace update` + `/reload-plugins` and nothing user-side needs to change

### 4.3 [Historical] Stable script mirror at `~/.claude/scripts/`

This existed in the original per-profile-settings architecture: scripts were copied to `~/.claude/scripts/` as a stable absolute path because the plugin cache path is version-namespaced and unstable. After moving to plugin-level hooks with `$CLAUDE_PLUGIN_ROOT` (§4.2), the mirror is no longer needed and has been removed. `~/.claude/scripts/profile-config.sh` (the shell-detection config) is preserved because it's still needed for alias installation.

### 4.4 [Historical] `render-settings.sh` as single source of truth for the per-profile settings template

This existed in the original per-profile-settings architecture. After moving to plugin-level hooks (§4.2), there is no per-profile `settings.json` file, so `render-settings.sh` was removed. Its single source of truth concern is gone — the hooks are defined once in the plugin's `hooks/hooks.json`.

### 4.5 SessionEnd extractor as backgrounded subprocess

`SessionEnd` hooks cannot block exit or return work to the parent session. The extractor is launched as a backgrounded subshell that survives the parent's exit:

```bash
(
  trap finish EXIT
  echo "[start] ..." >> "$LOG"
  claude -p "..." >> "$LOG" 2>&1
) &
```

The `EXIT` trap inside the subshell guarantees that every `start` event in `audit.log` is paired with either `complete` (exit 0) or `error` (non-zero). The only case the trap cannot catch is SIGKILL of the subshell — handled by the 5-minute orphan-grace window in `check-failures.sh`.

### 4.6 **Agent writes to /tmp, shell installs via `mv`** (the protected-paths workaround)

The decisive design choice. Per §3, the protected-paths gate is invisible to shell-side writes, so the agent's write goes to `/tmp/`, and the hook script then `mv`s the result into `~/.claude/profiles/<name>/memory.md`.

Concrete pattern in `compact-on-exit.sh`:

```bash
TMP_NEW=$(mktemp /tmp/nm-extract-${NAME}.XXXXXX.md)
trap "rm -f $TMP_NEW" EXIT
MTIME_BEFORE=$(stat -c %Y "$MEMORY_FILE")

claude -p "$INSTR Write the new memory contents to $TMP_NEW. Do not modify any file under ~/.claude/." \
  --permission-mode acceptEdits \
  --add-dir "$PROFILE_DIR" \
  --add-dir "$(dirname "$TMP_NEW")" \
  --add-dir "$(dirname "$TRANSCRIPT")" \
  >> "$LOG" 2>&1

if [ -s "$TMP_NEW" ]; then
  MTIME_NOW=$(stat -c %Y "$MEMORY_FILE")
  if [ "$MTIME_NOW" = "$MTIME_BEFORE" ]; then
    mv "$TMP_NEW" "$MEMORY_FILE"
  else
    # race: another writer touched memory.md while extractor ran
    audit hook error "reason=race_detected"
  fi
fi
```

Properties:
- **No `--dangerously-skip-permissions`** — does not depend on bypass flags that may be administratively disabled
- **No auto mode** — does not depend on the research-preview classifier, model/plan gating, or admin enablement
- **No data migration** — profiles stay at `~/.claude/profiles/<name>/`
- **Tighter security than bypass flags** — the headless agent only has Edit access to `/tmp/` + the transcript path; cannot accidentally rewrite `~/.bashrc` or other paths
- **Deterministic** — no LLM judgment on whether the write is "safe"
- **Works on every Claude Code installation** that supports plugins

Cost: a one-sentence change to the agent's instruction prompt ("write to $TMP_NEW, do not touch ~/.claude/") and a 4-line shell install step after the agent finishes.

### 4.7 Race detection via mtime comparison

The Edit tool requires `old_string` to match the current file content; if memory.md changed between agent read and write, the Edit fails cleanly. `mv` has no such check — it blindly overwrites.

To protect against a user opening `claude-<name>` for the same profile while a SessionEnd extractor is still running:
- Record `MTIME_BEFORE` at the start of extraction
- Before `mv`, compare against current mtime
- On mismatch: log `hook error reason=race_detected` and skip the install (memory.md as updated by the new session is preserved)

Low actual probability in practice (extractor takes 30s-3min; users don't typically re-open the same profile that fast). But the check is cheap and the failure mode would be silent data loss without it.

### 4.8 Reads remain through the Read tool

Reads of memory.md and the transcript stay native — they go through Claude's Read tool because reads aren't gated. The agent has full access to the current memory contents for compaction decisions.

### 4.9 Audit log as the single source of truth for hook health

`audit.log` is an append-only TSV per profile:

```
<iso8601> <source> <event> <key=val ...>
2026-... agent wrote tool=Edit size=18234
2026-... hook start transcript=/path/x.jsonl size=18234
2026-... hook complete exit=0 size=19081 delta=+847 transcript=/path/x.jsonl
2026-... hook error exit=127 reason=script_not_found transcript=/path/x.jsonl
2026-... user ack upto=2026-...
```

`source ∈ {agent, hook, user}`, `event ∈ {wrote, start, complete, error, ack}`. Fields are tab-separated (greppable from shell; JSONL was rejected for being uglier in `less`).

Every `hook` event carries `transcript=<path>` so events can be correlated AND so a future `/named-memory:retry` command could replay extraction against a still-on-disk transcript after a fix.

`ack` events live in the same file (not a separate one) — single source of truth.

After the tmp+install refactor, `agent wrote` events from the extractor disappear — the extractor writes to /tmp, not memory.md, so `log-memory-edit.sh` (PostToolUse on Write|Edit|MultiEdit, path-filtered to memory.md) no longer fires. Organic mid-session writes from the interactive agent still produce `agent wrote` events. This is correct behavior.

### 4.10 SessionStart banner is prescriptive and shell-parsed

`check-failures.sh` walks the tail of `audit.log` and emits a banner via JSON `additionalContext` *only* when there's an unacked structural failure. Healthy profile + healthy session = zero new context overhead.

The agent never reads `audit.log` directly. The shell does the parsing, the agent only sees a pre-digested actionable banner. Reflects the user's strong preference for "shell-side parsing, agent context lean."

Banners name the dismiss command:

```
⚠️ named-memory (<name>): SessionEnd hook failed at <ts> (reason=<reason>).
Dismiss: /named-memory:ack <name> (suppress this banner)
Details: ~/.claude/profiles/<name>/extract.log
```

(In v1 the banner also named a `/named-memory:refresh` fix command. After moving to plugin-level hooks (§4.2), the failure modes are more diverse — race detection, install failures, invalid tmp content, etc. — and there's no universal "run this to fix" command. The user reads `extract.log` for specifics.)

The detection logic in `check-failures.sh`:
- Walk `tail -500 audit.log` forward, tracking state
- Latest `user ack` clears prior errors/orphans (acks cover everything before them)
- Latest unacked `hook error` → emit failure banner
- `hook start` with no following `hook complete` → orphan (process killed before EXIT trap fired)
- **5-minute orphan-grace window** — orphans younger than 5 min are ignored (claude -p may still be running); older orphans get a banner

### 4.11 Failure categories deliberately excluded from banners

The "extractor produces no output" category (exit=0, delta=0, repeated runs) was discussed and explicitly excluded. Indistinguishable from legitimate "trivial session, nothing to add" without inspecting transcript content, and false positives are worse than rare misses.

Caveat: this turned out to also mask the original sensitive-file-gate failure mode (an `exit=0 delta=0` that hid permission denials for 2 days on 2026-05-21 through 2026-05-23). The fix is structural (4.6 removes the failure mode entirely), so the "delta=0 = silent failure" risk is now mostly moot.

### 4.12 Auto-ack on fix actions

Two paths to ack a failure:
1. Explicit: `/named-memory:ack <name>`
2. Implicit auto-ack when `/name <name>` (manual memory update) runs (manually updating memory is itself a workaround)

If a different underlying issue persists, the next SessionEnd produces a fresh failure event with a timestamp newer than the ack, and a new banner appears next session.

### 4.13 `PostToolUse` hook scoped by tool, not path

`log-memory-edit.sh` is registered with matcher `"Write|Edit|MultiEdit"`. Path filtering happens inside the script (canonicalize `tool_input.file_path`, compare to the profile's `memory.md`). Tool-name matchers are reliable; path matchers in hook config are less so. Reads are not logged — only writes to `memory.md`.

### 4.14 Native slash commands, not a TUI

Considered and rejected building a TUI (e.g., with opentui) for profile management. Native slash commands compose better with the rest of Claude Code's UX and avoid an entirely new runtime surface to maintain.

### 4.15 Two-layer safety on destructive commands

`/named-memory:delete` uses `AskUserQuestion` in the markdown body PLUS `--yes` enforcement inside the deletion script. Single confirmation paths get fat-fingered; double confirmation matches the user's strong preference for not accidentally nuking real state.

### 4.16 `/name` keeps direct Write (interactive contexts only)

The interactive `/name <profile>` command instructs the in-session agent to update memory.md directly via Edit/Write. In an interactive session, the user is present to approve the protected-paths permission prompt. The user has explicit intent ("I just ran /name"), so the friction is acceptable.

Could be migrated to the tmp+install pattern for prompt-free operation, but adds complexity without clear UX benefit while the user is sitting at the prompt. Deferred to a possible future iteration.

---

## 5. Architectural options we considered and rejected

This section records the alternatives we evaluated for solving the protected-paths problem, so future contributors don't re-tread these paths.

### Option A: Status quo + `--dangerously-skip-permissions`

- **Pros:** No migration. One-line script change. Works today.
- **Cons:**
  - Headless extractor has full filesystem write access (§2.4).
  - Breaks for users in managed environments with `permissions.disableBypassPermissionsMode: "disable"`.
  - Alarming flag name reduces plugin marketplace acceptance.
  - Future Claude Code versions may further restrict the flag.

### Option B: Migrate profile data to `~/.local/share/named-memory/`

- **Pros:** Profile data outside the gate; `acceptEdits` is sufficient. XDG-compliant on Linux.
- **Cons:**
  - One-time migration required.
  - Eight scripts carry hardcoded `$HOME/.claude/profiles/$NAME` prefix.
  - Per-profile `settings.json` files have absolute paths, must be re-rendered.
  - Per-OS path conventions (Linux `~/.local/share`, macOS `~/Library/Application Support/`).
  - Discoverability split — user expects everything Claude under `~/.claude/`.
  - **Does not actually provide a sandbox** (`--add-dir` doesn't bound writes), so the migration's security argument is overstated.

### Option C: Plugin-level hooks with fast-fail guard, profile data in `CLAUDE_PLUGIN_DATA`

- **Pros:** Hooks reference `${CLAUDE_PLUGIN_ROOT}/bin/*.sh` — no `~/.claude/scripts/` mirror, no `refresh-copy.sh`. Cleanest possible architecture.
- **Cons:**
  - Originally judged to violate hard constraint #1 (a plugin-level hook fires on every claude session even with a fast-fail guard). The constraint was later refined (§1) to "no observable behavioral change," which allows the fast-fail guard.
  - `CLAUDE_PLUGIN_DATA` is itself under `~/.claude/plugins/data/` — still subject to the gate. So this option doesn't solve the permission problem *on its own*; it needs to combine with one of A/D/E for writes.
- **Status:** The plugin-level-hooks half of this option is what we ended up adopting (combined with Option D — see the "Chosen" entry below). We dropped the `CLAUDE_PLUGIN_DATA` half because the gate makes it useless and we don't need it once Option D handles writes via shell.

### Option E: `--permission-mode auto` + custom `autoMode.allow` rules via `--settings`

- **Pros:** Tested empirically — 10/10 PASS in our scenario (§2.5). Tighter than bypass flags.
- **Cons:**
  - Auto mode is officially "research preview".
  - Model-gated: Sonnet 4.6+ / Opus 4.6+ only. Headless extractor would have to pin model.
  - Plan-gated: Team/Enterprise admins must enable it.
  - Provider-gated: Anthropic API only (no Bedrock/Vertex/Foundry).
  - Classifier is LLM-based and non-deterministic by design (~17% false-negative rate per Anthropic).
  - In `-p` mode, repeated classifier blocks abort the session — single-point-of-failure for the extractor.
  - Configurability of `autoMode` rules via `--settings` works, but adds a moving part to debug when things go sideways.

### Option D (chosen, combined with relaxed Option C): tmp + shell install, plus plugin-level hooks with fast-fail guard

The final architecture is a synthesis:

- **Option D** — the tmp+install pattern (§3, §4.6) solves the protected-paths gate without `--dangerously-skip-permissions`, auto mode, or data migration.
- **Relaxed Option C** — plugin-level hooks (§4.2) with a fast-fail guard eliminate `~/.claude/scripts/`, `refresh-copy.sh`, `render-settings.sh`, and per-profile `settings.json`.

Constraint #1 was initially read as "no code runs at all in vanilla sessions" — that strict reading made Option C non-viable on its own. It was refined (2026-05-24) to "no observable behavioral change in vanilla sessions" once the architectural cost became clear; a sub-millisecond fast-fail guard satisfies the refined constraint.

The synthesis wins on every axis: deterministic permissions, no bypass flags, no research-preview dependencies, no data migration, no manual mirror sync, and plugin upgrades are pure (`/plugin marketplace update` + `/reload-plugins`, no user-side housekeeping).

---

## 6. Test methodology

For reproducibility. All examples target a profile named `nm-builder` (replace with your profile name).

### 6.1 Verifying SessionEnd hook execution

```bash
claude-<name> --debug hooks --debug-file /tmp/claude-hooks.log
# ... session ...
# /exit or double Ctrl+C
grep -iE 'sessionend|hook' /tmp/claude-hooks.log
```

Status 127 means PATH problem. Status 0 with no `extract.log` activity means script-internal bail.

### 6.2 Probing the protected-paths gate

```bash
claude -p "Use the Write tool to create file_path=<TARGET> with content 'TEST'. Report verbatim." \
  --permission-mode <MODE> \
  --add-dir <ALLOWED_DIR>
ls -la <TARGET>  # did it land?
```

Run with each of: `--allowed-tools`, `--permission-mode acceptEdits`, `--settings <file>` with `permissions.allow`, `--permission-mode auto`, `--permission-mode bypassPermissions`, `--dangerously-skip-permissions`. Document which combinations succeed for which target paths.

### 6.3 Probing `--add-dir` enforcement

```bash
claude -p "Attempt to write outside your allowed dirs via [Write, Edit, Bash redirect, tee, symlink, cd && touch, python subprocess]. Report which succeed." \
  --dangerously-skip-permissions \
  --add-dir <ALLOWED_DIR>
ls /tmp/escape-test-*
```

### 6.4 Verifying plugin env vars in different hook contexts

```bash
# Create a throwaway plugin with hooks/hooks.json that logs $CLAUDE_PLUGIN_ROOT and $CLAUDE_PLUGIN_DATA
mkdir -p /tmp/env-test-plugin/.claude-plugin /tmp/env-test-plugin/hooks
cat > /tmp/env-test-plugin/.claude-plugin/plugin.json <<'EOF'
{"name": "env-test", "description": "test", "version": "0.0.1"}
EOF
cat > /tmp/env-test-plugin/hooks/hooks.json <<'EOF'
{"hooks": {"SessionStart": [{"matcher": ".*", "hooks": [{"type": "command", "command": "echo \"ROOT=$CLAUDE_PLUGIN_ROOT DATA=$CLAUDE_PLUGIN_DATA\" >> /tmp/probe.log"}]}]}}
EOF
claude -p "say hi" --plugin-dir /tmp/env-test-plugin < /dev/null
cat /tmp/probe.log

# Compare against the same hooks via --settings (user-side):
# (write same hook config to /tmp/user-settings.json, then:)
claude -p "say hi" --settings /tmp/user-settings.json < /dev/null
# User-side hooks get empty env vars; plugin-side hooks get them populated.
```

### 6.5 Stress-testing auto mode reliability

```bash
for i in $(seq 1 10); do
  target=$CLAUDE_PLUGIN_DATA/stress-$i.txt
  rm -f $target
  claude -p "Use Write tool to create file_path=$target with content 'OK_$i'." \
    --plugin-dir <plugin> --permission-mode auto --add-dir $CLAUDE_PLUGIN_DATA \
    < /dev/null > /dev/null 2>&1
  [ -f $target ] && echo "PASS" || echo "FAIL"
  rm -f $target
done
```

### 6.6 Verifying arbitrary env var propagation to hook commands

```bash
# Throwaway plugin that logs $CUSTOM_VAR from any hook event
mkdir -p /tmp/envprop/.claude-plugin /tmp/envprop/hooks
cat > /tmp/envprop/.claude-plugin/plugin.json <<'EOF'
{"name": "envprop", "description": "test", "version": "0.0.1"}
EOF
cat > /tmp/envprop/hooks/hooks.json <<'EOF'
{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "echo \"CUSTOM=$CUSTOM_VAR\" >> /tmp/probe.log"}]}]}}
EOF
rm -f /tmp/probe.log

# Three forms of setting the env var, all should yield CUSTOM=hello
CUSTOM_VAR=hello claude -p "say hi" --plugin-dir /tmp/envprop < /dev/null
export CUSTOM_VAR=hello; claude -p "say hi" --plugin-dir /tmp/envprop < /dev/null
wrap() { CUSTOM_VAR=hello claude "$@"; }; wrap -p "say hi" --plugin-dir /tmp/envprop < /dev/null

cat /tmp/probe.log
```

All three runs print `CUSTOM=hello`. Only `PATH` is observably tampered with by Claude Code for hooks.

### 6.7 Verifying the tmp+install pattern end-to-end

The hook script lives at `${CLAUDE_PLUGIN_ROOT}/bin/compact-on-exit.sh` and reads `$CLAUDE_NM_PROFILE` from the env (no positional arg). To exercise it manually:

```bash
# Find the live plugin install dir
PLUGIN_ROOT=$(ls -d ~/.claude/plugins/cache/pachu-plugins/named-memory/*/ | sort -V | tail -1)
TRANSCRIPT=<path to any session jsonl>

CLAUDE_NM_PROFILE=<profile-name> \
  "$PLUGIN_ROOT/bin/compact-on-exit.sh" <<EOF
{"transcript_path":"$TRANSCRIPT","reason":"prompt_input_exit","session_id":"test"}
EOF

# Wait for the backgrounded extractor (~30s–3min)
tail -f ~/.claude/profiles/<profile-name>/audit.log
```

A clean run shows `hook start` paired with `hook complete exit=0` and a non-zero delta. `extract.log` records the tmpfile path, the headless agent's narration, and the install outcome.

---

## 7. References

- [Plugins overview](https://code.claude.com/docs/en/plugins)
- [Plugins reference](https://code.claude.com/docs/en/plugins-reference)
- [Plugin marketplaces](https://code.claude.com/docs/en/plugin-marketplaces)
- [Discover and install plugins](https://code.claude.com/docs/en/discover-plugins)
- [Hooks reference](https://code.claude.com/docs/en/hooks)
- [Permission modes](https://code.claude.com/docs/en/permission-modes) — including protected paths
- [Configure permissions](https://code.claude.com/docs/en/permissions)
- [Configure auto mode](https://code.claude.com/docs/en/auto-mode-config)
- [Auto mode announcement](https://claude.com/blog/auto-mode)
- [Auto mode engineering deep-dive](https://www.anthropic.com/engineering/claude-code-auto-mode)
- [Built-in memory](https://code.claude.com/docs/en/memory)
- [Sandboxing](https://code.claude.com/docs/en/sandboxing)
- [Settings reference](https://code.claude.com/docs/en/settings)

Community plugins surveyed in §2.11:
- [thedotmack/claude-mem](https://github.com/thedotmack/claude-mem)
- [coleam00/claude-memory-compiler](https://github.com/coleam00/claude-memory-compiler)
- [julep-ai/memory-store-plugin](https://github.com/julep-ai/memory-store-plugin)
- [affaan-m/everything-claude-code](https://github.com/affaan-m/everything-claude-code)
- [davegoldblatt/total-recall](https://github.com/davegoldblatt/total-recall)

---

## 8. Things still worth investigating

- **Sandbox config (`sandbox.filesystem.allowWrite` / `denyWrite`)** — documented for Bash sandboxing on Linux/macOS/WSL2. Untested whether it applies to Edit/Write tool calls. If it works for Edit/Write, would provide actual filesystem confinement orthogonal to the protected-paths gate.
- **`/named-memory:retry <name>`** — audit log preserves `transcript=<path>` on every event. If a transcript file is still on disk after a failed extraction, we could replay extraction against it. Not yet built. After the §4.6 refactor, this becomes lower priority — the structural failure mode is gone.
- **`/name <existing>` idempotency** — `setup-profile.sh` intends to preserve memory.md and refresh only the alias. Worth a manual test before relying on the documented "re-run to refresh" workflow.
- **Mid-operation Ctrl+C exit semantics** — `/exit` and idle-prompt double Ctrl+C both fire SessionEnd cleanly. Mid-operation Ctrl+C is untested; may bypass SessionEnd if Claude Code kills child processes ungracefully.
- **Could `/name` also use the tmp+install pattern?** — Would eliminate the in-session permission prompt for memory.md writes. Trade-off is complexity vs. one prompt the user has to approve.
