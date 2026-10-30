# prama-agent

**Control plane para agentes de código en la terminal.** Lanza, supervisa y coordina Claude Code,
Agy (Antigravity) y OpenCode (modelos abiertos vía OpenRouter, incluidos los gratuitos) en varios repositorios, en un servidor remoto o
en tu máquina. Las sesiones sobreviven a cortes de SSH, los agentes se pasan tareas entre sí y todo se
controla desde una interfaz de terminal pensada tanto para escritorio como para el celular (Termius).

*Apache-2.0 · bash ≥ 4.4 + tmux ≥ 3.2 + git · opcionales: `fzf`, `jq`, `less`, `python3` + `curl` (solo Telegram)*

```
 ◆ PRAMA AGENT v6.0.0  server-01                   ● 3 activos · 1 trabajando   LOAD 1.63 · RAM 21%
 Próximo agente ›  o  Rol ✦ executor   y  Permisos ● ASK   e  Remoto off   p  Perfil default
╭─ Sesiones ───────────────────────────────── 3 ─╮╭─ ◉ prama-agy-web ─────────────────────────────╮
│   ● agy-web          ✦ exec  trabaja ▱▱▱▱   0% ││ ✦ executor · ● trabaja · CPU 3% · up 04:12    │
│ ▸ ● claude-backend   ✦ exec  listo   ▰▰▱▱  54% │├─ en vivo ─────────────────────────────────────┤
│   ● claude-backend   ❖ coord listo   ▱▱▱▱   0% ││ > agrega endpoint /health                     │
├─ Acciones ─────────────────────────────────────┤│ Thinking… editando src/routes/health.ts       │
│   ✚ Nuevo agente         claude, agy u openc… ││                                               │
│   ❖ Coordinar enjambre   coordinador + ejecut… ││                                               │
╰────────────────────────────────────────────────╯╰───────────────────── ↵ entrar · t tarea · l logs ─╯
  ↵  entrar  t  tarea  n  nuevo  l  logs  x  cerrar  r  reiniciar  /  filtrar  c  cockpit  ?  ayuda
```

## Instalación

```bash
git clone https://github.com/JSNN15/prama-agente.git && cd prama-agente
sudo make install          # o, solo para tu usuario:  make install PREFIX=~/.local CONF_DIR=~/.config/prama-agent
prama-agent doctor         # verifica dependencias, agentes y migra desde v5
eval "$(prama-agent completion bash)"   # autocompletado (el instalador lo deja en /etc/bash_completion.d)
```

## Uso rápido

```bash
prama-agent                                  # interfaz interactiva
prama-agent claude backend                   # lanzar y entrar (modo ASK por defecto)
prama-agent agy web --bg -w feat/login       # en segundo plano, aislado en un git worktree
prama-agent claude backend --role reader     # auditor de solo lectura (fuerza plan mode)
prama-agent status                           # panel de la flota
prama-agent attach prama-claude-backend      # volver a entrar (Alt+m o Ctrl+b d para salir)
```

### Interfaz interactiva

| Tecla | Acción | Tecla | Acción |
| --- | --- | --- | --- |
| `↑↓` `jk` `1-9` | moverse | `↵` | entrar a la sesión / elegir |
| `n` | nuevo agente (asistente) | `t` | enviar tarea a la sesión |
| `l` | ver historial (`less`) | `r` / `x` | reiniciar / cerrar (con confirmación) |
| `/` | filtrar sesiones | `f` | inspector `fzf` con vista previa |
| `c` | cockpit (coordinador + ejecutor + bus) | `?` | ayuda |
| `o` `y` `e` `p` `w` `g` | rol · permisos · remote · perfil LLM · worktree · segundo plano | `q` | salir |

- **Responsive:** lista + vista previa lado a lado desde 100 columnas, apilado en pantallas de celular.
- **En vivo:** estado, CPU y vista previa se refrescan solos cada 2 s; soporta toques y rueda del ratón
  (`PRAMA_TUI_MOUSE=0` para desactivarlo).
- **Volver al menú desde un agente:** toca `◂ MENU` en la barra inferior o pulsa `Alt+m`
  (configurable con `PRAMA_MENU_KEY`). El agente sigue vivo.

## Permisos y seguridad

| Modo | Flag | Qué hace |
| --- | --- | --- |
| **ASK** (por defecto) | `--ask` | el agente pide confirmación antes de cada acción |
| **PLAN** | `--plan` / `--role reader` | solo lectura nativa del CLI |
| **YOLO** | `--yolo` / `PRAMA_SKIP_PERMISSIONS=1` | sin confirmaciones; solo en servidores aislados |

