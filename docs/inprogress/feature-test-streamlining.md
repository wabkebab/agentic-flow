<!-- TRIAGE (first pass · 2026-11-17) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict
> Phase 3 of `product-harness-factory-optimization.md` (T-1 to T-8, R-15): run each test group once per commit and once per full suite, make per-step runs scenario-sized, stop a group from growing unnoticed, and stop adopters running the harness's internal tests on every `make test`. Part A is the analysis; Part B is the implementation brief (steps t-1 to t-8), drafted 2026-11-19 and awaiting approval. T-1, T-3 and the controller-group half of T-4 moved into Phase 2b on 2026-11-17 and are not part of this phase's brief. Runs after Phase 2b (`feature-station-hardening.md`).

# Feature — Test streamlining

## Tracker
<!-- Filled in when the brief is approved and plan-to-issues runs. -->
- [ ] Brief drafted 2026-11-19 (t-1 to t-8); awaiting the owner's approval. Branch `phase-3`, based on `phase-2b` while PR #161's CI is cancelled by the runner (see `feature-station-hardening.md`).

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
| T-1 | **Moved to Phase 2b (h-4).** **Verify once per commit.** `verify-step` returns the stored record when commit, tree, verifier implementation hash, signature source and harness version all match: the same freshness test `packet.sh` already applies. `--force` re-runs. Contracts: under the controller the executor does not run `verify-step` and the reviewer reads the packet's record. A reviewer re-runs only for a stale or failed record, or to test a specific doubt with a narrower command it names (decided 2026-11-17). | 1–2 group runs per step, plus each bounce |
| T-2 | **Exported-layout suite at close-out, not in every `make test`.** The export group's fresh export runs `--fast` plus a check that `make check` passes. The full suite in exported layout moves to its own target, which `ship` runs locally on the final head, after the close-out commit and before the final push (`ship.sh:111`). A failure stops the push. CI still runs it. | About one controller-group run (10+ min) per everyday `make test`; paid once per plan instead |
| T-3 | **Moved to Phase 2b (h-1).** **Profile before cutting.** A timing wrapper on `c4_run`, `c5_run` and the resets, enabled by an environment variable, reports per-scenario seconds in one run. | Turns T-4 into a measured decision |
| T-4 | **Controller group moved to Phase 2b (h-2); the `stations` group's tags stay here.** **Scenario selection.** Split `controller.sh` and `stations.sh` into tagged scenario files (launch, ledger, recovery, ship, andon). `make test-one F=controller S=<tag>`. A step's Verify line names its scenarios; the whole group runs at the end of the plan and in CI. | Likely 10 min down to a few per step; T-3 confirms |
| T-5 | **Parallel groups in `--full`.** Fixtures are already isolated and concurrent runs are supported. Wall time becomes the slowest shard. | Large once T-4 creates shards |
| T-6 | **Wall-time budget.** Record seconds per group next to the copy counts and fail when a group exceeds its own approved ceiling (per group, decided 2026-11-17), so the step that grows it is named. Enforced in `--only` runs too, and per tag for the tagged groups, so a step's own Verify run catches growth and close-out does not discover it. | Prevents a repeat of 32 s → 673 s |
| T-7 | **Gate cadence in the contracts.** Per step: `make check` and the step's Verify command only. Full `make test` once at the end of the plan. Reviewer: no test runs by default (T-1). | Removes the extra groups executors run today |
| T-8 | **Adopter test scope.** Each group declares a scope: `local` if it tests the adopter's real files, or `scaffold` if it runs harness scripts against fixtures (controller, stations, lifecycle, plan-to-issues, export, upgrade; contracts and hooks pending the audit under Decisions). In an exported project, `--full` runs the `local` groups, and the `scaffold` groups only when the change touches harness-owned paths from the payload manifest, as an upgrade commit does. The check covers uncommitted and untracked edits as well as commits, against a defined base (see Interface), so it needs no local state and works the same in CI. The shipped CI template fetches enough history for it. `--full --all-groups` forces everything. The export group's assertion changes to match, and the `self-test.sh` header becomes true again. Non-breaking; it does not wait for R-14b. | The controller and stations runtime on every adopter `make test`, locally and in CI |
| R-15 | **Split `self-test.sh` into `tests/<group>.sh`** (moved here from the cleanup list). T-4 and T-5 build on the split. Add an adopter-twin fixture (customized `CLAUDE.md` and `Makefile`, realistic commit commands) and run upgrade, hooks and `make check` against it as holdout scenarios. | Enables T-4/T-5 |

