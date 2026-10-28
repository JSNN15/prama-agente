PREFIX ?= /usr/local
CONF_DIR ?= /etc/prama-agent

.PHONY: all install uninstall test lint

all: lint test

lint:
	bash -n bin/prama-agent
	bash -n bin/prama-agy
	bash -n bin/prama-claude
	bash -n lib/core.sh
	bash -n lib/agents.sh
	bash -n lib/roles.sh
	bash -n lib/telegram.sh
	bash -n lib/bus.sh
	bash -n lib/tui.sh
	bash -n install.sh
	bash -n tests/test_prama_agent.sh

test: lint
	bash tests/test_prama_agent.sh

install:
	PREFIX="$(PREFIX)" CONF_DIR="$(CONF_DIR)" bash ./install.sh

uninstall:
	rm -f "$(PREFIX)/bin/prama-agent" "$(PREFIX)/bin/prama-agy" "$(PREFIX)/bin/prama-claude"
