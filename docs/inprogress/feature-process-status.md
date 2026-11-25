<!-- TRIAGE (first pass · 2026-11-25) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict (touches the controller loop; project baseline is Standard)
> Phase 1 of [harness configurability](product-harness-configurability.md) (areas E and G): an offline, read-only plan view that answers "whose turn is it?", a controller heartbeat, `run --detach` with a startup acknowledgment, and `run --wait-human` for resumable stops. Revision 2 (2026-11-25) answers the first review: resumable stops, launch acknowledgment, log capping, station evidence, executable next actions, read bounds. Revision 3 answers the second: a write-once acknowledgment file, heartbeat writes only under lock ownership, separate holds completeness, a live controller preferred over a stale cache, the only valid bounce resume, and observe-only polls with deduplicated notifications. Revision 4 answers the third: atomic acknowledgment with a final read after reaping, hold-id snapshots before and during waits, and a `--return`-free resume command.

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
  `agentic-flow handoff <N> resume --as approver [--return <state>] --body-file <note>`
  (`config/workflow.tsv`; `handoff.sh:300-316`). Replay sets `return_to`:
  - an `ask` sets it to the state the asker was in;
  - a bounce at the limit sets it to `executing` (`journal.jq:28-29`).

  `--return` is optional. When given, it must equal `return_to` (`handoff.sh:402-404`).
  When omitted, the successor uses `return_to`.
- **Startup order:** `controller_cmd` installs its EXIT trap before validating the doc and
  before `controller_lock` (`controller.sh:853`), so a rejected invocation still runs its
  exit path.
- **Reconcile effects:** a reconcile pass runs these, any of which can raise holds:
  - `controller_labels`, `controller_open_state`
  - `controller_plan_effect`, `controller_unjournaled`
  - `controller_completed_effects`, `controller_pending`
- **Local-only holds:** when the approver identity is unavailable, `handoff … hold`
  records a local-only hold and notifies. A later call for the same issue and reason finds
  the match with `comment_id=null`, records it again and notifies again
  (`scripts/lib/andon.sh:99-118`).
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
  --detach      success only with a write-once acknowledgment (C-4); prints controller pid, log, status cmd;
                exit 0 while the controller runs, or the controller's own code if it already finished
  --wait-human  wait on resumable stops (C-5); exit 2 with --once or --reconcile-only

<common>/agentic-flow/state/<plan>.controller.json     (≤ 4 KiB, tmp + mv)
{ v:1, plan, doc, pid, start, host, run, ownership:"owner"|"recovering",
  phase:"reconciling"|"station"|"waiting-human"|"stopped",
  turn, turn_cap,
  station:null|{issue, step, station, cli, run, started, timeout_s},
  waiting:null|{stop, reasons, issues, holds, seqs, since, next_poll_at, until, failed_polls},
  exit:null|<int>, updated_at }

<common>/agentic-flow/launches/<nonce>.json             (write-once ack, ≤ 1 KiB; read and removed by the detach parent)
{ v:1, nonce, plan, pid, start, host, run, ownership, at }

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
**Only the lock holder writes.** Every heartbeat write, including the final one, requires
`CT_LOCK_OWNED=true` or `CT_RECOVER_CLAIM=true`. An invocation that fails validation or
loses the lock never touches the heartbeat. Its EXIT trap skips the write. The controller
writes:
- right after `controller_lock` succeeds, as owner or as recovery claimant;
- at every turn start, at station launch and return, at entering and leaving a wait;
- at exit, on every path including interrupts, while still owning the lock. That is,
  before `controller_unlock` removes it and before `CT_TMP` cleanup.

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
Each cache source has its own completeness check:

- **Plan:** the plan block parses from the plan doc on the local branch ref (`git show`,
  ≤ 1 MiB, using the plan-block parser without an approval check).
- **Steps (tsv):** exactly one row per planned step, plus the tracker for Strict, or
  exactly one work row for Standard. Every state is valid for its topology.
- **Metrics:** parses within C-3's caps. Rows are matched to tsv issues, and a missing
  row only nulls that step's bounce count.
