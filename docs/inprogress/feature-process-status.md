<!-- TRIAGE (first pass · 2026-11-25) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict (touches the controller loop; project baseline is Standard)
> Phase 1 of [harness configurability](product-harness-configurability.md) (areas E and G): a local, read-only view of a plan's progress that answers "whose turn is it?", a controller heartbeat, `run --detach`, and `run --wait-human`. Drafted on `configurability-phase-1`; awaiting owner review.

# Feature — Process status and detached runs

## Tracker
- [ ] f-1 Publish a controller heartbeat — open
- [ ] f-2 Show plan progress in `agentic-flow status` — open
- [ ] f-3 Run the controller detached — open
- [ ] f-4 Wait for the human instead of exiting on a hold — open

---

# Part A — Analysis

## Goal

The owner reported that it is difficult to know the status of the process. While a plan
runs, the human cannot easily tell:

- whether a controller is alive,
- which station is working on which step, and for how long,
- how many bounces a step has used,
- whether the line is stopped and, if so, what the human must do next.

The controller also needs a terminal that stays open, and it exits as soon as the line
stops. Nothing resumes it when the human answers. This brief makes progress visible and
lets the controller run in the background and wait for the human, without adding a daemon.

## Current state

The data exists but nothing presents it.

- **Lock:** `agentic-flow/locks/controller-<plan>/owner.json` under the Git common dir holds
  `{pid,start,host,run}` (`scripts/lib/controller.sh:48-98`). Liveness is decided by
  matching the pid's start time through `scripts/lib/recovery.pl process`. Nothing records
  turn, phase or the running station.
- **State cache:** every reconcile writes `agentic-flow/state/<plan>.tsv` (issue, step,
  state, latest id, submitted head, refreshed time), `<plan>.metrics.json` (admitted events
  per issue, including bounces) and `<plan>.holds.json` (open holds)
  (`scripts/lib/handoff.sh:267-287`, `scripts/lib/andon.sh:162-174`).
- **Ledger:** `intent` records carry `started`, `issue`, `step`, `station`, `cli` and
  `model`. A matching `station` record carries `ended`, `seconds` and `usage`. An intent
  without a station record is a station in flight. `hold` and `clear` records mirror holds
  (`scripts/lib/ledger.pl:168-226`).
- **`agentic-flow status`** reports only the harness install (version, candidates,
  git-ignored payload). It exits 1 when that needs action (`scripts/agentic-flow:466-540`).
  Its tests live in `scripts/tests/upgrade.sh`.
- **`agentic-flow run`** is a foreground loop (`controller.sh:902`). It breaks out with
  result 10 when a hold, raised andon or escalated issue exists. `--once` stops after one
  station. The turn cap is 50. `andon_desktop` already notifies on a hold.
- Station timeouts come from the effective roles (`agentic-flow roles --json`).

## Proposed approach

### Option A — Local read-only view + heartbeat + detach/wait flags (recommended)

- The controller atomically writes a small heartbeat file each phase change.
- `status` reads only local files (heartbeat, lock, state cache, ledger, roles). It never
  calls `gh`, never takes the lock, and never writes.
- `run --detach` backgrounds the same controller with a log file.
- `run --wait-human` turns the "stop on hold" exit into a bounded, backed-off poll.

Pros: no network in the view, so `--watch` is free and safe; additive; no new process model.
Cons: the view is as fresh as the last reconcile. It shows the cache age rather than hiding it.

### Option B — Live view that queries the forge

Always current, but every refresh costs API calls and needs credentials. `--watch` would
hit rate limits. Rejected for this pass. An explicit `--refresh` can come later.

### Option C — A daemon serving status over a socket

Rejected in the product analysis (area G). It adds a process model for no new data.

**Recommendation:** Option A. The heartbeat is advisory display data. The lock and the
journal stay the only authorities. Nothing reads the heartbeat to make a decision.

