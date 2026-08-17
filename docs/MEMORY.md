# MEMORY.md — index

One line per entry, read every session; bodies in `docs/memory/` are read only when a line
below looks relevant. Format and lifecycle: [`README.md`](README.md).

Keep this short. `make check` fails past 50 lines here, and past 200 a reading harness starts
dropping entries silently. When an entry keeps proving itself, promote it to a `CLAUDE.md`
Gotchas bullet or a `make check` assertion and delete the line.

| Entry | Type | Description |
|-------|------|-------------|
| `manifest-validation-duplicated` | trap | Legal `merge-policy` values are hard-coded in both `payload-apply.sh` and `doctor.sh`; nothing asserts they agree, and `make check` cannot catch a mismatch — only `make test`. |
| `docs-index-stage-allowlist` | trap | Any `.md` under `docs/` outside the four lifecycle stages fails `make check`; a new subtree must join the skip list in the same commit. |
| `cp-restores-interactively` | trap | `cp` prompts on overwrite and `-f` may not suppress it, so a `cp`-based fixture restore can silently fail; stage first and restore with `git checkout --`. |
