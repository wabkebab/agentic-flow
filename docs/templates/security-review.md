<!-- TRIAGE (first pass · YYYY-MM-DD) -->
> **Type:** Security · **Status:** 🟦 Proposal | 🚧 In progress | ✅ Done
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
<!-- The burndown. Tick boxes and add the SHA + issue # as fixes land. -->
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

> **Audience:** an implementing agent (**Codex** by default). Each step is independently
> shippable and ordered **riskiest-first**. Do the steps in order; **one logical commit per
> step; do not bundle.** Stage files by name (never `git add -A`). Use verbose, *why*-first
> commit bodies. This brief carries the **approach and insights — not the code.**

## Branch
Base: `<base branch>`. One branch and one PR for the whole brief:
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

## Step 1 — SEC-1: <imperative summary>  🔴
**Why first:** <highest blast radius / a live bug / no dependencies — why this leads.>

**Problem:** <Precise statement with `file:line`. The mechanism, not just the symptom.>

**Implementation brief (approach, do NOT write code yet):**
1. <Step-by-step approach: which files, which functions, what order, edge cases to respect.>
2. <Call out gotchas the implementer would otherwise hit.>

**Regression test:** <Which test file; what it should assert; that it fails on old code and
passes after.>

**DoD:** <Observable end state.>
**Commit:** `<imperative commit subject>`

---

## Step 2 — SEC-2: <imperative summary>  🟠
**Why second:** <…>

**Problem:** <…>

**Implementation brief:**
1. <…>

**Regression test:** <…>

**DoD:** <…>
**Commit:** `<…>`

---

## Status / Implementation status
<!-- Kept current by the executor. -->
- **Tracking issue:** [#NN](<url>) — sub-issues: SEC-1 #__ · SEC-2 #__.
- **Approval:** <approved by whom and when>.
- **Verification evidence:** <CI run or PR checks URL; pending until execution>.
- **Review verdict:** <pending | approved with review URL>.
- Steps not yet started. Executor closes each via a PR with `Fixes #N`, records the commit
  SHA per step here, and ticks the matching SEC-N box in the Tracker above.