**`status` naming.** The product analysis left open whether the process view takes over
`status`. This brief takes the non-breaking path. `agentic-flow status` with no argument
prints the existing install report unchanged, followed by a one-line summary per local
plan. `--json` gains a `plans` key, and all existing keys stay identical. Its exit code
stays tied to the install report. `agentic-flow status <plan-id|doc>` prints the detailed
plan view alone, with its own exit codes.

## Interface (before the implementation)

```
agentic-flow status [--json]                          # install report + plans summary
agentic-flow status <plan-id|doc> [--watch [<s>]] [--json]
  exit 0  no human action needed (station working, or controller alive and reconciling)
  exit 10 human action needed (see "next")
  exit 2  usage (incl. --watch without a TTY, --watch with --json)
  exit 3  unknown plan (no state, no ledger, no lock)

agentic-flow run <doc> [--once] [--reconcile-only] [--take-over] [--json]
                       [--detach] [--wait-human [<max-s>]]
  --detach       start the same invocation in a new session; print pid, run log, status cmd; exit 0
  --wait-human   on result 10, poll with backoff instead of exiting; not with --once/--reconcile-only

<common>/agentic-flow/state/<plan>.controller.json     (≤ 4 KiB, atomic tmp+mv)
{ v:1, plan, pid, start, host, run, doc,
  phase: "reconciling"|"station"|"waiting-human"|"stopped",
  turn, turn_cap,
  station: null | {issue, step, station, cli, run, started, timeout_s},
  waiting: null | {since, next_poll_at, until},
  exit: null | <int>, updated_at }

<common>/agentic-flow/logs/<plan>/<run-id>.log         (detached runs; newest 20 kept per plan)

status JSON (plan view):
{ v:1, plan, doc, as_of:{cache, ledger},
  controller:{state:"alive"|"stopped"|"unknown", pid, phase, turn, turn_cap, updated_at, exit},
  steps:[{issue, step, state, bounces, bounce_limit, station:null|{cli, elapsed_s, timeout_s}}],
  holds:[{id, issue, reason, clear:"agentic-flow hold clear <doc> <id>"}],
  usage:{cost_usd:null|number},
  next:{owner:"controller"|"station"|"human", action:<text>, command:null|<text>} }
```

The `next` rules, applied in order:
1. An open hold → human, with the `hold clear` command.
2. An escalated issue → human, answer on `#N`.
3. The controller is alive → controller or station.
4. Every step is approved or closing → human, `agentic-flow ship <doc>`.
5. Otherwise → human, `agentic-flow run <doc>`.

## Threat model (one paragraph)

No new trust boundary or credential path. `status` reads files under the user's own Git
common dir that the controller, handoff and ledger already write. It treats them as
untrusted input: size-bounded, schema-checked, and rendered with control characters
stripped. Hold reasons and ask text can originate in station output, and an escape sequence
must not reach the terminal. A local process could forge the heartbeat. That only misleads
the display, because liveness is confirmed by the pid's start time, as the lock does, and
no decision reads the heartbeat. `--detach` passes the controller exactly the environment
a foreground `run` gets, and stations keep their `env -i` isolation. The detached log holds
the controller's stderr only, which is the same content the terminal shows today. It lives
under the Git common dir, outside the tree.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---|---|---|---|
| Heartbeat read | n/a (local) | Controller `unknown`; the rest of the view still renders | — |
| Process probe (`recovery.pl process`) | Controller `unknown` | Controller `unknown` | — |
| State cache / holds cache | n/a | Section shows "cache unreadable", cache age `null` | Rows that parse are shown |
| Ledger read | n/a | Ledger error shown on one line; ledger-derived fields `null` | — |
| Forge poll during `--wait-human` | Existing bounded `gh` timeout; counts as a failed poll | Same as today's reconcile (exit 5), retried as a failed poll | — |
| Heartbeat write | n/a | Warning on stderr; the controller continues (display data only) | tmp file removed |

