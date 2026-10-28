#!/usr/bin/env bash
# lib/bus.sh — Multi-Agent Communication Bus, Guided Swarm Wizard & Lazydocker Cockpit
# Licensed under the Apache License, Version 2.0

# Auto-registers active tmux sessions into the bus state directory
sync_bus_state() {
  mkdir -p "$PRAMA_BUS_DIR/inbox" "$PRAMA_BUS_DIR/state" 2>/dev/null || true
  if ! command -v tmux >/dev/null 2>&1; then
    return 0
  fi
  local s_name p_path
  while IFS='|' read -r s_name p_path; do
    [ -z "$s_name" ] && continue
    [[ "$s_name" == *-cockpit* ]] && continue
    [[ "$s_name" == *-telegram-bot* ]] && continue
    if [ ! -f "$PRAMA_BUS_DIR/state/${s_name}.env" ]; then
      local inferred_role="executor"
      case "$s_name" in
        *-coordinator-*|*coord*) inferred_role="coordinator" ;;
        *-reader-*|*reader*)     inferred_role="reader" ;;
        *-daemon-*|*daemon*)     inferred_role="daemon" ;;
      esac
      cat <<EOF > "$PRAMA_BUS_DIR/state/${s_name}.env"
SESSION_NAME="$s_name"
ROLE="$inferred_role"
PROFILE="default"
TARGET_DIR="${p_path:-$PWD}"
STARTED_AT="$(date -Iseconds)"
EOF
    fi
  done < <(tmux list-panes -a -F "#{session_name}|#{pane_current_path}" 2>/dev/null || true)
}

