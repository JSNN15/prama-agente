# Primeros pasos

[English](GETTING_STARTED.md) · **Español**

De un servidor (o computador) vacío a un equipo de agentes trabajando en tus repositorios, en cinco
pasos. Probado en Ubuntu 22.04 / 24.04 y Debian 12; sirve cualquier Linux con bash ≥ 4.4 y tmux ≥ 3.2.

## 1. Instala los CLIs de los agentes

prama-agent dirige agentes de código; no los reemplaza. Instala al menos uno:

| Agente | Instalación | Cuenta |
| --- | --- | --- |
| Claude Code (`claude`) | `curl -fsSL https://claude.ai/install.sh \| bash` | suscripción de Claude o clave de API de Anthropic |
| Antigravity CLI (`agy`) | según la documentación de Antigravity de Google | cuenta de Google |

Paquetes recomendados: `sudo apt install tmux git jq` (y `mosh` si te vas a conectar desde el celular).

## 2. Instala prama-agent

```bash
curl -fsSL https://raw.githubusercontent.com/JSNN15/prama-agente/main/install.sh | sudo bash   # para todo el sistema
curl -fsSL https://raw.githubusercontent.com/JSNN15/prama-agente/main/install.sh | bash        # solo para tu usuario
```

## 3. Ejecuta el asistente

```bash
prama-agent setup
```

Se puede repetir cuando quieras (`setup --check` solo revisa). Recorre:

**Inicio de sesión.** Las credenciales las guarda cada CLI: prama nunca las lee ni las almacena. El
asistente le pregunta a cada CLI si tiene sesión y, si no, abre su propio inicio de sesión:

```bash
prama-agent login            # estado de cada agente
prama-agent login claude     # claude auth login (en un servidor: abre el enlace en cualquier equipo y pega el código)
prama-agent login agy        # abre agy para entrar con tu cuenta de Google
```

Un agente sin sesión igual se lanza, pero prama lo marca `BLOCKED (login)` y deja su trabajo en cola
hasta que inicies sesión. Otros proveedores de modelos (OpenRouter, DeepSeek, GLM, un router local) se
configuran como perfiles: pon sus claves en `~/.config/prama-agent/providers.env` y lanza con
`--profile <nombre>` (`prama-agent profiles` los lista).

**Zonas.** Una zona es una carpeta de trabajo (normalmente un repositorio git) con un nombre corto que
vas a escribir: `backend`, `web`, `docs`. Mientras no registres ninguna, cada repositorio git que esté
directamente en `/opt` o en tu home es una zona. El asistente los lista para que elijas y les pongas
nombre; después:

```bash
prama-agent zones                                   # zonas y de dónde vienen
prama-agent zones scan                              # repositorios git aún sin registrar
prama-agent zones add backend /srv/app-backend "API y workers"
prama-agent zones remove backend
```

Las zonas registradas viven en `~/.config/prama-agent/zones.conf` (solo datos). También puedes
declararlas en `config.env` (`ZONES`, `ZONE_DIRS`), que gana si hay un nombre repetido.

**Permisos.** `ask` (el agente pregunta antes de cada acción, por defecto) o `yolo` (sin
confirmaciones, solo en servidores aislados que controlas). Cada agente puede cambiarlo con `--ask`,
`--plan` o `--yolo`.

## 4. Modelos

Cada CLI parte con su modelo por defecto. Tú eliges por agente o por equipo, y puedes cambiar el de un
agente en marcha sin perder su conversación:

```bash
prama-agent claude backend --model sonnet                     # un agente
prama-agent swarm backend --team docs --model opus --worker-model gemini-3.8-flash-high
prama-agent fleet models agy                                  # ids de modelos de agy (se validan antes de usarlos)
prama-agent fleet model prama-agy-backend gemini-4-argon-medium      # mismo panel, misma conversación
```

Los presets agrupan agente, modelo, nivel de esfuerzo y rol (`--preset cheap`, `reviewer`,
`architect`; ver [presets/README.md](../presets/README.md)).

## 5. Primer agente, primeros equipos

```bash
prama-agent                                   # el menú: n nuevo agente, s nuevo equipo
prama-agent claude backend                    # un agente, conectado (Alt+m vuelve al menú)
```

Un **equipo** es un coordinador más los agentes que gestiona. Una zona puede tener varios equipos, cada
uno con su nombre, coordinador, objetivo y cockpit:

```bash
prama-agent swarm backend --team arquitectura --workers agy:2 --task "Separar el módulo de facturación"
prama-agent swarm backend --team seguridad    --workers agy:1 --task "Auditar la autenticación"
prama-agent swarm backend --team docs         --workers agy:1 --task "Documentar la API pública"
prama-agent teams                             # los tres equipos de backend
prama-agent cockpit backend --team seguridad  # vista en vivo de un equipo
```

Los reportes y alertas de un agente van a su propio coordinador, y un coordinador solo puede gestionar
su equipo. Si repites `swarm` con el nombre de un equipo existente, los agentes se suman a ese equipo.

## Uso diario

| | |
| --- | --- |
| Volver al menú | `Alt+m` (o el botón `◂ MENU`): los agentes siguen trabajando |
| Lista de agentes / ir a cualquiera | `Alt+a` |
| Cockpit del equipo ⇄ agente | `Alt+c` |
| Agente siguiente / anterior | `Ctrl+b n` / `Ctrl+b p` |
| Cerrar un agente | `prama-agent stop <sesión>`, o `x` en el menú |
| Cerrar un equipo | `prama-agent swarm stop backend --team seguridad`, o `x` sobre su coordinador |
| Cerrar todo | `prama-agent stop --all -y` |

Desde el celular: mosh más el cockpit compacto, o el bot de Telegram (`prama-agent telegram setup`).
Ver la sección «Desde el celular» del README.

## Cuando algo falla

- `prama-agent doctor` revisa dependencias, agentes, hooks y configuración.
- `prama-agent fleet status` muestra por qué un agente está bloqueado (`login`, `credit`, `limit`,
  `trust`, `model`).
- Los agentes reportan solos los fallos de prama-agent (`prama-agent feedback list`);
  `feedback export <id>` te da el cuerpo de un issue para
  [GitHub](https://github.com/JSNN15/prama-agente/issues).