| Agente | YOLO | PLAN | Remote (`--remote`) | Prompt de rol |
| --- | --- | --- | --- | --- |
| `claude` | `--dangerously-skip-permissions` | `--permission-mode plan` | `--remote-control <sesión>` | `--append-system-prompt` |
| `agy` | `--dangerously-skip-permissions` | `--mode plan` | `--remote-control` | — |
| `opencode` | `--auto` + `permission: allow` | permisos `edit/bash: deny` | — | `instructions` (en su config) |

Garantías de diseño (detalle en [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)):

- prama usa **su propio servidor tmux** (`tmux -L prama`): nunca modifica tu `~/.tmux.conf` ni toca, lista
  o cierra tus sesiones personales.
- Todo el estado vive en `~/.local/state/prama-agent` con permisos `0700`; nada en `/tmp`.
- Los datos (estado de sesiones, colas, eventos) nunca se ejecutan como código.
- Las claves de API nunca aparecen en la línea de comandos (`ps`); se aplican dentro del panel del agente.
- Objetivos tmux exactos: `stop prama-claude` nunca cierra `prama-claude-backend`.
- `IS_SANDBOX=1` solo se exporta en modo YOLO.

## Roles y enjambre multi-agente

| Rol | Uso |
| --- | --- |
| `✦ executor` | implementa y prueba; reporta con `prama-agent bus report` |
| `❖ coordinator` | planifica y delega con `prama-agent bus assign` |
| `◉ reader` | auditor de solo lectura |
| `♺ daemon` | procesa una cola de tareas en bucle (`--loop 60 --task "..."`) |

```bash
prama-agent bus swarm-start backend claude agy     # coordinador (claude) + ejecutor (agy)
prama-agent cockpit backend                        # pantalla dividida con ambos + monitor del bus
prama-agent bus assign executor "Implementa /health y corre pytest"
prama-agent bus assign daemon "Corre ruff y pytest"   # encola para el daemon
prama-agent bus report "Endpoint listo; 18/18 tests ok"
prama-agent bus watch                              # eventos en vivo
prama-agent bus inbox prama-claude-backend --pop   # tareas pendientes de una sesión
```

- `assign` acepta un **nombre exacto** de sesión o un **rol** (si hay varias, la más reciente). Nunca hace
  coincidencias parciales.
- El texto solo se escribe en sesiones cuyo agente está listo o trabajando; si la sesión está en un shell,
  en standby o es un daemon, la tarea queda en su cola.
- `broadcast` solo llega a sesiones de agentes de prama, nunca a un shell.
- El daemon respeta el modo de permisos. En ASK, como no puede preguntar, las herramientas que requieren
  aprobación se deniegan (se avisa al iniciar).

## Flota: el coordinador administra a sus agentes

El coordinador (o tú) gestiona la flota con `prama-agent fleet`; todo devuelve JSON con `--json`.

```bash
prama-agent fleet status --json                          # estado, bloqueo + motivo, modelo, preset, cola, cuota
prama-agent fleet spawn opencode backend --preset cheap --task "Agrega tests a utils/date.ts"
prama-agent fleet model prama-claude-backend-2 sonnet    # reinicia en el mismo panel, misma conversación
prama-agent fleet edit prama-claude-backend-2 --effort high --preset reviewer
prama-agent fleet restart <sesión>  ·  fleet kill <sesión>  ·  fleet presets  ·  fleet models opencode
```

- **Salud determinista.** Claude Code recibe (vía `--settings`, sin tocar tu `~/.claude`) hooks que
  reportan `StopFailure` (límite de uso, autenticación, crédito, modelo inexistente), el modelo en uso y
  el id de conversación. agy recibe hooks `SessionStart`/`PreInvocation`/`Stop` (el error de un `Stop`
  se clasifica: cuota, créditos, auth…); como agy no admite hooks por sesión, prama mantiene una entrada
  `prama-agent` en `~/.gemini/config/hooks.json` que no hace nada fuera de sus paneles
  (`prama-agent fleet hooks status|install|uninstall`). Para lo que ocurre antes de los hooks (login,
  "¿confías en esta carpeta?", menú de modelo) y para opencode se lee la pantalla. Resultado: estado
  `BLOCKED` con motivo (`login`, `auth`, `limit`, `credit`, `trust`, `model`).
- **Cuota antes de chocar.** La statusline de claude y agy (solo para la sesión) reporta el % usado de
  las ventanas de 5 h y 7 días, su hora de reinicio y el % de contexto: aparece en `fleet status`, en la
  TUI y en el JSON (`quota`). Cuando una cuenta pasa `PRAMA_QUOTA_WARN` (90 %) el watchdog avisa una vez
  al coordinador para que reparta trabajo antes del bloqueo. Si ya tienes una statusline en Claude, se
  sigue mostrando (prama la encadena).
- **Nunca se escribe sobre un agente bloqueado:** la tarea queda en su cola.
- **Watchdog** (sesión interna, arranca solo): avisa al coordinador de la zona y a Telegram cuando un
  agente se bloquea, se detiene o se recupera, y entrega las tareas en cola cuando el agente vuelve a
  estar listo.
