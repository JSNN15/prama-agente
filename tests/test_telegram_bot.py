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

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("telegram_bot", os.path.join(HERE, "..", "lib", "telegram_bot.py"))
tb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tb)

COORD = "prama-coordinator-claude-backend"
FLEET = [
    {"session": COORD, "agent": "claude", "zone": "backend", "role": "coordinator", "state": "READY",
     "model": "opus", "parent": "operator", "queue": 0,
     "quota": {"five_hour_pct": 12, "seven_day_pct": 40, "context_pct": 8}},
    {"session": "prama-agy-backend", "agent": "agy", "zone": "backend", "role": "executor",
     "state": "WORKING", "model": "gemini-3.8-flash-high", "parent": COORD, "queue": 2,
     "quota": {"five_hour_pct": 93, "seven_day_pct": 7, "context_pct": 13}},
    {"session": "prama-claude-landing", "agent": "claude", "zone": "landing", "role": "executor",
     "state": "READY", "model": "", "parent": "operator", "queue": 0, "quota": None},
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
        if args[0] == "swarm" and args[1] == "stop":
            self.fleet_rows = [d for d in self.fleet_rows if d["zone"] != args[2]]
            return 0, "", ""
        if args[0] == "swarm":
            if not any(d["role"] == "coordinator" and d["zone"] == args[1] for d in self.fleet_rows):
                self.fleet_rows.append({"session": "prama-coordinator-claude-" + args[1], "agent": "claude",
                                        "zone": args[1], "role": "coordinator", "state": "READY",
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
        self.assertEqual(list(teams), ["backend"])
        coord, members = teams["backend"]
        self.assertEqual(coord["session"], COORD)
        self.assertEqual([m["session"] for m in members], ["prama-agy-backend"])

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
    def test_teams_view_lists_only_coordinated_zones(self):
        bot, api, _ = make_bot()
        bot.on_text("/equipos")
        self.assertIn("backend", api.last_text())
        self.assertNotIn("landing", api.last_text())
        self.assertIn("T:backend", api.last_kb())

    def test_team_view_shows_members_quota_and_actions(self):
        bot, api, _ = make_bot()
        bot.on_callback("T:backend", 7)
        text, kb = api.last_text(), api.last_kb()
        self.assertIn("prama-agy-backend", text)
        self.assertIn("5h 93%", text)
        self.assertIn("✉ 2", text)
        self.assertIn("t:" + COORD, kb)
        self.assertIn("tx:backend", kb)
        self.assertIn("ta:backend:agy", kb)

    def test_create_team_selects_coordinator_for_the_objective(self):
        bot, api, prama = make_bot(fleet=[])
        bot.on_callback("wn:landing:agy:2", 7)
        self.assertIn(["swarm", "landing", "--workers", "agy:2", "--no-open"], prama.ran)
        self.assertEqual(bot.selected, "prama-coordinator-claude-landing")
        self.assertIn("objetivo", api.last_text())

    def test_add_worker_to_existing_team(self):
        bot, api, prama = make_bot()
        bot.on_callback("ta:backend:agy", 7)
        self.assertIn(["swarm", "backend", "--workers", "agy:1", "--no-open"], prama.ran)
        self.assertIn("sumado", api.last_text())

    def test_team_input_is_validated(self):
        bot, api, prama = make_bot()
        for data in ("wn:nope:agy:1", "wn:backend:rm -rf:1", "wn:backend:agy:9", "wn:backend:agy"):
            bot.on_callback(data, 7)
            self.assertIn("⚠️", api.last_text(), data)
        self.assertFalse([a for a in prama.ran if a[0] == "swarm"])

    def test_close_team_asks_first(self):
        bot, api, prama = make_bot()
        bot.selected = "prama-agy-backend"
        bot.on_callback("tx:backend", 7)
        self.assertIn("¿Cerrar el equipo", api.last_text())
        self.assertFalse([a for a in prama.ran if a[:2] == ["swarm", "stop"]])
        bot.on_callback("TX:backend", 7)
        self.assertIn(["swarm", "stop", "backend"], prama.ran)
        self.assertEqual(bot.selected, "")

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


if __name__ == "__main__":
    sys.exit(unittest.main(verbosity=1))
