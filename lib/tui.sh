#!/usr/bin/env bash
# lib/tui.sh — Interactive full-screen TUI: hub, new-agent wizard and reusable widgets
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
#
# Rendering model
#   Every screen renders into TUI_FRAME[row] (one exact-width ANSI string per terminal row).
#   tui_flush rewrites only the rows that changed since the previous flush, inside a DEC
#   synchronized-output block (\e[?2026h … \e[?2026l). A cursor move therefore repaints two list
#   rows plus the preview, and the live refresh tick (read -t) repaints only what changed.
#   Layout is derived from the terminal size on every render (no fixed row numbers); SIGWINCH
#   triggers a full repaint. The hot path uses the fork-free ui_* helpers from ui.sh.
#
# Layouts:  wide (≥100 cols) list + live preview side by side · medium (70-99) stacked ·
#           compact (<70, phones) stacked with short labels.
#
# Public API (contracts in docs/ARCHITECTURE.md):
#   tui_main                                   interactive hub (entry point)
#   tui_select_box <step> <title> <labels> <metas> <avail> <targets>
#                                              sets CHOICE; returns 0 selected, 2 back
#   tui_prompt <label> <varname> [default]     line input; 0 = non-empty answer
#   tui_confirm <question> [danger] [yes_lbl]  0 = yes (y/Y, and s/S in Spanish)
#   tui_alert <title> <text> [err|ok|info]     modal message
#   tui_toast <ok|err|info> <text>             transient footer message (~3 s)
#   tui_enter_screen / tui_leave_screen, launch_fzf_cockpit, prompt_send_task_modal,
#   prompt_worktree_modal, cycle_role / cycle_perm_mode / cycle_profile

# ── State ───────────────────────────────────────────────────────────────────
TUI_ACTIVE=0
IN_TUI=${IN_TUI:-0}
TUI_STTY_SAVED=''
TUI_MOUSE=${PRAMA_TUI_MOUSE:-1}
TUI_TICK=${PRAMA_TUI_TICK:-2}
TUI_RESIZED=0
TUI_FORCE_CLEAR=0
TUI_TC=80 TUI_TR=24 TUI_MODE=wide
TUI_NOW=0 TUI_LAST_COLLECT=0
TUI_CRUMBS='' TUI_LIST_CRUMBS=''
TUI_FILTER='' TUI_FILTER_EDIT=0
TUI_SEL=0 TUI_SEL_KEY='' TUI_SCROLL=0 TUI_VH=1 TUI_QUIT=0
TUI_HOST='' TUI_TG_RUNNING=0 TUI_FEEDBACK=0 TUI_NWORK=0 TUI_LAST_ERR='' TUI_PROMPT_CANCELLED=0
TOAST_MSG='' TOAST_KIND=info TOAST_UNTIL=0
KEY='' MX=0 MY=0 MB=0 ZT=''
MODAL_TOP=1 MODAL_LEFT=1 MODAL_W=0 MODAL_H=0 MODAL_HINT=''
HUB_NS=0
HUB_ACTIONS=(new swarm teams cockpit telegram doctor prefs)
declare -ga TUI_FRAME=() TUI_PREV=() TUI_ZONES=() TUI_KEYS=() TUI_KEYS_R=() HUB_ITEMS=()
declare -ga S_NAME=() S_PID=() S_DEAD=() S_CMD=() S_ATT=() S_PATH=() S_STATE=() S_ROLE=()
declare -ga S_CPU=() S_MEM=() S_ETIME=() S_COMM=() PV=() LP=() RP=()
declare -ga S_TREE=() S_TCOLOR=() S_NMEM=()
declare -gA TUI_HIT=() TUI_ROLE_CACHE=() TUI_MCACHE=() TUI_VISIBLE=() TUI_TLABEL=() TUI_OBJ=() TUI_PLAN=() TUI_PLKEY=()

# ── Styles (attribute-only fallbacks keep focus visible under NO_COLOR) ─────
tui_styles() {
  if (( IS_TERM )); then
    T_OFF=$'\e[0m' T_BOLD=$'\e[1m' T_DIM=$'\e[2m' T_REV=$'\e[7m'
  else
    T_OFF='' T_BOLD='' T_DIM='' T_REV=''
  fi
  if (( HAS_COLOR )); then
    T_SEL=$BAR_ON T_HEAD=$C_HEAD_BG
    T_WARN="$C_WARN_BG$C_WARN_FG"$'\e[1m'
  else
    T_SEL=$T_REV T_HEAD='' T_WARN="$T_REV$T_BOLD"
  fi
}
tui_styles

tui_now() { printf -v TUI_NOW '%(%s)T' -1; }

_tui_locale_restore() {
  if declare -F restore_locale >/dev/null; then restore_locale; fi
  return 0
}

# ── Terminal control ────────────────────────────────────────────────────────
tui_enter_screen() {
  if (( IS_TERM )); then printf '\e[?1049h\e[?25l\e[?7l\e[2J\e[H'; fi
  return 0
}

tui_leave_screen() {
  if (( IS_TERM )); then printf '\e[?1000l\e[?1006l\e[?7h\e[?25h\e[?1049l'; fi
  return 0
}

tui_term_raw()    { stty -echo -icanon min 1 time 0 </dev/tty 2>/dev/null || true; }
tui_term_cooked() { if [ -n "$TUI_STTY_SAVED" ]; then stty "$TUI_STTY_SAVED" </dev/tty 2>/dev/null || true; fi; }
tui_mouse_on()    { if (( TUI_MOUSE )); then printf '\e[?1000h\e[?1006h'; fi; return 0; }
tui_mouse_off()   { printf '\e[?1000l\e[?1006l'; }

tui_flush_input() {
  local _c
  while IFS= read -rsn1 -t 0.01 _c; do :; done
  return 0
}

tui_measure() {
  refresh_dimensions
  TUI_TC=${TERM_COLS:-$COLS}
  (( TUI_TC > 250 )) && TUI_TC=250
  TUI_TR=${ROWS:-24}
  if (( TUI_TC >= 100 )); then TUI_MODE=wide
  elif (( TUI_TC >= 70 )); then TUI_MODE=medium
  else TUI_MODE=compact; fi
}

tui_setup() {
  TUI_ACTIVE=1 IN_TUI=1
  TUI_STTY_SAVED=$(stty -g </dev/tty 2>/dev/null) || TUI_STTY_SAVED=''
  trap 'tui_cleanup' EXIT
  trap 'tui_cleanup; exit 130' INT TERM HUP
  trap 'TUI_RESIZED=1' WINCH
  tui_styles
  tui_enter_screen
  tui_term_raw
  tui_mouse_on
  tui_measure
  tui_invalidate
}

# Idempotent: safe to call from EXIT/INT traps and normal exit paths.
tui_cleanup() {
  (( TUI_ACTIVE )) || return 0
  TUI_ACTIVE=0 IN_TUI=0
  tui_mouse_off
  tui_term_cooked
  tui_leave_screen
}

# Hard suspend: back to the normal screen (tmux attach, less, fzf).
tui_suspend() { tui_mouse_off; tui_term_cooked; tui_leave_screen; }
tui_resume()  { tui_enter_screen; tui_term_raw; tui_mouse_on; tui_flush_input; tui_measure; tui_invalidate; }

# Soft suspend: stay on the alternate screen with a cooked tty (external menus that print/read).
tui_soft_suspend() { tui_mouse_off; tui_term_cooked; printf '\e[?7h\e[2J\e[H\e[?25h'; }
tui_soft_resume()  { printf '\e[?25l\e[?7l'; tui_term_raw; tui_mouse_on; tui_flush_input; tui_measure; tui_invalidate; }

# ── Input ───────────────────────────────────────────────────────────────────
# tui_read_key [timeout] → KEY: UP DOWN LEFT RIGHT HOME END PGUP PGDN DEL TAB BTAB ENTER ESC
#   BACKSPACE SPACE MOUSE (MB MX MY) TIMEOUT EOF NONE, or the literal character.
tui_read_key() {
  local t=${1:-} c='' rc=0 seq ch
  KEY=NONE
  if [ -n "$t" ]; then IFS= read -rsn1 -t "$t" c || rc=$?
  else IFS= read -rsn1 c || rc=$?; fi
  if (( rc > 128 )); then KEY=TIMEOUT; return 0; fi
  if (( rc != 0 )) && [ -z "$c" ]; then KEY=EOF; return 0; fi
  case $c in
    $'\e')
      if ! IFS= read -rsn1 -t 0.03 c; then KEY=ESC; return 0; fi
      if [[ $c != '[' && $c != 'O' ]]; then KEY=ESC; return 0; fi
      seq=$c
      while IFS= read -rsn1 -t 0.03 ch; do
        seq+=$ch
        [[ $ch == [@-~] ]] && break
        (( ${#seq} > 32 )) && break
      done
      case $seq in
        '[A'|'OA') KEY=UP ;;
        '[B'|'OB') KEY=DOWN ;;
        '[C'|'OC') KEY=RIGHT ;;
        '[D'|'OD') KEY=LEFT ;;
        '[H'|'OH'|'[1~'|'[7~') KEY=HOME ;;
        '[F'|'OF'|'[4~'|'[8~') KEY=END ;;
        '[5~') KEY=PGUP ;;
        '[6~') KEY=PGDN ;;
        '[3~') KEY=DEL ;;
        '[Z')  KEY=BTAB ;;
        '[<'*M)
          seq=${seq#'[<'}; seq=${seq%M}
          IFS=';' read -r MB MX MY <<< "$seq"
          [[ $MB =~ ^[0-9]+$ && $MX =~ ^[0-9]+$ && $MY =~ ^[0-9]+$ ]] && KEY=MOUSE ;;
        '[M')   # legacy X10 mouse: three raw bytes follow
          local b x y
          if IFS= read -rsn3 -t 0.03 seq && (( ${#seq} == 3 )); then
            printf -v b '%d' "'${seq:0:1}"; printf -v x '%d' "'${seq:1:1}"; printf -v y '%d' "'${seq:2:1}"
            MB=$(( b - 32 )) MX=$(( x - 32 )) MY=$(( y - 32 ))
            (( MB != 3 )) && KEY=MOUSE
          fi ;;
        *) KEY=NONE ;;
      esac ;;
    ''|$'\n'|$'\r') KEY=ENTER ;;
    $'\x7f'|$'\b')  KEY=BACKSPACE ;;
    $'\t')          KEY=TAB ;;
    ' ')            KEY=SPACE ;;
    *)              KEY=$c ;;
  esac
  return 0
}

# Waits for a key with the live-refresh timeout (shortened while a toast is visible).
_tui_wait_key() {
  local t=$TUI_TICK rem
  tui_now
  if (( TOAST_UNTIL > TUI_NOW )); then
    rem=$(( TOAST_UNTIL - TUI_NOW ))
    (( rem < t )) && t=$rem
    (( t < 1 )) && t=1
  fi
  tui_read_key "$t"
  if (( TUI_RESIZED )); then
    TUI_RESIZED=0
    tui_measure
    tui_invalidate
    TUI_HOST=$(host_stats_label)
    [ "$KEY" = TIMEOUT ] && KEY=RESIZE
  fi
}

# Token of the clickable zone (footer keys, settings chips) under MX/MY → ZT.
_tui_zone_token() {
  local z r c1 c2 t
  ZT=''
  for z in "${TUI_ZONES[@]}"; do
    read -r r c1 c2 t <<< "$z"
    if (( MY == r && MX >= c1 && MX <= c2 )); then ZT=$t; return 0; fi
  done
  return 1
}

# ── Frame buffer ────────────────────────────────────────────────────────────
tui_invalidate() { TUI_PREV=(); TUI_FORCE_CLEAR=1; }
tui_frame_new()  { TUI_FRAME=(); TUI_HIT=(); TUI_ZONES=(); }

tui_flush() {
  local out=$'\e[?2026h' r line
  if (( TUI_FORCE_CLEAR )); then out+=$'\e[0m\e[2J'; TUI_FORCE_CLEAR=0; fi
  for ((r = 1; r <= TUI_TR; r++)); do
    line=${TUI_FRAME[r]-}
    if [[ -n ${TUI_PREV[r]+x} && ${TUI_PREV[r]} == "$line" ]]; then continue; fi
    out+=$'\e['"$r"$';1H\e[0m\e[2K'"$line"$'\e[0m'
    TUI_PREV[r]=$line
  done
  out+=$'\e[?2026l'
  printf '%s' "$out"
}

_tui_blank() { printf -v UI_S '%*s' "$1" ''; }

# ── Box builders (strings of exactly <w> columns, result in TB) ────────────
# _tb_top <w> <title> <title_style> <right> <border_color>
_tb_top() {
  local w=$1 title=$2 ts=$3 right=$4 bc=$5 rw=0 tw fill max_t
  if [ -z "$title" ] && [ -z "$right" ]; then
    ui_repeat '─' $(( w - 2 )); TB="$bc╭$UI_S╮$T_OFF"; return
  fi
  if [ -n "$right" ]; then ui_width "$right"; rw=$UI_W; fi
  max_t=$(( w - 6 - (rw ? rw + 3 : 0) ))
  if (( rw && max_t < 8 )); then right='' rw=0; max_t=$(( w - 6 )); fi
  ui_trunc "$title" "$max_t"; title=$UI_S; tw=$UI_W
  if (( rw )); then
    fill=$(( w - tw - rw - 8 ))
    ui_repeat '─' "$fill"
    TB="$bc╭─$T_OFF $ts$title$T_OFF $bc$UI_S$T_OFF $C_MUTED$right$T_OFF $bc─╮$T_OFF"
  else
    fill=$(( w - tw - 5 ))
    ui_repeat '─' "$fill"
    TB="$bc╭─$T_OFF $ts$title$T_OFF $bc$UI_S╮$T_OFF"
  fi
}

# _tb_bot <w> <border_color> [hint]
_tb_bot() {
  local w=$1 bc=$2 hint=${3:-}
  if [ -z "$hint" ]; then ui_repeat '─' $(( w - 2 )); TB="$bc╰$UI_S╯$T_OFF"; return; fi
  ui_trunc "$hint" $(( w - 8 )); hint=$UI_S
  ui_repeat '─' $(( w - UI_W - 5 ))
  TB="$bc╰$UI_S$T_OFF $C_MUTED$hint$T_OFF $bc─╯$T_OFF"
}

# _tb_sep <w> <border_color> [label]
_tb_sep() {
  local w=$1 bc=$2 label=${3:-}
  if [ -z "$label" ]; then ui_repeat '─' $(( w - 2 )); TB="$bc├$UI_S┤$T_OFF"; return; fi
  ui_trunc "$label" $(( w - 8 )); label=$UI_S
  ui_repeat '─' $(( w - UI_W - 5 ))
  TB="$bc├─$T_OFF $C_MUTED$label$T_OFF $bc$UI_S┤$T_OFF"
}

# _tb_line <w> <border_color> <ansi_text> → "│ text │" (text fitted to w-4)
_tb_line() {
  ui_ansi_fit "$3" $(( $1 - 4 ))
  TB="$2│$T_OFF $UI_S $2│$T_OFF"
}

# _tui_wrap <plain> <width> → WRAP (word wrap; long words are hard-cut)
_tui_wrap() {
  local text=$1 width=$2 word line='' lw=0 ww
  WRAP=()
  (( width < 4 )) && width=4
  for word in $text; do
    ui_width "$word"; ww=$UI_W
    while (( ww > width )); do
      if [ -n "$line" ]; then WRAP+=("$line"); line='' lw=0; fi
      ui_trunc "$word" "$width"; WRAP+=("$UI_S")
      word=${word:$(( width - 1 ))}; ui_width "$word"; ww=$UI_W
    done
    if (( lw == 0 )); then line=$word lw=$ww
    elif (( lw + 1 + ww <= width )); then line+=" $word"; lw=$(( lw + 1 + ww ))
    else WRAP+=("$line"); line=$word lw=$ww; fi
  done
  [ -n "$line" ] && WRAP+=("$line")
  return 0
}

# ── Labels and small formatters ─────────────────────────────────────────────
_tui_short() { UI_S=${1#"${PRAMA_SESSION_PREFIX}"-}; }

# Row label: prefix and role words dropped (the role badge already says it).
_tui_display_name() {
  local s=${1#"${PRAMA_SESSION_PREFIX}"-} r
  for r in coordinator reader daemon; do s=${s#"$r"-}; done
  UI_S=$s
}

_tui_state_label() {
  case $1 in
    WORKING) _tv UI_S 'working' ;;
    READY)   _tv UI_S 'ready' ;;
    STANDBY) _tv UI_S 'waiting' ;;
    DAEMON)  _tv UI_S 'daemon' ;;
    SHELL)   _tv UI_S 'shell' ;;
    DEAD)    _tv UI_S 'down' ;;
    BLOCKED) _tv UI_S 'blocked' ;;
    BOT)     _tv UI_S 'bot' ;;
    *)       UI_S='—' ;;
  esac
}

_tui_role_icon() {
  case $1 in
    coordinator) UI_S='❖' ;;
    reader)      UI_S='◉' ;;
    daemon)      UI_S='♺' ;;
    *)           UI_S='✦' ;;
  esac
}

_tui_role_short() {
  case $1 in
    coordinator) UI_S='❖ coord' ;;
    reader)      UI_S='◉ read' ;;
    daemon)      UI_S='♺ daem' ;;
    executor)    UI_S='✦ exec' ;;
    *)           UI_S="• ${1:0:5}" ;;
  esac
}

_tui_role_color() {
  case $1 in
    coordinator) UI_C=$C_PURP ;;
    reader)      UI_C=$C_NEON ;;
    daemon)      UI_C=$C_BRASS ;;
    *)           UI_C=$C_INDIGO ;;
  esac
}

_tui_role_desc() {
  case $1 in
    coordinator) _tv UI_S 'plans and hands out work' ;;
    reader)      _tv UI_S 'read-only (forces PLAN)' ;;
    daemon)      _tv UI_S 'works through its queue in a loop' ;;
    *)           _tv UI_S 'carries out tasks' ;;
  esac
}

# _tui_perm_label <mode> → UI_S (label) UI_C (color) UI_D (description)
_tui_perm_label() {
  case $1 in
    yolo) UI_S='▲ YOLO' UI_C="$C_ERR$T_BOLD"; _tv UI_D 'never asks for confirmation' ;;
    plan) UI_S='◉ PLAN' UI_C=$C_NEON; _tv UI_D 'read-only / planning' ;;
    *)    UI_S='● ASK'  UI_C=$C_LIVE; _tv UI_D 'confirms every action' ;;
  esac
}

_tui_mem_fmt() {
  local m=${1%MB}
  [[ $m =~ ^[0-9]+$ ]] || { UI_S='—'; return; }
  if (( m >= 1024 )); then printf -v UI_S '%d.%dG' $(( m / 1024 )) $(( (m % 1024) * 10 / 1024 ))
  else UI_S="${m}M"; fi
}

_tui_menu_key_label() { _tui_key_label "${PRAMA_MENU_KEY:-M-m}"; }

