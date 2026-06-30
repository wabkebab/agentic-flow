<!-- TRIAGE (first pass · YYYY-MM-DD) -->
> **Type:** Feature · **Status:** 🟦 Proposal | 🚧 In progress | ✅ Done
> One or two lines: what this feature is, what's current vs historical, what to do next.

<!--
  TEMPLATE — copy to docs/inprogress/feature-<topic>.md and fill in. Delete these comments.
  A Feature doc has two halves:
    PART A — the analysis (goal, current state, approach, what-not-to-build)
    PART B — the inlined IMPLEMENTATION BRIEF (the execution insights for the implementer —
             approach and steps, NOT the actual code)
  See METHODOLOGY.md §3. Verification commands come from CLAUDE.md "Stack profile".
-->

# Feature — <topic>

## Tracker
<!-- The burndown. Tick boxes and add the SHA + issue # as steps land. -->
- [ ] F-1 <one-line step> — open
- [ ] F-2 <one-line step> — open

---

# Part A — Analysis

## Goal
<!-- What the user actually wants, in their terms. The problem, not the solution. -->

## Current state
<!-- How it works today and where the gap is. Reference real code (file:line). Be precise
     about what already works so the brief doesn't re-implement it. -->

## Proposed approach
<!-- The design. If there are real alternatives, lay them out with trade-offs and make a
     recommendation — don't just present a menu. -->

### Option A — <name> (recommended)
<Trade-offs.>

### Option B — <name>
<Trade-offs, and why not.>

**Recommendation:** <Which, and why. The safest first version is usually the smallest one
that delivers the user-visible value.>

## Out of scope / What NOT to build in this pass
<!-- Just as important as the scope. Prevents gold-plating and scope creep. -->
- <…>

## Open questions
<!-- Things to confirm with the human before/while executing. Tag blocking ones [BLOCKING]. -->
- <…>

---

# Part B — Implementation Brief

> **Audience:** an implementing agent (**Codex** by default). Each step is independently
> shippable and ordered so the **riskiest / most foundational work lands first.** Do the
> steps in order; **one logical commit per step; do not bundle.** Stage files by name
> (never `git add -A`). Use verbose, *why*-first commit bodies. This brief carries the
> **approach and insights — not the code.**

## Branch
`feature-<topic>` off <base branch>. (Confirm the base with the human.)

## Definition of done (whole brief)
Every step's per-step DoD met; `make check` and `make test` green; the user-visible goal in
Part A is demonstrably met (note how to verify it manually if relevant — `make run` / `/verify`).

## Verification commands
<!-- These call the project's Makefile targets (see CLAUDE.md "Stack profile"). -->
```bash
make check                # per step (type-check + lint; also enforced by the Stop hook)
make test-one F=<file>    # the step's targeted test
make test                 # end of brief: full suite
```

---

## Step 1 — <imperative summary>
**Why first:** <foundational / unblocks the rest / riskiest — why this leads.>

**Approach (do NOT write code yet):**
1. <Which files, which functions, what order. Data-model / migration changes first.>
2. <Edge cases, gotchas, conventions to follow from CLAUDE.md.>

**Test:** <What to add or extend; what it should assert.>

**DoD:** <Observable end state for this step.>
**Commit:** `<imperative commit subject>`

---

## Step 2 — <imperative summary>
**Why second:** <…>

**Approach:**
1. <…>

**Test:** <…>

**DoD:** <…>
**Commit:** `<…>`

---

## Status / Implementation status
<!-- Kept current by the executor. -->
- **Tracking issue:** [#NN](<url>) — sub-issues: F-1 #__ · F-2 #__.
- Steps not yet started. Executor closes each via a PR with `Fixes #N`, records the commit
  SHA per step here, and ticks the matching F-N box in the Tracker above.
