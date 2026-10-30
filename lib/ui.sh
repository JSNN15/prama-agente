#!/usr/bin/env bash
# lib/ui.sh — Theme, display-width aware box engine and small visual widgets
# Licensed under the Apache License, Version 2.0
#
# Two families of helpers live here:
#   * Printing helpers (str_width, truncate_cols, box_*, …) — stable API used by every module.
#   * Fork-free "ui_*" helpers that return their result in globals (UI_W, UI_S). The TUI uses
#     these on its hot path so a full frame costs no subshells.

# ── Theme ───────────────────────────────────────────────────────────────────
# IS_TERM   stdout is a terminal that understands escape sequences (cursor, alt screen…)
# HAS_COLOR IS_TERM and colors are allowed (NO_COLOR unset/empty)
# IS_TTY    kept for compatibility: IS_TERM && HAS_COLOR (older callers used it for both)
# UI_COLOR_DEPTH truecolor | 256 (override with PRAMA_COLOR=truecolor|256)

# ui_rgb <fg|bg> r g b → sets UI_S to the escape sequence for the active color depth.
ui_rgb() {
  local layer=38 r=$2 g=$3 b=$4
  [ "$1" = bg ] && layer=48
  if [ "${UI_COLOR_DEPTH:-truecolor}" = truecolor ]; then
    printf -v UI_S '\e[%d;2;%d;%d;%dm' "$layer" "$r" "$g" "$b"
  else
    # Nearest entry in the 6x6x6 cube or the 24-step grey ramp.
    local ri=$(( (r * 5 + 127) / 255 )) gi=$(( (g * 5 + 127) / 255 )) bi=$(( (b * 5 + 127) / 255 ))
    local idx=$(( 16 + 36 * ri + 6 * gi + bi ))
    local mx=$r mn=$r
    (( g > mx )) && mx=$g; (( b > mx )) && mx=$b
    (( g < mn )) && mn=$g; (( b < mn )) && mn=$b
    if (( mx - mn < 12 )); then
      local grey=$(( (r + g + b) / 3 ))
      if (( grey < 8 )); then idx=16
      elif (( grey > 238 )); then idx=231
      else idx=$(( 232 + (grey - 8) / 10 )); fi
    fi
    printf -v UI_S '\e[%d;5;%dm' "$layer" "$idx"
  fi
}

ui_detect_color_depth() {
  case "${PRAMA_COLOR:-}" in
    truecolor|24bit) UI_COLOR_DEPTH=truecolor; return ;;
    256)             UI_COLOR_DEPTH=256; return ;;
  esac
  if [[ "${COLORTERM:-}" == *truecolor* || "${COLORTERM:-}" == *24bit* || "${TERM:-}" == *direct* ]]; then
    UI_COLOR_DEPTH=truecolor
  else
    case "${TERM_PROGRAM:-}" in
      iTerm.app|WezTerm|vscode|ghostty|Hyper|Tabby|rio) UI_COLOR_DEPTH=truecolor ;;
      *) UI_COLOR_DEPTH=256 ;;
    esac
  fi
}

