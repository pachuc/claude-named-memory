---
description: Load a named memory into this session's context
allowed-tools: [Bash, Read]
argument-hint: <name>
---

Load the named memory "$ARGUMENTS" into context for this session.

1. **Enforce one load per session.** If you have already loaded a named memory (via `/load`) or created one (via `/name`) earlier in THIS session, do NOT load another. Tell the user which memory is already active and stop — loading a second would mix unrelated contexts. (Start a fresh session to work with a different memory.)

2. Verify the profile exists: run `test -f ~/.claude/profiles/$ARGUMENTS/memory.md && echo OK || echo MISSING` via Bash. If MISSING, tell the user the profile "$ARGUMENTS" doesn't exist and suggest `/named-memory:list` to see available profiles (or `/name $ARGUMENTS` to create it). Stop.

3. Read `~/.claude/profiles/$ARGUMENTS/memory.md`. Treat its contents as your persistent memory / working context for the rest of this session.

4. Remember, for the rest of this session, that the active named memory is "$ARGUMENTS" — a later `/save` (no argument) will write back to it.

5. Give the user a one-line confirmation that "$ARGUMENTS" is loaded, and note they can persist updates with `/save`.
