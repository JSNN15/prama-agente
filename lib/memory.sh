#!/usr/bin/env bash
# lib/memory.sh — Shared memory for teams and zones: durable notes the agents read and add to
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
#
# A conversation dies with its agent (restart, model change, quota); the team's decisions should
# not. Each team has a Markdown file of short dated notes, and each zone one shared by all its
# teams (conventions, architecture facts). Agents read them when they start and add to them when
# they decide or learn something durable; new agents of the team get the same context.
#   $PRAMA_STATE_HOME/memory/<zone>/team-<team>.md     $PRAMA_STATE_HOME/memory/<zone>/zone.md
# Notes are one line each ("- 2026-11-01 14:03 · <author>: <text>"), redacted like feedback reports,
# and the file keeps the newest PRAMA_MEMORY_MAX_LINES. It is data: never sourced or executed.

PRAMA_MEMORY_MAX_LINES="${PRAMA_MEMORY_MAX_LINES:-200}"
MEM_NOTE_MAX=600

memory_dir() { printf '%s/memory' "$PRAMA_STATE_HOME"; }

# memory_file <zone> [team] → the team's file, or the zone's without a team
memory_file() {
  local z t=${2:-}
  z=$(slugify "$1")
  if [ -n "$t" ]; then printf '%s/%s/team-%s.md' "$(memory_dir)" "$z" "$(slugify "$t")"
  else printf '%s/%s/zone.md' "$(memory_dir)" "$z"; fi
}

memory_count() { local f; f=$(memory_file "$@"); [ -f "$f" ] && grep -c '^- ' "$f" || printf '0'; }

# _mem_resolve [target] [--team T] [--zone-wide] → MEM_ZONE MEM_TEAM (empty = the zone's memory).
# target: a zone or a session (its team). Without one, an agent means its own team (or zone).
_mem_resolve() {
  local target=${1:-} team=${2:-} zonewide=${3:-0} m c
  MEM_ZONE='' MEM_TEAM=''
  if [ -z "$target" ] && [ -n "${PRAMA_SESSION:-}" ]; then target=$PRAMA_SESSION; fi
  [ -n "$target" ] || return 1
  if valid_session_name "$target" && [ -f "$(state_file "$target")" ]; then
    MEM_ZONE=$(state_get "$target" ZONE)
    if [ -n "$team" ]; then MEM_TEAM=$team
    elif c=$(session_team "$target" 2>/dev/null) && [ -n "$c" ]; then MEM_TEAM=$(team_name "$c"); fi
  else
    m=$(match_zone "$target" 2>/dev/null) || die "$(_t "Unknown zone or session: '%s'" "$target")"
    MEM_ZONE=$m MEM_TEAM=$team
  fi
  [ -n "$MEM_ZONE" ] || die "$(_t "'%s' has no zone" "$target")"
  if [ -n "$MEM_TEAM" ]; then valid_team_name "$MEM_TEAM" || die "$(_t 'Invalid team name: %s' "$MEM_TEAM")"; fi
  (( zonewide )) && MEM_TEAM=''
  return 0
}

_mem_usage() {
  case ${PRAMA_UI_LANG:-en} in
    es) cat <<'EOF'
Uso: prama-agent memory [list]                              memorias de equipos y zonas
     prama-agent memory show [<zona>|<sesión>] [--team T]    leer (un agente: la de su equipo y su zona)
     prama-agent memory add [<zona>|<sesión>] [--team T] [--zone-wide] "<nota>"
     prama-agent memory clear <zona>|<sesión> [--team T] [--zone-wide] [-y]   (solo el operador)
     prama-agent memory path <zona>|<sesión> [--team T] [--zone-wide]
Notas breves y durables: decisiones, convenciones, hallazgos, dónde quedó el trabajo.
--zone-wide escribe en la memoria de la zona, compartida por todos sus equipos. list y show aceptan --json.
EOF
    ;;
    *) cat <<'EOF'
Usage: prama-agent memory [list]                              team and zone memories
       prama-agent memory show [<zone>|<session>] [--team T]   read (an agent: its team's and its zone's)
       prama-agent memory add [<zone>|<session>] [--team T] [--zone-wide] "<note>"
       prama-agent memory clear <zone>|<session> [--team T] [--zone-wide] [-y]   (operator only)
       prama-agent memory path <zone>|<session> [--team T] [--zone-wide]
Short, durable notes: decisions, conventions, findings, where the work stands.
--zone-wide writes to the zone's memory, shared by all its teams. list and show accept --json.
EOF
    ;;
  esac
}

