#!/usr/bin/env bash
# lib/fleet.sh — Fleet management API (used by humans and by coordinator agents)
# Licensed under the Apache License, Version 2.0
#
#   prama-agent fleet status [--json]
#   prama-agent fleet spawn <agent> <zone> [--role R] [--model M] [--effort E] [--preset P]
#                           [--profile X] [--name N] [--worktree B] [--task "…"] [--yolo|--ask|--plan]
#                           [--remote|--no-remote] [--json] [-- agent args]
#   prama-agent fleet kill <session>
#   prama-agent fleet model <session> <model>
#   prama-agent fleet edit <session> [--model M] [--effort E] [--preset P|none] [--profile X] [--perm P]
#   prama-agent fleet restart <session>
#   prama-agent fleet presets | models [agent] | watchdog [status|start|stop|logs]
#
# Guard rails when the caller is an agent (PRAMA_SESSION set): it can never act on itself or on
# a coordinator, and only on sessions inside PRAMA_FLEET_SCOPE (zone | children | all).
# spawn is capped by PRAMA_FLEET_MAX live agents. Every action lands in the event log.

_fleet_caller() { printf '%s' "${PRAMA_SESSION:-operator}"; }

# _fleet_authorize <target> <action> → dies with a reason when not allowed.
_fleet_authorize() {
  local t=$1 action=$2 caller=${PRAMA_SESSION:-}
  require_session "$t"
  is_internal_session "$t" && die "'$t' es una sesión interna de prama."
  [ -n "$caller" ] || return 0   # human operator
  [ "$t" = "$caller" ] && die "Un agente no puede aplicarse '$action' a sí mismo ($t)."
  [ "$(session_role "$t")" = coordinator ] && die "Los agentes no pueden aplicar '$action' a un coordinador ($t)."
  case "${PRAMA_FLEET_SCOPE:-zone}" in
    all) ;;
    children)
      [ "$(state_get "$t" PARENT)" = "$caller" ] || die "'$t' no fue lanzado por $caller (PRAMA_FLEET_SCOPE=children)." ;;
    *)
      local tz cz
      tz=$(state_get "$t" ZONE) cz=$(state_get "$caller" ZONE)
      [ -n "$cz" ] && [ "$tz" = "$cz" ] || die "'$t' está fuera de tu zona (${cz:-?}) (PRAMA_FLEET_SCOPE=zone)." ;;
  esac
}

# PID of the agent CLI running under a session's pane (empty when none).
_fleet_agent_pid() {
  local ppid apid
  ppid=$(tmx display-message -p -t "=$1:" '#{pane_pid}' 2>/dev/null) || return 0
  snapshot_procs
  apid=$(resolve_pane_agent_pid "$ppid")
  [ -n "$apid" ] && [ "$apid" != "$ppid" ] && [[ "${PS_COMM[$apid]:-}" =~ $AGENT_COMM_RE ]] && printf '%s' "$apid"
  return 0
}

# _fleet_restart_in_place <session> [KEY=VALUE…] — saves the new spec and makes the pane
# supervisor relaunch the agent (same pane, same conversation). Daemons pick it up next cycle.
_fleet_restart_in_place() {
  local s=$1; shift
  state_set "$s" "$@" RESTART_REQ=1
  local kv hm=()
  for kv in "$@"; do [[ "$kv" == MODEL=* ]] && hm=("$kv"); done   # until the agent reports its own
  health_set "$s" HEALTH=ok REASON= DETAIL= ${hm[@]+"${hm[@]}"}
  [ "$(session_role "$s")" = daemon ] && { ok "'$s' aplicará la nueva configuración en su próximo ciclo."; return 0; }
  local pid i
  pid=$(_fleet_agent_pid "$s")
  if [ -n "$pid" ]; then
    kill -TERM "$pid" 2>/dev/null || true
    for (( i = 0; i < 20; i++ )); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  else
    # Supervisor waiting in its STANDBY menu: "r" relaunches (and applies the request).
    tmx send-keys -t "=$s:" r 2>/dev/null || true
  fi
  return 0
}

