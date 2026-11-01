# shellcheck shell=bash disable=SC2034
# Spanish catalog for lib/health.sh (msgid = English text; see lib/i18n.sh)
I18N+=(
  ['Mon']='lun'
  ['Tue']='mar'
  ['Wed']='mié'
  ['Thu']='jue'
  ['Fri']='vie'
  ['Sat']='sáb'
  ['Sun']='dom'
  ['▲ %s blocked (%s): %s']='▲ %s bloqueado (%s): %s'
  ["[PRAMA ALERT] '%s' is BLOCKED (%s): %s. Its tasks stay queued. Options: 'prama-agent fleet restart %s', 'prama-agent fleet model %s <model>', reassign with 'prama-agent bus assign', or tell the operator if it needs a manual login."]='[ALERTA PRAMA] '\''%s'\'' está BLOQUEADO (%s): %s. Sus tareas quedan en cola. Opciones: '\''prama-agent fleet restart %s'\'', '\''prama-agent fleet model %s <modelo>'\'', reasignar con '\''prama-agent bus assign'\'', o avisar al operador si requiere login manual.'
  ['■ %s stopped (%s)']='■ %s detenido (%s)'
  ["[PRAMA ALERT] '%s' stopped (%s). Relaunch it with 'prama-agent fleet restart %s' or close it with 'prama-agent fleet kill %s'."]='[ALERTA PRAMA] '\''%s'\'' se detuvo (%s). Relánzalo con '\''prama-agent fleet restart %s'\'' o ciérralo con '\''prama-agent fleet kill %s'\''.'
  ['✔ %s recovered (%s)']='✔ %s recuperado (%s)'
  ["[PRAMA] '%s' recovered and is %s."]='[PRAMA] '\''%s'\'' se recuperó y está %s.'
  ['[QUEUED TASK]: %s']='[TAREA EN COLA]: %s'
  ['→ %s: queued task delivered']='→ %s: tarea en cola entregada'
  ['◔ quota %s %s at %s%%']='◔ cuota %s %s al %s%%'
  ["[PRAMA ALERT] %s quota at %s%% (%s window, resets %s). It affects every %s agent on this account: move heavy tasks to other agents/models (e.g. 'prama-agent fleet spawn agy <zone>' or 'prama-agent fleet model <session> <model>') before they get blocked."]='[ALERTA PRAMA] Cuota de %s al %s%% (ventana %s, se renueva %s). Afecta a todos los agentes %s de esta cuenta: reparte las tareas pesadas a otros agentes/modelos (p. ej. '\''prama-agent fleet spawn agy <zona>'\'' o '\''prama-agent fleet model <sesión> <modelo>'\'') antes de que se bloqueen.'
  ['Fleet watchdog running (every %ss). Ctrl+C to stop it.']='Watchdog de la flota activo (cada %ss). Ctrl+C para detenerlo.'
  ['No agents left; watchdog finished.']='Sin agentes; watchdog finalizado.'
)
