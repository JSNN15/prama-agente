#!/usr/bin/env bash
# prama-agent test suite — runs on an isolated tmux server, HOME and state dir.
# Each "regression" test maps to a finding from the v5 security/quality review.
# Copyright 2026 Julian Neira Nova
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
# The assertions below check the Spanish interface; the English one has its own section.
export PRAMA_LANG=es
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
export LC_ALL=C.UTF-8     # what bin/prama-agent forces; the UI tests also source the libs directly
unset TMUX IS_SANDBOX PRAMA_STATE_HOME PRAMA_BUS_DIR PRAMA_TMUX_CONF PRAMA_SKIP_PERMISSIONS PRAMA_DEFAULT_REMOTE PRAMA_SESSION
export PRAMA_WATCHDOG=0   # enabled explicitly in the watchdog section
STATE="$XDG_STATE_HOME/prama-agent"
P="tmux -L $PRAMA_TMUX_SOCKET"

# ── Basics ──────────────────────────────────────────────────────────────────
section "CLI basics"
assert_eq "--version" "prama-agent v$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$BIN")" "$("$BIN" --version)"
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
wait_for 6 "$P capture-pane -p -t '=tp-exec:' | grep -q 'implement /health'"
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
out=$("$BIN" capture tp-e2e 200)
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
# Regression (found live): the watchdog's alert about another agent's 429, wrapped by the CLI in a
# narrow cockpit pane, made the coordinator itself look blocked, so its queue stopped draining.
quoted=$'⏺ Reviso el equipo.\n──────────────────────────────────\n❯ [ALERTA PRAMA] \'tp-x\'\nestá BLOQUEADO (limit): generating\nand executing: RESOURCE_EXHAUSTED\n(code 429): Individual quota\n──────────────────────────────────'
out=$(bash -c 'source "'"$REPO_DIR"'/lib/core.sh"; screen_block_reason "$1" || echo none' _ "$quoted")
assert_eq "A quoted alert wrapped over several lines is not a block" "none" "$out"
out=$(bash -c 'source "'"$REPO_DIR"'/lib/core.sh"; screen_block_reason "$1" || echo none' _ $'⏺ Done.\nError: RESOURCE_EXHAUSTED (code 429): Individual quota reached')
assert_contains "…while the agent's own 429 output still is" "limit|" "$out"
mock_ctl tp-h4 interactive; mock_ctl tp-h4 screen "Error: RESOURCE_EXHAUSTED (code 429) seen in a log"; "$BIN" claude beta --bg --name tp-h4 >/dev/null
wait_for 5 "$P capture-pane -p -t '=tp-h4:' | grep -q 'RESOURCE_EXHAUSTED'"
printf '{"hook_event_name":"Stop","session_id":"h4"}' | PRAMA_SESSION=tp-h4 "$BIN" --internal-hook claude
assert_eq "Healthy hooks win over quota text on screen" "READY" "$(st tp-h4 .state)"
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

section "Teams, cockpit and navigation"
out=$("$BIN" swarm alpha --workers agy:2 --task "ship /health" --no-open 2>&1)
co=$("$BIN" fleet status --json | jq -r '.[] | select(.role=="coordinator" and .zone=="alpha") | .session')
assert_eq "swarm launches one coordinator" "1" "$(grep -c . <<< "$co")"
assert_eq "…and the requested workers, as its team" "2" "$("$BIN" fleet status --json | jq --arg c "$co" '[.[] | select(.parent==$c)] | length')"
assert_contains "The coordinator gets its team brief (queued until ready)" "Tu equipo «principal» en 'alpha'" "$("$BIN" bus inbox "$co" 2>&1)"
assert_true "…with the objective" "grep -q 'objetivo: ship /health' '$STATE/bus/events.jsonl'"
assert_contains "fleet status shows the team as a tree" "└" "$("$BIN" fleet status)"
"$BIN" cockpit alpha --no-attach >/dev/null 2>&1
assert_eq "Cockpit: one pane per team member plus the bus" "4" "$($P list-panes -t '=tp-cockpit-alpha' 2>/dev/null | grep -c .)"
PRAMA_SESSION=$co "$BIN" swarm alpha --workers agy:1 >/dev/null 2>&1
assert_eq "A coordinator can grow its own team" "3" "$("$BIN" fleet status --json | jq --arg c "$co" '[.[] | select(.parent==$c)] | length')"
"$BIN" cockpit alpha --no-attach >/dev/null 2>&1
assert_eq "…and the cockpit follows the team" "5" "$($P list-panes -t '=tp-cockpit-alpha' 2>/dev/null | grep -c .)"
# A phone: a real tmux client 60 columns wide, attached to the cockpit from another server.
# The compact layout needs tmux ≥ 3.3 (status ranges, #{hook_client}); 3.2 keeps the split view.
tmux_33() { [[ "$(tmux -V)" =~ ([0-9]+)\.([0-9]+) ]] && (( BASH_REMATCH[1] > 3 || (BASH_REMATCH[1] == 3 && BASH_REMATCH[2] >= 3) )); }
if tmux_33; then
zoomed() { $P display-message -p -t '=tp-cockpit-alpha:' '#{window_zoomed_flag}' 2>/dev/null; }
tmux -L "$USER_SOCKET" new-session -d -s phone -x 60 -y 30 "env -u TMUX tmux -L $PRAMA_TMUX_SOCKET attach-session -t =tp-cockpit-alpha"
assert_true "Cockpit on a phone-width client: one agent at a time (zoomed by the attach hook)" "wait_for 8 '[ \"\$(zoomed)\" = 1 ]'"
phone=$($P list-clients -t '=tp-cockpit-alpha' -F '#{client_name}' 2>/dev/null | head -n 1)
pane1=$($P display-message -p -t '=tp-cockpit-alpha:' '#{pane_id}')
"$BIN" --internal-nav click "$phone" tp-cockpit-alpha next >/dev/null 2>&1
assert_true "◀ ▶ page through the team inside the cockpit" "[ \"\$($P display-message -p -t '=tp-cockpit-alpha:' '#{pane_id}')\" != '$pane1' ]"
assert_eq "…and the pane stays zoomed" "1" "$(zoomed)"
tmux -L "$USER_SOCKET" resize-window -t '=phone:' -x 160 -y 40 2>/dev/null
assert_true "A wide client gets the split view back (resize hook)" "wait_for 8 '[ \"\$(zoomed)\" = 0 ]'"
$P resize-pane -Z -t '=tp-cockpit-alpha:' 2>/dev/null
"$BIN" --internal-nav fit "$phone" tp-cockpit-alpha >/dev/null 2>&1
assert_eq "…but a zoom chosen by the operator is left alone" "1" "$(zoomed)"
tmux -L "$USER_SOCKET" kill-session -t '=phone' 2>/dev/null
assert_contains "Compact status bar: previous / next buttons for phones" "range=user|next" "$(cat "$STATE/tmux.conf")"
else
assert_not_contains "tmux 3.2: no compact hooks (no #{hook_client} to rely on)" "client-resized" "$(cat "$STATE/tmux.conf")"
fi
out=$(PRAMA_SESSION=$co "$BIN" swarm beta --workers agy:1 2>&1); rc=$?
assert_true "An agent cannot build a team outside its zone" "[ $rc -ne 0 ]"
assert_contains "Navigation keys are bound on prama's tmux server" "--internal-nav pick" "$(cat "$STATE/tmux.conf")"
assert_contains "…and the cockpit toggle" "--internal-nav cockpit" "$(cat "$STATE/tmux.conf")"
# Several teams in one zone (architecture, security, docs…), each with its own coordinator.
out=$("$BIN" swarm alpha --workers agy:1 --no-open 2>&1); rc=$?
assert_true "A second team needs a name: never joins the first one silently" "[ $rc -ne 0 ]"
assert_contains "…and the message says how" "--team" "$out"
"$BIN" swarm alpha --team seguridad --workers agy:1 --task "audit auth" --no-open >/dev/null 2>&1
sec=$("$BIN" teams --json | jq -r '.[] | select(.team=="seguridad") | .coordinator')
assert_eq "A named team gets its own coordinator" "tp-alpha-seguridad-coord" "$sec"
assert_eq "…and its own workers" "tp-alpha-seguridad-agy" "$("$BIN" teams --json | jq -r '.[] | select(.team=="seguridad") | .members[0]')"
assert_eq "teams lists both teams of the zone" "2" "$("$BIN" teams --json | jq 'length')"
assert_eq "…the first one is the zone's principal team" "$co" "$("$BIN" teams --json | jq -r '.[] | select(.team=="principal") | .coordinator')"
assert_eq "The objective is kept on the coordinator" "audit auth" "$("$BIN" teams --json | jq -r '.[] | select(.team=="seguridad") | .objective')"
out=$("$BIN" cockpit alpha --no-attach 2>&1); rc=$?
assert_true "cockpit <zone> asks which team when there are several" "[ $rc -ne 0 ] && [[ \"\$out\" == *seguridad* ]]"
"$BIN" cockpit alpha --team seguridad --no-attach >/dev/null 2>&1
assert_eq "A team's cockpit shows only that team (+ bus)" "3" "$($P list-panes -t '=tp-cockpit-alpha-seguridad' 2>/dev/null | grep -c .)"
PRAMA_SESSION=tp-alpha-seguridad-agy "$BIN" bus report "seguridad: 0 findings" >/dev/null 2>&1
assert_eq "A worker's report goes to its own coordinator" "$sec" "$(jq -r 'select(.event=="report") | .to' "$STATE/bus/events.jsonl" | tail -n 1)"
PRAMA_SESSION=$co "$BIN" bus assign executor "principal task" >/dev/null 2>&1
dest=$(jq -r 'select(.text=="principal task") | .to' "$STATE/bus/events.jsonl" | tail -n 1)
assert_eq "bus assign <role> from a coordinator picks one of its own agents" "$co" "$(jq -r --arg d "$dest" '.[] | select(.session==$d) | .parent' <<< "$("$BIN" fleet status --json)")"
out=$(PRAMA_SESSION=$co "$BIN" fleet kill tp-alpha-seguridad-agy 2>&1); rc=$?
assert_true "A coordinator cannot manage another team's agents" "[ $rc -ne 0 ] && [[ \"\$out\" == *otro\ equipo* ]]"
out=$(PRAMA_SESSION=$co "$BIN" swarm alpha --team seguridad --workers agy:1 2>&1); rc=$?
assert_true "…nor grow another team" "[ $rc -ne 0 ]"
out=$("$BIN" swarm stop alpha 2>&1); rc=$?
assert_true "swarm stop <zone> asks which team when there are several" "[ $rc -ne 0 ] && [[ \"\$out\" == *--team* ]]"
"$BIN" swarm stop alpha --team seguridad >/dev/null 2>&1
assert_true "swarm stop --team closes only that team" "! $P has-session -t =tp-alpha-seguridad-coord 2>/dev/null && $P has-session -t '=$co' 2>/dev/null"
assert_true "…and its cockpit" "! $P has-session -t =tp-cockpit-alpha-seguridad 2>/dev/null"
"$BIN" swarm stop alpha >/dev/null 2>&1
assert_eq "swarm stop closes the coordinator and its team" "0" "$("$BIN" fleet status --json | jq '[.[] | select(.zone=="alpha")] | length')"
assert_true "…and its cockpit" "! $P has-session -t =tp-cockpit-alpha 2>/dev/null"
"$BIN" bus swarm-start beta claude agy >/dev/null 2>&1
assert_eq "v5 'bus swarm-start' still works (coordinator + 1 executor)" "2" "$("$BIN" fleet status --json | jq '[.[] | select(.zone=="beta")] | length')"
"$BIN" stop --all -y >/dev/null 2>&1

