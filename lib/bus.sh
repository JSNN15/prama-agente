#!/usr/bin/env bash
# lib/bus.sh — Multi-agent communication bus (teams and the cockpit live in lib/swarm.sh)
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
#
# Public API:
#   subcmd_bus <status|assign|report|broadcast|inbox|watch|clear|swarm-start|help> [args...]
#   resolve_bus_target <target>   → sets BUS_TARGET BUS_TARGET_KIND(session|role|none) BUS_TARGET_NOTE
#   bus_session_state <session>   → prints DEAD|BOT|STANDBY|DAEMON|WORKING|SHELL|READY
#   bus_can_inject <session>      → 0 if it is safe to type into the session
#   sync_bus_state                → compat shim (state is written by the runner; this only GCs)
#
# Security: session state is read with state_get only (never sourced); every tmux call goes
# through tmx with exact targets; events are written only via bus_event.

BUS_ROLES=(coordinator executor reader daemon)

# Kept for callers from v5 (entrypoint/TUI). State files are now written by launch_agent /
# internal_runner, so the only job left is dropping state of sessions that no longer exist.
sync_bus_state() { state_gc 2>/dev/null || true; }

# ── Small helpers ───────────────────────────────────────────────────────────
# _bus_cell <text-with-ansi> <width> → text padded/truncated to exactly <width> columns.
_bus_cell() {
  local text=$1 width=$2 plain vw
  plain=$(strip_ansi "$text")
  vw=$(str_width "$plain")
  if (( vw > width )); then
    text=$(truncate_cols "${plain:0:$(( width * 2 ))}" "$width")
    vw=$(str_width "$text")
  fi
  printf '%s%s%*s' "$text" "$C_OFF" $(( width - vw )) ''
}

# Removes control characters (ANSI injection guard) and flattens newlines.
_bus_clean() {
  local s=${1//[$'\n\r\t']/ }
  printf '%s' "${s//[[:cntrl:]]/}"
}

_bus_short_dir() {
  local d=$1
  [ -n "${HOME:-}" ] && [[ "$d" == "$HOME"* ]] && d="~${d#"$HOME"}"
  printf '%s' "$d"
}

_bus_sender() { printf '%s' "${PRAMA_SESSION:-operator}"; }

# Text input: tui_prompt/tui_confirm when the TUI provides them, plain readline otherwise.
_bus_prompt() {
  local label=$1 var=$2 _v=''
  if declare -F tui_prompt >/dev/null; then
    tui_prompt "$label" "$var"
    return
  fi
  printf '\e[?25h'
  IFS= read -e -r -p " $label " _v || true
  printf -v "$var" '%s' "$_v"
}

_bus_confirm() {
  local q=$1 a=''
  if declare -F tui_confirm >/dev/null; then
    tui_confirm "$q"
    return
  fi
  IFS= read -r -p " $q [s/N] " a || return 1
  [[ "$a" =~ ^[sSyY] ]]
}

_bus_pause() {
  [ -t 0 ] || return 0
  printf '\n %sPulsa cualquier tecla para volver…%s' "$C_MUTED" "$C_OFF"
  IFS= read -rsn1 _ || true
  printf '\n'
}

_bus_notify() { type telegram_notify >/dev/null 2>&1 && telegram_notify "$1" >/dev/null 2>&1; return 0; }

# ── Session inspection ──────────────────────────────────────────────────────
bus_session_state() {
  local s=$1 info dead=0 cmd=''
  info=$(tmx display-message -p -t "=$s:" '#{pane_dead}|#{pane_current_command}' 2>/dev/null) || { printf 'DEAD'; return; }
  IFS='|' read -r dead cmd <<< "$info"
  detect_session_state "$s" "${dead:-0}" "$cmd"
}

# Typing into a session is only safe when an agent is at its prompt or working (never into a
# shell, the supervisor's standby menu, a daemon loop or a dead pane).
bus_can_inject() {
  case "$(bus_session_state "$1")" in
    READY|WORKING) return 0 ;;
    *) return 1 ;;
  esac
}