_fleet_json_row() {
  local s=$1 st info reason='' detail='' model
  st=$(detect_session_state "$s")
  if [ "$st" = BLOCKED ]; then info=$(session_block_info "$s"); reason=${info%%|*} detail=${info#*|}; fi
  model=$(health_get "$s" MODEL "$(state_get "$s" MODEL)")
  printf '{"session":"%s","agent":"%s","zone":"%s","role":"%s","state":"%s","blocked_reason":"%s","blocked_detail":"%s","model":"%s","effort":"%s","preset":"%s","profile":"%s","perm":"%s","parent":"%s","queue":%d,"activity":"%s","started":"%s","quota":%s}' \
    "$(json_escape "$s")" "$(json_escape "$(state_get "$s" AGENT)")" "$(json_escape "$(state_get "$s" ZONE)")" \
    "$(session_role "$s")" "$st" "$(json_escape "$reason")" "$(json_escape "$detail")" "$(json_escape "$model")" \
    "$(json_escape "$(state_get "$s" EFFORT)")" "$(json_escape "$(state_get "$s" PRESET)")" \
    "$(json_escape "$(state_get "$s" PROFILE default)")" "$(state_get "$s" PERM)" \
    "$(json_escape "$(state_get "$s" PARENT)")" "$(queue_len "$s")" "$(health_get "$s" ACTIVITY)" \
    "$(state_get "$s" STARTED_AT)" "$(_fleet_quota_json "$s")"
}

# Usage telemetry from the agent's status line; null when there is no fresh data.
_fleet_quota_json() {
  local s=$1 ts k v out='' sep=''
  ts=$(quota_get "$s" Q_TS 0)
  if (( ${EPOCHSECONDS:-$(date +%s)} - ts >= ${PRAMA_QUOTA_STALE:-3600} )); then printf 'null'; return 0; fi
  for k in Q_5H:five_hour_pct Q_5H_RESET:five_hour_resets_at Q_7D:seven_day_pct Q_7D_RESET:seven_day_resets_at \
           CTX:context_pct; do
    v=$(quota_get "$s" "${k%%:*}")
    [[ "$v" =~ ^[0-9]+$ ]] || v=null
    out+="$sep\"${k#*:}\":$v"; sep=','
  done
  v=$(quota_get "$s" COST); [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || v=null
  printf '{%s,"cost_usd":%s,"updated":%s}' "$out" "$v" "$ts"
}

_fleet_status() {
  local json=0 s sep=''
  [ "${1:-}" = --json ] && json=1
  if (( json )); then
    printf '['
    while IFS= read -r s; do printf '%s' "$sep"; _fleet_json_row "$s"; sep=','; done < <(prama_sessions)
    printf ']\n'
    return 0
  fi
  refresh_dimensions
  local n=0 st info model wd q
  wd=$(watchdog_running && printf 'watchdog ●' || printf 'watchdog ○')
  box_top "⚑ FLOTA" "$wd · máx ${PRAMA_FLEET_MAX:-8}" "$C_BORDER_HI"
  while IFS= read -r s; do
    (( n++ ))
    st=$(detect_session_state "$s")
    model=$(health_get "$s" MODEL "$(state_get "$s" MODEL)")
    box_row "$C_BORDER_HI" "$(state_badge "$st")  ${C_BOLD}$s${C_OFF}  ${C_MUTED}$(state_get "$s" AGENT) · $(session_role "$s") · ${model:-modelo por defecto}${C_OFF}$( [ -n "$(state_get "$s" PRESET)" ] && printf ' · preset %s' "$(state_get "$s" PRESET)")"
    q=$(quota_label "$s")
    [ -n "$q" ] && box_row "$C_BORDER_HI" "    ${C_MUTED}◔ $q${C_OFF}"
    if [ "$st" = BLOCKED ]; then
      info=$(session_block_info "$s")
      box_row "$C_BORDER_HI" "    ${C_ERR}▲ ${info%%|*}${C_OFF} ${C_MUTED}$(truncate_cols "${info#*|}" $(( W - 20 )))${C_OFF}"
    fi
    (( $(queue_len "$s") > 0 )) && box_row "$C_BORDER_HI" "    ${C_BRASS}$(queue_len "$s") tarea(s) en cola${C_OFF}"
  done < <(prama_sessions)
  (( n == 0 )) && box_row "$C_BORDER_HI" "${C_MUTED}(Sin agentes activos)${C_OFF}"
  box_bottom "fleet spawn · model · edit · restart · kill" "$C_BORDER_HI"
}

_fleet_spawn() {
  local agent='' zone='' name='' wt='' task='' json=0 arg m
  local role=executor profile=default perm=ask remote=${PRAMA_DEFAULT_REMOTE:-0}
  local a_exp=0 r_exp=0 p_exp=0
  (( ${PRAMA_SKIP_PERMISSIONS:-0} )) && perm=yolo
  local pass=()
  AGENT_MODEL='' AGENT_EFFORT='' PRESET=''
  while (( $# )); do
    arg=$1
    case "$arg" in
      --role|-O)    role=${2:?--role requiere un rol}; r_exp=1; shift 2 ;;
      --model|-m)   AGENT_MODEL=${2:?--model requiere un modelo}; shift 2 ;;
      --effort)     AGENT_EFFORT=${2:?--effort requiere un nivel}; shift 2 ;;
      --preset)     PRESET=${2:?--preset requiere un nombre}; shift 2 ;;
      --profile|-P) profile=${2:?--profile requiere un perfil}; p_exp=1; shift 2 ;;
      --name|-n)    name=${2:?--name requiere un nombre}; shift 2 ;;
      --worktree|-w) wt=${2:?--worktree requiere una rama}; shift 2 ;;
      --task)       task=${2:?--task requiere una instrucción}; shift 2 ;;
      --yolo)       perm=yolo; shift ;;
      --ask)        perm=ask; shift ;;
      --plan)       perm=plan; shift ;;
      --remote)     remote=1; shift ;;
      --no-remote)  remote=0; shift ;;
      --json)       json=1; shift ;;
      --)           shift; pass+=("$@"); break ;;
      *)
        if [ -z "$agent" ] && m=$(match_one "$arg" "${AGENTS[@]}"); then agent=$m; a_exp=1
        elif [ -z "$zone" ] && m=$(match_one "$arg" "${ZONES[@]}"); then zone=$m
        else die "Argumento no reconocido para fleet spawn: '$arg'"; fi
        shift ;;
    esac
  done
  AGENT=$agent ROLE=$role PROFILE=$profile
  preset_apply_defaults "$a_exp" "$r_exp" "$p_exp" || exit 1
  agent=$AGENT role=$ROLE profile=$PROFILE
  [ -n "$agent" ] || die "Uso: prama-agent fleet spawn <${AGENTS[*]// /|}> <zona> [opciones]"
  [ -n "$zone" ] || zone=$(state_get "${PRAMA_SESSION:-}" ZONE)
  [ -n "$zone" ] || die "Falta la zona. Zonas: ${ZONES[*]}"
  if [ -n "${PRAMA_SESSION:-}" ] && [ "${PRAMA_FLEET_SCOPE:-zone}" = zone ]; then
    local cz; cz=$(state_get "$PRAMA_SESSION" ZONE)
    [ -z "$cz" ] || [ "$cz" = "$zone" ] || die "Solo puedes lanzar agentes en tu zona ($cz)."
  fi
  [ "$role" = coordinator ] && [ -n "${PRAMA_SESSION:-}" ] && die "Un agente no puede lanzar otro coordinador."
  [ -n "$AGENT_MODEL" ] && _fleet_check_model "$agent" "$AGENT_MODEL"
  local live
  live=$(prama_sessions | grep -c . || true)
  (( live < ${PRAMA_FLEET_MAX:-8} )) || die "Límite de la flota alcanzado ($live/${PRAMA_FLEET_MAX:-8}). Cierra agentes con 'prama-agent fleet kill'."
  [ -n "$name" ] && { valid_session_name "$name" || die "Nombre inválido: '$name'"; tmx_has "$name" && die "Ya existe la sesión '$name'."; }

  PASS=(${pass[@]+"${pass[@]}"}) ONESHOT=0 PARALLEL=1 DAEMON_TASK='' DAEMON_INTERVAL=60
  local out
  out=$(launch_agent "$agent" "$zone" "$role" "$perm" "$remote" "$profile" "$wt" porcelain "$name") || exit 1
  out=${out##*$'\n'}
  if [ -n "$task" ]; then
    queue_push "$out" "$task"
    bus_event queued "$(_fleet_caller)" "$out" "$task"
  fi
  if (( json )); then
    printf '{"session":"%s","agent":"%s","zone":"%s","role":"%s","model":"%s","preset":"%s","task_queued":%s}\n' \
      "$(json_escape "$out")" "$agent" "$(json_escape "$zone")" "$role" "$(json_escape "$AGENT_MODEL")" \
      "$(json_escape "$PRESET")" "$([ -n "$task" ] && echo true || echo false)"
  else
    printf '%s\n' "$out"
    [ -n "$task" ] && info_msg "Tarea inicial en cola: el watchdog la entrega cuando el agente esté listo." >&2
  fi
}

