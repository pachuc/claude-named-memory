---
description: Delete a named-memory profile after confirming with the user
argument-hint: <name>
allowed-tools: [Bash, AskUserQuestion, Read]
---

Delete the named-memory profile "$ARGUMENTS", confirming first.

1. If "$ARGUMENTS" is empty, tell the user "Usage: /named-memory:delete <name>" and stop.

2. Check that `~/.claude/profiles/$ARGUMENTS/` exists via Bash (`test -d ~/.claude/profiles/$ARGUMENTS`). If not, tell the user "Profile '$ARGUMENTS' not found." and suggest `/named-memory:list`. Stop.

3. Gather what will be removed and show it to the user in a short block:
   - Profile dir path: `~/.claude/profiles/$ARGUMENTS/`
   - memory.md size: run `wc -c < ~/.claude/profiles/$ARGUMENTS/memory.md` to get the char count
   - Shell alias path: read `~/.claude/scripts/profile-config.sh` to find `SHELL_TYPE` and `ALIAS_INSTALL_PATH`. If fish, the alias file is `$ALIAS_INSTALL_PATH/claude-$ARGUMENTS.fish`. If bash/zsh, it's an `alias claude-$ARGUMENTS=...` line inside `$ALIAS_INSTALL_PATH`.

4. Use AskUserQuestion with exactly these two options:
   - Label: "Delete '$ARGUMENTS' permanently" — Description: "Removes the profile directory, memory.md, and shell alias. Cannot be undone."
   - Label: "Cancel" — Description: "Do nothing. Profile stays as-is."
   Question text: "This will permanently remove the profile and all its accumulated memory. Proceed?"

5. If the user picks Cancel (or anything other than the delete option), tell them "Cancelled. Nothing was deleted." and stop.

6. If the user confirms, run `delete-profile.sh --yes $ARGUMENTS` via Bash. Show the output verbatim.
