#!/usr/bin/env bash
# Runs the full test suite inside a clean distro container, as an unprivileged user.
# Used by .github/workflows/ci.yml (matrix of images) and runnable locally:
#   docker run --rm -v "$PWD:/src:ro" debian:12 bash /src/.github/scripts/ci-container.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends bash git tmux jq python3 procps util-linux less ca-certificates >/dev/null
printf 'bash %s · %s · python %s · %s\n' "${BASH_VERSION}" "$(tmux -V)" "$(python3 -c 'import platform; print(platform.python_version())')" \
  "$(. /etc/os-release && echo "$PRETTY_NAME")"
src=${1:-/src}
useradd -m ci
cp -a "$src" /home/ci/prama-agent
chown -R ci:ci /home/ci/prama-agent
su ci -c 'cd ~/prama-agent && git config --global --add safe.directory "*" && python3 tests/test_telegram_bot.py && bash tests/test_prama_agent.sh'
