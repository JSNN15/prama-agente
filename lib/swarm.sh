#!/usr/bin/env bash
# lib/swarm.sh — Teams (coordinator + workers), the live team cockpit and in-tmux navigation
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
#
# Public API:
#   subcmd_swarm <zone> [opts] | stop <zone> | help     coordinator + N workers in one command
#   subcmd_cockpit [zone|session] [--no-attach]         live split view of a zone's team
#   cockpit_ensure <zone> [focus_session]               (re)builds the cockpit, prints its name
#   nav_main <pick|cockpit|next|prev|click> <client> [session] [range]   tmux key bindings
#
# A team is not a separate object: it is the coordinator of a zone plus the sessions whose
# PARENT is that coordinator (see prama_team_order). Everything stays a normal prama session,
# visible to the bus, the fleet API, the watchdog and Telegram.

# _swarm_spec_parse "agy:2,claude" → SW_AGENTS=(agy agy claude)
_swarm_spec_parse() {
  local spec=${1// /} part a n i
  SW_AGENTS=()
  IFS=',' read -ra _parts <<< "$spec"
  for part in "${_parts[@]}"; do
    [ -n "$part" ] || continue
    a=${part%%:*} n=1
    [[ "$part" == *:* ]] && n=${part#*:}
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 12 )) || die "Cantidad inválida en '$part' (1-12)"
    is_in "$a" "${AGENTS[@]}" || die "Agente no habilitado: '$a' (${AGENTS[*]})"
    agent_installed "$a" || die "El agente '$a' no está instalado."
    for (( i = 0; i < n; i++ )); do SW_AGENTS+=("$a"); done
  done
  (( ${#SW_AGENTS[@]} )) || die "Indica al menos un agente ejecutor (p. ej. --workers agy:2)."
}

# Exact zone name or a unique prefix ("b" → backend).
match_zone() { match_one "$1" "${ZONES[@]}"; }

# Coordinator of a zone, if one is running.
zone_coordinator() {
  local s
  while IFS= read -r s; do
    [ "$(session_role "$s")" = coordinator ] && [ "$(state_get "$s" ZONE)" = "$1" ] && { printf '%s' "$s"; return 0; }
  done < <(prama_sessions)
  return 1
}

_swarm_usage() {
  cat <<EOF
Uso: prama-agent swarm <zona> [opciones]       coordinador + agentes ejecutores, en un paso
       --coord <agente>          agente coordinador (por defecto: claude)
       --workers <spec>          ejecutores, p. ej. agy:3  o  agy:2,claude:1  (def. ${PRAMA_SWARM_WORKERS:-agy:2})
       --model <m>               modelo del coordinador
       --worker-model <m>        modelo de los ejecutores
       --task "<objetivo>"       objetivo inicial para el coordinador
       --no-open                 no abrir el cockpit al terminar
     prama-agent swarm stop <zona>             cierra el equipo de la zona (coordinador y sus agentes)

Si la zona ya tiene coordinador, los nuevos ejecutores se suman a su equipo.
Navegación dentro de tmux: ${PRAMA_NAV_KEY:-M-a} agentes · ${PRAMA_COCKPIT_KEY:-M-c} cockpit · ${PRAMA_MENU_KEY:-M-m} menú.
EOF
}

subcmd_swarm() {
  case "${1:-}" in
    ''|help|-h|--help) _swarm_usage ;;
    stop|down)         shift; _swarm_stop "$@" ;;
    start|up)          shift; _swarm_start "$@" ;;
    *)                 _swarm_start "$@" ;;
  esac
}

