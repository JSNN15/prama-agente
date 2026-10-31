# Security policy

**English** · [Español](#español)

prama-agent drives coding agents that can run commands on your machine, so security reports are taken
seriously.

## Reporting a vulnerability

Please do **not** open a public issue. Use GitHub's
[private vulnerability reporting](https://github.com/JSNN15/prama-agente/security/advisories/new) and
include the version (`prama-agent --version`), the steps to reproduce and the impact. You should get a
first answer within a week.

## Scope

In scope: command injection through session names, zones, task text or Telegram messages; state or
queue files being executed; secrets exposed on a command line or in world-readable files; prama acting
on tmux sessions or processes it does not own; secrets reaching a feedback report unredacted.

Out of scope: what an agent does once you run it in YOLO mode (`--yolo`), and vulnerabilities in the
agent CLIs themselves (report those to their vendors).

The design invariants that prama must uphold are listed in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#security-invariants).

## Español

prama-agent controla agentes que pueden ejecutar comandos en tu máquina, así que los reportes de
seguridad se atienden con prioridad. **No** abras un issue público: usa el
[reporte privado de vulnerabilidades](https://github.com/JSNN15/prama-agente/security/advisories/new)
de GitHub con la versión, los pasos para reproducir y el impacto. Recibirás una primera respuesta en
menos de una semana.