- **Holds:** the file exists, is within its cap and parses as an array. An empty array is
  valid and means no open holds. Each entry must name an issue of this plan. There is
  **no** coverage requirement against the tsv.

The snapshot is complete when the plan, step and holds checks pass. Metrics gaps never
make it incomplete.

Rules, in order:

1. Holds data complete and a hold open → human: `agentic-flow hold clear <doc> <hold-id>`,
   after reading the hold note on `#N`.
2. Step data complete and an issue escalated with no open hold → human records the
   decision:
   `agentic-flow handoff <N> resume --as approver --body-file <decision.md>`.
   - **The command never carries `--return`.** The flag is optional, and without it
     `handoff` resumes to the journal's own `return_to` (`handoff.sh:402-404, 109`).
     So the emitted command is valid whatever the cache says.
   - The expected return state is shown for information only, and only with matching
     event evidence: the issue's metrics row must have, as its last admitted event, the
     id in the tsv's `latest id` column, and that event must be an `ask` or `bounce`.
     The mapping follows replay:
     - executor `ask` → `executing`
     - reviewer `ask` → `reviewing`
     - bounce at the limit → `executing`
   - If the metrics row is missing, or its last event id differs from the tsv's (the two
     files are published separately), the view says "return state: see #N" and still
     emits the same command.
3. Controller `alive` or `recovering` → `station` when C-1 proves one is running, else
   `controller`. Exit 0. This rule runs before any incomplete-snapshot rule, because a live
   controller refreshes the cache itself and holds the lock that would reject a second
   `run`. The view adds "cache incomplete; the controller will refresh it".
4. Snapshot complete and the plan closed (the Strict tracker or the Standard work issue is
   `closed`) → `none`, exit 0. The action notes that `agentic-flow clean <plan>` follows
   the merge.
5. Snapshot incomplete, with no live controller → human:
   `agentic-flow run <doc> --reconcile-only`. Never `ship`, never "closed".
6. Snapshot complete and ready to ship → human: `agentic-flow ship <doc> --wait-review`.
   Ready means:
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
- **Acknowledgment: a write-once file, not the heartbeat.**
  - The nonce must match `^[0-9a-f]{32}$`.
  - Right after `controller_lock` succeeds, the controller writes the complete
    acknowledgment `{pid (CT_PID), start, host, run, ownership}` to a temp file in
    `launches/`. It publishes it atomically and exclusively with `ln <tmp> <nonce>.json`,
    which fails if the name exists, then removes the temp file. It never rewrites it. A
    reader therefore sees either no file or the whole file, never a partial one.
  - The file outlives the controller, so a run that finishes before the parent's first
    poll still leaves its acknowledgment.
- **Parent loop:** every 0.2 s for up to 30 s (`AGENTIC_DETACH_ACK_S` overrides this for
  tests), check the acknowledgment file first, then the child.
  - **Ack present, child running:** print the ack's `pid`, the log path and
    `agentic-flow status <plan> --watch`, remove the ack file, and exit 0.
  - **Ack present, child already exited:** print the same fields plus
    `controller finished: exit <n>`, remove the ack file, and exit with the child's code.
    The launch was acknowledged, and the code is the run's real outcome.
  - **Child exited with no ack seen:** reap the child first, then **read the
    acknowledgment file once more**. The child may have published it between the
    parent's read and its exit check.
    - If the final read finds it, this is the "ack present, child already exited" case.
    - Only if the final read also finds nothing is it a startup failure: print the last
      20 stripped log lines and exit with the child's code (a lost lock race is 9). A child
      exit of 0 with no ack exits 5 ("exited without acknowledgment").
  - **Timeout:** TERM the child's session, wait up to 10 s, then KILL, and exit 5 with the
    log path.
