#!/usr/bin/env bash
# lib/roles.sh — Role Profiles (Coordinator, Executor, Reader, Daemon) & In-Pane Supervisor
# Licensed under the Apache License, Version 2.0

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

# Builds the coordination system prompt injected into agents so they can talk to each other
build_role_system_prompt() {
  local role=$1 session_name=$2 zone=$3
  case "$role" in
    coordinator)
      cat <<EOF
[PRAMA-SWARM ROLE: COORDINATOR | session=$session_name | zone=$zone]
Eres el Agente COORDINADOR / ARQUITECTO en la zona '$zone'.
Tu misión es planificar, dividir el trabajo, revisar código y coordinar a otros agentes activos.
Comandos de coordinación disponibles mediante tu herramienta Bash:
- Ver agentes activos y cola de tareas: prama-agent bus status
- Asignar tarea a otro agente o rol:   prama-agent bus assign <sesión_o_rol> "<instrucción detallada>"
- Leer terminal de otro agente:        prama-agent logs <sesión> 50
EOF
      ;;
    executor)
      cat <<EOF
[PRAMA-SWARM ROLE: EXECUTOR | session=$session_name | zone=$zone]
Eres un Agente EJECUTOR en la zona '$zone'.
Tu misión es implementar código, ejecutar tests y verificar que todo compile sin errores.
Cuando completes una tarea asignada por el coordinador, reporta tu resultado ejecutando:
  prama-agent bus report "$session_name: <resumen conciso de cambios y tests>"
EOF
      ;;
    reader)
      cat <<EOF
[PRAMA-SWARM ROLE: READER (READ-ONLY) | session=$session_name | zone=$zone]
Eres un Agente LECTOR / AUDITOR en modo de SOLO LECTURA estricto en la zona '$zone'.
NO modifiques archivos ni ejecutes comandos destructivos. Analiza arquitectura, logs y bugs,
y reporta tus hallazgos con:
  prama-agent bus report "$session_name: <hallazgos>"
EOF
      ;;
    daemon)
      cat <<EOF
[PRAMA-SWARM ROLE: DAEMON WORKER | session=$session_name | zone=$zone]
Eres un Agente ESCLAVO / DAEMON autónomo en la zona '$zone'.
Procesa la tarea solicitada de principio a fin sin pedir confirmación interactiva y emite un resumen claro.
EOF
      ;;
  esac
}

# Executes a single headless prompt for a daemon worker across any supported CLI
run_daemon_turn() {
  local agent=$1 prompt=$2
  case "$agent" in
    claude)
      claude --dangerously-skip-permissions -p "$prompt"
      ;;
    agy)
      agy --dangerously-skip-permissions -p "$prompt"
      ;;
    kimi)
      kimi --yolo -p "$prompt"
      ;;
    gemini)
      gemini --yolo -p "$prompt"
      ;;
    qwen)
      qwen --yolo "$prompt"
      ;;
    *)
      "$agent" "$prompt"
      ;;
  esac
}

# ── Internal Supervisor Runner (Executed Inside Tmux Pane) ──────────────────
internal_runner() {
  local session_name=$1
  local target_dir=$2
  local profile=$3
  local oneshot=$4
  local role=${5:-executor}
  local daemon_interval=${6:-60}
  shift 6
  [ "${1:-}" = "--" ] && shift

  restore_locale
  cd "$target_dir" || exit 1
  export IS_SANDBOX=1
  export PRAMA_SESSION="$session_name"
  export PRAMA_ROLE="$role"

  if [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ] && [ -z "${OPENAI_API_KEY:-}" ]; then
    apply_provider_profile "$profile"
  fi

  # Register session metadata in shared bus state
  mkdir -p "$PRAMA_BUS_DIR/state" "$PRAMA_BUS_DIR/inbox" 2>/dev/null || true
  cat <<EOF > "$PRAMA_BUS_DIR/state/${session_name}.env"
SESSION_NAME="$session_name"
ROLE="$role"
PROFILE="$profile"
TARGET_DIR="$target_dir"
STARTED_AT="$(date -Iseconds)"
EOF

  # Set tmux pane title for cockpit visibility
  tmux select-pane -T "$(role_badge "$role") · $session_name" 2>/dev/null || true

  # ── Special Mode: Continuous Autonomous Daemon (Slave/Worker Loop) ────────
  if [ "$role" = "daemon" ]; then
    local agent_bin=${1:-claude}
    local inbox_file="$PRAMA_BUS_DIR/inbox/${session_name}.queue"
    local role_inbox="$PRAMA_BUS_DIR/inbox/daemon.queue"
    touch "$inbox_file" "$role_inbox"

    local cycle=0
    while true; do
      (( cycle++ ))
      local branch
      branch=$(git -C "$target_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "—")
      box_top "♺ DAEMON_HEARTBEAT // $session_name" "CICLO #$cycle" "$C_PURP"
      box_row "$C_PURP" "Agente: ${C_BOLD}$agent_bin${C_OFF} · Rama: ${C_NEON}⎇ $branch${C_OFF} · Intervalo: ${daemon_interval}s"
      box_row "$C_PURP" "Cola activa: $inbox_file"
      box_bottom "prama-agent bus assign $session_name \"<tarea>\"" "$C_PURP"

      local next_task=""
      if [ -s "$inbox_file" ]; then
        next_task=$(head -n 1 "$inbox_file")
        sed -i '1d' "$inbox_file"
      elif [ -s "$role_inbox" ]; then
        next_task=$(head -n 1 "$role_inbox")
        sed -i '1d' "$role_inbox"
      elif [ -n "${PRAMA_DAEMON_TASK:-}" ]; then
        next_task="$PRAMA_DAEMON_TASK"
      fi

      if [ -n "$next_task" ]; then
        printf '\n %s▸ EJECUTANDO TAREA DAEMON:%s %s\n\n' "$C_LIVE$C_BOLD" "$C_OFF" "$next_task"
        run_daemon_turn "$agent_bin" "$next_task"
        local rc=$?
        printf '{"ts":"%s","from":"%s","role":"daemon","event":"completed","rc":%d,"task":"%s"}\n' \
          "$(date -Iseconds)" "$session_name" "$rc" "$(json_escape "$next_task")" >> "$PRAMA_BUS_DIR/tasks.jsonl"
      else
        printf ' %s[%s] Cola vacía. Esperando tareas (prama-agent bus assign %s "<tarea>")...%s\n' \
          "$C_DIM" "$(date +%H:%M:%S)" "$session_name" "$C_OFF"
      fi

      (( oneshot )) && exit 0
      sleep "$daemon_interval"
    done
  fi

  # ── Standard Interactive / Supervised Agent Loop ──────────────────────────
  local run_count=0
  while true; do
    (( run_count++ ))
    local branch
    branch=$(git -C "$target_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "—")
    box_top "✦ SYS//$PRAMA_BRAND SUPERVISOR // $session_name" "RUN #$run_count" "$C_BORDER_HI"
    box_row "$C_BORDER_HI" "Rol: ${C_LIVE}${C_BOLD}$(role_badge "$role")${C_OFF} · Perfil LLM: ${C_NEON}${C_BOLD}$profile${C_OFF} · Rama: ${C_PURP}⎇ $branch${C_OFF}"
    box_row "$C_BORDER_HI" "${C_DIM}[Ctrl+b d] Salir sin cerrar (Detach)  ·  [Rueda ratón / Ctrl+b [] Scroll 50k líneas${C_OFF}"
    box_bottom "$target_dir" "$C_BORDER_HI"
    printf '\n'

    "$@"
    local exit_code=$?

    if (( oneshot )); then
      rm -f "$PRAMA_BUS_DIR/state/${session_name}.env" 2>/dev/null || true
      exit "$exit_code"
    fi

    printf '\n'
    box_top "▲ AGENTE FINALIZADO (código: $exit_code)" "STANDBY" "$C_BRASS"
    box_row "$C_BRASS" "El historial de 50.000 líneas sigue protegido en esta sesión ($session_name)."
    box_row "$C_BRASS" "${C_LIVE}${C_BOLD}[↵ / r]${C_OFF} Relanzar  ·  ${C_NEON}${C_BOLD}[s]${C_OFF} Shell en zona  ·  ${C_PURP}${C_BOLD}[m]${C_OFF} Menú TUI  ·  ${C_ERR}${C_BOLD}[q]${C_OFF} Cerrar"
    box_bottom "" "$C_BRASS"

    while true; do
      printf ' ⌘ Acción [r/s/m/q]: '
      local act=''
      IFS= read -r -n1 act || exit 0
      printf '\n'
      case "$act" in
        ''|r|R)
          printf ' ↻ Relanzando agente...\n\n'
          break
          ;;
        s|S)
          printf ' ▸ Abriendo shell en %s (escribe "exit" para volver al supervisor)...\n' "$target_dir"
          "${SHELL:-/bin/bash}" -l
          break
          ;;
        m|M)
          "$SELF_PATH"
          break
          ;;
        q|Q)
          rm -f "$PRAMA_BUS_DIR/state/${session_name}.env" 2>/dev/null || true
          exit 0
          ;;
      esac
    done
  done
}
