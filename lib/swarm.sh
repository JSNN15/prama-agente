#!/usr/bin/env bash
# lib/swarm.sh — Teams (coordinator + workers), the live team cockpit and in-tmux navigation
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
#
# Public API:
#   subcmd_swarm <zone> [--team T] [opts] | list | stop <zone|coordinator> [--team T|--all] | help
#   subcmd_cockpit [zone|session] [--team T] [--no-attach]   live split view of a team
#   cockpit_ensure <zone> [focus_session] [coordinator]      (re)builds the cockpit, prints its name
#   nav_main <pick|cockpit|next|prev|fit|click> <client> [session] [range]   tmux bindings and hooks
#
# A team is not a separate object: it is a coordinator plus the sessions whose PARENT it is, with
# a name unique in its zone (TEAM; see the team helpers in core.sh). A zone can hold several teams
# (architecture, security, docs…). Everything stays a normal prama session, visible to the bus,
# the fleet API, the watchdog and Telegram.

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

# First coordinator of a zone, if any (callers that need a specific team use find_team).
zone_coordinator() { local c; c=$(zone_teams "$1" | head -n 1); [ -n "$c" ] && printf '%s' "$c"; }

# _swarm_teams_hint <zone> → "arquitectura, seguridad" (team names of the zone)
_swarm_teams_hint() {
  local c out=''
  while IFS= read -r c; do out+="${out:+, }$(team_name "$c")"; done < <(zone_teams "$1")
  printf '%s' "$out"
}

_swarm_usage() {
  cat <<EOF
Uso: prama-agent swarm <zona> [--team <nombre>] [opciones]   coordinador + agentes ejecutores, en un paso
       --team <nombre>           equipo de la zona (p. ej. arquitectura, seguridad, docs). Si existe, los
                                 ejecutores se suman a él; si no, se crea con su propio coordinador.
                                 Sin --team: el equipo "$PRAMA_DEFAULT_TEAM" (o pide elegir si la zona ya tiene equipos)
       --coord <agente>          agente coordinador (por defecto: claude)
       --workers <spec>          ejecutores, p. ej. agy:3  o  agy:2,claude:1  (def. ${PRAMA_SWARM_WORKERS:-agy:2})
       --model <m>               modelo del coordinador
       --worker-model <m>        modelo de los ejecutores
       --task "<objetivo>"       objetivo inicial para el coordinador
       --no-open                 no abrir el cockpit al terminar
     prama-agent swarm list [--json]                         equipos activos (también: prama-agent teams)
     prama-agent swarm stop <zona> [--team <nombre>|--all]   cierra un equipo (coordinador y sus agentes)
     prama-agent swarm stop <sesión del coordinador>

Navegación dentro de tmux: ${PRAMA_NAV_KEY:-M-a} agentes · ${PRAMA_COCKPIT_KEY:-M-c} cockpit · ${PRAMA_MENU_KEY:-M-m} menú.
EOF
}

subcmd_swarm() {
  case "${1:-}" in
    ''|help|-h|--help) _swarm_usage ;;
    list|ls)           shift; _swarm_list "$@" ;;
    stop|down)         shift; _swarm_stop "$@" ;;
    start|up)          shift; _swarm_start "$@" ;;
    *)                 _swarm_start "$@" ;;
  esac
}

# Teams: one line per coordinator, or JSON.
_swarm_list() {
  local json=0 c sep='' zone team n m members any=0 o
  [ "${1:-}" = --json ] && json=1
  (( json )) && printf '['
  while IFS='|' read -r c _ zone; do
    [ "$(session_role "$c")" = coordinator ] || continue
    team=$(team_name "$c") n=0 members='' o=$(state_get "$c" OBJECTIVE)
    while IFS= read -r m; do
      [ "$(state_get "$m" PARENT)" = "$c" ] || continue
      (( n++ )); members+="${members:+,}\"$(json_escape "$m")\""
    done < <(prama_sessions)
    if (( json )); then
      printf '%s{"zone":"%s","team":"%s","coordinator":"%s","members":[%s],"objective":"%s"}' "$sep" \
        "$(json_escape "$zone")" "$(json_escape "$team")" "$(json_escape "$c")" "$members" "$(json_escape "$o")"
      sep=','
    else
      printf ' ❖ %-26s %-36s %d agente(s)%s\n' "$(team_label "$c")" "$c" "$n" "${o:+ · ${o:0:60}}"
    fi
    any=1
  done < <(prama_team_order)
  if (( json )); then printf ']\n'
  elif (( ! any )); then info_msg "No hay equipos activos. Crea uno: prama-agent swarm <zona> --team <nombre>"
  fi
  return 0
}

