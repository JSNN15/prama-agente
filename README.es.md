# prama-agent

[English](README.md) · **Español**

[![CI](https://github.com/JSNN15/prama-agente/actions/workflows/ci.yml/badge.svg)](https://github.com/JSNN15/prama-agente/actions/workflows/ci.yml)
[![Licencia: Apache-2.0](https://img.shields.io/badge/licencia-Apache--2.0-blue.svg)](LICENSE)
![bash ≥ 4.4](https://img.shields.io/badge/bash-%E2%89%A5%204.4-4EAA25)
![tmux ≥ 3.2](https://img.shields.io/badge/tmux-%E2%89%A5%203.2-1BB91F)

**Plano de control en la terminal para agentes de código.** prama-agent lanza, supervisa y coordina
[Claude Code](https://docs.anthropic.com/en/docs/claude-code) y Google Antigravity (`agy`) en varios
repositorios, en un servidor remoto o en tu equipo. Las sesiones sobreviven a cortes de SSH, los
agentes se pasan trabajo mediante un bus de mensajes y un agente coordinador puede administrar su
propia flota: lanzar ayudantes, cambiarles el modelo, reiniciarlos y reaccionar cuando uno queda
bloqueado por un login, una cuota o un problema de facturación.

Es bash sobre un servidor tmux dedicado: sin daemon que instalar, sin base de datos, sin Node.js.

```
 ◆ PRAMA AGENT v6.0.0  server-01                   ● 3 activos · 1 trabajando   LOAD 1.63 · RAM 21%
 Próximo agente ›  o  Rol ✦ executor   y  Permisos ● ASK   e  Remoto off   p  Perfil default
╭─ Sesiones ───────────────────────────────── 3 ─╮╭─ ◉ prama-agy-web ─────────────────────────────╮
│   ● agy-web          ✦ exec  trabaja ▱▱▱▱   0% ││ ✦ executor · ● trabaja · CPU 3% · up 04:12    │
│ ▸ ● claude-backend   ✦ exec  listo   ▰▰▱▱  54% │├─ en vivo ─────────────────────────────────────┤
│   ● claude-backend   ❖ coord listo   ▱▱▱▱   0% ││ > agrega endpoint /health                     │
├─ Acciones ─────────────────────────────────────┤│ Thinking… editando src/routes/health.ts       │
│   ✚ Nuevo agente         claude o agy en zona ││                                               │
│   ❖ Coordinar enjambre   coordinador + ejecut… ││                                               │
╰────────────────────────────────────────────────╯╰───────────────────── ↵ entrar · t tarea · l logs ─╯
  ↵  entrar  t  tarea  n  nuevo  l  logs  x  cerrar  r  reiniciar  /  filtrar  c  cockpit  ?  ayuda
```

## Por qué

Usar agentes de código para trabajo real termina en una docena de terminales: una por repositorio,
varias esperando un login, una detenida en silencio por un límite de uso, otra perdida porque se cortó
la conexión SSH. prama-agent las convierte en una flota supervisada:

- **Sesiones persistentes.** Cada agente corre bajo un supervisor en su propia sesión de un servidor
  tmux dedicado (`tmux -L prama`). Cierra el portátil, pierde la conexión y vuelve a entrar desde el
  celular.
- **Salud confiable.** Los agentes informan su estado mediante los hooks del CLI, no solo leyendo la
  pantalla: `READY`, `WORKING`, `BLOCKED` (con motivo: `login`, `auth`, `credit`, `limit`, `trust`,
  `model`), `STANDBY`. Nunca se escribe sobre un agente bloqueado; su trabajo queda en cola.
- **La cuota antes del choque.** El uso de las ventanas de 5 horas y semanal, su hora de reinicio y el
  uso de contexto se recogen de la statusline de cada agente. El coordinador recibe aviso al 90 %.
- **Agentes que administran agentes.** Un coordinador puede lanzar, editar, reiniciar y cerrar
  ayudantes con una API JSON con límites (alcance, máximo, nunca a sí mismo, nunca a otro coordinador).
- **Reinicio en el mismo panel.** Cambiar el modelo o el preset relanza el agente en el mismo panel y
  retoma la misma conversación; el scrollback se conserva.

## Instalación

```bash
git clone https://github.com/JSNN15/prama-agente.git && cd prama-agente
sudo make install            # o por usuario: make install PREFIX=~/.local CONF_DIR=~/.config/prama-agent
prama-agent doctor           # verifica dependencias, agentes, hooks y configuración
```

Requisitos: bash ≥ 4.4, tmux ≥ 3.2, git. Recomendados: `jq` (hooks y telemetría de cuota), `fzf`,
`less`. El puente opcional con Telegram necesita `python3` y `curl`. Al menos un CLI de agente:
`claude` (Claude Code) o `agy` (Antigravity CLI).

## Uso rápido

```bash
prama-agent                                   # interfaz interactiva
prama-agent claude backend                    # lanza Claude Code en la zona "backend" y entra
prama-agent agy web --bg -w feat/login        # en segundo plano, aislado en un git worktree
prama-agent claude backend --role reader      # auditor de solo lectura (plan mode)
prama-agent status                            # resumen de la flota
prama-agent attach prama-claude-backend       # volver a entrar (Alt+m regresa al menú)
```

Una **zona** es un directorio de trabajo con nombre, normalmente un repositorio. Las zonas se definen en
`config.env` o se descubren a partir de los repositorios git bajo `PRAMA_DISCOVER_ROOTS`.

### Interfaz interactiva

| Tecla | Acción | Tecla | Acción |
| --- | --- | --- | --- |
| `↑↓` `jk` `1-9` | moverse | `↵` | entrar a la sesión / elegir |
| `n` | nuevo agente (asistente) | `t` | enviar una tarea a la sesión |
| `l` | historial (`less`) | `r` / `x` | reiniciar / cerrar (con confirmación) |
| `/` | filtrar sesiones | `f` | inspector `fzf` con vista previa |
| `c` | cockpit (coordinador + ejecutor + bus) | `?` | ayuda |
| `o` `y` `e` `p` `w` `g` | rol · permisos · remoto · perfil LLM · worktree · segundo plano | `q` | salir |

Se adapta al ancho (lista y vista previa lado a lado desde 100 columnas, apiladas en el celular), se
refresca cada 2 s y admite toques y rueda del ratón. Desde un agente, `Alt+m` (o `◂ MENU` en la barra
inferior) vuelve al menú sin detenerlo.

## Administración de la flota

Todo lo siguiente está disponible para ti y para un agente coordinador; `--json` da salida para
máquinas.

```bash
prama-agent fleet status --json              # estado, motivo de bloqueo, modelo, preset, cola, cuota
prama-agent fleet spawn agy backend --preset cheap --task "Agrega tests a utils/date.ts"
prama-agent fleet model prama-claude-backend-2 sonnet      # mismo panel, misma conversación
prama-agent fleet edit  prama-claude-backend-2 --effort high --preset reviewer
prama-agent fleet restart <sesión> · fleet kill <sesión> · fleet presets · fleet models agy
prama-agent fleet hooks status               # hooks de salud de cada CLI
```

- **Watchdog.** Una sesión interna arranca con el primer agente. Avisa al coordinador de la zona (y a
  Telegram, si está configurado) cuando un agente se bloquea, se detiene, se recupera o cruza el umbral
  de cuota, y entrega las tareas en cola cuando el agente vuelve a estar listo.
- **Límites para los agentes.** Un agente no puede actuar sobre sí mismo ni sobre un coordinador, solo
  dentro de su alcance (`PRAMA_FLEET_SCOPE=zone|children|all`), y `spawn` respeta `PRAMA_FLEET_MAX`.
  Cada acción queda registrada en el bus.
- **Cambiar de modelo nunca altera tus valores por defecto.** prama reinicia el agente con `--model` en
  vez de escribir `/model`, que en Claude Code también reescribe tu modelo global. Los ids de modelo de
  agy se validan contra `agy models`, porque agy usa en silencio su modelo por defecto si el id no
  existe.

### Cómo se obtienen la salud y la cuota

| | Claude Code | Antigravity (`agy`) |
| --- | --- | --- |
| Hooks | `SessionStart`, `UserPromptSubmit`, `Stop`, `StopFailure`, `Notification`, … inyectados por sesión con `--settings` | `SessionStart`, `PreInvocation`, `Stop` (el texto del error se clasifica) |
| Dónde | solo en la sesión; `~/.claude` no se modifica | una entrada con nombre, `prama-agent`, en `~/.gemini/config/hooks.json` (agy no admite hooks por sesión); no hace nada fuera de los paneles de prama; `fleet hooks uninstall` la elimina |
| Cuota | `rate_limits` de la statusline (5 h / 7 d) | buckets de `quota` de la statusline para la familia del modelo activo |
| Reanudar | `--session-id` / `--resume <id>` | `--conversation <id>` (id que informan los hooks) |

La lectura de pantalla queda como respaldo para los diálogos que aparecen antes de los hooks (login,
confianza en la carpeta, selector de modelo). Si ya usas una statusline propia en Claude Code, prama la
encadena.

## Roles y enjambres

| Rol | Uso |
| --- | --- |
| `✦ executor` | implementa y prueba; informa con `prama-agent bus report` |
| `❖ coordinator` | planifica, delega con `bus assign` y administra la flota |
| `◉ reader` | revisor de solo lectura (plan mode) |
| `♺ daemon` | procesa una cola de tareas en bucle (`--loop 60 --task "…"`) |

```bash
prama-agent bus swarm-start backend claude agy   # coordinador (claude) + ejecutor (agy)
prama-agent cockpit backend                      # vista dividida: ambos agentes + bus en vivo
prama-agent bus assign executor "Implementa /health y corre pytest"
prama-agent bus watch                            # eventos en vivo
```

`assign` acepta un nombre exacto de sesión o un rol y nunca hace coincidencias parciales. Solo se
escribe en agentes listos o trabajando; lo demás queda en cola (colas Maildir, seguras con varios
consumidores).

## Presets

`--preset <nombre>` aplica de una vez agente, modelo, esfuerzo, rol, prompt adicional y una carpeta de
skills. Incluidos: `reviewer` (Claude, solo lectura), `architect` (Claude, esfuerzo muy alto) y `cheap`
(agy Flash para trabajo mecánico). Los tuyos van en `~/.config/prama-agent/presets/<nombre>.env`; un
`SKILLS_DIR` con carpetas `<skill>/SKILL.md` se monta como plugin solo para ese agente. Ver
[presets/README.md](presets/README.md).

## Permisos y seguridad

| Modo | Flag | Comportamiento |
| --- | --- | --- |
| **ASK** (por defecto) | `--ask` | el agente pregunta antes de cada acción |
| **PLAN** | `--plan`, `--role reader` | modo de solo lectura nativo del CLI |
| **YOLO** | `--yolo`, `PRAMA_SKIP_PERMISSIONS=1` | sin confirmaciones; para servidores aislados que controlas |

Garantías de diseño (detalle en [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)):

- **Servidor tmux dedicado**: tus sesiones tmux y tu `~/.tmux.conf` nunca se tocan.
- Todo el estado vive en `~/.local/state/prama-agent` (modo `0700`); nada en `/tmp`.
- Estado, colas y eventos son datos: nunca se ejecutan con `source` ni `eval`.
- Las claves de API nunca aparecen en la línea de comandos (`ps`); se aplican dentro del panel.
- Objetivos tmux exactos: cerrar `prama-claude` nunca cierra `prama-claude-backend`.
- Cerrar una sesión termina todo su grupo de procesos: no quedan agentes huérfanos corriendo.

Para reportar vulnerabilidades, ver [SECURITY.md](SECURITY.md).

## Telegram (control desde el celular)

```bash
prama-agent telegram setup     # pega el token de @BotFather y envía al bot el código de un solo uso
prama-agent telegram start     # bot 24/7 en una sesión persistente (status | logs | restart | stop)
```

Emparejamiento con código de un solo uso (solo tu chat y tu usuario quedan autorizados), menús con
botones para ver una pantalla, hablar con un agente, lanzar, reiniciar o cerrar, y argumentos validados
contra listas blancas. El bot equivale a una terminal remota: protege tu cuenta de Telegram con
verificación en dos pasos.

## Perfiles LLM

`--profile` dirige Claude Code a otro endpoint compatible con Anthropic: `openrouter`, `deepseek`,
`glm` o `local` (un router como claude-code-router). Las claves van en `providers.env` (`chmod 600`).

```bash
prama-agent profiles
prama-agent claude backend --profile deepseek
```

## Configuración

`/etc/prama-agent/config.env` y luego `~/.config/prama-agent/config.env` (sintaxis bash, ver
[config/config.env.example](config/config.env.example)).

| Variable | Por defecto | |
| --- | --- | --- |
| `ZONES` / `ZONE_DIRS` | descubiertas | directorios de trabajo con nombre |
| `PRAMA_SKIP_PERMISSIONS` | `0` | `1` = YOLO por defecto |
| `PRAMA_DEFAULT_REMOTE` | `0` | control remoto de los CLIs activado por defecto |
| `PRAMA_FLEET_MAX` / `PRAMA_FLEET_SCOPE` | `8` / `zone` | límites de la flota para los agentes |
| `PRAMA_HOOKS` / `PRAMA_STATUSLINE` | `1` / `1` | hooks de salud / telemetría de cuota |
| `PRAMA_QUOTA_WARN` | `90` | umbral de alerta de cuota (%) |
| `PRAMA_WATCHDOG` | `1` | watchdog de la flota |
| `PRAMA_MENU_KEY` | `M-m` | tecla para volver del agente al menú |
| `PRAMA_EXPERIMENTAL` | `0` | habilita agentes experimentales (OpenCode) |

Los **worktrees** (`-w <rama>`) se crean fuera del repositorio
(`<padre>/.prama-worktrees/<repo>/<rama>`), reutilizan la rama si ya existe sin reiniciarla y copian
`.env`, `.env.local` y `.mcp.json`.

## Estado y hoja de ruta

| Agente | Estado |
| --- | --- |
| Claude Code | soportado: hooks, cuota, reanudación, presets, control remoto |
| Antigravity (`agy`) | soportado: hooks, cuota, reanudación, validación de modelos, control remoto |
| OpenCode | **experimental**: integrado y probado, desactivado por defecto (`PRAMA_EXPERIMENTAL=1`) |
| Hermes Agent | **en evaluación**, no integrado |

OpenCode y Hermes son los dos candidatos serios para usar modelos abiertos (Qwen, Kimi, GLM,
DeepSeek) vía OpenRouter como agentes de bajo costo. La evaluación y los criterios para habilitarlos
están en [docs/ROADMAP.md](docs/ROADMAP.md).

## Migrar desde v5

`prama-agent doctor` detecta y limpia lo que dejó v5: borra el bus inseguro `/tmp/prama-bus`,
`doctor --restore-tmux-conf` restaura tu `~/.tmux.conf` original y avisa de agentes que corren fuera de
prama (no sobreviven a un corte de SSH). Las sesiones de v5 vivían en tu tmux personal; v6 usa su
propio servidor.

## Desarrollo

```bash
make lint     # bash -n, shellcheck, py_compile
make test     # suite de extremo a extremo en un servidor tmux, HOME y estado aislados
```

Arquitectura, invariantes de seguridad y API interna: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
(en inglés). Contribuir: [CONTRIBUTING.md](CONTRIBUTING.md). Cambios: [CHANGELOG.md](CHANGELOG.md).

## Licencia

[Apache License 2.0](LICENSE)
