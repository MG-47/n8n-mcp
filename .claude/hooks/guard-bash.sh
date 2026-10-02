#!/usr/bin/env bash
# PreToolUse(Bash) guard. Exit 2 blocks the call and shows stderr to the model.
# Role comes from `--as <role>` (agent-scoped hook) or from the hook payload's agent_type.
set -uo pipefail
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
export ORCH_ROOT="$ROOT"

role=""
[ "${1:-}" = "--as" ] && role="${2:-}"
input="$(cat)"
cmd="$(jq -r '.tool_input.command // ""' <<<"$input" 2>/dev/null)"
[ -n "$role" ] || role="$(jq -r '.agent_type // ""' <<<"$input" 2>/dev/null)"

deny() { echo "BLOCKED by orchestration guard: $1" >&2; exit 2; }

# --- 1. Codex may only be reached through the read-only wrapper -------------------------------
# `codex` counts only where it would be executed: command position (line start, after ; & | ( ` $( or -c "),
# optionally behind env/sudo/time/xargs/VAR=x prefixes, or launched through npx/bunx/dlx.
pre='(^|[;&|(`]|\$\(|-c[[:space:]]+["'"'"'])[[:space:]]*((env|sudo|time|nohup|exec|xargs|command|stdbuf|timeout[[:space:]]+[0-9a-z]+)[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
codex_cmd="${pre}((npx|bunx|pnpm[[:space:]]+dlx|yarn[[:space:]]+dlx)[[:space:]]+(-[A-Za-z-]+[[:space:]]+)*)?(@openai/)?([^[:space:]]*/)?codex([[:space:]]|\$)"
if grep -Eq '(^|[^A-Za-z0-9_])CODEX_(BIN|HOME)[[:space:]]*=' <<<"$cmd"; then
  deny "overriding the Codex binary/home is not allowed; Codex runs only through .claude/scripts/sol-review.sh"
fi
if grep -Eq "$codex_cmd" <<<"$cmd"; then
  deny "direct Codex use is forbidden. Use .claude/scripts/sol-review.sh (read-only, sandboxed)."
fi
if grep -Eq 'dangerously-bypass|danger-full-access|--full-auto|workspace-write' <<<"$cmd" && grep -Eq "codex|sol-review" <<<"$cmd"; then
  deny "Codex sandbox/approval flags cannot be changed. Sol is read-only by construction."
fi

# --- 2. Role-specific restrictions --------------------------------------------------------------
git_mutating='\bgit\b[^;&|]*\b(commit|push|add|rm|mv|stash|reset|checkout|switch|restore|clean|rebase|merge|cherry-pick|apply|am|tag|branch)\b'
case "$role" in
  sol-reviewer)
    ok_review='^[[:space:]]*(bash[[:space:]]+)?(\./)?\.claude/scripts/sol-review\.sh([[:space:]]+--task[[:space:]]+("[^"`$\\]*"|'"'"'[^'"'"']*'"'"'))?[[:space:]]*$'
    ok_state='^[[:space:]]*(bash[[:space:]]+)?(\./)?\.claude/scripts/orch-state\.sh[[:space:]]+(status|hash)[[:space:]]*$'
    ok_git='^[[:space:]]*git[[:space:]]+(diff|status|log|show)([[:space:]]+[A-Za-z0-9_./:=@^~ -]*)?$'
    if ! grep -Eq "$ok_review" <<<"$cmd" && ! grep -Eq "$ok_state" <<<"$cmd" && ! grep -Eq "$ok_git" <<<"$cmd"; then
      deny "sol-reviewer may only run .claude/scripts/sol-review.sh [--task \"...\"], orch-state.sh status, or read-only git diff/status/log/show."
    fi
    ;;
  sonnet-worker|fable-escalation|general-purpose)
    grep -Eq "$git_mutating" <<<"$cmd" && deny "sub-agents must not run state-changing git commands; the orchestrator commits."
    if grep -Eq 'orch-state\.sh' <<<"$cmd" && ! grep -Eq 'orch-state\.sh[[:space:]]+(status|hash|blocked)\b' <<<"$cmd"; then
      deny "sub-agents may only run orch-state.sh status|hash|blocked."
    fi
    grep -Eq 'sol-review\.sh' <<<"$cmd" && deny "workers do not run the review; the orchestrator dispatches sol-reviewer."
    ;;
esac

# --- 3. Commit / push gate: needs a Sol PASS on the exact current diff while orchestration is active ---
if grep -Eq '\bgit\b[^;&|]*\b(commit|push)\b' <<<"$cmd"; then
  msg="$("$ROOT/.claude/scripts/orch-state.sh" check-commit 2>&1)" || deny "$msg"
fi

exit 0
