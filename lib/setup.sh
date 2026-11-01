#!/usr/bin/env bash
# lib/setup.sh — First steps: zones (workspaces), agent logins and the setup wizard
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
#
#   prama-agent setup [--check]                guided first configuration (re-runnable)
#   prama-agent login [claude|agy|opencode]    login status of every agent / sign one in
#   prama-agent zones [list] [--json]          zones and where they come from
#   prama-agent zones add <name> <dir> ["description"]
#   prama-agent zones remove <name>
#   prama-agent zones scan [root…]             git repositories not registered yet
#
# Credentials stay with each agent CLI (Claude Code, agy): prama never reads or stores them, it
# only asks the CLI whether it is signed in and opens its own login. Zones are written to
# zones.conf (data, never sourced); scalar defaults go to the user's config.env.

# ── Zones ───────────────────────────────────────────────────────────────────
# _zone_source <name> → zones.conf | config.env | descubierta
_zone_source() {
  local f
  f=$(zones_file)
  if (( ZONES_DISCOVERED )); then printf 'descubierta'
  elif [ -f "$f" ] && grep -q "^$1|" "$f" 2>/dev/null; then printf 'zones.conf'
  else printf 'config.env'
  fi
}

subcmd_zones() {
  case "${1:-}" in
    ''|list|ls)  shift || true; _zones_list "$@" ;;
    --json)      _zones_list --json ;;
    add)         shift; _zones_add "$@" ;;
    remove|rm)   shift; _zones_remove "$@" ;;
    scan)        shift; _zones_scan "$@" ;;
    help|-h|--help)
      cat <<'EOF'
Uso: prama-agent zones [list] [--json]                  zonas (carpetas de trabajo) y su origen
     prama-agent zones add <nombre> <carpeta> ["desc"]   registrar una carpeta con un nombre corto
     prama-agent zones remove <nombre>                    quitar una zona registrada
     prama-agent zones scan [raíz…]                       repositorios git aún sin registrar

Sin zonas registradas, cada repositorio git directamente bajo PRAMA_DISCOVER_ROOTS es una zona.
Al registrar la primera, la lista pasa a ser la tuya (zones.conf y config.env).
EOF
      ;;
    *) die "Uso: prama-agent zones [list|add|remove|scan|help]" ;;
  esac
}

_zones_list() {
  local i
  if [ "${1:-}" = "--json" ]; then
    printf '['
    for i in "${!ZONES[@]}"; do
      (( i )) && printf ','
      printf '{"name":"%s","dir":"%s","exists":%s,"source":"%s","desc":"%s"}' "$(json_escape "${ZONES[$i]}")" \
        "$(json_escape "${ZONE_DIRS[$i]}")" "$([ -d "${ZONE_DIRS[$i]}" ] && echo true || echo false)" \
        "$(_zone_source "${ZONES[$i]}")" "$(json_escape "${ZONE_DESCS[$i]:-}")"
    done
    printf ']\n'
    return 0
  fi
  for i in "${!ZONES[@]}"; do
    printf '%-16s %-40s %s%s\n' "${ZONES[$i]}" "${ZONE_DIRS[$i]}" "$(_zone_source "${ZONES[$i]}")" \
      "$([ -d "${ZONE_DIRS[$i]}" ] || printf ' · ¡no existe!')"
  done
}

