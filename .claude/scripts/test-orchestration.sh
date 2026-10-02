#!/usr/bin/env bash
# Self-test for the multi-model orchestration: guards, state machine, Sol wrapper (stub Codex) and the real
# Codex read-only sandbox. Runs in a scratch git repo; the real repo's .claude/state is untouched.
# Usage: .claude/scripts/test-orchestration.sh
set -uo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
command -v jq >/dev/null || { echo "jq required"; exit 2; }

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { # check "<name>" "<expected rc>" "<actual rc>"
  if [ "$2" = "$3" ]; then ok "$1 (rc=$3)"; else bad "$1 (expected rc=$2, got $3)"; fi
}

T="$(mktemp -d)"; trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
R="$T/repo"; mkdir -p "$R"   # scratch repo; stub files live in $T, outside it
export ORCH_ROOT="$R" CLAUDE_PROJECT_DIR="$R"
cd "$R" && git init -q && git config user.email t@t && git config user.name t
mkdir -p .claude && cp -r "$SRC/.claude/"{hooks,scripts,orchestration.conf,agents} .claude/
printf '.claude/state/\n' > .gitignore; echo one > a.txt
git add -A && git commit -qm base
S=".claude/scripts"
state() { "$S/orch-state.sh" "$@"; }

gb() { # guard-bash: gb <command> [agent_type]  -> rc
  jq -nc --arg c "$1" --arg a "${2:-}" '{tool_name:"Bash",tool_input:{command:$c}} + (if $a=="" then {} else {agent_type:$a} end)' |
    .claude/hooks/guard-bash.sh >/dev/null 2>&1; echo $?
}
ga() { # guard-agent: ga <subagent_type> [model] [caller_agent_type] -> rc
  jq -nc --arg s "$1" --arg m "${2:-}" --arg a "${3:-}" \
    '{tool_name:"Agent",tool_input:({subagent_type:$s} + (if $m=="" then {} else {model:$m} end))} + (if $a=="" then {} else {agent_type:$a} end)' |
    .claude/hooks/guard-agent.sh >/dev/null 2>&1; echo $?
}

echo "== 1. Codex can only be reached through the wrapper (guard-bash)"
check "direct codex exec blocked"            2 "$(gb 'codex exec hello')"
check "codex behind && blocked"              2 "$(gb 'cd x && codex review')"
check "codex behind env var blocked"         2 "$(gb 'FOO=1 codex exec x')"
check "absolute path codex blocked"          2 "$(gb '/usr/local/bin/codex exec x')"
check "npx codex blocked"                    2 "$(gb 'npx -y @openai/codex exec x')"
check "bash -c codex blocked"                2 "$(gb 'bash -c "codex exec x"')"
check "bypass flag blocked"                  2 "$(gb 'codex exec --dangerously-bypass-approvals-and-sandbox x')"
check "workspace-write via wrapper blocked"  2 "$(gb '.claude/scripts/sol-review.sh -s workspace-write')"
check "CODEX_BIN override blocked"           2 "$(gb 'CODEX_BIN=/tmp/evil .claude/scripts/sol-review.sh')"
check "CODEX_HOME override blocked"          2 "$(gb 'export CODEX_HOME=/tmp/x')"
check "wrapper allowed"                      0 "$(gb '.claude/scripts/sol-review.sh --task "x"')"
check "npm install codex allowed"            0 "$(gb 'npm i -g @openai/codex')"
check "grep for the word allowed"            0 "$(gb 'grep -r codex src')"
check "heredoc mentioning codex allowed"     0 "$(gb $'cat <<EOF\nuse the codex tool\nEOF')"