# Resolves a target role name (e.g. "executor", "coordinator", "daemon") or exact session name
resolve_bus_target() {
  local target=$1
  sync_bus_state
  if tmux has-session -t "$target" 2>/dev/null; then
    echo "$target"
    return 0
  fi
  local f s_name s_role
  for f in "$PRAMA_BUS_DIR"/state/*.env; do
    [ -f "$f" ] || continue
    s_name=$(grep '^SESSION_NAME=' "$f" | cut -d'"' -f2)
    s_role=$(grep '^ROLE=' "$f" | cut -d'"' -f2)
    if [ "$s_role" = "$target" ] && tmux has-session -t "$s_name" 2>/dev/null; then
      echo "$s_name"
      return 0
    fi
  done
  local match
  match=$(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep -i "$target" | head -n1 || true)
  [ -n "$match" ] && { echo "$match"; return 0; }
  echo ""
}

subcmd_bus() {
  local action=${1:-status}
  shift || true
  sync_bus_state
  touch "$PRAMA_BUS_DIR/tasks.jsonl"

  case "$action" in
    status|ls)
      refresh_dimensions
      printf '\n'
      box_top "☍ SWARM COORDINATION BUS // ROLES & QUEUES" "MULTI-AGENT" "$C_BORDER_HI"
      local hdr
      hdr=$(printf '%s%-24s %-15s %-10s %s%s' "$C_DIM" "SESION" "ROL ASIGNADO" "PERFIL" "DIRECTORIO" "$C_OFF")
      box_row "$C_BORDER_HI" "$hdr"
      box_sep "$C_BORDER_HI"
      local count=0 f
      for f in "$PRAMA_BUS_DIR"/state/*.env; do
        [ -f "$f" ] || continue
        local SESSION_NAME="" ROLE="" PROFILE="" TARGET_DIR=""
        # shellcheck disable=SC1090
        source "$f"
        if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
          (( count++ ))
          local r_badge r_line
          r_badge=$(role_badge "$ROLE")
          r_line=$(printf '%s%-24s%s %s%-15s%s %s%-10s%s %s' \
            "$C_BOLD" "$SESSION_NAME" "$C_OFF" \
            "$C_LIVE" "$r_badge" "$C_OFF" \
            "$C_NEON" "$PROFILE" "$C_OFF" "$TARGET_DIR")
          box_row "$C_BORDER_HI" "$r_line"
        else
          rm -f "$f" 2>/dev/null || true
        fi
      done
      if (( count == 0 )); then
        box_row "$C_BORDER_HI" "${C_DIM}(Sin agentes registrados en el bus todavia)${C_OFF}"
      fi
      box_sep "$C_BORDER_HI"
      box_row "$C_BORDER_HI" "${C_LIVE}${C_BOLD}▸ ULTIMOS EVENTOS Y TAREAS EN EL BUS ($PRAMA_BUS_DIR/tasks.jsonl):${C_OFF}"
      if [ -s "$PRAMA_BUS_DIR/tasks.jsonl" ]; then
        local ev_line ts_short from_v to_v ev_v msg_v formatted_ev
        while IFS= read -r ev_line; do
          ts_short=$(sed -n 's/.*"ts":"[^"]*T\([0-9:]*\)[^"]*".*/\1/p' <<< "$ev_line")
          from_v=$(sed -n 's/.*"from":"\([^"]*\)".*/\1/p' <<< "$ev_line")
          to_v=$(sed -n 's/.*"to":"\([^"]*\)".*/\1/p' <<< "$ev_line")
          ev_v=$(sed -n 's/.*"event":"\([^"]*\)".*/\1/p' <<< "$ev_line")
          msg_v=$(sed -n 's/.*"\(task\|summary\)":"\([^"]*\)".*/\2/p' <<< "$ev_line")
          if [ -n "$ev_v" ]; then
            if [ -n "$to_v" ]; then
              formatted_ev=$(printf '[%s] %s ▸ %s (%s): %s' "${ts_short:-now}" "${from_v:-?}" "$ev_v" "$to_v" "$msg_v")
            else
              formatted_ev=$(printf '[%s] %s ▸ %s: %s' "${ts_short:-now}" "${from_v:-?}" "$ev_v" "$msg_v")
            fi
            box_row "$C_BORDER_HI" "  ${C_DIM}${formatted_ev}${C_OFF}"
          else
            box_row "$C_BORDER_HI" "  ${C_DIM}${ev_line}${C_OFF}"
          fi
        done < <(tail -n 6 "$PRAMA_BUS_DIR/tasks.jsonl")
      else
        box_row "$C_BORDER_HI" "  ${C_DIM}(Cola de eventos vacia)${C_OFF}"
      fi
      box_bottom "Asignar: prama-agent bus assign <rol|sesion> \"<tarea>\"" "$C_BORDER_HI"
      printf '\n'
      ;;

    assign|send)
      local target_raw=${1:-}
      shift || true
      local task_msg="${*:-}"
      [ -n "$target_raw" ] && [ -n "$task_msg" ] || die "Uso: prama-agent bus assign <sesión_o_rol> \"<instrucción>\""

      local resolved
      resolved=$(resolve_bus_target "$target_raw")
      local sender="${PRAMA_SESSION:-operator}"

      printf '{"ts":"%s","from":"%s","to":"%s","resolved":"%s","event":"assign","task":"%s"}\n' \
        "$(date -Iseconds)" "$sender" "$target_raw" "${resolved:-queue}" "$(json_escape "$task_msg")" >> "$PRAMA_BUS_DIR/tasks.jsonl"

      if [ "$target_raw" = "daemon" ] || grep -q 'ROLE="daemon"' "$PRAMA_BUS_DIR/state/${resolved}.env" 2>/dev/null; then
        local qfile="$PRAMA_BUS_DIR/inbox/${resolved:-daemon}.queue"
        printf '%s\n' "$task_msg" >> "$qfile"
        ok "Tarea encolada para el Daemon en $qfile"
        type telegram_notify >/dev/null 2>&1 && telegram_notify "📥 [BUS] Tarea encolada para Daemon ($sender): $task_msg"
        return 0
      fi

      if [ -n "$resolved" ]; then
        tmux send-keys -t "$resolved" -l "[TASK FROM $sender]: $task_msg"
        tmux send-keys -t "$resolved" Enter
        ok "Tarea enviada e inyectada en vivo a '$resolved' ($target_raw)."
        type telegram_notify >/dev/null 2>&1 && telegram_notify "📨 [BUS] $sender ➔ $resolved: $task_msg"
      else
        printf '%s\n' "$task_msg" >> "$PRAMA_BUS_DIR/inbox/${target_raw}.queue"
        warn "No hay sesión viva para '$target_raw'; tarea guardada en cola ($PRAMA_BUS_DIR/inbox/${target_raw}.queue)."
      fi
      ;;

    report)
      local report_msg="${*:-}"
      [ -n "$report_msg" ] || die "Uso: prama-agent bus report \"<resumen de resultado>\""
      local sender="${PRAMA_SESSION:-agent}"
      printf '{"ts":"%s","from":"%s","event":"report","summary":"%s"}\n' \
        "$(date -Iseconds)" "$sender" "$(json_escape "$report_msg")" >> "$PRAMA_BUS_DIR/tasks.jsonl"

      local coord_sess
      coord_sess=$(resolve_bus_target "coordinator")
      if [ -n "$coord_sess" ] && [ "$coord_sess" != "$sender" ]; then
        tmux send-keys -t "$coord_sess" -l "[REPORT FROM $sender]: $report_msg"
        tmux send-keys -t "$coord_sess" Enter
        ok "Reporte registrado y notificado al Coordinador ($coord_sess)."
      else
        ok "Reporte registrado en el bus ($PRAMA_BUS_DIR/tasks.jsonl)."
      fi
      type telegram_notify >/dev/null 2>&1 && telegram_notify "✅ [REPORTE DE $sender]: $report_msg"
      ;;

    swarm-start)
      local zone=${1:-${ZONES[0]}}
      local coord_agent=${2:-claude}
      local exec_agent=${3:-agy}
      ! command -v "$exec_agent" >/dev/null 2>&1 && exec_agent="claude"
      "$SELF_PATH" "$coord_agent" "$zone" --role coordinator --bg
      "$SELF_PATH" "$exec_agent" "$zone" --role executor --bg
      ok "Dupla Multi-Agente iniciada en zona '$zone' ($coord_agent Coordinador + $exec_agent Ejecutor)."
      type telegram_notify >/dev/null 2>&1 && telegram_notify "🤝 Enjambre iniciado en '$zone': Coordinador ($coord_agent) + Ejecutor ($exec_agent)."
      ;;

    broadcast)
      local msg="${*:-}"
      [ -n "$msg" ] || die "Uso: prama-agent bus broadcast \"<mensaje>\""
      local s
      while IFS= read -r s; do
        [ -z "$s" ] && continue
        [[ "$s" == *-cockpit* ]] && continue
        [[ "$s" == *-telegram-bot* ]] && continue
        tmux send-keys -t "$s" -l "[BROADCAST]: $msg"
        tmux send-keys -t "$s" Enter
      done < <(tmux list-sessions -F "#{session_name}" 2>/dev/null || true)
      ok "Broadcast enviado a todas las sesiones activas."
      ;;

    watch)
      printf ' %s☍ ESCUCHANDO BUS MULTI-AGENTE EN VIVO (%s/tasks.jsonl)...%s\n\n' "$C_NEON$C_BOLD" "$PRAMA_BUS_DIR" "$C_OFF"
      tail -n 20 -f "$PRAMA_BUS_DIR/tasks.jsonl"
      ;;

    clear)
      : > "$PRAMA_BUS_DIR/tasks.jsonl"
      rm -f "$PRAMA_BUS_DIR"/inbox/*.queue 2>/dev/null || true
      ok "Cola de tareas y eventos del bus limpiada."
      ;;

    *)
      die "Acción de bus desconocida: '$action' (usa: status | assign | report | swarm-start | broadcast | watch | clear)"
      ;;
  esac
}

# ── Guided Swarm Menu (In-TUI Wizard for Multi-Agent Coordination) ──────────
swarm_wizard_menu() {
  while true; do
    sync_bus_state
    local def_z="${ZONE:-${ZONES[0]}}"
    local SW_LABELS=(
      "◄ VOLVER AL MENU"
      "✦ LANZAR DUPLA"
      "❖ ABRIR COCKPIT"
      "☍ ENVIAR TAREA"
      "♺ LANZAR DAEMON"
      "◉ VER ACTIVIDAD"
    )
    local SW_METAS=(
      "Regresar al menú principal de Prama Agent"
      "Inicia 1 Coordinador (Claude) + 1 Ejecutor (Agy) que se hablan en '$def_z'"
      "Pantalla dividida 3 paneles (Coordinador + Ejecutor + Monitor Bus)"
      "Enviar una instrucción a un agente o al Coordinador"
      "Inicia un agente Esclavo/Daemon continuo que procesa la cola"
      "Ver agentes registrados y últimos mensajes entre ellos"
    )
    local SW_AVAIL=(1 1 1 1 1 1)
    local SW_TARGETS=("" "" "" "" "" "")
    local rc=0
    tui_select_box "hub" "🤝 COORDINAR ENJAMBRE (AGENTES QUE SE HABLAN)" SW_LABELS SW_METAS SW_AVAIL SW_TARGETS || rc=$?
    if (( rc == 2 )) || [ "${CHOICE:-0}" -eq 0 ]; then
      return 0
    fi
    case "$CHOICE" in
      1)
        printf '\e[2J\e[H'
        subcmd_bus swarm-start "$def_z" claude agy
        printf '\n Presiona cualquier tecla para volver...'
        IFS= read -rsn1 _ || true
        return 0
        ;;
      2)
        printf '\e[?25h\n'
        subcmd_cockpit "$def_z"
        return 0
        ;;
      3)
        printf '\e[?25h\n'
        box_top "☍ ENVIAR TAREA AL ENJAMBRE" "BUS" "$C_LIVE"
        printf ' %s│%s Destino (ej. coordinator, executor, daemon o nombre de sesión) [default: coordinator]: ' "$C_LIVE" "$C_OFF"
        local dest=''
        IFS= read -r dest || true
        [ -z "$dest" ] && dest="coordinator"
        printf ' %s│%s Instrucción: ' "$C_LIVE" "$C_OFF"
        local msg=''
        IFS= read -r msg || true
        if [ -n "$msg" ]; then
          subcmd_bus assign "$dest" "$msg"
          sleep 1.2
        fi
        printf '\e[?25l'
        ;;
      4)
        printf '\e[2J\e[H'
        "$SELF_PATH" claude "$def_z" --role daemon --loop 60 --bg
        printf '\n Presiona cualquier tecla para volver...'
        IFS= read -rsn1 _ || true
        return 0
        ;;
      5)
        printf '\e[2J\e[H'
        subcmd_bus status
        printf ' Presiona cualquier tecla para volver...'
        IFS= read -rsn1 _ || true
        ;;
    esac
  done
}

# ── Lazydocker-Style Multi-Agent Cockpit in Tmux ────────────────────────────
subcmd_cockpit() {
  local zone=${1:-${ZONES[0]}}
  local coord_agent=${2:-claude}
  local exec_agent=${3:-agy}
  ensure_tmux_conf 1

  local dir='' i
  for i in "${!ZONES[@]}"; do
    [ "${ZONES[$i]}" = "$zone" ] && dir=${ZONE_DIRS[$i]}
  done
  [ -n "$dir" ] || die "Zona '$zone' no encontrada."

  local cockpit_session="${PRAMA_SESSION_PREFIX}-cockpit-${zone}"
  if ! tmux has-session -t "$cockpit_session" 2>/dev/null; then
    local coord_cmd exec_cmd watch_cmd
    printf -v coord_cmd '%q ' "$SELF_PATH" "$coord_agent" "$zone" --direct --role coordinator
    printf -v exec_cmd  '%q ' "$SELF_PATH" "$exec_agent"  "$zone" --direct --role executor
    printf -v watch_cmd '%q ' "$SELF_PATH" bus watch

    tmux new-session -d -s "$cockpit_session" -c "$dir" -e "IS_SANDBOX=1" "${coord_cmd% }"
    tmux select-pane -t "${cockpit_session}:0.0" -T "❖ COORDINATOR ($coord_agent @ $zone)"

    tmux split-window -h -p 50 -t "${cockpit_session}:0.0" -c "$dir" -e "IS_SANDBOX=1" "${exec_cmd% }"
    tmux select-pane -t "${cockpit_session}:0.1" -T "✦ EXECUTOR ($exec_agent @ $zone)"

    tmux split-window -v -p 30 -t "${cockpit_session}:0.1" -c "$dir" "${watch_cmd% }"
    tmux select-pane -t "${cockpit_session}:0.2" -T "☍ SWARM BUS MONITOR"

    tmux select-pane -t "${cockpit_session}:0.0"
  fi

  ok "Entrando al Cockpit '$cockpit_session' (Toca [⬅ MENU PRAMA] abajo o Ctrl+g para volver al menú)."
  restore_locale
  (( ${IN_TUI:-0} )) && tui_leave_screen
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "$cockpit_session"
  else
    tmux attach-session -d -t "$cockpit_session" || true
  fi
  (( ${IN_TUI:-0} )) && tui_enter_screen
  return 0
}
