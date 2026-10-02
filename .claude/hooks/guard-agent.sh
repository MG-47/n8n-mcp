#!/usr/bin/env bash
# PreToolUse(Agent|Task) guard: keeps model roles intact and gates Fable behind real escalation triggers.
set -uo pipefail
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
export ORCH_ROOT="$ROOT"
. "$ROOT/.claude/orchestration.conf"
input="$(cat)"
deny() { echo "BLOCKED by orchestration guard: $1" >&2; exit 2; }

caller="$(jq -r '.agent_type // ""' <<<"$input")"
[ -z "$caller" ] || deny "sub-agents may not spawn further sub-agents."

sub="$(jq -r '.tool_input.subagent_type // ""' <<<"$input")"
model="$(jq -r '.tool_input.model // ""' <<<"$input" | tr '[:upper:]' '[:lower:]')"

wants_fable=false
[ "$sub" = "fable-escalation" ] && wants_fable=true
case "$model" in *fable*) wants_fable=true ;; esac

if $wants_fable; then
  if "$ROOT/.claude/scripts/orch-state.sh" escalation-eligible; then
    "$ROOT/.claude/scripts/orch-state.sh" consume-escalation >/dev/null
    exit 0
  fi
  deny "Fable is escalation-only. Eligible when: the same finding survives ${ESCALATE_AFTER_REPEATS:-2} consecutive Sol rounds, a worker reported BLOCKED (orch-state.sh blocked), or you grant one explicitly with a concrete reason (orch-state.sh escalate \"...\"). None applies right now."
fi

case "$model" in
  ""|sonnet|claude-sonnet-*) ;;
  *) deny "sub-agent model '$model' is not allowed. Workers run on Sonnet ($SONNET_MODEL); Fable only via escalation." ;;
esac

# Sub-agents without a pinned model would inherit Opus. Require our pinned agents or an explicit sonnet model.
if [ -z "$model" ]; then
  f="$ROOT/.claude/agents/$sub.md"
  if [ ! -f "$f" ] || ! sed -n '1,/^---$/p;' "$f" | grep -Eq '^model:[[:space:]]*(sonnet|claude-sonnet-)'; then
    deny "agent '$sub' has no pinned Sonnet model and would inherit the Opus orchestrator model. Pass model: \"sonnet\" or use sonnet-worker."
  fi
fi
exit 0
