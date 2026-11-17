---
id: close-out-needs-pr-first
type: trap
status: active
---
The Status field `Implementation PR` accepts only a real `url=…/pull/<N>`, and `pending`
leaves close-out UNVERIFIED. A PR exists only after the human pushes. So the last close-out
commit (Status, Tracker, TRIAGE Done, doc move) cannot be written until the branch is pushed
and the PR is open.

**Why:** #114's close-out prepared the version, changelog, risk and roadmap commits, then
stalled at the doc move until the human pushed and opened #121, which cost an extra
push and CI round.

**How to apply:** the human runs `agentic-flow ship <doc>`. Its first phase checks for
an existing PR, pushes the approved plan branch and opens the PR when needed, then runs
`close-out prep` with the real URL. Commit the staged close-out and run `ship` again for
CI and final-head evidence. Keep this entry until one pass has shipped through `ship`.