_zones_add() {
  local name=${1:-} dir=${2:-} desc=${3:-} f i
  [ -n "$name" ] && [ -n "$dir" ] || die "Uso: prama-agent zones add <nombre> <carpeta> [\"descripción\"]"
  valid_zone_name "$name" || die "Nombre inválido '$name': minúsculas, números, - y _ (máx. 24), p. ej. backend"
  [ -d "$dir" ] || die "La carpeta '$dir' no existe."
  dir=$(cd "$dir" && pwd -P)
  desc=${desc//|/-}; desc=${desc//$'\n'/ }
  if (( ! ZONES_DISCOVERED )); then
    for i in "${!ZONES[@]}"; do
      [ "${ZONES[$i]}" = "$name" ] || continue
      [ "$(_zone_source "$name")" = zones.conf ] || die "La zona '$name' está definida en config.env; edítala allí."
      _zones_remove "$name" >/dev/null
    done
  fi
  f=$(zones_file)
  ensure_private_dir "$PRAMA_CONFIG_HOME"
  ( umask 077; printf '%s|%s|%s\n' "$name" "$dir" "${desc:-$(basename "$dir")}" >> "$f" )
  [ -d "$dir/.git" ] || warn "'$dir' no es un repositorio git: funciona, pero sin worktrees (-w)."
  ok "Zona '$name' → $dir"
  (( ZONES_DISCOVERED )) && info_msg "Desde ahora las zonas son las que registres (antes se descubrían en: $PRAMA_DISCOVER_ROOTS)."
  return 0
}

_zones_remove() {
  local name=${1:-} f tmp
  [ -n "$name" ] || die "Uso: prama-agent zones remove <nombre>"
  f=$(zones_file)
  if [ ! -f "$f" ] || ! grep -q "^$name|" "$f"; then
    is_in "$name" "${ZONES[@]}" && (( ! ZONES_DISCOVERED )) \
      && die "La zona '$name' está definida en config.env; quítala allí."
    die "No hay una zona registrada '$name' (prama-agent zones)."
  fi
  tmp="$f.tmp.$$"
  grep -v "^$name|" "$f" > "$tmp" || true
  mv -f "$tmp" "$f"
  ok "Zona '$name' quitada (la carpeta no se toca)."
}

# Git repositories under the roots that are not a zone yet: "dir" lines.
_zones_candidates() {
  local root d
  for root in "$@"; do
    [ -d "$root" ] || continue
    for d in "$root"/*; do
      [ -d "$d/.git" ] || continue
      d=$(cd "$d" && pwd -P)
      (( ZONES_DISCOVERED )) || ! is_in "$d" "${ZONE_DIRS[@]}" || continue
      printf '%s\n' "$d"
    done
  done
}

_zones_scan() {
  local -a roots=("$@") found=()
  (( ${#roots[@]} )) || read -ra roots <<< "$PRAMA_DISCOVER_ROOTS"
  mapfile -t found < <(_zones_candidates "${roots[@]}")
  if (( ! ${#found[@]} )); then info_msg "No hay repositorios git nuevos en: ${roots[*]}"; return 0; fi
  local d
  for d in "${found[@]}"; do printf '%-18s %s\n' "$(_zone_suggest_name "$d")" "$d"; done
  info_msg "Registra una con: prama-agent zones add <nombre> <carpeta>"
}

# A short zone name from a folder: "Pramatic-Landing" → "pramatic-landing"
_zone_suggest_name() {
  local n
  n=$(basename "$1"); n=${n,,}; n=${n//[^a-z0-9_-]/-}; n=${n#[-_]}
  printf '%s' "${n:0:24}"
}

# ── Agent logins ────────────────────────────────────────────────────────────
# agent_auth_status <agent> → "ok|<detail>", "no|<hint>" or "?|<hint>"
agent_auth_status() {
  local a=$1 out
  agent_installed "$a" || { printf 'missing|%s' "$(_agent_install_hint "$a")"; return 0; }
  case "$a" in
    claude)
      if [ -n "${ANTHROPIC_API_KEY:-}" ]; then printf 'ok|ANTHROPIC_API_KEY'; return 0; fi
      out=$(timeout 15 claude auth status --json 2>/dev/null) || out=''
      if [[ "$out" =~ \"loggedIn\"[[:space:]]*:[[:space:]]*true ]]; then
        [[ "$out" =~ \"authMethod\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && printf 'ok|%s' "${BASH_REMATCH[1]}" || printf 'ok|'
      elif [ -n "$out" ]; then printf 'no|prama-agent login claude'
      else printf '?|prama-agent login claude'
      fi ;;
    agy)
      # agy has no status command; its OAuth token lives under ~/.gemini.
      if [ -s "$HOME/.gemini/antigravity-cli/antigravity-oauth-token" ] || [ -s "$HOME/.gemini/oauth_creds.json" ]; then
        printf 'ok|cuenta Google'
      else printf 'no|prama-agent login agy'
      fi ;;
    opencode) printf '?|opencode auth login (o OPENROUTER_API_KEY en providers.env)' ;;
    *) printf '?|' ;;
  esac
}

_agent_install_hint() {
  case "$1" in
    claude)   printf 'curl -fsSL https://claude.ai/install.sh | bash' ;;
    agy)      printf 'instala Antigravity CLI (agy) desde su documentación oficial' ;;
    opencode) printf 'npm i -g @opencode/cli' ;;
    *)        printf 'instálalo y ponlo en el PATH' ;;
  esac
}

subcmd_login() {
  local a=${1:-} st info
  if [ -z "$a" ]; then
    for a in "${AGENTS[@]}"; do
      st=$(agent_auth_status "$a") info=${st#*|}
      case ${st%%|*} in
        ok)      printf ' %s✔%s %-9s sesión iniciada%s\n' "$C_LIVE" "$C_OFF" "$a" "${info:+ ($info)}" ;;
        no)      printf ' %s✖%s %-9s sin sesión → %s\n' "$C_ERR" "$C_OFF" "$a" "${st#*|}" ;;
        missing) printf ' %s○%s %-9s no instalado → %s\n' "$C_MUTED" "$C_OFF" "$a" "${st#*|}" ;;
        *)       printf ' %s?%s %-9s no se pudo comprobar → %s\n' "$C_BRASS" "$C_OFF" "$a" "${st#*|}" ;;
      esac
    done
    return 0
  fi
  is_in "$a" "${AGENTS[@]}" || die "Agente no habilitado: '$a' (${AGENTS[*]})"
  agent_installed "$a" || die "$a no está instalado: $(_agent_install_hint "$a")"
  [ -t 0 ] || die "El inicio de sesión es interactivo: ejecútalo en una terminal."
  case "$a" in
    claude)
      info_msg "Claude Code: se abrirá el inicio de sesión (en un servidor, copia el enlace en tu navegador y pega el código)."
      claude auth login || die "No se completó el inicio de sesión de Claude Code." ;;
    agy)
      info_msg "Antigravity: se abre agy; sigue su inicio de sesión con tu cuenta Google y luego sal (Ctrl+C dos veces)."
      agy || true ;;
    opencode)
      opencode auth login || die "No se completó el inicio de sesión de OpenCode." ;;
  esac
  st=$(agent_auth_status "$a")
  if [ "${st%%|*}" = ok ]; then ok "$a: sesión iniciada."; else warn "$a: todavía sin sesión (${st#*|})."; fi
}

# ── User defaults (scalar keys in ~/.config/prama-agent/config.env) ─────────
# _config_set KEY VALUE — replaces or appends one assignment; only known keys and plain values.
_config_set() {
  local key=$1 val=$2 f tmp
  [[ "$key" =~ ^(PRAMA_SKIP_PERMISSIONS|PRAMA_DEFAULT_REMOTE|PRAMA_SWARM_WORKERS|PRAMA_LANG|PRAMA_THEME|PRAMA_TUI_MOUSE)$ ]] || die "Clave no admitida: $key"
  [[ "$val" =~ ^[A-Za-z0-9:,._-]*$ ]] || die "Valor no admitido para $key: '$val'"
  f="$PRAMA_CONFIG_HOME/config.env"
  ensure_private_dir "$PRAMA_CONFIG_HOME"
  [ -f "$f" ] || printf '# prama-agent — configuración del usuario (bash). Referencia: config/config.env.example\n' > "$f"
  tmp="$f.tmp.$$"
  { grep -v "^$key=" "$f" || true; printf '%s="%s"\n' "$key" "$val"; } > "$tmp" && mv -f "$tmp" "$f"
}

# ── Setup wizard ────────────────────────────────────────────────────────────
_setup_ask() {   # _setup_ask "question" default → REPLY (default when empty)
  local d=${2:-}
  IFS= read -r -e -p " ${C_NEON}?${C_OFF} $1${d:+ [$d]}: " REPLY || REPLY=''
  [ -n "$REPLY" ] || REPLY=$d
}

_setup_header() { printf '\n %s%s%s\n' "$C_BOLD" "$1" "$C_OFF"; }

subcmd_setup() {
  local check=0
  [ "${1:-}" = --check ] && check=1
  [ -t 0 ] || check=1
  printf '\n %s◆ PRAMA AGENT · primeros pasos%s  v%s\n' "$C_BOLD" "$C_OFF" "$VERSION"
  (( check )) && printf ' %s(solo comprobación: ejecuta "prama-agent setup" en una terminal para configurar)%s\n' "$C_MUTED" "$C_OFF"

  # 1 · Dependencies
  _setup_header "1 · Dependencias"
  local dep missing=()
  for dep in tmux git jq; do
    if command -v "$dep" >/dev/null 2>&1; then printf ' %s✔%s %s\n' "$C_LIVE" "$C_OFF" "$dep"
    else printf ' %s✖%s %s\n' "$C_ERR" "$C_OFF" "$dep"; missing+=("$dep"); fi
  done
  (( ${#missing[@]} )) && warn "Instala: sudo apt install ${missing[*]}  (jq: salud y cuota de los agentes)"

  # 2 · Agents and their logins
  _setup_header "2 · Agentes y sesión (las credenciales las guarda cada CLI; prama no las lee)"
  local a st info any=0
  for a in "${AGENTS[@]}"; do
    st=$(agent_auth_status "$a") info=${st#*|}
    case ${st%%|*} in
      ok)      printf ' %s✔%s %-8s sesión iniciada%s\n' "$C_LIVE" "$C_OFF" "$a" "${info:+ ($info)}"; any=1 ;;
      missing) printf ' %s○%s %-8s no instalado → %s\n' "$C_MUTED" "$C_OFF" "$a" "${st#*|}" ;;
      *)
        if [ "${st%%|*}" = no ]; then printf ' %s✖%s %-8s sin sesión\n' "$C_ERR" "$C_OFF" "$a"
        else printf ' %s?%s %-8s no se pudo comprobar la sesión\n' "$C_BRASS" "$C_OFF" "$a"; fi
        if (( ! check )); then
          _setup_ask "¿Iniciar sesión en $a ahora? (s/n)" s
          [[ "$REPLY" =~ ^[sSyY] ]] && { ( subcmd_login "$a" ) && any=1; }
        else printf '   → prama-agent login %s\n' "$a"; fi ;;
    esac
  done
  (( any )) || warn "Ningún agente listo: instala Claude Code o agy e inicia sesión (prama-agent login <agente>)."
  printf '   %sOtros proveedores (OpenRouter, DeepSeek, GLM, local): claves en %s/providers.env · prama-agent profiles%s\n' \
    "$C_MUTED" "$PRAMA_CONFIG_HOME" "$C_OFF"

  # 3 · Zones
  _setup_header "3 · Zonas (carpetas de trabajo con un nombre corto)"
  if (( ZONES_DISCOVERED )); then
    printf '   %sAún no registraste zonas: se usan los repositorios git de %s%s\n' "$C_MUTED" "$PRAMA_DISCOVER_ROOTS" "$C_OFF"
  fi
  _zones_list | sed 's/^/   /'
  if (( ! check )); then
    local -a cands=() roots=()
    read -ra roots <<< "$PRAMA_DISCOVER_ROOTS"
    mapfile -t cands < <(_zones_candidates "${roots[@]}")
    if (( ${#cands[@]} )); then
      local i
      printf '\n   Repositorios para registrar:\n'
      for i in "${!cands[@]}"; do printf '   %2d) %-18s %s\n' "$(( i + 1 ))" "$(_zone_suggest_name "${cands[i]}")" "${cands[i]}"; done
      _setup_ask "¿Cuáles registrar? (números separados por espacio, «todos» o vacío para ninguno)" ''
      local -a pick=()
      if [ "$REPLY" = todos ]; then for i in "${!cands[@]}"; do pick+=("$i"); done
      else for i in $REPLY; do [[ "$i" =~ ^[0-9]+$ ]] && (( i >= 1 && i <= ${#cands[@]} )) && pick+=("$(( i - 1 ))"); done; fi
      for i in ${pick[@]+"${pick[@]}"}; do
        _setup_ask "Nombre para ${cands[i]}" "$(_zone_suggest_name "${cands[i]}")"
        ( _zones_add "$REPLY" "${cands[i]}" ) || true
      done
    fi
    while :; do
      _setup_ask "¿Agregar otra carpeta? (ruta, o vacío para seguir)" ''
      [ -n "$REPLY" ] || break
      local dir=$REPLY
      _setup_ask "Nombre corto para $dir" "$(_zone_suggest_name "$dir")"
      ( _zones_add "$REPLY" "$dir" ) || true
    done
    printf '\n'; "$SELF_PATH" zones list | sed 's/^/   /'
  fi

  # 4 · Permissions
  _setup_header "4 · Permisos por defecto"
  if (( PRAMA_SKIP_PERMISSIONS )); then printf '   YOLO: los agentes actúan sin pedir confirmación.\n'
  else printf '   ASK: los agentes piden confirmación antes de cada acción (recomendado).\n'; fi
  if (( ! check )); then
    _setup_ask "Modo para los agentes nuevos: ask (confirma cada acción) o yolo (sin confirmar; solo servidores aislados)" \
      "$( (( PRAMA_SKIP_PERMISSIONS )) && echo yolo || echo ask)"
    case "$REPLY" in
      yolo) _config_set PRAMA_SKIP_PERMISSIONS 1; ok "YOLO por defecto (cámbialo con --ask por agente o en config.env)." ;;
      *)    _config_set PRAMA_SKIP_PERMISSIONS 0; ok "ASK por defecto." ;;
    esac
  fi

  # 5 · Optional
  _setup_header "5 · Opcional"
  printf '   Celular: Telegram (prama-agent telegram setup) y mosh (%s)\n' \
    "$(command -v mosh-server >/dev/null 2>&1 && echo 'instalado' || echo 'sudo apt install mosh')"
  printf '   Diagnóstico completo: prama-agent doctor\n'

  _setup_header "Listo. Próximos pasos"
  local z=${ZONES[0]:-<zona>}
  printf '   prama-agent                                     menú (n agente · s equipo)\n'
  printf '   prama-agent claude %-28s un agente\n' "$z"
  printf '   prama-agent swarm %s --team arquitectura --task "…"   un equipo\n\n' "$z"
}