### Ordering

**Option A — measure, then cut (recommended).** T-3 and T-1 moved to Phase 2b on 2026-11-17, so this phase starts at T-2, plus T-7's contract text. These are small, remove most of the repeats, and do not change coverage. T-8 lands with T-2, since both change the export group's assertion about the exported suite. Then R-15 with T-4 and T-5, guided by the profile. Then T-6, with ceilings set from the post-split timings.

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
  cost events gain group:<name>:seconds and, for tagged groups, group:<name>:<tag>:seconds
  ceiling file: one line per group and per tag of the controller and stations groups
  --only <group> (whole group): fails over the group's ceiling
  --only <group> --scenario <tags>: fails over each selected tag's ceiling; the group ceiling
    is not applied to a partial run, and every tag of a tagged group must have a ceiling line
  --full: every group ceiling; with parallel shards the ceiling is checked against the shard's own seconds

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
  the changed set touches a payload-manifest destination, where the changed set is
    git diff --name-only <base>              (committed + staged + unstaged vs the base)
    + git ls-files --others --exclude-standard   (untracked)
    <base> = git merge-base HEAD <ref>, <ref> = first that resolves of
      $AGENTIC_BASE_REF, origin/$GITHUB_BASE_REF, origin/HEAD, origin/main, origin/master
      (never the branch's own upstream: on a pushed feature branch it equals HEAD and would hide the
       branch's committed harness edits; only an integration branch is a valid base)
    no <ref>, no merge base, or any git failure → run every group
self-test.sh --full --all-groups          # force every group
make ship-gate                            # always: self-test.sh --full --all-groups in the fresh export
```

## Threat model

Verify reuse turns a stored record into permission to skip a gate. The record is keyed by commit, tree and the verifier's own hash, so a code or verifier change re-runs. The new risk is a forged record. Records live in `.git/agentic-flow/verify/`, which no station may write; T-1 now lands in Phase 2b, after P-1, which makes that a tested property for the CLIs that have an OS sandbox (OpenCode has none; see `feature-station-hardening.md`, Threat model). A human can still edit the record by hand, as they can skip any local gate today. CI does not use local records and runs the full suite.

T-8 lets an adopter skip harness-internal groups. The risk is a harness defect that only shows on the adopter's platform. The scaffold's own CI runs every group, the `scaffold` groups still run on any change to harness-owned files, and Phase 2b's probe exercises the real launcher on the adopter's machine. A hand edit to a harness file is itself a change to a harness-owned path, so it triggers the full run, committed or not: the changed set includes staged, unstaged and untracked files, so an adopter who edits a harness script and runs `make test` before committing still gets the scaffold groups. The shipped CI template fetches history and the base ref, so ordinary adopter CI computes a real base; where it cannot, every group runs, which is safe but forfeits the saving, and a test covers each such case.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---|---|---|---|
| `verify-step` reuse lookup | n/a (local file) | Unreadable or mismatched record → run the full verification | n/a |
| Parallel groups (T-5) | Each shard keeps its own timeout | n/a | Any failing shard fails `make test`, and every failing shard is reported |
| Scenario selection (T-4) | As the group | Unknown tag → exit 2, nothing runs | n/a |
| Harness-change detection (T-8) | n/a (local git) | No resolvable base ref, no merge base (shallow clone, detached checkout, missing refs) or any git error → run every group | Uncommitted and untracked files always count as changes |

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

> **Audience:** the implementing agent (Codex). Steps are ordered small and coverage-neutral first (contract text, then the exported suite leaves `make test`), then the structural split, then selection, parallelism and ceilings. One logical commit per step; do not bundle. Stage files by name. Why-first commit bodies. The brief carries intent, interface, invariants and acceptance scenarios; you choose files and functions.

```agentic-flow-plan
id: test-streamlining
profile: strict
tracking: Plan: Test streamlining
branch: phase-3
steps: t-1 t-2 t-3 t-4 t-5 t-6 t-7 t-8
```

## Prerequisite

Phase 2b's code is the base: `verify-step` reuse (h-4), controller tags and `S=` (h-2), `AGENTIC_TEST_TIMING` (h-1), the 190-copy budget (h-9) and the per-file lint (h-12). Phase 2b (PR #161) may not be merged when this runs, because its CI is cancelled by the runner (see its Tracker). In that case `phase-3` is created from `phase-2b`, and the human merges both PRs, `phase-2b` first, after CI passes. If `phase-2b` has merged, base on `main`. `.agentic-flow-review-policy` must say `identity-mode=distinct-account`; if it does not, stop and tell the human.

## Branch
Base: `phase-2b` (or `main` once it has merged). One branch and one PR for the whole brief: `phase-3`. Each step is one commit with `Fixes #N`. Review fixes land as new commits; never amend after a handoff. The controller's worktree owns the branch; do not also check `phase-3` out in another worktree.

## Word ceilings

| File | Ceiling | Enforced by |
|---|---|---|
| `CLAUDE.md` (root) | 1530 | `scripts/self-test.sh` (planner) |
| `AGENTS.md` (root) | 1090 | `scripts/self-test.sh` (executor) |
| `.agents/skills/review-execution/SKILL.md` | 1000 | `scripts/self-test.sh` (reviewer) |

Do not raise a ceiling. Only t-1 edits contracts. `CLAUDE.md` and `AGENTS.md` are at 1270 and 952, the reviewer skill at 940, so t-1 has room, but stay under each ceiling. A contract edit to `CLAUDE.md`, `AGENTS.md` or the `Makefile` needs the matching edit in `templates/harness/`.

## Invariants (every step)
- Bash 3.2: no `mapfile`, no associative arrays, guard empty arrays under `set -u`.
- Payload membership lives in `config/payload.tsv` only. New files under `scripts/tests/` ship because `scripts/` is one payload row; do not add a second list.
- No literal placeholder or credential-shaped string in any file; build them with `printf`.
- No group, scenario or assertion is removed or weakened. t-1 to t-8 change when and how tests run, never what they check. Each step that moves code states how it shows nothing was lost (scenario 7).
- The CI full run keeps every group and every scenario.
- `make check` stays under 10 seconds, and the Stop hook's skip-on-unchanged-tree behaviour is unchanged.
- Hermetic tests: fake `gh` and fake CLIs on `PATH`; no network.
- The root `Makefile` and `templates/harness/Makefile` agree on every target this brief adds or changes; a check asserts it.
- Copy budget: no step may raise the 190-copy limit. A step that adds fixtures reuses the existing resets.

## Definition of done (whole brief)
- Every step's DoD is met and all 11 acceptance scenarios pass as tests.
- `make check`, `make test`, `make ship-gate`, `make build` and `scripts/doctor.sh --check` are green here and in a fresh export.
- A full `make test` takes materially less than before: the close-out records the measured time against the 49-minute baseline (`4cfefaa`, local) and names what the nested exported suite and parallel shards each saved.
- An adopter-twin fixture runs upgrade, hooks and `make check` in `make test`.
- Steps t-1 to t-8 ran through `agentic-flow run`. The close-out lists every human `resume` and its cause (Phase 2b baseline: see its close-out).

## Acceptance scenarios (written at Spec; the executor does not edit these)

**T-7**
1. **Gate cadence contract.** `AGENTS.md` says: per step run `make check` and the step's Verify command; run the full `make test` once at the end of the plan; under the controller do not run `verify-step`. `CLAUDE.md` and the reviewer skill agree (reviewer runs no test by default). Every contract and sync check passes, the three files are under their ceilings, and root and `templates/harness/` copies match.

**T-2**
2. **Everyday `make test` runs the exported suite once, not twice.** The export group builds a fresh export, runs its `--fast` suite and `make check` there, and does not run `self-test.sh --full` inside it. A logging wrapper or marker proves the nested `--full` is not invoked from `make test`.
3. **`make ship-gate`.** It runs `self-test.sh --full --all-groups` in a fresh export (this repo), so the exported layout keeps full applicable coverage whatever T-8's filtering decides, and exits nonzero on failure. A test asserts the recipe passes `--all-groups` once t-3 has added the flag. When the Makefile defines `ship-gate`, `ship` runs it on the final head after the close-out commit and before the first push (`ship.sh`, before `git push`); a failing gate stops with exit 1, names the failing group, and a fake `git` records no push. When the target is absent, `ship` prints a notice and continues. When the gate passes, `ship` pushes as before.
4. **CI keeps it.** This repository's `ci.yml` runs `make test` and `make ship-gate` as separate steps, so the exported layout is still tested before merge. `templates/ci/ci.yml` runs whatever the adopter's `make test` defines and is otherwise unchanged.

**T-8**
5. **Every group declares a scope.** `SELF_TEST_GROUPS` and a scope list (`local` or `scaffold`) are validated against each other: a group with no scope, a scope for a missing group, or a scope other than the two fails `make check`. Each group's scope is justified in the commit body from what it reads (the audit decided in Part A).
6. **Exported-project scope.** In an exported project, `self-test.sh --full` runs the `local` groups, and also the `scaffold` groups when the changed set touches a payload-manifest destination (including a hand edit to a harness file and an upgrade commit). The changed set is committed, staged, unstaged and untracked changes against `git merge-base HEAD <ref>`, with `<ref>` chosen as the Interface says: an integration branch, never the branch's own upstream. A pushed feature branch that tracks `origin/<feature>` and carries a committed harness edit, with a clean working tree, triggers the scaffold groups. A harness file edited and left uncommitted, staged only, or newly created and untracked triggers the scaffold groups. An unresolvable base (shallow clone with no merge base, missing refs, no remote, any git error) runs every group. A detached PR-merge checkout with `GITHUB_BASE_REF` set and the base fetched computes a real base and, with no harness change, runs only `local`. `--all-groups` forces every group. In this source repository `--full` behaves as before. The "run the full suite" assertion in the export group and the `self-test.sh` header comment change to match.

**R-15**
7. **The split loses nothing.** After moving each group to `scripts/tests/<group>.sh`, the set of `fail`/assertion message strings found in the files is identical to the set before the move, `SELF_TEST_GROUPS` is unchanged, `--only <group>` passes for every group, and `--full` prints the same "self-test passed." with the same group order. A check compares the message set against a recorded list, so a dropped assertion fails.
8. **The adopter twin.** A fixture exports the scaffold into a project whose `CLAUDE.md` and `Makefile` are customized (renamed targets, a real commit command, extra Make targets, extra hook entries), then runs upgrade, hooks and `make check` against it. A change that works against the pristine export but breaks the customized one (for example the upgrade overwriting a customized Make target) fails the test; a red-first selector shows it.

**T-4 (stations) and T-5**
9. **Stations tags.** The `stations` group splits into tagged blocks and accepts `--scenario <tag>[,<tag>]` with the controller group's rules: a comma list is the union, no flag runs every block, an unknown tag exits 2 and runs nothing, a selection that runs no block fails, each tag passes alone in a fresh checkout. `make test-one F=stations S=<tag>` works in both Makefiles, and `--scenario` stays invalid for every other group.
10. **Parallel shards.** `self-test.sh --full --jobs <n>` runs groups (and controller/stations tag shards) as concurrent processes, default `min(shards, CPUs)`, capped at the CPU count. Each shard keeps its own timeout and its own fixture root. Output is printed per shard in a stable order. Every failing shard is reported and any failure fails the run. `--jobs 1` is the serial order. The copy-count budget is still enforced on the combined event stream, and the full run still proves every expected group executed.

**T-6**
11. **Wall-time ceilings.** Each group's seconds are recorded as cost events next to the copy counts. A whole-group run (`--only <group>` or `--full`) fails when a group exceeds its own ceiling, naming the group, its seconds and its ceiling. A `--scenario` selection fails when a selected tag exceeds that tag's ceiling and does not apply the group ceiling, so a partial run neither hides growth in the tags it ran nor is failed for tags it did not. Every tag of the controller and stations groups has a ceiling line, and `make check` fails when a group or tag has none. Ceilings live in one reviewed file, are set from t-7's measured post-split timings with headroom, and a boundary test shows a value at its ceiling passes and one second over fails, for a group and for a tag. A ceiling change is a diff to that file, so it needs review.

## Verification commands
```bash
make check                          # per step; also run by the Stop hook
make test-one F=<group>             # the group a step names
make test-one F=controller S=<tag>  # controller scenarios
make test-one F=stations S=<tag>    # from t-6 on
make test                           # end of brief
make ship-gate                      # from t-2 on
make build
scripts/doctor.sh --check
```

**Station sandbox.** The executor's sandbox cannot run `ps`, so any test that runs `scripts/lib/recovery.pl` fails there with `cannot read live process start time`, on an unchanged tree too (decided in Phase 2b). Do not weaken the sandbox or skip the test. Run `make check` and every command the sandbox allows, write the controller-group edits and their tests, and the controller's own `verify-step` runs the group outside the sandbox.

---

## t-1 — Gate cadence in the contracts (T-7)
**Why first:** it is text only, removes the extra group runs executors do today, and every later step runs under the new cadence.

**Approach:**
1. Edit `AGENTS.md`, `CLAUDE.md` and `.agents/skills/review-execution/SKILL.md`, and the matching `templates/harness/` copies, to state the cadence in scenario 1. Say it once, in the place each contract already describes verification; do not add a section.
2. Keep each file under its ceiling. Trim redundant wording as you add.

**Test:** scenario 1. The existing contract and sync checks must still pass; add one assertion that the cadence sentence is present in the root and template copies.

**DoD:** scenario 1 passes; no ceiling is raised.
**Verify:** `make test-one F=contracts`
**Risks:** a root/template copy drifting; an edit that contradicts the h-4 reviewer rule (read the packet's record first; re-run only a named narrower command); pushing a file over its ceiling.
**Red-first:** `scripts/self-test.sh --only contracts` — scripts/self-test.sh
**Commit:** `State the gate cadence: check and the step's verify per step, the full suite once at the end`

## t-2 — Take the nested exported suite out of everyday `make test` (T-2)
**Why second:** it is the biggest single saving (about one full controller-group run, 10+ minutes, per `make test`) and changes no coverage, because `ship` and CI still run it.

**Approach:**
1. In the export group, replace the nested `self-test.sh --full` with `--fast` plus `make check` in the fresh export (`self-test.sh` near the "full self-test failed in a fresh export" assertion). Keep every other export assertion.
2. Add `make ship-gate` to the root `Makefile` (and as an optional documented target in `templates/harness/Makefile`): it exports to a temporary directory and runs the full suite in exported layout, reusing the export group's fresh-export helper. Until t-3 adds `--all-groups` the recipe runs `--full`; t-3 changes it to `--full --all-groups` and asserts that. A failure names the failing group.
3. `ship` runs `make ship-gate` when the target exists, on the final head after the close-out commit and before the first `git push`, and stops with exit 1 on failure. With no target it prints a notice and continues.
4. `.github/workflows/ci.yml` adds a `make ship-gate` step after the Test suite step. Keep the existing action pins and the pin check green.
5. The per-script shellcheck lint (h-12) stays in `make test` unchanged.

**Test:** scenarios 2, 3, 4. Failure path first: a failing gate stops `ship` with no push (fake `git`); a missing target continues; the nested `--full` marker never appears in `make test`.

**DoD:** scenarios 2 to 4 pass. `make test` no longer runs the exported full suite; `make ship-gate` does and is green.
**Verify:** `make test-one F=export`, `make test-one F=lifecycle`, and `make ship-gate`
**Risks:** dropping the exported-layout check from every path (scenarios 3 and 4 are the guard); `ship` running the gate after the push; the two Makefiles drifting; CI time rising because the gate is a second long step (it is the same work moved, not added; record both steps' times).
**Red-first:** `scripts/self-test.sh --only export` — scripts/self-test.sh Makefile
**Commit:** `Run the exported-layout suite at close-out and in CI, not in every make test`

## t-3 — Declare each group's scope and gate adopters on harness changes (T-8)
**Why third:** it changes the same export assertion as t-2, and it stops adopters running the harness's internal groups on every `make test`.

**Approach:**
1. Next to `SELF_TEST_GROUPS`, add the scope list and the validation in scenario 5. Audit each group by what it reads: `local` only if it tests the adopter's real files. Record each decision and its reason in the commit body. Expect `local` to be nearly empty.
2. In an exported project (no source-only exporter), `--full` selects groups by scope as scenario 6 says. The harness-change test is one function over the changed set and base the Interface defines, and the payload manifest's destinations; no local state, same behaviour in CI. Any failure to compute it runs every group.
3. Add `--all-groups`. Update the `self-test.sh` header comment and the export group's assertion that an exported project passes its full suite.
4. Change `make ship-gate` to `self-test.sh --full --all-groups` and assert it.
5. Edit `templates/ci/ci.yml`'s app job (and its `templates/harness` mirror, if any) so the checkout has history and the base ref: `fetch-depth: 0`, and `AGENTIC_BASE_REF=origin/${{ github.base_ref }}` in the test step's environment for pull requests. The check-action-pins and CI-template checks must stay green.
6. Document the behaviour in `docs/` where the exported `make test` is described, and in the CHANGELOG draft notes for close-out.

**Test:** scenarios 5 and 6, failure path first: each unresolvable-base case runs all groups (shallow clone with no merge base, missing `origin` refs, no remote, a git error); an uncommitted, a staged-only and an untracked harness edit each run the scaffold groups; a committed one-line edit does too; a pushed feature branch whose upstream equals HEAD, with a committed harness edit against `origin/main` and a clean tree, runs the scaffold groups (the upstream is never the base); a detached PR-merge checkout with the base fetched and no harness change runs only `local`; the CI template change is asserted (`fetch-depth: 0`, base ref exported).

**DoD:** scenarios 5 and 6 pass. The source repository's `--full` runs the same groups as before.
**Verify:** `make test-one F=export`, `make test-one F=upgrade`, and `make test-one F=contracts`
**Risks:** skipping a group that would have caught a real adopter break (any harness-owned change re-enables them; an unknown base runs everything); a wrong `local`/`scaffold` call; detection reading a stale base in CI (it falls back to every group); a changed set that omits uncommitted or untracked files (scenario 6 tests each); a base that equals HEAD because the branch tracks itself (never use the upstream); the CI template leaving a shallow checkout so adopters keep running every group.
**Red-first:** `scripts/self-test.sh --only export` — scripts/self-test.sh
**Commit:** `Give each test group a scope and run scaffold groups in adopters only when harness files change`

## t-4 — Split `self-test.sh` into `scripts/tests/<group>.sh` (R-15, part 1)
**Why fourth:** t-5 to t-8 build on per-group files. It is a pure move, so nothing may change in what runs.

**Approach:**
1. Move each remaining group (export, contracts, hooks, plan-to-issues, lifecycle, upgrade) into `scripts/tests/<group>.sh`, sourced by the dispatcher the way `controller.sh` and `stations.sh` already are. The dispatcher keeps flag parsing, the fixtures and helpers shared across groups, the group-ran check and the cost budget.
2. Before moving, record the sorted set of assertion message strings (each `fail "…"` and each helper that names one) into a reviewed list; after the move a check compares them (scenario 7).
3. Keep the `should_run` call sites validated against `SELF_TEST_GROUPS`.
4. Put the test helpers that t-6 to t-8's tests need (fixture builders, assertion functions, the fake-clock or timing stubs) in `scripts/tests/helpers.sh`, not in the dispatcher's implementation. Tests for the dispatcher's own behaviour (flags, shards, ceilings) live in `scripts/tests/contracts.sh`. This lets a red-first run copy the tests and helpers onto the base while the implementation under test stays at the base version.

**Test:** scenario 7, failure path first: delete one assertion from a moved file and show the list check fails; rename a group file and show the dispatcher fails loudly.

**DoD:** scenario 7 passes; `self-test.sh` is shorter by roughly the moved lines; `make test` passes unchanged.
**Verify:** `make test-one F=export`, `make test-one F=contracts`, `make test-one F=hooks`, and `make test-one F=lifecycle`
**Risks:** a moved block losing a variable it used from the dispatcher; a dropped assertion (the list check is the guard); ordering changes that hide an interaction between groups.
**Red-first:** `scripts/self-test.sh --only contracts` — scripts/self-test.sh scripts/tests/contracts.sh
**Commit:** `Split self-test.sh into one file per group without changing what they assert`

## t-5 — Add the adopter-twin fixture (R-15, part 2)
**Why fifth:** the split makes adding a fixture cheap. Adopters customize `CLAUDE.md` and the `Makefile`, and the suite has never tested against a customized project.

**Approach:**
1. Add a fixture builder that exports into a project with a customized `CLAUDE.md`, a `Makefile` with renamed targets and extra targets, a real commit command and extra hook entries.
2. Run upgrade, the hooks group's checks and `make check` against it as holdout scenarios, in the groups that own them. Reuse the existing fixture resets; do not raise the copy limit.
3. State in the commit body one defect class the twin would have caught from the repository's history.

**Test:** scenario 8 with a red-first selector for the twin.

**DoD:** scenario 8 passes inside the 190-copy budget.
**Verify:** `make test-one F=upgrade`, `make test-one F=hooks`, and `make test-one F=export`
**Risks:** the twin duplicating a whole fixture copy and blowing the budget; a twin so similar to the pristine export that it proves nothing (the red-first case is the guard).
**Red-first:** `scripts/self-test.sh --only upgrade` — scripts/tests/upgrade.sh scripts/tests/helpers.sh
**Commit:** `Test upgrade, hooks and make check against a customized adopter project`

## t-6 — Select `stations` scenarios by tag (T-4, stations)
**Why sixth:** the `stations` group (about 120 s) is the next-largest group after the controller; per-step Verify lines need a scenario-sized run.

**Approach:**
1. Tag the `stations` blocks (propose launch, packet, verify, handoff; the executor may adjust to the real seams) and add the same selection rules as the controller group's `--scenario` handling, reusing that code.
2. `make test-one F=stations S=<tag>` in both Makefiles; the usage text names it; `--scenario` stays invalid for other groups.
3. Add a marker per block so a tag proves it ran only its blocks.

**Test:** scenario 9, failure path first: unknown tag exits 2; a tag that selects no block fails; each tag alone in a fresh checkout. The selector regression tests (unknown tag, empty selection, union, `--scenario` invalid for other groups) live in `scripts/tests/contracts.sh`; the tagged station blocks stay in `stations.sh`, and the red-first run copies only the contracts tests and helpers, so the dispatcher stays at the base version.

**DoD:** scenario 9 passes; whole-group behaviour and CI are unchanged.
**Verify:** `make test-one F=contracts`, `make test-one F=stations`, `make test-one F=stations S=launch`, `make test-one F=stations S=verify`, `make test-one F=stations S=handoff`, and `make test-one F=stations S=packet`
**Risks:** a block relying on state another tag creates (scenario 9's fresh-checkout run is the guard); drift between the controller and stations selection code (shared function); the root and template Makefile `S` rules drifting.
**Red-first:** `scripts/self-test.sh --only contracts` — scripts/tests/contracts.sh scripts/tests/helpers.sh
**Commit:** `Select stations scenarios by tag, sharing the controller group's selector`

## t-7 — Run groups and shards in parallel in `--full` (T-5)
**Why seventh:** with per-group files and tags in place, wall time can drop to the slowest shard without changing a single check.

**Approach:**
1. `--full --jobs <n>`: run each group (and each controller and stations tag shard) as its own process with its own fixture root and log, bounded by `min(shards, CPUs)`. Print each shard's log in a stable order and report every failing shard.
2. Merge the shards' cost events so the copy budget and the ran-every-group check still see the whole run.
3. Keep every existing group timeout per shard. `--jobs 1` is today's serial order. Bound memory: a shard runs no more than one shellcheck or fixture build at a time per process, and the default job count is cautious on a 2-CPU runner.
4. Record the measured wall time of `make test` at `--jobs 1` and at the default in the commit body.

**Test:** scenario 10, failure path first: one failing shard fails the run and the others still finish and report; a shard that never runs fails the ran-every-group check; two shards never share a fixture root.

**DoD:** scenario 10 passes; the commit body gives the two wall times.
**Verify:** `make test-one F=contracts`, `make test-one F=controller S=ledger`, and `make test` once at the end
**Risks:** shared state between shards (fixture roots, `HOME`, ledger directories); the copy budget undercounting; CPU-count detection differing on macOS and Linux; memory use on the 7 GB CI runner (the default must not start more shards than 2 CPUs allow there); interleaved logs hiding the failing line.
**Red-first:** `scripts/self-test.sh --only contracts` — scripts/tests/contracts.sh scripts/tests/helpers.sh
**Commit:** `Run self-test groups and scenario shards in parallel under --full`

## t-8 — Wall-time ceilings per group (T-6)
**Why last:** ceilings need the post-split, post-parallel timings, and a ceiling set too early would be wrong. They apply to the steps run after this one, so the growth the analysis describes is caught at the step that causes it, from the focused Verify run, not at close-out.

**Approach:**
1. Record each group's seconds as cost events (shard seconds, not the parallel total).
2. Add one reviewed ceiling file with one line per group and one per controller and stations tag. A whole-group run fails when a group exceeds its ceiling; a `--scenario` run fails when a selected tag exceeds its tag ceiling and applies no group ceiling. Each failure names the group or tag, seconds and ceiling. `make check` fails when a group or tag has no line.
3. Set ceilings from this phase's measured timings with headroom stated in the commit body (for example 1.5×). Provide a boundary test.
4. Document where the ceiling lives and that raising one is a reviewed change.

**Test:** scenario 11: at the ceiling passes, one second over fails, for a group and for a tag; a `--scenario` run enforces only the selected tags; a whole-group `--only` run enforces the group ceiling; a missing group or tag line fails `make check`.

**DoD:** scenario 11 passes; a full `make test` is green under the new ceilings.
**Verify:** `make test-one F=contracts`, then a full `make test` at the end of the brief
**Risks:** ceilings tuned to this machine failing on a slower CI runner (headroom, and a note on how to raise one); flaky ceilings from noisy neighbours; a ceiling file nobody reviews; a tag ceiling set so loosely it hides growth (set from measured seconds).
**Red-first:** `scripts/self-test.sh --only contracts` — scripts/tests/contracts.sh scripts/tests/helpers.sh
**Commit:** `Fail a test run when a group or scenario tag exceeds its approved wall-time ceiling`

---

# Close-out

Claude, on `phase-3`, after the last approval, and before the human merges:

1. Close-out commits: `VERSION` and a `CHANGELOG.md` entry with migration notes: `make ship-gate` and that `ship` runs it before the push; the exported suite leaving `make test`; group scopes and `--all-groups` for adopters; `--jobs`; `S=` for `stations`; the wall-time ceiling file; the contract change; and the Makefile changes to copy by hand.
2. Claude runs `make check && make test && make ship-gate` on `phase-3` at the close-out head before any push, and records result, head and wall times in the close-out commit message. A red run is fixed or escalated.
3. The human pushes, or runs `agentic-flow ship docs/inprogress/feature-test-streamlining.md`. Claude commits the staged prep; the human runs `ship` again; the reviewer runs `final-approve` when `ship` asks; **do not merge before `ship` reports READY**.
4. Update `product-harness-factory-optimization.md` (the Phase 3 table, next-docs list, before and after wall times).

---

## Status / Implementation status
- **Evidence schema:** v2
- **Tracking issue:** url=https://github.com/wabkebab/agentic-flow/issues/165
- **Approval:** status=approved; by=wabkebab; at=2026-11-19; rev=dd09d82350090b82ae0debe5d8e2e55b8e4fa406
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
