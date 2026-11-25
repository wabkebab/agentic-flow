<!-- TRIAGE (first pass · 2026-11-25) -->
> **Type:** Feature · **Status:** ✅ Done
> **Assurance:** Standard
> Let `plan-to-issues` adopt an existing GitHub issue for a plan step instead of creating a duplicate.

# Feature — Adopt existing issues

## Tracker
- [x] f-1 — #211; approved=10b1ec9ead7669164c59e345a0362926281ad73d; submissions=10b1ec9ead7669164c59e345a0362926281ad73d
---

# Part A — Analysis

## Goal
A project that already tracks its work in GitHub issues can run those issues through the controller.
The motivating case: an adopting project with a hand-written umbrella issue and about twenty step
issues, where `apply` would create a parallel set.

## Current state
`scripts/plan-to-issues.sh` finds a plan's issues only by their identity stamp (one `gh issue list`
search). With no stamp it creates a new issue. Reapply replaces the whole body of a stamped issue.

## Proposed approach
### Option A — an explicit `--adopt` mapping (recommended)
The owner names which issue belongs to which step. Adoption stamps that issue and keeps its text.
### Option B — an issue number in the plan block
Part of the approved design, but changes the strict parser and every consumer of the spec.
### Option C — match by title
Titles are editable; the script deliberately never identifies plans by them.

**Recommendation:** A.

## Interface (before the implementation)
```
scripts/plan-to-issues.sh --doc <path> --adopt <step-id>=<number> [--adopt ...] [--apply|--diff]
  <step-id> may be `tracker` for a Strict plan
adopted issue body = <original body> + "<!-- agentic-flow:adopted -->" + <rendered packet and stamps>
```

## Threat model (one paragraph)
Issue text is untrusted: anyone who can edit an issue can try to plant stamps or the adopted marker.
The worst outcomes are overwriting someone's text or pointing the controller at forged instructions.
Adoption therefore refuses a body that already contains any `agentic-flow:` comment, and the controller
keeps taking intent from the approved revision, not from the preserved text.

## Failure behavior
| External call | On timeout | On malformed response | On partial success |
|---|---|---|---|
| `gh issue view` | fail before any mutation | fail before any mutation | n/a |
| `gh issue edit` | exit nonzero | n/a | rerun resumes: stamped issues are found by stamp |

Bounds: at most one `--adopt` per step; adopted body plus packet within GitHub's 65,536 characters.

## Out of scope / What NOT to build in this pass
- Adopting from legacy JSON specs, moving a stamp between issues, or removing one.
- Matching by title, bulk import, or editing titles of adopted issues.
- Changes to the controller.

## Open questions
- None blocking.

---

# Part B — Implementation Brief

## Acceptance scenarios
- Given a missing, closed or pull-request number, or one in another repository, when adopted, then the
  run fails and nothing is created, edited or labelled.
- Given an issue that already carries an `agentic-flow:` comment for another plan or step, then it fails.
- Given an unknown step id, a repeated step or number, or `tracker` on a Standard plan, then it fails.
- Given a step already stamped on a different issue, then it fails and names that issue.
- Given one invalid mapping among several, then no issue is changed.
- Given a valid mapping, when applied, then the issue keeps its title and original text, gains the packet,
  stamps and workflow labels, no issue is created for that step, and the doc records its URL.
- Given an adopted issue, when reapplied without `--adopt`, then the original text and any edits above the
  marker survive and only the part below it changes.
- Given dry run or `--diff`, then the mapping is reported and nothing is mutated.

## Invariants
- Without `--adopt`, behavior and rendered bodies are unchanged for non-adopted issues.
- `--adopt` requires `--doc` with an approved revision, and Standard still records the approver.
- Adoption keeps existing labels and adds the creation labels once.
- Strict steps without a mapping are created as today.

```agentic-flow-plan
format: 2
id: adopt-issues
profile: standard
branch: adopt-issues
steps: f-1
```

## Branch
Base: `main`. One branch and one PR; the commit says `Fixes #<work issue>`.

## Definition of done (whole brief)
The step's DoD is met and `make check` and `make test` are green.

## Verification commands
```bash
make check
make test-one F=plan-to-issues
make test
```

---

## F-1 — Adopt existing issues in plan-to-issues
**Why first:** it is the whole change.

**Approach:** Parse and validate every mapping, and fetch each named issue directly (the stamp search will
not return it), before the first mutation. Feed adopted issues into the existing identity index so the
topology and duplicate checks apply. Preserve everything above the adopted marker on every later body
write, including approval migration. Document the flag in the script header, METHODOLOGY.md section 6,
the shared plan-to-issues skill template and its rendered copies. Add a CHANGELOG entry and bump VERSION.

**Test:** Extend `scripts/tests/plan-to-issues.sh` with the offline fake `gh`, failure scenarios first,
asserting that no mutating call was made.

**DoD:** All acceptance scenarios are covered and pass; the docs and rendered skills agree.
**Verify:** `make test-one F=plan-to-issues`
**Risks:**
- A reapply that drops the original issue text.
- Approval migration or topology detection misreading preserved text.
- Self-test wall-time ceilings and new assertion messages may need their recorded updates.
**Red-first:** none
**Commit:** `Adopt existing issues in plan-to-issues`

---

## Status / Implementation status
<!-- Finalized by the closer before the last repository commit. -->
- **Evidence schema:** v2
- **Tracking issue:** url=https://github.com/wabkebab/agentic-flow/issues/211
- **Approval:** status=approved; by=wabkebab; at=2026-11-25; rev=148c0df74416e80c191a4d506c479dee17ee8c33
- **Implementation head:** source=pr-head
- **Implementation PR:** source=final-approval
- **Verification evidence:** source=final-approval-run
- **Review verdict:** source=close-out-attestation
- **Memory:** status=n/a
- Close-out: `ship` finalizes Status and Tracker, sets TRIAGE to Done, and commits this
  document's move and the updated index before the first push. It opens the PR and
  waits for CI. The reviewer runs `final-approve` to record the PR, head, and run attempt
  on the tracking issue. `ship` verifies that evidence, closes the issue, and runs
  the pre-merge check before the human merges. If a closer command is unavailable,
  commit the staged close-out and rerun `ship`.
