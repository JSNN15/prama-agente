#!/usr/bin/env bash
# Automated test suite for prama-agent v5.0.0 (Modular Architecture & Swarm Bus)
# Licensed under the Apache License, Version 2.0
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_DIR/bin/prama-agent"
PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local desc=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    printf ' [PASS] %s\n' "$desc"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf ' [FAIL] %s\n   expected: %s\n   actual:   %s\n' "$desc" "$expected" "$actual" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_contains() {
  local desc=$1 needle=$2 haystack=$3
  if [[ "$haystack" == *"$needle"* ]]; then
    printf ' [PASS] %s\n' "$desc"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf ' [FAIL] %s\n   missing needle: %s\n   in output:      %s\n' "$desc" "$needle" "$haystack" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/home/.config/prama-agent" "$TMP_ROOT/bin" "$TMP_ROOT/repos/alpha" "$TMP_ROOT/repos/beta" "$TMP_ROOT/bus"
git -C "$TMP_ROOT/repos/alpha" init -q -b main
git -C "$TMP_ROOT/repos/beta" init -q -b main
echo "SECRET_TOKEN=12345" > "$TMP_ROOT/repos/alpha/.env"

for mock_agent in claude agy kimi gemini qwen; do
  cat <<'EOF' > "$TMP_ROOT/bin/$mock_agent"
#!/usr/bin/env bash
echo "mock-agent:$0 $*"
EOF
  chmod +x "$TMP_ROOT/bin/$mock_agent"
done

cat <<EOF > "$TMP_ROOT/home/.config/prama-agent/config.env"
AGENTS=(claude agy kimi gemini qwen)
AGENT_DESCS=("Claude Mock" "Agy Mock" "Kimi Mock" "Gemini Mock" "Qwen Mock")
ZONES=(alpha beta)
ZONE_DIRS=("$TMP_ROOT/repos/alpha" "$TMP_ROOT/repos/beta")
ZONE_DESCS=("Alpha Service" "Beta Service")
PRAMA_SESSION_PREFIX="testprama"
PRAMA_BUS_DIR="$TMP_ROOT/bus"
EOF

cat <<EOF > "$TMP_ROOT/home/.config/prama-agent/providers.env"
KIMI_API_KEY="mock-kimi-token-123"
DEEPSEEK_API_KEY="mock-ds-token-456"
EOF

export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$TMP_ROOT/home/.config"
export PATH="$TMP_ROOT/bin:$PATH"
export NO_COLOR=1

# 1. Version check
ver=$("$BIN" --version)
assert_eq "Version output matches v5.0.0" "prama-agent v5.0.0" "$ver"

# 2. Exact permission bypass flags across all 5 agents
dry_claude=$("$BIN" claude alpha --dry-run)
assert_contains "Claude uses --dangerously-skip-permissions" "--dangerously-skip-permissions" "$dry_claude"

dry_agy=$("$BIN" agy alpha --dry-run)
assert_contains "Agy uses --dangerously-skip-permissions" "--dangerously-skip-permissions" "$dry_agy"

dry_kimi=$("$BIN" kimi alpha --dry-run)
assert_contains "Kimi uses --yolo" "kimi --yolo" "$dry_kimi"

dry_gemini=$("$BIN" gemini alpha --dry-run)
assert_contains "Gemini uses --yolo" "gemini --yolo" "$dry_gemini"

dry_qwen=$("$BIN" qwen alpha --dry-run)
assert_contains "Qwen uses --yolo" "qwen --yolo" "$dry_qwen"

# 3. Reader Role (Read-Only / Plan flags) across agents
dry_reader_claude=$("$BIN" claude alpha --role reader --dry-run)
assert_contains "Reader role on Claude sets --permission-mode plan" "--permission-mode plan" "$dry_reader_claude"
assert_contains "Reader role names session with reader prefix" "testprama-reader-claude-alpha" "$dry_reader_claude"

dry_reader_agy=$("$BIN" agy alpha --role reader --dry-run)
assert_contains "Reader role on Agy sets --mode plan" "--mode plan" "$dry_reader_agy"

dry_reader_kimi=$("$BIN" kimi alpha --role reader --dry-run)
assert_contains "Reader role on Kimi sets --plan" "kimi --plan" "$dry_reader_kimi"

# 4. Native Remote-Control flags (--remote)
dry_rc_claude=$("$BIN" claude alpha --remote --dry-run)
assert_contains "Claude --remote injects --remote-control <session>" "--remote-control testprama-claude-alpha" "$dry_rc_claude"

dry_rc_agy=$("$BIN" agy alpha --remote --dry-run)
assert_contains "Agy --remote injects --remote-control" "agy --dangerously-skip-permissions --remote-control" "$dry_rc_agy"

# 5. Argument quoting preservation with spaces
dry_quoted=$("$BIN" agy beta --dry-run -- -p "analyze all logs and fix bugs")
assert_contains "Preserves multi-word arguments safely" "analyze\\ all\\ logs\\ and\\ fix\\ bugs" "$dry_quoted"

# 6. Worktree provisioning and .env synchronization
wt_out=$("$BIN" worktree create alpha feat-login)
assert_contains "Worktree created output" "Worktree listo en:" "$wt_out"
assert_eq "Synchronizes .env into new git worktree" "SECRET_TOKEN=12345" "$(cat "$TMP_ROOT/repos/alpha/worktrees/feat-login/.env")"

# 7. Inter-Agent Coordination Bus (assign & report)
bus_assign_out=$("$BIN" bus assign daemon "Run full test suite every hour")
assert_contains "Queues task for daemon in bus" "Tarea encolada para el Daemon" "$bus_assign_out"
bus_rep_out=$("$BIN" bus report "All 20 integration tests passed")
assert_contains "Records report in bus" "Reporte registrado" "$bus_rep_out"
bus_st_out=$("$BIN" bus status)
assert_contains "Bus status displays recorded events" "All 20 integration tests passed" "$bus_st_out"

# 8. E2E Tmux Supervised Session Lifecycle Test
if command -v tmux >/dev/null 2>&1; then
  cat <<'EOF' > "$TMP_ROOT/bin/claude"
#!/usr/bin/env bash
echo "E2E_AGENT_STARTED role=${PRAMA_ROLE:-none} profile=${ANTHROPIC_MODEL:-native} sandbox=${IS_SANDBOX:-0}"
sleep 1
EOF
  chmod +x "$TMP_ROOT/bin/claude"

  bg_out=$("$BIN" claude alpha --bg --role coordinator --name "testprama-e2e-coord" --profile kimi)
  assert_contains "Launches background coordinator tmux session" "testprama-e2e-coord" "$bg_out"
  sleep 0.5
  logs_out=$("$BIN" logs "testprama-e2e-coord" 20)
  assert_contains "Supervisor header rendered with role badge" "COORDINATOR" "$logs_out"
  assert_contains "Agent received role and profile env inside tmux" "E2E_AGENT_STARTED role=coordinator profile=kimi-k2.7 sandbox=1" "$logs_out"
  stop_out=$("$BIN" stop "testprama-e2e-coord")
  assert_contains "Stops background tmux session cleanly" "terminada correctamente" "$stop_out"
fi

# 9. Security & Open-Source Hygiene check (Zero hardcoded credentials or private keys in source)
if grep -riE "BEGIN (RSA |OPENSSH )?PRIVATE KEY|ghp_[A-Za-z0-9]{20}|sk-[a]nt-[A-Za-z0-9]{10}" "$REPO_DIR/bin" "$REPO_DIR/lib" "$REPO_DIR/config" "$REPO_DIR/README.md" 2>/dev/null; then
  printf ' [FAIL] Found hardcoded credentials in open-source files!\n' >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  printf ' [PASS] Zero hardcoded credentials or private keys in repository source\n'
  PASS_COUNT=$((PASS_COUNT + 1))
fi

printf '\nTest Summary: %d passed, %d failed.\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
