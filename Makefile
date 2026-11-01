# prama-agent — developer and install targets
# Without PREFIX/CONF_DIR, install.sh picks system paths as root (/usr/local, /etc/prama-agent)
# and user paths otherwise (~/.local, ~/.config/prama-agent).
SHELL_FILES := bin/prama-agent bin/prama-agy bin/prama-claude lib/*.sh lib/lang/*/*.sh install.sh tests/*.sh .github/scripts/*.sh tools/*.sh

.PHONY: all install uninstall test test-matrix lint i18n screenshots

all: lint test

lint:
	@for f in $(SHELL_FILES); do bash -n "$$f" || exit 1; done
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck -S warning -x $(SHELL_FILES) && echo "shellcheck: OK"; \
	else echo "shellcheck no instalado: solo se verificó la sintaxis"; fi
	@python3 -m py_compile lib/telegram_bot.py tests/test_telegram_bot.py tools/i18n_check.py tools/ansi2html.py && echo "py_compile: OK"
	@python3 tools/i18n_check.py

# README screenshots (docs/img) from a demo fleet; needs chromium
screenshots:
	bash tools/screenshots.sh all

# Translation coverage, listing catalog entries the code no longer uses literally.
i18n:
	@python3 tools/i18n_check.py --unused

test: lint
	python3 tests/test_telegram_bot.py
	bash tests/test_prama_agent.sh

# The CI matrix (tmux 3.2a / 3.3a / 3.4) in local containers: make test-matrix
test-matrix:
	@for img in ubuntu:22.04 debian:12 ubuntu:24.04; do \
	  echo "== $$img"; docker run --rm -v "$$PWD:/src:ro" $$img bash /src/.github/scripts/ci-container.sh || exit 1; \
	done

install:
	$(if $(PREFIX),PREFIX="$(PREFIX)") $(if $(CONF_DIR),CONF_DIR="$(CONF_DIR)") bash ./install.sh

uninstall:
	-prama-agent fleet hooks uninstall >/dev/null 2>&1
	@p="$(PREFIX)"; [ -n "$$p" ] || { [ "$$(id -u)" = 0 ] && p=/usr/local || p="$$HOME/.local"; }; \
	rm -f "$$p/bin/prama-agent" "$$p/bin/prama-agy" "$$p/bin/prama-claude" \
	      /etc/bash_completion.d/prama-agent "$$HOME/.local/share/bash-completion/completions/prama-agent"; \
	echo "prama-agent desinstalado de $$p/bin (la configuración y el estado se conservan)"
