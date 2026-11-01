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
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 12 )) || die "$(_t "Invalid count in '%s' (1-12)" "$part")"
    is_in "$a" "${AGENTS[@]}" || die "$(_t "Agent not enabled: '%s' (%s)" "$a" "${AGENTS[*]}")"
    agent_installed "$a" || die "$(_t "Agent '%s' is not installed." "$a")"
    for (( i = 0; i < n; i++ )); do SW_AGENTS+=("$a"); done
  done
  (( ${#SW_AGENTS[@]} )) || die "$(_t 'Give at least one executor agent (e.g. --workers agy:2).')"
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
  case $PRAMA_UI_LANG in
    es) _swarm_usage_es ;;
    *)  _swarm_usage_en ;;
  esac
}

_swarm_usage_en() {
  cat <<EOF
Usage: prama-agent swarm <zone> [--team <name>] [options]   coordinator + executor agents, in one step
       --team <name>             a team of the zone (e.g. architecture, security, docs). If it exists, the
                                 executors join it; if not, it is created with its own coordinator.
                                 Without --team: the "$PRAMA_DEFAULT_TEAM" team (or asks to choose if the zone already has teams)
       --coord <agent>           coordinator agent (default: claude)
       --workers <spec>          executors, e.g. agy:3  or  agy:2,claude:1  (def. ${PRAMA_SWARM_WORKERS:-agy:2})
       --model <m>               coordinator model
       --worker-model <m>        executors' model
       --task "<objective>"      initial objective for the coordinator
       --no-open                 do not open the cockpit when done
       --isolate | --shared      a git worktree and branch per executor (default for a new team in a git
                                 zone: PRAMA_SWARM_ISOLATE=1) or everyone in the zone folder
     prama-agent swarm list [--json]                         active teams (also: prama-agent teams)
     prama-agent swarm stop <zone> [--team <name>|--all]     closes a team (coordinator and its agents)
     prama-agent swarm stop <coordinator session>

Navigation inside tmux: ${PRAMA_NAV_KEY:-M-a} agents · ${PRAMA_COCKPIT_KEY:-M-c} cockpit · ${PRAMA_MENU_KEY:-M-m} menu.
EOF
}

_swarm_usage_es() {
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
       --isolate | --shared      un git worktree y una rama por ejecutor (por defecto en un equipo nuevo de
                                 una zona git: PRAMA_SWARM_ISOLATE=1) o todos en la carpeta de la zona
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
  local json=0 c sep='' zone team n m members any=0 o cnt
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
      _tv cnt '%d agent(s)' "$n"
      printf ' ❖ %-26s %-36s %s%s\n' "$(team_label "$c")" "$c" "$cnt" "${o:+ · ${o:0:60}}"
    fi
    any=1
  done < <(prama_team_order)
  if (( json )); then printf ']\n'
  elif (( ! any )); then info_msg "$(_t 'No active teams. Create one: prama-agent swarm <zone> --team <name>')"
  fi
  return 0
}

