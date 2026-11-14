<!-- TRIAGE (first pass · YYYY-MM-DD) -->
> **Type:** Feature · **Status:** 🟦 Proposal | 🚧 In progress | ✅ Done
> **Assurance:** Standard | Strict (choose at least the project baseline)
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
<!-- Standard: exactly one step and one work issue. Strict: parent tracker and
     one sub-issue per step. Tick boxes and add the SHA + issue # as steps land. -->
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

## Interface (before the implementation)
<!-- METHODOLOGY.md §11.2. Write the shapes here, not in your head: function signatures,
     endpoint contracts, request/response bodies, the data model delta. Most architecture
     problems are visible at this stage and cost nothing to fix; once code exists they are
     attached to something and get rationalised instead. Types/signatures — still not code. -->
```
<signatures / endpoint contracts / data shapes>
```

## Threat model (one paragraph)
<!-- METHODOLOGY.md §11.2. MANDATORY if this feature touches auth, money, or user data;
     ten minutes otherwise. Who are the untrusted actors, which data actually matters, and
     what is the worst thing an attacker could do with this change? If the honest answer is
     "nothing — no new trust boundary", write that and move on. -->
<…>

## Failure behavior
<!-- METHODOLOGY.md §11.2. Decide this NOW; decided mid-implementation it becomes an ad-hoc
     guess nobody revisits. One row per external call / dependency. -->

| External call | On timeout | On malformed response | On partial success |
|---------------|-----------|-----------------------|--------------------|
| <…>           | <…>       | <…>                   | <…>                |

Bounds: <every query's limit, every loop's cap, every request's timeout — §11.3>

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

```agentic-flow-plan
id: <stable-plan-id>
profile: strict
tracking: Plan: <topic>
branch: <branch>
steps: f-1 f-2
```
<!-- Standard: profile: standard, one step, and omit tracking. -->

## Branch
Base: `<base branch>`. One branch and one PR for the whole brief:
<!-- The issue spec packet takes brief path/heading, Definition of Done,
     verification commands, and risks/edge cases from this approved brief.
     Keep the resulting packet at or below 800 words. -->
`feature-<topic>` (confirm the base with the human). Each step lands as its own commit on
that branch, closing its issue via `Fixes #N`.

## Definition of done (whole brief)
Every step's per-step DoD met; `make check` and `make test` green; the user-visible goal in
Part A is demonstrably met (note how to verify it manually if relevant — `make run` / `/verify`).

Prefer raw runner selectors for Red-first: make masks recipe failures as exit 2;
Cargo assertion failures exit 101. Declare the project's assertion signature.
Exit 0 is green; nonzero plus a signature match is red except timeout 124 and
interrupts 130/143, which are invalid. Missing or mismatched signatures are invalid.
Evidence reuse requires matching reviewed SHA/tree and verifier implementation hash;
inspect signature-source provenance (shared review contract, METHODOLOGY.md §5).

## Verification commands
<!-- These call the project's Makefile targets (see CLAUDE.md "Stack profile"). -->
```bash
make check                # per step (type-check + lint; also enforced by the Stop hook)
make test-one F=<file>    # the step's targeted test
make test                 # end of brief: full suite
```

---

## F-1 — <imperative summary>
**Why first:** <foundational / unblocks the rest / riskiest — why this leads.>

**Approach (do NOT write code yet):**
1. <Which files, which functions, what order. Data-model / migration changes first.>
2. <Edge cases, gotchas, conventions to follow from CLAUDE.md.>

**Test:** <What to add or extend; what it should assert. **Failure path first** (§11.4) —
name the timeout / malformed / unauthorized case, not just the happy one.>

**DoD:** <Observable end state for this step.>
**Verify:** `make test-one F=<selector>`
**Risks:** <Failure paths and edge cases.>
**Red-first:** `<selector>` — <test-path> <runner-path>
**Commit:** `<imperative commit subject>`

---

## F-2 — <imperative summary>
**Why second:** <…>

**Approach:**
1. <…>

**Test:** <…>

**DoD:** <…>
**Verify:** `make test-one F=<selector>`
**Risks:** <Failure paths and edge cases.>
**Red-first:** `<selector>` — <test-path> <runner-path>
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
- Close-out: finalize Status/Tracker, set TRIAGE to Done, move this document and update
  the index in the last repository commit. After human push, obtain CI and a structured
  reviewer approval on the `Tracking issue` for that exact PR head and run attempt.
  Verify this moved file with `--phase close-out`, close the tracker without another
  repository edit, then recheck with `--phase pre-merge` before human merge.
