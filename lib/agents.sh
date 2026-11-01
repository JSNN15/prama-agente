#!/usr/bin/env bash
# lib/agents.sh — Agent CLI flag builders, provider profiles, git worktrees & the launch pipeline
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0

AVAILABLE_PROFILES=(default openrouter deepseek glm local)
AVAILABLE_PERM_MODES=(ask plan yolo)

agent_installed() { command -v "$1" >/dev/null 2>&1; }

# Model ids: aliases (opus), full ids (claude-opus-5-5[1m]) or provider paths
# (openrouter/qwen/qwen3-coder:free). Validated because they end up in argv and JSON.
MODEL_RE='^[][A-Za-z0-9._:/@#-]{1,120}$'
valid_model() { [[ "$1" =~ $MODEL_RE ]]; }

# Extended launch spec, read by build_agent_command (all optional):
#   AGENT_MODEL   model id / alias        (claude, agy: --model; opencode: provider/model in its config)
#   AGENT_EFFORT  low|medium|high|xhigh|max   (claude, agy: --effort)
#   AGENT_SID     conversation id: claude --session-id on first start, --resume on restarts;
#                 agy --conversation on restarts (id reported by its hooks)
#   AGENT_RESUME  1 = continue the previous conversation (restart in place)
#   PRESET        preset name (see preset_load); its flags are appended
AGENT_MODEL='' AGENT_EFFORT='' AGENT_SID='' AGENT_RESUME=0 PRESET=''
[ -n "${PASS+x}" ] || PASS=()

# compose_session_cmd <session> → rebuilds CMD for an existing session from its saved spec
# (state file + pass-through args), resuming its conversation. Used for in-place restarts.
compose_session_cmd() {
  local s=$1 agent role zone perm remote profile role_prompt=''
  agent=$(state_get "$s" AGENT claude) role=$(state_get "$s" ROLE executor) zone=$(state_get "$s" ZONE)
  perm=$(state_get "$s" PERM ask) remote=$(state_get "$s" REMOTE 0) profile=$(state_get "$s" PROFILE default)
  AGENT_MODEL=$(state_get "$s" MODEL) AGENT_EFFORT=$(state_get "$s" EFFORT) PRESET=$(state_get "$s" PRESET)
  AGENT_SID=$(health_get "$s" AGENT_SID "$(state_get "$s" SESSION_ID)")
  AGENT_RESUME=1
  [ "$role" = daemon ] && AGENT_SID='' AGENT_RESUME=0
  PASS=()
  local af
  af=$(state_args_file "$s")
  [ -f "$af" ] && mapfile -d '' -t PASS < "$af"
  [ "$role" != executor ] && role_prompt=$(build_role_system_prompt "$role" "$s" "$zone")
  PROFILE=$profile build_agent_command "$agent" "$perm" "$remote" "$s" "$role_prompt" ${PASS[@]+"${PASS[@]}"}
  COMPOSED_ROLE_PROMPT=$role_prompt
}

# True when the pass-through args already pick a conversation (then prama does not add one).
_pass_has() {
  local a want
  for a in "${@:2}"; do
    for want in $1; do [[ "$a" == "$want" || "$a" == "$want="* ]] && return 0; done
  done
  return 1
}