_fleet_kill() {
  local s=${1:-}
  [ -n "$s" ] || die "Uso: prama-agent fleet kill <sesión>"
  _fleet_authorize "$s" kill
  tmx_kill "$s"
  state_remove "$s"
  bus_event stopped "$(_fleet_caller)" "$s" "fleet kill"
  ok "Sesión '$s' cerrada."
}

# agy silently falls back to its default model on an unknown id, so ids are checked against
# `agy models` (skipped when the list cannot be fetched).
_fleet_check_model() {
  local agent=$1 model=$2 list
  [ "$agent" = agy ] && agent_installed agy || return 0
  list=$(timeout 20 agy models 2>/dev/null | grep -v '^Fetching') || return 0
  [ -n "$list" ] || return 0
  awk -F'\t' -v m="$model" '$1 == m || $2 == m { f = 1 } END { exit !f }' <<< "$list" && return 0
  die "agy no conoce el modelo '$model'. Disponibles: $(cut -f1 <<< "$list" | tr '\n' ' ')"
}

# Model changes always restart the agent with --model (claude/agy) or a new opencode config.
# Typing "/model X" into claude is NOT used: it also saves X as the user's global default.
_fleet_model() {
  local s=${1:-} model=${2:-}
  [ -n "$s" ] && [ -n "$model" ] || die "Uso: prama-agent fleet model <sesión> <modelo>"
  valid_model "$model" || die "Modelo inválido: '$model'"
  _fleet_authorize "$s" model
  _fleet_check_model "$(state_get "$s" AGENT)" "$model"
  _fleet_restart_in_place "$s" "MODEL=$model"
  bus_event model "$(_fleet_caller)" "$s" "$model"
  ok "'$s' se reinicia con el modelo $model (misma conversación)."
}

