---
description: List all named-memory profiles with sizes and last-modified times
allowed-tools: [Bash]
---

Run `list-profiles.sh` via Bash. It emits one TSV line per profile: `name<TAB>chars<TAB>mtime<TAB>preview`.

If the output is empty, tell the user: "No named-memory profiles found. Create one with `/name <name>` or `/named-memory:name <name>`." Then stop.

Otherwise, render a clean table for the user with columns: **Name**, **Size**, **Modified**, **Preview**.

- Size: format the raw char count as e.g. `14.8k` for thousands, `812` for under 1000. Append ` (near limit)` if chars > 18000 (compaction triggers at 20000).
- Preview: truncate to ~60 characters with an ellipsis if longer.
- Align columns so it's readable.

Do not narrate the steps — just print the table.
