#!/usr/bin/env bash
# Read-only diff review by Sol (GPT via Codex CLI).
#
# Read-only is enforced in four independent layers:
#   1. Codex runs with `-s read-only` and approval_policy=never (OS sandbox, cannot be widened from the prompt).
#   2. Codex sees a throwaway snapshot copy of the repo, never the working tree.
#   3. Before/after fingerprints of the real repo AND the snapshot; any change => exit 3 (violation).
#   4. Project hooks reject any direct `codex` call, sandbox-weakening flag or CODEX_BIN override.
#
# Usage: sol-review.sh [--task "<what the change is meant to do>"]
# Exit:  0 PASS | 1 FAIL | 3 read-only violation | 4 empty diff | 5 round cap | 6 invalid output | 7 Codex unavailable
# Only exit 0 means PASS; every other code must be treated as "not reviewed".
set -uo pipefail
. "$(dirname "$0")/lib.sh"

task_note=""
while [ $# -gt 0 ]; do
  case "$1" in
    --task) task_note="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1 (the reviewer sandbox mode cannot be configured from the command line)" >&2; exit 64 ;;
  esac
done

CODEX_BIN="${CODEX_BIN:-codex}"
command -v "$CODEX_BIN" >/dev/null 2>&1 || { echo "Codex CLI not found (npm i -g @openai/codex). Not reviewed." >&2; exit 7; }

if orch_diff_is_empty; then echo "Nothing to review: no changes against HEAD." >&2; exit 4; fi

state="$(orch_state_read)"
round="$(jq -r .round <<<"$state")"
if [ "$round" -ge "$MAX_REVIEW_ROUNDS" ]; then
  echo "Round cap reached ($round/$MAX_REVIEW_ROUNDS). Stop, summarise the unresolved findings and ask the user." >&2
  exit 5
fi
[ -n "$task_note" ] || task_note="$(jq -r .task <<<"$state")"

repo_fingerprint() {
  (
    cd "$ORCH_ROOT" || exit 1
    {
      git rev-parse HEAD
      git for-each-ref
      git status --porcelain=v2 -z
      git config --local --list
      orch_diff_hash
    } 2>&1 | sha256sum | cut -d' ' -f1
  )
}
tree_fingerprint() { (cd "$1" && find . -type f -not -path './.review/*' -print0 | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1); }

work="$(mktemp -d)"; snap="$work/snapshot"; mkdir -p "$snap/.review"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

# --- snapshot (tracked + untracked, non-ignored, size-capped) ---
(
  cd "$ORCH_ROOT" || exit 1
  git ls-files -z -co --exclude-standard | while IFS= read -r -d '' f; do
    [ -f "$f" ] && [ "$(stat -c%s -- "$f")" -le "$SNAPSHOT_MAX_FILE_BYTES" ] && printf '%s\0' "$f"
  done | tar --null -T - -cf - 2>/dev/null
) | tar -xf - -C "$snap"

cur_hash="$(orch_diff_hash)"
( cd "$ORCH_ROOT" && git diff HEAD --binary --stat -- . ':!.claude/state' > "$snap/.review/changed-files.txt"
  git diff HEAD -U8 -- . ':!.claude/state' > "$snap/.review/REVIEW.diff"
  git ls-files -o --exclude-standard -- . ':!.claude/state' | sed 's/^/untracked (new file, read it directly): /' >> "$snap/.review/changed-files.txt" )
[ -f "$ORCH_STATE_DIR/last-review.json" ] && cp "$ORCH_STATE_DIR/last-review.json" "$snap/.review/previous-review.json"
cp "$(dirname "$0")/sol-review.schema.json" "$work/schema.json"

cat > "$work/prompt.md" <<EOF
You are Sol, a strictly read-only code reviewer. You cannot and must not modify, create or delete files; do not try.
The working directory is a snapshot of the repository with the change applied. node_modules and large files are absent, so reason statically.