ui_init_theme() {
  IS_TERM=0 HAS_COLOR=0
  if [ -t 1 ] && [ "${TERM:-}" != "dumb" ]; then
    IS_TERM=1
    [ -z "${NO_COLOR:-}" ] && HAS_COLOR=1
  fi
  ui_detect_color_depth
  if (( HAS_COLOR )); then
    ui_rgb fg 56 189 248;   C_NEON=$UI_S       # sky     #38bdf8
    ui_rgb fg 129 140 248;  C_INDIGO=$UI_S     # indigo  #818cf8
    ui_rgb fg 52 211 153;   C_LIVE=$UI_S       # emerald #34d399
    ui_rgb fg 251 191 36;   C_BRASS=$UI_S      # amber   #fbbf24
    ui_rgb fg 248 113 113;  C_ERR=$UI_S        # coral   #f87171
    ui_rgb fg 192 132 252;  C_PURP=$UI_S       # purple  #c084fc
    ui_rgb fg 100 116 139;  C_MUTED=$UI_S      # slate-500
    ui_rgb fg 51 65 85;     C_BORDER=$UI_S     # slate-700
    C_BORDER_HI=$C_NEON
    ui_rgb fg 226 232 240;  C_TEXT=$UI_S       # slate-200 (primary text)
    ui_rgb bg 15 23 42;     C_HEAD_BG=$UI_S    # slate-900 (header bar)
    ui_rgb bg 127 29 29;    C_WARN_BG=$UI_S    # red-900   (danger banners)
    C_DIM=$'\e[2m'
    C_BOLD=$'\e[1m'
    C_OFF=$'\e[0m'
    local sel_bg sel_fg
    ui_rgb bg 30 58 95;     sel_bg=$UI_S
    ui_rgb fg 240 249 255;  sel_fg=$UI_S
    BAR_ON="$sel_bg$sel_fg"$'\e[1m'
    C_SEL=$sel_bg
    ui_rgb bg 30 41 59;     KEY_BADGE=$UI_S
    KEY_BADGE+=$C_NEON$'\e[1m'
    IS_TTY=1
  else
    C_NEON='' C_INDIGO='' C_LIVE='' C_BRASS='' C_ERR='' C_PURP='' C_MUTED='' C_TEXT=''
    C_BORDER='' C_BORDER_HI='' C_DIM='' C_BOLD='' C_OFF='' BAR_ON='' KEY_BADGE=''
    C_HEAD_BG='' C_WARN_BG='' C_SEL=''
    IS_TTY=0
  fi
}
ui_init_theme

# ── Terminal geometry ───────────────────────────────────────────────────────
# Sets COLS (capped 40..120, used by the box engine), W (box width), IS_COMPACT, ROWS and
# TERM_COLS (the real, uncapped width, used by the full-screen TUI).
refresh_dimensions() {
  local _rows='' _cols=''
  if [ -n "${PRAMA_COLS:-}" ]; then
    _cols=$PRAMA_COLS
    _rows=${PRAMA_ROWS:-}
  else
    { read -r _rows _cols < <(stty size </dev/tty); } 2>/dev/null || true
    [ -z "$_cols" ] && _cols=$(tput cols 2>/dev/null || echo 84)
  fi
  [[ "$_cols" =~ ^[0-9]+$ ]] || _cols=84
  [[ "$_rows" =~ ^[0-9]+$ ]] || _rows=${LINES:-24}
  ROWS=$_rows
  TERM_COLS=$_cols
  COLS=$_cols
  (( COLS > 120 )) && COLS=120
  (( COLS < 40 )) && COLS=40
  if (( COLS <= 70 )); then
    W=$(( COLS - 2 )); IS_COMPACT=1
  else
    W=$(( COLS - 4 )); IS_COMPACT=0
  fi
}
refresh_dimensions

# ── Display width (columns, not code points) — fork-free core ───────────────
# Width of one non-ASCII code point: 0 (combining / ZWJ / VS), 2 (wide) or 1.
_ui_cp_width() {
  local cp=$1
  if (( cp == 0x200D || (cp >= 0x200B && cp <= 0x200F) || (cp >= 0xFE00 && cp <= 0xFE0F) \
     || (cp >= 0x0300 && cp <= 0x036F) || (cp >= 0x20D0 && cp <= 0x20FF) || (cp >= 0xFE20 && cp <= 0xFE2F) \
     || (cp >= 0x1F3FB && cp <= 0x1F3FF) || (cp >= 0xE0000 && cp <= 0xE007F) )); then
    UI_CW=0
  elif (( (cp >= 0x1100 && cp <= 0x115F) || (cp >= 0x2E80 && cp <= 0xA4CF) || (cp >= 0xAC00 && cp <= 0xD7A3) \
       || (cp >= 0xF900 && cp <= 0xFAFF) || (cp >= 0xFE30 && cp <= 0xFE4F) || (cp >= 0xFF00 && cp <= 0xFF60) \
       || (cp >= 0xFFE0 && cp <= 0xFFE6) || (cp >= 0x1F300 && cp <= 0x1F64F) || (cp >= 0x1F680 && cp <= 0x1F6FF) \
       || (cp >= 0x1F900 && cp <= 0x1FAFF) || (cp >= 0x20000 && cp <= 0x3FFFD) )); then
    UI_CW=2
  else
    UI_CW=1
  fi
}

