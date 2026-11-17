<!-- TRIAGE (first pass · 2026-11-17) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict
> Phase 3 of `product-harness-factory-optimization.md` (T-1 to T-7, R-15): run each test group once per commit and once per full suite, make per-step runs scenario-sized, and stop a group from growing unnoticed. Part A is the analysis; Part B lists candidate steps and is not yet an approvable brief. Runs after Phase 2b (`feature-station-hardening.md`).

# Feature — Test streamlining

## Tracker
<!-- Filled in when the brief is approved and plan-to-issues runs. -->
- [ ] Brief not drafted yet; see Part B for the candidate steps.

---

# Part A — Analysis

## Goal

The same slow test group runs three to four times per step, and twice more per full `make test`. Only one of those runs carries new information. Cut the repeats and make per-step runs scenario-sized, without weakening any gate.

Success:

- a step whose Verify line names one test group runs that group once per commit, not three or four times;
- `make test` runs each group once;
- a per-step Verify runs the scenarios the step touched, in minutes, while CI still runs everything;
- a group's wall time cannot grow 20× without a failing check naming the step that did it.

## Current state

References are to `phase-2` at `7599d61`, which is not on `main` yet.

### Measured test cost

Verify records in `.git/agentic-flow/verify/` time every command `verify-step` runs:

| Commit (step) | `make check` | Step's Verify group | Red-first run |
|---|---|---|---|
| `b63be2e` (C-3) | 4 s | controller **32 s** (+ stations 120 s, lifecycle 34 s, hooks 14 s) | 0–5 s |
| `0772cc4` (C-4) | 4 s | controller **296 s** | 0 s |
| `d3e527d` (C-5) | 4 s | controller **615 s** | 32 s |
| `9108b74` (C-6) | 3 s | controller **673 s** (+ hooks 14 s) | 1 s |
| `9bd5011` (C-7) | 2 s | contracts 25 s | – |

- `make check` is not the cost. It takes 2–4 s, and the Stop hook already skips it on an unchanged tree (`scripts/hooks/check-gate.sh`, state hash).
- The controller group grew about 20× across three steps. `scripts/tests/controller.sh` has 1,726 lines, about 83 `c4_run`/`c5_run` controller invocations (`:1117`, `:1556`) and 48 fixture resets. Nothing flagged the growth: `assert_cost_budget` (`scripts/self-test.sh:134`) counts file copies, not time.
- The export group alone took more than 600 s (`make test-one F=export`, 2026-11-17).
- A full `make test` on `7599d61` was still running after 16 minutes (2026-11-17).
- Not measured yet: how the controller group's time splits across scenarios.

### Where a group runs more than once

For one step whose Verify line names the controller group, with no bounce:

| # | Who | What runs | Source |
|---|---|---|---|
| 1 | Executor | `make check` and `make test-one F=<group>` per step, and in practice other groups too. For C-7 Codex ran contracts and build and tried controller. | `AGENTS.md:43-44`; C-7 commit body |
| 2 | Controller | `verify-step` re-runs `make check` and every Verify command in a fresh worktree (C-6: 664 s). It never reuses an existing record. | `controller.sh:486`, `verify-step.sh:158-167`, record written at `:200` |
| 3 | Reviewer | The packet already carries that record with a freshness check (`packet.sh:89-104`), but the review contract tells reviewers to run `verify-step`. The C-7 reviewer reported re-running `make check`, contracts and build, and attempting the full `make test` until its 600 s timeout. | `.agents/skills/review-execution/SKILL.md:68` |
| 4 | Each bounce | Rows 1–3 again. | |

At the end of a plan:

| # | What runs | Source |
|---|---|---|
| 5 | Local `make test` runs every group, then the export group runs `self-test.sh --full` inside a fresh export, which runs the controller and stations groups a second time. | `self-test.sh:822` |
| 6 | CI runs the same `make test`, with the same doubling. | `.github/workflows/*.yml` (`make check`, `make test`) |

The planner pays too. Fixing the launcher during C-7 took 15 runs of the controller group, about 10 minutes each. Six of them iterated on one failing assertion, which a scenario selector would have run in seconds.

### Adopters

`scripts/tests/` and `self-test.sh` ship in the payload (`config/payload.tsv`, `scripts` row). An adopter's template `Makefile` runs `self-test.sh --fast` for `make check` (cheap) and `--full` for `make test`. In an exported project, `--full` skips only the export group, so every adopter `make test` runs the controller group against harness code the adopter never changes. Each clone's ledger stays local (`.git/agentic-flow/ledger`), so no timing data is exported.

## Proposed approach

