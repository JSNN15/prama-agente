#!/usr/bin/env bash
# lib/core.sh — Configuration, private state, dedicated tmux server, bus primitives & process telemetry
# Licensed under the Apache License, Version 2.0
#
# This module only defines functions and inert defaults. Nothing touches the filesystem or tmux
# until prama_init() is called by the entrypoint. See docs/ARCHITECTURE.md for the public API.

shopt -s extglob

# ── Defaults (overridable from config.env or the environment) ───────────────
PRAMA_BRAND="${PRAMA_BRAND:-PRAMA AGENT}"
PRAMA_SESSION_PREFIX="${PRAMA_SESSION_PREFIX:-prama}"
PRAMA_WORKTREE_COPY_FILES="${PRAMA_WORKTREE_COPY_FILES:-.env .env.local .mcp.json}"
PRAMA_SKIP_PERMISSIONS="${PRAMA_SKIP_PERMISSIONS:-0}"   # 0 = ask (safe default), 1 = yolo
PRAMA_DEFAULT_REMOTE="${PRAMA_DEFAULT_REMOTE:-0}"
PRAMA_DEFAULT_ROLE="${PRAMA_DEFAULT_ROLE:-executor}"
PRAMA_DISCOVER_ROOTS="${PRAMA_DISCOVER_ROOTS:-/opt $HOME}"
PRAMA_TMUX_SOCKET="${PRAMA_TMUX_SOCKET:-prama}"         # dedicated tmux server (tmux -L prama)
PRAMA_MENU_KEY="${PRAMA_MENU_KEY:-M-m}"                 # key that detaches back to the menu
PRAMA_HOOKS="${PRAMA_HOOKS:-1}"                         # inject state hooks into claude sessions
PRAMA_WATCHDOG="${PRAMA_WATCHDOG:-1}"                   # auto-start the fleet watchdog on launch
PRAMA_WATCH_INTERVAL="${PRAMA_WATCH_INTERVAL:-5}"
PRAMA_FLEET_MAX="${PRAMA_FLEET_MAX:-8}"                 # max live agent sessions (fleet spawn)
PRAMA_FLEET_SCOPE="${PRAMA_FLEET_SCOPE:-zone}"          # what an agent may manage: zone | children | all
PRAMA_OPENCODE_MODEL="${PRAMA_OPENCODE_MODEL:-openrouter/qwen/qwen3-coder:free}"

PRAMA_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/prama-agent"
PRAMA_STATE_HOME="${PRAMA_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/prama-agent}"
PRAMA_BUS_DIR="${PRAMA_BUS_DIR:-$PRAMA_STATE_HOME/bus}"
PRAMA_TMUX_CONF="${PRAMA_TMUX_CONF:-$PRAMA_STATE_HOME/tmux.conf}"

SUPPORTED_AGENTS=(claude agy opencode)
AGENTS=("${SUPPORTED_AGENTS[@]}")
AGENT_DESCS=(
  "Claude Code (Anthropic / API)"
  "Agy (Antigravity CLI)"
  "OpenCode (OpenRouter · modelos abiertos)"
)
ZONES=()
ZONE_DIRS=()
ZONE_DESCS=()

PRAMA_SYSTEM_CONFIG_DIR="${PRAMA_SYSTEM_CONFIG_DIR-/etc/prama-agent}"   # set empty to ignore /etc
CONFIG_FILES=("$PRAMA_SYSTEM_CONFIG_DIR/config.env" "$PRAMA_CONFIG_HOME/config.env")
PROVIDER_FILES=("$PRAMA_SYSTEM_CONFIG_DIR/providers.env" "$PRAMA_CONFIG_HOME/providers.env")

# ── Logging (stderr for errors so command substitution stays clean) ─────────
die()      { printf ' %s✖ ERROR:%s %s\n' "${C_ERR:-}" "${C_OFF:-}" "$1" >&2; exit 1; }
ok()       { printf ' %s✔%s %s\n' "${C_LIVE:-}" "${C_OFF:-}" "$1"; }
warn()     { printf ' %s▲%s %s\n' "${C_BRASS:-}" "${C_OFF:-}" "$1" >&2; }
info_msg() { printf ' %s•%s %s\n' "${C_NEON:-}" "${C_OFF:-}" "$1"; }

