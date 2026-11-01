#!/usr/bin/env bash
# tools/screenshots.sh — rebuilds the README screenshots (docs/img/*.png) from a demo fleet.
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
#
# Runs prama on a private tmux server with mock agents (copies of bash named claude / agy that
# print a canned screen), a demo plan with a few hours of history and a team memory, captures the
# screens with their colors and renders them with headless Chromium (tools/ansi2html.py).
# Needs: tmux, python3, chromium (or google-chrome). Usage: tools/screenshots.sh [en|es|all]
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT="$REPO/docs/img"
# Snap Chromium only reads non-hidden directories of $HOME.
WORK=${SHOTS_WORK:-$HOME/prama-shots}
CHROME=$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)
[ -n "$CHROME" ] || { echo "chromium not found" >&2; exit 1; }
LANGS=${1:-all}; [ "$LANGS" = all ] && LANGS="en es"
SOCK=prama-demo UI=prama-demo-ui

rm -rf "$WORK"; mkdir -p "$WORK"/{bin,interp,screens,repos,state,cfg,html} "$OUT"
export XDG_CONFIG_HOME="$WORK/cfg" PRAMA_STATE_HOME="$WORK/state" PRAMA_TMUX_SOCKET=$SOCK PRAMA_SYSTEM_CONFIG_DIR=
export PRAMA_HOOKS=0 PRAMA_WATCHDOG=0 PRAMA_DISCOVER_ROOTS="$WORK/repos" COLORTERM=truecolor TERM=xterm-256color
export PATH="$WORK/bin:$PATH" GIT_AUTHOR_NAME=demo GIT_AUTHOR_EMAIL=demo@example.com GIT_COMMITTER_NAME=demo GIT_COMMITTER_EMAIL=demo@example.com
BIN="$REPO/bin/prama-agent"
cleanup() { tmux -L $SOCK kill-server 2>/dev/null || true; tmux -L $UI kill-server 2>/dev/null || true; }
trap cleanup EXIT

# Mock agents: the process is named like the CLI, prints its canned screen and waits.
for a in claude agy; do
  cp "$(command -v bash)" "$WORK/interp/$a"
  printf '#!%s\ncat "%s/screens/${PRAMA_SESSION:-none}" 2>/dev/null\nwhile :; do sleep 3600; done\n' "$WORK/interp/$a" "$WORK" > "$WORK/bin/$a"
  chmod +x "$WORK/bin/$a"
done
for r in backend web; do
  mkdir -p "$WORK/repos/$r"; git -C "$WORK/repos/$r" init -q -b main
  echo "# $r" > "$WORK/repos/$r/README.md"; git -C "$WORK/repos/$r" add . ; git -C "$WORK/repos/$r" commit -qm init
done

screens() {   # canned agent screens, in the demo language
  if [ "$1" = es ]; then
    cat > "$WORK/screens/prama-backend-sec-coord" <<'EOF'
> Plan listo: 5 tareas, T1→T2→T3, T4 en paralelo. Delego T2 a agy y T4 a agy-2.
● Bash(prama-agent bus assign prama-backend-sec-agy "Rota las llaves JWT" --task T2)
  ↳ ✔ Tarea entregada en vivo a 'prama-backend-sec-agy'.
● Reviso la rama de T1: git diff main...prama/sec/agy — 3 archivos, tests verdes.
✻ Thinking… (esc to interrupt)
EOF
    cat > "$WORK/screens/prama-backend-sec-agy" <<'EOF'
> [T2] Rota las llaves JWT: rotación diaria, sin downtime.
● Editando src/auth/keys.py · agregando KeyRing con dos llaves activas
● Running… pytest tests/auth -q   (esc to interrupt)
EOF
  else
    cat > "$WORK/screens/prama-backend-sec-coord" <<'EOF'
> Plan ready: 5 tasks, T1→T2→T3, T4 in parallel. Delegating T2 to agy and T4 to agy-2.
● Bash(prama-agent bus assign prama-backend-sec-agy "Rotate the JWT keys" --task T2)
  ↳ ✔ Task delivered live to 'prama-backend-sec-agy'.
● Reviewing T1's branch: git diff main...prama/sec/agy — 3 files, tests green.
✻ Thinking… (esc to interrupt)
EOF
    cat > "$WORK/screens/prama-backend-sec-agy" <<'EOF'
> [T2] Rotate the JWT keys: daily rotation, no downtime.
● Editing src/auth/keys.py · adding a KeyRing with two active keys
● Running… pytest tests/auth -q   (esc to interrupt)
EOF
  fi
  printf '> ready\n' > "$WORK/screens/prama-backend-sec-agy-2"
  printf '> ready\n' > "$WORK/screens/prama-backend-docs-agy"
  printf '> ready\n' > "$WORK/screens/prama-backend-docs-coord"
  printf '> ready\n' > "$WORK/screens/prama-claude-web"
}

fleet() {   # fleet <lang>
  local L=$1 C=prama-backend-sec-coord
  tmux -L $SOCK kill-server 2>/dev/null || true
  sleep 0.5
  rm -rf "$WORK/state" "$WORK/cfg"; mkdir -p "$WORK/state" "$WORK/cfg"
  export PRAMA_LANG=$L
  screens "$L"
  "$BIN" zones add backend "$WORK/repos/backend" "API" >/dev/null
  "$BIN" zones add web "$WORK/repos/web" "Landing" >/dev/null
  if [ "$L" = es ]; then
    "$BIN" swarm backend --team sec --workers agy:2 --no-open --task "Endurecer la autenticación" >/dev/null 2>&1
    "$BIN" swarm backend --team docs --workers agy:1 --no-open --task "Documentar la API pública" >/dev/null 2>&1
    local t=("Auditar el flujo de login" "Rotar llaves JWT" "Documentar la política de sesiones" "Rate limiting en /login" "Pruebas de carga del login")
  else
    "$BIN" swarm backend --team sec --workers agy:2 --no-open --task "Harden authentication" >/dev/null 2>&1
    "$BIN" swarm backend --team docs --workers agy:1 --no-open --task "Document the public API" >/dev/null 2>&1
    local t=("Audit the login flow" "Rotate the JWT keys" "Document the session policy" "Rate limiting on /login" "Load tests for login")
  fi
  "$BIN" claude web --bg >/dev/null 2>&1
  export PRAMA_SESSION=$C
  "$BIN" plan add "${t[0]}" --est 45m --scope "src/auth/flow/**" --accept "pytest tests/auth" >/dev/null
  "$BIN" plan add "${t[1]}" --deps T1 --est 90m --scope "src/auth/keys.py" --accept "pytest tests/auth/test_keys.py" >/dev/null
  "$BIN" plan add "${t[2]}" --deps T2 --est 30m --scope "docs/**" >/dev/null
  "$BIN" plan add "${t[3]}" --est 2h --scope "src/api/limits/**" --accept "k6 run load/login.js" >/dev/null
  "$BIN" plan add "${t[4]}" --deps T4 --est 1h >/dev/null
  "$BIN" plan start T1 --owner prama-backend-sec-agy >/dev/null 2>&1
  "$BIN" plan "done" T1 --evidence "pytest tests/auth: 14 passed @3f9c2a1" >/dev/null 2>&1
  "$BIN" plan start T4 --owner prama-backend-sec-agy-2 >/dev/null 2>&1
  "$BIN" plan replan "$([ "$L" = es ] && echo 'La auditoría pide rate limiting antes de las pruebas de carga' || echo 'The audit asks for rate limiting before load tests')" >/dev/null 2>&1
  "$BIN" plan start T2 --owner prama-backend-sec-agy >/dev/null 2>&1
  "$BIN" plan set T2 progress=60 >/dev/null 2>&1
  "$BIN" plan set T4 progress=35 >/dev/null 2>&1
  "$BIN" memory add "$([ "$L" = es ] && echo 'Las llaves JWT rotan a diario; nunca loguearlas' || echo 'JWT keys rotate daily; never log them')" >/dev/null 2>&1
  unset PRAMA_SESSION
  # Give the plan a few hours of history (demo data).
  python3 - "$WORK/state/plans/backend/sec" <<'PY'
import sys, time, os
d = sys.argv[1]; now = int(time.time()); h = 3600
times = {"T1": (now-3*h, now-3*h+600, now-2*h+300, now-2*h+300), "T2": (now-3*h, now-95*60, now-60, ""),
         "T3": (now-3*h, "", now-3*h, ""), "T4": (now-3*h, now-2*h, now-120, ""), "T5": (now-3*h, "", now-3*h, "")}
rows = []
for line in open(os.path.join(d, "tasks"), encoding="utf-8"):
    f = line.rstrip("\n").split("\x1f")
    c, s, u, dn = times[f[0]]
    f[6], f[7], f[8], f[9] = str(c), str(s), str(u), str(dn)
    rows.append("\x1f".join(f))
open(os.path.join(d, "tasks"), "w", encoding="utf-8").write("\n".join(rows) + "\n")
log = [l.split("|", 1) for l in open(os.path.join(d, "log"), encoding="utf-8")]
out = []
for _ts, rest in log:
    t = now - 3*h
    if "|replan|" in rest: t = now - 100*60
    elif "|done|T1|" in rest: t = now - 2*h + 300
    elif "|doing|T2|" in rest: t = now - 95*60
    elif "|doing|T4|" in rest: t = now - 2*h
    out.append("%d|%s" % (t, rest))
open(os.path.join(d, "log"), "w", encoding="utf-8").writelines(out)
PY
  sleep 1.5
}

shot() {   # shot <name> <title> <cols> <rows> <command> [keys…]
  local name=$1 title=$2 cols=$3 rows=$4 cmd=$5; shift 5
  tmux -L $UI kill-server 2>/dev/null || true
  sleep 0.5
  tmux -L $UI -f /dev/null new-session -d -x "$cols" -y "$rows" \
    "env HOSTNAME=server-01 PRAMA_LANG=$PRAMA_LANG COLORTERM=truecolor TERM=xterm-256color bash -c '$cmd; sleep 60'"
  tmux -L $UI set -g default-terminal xterm-256color 2>/dev/null || true
  sleep 3
  local k; for k in "$@"; do tmux -L $UI send-keys "$k"; sleep 1; done
  sleep 1
  tmux -L $UI capture-pane -p -e > "$WORK/html/$name.ansi"
  python3 "$REPO/tools/ansi2html.py" "$title" < "$WORK/html/$name.ansi" > "$WORK/html/$name.html"
  _render "$WORK/html/$name.html" "$OUT/$name.png" $(( cols * 9 + 100 )) $(( rows * 20 + 120 ))
}

_render() {   # _render <html> <png> <width> <height>  (rendered under $WORK, then copied)
  local tmp; tmp="$WORK/png/$(basename "$2")"
  mkdir -p "$WORK/png"
  "$CHROME" --headless=new --no-sandbox --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --default-background-color=00000000 --window-size="$3,$4" --screenshot="$tmp" "file://$1" >/dev/null 2>&1 || true
  if [ -s "$tmp" ]; then cp "$tmp" "$2"; echo "  $2"; else echo "  FAILED: $2" >&2; fi
}

for L in $LANGS; do
  echo "== $L"
  fleet "$L"
  P="$BIN"
  shot "menu-$L" "prama-agent" 120 32 "$P" Down Down
  shot "teams-$L" "prama-agent · teams" 110 22 "$P" m Down Enter
  shot "plan-board-$L" "prama-agent plan" 150 14 "$P plan backend --team sec watch"
  shot "plan-timeline-$L" "prama-agent plan timeline" 110 17 "$P plan backend --team sec watch" v
  shot "help-$L" "prama-agent · ?" 100 38 "$P" '?'
  shot "phone-$L" "Termius · iPhone" 46 40 "$P"
  "$P" plan backend --team sec html "$WORK/html/plan-$L.html" >/dev/null
  _render "$WORK/html/plan-$L.html" "$OUT/plan-html-$L.png" 1240 940
done
PRAMA_LANG=en
shot "themes" "prama-agent theme" 104 14 "$BIN theme"
echo "done: $OUT"
