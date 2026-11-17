<!-- TRIAGE (first pass · 2026-11-17) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict
> Phase 3 of `product-harness-factory-optimization.md` (R-12 to R-17, R-22), plus the test-cost and station findings from running Phase 2's controller on itself. Part A is the analysis; Part B lists candidate steps and is not yet an approvable brief. Next: human review of Part A, then draft the brief and run `plan-to-issues --doc`.

# Feature — Harness simplification

## Tracker
<!-- Filled in when the brief is approved and plan-to-issues runs. -->
- [ ] Brief not drafted yet; see Part B for the candidate steps.

---

# Part A — Analysis

## Goal

Phase 3 removes what Phases 1 and 2 made redundant (R-12 to R-17, R-22 in the roadmap). Running Phase 2's controller on its own last steps (C-6, C-7) added two more targets:

1. **Test cost.** The same slow test group runs three to four times per step, and twice more per full `make test`. Only one of those runs carries new information. Cut the repeats without weakening any gate.
2. **Station reliability.** The controller's first real runs hit nine launcher and ledger defects that 600+ seconds of offline tests did not catch. Each one cost a live run, and most cost the human an andon `resume`. Catch this class of defect before a station runs, and make the rest cheaper to diagnose.

Success:

- a step whose Verify line names one test group runs that group once per commit, not three or four times;
- `make test` runs each group once;
- a launcher defect is found by a probe in seconds, not by a failed station run and a human `resume`;
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
- The controller group grew about 20× across three steps. `scripts/tests/controller.sh` has 1,726 lines, about 83 `c4_run`/`c5_run` controller invocations and 48 fixture resets. Nothing flagged the growth: `assert_cost_budget` (`scripts/self-test.sh:134`) counts file copies, not time.
- The export group alone took more than 600 s (`make test-one F=export`, 2026-11-17).
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

### Station defects found by dogfooding Phase 2

Every one of these passed the offline suite. The stub CLIs encoded the same wrong assumption the launcher made.

| Commit | Defect | Cost |
|---|---|---|
| `e76282a` | Connector-disable keys were JSON-quoted, and Codex 0.169 takes quotes in a `-c` key literally ("invalid transport"). | Preflight refused every Codex launch |
| `efc36e0` | A linked worktree keeps its index and the shared objects and refs outside the `workspace-write` sandbox, so a station could edit files but never commit. | Andon, `resume` |
| `1d738bd` | Codex makes `.agents/` read-only beneath any writable root. It is writable only as a root of its own. | Andon, `resume` |
| `c5b3859` | `ulimit -f 65536` (32 MB) killed Codex with SIGXFSZ (exit 153), because its global state databases are larger. | Two andons; looked like "malformed result" |
| `75b390d` | A caller-chosen OpenCode session id loses the user's provider (free-tier 429), and a plain UUID is rejected outright. | Reviewer exit 1 |
| `d490771` | OpenCode only resumes ids it issued (`ses_…`), and the chain kept resuming a stale UUID. | Andon, `resume` |
| `fa49bef` | The same file-size cap killed OpenCode's standalone server (its database is 254 MB). | Hidden behind the session-id bugs |
| `8148e32` | The ledger accepted a `session` record only for Codex, so recording OpenCode's own id failed the launch. | Andon, `resume` |
| `c79f01a` | OpenCode cannot enforce an output schema. Its reviewer ends with prose plus JSON, and the parser required bare JSON. | A completed 893 s review recorded as malformed; andon, `resume` |

Process defects seen in the same runs:

- **Salvage blocks the plan branch.** A commit on the plan branch while a salvage is pending re-raises `worktree-changed-after-salvage` on every reconcile. Clearing the hold does not re-baseline. The only way out was `reset --hard` and restarting the step.
- **Infrastructure faults escalate the step.** A launch that dies before the CLI starts (no tokens, under 5 s) is treated like a station question. It moves the step to `escalated` and needs the approver's `resume`. All five resumes in C-7 were for launcher faults.
- **Retries resume dead sessions.** `resume-valid` retries reused a session the CLI had already rejected, spending the retry for nothing.
- **Failed output is lost.** The launcher deletes the station's events and stderr, so diagnosing the parser fault needed a `PATH` shim that copied OpenCode's stdout.
- **Unexplained, not investigated:** every `run` prints `repaired #138: hold-projection`, often twice, so that repair is not sticking. `metrics` reports tokens as `n/a` although the ledger holds Codex usage (for example 1,193,961 input tokens).

## Proposed approach

### Test cost (T)

| ID | Change | Expected saving |
|---|---|---|
| T-1 | **Verify once per commit.** `verify-step` returns the stored record when commit, tree, verifier implementation hash, signature source and harness version all match: the same freshness test `packet.sh` already applies. `--force` re-runs. Contracts: under the controller the executor does not run `verify-step` and the reviewer reads the packet's record. A reviewer re-runs only for a stale or failed record, or to test a specific doubt with a narrower command. | 1–2 group runs per step, plus each bounce |
| T-2 | **No nested full suite in the export group.** The fresh export runs `--fast` plus the hooks and contracts groups. The full suite in exported layout becomes its own CI job, not part of local `make test`. | About one controller-group run (10+ min) per `make test`, locally and in CI |
| T-3 | **Profile before cutting.** A timing wrapper on `c4_run`, `c5_run` and the resets, enabled by an environment variable, reports per-scenario seconds in one run. | Turns T-4 into a measured decision |
| T-4 | **Scenario selection.** Split `controller.sh` (and `stations.sh`) into tagged scenario files (launch, ledger, recovery, ship, andon), in line with R-15. `make test-one F=controller S=<tag>`. A step's Verify line names its scenarios; the whole group runs at the end of the plan and in CI. | Likely 10 min to a few per step; T-3 confirms |
| T-5 | **Parallel groups in `--full`.** Fixtures are already isolated and concurrent runs are supported. Wall time becomes the slowest shard. | Large once T-4 creates shards |
| T-6 | **Wall-time budget.** Record seconds per group next to the copy counts and fail when a group exceeds its approved ceiling, so the step that grows it is named. | Prevents a repeat of 32 s → 673 s |
| T-7 | **Gate cadence in the contracts.** Per step: `make check` and the step's Verify command only. Full `make test` once at the end of the plan. Reviewer: no test runs by default (T-1). | Removes the extra groups executors run today |

**Adopters.** With R-14b's harness/project split, an adopter's `make test` runs the harness `--fast` checks plus their own tests. The harness's full suite runs when harness bytes change: on `upgrade`, and in the scaffold's own CI.

### Station reliability (P)

| ID | Change |
|---|---|
| P-1 | **Real-CLI probe.** `agentic-flow doctor --stations` (or `run --probe`) launches each assigned CLI through the real launcher, sandbox, environment and limits with a fixed tiny prompt. It checks exit status, session capture, result parsing, and that the sandbox allows writes to the worktree, `.agents/` and the commit paths. It runs before the first station of a plan and after any launcher or profile change. Six of the nine defects above would have failed it (quoted keys, commit paths, `.agents/`, both file-size caps, the OpenCode session id), and a seventh if the probe records its session through the ledger. Resume and verdict-format faults need a real station run. |
| P-2 | **Keep failed output.** On an invalid result, store bounded events and the stderr tail under the run's ledger directory and name the path in the andon comment. |
| P-3 | **Fresh session after a dead one.** If the previous attempt failed before launch (no session, no tokens, under 5 s), or the launcher or profile hash changed since the session started, the retry starts a fresh session instead of resuming. |
| P-4 | **Operator hold for infrastructure faults.** A pre-launch failure raises an operator hold on the tracker instead of escalating the step. Clearing it retries without a journaled `resume`. A station's real question still escalates the step. |
| P-5 | **Salvage re-baseline.** `hold clear --rebaseline` records a fresh salvage snapshot on top of the new HEAD, so a fix committed to the plan branch does not force `reset --hard`. |
| P-6 | **Explicit verdict format for schema-less CLIs.** The OpenCode prompt states that the final message is only the result JSON. The parser stays lenient. |
| P-7 | **Investigate** the repeated `hold-projection` repair and the missing token totals in `metrics`. |

### How this fits the existing Phase 3 items