echo "== 2. Role restrictions"
check "reviewer: wrapper ok"                 0 "$(gb '.claude/scripts/sol-review.sh --task "add x"' sol-reviewer)"
check "reviewer: git diff ok"                0 "$(gb 'git diff --stat' sol-reviewer)"
check "reviewer: arbitrary bash blocked"     2 "$(gb 'echo x > a.txt' sol-reviewer)"
check "reviewer: sed -i blocked"             2 "$(gb 'sed -i s/one/two/ a.txt' sol-reviewer)"
check "reviewer: chained cmd blocked"        2 "$(gb '.claude/scripts/sol-review.sh; rm -rf .' sol-reviewer)"
check "reviewer: git commit blocked"         2 "$(gb 'git commit -am x' sol-reviewer)"
check "worker: git commit blocked"           2 "$(gb 'git commit -am x' sonnet-worker)"
check "worker: git push blocked"             2 "$(gb 'git push origin x' sonnet-worker)"
check "worker: git add blocked"              2 "$(gb 'git add -A' sonnet-worker)"
check "worker: sol-review blocked"           2 "$(gb '.claude/scripts/sol-review.sh' sonnet-worker)"
check "worker: orch-state begin blocked"     2 "$(gb '.claude/scripts/orch-state.sh begin x' sonnet-worker)"
check "worker: orch-state blocked ok"        0 "$(gb '.claude/scripts/orch-state.sh blocked "why"' sonnet-worker)"
check "worker: npm test ok"                  0 "$(gb 'npm test -- tests/unit/x.test.ts' sonnet-worker)"
check "fable: git reset blocked"             2 "$(gb 'git reset --hard' fable-escalation)"
state begin "guard tests" >/dev/null; state hash >/dev/null
echo two > a.txt  # diff without PASS
check "orchestrator: commit w/o PASS blocked" 2 "$(gb 'git commit -am x')"
check "orchestrator: push w/o PASS blocked"   2 "$(gb 'git push origin main')"
state end >/dev/null 2>&1; check "end refused w/o PASS" 1 "$?"
git checkout -q a.txt; state end >/dev/null; echo two > a.txt

echo "== 3. Agent model roles (guard-agent)"
state begin "agent guard tests" >/dev/null
check "sonnet-worker allowed"                0 "$(ga sonnet-worker)"
check "sol-reviewer allowed"                 0 "$(ga sol-reviewer)"
check "pinned custom agent allowed"          0 "$(ga debugger)"
check "model sonnet allowed"                 0 "$(ga general-purpose sonnet)"
check "unpinned built-in blocked"            2 "$(ga general-purpose)"
check "opus sub-agent blocked"               2 "$(ga sonnet-worker opus)"
check "haiku sub-agent blocked"              2 "$(ga sonnet-worker haiku)"
check "fable agent blocked (no trigger)"     2 "$(ga fable-escalation)"
check "fable via model override blocked"     2 "$(ga sonnet-worker fable)"
check "nested spawn blocked"                 2 "$(ga sonnet-worker '' sonnet-worker)"
state escalate "short" >/dev/null 2>&1;       check "escalate: vague reason refused" 1 "$?"
state escalate "x" >/dev/null 2>&1;           check "escalate: tiny reason refused" 1 "$?"

echo "== 4. Sol wrapper with stub Codex (fail-closed behaviour)"
cat > "$T/stub-codex" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
out=""; dir=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; -C) dir="$2"; shift ;; esac; shift; done
cat > /dev/null
PASS='{"verdict":"PASS","summary":"looks fine","findings":[]}'
FAIL='{"verdict":"FAIL","summary":"needs a test","findings":[{"category":"missing-test","severity":"major","file":"a.txt","line":1,"issue":"no test","fix":"add one"}]}'
case "$STUB_MODE" in
  pass) echo "$PASS" > "$out" ;;
  fail) echo "$FAIL" > "$out" ;;
  pass_with_major) echo "${FAIL/FAIL/PASS}" > "$out" ;;
  mutate_snapshot) echo hacked >> "$dir/a.txt"; echo "$PASS" > "$out" ;;
  mutate_repo) echo hacked >> "$STUB_REPO/a.txt"; echo "$PASS" > "$out" ;;
  plant_repo) touch "$STUB_REPO/planted"; echo "$PASS" > "$out" ;;
  move_head) git -C "$STUB_REPO" commit -qam sneaky; echo "$PASS" > "$out" ;;
  authfail) echo "not logged in" >&2; exit 1 ;;
  garbage) echo "nope" > "$out" ;;
