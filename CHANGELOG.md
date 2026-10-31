# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [6.2.0] - 2026-10-31

### Added
- **Phone layout.** On clients narrower than `PRAMA_COMPACT_COLS` (100) the cockpit shows one agent at a
  time (zoomed pane) and the status bar becomes large tap targets: `◂` menu · `◀` previous · `☰`
  agents · `▶` next · `▦` cockpit. Back to the split view on a wide client; a zoom chosen by the
  operator is left alone. tmux hooks drive it (tmux ≥ 3.3). Inside the cockpit, next / previous
  (`Ctrl+b n/p`, `◀ ▶`) move between its panes.
- **Teams from Telegram**: `/equipos` (team status with model and quota, talk to the coordinator, view
  its screen, add a worker, close the team), *new team* (zone → workers → objective), `/cuota`.
- **Feedback channel** for prama-agent bugs: `prama-agent feedback "<what happened>"` (any agent or the
  operator), `list | show | export | close`. Reports keep their context (version, agent, model, state,
  recent bus events), are redacted, deduplicated, announced on the bus and Telegram (`/reportes`), and
  `export` produces a GitHub issue body. Every role prompt includes it; doctor and the menu show the
  open count.
- `x` on a coordinator in the menu closes its whole team with one confirmation.
- Doctor checks for mosh; the README has an "On your phone" section (mosh, compact layout, Telegram).
- Telegram bot unit tests (fake Telegram API and CLI, no network).
- CI: test matrix in clean containers (Ubuntu 22.04 / Debian 12 / Ubuntu 24.04: tmux 3.2a, 3.3a, 3.4;
  unprivileged user with a `/bin/sh` login shell), actionlint, CodeQL, OpenSSF Scorecard, SHA-pinned
  actions with Dependabot, release workflow from the tag and this changelog. Issue forms, PR template,
  CODEOWNERS, `.editorconfig`, `make test-matrix`.

### Changed
- The menu's action rows show only their label on a phone instead of a description cut short.
- Telegram's *Enjambre* (coordinator + one executor) became *Nuevo equipo* with a choice of workers.

### Fixed
- **Agents died on launch for users whose login shell is not bash** (dash, fish): tmux ran prama's pane
  commands, which use bash quoting, with the user's shell. prama's tmux server now runs commands with
  bash (`default-shell`) while plain panes still open the user's own shell (`default-command`). Found
  by the new container matrix.
- **A coordinator could be marked BLOCKED by an alert about another agent.** The watchdog's
  "[ALERTA PRAMA] … RESOURCE_EXHAUSTED (code 429)" message, wrapped by the CLI over several lines in a
  narrow cockpit pane, matched the screen quota patterns; the coordinator then stopped receiving its
  queue. Typed messages are now skipped whole, and when an agent's hooks report it healthy the screen
  can only add pre-hook dialogs (login, trust, model). Found in production; regression tests added.

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
  the conversation.
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
