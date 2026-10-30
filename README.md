# prama-agent

**English** · [Español](README.es.md)

[![CI](https://github.com/JSNN15/prama-agente/actions/workflows/ci.yml/badge.svg)](https://github.com/JSNN15/prama-agente/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![bash ≥ 4.4](https://img.shields.io/badge/bash-%E2%89%A5%204.4-4EAA25)
![tmux ≥ 3.2](https://img.shields.io/badge/tmux-%E2%89%A5%203.2-1BB91F)
![Release](https://img.shields.io/github/v/release/JSNN15/prama-agente)

**A terminal control plane for CLI coding agents.** prama-agent launches, supervises and coordinates
[Claude Code](https://docs.anthropic.com/en/docs/claude-code) and Google Antigravity (`agy`) across
several repositories, on a remote server or on your laptop. Sessions survive SSH drops, agents hand
work to each other through a message bus, and a coordinator agent can manage its own fleet: spawn
helpers, switch their models, restart them and react when one is blocked by a login, a quota or a
billing problem.

It is plain bash on top of a dedicated tmux server: no daemon to install, no database, no Node.js.

```
 ◆ PRAMA AGENT v6.1.0  server-01                   ● 3 activos · 1 trabajando   LOAD 1.63 · RAM 21%
 Próximo agente ›  o  Rol ✦ executor   y  Permisos ● ASK   e  Remoto off   p  Perfil default
╭─ Sesiones ───────────────────────────────── 3 ─╮╭─ ◉ prama-agy-backend ─────────────────────────╮
│   ● claude-backend   ❖ coord listo   ▱▱▱▱   0% ││ ✦ executor · ● trabaja · CPU 3% · up 04:12    │
│ ▸ ● └ agy-backend    ✦ exec  trabaja ▰▰▱▱  54% │├─ en vivo ─────────────────────────────────────┤
│   ● └ agy-backend-2  ✦ exec  listo   ▱▱▱▱   0% ││ > agrega endpoint /health                     │
├─ Acciones ─────────────────────────────────────┤│ Thinking… editando src/routes/health.ts       │
│   ✚ Nuevo agente         claude o agy en zona  ││                                               │
│   ❖ Nuevo equipo         coordinador + N agen… ││                                               │
╰────────────────────────────────────────────────╯╰───────────────── ↵ entrar · t tarea · l logs ─╯
  ↵  entrar  c  cockpit  t  tarea  l  logs  r  reiniciar  x  cerrar  n  nuevo  s  equipo  ?  ayuda
```

> The interactive UI and the agents' role prompts are in Spanish; the CLI flags, JSON output and
> documentation are bilingual. UI translation is on the [roadmap](docs/ROADMAP.md).

## Why

Running coding agents for real work quickly turns into a dozen terminals: one per repository, a few
of them waiting for a login, one silently stuck on a usage limit, another lost because the SSH
connection dropped. prama-agent turns that into a supervised fleet:

- **Persistent sessions.** Every agent runs under a supervisor inside its own tmux session on a
  dedicated server (`tmux -L prama`). Close the laptop, lose the connection, reattach from a phone.
- **Health you can trust.** Agents report their state through CLI hooks, not screen scraping alone:
  `READY`, `WORKING`, `BLOCKED` (with a reason: `login`, `auth`, `credit`, `limit`, `trust`, `model`),
  `STANDBY`. Nothing is ever typed into a blocked agent; its work is queued.
- **Quota before the wall.** Usage of the 5-hour and weekly windows, reset times and context usage
  are collected from each agent's status line. The coordinator is warned at 90 %.
- **Agents managing agents.** A coordinator can spawn, edit, restart and stop helpers through a
  JSON API with guard rails (scope, limits, never itself, never another coordinator).
- **In-place restarts.** Changing a model or preset relaunches the agent in the same pane and
  resumes the same conversation; the scrollback is kept.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/JSNN15/prama-agente/main/install.sh | sudo bash
prama-agent doctor           # checks dependencies, agents, hooks and config
```

Without `sudo` it installs for the current user (`~/.local/bin`, `~/.config/prama-agent`). From a clone:
`sudo make install` or `make install`. Update later with `prama-agent update` (or `update v6.1.0`).

Requirements: bash ≥ 4.4, tmux ≥ 3.2 (3.3+ for clickable status-bar buttons), git. Recommended: `jq`
(hooks and quota telemetry), `fzf`, `less`. The optional Telegram bridge needs `python3` and `curl`.
At least one agent CLI: `claude` (Claude Code) or `agy` (Antigravity CLI). Zones default to the git
repositories found under `/opt` and `$HOME`; name them in `config.env` when you want short aliases.

## Quick start

```bash
prama-agent                                   # interactive UI
prama-agent swarm backend --workers agy:3 --task "Add rate limiting to the public API"
                                              # coordinator + 3 agy workers, opens the team cockpit
prama-agent claude backend                    # launch Claude Code in the "backend" zone and attach
prama-agent agy web --bg -w feat/login        # background, isolated in a git worktree
prama-agent claude backend --role reader      # read-only auditor (plan mode)
prama-agent status                            # fleet overview
prama-agent attach prama-claude-backend       # reattach (Alt+m returns to the menu)
```

In the interactive UI: `n` new agent, `s` new team, `↵` attach, `c` team cockpit, `t` send a task,
`l` history, `r`/`x` restart/stop, `/` filter, `?` help. Sessions are listed as teams (a coordinator
followed by its agents). It adapts to the terminal width (side-by-side from 100 columns,
stacked on a phone), refreshes every 2 s and supports touch and mouse wheel.

A **zone** is a named working directory, usually a repository. Zones come from `config.env`, or are
discovered from git repositories under `PRAMA_DISCOVER_ROOTS`.

## Teams and the cockpit

```bash
prama-agent swarm backend                         # coordinator (claude) + PRAMA_SWARM_WORKERS (agy:2)
prama-agent swarm backend --workers agy:2,claude:1 --worker-model gemini-3.8-flash-high
prama-agent cockpit backend                       # live split view of the team
prama-agent swarm stop backend                    # close the coordinator and its agents
```

The coordinator receives the list of its team and the objective as soon as it is ready, delegates
through the bus and can grow the team itself (`swarm <its zone> --workers agy:2`), switch models or
close agents. If the zone already has a coordinator, new workers join its team.

The **cockpit** shows the coordinator on the left, its agents stacked on the right and the live bus
below; it is rebuilt automatically when agents join or leave. Inside prama's tmux, from any agent or
from the cockpit:

| Key | Status-bar button | Action |
| --- | --- | --- |
| `Alt+m` | `◂ MENU` | back to the menu (agents keep running) |
| `Alt+a` | `☰ AGENTES` | agent list (teams, state, model, quota): jump to any agent or cockpit |
| `Alt+c` | `▦ COCKPIT` | team cockpit ⇄ the agent in focus |
| `Ctrl+b n` / `Ctrl+b p` | | next / previous agent |
| `Ctrl+b z` | | zoom the focused cockpit pane |

Keys are configurable (`PRAMA_MENU_KEY`, `PRAMA_NAV_KEY`, `PRAMA_COCKPIT_KEY`); the buttons work by
touch in Termius.

## Fleet management

The fine-grained API behind teams, available to you and to a coordinator; add `--json` for machine
output.

```bash
prama-agent fleet status --json              # state, block reason, model, preset, queue, quota
prama-agent fleet spawn agy backend --preset cheap --task "Add tests for utils/date.ts"
prama-agent fleet model prama-claude-backend-2 sonnet      # same pane, same conversation
prama-agent fleet edit  prama-claude-backend-2 --effort high --preset reviewer
prama-agent fleet restart <session> · fleet kill <session> · fleet presets · fleet models agy
prama-agent fleet hooks status               # health hooks per agent CLI
```

- **Watchdog.** An internal session starts with the first agent. It alerts the zone's coordinator
  (and Telegram, if configured) when an agent becomes blocked, stops, recovers or crosses the quota
  threshold, and delivers queued tasks once the agent is ready again.
- **Guard rails for agents.** An agent cannot act on itself or on a coordinator, only within its
  scope (`PRAMA_FLEET_SCOPE=zone|children|all`), and `spawn` honours `PRAMA_FLEET_MAX`. Every action
  is logged on the bus.
- **Model changes never touch your defaults.** prama restarts the agent with `--model` instead of
  typing `/model`, which in Claude Code also rewrites your global default. agy model ids are
  validated against `agy models`, since agy silently falls back to its default on unknown ids.

### How health and quota are collected

| | Claude Code | Antigravity (`agy`) |
| --- | --- | --- |
| Hooks | `SessionStart`, `UserPromptSubmit`, `Stop`, `StopFailure`, `Notification`, … injected per session with `--settings` | `SessionStart`, `PreInvocation`, `Stop` (error text classified) |
| Where | session only; `~/.claude` is not modified | one named entry, `prama-agent`, in `~/.gemini/config/hooks.json` (agy has no per-session hooks); a no-op outside prama panes; `fleet hooks uninstall` removes it |
| Quota | status line `rate_limits` (5 h / 7 d) | status line `quota` buckets of the active model family |
| Resume | `--session-id` / `--resume <id>` | `--conversation <id>` (id reported by the hooks) |

Screen detection remains as a fallback for dialogs shown before hooks run (login, folder trust,
model picker). If you already use a custom Claude Code status line, prama chains it.

## Roles and swarms

| Role | Purpose |
| --- | --- |
| `✦ executor` | implements and tests; reports with `prama-agent bus report` |
| `❖ coordinator` | plans, delegates with `bus assign`, manages the fleet |
| `◉ reader` | read-only reviewer (plan mode) |
| `♺ daemon` | works through a task queue in a loop (`--loop 60 --task "…"`) |

```bash
prama-agent bus assign prama-agy-backend-2 "Implement /health and run pytest"
prama-agent bus assign executor "…"              # by role: the most recent executor
prama-agent bus report "Endpoint ready; 18/18 tests pass"
prama-agent bus watch                            # live events
```

`assign` takes an exact session name or a role and never matches partially. Text is only typed into
agents that are ready or working; anything else is queued (Maildir queues, multi-consumer safe).

## Presets

`--preset <name>` applies an agent, model, effort, role, extra prompt and a skills folder in one go.
Bundled: `reviewer` (Claude, read-only), `architect` (Claude, extra-high effort) and `cheap` (agy Flash
for mechanical work). Your own go in `~/.config/prama-agent/presets/<name>.env`; a `SKILLS_DIR` with
`<skill>/SKILL.md` folders is mounted as a plugin for that agent only. See
[presets/README.md](presets/README.md).

## Permissions and security

| Mode | Flag | Behaviour |
| --- | --- | --- |
| **ASK** (default) | `--ask` | the agent asks before each action |
| **PLAN** | `--plan`, `--role reader` | the CLI's native read-only mode |
| **YOLO** | `--yolo`, `PRAMA_SKIP_PERMISSIONS=1` | no confirmations; for isolated servers you control |

Design guarantees (details in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)):

- A **dedicated tmux server**; your own tmux sessions and `~/.tmux.conf` are never touched.
- All state lives in `~/.local/state/prama-agent` (mode `0700`); nothing in `/tmp`.
- State, queues and events are data: never `source`d or `eval`ed.
- API keys never appear on a command line (`ps`); they are applied inside the agent's pane.
- Exact tmux targets: stopping `prama-claude` never closes `prama-claude-backend`.
- Stopping a session terminates its whole process group, so no agent is left running orphaned.

Report vulnerabilities as described in [SECURITY.md](SECURITY.md).

## Telegram (control from your phone)

```bash
prama-agent telegram setup     # paste the @BotFather token, then send the one-time code to the bot
prama-agent telegram start     # 24/7 bot in a persistent session (status | logs | restart | stop)
```

One-time pairing code (only your chat and user are authorised), inline menus to view a screen, talk
to an agent, launch, restart or stop, and argument whitelists. The bot is a remote terminal: protect
your Telegram account with two-step verification.

## LLM profiles

`--profile` points Claude Code at another Anthropic-compatible endpoint: `openrouter`, `deepseek`,
`glm` or `local` (a router such as claude-code-router). Keys live in `providers.env` (`chmod 600`).

```bash
prama-agent profiles
prama-agent claude backend --profile deepseek
```

## Configuration

`/etc/prama-agent/config.env`, then `~/.config/prama-agent/config.env` (bash syntax, see
[config/config.env.example](config/config.env.example)).

| Variable | Default | |
| --- | --- | --- |
| `ZONES` / `ZONE_DIRS` | discovered | named working directories |
| `PRAMA_SKIP_PERMISSIONS` | `0` | `1` = YOLO by default |
| `PRAMA_DEFAULT_REMOTE` | `0` | enable the CLIs' remote control by default |
| `PRAMA_FLEET_MAX` / `PRAMA_FLEET_SCOPE` | `8` / `zone` | fleet limits for agents |
| `PRAMA_HOOKS` / `PRAMA_STATUSLINE` | `1` / `1` | health hooks / quota telemetry |
| `PRAMA_QUOTA_WARN` | `90` | quota alert threshold (%) |
| `PRAMA_WATCHDOG` | `1` | fleet watchdog |
| `PRAMA_SWARM_WORKERS` | `agy:2` | default workers for `swarm` |
| `PRAMA_MENU_KEY` / `PRAMA_NAV_KEY` / `PRAMA_COCKPIT_KEY` | `M-m` / `M-a` / `M-c` | navigation keys inside tmux |
| `PRAMA_EXPERIMENTAL` | `0` | enable experimental agents (OpenCode) |

**Worktrees** (`-w <branch>`) are created outside the repository
(`<parent>/.prama-worktrees/<repo>/<branch>`), reuse an existing branch without resetting it, and copy
`.env`, `.env.local` and `.mcp.json`.

## Status and roadmap

| Agent | Status |
| --- | --- |
| Claude Code | supported: hooks, quota, resume, presets, remote control |
| Antigravity (`agy`) | supported: hooks, quota, resume, model validation, remote control |
| OpenCode | **experimental**, integrated and tested but off by default (`PRAMA_EXPERIMENTAL=1`) |
| Hermes Agent | **under evaluation**, not integrated |

Running agents on other servers over SSH from the same prama-agent is a planned feature.

OpenCode and Hermes are the two serious candidates for running open-weight models (Qwen, Kimi, GLM,
DeepSeek) through OpenRouter as low-cost workers. The evaluation and the criteria for enabling them
are in [docs/ROADMAP.md](docs/ROADMAP.md).

## Migrating from v5

`prama-agent doctor` detects and cleans up what v5 left behind: it removes the insecure
`/tmp/prama-bus`, `doctor --restore-tmux-conf` restores your original `~/.tmux.conf`, and it lists agents
running outside prama (they do not survive an SSH drop). v5 sessions lived on your personal tmux server;
v6 uses its own.

## Development

```bash
make lint     # bash -n, shellcheck, py_compile
make test     # end-to-end suite on an isolated tmux server, HOME and state
```

Architecture, security invariants and internal API: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
Contributing: [CONTRIBUTING.md](CONTRIBUTING.md). Changes: [CHANGELOG.md](CHANGELOG.md).

## Author

Created and maintained by **Julian Neira Nova** (Hualpén, Chile) · [@JSNN15](https://github.com/JSNN15).
If you use prama-agent in your work, [CITATION.cff](CITATION.cff) has the citation.

## License

[Apache License 2.0](LICENSE) · see [NOTICE](NOTICE). Claude Code and Antigravity are trademarks of
their respective owners; this is an independent project.
