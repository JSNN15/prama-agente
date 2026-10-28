# prama-agent (v5.0)

**Multi-Agent Terminal Control Plane, Swarm Coordination Bus, Lazydocker-Style Cockpit & LLM Router**  
*License: Apache 2.0 · Zero Mandatory Runtime Dependencies (Modular Bash + Tmux + Git, optional `fzf`)*

`prama-agent` is a modular, production-grade terminal control plane for launching, supervising, and coordinating swarms of heterogeneous coding agents (**Claude Code**, **Antigravity (`agy`)**, **Kimi Code**, **Gemini CLI**, **Qwen Code**) across multiple repositories on remote Linux servers or local workstations.

---

## Core Capabilities

### 1. Verified Permission Bypass, Read-Only & Remote-Control Matrix
`prama-agent` automatically injects the exact verified CLI flags for each agent binary according to the selected **Permission Mode (`YOLO` / `PLAN` / `ASK`)** and **Remote Control (`--remote` / `PRAMA_DEFAULT_REMOTE=1`)**:

| Agent CLI | Bypass Permissions (`yolo`) | Read-Only (`plan` / `reader` role) | Native Remote Control (`--remote`) | System Prompt Injection |
| :--- | :--- | :--- | :--- | :--- |
| **`claude`** | `--dangerously-skip-permissions` | `--permission-mode plan` | `--remote-control "<session>"` | `--append-system-prompt` |
| **`agy`** | `--dangerously-skip-permissions` | `--mode plan` | `--remote-control` | Supervised / Initial prompt |
| **`kimi`** | `--yolo` | `--plan` | `kimi web` / `kimi server` | `-p` (in daemon loop) |
| **`gemini`** | `--yolo` | `--approval-mode plan` | Via `tmux` / SSH | `-i` / `GEMINI.md` |
| **`qwen`** | `--yolo` | `--approval-mode plan` | Via `tmux` / `qwen serve` | `--append-system-prompt` |

### 2. Predefined Multi-Agent Roles (`--role` / Key `[o]`)
Every agent session is launched with one of 4 structured operational roles:
- **`❖ coordinator` (`--role coordinator`):** Architect & lead orchestrator. Plans tasks, inspects other agents' logs, and dispatches work to executors or daemons via `prama-agent bus assign`.
- **`✦ executor` (`--role executor`):** Implementation specialist running with full permissions (`yolo`), isolated in its own Git worktree when needed, reporting results back via `prama-agent bus report`.
- **`◉ reader` (`--role reader`):** Strictly read-only auditor/researcher. Automatically enforces native read-only flags (`--permission-mode plan`, `--mode plan`, `--plan`) so it can never alter files.
- **`♺ daemon` (`--role daemon --loop 60`):** Autonomous background slave/worker that runs continuously in a loop, pulling tasks from the shared bus queue (`/tmp/prama-bus/inbox/daemon.queue`) or executing a recurring health/test check.

### 3. Inter-Agent Swarm Bus (`prama-agent bus`)
Agents from different vendors (e.g., a **Claude** Coordinator and an **Agy** or **Kimi** Executor) can communicate deterministically through `prama-agent bus`:
```bash
# Coordinator assigns a task to a running Executor (injects directly into its tmux pane + logs to tasks.jsonl)
prama-agent bus assign executor "Implement /health endpoint and run pytest"

# Enqueue a background task for the autonomous Daemon worker
prama-agent bus assign daemon "Run ruff and pytest across all modules"

# Executor reports completion back to the Coordinator
prama-agent bus report "Endpoint /health implemented; 18/18 tests passing"

# Watch live inter-agent communication bus
prama-agent bus watch
```

### 4. TrueColor TUI, Lazydocker-Style Cockpit & `fzf` Split-Screen Inspector
- **TrueColor Closed-Box TUI (`prama-agent`):** Features an RGB linear-gradient header, zero-fork `/proc` host telemetry (`LOAD` & `RAM`), pixel-aligned closed Unicode cards (`╭───╮ │ ... │ ╰───╯`), a live 6-line **Lazy Preview Pane (`◉ VISTA PREVIA EN VIVO`)** when hovering any active session, one-key task injection (`[t]`), role/permission/remote toggles (`[o]`, `[y]`, `[c]`), and full state-machine back navigation (`←`, `⌫`, `b`, `Esc`).
- **3-Pane Tmux Cockpit (`prama-agent cockpit <zone>` or Key `[v]`):** Launches a split-screen workspace with:
  - **Left Pane (50%):** `❖ COORDINATOR` agent
  - **Top-Right Pane (50%):** `✦ EXECUTOR` agent
  - **Bottom-Right Pane:** `☍ SWARM BUS MONITOR` (`prama-agent bus watch`)
- **Split-Screen Fuzzy Inspector (`prama-agent fzf` or Key `[f]`):** Opens a rounded `fzf` split-screen view with real-time ANSI terminal preview (`tmux capture-pane -ep`).

---

## Modular Repository Structure

```text
prama-agent/
├── bin/
│   ├── prama-agent       # CLI entrypoint & command dispatcher
│   ├── prama-agy         # Quick wrapper for Agy
│   └── prama-claude      # Quick wrapper for Claude Code
├── lib/
│   ├── core.sh           # TrueColor gradient engine, closed-box renderer, /proc telemetry & tmux setup
│   ├── agents.sh         # Verified CLI flag builders, remote-control, LLM router & worktrees
│   ├── roles.sh          # Role profiles (coordinator/executor/reader/daemon) & supervisor loop
│   ├── bus.sh            # Inter-agent JSONL bus, auto-discovery & 3-pane Cockpit builder
│   └── tui.sh            # State-machine TUI with live preview, fzf split view & back navigation
├── config/
│   ├── config.env.example
│   └── providers.env.example
└── tests/
    └── test_prama_agent.sh
```

---

## Installation & Testing

```bash
git clone https://github.com/JSNN15/prama-agente.git
cd prama-agente
sudo make install
make test
```

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
