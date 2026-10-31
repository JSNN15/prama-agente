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
#   tui_confirm <question> [danger] [yes_lbl]  0 = yes (s/S/y/Y)
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
HUB_ACTIONS=(new swarm cockpit telegram doctor)
declare -ga TUI_FRAME=() TUI_PREV=() TUI_ZONES=() TUI_KEYS=() TUI_KEYS_R=() HUB_ITEMS=()
declare -ga S_NAME=() S_PID=() S_DEAD=() S_CMD=() S_ATT=() S_PATH=() S_STATE=() S_ROLE=()
declare -ga S_CPU=() S_MEM=() S_ETIME=() S_COMM=() PV=() LP=() RP=()
declare -gA TUI_HIT=() TUI_ROLE_CACHE=() TUI_MCACHE=() TUI_VISIBLE=()

# ── Styles (attribute-only fallbacks keep focus visible under NO_COLOR) ─────
tui_styles() {
  if (( IS_TERM )); then
    T_OFF=$'\e[0m' T_BOLD=$'\e[1m' T_DIM=$'\e[2m' T_REV=$'\e[7m'
  else
    T_OFF='' T_BOLD='' T_DIM='' T_REV=''
  fi
  if (( HAS_COLOR )); then
    T_SEL=$BAR_ON T_HEAD=$C_HEAD_BG
    ui_rgb fg 254 226 226
    T_WARN="$C_WARN_BG$UI_S"$'\e[1m'
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

_tui_state_es() {
  case $1 in
    WORKING) UI_S='trabaja' ;;
    READY)   UI_S='listo' ;;
    STANDBY) UI_S='espera' ;;
    DAEMON)  UI_S='daemon' ;;
    SHELL)   UI_S='shell' ;;
    DEAD)    UI_S='caído' ;;
    BLOCKED) UI_S='bloqueado' ;;
    BOT)     UI_S='bot' ;;
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
    coordinator) UI_S='planifica y reparte trabajo' ;;
    reader)      UI_S='solo lectura (fuerza PLAN)' ;;
    daemon)      UI_S='procesa la cola en bucle' ;;
    *)           UI_S='ejecuta tareas' ;;
  esac
}

# _tui_perm_label <mode> → UI_S (label) UI_C (color) UI_D (description)
_tui_perm_label() {
  case $1 in
    yolo) UI_S='▲ YOLO' UI_C="$C_ERR$T_BOLD" UI_D='sin pedir confirmación' ;;
    plan) UI_S='◉ PLAN' UI_C=$C_NEON UI_D='solo lectura / planificación' ;;
    *)    UI_S='● ASK'  UI_C=$C_LIVE UI_D='confirma cada acción' ;;
  esac
}

_tui_mem_fmt() {
  local m=${1%MB}
  [[ $m =~ ^[0-9]+$ ]] || { UI_S='—'; return; }
  if (( m >= 1024 )); then printf -v UI_S '%d.%dG' $(( m / 1024 )) $(( (m % 1024) * 10 / 1024 ))
  else UI_S="${m}M"; fi
}