section "Isolated teams: a git worktree per executor"
ISO="$TMP_ROOT/repos/iso"; mkdir -p "$ISO"; git -C "$ISO" init -q -b main
echo base > "$ISO/app.txt"; gitc "$ISO" add app.txt; gitc "$ISO" commit -qm init
"$BIN" zones add iso "$ISO" >/dev/null 2>&1
out=$("$BIN" swarm iso --team t --workers claude:1,agy:1 --no-open 2>&1)
assert_contains "A new team in a git zone is isolated" "prama/t/claude" "$out"
assert_true "…each executor in its own worktree" "git -C '$ISO' worktree list | grep -q 'prama/t/agy'"
assert_true "…outside the repository" "grep -q '^TARGET_DIR=.*/repos/.prama-worktrees/iso/prama-t-claude' '$STATE/bus/state/tp-iso-t-claude.env'"
wait_for 5 "$P capture-pane -p -J -t '=tp-iso-t-claude:' -S -200 | grep -q 'prama/t/claude'"
assert_true "The executor's prompt names its branch" "$P capture-pane -p -J -t '=tp-iso-t-claude:' -S -200 | grep -q \"rama 'prama/t/claude'\""
WT="$TMP_ROOT/repos/.prama-worktrees/iso"
echo one > "$WT/prama-t-claude/app.txt"; gitc "$WT/prama-t-claude" commit -qam "claude: change"
out=$("$BIN" worktree status iso --json)
assert_true "worktree status --json: commits to merge" "jq -e '.[] | select(.session==\"tp-iso-t-claude\") | .ahead == 1' >/dev/null <<< '$out'"
out=$(PRAMA_SESSION=tp-iso-t-agy "$BIN" worktree merge tp-iso-t-claude 2>&1); rc=$?
assert_true "An executor cannot merge into the base" "[ $rc -ne 0 ]"
out=$(PRAMA_SESSION=tp-iso-t-coord "$BIN" worktree merge tp-iso-t-claude --test false 2>&1); rc=$?
assert_true "merge --test undoes a merge that breaks the tests" "[ $rc -ne 0 ] && [ \"\$(cat '$ISO/app.txt')\" = base ]"
out=$(PRAMA_SESSION=tp-iso-t-coord "$BIN" worktree merge tp-iso-t-claude --test true 2>&1); rc=$?
assert_true "The coordinator merges a branch" "[ $rc -eq 0 ] && [ \"\$(cat '$ISO/app.txt')\" = one ]"
echo two > "$WT/prama-t-agy/app.txt"; gitc "$WT/prama-t-agy" commit -qam "agy: conflicting change"
out=$(PRAMA_SESSION=tp-iso-t-coord "$BIN" worktree merge tp-iso-t-agy 2>&1); rc=$?
assert_true "A conflicting merge is aborted" "[ $rc -ne 0 ] && [[ \"\$out\" == *app.txt* ]]"
assert_eq "…and the base stays clean" "" "$(git -C "$ISO" status --porcelain --untracked-files=no)"
out=$(PRAMA_SESSION=tp-iso-t-agy "$BIN" worktree sync 2>&1); rc=$?
assert_true "The executor syncs itself and gets the conflict to resolve" "[ $rc -ne 0 ] && git -C '$WT/prama-t-agy' diff --name-only --diff-filter=U | grep -q app.txt"
gitc "$WT/prama-t-agy" merge --abort
out=$(PRAMA_SESSION=tp-iso-t-agy "$BIN" swarm stop tp-iso-t-coord 2>&1); rc=$?
assert_true "An executor cannot close the team" "[ $rc -ne 0 ]"
out=$(PRAMA_SESSION=tp-iso-t-coord "$BIN" swarm stop alpha --all 2>&1); rc=$?
assert_true "A coordinator cannot close another team" "[ $rc -ne 0 ]"
"$BIN" swarm stop iso --team t >/dev/null 2>&1
assert_true "swarm stop removes merged worktrees" "! git -C '$ISO' worktree list | grep -q 'prama/t/claude'"
assert_true "…and keeps unmerged work" "git -C '$ISO' worktree list | grep -q 'prama/t/agy'"
out=$("$BIN" swarm iso --team s --shared --workers agy:1 --no-open 2>&1)
assert_not_contains "--shared: no worktrees" "prama/s/" "$out"
"$BIN" swarm stop iso --team s >/dev/null 2>&1
"$BIN" zones remove iso >/dev/null 2>&1

