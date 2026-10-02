#!/usr/bin/env bash
# Orchestration state for the plan -> implement -> Sol review -> fix loop.
# Usage: orch-state.sh <begin|status|hash|end|blocked|escalate|record-review|consume-escalation|check-commit|escalation-eligible> [args]
set -euo pipefail
. "$(dirname "$0")/lib.sh"

cmd="${1:-status}"; shift || true

case "$cmd" in
  begin)
    task="${1:?usage: begin \"<task description>\"}"
    orch_state_read | jq --arg t "$task" \
      '.active=true | .task=$t | .round=0 | .last_verdict="" | .last_hash="" | .last_pass_hash=""
       | .last_fingerprints=[] | .repeat_count=0 | .worker_blocked=false | .blocked_reason=""
       | .escalation_grant=false | .escalations=0 | .violations=0' | orch_state_write
    orch_audit "begin task=\"$task\""
    echo "orchestration active: $task"
    ;;

  status)
    orch_state_read | jq --arg cur "$(orch_diff_hash)" '. + {current_hash:$cur, reviewed_current: (.last_pass_hash==$cur)}'
    ;;

  hash)
    orch_diff_hash
    ;;

  end)
    cur="$(orch_diff_hash)"
    last_pass="$(orch_state_read | jq -r .last_pass_hash)"
    if orch_diff_is_empty || [ "$cur" = "$last_pass" ]; then
      orch_state_read | jq '.active=false' | orch_state_write
      orch_audit "end ok"
      echo "orchestration ended"
    else
      echo "REFUSED: current diff has no Sol PASS (run .claude/scripts/sol-review.sh)" >&2
      exit 1
    fi
    ;;

  blocked)
    reason="${1:?usage: blocked \"<what the worker could not resolve>\"}"
    orch_state_read | jq --arg r "$reason" '.worker_blocked=true | .blocked_reason=$r' | orch_state_write
    orch_audit "worker_blocked reason=\"$reason\""
    echo "worker blocked recorded; Fable escalation is now eligible"
    ;;

  escalate)
    reason="${1:?usage: escalate \"<reason, >=40 chars>\"}"
    if [ "${#reason}" -lt 40 ]; then echo "REFUSED: give a concrete reason (>=40 chars)" >&2; exit 1; fi
    orch_state_read | jq '.escalation_grant=true' | orch_state_write
    orch_audit "escalation_grant reason=\"$reason\""
    echo "one Fable escalation granted"
    ;;

  escalation-eligible)
    s="$(orch_state_read)"
    jq -e --argjson n "$ESCALATE_AFTER_REPEATS" \
      '.active and (.worker_blocked or .escalation_grant or .repeat_count >= $n)' <<<"$s" >/dev/null
    ;;

  consume-escalation)
    orch_state_read | jq '.worker_blocked=false | .blocked_reason="" | .escalation_grant=false
                          | .repeat_count=0 | .escalations+=1' | orch_state_write
    orch_audit "escalation_consumed"
    ;;

  record-review)
    verdict="${1:?verdict}"; hash="${2:?hash}"; fps="${3:-}"
    fp_json="$(printf '%s\n' "$fps" | jq -R 'split(",") | map(select(length>0))')"
    orch_state_read | jq --arg v "$verdict" --arg h "$hash" --argjson fp "$fp_json" '
      (.last_verdict=="FAIL" and ($fp - (.last_fingerprints) | length) < ($fp | length)) as $repeat
      | .round += 1
      | .last_verdict=$v | .last_hash=$h
      | if $v=="PASS" then .last_pass_hash=$h | .repeat_count=0 | .last_fingerprints=[]
        else .last_fingerprints=$fp | .repeat_count=(if $repeat then .repeat_count+1 elif ($fp|length)>0 then 1 else 0 end) end' |
      orch_state_write
    orch_audit "review verdict=$verdict hash=${hash:0:12} findings=$fps"
    ;;

  record-violation)
    orch_state_read | jq '.violations+=1' | orch_state_write
    orch_audit "READ_ONLY_VIOLATION ${1:-}"
    ;;

  check-commit)
    s="$(orch_state_read)"
    if [ "$(jq -r .active <<<"$s")" != "true" ]; then exit 0; fi
    if [ "$(jq -r .last_pass_hash <<<"$s")" = "$(orch_diff_hash)" ]; then exit 0; fi
    echo "No Sol PASS for the current diff. Run .claude/scripts/sol-review.sh before commit/push." >&2
    exit 1
    ;;

  *)
    echo "unknown command: $cmd" >&2; exit 64 ;;
esac