_tui_menu_key_label() {
  local k=${PRAMA_MENU_KEY:-M-m}
  k=${k//M-/Alt+}; k=${k//C-/Ctrl+}
  UI_S=$k
}

# _tui_keycap <key> <label> → KC (ansi) KCW (width)
_tui_keycap() {
  ui_width "$1"; local kw=$UI_W
  ui_width "$2"
  if (( HAS_COLOR )); then KC="$KEY_BADGE $1 $T_OFF $C_MUTED$2$T_OFF"
  else KC="[$1] $2"; fi
  KCW=$(( kw + 3 + UI_W ))
}

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
  ui_gradient "$brand" 56 189 248 192 132 252; local gb=$UI_S
  ui_width "$brand"; local lw=$(( 4 + UI_W + 1 + ${#ver} ))
  local hostp=''
  [ "$TUI_MODE" != compact ] && [ -n "$host" ] && hostp="  $host"
  local n=${#S_NAME[@]} counts='' cw=0
  if (( n > 0 )); then
    if [ "$TUI_MODE" = compact ]; then counts="● $n"
    else
      counts="● $n activos"
      (( TUI_NWORK > 0 )) && counts+=" · $TUI_NWORK trabajando"
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
  local wt=${WORKTREE:-—} bgl=abrir
  (( BG )) && bgl='segundo plano'
  if [ "$TUI_MODE" = compact ]; then
    local s=" $rc$rl$T_OFF $C_MUTED·$T_OFF $pc$pl$T_OFF $C_MUTED·$T_OFF $PROFILE"
    [ -n "$WORKTREE" ] && s+=" $C_MUTED·$T_OFF $C_PURP⎇ $WORKTREE$T_OFF"
    (( BG )) && s+=" $C_MUTED· fondo$T_OFF"
    _tui_crumbs_line "$row" "${s# }"
    return
  fi
  local -a chips=("o|Rol|$rl|$rc" "y|Permisos|$pl|$pc" "e|Remoto|$rem|$C_TEXT" "p|Perfil|$PROFILE|$C_TEXT"
                  "w|Worktree|$wt|$C_PURP" "g|Al lanzar|$bgl|$C_TEXT")
  local out=' ' used=1 chip k n v c cw
  if [ "$TUI_MODE" = wide ]; then out+="${C_MUTED}Próximo agente ›$T_OFF "; used=$(( used + 17 )); fi
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
    k=${item%%|*}; item=${item#*|}; l=${item%%|*}; t=${item#*|}
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
    for item in "${TUI_KEYS[@]}"; do
      k=${item%%|*}; item=${item#*|}; l=${item%%|*}; t=${item#*|}
      _tui_keycap "$k" "$l"
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
  local r msg="Ventana muy pequeña"
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
  lines+=("" "$KEY_BADGE ↵ $T_OFF ${C_MUTED}cerrar$T_OFF")
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
  local q=$1 danger=${2:-0} yes=${3:-Sí} ans=''
  if (( ! TUI_ACTIVE )); then
    printf ' %s [s/N] ' "$q" >&2
    IFS= read -r ans || return 1
    [[ $ans == [sSyY]* ]]
    return
  fi
  local bc=$C_NEON yc=$C_LIVE
  (( danger )) && { bc=$C_ERR; yc="$C_ERR$T_BOLD"; }
  local w=$(( TUI_TC > 64 ? 60 : TUI_TC - 2 ))
  _tui_wrap "$q" $(( w - 4 ))
  local -a lines=("${WRAP[@]}" "")
  _tui_keycap s "$yes"; local yw=$KCW
  local btn
  if (( HAS_COLOR )); then btn="$KEY_BADGE s $T_OFF $yc$yes$T_OFF     $KEY_BADGE N $T_OFF ${C_MUTED}No$T_OFF"
  else btn="[s] $yes     [N] No"; fi
  lines+=("$btn")
  MODAL_HINT='esc cancela'
  local title='Confirmar'
  (( danger )) && title='▲ Confirmar'
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
  local -a lines=("" "" "${C_MUTED}↵ confirmar · ↵ vacío cancela$T_OFF")
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

_tui_help() {
  _tui_menu_key_label; local mk=$UI_S
  local K="$C_NEON$T_BOLD" O=$T_OFF M="$C_MUTED$T_BOLD"
  local -a L
  if (( TUI_TC >= 60 )); then
    L=(
      "${M}NAVEGACIÓN$O"
      "  ${K}↑ ↓  j k$O   mover              ${K}↵$O         entrar / abrir"
      "  ${K}/$O          filtrar sesiones   ${K}esc ← ⌫$O   volver"
      "  ${K}1-9$O        ir al elemento     ${K}?$O         esta ayuda"
      ""
      "${M}SESIÓN SELECCIONADA$O"
      "  ${K}t$O  enviar tarea               ${K}l$O  logs completos"
      "  ${K}r$O  reiniciar                  ${K}x$O  cerrar (confirma)"
      "  ${K}c$O  cockpit de su zona         ${K}f$O  inspector fzf"
      ""
      "${M}AJUSTES DEL PRÓXIMO AGENTE$O"
      "  ${K}o$O rol   ${K}y$O permisos   ${K}e$O remoto   ${K}p$O perfil LLM"
      "  ${K}w$O worktree   ${K}g$O abrir al lanzar / segundo plano"
      ""
      "${M}GLOBAL$O"
      "  ${K}n$O  nuevo agente   ${K}s$O  nuevo equipo   ${K}q$O  salir"
      "  toque o clic: selecciona · segundo toque: abre"
      ""
      "${M}DENTRO DE UN AGENTE O DEL COCKPIT$O (el agente sigue)"
      "  ${K}$mk$O  volver a este menú          (botón «◂ MENU»)"
      "  ${K}$PRAMA_NAV_KEY$O  lista de agentes, ir a otro  («☰ AGENTES»)"
      "  ${K}$PRAMA_COCKPIT_KEY$O  cockpit del equipo ⇄ agente  («▦ COCKPIT»)"
      "  ${K}Ctrl+b n/p$O siguiente/anterior · ${K}Ctrl+b z$O agrandar panel"
    )
  else
    L=(
      "${M}MOVER$O  ${K}↑↓$O ${K}jk$O · ${K}↵$O abrir · ${K}esc$O volver"
      "       ${K}/$O filtrar · ${K}1-9$O ir"
      "${M}SESIÓN$O ${K}t$O tarea · ${K}l$O logs · ${K}r$O reinicia"
      "       ${K}x$O cerrar · ${K}c$O cockpit · ${K}f$O fzf"
      "${M}AJUSTE$O ${K}o$O rol · ${K}y$O permisos · ${K}e$O remoto"
      "       ${K}p$O perfil · ${K}w$O worktree · ${K}g$O fondo"
      "${M}GLOBAL$O ${K}n$O nuevo · ${K}s$O equipo · ${K}q$O salir"
      "       toque = elegir · 2º toque = abrir"
      ""
      "${M}EN UN AGENTE$O ${K}$mk$O menú · ${K}$PRAMA_NAV_KEY$O agentes"
      "       ${K}$PRAMA_COCKPIT_KEY$O cockpit ⇄ agente"
    )
  fi
  local w=68
  (( TUI_TC < 70 )) && w=$TUI_TC
  MODAL_HINT='cualquier tecla cierra'
  _tui_modal "$C_NEON" "Atajos de teclado" "$w" "${L[@]}"
  MODAL_HINT=''
  while :; do
    tui_read_key 1
    case $KEY in
      TIMEOUT|NONE)
        if (( TUI_RESIZED )); then
          TUI_RESIZED=0; tui_measure; tui_invalidate
          (( TUI_TC < 70 )) && w=$TUI_TC
          MODAL_HINT='cualquier tecla cierra'; _tui_modal "$C_NEON" "Atajos de teclado" "$w" "${L[@]}"; MODAL_HINT=''
        fi ;;
      MOUSE) (( MB == 0 )) && break ;;
      *) break ;;
    esac
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
  TUI_HOST=$(host_stats_label)
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
    ui_fit "(sin salida todavía)" "$w"; PV+=("$C_MUTED$UI_S$T_OFF")
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
    _tb_sep "$w" "$bc" "en vivo"; RP+=("$TB")
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
  (( avail - 8 >= min ))      && { HC_STATE=7; avail=$(( avail - 8 )); }
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
  _tui_display_name "${S_NAME[i]}"
  if (( ${S_DEPTH[i]:-0} )); then ui_fit "└ $UI_S" "$HC_NAME"; else ui_fit "$UI_S" "$HC_NAME"; fi
  name=$UI_S
  nc=$C_TEXT
  [ "$st" = DEAD ] && nc=$C_MUTED
  (( sel )) && nc=$T_BOLD
  SR="$base $C_NEON$mark$R $sc●$R $nc$name$R"
  if (( HC_ROLE )); then
    _tui_role_short "${S_ROLE[i]}"; ui_fit "$UI_S" 7; _tui_role_color "${S_ROLE[i]}"
    SR+=" $UI_C$UI_S$R"
  fi
  if (( HC_STATE )); then _tui_state_es "$st"; ui_fit "$UI_S" 7; SR+=" $sc$UI_S$R"; fi
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
    new)      A_ICON='✚' A_LABEL='Nuevo agente'       A_DESC="${AGENTS[*]} en una zona" ;;
    swarm)    A_ICON='❖' A_LABEL='Nuevo equipo'       A_DESC='coordinador + N agentes en una zona' ;;
    cockpit)  A_ICON='▦' A_LABEL='Cockpit'            A_DESC='ver un equipo en vivo, pantalla dividida' ;;
    telegram) A_ICON='➤' A_LABEL='Telegram'           A_DESC='bot 24/7: controla todo desde el móvil'
              (( TUI_TG_RUNNING )) && A_DESC='bot activo · control desde el móvil' ;;
    doctor)   A_ICON='✱' A_LABEL='Doctor'             A_DESC='diagnóstico y reparación del servidor'
              (( TUI_FEEDBACK > 0 )) && A_DESC="$TUI_FEEDBACK reporte(s) de fallos de agentes sin revisar" ;;
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
  if [ -n "$TUI_FILTER" ]; then
    msg=("$C_MUTED○$T_OFF  ${T_BOLD}Sin coincidencias para «$TUI_FILTER»$T_OFF" "" "${C_MUTED}esc limpia el filtro$T_OFF")
  else
    local kb="$KEY_BADGE n $T_OFF" ks="$KEY_BADGE s $T_OFF"
    (( HAS_COLOR )) || { kb='[n]'; ks='[s]'; }
    msg=("$C_MUTED○$T_OFF  ${T_BOLD}Sin agentes activos$T_OFF" ""
         "$kb un agente  ·  $ks un equipo"
         "${C_MUTED}Siguen vivos aunque cierres la terminal$T_OFF")
    (( ZONES_DISCOVERED )) && msg+=("" "${C_MUTED}Primera vez: ${T_OFF}prama-agent setup")
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
  local right
  if (( TUI_FILTER_EDIT )); then right="/$TUI_FILTER▏"
  elif [ -n "$TUI_FILTER" ]; then right="/$TUI_FILTER · $ns de ${#S_NAME[@]}"
  elif (( ns > vh )); then right="$(( TUI_SCROLL + 1 ))-$(( TUI_SCROLL + vh )) de $ns"
  else right=$ns; fi
  _tb_top "$w" "Sesiones" "$T_BOLD$C_NEON" "$right" "$bc"; LP+=("$TB")
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
  _tb_sep "$w" "$bc" "Acciones"; LP+=("$TB")
  for ((r = 0; r < na; r++)); do
    j=$(( ns + r ))
    _tui_arow "${HUB_ACTIONS[r]}" $(( j == TUI_SEL )) "$cw"
    TUI_HIT[$(( row0 + 2 + vh + r ))]=$j
    LP+=("$bc│$T_OFF$SR$bc│$T_OFF")
  done
  local hint=''
  (( ns > TUI_SCROLL + vh )) && hint="▼ $(( ns - TUI_SCROLL - vh )) más"
  _tb_bot "$w" "$bc" "$hint"; LP+=("$TB")
}