Bounds:
- heartbeat ≤ 4 KiB; at most 100 issues rendered; text fields cut to 120 characters
- `--watch` interval 2–300 s (default 5)
- `--wait-human` backoff 60 s doubling to 900 s, default maximum 86,400 s, at most 604,800 s
- at most 3 consecutive failed polls, then the existing exit code
- logs capped by `ulimit -f` like station captures; newest 20 per plan kept

## Out of scope / What NOT to build in this pass
- Querying the forge from `status` (`--refresh`), or any network call in the view.
- launchd/systemd unit templates; a long-running multi-plan daemon.
- Making notification channels configurable (product area A/C). The existing desktop
  notification is kept.
- Changing what counts as a hold, the bounce limit, or the turn cap.
- A TUI library or GUI. `--watch` is a plain ANSI redraw.
- Denying `run` to agent stations in the command policy (a separate decision).

## Open questions
- [BLOCKING] Accept the non-breaking `status` shape above, or let `status` default to the
  process view in a future breaking release?
- Should `--wait-human` default to on for unattended `run` (no `--once`) once it has proven
  itself? This brief keeps it opt-in.

---

# Part B — Implementation Brief

## Acceptance scenarios
- Given no ledger, state or lock for a plan, when `status <plan>` runs, then it exits 3 and names `agentic-flow run <doc>`.
- Given a heartbeat whose pid is dead or has a different start time, when `status <plan>` runs, then the controller is `stopped`, `next` is the human with `agentic-flow run <doc>`, and the exit is 10.
- Given a malformed or oversized heartbeat, when `status <plan>` runs, then the controller is `unknown`, the other sections still render, and the exit is not a crash.
- Given an open hold whose reason contains ANSI escapes, when `status <plan>` runs, then the output has no control characters, shows the exact `hold clear` command, and the exit is 10.
- Given a live controller with an executor station in flight, when `status <plan>` runs, then the step shows the CLI, elapsed seconds and timeout, `next.owner` is `station`, and the exit is 0.
- Given a step with one admitted bounce, when `status <plan>` runs, then it shows `bounce 1/2`, with the limit taken from `config/workflow.tsv`.
- Given an adopted project, when `status` runs with no argument, then the install report lines and JSON keys are byte-identical to before, plus a `plans` section or key.
- Given a non-TTY stdout, when `status <plan> --watch` runs, then it exits 2.
- Given a live controller for a plan, when `run <doc> --detach` runs again, then it exits 9 before forking.
- Given `run <doc> --detach`, then it returns 0 promptly, prints the pid and log path, the log receives controller stderr, and `status` shows the controller alive.
- Given `--wait-human` with `--once` or `--reconcile-only`, then `run` exits 2.
- Given `--wait-human` and a hold, when the human clears it, then the controller resumes dispatch without a restart, and the polls did not consume the turn cap.
- Given `--wait-human` and an integrity failure (exit 9, 3 or 5 outside a poll), then the controller exits immediately as today.
- Given `--wait-human` and no human action before the maximum wait, then the controller exits 10.

## Invariants
- `status` never writes, never takes or edits the lock, and never runs `gh` or any network command.
- Nothing in the controller reads the heartbeat for a decision. The lock, ledger and journal stay authoritative.
- Foreground `run` without the new flags behaves exactly as today, apart from writing the heartbeat.
- Stations launched by a detached or waiting controller get the same environment and isolation as today.
- Bash 3.2 compatible; no new required tool. Detaching uses Perl's `POSIX::setsid`; Perl is already required by the ledger.
- Every rendered string is bounded and stripped of control characters.

```agentic-flow-plan
format: 2
id: process-status
profile: strict
tracking: Plan: Process status and detached runs
branch: configurability-phase-1
steps: f-1 f-2 f-3 f-4
```

## Branch
Base: `main`. One branch and one PR for the whole brief:
`configurability-phase-1`. Each step lands as its own commit on that branch, closing its
issue via `Fixes #N`.

