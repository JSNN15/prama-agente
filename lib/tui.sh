#!/usr/bin/env bash
# lib/tui.sh — Zero-Flicker Double-Buffered TUI Engine (Synchronized Output + Surgical Row Redraw)
# Licensed under the Apache License, Version 2.0

# Enter/Exit Alternate Screen Buffer cleanly (like btop, lazydocker, fzf)
tui_enter_screen() {
  if (( IS_TTY )); then
    printf '\e[?1049h\e[?25l\e[2J\e[H'
  fi
}

tui_leave_screen() {
  if (( IS_TTY )); then
    printf '\e[?25h\e[?1049l'
  fi
}

cycle_profile() {
  local idx=0 i n=${#AVAILABLE_PROFILES[@]}
  for ((i = 0; i < n; i++)); do
    if [ "${AVAILABLE_PROFILES[$i]}" = "$PROFILE" ]; then
      idx=$(( (i + 1) % n ))
      break
    fi
  done
  PROFILE="${AVAILABLE_PROFILES[$idx]}"
}

cycle_role() {
  local idx=0 i n=${#AVAILABLE_ROLES[@]}
  for ((i = 0; i < n; i++)); do
    if [ "${AVAILABLE_ROLES[$i]}" = "$ROLE" ]; then
      idx=$(( (i + 1) % n ))
      break
    fi
  done
  ROLE="${AVAILABLE_ROLES[$idx]}"
  if [ "$ROLE" = "reader" ]; then
    PERM_MODE="plan"
  elif [ "$PERM_MODE" = "plan" ]; then
    PERM_MODE="yolo"
  fi
}

cycle_perm_mode() {
  local idx=0 i n=${#AVAILABLE_PERM_MODES[@]}
  for ((i = 0; i < n; i++)); do
    if [ "${AVAILABLE_PERM_MODES[$i]}" = "$PERM_MODE" ]; then
      idx=$(( (i + 1) % n ))
      break
    fi
  done
  PERM_MODE="${AVAILABLE_PERM_MODES[$idx]}"
}

# Interactive Split-Screen Fuzzy Cockpit powered by fzf + tmux capture-pane
launch_fzf_cockpit() {
  if ! command -v fzf >/dev/null 2>&1; then
    warn "fzf no está instalado en PATH."
    return 1
  fi
  refresh_dimensions
  sync_bus_state
  local lines=() s_name p_pid p_path p_dead s_att p_cmd
  while IFS='|' read -r s_name p_pid p_path p_dead s_att p_cmd; do
    [ -z "$s_name" ] && continue
    local a_pid cpu mem _etime comm st_lbl _st_col s_role="executor"
    a_pid=$(resolve_pane_agent_pid "$p_pid")
    IFS='|' read -r cpu mem _etime comm <<< "$(get_proc_metrics "$a_pid")"
    IFS='|' read -r st_lbl _st_col <<< "$(detect_pane_activity_state "$s_name" "$p_dead" "$comm")"
    [ -f "$PRAMA_BUS_DIR/state/${s_name}.env" ] && s_role=$(grep '^ROLE=' "$PRAMA_BUS_DIR/state/${s_name}.env" | cut -d'"' -f2 || echo "executor")
    lines+=("$(printf '%-24s │ %-13s │ %-7s │ %s' "$s_name" "$(role_badge "$s_role")" "$st_lbl" "$mem")")
  done < <(tmux list-panes -a -F "#{session_name}|#{pane_pid}|#{pane_current_path}|#{pane_dead}|#{session_attached}|#{pane_current_command}" 2>/dev/null || true)

  if [ "${#lines[@]}" -eq 0 ]; then
    warn "No hay sesiones activas en tmux para inspeccionar con fzf."
    return 1
  fi

  local prev_win="right:58%:wrap:border-left"
  (( IS_COMPACT )) && prev_win="down:55%:wrap:border-top"

  printf '\e[?25h'
  local selected
  selected=$(printf '%s\n' "${lines[@]}" | fzf \
    --ansi \
    --border=rounded \
    --border-label=" ✦ PRAMA AGENT INSPECTOR " \
    --prompt="⌘ Sesión > " \
    --header="[Enter] Conectar  ·  [Esc] Volver al Menú" \
    --preview="tmux capture-pane -ep -t {1} -S -35 2>/dev/null" \
    --preview-window="$prev_win" \
    --color="bg+:#1e3a5f,fg+:#f0f9ff,hl:#38bdf8,hl+:#34d399,border:#38bdf8,label:#38bdf8,header:#fbbf24,prompt:#34d399" || true)
  printf '\e[?25l'

  if [ -n "$selected" ]; then
    local target_s
    target_s=$(awk '{print $1}' <<< "$selected")
    if [ -n "$target_s" ] && tmux has-session -t "$target_s" 2>/dev/null; then
      tui_leave_screen
      restore_locale
      if [ -n "${TMUX:-}" ]; then
        tmux switch-client -t "$target_s"
      else
        tmux attach-session -d -t "$target_s" || true
      fi
      tui_enter_screen
    fi
  fi
}

# Renders header without \e[2J (uses \e[H cursor home to prevent blank-screen flash)
render_header() {
  local step_name=$1
  local clear_screen=${2:-0}
  refresh_dimensions
  local host_stats
  host_stats=$(get_host_telemetry)

  if (( clear_screen )); then
    printf '\e[2J\e[H'
  else
    printf '\e[H'
  fi

  local bc_hub="⌂ MENU" bc_agent="✦ AGENTE" bc_zone="⟐ ZONA"
  [ -n "$AGENT" ] && bc_agent="✦ ${AGENT^^}"
  [ -n "$ZONE" ]  && bc_zone="⟐ ${ZONE^^}"

  case "$step_name" in
    hub)       bc_hub="${C_LIVE}${C_BOLD}[⌂ MENU]${C_OFF}" ;;
    agent)     bc_agent="${C_LIVE}${C_BOLD}[✦ AGENTE]${C_OFF}" ;;
    zone)      bc_zone="${C_LIVE}${C_BOLD}[⟐ ZONA]${C_OFF}" ;;
    collision) bc_zone="${C_BRASS}${C_BOLD}[▲ ACTIVA]${C_OFF}" ;;
  esac

  local wt_badge="off" rc_badge="OFF" tg_badge="OFF"
  [ -n "$WORKTREE" ] && wt_badge="$WORKTREE"
  (( REMOTE )) && rc_badge="ON"
  if [ "${TG_BOT_RUNNING:-0}" = "1" ]; then
    tg_badge="${C_LIVE}24/7${C_OFF}"
  fi

  box_top "✦ PRAMA AGENT v$VERSION" "$host_stats" "$C_BORDER_HI"
  if (( IS_COMPACT )); then
    local m1 m2
    m1=$(printf '%s ▸ %s ▸ %s  │ TG:%s' "$bc_hub" "$bc_agent" "$bc_zone" "$tg_badge")
    m2=$(printf '%s[o]Rol:%s%s%s%s %s[y]Perm:%s%s%s%s %s[c]RC:%s%s%s%s %s[p]LLM:%s%s%s%s' \
      "$C_MUTED" "$C_OFF" "$C_LIVE$C_BOLD" "$ROLE" "$C_OFF" \
      "$C_MUTED" "$C_OFF" "$C_BRASS$C_BOLD" "${PERM_MODE^^}" "$C_OFF" \
      "$C_MUTED" "$C_OFF" "$C_NEON$C_BOLD" "$rc_badge" "$C_OFF" \
      "$C_MUTED" "$C_OFF" "$C_PURP$C_BOLD" "$PROFILE" "$C_OFF")
    box_row "$C_BORDER_HI" "$m1"
    box_row "$C_BORDER_HI" "$m2"
  else
    local line1 line2
    line1=$(printf '%s %s▸%s %s %s▸%s %s │ %s[o] Rol:%s %s%-11s%s %s[y] Perm:%s %s%-4s%s %s[c] Remote:%s %s%s%s' \
      "$bc_hub" "$C_MUTED" "$C_OFF" "$bc_agent" "$C_MUTED" "$C_OFF" "$bc_zone" \
      "$C_MUTED" "$C_OFF" "$C_LIVE$C_BOLD" "$ROLE" "$C_OFF" \
      "$C_MUTED" "$C_OFF" "$C_BRASS$C_BOLD" "${PERM_MODE^^}" "$C_OFF" \
      "$C_MUTED" "$C_OFF" "$C_NEON$C_BOLD" "$rc_badge" "$C_OFF")
    line2=$(printf '%s[p] Perfil LLM:%s %s%-12s%s %s[w] Worktree:%s %s%-8s%s %sTelegram:%s %s' \
      "$C_MUTED" "$C_OFF" "$C_NEON$C_BOLD" "$PROFILE" "$C_OFF" \
      "$C_MUTED" "$C_OFF" "$C_PURP$C_BOLD" "$wt_badge" "$C_OFF" \
      "$C_MUTED" "$C_OFF" "$tg_badge")
    box_row "$C_BORDER_HI" "$line1"
    box_row "$C_BORDER_HI" "$line2"
  fi
  box_bottom "Volver desde agente: Toca [◄ MENU PRAMA] o Ctrl+g" "$C_BORDER_HI"
}

