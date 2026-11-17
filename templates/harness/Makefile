# Stack profile — the ONE place this project's build/test/run commands live.
# Humans, agents, hooks, and CI all call these targets; never hard-code raw commands
# elsewhere. See METHODOLOGY.md §1 and CLAUDE.md "Stack profile".
#
# `check` ships working — harness sanity (script syntax, docs-index freshness, action-pin
# structure, fast self-test) — and is what the Stop hook runs, so keep it fast. Extend it with
# your stack's type-check + lint. `test` ships with shellcheck over the harness scripts and
# REQUIRES it: a lint that skips when the tool is absent is green for the wrong reason.
# The remaining recipes no-op with a reminder until filled in for your stack (TS/Node
# examples shown commented), so a fresh scaffold doesn't block work.

# BEGIN SHARED SHELL GATE
.PHONY: check test test-one build run help

help:           ## list available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-10s %s\n",$$1,$$2}'

check:          ## fast sanity gate: harness checks + your type-check/lint. Run by the Stop hook.
	@scripts/shell-inventory.sh --syntax
	@scope=$$(scripts/shell-inventory.sh --scope-state docs) || exit 1; if [ "$$scope" = active ]; then scripts/docs-index.sh --check; fi
	@scripts/check-payload-manifest.sh
	@scripts/check-harness-sync.sh
	@scripts/check-memory-index.sh
	@scripts/check-action-pins.sh
	@scripts/self-test.sh --fast

test:           ## full test suite
	@scripts/self-test.sh --full
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck is required for 'make test' — install it (brew install shellcheck / apt-get install shellcheck)." >&2; exit 1; }
	@scripts/shell-inventory.sh --lint
# END SHARED SHELL GATE
#	npm run test:run

test-one:       ## one harness group: make test-one F=controller [S=launch,ledger]
	@[ -n "$(F)" ] || { echo "usage: make test-one F=export|contracts|hooks|plan-to-issues|lifecycle|upgrade|stations|controller [S=launch,ledger,recovery,ship,andon (controller only)]" >&2; exit 2; }
	@if [ "$(origin S)" != undefined ]; then \
	  [ "$(F)" = controller ] || { echo "S= is valid only with F=controller" >&2; exit 2; }; \
	  scripts/self-test.sh --only "$(F)" --scenario "$(S)"; \
	else scripts/self-test.sh --only "$(F)"; fi

build:          ## production build
	@echo "TODO: define 'build' in the Makefile."
#	npm run build

run:            ## start the app locally (for /run and /verify)
	@echo "TODO: define 'run' in the Makefile."
#	npm run dev

# Commit verification setup and assertion failure signature.
RED_FIRST_SIGNATURE := ^self-test failed:[[:space:]]
.PHONY: verify-prepare
verify-prepare:
	@:
