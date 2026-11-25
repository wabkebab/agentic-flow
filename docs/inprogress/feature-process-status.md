<!-- TRIAGE (first pass · 2026-11-25) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict (touches the controller loop; project baseline is Standard)
> Phase 1 of [harness configurability](product-harness-configurability.md) (areas E and G): an offline, read-only plan view that answers "whose turn is it?", a controller heartbeat, `run --detach` with a startup acknowledgment, and `run --wait-human` for resumable stops. Revision 2 (2026-11-25) answers the first review: resumable stops, launch acknowledgment, log capping, station evidence, executable next actions, read bounds.

# Feature — Process status and detached runs

## Tracker
- [ ] f-1 Publish a controller heartbeat — open
- [ ] f-2 Show plan progress in `agentic-flow status <plan>` — open
- [ ] f-3 Run the controller detached — open
- [ ] f-4 Wait for the human on resumable stops — open

---

# Part A — Analysis

## Goal

The owner reported that it is difficult to know the status of the process. While a plan
runs, the human cannot easily tell:

- whether a controller is alive,
- which station is working on which step, and for how long,
- how many bounces a step has used,
- whether the line is stopped and, if so, the exact command the human must run next.

The controller also needs a terminal that stays open, and it exits as soon as the line
stops. Nothing resumes it when the human answers. This brief makes progress visible and
lets the controller run in the background and wait for the human, without adding a daemon.

## Current state

- **Lock:** `<common>/agentic-flow/locks/controller-<plan>/owner.json` holds
  `{pid,start,host,run}`. A recovery claimant writes `recover/owner.json` with `{pid,start}`
  and replaces `owner.json` only after a clean reconcile (`scripts/lib/controller.sh:48-98`).
  Liveness is a pid plus process-start match through `recovery.pl process`. The host id
  is `recovery.pl host <common>` (12 hex).
- **`CT_PID`** is the PID of `controller_cmd`'s subshell, computed through
  `sh -c 'printf "%s\n" "$PPID"'` (`controller.sh:884`). It is not the PID of the
  `agentic-flow` process.
- **State cache:** each reconcile writes three files under `<common>/agentic-flow/state/`:
  - `<plan>.tsv`: issue, step, state, latest id, submitted head, time
  - `<plan>.metrics.json`: admitted events per issue with role; writer-capped at 4 MiB
  - `<plan>.holds.json`: open holds

  Sources: `scripts/lib/handoff.sh:267-287`, `scripts/lib/andon.sh:162-174`.
- **Ledger:** `intent` records carry `started`, `issue`, `step`, `station`, `cli`,
  `replaces` and `chain`. A `station` record closes a run. `end` records close chains.
  `ledger_read` takes a bounded `LOCK_SH` with a timeout on the existing file and reads at
  most 32 MiB (`scripts/lib/ledger.pl:69-71, 343-351`).
- **Exit 10 has four sources:**
  - the reconcile check (`controller.sh:939`): open holds, a raised andon, or an escalated issue
  - holds raised inside `controller_dispatch`: probe, preflight, launch, changed branch
    (`:651, 656, 724, 735, 754, 793, 798`)
  - the turn cap (`:956`)
  - an unreadable ledger (`:911`)
- **Escalation:** a station `ask`, or a bounce at the limit, moves an issue to `escalated`.
  It leaves that state only through
  `agentic-flow handoff <N> resume --as approver --return executing|reviewing --body-file <note>`
  (`config/workflow.tsv`; `handoff.sh:300-316`).
- **`agentic-flow status`** reports only the harness install and exits 1 when that needs
  action (`scripts/agentic-flow:466-540`). Its tests are in `scripts/tests/upgrade.sh`.
- Station captures already run under their own `ulimit -f` inside `launch.sh`.

## Proposed approach

### Option A — Local read-only view + heartbeat + acknowledged detach + classified waiting (recommended)
A heartbeat file is written by the controller that holds the lock. `status <plan>` reads
local files only. `--detach` returns only after the controller acknowledges that it holds
the lock. `--wait-human` waits only on stops a human answer can resolve within the same
process.

Pros: no network in the view; additive; the lock and the journal stay authoritative.
Cons: the view is as fresh as the last reconcile. It shows the cache age and refuses to
recommend `ship` from an incomplete snapshot.

