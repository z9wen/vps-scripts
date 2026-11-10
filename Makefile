SHELL := bash

SOURCES := $(shell find src -type f -name '*.sh' | sort)
TEST_FILES := $(shell find tests -maxdepth 1 -type f -name 'test_*.sh' | sort)
SCRIPT_FILES := build.sh $(shell find tests -type f -name '*.sh' | sort)

.PHONY: build check syntax lint test e2e

check: syntax lint test

# CI writes the committed installer; this is for local use.
build:
	@./build.sh

syntax:
	@for file in $(SCRIPT_FILES) $(SOURCES) xray-install.sh; do \
		bash -n "$$file"; \
	done
	@echo "Bash syntax OK"

# The modules share globals across files, so they are linted as one freshly
# assembled installer rather than file by file.
lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		bundle=$$(mktemp -d) && trap 'rm -rf "$$bundle"' EXIT && \
		XRAY_BUILD_OUTPUT="$$bundle/xray-install.sh" ./build.sh >/dev/null && \
		shellcheck --shell=bash --severity=warning $(SCRIPT_FILES) "$$bundle/xray-install.sh"; \
	else \
		echo "shellcheck not installed; skipped local lint"; \
	fi

test:
	@for file in $(TEST_FILES); do \
		echo "==> $$file"; \
		bash "$$file" || exit 1; \
	done

# Needs Docker and network access; downloads the latest stable and pre-release cores.
e2e:
	@tests/e2e/run.sh
