---
name: plan-to-issues
description: Turn an approved implementation brief (the Part B of a Security or Feature doc in docs/) into a GitHub tracking issue with one sub-issue per step. Use when a plan is approved and ready to hand to the executor. Implements METHODOLOGY.md §6.
---

# plan-to-issues

Convert an **approved** implementation brief into GitHub issues: one parent **tracking
issue** plus one **sub-issue per independently-shippable step**. The doc stays the source of
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
     "id": "<stable-kebab-id>",
     "tracking": {
       "title": "Plan: <topic>",
       "body": "<1–2 line summary, link to the doc path, and the branch>"
     },
     "labels": ["plan"],
     "steps": [
       {
         "id": "<stable-step-id>",
         "title": "Step 1 — <summary>",
         "body": "<brief-step link + concise DoD + current label state. Keep the *why* and Make recipes in the doc/Makefile.>",
         "labels": ["needs-execution", "agent:codex"]
       }
     ]
   }
   ```
   - Give the plan and every step a stable `id`. These identities survive title/body edits
     and let the driver reconcile without duplicating issues.
   - One step issue per brief step. Don't merge steps or split per-commit.
   - Step body = brief-step link + concise Definition of Done + current label state. Design
     rationale stays in the doc; Make recipes stay in the Makefile.
   - Labels follow METHODOLOGY.md §6: `plan` on the tracker; `needs-execution` + `agent:codex`
     on steps. For a **Security** doc add the matching `sev:high|med|low|nit` per step.
   - Do **not** pre-apply `needs-closing` to steps. The reviewer closes step issues outright,
     so `agent:claude` + `needs-closing` only ever lands on the tracking issue, and only when
     the last step is closed. The tracker is created with `plan` alone.
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
6. **Apply and write the tracker link back:**
   ```
   scripts/plan-to-issues.sh --apply --doc docs/inprogress/<doc>.md <spec.json>
   ```
7. **Close the loop:** tick nothing yet and tell the user the tracking issue URL.

## Notes
- The script stamps trackers and steps with their stable IDs. Repeating `--apply` updates
  existing issues, resumes interrupted runs, creates added steps, and closes removed steps
  with a history-preserving comment.
- Sub-issue linking is best-effort via the GitHub sub-issues API; if unavailable, the
  tracking issue still carries a `- [ ] #N` task list as the fallback checklist.
- For a **Security** doc's findings, each 🔴🟠🟡🔵 finding becomes a step entry with the
  matching `sev:*` label under one "Plan: <topic>" tracker.
