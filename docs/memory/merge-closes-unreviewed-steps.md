---
id: merge-closes-unreviewed-steps
type: trap
status: active
---
If a PR merges before the reviewer closes its step issues, the commits' `Fixes #N` trailers
close them, and it looks like a clean review. Context optimization (#46–#51, PR #52) closed
this way with a re-review still pending, and it went unnoticed for two months.

**Why:** METHODOLOGY.md §6 treats the trailers as a no-op because it assumes the reviewer
already closed each step. When a merge comes first, a closed step no longer means *reviewed
clean*. The tell is a closed step issue that still carries `agent:codex` + `needs-execution`,
with no verdict comment.

**How to apply:** at close-out, don't trust closed-state alone. Confirm that each step has
a reviewer verdict comment and that its closing actor isn't the merge. Treat a closed step
with no verdict as unreviewed: re-review it, or record the gap in `docs/accepted_risks.md`.
