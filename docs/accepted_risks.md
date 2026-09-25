# Accepted Risks & Declined Features

This file records findings and proposals that were reviewed and **intentionally accepted or
declined** rather than implemented. It is the durable answer to "why didn't we fix/build
that?" — and the place a future reader checks before re-opening a closed decision.

Each entry should be revisited if the deployment model, threat model, scale, or product
direction changes. Use `docs/templates/accepted-risk-entry.md` to add a new block.

<!-- Append accepted-risk / declined-feature blocks below, newest first. -->

<a id="single-operator-review"></a>
## F-3 — One GitHub account can attest to multiple agent roles

**Status:** Accepted risk
**Decision date:** 2026-09-25
**Decided by:** Human approval of the harness optimization brief, tracker #93
**Tracking:** issue #96

### Finding / proposal

This installation uses one GitHub credential for its agent roles. GitHub authenticates
the account that posts a verdict, but cannot prove that a different person reviewed it.

### Acceptance rationale

The lifecycle gate requires a structured reviewer role claim and records the API author.
The result is accountable single-operator attestation, with a persistent warning; it is
not independent review. Revisit when separate reviewer credentials are available.

<a id="mutable-external-evidence"></a>
## F-3 — Review comments and Actions runs can change after verification

**Status:** Accepted risk
**Decision date:** 2026-09-25
**Decided by:** Human approval of the harness optimization brief, tracker #93
**Tracking:** issue #96

### Finding / proposal

An issue-comment verdict can be edited or deleted, and an Actions run can be re-run or
deleted without a repository edit. The gate checks the current comment, run attempt,
head, repository, workflow, and conclusion when invoked. It cannot preserve those
external records or guard a later merge.

### Acceptance rationale

The closer checks immediately before closing the tracker; the human checks again
immediately before merge or uses protected-branch required checks. Durable evidence
would require stronger GitHub review or attestation mechanisms beyond this pass.

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
