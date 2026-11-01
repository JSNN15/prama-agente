#!/usr/bin/env bash
# lib/roles.sh — Role Profiles (Coordinator, Executor, Reader, Daemon) & In-Pane Supervisor
# Copyright 2026 Julian Neira Nova
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
# The prompt is in the interface language (the agents answer and report in it); the
# [PRAMA-SWARM ROLE: …] header is machine-parsed and identical in every language.
build_role_system_prompt() {
  local role=$1 session_name=$2 zone=$3
  session_name=${session_name//[^A-Za-z0-9_-]/}
  zone=${zone//[^[:print:]]/}
  local team
  team=$(state_get "$session_name" TEAM "${PRAMA_TEAM:-$PRAMA_DEFAULT_TEAM}")
  team=${team//[^a-z0-9-]/}
  local agents_list=${AGENTS[*]}
  agents_list=${agents_list// /|}
  # Isolated teams: the executor's branch and the team's integration branch (validated git names).
  local wt_branch=${PRAMA_WT_BRANCH:-} wt_base=${PRAMA_TEAM_BASE:-} isolated=${PRAMA_TEAM_ISOLATE:-0}
  wt_branch=${wt_branch//[^A-Za-z0-9._\/-]/} wt_base=${wt_base//[^A-Za-z0-9._\/-]/}
  [ "$role" = coordinator ] && [ -z "$wt_base" ] && (( isolated )) && wt_base=main
  local wt_text='' close_text=''
  case ${PRAMA_UI_LANG:-en} in
    es) _role_extra_es; _role_prompt_es ;;
    *)  _role_extra_en; _role_prompt_en ;;
  esac
}

# Paragraphs that depend on the team: isolation (worktrees) and closing. Read the locals above.
_role_extra_en() {
  if [ "$role" = executor ] && [ -n "$wt_branch" ]; then
    wt_text="
You work in your OWN git worktree on branch '$wt_branch' (created from '${wt_base:-the zone branch}');
other executors have their own. Commit your work there in small commits with clear messages. Do not
switch branches, merge into '${wt_base:-the base}', push, or touch other worktrees: the coordinator integrates.
If dependencies are missing in this worktree (node_modules, .venv…), install them here.
Before reporting: run the tests, commit, then report with the branch name, what changed and the
evidence (test command and result). If you change a shared interface, say so in the report.
When the coordinator asks you to catch up: prama-agent worktree sync  (merges '${wt_base:-the base}' into
your branch; resolve any conflict here, then git add + git commit)."
  fi
  if [ "$role" = coordinator ]; then
    if (( isolated )); then
      wt_text="
ISOLATED TEAM: each executor works in its own git worktree on branch prama/$team/<name>, created from
'$wt_base'. You stay on '$wt_base' in the zone folder and integrate:
- prama-agent worktree status                 every branch: commits to merge, uncommitted files, behind
- git log $wt_base..<branch> · git diff $wt_base...<branch>   review before merging
- prama-agent worktree merge <session>        merge into '$wt_base' (aborts on conflict: '$wt_base' stays clean)
- prama-agent worktree sync <session>         bring a branch up to date (or ask the executor to run it)
Split work so executors touch different files; merge ONE branch at a time, with the tests
('prama-agent worktree merge <session> --test \"<test command>\"' undoes a merge that breaks them);
after each merge ask the others to sync. Never let an executor merge into '$wt_base' itself."
    fi
    close_text="
How to run the team (what works in multi-agent studies):
- Plan before delegating: split the objective into tasks with explicit dependencies and, as far as
  possible, disjoint files. Each assignment says the goal, the files it may touch, the expected output
  and how it is checked. Do not parallelise sequential work; 2-4 executors is usually the sweet spot.
- Done means verified: ask for evidence (test command and result, commit) and check the objective
  itself, not only that it compiles, before you integrate.
- Shared interfaces: when a task changes one (API, schema, types), tell the other executors at once
  and record it in the team memory.
- You coordinate, review and integrate; leave the implementation to the executors.
Closing: 'prama-agent fleet kill <session>' closes one of your agents. When the objective is done and
reported (or the operator asks), 'prama-agent swarm stop $session_name' closes your whole team, you
last; merged worktrees are removed, unmerged work is kept. Save what matters to the team memory first."
  fi
}

_role_extra_es() {
  if [ "$role" = executor ] && [ -n "$wt_branch" ]; then
    wt_text="
Trabajas en TU PROPIO git worktree en la rama '$wt_branch' (creada desde '${wt_base:-la rama de la zona}');
los demás ejecutores tienen el suyo. Haz commits pequeños y con mensajes claros ahí. No cambies de rama,
no hagas merge en '${wt_base:-la base}', no hagas push ni toques otros worktrees: el coordinador integra.
Si faltan dependencias en este worktree (node_modules, .venv…), instálalas aquí.
Antes de reportar: corre los tests, haz commit y reporta con el nombre de la rama, qué cambió y la
evidencia (comando de tests y resultado). Si cambias una interfaz compartida, dilo en el reporte.
Cuando el coordinador te pida ponerte al día: prama-agent worktree sync  (trae '${wt_base:-la base}' a tu
rama; resuelve aquí cualquier conflicto y luego git add + git commit)."
  fi
  if [ "$role" = coordinator ]; then
    if (( isolated )); then
      wt_text="
EQUIPO AISLADO: cada ejecutor trabaja en su propio git worktree en la rama prama/$team/<nombre>, creada
desde '$wt_base'. Tú te quedas en '$wt_base' en la carpeta de la zona e integras:
- prama-agent worktree status                 cada rama: commits por integrar, archivos sin commit, atraso
- git log $wt_base..<rama> · git diff $wt_base...<rama>   revisa antes de integrar
- prama-agent worktree merge <sesión>         integra en '$wt_base' (aborta si hay conflicto: '$wt_base' queda limpia)
- prama-agent worktree sync <sesión>          pone al día una rama (o pídele al ejecutor que lo haga)
Reparte el trabajo para que los ejecutores toquen archivos distintos; integra UNA rama a la vez, con los
tests ('prama-agent worktree merge <sesión> --test \"<comando de tests>\"' deshace un merge que los rompe);
después de cada merge pide a los demás que hagan sync. Nunca dejes que un ejecutor integre en '$wt_base'."
    fi
    close_text="
Cómo llevar el equipo (lo que funciona según los estudios de sistemas multiagente):
- Planifica antes de delegar: divide el objetivo en tareas con dependencias explícitas y, en lo posible,
  archivos distintos. Cada encargo dice el objetivo, los archivos que puede tocar, el resultado esperado y
  cómo se verifica. No paralelices trabajo secuencial; 2 a 4 ejecutores suele ser lo óptimo.
- Listo significa verificado: pide evidencia (comando de tests y resultado, commit) y revisa el objetivo
  mismo, no solo que compile, antes de integrar.
- Interfaces compartidas: cuando una tarea cambia una (API, esquema, tipos), avisa de inmediato a los
  demás ejecutores y regístralo en la memoria del equipo.
- Tú coordinas, revisas e integras; deja la implementación a los ejecutores.
Cierre: 'prama-agent fleet kill <sesión>' cierra uno de tus agentes. Cuando el objetivo esté listo y
reportado (o el operador lo pida), 'prama-agent swarm stop $session_name' cierra todo tu equipo, a ti al
final; los worktrees integrados se borran y el trabajo sin integrar se conserva. Antes guarda lo
importante en la memoria del equipo."
  fi
}

# _role_prompt_en / _role_prompt_es — the role prompt text; they read the locals of
# build_role_system_prompt (role session_name zone team agents_list).
_role_prompt_en() {
  local bus_help models_help
  bus_help=$(cat <<EOF
Multi-agent bus commands (run them with your Bash tool):
- See live agents, roles, queues and latest events:  prama-agent bus status
- Assign a task to an exact session or to a role:    prama-agent bus assign <session|coordinator|executor|reader|daemon> "<instruction>"
- Report a result to the coordinator:                prama-agent bus report "<summary>"
- See the pending tasks in your queue:               prama-agent bus inbox $session_name
- Read another agent's terminal:                     prama-agent logs <session> 80
- Report a prama-agent bug (not one in your task):   prama-agent feedback "<command, what you expected, what you got>"
- Team memory (decisions, conventions, findings, where the work stands; it survives restarts and
  reaches new agents): read it with 'prama-agent memory show' when you start; add a short note with
  'prama-agent memory add "<note>"' when you decide or learn something durable
  (--zone-wide for facts every team of the zone needs).
EOF
)
  models_help="Models: claude → opus | sonnet | haiku (or a full id); agy → ids from 'prama-agent fleet models agy'
(e.g. gemini-3.8-flash-high). Use fast/cheap models for mechanical tasks (tests, scoped refactors,
documentation) and the most capable ones for design and delicate changes."
  if is_in opencode "${AGENTS[@]}"; then
    models_help+="
opencode (experimental) → openrouter/<provider>/<model> (e.g. openrouter/qwen/qwen3-coder:free);
list them with: prama-agent fleet models opencode."
  fi
  case "$role" in
    coordinator)
      cat <<EOF
[PRAMA-SWARM ROLE: COORDINATOR | session=$session_name | zone=$zone | team=$team]
You are the COORDINATOR / ARCHITECT agent of team '$team' in zone '$zone'.
Your mission is to plan, split the work, review code and coordinate the agents of your team.
Your team is the agents you launch (fleet spawn, swarm): their reports and alerts come to you.
The zone may have other teams with other goals: do not assign them work or manage their agents.
Delegate with 'prama-agent bus assign', check progress with 'prama-agent bus status' and
'prama-agent logs <session>'. Reports from other agents reach you as "[REPORT FROM <session>]: …".
Fleet alerts arrive as "[PRAMA ALERT] …" (an agent blocked by login, quota, credit,
model, or stopped) and when an account passes ${PRAMA_QUOTA_WARN:-90}% of its quota (5h or 7d window): decide whether to
restart it, change its model, reassign its task, spread work over other agents/models or tell the human.
$bus_help

Fleet management (you manage your agents; everything returns JSON with --json):
- Full status (state, block and reason, model, preset, queue, quota % and reset): prama-agent fleet status --json
- Available agents and presets (profiles with skills):              prama-agent fleet presets
- Launch an extra agent:  prama-agent fleet spawn <$agents_list> $zone [--role executor|reader] [--model M] [--preset P] [--name N] [--worktree branch] [--task "initial instruction"]
- Add several executors to your team at once: prama-agent swarm $zone --workers agy:3 [--worker-model M] --no-open
- Assigning by role (e.g. 'bus assign executor "…"') picks from your team's agents first.
- Change the model (restarts in the same pane and keeps the conversation): prama-agent fleet model <session> <model>
- Edit the configuration (model, effort, preset, permissions):  prama-agent fleet edit <session> [--model M] [--effort E] [--preset P]
- Restart an agent (e.g. after an error):                prama-agent fleet restart <session>
- Close an agent you no longer need:                     prama-agent fleet kill <session>
$models_help
Keep the team memory current: record each decision, the plan and who does what with
'prama-agent memory add', so a restarted coordinator or a new agent can pick up the work.
Close the extra agents when you are done.
Limit of simultaneous agents: ${PRAMA_FLEET_MAX:-8}.$wt_text$close_text
EOF
      ;;
    executor)
      cat <<EOF
[PRAMA-SWARM ROLE: EXECUTOR | session=$session_name | zone=$zone]
You are an EXECUTOR agent in zone '$zone'.
Your mission is to implement code, run tests and verify that everything builds without errors.
Tasks reach you as "[TASK FROM <session>]: …". When you finish, report your result with:
  prama-agent bus report "<concise summary of changes and tests>"$wt_text
$bus_help
EOF
      ;;
    reader)
      cat <<EOF
[PRAMA-SWARM ROLE: READER (READ-ONLY) | session=$session_name | zone=$zone]
You are a READER / AUDITOR agent in strict READ-ONLY mode in zone '$zone'.
Do NOT modify files or run destructive commands. Analyze architecture, logs and bugs,
and report your findings with:
  prama-agent bus report "<findings>"
$bus_help
EOF
      ;;
    daemon)
      cat <<EOF
