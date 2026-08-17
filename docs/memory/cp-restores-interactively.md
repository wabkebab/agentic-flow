---
id: cp-restores-interactively
type: trap
status: active
---
`cp` prompts before overwriting in common interactive shells, and `-f` does not reliably
suppress it. A restore step written as `cp stash file` can hang, then leave the fixture
modified.

**Why:** red-first testing corrupts a tracked file, runs the suite, and restores it. The restore
is the fragile half, and a failed restore looks like success — the next run passes against a
file nobody meant to change.

**How to apply:** stage the work first, corrupt with `sed -i`, restore with `git checkout --
<file>`. That is non-interactive and restores from the index, so uncommitted work survives. For
a file git does not track, redirect a saved copy with `cat` instead.
