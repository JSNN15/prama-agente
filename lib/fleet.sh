#!/usr/bin/env bash
# lib/fleet.sh — Fleet management API (used by humans and by coordinator agents)
# Copyright 2026 Julian Neira Nova
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
  is_internal_session "$t" && die "$(_t "'%s' is an internal prama session." "$t")"
  [ -n "$caller" ] || return 0   # human operator
  [ "$t" = "$caller" ] && die "$(_t "An agent cannot apply '%s' to itself (%s)." "$action" "$t")"
  [ "$(session_role "$t")" = coordinator ] && die "$(_t "Agents cannot apply '%s' to a coordinator (%s)." "$action" "$t")"
  case "${PRAMA_FLEET_SCOPE:-zone}" in
    all) ;;
    children)
      [ "$(state_get "$t" PARENT)" = "$caller" ] || die "$(_t "'%s' was not launched by %s (PRAMA_FLEET_SCOPE=children)." "$t" "$caller")" ;;
    *)
      local tz cz tt ct
      tz=$(state_get "$t" ZONE) cz=$(state_get "$caller" ZONE)
      [ -n "$cz" ] && [ "$tz" = "$cz" ] || die "$(_t "'%s' is outside your zone (%s) (PRAMA_FLEET_SCOPE=zone)." "$t" "${cz:-?}")"
      # Several teams can share a zone: an agent of another team is not yours to manage.
      tt=$(session_team "$t") || tt=''
      ct=$(session_team "$caller") || ct=''
      [ -z "$tt" ] || [ "$tt" = "$ct" ] || die "$(_t "'%s' belongs to another team ('%s')." "$t" "$(team_name "$tt")")" ;;
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
  [ "$(session_role "$s")" = daemon ] && { ok "$(_t "'%s' will apply the new configuration on its next cycle." "$s")"; return 0; }
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
  local team='' tc
  if tc=$(session_team "$s"); then team=$(team_name "$tc"); fi
  printf '{"session":"%s","agent":"%s","zone":"%s","team":"%s","role":"%s","state":"%s","blocked_reason":"%s","blocked_detail":"%s","model":"%s","effort":"%s","preset":"%s","profile":"%s","perm":"%s","parent":"%s","queue":%d,"activity":"%s","started":"%s","quota":%s}' \
    "$(json_escape "$s")" "$(json_escape "$(state_get "$s" AGENT)")" "$(json_escape "$(state_get "$s" ZONE)")" \
    "$(json_escape "$team")" "$(session_role "$s")" "$st" "$(json_escape "$reason")" "$(json_escape "$detail")" "$(json_escape "$model")" \
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
  local n=0 st info model wd q l_def l_queue
  wd=$(watchdog_running && printf 'watchdog ●' || printf 'watchdog ○')
  _tv l_def 'default model'
  box_top "$(_t '⚑ FLEET')" "$wd · $(_t 'max %s' "${PRAMA_FLEET_MAX:-8}")" "$C_BORDER_HI"
  local depth ind
  while IFS='|' read -r s depth _; do
    (( n++ ))
    ind=''; (( depth )) && ind='└ '
    st=$(detect_session_state "$s")
    model=$(health_get "$s" MODEL "$(state_get "$s" MODEL)")
    box_row "$C_BORDER_HI" "$ind$(state_badge "$st")  ${C_BOLD}$s${C_OFF}  ${C_MUTED}$(state_get "$s" AGENT) · $(session_role "$s") · ${model:-$l_def}${C_OFF}$( [ -n "$(state_get "$s" PRESET)" ] && printf ' · preset %s' "$(state_get "$s" PRESET)")"
    q=$(quota_label "$s")
    [ -n "$q" ] && box_row "$C_BORDER_HI" "    ${C_MUTED}◔ $q${C_OFF}"
    if [ "$st" = BLOCKED ]; then
      info=$(session_block_info "$s")
      box_row "$C_BORDER_HI" "    ${C_ERR}▲ ${info%%|*}${C_OFF} ${C_MUTED}$(truncate_cols "${info#*|}" $(( W - 20 )))${C_OFF}"
    fi
    if (( $(queue_len "$s") > 0 )); then
      _tv l_queue '%s queued task(s)' "$(queue_len "$s")"
      box_row "$C_BORDER_HI" "    ${C_BRASS}$l_queue${C_OFF}"
    fi
  done < <(prama_team_order)
  (( n == 0 )) && box_row "$C_BORDER_HI" "${C_MUTED}$(_t '(No active agents)')${C_OFF}"
  box_bottom "swarm · cockpit · fleet spawn|model|edit|restart|kill" "$C_BORDER_HI"
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
      --role|-O)    role=${2:?$(_t '--role requires a role')}; r_exp=1; shift 2 ;;
      --model|-m)   AGENT_MODEL=${2:?$(_t '--model requires a model')}; shift 2 ;;
      --effort)     AGENT_EFFORT=${2:?$(_t '--effort requires a level')}; shift 2 ;;
      --preset)     PRESET=${2:?$(_t '--preset requires a name')}; shift 2 ;;
      --profile|-P) profile=${2:?$(_t '--profile requires a profile')}; p_exp=1; shift 2 ;;
      --name|-n)    name=${2:?$(_t '--name requires a name')}; shift 2 ;;
      --worktree|-w) wt=${2:?$(_t '--worktree requires a branch')}; shift 2 ;;
      --task)       task=${2:?$(_t '--task requires an instruction')}; shift 2 ;;
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
        else die "$(_t "Unrecognized argument for fleet spawn: '%s'" "$arg")"; fi
        shift ;;
    esac
  done
  AGENT=$agent ROLE=$role PROFILE=$profile
  preset_apply_defaults "$a_exp" "$r_exp" "$p_exp" || exit 1
  agent=$AGENT role=$ROLE profile=$PROFILE
  [ -n "$agent" ] || die "$(_t 'Usage: prama-agent fleet spawn <%s> <zone> [options]' "${AGENTS[*]// /|}")"
  [ -n "$zone" ] || zone=$(state_get "${PRAMA_SESSION:-}" ZONE)
  [ -n "$zone" ] || die "$(_t 'Missing zone. Zones: %s' "${ZONES[*]}")"
  if [ -n "${PRAMA_SESSION:-}" ] && [ "${PRAMA_FLEET_SCOPE:-zone}" = zone ]; then
    local cz; cz=$(state_get "$PRAMA_SESSION" ZONE)
    [ -z "$cz" ] || [ "$cz" = "$zone" ] || die "$(_t 'You can only launch agents in your zone (%s).' "$cz")"
  fi
  [ "$role" = coordinator ] && [ -n "${PRAMA_SESSION:-}" ] && die "$(_t 'An agent cannot launch another coordinator.')"
  [ -n "$AGENT_MODEL" ] && _fleet_check_model "$agent" "$AGENT_MODEL"
  local live
  live=$(prama_sessions | grep -c . || true)
  (( live < ${PRAMA_FLEET_MAX:-8} )) || die "$(_t "Fleet limit reached (%s/%s). Close agents with 'prama-agent fleet kill'." "$live" "${PRAMA_FLEET_MAX:-8}")"
  [ -n "$name" ] && { valid_session_name "$name" || die "$(_t "Invalid name: '%s'" "$name")"; tmx_has "$name" && die "$(_t "Session '%s' already exists." "$name")"; }

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
    [ -n "$task" ] && info_msg "$(_t 'Initial task queued: the watchdog delivers it when the agent is ready.')" >&2
  fi
}

