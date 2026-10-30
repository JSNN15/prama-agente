#!/usr/bin/env python3
# lib/telegram_bot.py — prama-agent Telegram bridge (long polling, stdlib only, Python >= 3.8)
# Licensed under the Apache License, Version 2.0
#
# Started by `prama-agent telegram daemon` (never directly by users). Security model:
#  * The bot token is read from the config file named by PRAMA_TG_CONF (KEY=value lines, never
#    executed). It never appears on any command line and is redacted from every log line.
#  * Only the paired chat (TELEGRAM_CHAT_ID) and, when known, the paired user (TELEGRAM_USER_ID)
#    are obeyed. Everything else is ignored silently.
#  * Every action goes through the prama CLI (SELF_PATH) with validated arguments: agents, zones
#    and sessions must exist in the CLI's own JSON listings; roles come from a fixed allowlist.
#  * All dynamic text is HTML-escaped; screen snapshots are sent inside <pre>.
#
# Environment: PRAMA_TG_CONF, SELF_PATH, PRAMA_TMUX_SOCKET, PRAMA_BUS_DIR (passed through to the
# CLI), PRAMA_TG_API_BASE (default https://api.telegram.org), PRAMA_TG_LOG (optional log file).
# Exit codes: 0 = clean stop, 3 = configuration problem (do not restart), other = crash.

import html
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import traceback
import urllib.error
import urllib.request

EXIT_CONFIG = 3
SESSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$")
ROLES = ("executor", "coordinator", "reader", "daemon")
ROLE_DESCS = {
    "executor": "Ejecuta tareas",
    "coordinator": "Planifica y reparte",
    "reader": "Solo lectura / revisión",
    "daemon": "Bucle autónomo",
}
CB_MAX = 64                # Telegram limit for callback_data, in bytes
CB_CACHE_MAX = 512
POLL_TIMEOUT = 25
MAX_MSG = 4096
SNAP_CHARS = 3300          # budget for the escaped <pre> block
SNAP_LINES = 45
BACKLOG_MAX_AGE = 300      # ignore text commands older than this (sent while the bot was down)
WATCH_INTERVAL = 2.0
WATCH_MAX = 12.0
MAX_LISTED = 25
HOST = socket.gethostname().split(".")[0]

TOKEN = ""
LOG_PATH = os.environ.get("PRAMA_TG_LOG", "")


