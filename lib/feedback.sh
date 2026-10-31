#!/usr/bin/env bash
# lib/feedback.sh — Internal channel for agents (and the operator) to report prama-agent bugs
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
#
#   prama-agent feedback "<what happened>" [--idea]    file a report (an agent or the operator)
#   prama-agent feedback list [--all] [--json]          open reports (--all: closed too)
#   prama-agent feedback show <id>                      report with its context
#   prama-agent feedback export <id>                    Markdown body for a GitHub issue
#   prama-agent feedback close <id>... | --all          mark as handled
#
# Reports stay on this machine, in the private state dir: <state>/feedback/<id>/{meta,body.md}
# (meta is KEY=value, never sourced). Agents cannot publish anything: the operator reads the
# report, and exports it to the project's issue tracker when it is worth it. Text is redacted
# (provider keys from providers.env and common token shapes) before it is written.

FEEDBACK_MAX_CHARS=4000
FEEDBACK_MAX_OPEN=${PRAMA_FEEDBACK_MAX_OPEN:-50}

feedback_dir() { printf '%s/feedback' "$PRAMA_STATE_HOME"; }

# _feedback_redact <text> → text with secrets replaced by ***
_feedback_redact() {
  local t=$1 v name
  # Values of loaded secrets (providers.env, telegram), longest first is not needed: exact values.
  while IFS= read -r name; do
    v=${!name:-}
    (( ${#v} >= 8 )) && t=${t//"$v"/***}
  done < <(compgen -v | grep -E '(_API_KEY|_TOKEN|_SECRET|_PASSWORD|^TG_TOKEN)$' || true)
  printf '%s' "$t" | sed -E \
    -e 's/(sk-(ant-)?[A-Za-z0-9_-]{16,})/***/g' \
    -e 's/(gh[pousr]_[A-Za-z0-9]{20,})/***/g' \
    -e 's/(xox[abpr]-[A-Za-z0-9-]{10,})/***/g' \
    -e 's/([0-9]{6,}:[A-Za-z0-9_-]{30,})/***/g' \
    -e 's/(AIza[0-9A-Za-z_-]{30,})/***/g' \
    -e 's/((api[_-]?key|token|secret|password)["'\'' ]*[:=][ "'\'']*)[^ "'\'',;]{8,}/\1***/Ig'
}

_feedback_valid_id() { [[ "$1" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$ ]]; }

_feedback_require() {
  _feedback_valid_id "${1:-}" || die "Id de reporte inválido: '${1:-}' (prama-agent feedback list)"
  [ -f "$(feedback_dir)/$1/meta" ] || die "No existe el reporte '$1'."
}

_feedback_get() { _kv_get "$(feedback_dir)/$1/meta" "$2" "${3:-}"; }

# Ids, newest first. FB_STATUS filter: open | all
_feedback_ids() {
  local d f id
  d=$(feedback_dir)
  [ -d "$d" ] || return 0
  for f in "$d"/*/meta; do
    [ -f "$f" ] || continue
    id=${f%/meta}; id=${id##*/}
    _feedback_valid_id "$id" || continue
    if [ "${1:-open}" = open ] && [ "$(_kv_get "$f" STATUS open)" != open ]; then continue; fi
    printf '%s\n' "$id"
  done | sort -r
}

feedback_open_count() { _feedback_ids open | grep -c . || true; }

_feedback_usage() {
  cat <<'EOF'
Uso: prama-agent feedback "<qué pasó>" [--idea]   reportar un fallo (o una idea) de prama-agent
     prama-agent feedback list [--all] [--json]   reportes abiertos (--all: también cerrados)
     prama-agent feedback show <id>               reporte y su contexto
     prama-agent feedback export <id>             cuerpo Markdown para un issue de GitHub
     prama-agent feedback close <id>... | --all   marcar como atendido

Un buen reporte dice qué comando ejecutaste, qué esperabas y qué obtuviste (con el error exacto).
Es para fallos de prama-agent, no de tu tarea. Se guarda en este servidor; el operador lo revisa.
EOF
}

subcmd_feedback() {
  case "${1:-}" in
    ''|help|-h|--help) _feedback_usage ;;
    list|ls)           shift; _feedback_list "$@" ;;
    show)              shift; _feedback_show "${1:-}" ;;
    export)            shift; _feedback_export "${1:-}" ;;
    close|done)        shift; _feedback_close "$@" ;;
    *)                 _feedback_add "$@" ;;
  esac
}

