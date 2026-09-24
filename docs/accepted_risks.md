# Accepted Risks & Declined Features

This file records findings and proposals that were reviewed and **intentionally accepted or
declined** rather than implemented. It is the durable answer to "why didn't we fix/build
that?" — and the place a future reader checks before re-opening a closed decision.

Each entry should be revisited if the deployment model, threat model, scale, or product
direction changes. Use `docs/templates/accepted-risk-entry.md` to add a new block.

<!-- Append accepted-risk / declined-feature blocks below, newest first. -->

## F-5 — Context optimization shipped without re-review of its fixes

**Status:** Accepted risk
**Decision date:** 2026-09-24
**Decided by:** wabkebab (human owner)
**Tracking:** docs/done/context_optimization.md; tracker #46, steps #47–#51, PR #52

### Finding / proposal
The branch-level review of `e70fe64` came back as changes requested (8 findings, 4 requiring
change). Codex fixed them in `9134c41`, and PR #52 merged on 2026-07-25 before anyone
re-reviewed the fixes. The merge's `Fixes #N` trailers closed #47–#51, so the steps look
reviewed but aren't. Authoritative CI on the PR head `76a25fd` was green.

### Proposed mitigation / implementation
Have OpenCode re-review `9134c41` against the eight original findings before closing #46.

### Acceptance rationale
The work has been on `main` since v0.10.0 (2026-07-25), and later passes built on it. A
re-review now would read code that has changed since. The approved harness-optimization
brief (#93) re-audits this same area: lifecycle evidence, review provenance, and the
contract and ceiling guards. CI was green on the merged head, and `9134c41` hardened the
guards the review had flagged as unable to fail.

### Revisit if
- A regression traces back to one of the four change-requiring findings in `9134c41`.
- #93 is descoped or dropped before F-1–F-3 and F-8 land.

## F-4 — Template and instance copies can drift

**Status:** Accepted risk
**Decision date:** 2026-07-05
**Decided by:** Human approval of tracker #8
**Tracking:** docs/inprogress/feature-init-and-template-split.md; issue #4

### Finding / proposal
The scaffold now keeps pristine exported forms in `templates/harness/` and this repo's own
filled-in files at the root. That split prevents instance details from leaking into new
adoptions, but it creates a small risk that contract changes land in only one copy.

### Proposed mitigation / implementation
A heavier synchronization mechanism could derive one copy from the other or add a strict
template drift checker for every contract line. This pass keeps the split explicit and
documents the dual-copy rule in the root guidance.

### Acceptance rationale
The copied surface is limited to `CLAUDE.md`, `AGENTS.md`, and `Makefile`, and contract
changes are expected to be rare and reviewed. The alternative was continuing to ship this
repo's live instance as the adoption payload, which had already blocked dogfooding.

### Revisit if
- A third copy of the harness contract appears.
- A contract change ships in only one copy.