### Option B — Live view that queries the forge
Always current, but costs API calls and credentials on every refresh, and `--watch`
would hit rate limits. Rejected for this pass.

### Option C — A daemon serving status
Rejected in the product analysis (area G).

**Recommendation:** Option A.

**Command shape.** This is decided and mirrored in the product analysis.
`agentic-flow status` with no argument keeps the install report byte-identical and adds a
bounded `plans:` summary. `--json` gains a `plans` key. The exit code stays tied to the
install report. `agentic-flow status <plan-id|doc>` prints the plan view alone.
launchd/systemd units are deferred.

## Interface (before the implementation)

```
agentic-flow status [--json]                           # install report + bounded plans summary
agentic-flow status <plan-id|doc> [--watch [<s>]] [--json]
  exit 0  nothing for the human (station working, controller reconciling, or plan closed)
  exit 10 human action needed (see "next")
  exit 2  usage (incl. --watch without a TTY, --watch with --json)
  exit 3  unknown plan (no state, ledger, lock or plan doc)

agentic-flow run <doc> [...existing flags] [--detach] [--wait-human [<max-s>]]
  --detach      exit 0 only after a startup acknowledgment (C-4); prints controller pid, log, status cmd
  --wait-human  wait on resumable stops (C-5); exit 2 with --once or --reconcile-only

<common>/agentic-flow/state/<plan>.controller.json     (≤ 4 KiB, tmp + mv)
{ v:1, plan, doc, pid, start, host, run, ownership:"owner"|"recovering",
  launch:null|<nonce>,
  phase:"reconciling"|"station"|"waiting-human"|"stopped",
  turn, turn_cap,
  station:null|{issue, step, station, cli, run, started, timeout_s},
  waiting:null|{stop, reasons, issues, since, next_poll_at, until, failed_polls},
  exit:null|<int>, updated_at }

<common>/agentic-flow/logs/<plan>/<run-id>.log          (≤ 16 MiB; newest 20 per plan kept)

status JSON (plan view):
{ v:1, plan, doc, snapshot:{complete:<bool>, missing:[...], over_limit:[...], cache_at, ledger:"ok"|"busy"|"absent"|"error"},
  controller:{state:"alive"|"recovering"|"stopped"|"unknown"|"other-host", pid, phase, turn, turn_cap, updated_at, exit},
  steps:[{issue, step, state, bounces, bounce_limit,
          station:null|{cli, run, elapsed_s, timeout_s}, interrupted:[<run>...]}],
  holds:[{id, issue, reason, command}],
  escalations:[{issue, step, by, command}],
  usage:{cost_usd:null|number},
  next:{owner:"controller"|"station"|"human"|"none", action, command:null|<text>} }
```

### C-1 Heartbeat and liveness evidence
The controller writes the heartbeat:
- right after `controller_lock` succeeds, as owner or as recovery claimant;
- at every turn start, at station launch and return, at entering and leaving a wait;
- at exit, on every path including interrupts, before `CT_TMP` cleanup.

A write failure warns and never changes the result.

`status` reports `controller.state` as follows:
- **`other-host`:** the heartbeat `host` differs from the local host id. Nothing is probed.
- **`alive`:** the local host matches, `{pid,start}` equals `locks/…/owner.json`, and the
  process probe returns that start.
- **`recovering`:** the same checks, but against `locks/…/recover/owner.json`.
- **`stopped`:** there is no lock directory, or the probed process is gone or has a
  different start.
- **`unknown`:** anything else, such as a malformed file or a probe failure.

A step's station is reported as running only when all of these hold:
- the controller is `alive`, and the heartbeat `phase` is `station`;
- `heartbeat.station.run` names a ledger intent that has no `station` record;
- that intent is the newest in its chain, with no later intent whose `replaces` is it, and
  no `end` record for the chain.

Any other intent without a `station` record is listed under `interrupted`, never as running.

### C-2 Next action and snapshot completeness
The snapshot is **complete** only when every condition holds:
- The plan block parses from the plan doc on the local branch ref (`git show`, ≤ 1 MiB,
  using the plan-block parser without an approval check).
- The tsv has exactly one row per planned step, plus the tracker for Strict, or exactly
  one work row for Standard. Every state is valid for its topology.
- The metrics and holds caches parse within C-3's caps and cover the same issues.

Rules, in order:

1. Open hold → human: `agentic-flow hold clear <doc> <hold-id>`, after reading the hold
   note on `#N`.
