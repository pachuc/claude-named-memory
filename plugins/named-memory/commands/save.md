---
description: Save the active named memory (loaded or created this session) back to disk
allowed-tools: [Bash, Read, Edit, Write]
---

Persist the active named memory for this session back to its `memory.md`.

1. **Determine the target.** The target is the named memory you loaded via `/load` or created via `/name` earlier in THIS session. This command takes no argument. If you have NOT loaded or created a named memory this session, do not guess — tell the user to run `/load <name>` (to update an existing memory) or `/name <name>` (to create one) first, then stop.

2. Read `~/.claude/profiles/<name>/memory.md` to see the current state (header plus content below the `---` divider).

3. Update the memory file below the `---` divider with anything worth keeping from this session since it was loaded/created: important things built, key insights, the overall plan or project to track, reference filepaths or documents, and notes helpful for future iterations. Integrate or append rather than overwriting existing content; keep the header (everything above and including the `---`) untouched. Write directly to `~/.claude/profiles/<name>/memory.md` with Edit/Write.

4. Show the user a one-line confirmation naming the profile that was saved.