_fleet_edit() {
  local s=${1:-}
  [ -n "$s" ] || die "Uso: prama-agent fleet edit <sesión> [--model M] [--effort E] [--preset P|none] [--profile X] [--perm ask|plan|yolo]"
  shift
  _fleet_authorize "$s" edit
  local kv=() v
  while (( $# )); do
    case "$1" in
      --model|-m) v=${2:?}; valid_model "$v" || die "Modelo inválido"; _fleet_check_model "$(state_get "$s" AGENT)" "$v"
                  kv+=("MODEL=$v"); shift 2 ;;
      --effort)   v=${2:?}; [[ "$v" =~ ^(|low|medium|high|xhigh|max)$ ]] || die "--effort: low|medium|high|xhigh|max"; kv+=("EFFORT=$v"); shift 2 ;;
      --preset)   v=${2:?}; [ "$v" = none ] && v=''
                  [ -z "$v" ] || preset_find "$v" >/dev/null || die "Preset desconocido: '$v'"
                  kv+=("PRESET=$v"); shift 2 ;;
      --profile|-P) v=${2:?}; is_in "$v" "${AVAILABLE_PROFILES[@]}" || die "Perfil desconocido: '$v'"; kv+=("PROFILE=$v"); shift 2 ;;
      --perm)     v=${2:?}; is_in "$v" "${AVAILABLE_PERM_MODES[@]}" || die "--perm: ${AVAILABLE_PERM_MODES[*]}"
                  [ "$(session_role "$s")" = reader ] && [ "$v" != plan ] && die "Un reader siempre es plan."
                  kv+=("PERM=$v"); shift 2 ;;
      *) die "Opción no reconocida para fleet edit: '$1'" ;;
    esac
  done
  (( ${#kv[@]} )) || die "Nada que cambiar. Opciones: --model --effort --preset --profile --perm"
  _fleet_restart_in_place "$s" "${kv[@]}"
  bus_event edited "$(_fleet_caller)" "$s" "${kv[*]}"
  ok "'$s' se reinicia con: ${kv[*]}"
}

_fleet_restart() {
  local s=${1:-}
  [ -n "$s" ] || die "Uso: prama-agent fleet restart <sesión>"
  _fleet_authorize "$s" restart
  _fleet_restart_in_place "$s"
  bus_event restarted "$(_fleet_caller)" "$s" "fleet restart"
  ok "'$s' reiniciado (misma conversación)."
}

_fleet_presets() {
  local n f desc any=0
  printf '%sPresets%s (perfiles con skills; --preset <nombre>):\n' "$C_BOLD" "$C_OFF"
  while IFS= read -r n; do
    any=1
    f=$(preset_find "$n")
    PRESET=$n preset_load "$n" >/dev/null 2>&1
    desc=${PRESET_KV[DESCRIPTION]:-}
    printf '  %s%-18s%s %s %s(%s%s)%s\n' "$C_NEON" "$n" "$C_OFF" "$desc" "$C_MUTED" \
      "${PRESET_KV[AGENT]:-cualquier agente}" "${PRESET_KV[MODEL]:+ · ${PRESET_KV[MODEL]}}" "$C_OFF"
  done < <(preset_names)
  (( any )) || printf '  (ninguno) — crea uno en %s/presets/<nombre>.env\n' "$PRAMA_CONFIG_HOME"
  printf '\n%sAgentes:%s ' "$C_BOLD" "$C_OFF"
  local a
  for a in "${AGENTS[@]}"; do
    if agent_installed "$a"; then printf '%s✔ %s%s  ' "$C_LIVE" "$a" "$C_OFF"; else printf '%s✖ %s%s  ' "$C_MUTED" "$a" "$C_OFF"; fi
  done
  printf '\n'
}

_fleet_models() {
  local agent=${1:-}
  case "$agent" in
    claude|'')
      printf 'claude:   opus · sonnet · haiku · fable  (alias) o un id completo, p. ej. claude-opus-5-5\n' ;;
  esac
  case "$agent" in
    opencode|'')
      if agent_installed opencode; then
        printf 'opencode: (proveedor/modelo; gratis = sufijo :free)\n'
        timeout 30 opencode models openrouter 2>/dev/null | sed 's/^/  /' | head -n "${PRAMA_MODELS_LIMIT:-400}"
      else
        printf 'opencode: no instalado (npm i -g @opencode/cli). Formato: openrouter/<proveedor>/<modelo>\n'
      fi ;;
  esac
  case "$agent" in
    agy|'')
      if agent_installed agy; then
        printf 'agy:      (id  nombre)\n'
        timeout 30 agy models 2>/dev/null | grep -v '^Fetching' | sed 's/^/  /'
      else
        printf 'agy:      no instalado\n'
      fi ;;
  esac
}

