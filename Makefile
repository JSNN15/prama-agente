# prama-agent — developer and install targets
# Without PREFIX/CONF_DIR, install.sh picks system paths as root (/usr/local, /etc/prama-agent)
# and user paths otherwise (~/.local, ~/.config/prama-agent).
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
	$(if $(PREFIX),PREFIX="$(PREFIX)") $(if $(CONF_DIR),CONF_DIR="$(CONF_DIR)") bash ./install.sh

uninstall:
	-prama-agent fleet hooks uninstall >/dev/null 2>&1
	@p="$(PREFIX)"; [ -n "$$p" ] || { [ "$$(id -u)" = 0 ] && p=/usr/local || p="$$HOME/.local"; }; \
	rm -f "$$p/bin/prama-agent" "$$p/bin/prama-agy" "$$p/bin/prama-claude" \
	      /etc/bash_completion.d/prama-agent "$$HOME/.local/share/bash-completion/completions/prama-agent"; \
	echo "prama-agent desinstalado de $$p/bin (la configuración y el estado se conservan)"
