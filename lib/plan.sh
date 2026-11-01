#!/usr/bin/env bash
# lib/plan.sh — The team plan: tasks the coordinator maintains, a live board and a timeline
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
#
# A plan belongs to a team (zone + team name) and outlives its sessions:
#   $PRAMA_STATE_HOME/plans/<zone>/<team>/tasks   one task per line, fields separated by \x1f
#   $PRAMA_STATE_HOME/plans/<zone>/<team>/log     append-only history: ts|rev|actor|action|task|detail
#   $PRAMA_STATE_HOME/plans/<zone>/<team>/rev     the plan revision (replan increments it)
# The coordinator writes it with cheap one-line commands (plan add / start / done / replan …), and
# `bus assign --task` / `bus report --task` move tasks too. What the agents say is checked against
# what can be observed: a task in progress whose owner shows no activity is stale, one marked done
# without evidence is unverified, two tasks in progress on the same files overlap.
# Everything is data: never sourced or executed. Writes are serialised with flock.

PLAN_FIELDS=(id status owner deps est progress created started updated 'done' rev title scope accept evidence)
PLAN_STATUSES=(todo doing review blocked 'done' dropped)
PRAMA_PLAN_STALE_MIN="${PRAMA_PLAN_STALE_MIN:-20}"
PLAN_SEP=$'\x1f'

plan_root() { printf '%s/plans' "$PRAMA_STATE_HOME"; }