# Fixed-height (3 lines on mobile, 4 on desktop) preview/info box so the layout NEVER jumps when moving arrows!
render_fixed_context_box() {
  local target_sess=${1:-}
  local cur_label=${2:-}
  local p_lines=4
  (( IS_COMPACT )) && p_lines=3

  if [ -n "$target_sess" ] && [ -n "${PREVIEW_CACHE[$target_sess]:-}" ]; then
    box_top "◉ PANTALLA EN VIVO // $target_sess" "PREVIEW" "$C_INDIGO"
    local pline max_p=$(( W - 6 )) count=0
    while IFS= read -r pline; do
      (( count >= p_lines )) && break
      (( ${#pline} > max_p )) && pline="${pline:0:max_p-1}…"
      box_row "$C_INDIGO" "${C_DIM}${pline}${C_OFF}"
      (( count++ ))
    done <<< "${PREVIEW_CACHE[$target_sess]}"
    while (( count < p_lines )); do
      box_row "$C_INDIGO" ""
      (( count++ ))
    done
    if (( IS_COMPACT )); then
      box_bottom "[↵] Entrar · [t] Tarea · [l] Logs · [x] Cerrar" "$C_INDIGO"
    else
      box_bottom "[↵] Entrar · [t] Enviar instrucción · [l] Ver más · [x] Cerrar" "$C_INDIGO"
    fi
  else
    box_top "✦ DETALLE DE LA OPCION SELECCIONADA" "GUIA" "$C_INDIGO"
    local d1="" d2="" d3="" d4=""
    case "$cur_label" in
      *"NUEVO AGENTE"*)
        d1="Lanza una sesión protegida en tmux (Claude, Agy, Kimi, Gemini, Qwen)."
        d2="Rol actual: $ROLE · Permisos: ${PERM_MODE^^} · Remote Control: $REMOTE"
        d3="Usa [o] para cambiar Rol o [y] para alternar permisos YOLO/Plan."
        d4="Al entrar al agente, toca [◄ MENU PRAMA] abajo para regresar aquí."
        ;;
      *"COORDINAR"*)
        d1="Orquestación Multi-Agente: haz que varios agentes colaboren entre sí."
        d2="• Lanzar Dupla: Inicia 1 Coordinador (Claude) + 1 Ejecutor (Agy)."
        d3="• Abrir Cockpit: Pantalla dividida en 3 paneles estilo Lazydocker."
        d4="• Enviar Tarea / Ver Bus: Inyecta órdenes en vivo entre sesiones."
        ;;
      *"TELEGRAM"*)
        d1="Puente Bot de Telegram 24/7 para usar desde tu Smartphone."
        d2="Sigue controlando tus agentes aunque Termius se cierre o desconecte."
        d3="Incluye botones en Telegram para ver pantalla, lanzar y chatear."
        d4="Solo necesitas pegar el token de @BotFather una sola vez."
        ;;
      *"DOCTOR"*)
        d1="Autodiagnóstico y limpieza automática del servidor:"
        d2="• Desacopla sesiones SSH fantasma o clientes tmux colgados."
        d3="• Activa el botón táctil [◄ MENU PRAMA] y soporte de ratón."
        d4="• Limpia metadatos huérfanos de Git Worktrees."
        ;;
      *)
        d1="Usa las flechas [↑/↓] para moverte y [Enter] para seleccionar."
        d2="En submenús elige '01 ▸ ◄ VOLVER AL MENU' o presiona [0 / ← / ⌫]."
        d3="Teclas rápidas: [o] Rol ($ROLE) · [y] Permisos (${PERM_MODE^^}) · [p] LLM."
        d4="Presiona [q] en cualquier momento para salir a la terminal."
        ;;
    esac
    box_row "$C_INDIGO" "${C_DIM}${d1}${C_OFF}"
    box_row "$C_INDIGO" "${C_DIM}${d2}${C_OFF}"
    box_row "$C_INDIGO" "${C_DIM}${d3}${C_OFF}"
    if (( p_lines >= 4 )); then
      box_row "$C_INDIGO" "${C_DIM}${d4}${C_OFF}"
    fi
    if (( IS_COMPACT )); then
      box_bottom "[↵] Abrir opción seleccionada · [q] Salir" "$C_INDIGO"
    else
      box_bottom "[↵] Abrir opción · [o] Cambiar Rol · [y] Cambiar Permisos · [q] Salir" "$C_INDIGO"
    fi
  fi
}