_fleet_watchdog() {
  case "${1:-status}" in
    start)  watchdog_ensure force && ok "Watchdog activo ($(watchdog_session))." ;;
    stop)   tmx_kill "$(watchdog_session)" && ok "Watchdog detenido." ;;
    logs)   tmx_capture "$(watchdog_session)" "${2:-60}" ;;
    tick)   declare -gA W_PREV=() W_READY=() W_QGROUP=() W_QALERTED=(); watchdog_tick ;;   # one pass (scripts, cron, tests)
    status) if watchdog_running; then ok "Watchdog activo ($(watchdog_session))."; else warn "Watchdog detenido (se inicia solo al lanzar un agente)."; fi ;;
    *)      die "Uso: prama-agent fleet watchdog [status|start|stop|logs|tick]" ;;
  esac
}

# Hooks are how prama learns, without reading the screen, that an agent is working, idle or
# blocked (and why). Claude gets them per session (--settings); agy only reads them from
# ~/.gemini/config/hooks.json, where prama keeps one named entry.
_fleet_hooks() {
  case "${1:-status}" in
    status)
      printf 'claude:  por sesión (--settings %s)%s\n' "$PRAMA_STATE_HOME/hooks/claude-settings.json" \
        "$( (( ${PRAMA_HOOKS:-1} )) || printf ' — desactivados (PRAMA_HOOKS=0)')"
      if agy_hooks_installed; then printf 'agy:     instalados en %s (entrada "prama-agent")\n' "$(agy_hooks_file)"
      else printf 'agy:     no instalados (se instalan al lanzar agy; o: prama-agent fleet hooks install)\n'; fi
      printf 'statusline (cuota): %s\n' "$( (( ${PRAMA_STATUSLINE:-1} )) && echo activa || echo 'desactivada (PRAMA_STATUSLINE=0)')" ;;
    install)   PRAMA_HOOKS=1 agy_hooks_ensure && ok "Hooks de agy instalados en $(agy_hooks_file)." \
                 || die "No se pudo escribir $(agy_hooks_file) (¿agy nunca se ejecutó, falta jq o el JSON es inválido?)." ;;
    uninstall) agy_hooks_remove && ok "Entrada 'prama-agent' eliminada de $(agy_hooks_file)." ;;
    *) die "Uso: prama-agent fleet hooks [status|install|uninstall]" ;;
  esac
}