# _tui_key_label <tmux key> → UI_S readable (M-a → Alt+a, C-b → Ctrl+b)
_tui_key_label() {
  local k=$1
  k=${k//M-/Alt+}; k=${k//C-/Ctrl+}
  UI_S=$k
}

# _tui_keycap <key> <label> [danger] → KC (ansi) KCW (width). Destructive keys get the error color.
_tui_keycap() {
  ui_width "$1"; local kw=$UI_W lc=$C_MUTED
  [ -n "${3:-}" ] && lc=$C_ERR
  ui_width "$2"
  if (( HAS_COLOR )); then KC="$KEY_BADGE $1 $T_OFF $lc$2$T_OFF"
  else KC="[$1] $2"; fi
  KCW=$(( kw + 3 + UI_W ))
}

# Keybar builders: _tk <key> <msgid> [token] [danger] (left) · _tkr <key> <msgid> [token] (right).
_tk()  { local l; _tv l "$2"; TUI_KEYS+=("$1|$l|${3:-}|${4:-}"); }
_tkr() { local l; _tv l "$2"; TUI_KEYS_R+=("$1|$l|${3:-}"); }

tui_toast() {
  TOAST_KIND=${1:-info} TOAST_MSG=${2:-}
  tui_now
  TOAST_UNTIL=$(( TUI_NOW + 3 ))
}

# ── Shared chrome: header, crumbs, footer ───────────────────────────────────
_tui_header() {
  local row=$1 tc=$TUI_TC H=$T_HEAD brand=${PRAMA_BRAND:-PRAMA AGENT} ver="v${VERSION:-?}"
  [ "$TUI_MODE" = compact ] && brand=${brand%% *}
  local host=${HOSTNAME:-}; host=${host%%.*}
  # shellcheck disable=SC2086  # UI_GRAD holds the six gradient components
  ui_gradient "$brand" ${UI_GRAD:-56 189 248 192 132 252}; local gb=$UI_S
  ui_width "$brand"; local lw=$(( 4 + UI_W + 1 + ${#ver} ))
  local hostp=''
  [ "$TUI_MODE" != compact ] && [ -n "$host" ] && hostp="  $host"
  local n=${#S_NAME[@]} counts='' cw=0
  if (( n > 0 )); then
    if [ "$TUI_MODE" = compact ]; then counts="● $n"
    else
      _tv counts '● %d active' "$n"
      if (( TUI_NWORK > 0 )); then local wk; _tv wk ' · %d working' "$TUI_NWORK"; counts+=$wk; fi
    fi
    ui_width "$counts"; cw=$(( UI_W + 3 ))
  fi
  local tele=$TUI_HOST tw
  ui_width "$tele"; tw=$(( UI_W + 1 ))
  ui_width "$hostp"; local hw=$UI_W
  if (( lw + hw + cw + tw + 1 > tc )); then hostp='' hw=0; fi
  if (( lw + cw + tw + 1 > tc )); then counts='' cw=0; fi
  if (( lw + tw + 1 > tc )); then tele='' tw=0; fi
  local gap=$(( tc - lw - hw - cw - tw ))
  (( gap < 0 )) && gap=0
  _tui_blank "$gap"; local pad=$UI_S
  local line="$H $C_NEON◆$H $T_BOLD$gb$T_OFF$H $C_MUTED$ver$hostp$H$pad"
  [ -n "$counts" ] && line+="$C_LIVE$counts$H   "
  [ -n "$tele" ] && line+="$C_MUTED$tele$H "
  TUI_FRAME[row]="$line$T_OFF"
}

# _tui_crumbs_line <row> <ansi>
_tui_crumbs_line() {
  ui_ansi_fit " $2" "$TUI_TC"
  TUI_FRAME[$1]=$UI_S
}

# Settings for the next launch (hub row 2). Chips are clickable on wide terminals.
_tui_settings_line() {
  local row=$1 tc=$TUI_TC
  _tui_perm_label "$PERM_MODE"; local pl=$UI_S pc=$UI_C
  _tui_role_icon "$ROLE"; local rl="$UI_S $ROLE"
  _tui_role_color "$ROLE"; local rc=$UI_C
  local rem=off; (( REMOTE )) && rem=on
  local wt=${WORKTREE:-—} bgl
  if (( BG )); then _tv bgl 'background'; else _tv bgl 'open'; fi
  if [ "$TUI_MODE" = compact ]; then
    local s=" $rc$rl$T_OFF $C_MUTED·$T_OFF $pc$pl$T_OFF $C_MUTED·$T_OFF $PROFILE"
    [ -n "$WORKTREE" ] && s+=" $C_MUTED·$T_OFF $C_PURP⎇ $WORKTREE$T_OFF"
    (( BG )) && s+=" $C_MUTED· $bgl$T_OFF"
    _tui_crumbs_line "$row" "${s# }"
    return
  fi
  local n_role n_perm n_rem n_prof n_bg next
  _tv n_role 'Role'; _tv n_perm 'Permissions'; _tv n_rem 'Remote'; _tv n_prof 'Profile'; _tv n_bg 'On launch'
  local -a chips=("o|$n_role|$rl|$rc" "y|$n_perm|$pl|$pc" "e|$n_rem|$rem|$C_TEXT" "p|$n_prof|$PROFILE|$C_TEXT"
                  "w|Worktree|$wt|$C_PURP" "g|$n_bg|$bgl|$C_TEXT")
  local out=' ' used=1 chip k n v c cw
  if [ "$TUI_MODE" = wide ]; then
    _tv next 'Next agent ›'; ui_width "$next"
    out+="$C_MUTED$next$T_OFF "; used=$(( used + UI_W + 1 ))
  fi
  for chip in "${chips[@]}"; do
    k=${chip%%|*}; chip=${chip#*|}; n=${chip%%|*}; chip=${chip#*|}; v=${chip%%|*}; c=${chip#*|}
    ui_width "$n $v"; cw=$(( UI_W + 6 ))
    (( used + cw > tc )) && break
    TUI_ZONES+=("$row $(( used + 1 )) $(( used + cw - 2 )) $k")
    if (( HAS_COLOR )); then out+="$KEY_BADGE $k $T_OFF $C_MUTED$n$T_OFF $c$v$T_OFF  "
    else out+="[$k] $n $v  "; fi
    used=$(( used + cw ))
  done
  _tui_blank $(( tc - used )); out+=$UI_S
  TUI_FRAME[row]=$out
}

# Footer: toast (when active) or the contextual keybar from TUI_KEYS / TUI_KEYS_R ("key|label|token").
_tui_footer() {
  local row=$1 tc=$TUI_TC out=' ' used=1 item k l t rout='' rw=0
  local -a rz=()
  for item in "${TUI_KEYS_R[@]}"; do
    k=${item%%|*}; item=${item#*|}; l=${item%%|*}; t=${item#*|}; t=${t%%|*}
    _tui_keycap "$k" "$l"
    rz+=("$rw $KCW $t")
    rout+="$KC "; rw=$(( rw + KCW + 1 ))
  done
  tui_now
  if (( TOAST_UNTIL > TUI_NOW )) && [ -n "$TOAST_MSG" ]; then
    local ic col
    case $TOAST_KIND in
      ok)  ic='✔' col=$C_LIVE ;;
      err) ic='✖' col=$C_ERR ;;
      *)   ic='●' col=$C_NEON ;;
    esac
    (( tc - rw < 24 )) && { rout='' rw=0 rz=(); }
    ui_trunc "$TOAST_MSG" $(( tc - rw - 4 ))
    out=" $col$T_BOLD$ic $UI_S$T_OFF"; used=$(( 3 + UI_W ))
  else
    local dz
    for item in "${TUI_KEYS[@]}"; do
      k=${item%%|*}; item=${item#*|}; l=${item%%|*}; item=${item#*|}; t=${item%%|*}; dz=''
      [[ $item == *'|'* ]] && dz=${item#*|}
      _tui_keycap "$k" "$l" "$dz"
      (( used + KCW + 1 + rw > tc )) && break
      [ -n "$t" ] && TUI_ZONES+=("$row $(( used + 1 )) $(( used + KCW )) $t")
      out+="$KC "; used=$(( used + KCW + 1 ))
    done
  fi
  local gap=$(( tc - used - rw ))
  if (( gap < 0 )); then rout='' rw=0 rz=(); gap=$(( tc - used )); fi
  (( gap < 0 )) && gap=0
  local z off len
  for z in "${rz[@]}"; do
    read -r off len t <<< "$z"
    TUI_ZONES+=("$row $(( used + gap + off + 1 )) $(( used + gap + off + len )) $t")
  done
  _tui_blank "$gap"
  TUI_FRAME[row]="$out$UI_S$rout"
}

_tui_too_small() {
  local r msg
  _tv msg 'Window too small'
  for ((r = 1; r <= TUI_TR; r++)); do TUI_FRAME[r]=''; done
  ui_fit "$msg" "$TUI_TC"
  TUI_FRAME[$(( (TUI_TR + 1) / 2 ))]="$C_BRASS$UI_S$T_OFF"
}

# ── Modals (drawn on top of the current frame; the next flush repaints all) ─
# Repaints the current screen under a modal when it was invalidated (resize, return from a
# full-screen command). Each screen loop sets TUI_REDRAW_FN to its render function.
TUI_REDRAW_FN=''
_tui_redraw_bg() {
  if (( TUI_FORCE_CLEAR )) && [ -n "$TUI_REDRAW_FN" ] && declare -F "$TUI_REDRAW_FN" >/dev/null; then
    "$TUI_REDRAW_FN"
  fi
  return 0
}

# _tui_modal <border_color> <title> <width> <ansi_lines...>
_tui_modal() {
  local bc=$1 title=$2 w=$3 line top left r=0 out
  shift 3
  _tui_redraw_bg
  (( w > TUI_TC )) && w=$TUI_TC
  (( w < 20 )) && w=20
  local -a ml=("$@")
  local maxl=$(( TUI_TR - 2 ))
  (( maxl < 1 )) && maxl=1
  (( ${#ml[@]} > maxl )) && ml=("${ml[@]:0:maxl}")
  local h=$(( ${#ml[@]} + 2 ))
  top=$(( (TUI_TR - h) / 3 + 1 ))
  (( top < 2 && TUI_TR - h >= 2 )) && top=2
  (( top < 1 )) && top=1
  left=$(( (TUI_TC - w) / 2 + 1 ))
  MODAL_TOP=$top MODAL_LEFT=$left MODAL_W=$w MODAL_H=$h
  _tb_top "$w" "$title" "$T_BOLD$C_TEXT" "" "$bc"
  out=$'\e[?2026h\e[0m\e['"$top;${left}H$TB"
  for line in "${ml[@]}"; do
    r=$(( r + 1 ))
    ui_ansi_fit "$line" $(( w - 4 ))
    out+=$'\e['"$(( top + r ));${left}H$bc│$T_OFF $UI_S $bc│$T_OFF"
  done
  _tb_bot "$w" "$bc" "$MODAL_HINT"
  out+=$'\e['"$(( top + h - 1 ));${left}H$TB"$'\e[?2026l'
  printf '%s' "$out"
  tui_invalidate
}

# tui_alert <title> <text> [err|ok|info]
tui_alert() {
  local title=$1 text=$2 kind=${3:-err} bc=$C_NEON line
  [ "$kind" = err ] && bc=$C_ERR
  [ "$kind" = ok ] && bc=$C_LIVE
  if (( ! TUI_ACTIVE )); then printf ' %s\n %s\n' "$title" "$text" >&2; return 0; fi
  local w=$(( TUI_TC > 76 ? 72 : TUI_TC - 2 ))
  local -a lines=()
  ui_strip "$text"; text=$UI_S
  while IFS= read -r line; do
    _tui_wrap "$line" $(( w - 4 ))
    if (( ${#WRAP[@]} )); then lines+=("${WRAP[@]}"); else lines+=(""); fi
  done <<< "$text"
  local max=$(( TUI_TR - 5 ))
  (( max < 1 )) && max=1
  (( ${#lines[@]} > max )) && lines=("${lines[@]: -max}")
  local cl; _tv cl 'close'
  lines+=("" "$KEY_BADGE ↵ $T_OFF $C_MUTED$cl$T_OFF")
  local ic='●'
  [ "$kind" = err ] && ic='✖'
  [ "$kind" = ok ] && ic='✔'
  MODAL_HINT=''
  _tui_modal "$bc" "$ic $title" "$w" "${lines[@]}"
  while :; do
    tui_read_key 1
    case $KEY in
      TIMEOUT|NONE) (( TUI_RESIZED )) && { TUI_RESIZED=0; tui_measure; tui_invalidate; _tui_modal "$bc" "$ic $title" "$w" "${lines[@]}"; } ;;
      MOUSE) (( MB == 0 )) && break ;;
      *) break ;;
    esac
  done
  tui_invalidate
}

# tui_confirm <question> [danger:0|1] [yes_label] → 0 when the user answers yes
tui_confirm() {
  local q=$1 danger=${2:-0} yes=${3:-} ans='' yk=y no
  [ "$PRAMA_UI_LANG" = es ] && yk=s
  [ -n "$yes" ] || _tv yes 'Yes'
  _tv no 'No'
  if (( ! TUI_ACTIVE )); then
    printf ' %s [%s/N] ' "$q" "$yk" >&2
    IFS= read -r ans || return 1
    [[ $ans == [sSyY]* ]]
    return
  fi
  local bc=$C_NEON yc=$C_LIVE
  (( danger )) && { bc=$C_ERR; yc="$C_ERR$T_BOLD"; }
  local w=$(( TUI_TC > 64 ? 60 : TUI_TC - 2 ))
  _tui_wrap "$q" $(( w - 4 ))
  local -a lines=("${WRAP[@]}" "")
  _tui_keycap "$yk" "$yes"; local yw=$KCW
  local btn
  if (( HAS_COLOR )); then btn="$KEY_BADGE $yk $T_OFF $yc$yes$T_OFF     $KEY_BADGE N $T_OFF $C_MUTED$no$T_OFF"
  else btn="[$yk] $yes     [N] $no"; fi
  lines+=("$btn")
  _tv MODAL_HINT 'esc cancels'
  local title
  _tv title 'Confirm'
  (( danger )) && title="▲ $title"
  _tui_modal "$bc" "$title" "$w" "${lines[@]}"
  MODAL_HINT=''
  local brow=$(( MODAL_TOP + ${#lines[@]} )) bcol=$(( MODAL_LEFT + 2 )) rc=1
  while :; do
    tui_read_key 1
    case $KEY in
      TIMEOUT|NONE)
        if (( TUI_RESIZED )); then
          TUI_RESIZED=0; tui_measure; tui_invalidate
          _tui_modal "$bc" "$title" "$w" "${lines[@]}"
          brow=$(( MODAL_TOP + ${#lines[@]} )) bcol=$(( MODAL_LEFT + 2 ))
        fi
        continue ;;
      s|S|y|Y) rc=0 ;;
      MOUSE)
        (( MB == 0 )) || continue
        if (( MY == brow && MX >= bcol && MX < bcol + yw )); then rc=0; fi ;;
      *) rc=1 ;;
    esac
    break
  done
  tui_invalidate
  return "$rc"
}

# tui_prompt <label> <varname> [default] → 0 when the answer is non-empty.
# Line editing via readline (read -e) with a visible cursor; an empty answer cancels.
tui_prompt() {
  local _p_label=$1 _p_def=${3:-} _p_val='' _p_rc=0
  local -n _p_out=$2
  TUI_PROMPT_CANCELLED=0
  if (( ! TUI_ACTIVE )); then
    IFS= read -e -r -p " $_p_label: " -i "$_p_def" _p_val 2>/dev/tty || { TUI_PROMPT_CANCELLED=1; return 1; }
    _p_out=$_p_val
    [ -n "$_p_val" ]
    return
  fi
  local w=$(( TUI_TC > 76 ? 72 : TUI_TC ))
  local ph; _tv ph '↵ confirm · empty ↵ cancels'
  local -a lines=("" "" "$C_MUTED$ph$T_OFF")
  MODAL_HINT=''
  _tui_modal "$C_NEON" "$_p_label" "$w" "${lines[@]}"
  local row=$(( MODAL_TOP + 2 )) lead prompt
  _tui_blank $(( MODAL_LEFT - 1 )); lead=$UI_S
  prompt="$lead"$'\001'"$C_NEON"$'\002''│'$'\001'"$T_OFF$C_NEON$T_BOLD"$'\002'' › '$'\001'"$T_OFF"$'\002'
  tui_mouse_off
  tui_term_cooked
  printf '\e[%d;1H\e[?7h\e[?25h' "$row"
  trap 'TUI_PROMPT_CANCELLED=1' INT
  # readline draws on stderr: point it at the terminal even if stderr is redirected.
  IFS= read -e -r -p "$prompt" -i "$_p_def" _p_val 2>/dev/tty || _p_rc=1
  trap 'tui_cleanup; exit 130' INT
  (( TUI_PROMPT_CANCELLED )) && _p_rc=1
  printf '\e[?25l\e[?7l'
  tui_term_raw
  tui_mouse_on
  tui_invalidate
  if (( _p_rc )); then TUI_PROMPT_CANCELLED=1; return 1; fi
  _p_out=$_p_val
  [ -n "$_p_val" ]
}

# Keyboard help: sections of "keys|description" (built with _hs / _hk), two columns when the modal
# is wide enough, scrollable with ↑↓ when it does not fit (phones).
_hs() { local l; _tv l "$1"; HE+=("#$l"); }
_hk() { local l; _tv l "$2"; HE+=("$1|$l"); }

_tui_help_entries() {
  local mk nk ck
  _tui_menu_key_label; mk=$UI_S
  _tui_key_label "$PRAMA_NAV_KEY"; nk=$UI_S
  _tui_key_label "$PRAMA_COCKPIT_KEY"; ck=$UI_S
  HE=()
  _hs 'MOVE AROUND'
  _hk '↑↓ j k' 'move'
  _hk '↵ →' 'open / enter'
  _hk 'esc ←' 'back'
  _hk '/' 'filter the list'
  _hk '1-9' 'jump to an item'
  _hk 'q' 'quit (agents keep running)'
  _hs 'SELECTED AGENT'
  _hk 't' 'send it a task'
  _hk 'l' 'full logs'
  _hk 'c' 'its team cockpit'
  _hk 'r' 'restart (same conversation)'
  _hk 'x' 'close (asks first)'
  _hk 'f' 'fzf inspector'
  _hs 'TEAMS'
  _hk 's' 'new team'
  _hk 'm' 'manage teams'
  _hk '+' 'add agents to its team'
  _hk 'x' 'on a coordinator: close the team'
  _hs 'NEXT AGENT'
  _hk 'n' 'new agent'
  _hk 'o · y' 'role · permissions'
  _hk 'e · p' 'remote · LLM profile'
  _hk 'w · g' 'worktree · open or background'
  _hs 'INSIDE AN AGENT OR THE COCKPIT'
  _hk "$mk" 'back to this menu (◂ MENU)'
  _hk "$nk" 'agent list (☰)'
  _hk "$ck" 'team cockpit ⇄ agent (▦)'
  _hk 'Ctrl+b n/p' 'next / previous agent'
  _hk 'Ctrl+b z' 'zoom the focused pane'
  _hs 'MORE'
  _hk ',' 'preferences: language, theme'
  _hk '?' 'this help'
  _hk '⊙' 'tap: select · tap again: open'
}

# _tui_help_lines <w> → HL (ansi lines for a modal of width <w>)
_tui_help_lines() {
  local w=$1 e k d kw=4 cols=1 colw left='' n=0 K="$C_NEON$T_BOLD" O=$T_OFF
  HL=()
  (( w >= 76 )) && cols=2
  colw=$(( (w - 4) / cols ))
  for e in "${HE[@]}"; do
    [[ $e == '#'* ]] && continue
    ui_width "${e%%|*}"; (( UI_W + 1 > kw )) && kw=$(( UI_W + 1 ))
  done
  for e in "${HE[@]}" '#'; do
    if [[ $e == '#'* ]]; then
      [ -n "$left" ] && HL+=("$left")
      left='' n=0
      [ "$e" = '#' ] && break
      (( ${#HL[@]} )) && HL+=("")
      HL+=("$C_MUTED$T_BOLD${e#\#}$O")
      continue
    fi
    k=${e%%|*} d=${e#*|}
    ui_fit "$k" "$kw"; k=$UI_S
    ui_fit "$d" $(( colw - kw - 2 )); d=$UI_S
    if (( cols == 1 )); then HL+=(" $K$k$O $d"); continue; fi
    if (( n % 2 == 0 )); then left=" $K$k$O $d"
    else HL+=("$left $K$k$O $d"); left=''; fi
    n=$(( n + 1 ))
  done
}

_tui_help() {
  local w off=0 max=3 title hint redraw=1
  _tui_help_entries
  _tv title 'Keyboard shortcuts'
  while :; do
    if (( redraw )); then
      redraw=0 w=96
      (( w > TUI_TC )) && w=$TUI_TC
      _tui_help_lines "$w"
      max=$(( TUI_TR - 2 ))
      (( max < 3 )) && max=3
      if (( ${#HL[@]} > max )); then
        (( off > ${#HL[@]} - max )) && off=$(( ${#HL[@]} - max ))
        _tv hint '↑↓ scroll · any other key closes'
        MODAL_HINT=$hint
        _tui_modal "$C_NEON" "$title" "$w" "${HL[@]:off:max}"
      else
        off=0
        _tv MODAL_HINT 'any key closes'
        _tui_modal "$C_NEON" "$title" "$w" "${HL[@]}"
      fi
      MODAL_HINT=''
    fi
    tui_read_key 1
    case $KEY in
      TIMEOUT|NONE)
        if (( TUI_RESIZED )); then TUI_RESIZED=0; tui_measure; tui_invalidate; redraw=1; fi
        continue ;;
      UP|k) off=$(( off - 1 )) ;;
      DOWN|j) off=$(( off + 1 )) ;;
      PGUP) off=$(( off - max )) ;;
      PGDN|SPACE) off=$(( off + max )) ;;
      MOUSE)
        case $MB in
          64) off=$(( off - 2 )) ;;
          65) off=$(( off + 2 )) ;;
          0) break ;;
          *) continue ;;
        esac ;;
      *) break ;;
    esac
    (( off < 0 )) && off=0
    redraw=1
  done
  tui_invalidate
}

# ── Data collection (one tick) ──────────────────────────────────────────────
# Fork budget per tick: one tmux list-panes + host telemetry, a ps snapshot every
# second tick (CPU/RAM are then read fork-free from core's PS_* tables) and detect_session_state
# for the selected session plus a round-robin batch of TUI_STATE_BATCH others. A full refresh
# (tui_collect 1) recomputes everything (start-up); sessions never seen before are always computed.
TUI_STATE_BATCH=${PRAMA_TUI_STATE_BATCH:-1}
TUI_TICKN=0 TUI_RR=0 TUI_PS_DIRECT=-1

# _tui_proc_metrics <pane_pid> → M_CPU M_MEM M_ETIME M_COMM (same walk as resolve_pane_agent_pid)
_tui_proc_metrics() {
  local pane=$1 p c depth=0 found=''
  if (( TUI_PS_DIRECT < 0 )); then
    TUI_PS_DIRECT=0
    [[ $(declare -p PS_COMM PS_CHILDREN 2>/dev/null) == *"declare -A PS_COMM"*"declare -A PS_CHILDREN"* ]] && TUI_PS_DIRECT=1
  fi
  if (( ! TUI_PS_DIRECT )); then
    local a_pid
    a_pid=$(resolve_pane_agent_pid "$pane")
    IFS='|' read -r M_CPU M_MEM M_ETIME M_COMM <<< "$(get_proc_metrics "$a_pid")"
    return 0
  fi
  local -a queue=("$pane") next
  while (( ${#queue[@]} )) && (( depth < 4 )); do
    next=()
    for p in "${queue[@]}"; do
      if [[ ${PS_COMM[$p]:-} =~ ${AGENT_COMM_RE:-^$} ]]; then found=$p; break 2; fi
      for c in ${PS_CHILDREN[$p]:-}; do next+=("$c"); done
    done
    queue=("${next[@]}")
    depth=$(( depth + 1 ))
  done
  [ -n "$found" ] || found=$pane
  if [ -z "${PS_COMM[$found]:-}" ]; then M_CPU=0.0 M_MEM=0MB M_ETIME=0s M_COMM=dead; return 0; fi
  M_CPU=${PS_CPU[$found]:-0.0} M_MEM="$(( ${PS_RSS[$found]:-0} / 1024 ))MB" M_ETIME=${PS_ETIME[$found]:-0s} M_COMM=${PS_COMM[$found]}
}

# tui_collect [full:0|1]
tui_collect() {
  local full=${1:-0}
  tui_now
  TUI_LAST_COLLECT=$TUI_NOW
  TUI_TICKN=$(( TUI_TICKN + 1 ))
  # One tmux call gives every pane; sessions are filtered with the same predicate prama_sessions
  # uses (is_internal_session), in tmux's own (name) order. The active pane wins per session.
  local -A pinfo=()
  local -a order=()
  local name pid dead cmd att act path s
  while IFS='|' read -r name pid dead cmd att act path; do
    [ -n "$name" ] || continue
    [ -n "${pinfo[$name]+x}" ] || order+=("$name")
    if [ -z "${pinfo[$name]+x}" ] || [ "$act" = 11 ]; then
      pinfo[$name]="$pid|$dead|$cmd|$att|$path"
    fi
  done < <(tmx list-panes -a -F '#{session_name}|#{pane_pid}|#{pane_dead}|#{pane_current_command}|#{session_attached}|#{window_active}#{pane_active}|#{pane_current_path}' 2>/dev/null)
  TUI_TG_RUNNING=0
  [ -n "${pinfo[${PRAMA_SESSION_PREFIX}-telegram-bot]+x}" ] && TUI_TG_RUNNING=1
  TUI_FEEDBACK=$(feedback_open_count 2>/dev/null); TUI_FEEDBACK=${TUI_FEEDBACK:-0}

  # Teams first (coordinator, then the agents it launched), then anything else.
  local -A tdepth=() placed=()
  local -a torder=()
  local d
  TUI_TEAM_CACHE=$(prama_team_order 2>/dev/null)
  while IFS='|' read -r s d _; do
    [ -n "$s" ] && [ -n "${pinfo[$s]+x}" ] || continue
    torder+=("$s"); tdepth[$s]=$d; placed[$s]=1
  done <<< "$TUI_TEAM_CACHE"
  for s in "${order[@]}"; do [ -n "${placed[$s]:-}" ] || torder+=("$s"); done
  S_NAME=() S_PID=() S_DEAD=() S_CMD=() S_ATT=() S_PATH=() S_DEPTH=()
  for s in "${torder[@]}"; do
    is_internal_session "$s" && continue
    IFS='|' read -r pid dead cmd att path <<< "${pinfo[$s]}"
    S_NAME+=("$s") S_PID+=("$pid") S_DEAD+=("${dead:-0}") S_CMD+=("$cmd") S_ATT+=("${att:-0}") S_PATH+=("$path")
    S_DEPTH+=("${tdepth[$s]:-0}")
  done

  local n=${#S_NAME[@]} i st do_m=0 sel_s=''
  (( full || TUI_TICKN % 2 == 1 )) && do_m=1
  (( n > 0 && do_m )) && snapshot_procs
  [[ $TUI_SEL_KEY == s:* ]] && sel_s=${TUI_SEL_KEY#s:}
  # which sessions get a fresh state this tick
  local -A want=()
  if (( full )); then
    for ((i = 0; i < n && i < 40; i++)); do want[${S_NAME[i]}]=1; done
  else
    [ -n "$sel_s" ] && want[$sel_s]=1
    local k=0
    while (( n > 0 && k < TUI_STATE_BATCH && k < n )); do
      TUI_RR=$(( (TUI_RR + 1) % n ))
      want[${S_NAME[TUI_RR]}]=1
      k=$(( k + 1 ))
    done
  fi
  S_STATE=() S_ROLE=() S_CPU=() S_MEM=() S_ETIME=() S_COMM=()
  TUI_NWORK=0
  local old cpu mem etime comm
  for ((i = 0; i < n; i++)); do
    s=${S_NAME[i]}
    [ -n "${TUI_ROLE_CACHE[$s]+x}" ] || TUI_ROLE_CACHE[$s]=$(session_role "$s")
    S_ROLE[i]=${TUI_ROLE_CACHE[$s]}
    old=${TUI_MCACHE[$s]:-}
    IFS='|' read -r st cpu mem etime comm <<< "${old:-READY|0.0|0MB|-|?}"
    if [ "${S_DEAD[i]}" = 1 ]; then st=DEAD
    elif [ -z "$old" ] || [ -n "${want[$s]:-}" ] || [ "$st" = DEAD ]; then
      st=$(detect_session_state "$s" "${S_DEAD[i]}" "${S_CMD[i]}")
    fi
    if [ -z "$old" ] || (( do_m )); then
      (( do_m )) || snapshot_procs
      _tui_proc_metrics "${S_PID[i]}"
      cpu=$M_CPU mem=$M_MEM etime=$M_ETIME comm=$M_COMM
    fi
    TUI_MCACHE[$s]="$st|$cpu|$mem|$etime|$comm"
    S_STATE[i]=$st S_CPU[i]=$cpu S_MEM[i]=$mem S_ETIME[i]=$etime S_COMM[i]=$comm
    [ "$st" = WORKING ] && TUI_NWORK=$(( TUI_NWORK + 1 ))
  done
  _tui_team_tree
  TUI_HOST=$(host_stats_label)
}

# Team layout of the session list: S_TREE (T = coordinator, ├ / └ = its agents, '' = alone),
# S_TCOLOR (a color per team, so neighbouring teams never look alike) and S_NMEM (agents per team).
TUI_TEAM_COLORS=()
_tui_team_tree() {
  local n=${#S_NAME[@]} i j t=-1 c
  TUI_TEAM_COLORS=("$C_NEON" "$C_PURP" "$C_LIVE" "$C_BRASS" "$C_INDIGO")
  S_TREE=() S_TCOLOR=() S_NMEM=() TUI_NTEAMS=0
  for ((i = 0; i < n; i++)); do S_TREE[i]='' S_TCOLOR[i]='' S_NMEM[i]=0; done
  for ((i = 0; i < n; i++)); do
    if [ "${S_DEPTH[i]:-0}" = 0 ] && [ "${S_ROLE[i]}" = coordinator ]; then
      t=$(( t + 1 )); c=${TUI_TEAM_COLORS[t % ${#TUI_TEAM_COLORS[@]}]}
      S_TREE[i]=T S_TCOLOR[i]=$c
      for ((j = i + 1; j < n; j++)); do
        [ "${S_DEPTH[j]:-0}" = 1 ] || break
        S_TREE[j]='├' S_TCOLOR[j]=$c
      done
      S_NMEM[i]=$(( j - i - 1 )) TUI_NTEAMS=$(( t + 1 ))
      (( j > i + 1 )) && S_TREE[j-1]='└'
      [ -n "${TUI_TLABEL[${S_NAME[i]}]+x}" ] || TUI_TLABEL[${S_NAME[i]}]=$(team_label "${S_NAME[i]}")
    fi
  done
}

# _tui_preview <session> <lines> <width> → PV: exactly <lines> rows, ANSI kept, fitted to <width>.
# Cached per (session, size, tick) so cursor moves back and forth don't re-capture.
_tui_preview() {
  local s=$1 h=$2 w=$3 key="$1|$2|$3|$TUI_LAST_COLLECT"
  [ "$key" = "${TUI_PV_KEY:-}" ] && return 0
  TUI_PV_KEY=$key
  PV=()
  (( h > 0 )) || return 0
  local -a raw=()
  mapfile -t raw < <(tmx_capture "$s" "$h" 1)
  local end=${#raw[@]} i start
  while (( end > 0 )); do
    ui_strip "${raw[end-1]}"
    [[ -z ${UI_S//[[:space:]]/} ]] || break
    end=$(( end - 1 ))
  done
  if (( end == 0 )); then
    _tv UI_S '(no output yet)'; ui_fit "$UI_S" "$w"; PV+=("$C_MUTED$UI_S$T_OFF")
  else
    start=$(( end - h )); (( start < 0 )) && start=0
    for ((i = start; i < end; i++)); do ui_ansi_fit "${raw[i]}" "$w"; PV+=("$UI_S"); done
  fi
  _tui_blank "$w"
  while (( ${#PV[@]} < h )); do PV+=("$UI_S"); done
}

# _tui_preview_box <w> <h> <session> <title> <right> <hint> [meta_lines...] → RP (h rows)
_tui_preview_box() {
  local w=$1 h=$2 s=$3 title=$4 right=$5 hint=$6 line
  shift 6
  local cw=$(( w - 4 )) bc=$C_BORDER nm=$# ph
  RP=()
  ph=$(( h - 2 - (nm ? nm + 1 : 0) ))
  if (( ph < 2 && nm )); then nm=1; ph=$(( h - 4 )); fi
  if (( ph < 1 )); then nm=0; ph=$(( h - 2 )); fi
  _tb_top "$w" "$title" "$T_BOLD$C_TEXT" "$right" "$bc"; RP+=("$TB")
  if (( nm )); then
    for line in "${@:1:nm}"; do _tb_line "$w" "$bc" "$line"; RP+=("$TB"); done
    local lv; _tv lv 'live'
    _tb_sep "$w" "$bc" "$lv"; RP+=("$TB")
  fi
  _tui_preview "$s" "$ph" "$cw"
  for line in "${PV[@]}"; do RP+=("$bc│$T_OFF $line $bc│$T_OFF"); done
  _tb_bot "$w" "$bc" "$hint"; RP+=("$TB")
}

# _tui_text_box <w> <h> <title> <title_style> <hint> [ansi_lines...] → RP (h rows)
_tui_text_box() {
  local w=$1 h=$2 title=$3 ts=$4 hint=$5 line n=0
  shift 5
  local bc=$C_BORDER
  RP=()
  _tb_top "$w" "$title" "$ts" "" "$bc"; RP+=("$TB")
  for line in "$@"; do
    (( n >= h - 2 )) && break
    _tb_line "$w" "$bc" "$line"; RP+=("$TB"); n=$(( n + 1 ))
  done
  while (( n < h - 2 )); do _tb_line "$w" "$bc" ""; RP+=("$TB"); n=$(( n + 1 )); done
  _tb_bot "$w" "$bc" "$hint"; RP+=("$TB")
}

# ── Hub ─────────────────────────────────────────────────────────────────────
tui_hub_build_items() {
  HUB_ITEMS=()
  local i it f=${TUI_FILTER,,} found=-1
  for i in "${!S_NAME[@]}"; do
    if [ -n "$f" ] && [[ ${S_NAME[i],,} != *"$f"* && ${S_ROLE[i]} != *"$f"* ]]; then continue; fi
    HUB_ITEMS+=("s:$i")
  done
  HUB_NS=${#HUB_ITEMS[@]}
  for it in "${HUB_ACTIONS[@]}"; do HUB_ITEMS+=("a:$it"); done
  if [ -n "$TUI_SEL_KEY" ]; then
    for i in "${!HUB_ITEMS[@]}"; do
      it=${HUB_ITEMS[i]}
      [[ $it == s:* ]] && it="s:${S_NAME[${it#s:}]}"
      [ "$it" = "$TUI_SEL_KEY" ] && { found=$i; break; }
    done
  fi
  if (( found >= 0 )); then TUI_SEL=$found
  elif [ -z "$TUI_SEL_KEY" ]; then TUI_SEL=0
  elif [[ $TUI_SEL_KEY == s:* ]] && (( HUB_NS > 0 )); then
    (( TUI_SEL >= HUB_NS )) && TUI_SEL=$(( HUB_NS - 1 ))
  elif [[ $TUI_SEL_KEY == s:* ]]; then TUI_SEL=$HUB_NS
  fi
  (( TUI_SEL >= ${#HUB_ITEMS[@]} )) && TUI_SEL=$(( ${#HUB_ITEMS[@]} - 1 ))
  (( TUI_SEL < 0 )) && TUI_SEL=0
  _tui_hub_sel_key
}

_tui_hub_sel_key() {
  local it=${HUB_ITEMS[TUI_SEL]-}
  if [[ $it == s:* ]]; then TUI_SEL_KEY="s:${S_NAME[${it#s:}]}"; else TUI_SEL_KEY=$it; fi
}

# Column plan for session rows of content width <cw> → HC_* (0 = hidden)
# Names keep priority on phones; the CPU gauge appears once the name still gets ≥14 (wide) / ≥20.
_tui_hub_cols() {
  local avail=$(( $1 - 6 )) min=12 cpu_min=20
  [ "$TUI_MODE" = wide ] && cpu_min=14
  HC_ROLE=0 HC_STATE=0 HC_CPU=0 HC_MEM=0
  (( avail - 8 >= min ))      && { HC_ROLE=7;  avail=$(( avail - 8 )); }
  (( avail - 10 >= min ))     && { HC_STATE=9; avail=$(( avail - 10 )); }
  (( avail - 10 >= cpu_min )) && { HC_CPU=9;   avail=$(( avail - 10 )); }
  (( avail - 6 >= 20 ))       && { HC_MEM=5;   avail=$(( avail - 6 )); }
  HC_NAME=$avail
}

# _tui_srow <session_index> <selected> → SR (content row, width from _tui_hub_cols)
_tui_srow() {
  local i=$1 sel=$2 base=$T_OFF mark=' ' st sc nc R name
  if (( sel )); then base=$T_SEL; mark='▸'; fi
  R=$T_OFF$base
  st=${S_STATE[i]}; state_color "$st"; sc=$UI_S
  nc=$C_TEXT
  [ "$st" = DEAD ] && nc=$C_MUTED
  (( sel )) && nc=$T_BOLD
  local tr=${S_TREE[i]:-} tc=${S_TCOLOR[i]:-} lead=''
  case $tr in
    T)  # Coordinator row = the team: "▍zone · team  (n)" in the team's color.
        local lbl=${TUI_TLABEL[${S_NAME[i]}]:-} cnt=''
        [ -n "$lbl" ] || { _tui_display_name "${S_NAME[i]}"; lbl=$UI_S; }
        (( ${S_NMEM[i]:-0} )) && cnt=" (${S_NMEM[i]})"
        # The team label also takes the role column: the ▍ bar already says "coordinator".
        ui_fit "$lbl$cnt" $(( HC_NAME - 2 + (HC_ROLE ? HC_ROLE + 1 : 0) )); name=$UI_S
        lead="$tc▍$R "; nc="$tc$T_BOLD" ;;
    ├|└)
        _tui_display_name "${S_NAME[i]}"
        local coord short=$UI_S j
        for ((j = i - 1; j >= 0; j--)); do [ "${S_TREE[j]}" = T ] && { coord=${S_NAME[j]}; break; }; done
        # Agents named after their team (prama-<zone>-<team>-agy) show only the last part.
        [ -n "${coord:-}" ] && [[ ${S_NAME[i]} == "${coord%-coord}-"* ]] && short=${S_NAME[i]#"${coord%-coord}-"}
        ui_fit "$short" $(( HC_NAME - 2 )); name=$UI_S
        lead="$tc$tr$R " ;;
    *)  _tui_display_name "${S_NAME[i]}"; ui_fit "$UI_S" "$HC_NAME"; name=$UI_S ;;
  esac
  SR="$base $C_NEON$mark$R $sc●$R $lead$nc$name$R"
  if (( HC_ROLE )) && [ "$tr" != T ]; then
    _tui_role_short "${S_ROLE[i]}"; ui_fit "$UI_S" 7; _tui_role_color "${S_ROLE[i]}"
    SR+=" $UI_C$UI_S$R"
  fi
  if (( HC_STATE )); then _tui_state_label "$st"; ui_fit "$UI_S" 9; SR+=" $sc$UI_S$R"; fi
  if (( HC_CPU )); then
    local c=${S_CPU[i]%.*} gc=$C_LIVE pct
    [[ $c =~ ^[0-9]+$ ]] || c=0
    (( c >= 50 )) && gc=$C_BRASS
    (( c >= 85 )) && gc=$C_ERR
    ui_gauge "$c" 4; printf -v pct '%3d%%' "$c"
    SR+=" $gc$UI_S$R $C_MUTED$pct$R"
  fi
  if (( HC_MEM )); then
    _tui_mem_fmt "${S_MEM[i]}"; local m; printf -v m '%5s' "$UI_S"
    SR+=" $C_MUTED$m$R"
  fi
  SR+=" $T_OFF"
}

_tui_action_meta() {
  case $1 in
    new)      A_ICON='✚'; _tv A_LABEL 'New agent'; _tv A_DESC '%s in a zone' "${AGENTS[*]}" ;;
    swarm)    A_ICON='❖'; _tv A_LABEL 'New team'; _tv A_DESC 'coordinator + N agents in a zone' ;;
    teams)    A_ICON='▤'; _tv A_LABEL 'Teams'; _tv A_DESC 'manage teams: cockpit, message, add agents, close'
              (( TUI_NTEAMS > 0 )) && _tv A_DESC '%d team(s) running · manage, message, grow, close' "$TUI_NTEAMS" ;;
    cockpit)  A_ICON='▦'; A_LABEL='Cockpit'; _tv A_DESC 'watch a team live, split screen' ;;
    telegram) A_ICON='➤'; A_LABEL='Telegram'; _tv A_DESC '24/7 bot: control everything from your phone'
              (( TUI_TG_RUNNING )) && _tv A_DESC 'bot running · control from your phone' ;;
    doctor)   A_ICON='✱'; A_LABEL='Doctor'; _tv A_DESC 'server diagnosis and repair'
              (( TUI_FEEDBACK > 0 )) && _tv A_DESC '%d unreviewed bug report(s) from agents' "$TUI_FEEDBACK" ;;
    prefs)    A_ICON='⚙'; _tv A_LABEL 'Preferences'; _tv A_DESC 'language %s · theme %s' "$PRAMA_LANG_NAME" "$UI_THEME" ;;
  esac
}

# _tui_arow <action_id> <selected> <cw> → SR
_tui_arow() {
  local sel=$2 cw=$3 base=$T_OFF mark=' ' R lab desc lw=20
  if (( sel )); then base=$T_SEL; mark='▸'; fi
  R=$T_OFF$base
  _tui_action_meta "$1"
  local dw=$(( cw - 6 - lw - 1 ))
  # Phones: the label alone reads better than a description cut to a few characters.
  if (( dw < 10 )) || [ "$TUI_MODE" = compact ]; then
    ui_fit "$A_LABEL" $(( cw - 6 )); lab=$UI_S
    SR="$base $C_NEON$mark$R $C_NEON$A_ICON$R $T_BOLD$lab$R $T_OFF"
  else
    ui_fit "$A_LABEL" "$lw"; lab=$UI_S
    ui_fit "$A_DESC" "$dw"; desc=$UI_S
    SR="$base $C_NEON$mark$R $C_NEON$A_ICON$R $T_BOLD$lab$R $C_MUTED$desc$R $T_OFF"
  fi
}

# _tui_empty_lines <vh> <cw> → EMPTY (empty-state block, vertically centered)
_tui_empty_lines() {
  local vh=$1 cw=$2 line lw left r
  local -a msg
  local t1 t2 t3
  if [ -n "$TUI_FILTER" ]; then
    _tv t1 'No matches for "%s"' "$TUI_FILTER"; _tv t2 'esc clears the filter'
    msg=("$C_MUTED○$T_OFF  $T_BOLD$t1$T_OFF" "" "$C_MUTED$t2$T_OFF")
  else
    local kb="$KEY_BADGE n $T_OFF" ks="$KEY_BADGE s $T_OFF"
    (( HAS_COLOR )) || { kb='[n]'; ks='[s]'; }
    _tv t1 'No agents running'; _tv t2 '%s an agent  ·  %s a team' "$kb" "$ks"
    _tv t3 'They keep running even if you close the terminal'
    msg=("$C_MUTED○$T_OFF  $T_BOLD$t1$T_OFF" "" "$t2" "$C_MUTED$t3$T_OFF")
    if (( ZONES_DISCOVERED )); then _tv t1 'First time:'; msg+=("" "$C_MUTED$t1 ${T_OFF}prama-agent setup"); fi
  fi
  if (( vh < ${#msg[@]} )); then
    local -a keep=()
    for line in "${msg[@]}"; do [ -n "$line" ] && keep+=("$line"); done
    msg=("${keep[@]:0:vh}")
  fi
  EMPTY=()
  local top=$(( (vh - ${#msg[@]}) / 2 ))
  _tui_blank "$cw"; local blank=$UI_S
  for ((r = 0; r < top; r++)); do EMPTY+=("$blank"); done
  for line in "${msg[@]}"; do
    ui_strip "$line"; ui_width "$UI_S"; lw=$UI_W
    left=$(( (cw - lw) / 2 )); (( left < 1 )) && left=1
    _tui_blank "$left"
    ui_ansi_fit "$UI_S$line" "$cw"; EMPTY+=("$UI_S")
  done
  while (( ${#EMPTY[@]} < vh )); do EMPTY+=("$blank"); done
}

# _tui_hub_list_panel <w> <h> <row0> → LP (h rows); sessions scroll, actions pinned at the bottom
_tui_hub_list_panel() {
  local w=$1 h=$2 row0=$3 cw=$(( $1 - 2 )) ns=$HUB_NS na=${#HUB_ACTIONS[@]} r j bc=$C_BORDER_HI
  LP=()
  local vh=$(( h - 3 - na ))
  (( vh < 1 )) && vh=1
  TUI_VH=$vh
  if (( TUI_SEL < ns )); then
    (( TUI_SEL < TUI_SCROLL )) && TUI_SCROLL=$TUI_SEL
    (( TUI_SEL >= TUI_SCROLL + vh )) && TUI_SCROLL=$(( TUI_SEL - vh + 1 ))
  fi
  (( TUI_SCROLL > ns - vh )) && TUI_SCROLL=$(( ns - vh ))
  (( TUI_SCROLL < 0 )) && TUI_SCROLL=0
  local right title
  if (( TUI_FILTER_EDIT )); then right="/$TUI_FILTER▏"
  elif [ -n "$TUI_FILTER" ]; then _tv right '/%s · %d of %d' "$TUI_FILTER" "$ns" "${#S_NAME[@]}"
  elif (( ns > vh )); then _tv right '%d-%d of %d' $(( TUI_SCROLL + 1 )) $(( TUI_SCROLL + vh )) "$ns"
  else right=$ns; fi
  _tv title 'Agents and teams'
  _tb_top "$w" "$title" "$T_BOLD$C_NEON" "$right" "$bc"; LP+=("$TB")
  _tui_hub_cols "$cw"
  TUI_VISIBLE=()
  if (( ns == 0 )); then
    _tui_empty_lines "$vh" "$cw"
    for ((r = 0; r < vh; r++)); do LP+=("$bc│$T_OFF${EMPTY[r]}$bc│$T_OFF"); done
  else
    _tui_blank "$cw"; local blank=$UI_S si
    for ((r = 0; r < vh; r++)); do
      j=$(( TUI_SCROLL + r ))
      if (( j < ns )); then
        si=${HUB_ITEMS[j]#s:}
        _tui_srow "$si" $(( j == TUI_SEL ))
        TUI_HIT[$(( row0 + 1 + r ))]=$j
        TUI_VISIBLE[${S_NAME[si]}]=1
      else SR=$blank; fi
      LP+=("$bc│$T_OFF$SR$bc│$T_OFF")
    done
  fi
  _tv title 'Actions'
  _tb_sep "$w" "$bc" "$title"; LP+=("$TB")
  for ((r = 0; r < na; r++)); do
    j=$(( ns + r ))
    _tui_arow "${HUB_ACTIONS[r]}" $(( j == TUI_SEL )) "$cw"
    TUI_HIT[$(( row0 + 2 + vh + r ))]=$j
    LP+=("$bc│$T_OFF$SR$bc│$T_OFF")
  done
  local hint=''
  (( ns > TUI_SCROLL + vh )) && _tv hint '▼ %d more' $(( ns - TUI_SCROLL - vh ))
  _tb_bot "$w" "$bc" "$hint"; LP+=("$TB")
}

# Body text for the selected hub action → BODY (ansi lines, wrapped to <cw>)
_tui_action_body() {
  local id=$1 cw=$2 p K="$C_NEON$T_BOLD" O=$T_OFF M=$C_MUTED t
  BODY=()
  _tui_para() { _tui_wrap "$1" "$cw"; BODY+=("${WRAP[@]}"); }
  # _tui_bul <key-or-•> <msgid> [args] — one bullet line
  _tui_bul() { _tv t "$2" "${@:3}"; BODY+=("  $K$1$O  $t"); }
  case $id in
    new)
      _tv t 'Launches a coding agent inside tmux, in one of your zones (git repositories). It keeps running if SSH drops.'; _tui_para "$t"
      _tv t 'Settings for the next agent:'; BODY+=("" "$M$t$O")
      local n_role n_perm n_rem n_prof n_bg
      _tv n_role 'Role'; _tv n_perm 'Permissions'; _tv n_rem 'Remote'; _tv n_prof 'Profile'; _tv n_bg 'On launch'
      _tui_perm_label "$PERM_MODE"; local pl="$UI_C$UI_S$O $M— $UI_D$O"
      _tui_role_icon "$ROLE"; local ri=$UI_S
      _tui_role_color "$ROLE"
      ui_fit "$n_role" 12; BODY+=("  ${K}o$O  $UI_S $UI_C$ri $ROLE$O")
      ui_fit "$n_perm" 12; BODY+=("  ${K}y$O  $UI_S $pl")
      local rem=off; (( REMOTE )) && rem=on
      ui_fit "$n_rem" 12; BODY+=("  ${K}e$O  $UI_S $rem")
      ui_fit "$n_prof" 12; BODY+=("  ${K}p$O  $UI_S $PROFILE")
      ui_fit "Worktree" 12; BODY+=("  ${K}w$O  $UI_S ${WORKTREE:-—}")
      if (( BG )); then _tv t 'background'; else _tv t 'open it, back here when you leave'; fi
      ui_fit "$n_bg" 12; BODY+=("  ${K}g$O  $UI_S $t")
      if [ "$PERM_MODE" = yolo ]; then
        BODY+=("")
        _tv t '▲ YOLO on: the agent will run commands and edit files without asking.'
        _tui_wrap "$t" "$cw"
        for p in "${WRAP[@]}"; do BODY+=("$C_ERR$T_BOLD$p$O"); done
      fi
      _tv t 'Press %s to choose the agent and the zone.' "$K↵$O"; BODY+=("" "$t")
      ;;
    swarm)
      _tv t 'Launches a coordinator and several worker agents in a zone. The coordinator gets its team list and your objective, delegates through the bus and can add agents, switch models or close them.'; _tui_para "$t"
      BODY+=("")
      _tui_bul '•' 'Zone → team name → agent → how many → objective'
      _tui_bul '•' 'Several teams per zone: architecture, security, docs…'
      _tui_bul '•' 'Teams never mix: reports and alerts go to their own coordinator'
      _tui_bul '•' 'An existing name adds agents to that team'
      _tv t 'Press %s to create the team.' "$K↵$O"; BODY+=("" "$t")
      ;;
    teams)
      _tv t 'Every team at a glance, and everything you do with one in two keystrokes.'; _tui_para "$t"
      BODY+=("")
      _tui_bul '▦' 'open its cockpit (live split view)'
      _tui_bul '✉' 'message the coordinator (new objective, questions)'
      _tui_bul '✚' 'add agents to the team'
      _tui_bul '↗' 'enter the coordinator'
      _tui_bul '✖' 'close the team (coordinator and agents)'
      BODY+=("")
      _tui_bul 'm' 'from anywhere in the menu · %s on a coordinator adds agents' '+'
      _tv t 'Press %s to manage your teams.' "$K↵$O"; BODY+=("" "$t")
      ;;
    cockpit)
      _tv t "Split screen with one team: coordinator on the left, agents on the right, and the live bus. It follows agents joining or leaving."; _tui_para "$t"
      _tui_menu_key_label; local mk=$UI_S
      BODY+=("")
      _tui_key_label "$PRAMA_COCKPIT_KEY"; _tui_bul "$UI_S" 'cockpit ⇄ focused agent'
      _tui_key_label "$PRAMA_NAV_KEY"; _tui_bul "$UI_S" 'agent list (go to any)'
      _tui_bul "$mk" 'back to this menu'
      _tui_bul 'Ctrl+b z' 'zoom the focused pane'
      _tv t 'Press %s or %s to open it.' "$K↵$O" "${K}c$O"; BODY+=("" "$t")
      ;;
    telegram)
      _tv t 'Control your agents from your phone with a 24/7 Telegram bot, even when your SSH app is closed: alerts, teams, quotas and reports.'; _tui_para "$t"
      BODY+=("")
      local st
      if (( TUI_TG_RUNNING )); then _tv st 'bot running'; _tv t 'Status: %s' "$C_LIVE● $st$O"
      else _tv st 'stopped'; _tv t 'Status: %s' "$M○ $st$O"; fi
      BODY+=("$t")
      _tv t 'Press %s to link, start or stop the bot.' "$K↵$O"; BODY+=("" "$t")
      ;;
    doctor)
      _tv t 'Server diagnosis and repair:'; _tui_para "$t"
      BODY+=("")
      _tui_bul '•' 'dependencies and installed agents'
      _tui_bul '•' 'hung tmux clients or zombie sessions'
      _tui_bul '•' 'tmux configuration and the "◂ MENU" button'
      _tui_bul '•' 'orphaned metadata'
      _tui_bul '•' 'bug reports from agents (prama-agent feedback list)'
      _tv t 'Press %s to run it.' "$K↵$O"; BODY+=("" "$t")
      ;;
    prefs)
      _tv t 'How prama looks and speaks. Saved in your config.env and applied at once, also to the tmux status bar of running agents.'; _tui_para "$t"
      BODY+=("")
      _tui_bul '◐' 'Language: %s' "$PRAMA_LANG_NAME"
      _tui_bul '◑' 'Theme: %s' "$UI_THEME"
      local ms; if (( TUI_MOUSE )); then _tv ms 'on'; else _tv ms 'off'; fi
      _tui_bul '◒' 'Mouse and touch: %s' "$ms"
      _tv t 'Press %s or %s to change them.' "$K↵$O" "$K,$O"; BODY+=("" "$t")
      ;;
  esac
}

# _tui_hub_detail <w> <h> → RP (h rows): live preview of the selected session or action help
_tui_hub_detail() {
  local w=$1 h=$2 r
  RP=()
  if (( h < 3 )); then
    _tui_blank "$w"
    for ((r = 0; r < h; r++)); do RP+=("$UI_S"); done
    return
  fi
  local item=${HUB_ITEMS[TUI_SEL]-a:new} cw=$(( w - 4 ))
  if [[ $item == s:* ]]; then
    local si=${item#s:} s st role c q m1 m2 path hint=''
    s=${S_NAME[si]} st=${S_STATE[si]} role=${S_ROLE[si]}
    state_color "$st"; local sc=$UI_S
    _tui_state_label "$st"; local stl=$UI_S
    _tui_role_icon "$role"; local ri=$UI_S
    _tui_role_color "$role"; local rc=$UI_C
    c=${S_CPU[si]%.*}; [[ $c =~ ^[0-9]+$ ]] || c=0
    _tui_mem_fmt "${S_MEM[si]}"; local mem=$UI_S
    m1="$rc$ri $role$T_OFF $C_MUTED·$T_OFF $sc● $stl$T_OFF $C_MUTED·$T_OFF CPU $c% $C_MUTED·$T_OFF $mem"
    m1+=" $C_MUTED· up ${S_ETIME[si]} · ${S_COMM[si]}$T_OFF"
    path=${S_PATH[si]/#$HOME/\~}
    m2="$C_MUTED⌂ $path$T_OFF"
    local model info quota
    model=$(health_get "$s" MODEL "$(state_get "$s" MODEL)")
    [ -n "$model" ] && m2+="  $C_NEON◆ $model$T_OFF"
    quota=$(quota_label "$s")
    [ -n "$quota" ] && m2+="  $C_MUTED◔ $quota$T_OFF"
    if [ "$st" = BLOCKED ] && info=$(session_block_info "$s"); then
      local bl; _tv bl '▲ blocked: %s' "${info%%|*}"
      m1="$C_ERR$T_BOLD$bl$T_OFF $C_MUTED${info#*|}$T_OFF"
    fi
    if [ "${TUI_QKEY:-}" != "$s|$TUI_LAST_COLLECT" ]; then
      TUI_QKEY="$s|$TUI_LAST_COLLECT"
      TUI_QLEN=$(queue_len "$s" 2>/dev/null) || TUI_QLEN=0
    fi
    q=$TUI_QLEN
    local tx
    if [[ $q =~ ^[0-9]+$ ]] && (( q > 0 )); then _tv tx '✉ %d queued' "$q"; m2+="  $C_BRASS$tx$T_OFF"; fi
    if (( ${S_ATT[si]:-0} > 0 )); then _tv tx '◉ attached'; m2+="  $C_LIVE$tx$T_OFF"; fi
    # A coordinator is its team: show the team, its size and its objective.
    local -a mt=()
    if [ "${S_TREE[si]:-}" = T ]; then
      local obj
      [ -n "${TUI_OBJ[$s]+x}" ] || TUI_OBJ[$s]=$(state_get "$s" OBJECTIVE)
      obj=${TUI_OBJ[$s]}
      _tv tx '❖ team %s · %d agent(s)' "${TUI_TLABEL[$s]:-$s}" "${S_NMEM[si]:-0}"
      [ -n "$obj" ] && tx+="  $C_MUTED◎ $obj"
      mt=("${S_TCOLOR[si]}$tx$T_OFF")
      if [ "${TUI_PLKEY[$s]:-}" != "$TUI_LAST_COLLECT" ]; then
        TUI_PLKEY[$s]=$TUI_LAST_COLLECT; plan_summary "$s"; TUI_PLAN[$s]=$PLAN_SUM
      fi
      [ -n "${TUI_PLAN[$s]}" ] && mt+=("$C_MUTED📋 ${TUI_PLAN[$s]}$T_OFF")
    fi
    if [ "$TUI_MODE" = compact ]; then
      _tv hint '↵ enter'
      m1="$sc● $stl$T_OFF $C_MUTED·$T_OFF CPU $c% $C_MUTED·$T_OFF $mem $C_MUTED· ${S_ETIME[si]}$T_OFF"
      if (( h >= 12 )); then _tui_preview_box "$w" "$h" "$s" "◉ $s" "" "$hint" "$m1"
      else _tui_preview_box "$w" "$h" "$s" "◉ $s" "$stl" "$hint"; fi
    else
      if [ "${S_TREE[si]:-}" = T ]; then _tv hint '↵ enter · t message · + agents · c cockpit'
      else _tv hint '↵ enter · t task · l logs'; fi
      _tui_preview_box "$w" "$h" "$s" "◉ $s" "" "$hint" "$m1" "$m2" "${mt[@]}"
    fi
  else
    local id=${item#a:}
    _tui_action_meta "$id"
    _tui_action_body "$id" "$cw"
    _tui_text_box "$w" "$h" "$A_ICON $A_LABEL" "$T_BOLD$C_TEXT" "" "${BODY[@]}"
  fi
}

# Keybar: the keys for what is selected first, global ones after; destructive keys in red.
_tui_hub_footer() {
  local item=${HUB_ITEMS[TUI_SEL]-} si
  TUI_KEYS=() TUI_KEYS_R=()
  if (( TUI_FILTER_EDIT )); then
    _tk '↵' 'apply' ENTER; _tk esc 'clear' ESC; _tk '↑↓' 'move'
  elif [[ $item == s:* ]]; then
    si=${item#s:}
    _tk '↵' 'enter' ENTER
    if [ "${S_TREE[si]:-}" = T ]; then
      _tk t 'message' t; _tk + 'agents' +; _tk c 'cockpit' c; _tk x 'close team' x 1
    else
      _tk t 'task' t; _tk c 'cockpit' c; _tk l 'logs' l; _tk r 'restart' r; _tk x 'close' x 1
    fi
    _tk m 'teams' m; _tk n 'new' n; _tk / 'filter' /
  else
    _tk '↵' 'open' ENTER; _tk n 'new agent' n; _tk s 'new team' s; _tk m 'teams' m; _tk / 'filter' /
  fi
  if [ "$TUI_MODE" = compact ]; then _tkr '?' 'help' '?'
  else _tkr '?' 'help' '?'; _tkr q 'quit' q; fi
  _tui_footer "$1"
}

tui_render_hub() {
  tui_frame_new
  local tc=$TUI_TC tr=$TUI_TR i na=${#HUB_ACTIONS[@]}
  if (( tc < 32 || tr < 10 )); then _tui_too_small; tui_flush; return; fi
  tui_hub_build_items
  _tui_header 1
  _tui_settings_line 2
  local top=3 bh=$(( tr - 3 ))
  if [ "$TUI_MODE" = wide ]; then
    local lw=$(( tc * 45 / 100 ))
    (( lw < 50 )) && lw=50
    (( lw > 64 )) && lw=64
    _tui_hub_list_panel "$lw" "$bh" "$top"
    _tui_hub_detail $(( tc - lw )) "$bh"
    for ((i = 0; i < bh; i++)); do TUI_FRAME[top + i]="${LP[i]}${RP[i]}"; done
  else
    local vneed=$HUB_NS need pvmin lh
    (( HUB_NS == 0 )) && vneed=4
    need=$(( vneed + 3 + na ))
    pvmin=6; (( bh >= 26 )) && pvmin=10
    lh=$need
    (( lh > bh - pvmin )) && lh=$(( bh - pvmin ))
    if (( lh < 5 + na )); then lh=$(( need < bh ? need : bh )); fi
    _tui_hub_list_panel "$tc" "$lh" "$top"
    _tui_hub_detail "$tc" $(( bh - lh ))
    for ((i = 0; i < lh; i++)); do TUI_FRAME[top + i]=${LP[i]}; done
    for ((i = 0; i < bh - lh; i++)); do TUI_FRAME[top + lh + i]=${RP[i]}; done
  fi
  _tui_hub_footer "$tr"
  tui_flush
}

_tui_hub_move() {
  local n=${#HUB_ITEMS[@]}
  TUI_SEL=$(( TUI_SEL + $1 ))
  (( TUI_SEL < 0 )) && TUI_SEL=0
  (( TUI_SEL >= n )) && TUI_SEL=$(( n - 1 ))
  _tui_hub_sel_key
}

# ── Actions on sessions ─────────────────────────────────────────────────────
# _tui_run_fullscreen <capture_stderr:0|1> <cmd...>  — leaves the alternate screen, runs the command
# in a subshell (a `die` inside cannot kill the TUI) and comes back. Stderr tail → TUI_LAST_ERR.
_tui_run_fullscreen() {
  local cap=$1 rc=0 errf=/dev/null
  shift
  if (( cap )) && [ -d "${PRAMA_STATE_HOME:-}" ] && [ ! -L "$PRAMA_STATE_HOME" ]; then
    errf="$PRAMA_STATE_HOME/tui-last-error.log"
    : > "$errf" 2>/dev/null || errf=/dev/null
  fi
  tui_suspend
  if (( cap )); then ( _tui_locale_restore; "$@" ) 2>"$errf" || rc=$?
  else ( _tui_locale_restore; "$@" ) || rc=$?; fi
  tui_resume
  TUI_LAST_ERR=''
  if (( rc )) && [ "$errf" != /dev/null ] && [ -s "$errf" ]; then
    local -a el=()
    mapfile -t el < "$errf"
    (( ${#el[@]} > 12 )) && el=("${el[@]: -12}")
    printf -v TUI_LAST_ERR '%s\n' "${el[@]}"
  fi
  return "$rc"
}

# _tui_external <crumb> <pause:0|1> <cmd...> — runs a menu/command from another module on the
# alternate screen with a cooked tty (it may print, read lines or call tui_select_box).
_tui_external() {
  local crumb=$1 pause=$2 rc=0 prev=$TUI_CRUMBS
  shift 2
  local tx
  if ! declare -F "$1" >/dev/null; then _tv tx 'Function not available: %s' "$1"; tui_toast err "$tx"; return 0; fi
  _tv tx 'Menu'
  TUI_CRUMBS="$tx › $crumb"
  tui_soft_suspend
  (( pause )) && printf '\n %s%s%s\n\n' "$C_NEON$T_BOLD" "$crumb" "$T_OFF"
  ( "$@" ) || rc=$?
  if (( pause )); then
    _tv tx 'Press a key to go back'
    printf '\n %s ↵ %s %s ' "$KEY_BADGE" "$T_OFF" "$tx"
    IFS= read -rsn1 _ || true
  fi
  TUI_CRUMBS=$prev
  tui_soft_resume
  tui_collect 0
  if (( rc )); then _tv tx '%s ended with an error (code %d)' "$crumb" "$rc"; tui_toast err "$tx"; fi
  return 0
}

tui_attach_session() {
  local s=$1
  _tui_short "$s"; local short=$UI_S tx
  if ! tmx_has "$s"; then _tv tx 'Session %s no longer exists' "$short"; tui_toast err "$tx"; tui_collect 0; return 0; fi
  if _tui_run_fullscreen 1 tmx_attach "$s"; then
    _tv tx 'Back in Prama · %s keeps running' "$short"; tui_toast info "$tx"
  else
    _tv tx 'Could not enter %s' "$short"; tui_alert "$tx" "${TUI_LAST_ERR:-tmux attach failed}"
  fi
  tui_collect 0
}

_tui_task() {
  local s=$1 text='' out rc=0 tx
  _tui_short "$s"; local short=$UI_S
  if [ "${TUI_ROLE_CACHE[$s]:-}" = coordinator ]; then _tv tx 'Message for the coordinator %s' "$short"
  else _tv tx 'Task for %s' "$short"; fi
  tui_prompt "$tx" text || return 0
  out=$(subcmd_bus assign "$s" "$text" 2>&1) || rc=$?
  if (( rc == 0 )); then _tv tx 'Sent to %s' "$short"; tui_toast ok "$tx"
  else _tv tx 'Could not send the task'; tui_alert "$tx" "${out:-error $rc}"; fi
}

_tui_logs() {
  local s=$1
  if command -v less >/dev/null 2>&1; then
    _tui_short "$s"
    tui_suspend
    local lp; _tv lp 'logs %s  (q back, / search) ' "$UI_S"
    tmx_capture "$s" 2000 1 | less -R +G "-Ps$lp" 2>/dev/null
    tui_resume
  else
    tui_soft_suspend
    tmx_capture "$s" $(( TUI_TR - 3 )) 1
    local tx; _tv tx 'Press a key to go back'
    printf '\n %s ↵ %s %s ' "$KEY_BADGE" "$T_OFF" "$tx"
    IFS= read -rsn1 _ || true
    tui_soft_resume
  fi
}

_tui_session_action() {
  local k=$1 s=$2 short q yes tx
  _tui_short "$s"; short=$UI_S
  case $k in
    t) _tui_task "$s" ;;
    l) _tui_logs "$s" ;;
    r)
      _tv q 'Restart "%s"? The agent is relaunched in the same pane and resumes its conversation.' "$short"
      _tv yes 'Restart'
      if tui_confirm "$q" 1 "$yes"; then
        if ( _fleet_restart_in_place "$s" ) >/dev/null 2>&1; then _tv tx '%s is restarting' "$short"; tui_toast ok "$tx"
        else _tv tx 'Could not restart %s' "$short"; tui_toast err "$tx"; fi
        tui_collect 0
      fi ;;
    x)
      # A coordinator with agents: one confirmation closes its whole team (and its cockpit);
      # other teams of the same zone keep working.
      if [ "$(session_role "$s")" = coordinator ] && _tui_close_team "$s"; then return 0; fi
      _tv q 'Close "%s"? The agent stops and anything it has not saved is lost.' "$short"
      _tv yes 'Close'
      if tui_confirm "$q" 1 "$yes"; then
        tmx_kill "$s"
        state_remove "$s"
        unset "TUI_ROLE_CACHE[$s]" "TUI_MCACHE[$s]"
        _tv tx 'Session %s closed' "$short"; tui_toast ok "$tx"
        tui_collect 0
      fi ;;
  esac
}

# Live plan of a team, full screen (v toggles board and timeline, q returns).
_tui_plan_watch() { _plan_target "$1" ''; plan_watch; }

# _tui_team_members <coordinator> → TM (sessions whose PARENT is it)
_tui_team_members() {
  local m
  TM=()
  while IFS= read -r m; do [ "$(state_get "$m" PARENT)" = "$1" ] && TM+=("$m"); done < <(prama_sessions)
  return 0
}

# _tui_close_team <coordinator> — asks and closes the team; 1 when it has no agents (close it alone).
_tui_close_team() {
  local s=$1 label q yes tx
  _tui_team_members "$s"
  (( ${#TM[@]} )) || return 1
  label=$(team_label "$s")
  _tv q 'Close the team "%s"? The coordinator and its %d agent(s) stop; other teams keep working.' "$label" "${#TM[@]}"
  _tv yes 'Close team'
  if tui_confirm "$q" 1 "$yes"; then
    if ( _swarm_stop "$s" ) >/dev/null 2>&1; then _tv tx 'Team %s closed (%d agents)' "$label" $(( ${#TM[@]} + 1 )); tui_toast ok "$tx"
    else _tv tx 'Could not close the team %s' "$label"; tui_toast err "$tx"; fi
    TUI_ROLE_CACHE=() TUI_MCACHE=() TUI_TLABEL=() TUI_OBJ=()
    tui_collect 0
  fi
  return 0
}

# _tui_team_grow <coordinator> — agent → how many, then swarm <zone> --team <team> (no cockpit).
_tui_team_grow() {
  local c=$1 zone team label rc i n wa tx step=1
  zone=$(state_get "$c" ZONE) team=$(team_name "$c") label=$(team_label "$c")
  _tui_agent_lists
  local -a NL=() NM=() NA=() NT=()
  for i in 1 2 3 4 5 6; do NL+=("$i"); _tv tx '+%d agent(s) for %s' "$i" "$label"; NM+=("$tx"); NA+=(1); NT+=(""); done
  while :; do
    _tv tx 'Menu'; local crumb="$C_MUTED$tx$T_OFF $C_MUTED›$T_OFF"
    _tv tx 'Add agents'; TUI_LIST_CRUMBS="$crumb $T_BOLD$tx$T_OFF $C_MUTED›$T_OFF $label${wa:+ · $wa}"
    if (( step == 1 )); then
      _tv tx 'Which agent joins %s?' "$label"
      rc=0; tui_list_run "$tx" AG_LABELS AG_METAS AG_AVAIL AG_TARGETS -1 || rc=$?
      (( rc )) && break
      wa=${AGENTS[CHOICE]}; step=2
    else
      _tv tx 'How many %s agents?' "$wa"
      rc=0; tui_list_run "$tx" NL NM NA NT 0 || rc=$?
      if (( rc )); then step=1; continue; fi
      n=${NL[CHOICE]}
      TUI_LIST_CRUMBS=''; tui_invalidate
      if _tui_run_fullscreen 1 subcmd_swarm "$zone" --team "$team" --workers "$wa:$n" --no-open; then
        _tv tx '%d %s agent(s) joined %s' "$n" "$wa" "$label"; tui_toast ok "$tx"
      else
        _tv tx 'Could not add agents'; tui_alert "$tx" "${TUI_LAST_ERR:-swarm}"
      fi
      break
    fi
  done
  TUI_LIST_CRUMBS=''
  tui_invalidate
  tui_collect 0
  return 0
}

# Cockpit of the selected session's zone; without a selection, pick among zones with agents.
_tui_cockpit() {
  local s=${1:-} z c
  local -a CK_LABELS=() CK_METAS=() CK_AVAIL=() CK_TARGETS=() scopes=()
  if [ -n "$s" ]; then
    scopes=("$s")
  else
    # One entry per team, plus zones whose agents have no coordinator.
    local -A cnt=() teamed=()
    local -a zs=()
    while IFS='|' read -r c _ z; do
      [ -n "${cnt[$z]+x}" ] || zs+=("$z")
      cnt[$z]=$(( ${cnt[$z]:-0} + 1 ))
    done < <(prama_team_order)
    local tx
    if (( ${#zs[@]} == 0 )); then _tv tx 'No agents yet: create a team (❖ New team)'; tui_toast info "$tx"; return 0; fi
    for z in "${zs[@]}"; do
      while IFS= read -r c; do
        _tui_team_members "$c"
        _tv tx 'coordinator + %d agent(s)' "${#TM[@]}"
        CK_LABELS+=("$(team_label "$c")") CK_METAS+=("$tx") CK_AVAIL+=(1) CK_TARGETS+=("$c")
        scopes+=("$c"); teamed[$z]=1
      done < <(zone_teams "$z")
      if [ -z "${teamed[$z]:-}" ]; then
        _tv tx '%d agent(s) without a coordinator' "${cnt[$z]}"
        CK_LABELS+=("$z") CK_METAS+=("$tx") CK_AVAIL+=(1) CK_TARGETS+=("")
        scopes+=("$z")
      fi
    done
    if (( ${#scopes[@]} > 1 )); then
      _tv tx 'Menu'; TUI_LIST_CRUMBS="$C_MUTED$tx$T_OFF $C_MUTED›$T_OFF ${T_BOLD}Cockpit$T_OFF"
      _tv tx 'Which team do you want to watch?'
      local rc=0; tui_list_run "$tx" CK_LABELS CK_METAS CK_AVAIL CK_TARGETS 0 || rc=$?
      TUI_LIST_CRUMBS=''; tui_invalidate
      (( rc )) && return 0
      scopes=("${scopes[CHOICE]}")
    fi
  fi
  if ! _tui_run_fullscreen 1 subcmd_cockpit "${scopes[0]}"; then
    local te; _tv te 'Could not open the cockpit'
    tui_alert "$te" "${TUI_LAST_ERR:-${scopes[0]}}"
  fi
  tui_collect 0
}

# tui_new_team — zone → team → worker agent → how many → objective, then `swarm` (opens the
# cockpit). A zone can hold several teams: an existing name adds agents to that team.
tui_new_team() {
  local step=1 rc i zone='' team='' wa='' n=2 task='' coord=claude tx l_menu l_new l_zone iso=''
  local -a IL=() IM=() IA=(1 1) IT=('' '')
  is_in claude "${AGENTS[@]}" && agent_installed claude || coord=${AGENTS[0]}
  TUI_GIT_CACHE=()
  _tui_agent_lists
  local -a NL=() NM=() NA=() NT=()
  for i in 1 2 3 4 5 6; do NL+=("$i"); _tv tx '%d worker agent(s) + 1 coordinator (%s)' "$i" "$coord"; NM+=("$tx"); NA+=(1); NT+=(""); done
  _tv l_menu 'Menu'; _tv l_new 'New team'; _tv l_zone 'zone'
  while :; do
    TUI_LIST_CRUMBS="$C_MUTED$l_menu$T_OFF $C_MUTED›$T_OFF $T_BOLD$l_new$T_OFF $C_MUTED›$T_OFF ${zone:-$l_zone}${team:+ · $team}${wa:+ · $wa}"
    case $step in
      1) AGENT=$coord; _tui_zone_lists
         _tv tx 'Which zone will the team work in?'
         rc=0; tui_list_run "$tx" ZN_LABELS ZN_METAS ZN_AVAIL ZN_TARGETS -1 || rc=$?
         (( rc )) && break
         zone=${ZONES[CHOICE]}; step=15 ;;
      15) # Team: a new name creates a team with its own coordinator; an existing one adds agents.
         local existing def=''
         existing=$(_swarm_teams_hint "$zone")
         [ -n "$existing" ] || def=$PRAMA_DEFAULT_TEAM
         team=''
         if [ -n "$existing" ]; then _tv tx 'Team name (in %s: %s; an existing name adds agents)' "$zone" "$existing"
         else _tv tx 'Team name'; fi
         if ! tui_prompt "$tx" team "$def"; then
           step=1; continue
         fi
         team=${team,,}; team=${team// /-}
         if ! valid_team_name "$team"; then
           local t1 t2; _tv t1 'Invalid team name'; _tv t2 'Use lowercase letters, digits and dashes (max. 20), e.g. security or docs.'
           tui_alert "$t1" "$t2"
           continue
         fi
         # A new team in a git zone chooses its isolation; an existing team keeps its own.
         iso=''
         if ! find_team "$zone" "$team" >/dev/null 2>&1 && git_can_isolate "$(zone_dir "$zone")"; then step=17; else step=2; fi ;;
      17) IL=() IM=()
         _tv tx '⎇ A branch per agent (recommended)'; IL+=("$tx")
         _tv tx 'each executor in its own git worktree; the coordinator reviews and merges'; IM+=("$tx")
         _tv tx '▣ Shared folder'; IL+=("$tx")
         _tv tx 'everyone edits the zone folder (fine for one executor or read-only work)'; IM+=("$tx")
         _tv tx 'How will the team work on the code?'
         rc=0; tui_list_run "$tx" IL IM IA IT $(( ${PRAMA_SWARM_ISOLATE:-1} ? 0 : 1 )) || rc=$?
         if (( rc )); then step=15; continue; fi
         if (( CHOICE == 0 )); then iso=--isolate; else iso=--shared; fi
         step=2 ;;
      2) _tv tx 'Agent for the workers'
         rc=0; tui_list_run "$tx" AG_LABELS AG_METAS AG_AVAIL AG_TARGETS -1 || rc=$?
         if (( rc )); then step=15; continue; fi
         wa=${AGENTS[CHOICE]}; step=3 ;;
      3) _tv tx 'How many %s workers?' "$wa"
         rc=0; tui_list_run "$tx" NL NM NA NT 1 || rc=$?
         if (( rc )); then step=2; continue; fi
         n=${NL[CHOICE]}; step=4 ;;
      4) task=''
         _tv tx 'Objective for the coordinator (optional)'
         tui_prompt "$tx" task || task=''
         TUI_LIST_CRUMBS=''; tui_invalidate
         if ! _tui_run_fullscreen 1 subcmd_swarm "$zone" --team "$team" --coord "$coord" --workers "$wa:$n" ${iso:+"$iso"} ${task:+--task "$task"}; then
           local t1 t2; _tv t1 'Could not create the team'; _tv t2 'check prama-agent doctor'
           tui_alert "$t1" "${TUI_LAST_ERR:-$t2}"
         fi
         break ;;
    esac
  done
  TUI_LIST_CRUMBS=''
  tui_invalidate
  tui_collect 0
  return 0
}

# ── Teams screen: every team, then what to do with the chosen one ──────────
tui_teams() {
  local rc tx c m st nw obj l_menu l_teams
  _tv l_menu 'Menu'; _tv l_teams 'Teams'
  while :; do
    local -a TL=() TMe=() TA=() TT=() TC=()
    _tv tx '✚ New team'; TL+=("$tx")
    _tv tx 'coordinator + agents in a zone, with its own objective'; TMe+=("$tx"); TA+=(1); TT+=(""); TC+=("")
    while IFS='|' read -r c _ _; do
      [ -n "$c" ] && [ "$(session_role "$c")" = coordinator ] || continue
      _tui_team_members "$c"
      nw=0
      for m in "$c" "${TM[@]}"; do
        st=${TUI_MCACHE[$m]:-}; [ "${st%%|*}" = WORKING ] && nw=$(( nw + 1 ))
      done
      obj=$(state_get "$c" OBJECTIVE)
      _tv tx '%d agent(s) · %d working' "${#TM[@]}" "$nw"
      [ -n "$obj" ] && tx+=" · ◎ $obj"
      TL+=("❖ $(team_label "$c")") TMe+=("$tx") TA+=(1) TT+=("$c") TC+=("$c")
    done < <(prama_team_order)
    TUI_LIST_CRUMBS="$C_MUTED$l_menu$T_OFF $C_MUTED›$T_OFF $T_BOLD$l_teams$T_OFF"
    _tv tx 'Teams (%d)' $(( ${#TL[@]} - 1 ))
    rc=0; tui_list_run "$tx" TL TMe TA TT $(( ${#TL[@]} > 1 ? 1 : 0 )) || rc=$?
    (( rc )) && break
    if (( CHOICE == 0 )); then tui_new_team; continue; fi
    _tui_team_menu "${TC[CHOICE]}"
  done
  TUI_LIST_CRUMBS=''
  tui_invalidate
  tui_collect 0
  return 0
}

# _tui_team_menu <coordinator> — actions on one team; returns after closing it or with esc.
_tui_team_menu() {
  local c=$1 rc label tx l_menu l_teams
  label=$(team_label "$c")
  _tv l_menu 'Menu'; _tv l_teams 'Teams'
  while tmx_has "$c"; do
    local -a AL=() AM=() AA=() AT=() AK=(plan cockpit msg grow memory note)
    _tui_team_members "$c"
    plan_summary "$c"
    _tv tx '📋 Plan (live)';                 AL+=("$tx"); AM+=("${PLAN_SUM:-$(_t 'board and timeline of the tasks; the coordinator keeps it')}")
    _tv tx '▦ Open the cockpit';            AL+=("$tx"); _tv tx 'live split view: coordinator, agents and bus'; AM+=("$tx")
    _tv tx '✉ Message the coordinator';     AL+=("$tx"); _tv tx 'a new objective, a question, a change of plan'; AM+=("$tx")
    _tv tx '✚ Add agents';                  AL+=("$tx"); _tv tx 'more workers for this team (they report to its coordinator)'; AM+=("$tx")
    local nm; nm=$(( $(memory_count "$(state_get "$c" ZONE)" "$(team_name "$c")") + $(memory_count "$(state_get "$c" ZONE)") ))
    _tv tx '🧠 Team memory (%d)' "$nm";     AL+=("$tx"); _tv tx 'decisions and findings the agents keep; read them in full'; AM+=("$tx")
    _tv tx '✎ Add a note';                  AL+=("$tx"); _tv tx 'a decision or convention every agent of the team will read'; AM+=("$tx")
    if team_isolated "$c"; then
      _tv tx '⇄ Branches';                  AL+=("$tx"); _tv tx "each executor's branch: commits to merge, uncommitted, behind"; AM+=("$tx"); AK+=(branches)
    fi
    AK+=(enter close)
    _tv tx '↗ Enter the coordinator';       AL+=("$tx"); _tv tx 'talk to it directly; %s brings you back' "${PRAMA_MENU_KEY//M-/Alt+}"; AM+=("$tx")
    _tv tx '✖ Close the team';              AL+=("$tx"); _tv tx 'stops the coordinator and its %d agent(s)' "${#TM[@]}"; AM+=("$tx")
    AA=() AT=()
    for tx in "${AL[@]}"; do AA+=(1); AT+=("$c"); done
    TUI_LIST_CRUMBS="$C_MUTED$l_menu › $l_teams$T_OFF $C_MUTED›$T_OFF $T_BOLD$label$T_OFF"
    _tv tx 'Team %s' "$label"
    rc=0; tui_list_run "$tx" AL AM AA AT 0 || rc=$?
    (( rc )) && return 0
    case ${AK[CHOICE]} in
      cockpit) TUI_LIST_CRUMBS=''; tui_invalidate
               if ! _tui_run_fullscreen 1 subcmd_cockpit "$c"; then _tv tx 'Could not open the cockpit'; tui_alert "$tx" "${TUI_LAST_ERR:-$c}"; fi ;;
      msg)     TUI_ROLE_CACHE[$c]=coordinator; _tui_task "$c" ;;
      grow)    _tui_team_grow "$c" ;;
      plan)    TUI_LIST_CRUMBS=''; tui_invalidate
               _tui_run_fullscreen 0 _tui_plan_watch "$c" || true ;;
      branches) tui_suspend
               { wt_status "$c"; printf '\n'; } 2>&1 | less -R "-Ps$label  (q) " 2>/dev/null
               tui_resume ;;
      memory)  tui_suspend
               { subcmd_memory show "$c"; printf '\n'; } 2>&1 | less -R "-Ps$label  (q) " 2>/dev/null
               tui_resume ;;
      note)    local note=''
               _tv tx 'Note for the memory of %s' "$label"
               if tui_prompt "$tx" note; then
                 if ( subcmd_memory add "$c" "$note" ) >/dev/null 2>&1; then _tv tx 'Saved to the memory of %s' "$label"; tui_toast ok "$tx"
                 else _tv tx 'Could not save the note'; tui_toast err "$tx"; fi
               fi ;;
      enter)   TUI_LIST_CRUMBS=''; tui_attach_session "$c" ;;
      close)   if _tui_close_team "$c"; then :; else _tui_session_action x "$c"; fi ;;
    esac
  done
  return 0
}

# ── Preferences: language, theme (live preview), mouse ──────────────────────
TUI_PREVIEW_THEME=''
_tui_theme_preview() {
  [ "${PRAMA_THEMES[$1]:-}" = "$TUI_PREVIEW_THEME" ] && return 0
  TUI_PREVIEW_THEME=${PRAMA_THEMES[$1]:-}
  prefs_set_theme "$TUI_PREVIEW_THEME" 0
  TUI_TEAM_COLORS=("$C_NEON" "$C_PURP" "$C_LIVE" "$C_BRASS" "$C_INDIGO")
  tui_invalidate
}

tui_prefs() {
  local rc tx i cur l_menu l_prefs
  while :; do
    _tv l_menu 'Menu'; _tv l_prefs 'Preferences'
    local -a PL=() PM=() PA=(1 1 1) PT=('' '' '')
    _tv tx 'Language'; PL+=("◐ $tx"); PM+=("$PRAMA_LANG_NAME (${PRAMA_LANG:-auto})")
    _tv tx 'Color theme'; PL+=("◑ $tx"); PM+=("$UI_THEME · $(_theme_desc "$UI_THEME")")
    _tv tx 'Mouse and touch'; PL+=("◒ $tx")
    if (( TUI_MOUSE )); then _tv tx 'on: tap to select, tap again to open'; else _tv tx 'off: the terminal selects text as usual'; fi
    PM+=("$tx")
    TUI_LIST_CRUMBS="$C_MUTED$l_menu$T_OFF $C_MUTED›$T_OFF $T_BOLD$l_prefs$T_OFF"
    rc=0; tui_list_run "$l_prefs" PL PM PA PT 0 || rc=$?
    (( rc )) && break
    case $CHOICE in
      0)
        local -a LL=() LM=() LA=(1 1 1) LT=('' '' '') LC=(en es auto)
        LL=("English" "Español"); _tv tx 'Automatic'; LL+=("$tx")
        LM=("Interface in English" "Interfaz en español"); _tv tx 'from the locale (LANG)'; LM+=("$tx")
        cur=0; for i in 0 1 2; do [ "${LC[i]}" = "${PRAMA_LANG:-auto}" ] && cur=$i; done
        _tv tx 'Language'
        rc=0; tui_list_run "$tx" LL LM LA LT "$cur" || rc=$?
        if (( ! rc )) && prefs_set_lang "${LC[CHOICE]}"; then
          _tv tx 'Interface language: %s' "$PRAMA_LANG_NAME"; tui_toast ok "$tx"
        fi ;;
      1)
        local -a HL2=() HM=() HA=() HT=()
        local orig=$UI_THEME
        for i in "${!PRAMA_THEMES[@]}"; do
          HL2+=("${PRAMA_THEMES[i]}"); HM+=("$(_theme_desc "${PRAMA_THEMES[i]}")"); HA+=(1); HT+=('')
          [ "${PRAMA_THEMES[i]}" = "$UI_THEME" ] && cur=$i
        done
        _tv tx 'Color theme · moving previews it'
        TUI_PREVIEW_THEME=$UI_THEME
        TUI_LIST_ONMOVE=_tui_theme_preview
        rc=0; tui_list_run "$tx" HL2 HM HA HT "$cur" || rc=$?
        TUI_LIST_ONMOVE=''
        if (( rc )); then prefs_set_theme "$orig" 0
        else prefs_set_theme "${PRAMA_THEMES[CHOICE]}"; _tv tx 'Theme: %s' "$UI_THEME"; tui_toast ok "$tx"; fi
        TUI_TEAM_COLORS=("$C_NEON" "$C_PURP" "$C_LIVE" "$C_BRASS" "$C_INDIGO")
        tui_invalidate ;;
      2)
        TUI_MOUSE=$(( 1 - TUI_MOUSE ))
        _config_set PRAMA_TUI_MOUSE "$TUI_MOUSE"
        if (( TUI_MOUSE )); then tui_mouse_on; else tui_mouse_off; fi ;;
    esac
  done
  TUI_LIST_CRUMBS=''
  tui_invalidate
  return 0
}

_tui_fzf() {
  local tx
  if ! command -v fzf >/dev/null 2>&1; then _tv tx 'fzf is not installed (apt install fzf)'; tui_toast err "$tx"; return 0; fi
  if (( ${#S_NAME[@]} == 0 )); then _tv tx 'No sessions to inspect'; tui_toast info "$tx"; return 0; fi
  _tui_run_fullscreen 0 launch_fzf_cockpit || true
  tui_collect 0
}

# ── Settings toggles (shared by hub and confirm screen) ─────────────────────
cycle_profile() {
  local idx=0 i n=${#AVAILABLE_PROFILES[@]}
  for ((i = 0; i < n; i++)); do
    if [ "${AVAILABLE_PROFILES[$i]}" = "$PROFILE" ]; then idx=$(( (i + 1) % n )); break; fi
  done
  PROFILE="${AVAILABLE_PROFILES[$idx]}"
}

# Reader forces plan; leaving reader falls back to the safe default (ask), never to yolo.
cycle_role() {
  local idx=0 i n=${#AVAILABLE_ROLES[@]}
  for ((i = 0; i < n; i++)); do
    if [ "${AVAILABLE_ROLES[$i]}" = "$ROLE" ]; then idx=$(( (i + 1) % n )); break; fi
  done
  ROLE="${AVAILABLE_ROLES[$idx]}"
  if [ "$ROLE" = "reader" ]; then PERM_MODE="plan"
  elif [ "$PERM_MODE" = "plan" ]; then PERM_MODE="ask"; fi
}

cycle_perm_mode() {
  local idx=0 i n=${#AVAILABLE_PERM_MODES[@]}
  for ((i = 0; i < n; i++)); do
    if [ "${AVAILABLE_PERM_MODES[$i]}" = "$PERM_MODE" ]; then idx=$(( (i + 1) % n )); break; fi
  done
  PERM_MODE="${AVAILABLE_PERM_MODES[$idx]}"
}

_tui_toggle() {
  local tx
  case $1 in
    o)
      cycle_role
      if [ "$ROLE" = reader ]; then _tv tx 'Role: reader · permissions forced to PLAN'
      else _tv tx 'Role of the next agent: %s' "$ROLE"; fi
      tui_toast info "$tx" ;;
    y)
      if [ "$ROLE" = reader ]; then _tv tx 'The reader role always uses PLAN (read-only)'; tui_toast info "$tx"; return 0; fi
      cycle_perm_mode
      _tui_perm_label "$PERM_MODE"
      if [ "$PERM_MODE" = yolo ]; then _tv tx 'Permissions: ▲ YOLO — the agent will not ask for confirmation'; tui_toast err "$tx"
      else _tv tx 'Permissions: %s — %s' "$UI_S" "$UI_D"; tui_toast info "$tx"; fi ;;
    e)
      REMOTE=$(( 1 - ${REMOTE:-0} ))
      if (( REMOTE )); then _tv tx 'Native remote control: on (claude/agy)'
      else _tv tx 'Native remote control: off'; fi
      tui_toast info "$tx" ;;
    p) cycle_profile; _tv tx 'LLM profile: %s' "$PROFILE"; tui_toast info "$tx" ;;
    w)
      local v=''
      _tv tx 'Worktree branch (empty = no worktree)'
      if tui_prompt "$tx" v "$WORKTREE"; then
        if [[ $v =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,62}$ ]] && [[ $v != *..* ]]; then
          WORKTREE=$v; _tv tx 'Isolated worktree: %s' "$WORKTREE"; tui_toast ok "$tx"
        else
          _tv tx 'Invalid branch name: %s' "$v"; tui_toast err "$tx"
        fi
      elif (( ! TUI_PROMPT_CANCELLED )) || [ -z "$v" ]; then
        if [ -n "$WORKTREE" ]; then _tv tx "No worktree (the zone's directory)"; tui_toast info "$tx"; fi
        WORKTREE=''
      fi ;;
    g)
      BG=$(( 1 - ${BG:-0} ))
      if (( BG )); then _tv tx 'On launch: in the background'
      else _tv tx 'On launch: open it, back here when you leave'; fi
      tui_toast info "$tx" ;;
  esac
}

# ── Hub input ───────────────────────────────────────────────────────────────
_tui_hub_activate() {
  local item=${HUB_ITEMS[TUI_SEL]-}
  case $item in
    s:*)         tui_attach_session "${S_NAME[${item#s:}]}" ;;
    a:new)       tui_new_agent ;;
    a:swarm)     tui_new_team ;;
    a:teams)     tui_teams ;;
    a:cockpit)   _tui_cockpit "" ;;
    a:prefs)     tui_prefs ;;
    a:telegram)  _tui_external "Telegram" 0 subcmd_telegram menu ;;
    a:doctor)    _tui_external "Doctor" 1 subcmd_doctor ;;
  esac
}

_tui_hub_mouse() {
  case $MB in
    64) KEY=UP; tui_hub_handle_key; return ;;
    65) KEY=DOWN; tui_hub_handle_key; return ;;
    0) ;;
    *) return ;;
  esac
  if _tui_zone_token; then KEY=$ZT; tui_hub_handle_key; return; fi
  if [ -n "${TUI_HIT[$MY]+x}" ]; then
    local j=${TUI_HIT[$MY]}
    if (( j == TUI_SEL )); then KEY=ENTER; tui_hub_handle_key
    else TUI_SEL=$j; _tui_hub_sel_key; fi
  fi
}

tui_hub_handle_key() {
  local item=${HUB_ITEMS[TUI_SEL]-} s=''
  [[ $item == s:* ]] && s=${S_NAME[${item#s:}]}
  if (( TUI_FILTER_EDIT )); then
    case $KEY in
      ENTER) TUI_FILTER_EDIT=0; return ;;
      ESC) TUI_FILTER='' TUI_FILTER_EDIT=0; return ;;
      BACKSPACE)
        if [ -n "$TUI_FILTER" ]; then TUI_FILTER=${TUI_FILTER%?}; TUI_SEL_KEY=''; else TUI_FILTER_EDIT=0; fi
        return ;;
      SPACE) TUI_FILTER+=' '; TUI_SEL_KEY=''; return ;;
      UP|DOWN|PGUP|PGDN|HOME|END|MOUSE|TIMEOUT|RESIZE|EOF|NONE) ;;
      *) if (( ${#KEY} == 1 )); then TUI_FILTER+=$KEY; TUI_SEL_KEY=''; fi; return ;;
    esac
  fi
  case $KEY in
    TIMEOUT)            tui_collect 0 ;;
    RESIZE|NONE)        ;;
    EOF)                TUI_QUIT=1 ;;
    UP|k|K)             _tui_hub_move -1 ;;
    DOWN|j|J|TAB)       _tui_hub_move 1 ;;
    BTAB)               _tui_hub_move -1 ;;
    PGUP)               _tui_hub_move -5 ;;
    PGDN)               _tui_hub_move 5 ;;
    HOME)               TUI_SEL=0; _tui_hub_sel_key ;;
    END)                TUI_SEL=$(( ${#HUB_ITEMS[@]} - 1 )); _tui_hub_sel_key ;;
    ENTER|RIGHT|SPACE)  _tui_hub_activate ;;
    n|N)                tui_new_agent ;;
    s|S)                tui_new_team ;;
    t|T|l|L|r|R|x|X)
      if [ -n "$s" ]; then _tui_session_action "${KEY,,}" "$s"
      else local tx; _tv tx 'Select an agent first (↑↓)'; tui_toast info "$tx"; fi ;;
    +)
      if [ -n "$s" ] && [ "${S_TREE[${item#s:}]:-}" = T ]; then _tui_team_grow "$s"
      else local tx; _tv tx 'Select a team coordinator first (❖)'; tui_toast info "$tx"; fi ;;
    m|M)                tui_teams ;;
    ,)                  tui_prefs ;;
    c|C)                _tui_cockpit "$s" ;;
    f|F)                _tui_fzf ;;
    /)                  TUI_FILTER_EDIT=1 ;;
    ESC|LEFT|BACKSPACE|h)
      if [ -n "$TUI_FILTER" ]; then TUI_FILTER=''
      else local tx; _tv tx 'Press q to quit (agents keep running)'; tui_toast info "$tx"; fi ;;
    o|y|e|p|w|g)        _tui_toggle "$KEY" ;;
    '?')                _tui_help ;;
    q|Q)                TUI_QUIT=1 ;;
    [1-9])              (( KEY <= HUB_NS )) && { TUI_SEL=$(( KEY - 1 )); _tui_hub_sel_key; } ;;
    MOUSE)              _tui_hub_mouse ;;
  esac
}

# ── Entry point ─────────────────────────────────────────────────────────────
tui_plain_fallback() {
  local s
  printf '%s v%s — %s\n' "${PRAMA_BRAND:-PRAMA AGENT}" "${VERSION:-?}" "$(_t 'the interactive menu needs a terminal (TTY).')"
  while IFS= read -r s; do
    [ -n "$s" ] && printf '  ● %-40s %s\n' "$s" "$(session_role "$s")"
  done < <(prama_sessions)
  printf '%s\n' "$(_t 'Usage: prama-agent <agent> <zone> · prama-agent status · prama-agent attach <session>')"
}

# tui_main — interactive hub. Uses/updates AGENT ZONE ROLE PERM_MODE REMOTE PROFILE WORKTREE BG.
tui_main() {
  if (( ! IS_TERM )) || [ ! -t 0 ] || [ ! -t 1 ]; then tui_plain_fallback; return 1; fi
  : "${ROLE:=executor}" "${PERM_MODE:=ask}" "${REMOTE:=0}" "${PROFILE:=default}" "${BG:=0}"
  : "${WORKTREE:=}" "${AGENT:=}" "${ZONE:=}"
  # config.env is loaded after this file is sourced: read the TUI settings now.
  TUI_MOUSE=${PRAMA_TUI_MOUSE:-1} TUI_TICK=${PRAMA_TUI_TICK:-2}
  tui_setup
  state_gc >/dev/null 2>&1 || true
  TUI_SEL=0 TUI_SEL_KEY='' TUI_SCROLL=0 TUI_FILTER='' TUI_FILTER_EDIT=0 TUI_QUIT=0
  tui_collect 1
  local skip=0
  while (( ! TUI_QUIT )); do
    TUI_REDRAW_FN=tui_render_hub
    (( skip )) || tui_render_hub
    _tui_wait_key
    tui_hub_handle_key
    # Coalesce key-repeat: skip the repaint while more input is already queued.
    skip=0
    if [[ $KEY == UP || $KEY == DOWN ]] && read -t 0 2>/dev/null; then skip=1; fi
  done
  tui_cleanup
  trap - EXIT INT TERM HUP WINCH
  return 0
}

# ── Generic list screen (wizard steps and tui_select_box) ───────────────────
# tui_list_run <title> <labels> <metas> <avail> <targets> [start_index]
#   Renders a full-screen list with header, crumbs (TUI_LIST_CRUMBS or TUI_CRUMBS), filter,
#   detail/preview box and keybar. Sets CHOICE; returns 0 selected, 2 back.
tui_list_run() {
  local title=$1 start=${6:--1}
  local -n _tl_lab=$2 _tl_met=$3 _tl_ava=$4 _tl_tgt=$5
  local n=${#_tl_lab[@]} i sel=-1 pos=0 scroll=0 f='' fedit=0 moved=-1
  local -a vis=()
  if (( start >= 0 && start < n )); then sel=$start
  else
    for ((i = 0; i < n; i++)); do
      [ "${_tl_ava[i]:-0}" = 1 ] || continue
      if (( i == 0 && n > 1 )) && [[ ${_tl_lab[0]} == *VOLVER* ]]; then continue; fi
      sel=$i; break
    done
    (( sel < 0 )) && sel=0
  fi
  while :; do
    vis=()
    local fl=${f,,}
    for ((i = 0; i < n; i++)); do
      if [ -n "$fl" ] && [[ ${_tl_lab[i],,} != *"$fl"* && ${_tl_met[i]:-} != *"$fl"* ]]; then continue; fi
      vis+=("$i")
    done
    pos=-1
    for i in "${!vis[@]}"; do (( vis[i] == sel )) && { pos=$i; break; }; done
    if (( pos < 0 )); then pos=0; sel=${vis[0]:--1}; fi
    # Optional callback when the highlighted item changes (theme preview).
    if [ -n "${TUI_LIST_ONMOVE:-}" ] && (( sel >= 0 && sel != moved )); then moved=$sel; "$TUI_LIST_ONMOVE" "$sel"; fi
    TUI_REDRAW_FN=_tui_render_list
    _tui_render_list
    _tui_wait_key
    if (( fedit )); then
      case $KEY in
        ENTER) fedit=0; continue ;;
        ESC) f='' fedit=0; continue ;;
        BACKSPACE) if [ -n "$f" ]; then f=${f%?}; else fedit=0; fi; continue ;;
        SPACE) f+=' '; continue ;;
        UP|DOWN|PGUP|PGDN|HOME|END|MOUSE|TIMEOUT|RESIZE|EOF|NONE) ;;
        *) (( ${#KEY} == 1 )) && f+=$KEY; continue ;;
      esac
    fi
    local nv=${#vis[@]}
    case $KEY in
      TIMEOUT) TUI_HOST=$(host_stats_label) ;;
      UP|k|K|BTAB) (( pos > 0 )) && sel=${vis[pos-1]} ;;
      DOWN|j|J|TAB) (( pos < nv - 1 )) && sel=${vis[pos+1]} ;;
      PGUP) i=$(( pos - 5 )); (( i < 0 )) && i=0; (( nv )) && sel=${vis[i]} ;;
      PGDN) i=$(( pos + 5 )); (( i >= nv )) && i=$(( nv - 1 )); (( nv )) && sel=${vis[i]} ;;
      HOME) (( nv )) && sel=${vis[0]} ;;
      END) (( nv )) && sel=${vis[nv-1]} ;;
      ENTER|RIGHT|SPACE|l)
        if (( sel >= 0 )) && [ "${_tl_ava[sel]:-0}" = 1 ]; then CHOICE=$sel; return 0; fi
        if (( sel >= 0 )); then local na; _tv na 'Not available: %s (%s)' "${_tl_lab[sel]}" "${_tl_met[sel]##*· }"; tui_toast err "$na"; fi ;;
      [1-9])
        i=$(( KEY - 1 ))
        if (( i < n )) && [ "${_tl_ava[i]:-0}" = 1 ]; then CHOICE=$i; return 0; fi ;;
      /) fedit=1 ;;
      ESC)
        if [ -n "$f" ]; then f=''; else CHOICE=-1; return 2; fi ;;
      LEFT|BACKSPACE|h|b|q|Q|0|EOF) CHOICE=-1; return 2 ;;
      '?') _tui_help ;;
      MOUSE)
        case $MB in
          64) (( pos > 0 )) && sel=${vis[pos-1]} ;;
          65) (( pos < nv - 1 )) && sel=${vis[pos+1]} ;;
          0)
            if _tui_zone_token; then
              case $ZT in
                ENTER) if [ "${_tl_ava[sel]:-0}" = 1 ]; then CHOICE=$sel; return 0; fi ;;
                ESC) CHOICE=-1; return 2 ;;
                /) fedit=1 ;;
                '?') _tui_help ;;
              esac
            elif [ -n "${TUI_HIT[$MY]+x}" ]; then
              i=${TUI_HIT[$MY]}
              if (( i == sel )) && [ "${_tl_ava[i]:-0}" = 1 ]; then CHOICE=$i; return 0; fi
              sel=$i
            fi ;;
        esac ;;
    esac
  done
}

