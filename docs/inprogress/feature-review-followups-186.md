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
   inside-worktree refusal. **Reachability (checked on Git 2.55.0):** `rev-parse
   --show-toplevel` returns the physical path from an alias, and the CLI's `cd "$root"`
   (`scripts/lib/start.sh`, `plan_worktree_cmd`) makes `$PWD` physical before the guard
   runs, so the bypass does not reproduce here. Treat this as preventive hardening.
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
   exit 3 forever; only `pending` records complete. The `pending` path deletes every
   `refs/agentic-flow/salvage/<id>/` ref without an ancestry check, and those refs may be
   the only pointers to unshipped commits.

## Proposed approach
**One Standard step, one commit** (chosen by the owner). The six items are small and
independent, so a single review pass covers them. Alternative considered: Strict with six
steps — more per-item history, disproportionate overhead for fixes this size.

Decisions the executor must honor:
- Item 1 is hardening of an unreachable-through-the-CLI path: compare against `pwd -P`.
  Two tests with distinct expectations: (a) a CLI case `cd`-ing through an alias refuses
  on both revisions (compatibility check, since Git and `cd "$root"` normalize the path);
  (b) a unit-level call of the clean function from a logical-`$PWD` alias, against an
  otherwise eligible fixture (worktree present, clean, branch merged), **fails on the
  baseline** (the guard misses the alias and the worktree is removed) and passes after.
  Test (b) is item 1's Red-first evidence.
- Item 3 keeps the hidden-wrapper check (`<!-- ` opener plus `-->` terminator) as the
  predicate for metadata. `journal_marker_line` also accepts bare transition lines, so use
  it only to share the marker-text rule, never as the sole predicate. A bare marker line
  must still be treated as an ordinary comment. Refactor must be behavior-preserving.
- Item 5 applies to **unstamped** plans only. A `journal=v1` stamp disables legacy replay
  (`scripts/lib/journal.sh:17`); that must not change.
- Item 6: recovery applies only to an `open` record with no worktree whose branch ref is
  **confirmed absent**. Use `git show-ref --exists "$branch_ref"`, which separates exit 2
  (missing) from exit 0 (present, including a dangling symbolic ref) and any other status
  (lookup error, exit 3); `--verify --quiet` returns 1 for both missing and dangling, so
  do not use it here. `--exists` needs Git 2.43; the repository states no Git floor, so
  the floor applies only to this recovery. If `--exists` is unsupported (exit 129),
  recovery is unavailable: `clean` keeps today's `cannot resolve branch` refusal, adds the
  hint "Git 2.43 or newer is required to recover this record", and exits 3. Start's
  eligibility check is **not** changed, so no Git version loses a path it has today.
  A ref that is present but does not
  resolve to a commit keeps today's
  `cannot resolve branch` refusal; do not collapse the two cases through the existing
  `rev-parse "$branch_ref^{commit}"` check. The recovery makes **one** atomic
  `open` → `closed` write (`plan_record closed`) and never writes `pending`, so an
  interruption cannot send a retry into the `pending` path that deletes salvage refs.
  It preserves all salvage refs (no ancestry check is possible), prints them, and exits 0.
  `--dry-run` stays read-only (no record write) and prints "Would mark record closed;
  salvage refs preserved: …". The existing `pending` path is unchanged. A record whose
  branch ref exists keeps today's behavior.
- Start/clean coordination for one plan ID: both non-dry-run commands take an exclusive
  per-plan lock, `mkdir "$common/agentic-flow/worktree-locks/<id>"` (atomic, Bash 3.2-safe,
  no `flock`). It is a separate namespace: `locks/<id>` belongs to `handoff` (which moves
  a lock without a PID file after two seconds) and `locks/controller-<id>` to the
  controller; neither may be reused. The lock directory holds an `owner` file with the
  holder's PID; a directory without one is treated as held, never as stale. It is held from before their first eligibility check until after their last record
  write, and released on every exit path including INT/TERM and start's rollback. `clean`
  re-reads the record and re-checks branch and worktree absence **under the lock**
  immediately before the `closed` write. Contention fails fast with exit 3 and a message
  naming the lock directory. A lock is never stolen automatically. Only when `owner`
  names a PID that `kill -0` shows is not running does the message give the manual
  remedy (remove `owner`, then `rmdir` the directory); otherwise it says to wait. `--dry-run` takes no lock. Result: a fresh
  `open` record from a concurrent `start` is never overwritten by `closed`.
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
- Given the clean function called from a logical-`$PWD` alias of the plan worktree, over
  an otherwise eligible fixture, then it refuses with the inside-worktree error and
  removes nothing (fails on the baseline); the CLI alias case and the direct-`cd` case
  refuse on both revisions.
- Given a review comment line of exactly `agentic-flow-review: `, then lifecycle reports
  `BLOCKED ... malformed review record` and exits normally, on bash 3.2.