- **Cleanup:** before forking, remove acknowledgment files older than 24 h. `status` never
  reads them.
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
- **Fresh hold snapshot before waiting.**
  - `CT_HOLDS` can miss a hold raised during dispatch, and `CT_HOLD_REASONS` has no ids.
    So before entering a wait the controller re-runs `controller_holds`
    (`controller.sh:158-176`). It is observe-safe:
    - it reads the tracker;
    - it mirrors *existing* remote hold markers and clears into the ledger;
    - it rebuilds `CT_HOLDS` from those markers plus local-only ledger holds through
      `hold_snapshot`;
    - it never notifies, raises a hold or writes to the forge.
  - It records the full **open hold id set** and the escalated issue set.
  - The stop is classified from that snapshot. Every raised `{issue, reason}` in
    `CT_HOLD_REASONS` must appear in it; if one doesn't, the wait is refused and the
    controller exits 10.
- Record `waiting-human` with `until = now + max` (default 86,400 s, at most 604,800 s),
  plus the escalated issue set, the open hold id set and each plan issue's journal seq.
- Sleep `min(backoff, until − now)`; backoff starts at 60 s and doubles to 900 s.
- **Polls are observe-only.** A poll is not a reconcile pass.
  - **Enabled during a poll:**
    - the read-only report (`handoff_drift` via `controller_check`);
    - `controller_holds`' import of authorized remote clears into the ledger;
    - the state-cache write (`handoff_write_cache`).
  - **Disabled during a poll:** `controller_labels`, `controller_open_state`,
    `controller_plan_effect`, `controller_unjournaled`, `controller_completed_effects`,
    `controller_pending`, `controller_foreign`'s hold path, and dispatch.

  So a poll can neither raise a hold nor post a handoff.
- **The wait ends when the observation changes.** Each poll takes the same hold snapshot
  and compares the whole open hold id set with the recorded one. Hold markers are
  separate from transition sequences, so seqs alone would miss a new hold. The wait ends
  when:
  - every hold in the recorded set is cleared and no recorded issue is still escalated,
    so the stop is resolved;
  - **any hold id not in the recorded set is open**, including an integrity hold or one
    raised by an approver;
  - any plan issue's journal seq moves for another reason;
  - a foreign controller host appears.

  The loop then runs one normal, full turn, which counts against `CT_TURNS`. That turn
  classifies any new stop afresh and may legitimately raise holds.
- **Poll failures:**
  - a poll exiting 5 counts as a failed poll, with the same backoff and deadline;
  - 3 failed polls in a row exit 5;
  - any other non-zero code from a poll exits with that code.
- A poll never starts at or after `until`, which exits 10. Polls do not increment
  `CT_TURNS`. The lock stays held.

**Notification deduplication.** A notification fires only when a new hold id is recorded.
In `scripts/lib/andon.sh`:
- When a matching local-only hold already exists (same issue and reason,
  `comment_id=null`) and the approver identity is still unavailable, `handoff … hold`
  returns "hold already open (local-only)" without a new record or notification.
- When the approver identity is available, publishing that existing hold id as a comment
  is not a new hold and does not notify again.

