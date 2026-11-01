# shellcheck shell=bash disable=SC2034
# Spanish catalog for lib/feedback.sh (msgid = English text; see lib/i18n.sh)
# The issue body (feedback export) stays in English: the project's issue tracker is shared.
I18N+=(
  ["Invalid report id: '%s' (prama-agent feedback list)"]='Id de reporte inválido: '\''%s'\'' (prama-agent feedback list)'
  ["Report '%s' does not exist."]='No existe el reporte '\''%s'\''.'
  ['Describe the problem: prama-agent feedback "<what happened>"']='Describe el problema: prama-agent feedback "<qué pasó>"'
  ['Already reported: %s (repeated %s times).']='Ya estaba reportado: %s (repetido %s veces).'
  ['There are %s open reports; the operator must review them (prama-agent feedback list).']='Hay %s reportes abiertos; el operador debe revisarlos (prama-agent feedback list).'
  ['Could not create %s']='No se pudo crear %s'
  ['🐞 prama-agent report (%s) from %s: %s — prama-agent feedback show %s']='🐞 Reporte de prama-agent (%s) de %s: %s — prama-agent feedback show %s'
  ["Report %s filed. The operator will see it in 'prama-agent feedback list'."]='Reporte %s registrado. El operador lo verá en '\''prama-agent feedback list'\''.'
  ['Unknown option: %s']='Opción desconocida: %s'
  ['No open reports.']='No hay reportes abiertos.'
  ['No reports.']='No hay reportes.'
  ['Details: prama-agent feedback show <id> · issue: prama-agent feedback export <id>']='Detalle: prama-agent feedback show <id> · issue: prama-agent feedback export <id>'
  ["Agent's latest events:"]='Últimos eventos del agente:'
  ['Post as an issue: prama-agent feedback export %s | gh issue create -R %s -t "<title>" -F -']='Publicar como issue: prama-agent feedback export %s | gh issue create -R %s -t "<título>" -F -'
  ['Mark as handled: prama-agent feedback close %s']='Marcar como atendido: prama-agent feedback close %s'
  ['Usage: prama-agent feedback close <id>... | --all']='Uso: prama-agent feedback close <id>... | --all'
  ['Only the operator closes reports.']='Solo el operador cierra reportes.'
  ['Reports closed: %s']='Reportes cerrados: %s'
)
