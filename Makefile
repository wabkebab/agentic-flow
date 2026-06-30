# Stack profile — the ONE place this project's build/test/run commands live.
# Humans, agents, hooks, and CI all call these targets; never hard-code raw commands
# elsewhere. See METHODOLOGY.md §1 and CLAUDE.md "Stack profile".
#
# Fill in each recipe for your stack (TS/Node examples shown commented). Until a recipe is
# filled in it no-ops with a reminder, so a fresh scaffold doesn't block work — but note the
# Stop hook's `make check` gate is only meaningful once `check` is real.

.PHONY: check test test-one build run help

help:           ## list available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-10s %s\n",$$1,$$2}'

check:          ## fast sanity gate: type-check + lint (seconds). Run by the Stop hook.
	@echo "TODO: define 'check' (type-check + lint) in the Makefile."
#	npx tsc --noEmit
#	npx eslint .

test:           ## full test suite
	@echo "TODO: define 'test' in the Makefile."
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
