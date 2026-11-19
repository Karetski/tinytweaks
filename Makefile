# TinyTweaks developer tasks. `make check` is the full local gate; CI runs the same steps.

LUA      ?= luajit
LUACHECK ?= luacheck
PYTHON   ?= python3
WOW_DIR  ?= /Applications/World of Warcraft/_forever_

ADDON   := TinyTweaks
TOC     := $(ADDON).toc
VERSION := $(shell sed -n 's/^\#\# Version: *//p' $(TOC) | tr -d '\r')
FILES   := $(shell grep -v '^\#' $(TOC) | grep -v '^[[:space:]]*$$' | tr -d '\r' | tr '\\' '/')
EXTRAS  := LICENSE README.md $(wildcard CHANGELOG.md)

.PHONY: check test test-unit test-integration test-invariants lint lint-optional static bench dist link ingame-report ingame-wait clean help

help:
	@echo "make check             full local gate: lint (if installed), static checks, tests"
	@echo "make test              unit + integration + invariant tests"
	@echo "make test-unit         unit tests"
	@echo "make test-integration  integration tests (simulated client)"
	@echo "make test-invariants   performance/behavior invariants"
	@echo "make lint              luacheck (required)"
	@echo "make static            TOC, taint-contract and skill checks"
	@echo "make bench             micro benchmarks"
	@echo "make dist              dist/$(ADDON)-$(VERSION).zip"
	@echo "make link              symlink this repo and the dev recorder into \$$WOW_DIR/Interface/AddOns"
	@echo "make ingame-report     report on the last in-game session (errors, taint.log, saved vs. live state)"
	@echo "make ingame-wait       wait for the game to log out (or for SAVES=n reloads/logouts), then report"

check: lint-optional static test

test:
	$(LUA) tests/run.lua -q unit integration invariants

test-unit:
	$(LUA) tests/run.lua unit

test-integration:
	$(LUA) tests/run.lua integration

test-invariants:
	$(LUA) tests/run.lua invariants

lint:
	$(LUACHECK) .

lint-optional:
	@if command -v $(LUACHECK) >/dev/null 2>&1; then \
		$(LUACHECK) . ; \
	else \
		echo "warning: $(LUACHECK) not installed; skipping lint (CI runs it)"; \
	fi

static:
	$(PYTHON) tools/check.py

bench:
	$(LUA) tests/run.lua bench

dist:
	@rm -rf dist/stage && mkdir -p dist/stage/$(ADDON)
	@for f in $(TOC) $(FILES) $(EXTRAS); do \
		mkdir -p "dist/stage/$(ADDON)/$$(dirname $$f)" && cp "$$f" "dist/stage/$(ADDON)/$$f" || exit 1; \
	done
	@rm -f dist/$(ADDON)-$(VERSION).zip
	@cd dist/stage && zip -qr ../$(ADDON)-$(VERSION).zip $(ADDON)
	@rm -rf dist/stage
	@echo "dist/$(ADDON)-$(VERSION).zip"

# Links the addon and the dev-only recorder (dev/!TinyTweaksDev), which records errors, blocked
# actions and frame state for `make ingame-report`. Neither link overwrites a real folder.
link:
	@if [ ! -d "$(WOW_DIR)/Interface/AddOns" ]; then \
		echo "error: $(WOW_DIR)/Interface/AddOns not found; pass WOW_DIR=..."; exit 1; \
	fi; \
	for pair in "$(ADDON)|$(CURDIR)" "!TinyTweaksDev|$(CURDIR)/dev/!TinyTweaksDev"; do \
		name=$${pair%%|*}; source=$${pair#*|}; target="$(WOW_DIR)/Interface/AddOns/$$name"; \
		if [ -L "$$target" ]; then \
			ln -sfn "$$source" "$$target"; \
		elif [ -e "$$target" ]; then \
			echo "error: $$target exists and is not a symlink; remove it first"; exit 1; \
		else \
			ln -s "$$source" "$$target"; \
		fi; \
		echo "$$target -> $$source"; \
	done

ingame-report:
	@WOW_DIR="$(WOW_DIR)" LUA="$(LUA)" tools/ingame.sh report

ingame-wait:
	@WOW_DIR="$(WOW_DIR)" LUA="$(LUA)" SAVES="$(SAVES)" tools/ingame.sh wait

clean:
	rm -rf dist
