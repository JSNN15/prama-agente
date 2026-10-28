#!/usr/bin/env bash
# lib/telegram.sh — 24/7 Telegram Bot Bridge for Smartphone Control (Survives Termius/SSH drops)
# Licensed under the Apache License, Version 2.0

TELEGRAM_CONF_FILE="/etc/prama-agent/telegram.env"
[ ! -w "/etc/prama-agent" ] && [ ! -w "/etc" ] && TELEGRAM_CONF_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/prama-agent/telegram.env"
TELEGRAM_SESSION="${PRAMA_SESSION_PREFIX}-telegram-bot"

load_telegram_conf() {
  for _tf in "/etc/prama-agent/telegram.env" "${XDG_CONFIG_HOME:-$HOME/.config}/prama-agent/telegram.env"; do
    # shellcheck disable=SC1090
    [ -f "$_tf" ] && source "$_tf"
  done
}

# Sends a push notification to Telegram (non-blocking if configured)
telegram_notify() {
  local text=${1:-}
  load_telegram_conf
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ] || [ -z "$text" ]; then
    return 0
  fi
  curl -sS -m 6 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" >/dev/null 2>&1 &
}

# ── Guided 1-Minute Telegram Pairing Wizard ─────────────────────────────────
telegram_setup_wizard() {
  printf '\e[?25h\n'
  box_top "📱 VINCULAR TELEGRAM CON PRAMA AGENT (24/7)" "SETUP" "$C_NEON"
  box_row "$C_NEON" "Controla tus agentes desde el celular aunque Termius se cierre."
  box_row "$C_NEON" "1. Abre Telegram y busca a ${C_BOLD}@BotFather${C_OFF}"
  box_row "$C_NEON" "2. Envia ${C_LIVE}/newbot${C_OFF}, ponle un nombre y copia el ${C_BRASS}HTTP API Token${C_OFF}."
  box_bottom "Escribe 'q' o deja vacio para cancelar" "$C_NEON"
  printf '\n 🔑 Pega aquí el Token de @BotFather: '
  local token=''
  IFS= read -r token || true
  token="${token//[[:space:]]/}"
  if [ -z "$token" ] || [ "$token" = "q" ] || [ "$token" = "Q" ]; then
    warn "Configuración de Telegram cancelada."
    return 1
  fi

  info_msg "Verificando token con la API de Telegram..."
  local me_json bot_user
  me_json=$(curl -sS -m 10 "https://api.telegram.org/bot${token}/getMe" || true)
  bot_user=$(python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("result",{}).get("username",""))' <<< "$me_json" 2>/dev/null || true)

  if [ -z "$bot_user" ]; then
    warn "Token inválido o sin respuesta de Telegram. Verifica el token e intenta de nuevo."
    return 1
  fi

  ok "¡Bot verificado! Usuario: @$bot_user"
  printf '\n'
  box_top "📲 PASO FINAL: ENVIA UN MENSAJE DESDE TU CELULAR" "PAIRING" "$C_LIVE"
  box_row "$C_LIVE" "Abre Telegram en tu smartphone, entra a ${C_BOLD}@${bot_user}${C_OFF}"
  box_row "$C_LIVE" "y presiona ${C_BOLD}INICIAR (/start)${C_OFF} o envía cualquier mensaje (ej. 'hola')."
  box_row "$C_LIVE" "Esperando tu mensaje (máx 60 segundos)..."
  box_bottom "" "$C_LIVE"

  local chat_id='' chat_user='' attempt=0
  while (( attempt < 20 )); do
    (( attempt++ ))
    local upd_json
    upd_json=$(curl -sS -m 8 "https://api.telegram.org/bot${token}/getUpdates?timeout=3" || true)
    read -r chat_id chat_user < <(python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read() or "{}")
    res = d.get("result", [])
    if res:
        msg = res[-1].get("message") or res[-1].get("callback_query", {}).get("message") or {}
        chat = msg.get("chat", {})
        cid = str(chat.get("id", ""))
        uname = chat.get("username") or chat.get("first_name") or "operator"
        if cid:
            print(f"{cid} {uname}")
except Exception:
    pass
' <<< "$upd_json" 2>/dev/null || true)
    if [ -n "$chat_id" ]; then
      break
    fi
    printf '.'
  done
  printf '\n'

  if [ -z "$chat_id" ]; then
    printf ' No se detectó mensaje automático. ¿Conoces tu Chat ID numérico? (vacío para cancelar): '
    IFS= read -r chat_id || true
    chat_id="${chat_id//[[:space:]]/}"
    [ -z "$chat_id" ] && { warn "Vinculación cancelada."; return 1; }
    chat_user="manual"
  fi

  mkdir -p "$(dirname "$TELEGRAM_CONF_FILE")" 2>/dev/null || true
  cat <<EOF > "$TELEGRAM_CONF_FILE"
# Configuración privada del puente Telegram de Prama Agent
TELEGRAM_BOT_TOKEN="$token"
TELEGRAM_CHAT_ID="$chat_id"
TELEGRAM_BOT_USERNAME="$bot_user"
TELEGRAM_PAIRED_USER="$chat_user"
EOF
  chmod 600 "$TELEGRAM_CONF_FILE" 2>/dev/null || true

  ok "¡Telegram vinculado con éxito a @$chat_user (Chat ID: $chat_id)!"
  subcmd_telegram start
  telegram_notify "✅ Prama Agent v$VERSION conectado a tu smartphone (@$bot_user). Escribe /menu o usa los botones para controlar tus agentes aunque Termius se cierre."
}

