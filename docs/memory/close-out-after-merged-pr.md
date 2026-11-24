---
id: close-out-after-merged-pr
type: trap
status: active
---
If the implementation PR merges before the close-out commit, do not prepare close-out with
`--pr <merged PR>`. Finish on a follow-up PR from the plan branch with
`Implementation PR: source=final-approval`, and reconcile the tracker first.

**Why:** ask-answer-packet's PR #204 merged at 08783ad with the doc still in
`docs/inprogress/`, and its `Fixes #199` closed the work issue on GitHub while the journal
stayed `closing`. The follow-up close-out used `close-out prep --pr .../pull/204`, and both
lifecycle phases then failed. `close-out` was BLOCKED on the CLOSED issue. `pre-merge` reads
#204's head, which still has the in-progress doc and has no final approval, so it never verifies.

**How to apply:** on the follow-up PR, set the Status line to `source=final-approval` so
evidence comes from the reviewer's `final-approve` on that PR's head. Run
`agentic-flow handoff <issue> reconcile` once. It reopens the issue to match the `closing`
journal, so `ship` can finish close-out and run the pre-merge check.