_swarm_start() {
  local zone='' coord_a=claude spec=${PRAMA_SWARM_WORKERS:-agy:2} cmodel='' wmodel='' task='' open=1 m
  while (( $# )); do
    case "$1" in
      --coord|-c)        coord_a=${2:?--coord requiere un agente}; shift 2 ;;
      --workers|-w)      spec=${2:?--workers requiere agente:cantidad}; shift 2 ;;
      --model|-m)        cmodel=${2:?}; valid_model "$cmodel" || die "Modelo inválido: '$cmodel'"; shift 2 ;;
      --worker-model)    wmodel=${2:?}; valid_model "$wmodel" || die "Modelo inválido: '$wmodel'"; shift 2 ;;
      --task|-t)         task=${2:?--task requiere un texto}; shift 2 ;;
      --no-open)         open=0; shift ;;
      --open)            open=1; shift ;;
      -*)                die "Opción desconocida: $1 (prama-agent swarm help)" ;;
      *)
        [ -z "$zone" ] || die "Argumento sobrante: '$1'"
        m=$(match_zone "$1") || die "Zona desconocida: '$1'. Zonas: ${ZONES[*]}"
        zone=$m; shift ;;
    esac
  done
  [ -n "$zone" ] || { _swarm_usage >&2; die "Falta la zona."; }
  is_in "$coord_a" "${AGENTS[@]}" && agent_installed "$coord_a" || die "Coordinador no disponible: '$coord_a'"
  _swarm_spec_parse "$spec"

  local live
  live=$(prama_sessions | grep -c . || true)
  local cs need=${#SW_AGENTS[@]}
  cs=$(zone_coordinator "$zone") || need=$(( need + 1 ))
  # Called by an agent (a coordinator growing its team): same guard rails as `fleet spawn`.
  if [ -n "${PRAMA_SESSION:-}" ]; then
    local own; own=$(state_get "$PRAMA_SESSION" ZONE)
    [ "${PRAMA_FLEET_SCOPE:-zone}" = all ] || [ -z "$own" ] || [ "$own" = "$zone" ] \
      || die "Solo puedes formar equipos en tu zona ($own)."
    [ -n "$cs" ] || die "Un agente no puede crear un coordinador; pide al operador: prama-agent swarm $zone"
    open=0
  fi
  (( live + need <= ${PRAMA_FLEET_MAX:-8} )) \
    || die "El equipo necesita $need sesiones y hay $live de ${PRAMA_FLEET_MAX:-8} (PRAMA_FLEET_MAX)."

  if [ -z "$cs" ]; then
    cs=$("$SELF_PATH" "$coord_a" "$zone" --role coordinator --bg --porcelain ${cmodel:+--model "$cmodel"}) \
      || die "No se pudo lanzar el coordinador."
    ok "Coordinador: $cs ($coord_a)"
  else
    info_msg "La zona ya tiene coordinador: $cs (los ejecutores se suman a su equipo)."
  fi

  local a w team=()
  for a in "${SW_AGENTS[@]}"; do
    w=$(PRAMA_PARENT=$cs "$SELF_PATH" "$a" "$zone" --role executor --bg --porcelain --parallel ${wmodel:+--model "$wmodel"}) \
      || { warn "No se pudo lanzar un ejecutor $a."; continue; }
    team+=("$w ($a)")
    ok "Ejecutor: $w ($a)"
  done

  # The coordinator learns its team (and the objective) as soon as it is ready: the watchdog
  # delivers queued messages to an agent that has been READY for two ticks.
  local brief="[PRAMA] Tu equipo en '$zone': ${team[*]:-(sin ejecutores)}. Delega con 'prama-agent bus assign <sesión> \"<tarea>\"', revisa con 'prama-agent fleet status' y suma o quita agentes con 'prama-agent fleet spawn|kill'."
  [ -n "$task" ] && brief+=" OBJETIVO: $task"
  queue_push "$cs" "$brief"
  bus_event queued operator "$cs" "equipo: ${team[*]:-}${task:+ · objetivo: $task}"
  watchdog_ensure || true
  declare -F telegram_notify >/dev/null && telegram_notify "🤝 Equipo en '$zone': $cs + ${#team[@]} ejecutor(es)" >/dev/null 2>&1

  if (( open )) && [ -t 0 ] && [ -t 1 ]; then
    subcmd_cockpit "$zone" --focus "$cs"
  else
    info_msg "Cockpit del equipo: prama-agent cockpit $zone"
  fi
}

