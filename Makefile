# Stack profile — the ONE place this project's build/test/run commands live.
# Humans, agents, hooks, and CI all call these targets; never hard-code raw commands
# elsewhere. See METHODOLOGY.md §1 and CLAUDE.md "Stack profile".

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

test-one:       ## one harness group: make test-one F=controller [S=launch,ledger]
	@[ -n "$(F)" ] || { echo "usage: make test-one F=export|contracts|hooks|plan-to-issues|lifecycle|upgrade|stations|controller [S=launch,ledger,recovery,ship,andon (controller only)]" >&2; exit 2; }
	@if [ "$(origin S)" = "command line" ]; then \
	  [ "$(F)" = controller ] || { echo "S= is valid only with F=controller" >&2; exit 2; }; \
	  scripts/self-test.sh --only "$(F)" --scenario "$(S)"; \
	else scripts/self-test.sh --only "$(F)"; fi

.PHONY: ship-gate
ship-gate:      ## full regression suite in a fresh exported layout (close-out / CI)
	@scripts/self-test.sh --ship-gate

build:          ## production build
	@set -e; tmp=$$(mktemp -d "$${TMPDIR:-/tmp}/agentic-flow-build.XXXXXX"); \
	trap 'rm -rf "$$tmp"' EXIT; \
	scripts/export.sh --dry-run "$$tmp" >/dev/null; \
	echo "export dry-run ok: $$tmp"

run:            ## start the app locally (for /run and /verify)
	@scripts/doctor.sh

# Commit verification setup and assertion failure signature.
RED_FIRST_SIGNATURE := ^self-test failed:[[:space:]]
.PHONY: verify-prepare
verify-prepare:
	@:
