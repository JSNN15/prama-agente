#!/usr/bin/env bash
# prama-agent installer
# Licensed under the Apache License, Version 2.0
#
#   sudo make install          → system-wide (/usr/local/bin, /etc/prama-agent)
#   make install PREFIX=~/.local CONF_DIR=~/.config/prama-agent   → current user only
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
CONF_DIR="${CONF_DIR:-/etc/prama-agent}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$REPO_DIR/bin/prama-agent")

say()  { printf ' \033[38;2;52;211;153m✔\033[0m %s\n' "$1"; }
note() { printf ' \033[38;2;251;191;36m▲\033[0m %s\n' "$1"; }

(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || { echo "Se requiere bash >= 4.4" >&2; exit 1; }
command -v tmux >/dev/null 2>&1 || note "tmux no está instalado: es obligatorio (apt install tmux)."
command -v git  >/dev/null 2>&1 || note "git no está instalado: necesario para zonas y worktrees."

chmod +x "$REPO_DIR"/bin/*
mkdir -p "$PREFIX/bin"
for b in prama-agent prama-agy prama-claude; do
  ln -sf "$REPO_DIR/bin/$b" "$PREFIX/bin/$b"
done
say "Binarios enlazados en $PREFIX/bin"

(umask 077 && mkdir -p "$CONF_DIR")
if [ ! -f "$CONF_DIR/config.env" ]; then
  install -m 644 "$REPO_DIR/config/config.env.example" "$CONF_DIR/config.env"
  say "Configuración creada: $CONF_DIR/config.env"
else
  say "Configuración existente conservada: $CONF_DIR/config.env"
fi
if [ ! -f "$CONF_DIR/providers.env" ]; then
  install -m 600 "$REPO_DIR/config/providers.env.example" "$CONF_DIR/providers.env"
  say "Plantilla de proveedores creada (0600): $CONF_DIR/providers.env"
fi

if [ -d "${BASH_COMPLETION_USER_DIR:-/etc/bash_completion.d}" ] && [ -w "${BASH_COMPLETION_USER_DIR:-/etc/bash_completion.d}" ]; then
  "$REPO_DIR/bin/prama-agent" completion bash > "${BASH_COMPLETION_USER_DIR:-/etc/bash_completion.d}/prama-agent" 2>/dev/null \
    && say "Autocompletado bash instalado"
fi

say "prama-agent v$VERSION instalado. Siguiente paso: prama-agent doctor"