# ── Target: a team ──────────────────────────────────────────────────────────
# _plan_target [<zone>|<session>] [--team T] → PL_ZONE PL_TEAM PL_DIR PL_COORD (coordinator if alive)
_plan_target() {
  local arg=${1:-} team=${2:-} m c
  PL_ZONE='' PL_TEAM='' PL_COORD=''
  [ -n "$arg" ] || arg=${PRAMA_SESSION:-}
  [ -n "$arg" ] || die "$(_t 'Which plan? Give a zone (--team T) or a session, e.g.: prama-agent plan backend --team docs')"
  if valid_session_name "$arg" && [ -f "$(state_file "$arg")" ]; then
    PL_ZONE=$(state_get "$arg" ZONE)
    if [ "$(session_role "$arg")" = coordinator ]; then c=$arg; else c=$(session_team "$arg" 2>/dev/null) || c=''; fi
    [ -n "$c" ] || die "$(_t "'%s' does not belong to a team." "$arg")"
    PL_COORD=$c PL_TEAM=$(team_name "$c")
  else
    m=$(match_zone "$arg") || die "$(_t "Unknown zone or session: '%s'" "$arg")"
    PL_ZONE=$m
    if [ -n "$team" ]; then PL_TEAM=$team
    else
      local -a cs=()
      mapfile -t cs < <(zone_teams "$m")
      if (( ${#cs[@]} == 1 )); then PL_TEAM=$(team_name "${cs[0]}")
      elif (( ${#cs[@]} == 0 )); then PL_TEAM=$PRAMA_DEFAULT_TEAM
      else die "$(_t "Zone '%s' has %d teams: give --team <name>." "$m" "${#cs[@]}")"; fi
    fi
    PL_COORD=$(find_team "$PL_ZONE" "$PL_TEAM" 2>/dev/null) || PL_COORD=''
  fi
  valid_team_name "$PL_TEAM" || die "$(_t 'Invalid team name: %s' "$PL_TEAM")"
  PL_DIR="$(plan_root)/$(slugify "$PL_ZONE")/$PL_TEAM"
}

# Only the team's coordinator and the operator change the plan; executors move their own tasks.
# _plan_can_edit [task_owner] → 0 allowed
_plan_can_edit() {
  local owner=${1:-}
  [ -z "${PRAMA_SESSION:-}" ] && return 0
  [ "$PRAMA_SESSION" = "$PL_COORD" ] && return 0
  [ -n "$owner" ] && [ "$PRAMA_SESSION" = "$owner" ] && return 0
  return 1
}

# ── Storage ─────────────────────────────────────────────────────────────────
# _plan_load → P_* arrays (one entry per task, same index) and PL_REV
_plan_load() {
  local f line i
  P_id=() P_status=() P_owner=() P_deps=() P_est=() P_progress=() P_created=() P_started=()
  P_updated=() P_done=() P_rev=() P_title=() P_scope=() P_accept=() P_evidence=()
  PL_REV=1
  [ -f "$PL_DIR/rev" ] && { IFS= read -r PL_REV < "$PL_DIR/rev" || true; }
  [[ $PL_REV =~ ^[0-9]+$ ]] || PL_REV=1
  f="$PL_DIR/tasks"
  [ -f "$f" ] || return 0
  local -a v
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    IFS=$PLAN_SEP read -r -a v <<< "$line"
    i=${#P_id[@]}
    P_id[i]=${v[0]-} P_status[i]=${v[1]-todo} P_owner[i]=${v[2]-} P_deps[i]=${v[3]-} P_est[i]=${v[4]-}
    P_progress[i]=${v[5]-} P_created[i]=${v[6]-} P_started[i]=${v[7]-} P_updated[i]=${v[8]-} P_done[i]=${v[9]-}
    P_rev[i]=${v[10]-} P_title[i]=${v[11]-} P_scope[i]=${v[12]-} P_accept[i]=${v[13]-} P_evidence[i]=${v[14]-}
  done < "$f"
  # IFS read collapses nothing for a non-whitespace separator, but drops trailing empty fields:
  # the defaults above cover them.
}

_plan_clean() { local s=${1//$PLAN_SEP/ }; s=${s//$'\n'/ }; s=${s//$'\r'/}; s=${s//$'\t'/ }; printf '%s' "${s:0:${2:-300}}"; }

_plan_save() {
  local tmp="$PL_DIR/tasks.tmp.$$" i f
  {
    for i in "${!P_id[@]}"; do
      local out='' sep=''
      for f in "${PLAN_FIELDS[@]}"; do
        local -n _v="P_$f"
        out+="$sep${_v[i]-}"; sep=$PLAN_SEP
        unset -n _v
      done
      printf '%s\n' "$out"
    done
  } > "$tmp" && mv -f "$tmp" "$PL_DIR/tasks"
  printf '%s\n' "$PL_REV" > "$PL_DIR/rev"
}

_plan_log() {
  printf '%s|%s|%s|%s|%s|%s\n' "${EPOCHSECONDS:-$(date +%s)}" "$PL_REV" "${PRAMA_SESSION:-operator}" "$1" "${2:-}" \
    "$(_plan_clean "${3:-}" 200)" >> "$PL_DIR/log"
}

# _plan_idx <id> → PI (index) or 1
_plan_idx() {
  local i
  for i in "${!P_id[@]}"; do [ "${P_id[i]}" = "$1" ] && { PI=$i; return 0; }; done
  return 1
}

# _plan_tx <function> [args…] — load, change and save under the plan's lock
_plan_tx() {
  ensure_private_dir "$(plan_root)"
  ensure_private_dir "$(plan_root)/$(slugify "$PL_ZONE")"
  ensure_private_dir "$PL_DIR"
  local rc=0
  {
    flock 8
    _plan_load
    "$@" || rc=$?
    (( rc )) || _plan_save
  } 8>>"$PL_DIR/.lock"
  return "$rc"
}

# ── Derived state ───────────────────────────────────────────────────────────
_plan_now() { PL_NOW=${EPOCHSECONDS:-$(date +%s)}; }

# _plan_ready <i> → 0 when a todo task has all its dependencies done (or dropped)
_plan_ready() {
  local i=$1 d j
  [ "${P_status[i]}" = todo ] || return 1
  for d in ${P_deps[i]//,/ }; do
    _plan_idx "$d" || continue
    j=$PI
    [[ ${P_status[j]} == 'done' || ${P_status[j]} == dropped ]] || return 1
  done
  return 0
}

# Last sign of life of an agent: the tmux window activity (any output), epoch seconds.
_plan_activity() {
  local s=$1 a
  [ -n "$s" ] && tmx_has "$s" || { printf '0'; return; }
  a=$(tmx display-message -p -t "=$s:" '#{window_activity}' 2>/dev/null)
  printf '%s' "${a:-0}"
}

# _plan_flags <i> → PF: stale | unverified | overlap:<id> | ready (space separated)
_plan_flags() {
  local i=$1 last act j
  PF=''
  _plan_now
  case ${P_status[i]} in
    doing)
      last=${P_updated[i]:-0}
      act=$(_plan_activity "${P_owner[i]}")
      (( act > last )) && last=$act
      (( PL_NOW - last >= PRAMA_PLAN_STALE_MIN * 60 )) && PF+=' stale'
      [ -n "${P_owner[i]}" ] && ! tmx_has "${P_owner[i]}" && PF+=' orphan'
      if [ -n "${P_scope[i]}" ]; then
        for j in "${!P_id[@]}"; do
          (( j != i )) && [ "${P_status[j]}" = doing ] && [ -n "${P_scope[j]}" ] || continue
          _plan_scopes_overlap "${P_scope[i]}" "${P_scope[j]}" && PF+=" overlap:${P_id[j]}"
        done
      fi ;;
    done) [ -n "${P_evidence[i]}" ] || PF+=' unverified' ;;
    todo) _plan_ready "$i" && PF+=' ready' ;;
  esac
  PF=${PF# }
}

# Two file scopes overlap when one's fixed prefix (before any wildcard) starts the other's.
_plan_scopes_overlap() {
  local a b pa pb
  for a in ${1//,/ }; do
    pa=${a%%[\*\?\[]*}
    for b in ${2//,/ }; do
      pb=${b%%[\*\?\[]*}
      [[ $pa == "$pb"* || $pb == "$pa"* ]] && return 0
    done
  done
  return 1
}

# Duration "30m", "2h", "1d", "45" (minutes) → minutes
_plan_minutes() {
  local dur=${1:-}
  case $dur in
    '') printf '' ;;
    *[0-9]m) printf '%d' "${dur%m}" ;;
    *[0-9]h) printf '%d' $(( ${dur%h} * 60 )) ;;
    *[0-9]d) printf '%d' $(( ${dur%d} * 480 )) ;;
    *[!0-9]*) return 1 ;;
    *) printf '%d' "$dur" ;;
  esac
}

# ── Mutations (run inside _plan_tx) ─────────────────────────────────────────
_plan_m_add() {
  local id=$1 title=$2 owner=$3 deps=$4 est=$5 scope=$6 accept=$7 i n=0 d
  if [ -z "$id" ]; then
    for i in "${P_id[@]}"; do [[ $i =~ ^T([0-9]+)$ ]] && (( BASH_REMATCH[1] > n )) && n=${BASH_REMATCH[1]}; done
    id="T$(( n + 1 ))"
  fi
  [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,15}$ ]] || die "$(_t 'Invalid task id: %s' "$id")"
  _plan_idx "$id" && die "$(_t 'Task %s already exists (plan set %s …).' "$id" "$id")"
  for d in ${deps//,/ }; do _plan_idx "$d" || die "$(_t 'Unknown dependency: %s' "$d")"; done
  _plan_now
  i=${#P_id[@]}
  P_id[i]=$id P_status[i]=todo P_owner[i]=$owner P_deps[i]=$deps P_est[i]=$est P_progress[i]=''
  P_created[i]=$PL_NOW P_started[i]='' P_updated[i]=$PL_NOW P_done[i]='' P_rev[i]=$PL_REV
  P_title[i]=$(_plan_clean "$title" 160) P_scope[i]=$(_plan_clean "$scope" 200) P_accept[i]=$(_plan_clean "$accept" 200) P_evidence[i]=''
  _plan_log add "$id" "$title"
  PL_OUT=$id
}

# _plan_m_status <id> <status> [owner] [evidence/reason]
_plan_m_status() {
  local id=$1 st=$2 owner=${3:-} note=${4:-}
  _plan_idx "$id" || die "$(_t 'Unknown task: %s (prama-agent plan)' "$id")"
  local i=$PI
  _plan_can_edit "${P_owner[i]}" || die "$(_t 'Only the coordinator or the task owner can change %s.' "$id")"
  _plan_now
  [ -n "$owner" ] && P_owner[i]=$owner
  case $st in
    doing)
      [ -n "${P_started[i]}" ] || P_started[i]=$PL_NOW
      local d
      for d in ${P_deps[i]//,/ }; do
        _plan_idx "$d" && [[ ${P_status[PI]} != 'done' && ${P_status[PI]} != dropped ]] \
          && warn "$(_t '%s starts before its dependency %s is done.' "$id" "$d")"
      done ;;
    done)
      P_done[i]=$PL_NOW P_progress[i]=100
      [ -n "${P_started[i]}" ] || P_started[i]=$PL_NOW
      [ -n "$note" ] && P_evidence[i]=$(_plan_clean "$note" 200) ;;
    review) [ -n "$note" ] && P_evidence[i]=$(_plan_clean "$note" 200) ;;
  esac
  P_status[i]=$st P_updated[i]=$PL_NOW
  _plan_log "$st" "$id" "${owner:+@$owner }$note"
  if [ "$st" = doing ] && [ -n "${P_scope[i]}" ]; then
    _plan_flags "$i"
    [[ $PF == *overlap:* ]] && warn "$(_t '%s touches the same files as %s, also in progress: expect conflicts.' "$id" "$(sed -E 's/.*overlap:([^ ]+).*/\1/' <<< "$PF")")"
  fi
  return 0
}

_plan_m_set() {
  local id=$1 kv k v; shift
  _plan_idx "$id" || die "$(_t 'Unknown task: %s (prama-agent plan)' "$id")"
  local i=$PI
  # The task's owner may report progress and evidence; everything else is the coordinator's.
  if ! _plan_can_edit; then
    _plan_can_edit "${P_owner[i]}" || die "$(_t 'Only the coordinator changes the plan.')"
    for kv in "$@"; do [[ $kv == progress=* || $kv == evidence=* ]] || die "$(_t 'Only the coordinator changes the plan.')"; done
  fi
  for kv in "$@"; do
    k=${kv%%=*} v=${kv#*=}
    [ "$k" != "$kv" ] || die "$(_t 'Expected key=value, got: %s' "$kv")"
    case $k in
      title|scope|accept|evidence) local -n _f="P_$k"; _f[i]=$(_plan_clean "$v" 200); unset -n _f ;;
      owner) P_owner[i]=$v ;;
      deps) local d; for d in ${v//,/ }; do _plan_idx "$d" || die "$(_t 'Unknown dependency: %s' "$d")"; done; P_deps[i]=$v ;;
      est) P_est[i]=$(_plan_minutes "$v") || die "$(_t 'Invalid estimate: %s (e.g. 30m, 2h)' "$v")" ;;
      progress) [[ $v =~ ^[0-9]{1,3}$ ]] && (( v <= 100 )) || die "$(_t 'progress is 0-100' )"; P_progress[i]=$v ;;
      status) is_in "$v" "${PLAN_STATUSES[@]}" || die "$(_t 'Unknown status: %s (%s)' "$v" "${PLAN_STATUSES[*]}")"; P_status[i]=$v ;;
      *) die "$(_t 'Unknown field: %s (title owner deps est progress scope accept evidence status)' "$k")" ;;
    esac
  done
  _plan_now
  P_updated[i]=$PL_NOW P_rev[i]=$PL_REV
  _plan_log set "$id" "$*"
}