# Body text for the selected hub action → BODY (ansi lines, wrapped to <cw>)
_tui_action_body() {
  local id=$1 cw=$2 p K="$C_NEON$T_BOLD" O=$T_OFF M=$C_MUTED
  BODY=()
  _tui_para() { _tui_wrap "$1" "$cw"; BODY+=("${WRAP[@]}"); }
  case $id in
    new)
      _tui_para "Lanza un agente de código dentro de tmux, en una de tus zonas (repositorios git). Sigue vivo aunque se caiga el SSH."
      BODY+=("" "${M}Ajustes del próximo agente:$O")
      _tui_perm_label "$PERM_MODE"; local pl="$UI_C$UI_S$O $M— $UI_D$O"
      _tui_role_icon "$ROLE"; local ri=$UI_S
      _tui_role_color "$ROLE"
      BODY+=("  ${K}o$O  Rol        $UI_C$ri $ROLE$O")
      BODY+=("  ${K}y$O  Permisos   $pl")
      local rem=off; (( REMOTE )) && rem=on
      BODY+=("  ${K}e$O  Remoto     $rem")
      BODY+=("  ${K}p$O  Perfil     $PROFILE")
      BODY+=("  ${K}w$O  Worktree   ${WORKTREE:-—}")
      if (( BG )); then BODY+=("  ${K}g$O  Al lanzar  segundo plano")
      else BODY+=("  ${K}g$O  Al lanzar  abrir y volver aquí al salir"); fi
      if [ "$PERM_MODE" = yolo ]; then
        BODY+=("")
        _tui_wrap "▲ YOLO activo: el agente ejecutará comandos y editará archivos sin pedir confirmación." "$cw"
        for p in "${WRAP[@]}"; do BODY+=("$C_ERR$T_BOLD$p$O"); done
      fi
      BODY+=("" "Pulsa $K↵$O para elegir agente y zona.")
      ;;
    swarm)
      _tui_para "Lanza un coordinador y varios agentes ejecutores en una zona. El coordinador recibe la lista de su equipo y tu objetivo, delega por el bus y puede sumar, cambiar de modelo o cerrar agentes."
      BODY+=("" "  $K•$O Zona → nombre del equipo → agente → cuántos → objetivo"
             "  $K•$O Varios equipos por zona: arquitectura, seguridad, docs…"
             "  $K•$O Un nombre que ya existe suma agentes a ese equipo"
             "  $K•$O Se abre el cockpit del equipo al terminar" "" "Pulsa $K↵$O para crear el equipo.")
      ;;
    cockpit)
      _tui_para "Pantalla dividida con el equipo de una zona: coordinador a la izquierda, agentes a la derecha y el bus en vivo. Se actualiza solo cuando entran o salen agentes."
      _tui_menu_key_label
      BODY+=("" "  $K${PRAMA_COCKPIT_KEY}$O  cockpit ⇄ agente con el foco" "  $K${PRAMA_NAV_KEY}$O  lista de agentes (ir a cualquiera)"
             "  $K$UI_S$O  volver a este menú" "  ${K}Ctrl+b z$O  agrandar el panel con el foco" "" "Pulsa $K↵$O o ${K}c$O para abrirlo.")
      ;;
    telegram)
      _tui_para "Controla tus agentes desde el móvil con un bot de Telegram 24/7, aunque cierres Termius."
      BODY+=("")
      if (( TUI_TG_RUNNING )); then BODY+=("Estado: $C_LIVE● bot activo$O")
      else BODY+=("Estado: $M○ detenido$O"); fi
      BODY+=("" "Pulsa $K↵$O para vincular, iniciar o detener el bot.")
      ;;
    doctor)
      _tui_para "Diagnóstico y reparación del servidor:"
      BODY+=("" "  $K•$O dependencias y agentes instalados" "  $K•$O clientes tmux colgados o sesiones zombi"
             "  $K•$O configuración de tmux y botón «◂ MENU»" "  $K•$O metadatos huérfanos"
             "  $K•$O reportes de fallos de los agentes (prama-agent feedback list)" "" "Pulsa $K↵$O para ejecutarlo.")
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
    _tui_state_es "$st"; local stl=$UI_S
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
      m1="$C_ERR$T_BOLD▲ bloqueado: ${info%%|*}$T_OFF $C_MUTED${info#*|}$T_OFF"
    fi
    if [ "${TUI_QKEY:-}" != "$s|$TUI_LAST_COLLECT" ]; then
      TUI_QKEY="$s|$TUI_LAST_COLLECT"
      TUI_QLEN=$(queue_len "$s" 2>/dev/null) || TUI_QLEN=0
    fi
    q=$TUI_QLEN
    [[ $q =~ ^[0-9]+$ ]] && (( q > 0 )) && m2+="  $C_BRASS✉ $q en cola$T_OFF"
    (( ${S_ATT[si]:-0} > 0 )) && m2+="  $C_LIVE◉ conectado$T_OFF"
    if [ "$TUI_MODE" = compact ]; then
      hint='↵ entrar'
      m1="$sc● $stl$T_OFF $C_MUTED·$T_OFF CPU $c% $C_MUTED·$T_OFF $mem $C_MUTED· ${S_ETIME[si]}$T_OFF"
      if (( h >= 12 )); then _tui_preview_box "$w" "$h" "$s" "◉ $s" "" "$hint" "$m1"
      else _tui_preview_box "$w" "$h" "$s" "◉ $s" "$stl" "$hint"; fi
    else
      hint='↵ entrar · t tarea · l logs'
      _tui_preview_box "$w" "$h" "$s" "◉ $s" "" "$hint" "$m1" "$m2"
    fi
  else
    local id=${item#a:}
    _tui_action_meta "$id"
    _tui_action_body "$id" "$cw"
    _tui_text_box "$w" "$h" "$A_ICON $A_LABEL" "$T_BOLD$C_TEXT" "" "${BODY[@]}"
  fi
}