section "Team plan: tasks, board, timeline, honesty checks"
PL="$TMP_ROOT/repos/pl"; mkdir -p "$PL"; git -C "$PL" init -q -b main
echo x > "$PL/a"; gitc "$PL" add a; gitc "$PL" commit -qm init
"$BIN" zones add pl "$PL" >/dev/null 2>&1
"$BIN" swarm pl --team t --workers agy:2 --no-open >/dev/null 2>&1
CO=tp-pl-t-coord
out=$(PRAMA_SESSION=$CO "$BIN" plan add "Audit login" --est 45m --scope "src/auth/**" --accept "pytest" 2>&1)
assert_contains "plan add numbers the tasks" "T1" "$out"
PRAMA_SESSION=$CO "$BIN" plan add "Rotate keys" --deps T1 --est 1h --scope "src/auth/keys.py" >/dev/null 2>&1
out=$(PRAMA_SESSION=$CO "$BIN" plan add "Bad" --deps T9 2>&1); rc=$?
assert_true "Unknown dependencies are refused" "[ $rc -ne 0 ]"
out=$(PRAMA_SESSION=tp-pl-t-agy "$BIN" plan add "Mine" 2>&1); rc=$?
assert_true "Executors do not change the plan" "[ $rc -ne 0 ]"
PRAMA_SESSION=$CO "$BIN" bus assign tp-pl-t-agy "audit it" --task T1 >/dev/null 2>&1
js=$("$BIN" plan pl --team t json)
assert_true "bus assign --task starts the task for its owner" "jq -e '.tasks[0].status == \"doing\" and .tasks[0].owner == \"tp-pl-t-agy\"' >/dev/null <<< '$js'"
assert_true "…and the message carries the task id" "grep -q '\\[T1\\] audit it' '$STATE/bus/events.jsonl'"
PRAMA_SESSION=tp-pl-t-agy "$BIN" plan set T1 progress=60 >/dev/null 2>&1
PRAMA_SESSION=tp-pl-t-agy "$BIN" bus report "audit done, 14 tests pass" --task T1 >/dev/null 2>&1
js=$("$BIN" plan pl --team t json)
assert_true "bus report --task moves it to review with the evidence" "jq -e '.tasks[0].status == \"review\" and (.tasks[0].evidence | test(\"14 tests\"))' >/dev/null <<< '$js'"
PRAMA_SESSION=$CO "$BIN" plan start T2 --owner tp-pl-t-agy-2 >/dev/null 2>&1
out=$(PRAMA_SESSION=$CO "$BIN" plan "done" T2 2>&1)
assert_contains "done without evidence is flagged" "evidence" "$out"
assert_true "…as unverified" "$BIN plan pl --team t json | jq -e '.tasks[1].flags | test(\"unverified\")' >/dev/null"
PRAMA_SESSION=$CO "$BIN" plan replan "scope changed" >/dev/null 2>&1
assert_eq "replan bumps the revision" "2" "$("$BIN" plan pl --team t json | jq -r .rev)"
out=$(PRAMA_COLS=140 "$BIN" plan pl --team t)
assert_contains "Board: columns by status" "REVISIÓN" "$out"
out=$("$BIN" plan pl timeline --team t)
assert_contains "Timeline: a lane per owner" "agy" "$out"
"$BIN" plan pl html "$TMP_ROOT/plan.html" --team t >/dev/null 2>&1
assert_true "HTML export with an SVG timeline" "grep -q '<svg' '$TMP_ROOT/plan.html' && grep -q 'Rotate keys' '$TMP_ROOT/plan.html'"
PRAMA_SESSION=$CO "$BIN" plan add "Rate limit" --scope "src/auth/**" >/dev/null 2>&1
out=$(PRAMA_SESSION=$CO "$BIN" plan start T3 --owner tp-pl-t-agy-2 2>&1)
PRAMA_SESSION=$CO "$BIN" plan start T1 >/dev/null 2>&1
out=$(PRAMA_PLAN_STALE_MIN=0 bash -c 'source "'"$REPO_DIR"'/lib/core.sh"; source "'"$REPO_DIR"'/lib/ui.sh"; source "'"$REPO_DIR"'/lib/swarm.sh"; source "'"$REPO_DIR"'/lib/plan.sh"; prama_init >/dev/null; plan_alerts tp-pl-t-coord')
assert_contains "Watchdog: stale tasks" "sin actividad" "$out"
assert_contains "…same files in progress" "mismos archivos" "$out"
assert_contains "…done without evidence" "sin evidencia" "$out"
"$BIN" cockpit pl --team t --no-attach >/dev/null 2>&1
assert_true "The cockpit shows the plan live" "$P list-panes -a -F '#{pane_title}' | grep -q 'PLAN'"
"$BIN" swarm stop pl --team t >/dev/null 2>&1
assert_true "The plan outlives the team" "$BIN plan pl --team t json | jq -e '.tasks | length == 3' >/dev/null"
"$BIN" zones remove pl >/dev/null 2>&1

