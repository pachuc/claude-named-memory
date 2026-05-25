---
description: Show the full memory.md content for a named-memory profile
argument-hint: <name>
allowed-tools: [Read, Bash]
---

Show the full memory.md content for profile "$ARGUMENTS".

1. If "$ARGUMENTS" is empty, tell the user "Usage: /named-memory:view <name>" and stop.
2. Read `~/.claude/profiles/$ARGUMENTS/memory.md` and display the contents to the user verbatim.
3. If the file does not exist, tell the user the profile was not found and suggest running `/named-memory:list` to see what's available.

Do not summarize or narrate — just print the file content.
