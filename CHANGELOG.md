# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [6.1.0] - 2026-10-30

### Added
- **Teams**: `prama-agent swarm <zone> --workers agy:3 [--coord claude] [--task "…"]` launches a
  coordinator and N workers in one step; the coordinator receives its team and the objective, and can
  grow its own team. `swarm stop <zone>` closes a team.
- **Dynamic cockpit**: one pane per team member (coordinator large on the left) plus the live bus;
  rebuilt automatically when agents join or leave. `cockpit <zone|session>`.
- **Navigation inside tmux**: `Alt+a` agent picker (teams, state, model, quota), `Alt+c` cockpit ⇄
  agent, `Ctrl+b n/p` next/previous agent; tappable `◂ MENU · ☰ AGENTES · ▦ COCKPIT` status-bar
  buttons (tmux ≥ 3.3).
- TUI: sessions grouped as teams, `s` new-team wizard, cockpit action with team picker; restart keeps
  the conversation; `x` on a coordinator closes the whole team.
- Cockpit hint on narrow screens; docs recommend a tablet or computer for the cockpit.
- One-line installer (`curl … | bash`, per-user without root) and `prama-agent update [version]`.
- NOTICE, CITATION.cff and author information.

### Changed
- The swarm submenu was replaced by "Nuevo equipo" and "Cockpit"; `bus swarm-start` remains as a
  compatibility alias.
- `make install` without `sudo` installs for the current user.

## [6.0.0] - 2026-10-30

A rewrite focused on safety, determinism and fleet management.

### Added
- **Fleet API** (`prama-agent fleet`): `status`, `spawn`, `kill`, `model`, `edit`, `restart`,
  `presets`, `models`, `watchdog`, `hooks`, with JSON output and guard rails for agents (scope,
  maximum size, never itself, never a coordinator).
- **Agent health**: Claude Code hooks injected per session with `--settings`; Antigravity hooks through
  a named entry in `~/.gemini/config/hooks.json`. New `BLOCKED` state with a reason (`login`, `auth`,
  `credit`, `limit`, `trust`, `model`); screen detection as a fallback.
- **Quota telemetry** from the agents' status lines: 5-hour and weekly usage, reset times, context
  usage and cost, in `fleet status`, the TUI and JSON.
- **Watchdog** session: alerts coordinators and Telegram on blocked, stopped and recovered agents and
  on quota above `PRAMA_QUOTA_WARN`; delivers queued tasks when an agent is ready.
- **In-place restarts**: model, effort, preset or permission changes relaunch the agent in the same
  pane and resume the same conversation (`--resume` for Claude Code, `--conversation` for agy).
- **Presets**: reusable agent profiles with model, effort, role, prompt and a skills folder mounted as
  a plugin.
- Display-width-aware UI engine, responsive full-screen TUI, cockpit view.
- Telegram bot with one-time pairing and argument whitelists.
- OpenCode integration, **experimental** and off by default (`PRAMA_EXPERIMENTAL=1`).
- Bilingual documentation (English and Spanish), architecture guide and roadmap.

### Changed
- prama runs on its **own tmux server** (`tmux -L prama`) and never touches the user's tmux or
  `~/.tmux.conf`.
- All state moved to `~/.local/state/prama-agent` (mode `0700`); state files are data, never sourced.
- Permissions default to **ASK**; YOLO is opt-in.
- Provider secrets are applied inside the pane and never appear on a command line.

### Removed
- Kimi CLI, Gemini CLI and Qwen CLI agents.

### Fixed
- Stopping a session now terminates its whole process group, so agents that ignore `SIGHUP` (agy)
  are not left running orphaned.
- Exact tmux targets everywhere: `stop prama-claude` can no longer close `prama-claude-backend`.

### Security
- Removed the world-writable `/tmp/prama-bus` used by v5 (`doctor` cleans it up).

## [5.0.0]

Initial public release: double-buffered TUI, swarm wizard and Telegram bot.