is_in() {
  local x=$1 e; shift
  for e in "$@"; do [ "$e" = "$x" ] && return 0; done
  return 1
}

# ── Initialization ──────────────────────────────────────────────────────────
# Creates a directory that only the current user can read/write. Refuses symlinks and
# directories owned by someone else (protects against /tmp-style squatting).
ensure_private_dir() {
  local d=$1
  if [ -L "$d" ]; then
    die "Ruta insegura (es un symlink): $d"
  fi
  if [ ! -d "$d" ]; then
    (umask 077 && mkdir -p "$d") || die "No se pudo crear $d"
  fi
  local owner
  owner=$(stat -c %u "$d" 2>/dev/null || stat -f %u "$d" 2>/dev/null || echo "")
  if [ -n "$owner" ] && [ "$owner" != "$EUID" ]; then
    die "El directorio $d pertenece a otro usuario (uid $owner); se rechaza por seguridad."
  fi
  chmod 700 "$d" 2>/dev/null || true
}

prama_load_config() {
  local cfg
  # Config files are bash by design (documented); they must be owned by the user or root.
  for cfg in "${CONFIG_FILES[@]}" "${PROVIDER_FILES[@]}"; do
    # shellcheck disable=SC1090
    [ -f "$cfg" ] && source "$cfg"
  done
  # Re-derive paths in case config.env overrode their inputs.
  PRAMA_BUS_DIR="${PRAMA_BUS_DIR:-$PRAMA_STATE_HOME/bus}"
  PRAMA_TMUX_CONF="${PRAMA_TMUX_CONF:-$PRAMA_STATE_HOME/tmux.conf}"
}