_fleet_help() {
  cat <<EOF
${C_BOLD}prama-agent fleet${C_OFF} — gestión de la flota (para humanos y coordinadores)

  status [--json]                         estado, bloqueos y motivo, modelo, preset, cola, cuota
  spawn <agente> <zona> [opciones]        lanza un agente extra (imprime el nombre de la sesión)
        --role R --model M --effort E --preset P --profile X --name N --worktree B
        --task "instrucción inicial" --yolo|--ask|--plan --remote|--no-remote --json
  model <sesión> <modelo>                 cambia el modelo (reinicio en el mismo panel, misma conversación)
  edit <sesión> --model/--effort/--preset/--profile/--perm …
  restart <sesión>                        relanza el agente conservando la conversación
  kill <sesión>                           cierra el agente
  presets                                 presets disponibles y agentes instalados
  models [claude|opencode|agy]            modelos aceptados
  watchdog [status|start|stop|logs|tick]  vigilante de la flota (alertas, cuota y entrega de colas)
  hooks [status|install|uninstall]        hooks de salud de claude/agy

Desde un agente (PRAMA_SESSION definido) no se puede actuar sobre uno mismo ni sobre un coordinador,
y solo dentro de PRAMA_FLEET_SCOPE=${PRAMA_FLEET_SCOPE:-zone}. Máximo ${PRAMA_FLEET_MAX:-8} agentes vivos.
EOF
}

subcmd_fleet() {
  local cmd=${1:-status}
  (( $# )) && shift
  case "$cmd" in
    status|ls)      _fleet_status "$@" ;;
    spawn|new)      _fleet_spawn "$@" ;;
    kill|stop|rm)   _fleet_kill "$@" ;;
    model)          _fleet_model "$@" ;;
    edit|set)       _fleet_edit "$@" ;;
    restart)        _fleet_restart "$@" ;;
    presets)        _fleet_presets ;;
    models)         _fleet_models "$@" ;;
    watchdog|watch) _fleet_watchdog "$@" ;;
    hooks)          _fleet_hooks "$@" ;;
    help|-h|--help) _fleet_help ;;
    *) die "Subcomando de fleet desconocido: '$cmd' (prama-agent fleet help)" ;;
  esac
}