# ── Exact CLI flags per agent binary ────────────────────────────────────────
# build_agent_command <agent> <perm_mode> <remote 0|1> <session> <role_prompt> [pass-through...]
# Fills the global array CMD. Remote control for claude is only added with the native
# (default) profile, because it requires an Anthropic subscription login.
# opencode has no flags for model, role prompt or plan mode: those travel in
# OPENCODE_CONFIG_CONTENT, built by agent_runtime_env inside the pane.
build_agent_command() {
  local agent=$1 perm_mode=$2 remote_flag=$3 session_name=$4 role_prompt=$5
  shift 5
  CMD=("$agent")
  [ -n "$PRESET" ] && preset_load "$PRESET" >/dev/null 2>&1

  case "$perm_mode" in
    yolo|skip)
      case "$agent" in
        claude|agy) CMD+=(--dangerously-skip-permissions) ;;
        opencode)   CMD+=(--auto) ;;
      esac ;;
    plan|readonly)
      case "$agent" in
        claude) CMD+=(--permission-mode plan) ;;
        agy)    CMD+=(--mode plan) ;;
      esac ;;
  esac

  if (( remote_flag )); then
    case "$agent" in
      claude) [ "${PROFILE:-default}" = "default" ] && CMD+=(--remote-control "$session_name") ;;
      agy)    CMD+=(--remote-control) ;;
    esac
  fi

  local model=${AGENT_MODEL:-${PRESET_KV[MODEL]:-}} effort=${AGENT_EFFORT:-${PRESET_KV[EFFORT]:-}}
  case "$agent" in
    claude)
      [ -n "$model" ] && CMD+=(--model "$model")
      [ -n "$effort" ] && CMD+=(--effort "$effort")
      if [ -n "$AGENT_SID" ] && ! _pass_has "--resume -r --continue -c --session-id" "$@"; then
        if (( AGENT_RESUME )); then CMD+=(--resume "$AGENT_SID"); else CMD+=(--session-id "$AGENT_SID"); fi
      fi
      if (( ${PRAMA_HOOKS:-1} )) && ! _pass_has "--settings" "$@"; then
        local hs
        hs=$(claude_hook_settings 2>/dev/null) && CMD+=(--settings "$hs")
      fi
      _preset_claude_flags
      local prompt=$role_prompt extra
      extra=$(preset_prompt)
      [ -n "$extra" ] && prompt+="${prompt:+$'\n\n'}$extra"
      [ -n "$prompt" ] && CMD+=(--append-system-prompt "$prompt") ;;
    agy)
      [ -n "$model" ] && CMD+=(--model "$model")
      [ -n "$effort" ] && CMD+=(--effort "$effort")
      # Conversation id comes from agy's hooks (conversationId); restarts resume it.
      if (( AGENT_RESUME )) && [ -n "$AGENT_SID" ] && ! _pass_has "--conversation --continue -c" "$@"; then
        CMD+=(--conversation "$AGENT_SID")
      fi
      # Status line telemetry (quota) stacked under agy's own status line; --settings is
      # session-only and never saved to the user's settings.
      if (( ${PRAMA_STATUSLINE:-1} )) && ! _pass_has "--settings" "$@"; then
        local sl
        printf -v sl '%q --internal-statusline agy' "$SELF_PATH"
        CMD+=(--settings "{\"statusLine\":{\"type\":\"command\",\"command\":\"$(json_escape "$sl")\",\"stack_with_default\":true}}")
      fi ;;
    opencode)
      (( AGENT_RESUME )) && ! _pass_has "--continue -c --session -s" "$@" && CMD+=(--continue) ;;
  esac

  (( $# )) && CMD+=("$@")
  return 0
}

# Environment the agent needs inside its pane (never on argv). Called by the supervisor.
# agent_runtime_env <agent> <session> <perm> <role_prompt>
agent_runtime_env() {
  local agent=$1 session=$2 perm=$3 role_prompt=$4
  case "$agent" in
    opencode)
      # API keys for opencode's built-in providers, from providers.env.
      local k
      for k in OPENROUTER_API_KEY DEEPSEEK_API_KEY ZHIPU_API_KEY GROQ_API_KEY TOGETHER_API_KEY \
               DEEPINFRA_API_KEY CEREBRAS_API_KEY MOONSHOT_API_KEY; do
        [ -n "${!k:-}" ] && export "${k?}"
      done
      [ -n "${OPENROUTER_API_KEY:-}" ] || unset OPENROUTER_API_KEY
      local model=${AGENT_MODEL:-${PRESET_KV[MODEL]:-$PRAMA_OPENCODE_MODEL}} cfg extra pf
      cfg="\"model\":\"$(json_escape "$model")\""
      case "$perm" in
        yolo) cfg+=',"permission":"allow"' ;;
        plan) cfg+=',"permission":{"edit":"deny","bash":"deny","webfetch":"allow"}' ;;
      esac
      extra=$(preset_prompt)
      if [ -n "$role_prompt$extra" ]; then
        pf="$(state_file "$session")"; pf="${pf%.env}.prompt.md"
        printf '%s\n\n%s\n' "$role_prompt" "$extra" > "$pf"
        cfg+=",\"instructions\":[\"$(json_escape "$pf")\"]"
      fi
      export OPENCODE_CONFIG_CONTENT="{$cfg}" OPENCODE_DISABLE_AUTOUPDATE=1 ;;
  esac
  return 0
}