section "Feedback channel (agents report prama bugs)"
co=$("$BIN" claude alpha --role coordinator --bg --porcelain 2>/dev/null)
out=$(PRAMA_SESSION=$co OPENROUTER_API_KEY=sk-or-v1-0123456789abcdefghij "$BIN" feedback "fleet model no cambió el modelo; key sk-or-v1-0123456789abcdefghij token=supersecret123" 2>&1)
assert_contains "An agent files a report" "registrado" "$out"
fid=$("$BIN" feedback list --json | jq -r '.[0].id')
assert_true "…stored in the private state dir (0700)" "[ \"\$(stat -c %a '$STATE/feedback/$fid')\" = 700 ]"
assert_eq "…with the reporter's context" "coordinator" "$(grep '^ROLE=' "$STATE/feedback/$fid/meta" | cut -d= -f2)"
assert_not_contains "Secrets are redacted (provider key)" "0123456789abcdefghij" "$(cat "$STATE/feedback/$fid/body.md")"
assert_not_contains "…and token=value pairs" "supersecret123" "$(cat "$STATE/feedback/$fid/body.md")"
PRAMA_SESSION=$co "$BIN" feedback "fleet model no cambió el modelo; key sk-or-v1-0123456789abcdefghij token=supersecret123" >/dev/null 2>&1
assert_eq "A repeated report counts instead of piling up" "1 2" "$("$BIN" feedback list --json | jq -r '"\(length) \(.[0].count)"')"
assert_true "The operator is told through the bus" "grep -q '\"event\":\"feedback\"' '$STATE/bus/events.jsonl'"
assert_contains "Export: a Markdown issue body" "### Environment" "$("$BIN" feedback export "$fid")"
out=$(PRAMA_SESSION=$co "$BIN" feedback close "$fid" 2>&1); rc=$?
assert_true "Agents cannot close reports" "[ $rc -ne 0 ]"
"$BIN" feedback close "$fid" >/dev/null 2>&1
assert_eq "The operator closes them" "0" "$("$BIN" feedback list --json | jq length)"
assert_contains "Every agent learns how to report prama bugs" "prama-agent feedback" "$(bash -c 'source "'"$REPO_DIR"'/lib/core.sh"; source "'"$REPO_DIR"'/lib/roles.sh"; build_role_system_prompt executor s z')"
"$BIN" stop --all -y >/dev/null 2>&1