_swarm_start() {
  local zone='' team='' coord_a=claude spec=${PRAMA_SWARM_WORKERS:-agy:2} cmodel='' wmodel='' task='' open=1 m
  while (( $# )); do
    case "$1" in
      --team|-T)         team=${2:?--team requiere un nombre}; shift 2
                         valid_team_name "$team" || die "Nombre de equipo inválido: '$team' (minúsculas, números y -, máx. 20)" ;;
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

  local live cs='' need=${#SW_AGENTS[@]}
  live=$(prama_sessions | grep -c . || true)
  if [ -n "${PRAMA_SESSION:-}" ]; then
    # Called by an agent (a coordinator growing its own team): same guard rails as `fleet spawn`.
    local own; own=$(state_get "$PRAMA_SESSION" ZONE)
    [ "${PRAMA_FLEET_SCOPE:-zone}" = all ] || [ -z "$own" ] || [ "$own" = "$zone" ] \
      || die "Solo puedes formar equipos en tu zona ($own)."
    cs=$(session_team "$PRAMA_SESSION") \
      || die "Un agente no puede crear un coordinador; pide al operador: prama-agent swarm $zone --team <nombre>"
    [ -z "$team" ] || [ "$team" = "$(team_name "$cs")" ] || die "Solo puedes sumar agentes a tu propio equipo ($(team_name "$cs"))."
    team=$(team_name "$cs")
    open=0
  elif [ -n "$team" ]; then
    cs=$(find_team "$zone" "$team") || cs=''
  else
    # No --team: the zone's principal team when it has none yet; never join a team silently.
    local existing; existing=$(_swarm_teams_hint "$zone")
    if [ -n "$existing" ]; then
      die "La zona '$zone' ya tiene equipo(s): $existing. Para sumarle agentes: --team <nombre>; para uno nuevo: --team <otro nombre> (p. ej. seguridad, docs)."
    fi
    team=$PRAMA_DEFAULT_TEAM
  fi
  [ -n "$cs" ] || need=$(( need + 1 ))
  (( live + need <= ${PRAMA_FLEET_MAX:-8} )) \
    || die "El equipo necesita $need sesiones y hay $live de ${PRAMA_FLEET_MAX:-8} (PRAMA_FLEET_MAX)."

  # Session names: the principal team keeps the classic names; other teams carry their name
  # (prama-backend-seguridad-coord, prama-backend-seguridad-agy, …-agy-2).
  local base=''
  [ "$team" = "$PRAMA_DEFAULT_TEAM" ] || base=$(slugify "${PRAMA_SESSION_PREFIX}-$zone-$team")
  if [ -z "$cs" ]; then
    cs=$(PRAMA_TEAM=$team "$SELF_PATH" "$coord_a" "$zone" --role coordinator --bg --porcelain ${base:+--name "$base-coord"} \
           ${cmodel:+--model "$cmodel"}) || die "No se pudo lanzar el coordinador."
    [ -n "$task" ] && state_set "$cs" OBJECTIVE="$task"
    ok "Equipo «$team» en '$zone' · coordinador: $cs ($coord_a)"
  else
    info_msg "Equipo «$team» en '$zone' ($cs): los ejecutores se suman a él."
  fi

  local a w members=()
  for a in "${SW_AGENTS[@]}"; do
    w=$(PRAMA_PARENT=$cs "$SELF_PATH" "$a" "$zone" --role executor --bg --porcelain --parallel \
          ${base:+--name "$base-$a"} ${wmodel:+--model "$wmodel"}) \
      || { warn "No se pudo lanzar un ejecutor $a."; continue; }
    members+=("$w ($a)")
    ok "Ejecutor: $w ($a)"
  done

  # The coordinator learns its team (and the objective) as soon as it is ready: the watchdog
  # delivers queued messages to an agent that has been READY for two ticks.
  local brief="[PRAMA] Tu equipo «$team» en '$zone': ${members[*]:-(sin ejecutores)}. Delega con 'prama-agent bus assign <sesión> \"<tarea>\"', revisa con 'prama-agent fleet status' y suma o quita agentes con 'prama-agent fleet spawn|kill'."
  [ -n "$task" ] && brief+=" OBJETIVO: $task"
  queue_push "$cs" "$brief"
  bus_event queued "${PRAMA_SESSION:-operator}" "$cs" "equipo $team: ${members[*]:-}${task:+ · objetivo: $task}"
  watchdog_ensure || true
  declare -F telegram_notify >/dev/null && telegram_notify "🤝 Equipo «$team» en '$zone': $cs + ${#members[@]} ejecutor(es)" >/dev/null 2>&1

  if (( open )) && [ -t 0 ] && [ -t 1 ]; then
    subcmd_cockpit "$cs"
  else
    info_msg "Cockpit del equipo: prama-agent cockpit $zone --team $team"
  fi
}

# _swarm_stop <zone> [--team T | --all]  |  _swarm_stop <coordinator session>
_swarm_stop() {
  local arg=${1:-} team='' all=0 m zone c
  [ -n "$arg" ] || die "Uso: prama-agent swarm stop <zona> [--team <nombre>|--all] | <sesión del coordinador>"
  shift
  while (( $# )); do
    case "$1" in
      --team|-T) team=${2:?--team requiere un nombre}; shift 2 ;;
      --all)     all=1; shift ;;
      *)         die "Argumento sobrante: '$1'" ;;
    esac
  done
  local -a coords=()
  if valid_session_name "$arg" && tmx_has "$arg" && [ "$(session_role "$arg")" = coordinator ]; then
    coords=("$arg")
  else
    m=$(match_zone "$arg") || die "Zona o coordinador desconocido: '$arg'"
    zone=$m
    if [ -n "$team" ]; then
      c=$(find_team "$zone" "$team") || die "No hay un equipo «$team» en '$zone' (equipos: $(_swarm_teams_hint "$zone"))."
      coords=("$c")
    else
      mapfile -t coords < <(zone_teams "$zone")
      (( ${#coords[@]} )) || die "No hay equipos en '$zone'."
      (( ${#coords[@]} == 1 || all )) \
        || die "La zona '$zone' tiene ${#coords[@]} equipos ($(_swarm_teams_hint "$zone")): indica --team <nombre> o --all."
    fi
  fi
  for c in "${coords[@]}"; do _swarm_stop_team "$c"; done
}

_swarm_stop_team() {
  local cs=$1 s n=0 label cockpit
  label=$(team_label "$cs") cockpit=$(cockpit_session "$(state_get "$cs" ZONE)" "$cs")
  while IFS= read -r s; do
    [ "$(state_get "$s" PARENT)" = "$cs" ] || continue
    tmx_kill "$s"; state_remove "$s"; bus_event stopped "${PRAMA_SESSION:-operator}" "$s" "swarm stop"; (( n++ ))
  done < <(prama_sessions)
  tmx_kill "$cs"; state_remove "$cs"; bus_event stopped "${PRAMA_SESSION:-operator}" "$cs" "swarm stop"
  tmx_kill "$cockpit" 2>/dev/null || true
  ok "Equipo «$label» cerrado: $cs y $n ejecutor(es)."
}

# ── Cockpit ─────────────────────────────────────────────────────────────────
# cockpit_session <zone> [coordinator] → prama-cockpit-<zone> (the zone, or its principal team) or
# prama-cockpit-<zone>-<team>.
cockpit_session() {
  local team=''
  [ -n "${2:-}" ] && team=$(team_name "$2")
  if [ -n "$team" ] && [ "$team" != "$PRAMA_DEFAULT_TEAM" ]; then
    slugify "${PRAMA_SESSION_PREFIX}-cockpit-$1-$team"
  else
    slugify "${PRAMA_SESSION_PREFIX}-cockpit-$1"
  fi
}

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

# Members shown in a cockpit, coordinator first, at most PRAMA_COCKPIT_MAX: a team (its
# coordinator and the agents it launched) or, without a coordinator, every agent of the zone.
_cockpit_members() {
  local zone=$1 coord=${2:-} s z max=${PRAMA_COCKPIT_MAX:-6} n=0
  while IFS='|' read -r s _ z; do
    [ "$z" = "$zone" ] || continue
    if [ -n "$coord" ] && [ "$s" != "$coord" ] && [ "$(state_get "$s" PARENT)" != "$coord" ]; then continue; fi
    (( n++ < max )) || break
    printf '%s\n' "$s"
  done < <(prama_team_order)
}

# cockpit_ensure <zone> [focus] [coordinator] → prints the cockpit session name. The layout follows the team:
# when agents join or leave, the next call rebuilds it (the panes are only viewers, the agents
# are untouched).
cockpit_ensure() {
  local zone=$1 focus=${2:-} coord=${3:-} cs dir s sig p first='' last='' pane
  local -a members=()
  dir=$(zone_dir "$zone") || dir=$HOME
  mapfile -t members < <(_cockpit_members "$zone" "$coord")
  (( ${#members[@]} )) || { warn "No hay agentes en '$zone'. Lanza un equipo: prama-agent swarm $zone --team <nombre>"; return 1; }
  cs=$(cockpit_session "$zone" "$coord")
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
        # Build at a fixed size: with window-size "latest" (tmux 3.2) a client-less window can shrink
        # to the last active client (a small nested viewer) and the next split would not fit.
        tmx set-option -w -t "$pane" window-size manual 2>/dev/null
        tmx resize-window -t "$pane" -x "${COLS:-160}" -y "${ROWS:-45}" 2>/dev/null
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
    tmx set-option -wu -t "$first" window-size 2>/dev/null   # follow the attached client again
    tmx set-option -t "=$cs" @prama_team "$sig" 2>/dev/null
    tmx set-option -t "=$cs" @prama_zone "$zone" 2>/dev/null
  fi
  if [ -n "$focus" ]; then
    p=$(tmx list-panes -t "=$cs" -F '#{pane_id} #{@prama_view}' 2>/dev/null | awk -v s="$focus" '$2 == s { print $1; exit }')
    [ -n "$p" ] && tmx select-pane -t "$p" 2>/dev/null
  fi
  printf '%s' "$cs"
}

# cockpit_scope <arg> [team] → "zone|coordinator" (coordinator empty for a zone-wide view)
cockpit_scope() {
  local arg=${1:-} team=${2:-} zone='' coord='' m n
  if [ -n "$arg" ] && valid_session_name "$arg" && tmx_has "$arg" && [ -n "$(state_get "$arg" ZONE)" ]; then
    zone=$(state_get "$arg" ZONE); coord=$(session_team "$arg") || coord=''
  elif [ -n "$arg" ]; then
    m=$(match_zone "$arg") || { warn "Zona o sesión desconocida: '$arg'"; return 1; }
    zone=$m
    if [ -n "$team" ]; then
      coord=$(find_team "$zone" "$team") || { warn "No hay un equipo «$team» en '$zone' (equipos: $(_swarm_teams_hint "$zone"))."; return 1; }
    else
      n=$(zone_teams "$zone" | grep -c . || true)
      if (( n == 1 )); then coord=$(zone_teams "$zone")
      elif (( n > 1 )); then warn "La zona '$zone' tiene $n equipos ($(_swarm_teams_hint "$zone")): indica --team <nombre>."; return 1
      fi
    fi
  else
    # No argument: the first team (or the first zone with agents).
    IFS='|' read -r m _ zone < <(prama_team_order | head -n 1)
    [ -n "$zone" ] || { warn "No hay agentes activos. Lanza un equipo: prama-agent swarm <zona> --team <nombre>"; return 1; }
    coord=$(session_team "$m") || coord=''
  fi
  printf '%s|%s' "$zone" "$coord"
}

subcmd_cockpit() {
  local arg='' focus='' attach=1 team='' scope zone coord
  while (( $# )); do
    case "$1" in
      --no-attach) attach=0; shift ;;
      --focus)     focus=${2:-}; shift 2 ;;
      --team|-T)   team=${2:-}; shift 2 ;;
      *)           arg=$1; shift ;;
    esac
  done
  scope=$(cockpit_scope "$arg" "$team") || exit 1
  zone=${scope%%|*} coord=${scope#*|}
  if [ -z "$focus" ] && [ -n "$arg" ] && valid_session_name "$arg" && tmx_has "$arg"; then focus=$arg; fi
  local cs
  cs=$(cockpit_ensure "$zone" "${focus:-$coord}" "$coord") || exit 1
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
    fit)     _nav_fit "$client" "$cur" ;;
    click)   # status bar buttons; the range comes from #{mouse_status_range}
      case "${4:-}" in
        agents)  _nav_popup "$client" ;;
        cockpit) _nav_cockpit "$client" "$cur" ;;
        next)    _nav_cycle "$client" "$cur" 1 ;;
        prev)    _nav_cycle "$client" "$cur" -1 ;;
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
  local coord; coord=$(session_team "$cur") || coord=''
  cs=$(cockpit_ensure "$zone" "$cur" "$coord" 2>/dev/null) || { tmx display-message -c "$client" "Sin agentes en $zone" 2>/dev/null; return 0; }
  _nav_switch "$client" "$cs"
}

_nav_is_cockpit() { [[ "$1" == "${PRAMA_SESSION_PREFIX}-cockpit-"* ]]; }

# _nav_client <client> → "session|width" of a client. Read from list-clients: tmux hooks also fire
# for the nested viewer clients inside cockpit panes, and display-message -c does not resolve
# the client's own width from run-shell.
_nav_client() {
  tmx list-clients -F '#{client_name}|#{session_name}|#{client_width}' 2>/dev/null \
    | awk -F'|' -v c="$1" '$1 == c { print $2 "|" $3; exit }'
}

# Cockpit layout for the client's width (tmux hooks: attach, resize, session change). On a phone
# the focused pane is zoomed, one agent at a time; a wide client gets the split view back, but
# only when prama zoomed it (a zoom the operator chose with prefix z is left alone).
_nav_fit() {
  local client=$1 cs=$2 t info w
  _nav_is_cockpit "$cs" || return 0
  info=$(_nav_client "$client")
  [ "${info%|*}" = "$cs" ] || return 0      # a viewer pane's client, or one that already left
  w=${info##*|}
  [[ "$w" =~ ^[0-9]+$ ]] || return 0
  t="=$cs:"
  # Zoom is a toggle and several hooks can fire at once (attach + resize): test and toggle in
  # one tmux command, which the server runs atomically.
  if (( w < ${PRAMA_COMPACT_COLS:-100} )); then
    tmx if-shell -F -t "$t" '#{window_zoomed_flag}' '' \
      "resize-pane -Z -t '$t' ; set-option -w -t '$t' @prama_autozoom 1" 2>/dev/null
  else
    tmx if-shell -F -t "$t" '#{&&:#{window_zoomed_flag},#{==:#{@prama_autozoom},1}}' \
      "resize-pane -Z -t '$t' ; set-option -wu -t '$t' @prama_autozoom" '' 2>/dev/null
  fi
  return 0
}

# Inside a cockpit, next / previous moves the focus between its panes (agents and the bus);
# on a phone the pane stays zoomed, so ◀ ▶ page through the team one agent at a time.
_nav_cycle_panes() {
  local client=$1 cs=$2 dir=$3 i n
  local -a panes=()
  mapfile -t panes < <(tmx list-panes -t "=$cs:" -F '#{pane_active} #{pane_id}' 2>/dev/null)
  n=${#panes[@]}
  (( n > 1 )) || return 0
  for (( i = 0; i < n; i++ )); do [[ "${panes[i]}" == 1\ * ]] && break; done
  (( i >= n )) && i=0
  local next=${panes[$(( (i + dir + n) % n ))]#* }
  tmx select-pane -Z -t "$next" 2>/dev/null
  _nav_fit "$client" "$cs"
}

_nav_cycle() {
  local client=$1 cur dir=$3 i n
  if _nav_is_cockpit "$2"; then _nav_cycle_panes "$client" "$2" "$dir"; return 0; fi
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
  local c n
  for zone in ${zones_seen[@]+"${zones_seen[@]}"}; do
    n=0
    while IFS= read -r c; do
      rows+=("▦ cockpit  $(team_label "$c")"); targets+=("@team:$c"); (( n++ ))
    done < <(zone_teams "$zone")
    (( n )) || { rows+=("▦ cockpit  $zone"); targets+=("@cockpit:$zone"); }
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
    @team:*)     local cs; c=${target#@team:}
                 cs=$(cockpit_ensure "$(state_get "$c" ZONE)" "$c" "$c" 2>/dev/null) && _nav_switch "$client" "$cs" ;;
    *)           _nav_switch "$client" "$target" ;;
  esac
}
