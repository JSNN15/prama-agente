#!/usr/bin/env bash
# prama-agent test suite — runs on an isolated tmux server, HOME and state dir.
# Each "regression" test maps to a finding from the v5 security/quality review.
# Licensed under the Apache License, Version 2.0
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_DIR/bin/prama-agent"
PASS_COUNT=0
FAIL_COUNT=0

pass() { printf ' \033[32m✔\033[0m %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf ' \033[31m✖\033[0m %s\n%s\n' "$1" "${2:+   $2}" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

assert_eq()           { [ "$2" = "$3" ] && pass "$1" || fail "$1" "expected [$2] got [$3]"; }
assert_contains()     { [[ "$3" == *"$2"* ]] && pass "$1" || fail "$1" "missing [$2] in: ${3:0:400}"; }
assert_not_contains() { [[ "$3" != *"$2"* ]] && pass "$1" || fail "$1" "unexpected [$2] in: ${3:0:400}"; }
assert_true()         { if eval "$2"; then pass "$1"; else fail "$1" "condition failed: $2"; fi; }

wait_for() { # wait_for <seconds> <condition>
  local t=$(( $1 * 10 )); shift
  while (( t-- > 0 )); do eval "$1" && return 0; sleep 0.1; done
  return 1
}

# ── Isolated environment ────────────────────────────────────────────────────
TMP_ROOT=$(mktemp -d)
export PRAMA_TMUX_SOCKET="prama-test-$$"
USER_SOCKET="user-test-$$"
cleanup() {
  tmux -L "$PRAMA_TMUX_SOCKET" kill-server 2>/dev/null
  tmux -L "$USER_SOCKET" kill-server 2>/dev/null
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/home/.config/prama-agent" "$TMP_ROOT/bin" "$TMP_ROOT/repos/alpha" "$TMP_ROOT/repos/beta" "$TMP_ROOT/plain"
gitc() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
git -C "$TMP_ROOT/repos/alpha" init -q -b main
git -C "$TMP_ROOT/repos/beta" init -q -b main
gitc "$TMP_ROOT/repos/alpha" commit -q --allow-empty -m base
echo "SECRET_TOKEN=12345" > "$TMP_ROOT/repos/alpha/.env"
printf '.env\n' > "$TMP_ROOT/repos/alpha/.gitignore"
gitc "$TMP_ROOT/repos/alpha" add .gitignore && gitc "$TMP_ROOT/repos/alpha" commit -q -m ignore

# Mock agents print their argv and selected env, then stay alive briefly.
# The interpreter is a copy of bash named like the agent, so the process "comm" looks like the
# real CLI (prama inspects the process tree to tell running agents from plain shells).
mkdir -p "$TMP_ROOT/interp" "$TMP_ROOT/ctl"
# Per-session mock behaviour (tmux does not forward the client's environment to new sessions):
#   mock_ctl <session> interactive        → the mock reads stdin until SIGTERM
#   mock_ctl <session> screen "<text>"    → the mock prints <text> after starting
#   mock_ctl <session> nohup              → the mock ignores SIGHUP
mock_ctl() {
  if [ "$2" = screen ]; then printf '%s\n' "$3" > "$TMP_ROOT/ctl/$1.screen"
  else : > "$TMP_ROOT/ctl/$1.$2"; fi
}
mock_ctl_clear() { rm -f "$TMP_ROOT/ctl/$1".*; }
for a in claude agy opencode; do
  cp "$(command -v bash)" "$TMP_ROOT/interp/$a"
  {
    printf '#!%s\n' "$TMP_ROOT/interp/$a"
    printf 'CTL=%q\n' "$TMP_ROOT/ctl/"
    cat <<'EOF'
CTL="$CTL${PRAMA_SESSION:-none}"
printf 'MOCK_AGENT %s ARGS:' "$(basename "$0")"; printf ' [%s]' "$@"; printf '\n'
echo "ENV role=${PRAMA_ROLE:-none} model=${ANTHROPIC_MODEL:-native} sandbox=${IS_SANDBOX:-0}"
[ -n "${OPENCODE_CONFIG_CONTENT:-}" ] && echo "OCCFG $OPENCODE_CONFIG_CONTENT key=${OPENROUTER_API_KEY:+set}"
[ -f "$CTL.screen" ] && cat "$CTL.screen"
[ -f "$CTL.nohup" ] && trap '' HUP   # like agy: survives losing its terminal
if [ -f "$CTL.interactive" ]; then
  # Behaves like an interactive CLI: echoes every line it receives until SIGTERM.
  trap 'echo MOCK_TERM; exit 143' TERM
  while IFS= read -r line; do echo "GOT: $line"; done
  exit 0
fi
sleep "${MOCK_SLEEP:-3}"
EOF
  } > "$TMP_ROOT/bin/$a"
  chmod +x "$TMP_ROOT/bin/$a"
done

cat > "$TMP_ROOT/home/.config/prama-agent/config.env" <<EOF
ZONES=(alpha beta plain)
ZONE_DIRS=("$TMP_ROOT/repos/alpha" "$TMP_ROOT/repos/beta" "$TMP_ROOT/plain")
ZONE_DESCS=("Alpha" "Beta" "Not a repo")
PRAMA_SESSION_PREFIX="tp"
EOF
cat > "$TMP_ROOT/home/.config/prama-agent/providers.env" <<EOF
DEEPSEEK_API_KEY="mock-deepseek-token-SECRET123"
OPENROUTER_API_KEY="mock-or-key"
EOF
printf '# my personal tmux config\nset -g status-left "MINE"\n' > "$TMP_ROOT/home/.tmux.conf"

export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$TMP_ROOT/home/.config"
export XDG_STATE_HOME="$TMP_ROOT/home/.local/state"
export PRAMA_SYSTEM_CONFIG_DIR="$TMP_ROOT/no-system-config"
export PATH="$TMP_ROOT/bin:$PATH"
export NO_COLOR=1
unset TMUX IS_SANDBOX PRAMA_STATE_HOME PRAMA_BUS_DIR PRAMA_TMUX_CONF PRAMA_SKIP_PERMISSIONS PRAMA_DEFAULT_REMOTE PRAMA_SESSION
export PRAMA_WATCHDOG=0   # enabled explicitly in the watchdog section
STATE="$XDG_STATE_HOME/prama-agent"
P="tmux -L $PRAMA_TMUX_SOCKET"

# ── Basics ──────────────────────────────────────────────────────────────────
section "CLI basics"
assert_eq "--version" "prama-agent v6.0.0" "$("$BIN" --version)"
out=$("$BIN" --help); assert_contains "--help lists subcommands" "bus status" "$out"
out=$("$BIN" zones --json); assert_true "zones --json is valid JSON" "jq -e 'length == 3' >/dev/null <<< '$out'"
out=$("$BIN" agents --json); assert_true "agents --json is valid JSON" "jq -e '.[0].installed' >/dev/null <<< '$out'"
out=$("$BIN" completion bash); assert_contains "bash completion script" "complete -F _prama_agent" "$out"

section "Permission flags (dry-run)"
out=$("$BIN" claude alpha --dry-run)
assert_not_contains "Default permission mode is ASK (no bypass flag)" "--dangerously-skip-permissions" "$out"
assert_not_contains "Remote control off by default" "--remote-control" "$out"
assert_contains "Dry-run targets the dedicated tmux server" "tmux -L $PRAMA_TMUX_SOCKET" "$out"
assert_contains "claude --yolo"   "--dangerously-skip-permissions" "$("$BIN" claude alpha --yolo --dry-run)"
assert_contains "agy --yolo"      "agy --dangerously-skip-permissions" "$("$BIN" agy alpha --yolo --dry-run)"
out=$("$BIN" agents --json)
assert_true "Enabled agents by default: claude and agy" "jq -e '[.[].name] == [\"claude\",\"agy\"]' >/dev/null <<< '$out'"
out=$("$BIN" opencode alpha --dry-run 2>&1); rc=$?
assert_true "opencode is experimental: off unless PRAMA_EXPERIMENTAL=1" "[ $rc -ne 0 ]"
export PRAMA_EXPERIMENTAL=1   # the rest of the suite also covers the experimental opencode integration
assert_contains "opencode --yolo (experimental)" "opencode --auto" "$("$BIN" opencode alpha --yolo --dry-run)"
out=$("$BIN" agents --json)
assert_true "PRAMA_EXPERIMENTAL=1 adds opencode" "jq -e '[.[].name] == [\"claude\",\"agy\",\"opencode\"]' >/dev/null <<< '$out'"
out=$("$BIN" claude alpha --role reader --yolo --dry-run 2>&1)
assert_contains "Reader forces plan on claude even with --yolo" "--permission-mode plan" "$out"
assert_not_contains "Reader never gets bypass flag" "--dangerously-skip-permissions" "$out"
assert_contains "Reader session name" "tp-reader-claude-alpha" "$out"
assert_contains "agy plan" "--mode plan" "$("$BIN" agy alpha --plan --dry-run)"
out=$("$BIN" claude alpha --model opus --effort high --dry-run)
assert_contains "claude --model / --effort" "--model opus --effort high" "$out"
assert_contains "claude gets prama's state hooks via --settings" "--settings" "$out"
assert_true "Hook settings file is valid JSON with StopFailure" "jq -e '.hooks.StopFailure[0].hooks[0].command | contains(\"--internal-hook\")' '$STATE/hooks/claude-settings.json' >/dev/null"
out=$("$BIN" claude alpha --model 'x;rm' --dry-run 2>&1); assert_contains "Rejects invalid model" "Modelo inválido" "$out"
assert_contains "claude --remote" "--remote-control tp-claude-alpha" "$("$BIN" claude alpha --remote --dry-run)"
assert_contains "Unique prefix resolves zone" "tp-claude-alpha" "$("$BIN" claude alp --dry-run)"
assert_contains "Pass-through args keep quoting" "analyze\\ all\\ logs" "$("$BIN" agy beta --dry-run -- -p "analyze all logs")"

section "Input validation"
out=$("$BIN" claude alpha --name 'x$(id)' 2>&1); rc=$?
assert_true "Rejects malicious --name" "[ $rc -ne 0 ]"
assert_contains "…with a clear message" "Nombre inválido" "$out"
out=$("$BIN" claude alpha --role boss 2>&1); assert_contains "Rejects unknown role" "--role debe ser" "$out"
out=$("$BIN" claude alpha --profile nope 2>&1); assert_contains "Rejects unknown profile" "Perfil desconocido" "$out"
out=$("$BIN" claude alpha --loop abc 2>&1); assert_contains "Rejects non-numeric --loop" "--loop requiere" "$out"

# ── Regressions from the v5 review ──────────────────────────────────────────
section "Regression: private state, no /tmp bus (#2)"
"$BIN" bus status >/dev/null 2>&1
assert_eq "State dir is 0700" "700" "$(stat -c %a "$STATE")"
assert_eq "Bus dir is 0700" "700" "$(stat -c %a "$STATE/bus")"
mkdir -p "$TMP_ROOT/evil"; chmod 777 "$TMP_ROOT/evil"; ln -s "$TMP_ROOT/evil" "$TMP_ROOT/link-state"
out=$(PRAMA_STATE_HOME="$TMP_ROOT/link-state" "$BIN" bus status 2>&1); rc=$?
assert_true "Refuses a symlinked state dir" "[ $rc -ne 0 ]"

section "Regression: no code execution via session names (#1)"
cd "$TMP_ROOT" || exit 1
$P new-session -d -s 'x$(touch PWNED)' 'sleep 30'
$P new-session -d -s 'y`touch PWNED2`' 'sleep 30'
"$BIN" bus status >/dev/null 2>&1; "$BIN" status >/dev/null 2>&1; "$BIN" sessions --json >/dev/null 2>&1
assert_true "bus status / status / sessions do not execute names" "[ ! -e '$TMP_ROOT/PWNED' ] && [ ! -e '$TMP_ROOT/PWNED2' ]"
assert_true "No state file is ever sourced (grep source in libs)" "! grep -nE '^[^#]*source \"\\\$f\"' '$REPO_DIR'/lib/*.sh"
$P kill-server 2>/dev/null
cd "$REPO_DIR" || exit 1

section "Regression: exact tmux targets (#8)"
"$BIN" claude alpha --bg --porcelain >/dev/null
out=$("$BIN" stop tp-claude 2>&1); rc=$?
assert_true "stop with a prefix does not kill tp-claude-alpha" "[ $rc -ne 0 ] && $P has-session -t '=tp-claude-alpha' 2>/dev/null"
"$BIN" stop tp-claude-alpha >/dev/null

section "Regression: prama never touches the user's tmux (#6 #10 #11 #12)"
tmux -L "$USER_SOCKET" new-session -d -s personal 'sleep 60'
"$BIN" claude alpha --bg --porcelain >/dev/null
"$BIN" doctor >/dev/null 2>&1
"$BIN" stop --all -y >/dev/null 2>&1
assert_true "stop --all keeps the user's own sessions alive" "tmux -L '$USER_SOCKET' has-session -t =personal 2>/dev/null"
assert_contains "User .tmux.conf untouched" 'status-left "MINE"' "$(cat "$HOME/.tmux.conf")"
assert_true "No ~/.tmux.conf.bak created" "[ ! -e '$HOME/.tmux.conf.bak' ]"
assert_true "Managed config lives in the state dir" "grep -q prama-agent-managed-v6 '$STATE/tmux.conf'"
assert_true "Menu key is not C-g (Claude Code uses it)" "! grep -q 'bind -n C-g' '$STATE/tmux.conf'"
out=$(printf '' | "$BIN" stop --all 2>&1); rc=$?
"$BIN" claude alpha --bg --porcelain >/dev/null
out=$("$BIN" stop --all </dev/null 2>&1); rc=$?
assert_true "stop --all without a TTY requires -y" "[ $rc -ne 0 ] && $P has-session -t '=tp-claude-alpha' 2>/dev/null"
"$BIN" stop --all -y >/dev/null 2>&1

section "Regression: worktrees (#7 #9 #13)"
gitc "$TMP_ROOT/repos/alpha" branch feat
gitc "$TMP_ROOT/repos/alpha" checkout -q feat
gitc "$TMP_ROOT/repos/alpha" commit -q --allow-empty -m "valuable work"
gitc "$TMP_ROOT/repos/alpha" checkout -q main
before=$(git -C "$TMP_ROOT/repos/alpha" rev-parse feat)
out=$("$BIN" worktree create alpha feat 2>&1)
assert_contains "Worktree created" "Worktree listo en:" "$out"
assert_eq "Existing branch is NOT reset (commit preserved)" "$before" "$(git -C "$TMP_ROOT/repos/alpha" rev-parse feat)"
assert_eq "Worktree lives outside the repo (repo stays clean)" "" "$(git -C "$TMP_ROOT/repos/alpha" status --porcelain)"
assert_eq ".env copied into worktree" "SECRET_TOKEN=12345" "$(cat "$TMP_ROOT/repos/.prama-worktrees/alpha/feat/.env")"
out=$("$BIN" worktree create alpha new-branch 2>&1)
assert_true "New branch created from HEAD" "git -C '$TMP_ROOT/repos/alpha' show-ref --quiet refs/heads/new-branch"
out=$("$BIN" claude plain -w feat --bg 2>&1); rc=$?
assert_true "Worktree on a non-git zone fails instead of launching anyway" "[ $rc -ne 0 ] && ! $P has-session -t '=tp-claude-plain-feat' 2>/dev/null"
out=$("$BIN" worktree remove alpha new-branch 2>&1)
assert_contains "Worktree removed, branch kept" "se conserva" "$out"

section "Regression: secrets never on a command line (#4)"
MOCK_SLEEP=6 "$BIN" claude alpha --bg --profile deepseek --name tp-secret >/dev/null
wait_for 5 "$P capture-pane -p -t '=tp-secret:' | grep -q 'ENV role'"
leak=$(ps -eo args | grep -c 'mock-deepseek-token-SECRE[T]' || true)
assert_eq "Provider token not visible in ps" "0" "$leak"
out=$($P capture-pane -p -t '=tp-secret:' -S -40)
assert_contains "Profile still applied inside the pane" "model=deepseek-chat" "$out"
assert_contains "ASK mode does not set IS_SANDBOX" "sandbox=0" "$out"
"$BIN" stop tp-secret >/dev/null

section "Queues (#14)"
# shellcheck source=/dev/null
qtest=$(bash -c '
  source "'"$REPO_DIR"'/lib/core.sh"; prama_init
  for i in $(seq 1 60); do queue_push qt "task $i"; done
  queue_push qt "multi
line"
  ( while t=$(queue_pop qt); do echo "A:$t"; done ) > "'"$TMP_ROOT"'/qa" &
  ( while t=$(queue_pop qt); do echo "B:$t"; done ) > "'"$TMP_ROOT"'/qb" &
  wait
  cat "'"$TMP_ROOT"'/qa" "'"$TMP_ROOT"'/qb" | sed "s/^[AB]://" | grep -c "^task " ')
assert_eq "60 tasks consumed exactly once by 2 concurrent consumers" "60" "$qtest"
assert_true "Multiline task preserved" "cat '$TMP_ROOT/qa' '$TMP_ROOT/qb' | grep -q '^line$'"

section "Bus"
out=$("$BIN" bus assign daemon "Run full test suite" 2>&1)
assert_contains "Assign to daemon queues the task" "daemon" "$out"
out=$("$BIN" bus report "All 20 tests passed" 2>&1)
assert_true "Report recorded" "grep -q 'All 20 tests passed' '$STATE/bus/events.jsonl'"
assert_true "events.jsonl lines are valid JSON" "jq -e . '$STATE/bus/events.jsonl' >/dev/null"
out=$(PRAMA_COLS=120 "$BIN" bus status 30 2>&1)
assert_contains "bus status shows events" "All 20 tests" "$out"
MOCK_SLEEP=8 "$BIN" claude alpha --bg --role coordinator --name tp-coord >/dev/null
MOCK_SLEEP=8 "$BIN" claude beta --bg --name tp-exec >/dev/null
$P new-session -d -s tp-usershell 'bash --norc -i'
wait_for 5 "$P capture-pane -p -t '=tp-coord:' | grep -q MOCK_AGENT"
"$BIN" bus assign tp-exec "implement /health" >/dev/null 2>&1
wait_for 3 "$P capture-pane -p -t '=tp-exec:' | grep -q 'implement /health'"
assert_contains "Assign to exact session injects text" "implement /health" "$($P capture-pane -p -t '=tp-exec:' -S -40)"
"$BIN" bus assign tp-ex "should not arrive" >/dev/null 2>&1
sleep 0.5
assert_not_contains "No fuzzy/prefix matching of targets" "should not arrive" "$($P capture-pane -p -t '=tp-exec:' -S -40)"
"$BIN" bus broadcast "hello agents" >/dev/null 2>&1
sleep 0.5
assert_not_contains "Broadcast never types into a plain shell" "hello agents" "$($P capture-pane -p -t '=tp-usershell:' -S -40)"
"$BIN" stop --all -y >/dev/null 2>&1; $P kill-session -t =tp-usershell 2>/dev/null

section "Stopping a session ends its agent"
mock_ctl tp-hup interactive; mock_ctl tp-hup nohup; "$BIN" agy alpha --bg --name tp-hup >/dev/null
wait_for 5 "$P capture-pane -p -t '=tp-hup:' | grep -q MOCK_AGENT"
hpid=$(pgrep -f "$TMP_ROOT/bin/agy" | head -n 1)
"$BIN" stop tp-hup >/dev/null 2>&1
assert_true "An agent that ignores SIGHUP does not survive 'stop'" "[ -n '$hpid' ] && wait_for 7 '! kill -0 $hpid 2>/dev/null'"

section "Supervised session E2E"
MOCK_SLEEP=2 "$BIN" claude alpha --bg --role coordinator --name tp-e2e --profile deepseek >/dev/null
wait_for 5 "$P capture-pane -p -t '=tp-e2e:' | grep -q 'ENV role'"
out=$("$BIN" capture tp-e2e 40)
assert_contains "Agent got role and profile env" "ENV role=coordinator model=deepseek-chat" "$out"
assert_contains "Coordinator received system prompt" "--append-system-prompt" "$out"
out=$("$BIN" sessions --json)
assert_true "sessions --json reports role" "jq -e '.[] | select(.name==\"tp-e2e\") | .role == \"coordinator\"' >/dev/null <<< '$out'"
wait_for 6 "$P capture-pane -p -t '=tp-e2e:' -S -40 | grep -q PRAMA_STANDBY"
assert_eq "Standby is detected after the agent exits" "STANDBY" "$(jq -r '.[] | select(.name=="tp-e2e") | .state' <<< "$("$BIN" sessions --json)")"
out=$("$BIN" stop tp-e2e); assert_contains "Stops session" "cerrada" "$out"
assert_true "State file removed on stop" "[ ! -e '$STATE/bus/state/tp-e2e.env' ]"

section "Daemon (#17)"
MOCK_SLEEP=0 "$BIN" bus assign tp-daemon-1 "first queued task" >/dev/null 2>&1
MOCK_SLEEP=0 "$BIN" claude alpha --role daemon --plan --oneshot --name tp-daemon-1 --bg -- --model opus >/dev/null
wait_for 8 "grep -q 'completed' '$STATE/bus/events.jsonl' && grep -q tp-daemon-1 '$STATE/bus/events.jsonl'"
out=$($P capture-pane -p -t '=tp-daemon-1:' -S -60 2>/dev/null || true)
[ -z "$out" ] && out=$(grep tp-daemon-1 "$STATE/bus/events.jsonl")
assert_true "Daemon consumed its queued task" "grep -q 'first queued task' '$STATE/bus/events.jsonl'"
"$BIN" stop --all -y >/dev/null 2>&1

section "Agent health: hooks and screen detection"
mock_ctl tp-h1 interactive; "$BIN" claude alpha --bg --yolo --name tp-h1 >/dev/null
wait_for 5 "$P capture-pane -p -t '=tp-h1:' | grep -q MOCK_AGENT"
assert_contains "claude launched with a deterministic --session-id" "[--session-id]" "$("$BIN" capture tp-h1 30)"
st() { jq -r --arg s "$1" '.[] | select(.session==$s) | '"$2" <<< "$("$BIN" fleet status --json)"; }
assert_eq "Healthy interactive agent is READY" "READY" "$(st tp-h1 .state)"
printf '{"hook_event_name":"StopFailure","session_id":"abc","error":"rate_limit","error_details":"429 Too Many Requests"}' \
  | PRAMA_SESSION=tp-h1 "$BIN" --internal-hook claude
assert_eq "StopFailure hook → BLOCKED" "BLOCKED" "$(st tp-h1 .state)"
assert_eq "…with reason 'limit'" "limit" "$(st tp-h1 .blocked_reason)"
"$BIN" bus assign tp-h1 "task while blocked" >/dev/null 2>&1
sleep 0.5
assert_not_contains "Never types into a blocked agent" "task while blocked" "$("$BIN" capture tp-h1 30)"
assert_eq "…the task is queued instead" "1" "$(st tp-h1 .queue)"
printf '{"hook_event_name":"UserPromptSubmit","session_id":"abc"}' | PRAMA_SESSION=tp-h1 "$BIN" --internal-hook claude
assert_eq "Next prompt clears the block" "READY" "$(st tp-h1 .state)"
printf '{"hook_event_name":"SessionStart","session_id":"sid-2","model":"claude-sonnet-x"}' | PRAMA_SESSION=tp-h1 "$BIN" --internal-hook claude
assert_eq "SessionStart hook reports the model" "claude-sonnet-x" "$(st tp-h1 .model)"
out=$(printf 'not json' | PRAMA_SESSION='bad;name' "$BIN" --internal-hook claude; echo "rc=$?")
assert_eq "Hook never fails or prints, even with garbage" "rc=0" "$out"
mock_ctl tp-h2 interactive; mock_ctl tp-h2 screen "Invalid API key · Please run /login"; "$BIN" agy alpha --bg --name tp-h2 >/dev/null
wait_for 5 "$P capture-pane -p -t '=tp-h2:' | grep -q 'Invalid API key'"
assert_eq "Login screen → BLOCKED" "BLOCKED" "$(st tp-h2 .state)"
assert_eq "…reason 'login'" "login" "$(st tp-h2 .blocked_reason)"
mock_ctl tp-h3 interactive; mock_ctl tp-h3 screen "Do you trust the files in this folder?"; "$BIN" claude beta --bg --name tp-h3 >/dev/null
wait_for 5 "$P capture-pane -p -t '=tp-h3:' | grep -q 'trust'"
assert_eq "Trust dialog → BLOCKED (trust)" "trust" "$(st tp-h3 .blocked_reason)"
"$BIN" stop --all -y >/dev/null 2>&1

section "Fleet: spawn, model change in place, guard rails"
out=$("$BIN" fleet spawn opencode alpha --model openrouter/z-ai/glm-4.6 --yolo --name tp-oc --json 2>&1)
assert_true "fleet spawn --json" "jq -e '.session == \"tp-oc\"' >/dev/null <<< '$out'"
wait_for 5 "$P capture-pane -p -t '=tp-oc:' | grep -q OCCFG"
out=$("$BIN" capture tp-oc 30)
assert_contains "opencode gets its model through OPENCODE_CONFIG_CONTENT" '"model":"openrouter/z-ai/glm-4.6"' "$out"
assert_contains "…YOLO as permission allow" '"permission":"allow"' "$out"
assert_contains "…OpenRouter key exported inside the pane" "key=set" "$out"
"$BIN" stop tp-oc >/dev/null
mock_ctl tp-co interactive; "$BIN" claude alpha --bg --yolo --role coordinator --name tp-co >/dev/null
mock_ctl tp-ex1 interactive; "$BIN" fleet spawn claude alpha --model sonnet --name tp-ex1 >/dev/null 2>&1
wait_for 5 "$P capture-pane -p -t '=tp-ex1:' | grep -q MOCK_AGENT"
assert_eq "Spawned agent records its parent" "operator" "$(st tp-ex1 .parent)"
out=$(PRAMA_SESSION=tp-co "$BIN" fleet model tp-ex1 opus 2>&1)
assert_contains "Coordinator changes an executor's model" "opus" "$out"
wait_for 8 "$P capture-pane -p -t '=tp-ex1:' -S -80 | grep -q -- '\[--model\] \[opus\]'"
out=$($P capture-pane -p -t '=tp-ex1:' -S -80)
assert_contains "Agent relaunched with the new model" "[--model] [opus]" "$out"
assert_contains "…resuming the same conversation" "[--resume]" "$out"
assert_contains "…in the same pane (scrollback kept)" "[--model] [sonnet]" "$out"
assert_eq "Model saved in the fleet state" "opus" "$(st tp-ex1 .model)"
out=$(PRAMA_SESSION=tp-ex1 "$BIN" fleet kill tp-co 2>&1); rc=$?
assert_true "An agent cannot kill a coordinator" "[ $rc -ne 0 ] && $P has-session -t =tp-co"
out=$(PRAMA_SESSION=tp-co "$BIN" fleet kill tp-co 2>&1); rc=$?
assert_true "An agent cannot act on itself" "[ $rc -ne 0 ]"
mock_ctl tp-other interactive; "$BIN" claude beta --bg --name tp-other >/dev/null
out=$(PRAMA_SESSION=tp-co "$BIN" fleet restart tp-other 2>&1); rc=$?
assert_true "Zone scope: cannot touch agents of another zone" "[ $rc -ne 0 ]"
assert_contains "…with a clear reason" "fuera de tu zona" "$out"
out=$(PRAMA_FLEET_MAX=3 "$BIN" fleet spawn claude alpha 2>&1); rc=$?
assert_true "spawn respects PRAMA_FLEET_MAX" "[ $rc -ne 0 ]"
assert_contains "…and explains it" "Límite de la flota" "$out"
out=$(PRAMA_SESSION=tp-co "$BIN" fleet kill tp-ex1 2>&1)
assert_true "Coordinator kills an extra agent of its zone" "! $P has-session -t =tp-ex1 2>/dev/null"
"$BIN" stop --all -y >/dev/null 2>&1

section "Watchdog: alerts and queued delivery"
mock_ctl tp-wco interactive; "$BIN" claude alpha --bg --role coordinator --name tp-wco >/dev/null
mock_ctl tp-wex interactive; mock_ctl tp-wex screen "Credit balance is too low"; "$BIN" agy alpha --bg --name tp-wex >/dev/null
mock_ctl tp-wq interactive; "$BIN" claude alpha --bg --name tp-wq >/dev/null
"$BIN" bus assign tp-wq "queued for later" >/dev/null 2>&1   # may inject or queue
"$BIN" bus assign tp-wex "work for the blocked one" >/dev/null 2>&1
out=$("$BIN" fleet watchdog tick)
assert_contains "Watchdog pass detects the blocked agent" "tp-wex bloqueado (credit)" "$out"
wait_for 5 "$P capture-pane -p -t '=tp-wco:' -S -80 | grep -q 'ALERTA PRAMA'"
out=$($P capture-pane -p -t '=tp-wco:' -S -80 | tr -d '\n')
assert_contains "Coordinator is alerted about the blocked executor" "tp-wex" "$out"
assert_contains "…with the reason" "credit" "$out"
assert_true "Blocked event in the bus log" "grep -q '\"event\":\"blocked\"' '$STATE/bus/events.jsonl'"
assert_eq "Task for the blocked agent stays queued" "1" "$(st tp-wex .queue)"
mock_ctl_clear tp-wex; mock_ctl tp-wex interactive
$P send-keys -t '=tp-wex:' C-l 2>/dev/null; $P clear-history -t '=tp-wex:' 2>/dev/null
"$BIN" fleet restart tp-wex >/dev/null 2>&1
"$BIN" stop --all -y >/dev/null 2>&1
PRAMA_WATCHDOG=1 "$BIN" claude alpha --bg --name tp-wd >/dev/null 2>&1
assert_true "Launching an agent starts the watchdog session" "wait_for 3 '$P has-session -t =tp-watchdog 2>/dev/null'"
assert_not_contains "The watchdog is internal (not listed as an agent)" "tp-watchdog" "$("$BIN" fleet status --json)"
"$BIN" stop --all -y >/dev/null 2>&1
"$BIN" fleet watchdog stop >/dev/null 2>&1

section "agy hooks and quota telemetry"
mkdir -p "$HOME/.gemini/config"
printf '{"mine":{"Stop":[{"command":"true"}]}}\n' > "$HOME/.gemini/config/hooks.json"
mock_ctl tp-ag interactive; "$BIN" agy alpha --bg --yolo --name tp-ag >/dev/null
wait_for 5 "$P capture-pane -p -t '=tp-ag:' | grep -q MOCK_AGENT"
hj=$(cat "$HOME/.gemini/config/hooks.json")
assert_true "agy launch installs prama's named hook" "jq -e '.\"prama-agent\".Stop[0].command | test(\"--internal-hook agy Stop\")' >/dev/null <<< '$hj'"
assert_true "…keeping the user's own hooks" "jq -e '.mine.Stop' >/dev/null <<< '$hj'"
assert_contains "agy gets the quota status line (session-only --settings)" "--internal-statusline agy" "$("$BIN" capture tp-ag 30)"
assert_eq "agy hook outside prama panes only answers {}" "{}" "$(printf '{}' | env -u PRAMA_SESSION "$BIN" --internal-hook agy Stop)"
out=$(printf '{"conversationId":"conv-9","modelName":"gemini-3.8-flash-high"}' | PRAMA_SESSION=tp-ag "$BIN" --internal-hook agy PreInvocation)
assert_eq "agy hook answers {} inside prama too" "{}" "$out"
printf '{"conversationId":"conv-9","terminationReason":"ERROR","error":"Your AI credits balance is too low to continue."}' \
  | PRAMA_SESSION=tp-ag "$BIN" --internal-hook agy Stop >/dev/null
assert_eq "agy Stop with ERROR → BLOCKED" "BLOCKED" "$(st tp-ag .state)"
assert_eq "…reason classified from the error text (credit)" "credit" "$(st tp-ag .blocked_reason)"
printf '{"conversationId":"conv-9","terminationReason":"NO_TOOL_CALL"}' | PRAMA_SESSION=tp-ag "$BIN" --internal-hook agy Stop >/dev/null
assert_eq "agy normal Stop → READY" "READY" "$(st tp-ag .state)"
"$BIN" fleet restart tp-ag >/dev/null 2>&1
wait_for 8 "$P capture-pane -p -t '=tp-ag:' -S -80 | grep -q -- '\[--conversation\] \[conv-9\]'"
assert_contains "agy restarts resume its conversation (id from hooks)" "[--conversation] [conv-9]" "$($P capture-pane -p -t '=tp-ag:' -S -80)"
CL='{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"context_window":{"used_percentage":23},"cost":{"total_cost_usd":1.234},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1999999999},"seven_day":{"used_percentage":7,"resets_at":1999999999}}}'
mock_ctl tp-qc interactive; "$BIN" claude alpha --bg --role coordinator --name tp-qc >/dev/null
out=$(PRAMA_SESSION=tp-qc "$BIN" --internal-statusline claude <<< "$CL")
assert_contains "Claude status line shows quota" "5h 42% · 7d 7% · ctx 23%" "$out"
assert_eq "fleet status --json exposes quota" "42" "$(st tp-qc .quota.five_hour_pct)"
assert_eq "…and cost" "1.23" "$(st tp-qc .quota.cost_usd)"
AG='{"model":{"id":"Gemini 3.8 Flash (High)"},"quota":{"gemini-5h":{"remaining_fraction":0.75,"reset_in_seconds":100},"gemini-weekly":{"remaining_fraction":0.9,"reset_in_seconds":100},"gemini-argon-wtu-weekly":{"remaining_fraction":0.01,"reset_in_seconds":100},"3p-weekly":{"remaining_fraction":0.2,"reset_in_seconds":100}}}'
PRAMA_SESSION=tp-ag PRAMA_SL_CACHE='' "$BIN" --internal-statusline agy <<< "$AG" >/dev/null
assert_eq "agy quota: 5h bucket of the model family" "25" "$(st tp-ag .quota.five_hour_pct)"
assert_eq "…weekly ignores other models' buckets (argon, 3p)" "10" "$(st tp-ag .quota.seven_day_pct)"
PRAMA_SESSION=tp-ag PRAMA_SL_CACHE='' "$BIN" --internal-statusline agy <<< "${AG/Gemini 3.8 Flash/Gemini 4 Argon}" >/dev/null
assert_eq "…but counts the model's own bucket" "99" "$(st tp-ag .quota.seven_day_pct)"
mock_ctl tp-qx interactive; "$BIN" claude alpha --bg --name tp-qx >/dev/null
PRAMA_SESSION=tp-qx "$BIN" --internal-statusline claude <<< "${CL/\"used_percentage\":42/\"used_percentage\":95}" >/dev/null
out=$("$BIN" fleet watchdog tick)
assert_contains "Watchdog warns when an account passes PRAMA_QUOTA_WARN" "cuota claude 5h al 95%" "$out"
wait_for 5 "$P capture-pane -p -t '=tp-qc:' -S -80 | grep -q 'Cuota de claude'"
assert_contains "…the coordinator gets the alert" "Cuota de claude al 95%" "$($P capture-pane -p -t '=tp-qc:' -S -80 | tr -d '\n')"
"$BIN" fleet hooks uninstall >/dev/null
hj=$(cat "$HOME/.gemini/config/hooks.json")
assert_true "fleet hooks uninstall removes only prama's entry" "jq -e 'has(\"prama-agent\") | not' >/dev/null <<< '$hj' && jq -e '.mine' >/dev/null <<< '$hj'"
"$BIN" stop --all -y >/dev/null 2>&1

section "Presets"
mkdir -p "$XDG_CONFIG_HOME/prama-agent/presets/skills/db-migrations"
printf -- '---\nname: db-migrations\ndescription: test\n---\nbody\n' > "$XDG_CONFIG_HOME/prama-agent/presets/skills/db-migrations/SKILL.md"
cat > "$XDG_CONFIG_HOME/prama-agent/presets/reviewer.env" <<'EOP'
DESCRIPTION="Revisor estricto"
AGENT=claude
MODEL=haiku
EFFORT=high
SKILLS_DIR=skills
PROMPT="Revisa cada cambio con lupa."
EOP
out=$("$BIN" alpha --preset reviewer --dry-run 2>&1)
assert_contains "Preset picks the agent" "tp-claude-alpha" "$out"
assert_contains "Preset model and effort" "--model haiku --effort high" "$out"
assert_contains "Preset skills loaded as a plugin dir" "--plugin-dir" "$out"
assert_true "Generated plugin wraps the skills" "[ -f '$STATE/plugins/preset-reviewer/skills/db-migrations/SKILL.md' ]"
assert_contains "Preset prompt appended" "Revisa cada cambio" "$out"
assert_contains "fleet presets lists it" "reviewer" "$("$BIN" fleet presets)"
out=$("$BIN" claude alpha --preset nope --dry-run 2>&1); assert_contains "Unknown preset rejected" "Preset desconocido" "$out"

section "UI engine"
out=$(bash -c 'source "'"$REPO_DIR"'/lib/core.sh"; source "'"$REPO_DIR"'/lib/ui.sh"; str_width "ab"; echo; str_width "🤝 ab"; echo; str_width "✦ x"')
assert_eq "Display width counts emoji as 2 columns" $'2\n5\n3' "$out"
out=$(bash -c 'source "'"$REPO_DIR"'/lib/core.sh"; source "'"$REPO_DIR"'/lib/ui.sh"; W=30; IS_COMPACT=1; box_top "🤝 título largo de prueba" "x"; box_row "" "📱 hola"; box_bottom "fin"')
widths=$(while IFS= read -r l; do bash -c 'source "'"$REPO_DIR"'/lib/ui.sh"; str_width "$1"' _ "$l"; echo; done <<< "$out" | sort -u)
assert_eq "Box lines are all the same display width" "31" "$widths"

section "Hygiene"
if grep -rIiE "BEGIN (RSA |OPENSSH )?PRIVATE KEY|ghp_[A-Za-z0-9]{20}|sk-[a]nt-[A-Za-z0-9]{10}" "$REPO_DIR/bin" "$REPO_DIR/lib" "$REPO_DIR/config" "$REPO_DIR/README.md" >/dev/null 2>&1; then
  fail "No hardcoded credentials in the repository"
else
  pass "No hardcoded credentials in the repository"
fi
assert_true "No bare 'tmux -t' targets in libs (must use tmx/exact)" "! grep -nE '(^|[^-])tmux [a-z-]+ .*-t \"?\\\$[a-z_]+\"?( |$)' '$REPO_DIR'/lib/*.sh '$REPO_DIR'/bin/prama-agent | grep -v 'tmux -L'"
assert_true "No references to /tmp/prama-bus outside migration" "[ \$(grep -rl '/tmp/prama-bus' '$REPO_DIR/lib' '$REPO_DIR/bin' | grep -cv 'bin/prama-agent') -eq 0 ]"

printf '\n\033[1mResultado: %d ok, %d fallidos\033[0m\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