# Live session with the given role, closest to the sender first: an agent the sender launched,
# then its own team, then its zone, then anyone; among equals the most recently started wins.
# With several teams in a zone, "executor" from a coordinator never lands in another team.
# Sets BUS_ROLE_BEST and BUS_ROLE_COUNT.
_bus_find_role() {
  local role=$1 sender=${2:-operator} s ts rank best_ts='' best_rank=-1 steam='' szone=''
  BUS_ROLE_BEST='' BUS_ROLE_COUNT=0
  if [ "$sender" != operator ]; then
    steam=$(session_team "$sender") || steam=''
    szone=$(state_get "$sender" ZONE)
  fi
  while IFS= read -r s; do
    valid_session_name "$s" || continue
    [ "$s" = "$sender" ] && continue
    [ "$(session_role "$s")" = "$role" ] || continue
    (( BUS_ROLE_COUNT++ ))
    rank=0
    if [ "$sender" != operator ]; then
      if [ "$(state_get "$s" PARENT)" = "$sender" ]; then rank=3
      elif [ -n "$steam" ] && [ "$(session_team "$s" 2>/dev/null)" = "$steam" ]; then rank=2
      elif [ -n "$szone" ] && [ "$(state_get "$s" ZONE)" = "$szone" ]; then rank=1
      fi
    fi
    ts=$(state_get "$s" STARTED_AT)
    if (( rank > best_rank )) || { (( rank == best_rank )) && [[ "$ts" > "$best_ts" ]]; }; then
      BUS_ROLE_BEST=$s best_ts=$ts best_rank=$rank
    fi
  done < <(prama_sessions)
}

# resolve_bus_target <target>
#   exact live session name → that session
#   role name               → live session with that role (most recent if several)
#   otherwise               → no match (caller queues under that name)
# No substring/regex matching. Sets BUS_TARGET, BUS_TARGET_KIND, BUS_TARGET_NOTE.
resolve_bus_target() {
  local target=$1
  BUS_TARGET='' BUS_TARGET_KIND=none BUS_TARGET_NOTE=''
  [ -n "$target" ] || return 1
  if valid_session_name "$target" && ! is_internal_session "$target" && tmx_has "$target"; then
    BUS_TARGET=$target BUS_TARGET_KIND=session
    return 0
  fi
  if is_in "$target" "${BUS_ROLES[@]}"; then
    _bus_find_role "$target" "$(_bus_sender)"
    if [ -n "$BUS_ROLE_BEST" ]; then
      BUS_TARGET=$BUS_ROLE_BEST BUS_TARGET_KIND=role
      (( BUS_ROLE_COUNT > 1 )) && BUS_TARGET_NOTE="Hay $BUS_ROLE_COUNT sesiones con rol '$target'; se eligió la más reciente: $BUS_TARGET"
      return 0
    fi
  fi
  return 1
}