# Renders the list screen from tui_list_run's locals (dynamic scope).
_tui_render_list() {
  tui_frame_new
  local tc=$TUI_TC tr=$TUI_TR r j i
  if (( tc < 32 || tr < 8 )); then _tui_too_small; tui_flush; return; fi
  _tui_header 1
  if [ -n "$TUI_LIST_CRUMBS" ]; then _tui_crumbs_line 2 "$TUI_LIST_CRUMBS"
  else _tui_crumbs_line 2 "$C_MUTED${TUI_CRUMBS:-Prama}$T_OFF"; fi
  local bh=$(( tr - 3 )) nv=${#vis[@]} need dmin=0 lh vh
  need=$(( nv + 2 )); (( nv == 0 )) && need=3
  (( bh >= 12 )) && dmin=5
  lh=$need
  (( lh > bh - dmin )) && lh=$(( bh - dmin ))
  (( lh < 3 )) && lh=3
  vh=$(( lh - 2 ))
  (( pos < scroll )) && scroll=$pos
  (( pos >= scroll + vh )) && scroll=$(( pos - vh + 1 ))
  (( scroll > nv - vh )) && scroll=$(( nv - vh ))
  (( scroll < 0 )) && scroll=0
  local w=$tc cw=$(( tc - 2 )) bc=$C_BORDER_HI right
  if (( fedit )); then right="/$f▏"
  elif [ -n "$f" ]; then _tv right '/%s · %d of %d' "$f" "$nv" "$n"
  elif (( nv > vh )); then _tv right '%d-%d of %d' $(( scroll + 1 )) $(( scroll + vh )) "$nv"
  else _tv right '%d options' "$n"; fi
  _tb_top "$w" "$title" "$T_BOLD$C_NEON" "$right" "$bc"; TUI_FRAME[3]=$TB
  # label column
  local lw=4 maxlw=$(( (cw - 8) * 45 / 100 ))
  (( maxlw < 8 )) && maxlw=8
  for i in "${vis[@]}"; do ui_width "${_tl_lab[i]}"; (( UI_W > lw )) && lw=$UI_W; done
  (( lw > maxlw )) && lw=$maxlw
  _tui_blank "$cw"; local blank=$UI_S
  for ((r = 0; r < vh; r++)); do
    j=$(( scroll + r ))
    if (( nv == 0 && r == 0 )); then
      _tv UI_S '  No results · esc clears the filter'; ui_fit "$UI_S" "$cw"; SR="$C_MUTED$UI_S$T_OFF"
    elif (( j < nv )); then
      _tui_lrow "${vis[j]}" $(( vis[j] == sel )) "$cw" "$lw"
      TUI_HIT[$(( 4 + r ))]=${vis[j]}
    else SR=$blank; fi
    TUI_FRAME[4 + r]="$bc│$T_OFF$SR$bc│$T_OFF"
  done
  local hint=''
  (( nv > scroll + vh )) && _tv hint '▼ %d more' $(( nv - scroll - vh ))
  _tb_bot "$w" "$bc" "$hint"; TUI_FRAME[2 + lh]=$TB
  # detail / preview below the list
  local dh=$(( bh - lh )) row=$(( 3 + lh ))
  if (( dh >= 3 && sel >= 0 )); then
    local tgt=${_tl_tgt[sel]:-}
    if [ -n "$tgt" ] && valid_session_name "$tgt" && tmx_has "$tgt"; then
      _tui_preview_box "$w" "$dh" "$tgt" "◉ $tgt" "" ""
    else
      local meta=${_tl_met[sel]:-} cap
      local -a dl=()
      _tui_wrap "$meta" $(( w - 4 ))
      dl=("${WRAP[@]}")
      if [ "${_tl_ava[sel]:-0}" != 1 ]; then local na; _tv na '✖ Not available'; dl+=("" "$C_ERR$na$T_OFF"); fi
      cap=$(( ${#dl[@]} + 2 ))
      (( cap > dh )) && cap=$dh
      (( cap < 3 )) && cap=3
      _tui_text_box "$w" "$cap" "${_tl_lab[sel]}" "$T_BOLD$C_TEXT" "" "${dl[@]}"
    fi
    for ((r = 0; r < ${#RP[@]}; r++)); do TUI_FRAME[row + r]=${RP[r]}; done
  fi
  TUI_KEYS=() TUI_KEYS_R=()
  if (( fedit )); then _tk '↵' 'apply' ENTER; _tk esc 'clear' ESC; _tk '↑↓' 'move'
  else _tk '↵' 'choose' ENTER; _tk esc 'back' ESC; _tk '↑↓' 'move'; _tk / 'filter' /; _tk 1-9 'jump'; fi
  _tkr '?' 'help' '?'
  _tui_footer "$tr"
  tui_flush
}

# _tui_lrow <index> <selected> <cw> <label_w> → SR
_tui_lrow() {
  local i=$1 sel=$2 cw=$3 lw=$4 base=$T_OFF mark=' ' R num=' ' lab meta lc mc
  if (( sel )); then base=$T_SEL; mark='▸'; fi
  R=$T_OFF$base
  (( i < 9 )) && num=$(( i + 1 ))
  lc=$C_TEXT mc=$C_MUTED
  (( sel )) && lc=$T_BOLD
  if [ "${_tl_ava[i]:-0}" != 1 ]; then lc="$C_MUTED$T_DIM" mc="$C_MUTED$T_DIM"; mark='✖'; fi
  ui_fit "${_tl_lab[i]}" "$lw"; lab=$UI_S
  local mw=$(( cw - 9 - lw ))
  if (( mw >= 6 )); then ui_fit "${_tl_met[i]:-}" "$mw"; meta=$UI_S
  else meta=''; _tui_blank $(( mw > 0 ? mw : 0 )); meta=$UI_S; fi
  SR="$base $C_NEON$mark$R $C_MUTED$num$R  $lc$lab$R  $mc$meta$R "
  (( mw < 0 )) && { ui_ansi_fit "$SR" "$cw"; SR=$UI_S; }
  SR+=$T_OFF
}

# ── Compatibility selector used by bus.sh (swarm wizard) and telegram.sh ────
# tui_select_box <step_id> <title> <labels_arr> <metas_arr> <avail_arr> <targets_arr>
#   Sets CHOICE (index). Returns 0 = selected, 2 = back (CHOICE=-1). Works inside the running TUI
#   (keeps the alternate screen) or standalone (enters/leaves it); plain numbered prompt without TTY.
tui_select_box() {
  local _sb_title=${2:-}
  CHOICE=-1
  if (( ! IS_TERM )) || [ ! -t 0 ]; then _tui_select_plain "$_sb_title" "$3" "$4" "$5"; return; fi
  local _sb_owned=0 _sb_stty='' _sb_rc=0
  if (( TUI_ACTIVE )); then
    _sb_stty=$(stty -g </dev/tty 2>/dev/null) || _sb_stty=''
    printf '\e[?25l\e[?7l'
    tui_term_raw
    tui_mouse_on
  else
    _sb_owned=1
    tui_setup
  fi
  trap 'TUI_RESIZED=1' WINCH
  tui_measure
  tui_invalidate
  [ -n "$TUI_HOST" ] || TUI_HOST=$(host_stats_label)
  local _sb_crumbs=$TUI_LIST_CRUMBS
  TUI_LIST_CRUMBS=''
  tui_list_run "$_sb_title" "$3" "$4" "$5" "$6" || _sb_rc=$?
  TUI_LIST_CRUMBS=$_sb_crumbs
  if (( _sb_owned )); then
    tui_cleanup
    trap - EXIT INT TERM HUP WINCH
  else
    tui_mouse_off
    if [ -n "$_sb_stty" ]; then stty "$_sb_stty" </dev/tty 2>/dev/null || true; fi
    printf '\e[?7h\e[0m\e[2J\e[H\e[?25h'
  fi
  (( _sb_rc == 0 )) || CHOICE=-1
  return "$_sb_rc"
}

_tui_select_plain() {
  local title=$1 i ans
  local -n _sp_l=$2 _sp_m=$3 _sp_a=$4
  printf '\n %s\n' "$title" >&2
  for i in "${!_sp_l[@]}"; do
    printf '  %2d) %s — %s%s\n' $(( i + 1 )) "${_sp_l[i]}" "${_sp_m[i]:-}" \
      "$([ "${_sp_a[i]:-0}" = 1 ] || _t ' (not available)')" >&2
  done
  printf ' %s ' "$(_t 'Option (empty = back):')" >&2
  IFS= read -r ans || return 2
  [[ $ans =~ ^[0-9]+$ ]] || return 2
  (( ans >= 1 && ans <= ${#_sp_l[@]} )) || return 2
  [ "${_sp_a[ans-1]:-0}" = 1 ] || return 2
  CHOICE=$(( ans - 1 ))
  return 0
}

# ── New-agent wizard: agent → zone → confirm ────────────────────────────────
_tui_wiz_crumbs() {
  local step=$1 sep=" $C_MUTED›$T_OFF " a z c
  local cur="$C_NEON$T_BOLD" done_c=$C_LIVE fut=$C_MUTED l_ag l_zo l_co l_menu l_new
  _tv l_ag 'Agent'; _tv l_zo 'Zone'; _tv l_co 'Confirm'; _tv l_menu 'Menu'; _tv l_new 'New agent'
  if (( step == 1 )); then a="$cur▸ 1 $l_ag$T_OFF"; else a="$done_c✔ $AGENT$T_OFF"; fi
  if (( step == 2 )); then z="$cur▸ 2 $l_zo$T_OFF"
  elif (( step > 2 )); then z="$done_c✔ $ZONE$T_OFF"
  else z="${fut}2 $l_zo$T_OFF"; fi
  if (( step == 3 )); then c="$cur▸ 3 $l_co$T_OFF"; else c="${fut}3 $l_co$T_OFF"; fi
  TUI_LIST_CRUMBS="$C_MUTED$l_menu$T_OFF$sep$T_BOLD$l_new$T_OFF$sep$a$sep$z$sep$c"
}

_tui_agent_lists() {
  AG_LABELS=() AG_METAS=() AG_AVAIL=() AG_TARGETS=()
  local i a bin d ni
  _tv ni 'not installed'
  for i in "${!AGENTS[@]}"; do
    a=${AGENTS[i]} d=${AGENT_DESCS[i]:-${AGENTS[i]}}
    d=${I18N[$d]-$d}
    AG_LABELS+=("$a") AG_TARGETS+=("")
    if bin=$(command -v "$a" 2>/dev/null); then
      AG_METAS+=("$d · ${bin/#$HOME/\~}") AG_AVAIL+=(1)
    else
      AG_METAS+=("$d · $ni") AG_AVAIL+=(0)
    fi
  done
}

declare -gA TUI_GIT_CACHE=()
_tui_zone_lists() {
  ZN_LABELS=() ZN_METAS=() ZN_AVAIL=() ZN_TARGETS=() ZN_GIT=()
  local i dir l1 l2 br dirty meta name gi l_ch l_act l_nx
  _tv l_ch '● changes'; _tv l_act '◉ %s already running here' "$AGENT"; _tv l_nx 'does not exist'
  local -A live=()
  for name in "${S_NAME[@]}"; do live[$name]=1; done
  for i in "${!ZONES[@]}"; do
    dir=${ZONE_DIRS[i]:-}
    ZN_LABELS+=("${ZONES[i]}") ZN_TARGETS+=("")
    if [ -d "$dir" ]; then
      if [ -z "${TUI_GIT_CACHE[$dir]+x}" ]; then
        l1='' l2=''
        { IFS= read -r l1; IFS= read -r l2; } < <(git -C "$dir" status --porcelain -b -uno --ignore-submodules 2>/dev/null)
        br=''
        if [[ $l1 == '## No commits yet on '* ]]; then br=${l1#'## No commits yet on '}
        elif [[ $l1 == '## '* ]]; then br=${l1#'## '}; br=${br%%...*}; br=${br%% *}; fi
        dirty=0; [ -n "$l2" ] && dirty=1
        TUI_GIT_CACHE[$dir]="${br:-—}|$dirty"
      fi
      gi=${TUI_GIT_CACHE[$dir]}
      br=${gi%%|*} dirty=${gi#*|}
      ZN_GIT+=("$gi")
      meta="${dir/#$HOME/\~}  ⎇ $br"
      (( dirty )) && meta+=" $l_ch"
      name=$(session_name_for "$AGENT" "${ZONES[i]}" "$ROLE" "$WORKTREE")
      [ -n "${live[$name]:-}" ] && meta+="  $l_act"
      ZN_METAS+=("$meta") ZN_AVAIL+=(1)
    else
      ZN_GIT+=("—|0")
      ZN_METAS+=("$dir · $l_nx") ZN_AVAIL+=(0)
    fi
  done
}

# tui_new_agent — wizard; on success launches via launch_agent and returns to the hub.
tui_new_agent() {
  local step=1 rc i start
  TUI_GIT_CACHE=()
  _tui_agent_lists
  while :; do
    case $step in
      1)
        start=-1
        for i in "${!AGENTS[@]}"; do
          [ "${AGENTS[i]}" = "$AGENT" ] && [ "${AG_AVAIL[i]}" = 1 ] && start=$i
        done
        _tui_wiz_crumbs 1
        local tx; _tv tx 'Choose the agent'
        rc=0; tui_list_run "$tx" AG_LABELS AG_METAS AG_AVAIL AG_TARGETS "$start" || rc=$?
        if (( rc )); then break; fi
        AGENT=${AGENTS[CHOICE]}; step=2 ;;
      2)
        _tui_wiz_crumbs 2
        _tui_zone_lists
        start=-1
        for i in "${!ZONES[@]}"; do [ "${ZONES[i]}" = "$ZONE" ] && start=$i; done
        local tx; _tv tx 'Choose the working zone'
        rc=0; tui_list_run "$tx" ZN_LABELS ZN_METAS ZN_AVAIL ZN_TARGETS "$start" || rc=$?
        if (( rc )); then step=1; continue; fi
        ZONE=${ZONES[CHOICE]}; step=3 ;;
      3)
        _tui_wiz_crumbs 3
        rc=0; _tui_confirm_screen || rc=$?
        case $rc in
          2) step=2 ;;
          *) break ;;
        esac ;;
    esac
  done
  TUI_LIST_CRUMBS=''
  tui_invalidate
  return 0
}

# Confirm screen rows: 0-5 toggles, 6 launch button.
CF_KEYS=(o y e p w g)
# _tui_cf_names → CF_NAMES (translated when used: the language is known after config.env)
_tui_cf_names() {
  CF_NAMES=('' '' '' '' Worktree '')
  _tv 'CF_NAMES[0]' 'Role'; _tv 'CF_NAMES[1]' 'Permissions'; _tv 'CF_NAMES[2]' 'Remote'
  _tv 'CF_NAMES[3]' 'LLM profile'; _tv 'CF_NAMES[5]' 'On launch'
}

# _tui_cf_value <idx> → CF_MAIN CF_DESC CF_COLOR
_tui_cf_value() {
  case $1 in
    0) _tui_role_icon "$ROLE"; CF_MAIN="$UI_S $ROLE"; _tui_role_desc "$ROLE"; CF_DESC=" — $UI_S"
       _tui_role_color "$ROLE"; CF_COLOR=$UI_C ;;
    1) _tui_perm_label "$PERM_MODE"; CF_MAIN=$UI_S CF_COLOR=$UI_C CF_DESC=" — $UI_D"
       [ "$ROLE" = reader ] && _tv CF_DESC ' — forced by the reader role' ;;
    2) if (( REMOTE )); then CF_MAIN='on'; _tv CF_DESC ' — native remote control (claude/agy)'
       else CF_MAIN='off' CF_DESC=''; fi
       CF_COLOR=$C_TEXT ;;
    3) CF_MAIN=$PROFILE CF_COLOR=$C_TEXT; _tv CF_DESC ' — model provider' ;;
    4) if [ -n "$WORKTREE" ]; then CF_MAIN="⎇ $WORKTREE"; _tv CF_DESC ' — isolated branch (git worktree)'
       else CF_MAIN='—'; _tv CF_DESC ' no isolation · ↵ to create a branch'; fi
       CF_COLOR=$C_PURP ;;
    5) _tui_menu_key_label
       if (( BG )); then _tv CF_MAIN 'background'; _tv CF_DESC " — doesn't open the session"
       else _tv CF_MAIN 'open'; _tv CF_DESC ' — you come back here with %s' "$UI_S"; fi
       CF_COLOR=$C_TEXT ;;
  esac
}

_tui_render_confirm() {
  tui_frame_new
  local tc=$TUI_TC tr=$TUI_TR r i
  if (( tc < 32 || tr < 10 )); then _tui_too_small; tui_flush; return; fi
  _tui_header 1
  _tui_crumbs_line 2 "$TUI_LIST_CRUMBS"
  local w=$tc cw=$(( tc - 2 )) bc=$C_BORDER_HI bh=$(( tr - 3 ))
  local zi=-1 zdir='' zgit='—|0' adesc='' name exists=0
  for i in "${!ZONES[@]}"; do [ "${ZONES[i]}" = "$ZONE" ] && zi=$i; done
  (( zi >= 0 )) && { zdir=${ZONE_DIRS[zi]/#$HOME/\~}; zgit=${ZN_GIT[zi]:-—|0}; }
  for i in "${!AGENTS[@]}"; do [ "${AGENTS[i]}" = "$AGENT" ] && adesc=${AGENT_DESCS[i]:-}; done
  name=$(session_name_for "$AGENT" "$ZONE" "$ROLE" "$WORKTREE")
  tmx_has "$name" && exists=1
  local br=${zgit%%|*} dirty=${zgit#*|}
  local -a summ=()
  local M=$C_MUTED O=$T_OFF
  local yolo=0; [ "$PERM_MODE" = yolo ] && yolo=1
  local -a warn=()
  local tx l_ag l_zo l_se
  _tui_cf_names
  if (( yolo )); then
    _tv tx '▲ YOLO: the agent will run commands and edit files WITHOUT asking for confirmation.'
    _tui_wrap "$tx" $(( cw - 2 ))
    warn=("${WRAP[@]}")
  fi
  # rows: top + summary + sep + 6 toggles + sep + warn + button + bottom
  local full=$(( 1 + 3 + 1 + 6 + 1 + ${#warn[@]} + 1 + 1 ))
  adesc=${I18N[$adesc]-$adesc}
  if (( bh >= full )); then
    _tv l_ag 'Agent'; _tv l_zo 'Zone'; _tv l_se 'Session'
    ui_fit "$l_ag" 11; summ+=("$M$UI_S$O$T_BOLD$AGENT$O $M· $adesc$O")
    ui_fit "$l_zo" 11; local zl="$M$UI_S$O$T_BOLD$ZONE$O $M· $zdir$O  $C_PURP⎇ $br$O"
    if (( dirty )); then _tv tx '● changes'; zl+=" $C_BRASS$tx$O"; fi
    summ+=("$zl")
    ui_fit "$l_se" 11; local sl="$M$UI_S$O$name"
    if (( exists )); then _tv tx '▲ already running: it will open'; sl+="  $C_BRASS$tx$O"; fi
    summ+=("$sl")
  else
    local sl="$T_BOLD$AGENT$O $M@$O $T_BOLD$ZONE$O $M→ $name$O"
    if (( exists )); then _tv tx '▲ running'; sl+=" $C_BRASS$tx$O"; fi
    summ+=("$sl")
  fi
  local row=3
  _tv tx 'Confirm launch'
  _tb_top "$w" "$tx" "$T_BOLD$C_NEON" "" "$bc"; TUI_FRAME[row]=$TB; row=$(( row + 1 ))
  for i in "${summ[@]}"; do _tb_line "$w" "$bc" "$i"; TUI_FRAME[row]=$TB; row=$(( row + 1 )); done
  _tv tx 'Settings · ↵ or its key to change'
  _tb_sep "$w" "$bc" "$tx"; TUI_FRAME[row]=$TB; row=$(( row + 1 ))
  local base R mark full_s vw keyc
  for ((i = 0; i < 6; i++)); do
    base=$T_OFF mark=' '
    (( i == CF_SEL )) && { base=$T_SEL; mark='▸'; }
    R=$T_OFF$base
    _tui_cf_value "$i"
    vw=$(( cw - 19 ))
    (( vw < 4 )) && vw=4
    ui_fit "$CF_MAIN$CF_DESC" "$vw"; full_s=$UI_S
    if [[ $full_s == "$CF_MAIN"* ]]; then full_s="$CF_COLOR$CF_MAIN$R$C_MUTED${full_s:${#CF_MAIN}}$R"
    else full_s="$CF_COLOR$full_s$R"; fi
    ui_fit "${CF_NAMES[i]}" 11
    keyc=${CF_KEYS[i]}
    SR="$base $C_NEON$mark$R $C_MUTED$UI_S$R $full_s $C_NEON$keyc$R  $T_OFF"
    TUI_FRAME[row]="$bc│$T_OFF$SR$bc│$T_OFF"
    TUI_HIT[$row]=$i
    row=$(( row + 1 ))
  done
  _tb_sep "$w" "$bc"; TUI_FRAME[row]=$TB; row=$(( row + 1 ))
  for i in "${warn[@]}"; do
    ui_fit " $i" "$cw"
    TUI_FRAME[row]="$bc│$T_OFF$T_WARN$UI_S$T_OFF$bc│$T_OFF"; row=$(( row + 1 ))
  done
  local btn
  if (( yolo )); then _tv btn '▲ LAUNCH IN YOLO MODE'
  elif (( BG )); then _tv btn '▸ LAUNCH IN THE BACKGROUND'
  else _tv btn '▸ LAUNCH AND OPEN'; fi
  if (( exists )) && ! (( BG )); then _tv btn '▸ OPEN THE RUNNING SESSION'; fi
  btn="  $btn  "
  ui_width "$btn"; local bw=$UI_W bst
  if (( CF_SEL == 6 )); then
    if (( yolo )); then bst=$T_WARN; else bst="$T_SEL$T_BOLD"; fi
  else
    if (( yolo )); then bst="$C_ERR$T_BOLD"; else bst="$C_NEON$T_BOLD"; fi
  fi
  local lpad=$(( (cw - bw) / 2 ))
  (( lpad < 0 )) && lpad=0
  _tui_blank "$lpad"; local lp=$UI_S
  _tui_blank $(( cw - bw - lpad > 0 ? cw - bw - lpad : 0 ))
  TUI_FRAME[row]="$bc│$T_OFF$lp$bst$btn$T_OFF$UI_S$bc│$T_OFF"
  TUI_HIT[$row]=6
  row=$(( row + 1 ))
  _tb_bot "$w" "$bc"; TUI_FRAME[row]=$TB
  TUI_KEYS=() TUI_KEYS_R=()
  if (( CF_SEL == 6 )); then _tk '↵' 'launch' ENTER; _tk '↑↓' 'settings'
  else _tk '↵' 'change' ENTER; _tk '↑↓' 'move'; fi
  _tk esc 'back' ESC; _tk q 'cancel' q
  _tkr '?' 'help' '?'
  _tui_footer "$tr"
  tui_flush
}

# _tui_confirm_screen → 0 launched / cancelled to hub, 2 back to zone step
_tui_confirm_screen() {
  CF_SEL=6
  while :; do
    TUI_REDRAW_FN=_tui_render_confirm
    _tui_render_confirm
    _tui_wait_key
    if [ "$KEY" = MOUSE ]; then
      case $MB in
        64) KEY=UP ;;
        65) KEY=DOWN ;;
        0)
          if _tui_zone_token; then KEY=$ZT
          elif [ -n "${TUI_HIT[$MY]+x}" ]; then
            if (( TUI_HIT[$MY] == CF_SEL )); then KEY=ENTER; else CF_SEL=${TUI_HIT[$MY]}; continue; fi
          else continue; fi ;;
        *) continue ;;
      esac
    fi
    case $KEY in
      UP|k|K|BTAB) (( CF_SEL > 0 )) && CF_SEL=$(( CF_SEL - 1 )) ;;
      DOWN|j|J|TAB) (( CF_SEL < 6 )) && CF_SEL=$(( CF_SEL + 1 )) ;;
      HOME) CF_SEL=0 ;;
      END) CF_SEL=6 ;;
      ENTER|SPACE|RIGHT)
        if (( CF_SEL == 6 )); then _tui_launch && return 0
        else _tui_toggle "${CF_KEYS[CF_SEL]}"; fi ;;
      o|y|e|p|w|g) _tui_toggle "$KEY" ;;
      ESC|LEFT|BACKSPACE|h) return 2 ;;
      q|Q|EOF) return 0 ;;
      '?') _tui_help ;;
      TIMEOUT) TUI_HOST=$(host_stats_label) ;;
    esac
  done
}

