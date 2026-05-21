---
description: Create or update a named agent profile from this session's context
allowed-tools: [Bash, Write, Read, Edit]
---

Create or update a named agent profile called "$ARGUMENTS".

Steps (do all of this fully automatically — no confirmation prompts):

1. Run `setup-profile.sh $ARGUMENTS` via Bash. This creates `~/.claude/profiles/$ARGUMENTS/` with `memory.md` and `settings.json`, and installs the `claude-$ARGUMENTS` shell alias per the user's profile-config.sh. The script is idempotent: existing memory.md is preserved on re-run.

2. Read `~/.claude/profiles/$ARGUMENTS/memory.md` to see the current state (header plus any existing content below the `---` divider).

3. Reflect on this conversation and update the memory file below the `---` divider. Record any important information about the task or tasks worked on in this session: important things that were built, key insights, any overall plan or project to track, reference filepaths or documents, and notes that may be helpful for future iterations on the work. If memory already exists below the divider, append or integrate new content rather than overwriting. Keep the header (everything above and including the `---`) untouched.

4. Show the user a one-line confirmation: the alias name, the profile dir, and a reminder to use `claude-$ARGUMENTS` in a new shell.
