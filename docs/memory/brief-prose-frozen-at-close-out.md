---
id: brief-prose-frozen-at-close-out
type: trap
status: active
---
At close-out, the closer may change the Status block and the Tracker, but not the brief's
prose. `ship` normalizes the closed document and compares it with the approved revision, so
any other edit makes it refuse with `closed document differs from the approved brief`.

**Why:** at the flow-ergonomics close-out, the header sentence still said "awaiting approval",
and the closer corrected it. `ship` refused (`scripts/lib/ship.sh`, `ship_pr_body`), and the
fix was to restore the approved wording (d3ce3d8).

**How to apply:** record that a plan is approved or shipped in the Status block, the Tracker
and the roadmap. If the prose really is wrong, that is a plan change and needs re-approval.
Before running `ship`, compare `brief_normalize` hashes of the approved revision and the moved
doc.