# ── Presets (skill-based agent profiles) ────────────────────────────────────
# A preset is a KEY=value file (never sourced) named <name>.env in, by priority:
#   ~/.config/prama-agent/presets, /etc/prama-agent/presets, <repo>/presets
# Keys: DESCRIPTION AGENT MODEL EFFORT ROLE PROFILE PROMPT PROMPT_FILE SKILLS_DIR PLUGIN_DIRS
#       AGENTS_FILE MCP_CONFIG ALLOWED_TOOLS DISALLOWED_TOOLS ADD_DIRS
# Relative paths resolve against the preset's directory; lists are separated by ':'.
declare -gA PRESET_KV=()
PRESET_DIR=''

preset_dirs() {
  printf '%s\n' "$PRAMA_CONFIG_HOME/presets"
  [ -n "$PRAMA_SYSTEM_CONFIG_DIR" ] && printf '%s\n' "$PRAMA_SYSTEM_CONFIG_DIR/presets"
  printf '%s\n' "${REPO_ROOT:-$(dirname "$LIB_DIR")}/presets"
}

preset_find() {
  local d
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$ ]] || return 1
  while IFS= read -r d; do
    [ -f "$d/$1.env" ] && { printf '%s' "$d/$1.env"; return 0; }
  done < <(preset_dirs)
  return 1
}

