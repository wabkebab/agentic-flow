<!-- TRIAGE (first pass · 2026-11-24) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Standard
> Six small robustness fixes found reviewing PR #185 (issue #186). Next: human approval, then `plan-to-issues`.

# Feature — Review follow-ups from the flow-ergonomics final review

## Tracker
- [ ] F-1 Land the six PR #185 review follow-ups — open

---

# Part A — Analysis

## Goal
Close the six non-blocking findings from the PR #185 final review (issue #186) so the
flow's fail-closed paths report clearly instead of crashing, bypassing a guard, or going
silent. No new behavior beyond those six.

## Current state
Each item was verified against `main` at `6bee48d`:

1. `scripts/lib/start.sh:230` compares logical `$PWD` with `$top`, which is `pwd -P`
   normalized on the line above. A symlink alias into the plan worktree bypasses the
   inside-worktree refusal.
2. `scripts/lifecycle-status.sh:117-119` splits an empty marker into an empty array;
   `"${parts[@]}"` is unbound under `set -u` on bash 3.2, so the whole script exits.
3. `scripts/lib/packet-findings.sh:15` hardcodes the `<!-- agentic-flow-transition:`
   opener instead of `journal_marker_line` (`scripts/lib/journal-marker.jq:3`).
4. `scripts/app-input-key.sh:14-16` exits 1 silently-to-CI when the workflow filter cannot
   be read; `.github/workflows/ci.yml:62-66` runs it `continue-on-error`, so App checks
   run every time with no visible signal.
5. `scripts/lib/journal.jq:53-56` sets `.prefix=false` before the transition line is
   validated, so a near-miss marker stops legacy prose replay for the rest of the thread.
6. `scripts/lib/start.sh:286-287` makes an `open` record with no worktree and no branch
   exit 3 forever; only `pending` records complete.

## Proposed approach
**One Standard step, one commit** (chosen by the owner). The six items are small and
independent, so a single review pass covers them. Alternative considered: Strict with six
steps — more per-item history, disproportionate overhead for fixes this size.

Decisions the executor must honor:
- Item 6 takes the optional path: an `open` record with no worktree **and** no branch tip
  completes like `pending`. A record with a branch but no worktree keeps today's behavior.
- Item 4 fails safe as today; it only adds a visible signal.
- Item 5 flips `.prefix` only when the transition line parses, matching the bare path.

## Interface (before the implementation)
No new commands, flags, or data shapes. New output only: one Actions `::warning` /
step-summary line, "App-input key unavailable; App checks run every time".

## Threat model (one paragraph)
No new trust boundary. Items 1 and 2 harden handling of caller path aliases and
attacker-influenced comment text; both only tighten behavior and stay fail-closed.

## Failure behavior
No new external calls. Failing paths stay fail-closed: an unparseable review marker
reports `BLOCKED ... malformed review record`; an unreadable App filter still runs App
checks and now says so.

Bounds: no new loops or queries.

## Out of scope / What NOT to build in this pass
- Parallel App jobs (deferred, fe-1 in `docs/accepted_risks.md`).
- The PR #185 empty body; tests already demonstrate the rendered body.
- Any behavior change beyond the six items.

## Open questions
- None blocking.

---

# Part B — Implementation Brief

## Acceptance scenarios
- Given `clean <plan>` run from a symlink alias into the plan worktree, then it refuses
  with the inside-worktree error and removes nothing; the direct-`cd` case still refuses.
- Given a review comment line of exactly `agentic-flow-review: `, then lifecycle reports
  `BLOCKED ... malformed review record` and exits normally, on bash 3.2.
- Given a findings comment, then `packet-findings.sh` detects the opener through
  `journal_marker_line`, with identical results to today on existing fixtures.
- Given a workflow format the key script cannot parse, then the CI step still falls back
  to running App checks and emits the warning; a contracts test mutates the format and
  asserts the warning.
- Given a `journal=v1` plan whose thread has `<!-- agentic-flow-transition: garbage`
  followed by bare `Implemented in <sha>` and review-marker comments, then those later
  comments still replay.
- Given an `open` record whose worktree and branch are both gone, then `clean` completes
  and removes the record; given a branch still present, behavior is unchanged.

## Invariants
- Bash 3.2 compatible: no `mapfile`, no associative arrays, guard empty arrays under
  `set -u`.
- All six paths stay fail-closed; none gains an authorization path.
- `export.sh`, `doctor.sh`, and `self-test.sh` stay consistent in the same commit; new
  assertion messages follow the existing `scripts/tests/assertion-*` convention.

```agentic-flow-plan
format: 2
id: review-followups-186
profile: standard
branch: review-followups-186
steps: f-1
```

## Branch
Base: `main`. One branch (`review-followups-186`) and one PR; one commit closing the work
issue via `Fixes #N`.

## Definition of done (whole brief)
All six scenarios covered by tests that fail before the change and pass after;
`make check` and `make test` green; no unrelated behavior changed.

## Verification commands
```bash
make check
make test-one F=lifecycle
make test-one F=controller
make test-one F=contracts
make test
```

---

## F-1 — Land the six PR #185 review follow-ups
**Why first:** it is the only step; the items are independent, so order inside it is free.

**Approach:** Apply the six fixes as described under Proposed approach, each with its own
regression test next to the existing coverage: item 1 and 6 in
`scripts/tests/controller.sh` (near the `clean` cases), item 2 in
`scripts/tests/lifecycle.sh`, item 4 in `scripts/tests/contracts.sh`, items 3 and 5 in
whichever group already covers the packet and journal replay.

**Test:** Cover every acceptance scenario, failure paths first: symlink-alias refusal,
empty review marker, unparseable App filter warning, near-miss legacy marker, open record
with nothing left.

**DoD:** All six scenarios pass; `make check` and `make test` green.
**Verify:** `make test-one F=lifecycle`
**Risks:**
- Item 6 must not complete a record whose branch still exists.
- Item 3 must keep results identical on existing packet fixtures.
**Red-first:** `scripts/self-test.sh --only lifecycle` — scripts/tests/lifecycle.sh
**Commit:** `Fix the six PR #185 review follow-ups.`

---

## Status / Implementation status
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
