PREFIX ?= /usr/local
CONF_DIR ?= /etc/prama-agent
SHELL_FILES := bin/prama-agent bin/prama-agy bin/prama-claude lib/*.sh install.sh tests/*.sh

.PHONY: all install uninstall test lint

all: lint test

lint:
	@for f in $(SHELL_FILES); do bash -n "$$f" || exit 1; done
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck -S warning -x $(SHELL_FILES) && echo "shellcheck: OK"; \
	else echo "shellcheck no instalado: solo se verificó la sintaxis"; fi
	@if [ -f lib/telegram_bot.py ]; then python3 -m py_compile lib/telegram_bot.py && echo "py_compile: OK"; fi

test: lint
	bash tests/test_prama_agent.sh

install:
	PREFIX="$(PREFIX)" CONF_DIR="$(CONF_DIR)" bash ./install.sh

uninstall:
	rm -f "$(PREFIX)/bin/prama-agent" "$(PREFIX)/bin/prama-agy" "$(PREFIX)/bin/prama-claude" /etc/bash_completion.d/prama-agent
