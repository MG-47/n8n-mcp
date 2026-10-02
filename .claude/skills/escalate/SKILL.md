---
name: escalate
description: Escalate a stuck orchestration loop to Fable. Use only when the same Sol finding survived 2 consecutive rounds, a sonnet-worker reported BLOCKED, or a security/architecture decision cannot be settled by the plan. Not for routine work.
---

# Escalate to Fable (only when really stuck)

Eligibility is enforced by a hook. Eligible automatically when:
- the same blocker/major finding (same file + category) failed `ESCALATE_AFTER_REPEATS` consecutive Sol rounds, or
- a worker ran `orch-state.sh blocked "<reason>"`.

Otherwise, and only if the situation is genuinely a design/security dead end, grant one escalation with a concrete reason (>= 40 chars, it is audit-logged):
`.claude/scripts/orch-state.sh escalate "<specific reason>"`

Steps:
1. Gather: task, the repeated findings (`.claude/state/last-review.json`), what the worker tried, `git diff --stat`.
2. Spawn `fable-escalation` with that package. It is read-only and returns ROOT CAUSE / DECISION / STEPS / VERIFY.
3. Hand its STEPS to `sonnet-worker` unchanged, then resume the review loop at Sol. If the decision is "finding is invalid", record the evidence in the next worker brief and re-run Sol. If it says "needs user input", stop and ask the user that exact question.
4. One Fable call per escalation; the counter resets after use. If it fails again, report to the user rather than escalating repeatedly.