section "First steps: setup, login and zones"
mkdir -p "$TMP_ROOT/repos/gamma"
out=$("$BIN" zones add gamma "$TMP_ROOT/repos/gamma" "Gamma service" 2>&1)
assert_contains "zones add registers a folder under a short name" "gamma" "$("$BIN" zones)"
assert_eq "…in zones.conf, data only (name|dir|desc)" "gamma|$TMP_ROOT/repos/gamma|Gamma service" "$(cat "$HOME/.config/prama-agent/zones.conf")"
assert_contains "…next to the zones of config.env" "alpha" "$("$BIN" zones)"
assert_contains "A registered zone can be used right away" "tp-claude-gamma" "$("$BIN" claude gamma --dry-run 2>&1)"
out=$("$BIN" zones add alpha "$TMP_ROOT/plain" 2>&1); rc=$?
assert_true "A zone from config.env is not overwritten" "[ $rc -ne 0 ] && [[ \"\$out\" == *config.env* ]]"
out=$("$BIN" zones add 'gam;ma' "$TMP_ROOT/plain" 2>&1); rc=$?
assert_true "Zone names are validated" "[ $rc -ne 0 ]"
printf 'evil|$(touch %s/pwned)|x\n' "$TMP_ROOT" >> "$HOME/.config/prama-agent/zones.conf"
"$BIN" zones >/dev/null 2>&1
assert_true "zones.conf is never executed" "[ ! -e '$TMP_ROOT/pwned' ]"
"$BIN" zones remove evil >/dev/null 2>&1; "$BIN" zones remove gamma >/dev/null 2>&1
assert_not_contains "zones remove" "gamma" "$("$BIN" zones)"
out=$(MOCK_SLEEP=0 "$BIN" login 2>&1)
assert_contains "login shows each agent's session (agy without a token)" "agy" "$out"
assert_contains "…and how to sign in" "prama-agent login agy" "$out"
mkdir -p "$HOME/.gemini/antigravity-cli" && echo tok > "$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
assert_contains "…signed in once agy has its token" "sesión iniciada" "$(MOCK_SLEEP=0 "$BIN" login 2>&1 | grep agy)"
rm -rf "$HOME/.gemini/antigravity-cli"
out=$(MOCK_SLEEP=0 "$BIN" setup --check </dev/null 2>&1); rc=$?
assert_true "setup --check runs without a terminal" "[ $rc -eq 0 ]"
assert_contains "…and walks through agents, zones and permissions" "3 · Zonas" "$out"

