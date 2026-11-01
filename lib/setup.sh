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
# _zone_source <name> → zones.conf | config.env | descubierta (a stable value: zones --json "source")
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
      case $PRAMA_UI_LANG in es) _zones_help_es ;; *) _zones_help_en ;; esac ;;
    *) die "$(_t 'Usage: prama-agent zones [list|add|remove|scan|help]')" ;;
  esac
}

_zones_help_en() {
  cat <<'EOF'
Usage: prama-agent zones [list] [--json]                  zones (work folders) and where they come from
       prama-agent zones add <name> <dir> ["desc"]         register a folder under a short name
       prama-agent zones remove <name>                     drop a registered zone
       prama-agent zones scan [root…]                      git repositories not registered yet

With no registered zones, every git repository directly under PRAMA_DISCOVER_ROOTS is a zone.
Once you register the first one, the list is yours (zones.conf and config.env).
EOF
}

_zones_help_es() {
  cat <<'EOF'
Uso: prama-agent zones [list] [--json]                  zonas (carpetas de trabajo) y su origen
     prama-agent zones add <nombre> <carpeta> ["desc"]   registrar una carpeta con un nombre corto
     prama-agent zones remove <nombre>                    quitar una zona registrada
     prama-agent zones scan [raíz…]                       repositorios git aún sin registrar

Sin zonas registradas, cada repositorio git directamente bajo PRAMA_DISCOVER_ROOTS es una zona.
Al registrar la primera, la lista pasa a ser la tuya (zones.conf y config.env).
EOF
}

_zones_list() {
  local i src
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
    src=$(_zone_source "${ZONES[$i]}")
    [ "$src" = descubierta ] && _tv src 'discovered'
    printf '%-16s %-40s %s%s\n' "${ZONES[$i]}" "${ZONE_DIRS[$i]}" "$src" \
      "$([ -d "${ZONE_DIRS[$i]}" ] || _t ' · does not exist!')"
  done
}

_zones_add() {
  local name=${1:-} dir=${2:-} desc=${3:-} f i
  [ -n "$name" ] && [ -n "$dir" ] || die "$(_t 'Usage: prama-agent zones add <name> <dir> ["description"]')"
  valid_zone_name "$name" || die "$(_t "Invalid name '%s': lowercase letters, digits, - and _ (max. 24), e.g. backend" "$name")"
  [ -d "$dir" ] || die "$(_t "Folder '%s' does not exist." "$dir")"
  dir=$(cd "$dir" && pwd -P)
  desc=${desc//|/-}; desc=${desc//$'\n'/ }
  if (( ! ZONES_DISCOVERED )); then
    for i in "${!ZONES[@]}"; do
      [ "${ZONES[$i]}" = "$name" ] || continue
      [ "$(_zone_source "$name")" = zones.conf ] || die "$(_t "Zone '%s' is defined in config.env; edit it there." "$name")"
      _zones_remove "$name" >/dev/null
    done
  fi
  f=$(zones_file)
  ensure_private_dir "$PRAMA_CONFIG_HOME"
  ( umask 077; printf '%s|%s|%s\n' "$name" "$dir" "${desc:-$(basename "$dir")}" >> "$f" )
  [ -d "$dir/.git" ] || warn "$(_t "'%s' is not a git repository: it works, but without worktrees (-w)." "$dir")"
  ok "$(_t "Zone '%s' → %s" "$name" "$dir")"
  (( ZONES_DISCOVERED )) && info_msg "$(_t 'From now on the zones are the ones you register (before, they were discovered in: %s).' "$PRAMA_DISCOVER_ROOTS")"
  return 0
}

_zones_remove() {
  local name=${1:-} f tmp
  [ -n "$name" ] || die "$(_t 'Usage: prama-agent zones remove <name>')"
  f=$(zones_file)
  if [ ! -f "$f" ] || ! grep -q "^$name|" "$f"; then
    is_in "$name" "${ZONES[@]}" && (( ! ZONES_DISCOVERED )) \
      && die "$(_t "Zone '%s' is defined in config.env; remove it there." "$name")"
    die "$(_t "There is no registered zone '%s' (prama-agent zones)." "$name")"
  fi
  tmp="$f.tmp.$$"
  grep -v "^$name|" "$f" > "$tmp" || true
  mv -f "$tmp" "$f"
  ok "$(_t "Zone '%s' removed (the folder is not touched)." "$name")"
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
  if (( ! ${#found[@]} )); then info_msg "$(_t 'No new git repositories in: %s' "${roots[*]}")"; return 0; fi
  local d
  for d in "${found[@]}"; do printf '%-18s %s\n' "$(_zone_suggest_name "$d")" "$d"; done
  info_msg "$(_t 'Register one with: prama-agent zones add <name> <dir>')"
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
        printf 'ok|%s' "$(_t 'Google account')"
      else printf 'no|prama-agent login agy'
      fi ;;
    opencode) printf '?|%s' "$(_t 'opencode auth login (or OPENROUTER_API_KEY in providers.env)')" ;;
    *) printf '?|' ;;
  esac
}

_agent_install_hint() {
  case "$1" in
    claude)   printf 'curl -fsSL https://claude.ai/install.sh | bash' ;;
    agy)      _t 'install Antigravity CLI (agy) from its official documentation' ;;
    opencode) printf 'npm i -g @opencode/cli' ;;
    *)        _t 'install it and put it on the PATH' ;;
  esac
}

