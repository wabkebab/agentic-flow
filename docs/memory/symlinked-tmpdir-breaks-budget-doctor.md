---
id: symlinked-tmpdir-breaks-budget-doctor
type: trap
status: active
---
A contracts or controller run started from a default macOS shell fails the budget-mode doctor
test with `budget-mode: doctor omitted mode source or latest row`. The test is fine; the
caller's `TMPDIR` is the problem.

**Why:** `budget_overrun_dir` (`scripts/lib/budget.sh`) compares the fixture's `pwd -P`
git toplevel with the unresolved `$root`. The default `TMPDIR` is `/var/folders/.../T/`:
`/var` is a symlink to `/private/var` and the trailing slash yields `T//agentic-flow-test.*`,
so the comparison fails and no overrun rows are reported. On f-5 this turned the
controller's green `make test-one F=contracts` red (exit 2) while the executor's run, with
a different `TMPDIR`, had passed.

**How to apply:** start the controller, and run `make test-one F=contracts` by hand, with
`TMPDIR` set to the physical path with no trailing slash, for example
`TMPDIR=/private/var/folders/<id>/T`. If the doctor line fails, check the path before the
test. The root fix is to resolve `$root` with `pwd -P` before comparing; until that lands,
keep the workaround.
