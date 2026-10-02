---
name: sol-review
description: Get a read-only Sol (Codex) review of the current uncommitted diff, without running the whole pipeline. Invoke as /sol-review [what the change is meant to do].
---

# Sol review of the current diff

Intent (optional): $ARGUMENTS

1. Spawn the `sol-reviewer` agent with that intent (one sentence; if empty, derive it from `git diff --stat`).
2. Show the user the verdict and findings exactly as returned. Do not soften them.
3. Do not fix anything in this skill. If the user wants fixes, hand the findings to `sonnet-worker` (or continue with `/orchestrate`).

Only `RESULT: PASS` is a pass. `NOT_REVIEWED` means no review happened (Sol unavailable, empty diff, round cap, or a read-only violation) and must be reported as such.
