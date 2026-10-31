## What / Qué

<!-- The change and why. / El cambio y por qué. -->

## How it was tested / Cómo se probó

- [ ] `make test` (bash suite + Telegram bot unit tests)
- [ ] New behaviour is covered by a test / El comportamiento nuevo tiene un test
- [ ] Manual check in a real tmux client when it touches the TUI, the cockpit or navigation / Prueba manual en un cliente tmux real si toca la TUI, el cockpit o la navegación

## Checklist

- [ ] No `tmux -t` without an exact target (`tmx`, `=session`) / Sin `tmux -t` sin destino exacto
- [ ] No secrets on a command line, no state file is ever sourced / Sin secretos en la línea de comandos, ningún archivo de estado se ejecuta
- [ ] README.md / README.es.md and CHANGELOG.md updated when user-facing / Documentación y CHANGELOG actualizados si cambia algo visible
