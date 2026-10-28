#!/usr/bin/env bash
# lib/core.sh — Configuration, Responsive TrueColor Box Engine, Telemetry & Tmux Setup
# Licensed under the Apache License, Version 2.0

shopt -s extglob

PRAMA_BRAND="${PRAMA_BRAND:-PRAMA AGENT}"
PRAMA_SESSION_PREFIX="${PRAMA_SESSION_PREFIX:-prama}"
PRAMA_WORKTREE_COPY_FILES="${PRAMA_WORKTREE_COPY_FILES:-.env .env.local .mcp.json}"
PRAMA_SKIP_PERMISSIONS="${PRAMA_SKIP_PERMISSIONS:-1}"
PRAMA_DEFAULT_REMOTE="${PRAMA_DEFAULT_REMOTE:-0}"
PRAMA_DEFAULT_ROLE="${PRAMA_DEFAULT_ROLE:-executor}"
PRAMA_BUS_DIR="${PRAMA_BUS_DIR:-/tmp/prama-bus}"
PRAMA_DISCOVER_ROOTS="${PRAMA_DISCOVER_ROOTS:-/opt $HOME}"

AGENTS=(claude agy kimi gemini qwen)
AGENT_DESCS=(
  "Claude Code (Anthropic / API)"
  "Agy (Antigravity CLI)"
  "Kimi Code (Moonshot AI)"
  "Gemini CLI (Google AI)"
  "Qwen Code (Alibaba / OR)"
)

ZONES=()
ZONE_DIRS=()
ZONE_DESCS=()

CONFIG_FILES=(
  "/etc/prama-agent/config.env"
  "${XDG_CONFIG_HOME:-$HOME/.config}/prama-agent/config.env"
)
PROVIDER_FILES=(
  "/etc/prama-agent/providers.env"
  "${XDG_CONFIG_HOME:-$HOME/.config}/prama-agent/providers.env"
)
TELEGRAM_FILES=(
  "/etc/prama-agent/telegram.env"
  "${XDG_CONFIG_HOME:-$HOME/.config}/prama-agent/telegram.env"
)

for _cfg in "${CONFIG_FILES[@]}"; do
  # shellcheck disable=SC1090
  [ -f "$_cfg" ] && source "$_cfg"
done

for _prv in "${PROVIDER_FILES[@]}"; do
  # shellcheck disable=SC1090
  [ -f "$_prv" ] && source "$_prv"
done

for _tg in "${TELEGRAM_FILES[@]}"; do
  # shellcheck disable=SC1090
  [ -f "$_tg" ] && source "$_tg"
done

