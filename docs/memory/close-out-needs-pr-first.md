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

**How to apply:** at the start of a close-out, check `gh pr list --head <branch>`. If there is
no PR, commit the other close-out changes, ask the human to push and open the PR, then write
the doc-move commit with the PR URL. Otherwise, write it in one pass.
