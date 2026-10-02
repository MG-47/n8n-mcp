#!/usr/bin/env bash
# Stop hook: do not finish an orchestrated task while the current diff lacks a Sol PASS.
set -uo pipefail
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
export ORCH_ROOT="$ROOT"
input="$(cat)"
# One block per stop attempt; a second attempt goes through so the session can report why it is stuck.
[ "$(jq -r '.stop_hook_active // false' <<<"$input")" = "true" ] && exit 0

s="$("$ROOT/.claude/scripts/orch-state.sh" status 2>/dev/null)" || exit 0
[ "$(jq -r '.active' <<<"$s")" = "true" ] || exit 0
[ "$(jq -r '.reviewed_current' <<<"$s")" = "true" ] && exit 0
. "$ROOT/.claude/scripts/lib.sh"
orch_diff_is_empty && exit 0

{
  echo "Orchestrated task is active and the current diff has no Sol PASS (round $(jq -r .round <<<"$s")/$MAX_REVIEW_ROUNDS, last verdict: $(jq -r '.last_verdict' <<<"$s"))."
  echo "Continue the loop: dispatch sol-reviewer; on FAIL dispatch sonnet-worker with the findings. If Sol is unavailable or the round cap is hit, report that to the user instead of claiming completion."
} >&2
exit 2
