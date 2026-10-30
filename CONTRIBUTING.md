# Contributing to prama-agent

Thank you for your interest in contributing to **prama-agent**!

## Design Principles

1. **Minimal Runtime Dependencies:** the core control plane is bash ≥ 4.4 + tmux ≥ 3.2 + git. `fzf`, `jq` and `less` are optional enhancements and must have fallbacks. Python 3 (stdlib only) is allowed **only** for the optional Telegram bridge (`lib/telegram_bot.py`). Do not add Node.js or compiled dependencies.
2. **Security invariants first:** read the invariants in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — never `source`/`eval` data, all tmux calls through `tmx` with exact targets, state only in the private state dir, no secrets on argv, safe defaults.
3. **Determinism First:**
   - Never flatten command arrays with `"${CMD[*]}"` when invoking child shells or `tmux`; always preserve exact argument boundaries using `printf '%q'`.
   - Never rely on implicit environment inheritance across existing `tmux` server sockets; pass critical variables explicitly (`-e`) or apply them inside the supervised runner.
4. **Resilience Over Fragility:**
   - A crashing or updating CLI agent must never destroy the user's `tmux` window or 50,000-line scrollback buffer.
   - Reconnecting to a session must always detach stale/zombie SSH clients (`tmux attach-session -d`) so mobile or disconnected clients never constrain terminal dimensions.

## Development & Verification

Before opening a Pull Request, run the lint (bash -n + shellcheck + py_compile) and the test suite. Every bug fix should come with a regression test in `tests/test_prama_agent.sh`; tests run on an isolated tmux server (`PRAMA_TMUX_SOCKET`) and never touch your real tmux, HOME or `/etc`.

```bash
make lint
make test
```

## License

By contributing to `prama-agent`, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).