# Launches with the current settings. Background: launch_agent … porcelain (prints the session
# name). Foreground: launch_agent … return (attaches; we come back when the user detaches).
_tui_launch() {
  local rc=0 out name
  [ "$ROLE" = reader ] && PERM_MODE=plan
  local tx t2
  _tv tx 'Could not launch the agent'
  if ! declare -F launch_agent >/dev/null; then tui_alert "$tx" "launch_agent is not available"; return 1; fi
  if (( BG )); then
    _tv t2 'Launching %s in %s…' "$AGENT" "$ZONE"; tui_toast info "$t2"
    _tui_render_confirm
    out=$(launch_agent "$AGENT" "$ZONE" "$ROLE" "$PERM_MODE" "$REMOTE" "$PROFILE" "$WORKTREE" porcelain 2>&1) || rc=$?
    if (( rc )); then
      tui_alert "$tx" "${out:-launch_agent: exit $rc}"
      return 1
    fi
    name=${out%$'\n'}; name=${name##*$'\n'}
    if valid_session_name "$name"; then
      TUI_SEL_KEY="s:$name"; _tui_short "$name"
      _tv t2 'Agent %s running (background)' "$UI_S"; tui_toast ok "$t2"
    else
      _tv t2 'Agent %s launched in the background' "$AGENT"; tui_toast ok "$t2"
    fi
  else
    name=$(session_name_for "$AGENT" "$ZONE" "$ROLE" "$WORKTREE")
    if ! _tui_run_fullscreen 1 launch_agent "$AGENT" "$ZONE" "$ROLE" "$PERM_MODE" "$REMOTE" "$PROFILE" "$WORKTREE" return; then
      tui_alert "$tx" "${TUI_LAST_ERR:-launch_agent failed}"
      return 1
    fi
    TUI_SEL_KEY="s:$name"; _tui_short "$name"
    _tv t2 'Back in Prama · %s keeps running' "$UI_S"; tui_toast info "$t2"
  fi
  tui_collect 0
  return 0
}

# ── Compatibility helpers ───────────────────────────────────────────────────
prompt_send_task_modal() { [ -n "${1:-}" ] && _tui_task "$1"; return 0; }
prompt_worktree_modal()  { _tui_toggle w; }

# Split-screen fuzzy inspector (fzf + live tmux preview on the prama socket).
# Usable from the CLI (`prama-agent fzf`) and from the TUI (which suspends around it).
launch_fzf_cockpit() {
  if ! command -v fzf >/dev/null 2>&1; then warn "$(_t 'fzf is not installed (apt install fzf)')"; return 1; fi
  refresh_dimensions
  local -a names=() lines=()
  local s role st line sock prev_win sel
  mapfile -t names < <(prama_sessions)
  if (( ${#names[@]} == 0 )); then warn "$(_t 'No sessions to inspect')"; return 1; fi
  for s in "${names[@]}"; do
    role=$(session_role "$s")
    st=$(detect_session_state "$s")
    printf -v line '%-34s %-12s %s' "$s" "$role" "$st"
    lines+=("$line")
  done
  # fzf substitutes {1} with a single-quoted token, so it must stay outside double quotes:
  #   -t ={1}:  →  -t ='prama-x':  →  -t =prama-x:   (exact-match target, active pane)
  printf -v sock '%q' "$PRAMA_TMUX_SOCKET"
  local preview="tmux -L $sock capture-pane -ep -J -t ={1}: -S -80 2>/dev/null"
  prev_win='right:62%:wrap:border-left'
  (( ${TERM_COLS:-$COLS} < 100 )) && prev_win='down:60%:wrap:border-top'
  # fzf draws its UI on stderr: keep it on the terminal even if stderr is redirected.
  sel=$(printf '%s\n' "${lines[@]}" | SHELL=${BASH:-bash} fzf \
    --ansi --layout=reverse --border=rounded \
    --border-label=" ◆ PRAMA · INSPECTOR " \
    --prompt="$(_t 'session') › " \
    --header="$(_t '↵ enter · esc back')" \
    --preview="$preview" \
    --preview-window="$prev_win" \
    --color="bg+:$TH_SEL,fg+:$TH_SELFG,hl:$TH_ACCENT,hl+:$TH_OK,border:$TH_BORDER,label:$TH_ACCENT,header:$TH_MUTED,prompt:$TH_OK,pointer:$TH_ACCENT" \
    2>/dev/tty) || return 0
  sel=${sel%% *}
  valid_session_name "$sel" || return 0
  tmx_has "$sel" || return 0
  ( _tui_locale_restore; tmx_attach "$sel" )
  return 0
}
