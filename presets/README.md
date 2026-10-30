# Presets

Un preset es un perfil de agente reutilizable: agente, modelo, esfuerzo, rol, prompt y skills.
Se usan con `--preset <nombre>` al lanzar (`prama-agent claude backend --preset reviewer`) o
desde el coordinador (`prama-agent fleet spawn claude backend --preset reviewer`).

Búsqueda, por prioridad: `~/.config/prama-agent/presets/`, `/etc/prama-agent/presets/`, y esta carpeta.
Los archivos son `KEY=value` (nunca se ejecutan). Las rutas relativas parten de la carpeta del preset;
las listas se separan con `:`.

| Clave | Uso |
| --- | --- |
| `DESCRIPTION` | texto para `prama-agent fleet presets` |
| `AGENT` `ROLE` `PROFILE` | valores por defecto (los flags explícitos ganan) |
| `MODEL` `EFFORT` | `--model` / `--effort` (en opencode, el modelo va en su configuración) |
| `PROMPT` / `PROMPT_FILE` | instrucciones extra que se suman al prompt de rol |
| `SKILLS_DIR` | carpeta con `<skill>/SKILL.md`; prama la empaqueta como plugin (`--plugin-dir`) solo para ese agente |
| `PLUGIN_DIRS` `ADD_DIRS` | `--plugin-dir` / `--add-dir` adicionales (claude) |
| `AGENTS_FILE` `MCP_CONFIG` | `--agents` / `--mcp-config` (claude) |
| `ALLOWED_TOOLS` `DISALLOWED_TOOLS` | `--allowed-tools` / `--disallowed-tools` (claude) |
