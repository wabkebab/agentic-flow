---
name: plan-to-issues
description: Turn an approved Feature or Security brief into Standard's work issue or Strict's tracker and step issues. Implements METHODOLOGY.md §6.
---

# plan-to-issues

Convert an **approved** implementation brief into GitHub issues. Standard creates one work
issue; Strict creates a parent tracker and one issue per step. A profile-less legacy spec
keeps its tracker and steps. The doc stays the source of
design intent; the issues are the execution burndown (progress bar + `Fixes #N` auto-close).

This skill does the reading/extraction; the deterministic GitHub calls live in
`scripts/plan-to-issues.sh`, driven by a JSON spec.

## When to use
- A Security or Feature doc with an inlined implementation brief exists **and the human has
  approved it** (never create issues for a draft).
- The brief has an ordered step list where each step is independently committable.

## Preconditions — check first
1. `gh auth status` is logged in (repo scope is enough for tracking + sub-issues).
2. Issues are enabled: `gh repo view --json hasIssuesEnabled`.
3. Confirm the target doc path with the user if ambiguous.

## Procedure
1. **Read the doc's implementation brief (Part B).** Extract: the feature/topic name, the
   branch, the ordered steps, and each step's concise Definition of Done. Preserve the risk
   ordering. The approved brief owns intent; the Makefile owns executable command behavior.
   If the issue must point to the Stack profile, name `CLAUDE.md` as the owner.
2. **Build a JSON spec** (write to a temp file, e.g. the session scratchpad):
   ```json
   {
     "profile": "standard",
     "id": "<stable-kebab-id>",
     "steps": [
       {
         "id": "<stable-step-id>",
         "title": "Step 1 — <summary>",
         "body": "<brief-step link + concise DoD + current label state. Keep the *why* and Make recipes in the doc/Makefile.>",
         "packet": {
           "brief": "<approved brief path and step heading>",
           "definition_of_done": "<the approved step's acceptance criteria>",
           "verification": "<focused and broader Make targets from the brief>",
           "risks": "<failure path and edge cases from the brief>"
         },
         "labels": ["needs-execution", "agent:codex"]
       }
     ]
   }
   ```
   - Give the plan and every step a stable `id`. These identities survive title/body edits
     and let the driver reconcile without duplicating issues.
   - Standard has exactly one step and no `tracking` object. Strict requires a `tracking`
     object with a title and may have multiple steps. Omit `profile` only when reapplying
     a legacy plan. The project assurance baseline is a floor.
   - Every profiled step requires all four packet strings above, taken from the approved
     brief. The driver rejects a packet over 800 words; revise the source fields instead
     of truncating a requirement.
   - One issue per brief step. Don't merge steps or split per-commit.
   - Step body = brief-step link + concise Definition of Done + current label state. Design
     rationale stays in the doc; Make recipes stay in the Makefile.
   - Labels follow METHODOLOGY.md §6: `plan` on a Strict tracker;
     `needs-execution` + `agent:codex` on work and step issues. For a **Security** doc
     add the matching `sev:high|med|low|nit` per issue.
   - Strict's sub-issues close on approval; its parent then receives `needs-closing`.
     Standard's sole work issue receives `needs-closing` after an approving comment and
     stays open for close-out. Never pre-apply that label.
3. **Dry run** — show the user exactly what the spec describes. This is fully offline:
   ```
   scripts/plan-to-issues.sh <spec.json>
   ```
4. **Optional live diff** — after a plan has been applied, compare it with GitHub:
   ```
   scripts/plan-to-issues.sh --diff <spec.json>
   ```
5. **Get explicit approval.** Creating or reconciling issues writes public artifacts —
   never run `--apply`
   without the user's go-ahead in this turn.
6. **Apply and write the issue link back:**
   ```
   scripts/plan-to-issues.sh --apply --approved-by '<human identity>' \
     --doc docs/inprogress/<doc>.md <spec.json>
   ```
   Standard requires `--approved-by` on first apply; its work issue stores the identity
   and timestamp. Reapply preserves them. Strict also records them when supplied.
7. **Close the loop:** tick nothing yet and tell the user the work or tracking issue URL.

## Notes
- The script stamps work issues, trackers, and steps with their stable IDs. Repeating `--apply` updates
  existing issues, resumes interrupted runs, creates added steps, and closes removed steps
  with a history-preserving comment. Spec labels apply only when an issue is created;
  reapply preserves the live reviewer/executor label state.
- A plan's topology is immutable. Changing Standard, Strict, or legacy shape requires an
  explicit migration; the driver rejects the reapply before any GitHub mutation.
- Sub-issue linking is best-effort via the GitHub sub-issues API; if unavailable, the
  tracking issue still carries a `- [ ] #N` task list as the fallback checklist.
- For a **Security** doc's findings, each 🔴🟠🟡🔵 finding becomes a step entry with the
  matching `sev:*` label under one "Plan: <topic>" tracker.
