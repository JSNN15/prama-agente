# shellcheck shell=bash disable=SC2034
# Spanish catalog for lib/memory.sh (msgid = English text; see lib/i18n.sh)
I18N+=(
  ["Unknown zone or session: '%s'"]="Zona o sesión desconocida: '%s'"
  ["'%s' has no zone"]="'%s' no tiene zona"
  ['Invalid team name: %s']='Nombre de equipo inválido: %s'
  ['Unknown subcommand: memory %s']='Subcomando desconocido: memory %s'
  ['--team requires a name']='--team requiere un nombre'
  ['Which memory? Give a zone or a session, e.g.: prama-agent memory %s backend --team docs']='¿Qué memoria? Indica una zona o una sesión, p. ej.: prama-agent memory %s backend --team docs'
  ['ZONE']='ZONA'
  ['TEAM']='EQUIPO'
  ['NOTES']='NOTAS'
  ['UPDATED']='ACTUALIZADA'
  ['(no memories yet: prama-agent memory add <zone> --team <team> "<note>")']='(aún no hay memorias: prama-agent memory add <zona> --team <equipo> "<nota>")'
  ['# Zone memory: %s']='# Memoria de la zona: %s'
  ['# Team memory: %s · %s']='# Memoria del equipo: %s · %s'
  ['(the memory of %s · %s is empty: add notes with prama-agent memory add "<note>")']='(la memoria de %s · %s está vacía: agrega notas con prama-agent memory add "<nota>")'
  ['(the memory of zone %s is empty)']='(la memoria de la zona %s está vacía)'
  ['Empty note. Usage: prama-agent memory add "<note>"']='Nota vacía. Uso: prama-agent memory add "<nota>"'
  ['Saved to the memory of %s · %s']='Guardado en la memoria de %s · %s'
  ['Saved to the memory of zone %s']='Guardado en la memoria de la zona %s'
  ['Only the operator can clear a memory.']='Solo el operador puede borrar una memoria.'
  ['Nothing to clear: %s has no memory.']='Nada que borrar: %s no tiene memoria.'
  ['Clear the memory of %s (%s notes)? [y/N]']='¿Borrar la memoria de %s (%s notas)? [s/N]'
  ['Cancelled.']='Cancelado.'
  ['Memory of %s cleared']='Memoria de %s borrada'
)
