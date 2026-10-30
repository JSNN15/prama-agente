# Roadmap

**English** · [Español](#español)

## Agent support

| Agent | Status | Notes |
| --- | --- | --- |
| Claude Code | supported | hooks via `--settings`, status line quota, `--resume`, presets as plugins |
| Antigravity (`agy`) | supported | global named hook, status line quota, `--conversation`, model validation |
| OpenCode | experimental | integrated and covered by tests; off by default (`PRAMA_EXPERIMENTAL=1`) |
| Hermes Agent | under evaluation | not integrated |

### Low-cost workers: OpenCode and Hermes Agent

The goal is to run open-weight models (Qwen3 Coder, Kimi K2, GLM, DeepSeek), many of them free or very
cheap on OpenRouter, as workers under a Claude coordinator. Two open-source CLIs are serious
candidates.

**[OpenCode](https://opencode.ai)** (MIT) is a coding agent first.

- Already integrated: model, permissions and role instructions are passed per process through
  `OPENCODE_CONFIG_CONTENT`; `--auto` for unattended runs; `--continue` for in-place restarts;
  `opencode run` for daemons.
- Gaps: its plugin and event API is not documented as a stable contract, so health is screen-only; no
  quota telemetry (OpenRouter has no 5 h / 7 d windows; credits would have to come from the
  OpenRouter API).

**[Hermes Agent](https://github.com/NousResearch/hermes-agent)** (MIT, Nous Research) is a general,
self-improving assistant that also codes.

- Strengths for supervision: shell hooks with a JSON payload on stdin close to Claude Code's
  (`on_session_start`, `pre/post_llm_call`, `api_request_error`, …); per-process isolation with
  `HERMES_HOME`; `--yolo`, `-m/--provider`, `--resume`; built-in 429 back-off, provider fallback and
  key pools, which matter on free tiers.
- Concerns: persistent memory and self-written skills make runs less reproducible unless each pane
  gets a fresh `HERMES_HOME`; very frequent releases require pinning a version; hooks need explicit
  acceptance (`HERMES_ACCEPT_HOOKS=1`) for headless panes.

**Criteria to enable either one by default**

1. A scripted trial in a tmux pane with an invalid key, a non-existent model and a forced 429: each
   failure must be detectable deterministically (hook or exit status), not only on screen.
2. A stable way to inject role instructions and permissions per process without touching the user's
   global configuration.
3. Resuming a specific conversation by id.
4. A week of real use on mechanical tasks (tests, scoped refactors, docs) with acceptable quality.

## Remote hosts over SSH (planned)

Launch and supervise agents on other servers from the same prama-agent, so one cockpit can hold a team
spread across machines.

- Design: a `HOSTS` registry (`name → ssh target`) and zones qualified by host (`build:backend`). Each
  remote host runs its own prama-agent (installed with the one-line installer); the local one drives it
  through `ssh <host> prama-agent … --json`, which already covers launch, fleet status, bus and capture.
- The cockpit attaches to remote sessions with `ssh -t <host> prama-agent attach <session>` panes.
- Open questions: SSH multiplexing (`ControlMaster`) for a responsive TUI, bus events across hosts,
  and credentials (each host keeps its own agent logins and `providers.env`).

## Next

- Credit and rate-limit telemetry for OpenRouter-backed agents (OpenRouter key endpoint).
- English UI (the interface and role prompts are Spanish today); message catalogue for both languages.
- `fleet status` history: per-agent cost and quota over time from the bus log.
- Packaging: Homebrew tap and a `.deb`.

---

## Español

### Soporte de agentes

| Agente | Estado | Notas |
| --- | --- | --- |
| Claude Code | soportado | hooks con `--settings`, cuota desde la statusline, `--resume`, presets como plugins |
| Antigravity (`agy`) | soportado | hook global con nombre, cuota desde la statusline, `--conversation`, validación de modelos |
| OpenCode | experimental | integrado y cubierto por los tests; desactivado por defecto (`PRAMA_EXPERIMENTAL=1`) |
| Hermes Agent | en evaluación | no integrado |

### Agentes de bajo costo: OpenCode y Hermes Agent

El objetivo es usar modelos abiertos (Qwen3 Coder, Kimi K2, GLM, DeepSeek), muchos gratuitos o muy
baratos en OpenRouter, como ejecutores bajo un coordinador Claude. Hay dos CLIs de código abierto que
son candidatos serios.

**[OpenCode](https://opencode.ai)** (MIT) es ante todo un agente de código.

- Ya integrado: modelo, permisos e instrucciones de rol se pasan por proceso con
  `OPENCODE_CONFIG_CONTENT`; `--auto` para trabajar sin supervisión; `--continue` para reinicios en el
  mismo panel; `opencode run` para daemons.
- Pendiente: su API de plugins y eventos no está documentada como contrato estable, así que la salud se
  detecta solo por pantalla; no hay telemetría de cuota (OpenRouter no tiene ventanas de 5 h / 7 d; el
  crédito tendría que venir de la API de OpenRouter).

**[Hermes Agent](https://github.com/NousResearch/hermes-agent)** (MIT, Nous Research) es un asistente
general que se mejora a sí mismo y que también programa.

- A favor: hooks de shell con JSON por stdin parecidos a los de Claude Code (`on_session_start`,
  `pre/post_llm_call`, `api_request_error`, …); aislamiento por proceso con `HERMES_HOME`; `--yolo`,
  `-m/--provider`, `--resume`; manejo integrado de 429, proveedores de respaldo y rotación de claves,
  útiles en los planes gratuitos.
- En contra: la memoria persistente y las skills que escribe por sí mismo hacen que las ejecuciones
  sean menos reproducibles salvo que cada panel use un `HERMES_HOME` limpio; publica versiones muy
  seguido y habría que fijar una; los hooks requieren aceptación explícita (`HERMES_ACCEPT_HOOKS=1`)
  en paneles sin interacción.

**Criterios para habilitar cualquiera de los dos por defecto**

1. Una prueba automatizada en un panel tmux con clave inválida, modelo inexistente y un 429 forzado:
   cada fallo debe detectarse de forma determinista (hook o código de salida), no solo en pantalla.
2. Una forma estable de inyectar instrucciones de rol y permisos por proceso sin tocar la configuración
   global del usuario.
3. Reanudar una conversación concreta por id.
4. Una semana de uso real en tareas mecánicas (tests, refactors acotados, documentación) con calidad
   aceptable.

### Servidores remotos por SSH (planificado)

Lanzar y supervisar agentes en otros servidores desde el mismo prama-agent, para que un mismo cockpit
muestre un equipo repartido entre máquinas.

- Diseño: un registro `HOSTS` (`nombre → destino ssh`) y zonas calificadas por host (`build:backend`).
  Cada servidor remoto corre su propio prama-agent (instalado con el instalador de una línea); el local
  lo controla con `ssh <host> prama-agent … --json`, que ya cubre lanzar, estado de la flota, bus y
  captura de pantalla.
- El cockpit se conecta a sesiones remotas con paneles `ssh -t <host> prama-agent attach <sesión>`.
- Pendiente de definir: multiplexación SSH (`ControlMaster`) para que la TUI responda rápido, eventos
  del bus entre servidores y credenciales (cada servidor mantiene sus propios logins y `providers.env`).

### Próximos pasos

- Telemetría de crédito y límites para agentes sobre OpenRouter (endpoint de la clave de OpenRouter).
- Interfaz en inglés (hoy la interfaz y los prompts de rol están en español); catálogo de mensajes en
  ambos idiomas.
- Historial en `fleet status`: costo y cuota por agente a lo largo del tiempo, a partir del bus.
- Empaquetado: tap de Homebrew y `.deb`.