_tui_hub_footer() {
  local item=${HUB_ITEMS[TUI_SEL]-}
  if (( TUI_FILTER_EDIT )); then
    TUI_KEYS=("↵|aplicar|ENTER" "esc|limpiar|ESC" "↑↓|mover|")
  elif [[ $item == s:* ]]; then
    TUI_KEYS=("↵|entrar|ENTER" "c|cockpit|c" "t|tarea|t" "l|logs|l" "r|reiniciar|r" "x|cerrar|x" "n|nuevo|n" "s|equipo|s" "/|filtrar|/")
  else
    TUI_KEYS=("↵|abrir|ENTER" "n|nuevo|n" "s|equipo|s" "c|cockpit|c" "/|filtrar|/")
  fi
  if [ "$TUI_MODE" = compact ]; then TUI_KEYS_R=("?|más|?")
  else TUI_KEYS_R=("?|ayuda|?" "q|salir|q"); fi
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
  if ! declare -F "$1" >/dev/null; then tui_toast err "Función no disponible: $1"; return 0; fi
  TUI_CRUMBS="Menú › $crumb"
  tui_soft_suspend
  (( pause )) && printf '\n %s%s%s\n\n' "$C_NEON$T_BOLD" "$crumb" "$T_OFF"
  ( "$@" ) || rc=$?
  if (( pause )); then
    printf '\n %s ↵ %s Pulsa una tecla para volver ' "$KEY_BADGE" "$T_OFF"
    IFS= read -rsn1 _ || true
  fi
  TUI_CRUMBS=$prev
  tui_soft_resume
  tui_collect 0
  (( rc )) && tui_toast err "$crumb terminó con error (código $rc)"
  return 0
}

tui_attach_session() {
  local s=$1
  _tui_short "$s"; local short=$UI_S
  if ! tmx_has "$s"; then tui_toast err "La sesión $short ya no existe"; tui_collect 0; return 0; fi
  if _tui_run_fullscreen 1 tmx_attach "$s"; then
    tui_toast info "De vuelta en Prama · $short sigue activa"
  else
    tui_alert "No se pudo entrar a $short" "${TUI_LAST_ERR:-tmux attach falló}"
  fi
  tui_collect 0
}

_tui_task() {
  local s=$1 text='' out rc=0
  _tui_short "$s"; local short=$UI_S
  tui_prompt "Tarea para $short" text || return 0
  out=$(subcmd_bus assign "$s" "$text" 2>&1) || rc=$?
  if (( rc == 0 )); then tui_toast ok "Tarea enviada a $short"
  else tui_alert "No se pudo enviar la tarea" "${out:-error $rc}"; fi
}