_feedback_add() {
  local kind=bug text='' a
  for a in "$@"; do
    case "$a" in
      --idea) kind=idea ;;
      --bug)  kind=bug ;;
      *)      text+="${text:+ }$a" ;;
    esac
  done
  text=${text//$'\r'/}
  [ -n "${text//[[:space:]]/}" ] || die "Describe el problema: prama-agent feedback \"<qué pasó>\""
  (( ${#text} <= FEEDBACK_MAX_CHARS )) || text="${text:0:FEEDBACK_MAX_CHARS}…"
  text=$(_feedback_redact "$text")

  local from=${PRAMA_SESSION:-operator} d id f existing
  d=$(feedback_dir)
  (umask 077 && mkdir -p "$d")
  # The same open report twice (an agent retrying) counts instead of piling up.
  while IFS= read -r existing; do
    if [ "$(cat "$d/$existing/body.md" 2>/dev/null)" = "$text" ]; then
      local n; n=$(_feedback_get "$existing" COUNT 1)
      _kv_merge "$d/$existing/meta" "$existing" "COUNT=$(( n + 1 ))" "LAST_AT=$(date -Iseconds)"
      ok "Ya estaba reportado: $existing (repetido $(( n + 1 )) veces)."
      return 0
    fi
  done < <(_feedback_ids open)
  (( $(feedback_open_count) < FEEDBACK_MAX_OPEN )) \
    || die "Hay $FEEDBACK_MAX_OPEN reportes abiertos; el operador debe revisarlos (prama-agent feedback list)."

  printf -v id '%(%Y%m%d-%H%M%S)T-%04x' -1 $(( RANDOM % 65536 ))
  f="$d/$id"
  (umask 077 && mkdir -p "$f") || die "No se pudo crear $f"
  local tv st reason model agent role zone=''
  tv=$(tmux -V 2>/dev/null); tv=${tv#tmux }
  if [ "$from" != operator ]; then
    agent=$(state_get "$from" AGENT) role=$(session_role "$from") zone=$(state_get "$from" ZONE)
    model=$(health_get "$from" MODEL "$(state_get "$from" MODEL)")
    st=$(detect_session_state "$from" 2>/dev/null) reason=$(health_get "$from" REASON)
  fi
  local kv
  (
    umask 077
    printf '%s\n' "$text" > "$f/body.md"
    for kv in "ID=$id" "KIND=$kind" STATUS=open COUNT=1 "CREATED_AT=$(date -Iseconds)" "FROM=$from" \
              "AGENT=${agent:-}" "ROLE=${role:-operator}" "MODEL=${model:-}" "ZONE=$zone" \
              "AGENT_STATE=${st:-}" "AGENT_REASON=${reason:-}" "PRAMA_VERSION=$VERSION" "TMUX_VERSION=$tv" \
              "BASH_VERSION=${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" "OS=$(uname -sr 2>/dev/null)"; do
      [ -n "${kv#*=}" ] && printf '%s\n' "${kv//$'\n'/ }"
    done > "$f/meta"
    # Recent bus events of the reporter, redacted: what it was doing when it hit the problem.
    if [ "$from" != operator ] && [ -f "$PRAMA_BUS_DIR/events.jsonl" ]; then
      _feedback_redact "$(grep -F "\"$from\"" "$PRAMA_BUS_DIR/events.jsonl" 2>/dev/null | tail -n 5)" > "$f/events.jsonl"
    fi
  )
  local first=${text%%$'\n'*}
  bus_event feedback "$from" operator "[$kind $id] ${first:0:200}"
  declare -F telegram_notify >/dev/null \
    && telegram_notify "🐞 Reporte de prama-agent ($kind) de $from: ${first:0:300} — prama-agent feedback show $id" >/dev/null 2>&1
  ok "Reporte $id registrado. El operador lo verá en 'prama-agent feedback list'."
}

_feedback_list() {
  local which=open json=0 a id sep='' first n
  for a in "$@"; do
    case "$a" in
      --all) which=all ;;
      --json) json=1 ;;
      *) die "Opción desconocida: $a" ;;
    esac
  done
  if (( json )); then
    printf '['
    while IFS= read -r id; do
      first=$(head -n 1 "$(feedback_dir)/$id/body.md" 2>/dev/null)
      printf '%s{"id":"%s","kind":"%s","status":"%s","count":%s,"created":"%s","from":"%s","agent":"%s","model":"%s","summary":"%s"}' \
        "$sep" "$id" "$(_feedback_get "$id" KIND bug)" "$(_feedback_get "$id" STATUS open)" \
        "$(_feedback_get "$id" COUNT 1)" "$(json_escape "$(_feedback_get "$id" CREATED_AT)")" \
        "$(json_escape "$(_feedback_get "$id" FROM)")" "$(json_escape "$(_feedback_get "$id" AGENT)")" \
        "$(json_escape "$(_feedback_get "$id" MODEL)")" "$(json_escape "$first")"
      sep=','
    done < <(_feedback_ids "$which")
    printf ']\n'
    return 0
  fi
  n=0
  while IFS= read -r id; do
    first=$(head -n 1 "$(feedback_dir)/$id/body.md" 2>/dev/null)
    printf ' %s %-25s %-5s %-32s %s%s\n' "$( [ "$(_feedback_get "$id" STATUS open)" = open ] && echo '●' || echo '○')" \
      "$id" "$(_feedback_get "$id" KIND bug)" "$(_feedback_get "$id" FROM)" "${first:0:70}" \
      "$( (( $(_feedback_get "$id" COUNT 1) > 1 )) && printf ' (×%s)' "$(_feedback_get "$id" COUNT)")"
    (( n++ ))
  done < <(_feedback_ids "$which")
  (( n )) || info_msg "No hay reportes${which/open/ abiertos}."
  (( n )) && info_msg "Detalle: prama-agent feedback show <id> · issue: prama-agent feedback export <id>"
  return 0
}