Combined with observe-only polls, a wait never repeats a notification.

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
| Cache files | n/a | Listed in `over_limit` or `missing`; snapshot incomplete | No partial parse; rule 3 if the controller is live, else rule 5 |
| `ledger_read` | `ledger: busy`, fields `null` | `ledger: error`, fields `null` | — |
| Detach acknowledgment | TERM, then KILL the child session; exit 5 | Unparseable or wrong-nonce ack file = no ack | Child exit with ack → its code with the pid; without ack → its code (0 becomes 5) |
| Log writer | n/a | n/a | Write error: drain without writing |
| Forge poll in a wait | Existing `gh` bound; failed poll | Exit 5 from the observe-only poll = failed poll | — |

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
- Given an escalated issue, then `next` is the approver `resume` with no `--return` flag. With matching event evidence, the view shows `executing` after an executor `ask`, `reviewing` after a reviewer `ask`, and `executing` after a bounce at the limit. In a fixture, the emitted command resumes each case to the journal's `return_to`.
- Given an escalated issue whose metrics row is missing, or whose last event id differs from the tsv's `latest id`, then the view shows "return state: see #N" and emits the same `--return`-free command.
- Given every step approved, a tracker `open`, a holds cache of `[]`, and complete step data, then the snapshot is complete and `next` is `ship`. Given a closed tracker, then `next.owner` is `none` and the exit is 0.
- Given a missing step row or an over-limit holds cache and no live controller, then the snapshot is incomplete and `next` is `--reconcile-only`, never `ship`. With a live controller, `next.owner` is `controller`, the exit is 0, and the view notes that the cache is incomplete.
- Given a missing metrics row, then only that step's bounce count is null, and the snapshot stays complete.
- Given a held ledger lock, then `ledger: busy` is reported and the command still exits.
- Given 25 plans in `state/`, when `status` runs with no argument, then 20 are listed followed by `5 more`. The install lines and JSON keys are byte-identical to before.
- Given a non-TTY stdout, `status <plan> --watch` exits 2.
- Given two simultaneous `run --detach` invocations, then exactly one exits 0 with the acknowledged controller's pid, and the other exits 9. The winner's heartbeat (pid, run) is unchanged after the loser exits.
- Given an invocation that fails validation or loses the lock, then no heartbeat or acknowledgment file is written or changed.
- Given `run --detach --reconcile-only` on a fixture that finishes before the parent's first poll, then the parent reports the acknowledged pid and log, prints `controller finished: exit 0`, and exits 0.
- Given the acknowledgment lands after the parent's acknowledgment read but before its child-exit check, forced with a test pause hook between the two, then the final post-reap read finds it, and the launch is reported as acknowledged, not as a startup failure.
- Given a child that fails before the lock (a dirty plan worktree), then `--detach` exits 3 with the log tail and no acknowledgment.
- Given a stale acknowledgment file with another nonce, then it is ignored.
- Given a controller writing past 16 MiB of output, then the log stops at the cap with the truncation marker, and the run and its ledger writes complete.
- Given `--wait-human` with `--once` or `--reconcile-only`, then `run` exits 2.
- Given `--wait-human` and an existing hold found at reconcile, when the human clears it, then dispatch resumes in the same process without consuming turns.
- Given `--wait-human` and a dispatch-raised `station-infrastructure` hold, then the wait records that hold's id from the fresh snapshot. When the human clears it, dispatch resumes.
- Given `--wait-human` waiting on a resumable hold, when an integrity hold (or a hand-raised approver hold) opens without any transition seq moving, then the next poll sees the new hold id, the full turn classifies it as non-resumable, and the controller exits 10.
- Given `--wait-human` and a turn-cap stop, an unreadable ledger, or an integrity hold, then the controller exits 10 immediately.
- Given `--wait-human` and an approver `resume` on an escalated ask, then the next poll resumes dispatch.
- Given `--wait-human` and a pending plan effect or unjournaled condition during the wait, then no poll raises a hold or posts a handoff. Only the full turn after the observation changes may raise one.
- Given `--wait-human`, a local-only hold, and an approver identity that stays unavailable, then the desktop notification fires exactly once across the whole wait.
- Given `--wait-human`, then 3 failed polls exit 5, and an elapsed deadline exits 10 without another poll.

## Invariants
- `status` never writes files, never creates or edits the controller lock, and never runs `gh` or any network command. The only lock it takes is `ledger_read`'s bounded shared lock on an existing ledger file.
- Nothing in the controller reads the heartbeat for a decision. The lock, ledger and journal stay authoritative.
- Only the lock owner or recovery claimant writes the heartbeat or an acknowledgment file, and only while it holds that ownership.
- A `--wait-human` poll never raises a hold, posts a handoff, repairs labels or projects state. A notification fires only for a newly recorded hold id.
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
- The writer is a no-op unless `CT_LOCK_OWNED` or `CT_RECOVER_CLAIM` is true. The EXIT
  trap's final write runs before `controller_unlock`.
- Include `ownership`.
- A write failure warns only.
- Add the `status` tag to the controller group, its ceiling in
  `config/test-wall-ceilings.tsv`, and the tag in the Makefile usage string.