_fleet_kill() {
  local s=${1:-}
  [ -n "$s" ] || die "$(_t 'Usage: prama-agent fleet kill <session>')"
  _fleet_authorize "$s" kill
  tmx_kill "$s"
  state_remove "$s"
  bus_event stopped "$(_fleet_caller)" "$s" "fleet kill"
  ok "$(_t "Session '%s' closed." "$s")"
}

# agy silently falls back to its default model on an unknown id, so ids are checked against
# `agy models` (skipped when the list cannot be fetched).
_fleet_check_model() {
  local agent=$1 model=$2 list
  [ "$agent" = agy ] && agent_installed agy || return 0
  list=$(timeout 20 agy models 2>/dev/null | grep -v '^Fetching') || return 0
  [ -n "$list" ] || return 0
  awk -F'\t' -v m="$model" '$1 == m || $2 == m { f = 1 } END { exit !f }' <<< "$list" && return 0
  die "$(_t "agy does not know the model '%s'. Available: %s" "$model" "$(cut -f1 <<< "$list" | tr '\n' ' ')")"
}

# Model changes always restart the agent with --model (claude/agy) or a new opencode config.
# Typing "/model X" into claude is NOT used: it also saves X as the user's global default.
_fleet_model() {
  local s=${1:-} model=${2:-}
  [ -n "$s" ] && [ -n "$model" ] || die "$(_t 'Usage: prama-agent fleet model <session> <model>')"
  valid_model "$model" || die "$(_t "Invalid model: '%s'" "$model")"
  _fleet_authorize "$s" model
  _fleet_check_model "$(state_get "$s" AGENT)" "$model"
  _fleet_restart_in_place "$s" "MODEL=$model"
  bus_event model "$(_fleet_caller)" "$s" "$model"
  ok "$(_t "'%s' restarts with model %s (same conversation)." "$s" "$model")"
}