subcmd_login() {
  local a=${1:-} st info l_ok l_no l_miss l_unk
  if [ -z "$a" ]; then
    _tv l_ok 'signed in'; _tv l_no 'not signed in'; _tv l_miss 'not installed'; _tv l_unk 'could not check'
    for a in "${AGENTS[@]}"; do
      st=$(agent_auth_status "$a") info=${st#*|}
      case ${st%%|*} in
        ok)      printf ' %s✔%s %-9s %s%s\n' "$C_LIVE" "$C_OFF" "$a" "$l_ok" "${info:+ ($info)}" ;;
        no)      printf ' %s✖%s %-9s %s → %s\n' "$C_ERR" "$C_OFF" "$a" "$l_no" "${st#*|}" ;;
        missing) printf ' %s○%s %-9s %s → %s\n' "$C_MUTED" "$C_OFF" "$a" "$l_miss" "${st#*|}" ;;
        *)       printf ' %s?%s %-9s %s → %s\n' "$C_BRASS" "$C_OFF" "$a" "$l_unk" "${st#*|}" ;;
      esac
    done
    return 0
  fi
  is_in "$a" "${AGENTS[@]}" || die "$(_t "Agent not enabled: '%s' (%s)" "$a" "${AGENTS[*]}")"
  agent_installed "$a" || die "$(_t '%s is not installed: %s' "$a" "$(_agent_install_hint "$a")")"
  [ -t 0 ] || die "$(_t 'Signing in is interactive: run it in a terminal.')"
  case "$a" in
    claude)
      info_msg "$(_t 'Claude Code: the sign-in opens now (on a server, open the link in your browser and paste the code back).')"
      claude auth login || die "$(_t 'Claude Code sign-in was not completed.')" ;;
    agy)
      info_msg "$(_t 'Antigravity: agy opens; sign in with your Google account, then quit (Ctrl+C twice).')"
      agy || true ;;
    opencode)
      opencode auth login || die "$(_t 'OpenCode sign-in was not completed.')" ;;
  esac
  st=$(agent_auth_status "$a")
  if [ "${st%%|*}" = ok ]; then ok "$(_t '%s: signed in.' "$a")"; else warn "$(_t '%s: still not signed in (%s).' "$a" "${st#*|}")"; fi
}