# ── Event log rendering ─────────────────────────────────────────────────────
# Fallback JSON string extractor for our own events.jsonl format (used when jq is missing).
_bus_json_field() {
  local line=$1 key=$2 rest val='' chunk bs
  if [[ "$line" == *"\"$key\":\""* ]]; then
    rest=${line#*\""$key"\":\"}
    while [[ "$rest" == *'"'* ]]; do
      chunk=${rest%%\"*}
      rest=${rest#*\"}
      val+=$chunk
      bs=${chunk##*[!\\]}
      [ "$chunk" = "$bs" ] && bs=$chunk         # chunk made only of backslashes
      if (( ${#bs} % 2 == 0 )); then break; fi
      val+='"'
    done
    val=${val//\\\\/$'\x01'}
    val=${val//\\\"/\"}
    val=${val//\\n/ }; val=${val//\\r/ }; val=${val//\\t/ }
    val=${val//$'\x01'/\\}
    printf '%s' "$val"
  elif [[ "$line" =~ \"$key\":(-?[0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Streams "ts US event US from US to US text US rc" records (US = \x1f) from JSON lines on stdin.
_bus_event_records() {
  if command -v jq >/dev/null 2>&1; then
    jq --unbuffered -R -r 'fromjson? | select(type == "object")
      | [.ts, .event, .from, .to, .text, .rc]
      | map(if . == null then "" else tostring end | gsub("[\u0000-\u001f\u007f]"; " "))
      | join("\u001f")' 2>/dev/null
  else
    local line
    while IFS= read -r line; do
      [[ "$line" == "{"*"}" ]] || continue
      printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
        "$(_bus_clean "$(_bus_json_field "$line" ts)")" "$(_bus_clean "$(_bus_json_field "$line" event)")" \
        "$(_bus_clean "$(_bus_json_field "$line" from)")" "$(_bus_clean "$(_bus_json_field "$line" to)")" \
        "$(_bus_clean "$(_bus_json_field "$line" text)")" "$(_bus_clean "$(_bus_json_field "$line" rc)")"
    done
  fi
}

# _bus_render_event <ts> <event> <from> <to> <text> <rc> <width> → one colored line (no newline)
_bus_render_event() {
  local ts=$1 ev=$2 from=$3 to=$4 text=$5 rc=$6 width=$7 col sym
  case "$ev" in
    assign)    col=$C_NEON;   sym='▸' ;;
    queued)    col=$C_BRASS;  sym='◷' ;;
    report)    col=$C_LIVE;   sym='✔' ;;
    broadcast) col=$C_PURP;   sym='◉' ;;
    started)   col=$C_INDIGO; sym='▶' ;;
    completed) if [ -n "$rc" ] && [ "$rc" != 0 ]; then col=$C_ERR; sym='✖'; else col=$C_LIVE; sym='■'; fi ;;
    stopped)   col=$C_MUTED;  sym='□' ;;
    *)         col=$C_MUTED;  sym='•' ;;
  esac
  local hhmm=${ts:11:8}
  [ -n "$hhmm" ] || hhmm='--:--:--'
  local fw=16
  (( width < 70 )) && fw=11
  local route
  route="$(_bus_cell "$from" "$fw") ${C_MUTED}→${C_OFF} $(_bus_cell "${to:-*}" "$fw")"
  local label=$ev
  [ "$ev" = completed ] && [ -n "$rc" ] && label="$ev rc=$rc"
  local head_w=$(( 8 + 1 + 2 + 15 + 1 + fw * 2 + 3 + 1 ))
  local tw=$(( width - head_w ))
  (( tw < 8 )) && tw=8
  printf '%s%s%s %s%s %s%s %s %s' "$C_MUTED" "$hhmm" "$C_OFF" "$col" "$sym" "$(_bus_cell "$label" 15)" "$C_OFF" \
    "$route" "$(truncate_cols "${text:0:$(( tw * 2 ))}" "$tw")"
}

# ── Subcommand: bus ─────────────────────────────────────────────────────────
_bus_usage() {
  cat <<EOF
Uso: prama-agent bus <acción>
  status [N]                     Agentes vivos (rol, estado, cola) y últimos N eventos (def. 8)
  assign <sesión|rol> "<tarea>"  Envía una tarea (rol: coordinator|executor|reader|daemon)
  report "<resumen>"             Registra un resultado y avisa al coordinador
  broadcast "<mensaje>"          Envía un mensaje a todos los agentes listos (daemons: cola)
  inbox [sesión] [--pop]         Lista (o extrae) las tareas pendientes en una cola
  watch                          Vista en vivo de los eventos del bus (Ctrl-C para salir)
  clear [-y|--yes]               Vacía el registro de eventos y todas las colas
  swarm-start [zona] [coord] [exec]  (compatibilidad) usa: prama-agent swarm <zona> --workers agy:3
EOF
}

subcmd_bus() {
  local action=${1:-status}
  (( $# )) && shift
  case "$action" in
    status|ls)            _bus_status "$@" ;;
    assign|send)          _bus_assign "$@" ;;
    report)               _bus_report "$@" ;;
    broadcast)            _bus_broadcast "$@" ;;
    inbox|queue)          _bus_inbox "$@" ;;
    watch|tail)           _bus_watch "$@" ;;
    clear)                _bus_clear "$@" ;;
    swarm-start|swarm)    _bus_swarm_start "$@" ;;
    help|-h|--help)       _bus_usage ;;
    *) _bus_usage >&2; die "Acción de bus desconocida: '$action'" ;;
  esac
}

