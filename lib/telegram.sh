#!/usr/bin/env bash
# lib/telegram.sh — Telegram bridge: pairing wizard, notifications and bot daemon lifecycle
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
#
# The bot itself lives in lib/telegram_bot.py (python3, stdlib only). python3 is required ONLY for
# the Telegram feature; notifications (telegram_notify) need just curl.
#
# Security (see docs/ARCHITECTURE.md):
#  * The token never goes on a command line: curl reads its URL from a config on stdin (-K -) and
#    the bot reads the config file itself.
#  * telegram.env is KEY=value data (0600, atomic writes), parsed with tg_conf_get — never sourced.
#  * Pairing requires a one-time code shown in the terminal (or an explicit --chat-id).
#
# Config keys: TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TELEGRAM_USER_ID TELEGRAM_BOT_USERNAME
#              TELEGRAM_PAIRED_USER

TG_SYSTEM_CONF="/etc/prama-agent/telegram.env"
TG_TOKEN_RE='^[0-9]+:[A-Za-z0-9_-]{20,}$'
TG_CHAT_RE='^-?[0-9]+$'
TG_PAIR_TIMEOUT="${PRAMA_TG_PAIR_TIMEOUT:-120}"

tg_session()   { printf '%s-telegram-bot' "$PRAMA_SESSION_PREFIX"; }
tg_user_conf() { printf '%s/telegram.env' "$PRAMA_CONFIG_HOME"; }
tg_log_file()  { printf '%s/telegram-bot.log' "$PRAMA_STATE_HOME"; }
tg_api_base()  { printf '%s' "${PRAMA_TG_API_BASE:-https://api.telegram.org}"; }

# Config file to read: the user's file if present, else the system-wide one if readable.
tg_conf_file() {
  local u
  u=$(tg_user_conf)
  if [ -f "$u" ]; then printf '%s' "$u"; return 0; fi
  if [ -f "$TG_SYSTEM_CONF" ] && [ -r "$TG_SYSTEM_CONF" ]; then printf '%s' "$TG_SYSTEM_CONF"; return 0; fi
  printf '%s' "$u"
  return 1
}