# ── Python 3 Long-Polling Interactive Telegram Bot Daemon ───────────────────
run_telegram_bot_daemon() {
  load_telegram_conf
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || die "Telegram no está configurado. Ejecuta: prama-agent telegram setup"

  export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID SELF_PATH PRAMA_BUS_DIR
  export PRAMA_ZONES_CSV="${ZONES[*]}"

  exec python3 -u - <<'PYEOF'
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request

TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
ALLOWED_CHAT_ID = str(os.environ["TELEGRAM_CHAT_ID"]).strip()
SELF_PATH = os.environ.get("SELF_PATH", "/usr/local/bin/prama-agent")
ZONES = os.environ.get("PRAMA_ZONES_CSV", "backend").split()
API_BASE = f"https://api.telegram.org/bot{TOKEN}"

ACTIVE_TARGET_SESSION = ""

def api_call(method, payload=None, timeout=35):
    url = f"{API_BASE}/{method}"
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        sys.stderr.write(f"[telegram-bot] API {method} warn: {e}\n")
        return {}

def run_cmd(args):
    try:
        res = subprocess.run(args, capture_output=True, text=True, timeout=15)
        return (res.stdout or "") + (res.stderr or "")
    except Exception as e:
        return f"Error ejecutando comando: {e}"

def list_active_sessions():
    out = run_cmd(["tmux", "list-panes", "-a", "-F", "#{session_name}|#{pane_current_command}|#{pane_current_path}"])
    sessions = []
    for line in out.splitlines():
        if "|" not in line:
            continue
        s_name, cmd, path = line.split("|", 2)
        if s_name and "telegram-bot" not in s_name:
            sessions.append((s_name, cmd, path))
    return sessions

def capture_session_screen(s_name, lines=32):
    out = run_cmd(["tmux", "capture-pane", "-p", "-t", s_name, "-S", f"-{lines}"])
    cleaned = [l.rstrip() for l in out.splitlines() if l.strip() and "────────" not in l]
    text = "\n".join(cleaned[-28:])
    if not text.strip():
        text = "(Pantalla en espera / sin texto reciente)"
    if len(text) > 3500:
        text = text[-3500:]
    return text

def build_main_menu():
    global ACTIVE_TARGET_SESSION
    sessions = list_active_sessions()
    if sessions and (not ACTIVE_TARGET_SESSION or all(s[0] != ACTIVE_TARGET_SESSION for s in sessions)):
        ACTIVE_TARGET_SESSION = sessions[0][0]

    lines = ["✦ *PRAMA AGENT · CONTROL MOVIL 24/7*", ""]
    if sessions:
        lines.append(f"🟢 *Sesiones activas ({len(sessions)}):*")
        for s_name, cmd, path in sessions:
            marker = "💬 *(Chat activo)*" if s_name == ACTIVE_TARGET_SESSION else ""
            lines.append(f"• `{s_name}` ({cmd}) {marker}")
    else:
        lines.append("⚪ _No hay sesiones de agentes activas ahora mismo._")

    if ACTIVE_TARGET_SESSION:
        lines.append("")
        lines.append(f"✍️ *Tip:* Cualquier mensaje de texto que escribas aquí se enviará directo a `{ACTIVE_TARGET_SESSION}`.")

    kb = []
    for s_name, _cmd, _path in sessions:
        kb.append([
            {"text": f"👁 Ver {s_name}", "callback_data": f"peek:{s_name}"},
            {"text": f"💬 Hablar con {s_name}", "callback_data": f"select:{s_name}"},
        ])
        kb.append([
            {"text": f"🔄 Reiniciar {s_name}", "callback_data": f"restart:{s_name}"},
            {"text": f"🛑 Cerrar {s_name}", "callback_data": f"stop:{s_name}"},
        ])

    default_zone = ZONES[0] if ZONES else "backend"
    kb.append([
        {"text": f"➕ Claude ({default_zone})", "callback_data": f"launch:claude:{default_zone}:executor"},
        {"text": f"➕ Agy ({default_zone})", "callback_data": f"launch:agy:{default_zone}:executor"},
    ])
    kb.append([
        {"text": f"🤝 Lanzar Enjambre ({default_zone})", "callback_data": f"swarm:{default_zone}"},
        {"text": "📊 Refrescar Menú", "callback_data": "menu"},
    ])
    return "\n".join(lines), {"inline_keyboard": kb}

def send_menu(chat_id):
    text, reply_markup = build_main_menu()
    api_call("sendMessage", {
        "chat_id": chat_id,
        "text": text,
        "parse_mode": "Markdown",
        "reply_markup": reply_markup,
    })

def send_screen_snapshot(chat_id, s_name, prefix=""):
    snap = capture_session_screen(s_name, 30)
    header = f"📺 *Pantalla en vivo:* `{s_name}`\n"
    if prefix:
        header = f"{prefix}\n\n" + header
    kb = {"inline_keyboard": [
        [
            {"text": "🔄 Actualizar Pantalla", "callback_data": f"peek:{s_name}"},
            {"text": "⬅ Menú Principal", "callback_data": "menu"},
        ]
    ]}
    api_call("sendMessage", {
        "chat_id": chat_id,
        "text": f"{header}```\n{snap}\n```",
        "parse_mode": "Markdown",
        "reply_markup": kb,
    })

print(f"[prama-telegram-bot] Escuchando mensajes para Chat ID {ALLOWED_CHAT_ID}...")
offset = 0

while True:
    resp = api_call("getUpdates", {"offset": offset, "timeout": 25}, timeout=35)
    for upd in resp.get("result", []):
        offset = upd["update_id"] + 1

        # 1. Handle Inline Button Callbacks
        cb = upd.get("callback_query")
        if cb:
            cid = str(cb.get("message", {}).get("chat", {}).get("id", ""))
            if cid != ALLOWED_CHAT_ID:
                continue
            data = cb.get("data", "")
            api_call("answerCallbackQuery", {"callback_query_id": cb["id"]})

            if data == "menu":
                send_menu(cid)
            elif data.startswith("peek:"):
                s_target = data.split(":", 1)[1]
                send_screen_snapshot(cid, s_target)
            elif data.startswith("select:"):
                ACTIVE_TARGET_SESSION = data.split(":", 1)[1]
                send_screen_snapshot(cid, ACTIVE_TARGET_SESSION, f"💬 *Chat vinculado a:* `{ACTIVE_TARGET_SESSION}`\nEscribe cualquier instrucción abajo y se enviará al agente.")
            elif data.startswith("restart:"):
                s_target = data.split(":", 1)[1]
                run_cmd([SELF_PATH, "restart", s_target])
                time.sleep(1.5)
                send_screen_snapshot(cid, s_target, f"🔄 *Agente reiniciado en* `{s_target}`")
            elif data.startswith("stop:"):
                s_target = data.split(":", 1)[1]
                run_cmd([SELF_PATH, "stop", s_target])
                send_menu(cid)
            elif data.startswith("launch:"):
                _, ag, zn, rl = data.split(":", 3)
                run_cmd([SELF_PATH, ag, zn, "--role", rl, "--bg"])
                time.sleep(2.0)
                sessions = list_active_sessions()
                if sessions:
                    ACTIVE_TARGET_SESSION = sessions[-1][0]
                send_menu(cid)
            elif data.startswith("swarm:"):
                zn = data.split(":", 1)[1]
                run_cmd([SELF_PATH, "bus", "swarm-start", zn])
                time.sleep(2.0)
                send_menu(cid)
            continue

        # 2. Handle Text Messages & Commands
        msg = upd.get("message")
        if not msg:
            continue
        cid = str(msg.get("chat", {}).get("id", ""))
        if cid != ALLOWED_CHAT_ID:
            continue
        text = (msg.get("text") or "").strip()
        if not text:
            continue

        if text in ("/start", "/menu", "/status", "menu", "Menu"):
            send_menu(cid)
        elif text.startswith("/logs"):
            parts = text.split()
            target = parts[1] if len(parts) > 1 else ACTIVE_TARGET_SESSION
            if target:
                send_screen_snapshot(cid, target)
            else:
                send_menu(cid)
        elif text.startswith("/launch"):
            parts = text.split()
            ag = parts[1] if len(parts) > 1 else "claude"
            zn = parts[2] if len(parts) > 2 else (ZONES[0] if ZONES else "backend")
            rl = parts[3] if len(parts) > 3 else "executor"
            run_cmd([SELF_PATH, ag, zn, "--role", rl, "--bg"])
            time.sleep(2.0)
            send_menu(cid)
        else:
            # Direct message to the currently selected agent session!
            sessions = list_active_sessions()
            if not ACTIVE_TARGET_SESSION and sessions:
                ACTIVE_TARGET_SESSION = sessions[0][0]
            if not ACTIVE_TARGET_SESSION:
                api_call("sendMessage", {
                    "chat_id": cid,
                    "text": "⚠️ No hay ninguna sesión activa. Usa el menú para lanzar un agente primero.",
                })
                send_menu(cid)
                continue

            run_cmd([SELF_PATH, "send", ACTIVE_TARGET_SESSION, text])
            api_call("sendMessage", {
                "chat_id": cid,
                "text": f"📨 Enviado a `{ACTIVE_TARGET_SESSION}`. Capturando respuesta en 5s...",
                "parse_mode": "Markdown",
            })
            time.sleep(5.0)
            send_screen_snapshot(cid, ACTIVE_TARGET_SESSION)
PYEOF
}

