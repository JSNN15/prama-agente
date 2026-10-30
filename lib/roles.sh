#!/usr/bin/env bash
# lib/roles.sh — Role Profiles (Coordinator, Executor, Reader, Daemon) & In-Pane Supervisor
# Licensed under the Apache License, Version 2.0
#
# Public API (see docs/ARCHITECTURE.md):
#   role_badge <role>
#   build_role_system_prompt <role> <session> <zone>
#   daemon_perm_flags <agent> <perm_mode>              → sets DAEMON_PERM_FLAGS=()
#   build_daemon_turn <session> <perm_mode> <task> <zone> -- <CMD...>  → sets DAEMON_TURN=()
#   internal_runner <session> <target_dir> <profile> <oneshot 0|1> <role> <daemon_interval> \
#                   <perm_mode yolo|plan|ask> -- <agent CMD array...>

AVAILABLE_ROLES=(executor coordinator reader daemon)

role_badge() {
  case "${1:-executor}" in
    coordinator) printf '❖ COORDINATOR' ;;
    executor)    printf '✦ EXECUTOR' ;;
    reader)      printf '◉ READER (RO)' ;;
    daemon)      printf '♺ DAEMON' ;;
    *)           printf '⚙ %s' "$1" ;;
  esac
}

# Builds the coordination system prompt injected into agents so they can talk to each other.
# Session names are validated by core (SESSION_NAME_RE); the zone is free text (directory
# basename), so non-printable characters are stripped before it lands in the prompt.
build_role_system_prompt() {
  local role=$1 session_name=$2 zone=$3
  session_name=${session_name//[^A-Za-z0-9_-]/}
  zone=${zone//[^[:print:]]/}
  local bus_help
  bus_help=$(cat <<EOF
Comandos del bus multi-agente (ejecútalos con tu herramienta Bash):
- Ver agentes vivos, roles, colas y últimos eventos: prama-agent bus status
- Asignar una tarea a una sesión exacta o a un rol:  prama-agent bus assign <sesión|coordinator|executor|reader|daemon> "<instrucción>"
- Reportar un resultado al coordinador:              prama-agent bus report "<resumen>"
- Ver tareas pendientes en tu cola:                  prama-agent bus inbox $session_name
- Leer la terminal de otro agente:                   prama-agent logs <sesión> 80
EOF
)
  local agents_list=${AGENTS[*]} models_help
  agents_list=${agents_list// /|}
  models_help="Modelos: claude → opus | sonnet | haiku (o un id completo); agy → ids de 'prama-agent fleet models agy'
(p. ej. gemini-3.8-flash-high). Usa modelos rápidos/baratos para tareas mecánicas (tests, refactors
acotados, documentación) y los más capaces para diseño y cambios delicados."
  if is_in opencode "${AGENTS[@]}"; then
    models_help+="
opencode (experimental) → openrouter/<proveedor>/<modelo> (p. ej. openrouter/qwen/qwen3-coder:free);
lista con: prama-agent fleet models opencode."
  fi
  case "$role" in
    coordinator)
      cat <<EOF
[PRAMA-SWARM ROLE: COORDINATOR | session=$session_name | zone=$zone]
Eres el Agente COORDINADOR / ARQUITECTO en la zona '$zone'.
Tu misión es planificar, dividir el trabajo, revisar código y coordinar a otros agentes activos.
Delega con 'prama-agent bus assign', revisa el progreso con 'prama-agent bus status' y
'prama-agent logs <sesión>'. Los reportes de otros agentes te llegarán como "[REPORTE DE <sesión>]: …".
Las alertas de la flota llegan como "[ALERTA PRAMA] …" (agente bloqueado por login, cuota, crédito,
modelo, o detenido) y cuando una cuenta pasa el ${PRAMA_QUOTA_WARN:-90}% de su cuota (ventana 5h o 7d): decide si
reiniciarlo, cambiarle el modelo, reasignar su tarea, repartir a otros agentes/modelos o avisar al humano.
$bus_help

Gestión de la flota (tú administras a tus agentes; todo devuelve JSON con --json):
- Estado completo (estado, bloqueo y motivo, modelo, preset, cola, cuota % y reinicio): prama-agent fleet status --json
- Agentes disponibles y presets (perfiles con skills):              prama-agent fleet presets
- Lanzar un agente extra:  prama-agent fleet spawn <$agents_list> $zone [--role executor|reader] [--model M] [--preset P] [--name N] [--worktree rama] [--task "instrucción inicial"]
- Cambiar el modelo (reinicia en el mismo panel y conserva la conversación): prama-agent fleet model <sesión> <modelo>
- Editar configuración (modelo, esfuerzo, preset, permisos):  prama-agent fleet edit <sesión> [--model M] [--effort E] [--preset P]
- Reiniciar un agente (p. ej. tras un error):                prama-agent fleet restart <sesión>
- Cerrar un agente que ya no necesitas:                      prama-agent fleet kill <sesión>
$models_help
Cierra los agentes extra al terminar.
Límite de agentes simultáneos: ${PRAMA_FLEET_MAX:-8}.
EOF
      ;;
    executor)
      cat <<EOF
[PRAMA-SWARM ROLE: EXECUTOR | session=$session_name | zone=$zone]
Eres un Agente EJECUTOR en la zona '$zone'.
Tu misión es implementar código, ejecutar tests y verificar que todo compile sin errores.
Las tareas te llegarán como "[TAREA DE <sesión>]: …". Al terminar, reporta tu resultado con:
  prama-agent bus report "<resumen conciso de cambios y tests>"
$bus_help
EOF
      ;;
    reader)
      cat <<EOF
[PRAMA-SWARM ROLE: READER (READ-ONLY) | session=$session_name | zone=$zone]
Eres un Agente LECTOR / AUDITOR en modo de SOLO LECTURA estricto en la zona '$zone'.
NO modifiques archivos ni ejecutes comandos destructivos. Analiza arquitectura, logs y bugs,
y reporta tus hallazgos con:
  prama-agent bus report "<hallazgos>"
$bus_help
EOF
      ;;
    daemon)
      cat <<EOF
