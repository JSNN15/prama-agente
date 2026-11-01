# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [6.5.0] - 2026-11-01

### Added
- **Isolated teams: a git worktree and branch per executor.** A new team in a git zone (default,
  `PRAMA_SWARM_ISOLATE=1`; `swarm --shared` opts out) gives each executor its own worktree on
  `prama/<team>/<name>` from the zone's branch; the coordinator stays on it and integrates with
  `prama-agent worktree status | merge | sync | clean`. `merge` aborts on conflict and refuses a dirty
  base, so the base never stays broken; `merge --test "<cmd>"` (or `PRAMA_MERGE_TEST`) undoes a merge
  that breaks the tests. Only the coordinator or the operator merges. `swarm stop` removes clean,
  merged worktrees and keeps unmerged or uncommitted work. `PRAMA_WORKTREE_LINK` shares heavy
  directories (node_modules, .venv) with the main checkout. Menu: isolation step in the new-team
  wizard, Teams → Branches; Telegram: team → ⎇ Branches.
- Executors launched into a team now get their role prompt (bus, reports, their branch).
- Role prompts carry multi-agent practices backed by recent studies: plan with explicit dependencies
  and disjoint files, done means verified with evidence, announce shared-interface changes, merge one
  branch at a time with tests, the coordinator coordinates and does not implement.
- A coordinator can close its own team, itself last (`swarm stop <its session>`), and the operator is
  notified.

### Fixed
- `swarm stop` did not check who called it: an agent could close another team. Agents can now close
  only their own team, and only its coordinator can.

## [6.4.0] - 2026-11-01

### Added
- **English and Spanish.** The whole tool speaks both: menu, CLI, help, doctor, setup, the agents' role
  prompts and bus messages (agents report in your language) and the Telegram bot (commands in both:
  `/teams` = `/equipos`, `/alerts` = `/alertas`…). It follows the locale (`es_*` → Spanish) or
  `prama-agent lang en|es|auto` (`PRAMA_LANG`; the environment wins over config.env). The setup wizard
  asks first. English is the source language; translations live in `lib/lang/es/` (one catalog per
  module) and `tools/i18n_check.py` (part of `make lint`) fails on a missing translation, a placeholder
  mismatch or two catalogs translating the same text differently.
- **Color themes.** `prama-agent theme` lists seven (midnight, ocean, forest, ember, violet, light for
  light terminals, mono for high contrast) with swatches; a theme paints the menu, the tmux status bar
  and pane borders of every agent (regenerated and reloaded live) and the fzf inspector.
- **⚙ Preferences** in the menu (`,`): language, theme (moving through the list previews it live; esc
  restores) and mouse/touch, saved in config.env.
- **Teams screen** (`m`, ☷ Teams): every team with its agents, how many are working and its objective;
  per team: cockpit, message the coordinator, add agents, read or add to its memory, enter the
  coordinator, close it. `+` on a coordinator adds agents to its team from anywhere in the menu.
- **Shared team and zone memory**: `prama-agent memory show|add|clear|list` keeps short dated notes per
  team and per zone (`--zone-wide`) on the server, redacted, capped at `PRAMA_MEMORY_MAX_LINES`. Role
  prompts tell agents to read it at start and to record decisions; the coordinator's brief says how
  many notes are waiting. Agents write to their own team and cannot clear a memory.
- **Telegram alerts you can act on**: the watchdog's alerts (blocked, stopped, quota) arrive with
  buttons (view screen, talk, restart); team and report notifications carry theirs. New views:
  `/alerts` (agents that need you), `/daemons` (queues; queue a task), team memory (read, add a note),
  `/notify` (all · important · alerts · off) and `/mute 30m|1h|8h|24h|off` (silent delivery); also
  `prama-agent telegram alerts <level>` and `telegram mute <time>`.
- Keyboard help (`?`) grouped by task, in two columns when there is room and scrollable on a phone;
  the keybar shows the keys of what is selected, destructive ones in red; tmux keys are shown as
  `Alt+a` instead of `M-a`.
- Code of Conduct (Contributor Covenant 2.1).

### Changed
- The session list is grouped by team: the coordinator row is the team (`▍ backend · sec (2)`, one color
  per team, using the role column too) and its agents hang below with `├` / `└`, named by their last
  part (`agy`, `agy-2`).
- The repository is now `JSNN15/prama-agent` (GitHub redirects the old URLs).
- `status` aligns its columns by display width (accented headers).

### Fixed
- `LICENSE` is now the canonical Apache License 2.0 text (the previous copy differed in one word and
  lacked the appendix, so GitHub could not detect the license).
- `PRAMA_TUI_MOUSE` / `PRAMA_TUI_TICK` from config.env were ignored by the menu (read before the
  configuration was loaded).

## [6.3.0] - 2026-10-31

### Added
- **Several teams per zone.** `swarm <zone> --team <name>` creates a team with its own coordinator,
  objective and cockpit (architecture, security, docs… on the same repository); an existing name adds
  workers to that team. `prama-agent teams` (also `swarm list`, `--json`) lists them;
  `swarm stop <zone> --team <name> | --all | <coordinator>` and `cockpit <zone> --team <name>`. Named
  teams get readable session names (`prama-backend-seguridad-coord`, `…-seguridad-agy`); the zone's
  first team, `principal`, keeps the classic names. The menu's new-team wizard asks for the team name;
  Telegram lists every team and offers existing, suggested or typed names.
- **First steps for new users.** `prama-agent setup` (re-runnable; `--check` only reports): dependencies,
  each agent's sign-in, zones, default permissions, phone options. `prama-agent login [agent]` shows
  whether each CLI is signed in and opens its own login (credentials stay with the CLI).
  `prama-agent zones add|remove|scan` registers working folders under short names in `zones.conf`
  (data, never sourced), next to the zones of `config.env`. The installer and the empty menu point to
  `setup`. New guide: [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md) (also in Spanish).
- `fleet status --json` includes each agent's `team`.

### Changed
- `swarm <zone>` without `--team` no longer joins an existing team silently: it creates the zone's
  `principal` team, or asks for a name when the zone already has teams.
- Teams are isolated: an agent's reports (`bus report`) and the watchdog's alerts go to its own
  coordinator; `bus assign <role>` prefers the sender's own agents, then its team, then its zone; with
  `PRAMA_FLEET_SCOPE=zone` a coordinator cannot manage, grow or stop another team's agents.

### Fixed
- `bus report` delivered to the most recently started coordinator anywhere on the server (even another
  zone's); it now goes to the reporter's own coordinator.
- A cockpit built while other cockpits were open could come out tiny on tmux 3.2 ("no space for new
  pane"): it is now built at a fixed size and then follows the attached client.
- `main` is protected (pull requests with green CI); Discussions are enabled for questions.

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
- `prama-agent update` restarts the watchdog and the Telegram bot when the version changes (they are
  long-running and kept the old code until then).
- The quick guide (`prama-agent info`) describes teams and the phone workflow.
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