esac
STUB
chmod +x "$T/stub-codex"
export CODEX_BIN="$T/stub-codex" STUB_LOG="$T/stub.log" STUB_REPO="$R"
run() { STUB_MODE="$1" "$S/sol-review.sh" --task "test change" >"$T/out.txt" 2>"$T/err.txt"; echo $?; }

git checkout -q a.txt; state end >/dev/null; state begin "wrapper tests" >/dev/null
check "empty diff => exit 4"                 4 "$(run pass)"
echo two > a.txt
check "extra sandbox arg rejected"           64 "$("$S/sol-review.sh" --sandbox danger-full-access >/dev/null 2>&1; echo $?)"
check "FAIL verdict => exit 1"               1 "$(run fail)"
grep -q 'VERDICT: FAIL' "$T/out.txt" && ok "FAIL report printed" || bad "FAIL report missing"
check "authfail => exit 7 (not a pass)"      7 "$(run authfail)"
check "garbage output => exit 6"             6 "$(run garbage)"
check "PASS + major finding => FAIL (closed)" 1 "$(run pass_with_major)"
check "reviewed_current false before PASS"   false "$(state status | jq -r .reviewed_current)"
check "FAIL x2 same finding => escalation eligible" 0 "$(state escalation-eligible; echo $?)"
check "round counter advanced"               2 "$(state status | jq -r .round)"

echo "-- read-only enforcement (stub tries to write)"
check "write into snapshot => exit 3"        3 "$(run mutate_snapshot)"
check "write into real repo => exit 3"       3 "$(run mutate_repo)"
git checkout -q a.txt 2>/dev/null; echo two > a.txt
check "planted file in repo => exit 3"       3 "$(run plant_repo)"; rm -f "$R/planted"
check "commit/HEAD move in repo => exit 3"   3 "$(run move_head)"
git reset -q --hard HEAD~1; echo two > a.txt
check "violations recorded"                  true "$([ "$(state status | jq -r .violations)" -ge 4 ] && echo true || echo false)"
grep -q -- '-s read-only' "$T/stub.log" && ok "wrapper passes -s read-only" || bad "-s read-only missing"
grep -q 'approval_policy="never"' "$T/stub.log" && ok "wrapper passes approval_policy=never" || bad "approval_policy missing"
grep -q 'sandbox_mode="read-only"' "$T/stub.log" && ok "wrapper passes sandbox_mode=read-only" || bad "sandbox_mode missing"
! grep -Eq 'danger|bypass|workspace-write|full-auto' "$T/stub.log" && ok "no sandbox-widening flags ever passed" || bad "widening flag seen"

echo "-- PASS path, commit gate, escalation gate"
state begin "pass path" >/dev/null
check "PASS => exit 0"                       0 "$(run pass)"
check "reviewed_current true after PASS"     true "$(state status | jq -r .reviewed_current)"
check "commit allowed after PASS"            0 "$(gb 'git commit -am x')"
echo three > a.txt
check "commit blocked once diff changed"     2 "$(gb 'git commit -am x')"
check "stop-gate blocks unreviewed diff"     2 "$(echo '{}' | .claude/hooks/stop-gate.sh >/dev/null 2>&1; echo $?)"
check "stop-gate lets 2nd attempt through"   0 "$(echo '{"stop_hook_active":true}' | .claude/hooks/stop-gate.sh >/dev/null 2>&1; echo $?)"
check "round cap => exit 5"                  5 "$(MAX_REVIEW_ROUNDS=1 run pass)"
echo two > a.txt; state begin "pass path 2" >/dev/null; run pass >/dev/null
state end >/dev/null; check "end ok after PASS" 0 "$?"
check "stop-gate silent after end"           0 "$(echo '{}' | .claude/hooks/stop-gate.sh >/dev/null 2>&1; echo $?)"

