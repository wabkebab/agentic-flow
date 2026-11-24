<!-- TRIAGE (first pass · YYYY-MM-DD) -->
> **Type:** Security · **Status:** 🟦 Proposal | 🚧 In progress | ✅ Done
> **Assurance:** Standard | Strict (choose at least the project baseline; sensitive changes require Strict)
> One or two lines: scope of this review, what's current vs historical, what to do next.

<!--
  TEMPLATE — copy to docs/inprogress/security-<topic>.md and fill in. Delete these comments.
  A Security doc has two halves:
    PART A — the review (findings, severity-graded, with file:line and a fix)
    PART B — the inlined IMPLEMENTATION BRIEF (the execution insights for the implementer —
             approach and steps, NOT the actual code)
  Severity legend (maps to labels): 🔴 High (sev:high) · 🟠 Medium (sev:med) · 🟡 Low (sev:low) · 🟦 Nit (sev:nit).
  Accepted/by-design is a disposition, not a severity.
  See METHODOLOGY.md §3, §5. Verification commands come from CLAUDE.md "Stack profile".
-->

# Security Review — <topic>

## Tracker
<!-- Standard: exactly one step and one work issue. Strict: parent tracker and
     one sub-issue per step. Tick boxes and add the SHA + issue # as fixes land. -->
- [ ] SEC-1 <one-line finding> — open
- [ ] SEC-2 <one-line finding> — open

## Scope
<!-- What was reviewed: which components, branch, commit. One or two lines. -->

## Out of scope
<!-- What this review explicitly did NOT cover. -->

## Threat model / assumptions
<!-- Optional but recommended: who the adversary is, trust boundaries, what's already
     assumed-secure (e.g. the reverse proxy blocks /internal/*). Keeps findings honest. -->

---

# Part A — Findings

> Ordered by severity, highest first. Each finding: **location** (`file:line`), what's
> wrong and the realistic impact, then a concrete **Fix:**.

## 🔴 High severity

### SEC-1. <short title>
**Location:** `path/to/file.ext:NN`
<What's wrong, and the realistic worst case — who can trigger it and what they get.>

**Fix:** <The concrete change. One or two sentences. The detailed approach goes in Part B.>

## 🟠 Medium severity

### SEC-2. <short title>
**Location:** `path/to/file.ext:NN`
<Description.>

**Fix:** <…>

## 🟡 Low severity / maintenance

- **<title>** (`path:NN`) — <description>. **Fix:** <…>

## 🟦 Nit

- **<title>** (`path:NN`) — <wording, clarity, or hygiene issue>. Does not block closure.

## Accepted / by-design (disposition, not a severity)

A finding lands here after it has been graded above and the user has accepted it — the
severity says how bad it is, this section says what was decided about it.

- **<title>** (`path:NN`, was 🟠 Medium) — <why it's acceptable>. If the user accepts it,
  record it in `docs/accepted_risks.md` and link the entry here; otherwise leave it open in
  its severity section with a `[DECIDE]` tag.

## What looks solid (no action)
<!-- Optional: note what you checked and found correct, so the next reviewer doesn't re-tread it. -->

---

# Part B — Implementation Brief

## Acceptance scenarios
<!-- Write these during Spec. State the setup, action, and observable result for each
     scenario, starting with failure paths. Approval binds these scenarios. -->
- <Given …, when …, then …>

## Invariants
<!-- State what must hold across all scenarios, including trust boundaries and limits. -->
- <…>

```agentic-flow-plan
format: 2
id: <stable-plan-id>
profile: strict
tracking: Plan: <topic>
branch: <branch>
steps: sec-1 sec-2
```
<!-- Standard: profile: standard, one step, and omit tracking.
     Part B has a limit of 1,500 words plus 500 per step, excluding the plan block and Status. -->

## Branch
Base: `<base branch>`. One branch and one PR for the whole brief:
<!-- The issue spec packet takes brief path/heading, Definition of Done,
     verification commands, and risks/edge cases from this approved brief.
     Keep the resulting packet at or below 800 words. -->
`security-<topic>` (confirm the base with the human). Each finding lands as its own commit
on that branch, closing its issue via `Fixes #N`.

## Definition of done (whole brief)
Every step's per-step DoD met; `make check` and `make test` green; each fix has a
regression test that fails against old code and passes after.

## Verification commands
<!-- These call the project's Makefile targets (see CLAUDE.md "Stack profile"). -->
```bash
make check                # per step (type-check + lint; also enforced by the Stop hook)
make test-one F=<file>    # the step's targeted test
make test                 # end of brief: full suite
```

---

<!-- Order independently shippable steps with the riskiest work first.
     Name a selector only for steps adding a regression test: **Red-first:** `<raw selector>` — <test-path> <runner-path> -->

## SEC-1 — <imperative summary>  🔴
**Why first:** <highest blast radius / a live bug / no dependencies — why this leads.>

**Approach:** <Describe the intended fix and the security decisions the executor must honor.>

**Test:** <Name the acceptance scenarios this step covers and the assertions, starting with failure paths.>

**DoD:** <Observable end state.>
**Verify:** `make test-one F=<selector>`
**Risks:**
- <Failure path or edge case.>
**Red-first:** none
**Commit:** `<imperative commit subject>`

---

## SEC-2 — <imperative summary>  🟠
**Why second:** <…>

**Approach:** <…>

**Test:** <…>

**DoD:** <…>
**Verify:** `make test-one F=<selector>`
**Risks:**
- <Failure path or edge case.>
**Red-first:** none
**Commit:** `<…>`

---

## Status / Implementation status
<!-- Finalized by the closer before the last repository commit. -->
- **Evidence schema:** v2
- **Tracking issue:** pending
- **Approval:** pending
- **Implementation head:** source=pr-head
- **Implementation PR:** pending
- **Verification evidence:** source=final-approval-run
- **Review verdict:** source=close-out-attestation
- **Memory:** pending
- Close-out: `ship` finalizes Status and Tracker, sets TRIAGE to Done, and commits this
  document's move and the updated index before the first push. It opens the PR and
  waits for CI. The reviewer runs `final-approve` to record the PR, head, and run attempt
  on the tracking issue. `ship` verifies that evidence, closes the issue, and runs
  the pre-merge check before the human merges. If a closer command is unavailable,
  commit the staged close-out and rerun `ship`.
