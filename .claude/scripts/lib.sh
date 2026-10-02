#!/usr/bin/env bash
# Shared helpers for the orchestration scripts and hooks. Source this file; do not execute it.

command -v jq >/dev/null 2>&1 || { echo "orchestration: jq is required" >&2; return 1 2>/dev/null || exit 1; }

ORCH_ROOT="${ORCH_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ORCH_STATE_DIR="$ORCH_ROOT/.claude/state"
ORCH_STATE_FILE="$ORCH_STATE_DIR/orchestration.json"
ORCH_AUDIT_LOG="$ORCH_STATE_DIR/audit.log"

# shellcheck disable=SC1091
. "$ORCH_ROOT/.claude/orchestration.conf"

orch_audit() {
  mkdir -p "$ORCH_STATE_DIR"
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$ORCH_AUDIT_LOG"
}

# Hash of everything that differs from HEAD (tracked diff + untracked files), excluding .claude/state.
orch_diff_hash() {
  (
    cd "$ORCH_ROOT" || exit 1
    {
      git diff HEAD --binary -- . ':!.claude/state'
      git ls-files -o --exclude-standard -z -- . ':!.claude/state' | sort -z |
        while IFS= read -r -d '' f; do printf '== %s\n' "$f"; cat -- "$f"; done
    } | sha256sum | cut -d' ' -f1
  )
}

orch_diff_is_empty() {
  (
    cd "$ORCH_ROOT" || exit 1
    git diff HEAD --quiet -- . ':!.claude/state' &&
      [ -z "$(git ls-files -o --exclude-standard -- . ':!.claude/state' | head -1)" ]
  )
}

orch_state_read() {
  if [ -f "$ORCH_STATE_FILE" ]; then cat "$ORCH_STATE_FILE"; else
    echo '{"active":false,"task":"","round":0,"last_verdict":"","last_hash":"","last_pass_hash":"","last_fingerprints":[],"repeat_count":0,"worker_blocked":false,"blocked_reason":"","escalation_grant":false,"escalations":0,"violations":0}'
  fi
}

orch_state_write() {
  mkdir -p "$ORCH_STATE_DIR"
  local tmp; tmp="$(mktemp "$ORCH_STATE_DIR/.state.XXXXXX")"
  cat > "$tmp" && mv "$tmp" "$ORCH_STATE_FILE"
}