state begin "fable gate" >/dev/null
check "fable blocked with no trigger"        2 "$(ga fable-escalation)"
state blocked "worker could not reconcile X with Y after two attempts" >/dev/null
check "fable allowed after BLOCKED"          0 "$(ga fable-escalation)"
check "fable grant is one-shot"              2 "$(ga fable-escalation)"
state escalate "security tradeoff in session persistence cannot be settled by the plan" >/dev/null
check "explicit logged grant allows Fable"   0 "$(ga fable-escalation)"
check "grant logged in audit"                true "$(grep -q escalation_grant "$R/.claude/state/audit.log" && echo true || echo false)"
state end >/dev/null 2>&1 || { echo two > a.txt; git checkout -q a.txt; state end >/dev/null; }

echo "== 5. Static config"
cd "$SRC"
jq -e '.model=="claude-opus-5-5"' .claude/settings.json >/dev/null && ok "orchestrator model pinned to Opus 5.5" || bad "settings.json model"
for f in sonnet-worker sol-reviewer; do
  grep -q '^model: claude-sonnet-5-5' ".claude/agents/$f.md" && ok "$f pinned to Sonnet 5.5" || bad "$f model"
done
grep -q '^model: claude-fable-5-1' .claude/agents/fable-escalation.md && ok "fable-escalation pinned to Fable 5.1" || bad "fable model"
unpinned="$(for f in .claude/agents/*.md; do n=$(basename "$f" .md); [ "$n" = fable-escalation ] && continue; sed -n '1,/^---$/p' "$f" | grep -Eq '^model: claude-sonnet-5-5' || echo "$n"; done)"
[ -z "$unpinned" ] && ok "every other project agent is pinned to Sonnet" || bad "unpinned agents: $unpinned"
for f in sol-reviewer fable-escalation; do
  tools="$(sed -n '1,/^---$/p' ".claude/agents/$f.md" | grep '^tools:')"
  grep -Eq 'Edit|Write|NotebookEdit' <<<"$tools" && bad "$f has a write tool" || ok "$f has no Edit/Write tools"
done
for s in orchestrate sol-review escalate; do [ -f ".claude/skills/$s/SKILL.md" ] && ok "skill $s present" || bad "skill $s missing"; done
git check-ignore -q .claude/state/x && ok ".claude/state is gitignored" || bad ".claude/state not ignored"

echo "== 6. Real Codex read-only sandbox"
if command -v codex >/dev/null 2>&1; then
  probe="$SRC/.claude/state/.sandbox-probe"; mkdir -p "$SRC/.claude/state"; rm -f "$probe"
  codex sandbox -c 'sandbox_mode="read-only"' -- bash -c "echo x > '$probe'" >/dev/null 2>&1
  [ ! -e "$probe" ] && ok "codex read-only sandbox blocks writes inside the repo" || { bad "WRITE SUCCEEDED inside sandbox"; rm -f "$probe"; }
  codex sandbox -c 'sandbox_mode="read-only"' -- bash -c "echo x > '$T/outside-probe'" >/dev/null 2>&1
  [ ! -e "$T/outside-probe" ] && ok "codex read-only sandbox blocks writes outside the repo" || bad "WRITE SUCCEEDED outside repo"
  codex sandbox -c 'sandbox_mode="read-only"' -- bash -c "cat '$SRC/CLAUDE.md' >/dev/null" >/dev/null 2>&1
  check "sandbox still allows reads" 0 "$?"
  unset CODEX_BIN
  login_out="$(codex login status 2>&1)"
  if grep -qi 'not logged in' <<<"$login_out"; then
    cd "$R"; echo two > a.txt; state begin "real codex, no auth" >/dev/null
    SOL_TIMEOUT_SECS=20 "$S/sol-review.sh" --task t >/dev/null 2>&1; check "real codex without auth fails closed (exit 7)" 7 "$?"
  else
    echo "  skip real-model review (Codex is logged in; set up a deliberate live run manually)"
  fi
else
  echo "  skip: codex not installed (npm i -g @openai/codex)"
fi

echo; echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