## Definition of done (whole brief)
Every step's DoD met; `make check` and `make test` green. Manually: start
`agentic-flow run <doc> --detach --wait-human` on a fixture or real plan, watch it with
`agentic-flow status <plan> --watch`, clear a hold, and see the line resume. Help text,
`ADOPTION.md`'s run section, and the station-commands paragraph in both `CLAUDE.md` and
`templates/harness/CLAUDE.md` (and the matching `AGENTS.md` pair if it names `run`) describe
the new commands.

## Verification commands
```bash
make check                                # per step
make test-one F=controller S=status       # f-1..f-4 (new tag; add its wall-time ceiling)
make test-one F=upgrade                   # f-2: install report unchanged
make test                                 # end of brief
```

---

## F-1 — Publish a controller heartbeat
**Why first:** every other step reads it. It is also the only change inside the controller
loop that runs on every turn, so it should land and be reviewed alone.

**Approach:**
- Write `<common>/agentic-flow/state/<plan>.controller.json` (shape in Part A) through a
  tmp file + `mv`:
  - after the lock is taken,
  - at each turn start (`reconciling`),
  - when a station is launched (`station`, with the intent's run, issue, step, station,
    CLI, start time and effective timeout),
  - when it returns,
  - at exit (`stopped` plus the exit code, from the existing EXIT trap path).
- A write failure only warns. It never changes the controller's result.
- Add the `status` selector tag to the controller test group, with a ceiling in
  `config/test-wall-ceilings.tsv` and the tag in the Makefile usage string.

**Test:**
- Fixture controller run: the heartbeat exists, validates against the shape, and is ≤ 4 KiB.
- Phase moves `reconciling` → `station` → `stopped` with the exit code.
- A read-only state dir produces a warning and an unchanged result.
- The interrupt path (130/143) records `stopped`.

**DoD:** every controller exit leaves a `stopped` heartbeat with its exit code; existing controller tests unchanged.
**Verify:** `make test-one F=controller S=status`
**Risks:**
- Writing from the EXIT trap after `CT_TMP` is removed. Order the write before cleanup.
- A heartbeat must never be written into the lock directory, which `controller_unlock` deletes.
**Red-first:** none
**Commit:** `Publish a controller heartbeat for status readers`

---

## F-2 — Show plan progress in `agentic-flow status`
**Why second:** it delivers the user-visible goal, using f-1's heartbeat and existing caches.

**Approach:**
- Add a status library (e.g. `scripts/lib/status.sh`) that `status_cmd` sources. Add the
  library to `config/payload.tsv` only if `scripts/lib` is not already exported as a whole
  (it is today).
- **Plan resolution:** a plan id, or a `docs/inprogress|done/*.md` doc whose plan block
  gives the id.
- **Sources:** heartbeat plus the process probe for liveness; `<plan>.tsv` for step states;
  `<plan>.metrics.json` for bounce counts (admitted `bounce` events per issue);
  `<plan>.holds.json` plus ledger `hold`/`clear` for open holds; ledger `intent` without
  `station` for the in-flight station; ledger station usage for cost; effective roles for
  timeouts; `config/workflow.tsv` for the bounce limit.
- **Rendering:** text as sketched in the product analysis, area E, with cache age shown
  as `as of`.
- Apply the `next` rules in the stated order.
- `--watch [<s>]` redraws on a TTY only and exits 0 on interrupt.
- The no-argument form appends a `plans:` section, one line per plan found under
  `state/`, `locks/` or the ledger. Install output and exit code are unchanged.
- Strip control characters with one helper used for every rendered field.

**Test:** the first eight acceptance scenarios, plus:
- JSON plan view validates (`jq -e` on the shape).
- No-argument JSON keeps every existing key.
- The upgrade group's status tests still pass untouched.
- A `gh` sentinel on `PATH` proves no network call.

