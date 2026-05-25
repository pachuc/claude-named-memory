---
description: Rename a named-memory profile (moves dir, updates settings.json, swaps shell alias)
argument-hint: <old-name> <new-name>
allowed-tools: [Bash]
---

Rename a named-memory profile.

If "$ARGUMENTS" does not contain exactly two whitespace-separated tokens (an old name and a new name), tell the user "Usage: /named-memory:rename <old-name> <new-name>" and stop.

Otherwise, run `rename-profile.sh $ARGUMENTS` via Bash. The script validates names, refuses if the old profile doesn't exist or the new name is already taken, then moves the profile dir, regenerates `settings.json`, removes the old shell alias, and installs the new one. memory.md content is preserved.

Show the script's output to the user verbatim. Do not add narration.