# ── Logging ─────────────────────────────────────────────────────────────────
def log(msg):
    line = "%s [telegram-bot] %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    if TOKEN:
        line = line.replace(TOKEN, "***")
    try:
        sys.stderr.write(line + "\n")
        sys.stderr.flush()
    except OSError:
        pass
    if LOG_PATH:
        try:
            fd = os.open(LOG_PATH, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            with os.fdopen(fd, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            pass


def e(s):
    """HTML-escape any dynamic value for parse_mode=HTML."""
    return html.escape(str(s), quote=False)


def strip_html(s):
    return html.unescape(re.sub(r"<[^>]+>", "", s))


# ── Config (same KEY=value format the bash side writes; never executed) ─────
def parse_conf(path):
    out = {}
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip()
            if k.startswith("export "):
                k = k[7:].strip()
            if not re.match(r"^[A-Z_][A-Z0-9_]*$", k):
                continue
            v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            out[k] = v
    return out


def conf_candidates():
    env = os.environ.get("PRAMA_TG_CONF")
    if env:
        return [env]
    xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return [os.path.join(xdg, "prama-agent", "telegram.env"), "/etc/prama-agent/telegram.env"]


def load_conf():
    for path in conf_candidates():
        if os.path.isfile(path) and os.access(path, os.R_OK):
            return path, parse_conf(path)
    return None, {}


# ── Telegram API ────────────────────────────────────────────────────────────
class NetError(Exception):
    pass


class Api:
    def __init__(self, token, base):
        self._url = "%s/bot%s/" % (base.rstrip("/"), token)

    def call(self, method, payload=None, timeout=20):
        data = json.dumps(payload or {}).encode("utf-8")
        req = urllib.request.Request(self._url + method, data=data,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read()
        except urllib.error.HTTPError as ex:   # Telegram answers 4xx with a JSON body
            try:
                body = ex.read() or b""
                return json.loads(body.decode("utf-8", "replace"))
            except (ValueError, OSError):
                return {"ok": False, "error_code": ex.code, "description": "HTTP %s" % ex.code}
        except (urllib.error.URLError, OSError, ValueError) as ex:
            raise NetError("%s: %s" % (method, getattr(ex, "reason", ex)))
        try:
            return json.loads(body.decode("utf-8", "replace"))
        except ValueError:
            return {"ok": False, "description": "respuesta no JSON"}


# ── prama CLI wrapper ───────────────────────────────────────────────────────
class CliError(Exception):
    pass


class Prama:
    def __init__(self, self_path):
        self.path = self_path
        self._cache = {}

    def run(self, args, timeout=30):
        try:
            res = subprocess.run([self.path] + list(args), stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 timeout=timeout)
        except subprocess.TimeoutExpired:
            raise CliError("tiempo de espera agotado (%ss)" % timeout)
        except OSError as ex:
            raise CliError("no se pudo ejecutar prama-agent: %s" % ex)
        out = res.stdout.decode("utf-8", "replace")
        err = res.stderr.decode("utf-8", "replace")
        return res.returncode, out, err

    def ok(self, args, timeout=30):
        rc, out, err = self.run(args, timeout)
        if rc != 0:
            msg = clean_err(err) or clean_err(out) or ("código de salida %d" % rc)
            raise CliError(msg)
        return out

    def json(self, args, ttl=0):
        key = tuple(args)
        hit = self._cache.get(key)
        if ttl and hit and time.time() - hit[0] < ttl:
            return hit[1]
        out = self.ok(args, timeout=20)
        try:
            data = json.loads(out)
        except ValueError:
            raise CliError("salida JSON inválida de: prama-agent %s" % " ".join(args))
        if not isinstance(data, list):
            raise CliError("se esperaba una lista JSON de: prama-agent %s" % " ".join(args))
        self._cache[key] = (time.time(), data)
        return data

    def sessions(self):
        res = []
        for d in self.json(["sessions", "--json"]):
            if isinstance(d, dict) and isinstance(d.get("name"), str) and not d.get("internal"):
                res.append(d)
        return res

    def agents(self):
        return [d["name"] for d in self.json(["agents", "--json"], ttl=60)
                if isinstance(d, dict) and isinstance(d.get("name"), str) and d.get("installed", True)]

    def zones(self):
        return [d["name"] for d in self.json(["zones", "--json"], ttl=60)
                if isinstance(d, dict) and isinstance(d.get("name"), str) and d["name"]]

    def capture(self, name, lines=SNAP_LINES):
        return self.ok(["capture", name, str(lines)], timeout=15)


ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07")


def clean_err(s):
    s = ANSI_RE.sub("", s or "").strip()
    return s[-500:]


def clean_screen(raw):
    raw = ANSI_RE.sub("", raw).replace("\r", "").replace(" ", " ")
    lines = [l.rstrip() for l in raw.split("\n")]
    out = []
    for l in lines:
        if not l and out and not out[-1]:
            continue                       # collapse blank runs
        out.append(l)
    while out and not out[0]:
        out.pop(0)
    while out and not out[-1]:
        out.pop()
    return out


def fit_pre(lines):
    """Keeps the newest lines whose escaped size fits SNAP_CHARS."""
    kept, size = [], 0
    for l in reversed(lines):
        el = e(l)
        if size + len(el) + 1 > SNAP_CHARS:
            break
        kept.append(el)
        size += len(el) + 1
    kept.reverse()
    return "\n".join(kept) if kept else "(pantalla vacía)"


def dot(s):
    st = str(s.get("state", "")).upper()
    if st in ("WORKING",):
        return "🟢"
    if st in ("BLOCKED",):
        return "🔴"
    if st in ("READY", "DAEMON", "SHELL"):
        return "●"
    return "○"


def btn(text, data):
    return {"text": text, "callback_data": data}


# ── Bot ─────────────────────────────────────────────────────────────────────
class Bot:
    def __init__(self, api, prama, chat_id, user_id):
        self.api = api
        self.prama = prama
        self.chat_id = str(chat_id)
        self.user_id = str(user_id or "")
        self.selected = ""
        self.cb_cache = {}
        self.cb_next = 0
        self.lock = threading.Lock()
        self.unauth_seen = {}

    # ── helpers ──
    def cb(self, data):
        """callback_data must be <= 64 bytes; long payloads become an index into a cache."""
        if len(data.encode("utf-8")) <= CB_MAX:
            return data
        with self.lock:
            idx = self.cb_next
            self.cb_next += 1
            self.cb_cache[idx] = data
            while len(self.cb_cache) > CB_CACHE_MAX:
                del self.cb_cache[min(self.cb_cache)]
        return "#%d" % idx

    def b(self, text, data):
        return btn(text, self.cb(data))

    def send(self, text, kb=None, edit_id=None):
        """Sends (or edits in place) an HTML message. Falls back to plain text once on error."""
        if len(text) > MAX_MSG:
            text = text[:MAX_MSG - 20] + "…"
        payload = {"chat_id": self.chat_id, "text": text, "parse_mode": "HTML",
                   "disable_web_page_preview": True}
        if kb is not None:
            payload["reply_markup"] = {"inline_keyboard": kb}
        method = "sendMessage"
        if edit_id:
            method = "editMessageText"
            payload["message_id"] = edit_id
        res = self.api.call(method, payload)
        if res.get("ok"):
            r = res.get("result")
            return r.get("message_id", edit_id) if isinstance(r, dict) else edit_id
        desc = str(res.get("description", ""))
        if "message is not modified" in desc:
            return edit_id
        log("%s falló: %s" % (method, desc))
        if edit_id and ("not found" in desc or "can't be edited" in desc):
            return self.send(text, kb)
        payload.pop("parse_mode", None)
        payload["text"] = strip_html(text)[:MAX_MSG]
        res = self.api.call(method, payload)
        if res.get("ok"):
            r = res.get("result")
            return r.get("message_id", edit_id) if isinstance(r, dict) else edit_id
        log("%s (texto plano) falló: %s" % (method, res.get("description", "")))
        return None

    def authorized(self, chat_id, user_id):
        if str(chat_id) != self.chat_id:
            return False
        return not self.user_id or str(user_id) == self.user_id

    def note_unauthorized(self, chat_id, user_id):
        now = time.time()
        key = "%s/%s" % (chat_id, user_id)
        if now - self.unauth_seen.get(key, 0) > 600:
            self.unauth_seen[key] = now
            log("ignorado: chat %s / usuario %s no autorizado" % (chat_id, user_id))

    def find_session(self, name):
        """Returns the session dict if name is valid AND currently exists, else None."""
        if not isinstance(name, str) or not SESSION_RE.match(name):
            return None
        for s in self.prama.sessions():
            if s.get("name") == name:
                return s
        return None

    # ── views ──
    def view_menu(self, detail=False):
        ss = self.prama.sessions()
        names = [s["name"] for s in ss]
        if self.selected not in names:
            self.selected = ""
        controllable = [s for s in ss if SESSION_RE.match(s["name"])]
        if not self.selected and len(controllable) == 1:
            self.selected = controllable[0]["name"]
        lines = ["<b>✦ PRAMA AGENT · Control móvil</b>",
                 "🖥 <code>%s</code> · %s" % (e(HOST), time.strftime("%H:%M:%S")), ""]
        if ss:
            lines.append("<b>Sesiones (%d)</b>" % len(ss))
            for s in ss[:MAX_LISTED]:
                mark = "  ✍️" if s["name"] == self.selected else ""
                lines.append("%s <code>%s</code>%s" % (dot(s), e(s["name"]), mark))
                meta = "%s · %s · %s" % (s.get("role", "?"), s.get("agent", "?"),
                                         str(s.get("state", "?")).lower())
                if detail:
                    meta += " · CPU %s · %s" % (s.get("cpu", "?"), s.get("mem", "?"))
                lines.append("    <i>%s</i>" % e(meta))
            if len(ss) > MAX_LISTED:
                lines.append("<i>… y %d más</i>" % (len(ss) - MAX_LISTED))
        else:
            lines.append("<i>No hay agentes activos.</i>")
        lines.append("")
        if self.selected:
            lines.append("✍️ Lo que escribas irá a <b>%s</b>." % e(self.selected))
        else:
            lines.append("Toca una sesión o lanza un agente nuevo.")
        kb = []
        for s in controllable[:MAX_LISTED]:
            kb.append([self.b("%s %s · %s" % (dot(s), s["name"], s.get("role", "?")),
                              "s:" + s["name"])])
        kb.append([self.b("➕ Nuevo agente", "n"), self.b("🤝 Enjambre", "w")])
        kb.append([self.b("🔄 Refrescar", "m"), self.b("❓ Ayuda", "h")])
        return "\n".join(lines), kb

    def view_session(self, s, note=""):
        name = s["name"]
        lines = []
        if note:
            lines += [note, ""]
        lines += [
            "%s <b>%s</b>%s" % (dot(s), e(name), "  ✍️" if name == self.selected else ""),
            "Rol: <b>%s</b> · Agente: <b>%s</b>" % (e(s.get("role", "?")), e(s.get("agent", "?"))),
            "Estado: <b>%s</b> · Zona: <b>%s</b>" % (e(str(s.get("state", "?")).lower()),
                                                   e(s.get("zone", "?"))),
            "CPU %s · RAM %s" % (e(s.get("cpu", "?")), e(s.get("mem", "?"))),
        ]
        if s.get("dir"):
            lines.append("📁 <code>%s</code>" % e(s["dir"]))
        kb = [
            [self.b("👁 Ver pantalla", "p:" + name), self.b("💬 Hablar", "t:" + name)],
            [self.b("🔄 Reiniciar", "r:" + name), self.b("🛑 Cerrar", "x:" + name)],
            [self.b("⬅ Volver", "m")],
        ]
        return "\n".join(lines), kb

    def snapshot_html(self, name, raw, header=""):
        body = fit_pre(clean_screen(raw))
        top = (header + "\n") if header else ""
        return "%s📺 <b>%s</b> · %s\n<pre>%s</pre>" % (top, e(name), time.strftime("%H:%M:%S"), body)

    def snapshot_kb(self, name):
        return [[self.b("🔄 Actualizar", "p:" + name), self.b("💬 Hablar", "t:" + name)],
                [self.b("⬅ Volver", "s:" + name), self.b("☰ Menú", "m")]]

    def view_help(self):
        text = "\n".join([
            "<b>❓ Ayuda · Prama Agent</b>", "",
            "/menu — menú principal",
            "/status — sesiones con CPU/RAM",
            "/logs [sesión] — ver pantalla",
            "/send &lt;sesión&gt; &lt;texto&gt; — escribir a una sesión",
            "/launch &lt;agente&gt; &lt;zona&gt; [rol] — lanzar agente",
            "/help — esta ayuda", "",
            "Texto normal → se envía a la sesión seleccionada (✍️).",
            "Roles: " + ", ".join(ROLES),
        ])
        return text, [[self.b("⬅ Volver", "m")]]

    def view_error(self, msg, back="m"):
        return "⚠️ %s" % e(msg), [[self.b("⬅ Volver", back)]]

    # ── actions ──
    def do_launch(self, agent, zone, role, edit_id=None):
        if agent not in self.prama.agents():
            return self.send(*self.view_error("Agente no permitido o no instalado: %s" % agent),
                             edit_id=edit_id)
        if zone not in self.prama.zones():
            return self.send(*self.view_error("Zona desconocida: %s" % zone), edit_id=edit_id)
        if role not in ROLES:
            return self.send(*self.view_error("Rol inválido: %s (usa %s)" % (role, ", ".join(ROLES))),
                             edit_id=edit_id)
        mid = self.send("⏳ Lanzando <b>%s</b> en <b>%s</b> (%s)…" % (e(agent), e(zone), e(role)),
                        edit_id=edit_id)
        try:
            out = self.prama.ok([agent, zone, "--role", role, "--bg", "--porcelain"], timeout=90)
        except CliError as ex:
            return self.send(*self.view_error("No se pudo lanzar: %s" % ex), edit_id=mid)
        name = out.strip().splitlines()[-1].strip() if out.strip() else ""
        s = self.find_session(name)
        if not s:
            return self.send(*self.view_error("Lanzado, pero la sesión «%s» no aparece." % name),
                             edit_id=mid)
        self.selected = name
        return self.send(*self.view_session(s, "✅ Agente lanzado. Ahora escribes a esta sesión."),
                         edit_id=mid)

    def deliver_text(self, name, text, edit_id=None):
        s = self.find_session(name)
        if not s:
            return self.send(*self.view_error("Sesión no encontrada: %s" % name), edit_id=edit_id)
        text = text.replace("\r", "").replace("\n", " ").strip()
        if not text:
            return None
        try:
            before = self.prama.capture(name)
        except CliError:
            before = ""
        try:
            self.prama.ok(["send", name, text], timeout=20)
        except CliError as ex:
            return self.send(*self.view_error("No se pudo enviar a %s: %s" % (name, ex)))
        mid = self.send("📨 Enviado a <b>%s</b>. Esperando respuesta…" % e(name))
        if mid:
            t = threading.Thread(target=self._watch, args=(name, mid, before), daemon=True)
            t.start()
        return mid

    def _watch(self, name, mid, before):
        """Polls the screen until it stops changing (or WATCH_MAX), then edits the snapshot in."""
        try:
            t0, last, snap = time.time(), None, before
            while time.time() - t0 < WATCH_MAX:
                time.sleep(WATCH_INTERVAL)
                try:
                    cur = self.prama.capture(name)
                except CliError:
                    break
                snap = cur
                if cur == last and cur != before:
                    break
                last = cur
            self.send(self.snapshot_html(name, snap, "📨 Respuesta de <b>%s</b>:" % e(name)),
                      self.snapshot_kb(name), edit_id=mid)
        except Exception as ex:  # never let a watcher thread die noisily
            log("watch %s: %r" % (name, ex))

    def show_snapshot(self, name, edit_id=None):
        if not self.find_session(name):
            return self.send(*self.view_error("Sesión no encontrada: %s" % name), edit_id=edit_id)
        raw = self.prama.capture(name)
        return self.send(self.snapshot_html(name, raw), self.snapshot_kb(name), edit_id=edit_id)

    # ── callbacks ──
    def on_callback(self, data, mid):
        if data.startswith("#"):
            try:
                data = self.cb_cache[int(data[1:])]
            except (ValueError, KeyError):
                return self.send(*self.view_menu(), edit_id=mid)
        act, _, arg = data.partition(":")
        if act == "m":
            return self.send(*self.view_menu(), edit_id=mid)
        if act == "h":
            return self.send(*self.view_help(), edit_id=mid)
        if act in ("s", "p", "t", "r", "x", "R", "X"):
            s = self.find_session(arg)
            if not s:
                return self.send(*self.view_error("La sesión «%s» ya no existe." % arg), edit_id=mid)
            name = s["name"]
            if act == "s":
                return self.send(*self.view_session(s), edit_id=mid)
            if act == "p":
                return self.show_snapshot(name, edit_id=mid)
            if act == "t":
                self.selected = name
                return self.send(*self.view_session(
                    s, "💬 Chat vinculado a <b>%s</b>. Escribe tu mensaje." % e(name)), edit_id=mid)
            if act in ("r", "x"):
                verb = "reiniciar" if act == "r" else "cerrar"
                return self.send("⚠️ ¿Seguro que quieres <b>%s</b> la sesión <b>%s</b>?" % (verb, e(name)),
                                 [[self.b("✅ Sí, %s" % verb, act.upper() + ":" + name),
                                   self.b("✖ No", "s:" + name)]], edit_id=mid)
            if act == "R":
                self.send("⏳ Reiniciando <b>%s</b>…" % e(name), edit_id=mid)
                try:
                    self.prama.ok(["restart", name], timeout=60)
                except CliError as ex:
                    return self.send(*self.view_error("Reinicio fallido: %s" % ex, "s:" + name), edit_id=mid)
                time.sleep(1.5)
                s2 = self.find_session(name) or s
                return self.send(*self.view_session(s2, "🔄 Sesión reiniciada."), edit_id=mid)
            if act == "X":
                try:
                    self.prama.ok(["stop", name], timeout=60)
                except CliError as ex:
                    return self.send(*self.view_error("No se pudo cerrar: %s" % ex, "s:" + name), edit_id=mid)
                if self.selected == name:
                    self.selected = ""
                text, kb = self.view_menu()
                return self.send("🛑 Sesión <b>%s</b> cerrada.\n\n%s" % (e(name), text), kb, edit_id=mid)
        if act == "n":                      # new agent: choose agent
            agents = self.prama.agents()
            if not agents:
                return self.send(*self.view_error("No hay agentes instalados."), edit_id=mid)
            kb = [[self.b(a, "na:" + a)] for a in agents] + [[self.b("⬅ Volver", "m")]]
            return self.send("<b>➕ Nuevo agente · 1/3</b>\nElige el agente:", kb, edit_id=mid)
        if act == "na":                     # choose zone
            if arg not in self.prama.agents():
                return self.send(*self.view_error("Agente no permitido: %s" % arg, "n"), edit_id=mid)
            kb = [[self.b(z, "nz:%s:%s" % (arg, z))] for z in self.prama.zones()]
            kb.append([self.b("⬅ Volver", "n")])
            return self.send("<b>➕ Nuevo agente · 2/3</b>\nAgente: <b>%s</b>\nElige la zona:" % e(arg),
                             kb, edit_id=mid)
        if act == "nz":                     # choose role
            agent, _, zone = arg.partition(":")
            if agent not in self.prama.agents() or zone not in self.prama.zones():
                return self.send(*self.view_error("Selección inválida.", "n"), edit_id=mid)
            kb = [[self.b("%s · %s" % (r, ROLE_DESCS[r]), "nl:%s:%s:%s" % (agent, r, zone))] for r in ROLES]
            kb.append([self.b("⬅ Volver", "na:" + agent)])
            return self.send("<b>➕ Nuevo agente · 3/3</b>\nAgente: <b>%s</b> · Zona: <b>%s</b>\nElige el rol:"
                             % (e(agent), e(zone)), kb, edit_id=mid)
        if act == "nl":                     # launch
            parts = arg.split(":", 2)
            if len(parts) != 3:
                return self.send(*self.view_error("Selección inválida.", "n"), edit_id=mid)
            agent, role, zone = parts
            return self.do_launch(agent, zone, role, edit_id=mid)
        if act == "w":                      # swarm: choose zone
            kb = [[self.b(z, "wz:" + z)] for z in self.prama.zones()] + [[self.b("⬅ Volver", "m")]]
            return self.send("<b>🤝 Enjambre</b>\nCoordinador + Ejecutor. Elige la zona:", kb, edit_id=mid)
        if act == "wz":
            if arg not in self.prama.zones():
                return self.send(*self.view_error("Zona desconocida: %s" % arg), edit_id=mid)
            self.send("⏳ Iniciando enjambre en <b>%s</b>…" % e(arg), edit_id=mid)
            try:
                self.prama.ok(["bus", "swarm-start", arg], timeout=120)
            except CliError as ex:
                return self.send(*self.view_error("Enjambre fallido: %s" % ex), edit_id=mid)
            text, kb = self.view_menu()
            return self.send("🤝 Enjambre iniciado en <b>%s</b>.\n\n%s" % (e(arg), text), kb, edit_id=mid)
        return self.send(*self.view_menu(), edit_id=mid)

    # ── text & commands ──
    def on_text(self, text):
        text = text.strip()
        if not text:
            return None
        if text.startswith("/"):
            head, _, rest = text.partition(" ")
            cmd = head[1:].split("@", 1)[0].lower()
            rest = rest.strip()
            if cmd in ("start", "menu"):
                return self.send(*self.view_menu())
            if cmd == "status":
                return self.send(*self.view_menu(detail=True))
            if cmd == "help":
                return self.send(*self.view_help())
            if cmd == "logs":
                name = rest.split()[0] if rest else self.selected
                if not name:
                    return self.send(*self.view_error("Indica la sesión: /logs &lt;sesión&gt;"))
                return self.show_snapshot(name)
            if cmd == "send":
                name, _, msg = rest.partition(" ")
                if not name or not msg.strip():
                    return self.send(*self.view_error("Uso: /send <sesión> <texto>"))
                return self.deliver_text(name, msg)
            if cmd == "launch":
                args = rest.split()
                if len(args) not in (2, 3):
                    return self.send(*self.view_error("Uso: /launch <agente> <zona> [rol]"))
                role = args[2] if len(args) == 3 else "executor"
                return self.do_launch(args[0], args[1], role)
            return self.send(*self.view_error("Comando desconocido: /%s — usa /help" % cmd))
        if not self.selected or not self.find_session(self.selected):
            ss = [s for s in self.prama.sessions() if SESSION_RE.match(s["name"])]
            if len(ss) == 1:
                self.selected = ss[0]["name"]
            else:
                self.selected = ""
                text_m, kb = self.view_menu()
                return self.send("⚠️ No hay una sesión seleccionada. Elige una:\n\n" + text_m, kb)
        return self.deliver_text(self.selected, text)

    # ── dispatch ──
    def handle(self, upd):
        cbq = upd.get("callback_query")
        if cbq:
            msg = cbq.get("message") or {}
            chat = (msg.get("chat") or {}).get("id")
            user = (cbq.get("from") or {}).get("id")
            if not self.authorized(chat, user):
                self.note_unauthorized(chat, user)
                return
            self.api.call("answerCallbackQuery", {"callback_query_id": cbq.get("id")})
            data = cbq.get("data") or ""
            log("callback %s" % data)
            try:
                self.on_callback(data, msg.get("message_id"))
            except CliError as ex:
                self.send(*self.view_error(str(ex)), edit_id=msg.get("message_id"))
            return
        msg = upd.get("message")
        if not msg:
            return
        chat = (msg.get("chat") or {}).get("id")
        user = (msg.get("from") or {}).get("id")
        if not self.authorized(chat, user):
            self.note_unauthorized(chat, user)
            return
        text = msg.get("text") or ""
        age = time.time() - float(msg.get("date") or 0)
        if age > BACKLOG_MAX_AGE:
            log("ignorado mensaje antiguo (%ds): %s" % (age, text[:40]))
            return
        log("mensaje: %s" % text[:80])
        try:
            self.on_text(text)
        except CliError as ex:
            self.send(*self.view_error(str(ex)))

    def startup(self):
        backoff = 1
        while True:
            try:
                me = self.api.call("getMe")
                break
            except NetError as ex:
                log("sin red (%s); reintento en %ds" % (ex, backoff))
                time.sleep(backoff)
                backoff = min(backoff * 2, 60)
        if not me.get("ok"):
            log("getMe falló: %s" % me.get("description"))
            if me.get("error_code") in (401, 404):
                log("token inválido; ejecuta: prama-agent telegram setup")
                sys.exit(EXIT_CONFIG)
            raise NetError("getMe: %s" % me.get("description"))
        log("conectado como @%s; chat autorizado %s" % ((me.get("result") or {}).get("username"),
                                                       self.chat_id))
        try:
            self.api.call("deleteWebhook", {"drop_pending_updates": False})
            self.api.call("setMyCommands", {"commands": [
                {"command": "menu", "description": "Menú principal"},
                {"command": "status", "description": "Sesiones con CPU/RAM"},
                {"command": "logs", "description": "Ver pantalla: /logs [sesión]"},
                {"command": "send", "description": "Escribir: /send <sesión> <texto>"},
                {"command": "launch", "description": "Lanzar: /launch <agente> <zona> [rol]"},
                {"command": "help", "description": "Ayuda"},
            ]})
        except NetError as ex:
            log("setMyCommands: %s" % ex)

    def loop(self):
        self.startup()
        offset = None
        backoff = 1
        while True:
            payload = {"timeout": POLL_TIMEOUT, "allowed_updates": ["message", "callback_query"]}
            if offset is not None:
                payload["offset"] = offset
            try:
                res = self.api.call("getUpdates", payload, timeout=POLL_TIMEOUT + 15)
            except NetError as ex:
                log("red: %s; reintento en %ds" % (ex, backoff))
                time.sleep(backoff)
                backoff = min(backoff * 2, 60)
                continue
            if not res.get("ok"):
                code = res.get("error_code")
                log("getUpdates falló (%s): %s" % (code, res.get("description")))
                if code == 401:
                    sys.exit(EXIT_CONFIG)
                wait = (res.get("parameters") or {}).get("retry_after") or 0
                time.sleep(max(backoff, int(wait)))
                backoff = min(backoff * 2, 60)
                continue
            backoff = 1
            for upd in res.get("result") or []:
                uid = upd.get("update_id")
                if isinstance(uid, int):
                    offset = uid + 1
                try:
                    self.handle(upd)
                except Exception as ex:  # one bad update must never kill the loop
                    log("error procesando update %s: %r" % (uid, ex))
                    for l in traceback.format_exc().splitlines()[-6:]:
                        log("  " + l)


def main():
    global TOKEN
    path, conf = load_conf()
    if not path:
        log("Telegram no está configurado (falta telegram.env). Ejecuta: prama-agent telegram setup")
        return EXIT_CONFIG
    TOKEN = conf.get("TELEGRAM_BOT_TOKEN", "")
    chat = conf.get("TELEGRAM_CHAT_ID", "")
    if not re.match(r"^[0-9]+:[A-Za-z0-9_-]{20,}$", TOKEN) or not re.match(r"^-?[0-9]+$", chat):
        log("telegram.env incompleto o inválido (%s). Ejecuta: prama-agent telegram setup" % path)
        return EXIT_CONFIG
    self_path = os.environ.get("SELF_PATH", "")
    if not self_path or not os.access(self_path, os.X_OK):
        log("SELF_PATH no apunta a prama-agent ejecutable: %r" % self_path)
        return EXIT_CONFIG
    base = os.environ.get("PRAMA_TG_API_BASE") or "https://api.telegram.org"
    bot = Bot(Api(TOKEN, base), Prama(self_path), chat, conf.get("TELEGRAM_USER_ID", ""))
    log("iniciando (config %s, servidor tmux %s)" % (path, os.environ.get("PRAMA_TMUX_SOCKET", "prama")))
    try:
        bot.loop()
    except KeyboardInterrupt:
        log("detenido")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
