#!/usr/bin/env bash
# lib/prefs.sh — Interface preferences: language (lang) and color theme (theme)
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0

subcmd_lang() {
  local l=${1:-}
  if [ -z "$l" ]; then
    printf '%s (%s)\n' "$PRAMA_UI_LANG" "$(lang_name "$PRAMA_UI_LANG")"
    return 0
  fi
  is_in "$l" "${PRAMA_LANGS[@]}" auto || die "$(_t 'Unknown language: %s (available: %s)' "$l" "${PRAMA_LANGS[*]} auto")"
  _config_set PRAMA_LANG "$l"
  PRAMA_LANG=$l; i18n_init
  ok "$(_t 'Interface language: %s' "$(lang_name "$PRAMA_UI_LANG")")"
}

subcmd_theme() {
  local th=${1:-}
  if [ -z "$th" ]; then printf '%s\n' "$PRAMA_THEME"; return 0; fi
  _config_set PRAMA_THEME "$th"
  PRAMA_THEME=$th
  ok "$(_t 'Theme: %s' "$th")"
}
