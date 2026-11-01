#!/usr/bin/env bash
# lib/i18n.sh — Interface language: English source strings, translations in lib/lang/<lang>/*.sh
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
#
# Every user-facing string goes through _t (prints) or _tv (assigns, fork-free). The message id is
# the English text, a printf format with %s / %d placeholders (a literal % is %%), always a quoted
# literal so tools/i18n_check.py can extract it:
#     die "$(_t 'Unknown zone: %s' "$zone")"
#     _tv UI_S 'Sessions'
# A missing translation falls back to the English text. Catalogs are bash files that only add
# entries to I18N (one per module: lib/lang/es/<module>.sh); they are loaded for the active
# language only. Strings are translated when used, never at source time: the language is known
# only after config.env is loaded (PRAMA_LANG).

PRAMA_LANGS=(en es)
PRAMA_UI_LANG=${PRAMA_UI_LANG:-en}
I18N_LOADED=''
declare -gA I18N=()

# i18n_detect → PRAMA_UI_LANG from PRAMA_LANG (en | es | auto) or the locale (es_* → es).
i18n_detect() {
  local l=${PRAMA_LANG:-auto}
  if [ "$l" = auto ]; then l=${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}; fi
  case $l in
    es|es[_.-]*) PRAMA_UI_LANG=es ;;
    *)           PRAMA_UI_LANG=en ;;
  esac
}

# i18n_init — (re)loads the catalog of the active language; cheap when it did not change.
i18n_init() {
  i18n_detect
  [ "$PRAMA_UI_LANG" = "$I18N_LOADED" ] && return 0
  I18N=()
  local dir catalog
  dir="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)/lang/$PRAMA_UI_LANG"
  if [ "$PRAMA_UI_LANG" != en ] && [ -d "$dir" ]; then
    # Catalogs ship with prama (lib/lang), next to this file; never user or state files.
    for catalog in "$dir"/*.sh; do
      # shellcheck disable=SC1090
      [ -f "$catalog" ] && source "$catalog"
    done
  fi
  I18N_LOADED=$PRAMA_UI_LANG
  PRAMA_LANG_NAME=$(lang_name "$PRAMA_UI_LANG")
  export PRAMA_UI_LANG
}

# _t <msgid> [args...] — prints the translated, formatted message (no trailing newline).
# shellcheck disable=SC2059
_t() { printf -- "${I18N[$1]-$1}" "${@:2}"; }

# _tv <var> <msgid> [args...] — same, into <var> (no subshell; for hot paths).
# shellcheck disable=SC2059
_tv() { printf -v "$1" -- "${I18N[$2]-$2}" "${@:3}"; }

# lang_name <code> → the language's own name
lang_name() {
  case $1 in
    es) printf 'Español' ;;
    en) printf 'English' ;;
    *)  printf '%s' "$1" ;;
  esac
}

i18n_init
