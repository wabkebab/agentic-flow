---
id: close-out-needs-pr-first
type: trap
status: active
---
For plans with an already-open PR, `ship` prepares close-out with that PR's URL. New PRs
use `source=final-approval`, which allows the close-out commit before the first push.

**Why:** #114's close-out prepared the version, changelog, risk and roadmap commits, then
stalled at the doc move until the human pushed and opened #121, which cost an extra
push and CI round.

**How to apply.** When the PR already exists and the doc is still in progress, the human
runs `agentic-flow ship <doc>` to stage close-out with the real URL. Commit the staged
close-out and run `ship` again for CI and final-head evidence.