- **Cambio de modelo/configuración en caliente:** el supervisor relanza el agente en el mismo panel (el
  scrollback se conserva) con `--model`/`--effort`/preset nuevos y la misma conversación (claude
  `--resume <id>`, agy `--conversation <id>`). No usa `/model` (Claude lo guardaría como tu modelo por
  defecto global). Los modelos de agy se validan contra `agy models` (agy ignora en silencio un id
  desconocido).
- **Límites para agentes:** un agente no puede actuar sobre sí mismo ni sobre un coordinador, solo
  dentro de su zona (`PRAMA_FLEET_SCOPE`), y `spawn` respeta `PRAMA_FLEET_MAX`. Todo queda en el bus.

### Presets (perfiles con skills)

`--preset <nombre>` aplica agente, modelo, esfuerzo, rol, prompt y skills. Incluidos: `reviewer`
(Claude, solo lectura), `cheap` (OpenCode con Qwen3 Coder gratis) y `architect` (Claude, máximo esfuerzo).
Crea los tuyos en `~/.config/prama-agent/presets/<nombre>.env`; `SKILLS_DIR` apunta a una carpeta de
skills (`<skill>/SKILL.md`) que se carga como plugin solo en ese agente. Detalle en
[presets/README.md](presets/README.md).

## Telegram (control desde el celular)

```bash
prama-agent telegram setup     # pega el token de @BotFather y envía el código de 6 caracteres al bot
prama-agent telegram start     # bot 24/7 en una sesión persistente (status | logs | restart | stop)
```

- Emparejamiento con **código de un solo uso**: solo tu chat y tu usuario quedan autorizados.
- Menú con botones que se edita en su lugar: ver pantalla, hablar con un agente, lanzar, reiniciar o
  cerrar (con confirmación). Comandos: `/status`, `/logs`, `/send`, `/launch`, `/help`.
- Argumentos validados contra una lista blanca (agentes instalados, zonas registradas, sesiones vivas).
- El token se guarda en `~/.config/prama-agent/telegram.env` (`0600`) y nunca va en la línea de comandos.
- ⚠️ El bot equivale a una terminal remota: protege tu cuenta de Telegram con verificación en dos pasos.

## Perfiles LLM

```bash
prama-agent profiles                           # estado de cada perfil
prama-agent claude backend --profile deepseek  # Claude Code contra otro endpoint (openrouter/deepseek/glm/local)
prama-agent opencode backend --model openrouter/moonshotai/kimi-k2   # OpenCode con cualquier modelo de OpenRouter
```

Claves en `~/.config/prama-agent/providers.env` o `/etc/prama-agent/providers.env` (`chmod 600`).

## Configuración

`/etc/prama-agent/config.env` y `~/.config/prama-agent/config.env` (sintaxis bash; ver
[config/config.env.example](config/config.env.example)). Sin `ZONES`, cada repo git bajo
`PRAMA_DISCOVER_ROOTS` se registra como zona.

| Variable | Por defecto | |
| --- | --- | --- |
| `PRAMA_SKIP_PERMISSIONS` | `0` | `1` = YOLO por defecto |
| `PRAMA_DEFAULT_REMOTE` | `0` | Remote Control por defecto |
| `PRAMA_MENU_KEY` | `M-m` | tecla para volver al menú (evita `C-g`, que usa Claude Code) |
| `PRAMA_TMUX_SOCKET` | `prama` | servidor tmux dedicado |
| `PRAMA_WORKTREE_ROOT` | `<padre>/.prama-worktrees` | dónde se crean los worktrees |
| `PRAMA_COLOR` | auto | `truecolor` / `256` (útil si SSH no reenvía `COLORTERM`) |

**Worktrees:** se crean fuera del repo (`<padre>/.prama-worktrees/<repo>/<rama>`), reutilizan la rama
si existe (nunca la reinician) y copian `.env`, `.env.local` y `.mcp.json`.

## Migrar desde v5

`prama-agent doctor` detecta y limpia lo que dejó v5:

- borra el bus inseguro `/tmp/prama-bus`;
- `doctor --restore-tmux-conf` restaura tu `~/.tmux.conf` original (v5 lo sobrescribía);
- avisa si `/etc/prama-agent/config.env` sigue con `PRAMA_SKIP_PERMISSIONS=1`;
- las sesiones de v5 viven en tu tmux personal; v6 usa su propio servidor (`tmux -L prama`).

## Desarrollo

```bash
make lint     # bash -n + shellcheck + py_compile
make test     # suite en un servidor tmux, HOME y estado aislados
```

Arquitectura, invariantes de seguridad y API interna: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
Guía de contribución: [CONTRIBUTING.md](CONTRIBUTING.md).

## Licencia

[Apache License 2.0](LICENSE)
