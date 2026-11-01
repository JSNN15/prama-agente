#!/usr/bin/env python3
# lib/telegram_bot.py — prama-agent Telegram bridge (long polling, stdlib only, Python >= 3.8)
# Copyright 2026 Julian Neira Nova
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
# CLI), PRAMA_TG_API_BASE (default https://api.telegram.org), PRAMA_TG_LOG (optional log file),
# PRAMA_UI_LANG (interface language, en | es; default en).
#
# Interface text: the message id is the English text passed to _() (a plain literal, formatted
# afterwards with % or .format), translated from lib/lang/<lang>/telegram_bot.json; a missing
# entry falls back to English. tools/i18n_check.py checks every _() literal has a translation.
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
MAX_WORKERS = 6            # workers per team created from Telegram
TEAM_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,19}$")
DEFAULT_TEAM = "principal"  # team name stored by the CLI: data, never translated
# Suggested names for a new team (they become part of session names), per interface language.
TEAM_SUGGESTIONS = {"es": ("arquitectura", "seguridad", "docs", "tests"),
                    "en": ("architecture", "security", "docs", "tests")}
# Slash commands: canonical (English) name -> aliases. Every alias works in every language;
# LOCAL_COMMANDS gives the name shown in /help and in the command menu of a language.
COMMAND_ALIASES = {
    "menu": ("start",),
    "teams": ("team", "equipos", "equipo"),
    "quota": ("cuota",),
    "reports": ("reportes", "bugs"),
    "alerts": ("alertas", "alarms"),
    "daemons": ("daemon",),
    "notify": ("avisos", "notifications"),
    "mute": ("silencio", "silenciar"),
}
LOCAL_COMMANDS = {"es": {"teams": "equipos", "quota": "cuota", "reports": "reportes",
                         "alerts": "alertas", "notify": "avisos", "mute": "silencio"}}
NOTIFY_LEVELS = ("all", "important", "alerts", "off")
MUTE_CHOICES = ("30m", "1h", "8h", "24h")
QUOTA_ALERT = 90            # % of a quota window that counts as an alert
MEMORY_SHOWN = 15           # newest memory notes shown in a team's memory view
HOST = socket.gethostname().split(".")[0]

TOKEN = ""
LOG_PATH = os.environ.get("PRAMA_TG_LOG", "")


# ── Interface language ──────────────────────────────────────────────────────
LANG_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lang")
UI_LANG = "en"
CATALOG = {}