_swarm_stop() {
  local zone=${1:-} m cs s n=0
  [ -n "$zone" ] || die "Uso: prama-agent swarm stop <zona>"
  m=$(match_zone "$zone") || die "Zona desconocida: '$zone'"
  zone=$m
  cs=$(zone_coordinator "$zone") || die "No hay un equipo (coordinador) en '$zone'."
  while IFS= read -r s; do
    [ "$(state_get "$s" PARENT)" = "$cs" ] || continue
    tmx_kill "$s"; state_remove "$s"; bus_event stopped operator "$s" "swarm stop"; (( n++ ))
  done < <(prama_sessions)
  tmx_kill "$cs"; state_remove "$cs"; bus_event stopped operator "$cs" "swarm stop"
  tmx_kill "$(cockpit_session "$zone")" 2>/dev/null || true
  ok "Equipo de '$zone' cerrado: $cs y $n ejecutor(es)."
}

# ── Cockpit ─────────────────────────────────────────────────────────────────
cockpit_session() { slugify "${PRAMA_SESSION_PREFIX}-cockpit-$1"; }

# Pane command that shows a live agent session inside the cockpit (nested client on the same
# server). Re-attaches while the session exists; exits when it is stopped.
cockpit_view_cmd() {
  local target=$1 q_sock q_conf q_t
  printf -v q_sock '%q' "$PRAMA_TMUX_SOCKET"
  printf -v q_conf '%q' "$PRAMA_TMUX_CONF"
  printf -v q_t '%q' "=$target"
  printf 'while tmux -L %s has-session -t %s 2>/dev/null; do env -u TMUX tmux -L %s -f %s attach-session -t %s || sleep 1; done' \
    "$q_sock" "$q_t" "$q_sock" "$q_conf" "$q_t"
}

# Members of a zone's team view, coordinator(s) first, at most PRAMA_COCKPIT_MAX.
_cockpit_members() {
  local zone=$1 s z max=${PRAMA_COCKPIT_MAX:-6} n=0
  while IFS='|' read -r s _ z; do
    [ "$z" = "$zone" ] || continue
    (( n++ < max )) || break
    printf '%s\n' "$s"
  done < <(prama_team_order)
}

