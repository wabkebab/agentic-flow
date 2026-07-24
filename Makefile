# Stack profile — the ONE place this project's build/test/run commands live.
# Humans, agents, hooks, and CI all call these targets; never hard-code raw commands
# elsewhere. See METHODOLOGY.md §1 and CLAUDE.md "Stack profile".

.PHONY: check test test-one build run help

help:           ## list available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-10s %s\n",$$1,$$2}'

check:          ## fast sanity gate: harness checks + your type-check/lint. Run by the Stop hook.
	@for f in scripts/*.sh scripts/hooks/*.sh; do bash -n "$$f" || exit 1; done
	@scripts/docs-index.sh --check
	@scripts/check-action-pins.sh
	@scripts/self-test.sh

test:           ## full test suite
	@scripts/self-test.sh
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck scripts/*.sh scripts/hooks/*.sh; else echo "shellcheck not found; skipping."; fi

test-one:       ## one targeted test:  make test-one F=path/to/file
	@echo "No finer-grained harness test runner yet; running offline suite. F=$(F)"
	@scripts/self-test.sh

build:          ## production build
	@tmp=$$(mktemp -d "$${TMPDIR:-/tmp}/agentic-flow-build.XXXXXX"); \
	trap 'rm -rf "$$tmp"' EXIT; \
	scripts/export.sh --dry-run "$$tmp" >/dev/null; \
	echo "export dry-run ok: $$tmp"

run:            ## start the app locally (for /run and /verify)
	@scripts/doctor.sh
