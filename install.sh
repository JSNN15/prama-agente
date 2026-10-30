#!/usr/bin/env bash
# prama-agent installer
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
#
# One line (clones the repository, then installs):
#   curl -fsSL https://raw.githubusercontent.com/JSNN15/prama-agente/main/install.sh | bash
#   … | sudo bash                    system-wide: /opt/prama-agent, /usr/local/bin, /etc/prama-agent
#   … | PRAMA_REF=v6.1.0 bash        a specific release
# From a clone:
#   sudo make install                system-wide
#   make install                     current user: ~/.local/bin, ~/.config/prama-agent
set -euo pipefail

REPO_URL="${PRAMA_REPO_URL:-https://github.com/JSNN15/prama-agente.git}"
if [ "$(id -u)" = 0 ]; then
  PREFIX="${PREFIX:-/usr/local}" CONF_DIR="${CONF_DIR:-/etc/prama-agent}" DEST="${PRAMA_HOME:-/opt/prama-agent}"
else
  PREFIX="${PREFIX:-$HOME/.local}" CONF_DIR="${CONF_DIR:-$HOME/.config/prama-agent}" DEST="${PRAMA_HOME:-$HOME/.local/share/prama-agent}"
fi

say()  { printf ' \033[38;2;52;211;153m✔\033[0m %s\n' "$1"; }
note() { printf ' \033[38;2;251;191;36m▲\033[0m %s\n' "$1"; }
fail() { printf ' \033[38;2;248;113;113m✖\033[0m %s\n' "$1" >&2; exit 1; }

(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || fail "Se requiere bash >= 4.4 / bash >= 4.4 is required"

# ── Bootstrap: piped from curl (no repository next to this script) ─────────
src=${BASH_SOURCE[0]:-}
if [ -z "$src" ] || [ ! -f "$(dirname "$src")/bin/prama-agent" ]; then
  command -v git >/dev/null 2>&1 || fail "git es necesario / git is required (apt install git)"
  if [ -d "$DEST/.git" ]; then
    git -C "$DEST" fetch -q --tags origin && git -C "$DEST" checkout -q "${PRAMA_REF:-main}" \
      && { [ -n "${PRAMA_REF:-}" ] || git -C "$DEST" pull -q --ff-only; } || fail "No se pudo actualizar $DEST"
    say "Repositorio actualizado: $DEST"
  else
    mkdir -p "$(dirname "$DEST")"
    git clone -q ${PRAMA_REF:+--branch "$PRAMA_REF"} "$REPO_URL" "$DEST" || fail "No se pudo clonar $REPO_URL"
    say "Repositorio clonado en $DEST"
  fi
  exec env PREFIX="$PREFIX" CONF_DIR="$CONF_DIR" bash "$DEST/install.sh"
fi

REPO_DIR="$(cd "$(dirname "$src")" && pwd)"
VERSION=$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$REPO_DIR/bin/prama-agent")

# ── Dependencies ─────────────────────────────────────────────────────────────
missing=()
for dep in tmux git; do command -v "$dep" >/dev/null 2>&1 || missing+=("$dep"); done
[ ${#missing[@]} -eq 0 ] || fail "Faltan dependencias / missing: ${missing[*]} (sudo apt install ${missing[*]})"
optional=()
for dep in jq fzf less; do command -v "$dep" >/dev/null 2>&1 || optional+=("$dep"); done
[ ${#optional[@]} -eq 0 ] || note "Recomendado / recommended: sudo apt install ${optional[*]}  (jq: hooks y cuota)"

# ── Install ──────────────────────────────────────────────────────────────────
chmod +x "$REPO_DIR"/bin/*
mkdir -p "$PREFIX/bin"
for b in prama-agent prama-agy prama-claude; do
  ln -sf "$REPO_DIR/bin/$b" "$PREFIX/bin/$b"
done
say "Comandos enlazados en $PREFIX/bin"
case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) note "$PREFIX/bin no está en tu PATH: echo 'export PATH=\"$PREFIX/bin:\$PATH\"' >> ~/.bashrc" ;;
esac

(umask 077 && mkdir -p "$CONF_DIR")
if [ ! -f "$CONF_DIR/config.env" ]; then
  install -m 644 "$REPO_DIR/config/config.env.example" "$CONF_DIR/config.env"
  say "Configuración creada: $CONF_DIR/config.env (zonas: repos git bajo /opt y \$HOME)"
else
  say "Configuración existente conservada: $CONF_DIR/config.env"
fi
if [ ! -f "$CONF_DIR/providers.env" ]; then
  install -m 600 "$REPO_DIR/config/providers.env.example" "$CONF_DIR/providers.env"
  say "Plantilla de proveedores creada (0600): $CONF_DIR/providers.env"
fi

comp_dir="${BASH_COMPLETION_USER_DIR:-/etc/bash_completion.d}"
[ "$(id -u)" = 0 ] || comp_dir="${BASH_COMPLETION_USER_DIR:-$HOME/.local/share/bash-completion/completions}"
if mkdir -p "$comp_dir" 2>/dev/null && [ -w "$comp_dir" ]; then
  "$REPO_DIR/bin/prama-agent" completion bash > "$comp_dir/prama-agent" 2>/dev/null && say "Autocompletado bash instalado"
fi

agents=()
for a in claude agy; do command -v "$a" >/dev/null 2>&1 && agents+=("$a"); done
[ ${#agents[@]} -gt 0 ] || note "No se encontró ningún agente: instala Claude Code (claude) o Antigravity CLI (agy)."

say "prama-agent v$VERSION instalado."
printf '\n   prama-agent doctor          verifica el entorno\n   prama-agent                 abre la interfaz\n   prama-agent update          actualiza a la última versión\n\n'