| ID | Change | Expected saving |
|---|---|---|
| T-1 | **Verify once per commit.** `verify-step` returns the stored record when commit, tree, verifier implementation hash, signature source and harness version all match: the same freshness test `packet.sh` already applies. `--force` re-runs. Contracts: under the controller the executor does not run `verify-step` and the reviewer reads the packet's record. A reviewer re-runs only for a stale or failed record, or to test a specific doubt with a narrower command. | 1–2 group runs per step, plus each bounce |
| T-2 | **No nested full suite in the export group.** The fresh export runs `--fast` plus the hooks and contracts groups. The full suite in exported layout becomes its own CI job, not part of local `make test`. | About one controller-group run (10+ min) per `make test`, locally and in CI |
| T-3 | **Profile before cutting.** A timing wrapper on `c4_run`, `c5_run` and the resets, enabled by an environment variable, reports per-scenario seconds in one run. | Turns T-4 into a measured decision |
| T-4 | **Scenario selection.** Split `controller.sh` and `stations.sh` into tagged scenario files (launch, ledger, recovery, ship, andon). `make test-one F=controller S=<tag>`. A step's Verify line names its scenarios; the whole group runs at the end of the plan and in CI. | Likely 10 min down to a few per step; T-3 confirms |
| T-5 | **Parallel groups in `--full`.** Fixtures are already isolated and concurrent runs are supported. Wall time becomes the slowest shard. | Large once T-4 creates shards |
| T-6 | **Wall-time budget.** Record seconds per group next to the copy counts and fail when a group exceeds its approved ceiling, so the step that grows it is named. | Prevents a repeat of 32 s → 673 s |
| T-7 | **Gate cadence in the contracts.** Per step: `make check` and the step's Verify command only. Full `make test` once at the end of the plan. Reviewer: no test runs by default (T-1). | Removes the extra groups executors run today |
| R-15 | **Split `self-test.sh` into `tests/<group>.sh`** (moved here from the cleanup list). T-4 and T-5 build on the split. Add an adopter-twin fixture (customized `CLAUDE.md` and `Makefile`, realistic commit commands) and run upgrade, hooks and `make check` against it as holdout scenarios. | Enables T-4/T-5 |

### Ordering

**Option A — measure, then cut (recommended).** First T-3, T-1 and T-2, plus T-7's contract text. These are small, remove most of the repeats, and do not change coverage. Then R-15 with T-4 and T-5, guided by the profile. Then T-6, with ceilings set from the post-split timings.

**Option B — split first.** Start with R-15's split and scenario tags. This touches the most files before anything is measured, and the profile might show a few scenarios dominate, making a full split unnecessary.

**Recommendation:** Option A. T-1 and T-2 alone remove two to three controller-group runs per step and one per `make test` without moving a single test.

## Interface (before the implementation)

```
agentic-flow verify-step <sha> [--doc <doc> --step <id>] [--red-base <sha>] [--force] [--json]
  reuse: stored record where sha, tree, verifier implementation_sha256,
         signature_source and harness_version all match → print it, exit 0, no run
  --force: always run; overwrite the record

make test-one F=<group> [S=<scenario-tag>[,<tag>…]]
self-test.sh --only <group> [--scenario <tag>]
  AGENTIC_TEST_TIMING=1 → per-scenario seconds on stderr
  cost events gain group:<name>:seconds; full mode fails over an approved ceiling

self-test.sh --full [--jobs <n>]          # T-5; default min(groups, CPUs)
```

## Threat model

Verify reuse turns a stored record into permission to skip a gate. The record is keyed by commit, tree and the verifier's own hash, so a code or verifier change re-runs. The new risk is a forged record. Records live in `.git/agentic-flow/verify/`, which no station may write; Phase 2b's P-1 makes that a tested property, so T-1 must not land before it. A human can still edit the record by hand, as they can skip any local gate today. CI does not use local records and runs the full suite.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---|---|---|---|
| `verify-step` reuse lookup | n/a (local file) | Unreadable or mismatched record → run the full verification | n/a |
| Parallel groups (T-5) | Each shard keeps its own timeout | n/a | Any failing shard fails `make test`, and every failing shard is reported |
| Scenario selection (T-4) | As the group | Unknown tag → exit 2, nothing runs | n/a |

Bounds: parallel shards capped at the CPU count; each shard keeps the group's existing timeouts.

## Out of scope / What NOT to build in this pass

- Dropping any group or scenario from CI's full run. Selection (T-4) applies to per-step runs only.
- Changing what any group asserts. T-3 to T-5 change how tests run, not what they check.
- Sharing verify records across machines or with CI.
- The adopter test cadence (run the harness's full suite only when harness bytes change). It depends on R-14b's harness/project split, so it belongs with Phase 4.

## Open questions

- [BLOCKING] T-2: is the full suite in exported layout acceptable as a CI-only job, so local `make test` no longer runs it?
- T-1: should a reviewer that doubts a record re-run with `--force`, or only with a narrower command the reviewer names?
- T-6: set ceilings per group from the post-split timings, or one global ceiling for `make test`?

---

# Part B — Implementation Brief

> Not drafted yet. Part A has to be reviewed first. Candidate step order, per Option A:
>
> 1. T-3 profile wrapper; T-1 verify reuse with `--force`; T-7 contract text.
> 2. T-2 export group runs `--fast` plus hooks and contracts; full exported-layout CI job.
> 3. R-15 split into `tests/<group>.sh` and the adopter-twin fixture.
> 4. T-4 scenario tags and selector; T-5 parallel shards.
> 5. T-6 wall-time ceilings from the new timings.

## Status / Implementation status
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
