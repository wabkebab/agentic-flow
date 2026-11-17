<!-- TRIAGE (first pass · 2026-11-17) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict
> Phase 3 of `product-harness-factory-optimization.md` (T-1 to T-8, R-15): run each test group once per commit and once per full suite, make per-step runs scenario-sized, stop a group from growing unnoticed, and stop adopters running the harness's internal tests on every `make test`. Part A is the analysis; Part B lists candidate steps and is not yet an approvable brief. Runs after Phase 2b (`feature-station-hardening.md`).

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
- a group's wall time cannot grow 20× without a failing check naming the step that did it;
- an adopter's `make test` runs the checks that depend on the adopter's own files, and runs the harness's internal groups only when harness files change.

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
- A full `make test` takes **32 min 10 s** (`b6c1962`, 2026-11-17; 843 s user, 943 s system). During it, the nested exported-layout suite runs as a second `self-test.sh --full` process.
- The full-mode copy budget was exceeded for all of Phase 2 without anyone seeing it. The first full `make test` on `phase-2` failed only at its last check: 325 fixture file copies against a budget of 311. No new `cp` lines landed after C-1; C-2 to C-6 added scenarios that reuse the copying fixture resets. The budget is checked only in a full run, and every per-step Verify line ran `make test-one`. The owner approved 325 as the new baseline (`b6c1962`). This is the case for T-6 (per-group budgets checked on per-step runs) and T-7 (a full run once per plan).
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

Adopters run the controller and stations groups on every `make test`, and nobody decided they should. Four things combine:

1. The payload exports `scripts/` as one directory (`config/payload.tsv`, `scripts` row) with no row for `scripts/tests/`. The stations tests (`0e7cdde`, 2026-11-12) and controller tests (`2172760`, 2026-11-15) landed in a directory that already shipped.
2. The template `Makefile` maps `test:` to `self-test.sh --full`, and the shipped CI template runs `make test` (`templates/ci/ci.yml:124`).
3. In an exported project `--full` skips only the groups that need the source-only exporter (export, upgrade). There is no scaffold-only category. The file's own header still says an exported project checks "only the local invariants: hooks and spec validation" (`self-test.sh:4-6`).
4. The export group asserts that the full suite passes inside a fresh export (`self-test.sh:820-824`), so the scaffold's `make test` enforces it.

The adopter gains almost nothing. These groups drive the harness's own scripts against stub CLIs and fixtures, byte-identical to what the scaffold's CI already ran. The only new information is that the harness runs on that machine's bash, jq, git and perl, which a short smoke test or Phase 2b's station probe covers better. Each clone's ledger stays local (`.git/agentic-flow/ledger`), so no timing data is exported.

## Proposed approach

| ID | Change | Expected saving |
|---|---|---|
| T-1 | **Verify once per commit.** `verify-step` returns the stored record when commit, tree, verifier implementation hash, signature source and harness version all match: the same freshness test `packet.sh` already applies. `--force` re-runs. Contracts: under the controller the executor does not run `verify-step` and the reviewer reads the packet's record. A reviewer re-runs only for a stale or failed record, or to test a specific doubt with a narrower command it names (decided 2026-11-17). | 1–2 group runs per step, plus each bounce |
| T-2 | **Exported-layout suite at close-out, not in every `make test`.** The export group's fresh export runs `--fast` plus a check that `make check` passes. The full suite in exported layout moves to its own target, which `ship` runs locally on the final head, after the close-out commit and before the final push (`ship.sh:111`). A failure stops the push. CI still runs it. | About one controller-group run (10+ min) per everyday `make test`; paid once per plan instead |
| T-3 | **Profile before cutting.** A timing wrapper on `c4_run`, `c5_run` and the resets, enabled by an environment variable, reports per-scenario seconds in one run. | Turns T-4 into a measured decision |
| T-4 | **Scenario selection.** Split `controller.sh` and `stations.sh` into tagged scenario files (launch, ledger, recovery, ship, andon). `make test-one F=controller S=<tag>`. A step's Verify line names its scenarios; the whole group runs at the end of the plan and in CI. | Likely 10 min down to a few per step; T-3 confirms |
| T-5 | **Parallel groups in `--full`.** Fixtures are already isolated and concurrent runs are supported. Wall time becomes the slowest shard. | Large once T-4 creates shards |
| T-6 | **Wall-time budget.** Record seconds per group next to the copy counts and fail when a group exceeds its own approved ceiling (per group, decided 2026-11-17), so the step that grows it is named. | Prevents a repeat of 32 s → 673 s |
| T-7 | **Gate cadence in the contracts.** Per step: `make check` and the step's Verify command only. Full `make test` once at the end of the plan. Reviewer: no test runs by default (T-1). | Removes the extra groups executors run today |
| T-8 | **Adopter test scope.** Each group declares a scope: `local` if it tests the adopter's real files, or `scaffold` if it runs harness scripts against fixtures (controller, stations, lifecycle, plan-to-issues, export, upgrade; contracts and hooks pending the audit under Decisions). In an exported project, `--full` runs the `local` groups, and the `scaffold` groups only when the change touches harness-owned paths from the payload manifest, as an upgrade commit does. The check is a diff against the merge base, so it needs no local state and works the same in CI. `--full --all-groups` forces everything. The export group's assertion changes to match, and the `self-test.sh` header becomes true again. Non-breaking; it does not wait for R-14b. | The controller and stations runtime on every adopter `make test`, locally and in CI |
| R-15 | **Split `self-test.sh` into `tests/<group>.sh`** (moved here from the cleanup list). T-4 and T-5 build on the split. Add an adopter-twin fixture (customized `CLAUDE.md` and `Makefile`, realistic commit commands) and run upgrade, hooks and `make check` against it as holdout scenarios. | Enables T-4/T-5 |

### Ordering

**Option A — measure, then cut (recommended).** First T-3, T-1 and T-2, plus T-7's contract text. These are small, remove most of the repeats, and do not change coverage. T-8 lands with T-2, since both change the export group's assertion about the exported suite. Then R-15 with T-4 and T-5, guided by the profile. Then T-6, with ceilings set from the post-split timings.

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

# T-2: close-out gate, owned by the Makefile like every other command
make ship-gate        # optional target; ship runs it before the final push when it exists
                      # this repo: the full suite inside a fresh export (exported layout)
                      # adopters: whatever their Makefile defines, or nothing
ship: non-zero ship-gate → stop before push, print the failing group, exit 1

# T-8: group scope, declared once next to SELF_TEST_GROUPS (final split after the audit)
local:    groups that test the adopter's real files
scaffold: export upgrade plan-to-issues lifecycle stations controller (+ contracts, hooks if fixture-only)
exported project, --full: local groups; + scaffold groups when
  git diff --name-only <merge-base>...HEAD touches a payload-manifest destination
self-test.sh --full --all-groups          # force every group
```

## Threat model

Verify reuse turns a stored record into permission to skip a gate. The record is keyed by commit, tree and the verifier's own hash, so a code or verifier change re-runs. The new risk is a forged record. Records live in `.git/agentic-flow/verify/`, which no station may write; Phase 2b's P-1 makes that a tested property, so T-1 must not land before it. A human can still edit the record by hand, as they can skip any local gate today. CI does not use local records and runs the full suite.

T-8 lets an adopter skip harness-internal groups. The risk is a harness defect that only shows on the adopter's platform. The scaffold's own CI runs every group, the `scaffold` groups still run on any change to harness-owned files, and Phase 2b's probe exercises the real launcher on the adopter's machine. A hand edit to a harness file is itself a change to a harness-owned path, so it triggers the full run.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---|---|---|---|
| `verify-step` reuse lookup | n/a (local file) | Unreadable or mismatched record → run the full verification | n/a |
| Parallel groups (T-5) | Each shard keeps its own timeout | n/a | Any failing shard fails `make test`, and every failing shard is reported |
| Scenario selection (T-4) | As the group | Unknown tag → exit 2, nothing runs | n/a |
| Harness-change detection (T-8) | n/a (local git) | Merge base unknown (shallow clone, detached CI checkout) → run every group | n/a |

Bounds: parallel shards capped at the CPU count; each shard keeps the group's existing timeouts.

## Out of scope / What NOT to build in this pass

- Dropping any group or scenario from CI's full run. Selection (T-4) applies to per-step runs only.
- Changing what any group asserts. T-3 to T-5 change how tests run, not what they check.
- Sharing verify records across machines or with CI.
- Not exporting the harness tests at all. T-8 keeps them in the payload so an upgrade can run them; R-14b's harness/project split (Phase 4) may later make that cleaner.

## Decisions

- **T-1: a doubting reviewer runs a narrower command** (owner, 2026-11-17). It names the command it runs, for example one scenario or one test, and records it with its verdict. `--force` stays for a human or an executor who changed the environment; it is not the reviewer's tool.
- **T-6: ceilings per group** (owner, 2026-11-17), so a failure names the group that grew.
- **T-8: a group is `local` only if it tests the adopter's real files** (owner, 2026-11-17). Groups that run harness scripts against fixtures are `scaffold`. A first look: `lifecycle` runs against synthetic fixtures (`self-test.sh:4153`, `$TMP/lifecycle-v2`), so it is `scaffold`; contracts and hooks also appear to exercise harness scripts with fixtures. The brief audits each group. The `local` set may be nearly empty, because the checks that read an adopter's real files (harness sync, payload manifest, docs index, memory index, action pins) already run in `make check`.

- **T-2: the exported-layout suite runs at close-out, before CI** (owner, 2026-11-17). It leaves everyday `make test`. `ship` runs it locally through an optional `make ship-gate` target on the final head, after the close-out commit and before the final push, so adopter-layout breakage is caught before anything ships. CI keeps running it too, because CI is the merge gate and runs on a different platform. The cost is about 10+ minutes once per plan, at the end, instead of on every `make test`.

## Open questions

- None open.

---

# Part B — Implementation Brief

> Not drafted yet. Part A has to be reviewed first. Candidate step order, per Option A:
>
> 1. T-3 profile wrapper; T-1 verify reuse with `--force`; T-7 contract text.
> 2. T-2 export group runs `--fast` plus `make check` in the fresh export; the full exported-layout suite becomes `make ship-gate`, run by `ship` before the final push and kept in CI. T-8 group scopes and harness-change detection in the same step.
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
