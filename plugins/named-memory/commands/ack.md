---
description: Dismiss the SessionStart failure banner for a named-memory profile
argument-hint: <name>
allowed-tools: [Bash]
---

Run `ack-failures.sh $ARGUMENTS` via Bash. Show the output verbatim.

This appends a `user ack` event to the profile's audit.log, suppressing any pending SessionStart warning banner about past SessionEnd hook failures for that profile. Use this when you've investigated the failure (see `~/.claude/profiles/$ARGUMENTS/extract.log`) and either fixed it or decided not to pursue it. If the hook fails again later, a new banner will appear — ack is per-failure, not permanent.