[PRAMA-SWARM ROLE: DAEMON WORKER | session=$session_name | zone=$zone]
You are an autonomous WORKER / DAEMON agent in zone '$zone', running in headless mode.
Process the requested task from start to finish without asking for interactive confirmation, and end with
a clear summary (the supervisor logs it on the bus). If the task asks for it, you can report with:
  prama-agent bus report "<summary>"
$bus_help
EOF
      ;;
  esac
}

_role_prompt_es() {
  local bus_help models_help
  bus_help=$(cat <<EOF
Comandos del bus multi-agente (ejecútalos con tu herramienta Bash):
- Ver agentes vivos, roles, colas y últimos eventos: prama-agent bus status
- Asignar una tarea a una sesión exacta o a un rol:  prama-agent bus assign <sesión|coordinator|executor|reader|daemon> "<instrucción>"
- Reportar un resultado al coordinador:              prama-agent bus report "<resumen>"
- Ver tareas pendientes en tu cola:                  prama-agent bus inbox $session_name
- Leer la terminal de otro agente:                   prama-agent logs <sesión> 80
- Reportar un fallo de prama-agent (no de tu tarea):  prama-agent feedback "<comando, qué esperabas, qué obtuviste>"
- Memoria del equipo (decisiones, convenciones, hallazgos, en qué va el trabajo; sobrevive reinicios
  y llega a los agentes nuevos): léela con 'prama-agent memory show' al empezar; agrega una nota breve
  con 'prama-agent memory add "<nota>"' cuando decidas o aprendas algo durable
  (--zone-wide para hechos que necesitan todos los equipos de la zona).
EOF
)
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
[PRAMA-SWARM ROLE: COORDINATOR | session=$session_name | zone=$zone | team=$team]
Eres el Agente COORDINADOR / ARQUITECTO del equipo '$team' en la zona '$zone'.
Tu misión es planificar, dividir el trabajo, revisar código y coordinar a los agentes de tu equipo.
Tu equipo son los agentes que lanzas tú (fleet spawn, swarm): sus reportes y alertas te llegan a ti.
La zona puede tener otros equipos con otros objetivos: no les asignes trabajo ni gestiones sus agentes.
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
- Sumar varios ejecutores a tu equipo de una vez: prama-agent swarm $zone --workers agy:3 [--worker-model M] --no-open
- Asignar por rol (p. ej. 'bus assign executor "…"') elige primero entre los agentes de tu equipo.
- Cambiar el modelo (reinicia en el mismo panel y conserva la conversación): prama-agent fleet model <sesión> <modelo>
- Editar configuración (modelo, esfuerzo, preset, permisos):  prama-agent fleet edit <sesión> [--model M] [--effort E] [--preset P]
- Reiniciar un agente (p. ej. tras un error):                prama-agent fleet restart <sesión>
- Cerrar un agente que ya no necesitas:                      prama-agent fleet kill <sesión>
$models_help
Mantén al día la memoria del equipo: registra cada decisión, el plan y quién hace qué con
'prama-agent memory add', para que un coordinador reiniciado o un agente nuevo retome el trabajo.
Cierra los agentes extra al terminar.
Límite de agentes simultáneos: ${PRAMA_FLEET_MAX:-8}.$wt_text$close_text
EOF
      ;;
    executor)
      cat <<EOF