_plan_m_replan() {
  local reason=$1
  _plan_can_edit || die "$(_t 'Only the coordinator changes the plan.')"
  PL_REV=$(( PL_REV + 1 ))
  _plan_log replan '' "$reason"
}

# ── Commands ────────────────────────────────────────────────────────────────
_plan_usage() {
  case ${PRAMA_UI_LANG:-en} in
    es) cat <<'EOF'
Uso: prama-agent plan [<zona>|<sesión>] [--team T]           tablero del plan del equipo (un agente: el suyo)
     prama-agent plan add "<título>" [--id T3] [--owner <sesión>] [--deps T1,T2] [--est 30m|2h]
                          [--scope "src/api/**"] [--accept "<cómo se verifica>"]
     prama-agent plan start <id> [--owner <sesión>]        en curso
     prama-agent plan done <id> --evidence "<test y resultado, commit>"
     prama-agent plan review|block|drop <id> ["<motivo>"]   prama-agent plan set <id> clave=valor…
     prama-agent plan replan "<motivo>"                     nueva revisión del plan (queda en el historial)
     prama-agent plan board | timeline | log | watch | json | html [archivo]
También: bus assign <sesión> "<tarea>" --task T3 (la pone en curso) · bus report "<resumen>" --task T3 (a revisión).
EOF
    ;;
    *) cat <<'EOF'
Usage: prama-agent plan [<zone>|<session>] [--team T]           the team's plan board (an agent: its own)
       prama-agent plan add "<title>" [--id T3] [--owner <session>] [--deps T1,T2] [--est 30m|2h]
                            [--scope "src/api/**"] [--accept "<how it is checked>"]
       prama-agent plan start <id> [--owner <session>]        in progress
       prama-agent plan done <id> --evidence "<test and result, commit>"
       prama-agent plan review|block|drop <id> ["<reason>"]   prama-agent plan set <id> key=value…
       prama-agent plan replan "<reason>"                     a new revision of the plan (kept in the history)
       prama-agent plan board | timeline | log | watch | json | html [file]
Also: bus assign <session> "<task>" --task T3 (starts it) · bus report "<summary>" --task T3 (to review).
EOF
    ;;
  esac
}

subcmd_plan() {
  local sub=board target='' team='' a
  local -a rest=()
  # Global target options anywhere: a zone or a session as first word, --team T.
  while (( $# )); do
    case $1 in
      --team|-T) team=${2:?$(_t '--team requires a name')}; shift 2 ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  set -- "${rest[@]}"
  case ${1:-} in
    add|start|done|review|block|drop|set|replan|board|timeline|gantt|log|history|watch|json|html|help|-h|--help|show)
      sub=$1; shift ;;
    '') ;;
    *)
      if match_zone "$1" >/dev/null 2>&1 || { valid_session_name "$1" && [ -f "$(state_file "$1")" ]; }; then
        target=$1; shift
        if [ -n "${1:-}" ]; then sub=$1; shift; fi
      else
        _plan_usage >&2; die "$(_t 'Unknown subcommand: plan %s' "$1")"
      fi ;;
  esac
  case $sub in help|-h|--help) _plan_usage; return 0 ;; esac
  # Mutations by an agent apply to its own team; the operator names one (or the zone's only team).
  _plan_target "$target" "$team"
  case $sub in
    board|show) plan_board ;;
    timeline|gantt) plan_timeline ;;
    log|history) plan_history "$@" ;;
    watch) plan_watch ;;
    json) plan_json ;;
    html) plan_html "$@" ;;
    add)
      local title='' id='' owner='' deps='' est='' scope='' accept=''
      while (( $# )); do
        case $1 in
          --id) id=${2:?}; shift 2 ;;
          --owner) owner=${2:?}; shift 2 ;;
          --deps) deps=${2:?}; shift 2 ;;
          --est) est=$(_plan_minutes "${2:?}") || die "$(_t 'Invalid estimate: %s (e.g. 30m, 2h)' "$2")"; shift 2 ;;
          --scope) scope=${2:?}; shift 2 ;;
          --accept) accept=${2:?}; shift 2 ;;
          *) title+="${title:+ }$1"; shift ;;
        esac
      done
      [ -n "$title" ] || die "$(_t 'Usage: prama-agent plan add "<title>" [--deps T1,T2] [--est 30m] …')"
      _plan_can_edit || die "$(_t 'Only the coordinator changes the plan.')"
      _plan_tx _plan_m_add "$id" "$title" "$owner" "$deps" "$est" "$scope" "$accept" || return 1
      ok "$(_t 'Task %s added to the plan of %s.' "$PL_OUT" "$PL_ZONE · $PL_TEAM")" ;;
    start)
      local id=${1:-} owner=''; shift || true
      [ "${1:-}" = --owner ] && owner=${2:-}
      [ -n "$owner" ] || owner=${PRAMA_SESSION:-}
      [ "$owner" = "$PL_COORD" ] && owner=''
      [ -n "$id" ] || die "$(_t 'Usage: prama-agent plan %s <id>' start)"
      _plan_tx _plan_m_status "$id" doing "$owner" || return 1
      ok "$(_t '%s in progress.' "$id")" ;;
    done)
      local id=${1:-} ev=''; shift || true
      while (( $# )); do case $1 in --evidence|-e) ev=${2:-}; shift 2 ;; *) ev+="${ev:+ }$1"; shift ;; esac; done
      [ -n "$id" ] || die "$(_t 'Usage: prama-agent plan %s <id>' 'done')"
      _plan_tx _plan_m_status "$id" 'done' '' "$ev" || return 1
      if [ -n "$ev" ]; then ok "$(_t '%s done.' "$id")"
      else warn "$(_t '%s marked done WITHOUT evidence: it shows as unverified (add --evidence "<test and result>").' "$id")"; fi ;;
    review|block|drop)
      local id=${1:-}; shift || true
      local st=$sub; [ "$sub" = block ] && st=blocked; [ "$sub" = drop ] && st=dropped
      [ -n "$id" ] || die "$(_t 'Usage: prama-agent plan %s <id>' "$sub")"
      _plan_tx _plan_m_status "$id" "$st" '' "$*" || return 1
      ok "$(_t '%s → %s.' "$id" "$st")" ;;
    set)
      local id=${1:-}; shift || true
      [ -n "$id" ] && (( $# )) || die "$(_t 'Usage: prama-agent plan set <id> key=value …')"
      _plan_tx _plan_m_set "$id" "$@" || return 1
      ok "$(_t '%s updated.' "$id")" ;;
    replan)
      [ -n "${*:-}" ] || die "$(_t 'Usage: prama-agent plan replan "<reason>"')"
      _plan_tx _plan_m_replan "$*" || return 1
      bus_event replan "${PRAMA_SESSION:-operator}" "$PL_ZONE/$PL_TEAM" "r$PL_REV: $*"
      declare -F telegram_notify >/dev/null \
        && telegram_notify "$(_t '🗺 Team %s re-planned (r%d): %s' "$PL_ZONE · $PL_TEAM" "$PL_REV" "$*")" team "$PL_COORD" >/dev/null 2>&1
      ok "$(_t 'Plan revision r%d: %s' "$PL_REV" "$*")" ;;
  esac
}