subcmd_memory() {
  local sub=${1:-}
  case $sub in
    ''|list|ls) [ -n "$sub" ] && shift
                if [ -n "${PRAMA_SESSION:-}" ] && [ -z "$sub" ]; then _mem_show "$@"; else _mem_list "$@"; fi ;;
    show|cat|read) shift; _mem_show "$@" ;;
    add|note|save) shift; _mem_add "$@" ;;
    clear|reset)   shift; _mem_clear "$@" ;;
    path)          shift; _mem_args "$@"; memory_file "$MEM_ZONE" "$MEM_TEAM"; printf '\n' ;;
    -h|--help|help) _mem_usage ;;
    *) _mem_usage >&2; die "$(_t 'Unknown subcommand: memory %s' "$sub")" ;;
  esac
}

# _mem_args <args…> → MEM_ZONE MEM_TEAM MEM_REST (positional words left) MEM_JSON MEM_YES
_mem_args() {
  local target='' team='' zw=0
  MEM_REST=() MEM_JSON=0 MEM_YES=0
  while (( $# )); do
    case $1 in
      --team|-T)   team=${2:?$(_t '--team requires a name')}; shift 2 ;;
      --zone-wide) zw=1; shift ;;
      --json)      MEM_JSON=1; shift ;;
      -y|--yes)    MEM_YES=1; shift ;;
      --)          shift; MEM_REST+=("$@"); break ;;
      *)           MEM_REST+=("$1"); shift ;;
    esac
  done
  # The first word is a target when it names a zone or a session (and more words follow for add).
  if (( ${#MEM_REST[@]} )); then
    local w=${MEM_REST[0]}
    if match_zone "$w" >/dev/null 2>&1 || { valid_session_name "$w" && [ -f "$(state_file "$w")" ]; }; then
      target=$w; MEM_REST=("${MEM_REST[@]:1}")
    fi
  fi
  _mem_resolve "$target" "$team" "$zw" \
    || die "$(_t 'Which memory? Give a zone or a session, e.g.: prama-agent memory %s backend --team docs' "${MEM_CMD:-show}")"
}

# _mem_list [--json] — every memory file: zone, team (— for the zone's), notes, last change
_mem_list() {
  local json=0 f z t n ts first=1
  [ "${1:-}" = --json ] && json=1
  local dir; dir=$(memory_dir)
  (( json )) && printf '['
  (( json )) || printf ' %s%-14s %-16s %6s  %s%s\n' "$C_MUTED" "$(_t 'ZONE')" "$(_t 'TEAM')" "$(_t 'NOTES')" "$(_t 'UPDATED')" "$C_OFF"
  shopt -s nullglob
  for f in "$dir"/*/zone.md "$dir"/*/team-*.md; do
    z=${f%/*}; z=${z##*/}
    t=${f##*/}; t=${t%.md}
    if [ "$t" = zone ]; then t=''; else t=${t#team-}; fi
    n=$(grep -c '^- ' "$f" || true)
    ts=$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '—')
    if (( json )); then
      (( first )) || printf ','
      first=0
      printf '{"zone":"%s","team":"%s","notes":%d,"updated":"%s"}' "$(json_escape "$z")" "$(json_escape "$t")" "$n" "$ts"
    else
      printf ' %-14s %-16s %6d  %s\n' "$z" "${t:-—}" "$n" "$ts"
    fi
  done
  shopt -u nullglob
  if (( json )); then printf ']\n'
  elif [ -z "$(compgen -G "$dir/*/*.md")" ]; then
    printf ' %s\n' "$(_t '(no memories yet: prama-agent memory add <zone> --team <team> "<note>")')"
  fi
}

# _mem_show [target] [--team T] [--zone-wide] [--json] — the zone's notes, then the team's
_mem_show() {
  MEM_CMD=show _mem_args "$@"
  local f zf tf first=1 line ts by text scope
  zf=$(memory_file "$MEM_ZONE")
  tf=''; [ -n "$MEM_TEAM" ] && tf=$(memory_file "$MEM_ZONE" "$MEM_TEAM")
  if (( MEM_JSON )); then
    printf '['
    for f in "$zf" $tf; do
      [ -f "$f" ] || continue
      scope=zone; [ "$f" = "$tf" ] && scope=team
      while IFS= read -r line; do
        [[ $line =~ ^-\ ([0-9-]+\ [0-9:]+)\ ·\ ([^:]+):\ (.*)$ ]] || continue
        ts=${BASH_REMATCH[1]} by=${BASH_REMATCH[2]} text=${BASH_REMATCH[3]}
        (( first )) || printf ','
        first=0
        printf '{"scope":"%s","ts":"%s","by":"%s","text":"%s"}' "$scope" "$ts" "$(json_escape "$by")" "$(json_escape "$text")"
      done < "$f"
    done
    printf ']\n'
    return 0
  fi
  local any=0
  for f in "$zf" $tf; do
    [ -s "$f" ] || continue
    any=1
    if [ "$f" = "$zf" ]; then printf '%s%s%s\n' "$C_BOLD" "$(_t '# Zone memory: %s' "$MEM_ZONE")" "$C_OFF"
    else printf '\n%s%s%s\n' "$C_BOLD" "$(_t '# Team memory: %s · %s' "$MEM_ZONE" "$MEM_TEAM")" "$C_OFF"; fi
    grep '^- ' "$f"
  done
  if (( ! any )); then
    if [ -n "$MEM_TEAM" ]; then printf '%s\n' "$(_t '(the memory of %s · %s is empty: add notes with prama-agent memory add "<note>")' "$MEM_ZONE" "$MEM_TEAM")"
    else printf '%s\n' "$(_t '(the memory of zone %s is empty)' "$MEM_ZONE")"; fi
  fi
  return 0
}

# _mem_add [target] [--team T] [--zone-wide] "<note>"
_mem_add() {
  MEM_CMD=add _mem_args "$@"
  local note="${MEM_REST[*]:-}" f by stamp tmp
  note=${note//$'\r'/}; note=${note//$'\n'/ }; note=${note//$'\t'/ }
  note=$(_feedback_redact "$note" 2>/dev/null || printf '%s' "$note")
  note=${note#"${note%%[![:space:]]*}"}
  [ -n "$note" ] || die "$(_t 'Empty note. Usage: prama-agent memory add "<note>"')"
  (( ${#note} > MEM_NOTE_MAX )) && note="${note:0:MEM_NOTE_MAX}…"
  f=$(memory_file "$MEM_ZONE" "$MEM_TEAM")
  ensure_private_dir "$(memory_dir)"
  ensure_private_dir "${f%/*}"
  by=${PRAMA_SESSION:-operator}
  printf -v stamp '%(%Y-%m-%d %H:%M)T' -1
  (
    umask 077
    if [ ! -f "$f" ]; then
      if [ -n "$MEM_TEAM" ]; then printf '# %s · %s — prama team memory\n\n' "$MEM_ZONE" "$MEM_TEAM" > "$f"
      else printf '# %s — prama zone memory\n\n' "$MEM_ZONE" > "$f"; fi
    fi
    printf -- '- %s · %s: %s\n' "$stamp" "$by" "$note" >> "$f"
    # Keep the header and the newest notes.
    if (( $(grep -c '^- ' "$f") > PRAMA_MEMORY_MAX_LINES )); then
      tmp="$f.tmp.$$"
      { grep -v '^- ' "$f"; grep '^- ' "$f" | tail -n "$PRAMA_MEMORY_MAX_LINES"; } > "$tmp" && mv -f "$tmp" "$f"
    fi
  )
  bus_event memory "$by" "$MEM_ZONE${MEM_TEAM:+/$MEM_TEAM}" "$note"
  if [ -n "$MEM_TEAM" ]; then ok "$(_t 'Saved to the memory of %s · %s' "$MEM_ZONE" "$MEM_TEAM")"
  else ok "$(_t 'Saved to the memory of zone %s' "$MEM_ZONE")"; fi
}

_mem_clear() {
  [ -z "${PRAMA_SESSION:-}" ] || die "$(_t 'Only the operator can clear a memory.')"
  MEM_CMD=clear _mem_args "$@"
  local f label
  f=$(memory_file "$MEM_ZONE" "$MEM_TEAM")
  label="$MEM_ZONE${MEM_TEAM:+ · $MEM_TEAM}"
  [ -f "$f" ] || { info_msg "$(_t 'Nothing to clear: %s has no memory.' "$label")"; return 0; }
  if (( ! MEM_YES )); then
    local ans
    printf ' %s ' "$(_t 'Clear the memory of %s (%s notes)? [y/N]' "$label" "$(grep -c '^- ' "$f")")" >&2
    IFS= read -r ans || ans=''
    [[ $ans == [sSyY]* ]] || { info_msg "$(_t 'Cancelled.')"; return 0; }
  fi
  rm -f "$f"
  bus_event memory operator "$MEM_ZONE${MEM_TEAM:+/$MEM_TEAM}" "cleared"
  ok "$(_t 'Memory of %s cleared' "$label")"
}