def set_lang(lang):
    """Loads the catalog of lang (en | es). A missing catalog or entry falls back to English."""
    global UI_LANG, CATALOG
    lang = lang if re.match(r"^[a-z]{2}$", lang or "") else "en"
    cat = {}
    if lang != "en":
        try:
            with open(os.path.join(LANG_DIR, lang, "telegram_bot.json"), encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                cat = {k: v for k, v in data.items() if isinstance(k, str) and isinstance(v, str)}
        except (OSError, ValueError):
            pass  # no catalog: English
    UI_LANG, CATALOG = lang, cat


def _(msgid):
    """Translated text of an English message id."""
    return CATALOG.get(msgid, msgid)


def command_name(cmd):
    """Name of a canonical slash command in the active language ('teams' -> 'equipos' in es)."""
    return LOCAL_COMMANDS.get(UI_LANG, {}).get(cmd, cmd)


def canonical_command(cmd):
    for name, aliases in COMMAND_ALIASES.items():
        if cmd in aliases:
            return name
    return cmd


def role_desc(role):
    return {
        "executor": _("Runs tasks"),
        "coordinator": _("Plans and hands out work"),
        "reader": _("Read-only / review"),
        "daemon": _("Autonomous loop"),
    }.get(role, "")


set_lang(os.environ.get("PRAMA_UI_LANG", "en"))


# ── Logging ─────────────────────────────────────────────────────────────────
def log(msg):
    line = "%s [telegram-bot] %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    if TOKEN:
        line = line.replace(TOKEN, "***")
    try:
        sys.stderr.write(line + "\n")
        sys.stderr.flush()
    except OSError:
        pass  # stderr closed (daemon detached): the log file below is still written
    if LOG_PATH:
        try:
            fd = os.open(LOG_PATH, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            with os.fdopen(fd, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            pass  # logging must never take the bot down (disk full, file removed)


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
            return {"ok": False, "description": _("non-JSON response")}


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
            raise CliError(_("timed out (%ss)") % timeout)
        except OSError as ex:
            raise CliError(_("could not run prama-agent: %s") % ex)
        out = res.stdout.decode("utf-8", "replace")
        err = res.stderr.decode("utf-8", "replace")
        return res.returncode, out, err

    def ok(self, args, timeout=30):
        rc, out, err = self.run(args, timeout)
        if rc != 0:
            msg = clean_err(err) or clean_err(out) or (_("exit code %d") % rc)
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
            raise CliError(_("invalid JSON output from: prama-agent %s") % " ".join(args))
        if not isinstance(data, list):
            raise CliError(_("expected a JSON list from: prama-agent %s") % " ".join(args))
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

    def fleet(self):
        """Agent sessions with team, model and quota (prama-agent fleet status --json)."""
        return [d for d in self.json(["fleet", "status", "--json"])
                if isinstance(d, dict) and isinstance(d.get("session"), str)]

    def feedback(self):
        """Open bug reports filed by agents (prama-agent feedback list --json)."""
        return [d for d in self.json(["feedback", "list", "--json"])
                if isinstance(d, dict) and isinstance(d.get("id"), str)]

    def memory(self, target):
        """Notes of a team's memory and its zone's (prama-agent memory show <session> --json)."""
        return [d for d in self.json(["memory", "show", target, "--json"])
                if isinstance(d, dict) and isinstance(d.get("text"), str)]

    def branches(self, coord):
        """Worker branches of an isolated team (prama-agent worktree status <coord> --json)."""
        return [d for d in self.json(["worktree", "status", coord, "--json"])
                if isinstance(d, dict) and isinstance(d.get("branch"), str)]

    def notify_state(self):
        """(level, mute_until) of the Telegram notifications."""
        out = self.ok(["telegram", "alerts", "--porcelain"]).strip()
        level, _sep, until = out.partition("|")
        return (level if level in NOTIFY_LEVELS else "all"), (int(until) if until.isdigit() else 0)

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
    return "\n".join(kept) if kept else _("(empty screen)")


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


def quota_text(q):
    """'5h 12% · 7d 40% · ctx 8%' from a fleet quota object (empty when unknown)."""
    if not isinstance(q, dict):
        return ""
    parts = []
    for key, label in (("five_hour_pct", "5h"), ("seven_day_pct", "7d"), ("context_pct", "ctx")):
        v = q.get(key)
        if isinstance(v, (int, float)):
            parts.append("%s %d%%" % (label, v))
    return " · ".join(parts)


def quota_peak(q):
    """Highest 5h / 7d usage, to flag agents close to their limit."""
    if not isinstance(q, dict):
        return 0
    vals = [q.get(k) for k in ("five_hour_pct", "seven_day_pct")]
    return max([v for v in vals if isinstance(v, (int, float))] or [0])


def needs_attention(d):
    """Why an agent of `fleet status --json` needs the operator, or ''."""
    st = str(d.get("state", "")).upper()
    if st == "BLOCKED":
        return _("blocked") + (" (%s)" % d["blocked_reason"] if d.get("blocked_reason") else "")
    if st == "DEAD":
        return _("stopped")
    if quota_peak(d.get("quota")) >= QUOTA_ALERT:
        return _("quota at %d%%") % quota_peak(d.get("quota"))
    return ""


def teams_of(fleet):
    """{coordinator_session: (coordinator_row, [member_rows])}. A zone can hold several teams."""
    teams = {}
    for d in fleet:
        if d.get("role") == "coordinator" and d.get("zone"):
            teams[d["session"]] = (d, [])
    for d in fleet:
        parent = d.get("parent")
        if parent in teams and d is not teams[parent][0]:
            teams[parent][1].append(d)
    return teams


def team_name(coord):
    return coord.get("team") or DEFAULT_TEAM


def team_label(coord):
    """'backend' for the zone's principal team, 'backend · seguridad' otherwise."""
    name = team_name(coord)
    return coord.get("zone", "?") if name == DEFAULT_TEAM else "%s · %s" % (coord.get("zone", "?"), name)


def zone_teams(teams, zone):
    """Team names of a zone."""
    return [team_name(c) for c, _members in teams.values() if c.get("zone") == zone]


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
        self.pending_team = ""     # zone waiting for a typed team name ("✍️ Other name")
        self.pending_queue = ""    # daemon waiting for a typed task ("➕ Queue a task")
        self.pending_note = ""     # coordinator whose team memory gets the next text

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
        log(_("%s failed: %s") % (method, desc))
        if edit_id and ("not found" in desc or "can't be edited" in desc):
            return self.send(text, kb)
        payload.pop("parse_mode", None)
        payload["text"] = strip_html(text)[:MAX_MSG]
        res = self.api.call(method, payload)
        if res.get("ok"):
            r = res.get("result")
            return r.get("message_id", edit_id) if isinstance(r, dict) else edit_id
        log(_("%s (plain text) failed: %s") % (method, res.get("description", "")))
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
            log(_("ignored: chat %s / user %s not authorized") % (chat_id, user_id))

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
        lines = [_("<b>✦ PRAMA AGENT · Mobile control</b>"),
                 "🖥 <code>%s</code> · %s" % (e(HOST), time.strftime("%H:%M:%S")), ""]
        if ss:
            lines.append(_("<b>Sessions (%d)</b>") % len(ss))
            for s in ss[:MAX_LISTED]:
                mark = "  ✍️" if s["name"] == self.selected else ""
                lines.append("%s <code>%s</code>%s" % (dot(s), e(s["name"]), mark))
                meta = "%s · %s · %s" % (s.get("role", "?"), s.get("agent", "?"),
                                         str(s.get("state", "?")).lower())
                if detail:
                    meta += " · CPU %s · %s" % (s.get("cpu", "?"), s.get("mem", "?"))
                lines.append("    <i>%s</i>" % e(meta))
            if len(ss) > MAX_LISTED:
                lines.append(_("<i>… and %d more</i>") % (len(ss) - MAX_LISTED))
        else:
            lines.append(_("<i>No active agents.</i>"))
        lines.append("")
        if self.selected:
            lines.append(_("✍️ What you type goes to <b>%s</b>.") % e(self.selected))
        else:
            lines.append(_("Tap a session or launch a new agent."))
        kb = []
        for s in controllable[:MAX_LISTED]:
            kb.append([self.b("%s %s · %s" % (dot(s), s["name"], s.get("role", "?")),
                              "s:" + s["name"])])
        try:
            hot = [d for d in self.prama.fleet() if needs_attention(d)]
        except CliError:
            hot = []
        if hot:
            lines.insert(3, _("🚨 <b>%d agent(s) need attention</b> → /%s") % (len(hot), command_name("alerts")))
            lines.insert(4, "")
        kb.append([self.b(_("➕ New agent"), "n"), self.b(_("🤝 New team"), "w")])
        kb.append([self.b(_("👥 Teams"), "T"), self.b(_("🚨 Alerts") + (" (%d)" % len(hot) if hot else ""), "A")])
        kb.append([self.b(_("⚙️ Daemons"), "d"), self.b(_("◔ Quota"), "q")])
        kb.append([self.b(_("🔔 Notifications"), "N"), self.b(_("🔄 Refresh"), "m"), self.b(_("❓ Help"), "h")])
        return "\n".join(lines), kb

    def view_session(self, s, note=""):
        name = s["name"]
        lines = []
        if note:
            lines += [note, ""]
        lines += [
            "%s <b>%s</b>%s" % (dot(s), e(name), "  ✍️" if name == self.selected else ""),
            _("Role: <b>%s</b> · Agent: <b>%s</b>") % (e(s.get("role", "?")), e(s.get("agent", "?"))),
            _("State: <b>%s</b> · Zone: <b>%s</b>") % (e(str(s.get("state", "?")).lower()),
                                                      e(s.get("zone", "?"))),
            "CPU %s · RAM %s" % (e(s.get("cpu", "?")), e(s.get("mem", "?"))),
        ]
        if s.get("dir"):
            lines.append("📁 <code>%s</code>" % e(s["dir"]))
        kb = [
            [self.b(_("👁 View screen"), "p:" + name), self.b(_("💬 Talk"), "t:" + name)],
            [self.b(_("🔄 Restart"), "r:" + name), self.b(_("🛑 Close"), "x:" + name)],
            [self.b(_("⬅ Back"), "m")],
        ]
        return "\n".join(lines), kb

    def snapshot_html(self, name, raw, header=""):
        body = fit_pre(clean_screen(raw))
        top = (header + "\n") if header else ""
        return "%s📺 <b>%s</b> · %s\n<pre>%s</pre>" % (top, e(name), time.strftime("%H:%M:%S"), body)

    def snapshot_kb(self, name):
        return [[self.b(_("🔄 Update"), "p:" + name), self.b(_("💬 Talk"), "t:" + name)],
                [self.b(_("⬅ Back"), "s:" + name), self.b(_("☰ Menu"), "m")]]

    def view_help(self):
        text = "\n".join([
            _("<b>❓ Help · Prama Agent</b>"), "",
            _("/menu — main menu"),
            _("/status — sessions with CPU/RAM"),
            _("/logs [session] — view the screen"),
            _("/send &lt;session&gt; &lt;text&gt; — write to a session"),
            _("/launch &lt;agent&gt; &lt;zone&gt; [role] — launch an agent"),
            _("/%s — teams: status, talk to the coordinator, add or close") % command_name("teams"),
            _("/%s — 5h / 7d quota usage per agent") % command_name("quota"),
            _("/%s — prama-agent bugs reported by the agents") % command_name("reports"),
            _("/%s — agents that need you: blocked, stopped, quota") % command_name("alerts"),
            _("/daemons — daemon agents and their queues; queue a task"),
            _("/%s — what the bot notifies you about") % command_name("notify"),
            _("/%s [30m|1h|8h|off] — notifications without sound") % command_name("mute"),
            _("/help — this help"), "",
            _("Plain text → goes to the selected session (✍️)."),
            _("Roles: %s") % ", ".join(ROLES),
        ])
        return text, [[self.b(_("⬅ Back"), "m")]]

    def view_teams(self, note=""):
        teams = teams_of(self.prama.fleet())
        lines = ([note, ""] if note else []) + [_("<b>👥 Teams</b>"), ""]
        kb = []
        if not teams:
            lines.append(_("<i>No active teams.</i>"))
        for cs in sorted(teams, key=lambda c: team_label(teams[c][0])):
            coord, members = teams[cs]
            lines.append(_("%s <b>%s</b> · %s + %d agent(s)") % (dot(coord), e(team_label(coord)),
                                                                  e(coord.get("agent", "?")), len(members)))
            kb.append([self.b("🤝 %s (%d)" % (team_label(coord), len(members) + 1), "T:" + cs)])
        kb.append([self.b(_("🤝 New team"), "w"), self.b(_("⬅ Back"), "m")])
        return "\n".join(lines), kb

    def view_team(self, cs, note=""):
        teams = teams_of(self.prama.fleet())
        if cs not in teams:
            # /equipos <zone>: the zone's only team, or the list when it has several.
            in_zone = [c for c, (d, _members) in teams.items() if d.get("zone") == cs]
            if len(in_zone) != 1:
                return self.view_teams(_("⚠️ There is no team <b>%s</b>.") % e(cs) if not in_zone else note)
            cs = in_zone[0]
        coord, members = teams[cs]
        lines = ([note, ""] if note else []) + [_("<b>🤝 Team · %s</b>") % e(team_label(coord)), ""]
        for d, lead in [(coord, "❖")] + [(m, "└") for m in members]:
            st = str(d.get("state", "?")).lower()
            if d.get("blocked_reason"):
                st += " · " + str(d["blocked_reason"])
            lines.append("%s %s <code>%s</code>" % (lead, dot(d), e(d["session"])))
            meta = " · ".join(x for x in (d.get("agent", "?"), d.get("model") or "", st,
                                          quota_text(d.get("quota"))) if x)
            if d.get("queue"):
                meta += " · ✉ %s" % d["queue"]
            lines.append("    <i>%s</i>" % e(meta))
        lines += ["", _("💬 What you type after «Talk» goes to the coordinator, who hands out the work.")]
        kb = [[self.b(_("💬 Talk to the coordinator"), "t:" + cs), self.b(_("👁 Screen"), "p:" + cs)]]
        add = [self.b("➕ 1 %s" % a, "ta:%s:%s" % (cs, a)) for a in self.prama.agents()[:3]]
        if add:
            kb.append(add)
        kb.append([self.b(_("🧠 Memory"), "M:" + cs), self.b(_("⎇ Branches"), "B:" + cs)])
        kb.append([self.b(_("🛑 Close team"), "tx:" + cs), self.b("🔄", "T:" + cs)])
        kb.append([self.b(_("⬅ Teams"), "T"), self.b(_("☰ Menu"), "m")])
        return "\n".join(lines), kb

    def view_team_names(self, zone):
        """New team, step 2: an existing team of the zone (add agents) or a new name."""
        existing = zone_teams(teams_of(self.prama.fleet()), zone)
        kb = [[self.b(_("➕ add to «%s»") % t, "wn:%s:%s" % (zone, t))] for t in existing]
        suggestions = TEAM_SUGGESTIONS.get(UI_LANG, TEAM_SUGGESTIONS["en"])
        fresh = [t for t in ((DEFAULT_TEAM,) if not existing else ()) + suggestions if t not in existing]
        row = []
        for t in fresh:
            row.append(self.b("🆕 %s" % t, "wn:%s:%s" % (zone, t)))
            if len(row) == 2:
                kb.append(row)
                row = []
        if row:
            kb.append(row)
        kb.append([self.b(_("✍️ Other name"), "wo:" + zone)])
        kb.append([self.b(_("⬅ Back"), "w")])
        text = _("<b>🤝 New team · 2/3</b>\nZone: <b>%s</b>\nA zone can hold several teams (architecture, security, docs…), each with its own coordinator. Choose the team:") % e(zone)
        return text, kb

    def view_team_workers(self, zone, team):
        kb = [[self.b("%s × %d" % (a, n), "wg:%s:%s:%s:%d" % (zone, team, a, n)) for n in (1, 2, 3)]
              for a in self.prama.agents()]
        kb.append([self.b(_("⬅ Back"), "wz:" + zone)])
        return (_("<b>🤝 New team · 3/3</b>\nZone: <b>%s</b> · Team: <b>%s</b>\nChoose the executors:")
                % (e(zone), e(team))), kb

    def view_quota(self):
        fleet = self.prama.fleet()
        lines = [_("<b>◔ Quota per agent</b>"), ""]
        for d in fleet:
            q = quota_text(d.get("quota"))
            warn = " ⚠️" if quota_peak(d.get("quota")) >= 90 else ""
            lines.append("%s <code>%s</code>%s" % (dot(d), e(d["session"]), warn))
            lines.append("    <i>%s</i>" % e(" · ".join(x for x in (d.get("model") or d.get("agent", "?"),
                                                                    q or _("no data yet")) if x)))
        if not fleet:
            lines.append(_("<i>No active agents.</i>"))
        return "\n".join(lines), [[self.b(_("🔄 Update"), "q"), self.b(_("⬅ Back"), "m")]]

    def view_reports(self):
        reps = self.prama.feedback()
        lines = [_("<b>🐞 prama-agent bug reports</b>"), ""]
        for d in reps[:MAX_LISTED]:
            n = d.get("count") or 1
            lines.append("• <code>%s</code> · %s · %s%s" % (e(d["id"]), e(d.get("kind", "bug")), e(d.get("from", "?")),
                                                         " (×%s)" % e(n) if n != 1 else ""))
            lines.append("    <i>%s</i>" % e(str(d.get("summary", ""))[:200]))
        if not reps:
            lines.append(_("<i>No open reports.</i>"))
        else:
            hint = _("On the server: <code>prama-agent feedback show &lt;id&gt;</code> · <code>feedback export &lt;id&gt;</code> for a GitHub issue.")
            lines += ["", hint]
        return "\n".join(lines), [[self.b(_("🔄 Update"), "f"), self.b(_("⬅ Back"), "m")]]

    def do_team(self, zone, team, agent, count, edit_id=None):
        """Creates a team in a zone, or adds workers to it when it already exists."""
        if zone not in self.prama.zones():
            return self.send(*self.view_error(_("Unknown zone: %s") % zone, "w"), edit_id=edit_id)
        if not TEAM_RE.match(team or ""):
            return self.send(*self.view_error(_("Invalid team name: %s") % team, "w"), edit_id=edit_id)
        if agent not in self.prama.agents():
            return self.send(*self.view_error(_("Agent not allowed or not installed: %s") % agent, "w"),
                             edit_id=edit_id)
        if not (1 <= count <= MAX_WORKERS):
            return self.send(*self.view_error(_("Invalid count (1-%d).") % MAX_WORKERS, "w"), edit_id=edit_id)
        had = team in zone_teams(teams_of(self.prama.fleet()), zone)
        if had:
            busy = _("⏳ Adding <b>{count} {agent}</b> to team <b>{team}</b> in <b>{zone}</b>…")
        else:
            busy = _("⏳ Creating team <b>{team}</b> in <b>{zone}</b> with <b>{count} {agent}</b>…")
        mid = self.send(busy.format(count=count, agent=e(agent), team=e(team), zone=e(zone)), edit_id=edit_id)
        try:
            self.prama.ok(["swarm", zone, "--team", team, "--workers", "%s:%d" % (agent, count), "--no-open"],
                          timeout=240)
        except CliError as ex:
            return self.send(*self.view_error(_("Could not form the team: %s") % ex, "w"), edit_id=mid)
        teams = teams_of(self.prama.fleet())
        cs = next((c for c, (d, _members) in teams.items() if d.get("zone") == zone and team_name(d) == team), "")
        if cs and not had:
            self.selected = cs
            note = _("✅ Team ready. <b>Type the goal</b>: what you send now goes to the coordinator <b>%s</b>.") % e(cs)
        else:
            note = _("✅ %d %s added to the team.") % (count, e(agent))
        if not cs:
            return self.send(*self.view_teams(note), edit_id=mid)
        return self.send(*self.view_team(cs, note), edit_id=mid)

    def view_alerts(self, note=""):
        """Agents that need the operator, each with the buttons to act on it."""
        lines = ([note, ""] if note else []) + [_("<b>🚨 Alerts</b>"), ""]
        kb = []
        hot = [(d, needs_attention(d)) for d in self.prama.fleet()]
        hot = [(d, why) for d, why in hot if why]
        for d, why in hot[:MAX_LISTED]:
            s = d["session"]
            lines.append("%s <code>%s</code> · <b>%s</b>" % (dot(d), e(s), e(why)))
            if d.get("blocked_detail"):
                lines.append("    <i>%s</i>" % e(str(d["blocked_detail"])[:160]))
            if d.get("queue"):
                lines.append("    " + _("<i>%s task(s) waiting in its queue</i>") % e(d["queue"]))
            kb.append([self.b("👁 " + s[-22:], "p:" + s), self.b(_("🔄 Restart"), "r:" + s),
                       self.b(_("🛑 Close"), "x:" + s)])
        if not hot:
            lines.append(_("✅ All agents are fine."))
        lines += ["", _("Alerts also reach you as messages, with these buttons. /%s chooses which ones.")
                  % command_name("notify")]
        kb.append([self.b(_("🔄 Update"), "A"), self.b(_("⬅ Back"), "m")])
        return "\n".join(lines), kb

    def view_daemons(self, note=""):
        """Daemon agents: state and queue; queue a task, watch, close."""
        lines = ([note, ""] if note else []) + [_("<b>⚙️ Daemons</b>"), ""]
        kb = []
        ds = [d for d in self.prama.fleet() if d.get("role") == "daemon"]
        for d in ds[:MAX_LISTED]:
            s = d["session"]
            meta = " · ".join(x for x in (d.get("agent", "?"), str(d.get("state", "?")).lower(),
                                          _("%s queued") % d.get("queue", 0), quota_text(d.get("quota"))) if x)
            lines += ["%s <code>%s</code>" % (dot(d), e(s)), "    <i>%s</i>" % e(meta)]
            kb.append([self.b(_("➕ Queue a task"), "dq:" + s), self.b(_("👁 Screen"), "p:" + s),
                       self.b("🛑", "x:" + s)])
        if not ds:
            lines.append(_("<i>No daemons. A daemon works through its queue in a loop, unattended.</i>"))
        lines += ["", _("Launch one: ➕ New agent → role <b>daemon</b>.")]
        kb.append([self.b(_("➕ New agent"), "n"), self.b(_("🔄 Update"), "d"), self.b(_("⬅ Back"), "m")])
        return "\n".join(lines), kb

    def view_memory(self, cs, note=""):
        """A team's shared memory (and its zone's): the newest notes."""
        team = teams_of(self.prama.fleet()).get(cs)
        if not team:
            return self.view_teams(_("⚠️ That team no longer exists."))
        label = team_label(team[0])
        notes = self.prama.memory(cs)
        lines = ([note, ""] if note else []) + [_("<b>🧠 Memory · %s</b>") % e(label), ""]
        for d in notes[-MEMORY_SHOWN:]:
            scope = "🌐" if d.get("scope") == "zone" else "•"
            lines.append("%s <i>%s · %s</i>\n   %s" % (scope, e(d.get("ts", "")), e(d.get("by", "")), e(d["text"])))
        if not notes:
            lines.append(_("<i>Empty. The agents add decisions and findings here; so can you.</i>"))
        elif len(notes) > MEMORY_SHOWN:
            lines.append(_("<i>… %d older note(s) on the server: prama-agent memory show</i>") % (len(notes) - MEMORY_SHOWN))
        kb = [[self.b(_("✍️ Add a note"), "Mn:" + cs), self.b(_("🔄 Update"), "M:" + cs)],
              [self.b(_("⬅ Team"), "T:" + cs), self.b(_("☰ Menu"), "m")]]
        return "\n".join(lines), kb

    def view_branches(self, cs):
        """Isolated team: each executor's branch, what is left to merge, uncommitted work."""
        team = teams_of(self.prama.fleet()).get(cs)
        if not team:
            return self.view_teams(_("⚠️ That team no longer exists."))
        rows = self.prama.branches(cs)
        lines = [_("<b>⎇ Branches · %s</b>") % e(team_label(team[0])), ""]
        for d in rows:
            parts = []
            if d.get("ahead"):
                parts.append(_("%d to merge") % d["ahead"])
            if d.get("uncommitted"):
                parts.append(_("%d uncommitted") % d["uncommitted"])
            if d.get("behind"):
                parts.append(_("%d behind") % d["behind"])
            lines.append("%s <code>%s</code>\n    %s · <i>%s</i>" % ("↑" if d.get("ahead") else "·", e(d["branch"]),
                                                                   e(" · ".join(parts) or _("up to date")),
                                                                   e(str(d.get("last", ""))[:80])))
        if not rows:
            lines.append(_("<i>This team shares the zone folder (no branches per agent).</i>"))
        else:
            lines += ["", _("The coordinator merges them (prama-agent worktree merge). Ask it from 💬 Talk.")]
        return "\n".join(lines), [[self.b(_("🔄 Update"), "B:" + cs), self.b(_("⬅ Team"), "T:" + cs)]]

    def view_notify(self, note=""):
        level, until = self.prama.notify_state()
        names = {"all": _("everything (also bus traffic)"), "important": _("important (alerts, reports, teams)"),
                 "alerts": _("alerts only"), "off": _("nothing")}
        lines = ([note, ""] if note else []) + [_("<b>🔔 Notifications</b>"), "",
                                               _("Sending: <b>%s</b>") % e(names.get(level, level))]
        if until > time.time():
            lines.append(_("🔕 Without sound until %s") % time.strftime("%H:%M", time.localtime(until)))
        kb = [[self.b(("● " if lv == level else "") + names[lv], "Nl:" + lv)] for lv in NOTIFY_LEVELS]
        kb.append([self.b("🔕 " + m, "Nm:" + m) for m in MUTE_CHOICES])
        kb.append([self.b(_("🔔 Sound on"), "Nm:off"), self.b(_("⬅ Back"), "m")])
        return "\n".join(lines), kb

    def view_error(self, msg, back="m"):
        return "⚠️ %s" % e(msg), [[self.b(_("⬅ Back"), back)]]

    # ── actions ──
    def do_launch(self, agent, zone, role, edit_id=None):
        if agent not in self.prama.agents():
            return self.send(*self.view_error(_("Agent not allowed or not installed: %s") % agent),
                             edit_id=edit_id)
        if zone not in self.prama.zones():
            return self.send(*self.view_error(_("Unknown zone: %s") % zone), edit_id=edit_id)
        if role not in ROLES:
            return self.send(*self.view_error(_("Invalid role: %s (use %s)") % (role, ", ".join(ROLES))),
                             edit_id=edit_id)
        mid = self.send(_("⏳ Launching <b>%s</b> in <b>%s</b> (%s)…") % (e(agent), e(zone), e(role)),
                        edit_id=edit_id)
        try:
            out = self.prama.ok([agent, zone, "--role", role, "--bg", "--porcelain"], timeout=90)
        except CliError as ex:
            return self.send(*self.view_error(_("Could not launch: %s") % ex), edit_id=mid)
        name = out.strip().splitlines()[-1].strip() if out.strip() else ""
        s = self.find_session(name)
        if not s:
            return self.send(*self.view_error(_("Launched, but session «%s» does not show up.") % name),
                             edit_id=mid)
        self.selected = name
        return self.send(*self.view_session(s, _("✅ Agent launched. You are now writing to this session.")),
                         edit_id=mid)

    def deliver_text(self, name, text, edit_id=None):
        s = self.find_session(name)
        if not s:
            return self.send(*self.view_error(_("Session not found: %s") % name), edit_id=edit_id)
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
            return self.send(*self.view_error(_("Could not send to %s: %s") % (name, ex)))
        mid = self.send(_("📨 Sent to <b>%s</b>. Waiting for the reply…") % e(name))
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
            self.send(self.snapshot_html(name, snap, _("📨 Reply from <b>%s</b>:") % e(name)),
                      self.snapshot_kb(name), edit_id=mid)
        except Exception as ex:  # never let a watcher thread die noisily
            log("watch %s: %r" % (name, ex))

    def show_snapshot(self, name, edit_id=None):
        if not self.find_session(name):
            return self.send(*self.view_error(_("Session not found: %s") % name), edit_id=edit_id)
        raw = self.prama.capture(name)
        return self.send(self.snapshot_html(name, raw), self.snapshot_kb(name), edit_id=edit_id)

    # ── callbacks ──
    def on_callback(self, data, mid):
        if data.startswith("#"):
            try:
                data = self.cb_cache[int(data[1:])]
            except (ValueError, KeyError):
                return self.send(*self.view_menu(), edit_id=mid)
        act, _sep, arg = data.partition(":")
        if act == "m":
            return self.send(*self.view_menu(), edit_id=mid)
        if act == "h":
            return self.send(*self.view_help(), edit_id=mid)
        if act in ("s", "p", "t", "r", "x", "R", "X"):
            s = self.find_session(arg)
            if not s:
                return self.send(*self.view_error(_("Session «%s» no longer exists.") % arg), edit_id=mid)
            name = s["name"]
            if act == "s":
                return self.send(*self.view_session(s), edit_id=mid)
            if act == "p":
                return self.show_snapshot(name, edit_id=mid)
            if act == "t":
                self.selected = name
                return self.send(*self.view_session(
                    s, _("💬 Chat linked to <b>%s</b>. Type your message.") % e(name)), edit_id=mid)
            if act in ("r", "x"):
                if act == "r":
                    ask, yes = _("⚠️ Are you sure you want to <b>restart</b> session <b>%s</b>?"), _("✅ Yes, restart")
                else:
                    ask, yes = _("⚠️ Are you sure you want to <b>close</b> session <b>%s</b>?"), _("✅ Yes, close")
                return self.send(ask % e(name),
                                 [[self.b(yes, act.upper() + ":" + name),
                                   self.b(_("✖ No"), "s:" + name)]], edit_id=mid)
            if act == "R":
                self.send(_("⏳ Restarting <b>%s</b>…") % e(name), edit_id=mid)
                try:
                    self.prama.ok(["restart", name], timeout=60)
                except CliError as ex:
                    return self.send(*self.view_error(_("Restart failed: %s") % ex, "s:" + name), edit_id=mid)
                time.sleep(1.5)
                s2 = self.find_session(name) or s
                return self.send(*self.view_session(s2, _("🔄 Session restarted.")), edit_id=mid)
            if act == "X":
                try:
                    self.prama.ok(["stop", name], timeout=60)
                except CliError as ex:
                    return self.send(*self.view_error(_("Could not close: %s") % ex, "s:" + name), edit_id=mid)
                if self.selected == name:
                    self.selected = ""
                text, kb = self.view_menu()
                return self.send(_("🛑 Session <b>%s</b> closed.") % e(name) + "\n\n" + text, kb, edit_id=mid)
        if act == "n":                      # new agent: choose agent
            agents = self.prama.agents()
            if not agents:
                return self.send(*self.view_error(_("No agents installed.")), edit_id=mid)
            kb = [[self.b(a, "na:" + a)] for a in agents] + [[self.b(_("⬅ Back"), "m")]]
            return self.send(_("<b>➕ New agent · 1/3</b>\nChoose the agent:"), kb, edit_id=mid)
        if act == "na":                     # choose zone
            if arg not in self.prama.agents():
                return self.send(*self.view_error(_("Agent not allowed: %s") % arg, "n"), edit_id=mid)
            kb = [[self.b(z, "nz:%s:%s" % (arg, z))] for z in self.prama.zones()]
            kb.append([self.b(_("⬅ Back"), "n")])
            return self.send(_("<b>➕ New agent · 2/3</b>\nAgent: <b>%s</b>\nChoose the zone:") % e(arg),
                             kb, edit_id=mid)
        if act == "nz":                     # choose role
            agent, _sep, zone = arg.partition(":")
            if agent not in self.prama.agents() or zone not in self.prama.zones():
                return self.send(*self.view_error(_("Invalid selection."), "n"), edit_id=mid)
            kb = [[self.b("%s · %s" % (r, role_desc(r)), "nl:%s:%s:%s" % (agent, r, zone))] for r in ROLES]
            kb.append([self.b(_("⬅ Back"), "na:" + agent)])
            return self.send(_("<b>➕ New agent · 3/3</b>\nAgent: <b>%s</b> · Zone: <b>%s</b>\nChoose the role:")
                             % (e(agent), e(zone)), kb, edit_id=mid)
        if act == "nl":                     # launch
            parts = arg.split(":", 2)
            if len(parts) != 3:
                return self.send(*self.view_error(_("Invalid selection."), "n"), edit_id=mid)
            agent, role, zone = parts
            return self.do_launch(agent, zone, role, edit_id=mid)
        if act == "w":                      # new team: choose zone
            self.pending_team = ""
            kb = [[self.b(z, "wz:" + z)] for z in self.prama.zones()] + [[self.b(_("⬅ Back"), "m")]]
            return self.send(_("<b>🤝 New team · 1/3</b>\nCoordinator + executor agents. Choose the zone:"),
                             kb, edit_id=mid)
        if act == "wz":                     # choose the team (existing or new)
            if arg not in self.prama.zones():
                return self.send(*self.view_error(_("Unknown zone: %s") % arg, "w"), edit_id=mid)
            return self.send(*self.view_team_names(arg), edit_id=mid)
        if act == "wo":                     # type a team name
            if arg not in self.prama.zones():
                return self.send(*self.view_error(_("Unknown zone: %s") % arg, "w"), edit_id=mid)
            self.pending_team = arg
            return self.send(_("✍️ Type the team name for <b>%s</b> (lowercase letters, digits and hyphens, max. 20; e.g. <code>payments</code>).") % e(arg),
                             [[self.b(_("✖ Cancel"), "wz:" + arg)]], edit_id=mid)
        if act == "wn":                     # choose the workers
            zone, _sep, team = arg.partition(":")
            if zone not in self.prama.zones() or not TEAM_RE.match(team):
                return self.send(*self.view_error(_("Invalid selection."), "w"), edit_id=mid)
            return self.send(*self.view_team_workers(zone, team), edit_id=mid)
        if act == "wg":                     # create the team / add its workers
            parts = arg.split(":")
            if len(parts) != 4 or not parts[3].isdigit():
                return self.send(*self.view_error(_("Invalid selection."), "w"), edit_id=mid)
            return self.do_team(parts[0], parts[1], parts[2], int(parts[3]), edit_id=mid)
        if act == "ta":                     # add one worker to a team
            cs, _sep, agent = arg.partition(":")
            team = teams_of(self.prama.fleet()).get(cs)
            if not team:
                return self.send(*self.view_teams(_("⚠️ That team no longer exists.")), edit_id=mid)
            return self.do_team(team[0].get("zone", ""), team_name(team[0]), agent, 1, edit_id=mid)
        if act == "T":
            if arg:
                return self.send(*self.view_team(arg), edit_id=mid)
            return self.send(*self.view_teams(), edit_id=mid)
        if act == "q":
            return self.send(*self.view_quota(), edit_id=mid)
        if act == "A":
            return self.send(*self.view_alerts(), edit_id=mid)
        if act == "d":
            return self.send(*self.view_daemons(), edit_id=mid)
        if act == "dq":                     # queue a task for a daemon: the next text
            if not self.find_session(arg):
                return self.send(*self.view_daemons(_("⚠️ That daemon no longer exists.")), edit_id=mid)
            self.pending_queue, self.pending_note = arg, ""
            return self.send(_("✍️ Type the task for <b>%s</b>; it joins its queue.") % e(arg),
                             [[self.b(_("✖ Cancel"), "d")]], edit_id=mid)
        if act == "M":
            return self.send(*self.view_memory(arg), edit_id=mid)
        if act == "B":
            return self.send(*self.view_branches(arg), edit_id=mid)
        if act == "Mn":                     # a note for a team's memory: the next text
            self.pending_note, self.pending_queue = arg, ""
            return self.send(_("✍️ Type the note for the team memory (a decision, a convention, a finding)."),
                             [[self.b(_("✖ Cancel"), "M:" + arg)]], edit_id=mid)
        if act == "N":
            return self.send(*self.view_notify(), edit_id=mid)
        if act in ("Nl", "Nm"):
            if (act == "Nl" and arg not in NOTIFY_LEVELS) or (act == "Nm" and arg not in MUTE_CHOICES + ("off",)):
                return self.send(*self.view_notify(), edit_id=mid)
            self.prama.ok(["telegram", "alerts" if act == "Nl" else "mute", arg])
            return self.send(*self.view_notify(_("✅ Saved.")), edit_id=mid)
        if act == "f":
            return self.send(*self.view_reports(), edit_id=mid)
        if act in ("tx", "TX"):             # close a whole team (with confirmation)
            team = teams_of(self.prama.fleet()).get(arg)
            if not team:
                return self.send(*self.view_teams(_("⚠️ That team no longer exists.")), edit_id=mid)
            n, label = len(team[1]) + 1, team_label(team[0])
            if act == "tx":
                return self.send(_("⚠️ Close team <b>%s</b>? Its coordinator and agents stop (%d sessions). The other teams keep working.") % (e(label), n),
                                 [[self.b(_("✅ Yes, close"), "TX:" + arg), self.b(_("✖ No"), "T:" + arg)]],
                                 edit_id=mid)
            self.send(_("⏳ Closing team <b>%s</b>…") % e(label), edit_id=mid)
            try:
                self.prama.ok(["swarm", "stop", arg], timeout=120)
            except CliError as ex:
                return self.send(*self.view_error(_("Could not close: %s") % ex, "T:" + arg), edit_id=mid)
            if self.selected in [team[0]["session"]] + [m["session"] for m in team[1]]:
                self.selected = ""
            return self.send(*self.view_teams(_("🛑 Team <b>%s</b> closed (%d sessions).") % (e(label), n)),
                             edit_id=mid)
        return self.send(*self.view_menu(), edit_id=mid)

    # ── text & commands ──
    def on_text(self, text):
        text = text.strip()
        if not text:
            return None
        if text.startswith("/"):
            head, _sep, rest = text.partition(" ")
            cmd = canonical_command(head[1:].split("@", 1)[0].lower())
            rest = rest.strip()
            if cmd == "menu":
                return self.send(*self.view_menu())
            if cmd == "status":
                return self.send(*self.view_menu(detail=True))
            if cmd == "help":
                return self.send(*self.view_help())
            if cmd == "logs":
                name = rest.split()[0] if rest else self.selected
                if not name:
                    return self.send(*self.view_error(_("Name the session: /logs <session>")))
                return self.show_snapshot(name)
            if cmd == "send":
                name, _sep, msg = rest.partition(" ")
                if not name or not msg.strip():
                    return self.send(*self.view_error(_("Usage: /send <session> <text>")))
                return self.deliver_text(name, msg)
            if cmd == "teams":
                which = rest.split()[0] if rest else ""
                return self.send(*(self.view_team(which) if which else self.view_teams()))
            if cmd == "quota":
                return self.send(*self.view_quota())
            if cmd == "reports":
                return self.send(*self.view_reports())
            if cmd == "alerts":
                return self.send(*self.view_alerts())
            if cmd == "daemons":
                return self.send(*self.view_daemons())
            if cmd == "notify":
                return self.send(*self.view_notify())
            if cmd == "mute":
                arg = (rest.split() or ["1h"])[0].lower()
                if arg not in MUTE_CHOICES + ("off",):
                    return self.send(*self.view_error(_("Usage: /mute [30m|1h|8h|24h|off]")))
                self.prama.ok(["telegram", "mute", arg])
                return self.send(*self.view_notify(_("✅ Saved.")))
            if cmd == "launch":
                args = rest.split()
                if len(args) not in (2, 3):
                    return self.send(*self.view_error(_("Usage: /launch <agent> <zone> [role]")))
                role = args[2] if len(args) == 3 else "executor"
                return self.do_launch(args[0], args[1], role)
            return self.send(*self.view_error(_("Unknown command: /%s — use /help") % cmd))
        if self.pending_queue:
            target, self.pending_queue = self.pending_queue, ""
            self.prama.ok(["bus", "assign", target, text], timeout=30)
            return self.send(*self.view_daemons(_("✅ Queued for <b>%s</b>.") % e(target)))
        if self.pending_note:
            cs, self.pending_note = self.pending_note, ""
            self.prama.ok(["memory", "add", cs, text], timeout=30)
            return self.send(*self.view_memory(cs, _("✅ Note saved.")))
        if self.pending_team:
            zone, self.pending_team = self.pending_team, ""
            name = text.strip().lower().replace(" ", "-")
            if not TEAM_RE.match(name):
                self.pending_team = zone
                return self.send(_("⚠️ Invalid name. Use lowercase letters, digits and hyphens (max. 20)."),
                                 [[self.b(_("✖ Cancel"), "wz:" + zone)]])
            return self.send(*self.view_team_workers(zone, name))
        if not self.selected or not self.find_session(self.selected):
            ss = [s for s in self.prama.sessions() if SESSION_RE.match(s["name"])]
            if len(ss) == 1:
                self.selected = ss[0]["name"]
            else:
                self.selected = ""
                text_m, kb = self.view_menu()
                return self.send(_("⚠️ No session selected. Choose one:") + "\n\n" + text_m, kb)
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
            log(_("ignored old message (%ds): %s") % (age, text[:40]))
            return
        log(_("message: %s") % text[:80])
        try:
            self.on_text(text)
        except CliError as ex:
            self.send(*self.view_error(str(ex)))

    def command_menu(self):
        """setMyCommands list: the command names and descriptions of the active language."""
        return [{"command": c, "description": d} for c, d in (
            ("menu", _("Main menu")),
            ("status", _("Sessions with CPU/RAM")),
            ("logs", _("View the screen: /logs [session]")),
            ("send", _("Write: /send <session> <text>")),
            ("launch", _("Launch: /launch <agent> <zone> [role]")),
            (command_name("teams"), _("Teams: status, talk, add, close")),
            (command_name("quota"), _("5h / 7d quota per agent")),
            (command_name("reports"), _("prama bugs reported by agents")),
            (command_name("alerts"), _("Agents that need you")),
            ("daemons", _("Daemons and their queues")),
            (command_name("notify"), _("What the bot notifies")),
            (command_name("mute"), _("Mute: /mute 1h · off")),
            ("help", _("Help")),
        )]

    def startup(self):
        backoff = 1
        while True:
            try:
                me = self.api.call("getMe")
                break
            except NetError as ex:
                log(_("no network (%s); retrying in %ds") % (ex, backoff))
                time.sleep(backoff)
                backoff = min(backoff * 2, 60)
        if not me.get("ok"):
            log(_("getMe failed: %s") % me.get("description"))
            if me.get("error_code") in (401, 404):
                log(_("invalid token; run: prama-agent telegram setup"))
                sys.exit(EXIT_CONFIG)
            raise NetError("getMe: %s" % me.get("description"))
        log(_("connected as @%s; authorized chat %s") % ((me.get("result") or {}).get("username"),
                                                          self.chat_id))
        try:
            self.api.call("deleteWebhook", {"drop_pending_updates": False})
            self.api.call("setMyCommands", {"commands": self.command_menu()})
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
                log(_("network: %s; retrying in %ds") % (ex, backoff))
                time.sleep(backoff)
                backoff = min(backoff * 2, 60)
                continue
            if not res.get("ok"):
                code = res.get("error_code")
                log(_("getUpdates failed (%s): %s") % (code, res.get("description")))
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
                    log(_("error processing update %s: %r") % (uid, ex))
                    for l in traceback.format_exc().splitlines()[-6:]:
                        log("  " + l)


def main():
    global TOKEN
    path, conf = load_conf()
    if not path:
        log(_("Telegram is not configured (telegram.env is missing). Run: prama-agent telegram setup"))
        return EXIT_CONFIG
    TOKEN = conf.get("TELEGRAM_BOT_TOKEN", "")
    chat = conf.get("TELEGRAM_CHAT_ID", "")
    if not re.match(r"^[0-9]+:[A-Za-z0-9_-]{20,}$", TOKEN) or not re.match(r"^-?[0-9]+$", chat):
        log(_("telegram.env is incomplete or invalid (%s). Run: prama-agent telegram setup") % path)
        return EXIT_CONFIG
    self_path = os.environ.get("SELF_PATH", "")
    if not self_path or not os.access(self_path, os.X_OK):
        log(_("SELF_PATH does not point to an executable prama-agent: %r") % self_path)
        return EXIT_CONFIG
    base = os.environ.get("PRAMA_TG_API_BASE") or "https://api.telegram.org"
    bot = Bot(Api(TOKEN, base), Prama(self_path), chat, conf.get("TELEGRAM_USER_ID", ""))
    log(_("starting (config %s, tmux server %s)") % (path, os.environ.get("PRAMA_TMUX_SOCKET", "prama")))
    try:
        bot.loop()
    except KeyboardInterrupt:
        log(_("stopped"))
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
