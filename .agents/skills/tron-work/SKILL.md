---
name: tron-work
description: Show the live work dashboard (needs-you items, epics, claims, Ready queue, stale claims, disagreements, orphans, regressions). Use when the user asks for the board, the dashboard, or work status.
---

# Tron work

Follow [shared rules](../../../AGENTS.md). The command, its sections and its
failure modes are owned by [tools/work/README.md](../../../tools/work/README.md#dashboard).
The dashboard is read-only and fetched live; it never changes an issue, a
branch or the Project.

## Show the dashboard

When the user asks for the board, the dashboard or the work status:

1. Write it into the Tron internal workspace, using the resolved workspace
   root from your context (never a hard-coded personal path), under
   `files/work-dashboard/` with a UTC timestamp as the file name:

   ```bash
   scripts/tron work dashboard --html "<Tron internal workspace>/files/work-dashboard/<timestamp>.html"
   ```

   The command also prints a text summary. If it fails, report its `work:`
   error; do not retry with a cached or partial result.
2. Present the file with the `display` tool, using
   `source: { "kind": "internal_file", "path": "work-dashboard/<timestamp>.html" }`
   (the path is relative to `files/`) and `presentation.surface` `inline` or
   `sheet`.
3. In chat, summarize each **Needs you** item (issue number, title and why it
   needs the user). Mention stale claims, disagreements, orphans and open
   regressions only when present. Do not act on them unless the user asks.
