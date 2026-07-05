# Adoption Checklist

Use this after exporting `agentic-flow` into a target project and before committing the
harness.

## Required tools

- `bash`
- `make`
- `git`
- `jq`
- `gh`
- `git-claude`, unless the project opts out of Claude commits
- `git-codex`, unless the project is Claude-only or otherwise opts out of Codex execution

Recommended: `shellcheck`.

## Checklist

1. Run `scripts/export.sh /path/to/target-project` from this scaffold repo.
2. Fill in the target project's `Makefile` targets: `check`, `test`, `test-one`, `build`,
   and `run`.
3. Update `CLAUDE.md` with the project name, Stack profile, Architecture, Gotchas, and any
   opt-outs.
4. Update `AGENTS.md` with the project name and any executor-specific opt-outs.
5. Confirm `.claude/settings.json` wires `scripts/hooks/check-gate.sh`,
   `scripts/hooks/block-git-add-all.sh`, and `scripts/hooks/block-push.sh`.
6. Run `scripts/docs-index.sh --check`.
7. Run `scripts/doctor.sh --check`.
8. Add `make check`, `make test`, and `scripts/docs-index.sh --check` to CI where practical.

`scripts/doctor.sh` is the machine-readable version of this checklist. It reports missing
tools, required files, hook wiring, placeholder Make targets, and stale docs indexes.
