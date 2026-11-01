#!/usr/bin/env python3
# Unit tests for lib/telegram_bot.py — stdlib only, no network, no tmux.
# A fake Telegram API records every call; a fake CLI answers the JSON listings and records the
# commands the bot runs, so each test checks what the bot would send and execute.
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
import importlib.util
import os
import sys
import tempfile
import unittest
import warnings

HERE = os.path.dirname(os.path.abspath(__file__))
# The tests below check the Spanish texts; the English ones switch with tb.set_lang("en").
os.environ["PRAMA_UI_LANG"] = "es"
spec = importlib.util.spec_from_file_location("telegram_bot", os.path.join(HERE, "..", "lib", "telegram_bot.py"))
tb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tb)

COORD = "prama-coordinator-claude-backend"
SEC = "prama-backend-seguridad-coord"
FLEET = [
    {"session": COORD, "agent": "claude", "zone": "backend", "team": "principal", "role": "coordinator", "state": "READY",
     "model": "opus", "parent": "operator", "queue": 0,
     "quota": {"five_hour_pct": 12, "seven_day_pct": 40, "context_pct": 8}},
    {"session": "prama-agy-backend", "agent": "agy", "zone": "backend", "team": "principal", "role": "executor",
     "state": "WORKING", "model": "gemini-3.8-flash-high", "parent": COORD, "queue": 2,
     "quota": {"five_hour_pct": 93, "seven_day_pct": 7, "context_pct": 13}},
    {"session": "prama-claude-landing", "agent": "claude", "zone": "landing", "role": "executor",
     "state": "READY", "model": "", "parent": "operator", "queue": 0, "quota": None},
    {"session": SEC, "agent": "claude", "zone": "backend", "team": "seguridad", "role": "coordinator",
     "state": "READY", "model": "opus", "parent": "operator", "queue": 0, "quota": None},
]


class FakeApi:
    def __init__(self):
        self.calls = []

    def call(self, method, payload=None, timeout=20):
        self.calls.append((method, payload or {}))
        return {"ok": True, "result": {"message_id": 7}}

    def last_text(self):
        return [p for m, p in self.calls if m in ("sendMessage", "editMessageText")][-1]["text"]

    def last_kb(self):
        p = [p for m, p in self.calls if m in ("sendMessage", "editMessageText")][-1]
        return [b["callback_data"] for row in p.get("reply_markup", {}).get("inline_keyboard", []) for b in row]


class FakePrama(tb.Prama):
    def __init__(self, fleet=None):
        super().__init__("/nonexistent")
        self.fleet_rows = list(FLEET if fleet is None else fleet)
        self.ran = []

    def run(self, args, timeout=30):
        self.ran.append(list(args))
        if args[:3] == ["fleet", "status", "--json"]:
            import json
            return 0, json.dumps(self.fleet_rows), ""
        if args[:2] == ["agents", "--json"]:
            return 0, '[{"name":"claude"},{"name":"agy"}]', ""
        if args[:2] == ["zones", "--json"]:
            return 0, '[{"name":"backend"},{"name":"landing"}]', ""
        if args[:2] == ["sessions", "--json"]:
            import json
            return 0, json.dumps([{"name": d["session"], "role": d["role"], "state": d["state"],
                                   "agent": d["agent"], "zone": d["zone"]} for d in self.fleet_rows]), ""
        if args[:3] == ["feedback", "list", "--json"]:
            return 0, '[{"id":"20261031-120000-abcd","kind":"bug","from":"%s","count":3,"summary":"fleet <model> fails"}]' % COORD, ""
        if args[:2] == ["memory", "show"]:
            return 0, '[{"scope":"zone","ts":"2026-11-01 10:00","by":"operator","text":"API uses <FastAPI>"},' \
                      '{"scope":"team","ts":"2026-11-01 11:00","by":"%s","text":"JWT rotates daily"}]' % SEC, ""
        if args[:2] == ["worktree", "status"]:
            return 0, '[{"session":"prama-backend-seguridad-agy","branch":"prama/seguridad/agy","ahead":2,' \
                      '"behind":1,"uncommitted":0,"last":"abc1234 fix <auth>"}]', ""
        if len(args) >= 3 and args[0] == "plan" and args[2] == "json":
            return 0, '{"zone":"backend","team":"seguridad","rev":2,"tasks":[' \
                      '{"id":"T1","status":"done","owner":"prama-backend-seguridad-agy","title":"Audit <login>","evidence":"ok","flags":""},' \
                      '{"id":"T2","status":"doing","owner":"prama-backend-seguridad-agy","title":"Rotate keys","progress":"40","flags":"stale"}]}', ""
        if args[:3] == ["telegram", "alerts", "--porcelain"]:
            return 0, "important|0\n", ""
        if args[0] == "swarm" and args[1] == "stop":
            gone = {args[2]} | {d["session"] for d in self.fleet_rows if d.get("parent") == args[2]}
            self.fleet_rows = [d for d in self.fleet_rows if d["session"] not in gone]
            return 0, "", ""
        if args[0] == "swarm":
            zone, team = args[1], args[args.index("--team") + 1]
            if not any(d["role"] == "coordinator" and d["zone"] == zone and d.get("team") == team
                       for d in self.fleet_rows):
                self.fleet_rows.append({"session": "prama-%s-%s-coord" % (zone, team), "agent": "claude",
                                        "zone": zone, "team": team, "role": "coordinator", "state": "READY",
                                        "parent": "operator", "quota": None})
            return 0, "", ""
        return 0, "", ""