Change intent: ${task_note:-"(not provided)"}

Review the change in .review/REVIEW.diff (summary in .review/changed-files.txt; untracked files are new files, read them in the tree).
Check, in order: correctness and edge cases; security (injection, auth, secrets, SSRF, path traversal); regressions to existing behaviour;
missing or weak tests for the changed behaviour; consistency with CLAUDE.md conventions. Ignore pure style preferences.
If .review/previous-review.json exists, verify each earlier finding is actually fixed in this diff; report any that are not, reusing the same category slug.

Severity: blocker = wrong/unsafe, must fix; major = likely bug or missing test for changed behaviour; minor/nit = optional.
verdict=PASS only if there are no blocker or major findings. Respond with JSON matching the provided schema and nothing else.
EOF

before_repo="$(repo_fingerprint)"; before_snap="$(tree_fingerprint "$snap")"

env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
timeout "$SOL_TIMEOUT_SECS" "$CODEX_BIN" exec \
  -C "$snap" -s read-only --skip-git-repo-check --ephemeral --ignore-rules --color never \
  -c 'approval_policy="never"' -c 'sandbox_mode="read-only"' \
  -c "model=\"$SOL_MODEL\"" -c "model_reasoning_effort=\"$SOL_REASONING_EFFORT\"" \
  --output-schema "$work/schema.json" -o "$work/out.json" - < "$work/prompt.md" > "$work/codex.log" 2>&1
codex_rc=$?

after_repo="$(repo_fingerprint)"; after_snap="$(tree_fingerprint "$snap")"
if [ "$before_repo" != "$after_repo" ] || [ "$before_snap" != "$after_snap" ]; then
  "$(dirname "$0")/orch-state.sh" record-violation "repo=$([ "$before_repo" = "$after_repo" ] && echo same || echo CHANGED) snapshot=$([ "$before_snap" = "$after_snap" ] && echo same || echo CHANGED)" >/dev/null
  echo "READ-ONLY VIOLATION: files changed while Sol was running. Review discarded; inspect 'git status' and 'git diff' before continuing." >&2
  exit 3
fi

if [ "$codex_rc" -ne 0 ] || [ ! -s "$work/out.json" ]; then
  echo "Codex unavailable or failed (exit $codex_rc). Not reviewed. Last log lines:" >&2
  tail -n 8 "$work/codex.log" >&2
  exit 7
fi
if ! jq -e '.verdict and (.findings|type=="array")' "$work/out.json" >/dev/null 2>&1; then
  echo "Sol returned output that does not match the schema. Not reviewed." >&2; head -c 600 "$work/out.json" >&2; exit 6
fi

# Fail closed: a PASS verdict with blocker/major findings is a FAIL.
verdict="$(jq -r 'if .verdict=="PASS" and ([.findings[]|select(.severity=="blocker" or .severity=="major")]|length)==0 then "PASS" else "FAIL" end' "$work/out.json")"
fps="$(jq -r '[.findings[]|select(.severity=="blocker" or .severity=="major")|(.file+":"+.category)]|join(",")' "$work/out.json")"

jq --arg v "$verdict" --arg h "$cur_hash" '. + {effective_verdict:$v, diff_hash:$h}' "$work/out.json" > "$ORCH_STATE_DIR/last-review.json"
if ! "$(dirname "$0")/orch-state.sh" record-review "$verdict" "$cur_hash" "$fps" >/dev/null; then
  echo "Could not record the review in the orchestration state. Not treated as reviewed." >&2; exit 6
fi

echo "== Sol review (round $((round+1))/$MAX_REVIEW_ROUNDS, model $SOL_MODEL, diff ${cur_hash:0:12}) =="
jq -r '.summary, (.findings[] | "- [\(.severity)] \(.file):\(.line) (\(.category)) \(.issue)\n    fix: \(.fix)")' "$work/out.json"
echo "VERDICT: $verdict"
[ "$verdict" = "PASS" ]
