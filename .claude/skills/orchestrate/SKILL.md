---
name: orchestrate
description: Run a code change through the multi-model pipeline - Opus plans, sonnet-worker implements, Sol (Codex, read-only) reviews the diff, sonnet-worker fixes, Sol re-reviews until PASS. Use for any non-trivial change to this repo (feature, bug fix, refactor). Invoke as /orchestrate <task>.
---

# Orchestrate: plan -> implement -> Sol review -> fix -> re-review until PASS

You (Opus) are the orchestrator. You plan, delegate, judge. You do not implement non-trivial code yourself and you do not review your own diff.
Task: $ARGUMENTS

## 1. Plan (you)
- Read the relevant code and CLAUDE.md. Settle scope, files, acceptance criteria, tests required.
- Split into independent units if they touch disjoint files; each unit becomes one `sonnet-worker` brief (they may run in parallel). Overlapping files = sequential.
- Start the gate: `.claude/scripts/orch-state.sh begin "<one-sentence task>"`.

## 2. Implement (sonnet-worker)
- Spawn `sonnet-worker` with a self-contained brief: goal, files, constraints from CLAUDE.md, acceptance criteria, checks to run. Workers never commit.
- STATUS BLOCKED -> read `/escalate` before doing anything else.

## 3. Review (Sol)
- Spawn `sol-reviewer` (it runs `.claude/scripts/sol-review.sh`, read-only Codex on a snapshot). Pass the one-sentence intent.
- Only `RESULT: PASS` counts. `NOT_REVIEWED` (exit 4/5/6/7) is not a pass: exit 7/6 -> tell the user Sol is unavailable (do not substitute another reviewer to claim PASS); exit 5 -> stop and report unresolved findings; exit 3 -> read-only violation, stop, show `git status`/`git diff`, ask the user.

## 4. Fix loop
- On FAIL: pass Sol's findings verbatim to `sonnet-worker` (blocker/major are mandatory; minor/nit optional). Then go back to step 3 (Sol re-verifies the earlier findings automatically).
- Check Sol's findings against reality before relaying: a clearly wrong finding can be disputed in the brief, with evidence.
- Same finding survives 2 consecutive rounds, or the worker is BLOCKED -> `/escalate` (Fable). Never spawn Fable otherwise; a hook enforces this.
- Round cap is `MAX_REVIEW_ROUNDS` in `.claude/orchestration.conf`. At the cap stop and ask the user.

## 5. Finish
- After `RESULT: PASS`: run `npm run typecheck` and the relevant tests yourself once, then `.claude/scripts/orch-state.sh end`.
- Commit/push only if the user asked (hooks reject commit/push without a Sol PASS on the exact diff). Follow CLAUDE.md for commit attribution.
- Report to the user: what changed, rounds taken, final verdict, any escalations, any disputed findings.

## Hard rules
- Models: orchestrator Opus, workers Sonnet, Fable escalation-only, Sol reviewer-only. Never pass `model: opus` or `haiku` to a sub-agent.
- Sol never edits; neither does `sol-reviewer`. Only `sonnet-worker` edits code.
- Never edit `.claude/hooks`, `.claude/scripts`, `.claude/settings.json` or `.claude/orchestration.conf` to get past a gate; if a gate blocks you, report it.
- Trivial edits (typo, one-line config) can skip the pipeline: do not call `begin`, and say so.