# ui_width <plain> → UI_W. Only the non-ASCII characters are inspected one by one.
ui_width() {
  local s=$1
  if [[ $s != *[![:ascii:]]* ]]; then UI_W=${#s}; return; fi
  local wide=${s//[[:ascii:]]/} i cp
  UI_W=$(( ${#s} - ${#wide} ))
  for ((i = 0; i < ${#wide}; i++)); do
    printf -v cp '%d' "'${wide:i:1}"
    _ui_cp_width "$cp"
    (( UI_W += UI_CW ))
  done
}

# ui_trunc <plain> <max> → UI_S (cut to max columns, ending in … when cut), UI_W its width.
ui_trunc() {
  local s=$1 max=$2
  ui_width "$s"
  (( UI_W <= max )) && { UI_S=$s; return; }
  if (( max <= 0 )); then UI_S=''; UI_W=0; return; fi
  if [[ $s != *[![:ascii:]]* ]]; then
    UI_S="${s:0:max-1}…"; UI_W=$max; return
  fi
  local out='' w=0 i ch cp
  for ((i = 0; i < ${#s}; i++)); do
    ch=${s:i:1}
    if [[ $ch == [[:ascii:]] ]]; then UI_CW=1
    else printf -v cp '%d' "'$ch"; _ui_cp_width "$cp"; fi
    (( w + UI_CW > max - 1 )) && break
    out+=$ch
    (( w += UI_CW ))
  done
  UI_S="$out…"
  UI_W=$(( w + 1 ))
}

# ui_fit <plain> <width> → UI_S truncated and right-padded to exactly <width> columns.
ui_fit() {
  ui_trunc "$1" "$2"
  local pad=$(( $2 - UI_W ))
  (( pad > 0 )) && printf -v UI_S '%s%*s' "$UI_S" "$pad" ''
  UI_W=$2
}

# _ui_skip_osc: $s starts right after "\e]"; drops the OSC up to its BEL or ST terminator.
_ui_skip_osc() {
  local a=${s%%$'\a'*} t=${s%%$'\e\\'*}
  if (( ${#a} < ${#s} )) && (( ${#a} <= ${#t} )); then s=${s:${#a}+1}
  elif (( ${#t} < ${#s} )); then s=${s:${#t}+2}
  else s=''; fi
}

# ui_strip <text> → UI_S without ANSI escape sequences (CSI and OSC).
ui_strip() {
  local s=$1 out=''
  while [[ $s == *$'\e'* ]]; do
    out+=${s%%$'\e'*}
    s=${s#*$'\e'}
    case $s in
      \[*) s=${s:1}; s=${s#*[@-~]} ;;
      \]*) s=${s:1}; _ui_skip_osc ;;
      *)   s=${s:1} ;;
    esac
  done
  UI_S=$out$s
}

# ui_ansi_fit <text-with-SGR> <width> → UI_S cut/padded to <width> visible columns. Keeps SGR
# color codes, drops every other escape (cursor moves, OSC hyperlinks), ends with a reset.
ui_ansi_fit() {
  local s=$1 max=$2 out='' used=0 chunk seq
  s=${s//$'\t'/    }
  s=${s//$'\r'/}
  while [ -n "$s" ] && (( used < max )); do
    if [[ $s == $'\e'* ]]; then
      s=${s:1}
      case $s in
        \[*)
          s=${s:1}
          seq=${s%%[@-~]*}
          s=${s:${#seq}}
          [[ $s == m* ]] && out+=$'\e['"${seq}m"
          s=${s:1} ;;
        \]*) s=${s:1}; _ui_skip_osc ;;
        *) s=${s:1} ;;
      esac
      continue
    fi
    chunk=${s%%$'\e'*}
    s=${s:${#chunk}}
    chunk=${chunk//[$'\x01'-$'\x1f']/}
    ui_width "$chunk"
    if (( used + UI_W <= max )); then
      out+=$chunk; (( used += UI_W ))
    else
      ui_trunc "$chunk" $(( max - used ))
      out+=$UI_S; (( used += UI_W ))
      break
    fi
  done
  out+=$'\e[0m'
  (( used < max )) && printf -v out '%s%*s' "$out" $(( max - used )) ''
  UI_S=$out
  UI_W=$max
}

# ── Display width — printing API (stable) ───────────────────────────────────
strip_ansi()    { ui_strip "$1"; printf '%s' "$UI_S"; }
str_width()     { ui_width "$1"; printf '%d' "$UI_W"; }
truncate_cols() { ui_trunc "$1" "$2"; printf '%s' "$UI_S"; }

repeat_char() {
  local ch=$1 count=$2 out=''
  (( count <= 0 )) && return 0
  printf -v out '%*s' "$count" ''
  printf '%s' "${out// /$ch}"
}

# ui_repeat <char> <count> → UI_S
ui_repeat() {
  UI_S=''
  (( $2 <= 0 )) && return 0
  printf -v UI_S '%*s' "$2" ''
  UI_S=${UI_S// /$1}
}

# gradient_text <text> r1 g1 b1 r2 g2 b2 → text with a per-character horizontal color ramp.
# ui_gradient does the same into UI_S. Plain text when colors are off.
ui_gradient() {
  local text=$1 r1=$2 g1=$3 b1=$4 r2=$5 g2=$6 b2=$7
  if (( ! HAS_COLOR )); then UI_S=$text; return; fi
  local n=${#text} i out='' den
  den=$(( n > 1 ? n - 1 : 1 ))
  for ((i = 0; i < n; i++)); do
    ui_rgb fg $(( r1 + (r2 - r1) * i / den )) $(( g1 + (g2 - g1) * i / den )) $(( b1 + (b2 - b1) * i / den ))
    out+="$UI_S${text:i:1}"
  done
  UI_S=$out
}
gradient_text() { ui_gradient "$@"; printf '%s%s' "$UI_S" "$C_OFF"; }

# ── Box primitives (stable API used across modules) ─────────────────────────
# box_top <title> [right] [border_color]
box_top() {
  local title=${1:-} right=${2:-} bc=${3:-$C_BORDER}
  local inner=$(( W - 2 )) eol='' line
  (( IS_TERM )) && eol=$'\e[K'
  if [ -z "$title" ] && [ -z "$right" ]; then
    ui_repeat '─' "$inner"
    printf ' %s╭%s╮%s%s\n' "$bc" "$UI_S" "$C_OFF" "$eol"
    return
  fi
  local tw rw
  ui_width "$right"; rw=$UI_W
  ui_width "$title"
  (( IS_COMPACT && UI_W + rw + 7 > inner )) && { right=''; rw=0; }
  local max_t=$(( inner - 4 - (rw ? rw + 3 : 0) ))
  ui_trunc "$title" "$max_t"; title=$UI_S; tw=$UI_W
  if [ -n "$right" ]; then
    local pad=$(( inner - tw - rw - 6 ))
    (( pad < 1 )) && pad=1
    ui_repeat '─' "$pad"; line=$UI_S
    printf ' %s╭─%s %s%s%s %s%s%s %s%s%s %s─╮%s%s\n' \
      "$bc" "$C_OFF" "$C_BOLD$C_NEON" "$title" "$C_OFF" "$bc" "$line" "$C_OFF" \
      "$C_MUTED" "$right" "$C_OFF" "$bc" "$C_OFF" "$eol"
  else
    local pad=$(( inner - tw - 3 ))
    (( pad < 1 )) && pad=1
    ui_repeat '─' "$pad"; line=$UI_S
    printf ' %s╭─%s %s%s%s %s%s╮%s%s\n' \
      "$bc" "$C_OFF" "$C_BOLD$C_NEON" "$title" "$C_OFF" "$bc" "$line" "$C_OFF" "$eol"
  fi
}

# box_sep [border_color]
box_sep() {
  local bc=${1:-$C_BORDER} eol=''
  (( IS_TERM )) && eol=$'\e[K'
  ui_repeat '─' $(( W - 2 ))
  printf ' %s├%s┤%s%s\n' "$bc" "$UI_S" "$C_OFF" "$eol"
}

# box_row <border_color> <content-with-ansi>
box_row() {
  local bc=${1:-$C_BORDER} content=${2:-}
  local max_vis=$(( W - 4 )) eol=''
  (( IS_TERM )) && eol=$'\e[K'
  local vlen
  ui_strip "$content"
  ui_width "$UI_S"; vlen=$UI_W
  if (( vlen > max_vis )); then
    ui_trunc "$UI_S" "$max_vis"
    content=$UI_S; vlen=$UI_W
  fi
  local pad=$(( max_vis - vlen ))
  (( pad < 0 )) && pad=0
  printf ' %s│%s %s%s%*s %s│%s%s\n' "$bc" "$C_OFF" "$content" "$C_OFF" "$pad" "" "$bc" "$C_OFF" "$eol"
}

# box_bottom [hint] [border_color]
box_bottom() {
  local hint=${1:-} bc=${2:-$C_BORDER}
  local inner=$(( W - 2 )) eol=''
  (( IS_TERM )) && eol=$'\e[K'
  if [ -z "$hint" ]; then
    ui_repeat '─' "$inner"
    printf ' %s╰%s╯%s%s\n' "$bc" "$UI_S" "$C_OFF" "$eol"
    return
  fi
  ui_trunc "$hint" $(( inner - 5 )); hint=$UI_S
  local pad=$(( inner - UI_W - 3 ))
  (( pad < 1 )) && pad=1
  ui_repeat '─' "$pad"
  printf ' %s╰%s %s%s%s %s─╯%s%s\n' "$bc" "$UI_S" "$C_MUTED" "$hint" "$C_OFF" "$bc" "$C_OFF" "$eol"
}

# ── Widgets ─────────────────────────────────────────────────────────────────
# ui_gauge <pct> [width] → UI_S (plain ▰▱ bar)
ui_gauge() {
  local val=${1%.*} width=${2:-5} filled
  [[ "$val" =~ ^[0-9]+$ ]] || val=0
  (( val > 100 )) && val=100
  filled=$(( (val * width + 49) / 100 ))
  (( val > 0 && filled == 0 )) && filled=1
  local on off
  ui_repeat '▰' "$filled"; on=$UI_S
  ui_repeat '▱' $(( width - filled )); off=$UI_S
  UI_S=$on$off
}
draw_gauge() { ui_gauge "$@"; printf '%s' "$UI_S"; }

# state_color <STATE> → UI_S (color escape for a session state)
state_color() {
  case "$1" in
    WORKING) UI_S="$C_LIVE$C_BOLD" ;;
    READY)   UI_S=$C_LIVE ;;
    STANDBY) UI_S=$C_BRASS ;;
    DAEMON)  UI_S=$C_PURP ;;
    BOT|SHELL) UI_S=$C_NEON ;;
    DEAD|BLOCKED) UI_S=$C_ERR$C_BOLD ;;
    *)       UI_S=$C_MUTED ;;
  esac
}

# state_badge <STATE> → colored "● STATE" label
state_badge() {
  state_color "$1"
  printf '%s●%s %s' "$UI_S" "$C_OFF" "$1"
}

host_stats_label() {
  local l1 pct used
  IFS='|' read -r l1 pct used <<< "$(get_host_telemetry)"
  if (( IS_COMPACT )); then
    printf 'LOAD %s · RAM %d%%' "$l1" "$pct"
  else
    printf 'LOAD %s · RAM %dM (%d%%)' "$l1" "$used" "$pct"
  fi
}