2. Escalated issue with no open hold → human records the decision:
   `agentic-flow handoff <N> resume --as approver --return <state> --body-file <decision.md>`.
   The return state depends on the last admitted event:
   - executor `ask` → `executing`
   - reviewer `ask` → `reviewing`
   - bounce at the limit → both commands are shown, and the human chooses
3. Incomplete snapshot → human: `agentic-flow run <doc> --reconcile-only`. Never `ship`,
   never "closed".
4. Plan closed: the Strict tracker or the Standard work issue is `closed` → `none`, exit 0.
   The action notes that `agentic-flow clean <plan>` follows the merge.
5. Controller `alive` or `recovering` → `station` when C-1 proves one is running, else
   `controller`. Exit 0.
6. Ready to ship → human: `agentic-flow ship <doc> --wait-review`. Ready means:
   - Strict: every step `approved` and the tracker `open` or `closing`
   - Standard: the work issue `closing`
7. Otherwise → human: `agentic-flow run <doc>`.

### C-3 Read bounds
Every file is opened only when it is a regular file, not a symlink, and passes a
`wc -c` check:

| File | Byte cap | Entry cap |
|---|---|---|
| Heartbeat | 4 KiB | — |
| Lock owner files | 4 KiB | — |
| `<plan>.tsv` | 256 KiB | 200 rows |
| `<plan>.holds.json` | 256 KiB | 100 holds |
| `<plan>.metrics.json` | 4 MiB | 200 rows |
| Plan doc | 1 MiB | — |

A file over its cap is not parsed at all. It is listed in `snapshot.over_limit`, which
makes the snapshot incomplete.

The ledger is read through the existing `ledger_read`, and only when the plan's ledger
file already exists, so the reader creates nothing. Its bounded shared lock is the one
lock `status` may take. A lock timeout reports `ledger: busy` and nulls the
ledger-derived fields. `--watch` re-reads the ledger only when its size or mtime changes.

Plan discovery for the no-argument summary:
- examines at most 1,000 entries in `state/` and `locks/` and never lists the ledger
  directory;
- shows the newest 20 plans by heartbeat or tsv mtime, followed by `N more`;
- reads only each plan's heartbeat and tsv.

Rendered text fields are cut to 120 characters, and control characters are stripped.

### C-4 Detached launch
- **Before forking:** validate arguments (usage errors exit 2 in the foreground). Run the
  lock pre-check (a live owner exits 9) for a friendly early error only.
- **Fork:**
  - The parent generates a 32-hex nonce.
  - It starts `perl -MPOSIX -e 'setsid(); exec @ARGV'` running the same argv without
    `--detach`, with `AGENTIC_DETACH_NONCE` set, stdin from `/dev/null`, and stdout and
    stderr merged into a pipe.
  - The pipe feeds a bounded log writer started in the same session.
- **Acknowledgment:** the controller writes `launch:<nonce>` into its first post-lock
  heartbeat. The parent polls every 0.2 s for up to 30 s
  (`AGENTIC_DETACH_ACK_S` overrides this for tests). It succeeds when the heartbeat
  carries the nonce and C-1 classifies it `alive` or `recovering`. The parent then prints
  the heartbeat's `pid`, which is the controller's `CT_PID`, not the fork PID, plus the log
  path and `agentic-flow status <plan> --watch`, and exits 0.
- **Child exits first:** the parent reaps it, prints the last 20 stripped log lines and
  exits with the child's code. A lost lock race is 9.
- **Timeout:** TERM the child's session, wait up to 10 s, then KILL, and exit 5 with the
  log path.
- **Log writer:**
  - writes the first 16 MiB and then discards while still draining;
  - writes one marker at EOF: `agentic-flow: log truncated; <n> bytes dropped`;
  - on a write error such as a full disk, stops writing and keeps draining;
  - ignores INT, TERM and HUP, and exits only at EOF.
  - Both streams are captured: the controller's final summary is on stdout, its
    diagnostics on stderr. The heartbeat's `exit` is the authoritative result.
  - No `ulimit -f` is applied to the controller.
- **Pruning:** before the fork, prune the plan's logs to the newest 20, never the log of a
  live controller.

### C-5 Resumable stops
When the loop ends with result 10, the stop is classified from the union of open holds
(`CT_HOLDS`), holds raised this turn (`CT_HOLD_REASONS`) and escalated issues. This
covers stops from both the reconcile check and dispatch.