_tui_logs() {
  local s=$1
  if command -v less >/dev/null 2>&1; then
    _tui_short "$s"
    tui_suspend
    tmx_capture "$s" 2000 1 | less -R +G "-Ps logs $UI_S  (q vuelve, / busca) " 2>/dev/null
    tui_resume
  else
    tui_soft_suspend
    tmx_capture "$s" $(( TUI_TR - 3 )) 1
    printf '\n %s ↵ %s Pulsa una tecla para volver ' "$KEY_BADGE" "$T_OFF"
    IFS= read -rsn1 _ || true
    tui_soft_resume
  fi
}

_tui_session_action() {
  local k=$1 s=$2 short
  _tui_short "$s"; short=$UI_S
  case $k in
    t) _tui_task "$s" ;;
    l) _tui_logs "$s" ;;
    r)
      if tui_confirm "¿Reiniciar «$short»? El agente se relanza en el mismo panel y retoma su conversación." 1 "Reiniciar"; then
        if ( _fleet_restart_in_place "$s" ) >/dev/null 2>&1; then tui_toast ok "$short se está reiniciando"
        else tui_toast err "No se pudo reiniciar $short"; fi
        tui_collect 0
      fi ;;
    x)
      # A coordinator with agents: one confirmation closes its whole team (and its cockpit);
      # other teams of the same zone keep working.
      local label members=0 m
      if [ "$(session_role "$s")" = coordinator ]; then
        label=$(team_label "$s")
        while IFS= read -r m; do [ "$(state_get "$m" PARENT)" = "$s" ] && (( members++ )); done < <(prama_sessions)
        if (( members )); then
          if tui_confirm "¿Cerrar el equipo «$label»? Se detienen el coordinador y sus $members agente(s)." 1 "Cerrar equipo"; then
            if ( _swarm_stop "$s" ) >/dev/null 2>&1; then tui_toast ok "Equipo $label cerrado ($(( members + 1 )) agentes)"
            else tui_toast err "No se pudo cerrar el equipo $label"; fi
            TUI_ROLE_CACHE=() TUI_MCACHE=()
            tui_collect 0
          fi
          return 0
        fi
      fi
      if tui_confirm "¿Cerrar «$short»? El agente se detendrá y se perderá lo que no haya guardado." 1 "Cerrar"; then
        tmx_kill "$s"
        state_remove "$s"
        unset "TUI_ROLE_CACHE[$s]" "TUI_MCACHE[$s]"
        tui_toast ok "Sesión $short cerrada"
        tui_collect 0
      fi ;;
  esac
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
    if (( ${#zs[@]} == 0 )); then tui_toast info "No hay agentes: crea un equipo (❖ Nuevo equipo)"; return 0; fi
    for z in "${zs[@]}"; do
      while IFS= read -r c; do
        local n=0 m
        while IFS= read -r m; do [ "$(state_get "$m" PARENT)" = "$c" ] && (( n++ )); done < <(prama_sessions)
        CK_LABELS+=("$(team_label "$c")") CK_METAS+=("coordinador + $n agente(s)") CK_AVAIL+=(1) CK_TARGETS+=("")
        scopes+=("$c"); teamed[$z]=1
      done < <(zone_teams "$z")
      if [ -z "${teamed[$z]:-}" ]; then
        CK_LABELS+=("$z") CK_METAS+=("${cnt[$z]} agente(s) sin coordinador") CK_AVAIL+=(1) CK_TARGETS+=("")
        scopes+=("$z")
      fi
    done
    if (( ${#scopes[@]} > 1 )); then
      TUI_LIST_CRUMBS="${C_MUTED}Menú$T_OFF $C_MUTED›$T_OFF ${T_BOLD}Cockpit$T_OFF"
      local rc=0; tui_list_run "¿Qué equipo quieres ver?" CK_LABELS CK_METAS CK_AVAIL CK_TARGETS 0 || rc=$?
      TUI_LIST_CRUMBS=''; tui_invalidate
      (( rc )) && return 0
      scopes=("${scopes[CHOICE]}")
    fi
  fi
  if ! _tui_run_fullscreen 1 subcmd_cockpit "${scopes[0]}"; then
    tui_alert "No se pudo abrir el cockpit" "${TUI_LAST_ERR:-${scopes[0]}}"
  fi
  tui_collect 0
}

# tui_new_team — zone → team → worker agent → how many → objective, then `swarm` (opens the
# cockpit). A zone can hold several teams: an existing name adds agents to that team.
tui_new_team() {
  local step=1 rc i zone='' team='' wa='' n=2 task='' coord=claude
  is_in claude "${AGENTS[@]}" && agent_installed claude || coord=${AGENTS[0]}
  TUI_GIT_CACHE=()
  _tui_agent_lists
  local -a NL=() NM=() NA=() NT=()
  for i in 1 2 3 4 5 6; do NL+=("$i"); NM+=("$i agente(s) ejecutor(es) + 1 coordinador ($coord)"); NA+=(1); NT+=(""); done
  while :; do
    TUI_LIST_CRUMBS="${C_MUTED}Menú$T_OFF $C_MUTED›$T_OFF ${T_BOLD}Nuevo equipo$T_OFF $C_MUTED›$T_OFF ${zone:-zona}${team:+ · $team}${wa:+ · $wa}"
    case $step in
      1) AGENT=$coord; _tui_zone_lists
         rc=0; tui_list_run "¿En qué zona trabajará el equipo?" ZN_LABELS ZN_METAS ZN_AVAIL ZN_TARGETS -1 || rc=$?
         (( rc )) && break
         zone=${ZONES[CHOICE]}; step=15 ;;
      15) # Team: a new name creates a team with its own coordinator; an existing one adds agents.
         local existing def=''
         existing=$(_swarm_teams_hint "$zone")
         [ -n "$existing" ] || def=$PRAMA_DEFAULT_TEAM
         team=''
         if ! tui_prompt "Nombre del equipo${existing:+ (en $zone: $existing; un nombre existente suma agentes)}" team "$def"; then
           step=1; continue
         fi
         team=${team,,}; team=${team// /-}
         if ! valid_team_name "$team"; then
           tui_alert "Nombre de equipo inválido" "Usa minúsculas, números y guiones (máx. 20), p. ej. seguridad o docs."
           continue
         fi
         step=2 ;;
      2) rc=0; tui_list_run "Agente para los ejecutores" AG_LABELS AG_METAS AG_AVAIL AG_TARGETS -1 || rc=$?
         if (( rc )); then step=15; continue; fi
         wa=${AGENTS[CHOICE]}; step=3 ;;
      3) rc=0; tui_list_run "¿Cuántos ejecutores $wa?" NL NM NA NT 1 || rc=$?
         if (( rc )); then step=2; continue; fi
         n=${NL[CHOICE]}; step=4 ;;
      4) task=''
         tui_prompt "Objetivo para el coordinador (opcional)" task || task=''
         TUI_LIST_CRUMBS=''; tui_invalidate
         if ! _tui_run_fullscreen 1 subcmd_swarm "$zone" --team "$team" --coord "$coord" --workers "$wa:$n" ${task:+--task "$task"}; then
           tui_alert "No se pudo crear el equipo" "${TUI_LAST_ERR:-revisa prama-agent doctor}"
         fi
         break ;;
    esac
  done
  TUI_LIST_CRUMBS=''
  tui_invalidate
  tui_collect 0
  return 0
}

_tui_fzf() {
  if ! command -v fzf >/dev/null 2>&1; then tui_toast err "fzf no está instalado (apt install fzf)"; return 0; fi
  if (( ${#S_NAME[@]} == 0 )); then tui_toast info "No hay sesiones que inspeccionar"; return 0; fi
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
  case $1 in
    o)
      cycle_role
      if [ "$ROLE" = reader ]; then tui_toast info "Rol: reader · permisos forzados a PLAN"
      else tui_toast info "Rol del próximo agente: $ROLE"; fi ;;
    y)
      if [ "$ROLE" = reader ]; then tui_toast info "El rol reader siempre usa PLAN (solo lectura)"; return 0; fi
      cycle_perm_mode
      _tui_perm_label "$PERM_MODE"
      if [ "$PERM_MODE" = yolo ]; then tui_toast err "Permisos: ▲ YOLO — el agente no pedirá confirmación"
      else tui_toast info "Permisos: $UI_S — $UI_D"; fi ;;
    e)
      REMOTE=$(( 1 - ${REMOTE:-0} ))
      if (( REMOTE )); then tui_toast info "Control remoto nativo: on (claude/agy)"
      else tui_toast info "Control remoto nativo: off"; fi ;;
    p) cycle_profile; tui_toast info "Perfil LLM: $PROFILE" ;;
    w)
      local v=''
      if tui_prompt "Rama del worktree (vacío = sin worktree)" v "$WORKTREE"; then
        if [[ $v =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,62}$ ]] && [[ $v != *..* ]]; then
          WORKTREE=$v; tui_toast ok "Worktree aislado: $WORKTREE"
        else
          tui_toast err "Nombre de rama no válido: $v"
        fi
      elif (( ! TUI_PROMPT_CANCELLED )) || [ -z "$v" ]; then
        [ -n "$WORKTREE" ] && tui_toast info "Sin worktree (directorio de la zona)"
        WORKTREE=''
      fi ;;
    g)
      BG=$(( 1 - ${BG:-0} ))
      if (( BG )); then tui_toast info "Al lanzar: en segundo plano"
      else tui_toast info "Al lanzar: abrir y volver aquí al salir"; fi ;;
  esac
}