def make_bot(fleet=None):
    api, prama = FakeApi(), FakePrama(fleet)
    return tb.Bot(api, prama, 100, 200), api, prama


class Helpers(unittest.TestCase):
    def test_quota_text(self):
        self.assertEqual(tb.quota_text({"five_hour_pct": 12, "seven_day_pct": 40, "context_pct": None}),
                         "5h 12% · 7d 40%")
        self.assertEqual(tb.quota_text(None), "")

    def test_quota_peak(self):
        self.assertEqual(tb.quota_peak({"five_hour_pct": 93, "seven_day_pct": 7}), 93)
        self.assertEqual(tb.quota_peak({}), 0)

    def test_teams_of(self):
        teams = tb.teams_of(FLEET)
        self.assertEqual(sorted(teams), sorted([COORD, SEC]))
        coord, members = teams[COORD]
        self.assertEqual([m["session"] for m in members], ["prama-agy-backend"])
        self.assertEqual(teams[SEC][1], [])

    def test_team_label(self):
        teams = tb.teams_of(FLEET)
        self.assertEqual(tb.team_label(teams[COORD][0]), "backend")
        self.assertEqual(tb.team_label(teams[SEC][0]), "backend · seguridad")

    def test_parse_conf_never_executes(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write('TELEGRAM_BOT_TOKEN="1:abc"\n$(touch /tmp/x)=1\nexport TELEGRAM_CHAT_ID=5\n# c\n')
        try:
            self.assertEqual(tb.parse_conf(f.name), {"TELEGRAM_BOT_TOKEN": "1:abc", "TELEGRAM_CHAT_ID": "5"})
        finally:
            os.unlink(f.name)

    def test_callback_data_limit(self):
        bot, _, _ = make_bot()
        long = "T:" + "x" * 100
        data = bot.cb(long)
        self.assertLessEqual(len(data.encode()), tb.CB_MAX)
        self.assertEqual(bot.cb_cache[int(data[1:])], long)


class Teams(unittest.TestCase):
    def test_teams_view_lists_every_team_of_a_zone(self):
        bot, api, _ = make_bot()
        bot.on_text("/equipos")
        text, kb = api.last_text(), api.last_kb()
        self.assertIn("backend · seguridad", text)
        self.assertNotIn("landing", text)
        self.assertIn("T:" + COORD, kb)
        self.assertIn("T:" + SEC, kb)

    def test_team_view_shows_members_quota_and_actions(self):
        bot, api, _ = make_bot()
        bot.on_callback("T:" + COORD, 7)
        text, kb = api.last_text(), api.last_kb()
        self.assertIn("prama-agy-backend", text)
        self.assertIn("5h 93%", text)
        self.assertIn("✉ 2", text)
        self.assertIn("t:" + COORD, kb)
        self.assertIn("tx:" + COORD, kb)
        self.assertIn("ta:%s:agy" % COORD, kb)

    def test_new_team_offers_existing_and_new_names(self):
        bot, api, _ = make_bot()
        bot.on_callback("wz:backend", 7)
        kb = api.last_kb()
        self.assertIn("wn:backend:principal", kb)        # existing: add agents
        self.assertIn("wn:backend:seguridad", kb)
        self.assertIn("wn:backend:docs", kb)             # suggestion: new team
        self.assertIn("wo:backend", kb)                  # type another name

    def test_create_named_team_selects_its_coordinator(self):
        bot, api, prama = make_bot()
        bot.on_callback("wg:backend:docs:agy:2", 7)
        self.assertIn(["swarm", "backend", "--team", "docs", "--workers", "agy:2", "--no-open"], prama.ran)
        self.assertEqual(bot.selected, "prama-backend-docs-coord")
        self.assertIn("objetivo", api.last_text())

    def test_typed_team_name(self):
        bot, api, prama = make_bot()
        bot.on_callback("wo:backend", 7)
        bot.on_text("Pagos Web")
        self.assertIn("wg:backend:pagos-web:agy:1", api.last_kb())
        bot.on_callback("wo:backend", 7)
        bot.on_text("../etc")
        self.assertIn("inválido", api.last_text())
        self.assertFalse([a for a in prama.ran if a[0] == "swarm"])

    def test_add_worker_to_existing_team(self):
        bot, api, prama = make_bot()
        bot.on_callback("ta:%s:agy" % SEC, 7)
        self.assertIn(["swarm", "backend", "--team", "seguridad", "--workers", "agy:1", "--no-open"], prama.ran)
        self.assertIn("sumado", api.last_text())

    def test_team_input_is_validated(self):
        bot, api, prama = make_bot()
        for data in ("wg:nope:docs:agy:1", "wg:backend:docs:rm -rf:1", "wg:backend:docs:agy:9",
                     "wg:backend:Bad Name:agy:1", "wg:backend:docs:agy"):
            bot.on_callback(data, 7)
            self.assertIn("⚠️", api.last_text(), data)
        self.assertFalse([a for a in prama.ran if a[0] == "swarm"])

    def test_close_one_team_asks_first_and_keeps_the_others(self):
        bot, api, prama = make_bot()
        bot.selected = "prama-agy-backend"
        bot.on_callback("tx:" + COORD, 7)
        self.assertIn("¿Cerrar el equipo", api.last_text())
        self.assertFalse([a for a in prama.ran if a[:2] == ["swarm", "stop"]])
        bot.on_callback("TX:" + COORD, 7)
        self.assertIn(["swarm", "stop", COORD], prama.ran)
        self.assertEqual(bot.selected, "")
        self.assertIn("backend · seguridad", api.last_text())

    def test_quota_view_flags_agents_near_the_limit(self):
        bot, api, _ = make_bot()
        bot.on_text("/cuota")
        text = api.last_text()
        self.assertIn("prama-agy-backend</code> ⚠️", text)
        self.assertIn("sin datos aún", text)


class Reports(unittest.TestCase):
    def test_reports_are_listed_escaped(self):
        bot, api, _ = make_bot()
        bot.on_text("/reportes")
        text = api.last_text()
        self.assertIn("20261031-120000-abcd", text)
        self.assertIn("(×3)", text)
        self.assertIn("fleet &lt;model&gt; fails", text)


class Security(unittest.TestCase):
    def test_unauthorized_chat_is_ignored(self):
        bot, api, prama = make_bot()
        bot.handle({"message": {"chat": {"id": 999}, "from": {"id": 200}, "text": "/equipos",
                                "date": 9e12}})
        self.assertEqual(api.calls, [])
        self.assertEqual(prama.ran, [])

    def test_send_to_unknown_session_is_rejected(self):
        bot, api, prama = make_bot()
        bot.on_text("/send ;rm hola")
        self.assertIn("⚠️", api.last_text())
        self.assertFalse([a for a in prama.ran if a[0] == "send"])


class AlertsDaemonsMemory(unittest.TestCase):
    def test_alerts_view_lists_blocked_and_quota_with_actions(self):
        fleet = FLEET + [{"session": "prama-agy-landing", "agent": "agy", "zone": "landing", "role": "executor",
                          "state": "BLOCKED", "blocked_reason": "login", "blocked_detail": "Sign in <again>",
                          "parent": "operator", "queue": 3, "quota": None}]
        bot, api, _ = make_bot(fleet)
        bot.on_text("/alertas")
        text = api.last_text()
        self.assertIn("prama-agy-landing", text)
        self.assertIn("bloqueado (login)", text)
        self.assertIn("&lt;again&gt;", text)
        self.assertIn("cuota al 93%", text)              # prama-agy-backend
        self.assertNotIn(COORD + "</code>", text)
        self.assertIn("r:prama-agy-landing", api.last_kb())

    def test_menu_counts_agents_that_need_attention(self):
        bot, api, _ = make_bot()
        bot.on_text("/menu")
        self.assertIn("1 agente(s) necesitan atención", api.last_text())
        self.assertIn("A", api.last_kb())

    def test_daemon_queue_takes_the_next_text(self):
        fleet = FLEET + [{"session": "prama-daemon-agy-backend", "agent": "agy", "zone": "backend",
                          "role": "daemon", "state": "DAEMON", "parent": "operator", "queue": 1, "quota": None}]
        bot, api, prama = make_bot(fleet)
        bot.on_text("/daemons")
        self.assertIn("prama-daemon-agy-backend", api.last_text())
        bot.on_callback("dq:prama-daemon-agy-backend", 7)
        bot.on_text("revisar dependencias")
        self.assertIn(["bus", "assign", "prama-daemon-agy-backend", "revisar dependencias"], prama.ran)
        self.assertIn("En cola", api.last_text())

    def test_team_memory_view_and_note(self):
        bot, api, prama = make_bot()
        bot.on_callback("T:" + SEC, 7)
        self.assertIn("M:" + SEC, api.last_kb())
        bot.on_callback("M:" + SEC, 7)
        self.assertIn("JWT rotates daily", api.last_text())
        self.assertIn("&lt;FastAPI&gt;", api.last_text())
        bot.on_callback("Mn:" + SEC, 7)
        bot.on_text("usar Argon2")
        self.assertIn(["memory", "add", SEC, "usar Argon2"], prama.ran)

    def test_team_plan_view(self):
        bot, api, _ = make_bot()
        bot.on_callback("P:" + SEC, 7)
        text = api.last_text()
        self.assertIn("r2", text)
        self.assertIn("1 de 2 listas", text)
        self.assertIn("&lt;login&gt;", text)
        self.assertIn("sin actividad", text)

    def test_team_branches_view(self):
        bot, api, _ = make_bot()
        bot.on_callback("T:" + SEC, 7)
        self.assertIn("B:" + SEC, api.last_kb())
        bot.on_callback("B:" + SEC, 7)
        text = api.last_text()
        self.assertIn("prama/seguridad/agy", text)
        self.assertIn("2 por integrar", text)
        self.assertIn("&lt;auth&gt;", text)

    def test_notification_level_and_mute(self):
        bot, api, prama = make_bot()
        bot.on_text("/avisos")
        self.assertIn("lo importante", api.last_text())
        bot.on_callback("Nl:alerts", 7)
        self.assertIn(["telegram", "alerts", "alerts"], prama.ran)
        bot.on_text("/silencio 8h")
        self.assertIn(["telegram", "mute", "8h"], prama.ran)
        bot.on_callback("Nl:rm -rf", 7)
        self.assertFalse([a for a in prama.ran if a[:2] == ["telegram", "alerts"] and a[2:] == ["rm -rf"]])


class Language(unittest.TestCase):
    def setUp(self):
        tb.set_lang("en")

    def tearDown(self):
        tb.set_lang("es")

    def test_english_teams_view(self):
        bot, api, _ = make_bot()
        bot.on_text("/teams")
        text, kb = api.last_text(), api.last_kb()
        self.assertIn("👥 Teams", text)
        self.assertIn("backend · seguridad", text)        # team names are data, never translated
        self.assertIn("T:" + COORD, kb)                   # callback data is unchanged
        self.assertNotIn("Equipos", text)

    def test_spanish_commands_still_work_in_english(self):
        bot, api, _ = make_bot()
        bot.on_text("/equipos")
        self.assertIn("👥 Teams", api.last_text())
        bot.on_text("/cuota")
        self.assertIn("Quota per agent", api.last_text())
        self.assertIn("no data yet", api.last_text())
        bot.on_text("/reports")
        self.assertIn("bug reports", api.last_text())

    def test_english_help_and_command_menu(self):
        bot, api, _ = make_bot()
        bot.on_text("/help")
        self.assertIn("/teams — teams", api.last_text())
        self.assertEqual([c["command"] for c in bot.command_menu()][5:8], ["teams", "quota", "reports"])
        tb.set_lang("es")
        bot.on_text("/help")
        self.assertIn("/equipos — equipos", api.last_text())
        menu = bot.command_menu()
        self.assertEqual([c["command"] for c in menu][5:8], ["equipos", "cuota", "reportes"])
        self.assertEqual(menu[0]["description"], "Menú principal")

    def test_english_team_creation_progress(self):
        bot, api, _ = make_bot()
        bot.on_callback("wg:backend:docs:agy:2", 7)
        sent = [p["text"] for m, p in api.calls if m in ("sendMessage", "editMessageText")]
        self.assertIn("⏳ Creating team <b>docs</b> in <b>backend</b> with <b>2 agy</b>…", sent)
        self.assertIn("Type the goal", api.last_text())

    def test_unknown_language_falls_back_to_english(self):
        tb.set_lang("xx")
        self.assertEqual(tb._("<i>No active agents.</i>"), "<i>No active agents.</i>")
        tb.set_lang("../es")
        self.assertEqual(tb.UI_LANG, "en")

    def test_every_message_id_has_a_spanish_translation(self):
        spec_c = importlib.util.spec_from_file_location("i18n_check", os.path.join(HERE, "..", "tools", "i18n_check.py"))
        ic = importlib.util.module_from_spec(spec_c)
        spec_c.loader.exec_module(ic)
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", ResourceWarning)   # the checker reads files without `with`
            ids, catalog = ic.py_ids(), ic.py_catalog("es")
        self.assertGreater(len(ids), 100)
        errors, unused = ic.check("python", ids, catalog, "es", True)
        self.assertEqual((errors, unused), (0, 0))


if __name__ == "__main__":
    sys.exit(unittest.main(verbosity=1))
