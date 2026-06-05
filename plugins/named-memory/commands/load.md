---
description: Load a named memory into this session's context
allowed-tools: [Bash, Read]
argument-hint: <name>
---

Load the named memory "$ARGUMENTS" into context for this session.

1. **Enforce one load per session.** Run `session-marker.sh get` via Bash to find the profile already active this session (if any — in the extra tier this is the `claude-<name>` profile, in the minimal tier it's whatever was loaded/created this session).
   - If it prints a name **different** from "$ARGUMENTS": tell the user that memory is already active and stop — loading a second would mix unrelated contexts. (Start a fresh session to work with a different memory.)
   - If it prints "$ARGUMENTS" (same name): it's already loaded; you may re-read to refresh, then confirm and stop.
   - If it prints nothing: proceed.

2. Verify the profile exists: run `test -f ~/.claude/profiles/$ARGUMENTS/memory.md && echo OK || echo MISSING` via Bash. If MISSING, tell the user the profile "$ARGUMENTS" doesn't exist and suggest `/named-memory:list` to see available profiles (or `/name $ARGUMENTS` to create it). Stop.

3. Read `~/.claude/profiles/$ARGUMENTS/memory.md`. Treat its contents as your persistent memory / working context for the rest of this session.

4. Run `session-marker.sh set $ARGUMENTS` via Bash to record "$ARGUMENTS" as the active profile for this session. A later `/save` (no argument) reads this marker to know where to write. (In the extra tier the `CLAUDE_NM_PROFILE` env var already pins the active profile and takes precedence, so this is a harmless no-op there.)

5. Give the user a one-line confirmation that "$ARGUMENTS" is loaded, and note they can persist updates with `/save`.
