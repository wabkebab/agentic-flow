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

.PHONY: check test test-one build run help

help:           ## list available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-10s %s\n",$$1,$$2}'

check:          ## fast sanity gate: harness checks + your type-check/lint. Run by the Stop hook.
	@for f in scripts/*.sh scripts/hooks/*.sh scripts/lib/*.sh; do bash -n "$$f" || exit 1; done
	@scripts/docs-index.sh --check
	@scripts/check-payload-manifest.sh
	@scripts/check-action-pins.sh
	@scripts/check-memory-index.sh
	@scripts/self-test.sh --fast
#	npm run typecheck && npm run lint

test:           ## full test suite
	@scripts/self-test.sh --full
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck is required for 'make test' — install it (brew install shellcheck / apt-get install shellcheck)." >&2; exit 1; }
	@shellcheck scripts/*.sh scripts/hooks/*.sh scripts/lib/*.sh
	@echo "TODO: add your stack's test suite to 'test' in the Makefile."
#	npm run test:run

test-one:       ## one targeted test:  make test-one F=path/to/file
	@echo "TODO: define 'test-one' (uses F=...). Got F=$(F)"
#	npx vitest run $(F)

build:          ## production build
	@echo "TODO: define 'build' in the Makefile."
#	npm run build

run:            ## start the app locally (for /run and /verify)
	@echo "TODO: define 'run' in the Makefile."
#	npm run dev