discover_zones() {
  [ "${#ZONES[@]}" -gt 0 ] && return 0
  local root d
  for root in $PRAMA_DISCOVER_ROOTS; do
    [ -d "$root" ] || continue
    for d in "$root"/*; do
      [ -d "$d/.git" ] || continue
      ZONES+=("$(basename "$d")")
      ZONE_DIRS+=("$d")
      ZONE_DESCS+=("git · $(basename "$d")")
    done
  done
  if [ "${#ZONES[@]}" -eq 0 ]; then
    ZONES=("workspace")
    ZONE_DIRS=("$PWD")
    ZONE_DESCS=("directorio actual")
  fi
}

# Call once from the entrypoint after argument pre-dispatch.
prama_init() {
  prama_load_config
  _filter_agents
  discover_zones
  ensure_private_dir "$PRAMA_STATE_HOME"
  ensure_private_dir "$PRAMA_BUS_DIR"
  ensure_private_dir "$PRAMA_BUS_DIR/state"
  ensure_private_dir "$PRAMA_BUS_DIR/inbox"
  : >> "$PRAMA_BUS_DIR/events.jsonl"
  chmod 600 "$PRAMA_BUS_DIR/events.jsonl" 2>/dev/null || true
  export PRAMA_TMUX_SOCKET PRAMA_BUS_DIR PRAMA_STATE_HOME PRAMA_TMUX_CONF
}

# A config.env written for v5 may still list agents prama no longer drives (kimi, gemini, qwen):
# keep only supported ones, in the configured order. Dropped names go to DROPPED_AGENTS (doctor).
_filter_agents() {
  local a d keep=() descs=()
  DROPPED_AGENTS=()
  for a in "${AGENTS[@]}"; do
    if is_in "$a" "${SUPPORTED_AGENTS[@]}"; then keep+=("$a"); else DROPPED_AGENTS+=("$a"); fi
  done
  # A legacy list (it named dropped agents) predates opencode: offer every supported agent.
  if (( ${#DROPPED_AGENTS[@]} )); then
    for a in "${SUPPORTED_AGENTS[@]}"; do is_in "$a" ${keep[@]+"${keep[@]}"} || keep+=("$a"); done
  fi
  (( ${#keep[@]} )) || keep=("${SUPPORTED_AGENTS[@]}")
  for a in "${keep[@]}"; do
    case "$a" in
      claude)   d="Claude Code (Anthropic / API)" ;;
      agy)      d="Agy (Antigravity CLI)" ;;
      opencode) d="OpenCode (OpenRouter · modelos abiertos)" ;;
    esac
    descs+=("$d")
  done
  AGENTS=("${keep[@]}") AGENT_DESCS=("${descs[@]}")
}

# ── Zones ───────────────────────────────────────────────────────────────────
# Prints the directory of a registered zone; returns 1 if unknown.
zone_dir() {
  local z=$1 i
  for i in "${!ZONES[@]}"; do
    if [ "${ZONES[$i]}" = "$z" ]; then
      printf '%s' "${ZONE_DIRS[$i]}"
      return 0
    fi
  done
  return 1
}

# ── Session names ───────────────────────────────────────────────────────────
# Session names are restricted so they are safe as file names, tmux targets and
# Telegram callback payloads (64 bytes max including an 8-byte action prefix).
SESSION_NAME_RE='^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$'

valid_session_name() { [[ "${1:-}" =~ $SESSION_NAME_RE ]]; }

# Turns arbitrary text into a valid session-name fragment.
slugify() {
  local s=${1//[^A-Za-z0-9_-]/-}
  s=${s##+(-)}
  printf '%s' "${s:0:48}"
}

# Canonical session name for an agent launch.
session_name_for() {
  local agent=$1 zone=$2 role=$3 wt=${4:-}
  local name="$PRAMA_SESSION_PREFIX"
  [ "$role" != "executor" ] && name+="-$role"
  name+="-$agent-$zone"
  [ -n "$wt" ] && name+="-$wt"
  name=$(slugify "$name")
  printf '%s' "$name"
}

# ── Dedicated tmux server ───────────────────────────────────────────────────
# All prama sessions live on their own server, so the user's personal tmux sessions and
# ~/.tmux.conf are never touched, listed, broadcast to or killed.
tmx() { tmux -L "$PRAMA_TMUX_SOCKET" -f "$PRAMA_TMUX_CONF" "$@"; }

tmx_running() { tmx list-sessions >/dev/null 2>&1; }

# Exact-match targets: plain "-t name" in tmux does prefix/pattern matching.
tmx_has()  { tmx has-session -t "=$1" 2>/dev/null; }
tmx_kill() { tmx kill-session -t "=$1" 2>/dev/null; }

# Types text literally into a session and presses Enter.
tmx_send() {
  local s=$1 text=$2
  tmx send-keys -t "=$s:" -l -- "$text" && tmx send-keys -t "=$s:" Enter
}

# Prints the last N lines of a session's active pane (ansi=1 keeps colors).
tmx_capture() {
  local s=$1 lines=${2:-40} ansi=${3:-0}
  local flags=(-p -J)
  (( ansi )) && flags+=(-e)
  tmx capture-pane "${flags[@]}" -t "=$s:" -S "-$lines" 2>/dev/null
}

# Lists sessions on the prama server. Internal sessions (telegram bot, cockpits) are
# skipped unless include_internal=1.
prama_sessions() {
  local include_internal=${1:-0} s
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    if (( ! include_internal )) && is_internal_session "$s"; then continue; fi
    printf '%s\n' "$s"
  done < <(tmx list-sessions -F '#{session_name}' 2>/dev/null)
}

is_internal_session() {
  [[ "$1" == "${PRAMA_SESSION_PREFIX}-telegram-bot" || "$1" == "${PRAMA_SESSION_PREFIX}-watchdog" \
     || "$1" == "${PRAMA_SESSION_PREFIX}-cockpit-"* ]]
}

# Attaches to a prama session from wherever we are:
#  - inside the prama server  → switch-client
#  - inside another tmux      → nested attach (TMUX unset), returns on detach
#  - plain terminal           → attach -d (detaches stale/zombie clients)
# With exec_mode=1 the current process is replaced (CLI usage).
tmx_attach() {
  local s=$1 exec_mode=${2:-0}
  local cmd
  if [ -n "${TMUX:-}" ] && [[ "${TMUX%%,*}" == */"$PRAMA_TMUX_SOCKET" ]]; then
    cmd=(tmux -L "$PRAMA_TMUX_SOCKET" switch-client -t "=$s")
  elif [ -n "${TMUX:-}" ]; then
    cmd=(env -u TMUX tmux -L "$PRAMA_TMUX_SOCKET" -f "$PRAMA_TMUX_CONF" attach-session -t "=$s")
  else
    cmd=(tmux -L "$PRAMA_TMUX_SOCKET" -f "$PRAMA_TMUX_CONF" attach-session -d -t "=$s")
  fi
  if (( exec_mode )); then exec "${cmd[@]}"; fi
  "${cmd[@]}" || true
}

# Writes the managed tmux config for the prama server (never ~/.tmux.conf) and reloads it.
TMUX_CONF_VERSION="prama-agent-managed-v6"
ensure_tmux_conf() {
  local force=${1:-0}
  if (( force )) || [ ! -f "$PRAMA_TMUX_CONF" ] || ! grep -q "$TMUX_CONF_VERSION" "$PRAMA_TMUX_CONF" 2>/dev/null \
     || ! grep -q "bind -n $PRAMA_MENU_KEY " "$PRAMA_TMUX_CONF" 2>/dev/null; then
    local tmp="$PRAMA_TMUX_CONF.tmp.$$"
    cat > "$tmp" <<EOF
# $TMUX_CONF_VERSION — generated, do not edit (regenerated by 'prama-agent doctor')
# Applies only to the dedicated prama tmux server (tmux -L $PRAMA_TMUX_SOCKET).

set -g mouse on
set -g history-limit 50000
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",*256col*:Tc,xterm*:Tc,tmux*:Tc"
set -as terminal-features ",*:sync"
set -s escape-time 10
setw -g aggressive-resize on
set -g set-clipboard on
set -g focus-events on
setw -g mode-keys vi
set -g detach-on-destroy on
set -g base-index 0
set -g renumber-windows on

# Return to the Prama menu without stopping the agent
bind -n $PRAMA_MENU_KEY detach-client
bind m detach-client
bind -n MouseDown1StatusLeft detach-client

# Pane titles show the agent role
set -g pane-border-status top
set -g pane-border-lines heavy
set -g pane-border-format " #[bold]#{?pane_active,#[fg=#38bdf8],#[fg=#64748b]}#{pane_title}#[default] "
set -g pane-border-style "fg=#334155"
set -g pane-active-border-style "fg=#38bdf8"

# Status bar: left segment is a tappable "back to menu" button (Termius / mouse)
set -g status-interval 5
set -g status-style "bg=#0f172a,fg=#cbd5e1"
set -g status-left "#[bg=#38bdf8,fg=#0f172a,bold]  ◂ MENU #[bg=#1e293b,fg=#38bdf8] $PRAMA_MENU_KEY #[default] "
set -g status-left-length 30
set -g status-right "#[fg=#64748b]#{session_name} #[fg=#34d399]● #[fg=#94a3b8]%H:%M "
set -g status-right-length 60
set -g window-status-format ""
set -g window-status-current-format ""
set -g message-style "bg=#1e293b,fg=#f0f9ff"
set -g mode-style "bg=#1e3a5f,fg=#f0f9ff"
EOF
    mv -f "$tmp" "$PRAMA_TMUX_CONF"
    if tmx_running; then tmx source-file "$PRAMA_TMUX_CONF" 2>/dev/null || true; fi
  fi
}

# ── Session state (KEY=value files; never sourced, never eval'd) ────────────
state_file() { printf '%s/state/%s.env' "$PRAMA_BUS_DIR" "$(slugify "$1")"; }

# state_write <session> KEY=VALUE...   (atomic replace)
state_write() {
  local s=$1; shift
  local f tmp kv
  f=$(state_file "$s")
  tmp="$f.tmp.$$"
  {
    printf 'SESSION_NAME=%s\n' "$s"
    for kv in "$@"; do
      kv=${kv//$'\n'/ }
      printf '%s\n' "$kv"
    done
  } > "$tmp" && mv -f "$tmp" "$f"
}

# state_get <session> KEY [default]
state_get() {
  local f k v
  f=$(state_file "$1")
  if [ -f "$f" ]; then
    while IFS='=' read -r k v; do
      [ "$k" = "$2" ] && { printf '%s' "$v"; return 0; }
    done < "$f"
  fi
  printf '%s' "${3:-}"
}

state_remove() {
  local f
  f=$(state_file "$1")
  rm -f "$f" "${f%.env}".{args,health,quota,sl,prompt.md} "$f.lock" "${f%.env}.health.lock" "${f%.env}.quota.lock" 2>/dev/null || true
}

# state_set <session> KEY=VALUE...   (merge: replaces only the given keys, atomic, serialized)
state_set() { _kv_merge "$(state_file "$1")" "$@"; }

# _kv_merge <file> <session> KEY=VALUE...  — shared by state_set / health_set
_kv_merge() {
  local f=$1 s=$2; shift 2
  local tmp="$f.tmp.$$" kv k line
  declare -A upd=()
  local order=()
  for kv in "$@"; do
    k=${kv%%=*}
    [[ "$k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    [ -n "${upd[$k]+x}" ] || order+=("$k")
    upd[$k]=${kv//$'\n'/ }
  done
  {
    command -v flock >/dev/null 2>&1 && flock 8
    {
      if [ -f "$f" ]; then
        while IFS= read -r line; do
          k=${line%%=*}
          [ -n "${upd[$k]+x}" ] && continue
          printf '%s\n' "$line"
        done < "$f"
      else
        printf 'SESSION_NAME=%s\n' "$s"
      fi
      for k in "${order[@]}"; do printf '%s\n' "${upd[$k]}"; done
    } > "$tmp" && mv -f "$tmp" "$f"
  } 8>>"$f.lock"
}

# ── Agent health (written by hooks / screen detection, read by watchdog & fleet) ──
# Keys: HEALTH=ok|blocked  REASON  DETAIL  ACTIVITY=working|idle|ended  MODEL  AGENT_SID  TS
health_file() { local f; f=$(state_file "$1"); printf '%s' "${f%.env}.health"; }
health_set()  { _kv_merge "$(health_file "$1")" "$@" "TS=${EPOCHSECONDS:-$(date +%s)}"; }
health_get()  { _kv_get "$(health_file "$1")" "$2" "${3:-}"; }

# Usage telemetry, written by the CLI status line (statusline_ingest in health.sh).
# Keys: Q_5H Q_7D (quota used %, highest bucket)  Q_5H_RESET Q_7D_RESET (epoch)  CTX (context
# used %)  COST (USD)  Q_MODEL  Q_PLAN  Q_TS
quota_file() { local f; f=$(state_file "$1"); printf '%s' "${f%.env}.quota"; }
quota_get()  { _kv_get "$(quota_file "$1")" "$2" "${3:-}"; }

# _kv_get <file> <KEY> [default]
_kv_get() {
  local k v
  if [ -f "$1" ]; then
    while IFS='=' read -r k v; do
      [ "$k" = "$2" ] && { printf '%s' "$v"; return 0; }
    done < "$1"
  fi
  printf '%s' "${3:-}"
}

# Launch arguments passed through to the agent CLI (NUL separated, never evaluated).
state_args_file() { local f; f=$(state_file "$1"); printf '%s' "${f%.env}.args"; }

# Role of a session: explicit state first, then inferred from the canonical name.
session_role() {
  local s=$1 r
  r=$(state_get "$s" ROLE)
  if [ -z "$r" ]; then
    case "$s" in
      "${PRAMA_SESSION_PREFIX}-coordinator-"*) r=coordinator ;;
      "${PRAMA_SESSION_PREFIX}-reader-"*)      r=reader ;;
      "${PRAMA_SESSION_PREFIX}-daemon-"*)      r=daemon ;;
      *)                                       r=executor ;;
    esac
  fi
  printf '%s' "$r"
}

# Drops state files for sessions that no longer exist.
state_gc() {
  local f s
  for f in "$PRAMA_BUS_DIR"/state/*.env; do
    [ -f "$f" ] || continue
    s=$(basename "$f" .env)
    tmx_has "$s" || rm -f "$f" "${f%.env}".{args,health,quota,sl,prompt.md} "$f.lock" "${f%.env}.health.lock" "${f%.env}.quota.lock"
  done
}

# ── Task queues (maildir-style: one file per task, atomic rename to claim) ──
queue_dir() { printf '%s/inbox/%s' "$PRAMA_BUS_DIR" "$(slugify "$1")"; }

# queue_push <target> <text>
queue_push() {
  local d f
  d=$(queue_dir "$1")
  mkdir -p "$d/new" "$d/cur"
  f=$(printf '%s/new/%s-%05d-%s.task' "$d" "$(date +%s%N)" "$$" "$RANDOM")
  printf '%s' "$2" > "$f.tmp" && mv -f "$f.tmp" "$f"
}

# queue_pop <target> → prints the oldest task and removes it; returns 1 if empty.
# Safe with several concurrent consumers: only one rename of a given file succeeds.
queue_pop() {
  local d f claimed
  d=$(queue_dir "$1")
  [ -d "$d/new" ] || return 1
  mkdir -p "$d/cur"
  for f in "$d"/new/*.task; do
    [ -f "$f" ] || continue
    claimed="$d/cur/$(basename "$f").$$"
    if mv "$f" "$claimed" 2>/dev/null; then
      cat "$claimed"
      rm -f "$claimed"
      return 0
    fi
  done
  return 1
}

queue_len() {
  local d n=0 f
  d=$(queue_dir "$1")
  for f in "$d"/new/*.task; do [ -f "$f" ] && (( n++ )); done
  printf '%d' "$n"
}

queue_clear() { rm -rf "$PRAMA_BUS_DIR"/inbox/* 2>/dev/null || true; }

# ── Event log (JSON Lines) ──────────────────────────────────────────────────
json_escape() {
  local s=${1:-} out='' c i
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  if [[ "$s" == *[$'\x01'-$'\x1f']* ]]; then
    for ((i = 0; i < ${#s}; i++)); do
      c=${s:i:1}
      if [[ "$c" == [$'\x01'-$'\x1f'] ]]; then
        printf -v c '\\u%04x' "'$c"
      fi
      out+=$c
    done
    s=$out
  fi
  printf '%s' "$s"
}

# bus_event <event> <from> <to> <text> [rc]
bus_event() {
  local ev=$1 from=$2 to=$3 text=$4 rc=${5:-}
  local line
  line=$(printf '{"ts":"%s","event":"%s","from":"%s","to":"%s","text":"%s"%s}' \
    "$(date -Iseconds)" "$(json_escape "$ev")" "$(json_escape "$from")" "$(json_escape "$to")" \
    "$(json_escape "$text")" "${rc:+,\"rc\":$rc}")
  # flock keeps concurrent writers from interleaving long lines
  {
    command -v flock >/dev/null 2>&1 && flock 9
    printf '%s\n' "$line" >&9
  } 9>>"$PRAMA_BUS_DIR/events.jsonl"
}

# ── Process telemetry (one ps snapshot shared by every helper) ──────────────
declare -gA PS_COMM=() PS_CPU=() PS_RSS=() PS_ETIME=() PS_PPID=() PS_CHILDREN=() PS_TTY=()
PS_SNAP_AT=0
AGENT_COMM_RE='^(claude|agy|opencode|node)$'
AGENT_BIN_RE='^(claude|agy|opencode)$'

snapshot_procs() {
  local now=${EPOCHSECONDS:-$(date +%s)}
  (( now - PS_SNAP_AT < 2 )) && return 0
  PS_COMM=() PS_CPU=() PS_RSS=() PS_ETIME=() PS_PPID=() PS_CHILDREN=() PS_TTY=()
  local pid ppid cpu rss etime tty comm
  while read -r pid ppid cpu rss etime tty comm; do
    [ -z "$pid" ] && continue
    PS_COMM[$pid]=$comm
    PS_CPU[$pid]=$cpu
    PS_RSS[$pid]=$rss
    PS_ETIME[$pid]=$etime
    PS_PPID[$pid]=$ppid
    PS_TTY[$pid]=$tty
    PS_CHILDREN[$ppid]+="$pid "
  done < <(ps -eo pid=,ppid=,%cpu=,rss=,etime=,tty=,comm= 2>/dev/null)
  PS_SNAP_AT=$now
}

# Finds the agent process under a pane (breadth-first over descendants).
resolve_pane_agent_pid() {
  local pane_pid=$1 queue p c depth=0
  snapshot_procs
  queue=("$pane_pid")
  while (( ${#queue[@]} )) && (( depth < 4 )); do
    local next=()
    for p in "${queue[@]}"; do
      [[ "${PS_COMM[$p]:-}" =~ $AGENT_COMM_RE ]] && { printf '%s' "$p"; return 0; }
      for c in ${PS_CHILDREN[$p]:-}; do next+=("$c"); done
    done
    queue=("${next[@]}")
    (( depth++ ))
  done
  printf '%s' "$pane_pid"
}

# Prints "cpu|rssMB|etime|comm" for a pid.
get_proc_metrics() {
  local pid=$1
  snapshot_procs
  if [ -z "$pid" ] || [ -z "${PS_COMM[$pid]:-}" ]; then
    printf '0.0|0MB|0s|dead'
    return 0
  fi
  printf '%s|%sMB|%s|%s' "${PS_CPU[$pid]:-0.0}" "$(( ${PS_RSS[$pid]:-0} / 1024 ))" "${PS_ETIME[$pid]:-0s}" "${PS_COMM[$pid]}"
}

get_host_telemetry() {
  local l1="0.00" _rest mem_total=0 mem_avail=0 k v _u
  [ -r /proc/loadavg ] && read -r l1 _rest < /proc/loadavg
  if [ -r /proc/meminfo ]; then
    while read -r k v _u; do
      case "$k" in
        MemTotal:) mem_total=$v ;;
        MemAvailable:) mem_avail=$v; break ;;
      esac
    done < /proc/meminfo
  fi
  local pct=0
  (( mem_total > 0 )) && pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
  printf '%s|%d|%d' "$l1" "$pct" "$(( (mem_total - mem_avail) / 1024 ))"
}

# Classifies what a session is doing from its last screen lines. Prints a STATE word:
# DEAD | BOT | STANDBY | DAEMON | WORKING | SHELL | READY
detect_session_state() {
  local s=$1 pane_dead=${2:-0} pcmd=${3:-}
  if [ "$pane_dead" = "1" ]; then printf 'DEAD'; return; fi
  if [ "$s" = "${PRAMA_SESSION_PREFIX}-telegram-bot" ]; then printf 'BOT'; return; fi
  local snippet
  snippet=$(tmx_capture "$s" 12)
  if [[ "$snippet" == *"PRAMA_STANDBY"* || "$snippet" == *"AGENTE FINALIZADO"* ]]; then printf 'STANDBY'
  elif [[ "$snippet" == *"PRAMA_DAEMON"* ]]; then printf 'DAEMON'
  elif [[ "$snippet" =~ esc\ to\ interrupt|Esc\ to\ cancel|Thinking|Working|Running…|Synthesizing ]]; then printf 'WORKING'
  elif session_block_info "$s" "$snippet" >/dev/null; then printf 'BLOCKED'
  elif [[ "$pcmd" =~ ^(bash|sh|zsh|fish)$ ]] && ! session_has_agent_process "$s"; then printf 'SHELL'
  else printf 'READY'
  fi
}

# Screen patterns of a blocked agent (login, auth, quota, trust dialog, model picker…).
# Only the last lines are inspected and only when the agent is not working, so text the agent
# prints about these topics while coding does not count. Order matters: first match wins.
BLOCK_PATTERNS=(
  'login|please run /login|run /login to|not logged in|select login method|login required|log in to continue'
  'auth|invalid api key|authentication_error|authentication failed|oauth token has expired|token has expired|missing authentication header|no auth credentials|unauthorized|api key not valid'
  'credit|credit balance is too low|credits balance is too low|out of credits|insufficient credits|insufficient balance|payment required|billing'
  'limit|usage limit reached|hit your limit|limit will reset|rate limit|rate_limit|too many requests|quota exceeded|individual quota|quota reached|resource_exhausted|overloaded'
  'trust|do you trust the files|trust this folder|project you created or one you trust'
  'model|model not found|model_not_found|unrecognized_model|issue with the selected model|not a valid model|select model|choose a model'
)

# screen_block_reason <text> → prints "reason|matching line"; returns 1 when nothing matches.
screen_block_reason() {
  local text=$1 entry reason pats line low
  local -a lines=()
  # Ignore messages typed into the agent (prompt echo "> …", prama's own [TAREA/ALERTA…] texts):
  # they quote problems, they are not the agent being blocked.
  mapfile -t lines < <(printf '%s\n' "$text" | strip_ansi_stream | grep -v '^[[:space:]]*$' \
    | grep -vE '^[[:space:]│|]*[>❯›]|\[(ALERTA PRAMA|PRAMA|TAREA|REPORTE|BROADCAST)' | tail -n 8)
  for entry in "${BLOCK_PATTERNS[@]}"; do
    reason=${entry%%|*} pats=${entry#*|}
    for line in "${lines[@]}"; do
      low=${line,,}
      if [[ "$low" =~ $pats ]]; then
        line=${line#"${line%%[![:space:]│|>]*}"}
        printf '%s|%s' "$reason" "${line:0:140}"
        return 0
      fi
    done
  done
  return 1
}

strip_ansi_stream() { sed -E 's/\x1b\[[0-9;?]*[ -\/]*[@-~]//g; s/\x1b\][^\x07]*\x07//g'; }

# session_block_info <session> [snippet] → "reason|detail"; returns 1 when the agent is not blocked.
# Hook-reported health (deterministic) wins; the screen is the fallback for dialogs that appear
# before hooks run (login, trust, model picker) and for CLIs without hooks.
session_block_info() {
  local s=$1 snippet=${2-}
  if [ "$(health_get "$s" HEALTH)" = blocked ]; then
    local reason ts
    reason=$(health_get "$s" REASON error) ts=$(health_get "$s" TS 0)
    # Transient failures (quota windows, overload, server errors) expire: the next prompt
    # either works or fails again and re-reports. Auth/credit/model need a human or a change.
    if [[ "$reason" =~ ^(limit|error)$ ]] && (( ${EPOCHSECONDS:-$(date +%s)} - ts > ${PRAMA_BLOCK_TTL:-900} )); then
      :
    else
      printf '%s|%s' "$reason" "$(health_get "$s" DETAIL)"
      return 0
    fi
  fi
  [ -n "$snippet" ] || snippet=$(tmx_capture "$s" 12)
  screen_block_reason "$snippet"
}

# True when an agent CLI runs somewhere under the session's pane. The supervisor runs the agent
# as a child of bash, so tmux's pane_current_command alone always says "bash".
session_has_agent_process() {
  local ppid apid
  ppid=$(tmx display-message -p -t "=$1:" '#{pane_pid}' 2>/dev/null) || return 1
  snapshot_procs   # populate the cache in this shell; the $(...) below runs in a subshell
  apid=$(resolve_pane_agent_pid "$ppid")
  [[ "${PS_COMM[$apid]:-}" =~ $AGENT_COMM_RE ]]
}

# Agent processes running outside the prama tmux server (no SSH-drop protection).
# Prints "pid|tty|comm|cpu%|MB|etime|cwd" lines.
find_unmanaged_agents() {
  snapshot_procs
  declare -A in_prama=()
  local tp
  while IFS= read -r tp; do [ -n "$tp" ] && in_prama[$tp]=1; done < <(tmx list-panes -a -F '#{pane_pid}' 2>/dev/null)
  local pid p hops managed
  for pid in "${!PS_COMM[@]}"; do
    [[ "${PS_COMM[$pid]}" =~ $AGENT_BIN_RE ]] || continue
    managed=0; p=$pid; hops=0
    while [ -n "$p" ] && (( p > 1 && hops < 32 )); do
      [ -n "${in_prama[$p]:-}" ] && { managed=1; break; }
      p=${PS_PPID[$p]:-}
      (( hops++ ))
    done
    (( managed )) && continue
    # skip children of another agent process (sub-processes of the same CLI)
    [[ "${PS_COMM[${PS_PPID[$pid]:-0}]:-}" =~ $AGENT_BIN_RE ]] && continue
    printf '%s|%s|%s|%s%%|%sMB|%s|%s\n' "$pid" "${PS_TTY[$pid]}" "${PS_COMM[$pid]}" "${PS_CPU[$pid]}" \
      "$(( ${PS_RSS[$pid]:-0} / 1024 ))" "${PS_ETIME[$pid]}" "$(readlink -f "/proc/$pid/cwd" 2>/dev/null || echo '?')"
  done
}
