---
name: caveman-stats
description: >
  Show factual OpenCode token usage recorded from completed assistant messages.
  Triggers on /caveman-stats.
---

Call the `caveman_stats` tool exactly once and return its output verbatim. The
OpenCode plugin records completed turns in the XDG state directory and reports
session and lifetime input, output, reasoning, cache-read, and cost totals.

Do not estimate token savings, baselines, or compression ratios. OpenCode hooks
do not expose a counterfactual non-caveman response.
