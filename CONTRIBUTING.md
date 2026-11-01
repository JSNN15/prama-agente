# Contributing to prama-agent

**English** · [Español](#español)

Thanks for your interest in prama-agent. Issues and pull requests are welcome in English or Spanish.
Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md). Questions and ideas go to
[Discussions](https://github.com/JSNN15/prama-agent/discussions); bugs to the issue forms.

## Design principles

1. **Minimal runtime dependencies.** The control plane is bash ≥ 4.4, tmux ≥ 3.2 and git. `jq`, `fzf`
   and `less` are optional and must have fallbacks. Python 3 (standard library only) is allowed only
   for the optional Telegram bridge (`lib/telegram_bot.py`). No Node.js or compiled dependencies.
2. **Security invariants first.** Read them in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): never
   `source` or `eval` data, every tmux call goes through `tmx` with exact targets, state only in the
   private state directory, no secrets on a command line, safe defaults.
3. **Determinism.** Keep argument boundaries (`"${CMD[@]}"`, `printf '%q'`), never flatten command
   arrays. Do not rely on environment inheritance across tmux servers: pass variables explicitly
   (`-e`) or set them inside the supervised runner.
4. **Resilience.** A crashing or updating agent must never destroy the user's pane or its scrollback.
   Prefer hooks and exit statuses over reading the screen; screen patterns are a fallback.
5. **The user's configuration is theirs.** prama does not rewrite user files it does not own. When it
   must add something (agy hooks), it owns one named key, preserves everything else and refuses to
   touch a file it cannot parse.

## Workflow

```bash
make lint          # bash -n, shellcheck, py_compile
make test          # Telegram bot unit tests + end-to-end suite on an isolated tmux server, HOME and state
make test-matrix   # the CI matrix in local containers (needs Docker): tmux 3.2a, 3.3a, 3.4
```

- Every bug fix comes with a regression test in `tests/test_prama_agent.sh` (or
  `tests/test_telegram_bot.py` for the bot). Tests never touch your real tmux, `HOME` or `/etc`.
- Behaviour that depends on the tmux version is gated in code and in tests (see `tmux_33` in the suite);
  CI must stay green on every image of the matrix.
- Workflow actions are pinned by commit SHA (Dependabot updates them); keep it that way in new workflows.
- Releases: bump `VERSION` in `bin/prama-agent`, add the `CHANGELOG.md` section, tag `vX.Y.Z`; the
  release workflow publishes the notes.
- Keep comments in English. User-facing text goes through `_t 'English text %s' "$arg"` (or `_tv var
  …` on hot paths), with the Spanish translation in `lib/lang/es/<module>.sh` (Python: `_("…")` and
  `lib/lang/es/telegram_bot.json`). The msgid is a one-line literal with printf placeholders; never
  translate at source time, never translate JSON, events or other machine output. `make lint` runs
  `tools/i18n_check.py`; `make i18n` also lists catalog entries nobody uses.
- Document new behaviour in both `README.md` and `README.es.md`, and add an entry to `CHANGELOG.md`.

## License

By contributing you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).

## Español

Los issues y pull requests son bienvenidos en español o en inglés. Quienes participan siguen el
[Código de Conducta](CODE_OF_CONDUCT.md); las dudas e ideas van a
[Discussions](https://github.com/JSNN15/prama-agent/discussions). Antes de abrir un PR ejecuta
`make lint` y `make test` (y `make test-matrix` si tienes Docker); cada corrección de errores debe incluir
una prueba de regresión. El CI corre la suite en Ubuntu 22.04, Debian 12 y Ubuntu 24.04 y debe quedar en
verde en todas. Si encuentras un fallo usando prama con agentes, `prama-agent feedback export <id>` te da
el cuerpo del issue listo para la plantilla. Lee los
principios de diseño de arriba y las invariantes de seguridad en
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Documenta los cambios en `README.md` y `README.es.md`.
Los textos para el usuario se escriben en inglés con `_t` / `_tv` y su traducción va en
`lib/lang/es/<módulo>.sh` (Python: `_("…")` y `lib/lang/es/telegram_bot.json`); `make lint` revisa
que no falte ninguna.