**Test:**
- The shape validates and is ≤ 4 KiB.
- The phase sequence on a fixture run.
- The `recovering` ownership for a claimant.
- `stopped` with the exit code on normal, error and 130/143 paths.
- An invocation rejected at doc validation, and one that loses the lock, leave an existing
  heartbeat byte-identical.
- A read-only state dir leaves the result unchanged.

**DoD:** every controller exit leaves a `stopped` heartbeat with its exit code; existing controller tests unchanged.
**Verify:** `make test-one F=controller S=status`
**Risks:**
- The EXIT trap removing `CT_TMP` or the lock before the final write.
- A losing invocation's trap overwriting the winner's heartbeat.
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
- Implement C-4:
  - validation and pre-check;
  - the nonce;
  - the controller's write-once acknowledgment file, created right after the lock is
    taken and published atomically with `ln`;
  - the Perl `setsid` exec;
  - the parent loop with its four outcomes, and the final acknowledgment read after
    reaping;
  - the bounded log writer (a small Perl script under `scripts/lib/`);
  - pruning of logs and old acknowledgment files.
- `--json` prints `{pid, log, status, finished_exit}`.

**Test:**
- Two simultaneous detaches: one 0, one 9. The winner's heartbeat and acknowledgment
  survive the loser.
- A `--reconcile-only` run that finishes before the first poll reports the acknowledged
  pid and its exit.
- A test pause hook lands the acknowledgment between the parent's read and its exit
  check; the final read after reaping still reports success.
- A child failing before the lock exits with its code and the log tail.
- An acknowledgment timeout terminates the session and exits 5.
- A stale acknowledgment file with another nonce is ignored.
- Output over the cap truncates the log, and the run's ledger and cache writes still
  succeed.
- The child survives the parent's exit.

**DoD:** `--detach` reports success only for an acknowledged controller, with that controller's pid, even when the run has already finished; logs are capped without limiting the controller.
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
- Add an observe-only poll function made only of C-5's enabled effects. It is not a
  reconcile pass with dispatch switched off.
- When the observation changes, run one normal full turn.
- Add the local-only hold dedup in `scripts/lib/andon.sh` per C-5.
- `--wait-human` with `--once` or `--reconcile-only` exits 2.
- Before waiting, re-run `controller_holds` for a fresh open hold id set. Refuse the wait
  if a raised `{issue, reason}` is missing from it.
- Each poll compares the whole open hold id set as well as the seqs.
- The heartbeat records `waiting` per Part A, including the hold ids and the journal seqs
  that define "changed".
- Tests use a backoff override to stay within the tag ceiling.

**Test:**
- A reconcile-time hold, a dispatch-raised hold, and an escalated ask each resume after
  the human acts.
- An integrity hold arriving while waiting on a resumable hold ends the wait, and the run
  exits 10.
- Turn cap, unreadable ledger and integrity hold each exit 10 at once.
- A fixture with a pending plan effect and an unjournaled condition: polls raise no hold
  and post nothing.
- A local-only hold with the approver unavailable notifies exactly once (count the
  `osascript`/`notify-send` sentinel calls).
- `CT_TURNS` is unchanged across polls.
- Failed polls and the deadline behave as stated in C-5.
- Flag conflicts exit 2.

**DoD:** resumable stops resume in-process after the human acts; every other exit path is unchanged.
**Verify:** `make test-one F=controller S=status`
**Risks:**
- Per-turn state leaking into a poll.
- A dispatch-raised hold missing from `CT_HOLDS` until the next reconcile; classify with
  `CT_HOLD_REASONS`.
- The dedup change must still publish a local-only hold once the approver becomes
  available, without notifying again.
**Red-first:** none
**Commit:** `Add run --wait-human for resumable stops`

---

## Status / Implementation status
- **Evidence schema:** v2
- **Tracking issue:** pending
- **Approval:** status=approved; by=wabkebab; at=2026-11-25; rev=f93645f45f4f52a548fe71b734b12fb642bcd20b
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
