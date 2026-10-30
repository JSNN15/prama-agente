# Presets

**English** · [Español](#español)

A preset is a reusable agent profile: agent, model, effort, role, extra prompt and skills. Use it when
launching (`prama-agent claude backend --preset reviewer`) or from a coordinator
(`prama-agent fleet spawn claude backend --preset reviewer`).

Lookup order: `~/.config/prama-agent/presets/`, `/etc/prama-agent/presets/`, then this folder. Files
are `KEY=value` lines and are never executed. Relative paths are resolved from the preset's folder;
lists are separated by `:`.

| Key | Effect |
| --- | --- |
| `DESCRIPTION` | text shown by `prama-agent fleet presets` |
| `AGENT` `ROLE` `PROFILE` | defaults (explicit flags win) |
| `MODEL` `EFFORT` | `--model` / `--effort` (OpenCode: the model goes into its configuration) |
| `PROMPT` / `PROMPT_FILE` | extra instructions appended to the role prompt |
| `SKILLS_DIR` | folder of `<skill>/SKILL.md`; packaged as a plugin (`--plugin-dir`) for that agent only |
| `PLUGIN_DIRS` `ADD_DIRS` | extra `--plugin-dir` / `--add-dir` (Claude Code) |
| `AGENTS_FILE` `MCP_CONFIG` | `--agents` / `--mcp-config` (Claude Code) |
| `ALLOWED_TOOLS` `DISALLOWED_TOOLS` | `--allowed-tools` / `--disallowed-tools` (Claude Code) |

Bundled presets:

| Preset | Agent | Purpose |
| --- | --- | --- |
| `reviewer` | Claude Code | read-only code review |
| `architect` | Claude Code | design work at extra-high effort |
| `cheap` | agy (Flash) | mechanical tasks: tests, scoped refactors, docs |
| `openrouter-free` | OpenCode | *experimental*, needs `PRAMA_EXPERIMENTAL=1` |

## Español

Un preset es un perfil de agente reutilizable: agente, modelo, esfuerzo, rol, prompt adicional y
skills. Se usa al lanzar (`--preset <nombre>`) o desde el coordinador con `fleet spawn`. Se buscan en
`~/.config/prama-agent/presets/`, `/etc/prama-agent/presets/` y esta carpeta; son líneas `KEY=value` y
nunca se ejecutan. Las claves son las de la tabla anterior. `SKILLS_DIR` apunta a una carpeta con
`<skill>/SKILL.md` que se monta como plugin solo para ese agente.