if [ "${#ZONES[@]}" -eq 0 ]; then
  for _root in $PRAMA_DISCOVER_ROOTS; do
    [ -d "$_root" ] || continue
    for _d in "$_root"/*; do
      [ -d "$_d/.git" ] || continue
      _bname=$(basename "$_d")
      ZONES+=("$_bname")
      ZONE_DIRS+=("$_d")
      ZONE_DESCS+=("git · $_bname")
    done
  done
  if [ "${#ZONES[@]}" -eq 0 ]; then
    ZONES=("workspace")
    ZONE_DIRS+=("$PWD")
    ZONE_DESCS+=("current working directory")
  fi
fi

mkdir -p "$PRAMA_BUS_DIR/inbox" "$PRAMA_BUS_DIR/state" 2>/dev/null || true

# ── TrueColor & 256-Color Design System ─────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_NEON=$'\e[38;2;56;189;248m'       # Sky Cyan (#38bdf8)
  C_INDIGO=$'\e[38;2;129;140;248m'    # Indigo (#818cf8)
  C_LIVE=$'\e[38;2;52;211;153m'       # Emerald (#34d399)
  C_BRASS=$'\e[38;2;251;191;36m'      # Amber (#fbbf24)
  C_ERR=$'\e[38;2;248;113;113m'       # Coral Red (#f87171)
  C_PURP=$'\e[38;2;192;132;252m'      # Purple (#c084fc)
  C_MUTED=$'\e[38;5;243m'             # Slate Gray
  C_BORDER=$'\e[38;5;239m'            # Box border dark gray
  C_BORDER_HI=$'\e[38;2;56;189;248m'  # Active box border cyan
  C_DIM=$'\e[2m'
  C_BOLD=$'\e[1m'
  C_OFF=$'\e[0m'
  BAR_ON=$'\e[48;2;30;58;95m\e[38;2;240;249;255m\e[1m'
  KEY_BADGE=$'\e[48;5;236m\e[38;2;56;189;248m\e[1m'
  IS_TTY=1
else
  C_NEON='' C_INDIGO='' C_LIVE='' C_BRASS='' C_ERR='' C_PURP='' C_MUTED=''
  C_BORDER='' C_BORDER_HI='' C_DIM='' C_BOLD='' C_OFF=''
  BAR_ON='' KEY_BADGE=''
  IS_TTY=0
fi

# Reads true terminal dimensions directly from /dev/tty (works inside subshells & Termius mobile)
refresh_dimensions() {
  local _rows=24 _cols=80
  if [ -n "${PRAMA_COLS:-}" ]; then
    COLS=$PRAMA_COLS
  elif [ -r /dev/tty ]; then
    read -r _rows _cols < <(stty size </dev/tty 2>/dev/null || echo "24 80")
    COLS=${_cols:-80}
  elif [ -t 1 ]; then
    COLS=$(tput cols 2>/dev/null || echo 80)
  else
    COLS=84
  fi
  (( COLS > 100 )) && COLS=100
  (( COLS < 40 )) && COLS=40
  if (( COLS <= 70 )); then
    W=$(( COLS - 2 ))
    IS_COMPACT=1
  else
    W=$(( COLS - 4 ))
    IS_COMPACT=0
  fi
}
refresh_dimensions

die()      { printf ' %s✖ ERROR:%s %s\n' "$C_ERR" "$C_OFF" "$1" >&2; exit 1; }
ok()       { printf ' %s✔ OK:%s %s\n' "$C_LIVE" "$C_OFF" "$1"; }
warn()     { printf ' %s▲ AVISO:%s %s\n' "$C_BRASS" "$C_OFF" "$1"; }
info_msg() { printf ' %s✦ INFO:%s %s\n' "$C_NEON" "$C_OFF" "$1"; }

is_in() {
  local x=$1 e; shift
  for e in "$@"; do [ "$e" = "$x" ] && return 0; done
  return 1
}

repeat_char() {
  local ch=$1 count=$2 out='' i
  for ((i = 0; i < count; i++)); do out+="$ch"; done
  printf '%s' "$out"
}

json_escape() {
  local s=${1:-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# Renders TrueColor RGB linear gradient text
gradient_text() {
  local txt=$1 r1=${2:-56} g1=${3:-189} b1=${4:-248} r2=${5:-52} g2=${6:-211} b2=${7:-153}
  if (( ! IS_TTY )); then
    printf '%s' "$txt"
    return 0
  fi
  local len=${#txt} i ch r g b out=''
  (( len == 0 )) && return 0
  for ((i = 0; i < len; i++)); do
    ch="${txt:i:1}"
    if (( len > 1 )); then
      r=$(( r1 + (r2 - r1) * i / (len - 1) ))
      g=$(( g1 + (g2 - g1) * i / (len - 1) ))
      b=$(( b1 + (b2 - b1) * i / (len - 1) ))
    else
      r=$r1; g=$g1; b=$b1
    fi
    out+=$'\e[1;38;2;'"${r};${g};${b}m${ch}"
  done
  out+="$C_OFF"
  printf '%s' "$out"
}

# Zero-fork host telemetry reader from /proc/loadavg and /proc/meminfo
get_host_telemetry() {
  local l1="0.00" _rest mem_total=0 mem_avail=0 k v _u
  if [ -r /proc/loadavg ]; then
    read -r l1 _rest < /proc/loadavg
  fi
  if [ -r /proc/meminfo ]; then
    while read -r k v _u; do
      case "$k" in
        MemTotal:) mem_total=$v ;;
        MemAvailable:) mem_avail=$v; break ;;
      esac
    done < /proc/meminfo
  fi
  local used_mb=$(( (mem_total - mem_avail) / 1024 ))
  local total_mb=$(( mem_total / 1024 ))
  local pct=0
  (( total_mb > 0 )) && pct=$(( used_mb * 100 / total_mb ))
  if (( IS_COMPACT )); then
    printf 'CPU %s · RAM %d%%' "$l1" "$pct"
  else
    printf 'LOAD %s · RAM %dM/%dM (%d%%)' "$l1" "$used_mb" "$total_mb" "$pct"
  fi
}

draw_gauge() {
  local val=${1%.*} width=${2:-5} filled i out=''
  val=${val:-0}
  (( val > 100 )) && val=100
  (( val < 0 )) && val=0
  filled=$(( (val * width + 49) / 100 ))
  (( val > 0 && filled == 0 )) && filled=1
  for ((i = 0; i < width; i++)); do
    if (( i < filled )); then out+="▰"; else out+="▱"; fi
  done
  printf '%s' "$out"
}

# ── Closed Box-Drawing Primitives (Responsive & Exact Column Alignment) ─────
box_top() {
  local title=${1:-} right=${2:-} border_col=${3:-$C_BORDER}
  local inner=$(( W - 2 ))
  local eol=""
  (( IS_TTY )) && eol=$'\e[K'
  if [ -z "$title" ] && [ -z "$right" ]; then
    printf ' %s╭%s╮%s%s\n' "$border_col" "$(repeat_char '─' "$inner")" "$C_OFF" "$eol"
    return
  fi
  if (( IS_COMPACT )) && (( ${#title} + ${#right} + 7 > inner )); then
    right=""
  fi
  local t_len=${#title} r_len=${#right}
  if [ -n "$right" ]; then
    local max_t=$(( inner - r_len - 7 ))
    if (( t_len > max_t && max_t > 4 )); then
      title="${title:0:max_t-1}…"
      t_len=${#title}
    fi
    local pad=$(( inner - t_len - r_len - 6 ))
    (( pad < 1 )) && pad=1
    printf ' %s╭─%s %s%s%s %s%s%s %s%s%s %s─╮%s%s\n' \
      "$border_col" "$C_OFF" "$C_BOLD$C_NEON" "$title" "$C_OFF" \
      "$border_col" "$(repeat_char '─' "$pad")" "$C_OFF" \
      "$C_MUTED" "$right" "$C_OFF" "$border_col" "$C_OFF" "$eol"
  else
    local max_t2=$(( inner - 4 ))
    if (( t_len > max_t2 && max_t2 > 4 )); then
      title="${title:0:max_t2-1}…"
      t_len=${#title}
    fi
    local pad2=$(( inner - t_len - 3 ))
    (( pad2 < 1 )) && pad2=1
    printf ' %s╭─%s %s%s%s %s%s╮%s%s\n' \
      "$border_col" "$C_OFF" "$C_BOLD$C_NEON" "$title" "$C_OFF" \
      "$border_col" "$(repeat_char '─' "$pad2")" "$C_OFF" "$eol"
  fi
}

box_sep() {
  local border_col=${1:-$C_BORDER}
  local inner=$(( W - 2 ))
  local eol=""
  (( IS_TTY )) && eol=$'\e[K'
  printf ' %s├%s┤%s%s\n' "$border_col" "$(repeat_char '─' "$inner")" "$C_OFF" "$eol"
}

box_row() {
  local border_col=${1:-$C_BORDER}
  local content=${2:-}
  local inner=$(( W - 2 ))
  local max_vis=$(( inner - 2 ))
  local eol=""
  (( IS_TTY )) && eol=$'\e[K'
  local plain='' _rest=$content
  while [[ $_rest == *$'\e['* ]]; do
    plain+=${_rest%%$'\e['*}
    _rest=${_rest#*$'\e['}
    _rest=${_rest#*m}
  done
  plain+=$_rest
  local vlen=${#plain}
  if (( vlen > max_vis )); then
    content="${plain:0:max_vis-1}…"
    vlen=$max_vis
  fi
  local pad=$(( max_vis - vlen ))
  (( pad < 0 )) && pad=0
  printf ' %s│%s %s%*s %s│%s%s\n' "$border_col" "$C_OFF" "$content" "$pad" "" "$border_col" "$C_OFF" "$eol"
}

box_bottom() {
  local hint=${1:-} border_col=${2:-$C_BORDER}
  local inner=$(( W - 2 ))
  local eol=""
  (( IS_TTY )) && eol=$'\e[K'
  if [ -z "$hint" ]; then
    printf ' %s╰%s╯%s%s\n' "$border_col" "$(repeat_char '─' "$inner")" "$C_OFF" "$eol"
  else
    local max_h=$(( inner - 4 ))
    if (( ${#hint} > max_h && max_h > 4 )); then
      hint="${hint:0:max_h-1}…"
    fi
    local h_len=${#hint}
    local pad=$(( inner - h_len - 3 ))
    (( pad < 1 )) && pad=1
    printf ' %s╰%s %s%s%s %s─╯%s%s\n' \
      "$border_col" "$(repeat_char '─' "$pad")" "$C_MUTED" "$hint" "$C_OFF" "$border_col" "$C_OFF" "$eol"
  fi
}

# ── Tmux Configuration Management (With 1-Tap & 1-Key Return to Menu) ───────
TMUX_CONF_MARKER="# prama-agent-managed-v5.1"

ensure_tmux_conf() {
  local force=${1:-0}
  local conf="$HOME/.tmux.conf"
  if (( force )) || [ ! -f "$conf" ] || ! grep -q "$TMUX_CONF_MARKER" "$conf" 2>/dev/null; then
    [ -f "$conf" ] && cp -f "$conf" "${conf}.bak" 2>/dev/null || true
    cat <<'EOF' > "$conf"
# prama-agent-managed-v5.1
# High-performance tmux profile for Prama Agent (Smartphone Termius + Desktop)

set -g mouse on
set -g history-limit 50000
set -g default-terminal "xterm-256color"
set -ga terminal-overrides ",*256col*:Tc,xterm*:Tc,tmux*:Tc"
set -s escape-time 0
setw -g aggressive-resize on
set -g set-clipboard on
set -g focus-events on
setw -g mode-keys vi
set -g detach-on-destroy on

# 1-Key & 1-Tap Touch Return to Prama Agent Main Menu (without stopping the agent!)
bind -n C-g detach-client
bind -n M-b detach-client
bind -n M-m detach-client
bind m detach-client
bind -n MouseDown1StatusLeft detach-client

# Top border shows clear instructions on how to return to the menu
set -g pane-border-status top
set -g pane-border-format " #[bold,fg=colour42][⬅ Toca barra inf. o Ctrl+g = MENU]#[default] · #[bold,fg=colour75]#{pane_title}#[default] "
set -g pane-border-style fg=colour238
set -g pane-active-border-style fg=colour75

# Bottom status bar acts as a clickable button on Termius Smartphone
set -g status-interval 5
set -g status-style bg=colour235,fg=colour252
set -g status-left "#[bg=colour31,fg=colour255,bold] ⬅ MENU PRAMA (Ctrl+g) #[default] "
set -g status-left-length 28
set -g status-right " #[fg=colour75,bold]#S#[default] #[fg=colour42]●#[default] %H:%M "
set -g status-right-length 36
EOF
    if command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>/dev/null; then
      tmux source-file "$conf" 2>/dev/null || true
    fi
  fi
}

# ── Process & Telemetry Inspection Helpers ──────────────────────────────────
# Single `ps` snapshot shared by all helpers (avoids 3-5 forks per session on every redraw)
declare -gA PS_COMM=() PS_CPU=() PS_RSS=() PS_ETIME=() PS_CHILDREN=()
PS_SNAP_AT=0
snapshot_procs() {
  local now=${EPOCHSECONDS:-$(date +%s)}
  (( now - PS_SNAP_AT < 2 )) && return 0
  PS_COMM=() PS_CPU=() PS_RSS=() PS_ETIME=() PS_CHILDREN=()
  local pid ppid cpu rss etime comm
  while read -r pid ppid cpu rss etime comm; do
    [ -z "$pid" ] && continue
    PS_COMM[$pid]=$comm
    PS_CPU[$pid]=$cpu
    PS_RSS[$pid]=$rss
    PS_ETIME[$pid]=$etime
    PS_CHILDREN[$ppid]+="$pid "
  done < <(ps -eo pid=,ppid=,%cpu=,rss=,etime=,comm= 2>/dev/null)
  PS_SNAP_AT=$now
}

resolve_pane_agent_pid() {
  local pane_pid=$1 child
  snapshot_procs
  if [[ "${PS_COMM[$pane_pid]:-}" =~ ^(claude|agy|gemini|qwen|kimi|opencode|python3)$ ]]; then
    echo "$pane_pid"
    return 0
  fi
  for child in ${PS_CHILDREN[$pane_pid]:-}; do
    if [[ "${PS_COMM[$child]:-}" =~ ^(claude|agy|gemini|qwen|kimi|opencode|python3)$ ]]; then
      echo "$child"
      return 0
    fi
  done
  echo "$pane_pid"
}

get_proc_metrics() {
  local pid=$1
  snapshot_procs
  if [ -z "$pid" ] || [ -z "${PS_COMM[$pid]:-}" ]; then
    echo "0.0|0MB|0s|dead"
    return 0
  fi
  local rss=${PS_RSS[$pid]:-0}
  echo "${PS_CPU[$pid]:-0.0}|$(( rss / 1024 ))MB|${PS_ETIME[$pid]:-0s}|${PS_COMM[$pid]}"
}

detect_pane_activity_state() {
  local s_name=$1 pane_dead=$2 cmd=$3
  if [ "$pane_dead" = "1" ]; then
    echo "DEAD|$C_ERR"
    return 0
  fi
  if [[ "$s_name" == *telegram* ]]; then
    echo "BOT-24/7|$C_NEON$C_BOLD"
    return 0
  fi
  local snippet
  snippet=$(tmux capture-pane -p -t "$s_name" -S -12 2>/dev/null || true)
  if grep -qE "AGENTE FINALIZADO|Acción \[r/s" <<< "$snippet"; then
    echo "STANDBY|$C_BRASS"
  elif grep -qE "DAEMON_HEARTBEAT|CICLO DAEMON" <<< "$snippet"; then
    echo "DAEMON|$C_PURP"
  elif grep -qE "Synthesizing|Thinking|Thought for|Running|Waiting|esc to interrupt" <<< "$snippet"; then
    echo "WORKING|$C_LIVE$C_BOLD"
  elif [[ "$cmd" == "bash" || "$cmd" == "sh" || "$cmd" == "zsh" ]]; then
    echo "SHELL|$C_NEON"
  else
    echo "READY|$C_LIVE"
  fi
}

find_unmanaged_agents() {
  local tmux_pids=()
  if command -v tmux >/dev/null 2>&1; then
    while IFS= read -r tp; do
      [ -n "$tp" ] && tmux_pids+=("$tp")
    done < <(tmux list-panes -a -F "#{pane_pid}" 2>/dev/null || true)
  fi

  local pid comm tty cpu rss etime cwd
  while read -r pid cpu rss etime tty comm; do
    [ -z "$pid" ] && continue
    local p=$pid in_tmux=0
    while [ "$p" -gt 1 ] 2>/dev/null; do
      if is_in "$p" "${tmux_pids[@]:-}"; then
        in_tmux=1
        break
      fi
      p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ' || echo 1)
      [ -z "$p" ] && break
    done
    (( in_tmux )) && continue
    cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || echo "?")
    local mb=$(( ${rss:-0} / 1024 ))
    echo "$pid|$tty|$comm|${cpu}%|${mb}MB|$etime|$cwd"
  done < <(ps -eo pid=,%cpu=,rss=,etime=,tty=,comm= 2>/dev/null | awk '$6 ~ /^(claude|agy|gemini|qwen|kimi|opencode)$/ {print $1, $2, $3, $4, $5, $6}')
}
