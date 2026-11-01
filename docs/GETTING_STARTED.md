# Getting started

**English** · [Español](GETTING_STARTED.es.md)

From an empty server (or laptop) to a team of agents working on your repositories, in five steps.
Tested on Ubuntu 22.04 / 24.04 and Debian 12; any Linux with bash ≥ 4.4 and tmux ≥ 3.2 works.

## 1. Install the agent CLIs

prama-agent drives coding agents; it does not replace them. Install at least one:

| Agent | Install | Account |
| --- | --- | --- |
| Claude Code (`claude`) | `curl -fsSL https://claude.ai/install.sh \| bash` | a Claude subscription or an Anthropic API key |
| Antigravity CLI (`agy`) | from Google's Antigravity documentation | a Google account |

Recommended packages: `sudo apt install tmux git jq` (and `mosh` if you will connect from a phone).

## 2. Install prama-agent

```bash
curl -fsSL https://raw.githubusercontent.com/JSNN15/prama-agent/main/install.sh | sudo bash   # system-wide
curl -fsSL https://raw.githubusercontent.com/JSNN15/prama-agent/main/install.sh | bash        # just for you
```

## 3. Run the setup wizard

```bash
prama-agent setup
```

It is safe to run again at any time (`setup --check` only reports). It walks through:

**Sign-in.** Credentials stay with each agent CLI: prama never reads or stores them. The wizard asks
each CLI whether it is signed in and, if not, opens its own login:

```bash
prama-agent login            # status of every agent
prama-agent login claude     # claude auth login (on a server: open the link on any device, paste the code)
prama-agent login agy        # opens agy to sign in with your Google account
```

Agents that are not signed in still launch, but prama marks them `BLOCKED (login)` and queues their
work until you sign in. Other model providers (OpenRouter, DeepSeek, GLM, a local router) are
configured as profiles: put their keys in `~/.config/prama-agent/providers.env` and launch with
`--profile <name>` (`prama-agent profiles` lists them).

**Zones.** A zone is a working folder (usually a git repository) with a short name you will type:
`backend`, `web`, `docs`. Until you register one, every git repository directly under `/opt` and your
home is a zone. The wizard lists those repositories and lets you pick and name them; later:

```bash
prama-agent zones                                   # zones and where they come from
prama-agent zones scan                              # git repositories not registered yet
prama-agent zones add backend /srv/app-backend "API and workers"
prama-agent zones remove backend
```

Registered zones live in `~/.config/prama-agent/zones.conf` (data only). You can also declare them in
`config.env` (`ZONES`, `ZONE_DIRS`), which wins on a name clash.

**Permissions.** `ask` (the agent asks before each action, the default) or `yolo` (no confirmations,
only for isolated servers you control). Any agent can override it with `--ask`, `--plan` or `--yolo`.

## 4. Models

Each CLI starts with its own default model. You choose per agent or per team, and can change a running
agent without losing its conversation:

```bash
prama-agent claude backend --model sonnet                     # one agent
prama-agent swarm backend --team docs --model opus --worker-model gemini-3.8-flash-high
prama-agent fleet models agy                                  # agy model ids (validated before use)
prama-agent fleet model prama-agy-backend gemini-4-argon-medium      # same pane, same conversation
```

Presets bundle an agent, a model, an effort level and a role (`--preset cheap`, `reviewer`, `architect`;
see [presets/README.md](../presets/README.md)).

## 5. First agent, first teams

```bash
prama-agent                                   # the menu: n new agent, s new team
prama-agent claude backend                    # one agent, attached (Alt+m returns to the menu)
```

A **team** is a coordinator plus the agents it manages. A zone can hold several teams, each with its
own name, coordinator, objective and cockpit:

```bash
prama-agent swarm backend --team arquitectura --workers agy:2 --task "Split the billing module"
prama-agent swarm backend --team seguridad    --workers agy:1 --task "Audit authentication"
prama-agent swarm backend --team docs         --workers agy:1 --task "Document the public API"
prama-agent teams                             # the three teams of backend
prama-agent cockpit backend --team seguridad  # live view of one team
```

Reports and alerts of an agent go to its own coordinator, and a coordinator can only manage its own
team. Running `swarm` again with an existing team name adds workers to that team.

## Daily use

| | |
| --- | --- |
| Back to the menu | `Alt+m` (or the `◂ MENU` button) — agents keep running |
| Agent list / jump anywhere | `Alt+a` |
| Team cockpit ⇄ agent | `Alt+c` |
| Next / previous agent | `Ctrl+b n` / `Ctrl+b p` |
| Close one agent | `prama-agent stop <session>`, or `x` in the menu |
| Close one team | `prama-agent swarm stop backend --team seguridad`, or `x` on its coordinator |
| Close everything | `prama-agent stop --all -y` |

From a phone: mosh plus the compact cockpit, or the Telegram bot (`prama-agent telegram setup`). See
the README's "On your phone" section.

## When something goes wrong

- `prama-agent doctor` checks dependencies, agents, hooks and configuration.
- `prama-agent fleet status` shows why an agent is blocked (`login`, `credit`, `limit`, `trust`, `model`).
- Agents report prama-agent bugs themselves (`prama-agent feedback list`); `feedback export <id>` gives
  you an issue body for [GitHub](https://github.com/JSNN15/prama-agent/issues).