# Integration with the bus: assign --task starts the task, report --task sends it to review.
plan_bus_hook() {
  local kind=$1 task=$2 who=$3 text=${4:-} c
  [ -n "$task" ] || return 0
  if [ "$kind" = assign ]; then
    _plan_target "$who" '' 2>/dev/null || return 0
    [ "$who" = "$PL_COORD" ] && who=''
    ( _plan_tx _plan_m_status "$task" doing "$who" ) || return 1
  else
    _plan_target "$who" '' 2>/dev/null || return 0
    ( _plan_tx _plan_m_status "$task" review '' "$text" ) || return 1
  fi
}

# ── Views ───────────────────────────────────────────────────────────────────
# Owner colors: one per agent, stable within a plan (order of first appearance).
_plan_owner_colors() {
  local i o n=0
  declare -gA PL_OC=()
  local -a pal=("$C_NEON" "$C_PURP" "$C_LIVE" "$C_BRASS" "$C_INDIGO" "$C_ERR")
  for i in "${!P_id[@]}"; do
    o=${P_owner[i]}
    [ -n "$o" ] && [ -z "${PL_OC[$o]+x}" ] && { PL_OC[$o]=${pal[n % ${#pal[@]}]}; n=$(( n + 1 )); }
  done
}

_plan_short_owner() {
  local o=${1#"${PRAMA_SESSION_PREFIX}"-}
  local base="${PL_ZONE}-${PL_TEAM}-"
  o=${o#"$base"}
  printf '%s' "$o"
}

# _plan_card <i> <width> → UI_S (one ANSI line)
_plan_card() {
  local i=$1 w=$2
  local st=${P_status[i]} col=$C_TEXT mark=' ' own='' flags='' g=''
  _plan_flags "$i"
  case $st in
    doing) col=$C_NEON; mark='▶' ;;
    review) col=$C_PURP; mark='◆' ;;
    blocked) col=$C_ERR; mark='■' ;;
    done) col=$C_LIVE; mark='✔' ;;
    dropped) col=$C_MUTED; mark='×' ;;
    *) col=$C_TEXT; mark='○'; [[ $PF == *ready* ]] && mark='●' ;;
  esac
  [ -n "${P_owner[i]}" ] && own=" $(_plan_short_owner "${P_owner[i]}")"
  [[ $PF == *stale* ]] && flags+=" ⚠"
  [[ $PF == *orphan* ]] && flags+=" ✝"
  [[ $PF == *unverified* ]] && flags+=" ?"
  [[ $PF == *overlap* ]] && flags+=" ⇄"
  (( ${P_rev[i]:-0} == PL_REV && PL_REV > 1 )) && flags+=" Δ"
  if [ "$st" = doing ] && [ -n "${P_progress[i]}" ]; then ui_gauge "${P_progress[i]}" 4; g=" $UI_S"; fi
  local oc=$C_MUTED
  [ -n "${P_owner[i]}" ] && oc=${PL_OC[${P_owner[i]}]:-$C_MUTED}
  local plain="$mark ${P_id[i]} ${P_title[i]}"
  ui_width "$own$g$flags"; local tail_w=$UI_W
  ui_fit "$plain" $(( w - tail_w > 6 ? w - tail_w : 6 ))
  UI_S="$col$UI_S$C_OFF$oc$own$C_OFF$C_MUTED$g$C_OFF$C_BRASS$flags$C_OFF"
}

