#!/usr/bin/env bash
# SessionStart: remind the session of the role split and the state of any active orchestration.
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
export ORCH_ROOT="$ROOT"
echo "Multi-model mode: Opus plans/orchestrates, sonnet-worker implements, sol-reviewer (Codex, read-only) reviews the diff, fable-escalation only on real escalation. Start with /orchestrate."
command -v codex >/dev/null 2>&1 || echo "WARNING: Codex CLI not installed (npm i -g @openai/codex); Sol reviews will fail closed."
s="$("$ROOT/.claude/scripts/orch-state.sh" status 2>/dev/null)" || exit 0
if [ "$(jq -r .active <<<"$s")" = "true" ]; then
  echo "Active orchestration: $(jq -r '"task=\(.task) round=\(.round) last_verdict=\(.last_verdict) reviewed_current=\(.reviewed_current)"' <<<"$s")"
fi
exit 0