- **Resumable:**
  - escalated issues with no open hold;
  - open holds whose reasons are all in `{station-escalation, station-infrastructure,
    findings-incomplete, plan-effect-pending}`.
- **Not resumable, exit 10 at once as today:**
  - the turn cap;
  - an unreadable ledger (`CT_SALVAGE_ONLY`);
  - any hold with another reason, including integrity holds and holds an approver raised
    by hand.

  These need repair or a new invocation.

Waiting:
- Record `waiting-human` with `until = now + max` (default 86,400 s, at most 604,800 s).
- Sleep `min(backoff, until − now)`; backoff starts at 60 s and doubles to 900 s.
- Each poll resets the loop's per-turn state through the loop's existing top-of-iteration
  reset, sets `result=0`, and runs one reconcile pass with dispatch suppressed.
- Poll results:
  - result 0 ends the wait, and the loop continues normally;
  - result 10 with a resumable stop keeps waiting;
  - result 10 with a non-resumable stop exits 10;
  - result 5 counts as a failed poll, with the same backoff and deadline; 3 in a row exit 5;
  - any other code exits with that code.
- A poll never starts at or after `until`, which exits 10. Polls do not increment
  `CT_TURNS`. The lock stays held.

## Threat model (one paragraph)

No new trust boundary or credential path. `status` reads files under the user's own Git
common dir that existing code writes. It treats them as untrusted: type-checked,
size-capped before parsing, schema-checked, and printed with control characters stripped.
Hold reasons and asks can carry station output, so escape sequences must not reach the
terminal. A forged heartbeat can only mislead the display. Liveness needs a lock-file and
process-start match, and no decision reads the heartbeat. `--detach` gives the controller
the environment a foreground `run` gets, and stations keep `env -i`. The detach nonce only
proves which launch acknowledged. It is not a secret. Logs hold what the terminal shows
today, under the Git common dir.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---|---|---|---|
| Heartbeat / lock files | n/a | Controller `unknown`; other sections render | — |
| Process probe | Controller `unknown` | Controller `unknown` | — |
| Cache files | n/a | Listed in `over_limit` or `missing`; snapshot incomplete | No partial parse; rule 3 applies |
| `ledger_read` | `ledger: busy`, fields `null` | `ledger: error`, fields `null` | — |
| Detach acknowledgment | TERM, then KILL the child session; exit 5 | Nonce mismatch = no ack | Child exit before ack → its code |
| Log writer | n/a | n/a | Write error: drain without writing |
| Forge poll in a wait | Existing `gh` bound; failed poll | Exit 5 from reconcile = failed poll | — |

Bounds:
- read caps as listed in C-3; at most 100 issues rendered
- `--watch` interval 2–300 s
- acknowledgment wait ≤ 30 s plus 10 s for shutdown; log ≤ 16 MiB
- wait deadline ≤ 604,800 s; ≤ 3 consecutive failed polls

## Out of scope / What NOT to build in this pass
- Network calls from `status` (`--refresh`).
- launchd/systemd units, deferred. A long-running daemon.
- Making notification channels, hold policy, the bounce limit or the turn cap configurable
  (product area A/C).
- Waiting on non-resumable stops.
- A TUI or GUI.
- Denying `run` to agent stations in the command policy.

## Open questions
None open.

**Decided by the owner (2026-11-25): waiting is opt-in.** `run` defaults to unattended
behaviour: a stop exits with its code as today. The controller waits for human
interaction only when `--wait-human` is passed explicitly. There is no plan to make it the
default.

---

# Part B — Implementation Brief

