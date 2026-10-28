#!/usr/bin/env bash
# prama-agent installer
# Licensed under the Apache License, Version 2.0
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
CONF_DIR="${CONF_DIR:-/etc/prama-agent}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

chmod +x "$REPO_DIR/bin/prama-agent" "$REPO_DIR/bin/prama-agy" "$REPO_DIR/bin/prama-claude"

mkdir -p "$PREFIX/bin" "$CONF_DIR"

ln -sf "$REPO_DIR/bin/prama-agent"  "$PREFIX/bin/prama-agent"
ln -sf "$REPO_DIR/bin/prama-agy"    "$PREFIX/bin/prama-agy"
ln -sf "$REPO_DIR/bin/prama-claude" "$PREFIX/bin/prama-claude"

if [ ! -f "$CONF_DIR/config.env" ]; then
  cp "$REPO_DIR/config/config.env.example" "$CONF_DIR/config.env"
  echo "[prama-agent] Created default config at $CONF_DIR/config.env"
fi

if [ ! -f "$CONF_DIR/providers.env" ]; then
  cp "$REPO_DIR/config/providers.env.example" "$CONF_DIR/providers.env"
  chmod 600 "$CONF_DIR/providers.env"
  echo "[prama-agent] Created provider profile template at $CONF_DIR/providers.env"
fi

echo "[prama-agent] Installed v4.0.0 binaries into $PREFIX/bin"
