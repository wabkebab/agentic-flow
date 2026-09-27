# Accepted Risks & Declined Features

This file records findings and proposals that were reviewed and **intentionally accepted or
declined** rather than implemented. It is the durable answer to "why didn't we fix/build
that?" — and the place a future reader checks before re-opening a closed decision.

Each entry should be revisited if the deployment model, threat model, scale, or product
direction changes. Use `docs/templates/accepted-risk-entry.md` to add a new block.

<!-- Append accepted-risk / declined-feature blocks below, newest first. -->

<a id="f10-unreviewed-amendment"></a>
## F-10 — Post-approval amendment `987c58b` was not re-reviewed

**Status:** Accepted risk
**Decision date:** 2026-09-27
**Decided by:** wabkebab (human owner)
**Tracking:** docs/inprogress/feature-harness-optimization.md; tracker #93, step #103

### Finding / proposal
OpenCode approved F-10 at `6b738c8` and closed #103. Codex then amended the commit to
`987c58b` to address that review's Low finding and Nit. Nobody reviewed the amendment
(12 lines across `scripts/hooks/require-step-comment.sh`, `scripts/self-test.sh`, and both
`CLAUDE.md` copies). F-11 and F-12 were reviewed on top of it, but only their own ranges.

### Proposed mitigation / implementation
Have the reviewer re-review `6b738c8..987c58b` before close-out.

### Acceptance rationale
The delta only applies the reviewer's own requested fixes. The hook change widens a
fail-closed match from the whole comment to one marker line, which is the lifecycle parser's
rule, and it adds regressions for prose before and after the marker. Every later step's
`make check`, focused hook groups, and full suite ran with it in place.

### Revisit if
- A Standard handoff is wrongly allowed or blocked by `require-step-comment.sh`.

<a id="harness-optimization-branch-split"></a>
## #93 — Harness optimization executed across per-step branches

**Status:** Accepted risk
**Decision date:** 2026-09-27
**Decided by:** wabkebab (human owner)
**Tracking:** docs/inprogress/feature-harness-optimization.md; tracker #93

### Finding / proposal
Part B names one branch, `codex/trustworthy-proportionate-harness`. That branch stopped at
`0eb39f3` with an uncommitted draft in the F-2 worktree, so Codex continued on stacked
branches `…-f3` through `…-f12`. The finished history is one linear chain,
`87d6ae9..ba2cbd9`, on `codex/trustworthy-proportionate-harness-f12`.

### Proposed mitigation / implementation
Discard the stale draft and fast-forward the named branch to the chain head.

### Acceptance rationale
The chain is linear and each step is still one reviewed logical commit plus its review fixes.
The PR is opened from `…-f12`. The draft left in the named branch's worktree has no content
difference from `0eb39f3` (`git diff HEAD` is empty), so nothing is lost by leaving it.
The human can clean up the named branch and its worktree.

### Revisit if
- Another Strict brief is executed across stacked branches; the single-branch rule then
  needs enforcement rather than a per-plan exception.

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
