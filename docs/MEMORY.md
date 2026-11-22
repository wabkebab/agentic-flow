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
| `close-out-needs-pr-first` | trap | Plans with an already-open PR finish on the old two-push path; new PRs resolve from final approval. |
| `rebasing-approved-plan` | trap | Rebasing after approval can orphan the approved brief and step SHAs. Merge base updates into the plan branch. |
| `shellcheck-follow-sources-oom` | trap | `shellcheck -x` on a file that sources the test groups analyses them all in one process and OOM-kills the CI runner; keep `source=/dev/null` on group imports. |
| `cp-restores-interactively` | trap | `cp` prompts on overwrite and `-f` may not suppress it, so a `cp`-based fixture restore can silently fail; stage first and restore with `git checkout --`. |
| `timeout-exit-not-a-signal` | trap | GNU make on Linux handles TERM and exits 2, so a timeout check that only maps 137/143 to 124 misses real timeouts; decide from the watchdog's marker. |
| `relative-source-path-after-cd` | trap | `BASH_SOURCE` is relative at call time after the caller `cd`s; resolve a library's directory once at source time. |
| `fixes-trailer-on-fix-commits` | trap | A hand-made commit on a controller-run step branch needs `Fixes #N`, or the head becomes an `ask`. |
| `brief-prose-frozen-at-close-out` | trap | `ship` compares the closed doc to the approved brief; at close-out change only the Status block and Tracker, never the brief's prose. |
| `library-sources-its-dependencies` | trap | A library that calls another library's function must source that library itself; a shard that sources only part of the set hits `command not found`. |
| `lint-before-push` | trap | The ship gate runs shellcheck and checks the exported copy budget. `make test` checks the source-layout copy budget. |