render_keybar() {
  local mode=$1
  local kb1
  if (( IS_COMPACT )); then
    if [ "$mode" = "hub" ]; then
      kb1=$(printf '%s[↑↓]%sMover %s[↵]%sElegir %s[t]%sTarea %s[o]%sRol %s[x]%sKill %s[q]%sSalir' \
        "$KEY_BADGE" "$C_OFF" "$KEY_BADGE" "$C_OFF" "$KEY_BADGE" "$C_OFF" \
        "$KEY_BADGE" "$C_OFF" "$KEY_BADGE" "$C_OFF" "$KEY_BADGE" "$C_OFF")
    else
      kb1=$(printf '%s[↑↓]%sMover %s[↵]%sElegir %s[0/←/⌫/b]%s %sVolver al Menú%s %s[q]%sSalir' \
        "$KEY_BADGE" "$C_OFF" "$KEY_BADGE" "$C_OFF" "$KEY_BADGE" "$C_OFF" "$C_BRASS$C_BOLD" "$C_OFF" "$KEY_BADGE" "$C_OFF")
    fi
  else
    if [ "$mode" = "hub" ]; then
      kb1=$(printf '%s[↑↓/jk]%s Mover %s[↵ / 1-9]%s Elegir %s[t]%s Enviar Tarea %s[o]%s Rol %s[y]%s YOLO %s[f]%s fzf %s[x]%s Cerrar %s[q]%s Salir' \
        "$KEY_BADGE" "$C_OFF" "$KEY_BADGE" "$C_OFF" "$KEY_BADGE" "$C_OFF" \
        "$KEY_BADGE" "$C_OFF" "$KEY_BADGE" "$C_OFF" "$KEY_BADGE" "$C_OFF" \
        "$KEY_BADGE" "$C_OFF" "$KEY_BADGE" "$C_OFF")
    else
      kb1=$(printf '%s[↑↓/jk]%s Mover  %s[↵ / 1-9]%s Seleccionar  %s[0 / ← / ⌫ / b / Esc]%s %s◄ VOLVER AL MENU%s  %s[q]%s Salir' \
        "$KEY_BADGE" "$C_OFF" "$KEY_BADGE" "$C_OFF" "$KEY_BADGE" "$C_OFF" "$C_BRASS$C_BOLD" "$C_OFF" "$KEY_BADGE" "$C_OFF")
    fi
  fi
  box_top "⌘ CONTROLES" "" "$C_BORDER"
  box_row "$C_BORDER" "$kb1"
  box_bottom "" "$C_BORDER"
}