plan_board() {
  _plan_load
  _plan_owner_colors
  refresh_dimensions
  local tc=${TERM_COLS:-$COLS} i n=${#P_id[@]} st
  local ndone=0 nact=0
  for i in "${!P_id[@]}"; do
    [ "${P_status[i]}" = 'done' ] && ndone=$(( ndone + 1 ))
    [ "${P_status[i]}" = dropped ] || nact=$(( nact + 1 ))
  done
  local pct=0; (( nact )) && pct=$(( ndone * 100 / nact ))
  ui_gauge "$pct" 20
  printf ' %s%s%s  %s%s%s %d%%  %s\n' "$C_BOLD" "$(_t 'Plan · %s · r%d' "$PL_ZONE · $PL_TEAM" "$PL_REV")" "$C_OFF" \
    "$C_LIVE" "$UI_S" "$C_OFF" "$pct" "$C_MUTED$(_t '%d of %d tasks done' "$ndone" "$nact")$C_OFF"
  if (( n == 0 )); then
    printf '\n %s\n' "$(_t '(empty plan: the coordinator adds tasks with prama-agent plan add "<title>" --deps … --est …)')"
    return 0
  fi
  local -a cols=(todo doing review blocked 'done') heads
  heads=("$(_t 'TO DO')" "$(_t 'IN PROGRESS')" "$(_t 'REVIEW')" "$(_t 'BLOCKED')" "$(_t 'DONE')")
  if (( tc >= 110 )); then
    # Columns side by side.
    local cw=$(( (tc - 2) / 5 - 1 )) r maxr=0 c line
    local -a colitems=()
    for c in 0 1 2 3 4; do
      local list=''
      for i in "${!P_id[@]}"; do [ "${P_status[i]}" = "${cols[c]}" ] && list+="$i "; done
      colitems[c]=$list
      local cnt; cnt=$(wc -w <<< "$list"); (( cnt > maxr )) && maxr=$cnt
    done
    line=' '
    for c in 0 1 2 3 4; do
      local cnt; cnt=$(wc -w <<< "${colitems[c]}")
      ui_fit "${heads[c]} ($cnt)" "$cw"; line+="$C_MUTED$C_BOLD$UI_S$C_OFF "
    done
    printf '\n%s\n' "$line"
    ui_repeat '─' "$cw"; local rule=$UI_S
    printf ' %s\n' "$C_BORDER$rule $rule $rule $rule $rule$C_OFF"
    for ((r = 0; r < maxr; r++)); do
      line=' '
      for c in 0 1 2 3 4; do
        local -a it; read -r -a it <<< "${colitems[c]}"
        if (( r < ${#it[@]} )); then
          _plan_card "${it[r]}" "$cw"
          if (( HAS_COLOR )); then ui_ansi_fit "$UI_S" "$cw"; else ui_fit "$UI_S" "$cw"; fi
          line+="$UI_S "
        else _tui_blank_s "$cw"; line+="$UI_S "; fi
      done
      printf '%s\n' "$line"
    done
  else
    local c
    for c in 0 1 2 3 4; do
      local any=0
      for i in "${!P_id[@]}"; do
        [ "${P_status[i]}" = "${cols[c]}" ] || continue
        (( any )) || printf '\n %s%s%s\n' "$C_MUTED$C_BOLD" "${heads[c]}" "$C_OFF"
        any=1
        _plan_card "$i" $(( tc - 4 )); printf '  %s\n' "$UI_S"
      done
    done
  fi
  printf '\n %s\n' "$C_MUTED$(_t '● ready  ▶ in progress  ◆ review  ■ blocked  ✔ done  ⚠ stale  ? no evidence  ⇄ same files  ✝ owner gone  Δ changed in r%d' "$PL_REV")$C_OFF"
}

_tui_blank_s() { printf -v UI_S '%*s' "$1" ''; }

# Timeline: one lane per owner, a bar per task from start to done (or now), the estimate after it
# as a dotted forecast, and re-plan marks on the time axis. Planned (not started) tasks are listed
# under their lane.
plan_timeline() {
  _plan_load
  _plan_owner_colors
  refresh_dimensions
  _plan_now
  local tc=${TERM_COLS:-$COLS} i t0=0 t1=$PL_NOW lw=14 w
  for i in "${!P_id[@]}"; do
    [ -n "${P_started[i]}" ] && { (( t0 == 0 || P_started[i] < t0 )) && t0=${P_started[i]}; }
    if [ "${P_status[i]}" = doing ] && [ -n "${P_est[i]}" ]; then
      local f=$(( P_started[i] + P_est[i] * 60 )); (( f > t1 )) && t1=$f
    fi
  done
  printf ' %s%s%s\n' "$C_BOLD" "$(_t 'Timeline · %s · r%d' "$PL_ZONE · $PL_TEAM" "$PL_REV")" "$C_OFF"
  if (( t0 == 0 )); then printf '\n %s\n' "$(_t '(no task started yet)')"; return 0; fi
  (( t1 <= t0 )) && t1=$(( t0 + 60 ))
  # Room after the bars for "T12 +45m ⚠ ?".
  w=$(( tc - lw - 18 )); (( w < 20 )) && w=20
  local span=$(( t1 - t0 ))
  # Axis: start time, now marker, end; re-plan marks from the log.
  local axis marks
  printf -v axis '%*s' "$w" ''
  marks=$axis
  local nowc=$(( (PL_NOW - t0) * (w - 1) / span ))
  if [ -f "$PL_DIR/log" ]; then
    local ts rev act _r
    while IFS='|' read -r ts rev _r act _r _r; do
      [ "$act" = replan ] || continue
      (( ts >= t0 )) || continue
      local c=$(( (ts - t0) * (w - 1) / span ))
      marks="${marks:0:c}↻${marks:c+1}"
    done < "$PL_DIR/log"
  fi
  printf ' %-*s %s%s%s\n' "$lw" '' "$C_BRASS" "$marks" "$C_OFF"
  local lstart lend
  printf -v lstart '%(%H:%M)T' "$t0"; printf -v lend '%(%H:%M)T' "$t1"
  printf ' %-*s %s%-*s%s%s\n' "$lw" '' "$C_MUTED" $(( w - ${#lend} )) "$lstart" "$lend" "$C_OFF"
  # Lanes
  local -a owners=() ; local o
  for i in "${!P_id[@]}"; do
    o=${P_owner[i]:-—}
    is_in "$o" "${owners[@]}" || owners+=("$o")
  done
  for o in "${owners[@]}"; do
    local oc=$C_MUTED label
    [ "$o" != — ] && oc=${PL_OC[$o]:-$C_MUTED}
    if [ "$o" = — ]; then label=$(_t '(unassigned)'); else label=$(_plan_short_owner "$o"); fi
    ui_fit "$label" "$lw"; local lab=$UI_S first=1
    for i in "${!P_id[@]}"; do
      [ "${P_owner[i]:-—}" = "$o" ] || continue
      [ -n "${P_started[i]}" ] || continue
      local s=${P_started[i]} e=$PL_NOW ch='█' col=$oc
      [ -n "${P_done[i]}" ] && e=${P_done[i]}
      case ${P_status[i]} in done) col=$oc ;; review) ch='▓' ;; blocked) col=$C_ERR; ch='▒' ;; dropped) col=$C_MUTED; ch='░' ;; esac
      local a=$(( (s - t0) * (w - 1) / span )) b=$(( (e - t0) * (w - 1) / span ))
      (( b < a )) && b=$a
      local bar fc=''
      printf -v bar '%*s' "$a" ''
      local seg; ui_repeat "$ch" $(( b - a + 1 )); seg=$UI_S
      if [ "${P_status[i]}" = doing ] && [ -n "${P_est[i]}" ]; then
        local fe=$(( (s + P_est[i] * 60 - t0) * (w - 1) / span ))
        (( fe > b )) && { ui_repeat '┄' $(( fe - b )); fc=$UI_S; }
      fi
      local over=''
      if [ -n "${P_est[i]}" ] && (( (e - s) / 60 - P_est[i] >= 1 )); then over=" $C_ERR+$(( (e - s) / 60 - P_est[i] ))m$C_OFF"; fi
      _plan_flags "$i"
      local fl=''; [[ $PF == *stale* ]] && fl=" $C_BRASS⚠$C_OFF"; [[ $PF == *unverified* ]] && fl+=" $C_BRASS?$C_OFF"
      if (( first )); then printf ' %s%s%s ' "$oc" "$lab" "$C_OFF"; first=0; else printf ' %-*s ' "$lw" ''; fi
      printf '%s%s%s%s%s%s %s%s%s%s\n' "$bar" "$col" "$seg" "$C_MUTED" "$fc" "$C_OFF" "$C_TEXT" "${P_id[i]}" "$C_OFF" "$over$fl"
    done
    local pend=''
    for i in "${!P_id[@]}"; do
      [ "${P_owner[i]:-—}" = "$o" ] && [ -z "${P_started[i]}" ] && [ "${P_status[i]}" != dropped ] && pend+=" ${P_id[i]}"
    done
    if [ -n "$pend" ]; then
      if (( first )); then printf ' %s%s%s ' "$oc" "$lab" "$C_OFF"; else printf ' %-*s ' "$lw" ''; fi
      printf '%s%s%s\n' "$C_MUTED" "$(_t 'next:%s' "$pend")" "$C_OFF"
    fi
  done
  printf '\n %s\n' "$C_MUTED$(_t '█ work  ▓ in review  ┄ estimate left  ↻ re-plan  +Nm over the estimate')$C_OFF"
}

plan_history() {
  [ -f "$PL_DIR/log" ] || { info_msg "$(_t 'No history yet.')"; return 0; }
  local ts rev who act task det n=${1:-40}
  tail -n "$n" "$PL_DIR/log" | while IFS='|' read -r ts rev who act task det; do
    local col=$C_TEXT
    case $act in replan) col=$C_BRASS ;; done) col=$C_LIVE ;; blocked|dropped) col=$C_ERR ;; doing) col=$C_NEON ;; esac
    printf ' %s%(%m-%d %H:%M)T%s r%-2s %s%-7s%s %-5s %s %s\n' "$C_MUTED" "$ts" "$C_OFF" "$rev" "$col" "$act" "$C_OFF" "$task" \
      "$C_MUTED$(_plan_short_owner "$who")$C_OFF" "$det"
  done
}