section "Languages, themes and team memory"
out=$(PRAMA_LANG=en "$BIN" --help)
assert_contains "English interface: usage" "FIRST STEPS" "$out"
assert_not_contains "…without Spanish" "PRIMEROS" "$out"
assert_contains "Spanish interface (PRAMA_LANG=es)" "PRIMEROS PASOS" "$("$BIN" --help)"
out=$(PRAMA_LANG=en "$BIN" claude nowhere --dry-run 2>&1)
assert_not_contains "English errors" "desconocida" "$out"
out=$(bash -c 'source "'"$REPO_DIR"'/lib/core.sh"; source "'"$REPO_DIR"'/lib/roles.sh"; PRAMA_LANG=en; i18n_init; build_role_system_prompt coordinator s z')
assert_contains "English role prompt keeps the machine marker" "[PRAMA-SWARM ROLE: COORDINATOR" "$out"
assert_contains "…and teaches the team memory" "prama-agent memory add" "$out"
assert_contains "Screen filter knows the English tags" "none" "$(bash -c 'source "'"$REPO_DIR"'/lib/core.sh"; screen_block_reason "$1" || echo none' _ $'> [PRAMA ALERT] quota exceeded, credit balance is too low\n⏺ ok')"
LANGCFG="$TMP_ROOT/langcfg"; mkdir -p "$LANGCFG"
out=$(XDG_CONFIG_HOME="$LANGCFG" PRAMA_LANG='' "$BIN" lang en 2>&1)
assert_contains "lang en saves the language" 'PRAMA_LANG="en"' "$(cat "$LANGCFG/prama-agent/config.env")"
assert_contains "…and it applies from config.env" "FIRST STEPS" "$(XDG_CONFIG_HOME="$LANGCFG" PRAMA_LANG='' "$BIN" --help)"
assert_contains "…unless the environment says otherwise" "PRIMEROS PASOS" "$(XDG_CONFIG_HOME="$LANGCFG" PRAMA_LANG=es "$BIN" --help)"
assert_eq "theme --names lists the themes" "7" "$("$BIN" theme --names | wc -l | tr -d ' ')"
out=$(XDG_CONFIG_HOME="$LANGCFG" "$BIN" theme ocean 2>&1)
assert_contains "theme <name> saves it" 'PRAMA_THEME="ocean"' "$(cat "$LANGCFG/prama-agent/config.env")"
assert_contains "…and regenerates the tmux status bar" "theme=ocean" "$(cat "$HOME/.local/state/prama-agent/tmux.conf")"
out=$("$BIN" theme 'x;y' 2>&1); rc=$?
assert_true "Unknown themes are refused" "[ $rc -ne 0 ]"
"$BIN" theme midnight >/dev/null 2>&1
"$BIN" memory add alpha --team sec "Auth uses JWT (token=sk-ant-abcdefghijklmnopqrstuvwxyz0123)" >/dev/null
"$BIN" memory add alpha --zone-wide "Python 3.12" >/dev/null
out=$("$BIN" memory show alpha --team sec)
assert_contains "memory: the team's notes" "Auth uses JWT" "$out"
assert_contains "…after the zone's" "Python 3.12" "$out"
assert_not_contains "…with secrets redacted" "sk-ant-" "$out"
assert_true "memory show --json is valid JSON" "$BIN memory show alpha --team sec --json | jq -e 'length == 2' >/dev/null"
out=$(PRAMA_SESSION=tp-claude-alpha "$BIN" memory clear alpha --zone-wide -y 2>&1); rc=$?
assert_true "Agents cannot clear a memory" "[ $rc -ne 0 ]"
"$BIN" memory clear alpha --team sec -y >/dev/null
assert_not_contains "The operator can" "Auth uses JWT" "$("$BIN" memory show alpha --team sec)"
"$BIN" telegram alerts important >/dev/null 2>&1
assert_eq "Telegram notification level (state file)" "important|0" "$("$BIN" telegram alerts --porcelain)"
"$BIN" telegram mute 1h >/dev/null 2>&1
assert_true "telegram mute stores the end time" "[ \"\$($BIN telegram alerts --porcelain | cut -d'|' -f2)\" -gt \$(date +%s) ]"
out=$("$BIN" telegram mute forever 2>&1); rc=$?
assert_true "…and validates the duration" "[ $rc -ne 0 ]"
"$BIN" telegram mute off >/dev/null 2>&1; "$BIN" telegram alerts all >/dev/null 2>&1