read_key_token() {
  local key rest
  IFS= read -rsn1 key || { echo "QUIT"; return 0; }
  case "$key" in
    $'\e')
      read -rsn2 -t 0.04 rest || rest=''
      case "$rest" in
        '[A'|'OA') echo "UP" ;;
        '[B'|'OB') echo "DOWN" ;;
        '[D'|'OD') echo "BACK" ;;
        '[C'|'OC') echo "ENTER" ;;
        '')        echo "BACK" ;;
        *)         echo "NONE" ;;
      esac
      ;;
    $'\x7f'|$'\b'|0) echo "BACK" ;;
    ''|$'\r'|$'\n')  echo "ENTER" ;;
    *) echo "$key" ;;
  esac
}

prompt_worktree_modal() {
  printf '\e[?25h'
  printf '\n'
  box_top "⎇ AISLAMIENTO GIT WORKTREE" "BRANCH" "$C_PURP"
  printf ' %s│%s Rama worktree (vacío=off): ' "$C_PURP" "$C_OFF"
  local input=''
  IFS= read -r input || true
  WORKTREE="$input"
  printf '\e[?25l'
}

prompt_send_task_modal() {
  local target_sess=$1
  printf '\e[?25h'
  printf '\n'
  box_top "☍ ENVIAR TAREA A $target_sess" "BUS" "$C_LIVE"
  printf ' %s│%s Escribe la instrucción para el agente: ' "$C_LIVE" "$C_OFF"
  local task_input=''
  IFS= read -r task_input || true
  if [ -n "$task_input" ]; then
    subcmd_bus assign "$target_sess" "$task_input"
    sleep 0.8
  fi
  printf '\e[?25l'
}