- Given a hidden-wrapper findings comment and a bare transition-line comment, then
  `packet-findings.sh` parses structured findings only from the hidden wrapper and treats
  the bare form as ordinary; results are identical on the existing packet fixtures at both
  the base and the new revision.
- Given a workflow format the key script cannot parse, then the key step publishes no
  `key`, App checks stay eligible when the path filter selects them, and the warning is
  emitted. A contracts test mutates the format and asserts all three, for both
  `.github/workflows/ci.yml` and `templates/ci/ci.yml`.
- Given an **unstamped** plan whose thread has `<!-- agentic-flow-transition: garbage`
  followed by bare `Implemented in <sha>` and review-marker comments, then those later
  comments still replay. Given the same comments on a `journal=v1` issue, they are still
  ignored.
- Given an `open` record whose worktree is gone, whose branch ref is confirmed absent, and
  a salvage ref still present, then `clean` marks the record `closed`, keeps the salvage
  ref, and a retry prints "Nothing to remove". A fault injected after the write attempt
  never leaves the record `pending`. `--dry-run` writes nothing and reports the refs would
  be preserved. Given no salvage refs it also marks the record closed.
- Given a stale-looking `locks/<id>` handoff lock and a held worktree lock for the same
  plan ID, then neither protocol moves, blocks, or removes the other's directory, and a
  worktree lock with no `owner` file is never treated as stale.
- Given a Git whose `show-ref --exists` exits 129 (a PATH shim in the test), then `clean`
  on that record exits 3 with the Git 2.43 hint, and `start` behaves exactly as today.
- Given the per-plan lock held, then `start` and non-dry-run `clean` for that ID exit 3
  without touching refs, worktrees, or the record, and `--dry-run` still works. Given
  `clean` finishing before `start`, then `start` creates a fresh `open` record that a
  later `clean` run sees; the lock is released after failures and interrupts.
- Given a dangling symbolic branch ref, then `clean` exits 3 with `cannot resolve branch`.
- Given an `open` record whose branch ref exists but cannot resolve to a commit, then
  `clean` still exits 3 with `cannot resolve branch`; given a resolvable branch, behavior
  is unchanged.

## Invariants
- Bash 3.2 compatible: no `mapfile`, no associative arrays, guard empty arrays under
  `set -u`.
- All six paths stay fail-closed; none gains an authorization path.
- `clean` never deletes a ref it cannot prove was shipped.
- The `journal=v1` stamp keeps legacy replay disabled.
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
Every scenario with an observable baseline failure (items 1, 2, 4, 5, 6) is covered by a
test declared under Red-first that fails on the base and passes after. Only item 3 is a
pure compatibility check: its packet fixtures must be green on both revisions. Item 1's
CLI alias case is also a compatibility check; its unit-level guard test is the Red-first
evidence. `make check` and
`make test` green; no unrelated behavior changed.

Bash 3.2 evidence is collected on the executor's macOS host, where `/bin/bash` is 3.2.57:
the empty-marker test prints `$BASH_VERSION` and runs `scripts/lifecycle-status.sh` under
`/bin/bash`. CI's App job runs on Ubuntu (newer Bash, where the empty-array expansion does
not abort), so CI is not Bash 3.2 evidence; the Red-first failure for item 2 is expected
only on the macOS host.

## Verification commands
```bash
make check
make test-one F=lifecycle     # items 2, 5 (empty marker under /bin/bash 3.2)
make test-one F=controller    # items 1, 6 (clean guard, salvage preservation)
make test-one F=stations      # item 3 (packet fixtures, both marker forms)
make test-one F=contracts     # item 4 (active workflow and shipped template)
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

**Test:** Cover every acceptance scenario, failure paths first: lock namespaces, old-Git
shim, lock contention and
dangling ref, logical-`$PWD` guard,
empty review marker (run explicitly under `/bin/bash`, Bash 3.2), unparseable App filter
(no key, App checks still eligible, warning, both workflow files), near-miss marker on
unstamped and `journal=v1` issues, open record with a salvage ref left.

**DoD:** All six scenarios pass; `make check` and `make test` green.
**Verify:** `make test-one F=lifecycle && make test-one F=controller && make test-one F=stations && make test-one F=contracts`
**Risks:**
- Item 6 must not use `show-ref --verify --quiet` as its absence test, must not reuse
  the handoff or controller lock namespaces, and the lock must never be stolen
  automatically.
- Item 6 must not complete a record whose branch ref exists (resolvable or not), must
  not write `pending`, and must not delete salvage refs.
- Item 3 must not let a bare marker line enter structured findings parsing.
- Item 5 must not re-enable legacy replay on `journal=v1` issues.
**Red-first:** `scripts/self-test.sh --only lifecycle` — scripts/tests/lifecycle.sh
**Red-first:** `scripts/self-test.sh --only controller` — scripts/tests/controller.sh
**Red-first:** `scripts/self-test.sh --only contracts` — scripts/tests/contracts.sh
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