_swarm_start() {
  local zone='' team='' coord_a=claude spec=${PRAMA_SWARM_WORKERS:-agy:2} cmodel='' wmodel='' task='' open=1 m
  local isolate=''   # '' = the team's setting (new team: PRAMA_SWARM_ISOLATE), 1 = worktrees, 0 = shared
  while (( $# )); do
    case "$1" in
      --team|-T)         team=${2:?$(_t '--team requires a name')}; shift 2
                         valid_team_name "$team" || die "$(_t "Invalid team name: '%s' (lowercase letters, digits and -, max. 20)" "$team")" ;;
      --coord|-c)        coord_a=${2:?$(_t '--coord requires an agent')}; shift 2 ;;
      --workers|-w)      spec=${2:?$(_t '--workers requires agent:count')}; shift 2 ;;
      --model|-m)        cmodel=${2:?}; valid_model "$cmodel" || die "$(_t "Invalid model: '%s'" "$cmodel")"; shift 2 ;;
      --worker-model)    wmodel=${2:?}; valid_model "$wmodel" || die "$(_t "Invalid model: '%s'" "$wmodel")"; shift 2 ;;
      --task|-t)         task=${2:?$(_t '--task requires a text')}; shift 2 ;;
      --no-open)         open=0; shift ;;
      --isolate|--worktrees) isolate=1; shift ;;
      --shared)          isolate=0; shift ;;
      --open)            open=1; shift ;;
      -*)                die "$(_t 'Unknown option: %s (prama-agent swarm help)' "$1")" ;;
      *)
        [ -z "$zone" ] || die "$(_t "Unexpected argument: '%s'" "$1")"
        m=$(match_zone "$1") || die "$(_t "Unknown zone: '%s'. Zones: %s" "$1" "${ZONES[*]}")"
        zone=$m; shift ;;
    esac
  done
  [ -n "$zone" ] || { _swarm_usage >&2; die "$(_t 'Missing the zone.')"; }
  is_in "$coord_a" "${AGENTS[@]}" && agent_installed "$coord_a" || die "$(_t "Coordinator not available: '%s'" "$coord_a")"
  _swarm_spec_parse "$spec"

  local live cs='' need=${#SW_AGENTS[@]}
  live=$(prama_sessions | grep -c . || true)
  if [ -n "${PRAMA_SESSION:-}" ]; then
    # Called by an agent (a coordinator growing its own team): same guard rails as `fleet spawn`.
    local own; own=$(state_get "$PRAMA_SESSION" ZONE)
    [ "${PRAMA_FLEET_SCOPE:-zone}" = all ] || [ -z "$own" ] || [ "$own" = "$zone" ] \
      || die "$(_t 'You can only form teams in your own zone (%s).' "$own")"
    cs=$(session_team "$PRAMA_SESSION") \
      || die "$(_t 'An agent cannot create a coordinator; ask the operator: prama-agent swarm %s --team <name>' "$zone")"
    [ -z "$team" ] || [ "$team" = "$(team_name "$cs")" ] || die "$(_t 'You can only add agents to your own team (%s).' "$(team_name "$cs")")"
    team=$(team_name "$cs")
    open=0
  elif [ -n "$team" ]; then
    cs=$(find_team "$zone" "$team") || cs=''
  else
    # No --team: the zone's principal team when it has none yet; never join a team silently.
    local existing; existing=$(_swarm_teams_hint "$zone")
    if [ -n "$existing" ]; then
      die "$(_t "Zone '%s' already has team(s): %s. To add agents to one: --team <name>; for a new one: --team <another name> (e.g. security, docs)." "$zone" "$existing")"
    fi
    team=$PRAMA_DEFAULT_TEAM
  fi
  [ -n "$cs" ] || need=$(( need + 1 ))
  (( live + need <= ${PRAMA_FLEET_MAX:-8} )) \
    || die "$(_t 'The team needs %s sessions and %s of %s are in use (PRAMA_FLEET_MAX).' "$need" "$live" "${PRAMA_FLEET_MAX:-8}")"

  # Session names: the principal team keeps the classic names; other teams carry their name
  # (prama-backend-seguridad-coord, prama-backend-seguridad-agy, …-agy-2).
  local base='' zdir tbase=''
  [ "$team" = "$PRAMA_DEFAULT_TEAM" ] || base=$(slugify "${PRAMA_SESSION_PREFIX}-$zone-$team")
  zdir=$(zone_dir "$zone")
  # Isolation: a new team takes --isolate/--shared or PRAMA_SWARM_ISOLATE; an existing one keeps its own.
  if [ -n "$cs" ]; then
    [ -n "$isolate" ] || isolate=$(state_get "$cs" ISOLATE 0)
    if (( isolate )) && ! team_isolated "$cs"; then
      warn "$(_t 'Team "%s" shares the zone folder: new executors join it without worktrees.' "$team")"; isolate=0
    fi
  else
    [ -n "$isolate" ] || isolate=${PRAMA_SWARM_ISOLATE:-1}
  fi
  if (( isolate )) && ! git_can_isolate "$zdir"; then
    warn "$(_t "'%s' is not a git repository with commits on a branch: the team shares the folder (no worktrees)." "$zdir")"
    isolate=0
  fi
  if [ -z "$cs" ]; then
    (( isolate )) && tbase=$(git -C "$zdir" symbolic-ref --short -q HEAD)
    cs=$(PRAMA_TEAM=$team PRAMA_TEAM_ISOLATE=$isolate PRAMA_TEAM_BASE=$tbase \
           "$SELF_PATH" "$coord_a" "$zone" --role coordinator --bg --porcelain ${base:+--name "$base-coord"} \
           ${cmodel:+--model "$cmodel"}) || die "$(_t 'Could not launch the coordinator.')"
    state_set "$cs" ISOLATE="$isolate" ${tbase:+BASE="$tbase"}
    [ -n "$task" ] && state_set "$cs" OBJECTIVE="$task"
    ok "$(_t "Team \"%s\" in '%s' · coordinator: %s (%s)" "$team" "$zone" "$cs" "$coord_a")"
  else
    info_msg "$(_t "Team \"%s\" in '%s' (%s): the executors join it." "$team" "$zone" "$cs")"
  fi
  (( isolate )) && { tbase=$(team_base "$cs"); info_msg "$(_t 'Isolated team: each executor gets its own git worktree and branch from %s.' "$tbase")"; }

  local a w name n members=() branches=()
  for a in "${SW_AGENTS[@]}"; do
    # The session name is chosen here (not with --parallel) so the branch can carry it.
    if [ -n "$base" ]; then name="$base-$a"; else name=$(session_name_for "$a" "$zone" executor ""); fi
    if tmx_has "$name" || [ -f "$(state_file "$name")" ]; then
      n=2; while tmx_has "$name-$n" || [ -f "$(state_file "$name-$n")" ]; do (( n++ )); done
      name="$name-$n"
    fi
    local wtargs=()
    if (( isolate )); then
      local br; br=$(worker_branch "$team" "$name" "$base")
      wtargs=(--worktree "$br")
    fi
    w=$(PRAMA_PARENT=$cs PRAMA_TEAM_BASE=$tbase "$SELF_PATH" "$a" "$zone" --role executor --bg --porcelain \
          --name "$name" "${wtargs[@]}" ${wmodel:+--model "$wmodel"}) \
      || { warn "$(_t 'Could not launch a %s executor.' "$a")"; continue; }
    members+=("$w ($a)")
    if (( isolate )); then
      branches+=("$w → ${wtargs[1]}")
      ok "$(_t 'Executor: %s (%s) · branch %s' "$w" "$a" "${wtargs[1]}")"
    else
      ok "$(_t 'Executor: %s (%s)' "$w" "$a")"
    fi
  done

  # The coordinator learns its team (and the objective) as soon as it is ready: the watchdog
  # delivers queued messages to an agent that has been READY for two ticks.
  local brief who="${members[*]:-}" evtext
  [ -n "$who" ] || _tv who '(no executors)'
  _tv brief "[PRAMA] Your team \"%s\" in '%s': %s. Delegate with 'prama-agent bus assign <session> \"<task>\"', check with 'prama-agent fleet status' and add or remove agents with 'prama-agent fleet spawn|kill'." "$team" "$zone" "$who"
  [ -n "$task" ] && brief+=" $(_t 'OBJECTIVE: %s' "$task")"
  if (( ${#branches[@]} )); then
    brief+=" $(_t "ISOLATED TEAM: each executor works on its own branch (%s), you stay on %s in the zone folder. See them with 'prama-agent worktree status', review with 'git diff %s...<branch>', integrate with 'prama-agent worktree merge <session>'." "$(IFS=';'; printf '%s' "${branches[*]}")" "$tbase" "$tbase")"
  fi
  local nm; nm=$(( $(memory_count "$zone" "$team") + $(memory_count "$zone") ))
  (( nm > 0 )) && brief+=" $(_t "TEAM MEMORY: %d note(s), read them first with 'prama-agent memory show'." "$nm")"
  queue_push "$cs" "$brief"
  _tv evtext 'team %s: %s' "$team" "${members[*]:-}"
  [ -n "$task" ] && evtext+=$(_t ' · objective: %s' "$task")
  bus_event queued "${PRAMA_SESSION:-operator}" "$cs" "$evtext"
  watchdog_ensure || true
  declare -F telegram_notify >/dev/null && telegram_notify "$(_t "🤝 Team \"%s\" in '%s': %s + %d executor(s)" "$team" "$zone" "$cs" "${#members[@]}")" team "$cs" >/dev/null 2>&1

  if (( open )) && [ -t 0 ] && [ -t 1 ]; then
    subcmd_cockpit "$cs"
  else
    info_msg "$(_t 'Team cockpit: prama-agent cockpit %s --team %s' "$zone" "$team")"
  fi
}

# _swarm_stop <zone> [--team T | --all]  |  _swarm_stop <coordinator session>
_swarm_stop() {
  local arg=${1:-} team='' all=0 m zone c
  [ -n "$arg" ] || die "$(_t 'Usage: prama-agent swarm stop <zone> [--team <name>|--all] | <coordinator session>')"
  shift
  while (( $# )); do
    case "$1" in
      --team|-T) team=${2:?$(_t '--team requires a name')}; shift 2 ;;
      --all)     all=1; shift ;;
      *)         die "$(_t "Unexpected argument: '%s'" "$1")" ;;
    esac
  done
  local -a coords=()
  if valid_session_name "$arg" && tmx_has "$arg" && [ "$(session_role "$arg")" = coordinator ]; then
    coords=("$arg")
  else
    m=$(match_zone "$arg") || die "$(_t "Unknown zone or coordinator: '%s'" "$arg")"
    zone=$m
    if [ -n "$team" ]; then
      c=$(find_team "$zone" "$team") || die "$(_t "There is no team \"%s\" in '%s' (teams: %s)." "$team" "$zone" "$(_swarm_teams_hint "$zone")")"
      coords=("$c")
    else
      mapfile -t coords < <(zone_teams "$zone")
      (( ${#coords[@]} )) || die "$(_t "No teams in '%s'." "$zone")"
      (( ${#coords[@]} == 1 || all )) \
        || die "$(_t "Zone '%s' has %d teams (%s): give --team <name> or --all." "$zone" "${#coords[@]}" "$(_swarm_teams_hint "$zone")")"
    fi
  fi
  # An agent closes only its own team; a coordinator closing its team closes itself last.
  if [ -n "${PRAMA_SESSION:-}" ]; then
    local own
    if [ "$(session_role "$PRAMA_SESSION")" = coordinator ]; then own=$PRAMA_SESSION; else own=$(session_team "$PRAMA_SESSION") || own=''; fi
    [ "${#coords[@]}" = 1 ] && [ "${coords[0]}" = "$own" ] \
      || die "$(_t 'An agent can only close its own team (%s).' "${own:-—}")"
    [ "$own" = "$PRAMA_SESSION" ] || die "$(_t 'Only the coordinator can close the team; ask it with prama-agent bus report.')"
  fi
  for c in "${coords[@]}"; do _swarm_stop_team "$c"; done
}

_swarm_stop_team() {
  local cs=$1 s n=0 label cockpit self=0
  label=$(team_label "$cs") cockpit=$(cockpit_session "$(state_get "$cs" ZONE)" "$cs")
  [ "${PRAMA_SESSION:-}" = "$cs" ] && self=1
  wt_snapshot_team "$cs"
  while IFS= read -r s; do
    [ "$(state_get "$s" PARENT)" = "$cs" ] || continue
    tmx_kill "$s"; state_remove "$s"; bus_event stopped "${PRAMA_SESSION:-operator}" "$s" "swarm stop"; (( n++ ))
  done < <(prama_sessions)
  tmx_kill "$cockpit" 2>/dev/null || true
  wt_clean_snapshot
  ok "$(_t "Team \"%s\" closed: %s and %d executor(s)." "$label" "$cs" "$n")"
  bus_event stopped "${PRAMA_SESSION:-operator}" "$cs" "swarm stop"
  if (( self )); then
    # This command runs inside the coordinator's own pane: tell the operator, then let tmux close
    # the session a moment later, from outside this process.
    declare -F telegram_notify >/dev/null \
      && telegram_notify "$(_t '🏁 The coordinator closed team "%s" (%d executor(s)).' "$label" "$n")" team >/dev/null 2>&1
    state_remove "$cs"
    tmx run-shell -b "sleep 2; tmux -L '$PRAMA_TMUX_SOCKET' kill-session -t '=$cs'" 2>/dev/null || tmx_kill "$cs"
    return 0
  fi
  tmx_kill "$cs"; state_remove "$cs"
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
  (( ${#members[@]} )) || { warn "$(_t "No agents in '%s'. Launch a team: prama-agent swarm %s --team <name>" "$zone" "$zone")"; return 1; }
  cs=$(cockpit_session "$zone" "$coord")
  valid_session_name "$cs" || return 1
  # The team's plan gets a live pane once it has tasks (part of the signature: it appears by itself).
  local pcoord=$coord plan_on=0
  [ -n "$pcoord" ] || pcoord=$(zone_teams "$zone" | head -n 1)
  if [ -n "$pcoord" ] && declare -F plan_root >/dev/null \
     && [ -s "$(plan_root)/$(slugify "$zone")/$(team_name "$pcoord")/tasks" ]; then plan_on=1; fi
  sig="${members[*]} plan=$plan_on"
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
    if (( plan_on )); then
      printf -v watch_cmd '%q ' "$SELF_PATH" plan "$pcoord" watch
      pane=$(tmx split-window -P -F '#{pane_id}' -t "$last" -c "$dir" "${env_args[@]}" "${watch_cmd% }") \
        && { tmx select-pane -t "$pane" -T "$(_t '📋 PLAN · live')" 2>/dev/null; last=$pane; }
    fi
    printf -v watch_cmd '%q ' "$SELF_PATH" bus watch
    pane=$(tmx split-window -P -F '#{pane_id}' -t "$last" -c "$dir" "${env_args[@]}" "${watch_cmd% }") \
      && tmx select-pane -t "$pane" -T "$(_t '☍ BUS · live events')" 2>/dev/null
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
    m=$(match_zone "$arg") || { warn "$(_t "Unknown zone or session: '%s'" "$arg")"; return 1; }
    zone=$m
    if [ -n "$team" ]; then
      coord=$(find_team "$zone" "$team") || { warn "$(_t "There is no team \"%s\" in '%s' (teams: %s)." "$team" "$zone" "$(_swarm_teams_hint "$zone")")"; return 1; }
    else
      n=$(zone_teams "$zone" | grep -c . || true)
      if (( n == 1 )); then coord=$(zone_teams "$zone")
      elif (( n > 1 )); then warn "$(_t "Zone '%s' has %d teams (%s): give --team <name>." "$zone" "$n" "$(_swarm_teams_hint "$zone")")"; return 1
      fi
    fi
  else
    # No argument: the first team (or the first zone with agents).
    IFS='|' read -r m _ zone < <(prama_team_order | head -n 1)
    [ -n "$zone" ] || { warn "$(_t 'No active agents. Launch a team: prama-agent swarm <zone> --team <name>')"; return 1; }
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
    info_msg "$(_t 'Cockpit ready: prama-agent attach %s' "$cs")"
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
  local m
  [ -n "$zone" ] || { _tv m 'This session does not belong to a zone'; tmx display-message -c "$client" "$m" 2>/dev/null; return 0; }
  local coord; coord=$(session_team "$cur") || coord=''
  cs=$(cockpit_ensure "$zone" "$cur" "$coord" 2>/dev/null) || { _tv m 'No agents in %s' "$zone"; tmx display-message -c "$client" "$m" 2>/dev/null; return 0; }
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
  local l_menu l_prompt l_head l_num
  _tv l_menu '◂ prama menu'; _tv l_prompt 'agent › '; _tv l_head '↵ go · Esc close'; _tv l_num 'Number (Enter closes): '
  rows+=("$l_menu"); targets+=("@menu")
  if command -v fzf >/dev/null 2>&1; then
    choice=$(printf '%s\n' "${rows[@]}" | fzf --no-sort --layout=reverse --prompt="$l_prompt" \
      --header="$l_head" --info=hidden) || return 0
    for (( i = 0; i < ${#rows[@]}; i++ )); do [ "${rows[i]}" = "$choice" ] && { target=${targets[i]}; break; }; done
  else
    for (( i = 0; i < ${#rows[@]}; i++ )); do printf '%2d  %s\n' "$(( i + 1 ))" "${rows[i]}"; done
    printf '\n%s' "$l_num"
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