# ── User defaults (scalar keys in ~/.config/prama-agent/config.env) ─────────
# _config_set KEY VALUE — replaces or appends one assignment; only known keys and plain values.
_config_set() {
  local key=$1 val=$2 f tmp
  [[ "$key" =~ ^(PRAMA_SKIP_PERMISSIONS|PRAMA_DEFAULT_REMOTE|PRAMA_SWARM_WORKERS|PRAMA_LANG|PRAMA_THEME|PRAMA_TUI_MOUSE)$ ]] || die "$(_t 'Unsupported key: %s' "$key")"
  [[ "$val" =~ ^[A-Za-z0-9:,._-]*$ ]] || die "$(_t "Unsupported value for %s: '%s'" "$key" "$val")"
  f="$PRAMA_CONFIG_HOME/config.env"
  ensure_private_dir "$PRAMA_CONFIG_HOME"
  [ -f "$f" ] || _t '# prama-agent — user configuration (bash). Reference: config/config.env.example\n' > "$f"
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

# _setup_lang_unset — true when no config file (nor the environment) chose the interface language.
_setup_lang_unset() {
  [[ ${PRAMA_LANG@a} == *x* ]] && return 1
  ! grep -qsE '^[[:space:]]*(export[[:space:]]+)?PRAMA_LANG=' "${CONFIG_FILES[@]}"
}

# _setup_lang — first step of the wizard: the interface language (both languages on screen).
_setup_lang() {
  local def=$PRAMA_UI_LANG code
  _setup_header "◆ PRAMA AGENT · Language / Idioma"
  printf '   en) English    es) Español\n'
  _setup_ask "Language / Idioma (en/es)" "$def"
  case ${REPLY,,} in
    en|english|inglés|ingles)          code=en ;;
    es|español|espanol|spanish|spa)    code=es ;;
    *)                                 code=$def ;;
  esac
  _config_set PRAMA_LANG "$code"
  PRAMA_LANG=$code; i18n_init
  ok "$(_t 'Interface language: %s' "$(lang_name "$PRAMA_UI_LANG")")"
}