preset_names() {
  local d f n
  declare -A seen=()
  while IFS= read -r d; do
    for f in "$d"/*.env; do
      [ -f "$f" ] || continue
      n=$(basename "$f" .env)
      [ -n "${seen[$n]:-}" ] && continue
      seen[$n]=1; printf '%s\n' "$n"
    done
  done < <(preset_dirs)
}

# preset_load <name> → fills PRESET_KV and PRESET_DIR; returns 1 if unknown.
preset_load() {
  local f k v line
  PRESET_KV=() PRESET_DIR=''
  f=$(preset_find "$1") || { warn "$(_t "Unknown preset: '%s'. Available: %s" "$1" "$(preset_names | tr '\n' ' ')")"; return 1; }
  PRESET_DIR=$(dirname "$f")
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    k=${line%%=*} v=${line#*=}
    [[ "$k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    v=${v%\"}; v=${v#\"}; v=${v%\'}; v=${v#\'}
    PRESET_KV[$k]=$v
  done < "$f"
}

_preset_path() {
  local p=$1
  case "$p" in
    \~/*) p="$HOME/${p#\~/}" ;;
    /*)    ;;
    *)     p="$PRESET_DIR/$p" ;;
  esac
  printf '%s' "$p"
}

preset_prompt() {
  [ -n "$PRESET" ] || return 0
  local out=${PRESET_KV[PROMPT]:-} f
  if [ -n "${PRESET_KV[PROMPT_FILE]:-}" ]; then
    f=$(_preset_path "${PRESET_KV[PROMPT_FILE]}")
    [ -f "$f" ] && out+="${out:+$'\n\n'}$(cat "$f")"
  fi
  [ -n "$out" ] && printf '[PRAMA PRESET: %s]\n%s' "$PRESET" "$out"
  return 0
}

# Wraps a directory of skills (<dir>/<skill>/SKILL.md) as a Claude Code plugin so it can be
# loaded with --plugin-dir without touching the user's ~/.claude.
_preset_skills_plugin() {
  local src=$1 dst="$PRAMA_STATE_HOME/plugins/preset-$PRESET"
  [ -d "$src" ] || { warn "$(_t 'SKILLS_DIR does not exist: %s' "$src")" >&2; return 1; }
  mkdir -p "$dst/.claude-plugin" || return 1
  printf '{"name":"prama-preset-%s","version":"1.0.0","description":"%s"}\n' \
    "$PRESET" "$(_t 'Skills from the %s preset (prama-agent)' "$PRESET")" > "$dst/.claude-plugin/plugin.json"
  ln -sfn "$src" "$dst/skills"
  printf '%s' "$dst"
}

_preset_claude_flags() {
  [ -n "$PRESET" ] || return 0
  local d p list=()
  if [ -n "${PRESET_KV[SKILLS_DIR]:-}" ]; then
    p=$(_preset_skills_plugin "$(_preset_path "${PRESET_KV[SKILLS_DIR]}")") && CMD+=(--plugin-dir "$p")
  fi
  IFS=':' read -ra list <<< "${PRESET_KV[PLUGIN_DIRS]:-}"
  for d in ${list[@]+"${list[@]}"}; do [ -n "$d" ] && CMD+=(--plugin-dir "$(_preset_path "$d")"); done
  list=()
  IFS=':' read -ra list <<< "${PRESET_KV[ADD_DIRS]:-}"
  for d in ${list[@]+"${list[@]}"}; do [ -n "$d" ] && CMD+=(--add-dir "$(_preset_path "$d")"); done
  [ -n "${PRESET_KV[AGENTS_FILE]:-}" ] && CMD+=(--agents "$(_preset_path "${PRESET_KV[AGENTS_FILE]}")")
  [ -n "${PRESET_KV[MCP_CONFIG]:-}" ] && CMD+=(--mcp-config "$(_preset_path "${PRESET_KV[MCP_CONFIG]}")")
  [ -n "${PRESET_KV[ALLOWED_TOOLS]:-}" ] && CMD+=(--allowed-tools "${PRESET_KV[ALLOWED_TOOLS]}")
  [ -n "${PRESET_KV[DISALLOWED_TOOLS]:-}" ] && CMD+=(--disallowed-tools "${PRESET_KV[DISALLOWED_TOOLS]}")
  return 0
}

# preset_apply_defaults: fills AGENT ROLE PROFILE (globals of the launch CLI / fleet) from the
# loaded preset, only where the caller left the default. Callers pass which ones were explicit.
# preset_apply_defaults <agent_explicit 0|1> <role_explicit 0|1> <profile_explicit 0|1>
preset_apply_defaults() {
  [ -n "$PRESET" ] || return 0
  preset_load "$PRESET" || return 1
  (( $1 )) || { [ -n "${PRESET_KV[AGENT]:-}" ] && AGENT=${PRESET_KV[AGENT]}; }
  (( $2 )) || { [ -n "${PRESET_KV[ROLE]:-}" ] && ROLE=${PRESET_KV[ROLE]}; }
  (( $3 )) || { [ -n "${PRESET_KV[PROFILE]:-}" ] && PROFILE=${PRESET_KV[PROFILE]}; }
  return 0
}

# ── Provider profiles (exports env for the agent process) ───────────────────
# Profiles point Claude Code at another Anthropic-compatible endpoint. OpenCode talks to
# OpenRouter & co. natively (see agent_runtime_env), so it ignores them.
apply_provider_profile() {
  local profile=${1:-default}
  case "$profile" in
    ""|default|native) return 0 ;;
    openrouter|or)
      [ -n "${OPENROUTER_API_KEY:-}" ] || die "$(_t "The '%s' profile requires %s in providers.env" openrouter OPENROUTER_API_KEY)"
      export ANTHROPIC_BASE_URL="${OPENROUTER_ANTHROPIC_URL:-https://openrouter.ai/api}"
      export ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"
      export ANTHROPIC_API_KEY=""
      [ -n "${OPENROUTER_MODEL:-}" ] && export ANTHROPIC_MODEL="$OPENROUTER_MODEL"
      return 0 ;;
    deepseek)
      [ -n "${DEEPSEEK_API_KEY:-}" ] || die "$(_t "The '%s' profile requires %s in providers.env" deepseek DEEPSEEK_API_KEY)"
      unset ANTHROPIC_API_KEY
      export ANTHROPIC_BASE_URL="${DEEPSEEK_BASE_URL:-https://api.deepseek.com/anthropic}"
      export ANTHROPIC_AUTH_TOKEN="$DEEPSEEK_API_KEY"
      export ANTHROPIC_MODEL="${DEEPSEEK_MODEL:-deepseek-chat}"
      export ANTHROPIC_SMALL_FAST_MODEL="${DEEPSEEK_FAST_MODEL:-deepseek-chat}" ;;
    glm|zai)
      [ -n "${GLM_API_KEY:-}" ] || die "$(_t "The '%s' profile requires %s in providers.env" glm GLM_API_KEY)"
      unset ANTHROPIC_API_KEY
      export ANTHROPIC_BASE_URL="${GLM_BASE_URL:-https://open.bigmodel.cn/api/anthropic}"
      export ANTHROPIC_AUTH_TOKEN="$GLM_API_KEY"
      export ANTHROPIC_MODEL="${GLM_MODEL:-glm-4.6}"
      export ANTHROPIC_SMALL_FAST_MODEL="${GLM_FAST_MODEL:-${GLM_MODEL:-glm-4.6}}" ;;
    local|router|ccr)
      unset ANTHROPIC_API_KEY
      export ANTHROPIC_BASE_URL="${LOCAL_ROUTER_URL:-http://127.0.0.1:3456}"
      export ANTHROPIC_AUTH_TOKEN="${LOCAL_ROUTER_TOKEN:-local-router}"
      export ANTHROPIC_MODEL="${LOCAL_ROUTER_MODEL:-default}" ;;
    *)
      die "$(_t "Unknown profile: '%s'. Run 'prama-agent profiles' to see the options." "$profile")" ;;
  esac
}

# ── Git worktrees ───────────────────────────────────────────────────────────
# Worktrees live OUTSIDE the repository (so linters, test runners and agents scanning the
# repo don't see duplicate trees):  <parent>/.prama-worktrees/<repo>/<branch-slug>
worktree_path() {
  local base_dir=$1 branch=$2
  local legacy="$base_dir/worktrees/$branch"
  if [ -d "$legacy" ]; then printf '%s' "$legacy"; return; fi   # created by v5
  local root=${PRAMA_WORKTREE_ROOT:-$(dirname "$base_dir")/.prama-worktrees}
  printf '%s/%s/%s' "$root" "$(basename "$base_dir")" "$(slugify "$branch")"
}

# provision_worktree <repo_dir> <branch> → prints the worktree path; returns 1 on failure.
# Never resets an existing branch: reuses it if it exists, creates it from HEAD otherwise.
provision_worktree() {
  local base_dir=$1 branch=$2 wt_dir
  if ! git -C "$base_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    warn "$(_t "'%s' is not a Git repository; --worktree is not possible." "$base_dir")"
    return 1
  fi
  if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    warn "$(_t "Invalid branch name: '%s'" "$branch")"
    return 1
  fi
  wt_dir=$(worktree_path "$base_dir" "$branch")
  if [ ! -d "$wt_dir" ]; then
    mkdir -p "$(dirname "$wt_dir")" || return 1
    if git -C "$base_dir" show-ref --verify --quiet "refs/heads/$branch"; then
      info_msg "$(_t "Reusing the existing branch '%s' in %s" "$branch" "$wt_dir")" >&2
      git -C "$base_dir" worktree add "$wt_dir" "$branch" >&2 \
        || { warn "$(_t "Could not create the worktree (is branch '%s' already checked out in another worktree?)" "$branch")"; return 1; }
    else
      info_msg "$(_t "Creating branch '%s' in %s" "$branch" "$wt_dir")" >&2
      git -C "$base_dir" worktree add -b "$branch" "$wt_dir" >&2 \
        || { warn "$(_t "Could not create the worktree '%s'" "$branch")"; return 1; }
    fi
  fi
  local f
  # Heavy, rebuildable directories (node_modules, .venv…) can be shared with the main checkout
  # instead of reinstalled in every worktree: PRAMA_WORKTREE_LINK="node_modules .venv".
  for f in ${PRAMA_WORKTREE_LINK:-}; do
    [[ $f == */* || $f == .. || $f == . ]] && continue
    if [ -d "$base_dir/$f" ] && [ ! -e "$wt_dir/$f" ]; then
      ln -s "$base_dir/$f" "$wt_dir/$f" && info_msg "$(_t "Linked '%s' from the main checkout" "$f")" >&2
    fi
  done
  for f in $PRAMA_WORKTREE_COPY_FILES; do
    if [ -f "$base_dir/$f" ] && [ ! -e "$wt_dir/$f" ]; then
      cp -p "$base_dir/$f" "$wt_dir/$f" && chmod 600 "$wt_dir/$f" 2>/dev/null
      info_msg "$(_t "Copied '%s' into the worktree" "$f")" >&2
    fi
  done
  printf '%s' "$wt_dir"
}