# ── Zero-Flicker Menu Selector (Pre-cached + Surgical 2-Line Cursor Updates) ─
tui_select_box() {
  local step_id=$1 box_title=$2
  local -n _labels=$3 _metas=$4 _avail=$5 _targets=$6
  local n=${#_labels[@]} idx=0 prev_idx=-1 i row pad max_row lbl_w
  local need_full_redraw=1

  for ((i = 0; i < n; i++)); do [ "${_avail[$i]}" = 1 ] && { idx=$i; break; }; done
  if [ "$step_id" != "hub" ] && (( n > 1 )) && [[ "${_labels[0]}" == *"VOLVER"* ]]; then
    for ((i = 1; i < n; i++)); do [ "${_avail[$i]}" = 1 ] && { idx=$i; break; }; done
  fi

  # Pre-cache live session previews ONCE on menu entry so arrow keys do 0 subshell forks!
  declare -A PREVIEW_CACHE=()
  TG_BOT_RUNNING=0
  if command -v tmux >/dev/null 2>&1; then
    tmux has-session -t "${PRAMA_SESSION_PREFIX}-telegram-bot" 2>/dev/null && TG_BOT_RUNNING=1
    for ((i = 0; i < n; i++)); do
      local t_s="${_targets[$i]:-}"
      if [ -n "$t_s" ] && [ -z "${PREVIEW_CACHE[$t_s]:-}" ]; then
        local cap
        cap=$(tmux capture-pane -p -t "$t_s" -S -25 2>/dev/null \
          | sed $'s/\xc2\xa0/ /g; s/[[:space:]]*$//; s/^[[:space:]]*//; s/   */  /g' \
          | grep -v '^[[:space:]]*$' \
          | grep -v '────────' \
          | grep -v '━━━━━━━━' \
          | tail -n 4 || true)
        [ -z "$cap" ] && cap="(Terminal activa en espera)"
        PREVIEW_CACHE["$t_s"]="$cap"
      fi
    done
  fi

  local -a PADDED_ROWS=()

  build_padded_rows() {
    refresh_dimensions
    max_row=$(( W - 4 ))
    lbl_w=17
    (( IS_COMPACT )) && lbl_w=15
    PADDED_ROWS=()
    for ((i = 0; i < n; i++)); do
      local icon="▸"
      [ "${_avail[$i]}" != 1 ] && icon="✖"
      local cur_lbl="${_labels[$i]}"
      (( ${#cur_lbl} > lbl_w )) && cur_lbl="${cur_lbl:0:lbl_w}"
      local lbl_pad=$(( lbl_w - ${#cur_lbl} ))
      (( lbl_pad < 0 )) && lbl_pad=0
      row=$(printf " %02d %s %s%*s %s" $((i + 1)) "$icon" "$cur_lbl" "$lbl_pad" "" "${_metas[$i]}")
      (( ${#row} > max_row )) && row="${row:0:max_row-1}…"
      pad=$(( max_row - ${#row} ))
      (( pad > 0 )) && row+=$(printf '%*s' "$pad" '')
      PADDED_ROWS+=("$row")
    done
  }

  render_single_menu_row() {
    local r_idx=$1 sel_idx=$2
    local r_txt="${PADDED_ROWS[$r_idx]}"
    if [ "${_avail[$r_idx]}" != 1 ]; then
      printf ' %s│%s %s%s%s %s│%s\e[K\n' "$C_BORDER_HI" "$C_OFF" "$C_DIM" "$r_txt" "$C_OFF" "$C_BORDER_HI" "$C_OFF"
    elif (( r_idx == sel_idx )); then
      printf ' %s│%s %s%s%s %s│%s\e[K\n' "$C_BORDER_HI" "$C_OFF" "$BAR_ON" "$r_txt" "$C_OFF" "$C_BORDER_HI" "$C_OFF"
    else
      printf ' %s│%s %s %s│%s\e[K\n' "$C_BORDER_HI" "$C_OFF" "$r_txt" "$C_BORDER_HI" "$C_OFF"
    fi
  }

  build_padded_rows

  # Header takes 4 lines (top + 2 rows + bottom), Menu box_top is line 5, so row 0 is at terminal line 6!
  local MENU_FIRST_ROW=6
  local CONTEXT_FIRST_ROW=$(( MENU_FIRST_ROW + n + 1 ))

  while true; do
    if (( need_full_redraw )); then
      build_padded_rows
      MENU_FIRST_ROW=6
      CONTEXT_FIRST_ROW=$(( MENU_FIRST_ROW + n + 1 ))

      # Assemble entire screen in memory and flush atomically inside DEC Synchronized Update (\e[?2026h ... \e[?2026l)
      local frame_buf
      frame_buf=$(
        render_header "$step_id" 0
        box_top "$box_title" "${n} opciones" "$C_BORDER_HI"
        for ((i = 0; i < n; i++)); do
          render_single_menu_row "$i" "$idx"
        done
        box_bottom "" "$C_BORDER_HI"
        if [ "$step_id" = "hub" ]; then
          render_fixed_context_box "${_targets[$idx]:-}" "${_labels[$idx]:-}"
        fi
        render_keybar "$step_id"
      )
      printf '\e[?2026h%s\e[J\e[?2026l' "$frame_buf"
      need_full_redraw=0
      prev_idx=$idx
    elif (( idx != prev_idx )); then
      # SURGICAL ZERO-FLICKER UPDATE: Only redraw the 2 changed menu rows (+ context box in hub)
      local patch_buf
      patch_buf=$(
        printf '\e[%d;1H' $(( MENU_FIRST_ROW + prev_idx ))
        render_single_menu_row "$prev_idx" "$idx"
        printf '\e[%d;1H' $(( MENU_FIRST_ROW + idx ))
        render_single_menu_row "$idx" "$idx"
        if [ "$step_id" = "hub" ]; then
          printf '\e[%d;1H' "$CONTEXT_FIRST_ROW"
          render_fixed_context_box "${_targets[$idx]:-}" "${_labels[$idx]:-}"
        fi
      )
      printf '\e[?2026h%s\e[?2026l' "$patch_buf"
      prev_idx=$idx
    fi

    local tok
    tok=$(read_key_token)
    case "$tok" in
      UP|k|K)   (( idx = (idx - 1 + n) % n )) ;;
      DOWN|j|J) (( idx = (idx + 1) % n )) ;;
      BACK|b|B) return 2 ;;
      ENTER)
        if [ "${_avail[$idx]}" = 1 ]; then
          CHOICE=$idx
          return 0
        fi
        ;;
      [1-9])
        if (( tok <= n )) && [ "${_avail[$((tok - 1))]}" = 1 ]; then
          CHOICE=$((tok - 1))
          return 0
        fi
        ;;
      n|N)
        if [ "$step_id" = "hub" ]; then
          AGENT=""
          ZONE=""
          CHOICE=-10
          return 0
        fi
        ;;
      v|V)
        subcmd_cockpit "${ZONE:-${ZONES[0]}}"
        return 3
        ;;
      f|F)
        launch_fzf_cockpit || true
        need_full_redraw=1
        ;;
      o|O) cycle_role; need_full_redraw=1 ;;
      y|Y) cycle_perm_mode; need_full_redraw=1 ;;
      c|C) REMOTE=$(( 1 - REMOTE )); need_full_redraw=1 ;;
      p|P) cycle_profile; need_full_redraw=1 ;;
      w|W) prompt_worktree_modal; need_full_redraw=1 ;;
      g|G) BG=$(( 1 - BG )); need_full_redraw=1 ;;
      t|T)
        if [ "$step_id" = "hub" ] && [ -n "${_targets[$idx]:-}" ]; then
          prompt_send_task_modal "${_targets[$idx]}"
          return 3
        fi
        ;;
      d|D)
        printf '\e[2J\e[H'
        subcmd_doctor
        printf ' Presiona cualquier tecla para volver...'
        IFS= read -rsn1 _ || true
        return 3
        ;;
      s|S)
        printf '\e[2J\e[H'
        subcmd_status
        subcmd_bus status
        printf ' Presiona cualquier tecla para volver...'
        IFS= read -rsn1 _ || true
        need_full_redraw=1
        ;;
      \?|h|H|i|I)
        printf '\e[2J\e[H'
        info
        printf ' Presiona cualquier tecla para volver...'
        IFS= read -rsn1 _ || true
        need_full_redraw=1
        ;;
      l|L)
        if [ "$step_id" = "hub" ] && [ -n "${_targets[$idx]:-}" ]; then
          printf '\e[2J\e[H'
          subcmd_logs "${_targets[$idx]}" 35
          printf ' %s[← / ⌫ / Enter]%s Volver al menú...' "$KEY_BADGE" "$C_OFF"
          IFS= read -rsn1 _ || true
          need_full_redraw=1
        fi
        ;;
      r|R)
        if [ "$step_id" = "hub" ] && [ -n "${_targets[$idx]:-}" ]; then
          tmux respawn-pane -k -t "${_targets[$idx]}" 2>/dev/null || true
          return 3
        fi
        ;;
      x|X)
        if [ "$step_id" = "hub" ] && [ -n "${_targets[$idx]:-}" ]; then
          local t_kill="${_targets[$idx]}"
          printf '\n %s▲ ¿Cerrar "%s"? [y/N]:%s ' "$C_ERR$C_BOLD" "$t_kill" "$C_OFF"
          local confirm=''
          IFS= read -rsn1 confirm || true
          if [[ "$confirm" =~ ^[yYsS]$ ]]; then
            tmux kill-session -t "$t_kill" 2>/dev/null || true
            rm -f "$PRAMA_BUS_DIR/state/${t_kill}.env" 2>/dev/null || true
            return 3
          fi
          need_full_redraw=1
        fi
        ;;
      q|Q|QUIT)
        tui_leave_screen
        exit 0
        ;;
    esac
  done
}
