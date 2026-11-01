#!/usr/bin/env bash
# lib/prefs.sh — Interface preferences: language (lang) and color theme (theme)
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
#
# Both are saved in the user's config.env (_config_set) and take effect at once: the palette and
# the catalog are reloaded in this process, and the prama tmux config (status bar, pane borders)
# is regenerated and reloaded so running agents and cockpits pick them up too.

# prefs_set_theme <name> [save:1|0] — applies a theme (and saves it).
prefs_set_theme() {
  local th=$1 save=${2:-1}
  valid_theme "$th" || return 1
  (( save )) && _config_set PRAMA_THEME "$th"
  PRAMA_THEME=$th
  ui_init_theme
  if declare -F tui_styles >/dev/null; then tui_styles; fi
  (( save )) && _prefs_reload_tmux
  return 0
}

# prefs_set_lang <en|es|auto> — applies and saves the interface language.
prefs_set_lang() {
  local l=$1
  is_in "$l" "${PRAMA_LANGS[@]}" auto || return 1
  _config_set PRAMA_LANG "$l"
  PRAMA_LANG=$l
  i18n_init
  _prefs_reload_tmux
  return 0
}

_prefs_reload_tmux() {
  [ -d "${PRAMA_STATE_HOME:-}" ] || return 0
  ensure_tmux_conf 1 >/dev/null 2>&1 || true
}

# theme_swatch <name> → UI_S: a line of color blocks in the theme's palette (plain name without colors).
theme_swatch() {
  local -a TH=() idx=(0 1 2 3 4 5) out='' i
  _ui_theme_hex "$1" || return 1
  if (( ! HAS_COLOR )); then UI_S=''; return 0; fi
  ui_hex bg "${TH[9]}"; out+=$UI_S
  ui_hex fg "${TH[0]}"; out+="$UI_S$C_BOLD ◆ PRAMA "
  for i in "${idx[@]}"; do ui_hex fg "${TH[i]}"; out+="$UI_S██"; done
  ui_hex fg "${TH[6]}"; out+="$UI_S ··· $C_OFF"
  UI_S=$out
}

subcmd_theme() {
  local th=${1:-} t mark sw
  case $th in
    ''|list|ls)
      printf ' %s%s%s\n\n' "$C_BOLD" "$(_t 'Color themes')" "$C_OFF"
      for t in "${PRAMA_THEMES[@]}"; do
        mark='  '; [ "$t" = "$UI_THEME" ] && mark="$C_LIVE●$C_OFF "
        theme_swatch "$t"; sw=$UI_S
        printf '  %s%-9s %s  %s%s%s\n' "$mark" "$t" "$sw" "$C_MUTED" "$(_theme_desc "$t")" "$C_OFF"
      done
      printf '\n %s\n' "$(_t 'Change it with: prama-agent theme <name>  (also in the menu: ⚙ Preferences)')"
      return 0 ;;
    -h|--help|help)
      printf '%s\n' "$(_t 'Usage: prama-agent theme [list | <name>]')"; return 0 ;;
  esac
  valid_theme "$th" || die "$(_t 'Unknown theme: %s (available: %s)' "$th" "${PRAMA_THEMES[*]}")"
  prefs_set_theme "$th"
  ok "$(_t 'Theme: %s' "$th")"
}

_theme_desc() {
  case $1 in
    midnight) _t 'sky blue and violet on slate (default)' ;;
    ocean)    _t 'cyan and blue' ;;
    forest)   _t 'greens' ;;
    ember)    _t 'orange and rose' ;;
    violet)   _t 'purple and pink' ;;
    light)    _t 'for terminals with a light background' ;;
    mono)     _t 'no hues, high contrast' ;;
  esac
}

subcmd_lang() {
  local l=${1:-}
  case $l in
    '')
      printf '%s (%s)\n' "$PRAMA_UI_LANG" "$(lang_name "$PRAMA_UI_LANG")"
      return 0 ;;
    -h|--help|help)
      printf '%s\n' "$(_t 'Usage: prama-agent lang [en | es | auto]')"; return 0 ;;
  esac
  prefs_set_lang "$l" || die "$(_t 'Unknown language: %s (available: %s)' "$l" "${PRAMA_LANGS[*]} auto")"
  ok "$(_t 'Interface language: %s' "$(lang_name "$PRAMA_UI_LANG")")"
}