# ── Launch pipeline (single implementation used by CLI, TUI, bus and Telegram) ─
# launch_agent <agent> <zone> <role> <perm> <remote> <profile> <worktree> <mode> [session_name]
#   mode: attach  → replace this process with the attach (CLI)
#         return  → attach and return here when the user detaches (TUI)
#         bg      → start detached and print a summary
#         porcelain → start detached and print ONLY the session name
# Uses globals: PASS (pass-through args), ONESHOT, DAEMON_INTERVAL, DAEMON_TASK, PARALLEL.
# Errors go to stderr and return non-zero (never exits, so the TUI survives).
launch_agent() {
  local agent=$1 zone=$2 role=$3 perm=$4 remote=$5 profile=$6 wt=$7 mode=$8 name=${9:-}
  local dir target_d

  dir=$(zone_dir "$zone") || { warn "$(_t "Zone '%s' is not registered." "$zone")"; return 1; }
  [ -d "$dir" ] || { warn "$(_t "The directory '%s' of zone '%s' does not exist." "$dir" "$zone")"; return 1; }
  agent_installed "$agent" || { warn "$(_t "Agent '%s' is not installed (not in PATH)." "$agent")"; return 1; }
  is_in "$role" "${AVAILABLE_ROLES[@]}" || { warn "$(_t "Invalid role: '%s'" "$role")"; return 1; }
  [ "$role" = "reader" ] && perm="plan"
  is_in "$perm" "${AVAILABLE_PERM_MODES[@]}" || { warn "$(_t "Invalid permission mode: '%s'" "$perm")"; return 1; }
  ( apply_provider_profile "$profile" ) || return 1
  if [ -n "$PRESET" ]; then ( preset_load "$PRESET" >/dev/null ) || { warn "$(_t "Unknown preset: '%s'" "$PRESET")"; return 1; }; fi

  [ -n "$name" ] || name=$(session_name_for "$agent" "$zone" "$role" "$wt")
  valid_session_name "$name" || { warn "$(_t "Invalid session name: '%s' (letters, digits, - and _; max 48)" "$name")"; return 1; }

  ensure_tmux_conf

  if tmx_has "$name"; then
    if (( ${PARALLEL:-0} )); then
      local n=2
      while tmx_has "$name-$n"; do (( n++ )); done
      name="$name-$n"
    else
      case "$mode" in
        porcelain) printf '%s\n' "$name"; return 0 ;;
        bg)        info_msg "$(_t "Session '%s' is already running (use --parallel for another instance)." "$name")"; return 0 ;;
        return)    tmx_attach "$name"; return 0 ;;
        *)         tmx_attach "$name" 1 ;;
      esac
    fi
  fi

  target_d=$dir
  if [ -n "$wt" ]; then
    target_d=$(provision_worktree "$dir" "$wt") || return 1
  fi

  local role_prompt="" parent_s=${PRAMA_PARENT:-${PRAMA_SESSION:-}}
  # A plain executor gets no prompt (it is your own agent); one launched into a team learns the
  # bus, its coordinator and, in an isolated team, its branch.
  if [ "$role" != "executor" ] || { [ -n "$parent_s" ] && [ "$(session_role "$parent_s")" = coordinator ]; }; then
    role_prompt=$(PRAMA_WT_BRANCH=$wt PRAMA_WT_DIR=$target_d build_role_system_prompt "$role" "$name" "$zone")
  fi
  # A known conversation id lets prama restart the agent in place (new model, preset…) and
  # resume exactly this conversation, even with several agents in the same directory.
  local sid=''
  if [ "$agent" = claude ] && [ "$role" != daemon ]; then
    sid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || true)
  fi
  AGENT_SID=$sid AGENT_RESUME=0 PROFILE=$profile \
    build_agent_command "$agent" "$perm" "$remote" "$name" "$role_prompt" ${PASS[@]+"${PASS[@]}"}

  # Only non-secret env goes on the tmux command line; provider tokens are applied by the
  # runner inside the pane (they would otherwise be visible in `ps`).
  local tmux_env=(-e "PATH=$PATH" -e "PRAMA_DAEMON_TASK=${DAEMON_TASK:-}")
  [ "$perm" = "yolo" ] && tmux_env+=(-e "IS_SANDBOX=1")
  [ -n "${XDG_CONFIG_HOME:-}" ] && tmux_env+=(-e "XDG_CONFIG_HOME=$XDG_CONFIG_HOME")

  local runner=("$SELF_PATH" --internal-runner "$name" "$target_d" "$profile" "${ONESHOT:-0}" "$role" \
    "${DAEMON_INTERVAL:-60}" "$perm" -- "${CMD[@]}")
  local runner_s
  printf -v runner_s '%q ' "${runner[@]}"

  # agy reads its hooks at startup, so they must exist before the pane starts.
  if [ "$agent" = agy ] && ! agy_hooks_ensure; then
    warn "$(_t "Could not install agy's hooks; its health will be detected from the screen only.")"
  fi
  tmx new-session -d -s "$name" -x "${COLS:-120}" -y 40 -c "$target_d" "${tmux_env[@]}" "${runner_s% }" \
    || { warn "$(_t "tmux could not create session '%s'." "$name")"; return 1; }
  # Team: given for a coordinator (PRAMA_TEAM), inherited from the coordinator that launches an agent.
  local team=${PRAMA_TEAM:-} parent=${PRAMA_PARENT:-${PRAMA_SESSION:-operator}}
  if [ -z "$team" ] && [ "$parent" != operator ] && [ "$(session_role "$parent")" = coordinator ]; then
    team=$(team_name "$parent")
  fi
  state_write "$name" ROLE="$role" AGENT="$agent" ZONE="$zone" PROFILE="$profile" PERM="$perm" ${team:+TEAM="$team"} \
    REMOTE="$remote" MODEL="$AGENT_MODEL" EFFORT="$AGENT_EFFORT" PRESET="$PRESET" WORKTREE="$wt" \
    SESSION_ID="$sid" PARENT="$parent" TARGET_DIR="$target_d" STARTED_AT="$(date -Iseconds)"
  if (( ${#PASS[@]} )); then printf '%s\0' "${PASS[@]}" > "$(state_args_file "$name")"; fi
  bus_event started "${PRAMA_SESSION:-operator}" "$name" "$agent@$zone ($role, $perm${AGENT_MODEL:+, $AGENT_MODEL}${PRESET:+, preset $PRESET})"
  watchdog_ensure || true

  case "$mode" in
    porcelain) printf '%s\n' "$name" ;;
    bg)
      refresh_dimensions
      # Labels padded to one column width (11) whatever the language.
      local l_role l_perm l_prof l_dir l_model
      _tv l_role 'Role'; _tv l_perm 'Permissions'; _tv l_prof 'LLM profile'; _tv l_dir 'Directory'
      _tv l_model 'Model'
      printf -v l_role '%-11s' "$l_role"; printf -v l_perm '%-11s' "$l_perm"
      printf -v l_prof '%-11s' "$l_prof"; printf -v l_dir '%-11s' "$l_dir"
      box_top "$(_t '✔ AGENT IN THE BACKGROUND')" "$name" "$C_LIVE"
      box_row "$C_LIVE" "${C_MUTED}$l_role${C_OFF}$(role_badge "$role")"
      box_row "$C_LIVE" "${C_MUTED}$l_perm${C_OFF}$(perm_badge "$perm")   ${C_MUTED}Remote${C_OFF} $([ "$remote" = 1 ] && echo on || echo off)"
      box_row "$C_LIVE" "${C_MUTED}$l_prof${C_OFF}$profile${AGENT_MODEL:+   ${C_MUTED}$l_model${C_OFF} $AGENT_MODEL}${PRESET:+   ${C_MUTED}Preset${C_OFF} $PRESET}"
      box_row "$C_LIVE" "${C_MUTED}$l_dir${C_OFF}$target_d"
      box_bottom "prama-agent attach $name" "$C_LIVE" ;;
    return) tmx_attach "$name" ;;
    *)      tmx_attach "$name" 1 ;;
  esac
}

perm_badge() {
  local l
  case "$1" in
    yolo) printf '%s▲ YOLO%s' "$C_ERR$C_BOLD" "$C_OFF" ;;
    plan) _tv l '◉ PLAN (read-only)'; printf '%s%s%s' "$C_NEON" "$l" "$C_OFF" ;;
    *)    _tv l '● ASK (confirm each action)'; printf '%s%s%s' "$C_LIVE" "$l" "$C_OFF" ;;
  esac
}