# cockpit_ensure <zone> [focus] → prints the cockpit session name. The layout follows the team:
# when agents join or leave, the next call rebuilds it (the panes are only viewers, the agents
# are untouched).
cockpit_ensure() {
  local zone=$1 focus=${2:-} cs dir s sig p first='' last='' pane
  local -a members=()
  dir=$(zone_dir "$zone") || dir=$HOME
  mapfile -t members < <(_cockpit_members "$zone")
  (( ${#members[@]} )) || { warn "No hay agentes en '$zone'. Lanza un equipo: prama-agent swarm $zone"; return 1; }
  cs=$(cockpit_session "$zone")
  valid_session_name "$cs" || return 1
  sig="${members[*]}"
  ensure_tmux_conf
  if tmx_has "$cs" && [ "$(tmx show-options -qv -t "=$cs" @prama_team 2>/dev/null)" != "$sig" ]; then
    tmx kill-session -t "=$cs" 2>/dev/null   # viewers only
  fi
  if ! tmx_has "$cs"; then
    local env_args=(-e "PATH=$PATH" -e "PRAMA_TMUX_SOCKET=$PRAMA_TMUX_SOCKET" -e "PRAMA_TMUX_CONF=$PRAMA_TMUX_CONF"
                    -e "PRAMA_STATE_HOME=$PRAMA_STATE_HOME" -e "PRAMA_BUS_DIR=$PRAMA_BUS_DIR")
    refresh_dimensions
    for s in "${members[@]}"; do
      if [ -z "$first" ]; then
        pane=$(tmx new-session -d -P -F '#{pane_id}' -s "$cs" -x "${COLS:-160}" -y "${ROWS:-45}" -c "$dir" \
                 "${env_args[@]}" "$(cockpit_view_cmd "$s")") || return 1
        first=$pane
      else
        pane=$(tmx split-window -P -F '#{pane_id}' -t "$last" -c "$dir" "${env_args[@]}" "$(cockpit_view_cmd "$s")") || break
        tmx select-layout -t "$first" tiled >/dev/null 2>&1   # keeps room for the next split
      fi
      tmx select-pane -t "$pane" -T "$(role_badge "$(session_role "$s")") · $s · $(state_get "$s" AGENT)" 2>/dev/null
      tmx set-option -p -t "$pane" @prama_view "$s" 2>/dev/null
      last=$pane
    done
    local watch_cmd
    printf -v watch_cmd '%q ' "$SELF_PATH" bus watch
    pane=$(tmx split-window -P -F '#{pane_id}' -t "$last" -c "$dir" "${env_args[@]}" "${watch_cmd% }") \
      && tmx select-pane -t "$pane" -T "☍ BUS · eventos en vivo" 2>/dev/null
    # Coordinator large on the left, the rest stacked on the right.
    tmx set-option -w -t "$cs" main-pane-width 58% 2>/dev/null
    tmx select-layout -t "$first" main-vertical >/dev/null 2>&1
    tmx set-option -t "=$cs" @prama_team "$sig" 2>/dev/null
    tmx set-option -t "=$cs" @prama_zone "$zone" 2>/dev/null
  fi
  if [ -n "$focus" ]; then
    p=$(tmx list-panes -t "=$cs" -F '#{pane_id} #{@prama_view}' 2>/dev/null | awk -v s="$focus" '$2 == s { print $1; exit }')
    [ -n "$p" ] && tmx select-pane -t "$p" 2>/dev/null
  fi
  printf '%s' "$cs"
}

subcmd_cockpit() {
  local arg='' focus='' attach=1 zone='' m
  while (( $# )); do
    case "$1" in
      --no-attach) attach=0; shift ;;
      --focus)     focus=${2:-}; shift 2 ;;
      *)           arg=$1; shift ;;
    esac
  done
  if [ -n "$arg" ] && valid_session_name "$arg" && tmx_has "$arg" && [ -n "$(state_get "$arg" ZONE)" ]; then
    zone=$(state_get "$arg" ZONE); focus=${focus:-$arg}
  elif [ -n "$arg" ]; then
    m=$(match_zone "$arg") || die "Zona o sesión desconocida: '$arg'"; zone=$m
  else
    # No argument: the first zone that has agents.
    zone=$(prama_team_order | head -n 1 | cut -d'|' -f3)
    [ -n "$zone" ] || die "No hay agentes activos. Lanza un equipo: prama-agent swarm <zona>"
  fi
  local cs
  cs=$(cockpit_ensure "$zone" "$focus") || exit 1
  if (( ! attach )) || [ ! -t 0 ] || [ ! -t 1 ]; then
    info_msg "Cockpit listo: prama-agent attach $cs"
    return 0
  fi
  type restore_locale >/dev/null 2>&1 && restore_locale
  (( ${IN_TUI:-0} )) && declare -F tui_leave_screen >/dev/null && tui_leave_screen
  tmx_attach "$cs"
  (( ${IN_TUI:-0} )) && declare -F tui_enter_screen >/dev/null && tui_enter_screen
  return 0
}

# ── Navigation from inside tmux (key bindings and status bar buttons) ──────
# nav_main <action> <client> [current_session]
nav_main() {
  local action=${1:-pick} client=${2:-} cur=${3:-}
  case "$action" in
    pick)    _nav_pick "$client" ;;
    cockpit) _nav_cockpit "$client" "$cur" ;;
    next)    _nav_cycle "$client" "$cur" 1 ;;
    prev)    _nav_cycle "$client" "$cur" -1 ;;
    click)   # status bar buttons; the range comes from #{mouse_status_range}
      case "${4:-}" in
        agents)  _nav_popup "$client" ;;
        cockpit) _nav_cockpit "$client" "$cur" ;;
        *)       tmx detach-client -c "$client" 2>/dev/null ;;
      esac ;;
  esac
}

_nav_popup() {
  local nav
  printf -v nav 'env PRAMA_TMUX_SOCKET=%q PRAMA_STATE_HOME=%q %q --internal-nav pick %q' \
    "$PRAMA_TMUX_SOCKET" "$PRAMA_STATE_HOME" "$SELF_PATH" "$1"
  tmx display-popup -c "$1" -E -w 92% -h 75% "$nav" 2>/dev/null
}

_nav_switch() { tmx switch-client -c "$1" -t "=$2" 2>/dev/null; }