# ── Hub input ───────────────────────────────────────────────────────────────
_tui_hub_activate() {
  local item=${HUB_ITEMS[TUI_SEL]-}
  case $item in
    s:*)         tui_attach_session "${S_NAME[${item#s:}]}" ;;
    a:new)       tui_new_agent ;;
    a:swarm)     tui_new_team ;;
    a:cockpit)   _tui_cockpit "" ;;
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
      else tui_toast info "Selecciona primero una sesión (↑↓)"; fi ;;
    c|C)                _tui_cockpit "$s" ;;
    f|F)                _tui_fzf ;;
    /)                  TUI_FILTER_EDIT=1 ;;
    ESC|LEFT|BACKSPACE|h)
      if [ -n "$TUI_FILTER" ]; then TUI_FILTER=''
      else tui_toast info "Pulsa q para salir"; fi ;;
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
  printf '%s v%s — el menú interactivo necesita una terminal (TTY).\n' "${PRAMA_BRAND:-PRAMA AGENT}" "${VERSION:-?}"
  while IFS= read -r s; do
    [ -n "$s" ] && printf '  ● %-40s %s\n' "$s" "$(session_role "$s")"
  done < <(prama_sessions)
  printf 'Uso: prama-agent <agente> <zona> · prama-agent status · prama-agent attach <sesión>\n'
}