**DoD:** `status <plan>` answers "whose turn is it?" offline with correct exit codes; the install report is unchanged.
**Verify:** `make test-one F=controller S=status` and `make test-one F=upgrade`
**Risks:**
- Two plans with the same id in different worktrees. The Git common dir is shared, so the id is unique. Assert it.
- Stale cache read as live state. Always print the cache age; never infer "alive" from the cache.
**Red-first:** none
**Commit:** `Show plan progress and the next owner in agentic-flow status`

---

## F-3 — Run the controller detached
**Why third:** it is only useful once the human can see a background run (f-2).

**Approach:**
- `run <doc> --detach` validates the remaining arguments first, so usage errors still
  exit 2 in the foreground.
- It pre-checks the lock owner the way `controller_lock` does, and exits 9 with the same
  message if a live controller owns the plan.
- It then re-invokes the same `agentic-flow run` argv, without `--detach`, in a new
  session via `perl -MPOSIX -e 'POSIX::setsid()…'`:
  - stdin from `/dev/null`,
  - stdout and stderr to `logs/<plan>/<run-id>.log` under `ulimit -f`.
- It prints the child pid, the log path and `agentic-flow status <plan> --watch`, then
  exits 0.
- It prunes the plan's logs to the newest 20 before starting.
- `--json` prints those three fields as JSON.

**Test:**
- The detached fixture run returns within a few seconds while the fixture station sleeps.
- The log receives controller stderr.
- The heartbeat shows `alive` with the child's pid.
- A second `--detach` exits 9 without forking.
- A usage error exits 2 without forking.
- The child survives the parent shell exiting (checked by pid and start time).

**DoD:** a detached run is observable through `status` and its log, and refuses to double-start.
**Verify:** `make test-one F=controller S=status`
**Risks:**
- A pre-check race with a starting controller. The child's own `controller_lock` stays authoritative; the pre-check is only for a friendly error.
- macOS has no `setsid` binary. Use Perl, not `nohup`, which the command policy denies for agents and which does not create a new session.
**Red-first:** none
**Commit:** `Add run --detach with a per-plan run log`

---

## F-4 — Wait for the human instead of exiting on a hold
**Why last:** it changes loop control flow on the stop path, the riskiest edit. It builds
on f-1's `waiting-human` phase.

**Approach:**
- With `--wait-human [<max-s>]`, a loop iteration that would `break` with result 10
  instead records `waiting-human` (since, next poll, until) in the heartbeat and sleeps.
  Backoff starts at 60 s and doubles to 900 s. Then the iteration re-enters the
  reconcile, which already re-reads holds and journal.
- Poll iterations do not increment `CT_TURNS`.
- A poll that fails with exit 5 counts as a failed poll. Three in a row end the run with 5.
- Any other non-10 result exits immediately, unchanged.
- The run exits 10 when `until` passes.
- `--wait-human` with `--once` or `--reconcile-only` exits 2.
- The lock stays held throughout.
- The existing desktop notification fires once per new hold, not once per poll.

**Test:**
- Hold raised → waiting heartbeat; clear recorded in the fixture → the next poll resumes
  dispatch.
- `CT_TURNS` is unchanged across polls.
- Exit 9 and 3 paths are unaffected.
- Three failed polls → exit 5.
- A maximum wait elapses → exit 10.
- Flag conflicts → exit 2.
- Use a test-only backoff override so the tag stays within its ceiling.

**DoD:** an unattended run with `--wait-human` survives a hold and resumes on its own; every other exit path is unchanged.
**Verify:** `make test-one F=controller S=status`
**Risks:**
- Re-entering the loop with per-turn state left over (`CT_RAISED`, `CT_HOLD_REASONS`). Reuse the loop's existing reset at the top of each iteration rather than a second path.
- Sleeping while holding the lock past the lease. The lease governs foreign hosts' journal age, not local pid ownership. State this in the help text.
**Red-first:** none
**Commit:** `Add run --wait-human to resume after the human answers`

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