[PRAMA-SWARM ROLE: EXECUTOR | session=$session_name | zone=$zone]
Eres un Agente EJECUTOR en la zona '$zone'.
Tu misión es implementar código, ejecutar tests y verificar que todo compile sin errores.
Las tareas te llegarán como "[TAREA DE <sesión>]: …". Al terminar, reporta tu resultado con:
  prama-agent bus report "<resumen conciso de cambios y tests>"$wt_text
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
  box_top "$(_t '✖ COULD NOT START THE AGENT')" "${_RUNNER_SESSION:-}" "$C_ERR"
  box_row "$C_ERR" "$1"
  box_bottom "$(_t 'Press a key to close')" "$C_ERR"
  [ -t 0 ] && { IFS= read -r -n1 -t 300 _ || true; }
  _runner_cleanup
  exit 1
}

# Compact one-line daemon heartbeat. Contains the PRAMA_DAEMON marker used by detect_session_state.
_daemon_heartbeat() {
  local session=$1 cycle=$2 left=$3 eol=${4:-}
  local qs qr cr='' clr='' next mid
  qs=$(queue_len "$session"); qr=$(queue_len daemon)
  [ -t 1 ] && { cr=$'\r'; clr=$'\e[K'; }
  if [ "$left" = oneshot ]; then _tv next 'oneshot: end'; else _tv next 'next in %3ss' "$left"; fi
  _tv mid '· cycle #%d · queue' "$cycle"
  printf '%s %s♺%s %s%s%s %s %s%s%s+%s · %s %sPRAMA_DAEMON%s%s%s' \
    "$cr" "$C_PURP" "$C_OFF" "$C_MUTED" "$(date +%H:%M:%S)" "$C_OFF" "$mid" \
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
  box_row "$C_PURP" "$(_t 'Zone: %s · Branch: %s · Interval: %ss' "${C_NEON}$target_dir${C_OFF}" "${C_NEON}⎇ $(_runner_branch "$target_dir")${C_OFF}" "$interval")"
  local recur=''
  [ -n "${PRAMA_DAEMON_TASK:-}" ] && recur=" $(_t '→ recurring task')"
  box_row "$C_PURP" "$(_t 'Queues: %s → %s (shared)%s' "${C_BOLD}$session${C_OFF}" "${C_BOLD}daemon${C_OFF}" "$recur")"
  if [ "$perm" = "ask" ] || [ "$perm" = "safe" ]; then
    box_row "$C_PURP" "${C_BRASS}$(_t '▲ ASK mode while headless: nobody is there to approve, so tools that')${C_OFF}"
    box_row "$C_PURP" "${C_BRASS}$(_t '  need permission will be DENIED. Use --plan or --yolo if you need them.')${C_OFF}"
  fi
  box_bottom "$(_t 'prama-agent bus assign %s "<task>"' "$session")" "$C_PURP"

  local cycle=0 task src rc
  while true; do
    (( cycle++ ))
    if [ "$(state_get "$session" RESTART_REQ)" = 1 ]; then
      state_set "$session" RESTART_REQ=
      compose_session_cmd "$session"
      set -- "${CMD[@]}"
      printf '\n %s%s%s %s\n' "$C_NEON" "$(_t '↻ Reconfigured')" "$C_OFF" "${AGENT_MODEL:+$(_t 'model %s' "$AGENT_MODEL")}"
    fi
    task='' src=''
    if task=$(queue_pop "$session"); then src=$session
    elif task=$(queue_pop daemon); then src=daemon
    elif [ -n "${PRAMA_DAEMON_TASK:-}" ]; then task=$PRAMA_DAEMON_TASK; src=recurrente
    else task=''
    fi

    if [ -n "$task" ]; then
      printf '\n %s%s%s %s(%s · %s)%s %s\n\n' "$C_LIVE$C_BOLD" "$(_t '▸ TASK')" "$C_OFF" "$C_MUTED" "$src" "$(date +%H:%M:%S)" "$C_OFF" \
        "$(truncate_cols "${task//$'\n'/ }" $(( W - 20 )))"
      bus_event started "$session" "$src" "$task"
      build_daemon_turn "$session" "$perm" "$task" "$zone" -- "$@"
      rc=0
      "${DAEMON_TURN[@]}" || rc=$?
      bus_event completed "$session" "$src" "$task" "$rc"
      if (( rc == 0 )); then
        printf '\n %s%s%s %s(rc=0)%s\n' "$C_LIVE" "$(_t '✔ completed')" "$C_OFF" "$C_MUTED" "$C_OFF"
      else
        printf '\n %s%s%s %s(rc=%d)%s\n' "$C_ERR" "$(_t '✖ failed')" "$C_OFF" "$C_MUTED" "$rc" "$C_OFF"
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
  (( $# >= 7 )) || die "$(_t 'internal_runner: not enough arguments')"
  local session_name=$1 target_dir=$2 profile=${3:-default} oneshot=${4:-0}
  local role=${5:-executor} daemon_interval=${6:-60} perm_mode=${7:-ask}
  shift 7
  [ "${1:-}" = "--" ] && shift
  (( $# )) || die "$(_t "internal_runner: missing the agent command after '--'")"
  [ -n "$session_name" ] || die "$(_t 'internal_runner: empty session')"
  [[ "$oneshot" =~ ^[01]$ ]] || oneshot=0

  # Defensive: the entrypoint is expected to call prama_init first (config + providers.env).
  (( ${#ZONES[@]} )) || prama_init

  _RUNNER_SESSION=$session_name
  trap '_runner_cleanup' EXIT
  trap '_runner_cleanup; exit 130' INT TERM HUP

  type restore_locale >/dev/null 2>&1 && restore_locale
  cd "$target_dir" 2>/dev/null || _runner_fatal "$(_t 'The working directory does not exist: %s' "$target_dir")"
  export PRAMA_SESSION="$session_name" PRAMA_ROLE="$role"
  local sf; sf=$(state_file "$session_name")
  export PRAMA_SL_CACHE="${sf%.env}.sl"   # status line throttle cache (see bin/prama-agent)
  # IS_SANDBOX lets claude accept --dangerously-skip-permissions as root; only for YOLO.
  if [ "$perm_mode" = "yolo" ]; then export IS_SANDBOX=1; else unset IS_SANDBOX; fi

  # Provider secrets are loaded here (never passed through tmux -e / argv). Validate in a subshell
  # first so a missing key shows an error box instead of silently closing the pane.
  local perr
  if ! perr=$( (apply_provider_profile "$profile") 2>&1 ); then
    _runner_fatal "$(_t "Profile '%s': %s" "$profile" "$(strip_ansi "${perr//$'\n'/ }")")"
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
      else printf ' %s✖ %s%s\n' "$C_ERR" "$(_t 'Profile %s: %s' "$profile" "$(strip_ansi "${perr//$'\n'/ }")")" "$C_OFF"; fi
      if [ "$perm_mode" = "yolo" ]; then export IS_SANDBOX=1; else unset IS_SANDBOX; fi
      _runner_env "$session_name" "$agent" "$perm_mode" "$role" "$zone"
      health_set "$session_name" HEALTH=ok REASON= DETAIL=
      printf '\n %s%s%s %s\n\n' "$C_NEON$C_BOLD" "$(_t '↻ Restarting with the new configuration')" "$C_OFF" \
        "$(state_get "$session_name" MODEL)${PRESET:+ · preset $PRESET}"
      bus_event restarted "$session_name" "$session_name" "model=$(state_get "$session_name" MODEL) preset=$PRESET"
    fi
    refresh_dimensions
    local pending
    pending=$(queue_len "$session_name")
    box_top "✦ $PRAMA_BRAND // $session_name" "RUN #$run_count" "$C_BORDER_HI"
    box_row "$C_BORDER_HI" "$(role_badge "$role") · ${C_NEON}$agent${C_OFF} · $(_t 'profile %s · permissions %s' "${C_NEON}$profile${C_OFF}" "${C_BRASS}${perm_mode^^}${C_OFF}") · ${C_PURP}⎇ $(_runner_branch "$target_dir")${C_OFF}"
    if (( pending > 0 )); then
      box_row "$C_BORDER_HI" "${C_BRASS}$(_t '▲ %d queued task(s):' "$pending")${C_OFF} prama-agent bus inbox $session_name"
    fi
    box_bottom "$(_t '%s menu · wheel/Ctrl+b [ scroll · %s' "$PRAMA_MENU_KEY" "$target_dir")" "$C_BORDER_HI"
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
        box_top "$(_t '▲ AGENT EXITED')" "$(_t 'code %d' "$exit_code")" "$C_BRASS"
        box_row "$C_BRASS" "${C_MUTED}$(_t "This session's scrollback is kept (%s)." "$session_name")${C_OFF}"
        box_sep "$C_BRASS"
        local a_r a_s a_m a_q
        _tv a_r 'Relaunch'; _tv a_s 'Shell in zone'; _tv a_m 'Back to the menu'; _tv a_q 'Close'
        box_row "$C_BRASS" "${C_LIVE}${C_BOLD}[↵/r]${C_OFF} $a_r   ${C_NEON}${C_BOLD}[s]${C_OFF} $a_s   ${C_PURP}${C_BOLD}[m]${C_OFF} $a_m   ${C_ERR}${C_BOLD}[q]${C_OFF} $a_q"
        box_bottom "STANDBY" "$C_BRASS"
        show_menu=0
      fi
      printf ' %s %sPRAMA_STANDBY%s' "$(_t '⌘ Action [r/s/m/q]:')" "$C_DIM" "$C_OFF"
      printf '\e[%dD' 13   # park the cursor before the (dim) marker
      local act=''
      IFS= read -r -n1 act || { _runner_cleanup; exit 0; }
      printf '\n'
      case "$act" in
        ''|r|R)
          printf ' %s\n\n' "$(_t '↻ Relaunching the agent...')"
          _runner_title "$session_name" "$(role_badge "$role") · $agent · $session_name"
          break
          ;;
        s|S)
          printf ' %s\n' "$(_t '▸ Shell in %s (type "exit" to return to the supervisor)' "$target_dir")"
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