_fleet_edit() {
  local s=${1:-}
  [ -n "$s" ] || die "$(_t 'Usage: prama-agent fleet edit <session> [--model M] [--effort E] [--preset P|none] [--profile X] [--perm ask|plan|yolo]')"
  shift
  _fleet_authorize "$s" edit
  local kv=() v
  while (( $# )); do
    case "$1" in
      --model|-m) v=${2:?}; valid_model "$v" || die "$(_t 'Invalid model')"; _fleet_check_model "$(state_get "$s" AGENT)" "$v"
                  kv+=("MODEL=$v"); shift 2 ;;
      --effort)   v=${2:?}; [[ "$v" =~ ^(|low|medium|high|xhigh|max)$ ]] || die "--effort: low|medium|high|xhigh|max"; kv+=("EFFORT=$v"); shift 2 ;;
      --preset)   v=${2:?}; [ "$v" = none ] && v=''
                  [ -z "$v" ] || preset_find "$v" >/dev/null || die "$(_t "Unknown preset: '%s'" "$v")"
                  kv+=("PRESET=$v"); shift 2 ;;
      --profile|-P) v=${2:?}; is_in "$v" "${AVAILABLE_PROFILES[@]}" || die "$(_t "Unknown profile: '%s'" "$v")"; kv+=("PROFILE=$v"); shift 2 ;;
      --perm)     v=${2:?}; is_in "$v" "${AVAILABLE_PERM_MODES[@]}" || die "--perm: ${AVAILABLE_PERM_MODES[*]}"
                  [ "$(session_role "$s")" = reader ] && [ "$v" != plan ] && die "$(_t 'A reader is always plan.')"
                  kv+=("PERM=$v"); shift 2 ;;
      *) die "$(_t "Unrecognized option for fleet edit: '%s'" "$1")" ;;
    esac
  done
  (( ${#kv[@]} )) || die "$(_t 'Nothing to change. Options: --model --effort --preset --profile --perm')"
  _fleet_restart_in_place "$s" "${kv[@]}"
  bus_event edited "$(_fleet_caller)" "$s" "${kv[*]}"
  ok "$(_t "'%s' restarts with: %s" "$s" "${kv[*]}")"
}

_fleet_restart() {
  local s=${1:-}
  [ -n "$s" ] || die "$(_t 'Usage: prama-agent fleet restart <session>')"
  _fleet_authorize "$s" restart
  _fleet_restart_in_place "$s"
  bus_event restarted "$(_fleet_caller)" "$s" "fleet restart"
  ok "$(_t "'%s' restarted (same conversation)." "$s")"
}

_fleet_presets() {
  local n f desc any=0 l_any
  _tv l_any 'any agent'
  printf '%sPresets%s %s\n' "$C_BOLD" "$C_OFF" "$(_t '(skill-based profiles; --preset <name>):')"
  while IFS= read -r n; do
    any=1
    f=$(preset_find "$n")
    PRESET=$n preset_load "$n" >/dev/null 2>&1
    desc=${PRESET_KV[DESCRIPTION]:-}
    printf '  %s%-18s%s %s %s(%s%s)%s\n' "$C_NEON" "$n" "$C_OFF" "$desc" "$C_MUTED" \
      "${PRESET_KV[AGENT]:-$l_any}" "${PRESET_KV[MODEL]:+ · ${PRESET_KV[MODEL]}}" "$C_OFF"
  done < <(preset_names)
  (( any )) || printf '%s\n' "$(_t '  (none) — create one in %s/presets/<name>.env' "$PRAMA_CONFIG_HOME")"
  printf '\n%s%s%s ' "$C_BOLD" "$(_t 'Agents:')" "$C_OFF"
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
      printf '%s\n' "$(_t 'claude:   opus · sonnet · haiku · fable  (aliases) or a full id, e.g. claude-opus-5-5')" ;;
  esac
  case "$agent" in
    opencode|'')
      if agent_installed opencode; then
        printf '%s\n' "$(_t 'opencode: (provider/model; free = :free suffix)')"
        timeout 30 opencode models openrouter 2>/dev/null | sed 's/^/  /' | head -n "${PRAMA_MODELS_LIMIT:-400}"
      else
        printf '%s\n' "$(_t 'opencode: not installed (npm i -g @opencode/cli). Format: openrouter/<provider>/<model>')"
      fi ;;
  esac
  case "$agent" in
    agy|'')
      if agent_installed agy; then
        printf '%s\n' "$(_t 'agy:      (id  name)')"
        timeout 30 agy models 2>/dev/null | grep -v '^Fetching' | sed 's/^/  /'
      else
        printf '%s\n' "$(_t 'agy:      not installed')"
      fi ;;
  esac
}

