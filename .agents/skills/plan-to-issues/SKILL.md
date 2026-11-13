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
`scripts/plan-to-issues.sh`, driven by the approved document or a legacy JSON spec.

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
2. **Record human approval.** When the human approves the plan, record the Status field
   `Approval: status=approved; by=<human>; at=<date>; rev=<sha40>`, where `rev` is the
   commit they read. Commit the approval field. Plan content at HEAD must normalize
   equal to that revision; later design changes require re-approval.
3. **Dry run** the plan block and step labels, extracted directly from the approved revision:
   ```
   scripts/plan-to-issues.sh --doc docs/inprogress/<doc>.md
   ```
   The brief declares one fenced `agentic-flow-plan` block with `id`, `profile`, `branch`,
   ordered `steps`, and (Strict only) `tracking`. Each step section has `**DoD:**`,
   `**Verify:**`, `**Risks:**` and `**Red-first:**` labels. Packets must stay below 800 words.
   The Stack profile in `CLAUDE.md` explains the Makefile commands.
4. **Compare an existing plan** before reconciling:
   ```
   scripts/plan-to-issues.sh --doc docs/inprogress/<doc>.md --diff
   ```
5. **Apply.** Human plan approval authorizes apply; no second go-ahead is required.
   The document must be committed, clean and approved at HEAD:
   ```
   scripts/plan-to-issues.sh --doc docs/inprogress/<doc>.md --apply
   ```
   Reapply stamps `approved=<rev>` without changing existing workflow labels or
   `journal=` eligibility. A changed plan names the first changing commit: re-approve it.
6. **Legacy JSON path.** For legacy plans and Security docs without a plan block, write
   a JSON spec and use `scripts/plan-to-issues.sh <spec.json>` to dry-run; `--diff` compares,
   and `--apply --approved-by <human> [--doc <path>] <spec.json>` reconciles.
   The spec has a stable `id`, `profile` (`standard` or `strict`), and `steps` array.
   Every step has stable `id`, `title`, `body`, `labels` and a `packet` object containing
   `brief`, `definition_of_done`, `verification`, `risks` strings from the approved brief.
   Standard has one step and no `tracking`; Strict requires `tracking: {title, body}`.
   Omit `profile` only for existing legacy topology. Labels are `plan` for trackers and
   `agent:codex`, `needs-execution` for steps. Security findings add the matching `sev:*`.
   Human plan approval also authorizes this apply. Standard requires `--approved-by` on
   first apply; reapply preserves the recorded identity and timestamp.
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
