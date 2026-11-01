#!/usr/bin/env python3
# tools/ansi2html.py — renders a terminal capture (tmux capture-pane -e) as an HTML page that looks
# like a terminal window, for the README screenshots (tools/screenshots.sh turns it into a PNG).
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
"""Usage: ansi2html.py <title> [--bg '#0f172a'] [--fg '#e2e8f0'] < capture.txt > page.html"""
import html
import re
import sys

PALETTE16 = ["#1e293b", "#f87171", "#34d399", "#fbbf24", "#60a5fa", "#c084fc", "#22d3ee", "#e2e8f0",
             "#64748b", "#fca5a5", "#6ee7b7", "#fde68a", "#93c5fd", "#d8b4fe", "#67e8f9", "#f8fafc"]


def xterm256(n):
    if n < 16:
        return PALETTE16[n]
    if n < 232:
        n -= 16
        steps = [0, 95, 135, 175, 215, 255]
        return "#%02x%02x%02x" % (steps[n // 36], steps[(n // 6) % 6], steps[n % 6])
    g = 8 + (n - 232) * 10
    return "#%02x%02x%02x" % (g, g, g)


SGR = re.compile(r"\x1b\[([0-9;:]*)m")
# Everything but colors (SGR, "m"): cursor moves, OSC titles and hyperlinks.
OTHER = re.compile(r"\x1b\[[0-9;?]*[A-Za-ln-z]|\x1b\][^\x07]*(\x07|\x1b\\)")


def render(text):
    out, state = [], {"fg": None, "bg": None, "bold": False, "dim": False, "rev": False}
    for line in text.split("\n"):
        line = OTHER.sub("", line)
        pos, spans = 0, []
        for m in SGR.finditer(line):
            spans.append((line[pos:m.start()], dict(state)))
            codes = [c for c in re.split("[;:]", m.group(1)) if c != ""] or ["0"]
            i = 0
            while i < len(codes):
                c = int(codes[i])
                if c == 0:
                    state.update(fg=None, bg=None, bold=False, dim=False, rev=False)
                elif c == 1:
                    state["bold"] = True
                elif c == 2:
                    state["dim"] = True
                elif c == 7:
                    state["rev"] = True
                elif c in (22,):
                    state.update(bold=False, dim=False)
                elif c == 27:
                    state["rev"] = False
                elif 30 <= c <= 37:
                    state["fg"] = PALETTE16[c - 30]
                elif 90 <= c <= 97:
                    state["fg"] = PALETTE16[c - 90 + 8]
                elif 40 <= c <= 47:
                    state["bg"] = PALETTE16[c - 40]
                elif 100 <= c <= 107:
                    state["bg"] = PALETTE16[c - 100 + 8]
                elif c in (39,):
                    state["fg"] = None
                elif c in (49,):
                    state["bg"] = None
                elif c in (38, 48) and i + 1 < len(codes):
                    key = "fg" if c == 38 else "bg"
                    if codes[i + 1] == "5" and i + 2 < len(codes):
                        state[key] = xterm256(int(codes[i + 2]))
                        i += 2
                    elif codes[i + 1] == "2" and i + 4 < len(codes):
                        state[key] = "#%02x%02x%02x" % tuple(int(x) for x in codes[i + 2:i + 5])
                        i += 4
                i += 1
            pos = m.end()
        spans.append((line[pos:], dict(state)))
        row = []
        for txt, st in spans:
            if not txt:
                continue
            fg, bg = st["fg"], st["bg"]
            if st["rev"]:
                fg, bg = bg or "var(--bg)", fg or "var(--fg)"
            css = []
            if fg:
                css.append("color:%s" % fg)
            if bg:
                css.append("background:%s" % bg)
            if st["bold"]:
                css.append("font-weight:700")
            if st["dim"]:
                css.append("opacity:.6")
            esc = html.escape(txt)
            row.append('<span style="%s">%s</span>' % (";".join(css), esc) if css else esc)
        out.append("".join(row))
    while out and not re.sub(r"<[^>]+>", "", out[-1]).strip():
        out.pop()
    return "\n".join(out)


def main():
    args = sys.argv[1:]
    title = args[0] if args else "prama-agent"
    bg, fg = "#0b1220", "#e2e8f0"
    if "--bg" in args:
        bg = args[args.index("--bg") + 1]
    if "--fg" in args:
        fg = args[args.index("--fg") + 1]
    body = render(sys.stdin.read())
    sys.stdout.write("""<!doctype html><html><head><meta charset="utf-8"><style>
:root{--bg:%s;--fg:%s}
html,body{margin:0;background:transparent}
.win{display:inline-block;margin:28px;border-radius:12px;overflow:hidden;background:var(--bg);
 box-shadow:0 24px 60px rgba(2,6,23,.55),0 0 0 1px rgba(148,163,184,.18)}
.bar{height:34px;background:linear-gradient(#1f2937,#111827);display:flex;align-items:center;padding:0 14px;gap:8px;
 font:600 13px/1 ui-sans-serif,system-ui,sans-serif;color:#94a3b8}
.dot{width:12px;height:12px;border-radius:50%%;display:inline-block}
.t{margin-left:12px;letter-spacing:.02em}
pre{margin:0;padding:14px 18px 18px;color:var(--fg);font:15px/1.32 "DejaVu Sans Mono","Noto Sans Mono","Liberation Mono",monospace;
 font-variant-ligatures:none;white-space:pre}
</style></head><body><div class="win"><div class="bar"><span class="dot" style="background:#f87171"></span>
<span class="dot" style="background:#fbbf24"></span><span class="dot" style="background:#34d399"></span>
<span class="t">%s</span></div><pre>%s</pre></div></body></html>
""" % (bg, fg, html.escape(title), body))


if __name__ == "__main__":
    main()