_fleet_watchdog() {
  case "${1:-status}" in
    start)  watchdog_ensure force && ok "$(_t 'Watchdog running (%s).' "$(watchdog_session)")" ;;
    stop)   tmx_kill "$(watchdog_session)" && ok "$(_t 'Watchdog stopped.')" ;;
    logs)   tmx_capture "$(watchdog_session)" "${2:-60}" ;;
    tick)   declare -gA W_PREV=() W_READY=() W_QGROUP=() W_QALERTED=(); watchdog_tick ;;   # one pass (scripts, cron, tests)
    status) if watchdog_running; then ok "$(_t 'Watchdog running (%s).' "$(watchdog_session)")"
            else warn "$(_t 'Watchdog stopped (it starts by itself when an agent is launched).')"; fi ;;
    *)      die "$(_t 'Usage: prama-agent fleet watchdog [status|start|stop|logs|tick]')" ;;
  esac
}

# Hooks are how prama learns, without reading the screen, that an agent is working, idle or
# blocked (and why). Claude gets them per session (--settings); agy only reads them from
# ~/.gemini/config/hooks.json, where prama keeps one named entry.
_fleet_hooks() {
  case "${1:-status}" in
    status)
      printf '%s\n' "$(_t 'claude:  per session (--settings %s)%s' "$PRAMA_STATE_HOME/hooks/claude-settings.json" \
        "$( (( ${PRAMA_HOOKS:-1} )) || _t ' — disabled (PRAMA_HOOKS=0)')")"
      if agy_hooks_installed; then printf '%s\n' "$(_t 'agy:     installed in %s ("prama-agent" entry)' "$(agy_hooks_file)")"
      else printf '%s\n' "$(_t 'agy:     not installed (installed when agy is launched; or: prama-agent fleet hooks install)')"; fi
      if (( ${PRAMA_STATUSLINE:-1} )); then printf '%s\n' "$(_t 'statusline (quota): enabled')"
      else printf '%s\n' "$(_t 'statusline (quota): disabled (PRAMA_STATUSLINE=0)')"; fi ;;
    install)   PRAMA_HOOKS=1 agy_hooks_ensure && ok "$(_t 'agy hooks installed in %s.' "$(agy_hooks_file)")" \
                 || die "$(_t 'Could not write %s (has agy never run, is jq missing, or is the JSON invalid?).' "$(agy_hooks_file)")" ;;
    uninstall) agy_hooks_remove && ok "$(_t "Removed the 'prama-agent' entry from %s." "$(agy_hooks_file)")" ;;
    *) die "$(_t 'Usage: prama-agent fleet hooks [status|install|uninstall]')" ;;
  esac
}

_fleet_help() {
  case $PRAMA_UI_LANG in
    es) _fleet_help_es ;;
    *)  _fleet_help_en ;;
  esac
}

_fleet_help_en() {
  cat <<EOF
${C_BOLD}prama-agent fleet${C_OFF} — fleet management (for humans and coordinators)

  status [--json]                         state, blocks and their reason, model, preset, queue, quota
  spawn <agent> <zone> [options]          launches an extra agent (prints the session name)
        --role R --model M --effort E --preset P --profile X --name N --worktree B
        --task "initial instruction" --yolo|--ask|--plan --remote|--no-remote --json
  model <session> <model>                 changes the model (restart in the same pane, same conversation)
  edit <session> --model/--effort/--preset/--profile/--perm …
  restart <session>                       relaunches the agent, keeping the conversation
  kill <session>                          closes the agent
  presets                                 available presets and installed agents
  models [claude|opencode|agy]            accepted models
  watchdog [status|start|stop|logs|tick]  fleet watchdog (alerts, quota and queue delivery)
  hooks [status|install|uninstall]        claude/agy health hooks

From an agent (PRAMA_SESSION set) you cannot act on yourself or on a coordinator,
and only within PRAMA_FLEET_SCOPE=${PRAMA_FLEET_SCOPE:-zone}. At most ${PRAMA_FLEET_MAX:-8} live agents.
EOF
}

_fleet_help_es() {
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
    *) die "$(_t "Unknown fleet subcommand: '%s' (prama-agent fleet help)" "$cmd")" ;;
  esac
}
