# prama-agent architecture (v6)

## Module ownership

| File | Responsibility |
| --- | --- |
| `bin/prama-agent` | Entrypoint: pre-dispatch, `prama_init`, subcommand dispatch, launch pipeline |
| `lib/core.sh` | Config loading, private state dirs, **dedicated tmux server**, session state, task queues, event log, process telemetry. No UI. |
| `lib/ui.sh` | Theme, display-width aware box engine, widgets (`state_badge`, `draw_gauge`, …) |
| `lib/agents.sh` | Per-agent CLI flag builders, provider profiles, git worktrees |
| `lib/roles.sh` | Role prompts, in-pane supervisor (`internal_runner`), daemon loop |
| `lib/bus.sh` | `prama-agent bus …`, swarm wizard, cockpit |
| `lib/health.sh` | CLI hooks (claude, agy) → health file, status line → quota file, `BLOCKED`/quota alerts, fleet watchdog, queued delivery |
| `lib/fleet.sh` | `prama-agent fleet …`: spawn/kill/model/edit/restart with guard rails |
| `lib/telegram.sh` + `lib/telegram_bot.py` | Telegram bridge |
| `lib/tui.sh` | Interactive full-screen TUI |

Source order: `core.sh` → `ui.sh` → `agents.sh` → `roles.sh` → `bus.sh` → `health.sh` → `fleet.sh` →
`telegram.sh` → `tui.sh`. `--internal-hook` and `--internal-statusline` are fast paths that only source
`core.sh` + `health.sh`; outside prama panes the hook exits before sourcing anything (agy's hooks are
global), and the status line reuses its last output for `PRAMA_SL_MIN` seconds using bash builtins only
(agy redraws it several times per second).
Sourcing has **no side effects**; the entrypoint calls `prama_init` (loads config, discovers zones,
creates private dirs).

## Security invariants

1. **Never `source`/`eval` data.** Session state is `KEY=value` lines read with `state_get`.
2. **All mutable state lives in `$PRAMA_STATE_HOME`** (`~/.local/state/prama-agent`, mode 0700,
   owner-checked by `ensure_private_dir`). Nothing in `/tmp`.
3. **All tmux calls go through `tmx`** (`tmux -L $PRAMA_TMUX_SOCKET -f $PRAMA_TMUX_CONF`). prama never
   touches the user's own tmux server or `~/.tmux.conf`.
4. **Exact tmux targets only:** `-t "=$session"` (session) or `-t "=$session:"` (its active pane).
   Prefer the helpers `tmx_has`, `tmx_kill`, `tmx_send`, `tmx_capture`.
5. **Session names** must match `SESSION_NAME_RE` (`valid_session_name`); build them with
   `session_name_for` / `slugify`.
6. **Secrets never on argv** (visible in `ps`). Pass via env inside the runner or via stdin/config files.
7. **Permissions default to `ask`.** YOLO is opt-in (`--yolo` or `PRAMA_SKIP_PERMISSIONS=1`).
8. Functions that can fail inside `$(...)` must be followed by `|| exit 1` / `|| return 1` — `die`
   only exits the subshell.
9. **Never type into an agent that is not READY/WORKING** (`bus_can_inject`); BLOCKED agents get a queue.
10. **Hooks never fail or print** (`--internal-hook` always exits 0, stdout/stderr discarded; for agy it
    prints exactly `{}`, the "no decision" answer). prama never edits a user file it cannot parse, and
    only owns the `prama-agent` key of `~/.gemini/config/hooks.json`.
11. **Agents managing agents** go through `_fleet_authorize`: not itself, not a coordinator, within
    `PRAMA_FLEET_SCOPE`; `spawn` is capped by `PRAMA_FLEET_MAX`.

## core.sh API