- T-4 and T-5 are the test-cost half of R-15 (split `self-test.sh`). Do them together.
- The adopter cadence depends on R-14b. Plan them together, as R-22 already is.
- R-12, R-13, R-14a, R-16, R-17 and R-22 are unchanged by this analysis.
- R-13 should land after P-1: removing comment-based approvals is safer once station runs are reliable.

### Ordering

**Option A — measure, then cut (recommended).** First T-3 (profile), T-1 (verify reuse) and T-2 (no nesting), plus T-7's contract text. These are small, remove most of the repeats, and do not change coverage. Then P-1, which prevents the next launcher regression. Then T-4/T-5 with R-15, guided by the profile, then T-6. P-2 to P-5 follow; R-12 to R-17 and R-22 keep the roadmap's order.

**Option B — split first.** Start with R-15's split and scenario tags. This touches the most files before anything is measured, and the profile might show a few scenarios dominate, making most of the split unnecessary.

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

agentic-flow doctor --stations [--station executor|reviewer] [--json]
  per station: {station, cli, launched, exit, session_captured, result_parsed,
                writable: {worktree, agents, commit_paths}, seconds, error}

ledger runs/<plan>/<issue>/<seq>/<station>/<chain>/<n>/
  events.tail (≤ 256 KiB), stderr.tail (≤ 64 KiB)   # invalid results only

hold kinds: + station-infrastructure (tracker-level, cleared by `hold clear`)
agentic-flow hold clear <doc> <hold-id> [--rebaseline] [--note <text>]
```

## Threat model

Verify reuse turns a stored record into permission to skip a gate. The record is keyed by commit, tree and the verifier's own hash, so a code or verifier change re-runs. The new risk is a forged record. Records live in `.git/agentic-flow/verify/`, which no station may write. Since `efc36e0` the Codex sandbox can write the shared `objects`, `refs/heads` and `logs`, and none of those hold verify records. P-1 must keep the verify and ledger directories outside every station's writable roots and test that. The station probe runs real CLIs with the user's provider credentials, under the same isolation as a station, with a fixed prompt and no repository content.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---|---|---|---|
| `verify-step` reuse lookup | n/a (local file) | Unreadable or mismatched record → run the full verification | n/a |
| Station probe (`doctor --stations`) | Probe fails for that station; reported, no state change | Result not parsed → probe fails with the bounded output tail | Per-station report; one failing station does not hide the others |
| Station launch, pre-launch failure | Operator hold (P-4) | n/a | n/a |
| Parallel groups (T-5) | Each shard keeps its own timeout | n/a | Any failing shard fails `make test`, and every failing shard is reported |

Bounds: probe prompt fixed, 120 s per CLI; stored tails 256 KiB events and 64 KiB stderr per invalid run; parallel shards capped at the CPU count.

## Out of scope / What NOT to build in this pass

- Dropping any group from CI's full run. Selection (T-4) applies to per-step runs only.
- Sharing verify records across machines or with CI.
- Remote or cloud test execution.
- Changing what the controller group tests. T-3 to T-5 change how it is run, not what it asserts.

## Open questions

- [BLOCKING] T-2: is the full suite in exported layout acceptable as a CI-only job, so local `make test` no longer runs it?
- T-1: should a reviewer that doubts a record re-run with `--force`, or only with a narrower command the reviewer names?
- P-4: should the operator hold notify the owner like an andon, or only show in `brief` and `SessionStart`?
- Adopters: tie the harness-full cadence to R-14b (1.0), or ship an opt-out earlier?

---

# Part B — Implementation Brief

> Not drafted yet. Part A has to be reviewed first. Candidate step order, per Option A:
>
> 1. T-3 profile wrapper; T-1 verify reuse with `--force`; T-7 contract text.
> 2. T-2 export group runs `--fast` plus hooks and contracts; full exported-layout CI job.
> 3. P-1 station probe, with the verify and ledger directories proven unwritable by stations.
> 4. P-2 to P-5: kept output, fresh-session retry, operator hold, salvage re-baseline.
> 5. R-15 with T-4/T-5 (split, scenario tags, parallel shards), then T-6 time budget.
> 6. R-12, R-13, R-14a, R-16, R-17; R-14b with R-22 and the adopter cadence at 1.0.

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