## Acceptance scenarios
- Given no ledger, state, lock or plan doc, when `status <plan>` runs, then it exits 3.
- Given a heartbeat whose `{pid,start}` matches no lock owner or claimant, or whose process start differs, then the controller is `stopped`, `next` is `agentic-flow run <doc>`, and the exit is 10.
- Given a heartbeat from another host id, then the controller is `other-host` and is not probed.
- Given a malformed or oversized heartbeat, then the controller is `unknown` and the other sections render.
- Given a recovery claimant matching `recover/owner.json`, then the controller is `recovering`.
- Given a live reconciling controller and an intent without a station record, then the step lists the run under `interrupted`, `next.owner` is `controller`, and the exit is 0.
- Given a live controller whose heartbeat names the newest open intent, then the step shows the CLI, elapsed time and timeout, and `next.owner` is `station`.
- Given an open hold whose reason contains ANSI escapes, then the output has no control characters, shows `hold clear` for that hold id, and the exit is 10.
- Given an escalated issue after an executor `ask`, then `next` is the approver `resume` with `--return executing`. After a bounce at the limit, both returns are shown.
- Given every step approved, a tracker `open`, and a complete snapshot, then `next` is `ship`. Given a closed tracker, then `next.owner` is `none` and the exit is 0.
- Given a missing step row or an over-limit metrics cache, then the snapshot is incomplete and `next` is `--reconcile-only`, never `ship`.
- Given a held ledger lock, then `ledger: busy` is reported and the command still exits.
- Given 25 plans in `state/`, when `status` runs with no argument, then 20 are listed followed by `5 more`. The install lines and JSON keys are byte-identical to before.
- Given a non-TTY stdout, `status <plan> --watch` exits 2.
- Given two simultaneous `run --detach` invocations, then exactly one exits 0 with the acknowledged controller's pid, and the other exits 9.
- Given a child that fails before the lock (a dirty plan worktree), then `--detach` exits 3 with the log tail and no acknowledgment.
- Given a controller writing past 16 MiB of output, then the log stops at the cap with the truncation marker, and the run and its ledger writes complete.
- Given `--wait-human` with `--once` or `--reconcile-only`, then `run` exits 2.
- Given `--wait-human` and an existing hold found at reconcile, when the human clears it, then dispatch resumes in the same process without consuming turns.
- Given `--wait-human` and a dispatch-raised `station-infrastructure` hold, when the human clears it, then dispatch resumes.
- Given `--wait-human` and a turn-cap stop, an unreadable ledger, or an integrity hold, then the controller exits 10 immediately.
- Given `--wait-human` and an approver `resume` on an escalated ask, then the next poll resumes dispatch.
- Given `--wait-human`, then 3 failed polls exit 5, and an elapsed deadline exits 10 without another poll.

## Invariants
- `status` never writes files, never creates or edits the controller lock, and never runs `gh` or any network command. The only lock it takes is `ledger_read`'s bounded shared lock on an existing ledger file.
- Nothing in the controller reads the heartbeat for a decision. The lock, ledger and journal stay authoritative.
- Without the new flags, `run` behaves exactly as today, apart from writing the heartbeat. Waiting happens only when `--wait-human` is given explicitly (owner decision).
- No `ulimit -f` is applied to the controller. Station captures keep their own limit.
- Bash 3.2; no new required tool. Detaching uses Perl, which is already required.

```agentic-flow-plan
format: 2
id: process-status
profile: strict
tracking: Plan: Process status and detached runs
branch: configurability-phase-1
steps: f-1 f-2 f-3 f-4
```

## Branch
Base: `main`. One branch and one PR for the whole brief: `configurability-phase-1`. Each
step lands as its own commit, closing its issue via `Fixes #N`.

## Definition of done (whole brief)
Every step's DoD met; `make check` and `make test` green. Manually: run
`agentic-flow run <doc> --detach --wait-human`, watch `agentic-flow status <plan> --watch`,
clear a hold, and see the line resume. Help text, `ADOPTION.md`'s run section, and the
station-commands paragraph in `CLAUDE.md` and `templates/harness/CLAUDE.md` (plus the
`AGENTS.md` pair if it names `run`) describe the new commands.

## Verification commands
```bash
make check                                # per step
make test-one F=controller S=status       # f-1..f-4 (new tag; add its wall-time ceiling)
make test-one F=upgrade                   # f-2: install report unchanged
make test                                 # end of brief
```

---

## F-1 — Publish a controller heartbeat
**Why first:** the other steps read it, and it is the only per-turn change to the loop.

**Approach:**
- Implement the writer for Part A's heartbeat shape at every point listed in C-1, through
  tmp + `mv`, never inside the lock directory.
- Include `ownership`, plus `launch` when `AGENTIC_DETACH_NONCE` is set.
- A write failure warns only.
- Add the `status` tag to the controller group, its ceiling in
  `config/test-wall-ceilings.tsv`, and the tag in the Makefile usage string.

**Test:**
- The shape validates and is ≤ 4 KiB.
- The phase sequence on a fixture run.
- The `recovering` ownership for a claimant.
- `stopped` with the exit code on normal, error and 130/143 paths.
- A read-only state dir leaves the result unchanged.

