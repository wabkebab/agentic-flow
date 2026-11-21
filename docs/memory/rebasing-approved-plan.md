---
id: rebasing-approved-plan
type: trap
status: active
---
Rebasing a plan branch after approval can leave the approved brief revision and reviewed
step commits outside the branch's history, even when the resulting files are identical.

**Why.** Issue generation and shipping use the approved brief revision. Close-out also
checks that approved step commits are ancestors of the PR head.

**How to apply.** Merge updates from the base into the plan branch in its worktree. If
history has already been rewritten, recover the approved history or obtain fresh approval
and review before shipping.