plan_json() {
  _plan_load
  local i f sep='' fsep
  printf '{"zone":"%s","team":"%s","rev":%d,"tasks":[' "$(json_escape "$PL_ZONE")" "$(json_escape "$PL_TEAM")" "$PL_REV"
  for i in "${!P_id[@]}"; do
    _plan_flags "$i"
    printf '%s{' "$sep"; fsep=''
    for f in "${PLAN_FIELDS[@]}"; do
      local -n _v="P_$f"
      printf '%s"%s":"%s"' "$fsep" "$f" "$(json_escape "${_v[i]-}")"; fsep=','
      unset -n _v
    done
    printf ',"flags":"%s"}' "$PF"
    sep=','
  done
  printf ']}\n'
}

# Live view for a terminal pane (cockpit, menu): board and timeline, redrawn when the plan changes.
plan_watch() {
  local view=board key last='' cur
  [ -t 1 ] && printf '\e[?25l'
  trap 'printf "\e[?25h"' EXIT
  while :; do
    cur="$(stat -c %Y "$PL_DIR/tasks" "$PL_DIR/log" 2>/dev/null | tr '\n' .)$view$(date +%M)"
    if [ "$cur" != "$last" ]; then
      last=$cur
      printf '\e[H\e[2J'
      if [ "$view" = board ]; then plan_board; else plan_timeline; fi
      printf '\n %s' "$C_MUTED$(_t 'v board ⇄ timeline · q close · live')$C_OFF"
    fi
    key=''
    IFS= read -rsn1 -t 2 key 2>/dev/null || true
    case $key in
      v|V|t|b) if [ "$view" = board ]; then view=timeline; else view=board; fi ;;
      q|Q) break ;;
    esac
  done
}

