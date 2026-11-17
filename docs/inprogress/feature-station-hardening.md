<!-- TRIAGE (first pass · 2026-11-17) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict
> Phase 2b of `product-harness-factory-optimization.md` (P-1 to P-7): make controller-run stations fail before launch, not mid-step, and make the remaining failures cheap to diagnose. Found by running Phase 2's controller on its own steps C-6 and C-7. Part A is the analysis; Part B lists candidate steps and is not yet an approvable brief. Runs after Phase 2 merges and before Phase 3 (`feature-test-streamlining.md`).

# Feature — Station hardening

## Tracker
<!-- Filled in when the brief is approved and plan-to-issues runs. -->
- [ ] Brief not drafted yet; see Part B for the candidate steps.

---

# Part A — Analysis

## Goal

Phase 2's controller ran its first real stations on C-6 and C-7. It hit nine launcher and ledger defects that 600+ seconds of offline tests did not catch, and all five approver `resume`s in C-7 were for launcher faults, not for questions about the step. Every later phase executes through this controller, so it has to be reliable first.

Success:

- a launcher defect is found by a probe in seconds, before a plan's first station runs;
- an infrastructure failure does not cost the approver a `resume`;
- a failed station's output survives for diagnosis;
- a retry never spends itself resuming a session the CLI already rejected.

## Current state

References are to `phase-2` at `7599d61`, which is not on `main` yet.

### Defects found by dogfooding

Every one passed the offline suite. The stub CLIs shared the launcher's assumptions: they accepted any `-c` key, any session id and only bare JSON.

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

### Process defects seen in the same runs

- **Salvage blocks the plan branch.** A commit on the plan branch while a salvage is pending re-raises `worktree-changed-after-salvage` on every reconcile (`scripts/lib/controller.sh:269-273`). Clearing the hold does not re-baseline. The only way out was `reset --hard` and restarting the step.
- **Infrastructure faults escalate the step.** A launch that dies before the CLI starts (no tokens, under 5 s) is handled like a station question. It moves the step to `escalated` and needs the approver's `resume`.
- **Retries resume dead sessions.** `resume-valid` retries reused a session the CLI had already rejected, so the retry was spent for nothing.
- **Failed output is lost.** The launcher deletes the station's events and stderr with its scratch directory (`scripts/lib/launch.sh`, end of `launch_station`), so diagnosing the parser fault needed a `PATH` shim that copied OpenCode's stdout.
- **Unexplained, not investigated:** every `run` prints `repaired #138: hold-projection`, often twice, so that repair is not sticking. `metrics` reports tokens as `n/a` although the ledger holds Codex usage (for example 1,193,961 input tokens).

## Proposed approach

| ID | Change |
|---|---|
| P-1 | **Real-CLI probe.** `agentic-flow doctor --stations` launches each assigned CLI through the real launcher, sandbox, environment and limits with a fixed tiny prompt. It checks exit status, session capture, result parsing, and that the sandbox allows writes to the worktree, `.agents/` and the commit paths and denies writes to the verify and ledger directories. `run` probes a station when its launcher or profile hash changed since the last passing probe (decided 2026-11-17). Six of the nine defects would have failed it (quoted keys, commit paths, `.agents/`, both file-size caps, the OpenCode session id), and a seventh if it records its session through the ledger. Resume and verdict-format faults still need a real station run. |
| P-2 | **Keep failed output.** On an invalid result, store bounded events and the stderr tail under the run's ledger directory and name the path in the andon comment. |
| P-3 | **Fresh session after a dead one.** If the previous attempt failed before launch (no session, no tokens, under 5 s), or the launcher or profile hash changed since the session started, the retry starts a fresh session instead of resuming. |
| P-4 | **Operator hold for infrastructure faults.** A pre-launch failure raises an operator hold on the tracker instead of escalating the step, and @-mentions the owner like an andon (decided 2026-11-17). Clearing it retries without a journaled `resume`. A station's real question still escalates the step. |
| P-5 | **Salvage re-baseline.** `hold clear --rebaseline` records a fresh salvage snapshot on top of the new HEAD, so a fix committed to the plan branch does not force `reset --hard`. |
| P-6 | **Explicit verdict format for schema-less CLIs.** The OpenCode prompt states that the final message is only the result JSON. The parser stays lenient. |
| P-7 | **Investigate** the repeated `hold-projection` repair and the missing token totals in `metrics`, and fix or record each. |

**Ordering.** P-1 first: it turns the next launcher regression into a preflight failure. P-2 next, so anything P-1 misses can be diagnosed. Then P-3 and P-4, which remove the human cost of infrastructure faults. P-5, P-6 and P-7 are independent.

## Interface (before the implementation)

```
agentic-flow doctor --stations [--station executor|reviewer] [--json]
  per station: {station, cli, launched, exit, session_captured, result_parsed,
                writable: {worktree, agents, commit_paths},
                denied:   {verify_dir, ledger_dir},
                seconds, error}

ledger runs/<plan>/<issue>/<seq>/<station>/<chain>/<n>/
  events.tail (≤ 256 KiB), stderr.tail (≤ 64 KiB)   # invalid results only

retry policy: resume only when the prior run captured a session, used tokens,
              and the launcher/profile hash is unchanged; otherwise fresh

hold kinds: + station-infrastructure (tracker-level, cleared by `hold clear`)
agentic-flow hold clear <doc> <hold-id> [--rebaseline] [--note <text>]
```

## Threat model

The probe runs real CLIs with the user's provider credentials, under the same isolation as a station, with a fixed prompt and no repository content. Since `efc36e0` the Codex sandbox can write the shared `objects`, `refs/heads` and `logs`. That is what a commit needs, and none of those directories holds verify records or the ledger. P-1 makes that boundary a tested property: a station that can write the verify or ledger directory could forge evidence, and Phase 3's verify reuse (T-1) relies on it. Stored output tails can contain whatever the station printed, so they stay in the git common directory, which is never pushed.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---|---|---|---|
| Station probe | That station fails the probe; reported, no state change | Result not parsed → probe fails with the bounded output tail | Per-station report; one failing station does not hide the others |
| Station launch, pre-launch failure | Operator hold (P-4) | n/a | n/a |
| Station run, invalid result | Existing retry chain, now with P-3's fresh-session rule | Output tails stored (P-2) | Salvage as today |

Bounds: probe prompt fixed, 120 s per CLI; stored tails 256 KiB events and 64 KiB stderr per invalid run.

## Out of scope / What NOT to build in this pass

- Test streamlining (Phase 3) and the cleanup items (Phase 4).
- Supporting new station CLIs.
- Unattended mode changes beyond P-4's hold.

## Decisions

- **P-4 notifies like an andon** (owner, 2026-11-17). The operator hold @-mentions the owner on the tracker, as R-9 does, so an unattended run never stalls silently. It stays an operator hold, not a step escalation: clearing it needs `hold clear`, not the approver's `resume`.
- **P-1 runs only on change** (owner, 2026-11-17). `run` probes a station when its launcher or profile hash differs from the last passing probe; `doctor --stations` forces a probe. Each probe makes real model calls, so it does not run before every station.

## Open questions

- None open.

---

# Part B — Implementation Brief

> Not drafted yet. Part A has to be reviewed first. Candidate step order:
>
> 1. P-1 station probe, including the denied verify and ledger directories.
> 2. P-2 kept output tails.
> 3. P-3 fresh-session retry rule and P-4 operator hold.
> 4. P-5 salvage re-baseline.
> 5. P-6 verdict-format prompt; P-7 investigation.

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