# tui_main — interactive hub. Uses/updates AGENT ZONE ROLE PERM_MODE REMOTE PROFILE WORKTREE BG.
tui_main() {
  if (( ! IS_TERM )) || [ ! -t 0 ] || [ ! -t 1 ]; then tui_plain_fallback; return 1; fi
  : "${ROLE:=executor}" "${PERM_MODE:=ask}" "${REMOTE:=0}" "${PROFILE:=default}" "${BG:=0}"
  : "${WORKTREE:=}" "${AGENT:=}" "${ZONE:=}"
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
  local n=${#_tl_lab[@]} i sel=-1 pos=0 scroll=0 f='' fedit=0
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
        (( sel >= 0 )) && tui_toast err "No disponible: ${_tl_lab[sel]} (${_tl_met[sel]##*· })" ;;
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
  elif [ -n "$f" ]; then right="/$f · $nv de $n"
  elif (( nv > vh )); then right="$(( scroll + 1 ))-$(( scroll + vh )) de $nv"
  else right="$n opciones"; fi
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
      ui_fit "  Sin resultados · esc limpia el filtro" "$cw"; SR="$C_MUTED$UI_S$T_OFF"
    elif (( j < nv )); then
      _tui_lrow "${vis[j]}" $(( vis[j] == sel )) "$cw" "$lw"
      TUI_HIT[$(( 4 + r ))]=${vis[j]}
    else SR=$blank; fi
    TUI_FRAME[4 + r]="$bc│$T_OFF$SR$bc│$T_OFF"
  done
  local hint=''
  (( nv > scroll + vh )) && hint="▼ $(( nv - scroll - vh )) más"
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
      [ "${_tl_ava[sel]:-0}" = 1 ] || dl+=("" "$C_ERR✖ No disponible$T_OFF")
      cap=$(( ${#dl[@]} + 2 ))
      (( cap > dh )) && cap=$dh
      (( cap < 3 )) && cap=3
      _tui_text_box "$w" "$cap" "${_tl_lab[sel]}" "$T_BOLD$C_TEXT" "" "${dl[@]}"
    fi
    for ((r = 0; r < ${#RP[@]}; r++)); do TUI_FRAME[row + r]=${RP[r]}; done
  fi
  if (( fedit )); then TUI_KEYS=("↵|aplicar|ENTER" "esc|limpiar|ESC" "↑↓|mover|")
  else TUI_KEYS=("↵|elegir|ENTER" "↑↓|mover|" "esc|volver|ESC" "/|filtrar|/" "1-9|directo|"); fi
  TUI_KEYS_R=("?|ayuda|?")
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
      "$([ "${_sp_a[i]:-0}" = 1 ] || printf ' (no disponible)')" >&2
  done
  printf ' Opción (vacío = volver): ' >&2
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
  local cur="$C_NEON$T_BOLD" done_c=$C_LIVE fut=$C_MUTED
  if (( step == 1 )); then a="$cur▸ 1 Agente$T_OFF"; else a="$done_c✔ $AGENT$T_OFF"; fi
  if (( step == 2 )); then z="$cur▸ 2 Zona$T_OFF"
  elif (( step > 2 )); then z="$done_c✔ $ZONE$T_OFF"
  else z="${fut}2 Zona$T_OFF"; fi
  if (( step == 3 )); then c="$cur▸ 3 Confirmar$T_OFF"; else c="${fut}3 Confirmar$T_OFF"; fi
  TUI_LIST_CRUMBS="${C_MUTED}Menú$T_OFF$sep${T_BOLD}Nuevo agente$T_OFF$sep$a$sep$z$sep$c"
}

_tui_agent_lists() {
  AG_LABELS=() AG_METAS=() AG_AVAIL=() AG_TARGETS=()
  local i a bin
  for i in "${!AGENTS[@]}"; do
    a=${AGENTS[i]}
    AG_LABELS+=("$a") AG_TARGETS+=("")
    if bin=$(command -v "$a" 2>/dev/null); then
      AG_METAS+=("${AGENT_DESCS[i]:-$a} · ${bin/#$HOME/\~}") AG_AVAIL+=(1)
    else
      AG_METAS+=("${AGENT_DESCS[i]:-$a} · no instalado") AG_AVAIL+=(0)
    fi
  done
}

declare -gA TUI_GIT_CACHE=()
_tui_zone_lists() {
  ZN_LABELS=() ZN_METAS=() ZN_AVAIL=() ZN_TARGETS=() ZN_GIT=()
  local i dir l1 l2 br dirty meta name gi
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
      (( dirty )) && meta+=" ● cambios"
      name=$(session_name_for "$AGENT" "${ZONES[i]}" "$ROLE" "$WORKTREE")
      [ -n "${live[$name]:-}" ] && meta+="  ◉ $AGENT ya activo aquí"
      ZN_METAS+=("$meta") ZN_AVAIL+=(1)
    else
      ZN_GIT+=("—|0")
      ZN_METAS+=("$dir · no existe") ZN_AVAIL+=(0)
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
        rc=0; tui_list_run "Elige el agente" AG_LABELS AG_METAS AG_AVAIL AG_TARGETS "$start" || rc=$?
        if (( rc )); then break; fi
        AGENT=${AGENTS[CHOICE]}; step=2 ;;
      2)
        _tui_wiz_crumbs 2
        _tui_zone_lists
        start=-1
        for i in "${!ZONES[@]}"; do [ "${ZONES[i]}" = "$ZONE" ] && start=$i; done
        rc=0; tui_list_run "Elige la zona de trabajo" ZN_LABELS ZN_METAS ZN_AVAIL ZN_TARGETS "$start" || rc=$?
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
CF_NAMES=("Rol" "Permisos" "Remoto" "Perfil LLM" "Worktree" "Al lanzar")

# _tui_cf_value <idx> → CF_MAIN CF_DESC CF_COLOR
_tui_cf_value() {
  case $1 in
    0) _tui_role_icon "$ROLE"; CF_MAIN="$UI_S $ROLE"; _tui_role_desc "$ROLE"; CF_DESC=" — $UI_S"
       _tui_role_color "$ROLE"; CF_COLOR=$UI_C ;;
    1) _tui_perm_label "$PERM_MODE"; CF_MAIN=$UI_S CF_COLOR=$UI_C CF_DESC=" — $UI_D"
       [ "$ROLE" = reader ] && CF_DESC=' — forzado por el rol reader' ;;
    2) if (( REMOTE )); then CF_MAIN='on' CF_DESC=' — control remoto nativo (claude/agy)'
       else CF_MAIN='off' CF_DESC=''; fi
       CF_COLOR=$C_TEXT ;;
    3) CF_MAIN=$PROFILE CF_DESC=' — proveedor del modelo' CF_COLOR=$C_TEXT ;;
    4) if [ -n "$WORKTREE" ]; then CF_MAIN="⎇ $WORKTREE" CF_DESC=' — rama aislada (git worktree)'
       else CF_MAIN='—' CF_DESC=' sin aislamiento · ↵ para crear rama'; fi
       CF_COLOR=$C_PURP ;;
    5) _tui_menu_key_label
       if (( BG )); then CF_MAIN='segundo plano' CF_DESC=' — no entra a la sesión'
       else CF_MAIN='abrir' CF_DESC=" — vuelves aquí con $UI_S"; fi
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
  if (( yolo )); then
    _tui_wrap "▲ YOLO: el agente ejecutará comandos y editará archivos SIN pedir confirmación." $(( cw - 2 ))
    warn=("${WRAP[@]}")
  fi
  # rows: top + summary + sep + 6 toggles + sep + warn + button + bottom
  local full=$(( 1 + 3 + 1 + 6 + 1 + ${#warn[@]} + 1 + 1 ))
  if (( bh >= full )); then
    summ+=("${M}Agente     $O$T_BOLD$AGENT$O $M· $adesc$O")
    local zl="${M}Zona       $O$T_BOLD$ZONE$O $M· $zdir$O  $C_PURP⎇ $br$O"
    (( dirty )) && zl+=" $C_BRASS● cambios$O"
    summ+=("$zl")
    local sl="${M}Sesión     $O$name"
    (( exists )) && sl+="  $C_BRASS▲ ya activa: se abrirá$O"
    summ+=("$sl")
  else
    local sl="$T_BOLD$AGENT$O $M@$O $T_BOLD$ZONE$O $M→ $name$O"
    (( exists )) && sl+=" $C_BRASS▲ activa$O"
    summ+=("$sl")
  fi
  local row=3
  _tb_top "$w" "Confirmar lanzamiento" "$T_BOLD$C_NEON" "" "$bc"; TUI_FRAME[row]=$TB; row=$(( row + 1 ))
  for i in "${summ[@]}"; do _tb_line "$w" "$bc" "$i"; TUI_FRAME[row]=$TB; row=$(( row + 1 )); done
  _tb_sep "$w" "$bc" "Ajustes · ↵ o tecla para cambiar"; TUI_FRAME[row]=$TB; row=$(( row + 1 ))
  local base R mark full_s vw keyc
  for ((i = 0; i < 6; i++)); do
    base=$T_OFF mark=' '
    (( i == CF_SEL )) && { base=$T_SEL; mark='▸'; }
    R=$T_OFF$base
    _tui_cf_value "$i"
    vw=$(( cw - 18 ))
    (( vw < 4 )) && vw=4
    ui_fit "$CF_MAIN$CF_DESC" "$vw"; full_s=$UI_S
    if [[ $full_s == "$CF_MAIN"* ]]; then full_s="$CF_COLOR$CF_MAIN$R$C_MUTED${full_s:${#CF_MAIN}}$R"
    else full_s="$CF_COLOR$full_s$R"; fi
    ui_fit "${CF_NAMES[i]}" 10
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
  if (( yolo )); then btn='▲ LANZAR EN MODO YOLO'
  elif (( BG )); then btn='▸ LANZAR EN SEGUNDO PLANO'
  else btn='▸ LANZAR Y ABRIR'; fi
  (( exists )) && ! (( BG )) && btn='▸ ABRIR SESIÓN EXISTENTE'
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
  if (( CF_SEL == 6 )); then TUI_KEYS=("↵|lanzar|ENTER" "↑↓|ajustes|" "esc|volver|ESC" "q|cancelar|q")
  else TUI_KEYS=("↵|cambiar|ENTER" "↑↓|mover|" "esc|volver|ESC" "q|cancelar|q"); fi
  TUI_KEYS_R=("?|ayuda|?")
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
  if ! declare -F launch_agent >/dev/null; then tui_alert "No se pudo lanzar" "launch_agent no está disponible"; return 1; fi
  if (( BG )); then
    tui_toast info "Lanzando $AGENT en $ZONE…"
    _tui_render_confirm
    out=$(launch_agent "$AGENT" "$ZONE" "$ROLE" "$PERM_MODE" "$REMOTE" "$PROFILE" "$WORKTREE" porcelain 2>&1) || rc=$?
    if (( rc )); then
      tui_alert "No se pudo lanzar el agente" "${out:-launch_agent terminó con código $rc}"
      return 1
    fi
    name=${out%$'\n'}; name=${name##*$'\n'}
    if valid_session_name "$name"; then
      TUI_SEL_KEY="s:$name"; _tui_short "$name"
      tui_toast ok "Agente $UI_S en marcha (segundo plano)"
    else
      tui_toast ok "Agente $AGENT lanzado en segundo plano"
    fi
  else
    name=$(session_name_for "$AGENT" "$ZONE" "$ROLE" "$WORKTREE")
    if ! _tui_run_fullscreen 1 launch_agent "$AGENT" "$ZONE" "$ROLE" "$PERM_MODE" "$REMOTE" "$PROFILE" "$WORKTREE" return; then
      tui_alert "No se pudo lanzar el agente" "${TUI_LAST_ERR:-launch_agent falló}"
      return 1
    fi
    TUI_SEL_KEY="s:$name"; _tui_short "$name"
    tui_toast info "De vuelta en Prama · $UI_S sigue activa"
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
  if ! command -v fzf >/dev/null 2>&1; then warn "fzf no está instalado en PATH."; return 1; fi
  refresh_dimensions
  local -a names=() lines=()
  local s role st line sock prev_win sel
  mapfile -t names < <(prama_sessions)
  if (( ${#names[@]} == 0 )); then warn "No hay sesiones activas para inspeccionar."; return 1; fi
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
    --prompt="sesión › " \
    --header="↵ entrar · esc volver" \
    --preview="$preview" \
    --preview-window="$prev_win" \
    --color="bg+:#1e3a5f,fg+:#f0f9ff,hl:#38bdf8,hl+:#34d399,border:#334155,label:#38bdf8,header:#64748b,prompt:#34d399,pointer:#38bdf8" \
    2>/dev/tty) || return 0
  sel=${sel%% *}
  valid_session_name "$sel" || return 0
  tmx_has "$sel" || return 0
  ( _tui_locale_restore; tmx_attach "$sel" )
  return 0
}