subcmd_setup() {
  local check=0
  [ "${1:-}" = --check ] && check=1
  [ -t 0 ] || check=1
  (( check )) || ! _setup_lang_unset || _setup_lang
  printf '\n %s◆ PRAMA AGENT · %s%s  v%s\n' "$C_BOLD" "$(_t 'first steps')" "$C_OFF" "$VERSION"
  (( check )) && printf ' %s%s%s\n' "$C_MUTED" "$(_t '(check only: run "prama-agent setup" in a terminal to configure)')" "$C_OFF"

  # 1 · Dependencies
  _setup_header "$(_t '1 · Dependencies')"
  local dep missing=()
  for dep in tmux git jq; do
    if command -v "$dep" >/dev/null 2>&1; then printf ' %s✔%s %s\n' "$C_LIVE" "$C_OFF" "$dep"
    else printf ' %s✖%s %s\n' "$C_ERR" "$C_OFF" "$dep"; missing+=("$dep"); fi
  done
  (( ${#missing[@]} )) && warn "$(_t 'Install: sudo apt install %s  (jq: agent health and quota)' "${missing[*]}")"

  # 2 · Agents and their logins
  _setup_header "$(_t "2 · Agents and login (each CLI keeps its own credentials; prama never reads them)")"
  local a st info any=0
  for a in "${AGENTS[@]}"; do
    st=$(agent_auth_status "$a") info=${st#*|}
    case ${st%%|*} in
      ok)      printf ' %s✔%s %-8s %s%s\n' "$C_LIVE" "$C_OFF" "$a" "$(_t 'signed in')" "${info:+ ($info)}"; any=1 ;;
      missing) printf ' %s○%s %-8s %s → %s\n' "$C_MUTED" "$C_OFF" "$a" "$(_t 'not installed')" "${st#*|}" ;;
      *)
        if [ "${st%%|*}" = no ]; then printf ' %s✖%s %-8s %s\n' "$C_ERR" "$C_OFF" "$a" "$(_t 'not signed in')"
        else printf ' %s?%s %-8s %s\n' "$C_BRASS" "$C_OFF" "$a" "$(_t 'could not check the session')"; fi
        if (( ! check )); then
          _setup_ask "$(_t 'Sign in to %s now? (y/n)' "$a")" "$(_t 'y')"
          [[ "$REPLY" =~ ^[sSyY] ]] && { ( subcmd_login "$a" ) && any=1; }
        else printf '   → prama-agent login %s\n' "$a"; fi ;;
    esac
  done
  (( any )) || warn "$(_t 'No agent ready: install Claude Code or agy and sign in (prama-agent login <agent>).')"
  printf '   %s%s%s\n' "$C_MUTED" \
    "$(_t 'Other providers (OpenRouter, DeepSeek, GLM, local): keys in %s/providers.env · prama-agent profiles' "$PRAMA_CONFIG_HOME")" "$C_OFF"

  # 3 · Zones
  _setup_header "$(_t '3 · Zones (work folders under a short name)')"
  if (( ZONES_DISCOVERED )); then
    printf '   %s%s%s\n' "$C_MUTED" "$(_t 'No zones registered yet: using the git repositories in %s' "$PRAMA_DISCOVER_ROOTS")" "$C_OFF"
  fi
  _zones_list | sed 's/^/   /'
  if (( ! check )); then
    local -a cands=() roots=()
    read -ra roots <<< "$PRAMA_DISCOVER_ROOTS"
    mapfile -t cands < <(_zones_candidates "${roots[@]}")
    if (( ${#cands[@]} )); then
      local i
      printf '\n   %s\n' "$(_t 'Repositories to register:')"
      for i in "${!cands[@]}"; do printf '   %2d) %-18s %s\n' "$(( i + 1 ))" "$(_zone_suggest_name "${cands[i]}")" "${cands[i]}"; done
      _setup_ask "$(_t 'Which ones? (numbers separated by spaces, "all", or empty for none)')" ''
      local -a pick=()
      if [ "$REPLY" = all ] || [ "$REPLY" = todos ]; then for i in "${!cands[@]}"; do pick+=("$i"); done
      else for i in $REPLY; do [[ "$i" =~ ^[0-9]+$ ]] && (( i >= 1 && i <= ${#cands[@]} )) && pick+=("$(( i - 1 ))"); done; fi
      for i in ${pick[@]+"${pick[@]}"}; do
        _setup_ask "$(_t 'Name for %s' "${cands[i]}")" "$(_zone_suggest_name "${cands[i]}")"
        ( _zones_add "$REPLY" "${cands[i]}" ) || true
      done
    fi
    while :; do
      _setup_ask "$(_t 'Add another folder? (path, or empty to continue)')" ''
      [ -n "$REPLY" ] || break
      local dir=$REPLY
      _setup_ask "$(_t 'Short name for %s' "$dir")" "$(_zone_suggest_name "$dir")"
      ( _zones_add "$REPLY" "$dir" ) || true
    done
    printf '\n'; "$SELF_PATH" zones list | sed 's/^/   /'
  fi

  # 4 · Permissions
  _setup_header "$(_t '4 · Default permissions')"
  if (( PRAMA_SKIP_PERMISSIONS )); then printf '   %s\n' "$(_t 'YOLO: agents act without asking for confirmation.')"
  else printf '   %s\n' "$(_t 'ASK: agents ask for confirmation before each action (recommended).')"; fi
  if (( ! check )); then
    _setup_ask "$(_t 'Mode for new agents: ask (confirm each action) or yolo (no confirmation; isolated servers only)')" \
      "$( (( PRAMA_SKIP_PERMISSIONS )) && echo yolo || echo ask)"
    case "$REPLY" in
      yolo) _config_set PRAMA_SKIP_PERMISSIONS 1; ok "$(_t 'YOLO by default (override it per agent with --ask, or in config.env).')" ;;
      *)    _config_set PRAMA_SKIP_PERMISSIONS 0; ok "$(_t 'ASK by default.')" ;;
    esac
  fi

  # 5 · Optional
  _setup_header "$(_t '5 · Optional')"
  local lang_lbl
  lang_lbl=$(lang_name "$PRAMA_UI_LANG")
  [ "${PRAMA_LANG:-auto}" = auto ] && lang_lbl+=' (auto)'
  printf '   %s\n' "$(_t 'Language: %s (prama-agent lang)' "$lang_lbl")" "$(_t 'Theme: %s (prama-agent theme)' "$PRAMA_THEME")"
  printf '   %s\n' "$(_t 'Phone: Telegram (prama-agent telegram setup) and mosh (%s)' \
    "$(command -v mosh-server >/dev/null 2>&1 && _t 'installed' || echo 'sudo apt install mosh')")"
  printf '   %s\n' "$(_t 'Full diagnostics: prama-agent doctor')"

  _setup_header "$(_t 'Done. Next steps')"
  local z=${ZONES[0]:-$(_t '<zone>')}
  printf '   prama-agent                                     %s\n' "$(_t 'menu (n agent · s team)')"
  printf '   prama-agent claude %-28s %s\n' "$z" "$(_t 'one agent')"
  printf '   prama-agent swarm %s --team %s --task "…"   %s\n\n' "$z" "$(_t 'architecture')" "$(_t 'a team')"
}
