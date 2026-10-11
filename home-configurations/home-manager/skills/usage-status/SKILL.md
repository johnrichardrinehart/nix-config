---
name: usage-status
description: Show weekly Codex usage pace and catch-up ETAs via codex-weekly-pace.
---

# Usage Status

Use this skill when the user asks about Codex weekly usage pace, over/under status, or catch-up ETAs.

Run:

```bash
if [ -n "${ARGUMENTS:-}" ]; then
  env CODEX_WEEKLY_PACE_RUN=1 codex-weekly-pace ${ARGUMENTS}
else
  env CODEX_WEEKLY_PACE_RUN=1 codex-weekly-pace
fi
```

Examples:

- `$usage-status`
- `$usage-status --watch`
- `$usage-status --interval 15`