_bus_status() {
  local n=${1:-8}
  [[ "$n" =~ ^[0-9]+$ ]] || n=8
  state_gc 2>/dev/null || true
  refresh_dimensions
  local inner=$(( W - 4 )) bc=$C_BORDER_HI
  local nw=24 rw=15 sw=11 qw=5
  if (( IS_COMPACT )); then nw=18 rw=13 sw=10 qw=4; fi
  local dw=$(( inner - nw - rw - sw - qw - 4 ))

  printf '\n'
  box_top "☍ BUS MULTI-AGENTE" "$(date +%H:%M:%S)" "$bc"
  if (( dw >= 6 )); then
    box_row "$bc" "${C_MUTED}$(_bus_cell SESIÓN "$nw") $(_bus_cell ROL "$rw") $(_bus_cell ESTADO "$sw") $(_bus_cell COLA "$qw") DIRECTORIO${C_OFF}"
  else
    box_row "$bc" "${C_MUTED}$(_bus_cell SESIÓN "$nw") $(_bus_cell ROL "$rw") $(_bus_cell ESTADO "$sw") COLA${C_OFF}"
  fi
  box_sep "$bc"

  local s count=0 skipped=0 role st q dir line
  while IFS= read -r s; do
    if ! valid_session_name "$s"; then (( skipped++ )); continue; fi
    (( count++ ))
    role=$(session_role "$s")
    st=$(bus_session_state "$s")
    q=$(queue_len "$s")
    dir=$(state_get "$s" TARGET_DIR)
    [ -n "$dir" ] || dir=$(tmx display-message -p -t "=$s:" '#{pane_current_path}' 2>/dev/null)
    local qtxt="$q"
    (( q > 0 )) && qtxt="${C_BRASS}${C_BOLD}$q${C_OFF}"
    line="${C_BOLD}$(_bus_cell "$s" "$nw")${C_OFF} $(_bus_cell "$(role_badge "$role")" "$rw") $(_bus_cell "$(state_badge "$st")" "$sw") $(_bus_cell "$qtxt" "$qw")"
    (( dw >= 6 )) && line+=" ${C_MUTED}$(_bus_cell "$(_bus_short_dir "$dir")" "$dw")${C_OFF}"
    box_row "$bc" "$line"
  done < <(prama_sessions)
  (( count == 0 )) && box_row "$bc" "${C_MUTED}(No hay agentes vivos en el servidor prama)${C_OFF}"
  (( skipped > 0 )) && box_row "$bc" "${C_BRASS}▲ $skipped sesión(es) con nombre no válido ignoradas${C_OFF}"

  local qd
  qd=$(queue_len daemon)
  (( qd > 0 )) && box_row "$bc" "${C_PURP}♺${C_OFF} Cola compartida de daemons: ${C_BRASS}${C_BOLD}$qd${C_OFF} tarea(s)"
  local orphan_q='' d name
  for d in "$PRAMA_BUS_DIR"/inbox/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    [ "$name" = daemon ] && continue
    tmx_has "$name" && continue
    (( $(queue_len "$name") > 0 )) && orphan_q+="$name($(queue_len "$name")) "
  done
  [ -n "$orphan_q" ] && box_row "$bc" "${C_BRASS}◷${C_OFF} Colas sin sesión viva: ${C_MUTED}$(_bus_clean "$orphan_q")${C_OFF}"

  box_sep "$bc"
  box_row "$bc" "${C_LIVE}${C_BOLD}▸ ÚLTIMOS EVENTOS${C_OFF}"
  local ev_file="$PRAMA_BUS_DIR/events.jsonl" shown=0
  local ts ev from to text rc
  if [ -s "$ev_file" ] && (( n > 0 )); then
    while IFS=$'\x1f' read -r ts ev from to text rc; do
      box_row "$bc" "$(_bus_render_event "$ts" "$ev" "$from" "$to" "$text" "$rc" "$inner")"
      (( shown++ ))
    done < <(tail -n "$n" "$ev_file" | _bus_event_records)
  fi
  (( shown == 0 )) && box_row "$bc" "${C_MUTED}(Sin eventos todavía)${C_OFF}"
  box_bottom "bus assign <sesión|rol> \"<tarea>\" · bus watch" "$bc"
  printf '\n'
}

_bus_assign() {
  local target=${1:-}
  (( $# )) && shift
  local msg="$*"
  [ -n "$target" ] && [ -n "$msg" ] || die "Uso: prama-agent bus assign <sesión|rol> \"<instrucción>\""
  local sender
  sender=$(_bus_sender)

  # Shared daemon queue: any daemon worker picks it up.
  if [ "$target" = daemon ]; then
    queue_push daemon "$msg"
    bus_event queued "$sender" daemon "$msg"
    ok "Tarea encolada en la cola compartida de daemons ($(queue_len daemon) pendiente(s))."
    _bus_notify "📥 [BUS] $sender → daemon (cola): $msg"
    return 0
  fi

  if ! resolve_bus_target "$target"; then
    if ! valid_session_name "$target" || is_internal_session "$target"; then
      die "Destino no válido: '$target' (usa un nombre de sesión exacto o un rol: ${BUS_ROLES[*]})"
    fi
    queue_push "$target" "$msg"
    bus_event queued "$sender" "$target" "$msg"
    warn "No hay ninguna sesión viva llamada '$target' (ni con ese rol). Tarea guardada en su cola."
    return 0
  fi
  [ -n "$BUS_TARGET_NOTE" ] && info_msg "$BUS_TARGET_NOTE"
  local dest=$BUS_TARGET

  if [ "$(session_role "$dest")" = daemon ]; then
    queue_push "$dest" "$msg"
    bus_event queued "$sender" "$dest" "$msg"
    ok "Tarea encolada para el daemon '$dest' ($(queue_len "$dest") pendiente(s))."
    _bus_notify "📥 [BUS] $sender → $dest (cola): $msg"
    return 0
  fi

  if bus_can_inject "$dest"; then
    tmx_send "$dest" "[TAREA DE $sender]: ${msg//$'\n'/ }" || die "No se pudo escribir en '$dest'."
    bus_event assign "$sender" "$dest" "$msg"
    ok "Tarea entregada en vivo a '$dest'."
    _bus_notify "📨 [BUS] $sender → $dest: $msg"
  else
    queue_push "$dest" "$msg"
    bus_event queued "$sender" "$dest" "$msg"
    warn "'$dest' no está listo para recibir texto ($(bus_session_state "$dest")); tarea guardada en su cola."
  fi
}

_bus_report() {
  local msg="$*"
  [ -n "$msg" ] || die "Uso: prama-agent bus report \"<resumen del resultado>\""
  local sender coord=''
  sender=$(_bus_sender)
  # The sender's own coordinator (its team); without a team, the closest coordinator.
  if [ "$sender" != operator ] && coord=$(session_team "$sender") && [ "$coord" != "$sender" ]; then :
  else
    coord=''
    resolve_bus_target coordinator && [ "$BUS_TARGET_KIND" = role ] && coord=$BUS_TARGET
  fi
  bus_event report "$sender" "${coord:-coordinator}" "$msg"
  if [ -n "$coord" ] && [ "$coord" != "$sender" ]; then
    if bus_can_inject "$coord"; then
      tmx_send "$coord" "[REPORTE DE $sender]: ${msg//$'\n'/ }" || true
      ok "Reporte registrado y entregado al coordinador ($coord)."
    else
      queue_push "$coord" "[REPORTE DE $sender]: $msg"
      ok "Reporte registrado; el coordinador ($coord) no está listo, quedó en su cola."
    fi
  else
    ok "Reporte registrado en el bus."
  fi
  _bus_notify "✅ [REPORTE DE $sender]: $msg"
}

_bus_broadcast() {
  local msg="$*"
  [ -n "$msg" ] || die "Uso: prama-agent bus broadcast \"<mensaje>\""
  local sender s st sent=0 queued=0 skipped=()
  sender=$(_bus_sender)
  while IFS= read -r s; do
    valid_session_name "$s" || continue
    [ "$s" = "$sender" ] && continue
    if [ "$(session_role "$s")" = daemon ]; then
      queue_push "$s" "$msg"; (( queued++ ))
      continue
    fi
    st=$(bus_session_state "$s")
    case "$st" in
      READY|WORKING)
        if tmx_send "$s" "[BROADCAST DE $sender]: ${msg//$'\n'/ }"; then (( sent++ )); else skipped+=("$s:ERROR"); fi ;;
      *) skipped+=("$s:$st") ;;
    esac
  done < <(prama_sessions)
  bus_event broadcast "$sender" '*' "$msg"
  ok "Broadcast: $sent entregado(s) en vivo, $queued encolado(s) a daemons."
  (( ${#skipped[@]} )) && info_msg "Omitidas (no listas para recibir texto): ${skipped[*]}"
  return 0
}

_bus_inbox() {
  local target='' pop=0 a
  for a in "$@"; do
    case "$a" in
      --pop) pop=1 ;;
      *) target=$a ;;
    esac
  done
  [ -n "$target" ] || target=${PRAMA_SESSION:-}
  [ -n "$target" ] || die "Uso: prama-agent bus inbox <sesión|daemon> [--pop]"
  valid_session_name "$target" || die "Nombre de cola no válido: '$target'"
  if (( pop )); then
    queue_pop "$target" || { info_msg "La cola de '$target' está vacía."; return 1; }
    printf '\n'
    return 0
  fi
  local d f i=0
  d=$(queue_dir "$target")
  refresh_dimensions
  box_top "◷ COLA DE $target" "$(queue_len "$target") pendiente(s)" "$C_BRASS"
  for f in "$d"/new/*.task; do
    [ -f "$f" ] || continue
    (( i++ ))
    box_row "$C_BRASS" "${C_BOLD}$i.${C_OFF} $(_bus_clean "$(head -c 2000 "$f")")"
  done
  (( i == 0 )) && box_row "$C_BRASS" "${C_MUTED}(vacía)${C_OFF}"
  box_bottom "bus inbox $target --pop  extrae la más antigua" "$C_BRASS"
}

_bus_watch() {
  local ev_file="$PRAMA_BUS_DIR/events.jsonl"
  [ -f "$ev_file" ] || : >> "$ev_file"
  refresh_dimensions
  printf ' %s☍ BUS EN VIVO%s %s· Ctrl-C para salir%s\n' "$C_NEON$C_BOLD" "$C_OFF" "$C_MUTED" "$C_OFF"
  local old_trap
  old_trap=$(trap -p INT)
  trap ':' INT
  (
    trap 'exit 0' INT
    tail -n 15 -F "$ev_file" 2>/dev/null | _bus_event_records | {
      trap 'exit 0' INT
      while IFS=$'\x1f' read -r ts ev from to text rc; do
        refresh_dimensions
        printf ' %s\n' "$(_bus_render_event "$ts" "$ev" "$from" "$to" "$text" "$rc" $(( COLS - 2 )))"
      done
    }
  )
  if [ -n "$old_trap" ]; then eval "$old_trap"; else trap - INT; fi
  printf '\n'
  return 0
}

_bus_clear() {
  local yes=0 a
  for a in "$@"; do
    case "$a" in -y|--yes) yes=1 ;; esac
  done
  if (( ! yes )); then
    [ -t 0 ] || die "Sin terminal interactiva: usa 'prama-agent bus clear --yes' para confirmar."
    _bus_confirm "¿Vaciar el registro de eventos y TODAS las colas de tareas del bus?" \
      || { info_msg "Cancelado."; return 0; }
  fi
  local ev_file="$PRAMA_BUS_DIR/events.jsonl"
  {
    command -v flock >/dev/null 2>&1 && flock 9
    : > "$ev_file"
  } 9>>"$ev_file"
  queue_clear
  ok "Registro de eventos y colas del bus vaciados."
}

# Validates/launches a coordinator + executor pair. Prints the two session names.
# v5 compatibility: `bus swarm-start [zone] [coord] [exec]` → `swarm <zone> --coord C --workers E:1`.
_bus_swarm_start() {
  local zone=${1:-${ZONES[0]:-}} coord=${2:-claude} exec_a=${3:-agy}
  _swarm_start "$zone" --coord "$coord" --workers "$exec_a:1" --no-open
}