subcmd_telegram() {
  local action=${1:-menu}
  shift || true
  load_telegram_conf

  case "$action" in
    setup|pair|config)
      telegram_setup_wizard
      ;;
    start)
      if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
        telegram_setup_wizard
        return $?
      fi
      if tmux has-session -t "$TELEGRAM_SESSION" 2>/dev/null; then
        ok "El Bot de Telegram 24/7 ya está activo en segundo plano ($TELEGRAM_SESSION)."
        return 0
      fi
      tmux new-session -d -s "$TELEGRAM_SESSION" "$SELF_PATH telegram daemon"
      ok "Bot de Telegram 24/7 iniciado en sesión persistente '$TELEGRAM_SESSION' (@${TELEGRAM_BOT_USERNAME:-bot})."
      ;;
    stop)
      if tmux has-session -t "$TELEGRAM_SESSION" 2>/dev/null; then
        tmux kill-session -t "$TELEGRAM_SESSION"
        ok "Bot de Telegram detenido."
      else
        warn "El Bot de Telegram no estaba activo."
      fi
      ;;
    status)
      printf '\n'
      box_top "📱 ESTADO DEL PUENTE TELEGRAM 24/7" "SMARTPHONE" "$C_BORDER_HI"
      if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        box_row "$C_BORDER_HI" "Bot vinculado: ${C_LIVE}${C_BOLD}@${TELEGRAM_BOT_USERNAME:-configurado}${C_OFF} · Chat ID: ${C_NEON}${TELEGRAM_CHAT_ID}${C_OFF}"
      else
        box_row "$C_BORDER_HI" "Estado: ${C_BRASS}No configurado aún (usa 'Configurar Token')${C_OFF}"
      fi
      if tmux has-session -t "$TELEGRAM_SESSION" 2>/dev/null; then
        box_row "$C_BORDER_HI" "Daemon 24/7:   ${C_LIVE}${C_BOLD}● ACTIVO EN SEGUNDO PLANO ($TELEGRAM_SESSION)${C_OFF}"
      else
        box_row "$C_BORDER_HI" "Daemon 24/7:   ${C_ERR}○ DETENIDO${C_OFF}"
      fi
      box_bottom "Abre tu bot en Telegram y escribe /menu" "$C_BORDER_HI"
      printf '\n'
      ;;
    notify)
      telegram_notify "${*:-}"
      ok "Notificación enviada a Telegram."
      ;;
    daemon)
      run_telegram_bot_daemon
      ;;
    menu|*)
      while true; do
        load_telegram_conf
        local tg_state="DESCONECTADO"
        if tmux has-session -t "$TELEGRAM_SESSION" 2>/dev/null; then
          tg_state="ACTIVO (@${TELEGRAM_BOT_USERNAME:-bot})"
        elif [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
          tg_state="CONFIGURADO (DETENIDO)"
        fi
        local TG_LABELS=(
          "◄ VOLVER AL MENU"
          "✦ VINCULAR BOT"
          "▸ INICIAR BOT 24/7"
          "☍ ENVIAR PRUEBA"
          "✖ DETENER BOT"
        )
        local TG_METAS=(
          "Regresar al menú principal de Prama Agent"
          "Configurar Token de @BotFather y vincular tu celular [$tg_state]"
          "Arrancar el daemon de Telegram en segundo plano"
          "Enviar un mensaje de prueba a tu Telegram ahora mismo"
          "Detener el daemon de Telegram"
        )
        local TG_AVAIL=(1 1 1 1 1)
        local TG_TARGETS=("" "" "" "" "")
        local rc=0
        tui_select_box "hub" "📱 CONTROL POR TELEGRAM ($tg_state)" TG_LABELS TG_METAS TG_AVAIL TG_TARGETS || rc=$?
        if (( rc == 2 )) || [ "${CHOICE:-0}" -eq 0 ]; then
          return 0
        fi
        case "$CHOICE" in
          1)
            printf '\e[2J\e[H'
            telegram_setup_wizard || true
            printf '\n Presiona cualquier tecla para continuar...'
            IFS= read -rsn1 _ || true
            ;;
          2)
            printf '\n'
            subcmd_telegram start || true
            sleep 1
            ;;
          3)
            telegram_notify "✦ Prueba desde Prama Agent ($(hostname -s)): Conexión móvil 24/7 operativa."
            printf '\n'
            ok "Mensaje de prueba enviado a tu Telegram."
            sleep 1
            ;;
          4)
            printf '\n'
            subcmd_telegram stop || true
            sleep 1
            ;;
        esac
      done
      ;;
  esac
}
