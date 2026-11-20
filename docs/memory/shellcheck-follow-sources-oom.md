---
id: shellcheck-follow-sources-oom
type: trap
status: active
---
`shell-inventory.sh --lint` runs `shellcheck -x` once per file, and `-x` follows every
`source`. A file that sources the test groups is analysed together with all of them, in one
process. `scripts/self-test.sh` did that and reached 7.7 GB.

**Why:** the CI runner for this private repo has about 7 GB of memory. When it runs out, the
job is killed about 2.5 minutes after `self-test passed.`, with `make: *** [Makefile:23: test]
Terminated` and "The runner has received a shutdown signal". Nothing names shellcheck, and a
re-run fails the same way. This cost PR #161 five runs and PR #165 two, and it outlived h-12's
per-file split. 7304024 (#173) bounded it, to about 2.5 GiB peak.

**How to apply:** each group import in the `self-test.sh` dispatcher keeps
`# shellcheck source=/dev/null`, and a new group gets the same directive. The groups are
inventory files and are linted on their own. To check a file's cost, run
`/usr/bin/time -v shellcheck -x <file>` in an amd64 `ubuntu:24.04` container with the CI
ShellCheck version. Run it on a `git archive` of the PR head, because the shared checkout may
be on another branch.