# Inside a cockpit, the "current" agent is the one in the focused pane.
_nav_current_agent() {
  local cur=$1 v
  if [[ "$cur" == "${PRAMA_SESSION_PREFIX}-cockpit-"* ]]; then
    v=$(tmx display-message -p -t "=$cur:" '#{@prama_view}' 2>/dev/null)
    [ -n "$v" ] && cur=$v
  fi
  printf '%s' "$cur"
}

_nav_cockpit() {
  local client=$1 cur=$2 zone cs
  if [[ "$cur" == "${PRAMA_SESSION_PREFIX}-cockpit-"* ]]; then
    # Toggle: from the cockpit back to the agent that has the focus.
    _nav_switch "$client" "$(_nav_current_agent "$cur")" || tmx switch-client -c "$client" -l 2>/dev/null
    return 0
  fi
  zone=$(state_get "$cur" ZONE)
  [ -n "$zone" ] || { tmx display-message -c "$client" "Esta sesión no pertenece a una zona" 2>/dev/null; return 0; }
  cs=$(cockpit_ensure "$zone" "$cur" 2>/dev/null) || { tmx display-message -c "$client" "Sin agentes en $zone" 2>/dev/null; return 0; }
  _nav_switch "$client" "$cs"
}

_nav_cycle() {
  local client=$1 cur dir=$3 i n
  cur=$(_nav_current_agent "$2")
  local -a list=()
  mapfile -t list < <(prama_team_order | cut -d'|' -f1)
  n=${#list[@]}
  (( n )) || return 0
  for (( i = 0; i < n; i++ )); do [ "${list[i]}" = "$cur" ] && break; done
  (( i >= n )) && i=-1
  _nav_switch "$client" "${list[$(( (i + dir + n) % n ))]}"
}

# Agent picker shown in a tmux popup: teams, state, model and quota at a glance.
_nav_pick() {
  local client=$1 s depth zone st role agent model q line choice target='' i
  local -a rows=() targets=() zones_seen=()
  local -A zseen=()
  while IFS='|' read -r s depth zone; do
    st=$(detect_session_state "$s")
    role=$(session_role "$s") agent=$(state_get "$s" AGENT)
    model=$(health_get "$s" MODEL "$(state_get "$s" MODEL)")
    q=$(quota_label "$s")
    if [ -z "${zseen[$zone]:-}" ]; then zseen[$zone]=1; zones_seen+=("$zone"); fi
    printf -v line '%-10s %s%-34s %-8s %-11s %s' "$zone" "$( (( depth )) && printf '└ ' || printf '')" "$s" "$st" "$agent·${role:0:5}" "${model:-—}${q:+  ◔ $q}"
    rows+=("$line"); targets+=("$s")
  done < <(prama_team_order)
  for zone in ${zones_seen[@]+"${zones_seen[@]}"}; do
    rows+=("▦ cockpit  $zone"); targets+=("@cockpit:$zone")
  done
  rows+=("◂ menú de prama"); targets+=("@menu")
  if command -v fzf >/dev/null 2>&1; then
    choice=$(printf '%s\n' "${rows[@]}" | fzf --no-sort --layout=reverse --prompt='agente › ' \
      --header='↵ ir · Esc cerrar' --info=hidden) || return 0
    for (( i = 0; i < ${#rows[@]}; i++ )); do [ "${rows[i]}" = "$choice" ] && { target=${targets[i]}; break; }; done
  else
    for (( i = 0; i < ${#rows[@]}; i++ )); do printf '%2d  %s\n' "$(( i + 1 ))" "${rows[i]}"; done
    printf '\nNúmero (Enter cierra): '
    IFS= read -r choice || return 0
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#rows[@]} )) || return 0
    target=${targets[$(( choice - 1 ))]}
  fi
  case "${target:-}" in
    '')          return 0 ;;
    @menu)       tmx detach-client -c "$client" 2>/dev/null ;;
    @cockpit:*)  local cs; cs=$(cockpit_ensure "${target#@cockpit:}" 2>/dev/null) && _nav_switch "$client" "$cs" ;;
    *)           _nav_switch "$client" "$target" ;;
  esac
}