[PRAMA-SWARM ROLE: DAEMON WORKER | session=$session_name | zone=$zone]
Eres un Agente ESCLAVO / DAEMON autónomo en la zona '$zone', ejecutado en modo headless.
Procesa la tarea solicitada de principio a fin sin pedir confirmación interactiva y termina con
un resumen claro (el supervisor lo registra en el bus). Si la tarea lo pide, puedes reportar con:
  prama-agent bus report "<resumen>"
$bus_help
EOF
      ;;
  esac
}

# ── Daemon (headless) turn construction ─────────────────────────────────────
# daemon_perm_flags <agent> <perm_mode> → DAEMON_PERM_FLAGS=() (same matrix as build_agent_command)
daemon_perm_flags() {
  local agent=$1 mode=$2
  DAEMON_PERM_FLAGS=()
  case "$mode" in
    yolo|skip)
      case "$agent" in
        claude|agy) DAEMON_PERM_FLAGS=(--dangerously-skip-permissions) ;;
        opencode)   DAEMON_PERM_FLAGS=(--auto) ;;
      esac
      ;;
    plan|readonly)
      case "$agent" in
        claude) DAEMON_PERM_FLAGS=(--permission-mode plan) ;;
        agy)    DAEMON_PERM_FLAGS=(--mode plan) ;;
      esac
      ;;
  esac
}