section "Installer"
out=$(BASH_COMPLETION_USER_DIR="$TMP_ROOT/comp" PREFIX="$TMP_ROOT/inst" CONF_DIR="$TMP_ROOT/inst/etc" bash "$REPO_DIR/install.sh" 2>&1); rc=$?
assert_true "install.sh from a clone links the commands" "[ $rc -eq 0 ] && [ -x '$TMP_ROOT/inst/bin/prama-agent' ]"
assert_true "…creates config.env and a 0600 providers.env" "[ -f '$TMP_ROOT/inst/etc/config.env' ] && [ \"\$(stat -c %a '$TMP_ROOT/inst/etc/providers.env')\" = 600 ]"
git clone -q --bare "$REPO_DIR" "$TMP_ROOT/remote.git" 2>/dev/null
out=$(cat "$REPO_DIR/install.sh" | BASH_COMPLETION_USER_DIR="$TMP_ROOT/comp" PRAMA_REPO_URL="$TMP_ROOT/remote.git" PRAMA_HOME="$TMP_ROOT/boot/src" \
      PREFIX="$TMP_ROOT/boot" CONF_DIR="$TMP_ROOT/boot/etc" bash 2>&1); rc=$?
assert_true "One-line install (piped) clones and installs" "[ $rc -eq 0 ] && [ -x '$TMP_ROOT/boot/bin/prama-agent' ] && [ -d '$TMP_ROOT/boot/src/.git' ]"
assert_contains "…and the installed command runs" "prama-agent v" "$("$TMP_ROOT/boot/bin/prama-agent" --version 2>&1)"

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