| Function | Purpose |
| --- | --- |
| `prama_init` | Load config, discover zones, create private dirs |
| `zone_dir <zone>` | Print directory, return 1 if unknown |
| `valid_session_name <s>` / `slugify <s>` / `session_name_for <agent> <zone> <role> [wt]` | Session naming |
| `tmx …` | tmux on the prama server |
| `tmx_running` / `tmx_has <s>` / `tmx_kill <s>` | Server / session checks |
| `tmx_send <s> <text>` | Type literal text + Enter |
| `tmx_capture <s> [lines] [ansi]` | Last N lines of the active pane |
| `tmx_attach <s> [exec_mode]` | Attach/switch/nested-attach correctly from anywhere |
| `prama_sessions [include_internal]` | Session names (telegram bot / cockpits skipped by default) |
| `is_internal_session <s>` | Bot or cockpit |
| `ensure_tmux_conf [force]` | Write `$PRAMA_TMUX_CONF` and reload |
| `state_write <s> KEY=V…` / `state_get <s> KEY [def]` / `state_remove <s>` / `state_gc` | Session metadata |
| `session_role <s>` | Role from state, else inferred from canonical name |
| `queue_push <target> <text>` / `queue_pop <target>` / `queue_len <target>` / `queue_clear` | Maildir task queues, multi-consumer safe, multiline safe |
| `bus_event <event> <from> <to> <text> [rc]` | Append JSON line to `$PRAMA_BUS_DIR/events.jsonl` |
| `json_escape <s>` | Full JSON string escaping |
| `snapshot_procs` / `resolve_pane_agent_pid <pid>` / `get_proc_metrics <pid>` | `cpu\|MB\|etime\|comm` |
| `get_host_telemetry` | `load1\|ram_pct\|ram_used_mb` |
| `detect_session_state <s> [dead] [cmd]` | `DEAD BOT STANDBY DAEMON WORKING BLOCKED SHELL READY` |
| `session_block_info <s> [snippet]` / `screen_block_reason <text>` | `reason\|detail` of a BLOCKED agent (hooks first, screen fallback) |
| `state_set <s> KEY=V…` | Merge keys into the state file (atomic, flock) |
| `health_set` / `health_get` / `health_file` | Hook-reported health: `HEALTH REASON DETAIL ACTIVITY MODEL AGENT_SID TS` |
| `state_args_file <s>` | Pass-through agent args (NUL separated, never evaluated) |
| `quota_get <s> KEY` / `quota_file` | Status line telemetry: `Q_5H Q_7D` (used %), `Q_5H_RESET Q_7D_RESET` (epoch), `CTX COST Q_MODEL Q_PLAN Q_TS` |
| `find_unmanaged_agents` | Agents running outside the prama server |
| `die` / `ok` / `warn` / `info_msg` / `is_in` | Logging / helpers |

Event schema (`events.jsonl`): `{"ts","event","from","to","text","rc"?}`; events: `assign`, `queued`,
`report`, `broadcast`, `started`, `completed`, `stopped`, `blocked`, `recovered`, `quota`, `model`,
`edited`, `restarted`.

Session spec (state file): `ROLE AGENT ZONE PROFILE PERM REMOTE MODEL EFFORT PRESET WORKTREE SESSION_ID
PARENT TARGET_DIR STARTED_AT` (+ `RESTART_REQ` while an in-place restart is pending).

## ui.sh API (stable signatures)

`box_top <title> [right] [color]`, `box_row <color> <content>`, `box_sep [color]`,
`box_bottom [hint] [color]`, `str_width`, `truncate_cols`, `strip_ansi`, `repeat_char`,
`draw_gauge <pct> [width]`, `state_badge <STATE>`, `host_stats_label`, `refresh_dimensions`
(sets `COLS ROWS W IS_COMPACT`), theme vars `C_*`, `IS_TTY`.

Also: `IS_TERM` (stdout is a terminal, regardless of color), `HAS_COLOR`, `gradient_text`, `state_color`,
and variable-returning variants used by the TUI hot path.

## tui.sh API

| Function | Contract |
| --- | --- |
| `tui_main` | Full-screen hub. Returns 1 (prints a plain list) without a terminal; 0 on quit. Reads/updates `AGENT ZONE ROLE PERM_MODE REMOTE PROFILE WORKTREE BG`. |
| `tui_select_box <step> <title> <labels> <metas> <avail> <targets>` | Array *names*. Sets `CHOICE`; returns 0 selected, 2 back (`CHOICE=-1`). Works inside the TUI, standalone, or as a numbered prompt without a TTY. |
| `tui_prompt <label> <var> [default]` | Line-edit popup; 0 only for non-empty input. |
| `tui_confirm <question> [danger] [yes_label]` | 0 on s/S/y/Y. |
| `tui_alert <title> <text> [err\|ok\|info]` / `tui_toast <ok\|err\|info> <text>` | Modal / transient footer message. |

The TUI reads core's process tables (`PS_COMM`, `PS_CHILDREN`, `PS_CPU`, `PS_RSS`, `PS_ETIME`) and
`AGENT_COMM_RE` directly for speed — keep those names stable.

## agents.sh / roles.sh / bus.sh key entry points

- `launch_agent <agent> <zone> <role> <perm> <remote> <profile> <worktree> <mode> [name]` — the single launch
  pipeline; `mode` ∈ `attach | return | bg | porcelain`. Returns non-zero with a stderr message on failure.
- `internal_runner <session> <dir> <profile> <oneshot> <role> <interval> <perm> -- <CMD…>` — pane supervisor.
  When `RESTART_REQ=1`, it rebuilds the command with `compose_session_cmd` (spec + `--resume <id>`) and
  relaunches in the same pane.
- `build_agent_command` reads `AGENT_MODEL AGENT_EFFORT AGENT_SID AGENT_RESUME PRESET`;
  `agent_runtime_env` exports per-agent env inside the pane (opencode: `OPENCODE_CONFIG_CONTENT`, API keys).
- `preset_load` / `preset_find` / `preset_names` / `preset_apply_defaults` — presets (`KEY=value`, never sourced).
- `subcmd_bus`, `subcmd_cockpit`, `swarm_wizard_menu`, `subcmd_telegram`.

## Machine-readable CLI (used by the Telegram bot and scripts)

`fleet status --json`, `fleet spawn … --json`, `sessions --json`, `zones --json`, `agents --json`,
`capture <s> [N]`, `send <s> <text>`,
`<agent> <zone> … --bg --porcelain` (prints only the session name).
