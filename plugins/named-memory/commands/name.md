---
description: Create a new named memory profile from this session's context
allowed-tools: [Bash, Write, Read, Edit]
argument-hint: <name>
---

Create (or refresh) a named memory profile called "$ARGUMENTS" from this session.

Steps (do all of this fully automatically — no confirmation prompts):

1. Run `setup-profile.sh $ARGUMENTS` via Bash. This creates `~/.claude/profiles/$ARGUMENTS/` with a templated `memory.md`. It is idempotent: an existing memory.md is preserved.

2. Run `install-alias.sh $ARGUMENTS` via Bash. In the minimal (default) experience this prints a "minimal mode" notice and does nothing to the user's shell. If the user has run `/install-extra`, it installs/refreshes the `claude-$ARGUMENTS` shell alias. Show its output.

3. Read `~/.claude/profiles/$ARGUMENTS/memory.md` to see the current state (header plus any existing content below the `---` divider).

4. Reflect on this conversation and update the memory file below the `---` divider. Record any important information about the task or tasks worked on in this session: important things that were built, key insights, any overall plan or project to track, reference filepaths or documents, and notes that may be helpful for future iterations on the work. If memory already exists below the divider, append or integrate new content rather than overwriting. Keep the header (everything above and including the `---`) untouched.

5. Run `ack-failures.sh $ARGUMENTS` via Bash. Manually updating memory is itself a fix action, so any pending SessionEnd-failure banner for this profile can be dismissed.

6. Run `session-marker.sh set $ARGUMENTS` via Bash to record "$ARGUMENTS" as the active profile for this session. A later `/save` (no argument) reads this marker to know where to write. (In the extra tier the `CLAUDE_NM_PROFILE` env var already pins the active profile and takes precedence, so this is a harmless no-op there.)

7. Show the user a one-line confirmation: the profile dir, and — if an alias was installed — a reminder to use `claude-$ARGUMENTS` in a new shell. If in minimal mode, remind them they can update this memory later with `/save`, or run `/install-extra` for the automatic experience.