# tg_conf_get KEY [file] — prints the value of KEY (surrounding quotes stripped). Never evaluates.
tg_conf_get() {
  local want=$1 f=${2:-} line k v
  [ -n "$f" ] || f=$(tg_conf_file) || return 1
  [ -r "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" == *=* ]] || continue
    k=${line%%=*}; v=${line#*=}
    k=${k#export }
    k=${k//[[:space:]]/}
    [ "$k" = "$want" ] || continue
    if [[ "$v" =~ ^\"(.*)\"$ || "$v" =~ ^\'(.*)\'$ ]]; then v=${BASH_REMATCH[1]}; fi
    printf '%s' "$v"
    return 0
  done < "$f"
  return 1
}

# Loads the config into shell variables (not exported, so child processes never see the token).
tg_load() {
  TG_CONF_FILE=$(tg_conf_file) || true
  TG_TOKEN=$(tg_conf_get TELEGRAM_BOT_TOKEN "$TG_CONF_FILE" 2>/dev/null) || TG_TOKEN=''
  TG_CHAT_ID=$(tg_conf_get TELEGRAM_CHAT_ID "$TG_CONF_FILE" 2>/dev/null) || TG_CHAT_ID=''
  TG_USER_ID=$(tg_conf_get TELEGRAM_USER_ID "$TG_CONF_FILE" 2>/dev/null) || TG_USER_ID=''
  TG_BOT_USER=$(tg_conf_get TELEGRAM_BOT_USERNAME "$TG_CONF_FILE" 2>/dev/null) || TG_BOT_USER=''
  TG_PAIRED=$(tg_conf_get TELEGRAM_PAIRED_USER "$TG_CONF_FILE" 2>/dev/null) || TG_PAIRED=''
}

tg_configured() {
  tg_load
  [[ "$TG_TOKEN" =~ $TG_TOKEN_RE && "$TG_CHAT_ID" =~ $TG_CHAT_RE ]]
}

# tg_conf_write KEY=VALUE... — atomic, 0600, in a private 0700 directory.
tg_conf_write() {
  local f dir tmp kv
  f=$(tg_user_conf); dir=${f%/*}
  ensure_private_dir "$dir"
  tmp=$(umask 077 && mktemp "$dir/.telegram.env.XXXXXX") || { warn "No se pudo escribir en $dir"; return 1; }
  if ! {
    printf '# prama-agent · puente Telegram (privado, 0600). Formato KEY=valor; no se ejecuta.\n'
    for kv in "$@"; do
      kv=${kv//[$'\n\r']/}
      printf '%s\n' "$kv"
    done
  } > "$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$f"; then
    rm -f "$tmp"; warn "No se pudo guardar $f"; return 1
  fi
}

# ── HTTP (token only ever travels through stdin) ────────────────────────────
# tg_api <token> <method> [json_body] [timeout] → prints the response body
tg_api() {
  local token=$1 method=$2 body=${3:-} tmo=${4:-15} base esc
  base=$(tg_api_base)
  [[ "$token" =~ $TG_TOKEN_RE ]] || return 1
  [[ "$base" == *[\"\\[:space:]]* ]] && return 1
  esc=${body//\\/\\\\}
  esc=${esc//\"/\\\"}
  esc=${esc//$'\n'/\\n}
  {
    printf 'url = "%s/bot%s/%s"\n' "$base" "$token" "$method"
    printf 'header = "Content-Type: application/json"\n'
    [ -n "$body" ] && printf 'data-binary = "%s"\n' "$esc"
  } | curl -sS -m "$tmo" -K - 2>/dev/null
}

tg_have_json() { command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; }

# tg_json_get <path> — stdin JSON, path like .result.username (dotted keys / integer indexes).
tg_json_get() {
  if command -v jq >/dev/null 2>&1; then
    jq -r "($1) // empty | tostring" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
try:
    v = json.load(sys.stdin)
    for p in [p for p in sys.argv[1].split(".") if p]:
        v = v[int(p)] if isinstance(v, list) else v.get(p)
    if v is not None:
        print(v if isinstance(v, str) else json.dumps(v))
except Exception:
    pass' "$1"
  fi
}

# JSON body for sendMessage (no parse_mode → no markup errors possible).
tg_msg_json() {
  printf '{"chat_id":"%s","text":"%s","disable_web_page_preview":true}' \
    "$(json_escape "$1")" "$(json_escape "$2")"
}

# Sends a push notification to the paired chat. Non-blocking; silent no-op if not configured.
telegram_notify() {
  local text=${1:-}
  [ -n "$text" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  tg_configured || return 0
  local body
  body=$(tg_msg_json "$TG_CHAT_ID" "${text:0:4000}")
  ( tg_api "$TG_TOKEN" sendMessage "$body" 10 >/dev/null 2>&1 & ) 2>/dev/null
  return 0
}

# ── Pairing ─────────────────────────────────────────────────────────────────
tg_random_code() {
  local c=''
  while [ "${#c}" -lt 6 ]; do
    c+=$(LC_ALL=C tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789' < /dev/urandom 2>/dev/null | head -c 6)
  done
  printf '%s' "${c:0:6}"
}

# stdin: getUpdates JSON. Prints "maxid<TAB>chat_id<TAB>user_id<TAB>first_name<TAB>username"
# where the chat fields are filled only for a private message whose text is exactly the code
# (optionally preceded by /start).
tg_parse_pairing() {
  local code=$1
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg c "$code" '
      (.result // []) as $r
      | ([$r[].update_id] | max) as $m
      | ([$r[] | .message // empty
          | select((.chat.type // "") == "private")
          | select(((.text // "") | ascii_upcase | gsub("^\\s+|\\s+$"; "") | gsub("\\s+"; " "))
                   as $t | $t == $c or $t == ("/START " + $c))] | .[0]) as $h
      | [($m // ""), ($h.chat.id // ""), ($h.from.id // ""), ($h.from.first_name // ""), ($h.from.username // "")]
      | map(tostring | gsub("[\t\n\r]"; " ")) | @tsv' 2>/dev/null
  else
    python3 -c '
import json, sys
code = sys.argv[1]
try:
    r = json.load(sys.stdin).get("result") or []
except Exception:
    r = []
ids = [u.get("update_id") for u in r if isinstance(u.get("update_id"), int)]
hit = {}
for u in r:
    m = u.get("message") or {}
    t = " ".join((m.get("text") or "").upper().split())
    if (m.get("chat") or {}).get("type") == "private" and t in (code, "/START " + code):
        hit = m
        break
f = [max(ids) if ids else "", (hit.get("chat") or {}).get("id", ""), (hit.get("from") or {}).get("id", ""),
     (hit.get("from") or {}).get("first_name", ""), (hit.get("from") or {}).get("username", "")]
print("\t".join(" ".join(str(x).split()) for x in f))' "$code"
  fi
}

tg_read_line() {  # tg_read_line <prompt> <varname> — tui_prompt if available
  local __p=$1 __v=$2
  if declare -F tui_prompt >/dev/null 2>&1 && [ -t 0 ]; then
    tui_prompt "$__p" "$__v"
  else
    local __x=''
    IFS= read -e -r -p " $__p " __x || return 1
    printf -v "$__v" '%s' "$__x"
  fi
}

tg_confirm() {
  if declare -F tui_confirm >/dev/null 2>&1 && [ -t 0 ]; then
    tui_confirm "$1"
    return $?
  fi
  local a=''
  IFS= read -r -p " $1 [S/n] " a || return 1
  [[ -z "$a" || "$a" =~ ^[SsYy] ]]
}

# Waits for "/start CODE" from the phone. Sets PAIR_CHAT PAIR_USER PAIR_NAME PAIR_UNAME.
tg_wait_for_code() {
  local token=$1 code=$2 res line maxid chat uid fname uname offset=''
  PAIR_CHAT='' PAIR_USER='' PAIR_NAME='' PAIR_UNAME=''
  # Skip everything sent before the code was shown.
  res=$(tg_api "$token" getUpdates '{"offset":-1,"timeout":0}' 10) || true
  IFS=$'\t' read -r maxid _ <<< "$(tg_parse_pairing "$code" <<< "$res")"
  [[ "$maxid" =~ ^[0-9]+$ ]] && offset=$(( maxid + 1 ))
  local deadline=$(( SECONDS + TG_PAIR_TIMEOUT ))
  while (( SECONDS < deadline )); do
    res=$(tg_api "$token" getUpdates "{\"timeout\":5,\"allowed_updates\":[\"message\"]${offset:+,\"offset\":$offset}}" 15) || true
    line=$(tg_parse_pairing "$code" <<< "$res")
    IFS=$'\t' read -r maxid chat uid fname uname <<< "$line"
    [[ "$maxid" =~ ^[0-9]+$ ]] && offset=$(( maxid + 1 ))
    if [[ "$chat" =~ $TG_CHAT_RE ]]; then
      # acknowledge the update so the bot does not process the pairing message later
      tg_api "$token" getUpdates "{\"offset\":$offset,\"timeout\":0}" 10 >/dev/null || true
      PAIR_CHAT=$chat PAIR_USER=$uid PAIR_NAME=$fname PAIR_UNAME=$uname
      return 0
    fi
    printf '.'
  done
  return 1
}

# telegram_setup_wizard [--chat-id <id>]
telegram_setup_wizard() {
  local manual_chat=''
  while [ $# -gt 0 ]; do
    case $1 in
      --chat-id) manual_chat=${2:-}; shift 2 || shift ;;
      --chat-id=*) manual_chat=${1#*=}; shift ;;
      *) warn "Opción desconocida: $1"; return 1 ;;
    esac
  done
  if [ -n "$manual_chat" ] && ! [[ "$manual_chat" =~ $TG_CHAT_RE ]]; then
    warn "Chat ID inválido: debe ser numérico."
    return 1
  fi
  command -v curl >/dev/null 2>&1 || { warn "Se necesita curl para configurar Telegram."; return 1; }
  tg_have_json || { warn "Se necesita jq o python3 para configurar Telegram."; return 1; }

  (( IS_TTY )) && printf '\e[?25h'
  printf '\n'
  box_top "VINCULAR TELEGRAM CON PRAMA AGENT" "SETUP" "$C_NEON"
  box_row "$C_NEON" "Controla tus agentes desde el celular, 24/7."
  box_row "$C_NEON" "1. En Telegram abre ${C_BOLD}@BotFather${C_OFF} y envia ${C_LIVE}/newbot${C_OFF}."
  box_row "$C_NEON" "2. Copia el ${C_BRASS}token HTTP API${C_OFF} y pegalo aqui (no se muestra)."
  box_bottom "Vacio o 'q' para cancelar" "$C_NEON"

  tg_load
  local token='' old_token=$TG_TOKEN
  if [[ "$old_token" =~ $TG_TOKEN_RE ]]; then
    printf ' Token actual: ...%s (Enter para conservarlo)\n' "${old_token: -4}"
  fi
  printf ' Token de @BotFather: '
  IFS= read -r -s token || true
  printf '\n'
  token=${token//[[:space:]]/}
  [ -z "$token" ] && [[ "$old_token" =~ $TG_TOKEN_RE ]] && token=$old_token
  if [ -z "$token" ] || [ "$token" = q ] || [ "$token" = Q ]; then
    warn "Configuración de Telegram cancelada."
    return 1
  fi
  if ! [[ "$token" =~ $TG_TOKEN_RE ]]; then
    warn "Formato de token inválido (esperado: 123456789:ABC...)."
    return 1
  fi

  info_msg "Verificando token con Telegram..."
  local me bot_user
  me=$(tg_api "$token" getMe '' 10) || true
  bot_user=$(tg_json_get '.result.username' <<< "$me")
  if [ -z "$bot_user" ]; then
    warn "Token rechazado o sin respuesta de Telegram: $(tg_json_get '.description' <<< "$me")"
    return 1
  fi
  ok "Bot verificado: @$bot_user"

  # The running bot would steal getUpdates from the pairing loop.
  local was_running=0
  if tmx_has "$(tg_session)"; then
    was_running=1
    tmx_kill "$(tg_session)"
    info_msg "Bot detenido temporalmente durante la vinculación."
  fi

  local chat='' uid='' fname='' uname=''
  if [ -n "$manual_chat" ]; then
    chat=$manual_chat
    local info
    info=$(tg_api "$token" getChat "{\"chat_id\":\"$chat\"}" 10) || true
    fname=$(tg_json_get '.result.first_name' <<< "$info")
    [ -z "$fname" ] && fname=$(tg_json_get '.result.title' <<< "$info")
    uname=$(tg_json_get '.result.username' <<< "$info")
    if [ -z "$(tg_json_get '.result.id' <<< "$info")" ]; then
      warn "Telegram no reconoce el chat $chat (¿enviaste /start al bot?): $(tg_json_get '.description' <<< "$info")"
    fi
  else
    local code
    code=$(tg_random_code)
    printf '\n'
    box_top "PASO FINAL: CODIGO DE VINCULACION" "PAIRING" "$C_LIVE"
    box_row "$C_LIVE" "Desde tu celular abre ${C_BOLD}@${bot_user}${C_OFF} y envia:"
    box_row "$C_LIVE" ""
    box_row "$C_LIVE" "      ${C_BOLD}${C_BRASS}/start ${code}${C_OFF}"
    box_row "$C_LIVE" ""
    box_row "$C_LIVE" "o abre: https://t.me/${bot_user}?start=${code}"
    box_row "$C_LIVE" "Esperando ${TG_PAIR_TIMEOUT}s. Solo ese codigo vincula el chat."
    box_bottom "Ctrl-C para cancelar" "$C_LIVE"
    printf ' '
    if ! tg_wait_for_code "$token" "$code"; then
      printf '\n'
      warn "No llegó el código a tiempo. Reintenta o usa: prama-agent telegram setup --chat-id <id>"
      (( was_running )) && subcmd_telegram start >/dev/null 2>&1
      return 1
    fi
    printf '\n'
    chat=$PAIR_CHAT uid=$PAIR_USER fname=$PAIR_NAME uname=$PAIR_UNAME
  fi

  local who="${fname:-?}"
  [ -n "$uname" ] && who+=" (@$uname)"
  printf '\n'
  info_msg "Chat encontrado: ${C_BOLD}$who${C_OFF} · chat id $chat${uid:+ · usuario $uid}"
  if ! tg_confirm "¿Vincular este chat con prama-agent?"; then
    warn "Vinculación cancelada; no se guardó nada."
    (( was_running )) && subcmd_telegram start >/dev/null 2>&1
    return 1
  fi
  [ -z "$uid" ] && [[ "$chat" =~ ^[0-9]+$ ]] && uid=$chat   # private chat id == user id
  tg_conf_write "TELEGRAM_BOT_TOKEN=$token" "TELEGRAM_CHAT_ID=$chat" "TELEGRAM_USER_ID=$uid" \
    "TELEGRAM_BOT_USERNAME=$bot_user" "TELEGRAM_PAIRED_USER=${who//[^[:print:]]/}" || return 1
  ok "Telegram vinculado con $who (config: $(tg_user_conf))."
  telegram_notify "✅ Prama Agent v${VERSION:-?} vinculado en $(hostname -s 2>/dev/null || echo host). Escribe /menu para controlar tus agentes."
  if command -v python3 >/dev/null 2>&1; then
    subcmd_telegram restart
  else
    warn "python3 no está instalado: las notificaciones funcionan, pero el bot interactivo no."
  fi
}

# ── Daemon ──────────────────────────────────────────────────────────────────
tg_bot_script() {
  local d=${LIB_DIR:-}
  [ -n "$d" ] || d=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  printf '%s/telegram_bot.py' "$d"
}

# Runs the python bot in the foreground with a restart-on-crash loop. Used inside the tmux session.
run_telegram_bot_daemon() {
  local py=${PRAMA_TG_PYTHON:-python3}
  local delay=${PRAMA_TG_RESTART_DELAY:-5} max_rapid=${PRAMA_TG_MAX_CRASHES:-5}
  command -v "$py" >/dev/null 2>&1 || die "python3 no está instalado (requerido solo para el bot de Telegram)."
  tg_configured || die "Telegram no está configurado. Ejecuta: prama-agent telegram setup"
  local script
  script=$(tg_bot_script)
  [ -r "$script" ] || die "No se encuentra $script"
  ensure_private_dir "$PRAMA_STATE_HOME"
  local logf
  logf=$(tg_log_file)
  if [ -f "$logf" ] && [ "$(wc -c < "$logf")" -gt 1048576 ]; then mv -f "$logf" "$logf.1"; fi
  ( umask 077; : >> "$logf" )

  export PRAMA_TG_CONF="$TG_CONF_FILE" SELF_PATH PRAMA_TMUX_SOCKET PRAMA_BUS_DIR PRAMA_STATE_HOME \
    PRAMA_SESSION_PREFIX PRAMA_TG_LOG="$logf"
  unset TG_TOKEN
  local rapid=0 started rc
  while true; do
    started=$SECONDS
    "$py" -u "$script"
    rc=$?
    case $rc in
      0) printf '%s [daemon] bot detenido (rc=0)\n' "$(date '+%F %T')" | tee -a "$logf" >&2; return 0 ;;
      3) printf '%s [daemon] error de configuración (rc=3); no se reinicia\n' "$(date '+%F %T')" | tee -a "$logf" >&2; return 3 ;;
    esac
    if (( SECONDS - started < 60 )); then (( rapid++ )); else rapid=1; fi
    if (( rapid >= max_rapid )); then
      printf '%s [daemon] %d caídas seguidas; me rindo. Revisa: prama-agent telegram logs\n' "$(date '+%F %T')" "$rapid" | tee -a "$logf" >&2
      return 1
    fi
    printf '%s [daemon] bot caído (rc=%d); reinicio en %ss (%d/%d)\n' "$(date '+%F %T')" "$rc" "$delay" "$rapid" "$max_rapid" | tee -a "$logf" >&2
    sleep "$delay"
  done
}

tg_start() {
  local sess
  sess=$(tg_session)
  if ! tg_configured; then
    warn "Telegram no está configurado. Ejecuta: prama-agent telegram setup"
    return 1
  fi
  command -v python3 >/dev/null 2>&1 || { warn "python3 no está instalado (requerido solo para el bot de Telegram)."; return 1; }
  if tmx_has "$sess"; then
    ok "El bot de Telegram ya está activo ($sess)."
    return 0
  fi
  declare -F ensure_tmux_conf >/dev/null && ensure_tmux_conf
  # Non-secret environment is passed explicitly: an existing tmux server may have a different env.
  local envs=(env "PRAMA_TMUX_SOCKET=$PRAMA_TMUX_SOCKET" "PRAMA_STATE_HOME=$PRAMA_STATE_HOME"
              "PRAMA_BUS_DIR=$PRAMA_BUS_DIR" "PRAMA_TMUX_CONF=$PRAMA_TMUX_CONF"
              "PRAMA_SESSION_PREFIX=$PRAMA_SESSION_PREFIX")
  [ -n "${XDG_CONFIG_HOME:-}" ] && envs+=("XDG_CONFIG_HOME=$XDG_CONFIG_HOME")
  local v
  for v in PRAMA_TG_API_BASE PRAMA_TG_PYTHON PRAMA_TG_RESTART_DELAY PRAMA_TG_MAX_CRASHES; do
    [ -n "${!v:-}" ] && envs+=("$v=${!v}")
  done
  local cmd
  printf -v cmd '%q ' "${envs[@]}" "$SELF_PATH" telegram daemon
  if ! tmx new-session -d -s "$sess" "$cmd"; then
    warn "No se pudo crear la sesión tmux $sess."
    return 1
  fi
  sleep 1
  if tmx_has "$sess"; then
    ok "Bot de Telegram iniciado en la sesión '$sess' (@${TG_BOT_USER:-bot})."
  else
    warn "El bot terminó al arrancar. Revisa: prama-agent telegram logs"
    return 1
  fi
}

tg_stop() {
  local sess
  sess=$(tg_session)
  if tmx_has "$sess"; then
    tmx_kill "$sess"
    ok "Bot de Telegram detenido."
  else
    info_msg "El bot de Telegram no estaba activo."
  fi
}

tg_status() {
  tg_load
  local sess c=$C_BORDER_HI
  sess=$(tg_session)
  printf '\n'
  box_top "PUENTE TELEGRAM" "ESTADO" "$c"
  if tg_configured; then
    box_row "$c" "Bot:      ${C_LIVE}${C_BOLD}@${TG_BOT_USER:-?}${C_OFF}"
    box_row "$c" "Vinculado: ${TG_PAIRED:-?} · chat ${C_NEON}${TG_CHAT_ID}${C_OFF}"
    box_row "$c" "Config:   ${C_MUTED}${TG_CONF_FILE}${C_OFF}"
  else
    box_row "$c" "Estado:   ${C_BRASS}no configurado (prama-agent telegram setup)${C_OFF}"
  fi
  if tmx_has "$sess"; then
    box_row "$c" "Daemon:   ${C_LIVE}${C_BOLD}● ACTIVO${C_OFF} (sesión $sess)"
  else
    box_row "$c" "Daemon:   ${C_ERR}○ DETENIDO${C_OFF}"
  fi
  command -v python3 >/dev/null 2>&1 || box_row "$c" "${C_BRASS}python3 no instalado: el bot interactivo no puede correr${C_OFF}"
  box_row "$c" "Log:      ${C_MUTED}$(tg_log_file)${C_OFF}"
  box_bottom "En Telegram escribe /menu" "$c"
  printf '\n'
}

tg_test() {
  if ! tg_configured; then warn "Telegram no está configurado."; return 1; fi
  local me res
  me=$(tg_api "$TG_TOKEN" getMe '' 10) || true
  if [ -z "$(tg_json_get '.result.username' <<< "$me")" ]; then
    warn "getMe falló: $(tg_json_get '.description' <<< "$me")"
    return 1
  fi
  res=$(tg_api "$TG_TOKEN" sendMessage "$(tg_msg_json "$TG_CHAT_ID" "✦ Prueba desde Prama Agent ($(hostname -s 2>/dev/null)): conexión operativa.")" 10) || true
  if [ "$(tg_json_get '.ok' <<< "$res")" = true ]; then
    ok "Mensaje de prueba entregado (@$(tg_json_get '.result.username' <<< "$me") → chat $TG_CHAT_ID)."
  else
    warn "sendMessage falló: $(tg_json_get '.description' <<< "$res")"
    return 1
  fi
}

tg_usage() {
  cat <<EOF
Uso: prama-agent telegram <acción>
  setup [--chat-id <id>]  Vincular bot (código de un solo uso, o chat id manual)
  start | stop | restart  Controlar el bot 24/7 (sesión tmux $(tg_session))
  status                  Estado del puente
  logs [-f] [N]           Ver el log del bot
  test                    Enviar un mensaje de prueba (síncrono)
  notify <texto>          Enviar una notificación
  menu                    Menú interactivo
Requiere curl; el bot interactivo requiere además python3.
EOF
}

# ── TUI submenu ─────────────────────────────────────────────────────────────
tg_menu() {
  while true; do
    tg_load
    local running=0 configured=0 st="NO CONFIGURADO"
    tmx_has "$(tg_session)" && running=1
    tg_configured && configured=1
    if (( running )); then st="ACTIVO @${TG_BOT_USER:-bot}"
    elif (( configured )); then st="CONFIGURADO, DETENIDO"
    fi
    local TG_LABELS=("VOLVER" "VINCULAR BOT" "INICIAR BOT" "DETENER BOT" "REINICIAR BOT" "ENVIAR PRUEBA" "VER LOG" "ESTADO")
    local TG_METAS=(
      "Regresar al menu principal"
      "Token de @BotFather + codigo de vinculacion [$st]"
      "Arrancar el bot 24/7 en segundo plano"
      "Detener el bot"
      "Reiniciar el bot (recarga la configuracion)"
      "Enviar un mensaje de prueba ahora"
      "Ultimas lineas del log del bot"
      "Configuracion y estado del daemon"
    )
    local TG_AVAIL=(1 1 "$(( configured && !running ))" "$running" "$configured" "$configured" 1 1)
    local TG_TARGETS=("" "" "" "" "" "" "" "")
    local rc=0
    CHOICE=0
    tui_select_box "telegram" "CONTROL POR TELEGRAM ($st)" TG_LABELS TG_METAS TG_AVAIL TG_TARGETS || rc=$?
    (( rc == 3 )) && continue
    (( rc == 2 )) && return 0
    (( rc != 0 )) && return 0
    printf '\e[2J\e[H'
    case "${CHOICE:-0}" in
      0) return 0 ;;
      1) telegram_setup_wizard || true ;;
      2) tg_start || true ;;
      3) tg_stop || true ;;
      4) tg_stop >/dev/null; tg_start || true ;;
      5) tg_test || true ;;
      6) tail -n 40 "$(tg_log_file)" 2>/dev/null || info_msg "Sin log todavía." ;;
      7) tg_status ;;
    esac
    printf '\n Presiona cualquier tecla para continuar...'
    IFS= read -rsn1 _ || true
  done
}

subcmd_telegram() {
  local action=${1:-menu}
  shift || true
  case "$action" in
    setup|pair|config) telegram_setup_wizard "$@" ;;
    start)   tg_start ;;
    stop)    tg_stop ;;
    restart) tg_stop >/dev/null; tg_start ;;
    status)  tg_status ;;
    logs|log)
      local logf follow=0 n=60
      logf=$(tg_log_file)
      while [ $# -gt 0 ]; do
        case $1 in -f|--follow) follow=1 ;; *[!0-9]*) ;; *) n=$1 ;; esac
        shift
      done
      [ -f "$logf" ] || { info_msg "Sin log todavía ($logf)."; return 0; }
      if (( follow )); then tail -n "$n" -f "$logf"; else tail -n "$n" "$logf"; fi
      ;;
    notify)
      tg_configured || { warn "Telegram no está configurado."; return 1; }
      [ -n "${*:-}" ] || { warn "Uso: prama-agent telegram notify <texto>"; return 1; }
      telegram_notify "$*"
      ok "Notificación enviada."
      ;;
    test)    tg_test ;;
    daemon)  run_telegram_bot_daemon ;;
    menu)
      if [ -t 0 ] && declare -F tui_select_box >/dev/null; then tg_menu; else tg_status; fi
      ;;
    -h|--help|help) tg_usage ;;
    *) warn "Acción desconocida: $action"; tg_usage; return 1 ;;
  esac
}
