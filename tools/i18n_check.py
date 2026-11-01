#!/usr/bin/env python3
# tools/i18n_check.py — every message id used in the code has a translation, with the same
# printf placeholders. Bash: _t / _tv with a literal msgid, catalogs lib/lang/<lang>/*.sh.
# Python (Telegram bridge): _("…") with catalogs lib/lang/<lang>/telegram_bot.json.
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
"""Usage: tools/i18n_check.py [--unused]   (exit 1 on missing translations or placeholder errors)"""
import glob
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANGS = ["es"]
SH_FILES = ["bin/prama-agent"] + sorted(glob.glob("lib/*.sh"))
PY_FILES = ["lib/telegram_bot.py"]

SQ = r"'([^']*)'"
DQ = r'"((?:[^"\\$`]|\\.)*)"'
SH_RE = re.compile(r"(?<![\w-])_t(?:v\s+[A-Za-z_][A-Za-z0-9_\[\]$]*)?\s+(?:" + SQ + "|" + DQ + r")")
SH_DYN = re.compile(r"(?<![\w-])_t(?:v\s+\S+)?\s+\"[^\"]*\$")
PY_RE = re.compile(r"(?<![\w.])_\(\s*(?:'((?:[^'\\]|\\.)*)'|\"((?:[^\"\\]|\\.)*)\")\s*[,)]")
PH_RE = re.compile(r"%[-+ #0]*\d*(?:\.\d+)?[sdifxXc%]|\{[a-z_0-9]*\}")


def unescape_dq(s):
    return re.sub(r'\\([\\"$`])', r"\1", s)


def placeholders(s):
    return sorted(p for p in PH_RE.findall(s) if p != "%%")


def sh_ids():
    ids, dyn = {}, []
    for f in SH_FILES:
        for n, line in enumerate(open(os.path.join(ROOT, f), encoding="utf-8"), 1):
            if line.lstrip().startswith("#"):
                continue
            for m in SH_RE.finditer(line):
                mid = m.group(1) if m.group(1) is not None else unescape_dq(m.group(2))
                ids.setdefault(mid, f"{f}:{n}")
            if SH_DYN.search(line):
                dyn.append(f"{f}:{n}")
    return ids, dyn


def py_ids():
    ids = {}
    for f in PY_FILES:
        src = open(os.path.join(ROOT, f), encoding="utf-8").read()
        for m in PY_RE.finditer(src):
            raw = m.group(1) if m.group(1) is not None else m.group(2)
            mid = bytes(raw, "utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8")
            ids.setdefault(mid, f"{f}:{src.count(chr(10), 0, m.start()) + 1}")
    return ids


def sh_catalog(lang):
    script = (f'source lib/i18n.sh; PRAMA_LANG={lang}; I18N_LOADED=; i18n_init; '
              'for k in "${!I18N[@]}"; do printf "%s\\0%s\\0" "$k" "${I18N[$k]}"; done')
    out = subprocess.run(["bash", "-c", script], cwd=ROOT, capture_output=True, check=True).stdout
    parts = out.decode("utf-8").split("\0")[:-1]
    return dict(zip(parts[0::2], parts[1::2]))


def py_catalog(lang):
    path = os.path.join(ROOT, "lib", "lang", lang, "telegram_bot.json")
    return json.load(open(path, encoding="utf-8")) if os.path.exists(path) else {}


def check(kind, ids, cat, lang, show_unused):
    errors = 0
    for mid, where in sorted(ids.items(), key=lambda kv: kv[1]):
        if mid not in cat:
            print(f"{where}: [{lang}] missing translation: {mid!r}")
            errors += 1
        elif placeholders(mid) != placeholders(cat[mid]):
            print(f"{where}: [{lang}] placeholders differ: {mid!r} -> {cat[mid]!r}")
            errors += 1
    unused = sorted(set(cat) - set(ids))
    if show_unused:
        for mid in unused:
            print(f"[{lang}] {kind} catalog entry not found as a literal in the code: {mid!r}")
    return errors, len(unused)


def main():
    show_unused = "--unused" in sys.argv
    sids, dyn = sh_ids()
    pids = py_ids()
    errors = 0
    for lang in LANGS:
        e, u1 = check("bash", sids, sh_catalog(lang), lang, show_unused)
        errors += e
        e, u2 = check("python", pids, py_catalog(lang), lang, show_unused)
        errors += e
    for where in dyn:
        print(f"{where}: msgid with a $ expansion (use a %s placeholder)")
        errors += 1
    print(f"i18n: {len(sids)} bash + {len(pids)} python message ids, {errors} error(s)"
          + ("" if show_unused else f", {u1 + u2} catalog entries only used dynamically (--unused lists them)"))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
