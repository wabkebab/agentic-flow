<!-- TRIAGE (first pass · YYYY-MM-DD) -->
> **Type:** Product Analysis · **Status:** 🟦 Proposal | ✅ Decided | 🕰️ Superseded
> One or two lines: the decision this informs, what's current vs historical.

<!--
  TEMPLATE — copy to docs/inprogress/product-<topic>.md and fill in. Delete these comments.
  A Product Analysis is a DECISION RECORD: explore options, weigh trade-offs, recommend.
  It has NO implementation brief. If it greenlights work, spin off a Feature (or Security)
  doc for that work and link it from the Recommendation. See METHODOLOGY.md §3.
-->

# Product Analysis — <topic>

## Goal / context
<!-- The business or product question being explored, in plain terms. What decision does
     this analysis need to unblock? Who is affected? -->

## Constraints & assumptions
<!-- Budget, scale, team size, timeline, regulatory (GDPR, etc.), existing tech, reversibility.
     The forces that bound the answer. -->

---

## Options
<!-- Lay out the real options as a spectrum, not a binary. For each: what it is, and its
     trade-offs across the dimensions that matter (cost, isolation, complexity, time-to-build,
     reversibility, operational burden, ...). Be specific about the dimension that decides it. -->

### Option 1 — <name>
- **What it is:** <…>
- **Pros:** <…>
- **Cons / risks:** <…>
- **Cost / effort:** <…>
- **Right for:** <when this is the answer>

### Option 2 — <name>
- **What it is:** <…>
- **Pros:** <…>
- **Cons / risks:** <…>
- **Cost / effort:** <…>
- **Right for:** <…>

### Option 3 — <name>
- …

## Comparison
<!-- Optional table across the dimensions that actually drive the decision. -->

| Dimension | Option 1 | Option 2 | Option 3 |
|-----------|----------|----------|----------|
| <e.g. cost> | | | |
| <e.g. isolation> | | | |
| <e.g. effort> | | | |
| <e.g. reversibility> | | | |

---

## Recommendation
<!-- A clear pick, the reasoning, and the *one* dimension that tips it. State what you'd
     defer and why (don't pre-pay complexity you don't need yet). -->

**Recommended:** <Option N — one line why.>

**Defer:** <What to explicitly NOT do yet, and the signal that would change that.>

## Decisions to make up front
<!-- The few choices that are expensive to reverse and should be settled before building.
     These are the ones worth a human's explicit sign-off. -->
- <…>

## If approved → next docs
<!-- This analysis doesn't get an implementation brief. List the Feature/Security docs to
     spin off if the recommendation is accepted, so the thread isn't lost. -->
- [ ] `docs/inprogress/feature-<…>.md`
- [ ] `docs/inprogress/security-<…>.md`

## Status
<!-- Decision record. -->
- **Decision:** <pending | accepted <date> | rejected <date> | superseded by <doc>>.
- **Decided by:** <human>.
