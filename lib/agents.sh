#!/usr/bin/env bash
# lib/agents.sh — Verified Agent CLI Flag Builders, Remote-Control, Profiles & Worktrees
# Licensed under the Apache License, Version 2.0

AVAILABLE_PROFILES=(default kimi deepseek glm openrouter openrouter-free local)
AVAILABLE_PERM_MODES=(yolo plan ask)

# ── Exact CLI Flags Verified per Agent Binary ───────────────────────────────
# Builds the exact command array CMD=() based on:
#   agent, perm_mode (yolo|plan|ask), remote_flag (0|1), session_name, role_prompt, pass_args
build_agent_command() {
  local agent=$1
  local perm_mode=$2
  local remote_flag=$3
  local session_name=$4
  local role_prompt=$5
  shift 5
  local extra_args=("$@")

  CMD=("$agent")

  # 1. Permission Mode (YOLO / Skip-Permissions vs Plan / Read-Only vs Ask)
  case "$perm_mode" in
    yolo|skip)
      case "$agent" in
        claude|agy)       CMD+=(--dangerously-skip-permissions) ;;
        kimi|gemini|qwen) CMD+=(--yolo) ;;
      esac
      ;;
    plan|readonly)
      case "$agent" in
        claude)           CMD+=(--permission-mode plan) ;;
        agy)              CMD+=(--mode plan) ;;
        kimi)             CMD+=(--plan) ;;
        gemini|qwen)      CMD+=(--approval-mode plan) ;;
      esac
      ;;
    ask|safe)
      # Native interactive confirmation prompts enabled
      ;;
  esac

  # 2. Native Remote-Control Mode (Verified on claude v2.1+ and agy v1.4+)
  if (( remote_flag )); then
    case "$agent" in
      claude)
        # claude --remote-control [name] starts interactive session WITH remote bridge active!
        if [ "${PROFILE:-default}" = "default" ]; then
          CMD+=(--remote-control "$session_name")
        fi
        ;;
      agy)
        CMD+=(--remote-control)
        ;;
    esac
  fi

  # 3. Role System Prompt Injection (for Coordinator / Executor / Reader specialization)
  if [ -n "$role_prompt" ]; then
    case "$agent" in
      claude|qwen)
        CMD+=(--append-system-prompt "$role_prompt")
        ;;
    esac
  fi

  # 4. Append user pass-through arguments
  if [ "${#extra_args[@]}" -gt 0 ]; then
    CMD+=("${extra_args[@]}")
  fi
}

# ── Multi-Provider LLM Profile Application ──────────────────────────────────
apply_provider_profile() {
  local profile=${1:-default}
  case "$profile" in
    ""|default|native)
      return 0
      ;;
    kimi|moonshot)
      [ -n "${KIMI_API_KEY:-}" ] || die "Perfil 'kimi' requiere KIMI_API_KEY en providers.env"
      unset ANTHROPIC_API_KEY
      export ANTHROPIC_BASE_URL="${KIMI_BASE_URL:-https://api.moonshot.ai/anthropic}"
      export ANTHROPIC_AUTH_TOKEN="$KIMI_API_KEY"
      export ANTHROPIC_MODEL="${KIMI_MODEL:-kimi-k2.7}"
      export ANTHROPIC_SMALL_FAST_MODEL="${KIMI_FAST_MODEL:-${KIMI_MODEL:-kimi-k2.7}}"
      ;;
    deepseek)
      [ -n "${DEEPSEEK_API_KEY:-}" ] || die "Perfil 'deepseek' requiere DEEPSEEK_API_KEY en providers.env"
      unset ANTHROPIC_API_KEY
      export ANTHROPIC_BASE_URL="${DEEPSEEK_BASE_URL:-https://api.deepseek.com/anthropic}"
      export ANTHROPIC_AUTH_TOKEN="$DEEPSEEK_API_KEY"
      export ANTHROPIC_MODEL="${DEEPSEEK_MODEL:-deepseek-chat}"
      export ANTHROPIC_SMALL_FAST_MODEL="${DEEPSEEK_FAST_MODEL:-deepseek-chat}"
      ;;
    glm|zai)
      [ -n "${GLM_API_KEY:-}" ] || die "Perfil 'glm' requiere GLM_API_KEY en providers.env"
      unset ANTHROPIC_API_KEY
      export ANTHROPIC_BASE_URL="${GLM_BASE_URL:-https://open.bigmodel.cn/api/anthropic}"
      export ANTHROPIC_AUTH_TOKEN="$GLM_API_KEY"
      export ANTHROPIC_MODEL="${GLM_MODEL:-glm-4.6}"
      export ANTHROPIC_SMALL_FAST_MODEL="${GLM_FAST_MODEL:-${GLM_MODEL:-glm-4.6}}"
      ;;
    openrouter)
      [ -n "${OPENROUTER_API_KEY:-}" ] || die "Perfil 'openrouter' requiere OPENROUTER_API_KEY en providers.env"
      export OPENAI_BASE_URL="${OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}"
      export OPENAI_API_KEY="$OPENROUTER_API_KEY"
      export OPENROUTER_MODEL="${OPENROUTER_MAIN_MODEL:-anthropic/claude-sonnet-4}"
      ;;
    openrouter-free|free)
      [ -n "${OPENROUTER_API_KEY:-}" ] || die "Perfil 'openrouter-free' requiere OPENROUTER_API_KEY en providers.env"
      export OPENAI_BASE_URL="${OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}"
      export OPENAI_API_KEY="$OPENROUTER_API_KEY"
      export OPENROUTER_MODEL="${OPENROUTER_FREE_MODEL:-qwen/qwen3-coder:free}"
      ;;
    local|router|ccr)
      unset ANTHROPIC_API_KEY
      export ANTHROPIC_BASE_URL="${LOCAL_ROUTER_URL:-http://127.0.0.1:3456}"
      export ANTHROPIC_AUTH_TOKEN="${LOCAL_ROUTER_TOKEN:-local-router}"
      export ANTHROPIC_MODEL="${LOCAL_ROUTER_MODEL:-default}"
      ;;
    *)
      die "Perfil de proveedor desconocido: '$profile'. Usa 'prama-agent profiles' para ver opciones."
      ;;
  esac
}

# ── Git Worktree Manager ────────────────────────────────────────────────────
provision_worktree() {
  local base_dir=$1 wt_name=$2
  if ! git -C "$base_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "El directorio '$base_dir' no es un repositorio Git; no admite --worktree."
  fi
  local wt_dir="$base_dir/worktrees/$wt_name"
  if [ ! -d "$wt_dir" ]; then
    mkdir -p "$base_dir/worktrees"
    info_msg "Creando Git worktree en $wt_dir (rama: $wt_name)..." >&2
    git -C "$base_dir" worktree add -B "$wt_name" "$wt_dir" >&2 || die "Fallo al crear git worktree '$wt_name'"
  fi
  local f
  for f in $PRAMA_WORKTREE_COPY_FILES; do
    if [ -f "$base_dir/$f" ] && [ ! -f "$wt_dir/$f" ]; then
      cp -p "$base_dir/$f" "$wt_dir/$f"
      chmod 600 "$wt_dir/$f" 2>/dev/null || true
      info_msg "Archivo '$f' sincronizado al worktree $wt_name" >&2
    fi
  done
  printf '%s' "$wt_dir"
}