_feedback_show() {
  local id=$1 d k v
  _feedback_require "$id"
  d="$(feedback_dir)/$id"
  printf '\n'
  while IFS='=' read -r k v; do
    [ -n "$v" ] && printf '  %-14s %s\n' "$k" "$v"
  done < "$d/meta"
  printf '\n'
  sed 's/^/  │ /' "$d/body.md"
  if [ -s "$d/events.jsonl" ]; then printf '\n  Últimos eventos del agente:\n'; sed 's/^/    /' "$d/events.jsonl"; fi
  printf '\n'
  info_msg "Publicar como issue: prama-agent feedback export $id | gh issue create -R ${PRAMA_ISSUES_REPO:-JSNN15/prama-agente} -t \"<título>\" -F -"
  info_msg "Marcar como atendido: prama-agent feedback close $id"
}

# Markdown for the project's issue template: summary, report, environment, agent context.
_feedback_export() {
  local id=$1 d first
  _feedback_require "$id"
  d="$(feedback_dir)/$id"
  first=$(head -n 1 "$d/body.md")
  cat <<EOF
<!-- Reported through prama-agent's internal channel ($(_feedback_get "$id" KIND bug), $id). Review before posting. -->
### Summary

$first

### Report

$(cat "$d/body.md")

### Environment

| | |
| --- | --- |
| prama-agent | $(_feedback_get "$id" PRAMA_VERSION) |
| tmux / bash | $(_feedback_get "$id" TMUX_VERSION) / $(_feedback_get "$id" BASH_VERSION) |
| OS | $(_feedback_get "$id" OS) |
| Reporter | $(_feedback_get "$id" ROLE operator) $(_feedback_get "$id" AGENT) $(_feedback_get "$id" MODEL) ($(_feedback_get "$id" FROM)) |
| Agent state | $(_feedback_get "$id" AGENT_STATE —) $(_feedback_get "$id" AGENT_REASON) |
| Seen | $(_feedback_get "$id" COUNT 1) time(s) |
EOF
  if [ -s "$d/events.jsonl" ]; then
    printf '\n### Recent bus events\n\n```json\n%s\n```\n' "$(cat "$d/events.jsonl")"
  fi
}

_feedback_close() {
  local id n=0
  [ $# -gt 0 ] || die "Uso: prama-agent feedback close <id>... | --all"
  [ -z "${PRAMA_SESSION:-}" ] || die "Solo el operador cierra reportes."
  local -a ids=("$@")
  [ "$1" = --all ] && mapfile -t ids < <(_feedback_ids open)
  for id in ${ids[@]+"${ids[@]}"}; do
    _feedback_require "$id"
    _kv_merge "$(feedback_dir)/$id/meta" "$id" STATUS=closed "CLOSED_AT=$(date -Iseconds)"
    (( n++ ))
  done
  ok "Reportes cerrados: $n"
}
