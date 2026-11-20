# MEMORY.md — index

One line per entry, read every session; bodies in `docs/memory/` are read only when a line
below looks relevant. Format and lifecycle: [`README.md`](README.md).

Keep this short. `make check` fails past 50 lines here, and past 200 a reading harness starts
dropping entries silently. When an entry keeps proving itself, promote it to a `CLAUDE.md`
Gotchas bullet or a `make check` assertion and delete the line.

| Entry | Type | Description |
|-------|------|-------------|
| `manifest-validation-duplicated` | trap | `merge-policy` is validated compatibility metadata, not executable per-file policy; removal needs a versioned migration for old upgraders. |
| `docs-index-stage-allowlist` | trap | Any `.md` under `docs/` outside the four lifecycle stages fails `make check`; a new subtree must join the skip list in the same commit. |
| `close-out-needs-pr-first` | trap | `Implementation PR` must be a real pull URL, so the final close-out commit waits for the human's push and PR; check for the PR first. |
| `shellcheck-follow-sources-oom` | trap | `shellcheck -x` on a file that sources the test groups analyses them all in one process and OOM-kills the CI runner; keep `source=/dev/null` on group imports. |
| `cp-restores-interactively` | trap | `cp` prompts on overwrite and `-f` may not suppress it, so a `cp`-based fixture restore can silently fail; stage first and restore with `git checkout --`. |