# build_daemon_turn <session> <perm_mode> <task> <zone> -- <CMD...>  → DAEMON_TURN=()
#
# Strategy: reuse the interactive CMD built by build_agent_command (it already carries the
# permission flags, role prompt and user pass-through args) and turn it into a headless turn:
#   CMD[0] -p "<task>" <CMD[1..] without --remote-control [value]>
# Missing pieces are added defensively: the permission flags for perm_mode (only if their first
# token is absent) and, for claude, the daemon role prompt (only if no
# --append-system-prompt is present). opencode's headless form is `opencode run [--auto] "<task>"`
# (model, permissions and instructions travel in OPENCODE_CONFIG_CONTENT).
build_daemon_turn() {
  local session=$1 perm=$2 task=$3 zone=$4
  shift 4
  [ "${1:-}" = "--" ] && shift
  local bin=${1:-claude}
  (( $# )) && shift
  local agent=${bin##*/}
  local tail=() a skip_next=0 have_prompt=0
  for a in "$@"; do
    if (( skip_next )); then
      skip_next=0
      # claude: --remote-control <session-name>; never swallow a flag
      [[ "$a" != -* ]] && [ "$a" = "$session" ] && continue
    fi
    case "$a" in
      --remote-control) skip_next=1; continue ;;
      --remote-control=*) continue ;;
      --continue) [ "$agent" = opencode ] && continue ;;
      --append-system-prompt|--append-system-prompt=*) have_prompt=1 ;;
    esac
    tail+=("$a")
  done
  daemon_perm_flags "$agent" "$perm"
  if (( ${#DAEMON_PERM_FLAGS[@]} )) && ! is_in "${DAEMON_PERM_FLAGS[0]}" "${tail[@]}"; then
    tail=("${DAEMON_PERM_FLAGS[@]}" "${tail[@]}")
  fi
  if (( ! have_prompt )); then
    case "$agent" in
      claude) tail+=(--append-system-prompt "$(build_role_system_prompt daemon "$session" "$zone")") ;;
    esac
  fi
  if [ "$agent" = opencode ]; then
    DAEMON_TURN=("$bin" run ${tail[@]+"${tail[@]}"} "$task")
  else
    DAEMON_TURN=("$bin" -p "$task" ${tail[@]+"${tail[@]}"})
  fi
}

# ── Supervisor helpers ──────────────────────────────────────────────────────
_runner_branch() { git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '—'; }

_runner_title() { tmx select-pane -t "=$1:" -T "$2" 2>/dev/null || true; }

_runner_cleanup() {
  [ -n "${_RUNNER_SESSION:-}" ] && state_remove "$_RUNNER_SESSION"
}

# Shows an error inside the pane and waits for a key so the message is not lost when the pane closes.
_runner_fatal() {
  refresh_dimensions
  printf '\n'
  box_top "✖ NO SE PUDO INICIAR EL AGENTE" "${_RUNNER_SESSION:-}" "$C_ERR"
  box_row "$C_ERR" "$1"
  box_bottom "Pulsa una tecla para cerrar" "$C_ERR"
  [ -t 0 ] && { IFS= read -r -n1 -t 300 _ || true; }
  _runner_cleanup
  exit 1
}

# Compact one-line daemon heartbeat. Contains the PRAMA_DAEMON marker used by detect_session_state.
_daemon_heartbeat() {
  local session=$1 cycle=$2 left=$3 eol=${4:-}
  local qs qr cr='' clr='' next
  qs=$(queue_len "$session"); qr=$(queue_len daemon)
  [ -t 1 ] && { cr=$'\r'; clr=$'\e[K'; }
  if [ "$left" = oneshot ]; then next='oneshot: fin'; else printf -v next 'próximo en %3ss' "$left"; fi
  printf '%s %s♺%s %s%s%s · ciclo #%d · cola %s%s%s+%s · %s %sPRAMA_DAEMON%s%s%s' \
    "$cr" "$C_PURP" "$C_OFF" "$C_MUTED" "$(date +%H:%M:%S)" "$C_OFF" "$cycle" \
    "$C_BOLD" "$qs" "$C_OFF" "$qr" "$next" "$C_DIM" "$C_OFF" "$clr" "$eol"
}

# ── Daemon loop ─────────────────────────────────────────────────────────────
_runner_daemon_loop() {
  local session=$1 target_dir=$2 oneshot=$3 interval=$4 perm=$5
  shift 5
  local agent=${1##*/} zone
  zone=$(state_get "$session" ZONE "$(basename "$target_dir")")
  [[ "$interval" =~ ^[0-9]+$ ]] && (( interval > 0 )) || interval=60

  refresh_dimensions
  box_top "♺ DAEMON // $session" "${agent} · ${perm^^}" "$C_PURP"
  box_row "$C_PURP" "Zona: ${C_NEON}$target_dir${C_OFF} · Rama: ${C_NEON}⎇ $(_runner_branch "$target_dir")${C_OFF} · Intervalo: ${interval}s"
  box_row "$C_PURP" "Colas: ${C_BOLD}$session${C_OFF} → ${C_BOLD}daemon${C_OFF} (compartida)${PRAMA_DAEMON_TASK:+ → tarea recurrente}"
  if [ "$perm" = "ask" ] || [ "$perm" = "safe" ]; then
    box_row "$C_PURP" "${C_BRASS}▲ Modo ASK en headless: no hay quien apruebe, las herramientas que${C_OFF}"
    box_row "$C_PURP" "${C_BRASS}  requieran permiso serán DENEGADAS. Usa --plan o --yolo si lo necesitas.${C_OFF}"
  fi
  box_bottom "prama-agent bus assign $session \"<tarea>\"" "$C_PURP"

  local cycle=0 task src rc
  while true; do
    (( cycle++ ))
    if [ "$(state_get "$session" RESTART_REQ)" = 1 ]; then
      state_set "$session" RESTART_REQ=
      compose_session_cmd "$session"
      set -- "${CMD[@]}"
      printf '\n %s↻ Reconfigurado%s %s\n' "$C_NEON" "$C_OFF" "${AGENT_MODEL:+modelo $AGENT_MODEL}"
    fi
    task='' src=''
    if task=$(queue_pop "$session"); then src=$session
    elif task=$(queue_pop daemon); then src=daemon
    elif [ -n "${PRAMA_DAEMON_TASK:-}" ]; then task=$PRAMA_DAEMON_TASK; src=recurrente
    else task=''
    fi

    if [ -n "$task" ]; then
      printf '\n %s▸ TAREA%s %s(%s · %s)%s %s\n\n' "$C_LIVE$C_BOLD" "$C_OFF" "$C_MUTED" "$src" "$(date +%H:%M:%S)" "$C_OFF" \
        "$(truncate_cols "${task//$'\n'/ }" $(( W - 20 )))"
      bus_event started "$session" "$src" "$task"
      build_daemon_turn "$session" "$perm" "$task" "$zone" -- "$@"
      rc=0
      "${DAEMON_TURN[@]}" || rc=$?
      bus_event completed "$session" "$src" "$task" "$rc"
      if (( rc == 0 )); then
        printf '\n %s✔ completada%s %s(rc=0)%s\n' "$C_LIVE" "$C_OFF" "$C_MUTED" "$C_OFF"
      else
        printf '\n %s✖ falló%s %s(rc=%d)%s\n' "$C_ERR" "$C_OFF" "$C_MUTED" "$rc" "$C_OFF"
      fi
    fi

    if (( oneshot )); then
      _daemon_heartbeat "$session" "$cycle" oneshot $'\n'
      return "${rc:-0}"
    fi
    # Drain queued work back-to-back; recurring tasks always wait for the interval.
    if [ -n "$task" ] && [ "$src" != recurrente ] \
       && (( $(queue_len "$session") + $(queue_len daemon) > 0 )); then
      continue
    fi

    local left=$interval
    if [ -t 1 ]; then
      while (( left > 0 )); do
        _daemon_heartbeat "$session" "$cycle" "$left"
        sleep 1
        (( left-- ))
        (( $(queue_len "$session") + $(queue_len daemon) > 0 )) && break
      done
      printf '\n'
    else
      _daemon_heartbeat "$session" "$cycle" "$left" $'\n'
      while (( left > 0 )); do
        sleep 1; (( left-- ))
        (( $(queue_len "$session") + $(queue_len daemon) > 0 )) && break
      done
    fi
  done
}

# Exports what the agent needs inside the pane: preset values and per-agent runtime env.
_runner_env() {
  local s=$1 agent=$2 perm=$3 role=$4 zone=$5 rp=''
  PRESET=$(state_get "$s" PRESET) AGENT_MODEL=$(state_get "$s" MODEL)
  [ -n "$PRESET" ] && preset_load "$PRESET" >/dev/null 2>&1
  [ "$role" != executor ] && rp=$(build_role_system_prompt "$role" "$s" "$zone")
  agent_runtime_env "$agent" "$s" "$perm" "$rp"
}

# ── Internal Supervisor Runner (executed inside the tmux pane) ──────────────
# internal_runner <session> <target_dir> <profile> <oneshot 0|1> <role> <daemon_interval> \
#                 <perm_mode yolo|plan|ask> -- <agent CMD array...>
internal_runner() {
  (( $# >= 7 )) || die "internal_runner: argumentos insuficientes"
  local session_name=$1 target_dir=$2 profile=${3:-default} oneshot=${4:-0}
  local role=${5:-executor} daemon_interval=${6:-60} perm_mode=${7:-ask}
  shift 7
  [ "${1:-}" = "--" ] && shift
  (( $# )) || die "internal_runner: falta el comando del agente tras '--'"
  [ -n "$session_name" ] || die "internal_runner: sesión vacía"
  [[ "$oneshot" =~ ^[01]$ ]] || oneshot=0

  # Defensive: the entrypoint is expected to call prama_init first (config + providers.env).
  (( ${#ZONES[@]} )) || prama_init

  _RUNNER_SESSION=$session_name
  trap '_runner_cleanup' EXIT
  trap '_runner_cleanup; exit 130' INT TERM HUP

  type restore_locale >/dev/null 2>&1 && restore_locale
  cd "$target_dir" 2>/dev/null || _runner_fatal "El directorio de trabajo no existe: $target_dir"
  export PRAMA_SESSION="$session_name" PRAMA_ROLE="$role"
  local sf; sf=$(state_file "$session_name")
  export PRAMA_SL_CACHE="${sf%.env}.sl"   # status line throttle cache (see bin/prama-agent)
  # IS_SANDBOX lets claude accept --dangerously-skip-permissions as root; only for YOLO.
  if [ "$perm_mode" = "yolo" ]; then export IS_SANDBOX=1; else unset IS_SANDBOX; fi

  # Provider secrets are loaded here (never passed through tmux -e / argv). Validate in a subshell
  # first so a missing key shows an error box instead of silently closing the pane.
  local perr
  if ! perr=$( (apply_provider_profile "$profile") 2>&1 ); then
    _runner_fatal "Perfil '$profile': $(strip_ansi "${perr//$'\n'/ }")"
  fi
  apply_provider_profile "$profile"

  local agent=${1##*/} zone
  zone=$(state_get "$session_name" ZONE "$(basename "$target_dir")")   # written by launch_agent
  # Merge: launch_agent already saved the full spec (model, preset, conversation id…).
  state_set "$session_name" "ROLE=$role" "PROFILE=$profile" "PERM=$perm_mode" "ZONE=$zone" \
    "TARGET_DIR=$target_dir" "AGENT=$agent" "STARTED_AT=$(date -Iseconds)"
  rm -f "$(health_file "$session_name")" 2>/dev/null
  _runner_env "$session_name" "$agent" "$perm_mode" "$role" "$zone"
  _runner_title "$session_name" "$(role_badge "$role") · $agent · $session_name"

  if [ "$role" = "daemon" ]; then
    local drc=0
    _runner_daemon_loop "$session_name" "$target_dir" "$oneshot" "$daemon_interval" "$perm_mode" "$@" || drc=$?
    exit "$drc"
  fi

  # ── Standard interactive / supervised agent loop ──────────────────────────
  local run_count=0 exit_code
  while true; do
    (( run_count++ ))
    # In-place restart: same pane (the scrollback stays), new flags, same conversation.
    if [ "$(state_get "$session_name" RESTART_REQ)" = 1 ]; then
      state_set "$session_name" RESTART_REQ=
      compose_session_cmd "$session_name"
      set -- "${CMD[@]}"
      profile=$(state_get "$session_name" PROFILE default) perm_mode=$(state_get "$session_name" PERM "$perm_mode")
      if perr=$( (apply_provider_profile "$profile") 2>&1 ); then apply_provider_profile "$profile"
      else printf ' %s✖ Perfil %s: %s%s\n' "$C_ERR" "$profile" "$(strip_ansi "${perr//$'\n'/ }")" "$C_OFF"; fi
      if [ "$perm_mode" = "yolo" ]; then export IS_SANDBOX=1; else unset IS_SANDBOX; fi
      _runner_env "$session_name" "$agent" "$perm_mode" "$role" "$zone"
      health_set "$session_name" HEALTH=ok REASON= DETAIL=
      printf '\n %s↻ Reiniciando con la nueva configuración%s %s\n\n' "$C_NEON$C_BOLD" "$C_OFF" \
        "$(state_get "$session_name" MODEL)${PRESET:+ · preset $PRESET}"
      bus_event restarted "$session_name" "$session_name" "model=$(state_get "$session_name" MODEL) preset=$PRESET"
    fi
    refresh_dimensions
    local pending
    pending=$(queue_len "$session_name")
    box_top "✦ $PRAMA_BRAND // $session_name" "RUN #$run_count" "$C_BORDER_HI"
    box_row "$C_BORDER_HI" "$(role_badge "$role") · ${C_NEON}$agent${C_OFF} · perfil ${C_NEON}$profile${C_OFF} · permisos ${C_BRASS}${perm_mode^^}${C_OFF} · ${C_PURP}⎇ $(_runner_branch "$target_dir")${C_OFF}"
    if (( pending > 0 )); then
      box_row "$C_BORDER_HI" "${C_BRASS}▲ $pending tarea(s) en cola:${C_OFF} prama-agent bus inbox $session_name"
    fi
    box_bottom "$PRAMA_MENU_KEY menú · rueda/Ctrl+b [ scroll · $target_dir" "$C_BORDER_HI"
    printf '\n'

    exit_code=0
    "$@" || exit_code=$?

    if (( oneshot )); then
      exit "$exit_code"
    fi

    # In-place restart requested by `prama-agent fleet model|edit|restart` (applied at the top
    # of the loop): skip the standby menu.
    [ "$(state_get "$session_name" RESTART_REQ)" = 1 ] && continue

    _runner_title "$session_name" "$(role_badge "$role") · $agent · STANDBY"
    local show_menu=1
    while true; do
      if (( show_menu )); then
        refresh_dimensions
        printf '\n'
        box_top "▲ AGENTE FINALIZADO" "código $exit_code" "$C_BRASS"
        box_row "$C_BRASS" "${C_MUTED}El scrollback de esta sesión se conserva ($session_name).${C_OFF}"
        box_sep "$C_BRASS"
        box_row "$C_BRASS" "${C_LIVE}${C_BOLD}[↵/r]${C_OFF} Relanzar   ${C_NEON}${C_BOLD}[s]${C_OFF} Shell en zona   ${C_PURP}${C_BOLD}[m]${C_OFF} Volver al menú   ${C_ERR}${C_BOLD}[q]${C_OFF} Cerrar"
        box_bottom "STANDBY" "$C_BRASS"
        show_menu=0
      fi
      printf ' ⌘ Acción [r/s/m/q]: %sPRAMA_STANDBY%s' "$C_DIM" "$C_OFF"
      printf '\e[%dD' 13   # park the cursor before the (dim) marker
      local act=''
      IFS= read -r -n1 act || { _runner_cleanup; exit 0; }
      printf '\n'
      case "$act" in
        ''|r|R)
          printf ' ↻ Relanzando agente...\n\n'
          _runner_title "$session_name" "$(role_badge "$role") · $agent · $session_name"
          break
          ;;
        s|S)
          printf ' ▸ Shell en %s (escribe "exit" para volver al supervisor)\n' "$target_dir"
          "${SHELL:-/bin/bash}" -l || true
          show_menu=1
          ;;
        m|M)
          tmx detach-client -s "=$session_name" 2>/dev/null || true
          show_menu=1
          ;;
        q|Q)
          _runner_cleanup
          exit 0
          ;;
      esac
    done
  done
}
