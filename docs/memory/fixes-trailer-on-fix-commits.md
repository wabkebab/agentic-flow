---
id: fixes-trailer-on-fix-commits
type: trap
status: active
---
Under the controller, every commit a human or planner adds to a step branch needs the
`Fixes #N` trailer for that step's issue, or the executor's claimed head is turned into an
`ask` escalation.

**Why:** the controller checks that the claimed head is an ancestor and that its commit
message contains `Fixes #N` (`controller.sh`, about line 372). A fix I committed on top of
e-1 lacked the trailer, so the resubmission would have escalated. An empty commit carrying
`Fixes #176` repaired it.

**How to apply:** put `Fixes #<step issue>` in any hand-made commit on a controller-run
branch, and expect the head the executor resubmits to be the one that carries it.