# ── HTML export: one self-contained file (no scripts, no network) ───────────
_plan_h() { local s=${1//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; s=${s//\"/&quot;}; printf '%s' "$s"; }

# plan html [file] — board, timeline (SVG) and dependencies, in the theme's colors
plan_html() {
  local out=${1:-}
  _plan_load
  _plan_now
  [ -n "$out" ] || out="$PL_DIR/plan.html"
  local -a pal=("${TH_ACCENT:-#38bdf8}" "${TH_PURP:-#c084fc}" "${TH_OK:-#34d399}" "${TH_WARN:-#fbbf24}" "${TH_ACCENT2:-#818cf8}" "${TH_ERR:-#f87171}")
  local -A oc=(); local i o n=0
  for i in "${!P_id[@]}"; do o=${P_owner[i]}; [ -n "$o" ] && [ -z "${oc[$o]+x}" ] && { oc[$o]=${pal[n % 6]}; n=$(( n + 1 )); }; done
  local ndone=0 nact=0
  for i in "${!P_id[@]}"; do
    [ "${P_status[i]}" = 'done' ] && ndone=$(( ndone + 1 )); [ "${P_status[i]}" = dropped ] || nact=$(( nact + 1 ))
  done
  local pct=0; (( nact )) && pct=$(( ndone * 100 / nact ))
  local stamp; printf -v stamp '%(%Y-%m-%d %H:%M)T' "$PL_NOW"
  {
  cat <<HTML
<!doctype html>
<html lang="${PRAMA_UI_LANG:-en}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$(_plan_h "$(_t 'Plan · %s' "$PL_ZONE · $PL_TEAM")")</title>
<style>
:root{--bg:${TH_HEAD:-#0f172a};--card:${TH_BADGE:-#1e293b};--text:${TH_TEXT:-#e2e8f0};--muted:${TH_MUTED:-#64748b};--border:${TH_BORDER:-#334155};--accent:${TH_ACCENT:-#38bdf8};--ok:${TH_OK:-#34d399};--warn:${TH_WARN:-#fbbf24};--err:${TH_ERR:-#f87171};--purp:${TH_PURP:-#c084fc}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;padding:24px 16px}
main{max-width:1200px;margin:0 auto}h1{font-size:22px;margin:0 0 4px}.sub{color:var(--muted);margin-bottom:18px}
.bar{height:10px;background:var(--card);border-radius:6px;overflow:hidden;margin:6px 0 22px}.bar>i{display:block;height:100%;background:var(--ok);width:${pct}%}
.cols{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:12px}@media(max-width:900px){.cols{grid-template-columns:1fr}}
.col h2{font-size:12px;letter-spacing:.08em;color:var(--muted);margin:0 0 8px;text-transform:uppercase}
.card{background:var(--card);border:1px solid var(--border);border-left:4px solid var(--c,var(--border));border-radius:8px;padding:8px 10px;margin-bottom:8px}
.card b{color:var(--accent);margin-right:6px}.meta{color:var(--muted);font-size:12px;margin-top:4px}.flag{color:var(--warn);font-weight:600;margin-left:6px}
.prog{height:4px;background:var(--border);border-radius:3px;margin-top:6px}.prog>i{display:block;height:100%;background:var(--c,var(--accent));border-radius:3px}
section{margin-top:28px}svg text{fill:var(--text);font-size:12px}.legend{color:var(--muted);font-size:12px;margin-top:6px}
table{border-collapse:collapse;width:100%}td,th{border-bottom:1px solid var(--border);padding:6px 8px;text-align:left;font-size:13px}th{color:var(--muted);font-weight:600}
</style></head><body><main>
<h1>$(_plan_h "$(_t 'Plan · %s' "$PL_ZONE · $PL_TEAM")") <span style="color:var(--muted);font-weight:400">r$PL_REV</span></h1>
<div class="sub">$(_plan_h "$(_t '%d of %d tasks done · generated %s by prama-agent' "$ndone" "$nact" "$stamp")")</div>
<div class="bar"><i></i></div>
<div class="cols">
HTML
  local -a cols=(todo doing review blocked 'done')
  local -a heads=("$(_t 'TO DO')" "$(_t 'IN PROGRESS')" "$(_t 'REVIEW')" "$(_t 'BLOCKED')" "$(_t 'DONE')")
  local c
  for c in 0 1 2 3 4; do
    printf '<div class="col"><h2>%s</h2>\n' "$(_plan_h "${heads[c]}")"
    for i in "${!P_id[@]}"; do
      [ "${P_status[i]}" = "${cols[c]}" ] || continue
      _plan_flags "$i"
      local col='var(--border)' fl='' meta=''
      [ -n "${P_owner[i]}" ] && col=${oc[${P_owner[i]}]:-var(--border)}
      [[ $PF == *stale* ]] && fl+="<span class=flag>⚠ $(_plan_h "$(_t 'stale')")</span>"
      [[ $PF == *unverified* ]] && fl+="<span class=flag>? $(_plan_h "$(_t 'no evidence')")</span>"
      [[ $PF == *overlap* ]] && fl+="<span class=flag>⇄ $(_plan_h "$(_t 'same files')")</span>"
      [[ $PF == *ready* ]] && fl+="<span class=flag style=color:var(--ok)>● $(_plan_h "$(_t 'ready')")</span>"
      [ -n "${P_owner[i]}" ] && meta+="$(_plan_h "$(_plan_short_owner "${P_owner[i]}")")"
      [ -n "${P_deps[i]}" ] && meta+=" · ⤷ $(_plan_h "${P_deps[i]}")"
      [ -n "${P_est[i]}" ] && meta+=" · ${P_est[i]}m"
      [ -n "${P_evidence[i]}" ] && meta+="<br>✔ $(_plan_h "${P_evidence[i]}")"
      printf '<div class="card" style="--c:%s"><b>%s</b>%s%s<div class="meta">%s</div>' "$col" "$(_plan_h "${P_id[i]}")" "$(_plan_h "${P_title[i]}")" "$fl" "$meta"
      [ -n "${P_progress[i]}" ] && [ "${P_status[i]}" = doing ] && printf '<div class="prog"><i style="width:%d%%"></i></div>' "${P_progress[i]}"
      printf '</div>\n'
    done
    printf '</div>\n'
  done
  printf '</div>\n'
  # Timeline SVG
  local t0=0 t1=$PL_NOW
  for i in "${!P_id[@]}"; do
    [ -n "${P_started[i]}" ] && { (( t0 == 0 || P_started[i] < t0 )) && t0=${P_started[i]}; }
    if [ "${P_status[i]}" = doing ] && [ -n "${P_est[i]}" ]; then local f=$(( P_started[i] + P_est[i] * 60 )); (( f > t1 )) && t1=$f; fi
  done
  if (( t0 > 0 )); then
    (( t1 <= t0 )) && t1=$(( t0 + 60 ))
    local W=1100 L=170 rowh=26 y=30 span=$(( t1 - t0 )) rows=0
    for i in "${!P_id[@]}"; do [ -n "${P_started[i]}" ] && rows=$(( rows + 1 )); done
    local H=$(( 50 + rows * rowh ))
    printf '<section><h2 style="font-size:16px">%s</h2><svg viewBox="0 0 %d %d" width="100%%" role="img">\n' "$(_plan_h "$(_t 'Timeline')")" "$W" "$H"
    local x_now=$(( L + (PL_NOW - t0) * (W - L - 20) / span ))
    printf '<line x1="%d" y1="18" x2="%d" y2="%d" stroke="%s" stroke-dasharray="3 3"/><text x="%d" y="14">%s</text>\n' \
      "$x_now" "$x_now" "$H" "${TH_ACCENT:-#38bdf8}" $(( x_now - 14 )) "$(_plan_h "$(_t 'now')")"
    if [ -f "$PL_DIR/log" ]; then
      local ts rev act _r det
      while IFS='|' read -r ts rev _r act _r det; do
        [ "$act" = replan ] && (( ts >= t0 )) || continue
        local xr=$(( L + (ts - t0) * (W - L - 20) / span ))
        printf '<line x1="%d" y1="18" x2="%d" y2="%d" stroke="%s"/><text x="%d" y="%d" style="fill:%s">↻ r%s</text><title>%s</title>\n' \
          "$xr" "$xr" "$H" "${TH_WARN:-#fbbf24}" $(( xr + 3 )) $(( H - 4 )) "${TH_WARN:-#fbbf24}" "$rev" "$(_plan_h "$det")"
      done < "$PL_DIR/log"
    fi
    for i in "${!P_id[@]}"; do
      [ -n "${P_started[i]}" ] || continue
      local s=${P_started[i]} e=$PL_NOW col=${TH_MUTED:-#64748b} op=1
      [ -n "${P_owner[i]}" ] && col=${oc[${P_owner[i]}]:-$col}
      [ -n "${P_done[i]}" ] && e=${P_done[i]}
      [ "${P_status[i]}" = 'done' ] && op=0.75
      [ "${P_status[i]}" = blocked ] && col=${TH_ERR:-#f87171}
      local x1=$(( L + (s - t0) * (W - L - 20) / span )) x2=$(( L + (e - t0) * (W - L - 20) / span ))
      (( x2 < x1 + 4 )) && x2=$(( x1 + 4 ))
      printf '<text x="4" y="%d">%s</text>' $(( y + 13 )) "$(_plan_h "${P_id[i]} $(_plan_short_owner "${P_owner[i]:-—}")")"
      printf '<rect x="%d" y="%d" width="%d" height="16" rx="4" fill="%s" opacity="%s"><title>%s</title></rect>' \
        "$x1" "$y" $(( x2 - x1 )) "$col" "$op" "$(_plan_h "${P_id[i]} · ${P_title[i]} · ${P_status[i]}")"
      if [ "${P_status[i]}" = doing ] && [ -n "${P_est[i]}" ]; then
        local xf=$(( L + (s + P_est[i] * 60 - t0) * (W - L - 20) / span ))
        (( xf > x2 )) && printf '<rect x="%d" y="%d" width="%d" height="16" rx="4" fill="none" stroke="%s" stroke-dasharray="4 3"/>' "$x2" "$y" $(( xf - x2 )) "$col"
      fi
      printf '\n'
      y=$(( y + rowh ))
    done
    printf '</svg><div class="legend">%s</div></section>\n' "$(_plan_h "$(_t 'Solid: work done or in progress · dashed: estimate left · ↻ re-plan')")"
  fi
  # Dependencies table
  printf '<section><h2 style="font-size:16px">%s</h2><table><tr><th>%s</th><th>%s</th><th>%s</th><th>%s</th><th>%s</th></tr>\n' \
    "$(_plan_h "$(_t 'Tasks')")" "ID" "$(_plan_h "$(_t 'Task')")" "$(_plan_h "$(_t 'Owner')")" "$(_plan_h "$(_t 'Depends on')")" "$(_plan_h "$(_t 'How it is checked')")"
  for i in "${!P_id[@]}"; do
    printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$(_plan_h "${P_id[i]}")" "$(_plan_h "${P_title[i]}")" \
      "$(_plan_h "$(_plan_short_owner "${P_owner[i]:-—}")")" "$(_plan_h "${P_deps[i]:-—}")" "$(_plan_h "${P_accept[i]:-—}")"
  done
  printf '</table></section></main></body></html>\n'
  } > "$out"
  ok "$(_t 'Plan exported: %s' "$out")"
}

# ── Watchdog: keep the plan honest ──────────────────────────────────────────
# plan_alerts <coordinator> → one line per alert to send to it, at most once an hour per task and
# kind: a task in progress whose owner shows no activity, a task done without evidence, a ready
# task nobody has, two tasks in progress on the same files. Run in a subshell by the watchdog.
plan_alerts() {
  local c=$1 i key now last
  _plan_target "$c" '' || return 0
  [ -f "$PL_DIR/tasks" ] || return 0
  _plan_load
  _plan_now; now=$PL_NOW
  local -A sent=()
  if [ -f "$PL_DIR/.alerted" ]; then
    while IFS=' ' read -r key last; do [ -n "$key" ] && sent[$key]=$last; done < "$PL_DIR/.alerted"
  fi
  local -a out=()
  for i in "${!P_id[@]}"; do
    _plan_flags "$i"
    [ -n "$PF" ] || continue
    local id=${P_id[i]} k msg='' flag
    for flag in $PF; do
    msg=''
    case $flag in
      stale)            k="$id:stale";      _tv msg "[PRAMA] Plan: %s (\"%s\", %s) has shown no activity for over %d min. Check it (prama-agent logs %s) and update the plan." "$id" "${P_title[i]:0:60}" "${P_owner[i]:-—}" "$PRAMA_PLAN_STALE_MIN" "${P_owner[i]:-…}" ;;
      orphan)           k="$id:orphan";     _tv msg "[PRAMA] Plan: %s is in progress but its owner %s is gone. Reassign it (bus assign <session> \"…\" --task %s)." "$id" "${P_owner[i]}" "$id" ;;
      unverified)       k="$id:unverified"; _tv msg "[PRAMA] Plan: %s is done without evidence. Verify it and record how: prama-agent plan set %s evidence=\"<test and result>\"." "$id" "$id" ;;
      overlap:*)        k="$id:overlap";    _tv msg "[PRAMA] Plan: %s and another task in progress touch the same files (%s): expect conflicts; sequence them or split the files." "$id" "${P_scope[i]}" ;;
      ready)
        [ -z "${P_owner[i]}" ] || continue
        (( now - ${P_updated[i]:-now} > PRAMA_PLAN_STALE_MIN * 60 )) || continue
        k="$id:ready"; _tv msg "[PRAMA] Plan: %s (\"%s\") is ready (its dependencies are done) and nobody has it." "$id" "${P_title[i]:0:60}" ;;
    esac
    [ -n "$msg" ] || continue
    (( now - ${sent[$k]:-0} >= 3600 )) || continue
    sent[$k]=$now
    out+=("$msg")
    done
  done
  if (( ${#out[@]} )); then
    { for key in "${!sent[@]}"; do printf '%s %s\n' "$key" "${sent[$key]}"; done; } > "$PL_DIR/.alerted.tmp" \
      && mv -f "$PL_DIR/.alerted.tmp" "$PL_DIR/.alerted"
    printf '%s\n' "${out[@]}"
  fi
  return 0
}

# plan_summary <coordinator> → PLAN_SUM: "r2 · 1/4 done · 2 in progress · 1 review" (empty: no plan)
plan_summary() {
  PLAN_SUM=''
  local c=$1 i nd=0 na=0 ndo=0 nr=0 nb=0 dir
  dir="$(plan_root)/$(slugify "$(state_get "$c" ZONE)")/$(team_name "$c")"
  [ -s "$dir/tasks" ] || return 0
  local PL_DIR=$dir PL_REV
  _plan_load
  for i in "${!P_id[@]}"; do
    case ${P_status[i]} in
      done) nd=$(( nd + 1 )) ;; doing) ndo=$(( ndo + 1 )) ;; review) nr=$(( nr + 1 )) ;; blocked) nb=$(( nb + 1 )) ;;
    esac
    [ "${P_status[i]}" = dropped ] || na=$(( na + 1 ))
  done
  _tv PLAN_SUM 'plan r%d · %d/%d done · %d in progress' "$PL_REV" "$nd" "$na" "$ndo"
  (( nr )) && PLAN_SUM+=$(_t ' · %d to review' "$nr")
  (( nb )) && PLAN_SUM+=$(_t ' · %d blocked' "$nb")
  return 0
}