**DoD:** every controller exit leaves a `stopped` heartbeat with its exit code; existing controller tests unchanged.
**Verify:** `make test-one F=controller S=status`
**Risks:**
- The EXIT trap removing `CT_TMP` before the final write.
- Writing the claimant's heartbeat before the claim file exists.
**Red-first:** none
**Commit:** `Publish a controller heartbeat for status readers`

---

## F-2 — Show plan progress in `agentic-flow status <plan>`
**Why second:** it delivers the user-visible goal on f-1's evidence.

**Approach:**
- Add `scripts/lib/status.sh`. `scripts/lib` is already exported whole.
- Resolve a plan id or doc.
- Apply C-1 for the controller and station, C-2 for the snapshot and `next`, and C-3 for
  every read and for plan discovery.
- Bounces are admitted `bounce` events from the metrics cache. The limit comes from
  `config/workflow.tsv`.
- Render text and the JSON shape in Part A.
- `--watch` redraws on a TTY only and exits 0 on interrupt.
- The no-argument summary is appended after the unchanged install report.
- Use one control-character stripping helper for every rendered field.

**Test:**
- The status, interrupted, hold, escalation, ship, closed, incomplete, busy-ledger,
  discovery and TTY scenarios.
- A `gh` sentinel on `PATH` proves no network call.
- The upgrade group's status tests pass unchanged.

**DoD:** `status <plan>` names the next owner and an executable command offline, with the stated exit codes; the install report is unchanged.
**Verify:** `make test-one F=controller S=status` and `make test-one F=upgrade`
**Risks:**
- Recommending `ship` from partial rows. C-2 rule 3 must run before rule 6.
- Treating an orphaned intent as running.
**Red-first:** none
**Commit:** `Show plan progress and the next owner in agentic-flow status`

---

## F-3 — Run the controller detached
**Why third:** a background run is only usable once it is visible.

**Approach:**
- Implement C-4: validation and pre-check, the nonce, the Perl `setsid` exec, the
  acknowledgment wait, child-exit and timeout handling, the bounded log writer (a small
  Perl script under `scripts/lib/`), and pruning.
- `--json` prints `{pid, log, status}`.

**Test:**
- Two simultaneous detaches: one 0, one 9.
- A child failing before the lock exits with its code and the log tail.
- An acknowledgment timeout terminates the session and exits 5.
- A stale heartbeat with another nonce is not accepted.
- Output over the cap truncates the log, and the run's ledger and cache writes still
  succeed.
- The child survives the parent's exit.

**DoD:** `--detach` exits 0 only for an acknowledged controller and reports that controller's pid; logs are capped without limiting the controller.
**Verify:** `make test-one F=controller S=status`
**Risks:**
- The writer exiting early would raise EPIPE in the controller. The writer exits only at
  EOF.
- macOS has no `setsid` binary. Use Perl, not `nohup`.
**Red-first:** none
**Commit:** `Add run --detach with a startup acknowledgment and bounded log`

---

## F-4 — Wait for the human on resumable stops
**Why last:** it changes loop control flow on the stop path, the riskiest edit.

**Approach:**
- Implement C-5 at the single point after the loop breaks, so reconcile-time and
  dispatch-time stops share one classification.
- Polls reuse the loop's top-of-iteration reset and suppress dispatch.
- `--wait-human` with `--once` or `--reconcile-only` exits 2.
- The heartbeat records `waiting` per Part A.
- Polls raise nothing, so no notification repeats.
- Tests use a backoff override to stay within the tag ceiling.

**Test:**
- A reconcile-time hold, a dispatch-raised hold, and an escalated ask each resume after
  the human acts.
- Turn cap, unreadable ledger and integrity hold each exit 10 at once.
- `CT_TURNS` is unchanged across polls.
- Failed polls and the deadline behave as stated in C-5.
- Flag conflicts exit 2.

**DoD:** resumable stops resume in-process after the human acts; every other exit path is unchanged.
**Verify:** `make test-one F=controller S=status`
**Risks:**
- Per-turn state leaking into a poll.
- A dispatch-raised hold missing from `CT_HOLDS` until the next reconcile; classify with
  `CT_HOLD_REASONS`.
**Red-first:** none
**Commit:** `Add run --wait-human for resumable stops`

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
