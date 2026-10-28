# Contributing to prama-agent

Thank you for your interest in contributing to **prama-agent**!

## Design Principles

1. **Zero Heavy Runtime Dependencies:** `prama-agent` is built strictly on standard POSIX/Linux primitives (`bash >= 4.4`, `tmux`, `git`, `ps`, `tput`). Do not introduce Python, Node.js, or compiled daemon dependencies into the core control plane.
2. **Determinism First:**
   - Never flatten command arrays with `"${CMD[*]}"` when invoking child shells or `tmux`; always preserve exact argument boundaries using `printf '%q'`.
   - Never rely on implicit environment inheritance across existing `tmux` server sockets; pass critical variables explicitly (`-e`) or apply them inside the supervised runner.
3. **Resilience Over Fragility:**
   - A crashing or updating CLI agent must never destroy the user's `tmux` window or 50,000-line scrollback buffer.
   - Reconnecting to a session must always detach stale/zombie SSH clients (`tmux attach-session -d`) so mobile or disconnected clients never constrain terminal dimensions.

## Development & Verification

Before opening a Pull Request, run the lint and automated test suite:

```bash
make lint
make test
```

## License

By contributing to `prama-agent`, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).
