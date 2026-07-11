---
description: Caveman-style code review — one-line findings with severity
---
Review the current diff (or files: $ARGUMENTS).

One line per finding. Format: `path/to/file:line: <emoji> <tier>: <problem>. <fix>.`
Severity: 🔴 bug · 🟡 risk · 🔵 nit · ❓ question. Skip non-issues.
End with totals by severity; use `No issues.` when empty.
