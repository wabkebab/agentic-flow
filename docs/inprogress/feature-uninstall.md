<!-- TRIAGE (first pass · 2026-11-27) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict (deletes adopter files, changes the install records, the controller lock and the hook setup, and adds a command-policy floor row; project baseline is Standard)
> Phase 3 of [harness configurability](product-harness-configurability.md) (area J): `agentic-flow uninstall`, which removes only what the harness has recorded evidence of creating, behind a fence that excludes every writer. A resumable apply leaves the verified deletions staged for the adopter to commit. Kept files and shared Git state are reported for manual follow-up.
> Draft 8 (2026-11-27), written against `0.21.0` (`3757627`). It answers the sixth review: a file that reappears after a staged deletion is kept, removal eligibility includes the Git mode, and the staged-edit test now expects the resume gate's refusal. See *Revision history*. Owner decisions: *Uninstall acceptance* yes, *Legacy ownership* keep f-5, *Commit* stage-only, *Shared Git state* report-only, *Plan cleanup* adopter runs `clean` first. Next: the reviewer's seventh round, then owner approval.

# Feature — Uninstall: remove only what the harness owns

## Tracker
- [ ] f-1 — Record ownership evidence when the harness writes a path — open
- [ ] f-2 — Classify ownership and report the removal as a dry run — open
- [ ] f-3 — Fence uninstall against every shared-state writer — open
- [ ] f-4 — Stage the removal from a persisted plan that a retry can resume — open
- [ ] f-5 — Let the owner claim legacy paths, proven against the installed revision — open

---

# Part A — Analysis

## Goal

An adopter who stops using the harness needs a clean way out. Today the only way is to
delete files by hand. That loses either way: it leaves stamps, a `core.hooksPath` that
points at a deleted directory, and plan worktrees, or it deletes files the adopter changed.

The owner's goal 8 (2026-11-25) asks for a script that removes the harness cleanly. The
product analysis (area J) settled what "cleanly" means. Remove only what the harness can
prove it owns. Never override a plan guard. Print everything outside the repository, and
everything kept, as a checklist instead of touching it.

**v1 scope (owner, 2026-11-27).**
- Uninstall *stages* the verified deletions. The adopter reviews the result and commits
  it with their own hooks and signing.
- Shared Git state under `<common>/agentic-flow/` is reported, with sizes and exact
  removal commands, but not deleted.
- The adopter runs `agentic-flow clean <plan>` for each open plan first. Uninstall never
  deletes worktrees, branches or salvage refs. The dry run names each blocking plan with
  its command.
- Automatic commit and automatic purge are follow-ups (see *Out of scope*).

## Current state

- **Installation record.** `.agentic-flow-installation` lists active scopes and one
  `file=<sha256>  <path>` row per installed path (`payload-apply.sh:228-247`). It hashes
  the destination *after* the apply, so it also records preserved edits, `kept` files and
  hand-merged contracts.
- **Upstream record (since 0.20.0).** `.agentic-flow-upstream` holds `accepted=` (the
  shipped source hash a path was last reconciled to) and `offered=` (the latest pending
  candidate) per path (`payload-apply.sh:417-477`). `payload_apply_entry` sets `accepted=`
  for `same`, `create` and `overwrite`. It leaves `accepted=` unchanged for `kept`, and
  `upgrade --merged` promotes `offered=` (`payload-apply.sh:489-510, 584-600`).
  - **Checked 2026-11-27:** a fresh export of `3757627` into an empty directory wrote 149
    `file=` rows and 149 `accepted=` rows. 148 matched. `docs/README.md` differs because
    export seeds the docs index after the apply (`export.sh:166-172`).
- **Nothing records who created a path.** `same` means the destination already held
  identical bytes. That can be an adopter file:
  - one that was untracked when export ran and was then committed together with the
    version stamp;
  - one the adopter added after adoption, at a path a later upgrade first ships.

  The five `docs/*/.gitkeep` payload files are empty, so any adopter `.gitkeep` at those
  paths matches. `--force` records `accepted=` over the file it replaced. Git history
  cannot settle this: the adoption commit's parent has no trace of an untracked file.
- **Candidates.** `payload_apply_candidate` writes `<path>.agentic-new`, then
  `.agentic-new.<version>`, then `.agentic-new.<version>.<12-hex>`
  (`payload-apply.sh:516-544`). Only the latest offer's hash survives, in `offered=`.
  Adopters edit candidates while merging, and most candidates are untracked.
  - **A byte-identical candidate is reused, not written.** The apply classifies it
    `pending` and still records `offered=` (`payload-apply.sh:519-525, 598`). `offered=`
    does not prove the harness wrote any candidate.
  - **A pending apply does not update the installation record.** Export and upgrade
    write `.agentic-flow-installation` only when nothing is pending, but they always write
    `.agentic-flow-upstream` (`export.sh:133, 170-172`, `scripts/agentic-flow:431, 447-449`).
  - `init.sh` also renders `Makefile.agentic-new` and `templates/ci/ci.yml.agentic-new`
    itself (`init.sh:304-309`), outside the payload library.
- **Older installs.** Installs before 0.20.0 have no `.agentic-flow-upstream` until their
  next upgrade. `.agentic-flow-version` stamps `<semver>+<short-sha>`
  (`payload-apply.sh:605-611`). `fetch_standard` clones `--depth 1 --branch <ref>`
  (`scripts/agentic-flow:161-171`), so it cannot reach a commit.
- **Locks.** All are `mkdir` directories under `<common>/agentic-flow/`:
  - `locks/controller-<plan>` publishes `owner.json` (`pid`, `start`, `host`) only *after*
    the `mkdir` succeeds (`controller.sh:68-110`), so it can exist without an owner;
  - `locks/<plan>` (handoff) records only a `pid` (`handoff.sh:346-365`);
  - `worktree-locks/<plan>` (`start`/`clean`) records only an `owner` PID
    (`start.sh:71-87`).
- **Lockless writers.** These also write under `<common>/agentic-flow/`, and a single
  check at dispatch does not cover their writes:
  - `verify-step` writes `verify/<sha>.json` at the end of its run
    (`verify-step.sh:255-262`);
  - `packet` writes `decisions/` and `findings/`;
  - `doctor --stations` writes `probe/`;
  - `budget.sh` writes `state/budget-overruns` from `make check`, outside the dispatcher.
- **Direct install writers.** `scripts/export.sh` and `scripts/init.sh` run from a
  scaffold checkout against the adopter's repository, outside its dispatcher.
  - `init.sh` runs `export.sh` as a *child* (`init.sh:233`). Afterwards it writes
    `.agentic-flow/config`, `core.hooksPath` (`init.sh:244`), the rendered `Makefile` and
    the stack stamps (`init.sh:299-309`).
  - `agentic-flow upgrade` goes through the dispatcher, but it `exec`s the fetched CLI
    (`payload-apply.sh:11-15`), which replaces the process image and its EXIT trap.
- **`git rm` refuses a path whose bytes differ from the index.** An upgrade that is not yet
  committed leaves a tracked file whose bytes match `accepted=` while its index entry and
  `HEAD` hold the previous release. `git rm` fails with "has local modifications".
  Checked in scratch on 2026-11-27.
- **`flock` on an inherited descriptor outlives the locking process.** When Bash opens a
  file on a descriptor and a child Perl process `flock`s it, the lock stays held after
  Perl exits. The kernel releases it when that descriptor closes or Bash dies. Checked in
  scratch on 2026-11-27. The harness already requires Perl.
- **Plan cleanup.** `clean` refuses a dirty worktree, a detached or mismatched branch, the
  base branch, and a branch that is not an ancestor of `origin/<base>`. It also refuses to
  run from inside the worktree it removes. It deletes the plan's salvage refs and records
  the plan closed (`start.sh:307-405`). It has a `--dry-run`.
- **Hook path.** `git_guard_enable` sets `core.hooksPath=scripts/git-hooks` in the
  repository-local config only when no scope sets it (`git-guards.sh:11-26`). It is called
  by `init.sh:244` and the guard migration (`guard-migration.sh:80`). ADOPTION tells
  adopters to set the same value by hand. Nothing records which of these happened.
- **Kept files reference harness files.** `init` fills in `CLAUDE.md`, `AGENTS.md`, the
  `Makefile` and `.agentic-flow-review-policy`, so these are almost never pristine and are
  kept. They still reference files uninstall removes:
  - the `Makefile` template's `check`, `test` and `test-one` recipes call
    `scripts/self-test.sh` and the `check-*.sh` scripts (`templates/harness/Makefile:19-39`);
  - the CI template calls `make check`, `scripts/doctor.sh` and `docs-index.sh`
    (`templates/ci/ci.yml:159-198`);
  - the contracts reference `METHODOLOGY.md`, `scripts/` and `agentic-flow`;
  - `.claude/settings.json` and `.codex/hooks.json` run `scripts/hooks/*.sh`.
- **Shared Git state** under `<common>/agentic-flow/`:
  - caches: `state`, `verify`, `gate`, `launches`, `probe`, `locks`, `worktree-locks`,
    `codex-home`;
  - records: `ledger`, `decisions`, `findings`, `plans`, and the `worktrees` root;
  - refs: `refs/agentic-flow/salvage/<plan>/…`.
- **Outside the repository.** Operator files live under
  `${XDG_CONFIG_HOME:-~/.config}/agentic-flow/`. The forge holds labels, issues, rulesets,
  any App, and the adopter's copy of `templates/ci/ci.yml`.
- **Stamps.**
  - Harness-owned: `.agentic-flow-version`, `-source`, `-source-applied`,
    `-candidate-version`, `-installation`, `-upstream`, `-scopes-excluded`,
    `-stack-candidate`, and the new `-ownership`.
  - Project-owned: `.agentic-flow-assurance`, `-assurance-audit`, `-roles`, `-stack`,
    `-review-policy`, `.agentic-flow/config`.
- **No `uninstall` exists.** The command policy has no row for it.

## Proposed approach

### Option A — install-time ownership evidence, fenced and resumable stage-only apply (recommended)

**Evidence is recorded when the harness writes** (f-1). A new `.agentic-flow-ownership`
record is written next to the upstream record on every apply, pending or not:
- `created=<sha>  <path>`: the harness wrote this path when it did not exist (`create`).
- `preexisting=<sha>  <path>`: the path existed and was not in the previous installation
  record when the harness first installed it (`same`, `overwrite`, `candidate`). The file
  is the adopter's for good.
- `inherited=<sha>  <path>`: the path was installed before ownership was recorded. Its
  origin is unknown.
- `candidate=<sha>  <candidate path>`: a candidate the harness *wrote*. A reused candidate
  never gets a row.

Rows carry forward while the path is an active manifest destination, or while the
candidate file exists. A row changes only when the harness re-creates a path the adopter
deleted, which makes it `created`.

**A payload file is removed only when all of these hold:**
- it has a `created` row, or an owner claim (f-5);
- it has an `accepted=` hash with no pending `offered=`;
- its current bytes match that hash;
- if tracked, its index entry and `HEAD` entry hold the same bytes *and the same Git
  mode*. The worktree's executable bit must also match that mode whenever
  `core.fileMode` is true. Otherwise `git rm` refuses even with equal blobs, as a scratch
  repository confirmed during review. With all of this, `git rm` cannot refuse, and the
  staged deletion removes exactly the verified bytes.

A tracked path whose bytes are pristine but whose mode disagrees anywhere is kept as
`mode-changed` and listed. A mode change is an adopter edit.

A created, pristine, tracked path whose index or `HEAD` differs is a harness write that
has not been committed yet. It is reported as `uncommitted-change`, and apply refuses with
`uncommitted-install` until the adopter commits or discards it. `preexisting`, `inherited`
and missing rows are kept.

The classifier walks the union of installation rows and ownership rows, so a path that a
pending upgrade created is still considered.

**A candidate is removed only when its bytes match its own `candidate` row.** Candidates
are discovered from `candidate` rows and by name next to every installed or owned path.
Legacy, reused, edited and unrecognized candidates are kept and listed. That includes
init's rendered ones.

**`core.hooksPath` is unset only when the harness can show it set the value.** f-1 makes
`git_guard_enable` record `agentic-flow.hooksPathSetBy=<init|migration>` in the same local
config when it sets the path. Uninstall unsets both values only when all of these hold:
- `git config --show-scope --get-all core.hooksPath` returns exactly one value,
  `scripts/git-hooks`, in `local` scope from the common dir's `config`;
- no `worktree` scope overrides it;
- the marker is present.

Anything else is kept and reported with the exact removal command.

**Kept files are listed, with what still references removed files.** After classifying,
uninstall scans every kept file and `.github/workflows/*` for references to removed paths
and to the `agentic-flow` CLI. It prints both lists. It never edits a kept file.

**Shared Git state is reported, not removed.** The report lists each directory under
`<common>/agentic-flow/` with its entry count, its size, and whether it is a cache or a
record. It also prints the exact `rm -rf` commands, and flags the ledger as the only copy
of the plan journal. Salvage refs that `clean` preserved are listed with their
`git update-ref -d` commands.

**Open plans block apply** (owner, 2026-11-27). Any plan record that is not `closed`, and
any linked worktree, refuses apply with `plan-open` or `linked-worktree`. The dry run
prints `agentic-flow clean <id>` for each, so `clean`'s own guards decide, and run its own
fetch, before uninstall starts. Uninstall therefore never calls `clean` and needs no
exemption from the fence.

**Writers register; uninstall fences** (f-3).
- **Writers register first.** Every process that may write under `<common>/agentic-flow/`,
  or to an adopter's tree as an installer, does this for its whole mutation window:
  1. Create `writers/<nonce>` holding `pid`, `start` and `host`.
  2. Check for the fence. If it exists, remove the registration and refuse.
  3. Work, then remove the registration when the process exits.

  **Every writing process registers itself.** A child never relies on its parent's
  registration, because it can outlive the parent. Who registers:
  - **The dispatcher,** for every subcommand except `uninstall`, `--help` and
    `--version`.
  - **The detached controller child,** before it acknowledges.
  - **`budget.sh`, and any hook that writes.**
  - **`export.sh` and `init.sh`,** each in the target's common dir, before its first write
    to the target. `init` and the `export` child it runs each hold their own registration.

  The only hand-over is **adopt on `exec`**. Upgrade's bridge replaces the process image
  under the same PID and passes `AGENTIC_FLOW_WRITER_REGISTRATION`. The new image adopts
  the registration only if its owner PID equals `$$`, and re-arms the EXIT trap. A child
  process cannot pass that check.

  A `make check` assertion enforces the inventory of registering writers.
- **Uninstall fences first.** It publishes the fence, then scans the registrations, the
  three lock roots and the linked worktrees. It refuses if anything is `live` or
  `unresolved`, and it removes only `stale-local` registrations, which hold no state. It
  never clears a lock.

Each side writes its own marker before reading the other's, so they cannot both proceed. A
writer that passed dispatch before the fence existed is still registered at its last write.

**One uninstall at a time, through a stable mutex** (f-3).
- `<common>/agentic-flow/uninstall.lock` is a stable, empty file. Uninstall creates it if
  absent and never deletes it; the shared-state report lists it.
- Every uninstall that may change the fence takes `flock(LOCK_EX|LOCK_NB)` on it, through
  a descriptor Bash keeps for the process's lifetime, so the re-exec into `bin/` keeps it.
  That covers apply, resume, and a run clearing an abandoned preparation. A busy lock
  refuses with `uninstall-busy`.
- Every fence transition happens while the mutex is held. Holding it proves that no other
  uninstall is alive on this host, so no generation protocol is needed. The fence's
  `nonce` names the artifacts directory.
- `flock` is not trusted across hosts. A fence whose `host` differs is refused with
  `fence-owner-unresolved`.

**The fence carries the phase that decides recovery** (f-3, f-4).
- `<common>/agentic-flow/uninstall.fence` is a small file holding `{v, nonce, phase, pid,
  start, host}`. It is first published by `link(2)` from a complete temp file, so it is
  never ownerless. Every later change is a rename over the path, under the mutex.
- The phases are:
  1. **`preparing`**: the run is writing `plan.json`, then `bin/` (staged as `bin.tmp/` and
     renamed), then `ready`, which holds the SHA-256 of `plan.json` and of the `bin/`
     manifest.
  2. **`applying`**: written only after `ready` validates, and before the first destructive
     action. **This is the only boundary that matters for recovery.**
  3. **`done`**: written after every action has completed or been kept.
- Recovery by phase:

  | Fence phase | Artifacts | What any `uninstall` invocation does (under the mutex) |
  |---|---|---|
  | `preparing` | anything | Apply never began. Delete the artifacts directory, unlink the fence, report "abandoned preparation cleared", continue |
  | `applying` | `ready` valid | Resume (below) |
  | `applying` | missing, or failing validation | **`recovery-damaged`**: refuse, preserve the fence and the artifacts, print the manual procedure. Nothing is deleted automatically |
  | `done` | anything | Finish cleanup only |
  | unreadable or malformed fence | — | `fence-owner-unresolved`: preserve everything and print the manual procedure |

  The manual procedure tells the adopter to:
  - inspect `git status` and `progress`, if it is readable;
  - restore staged deletions with `git restore --staged --worktree -- <paths>`, or finish
    them by hand;
  - move the fence and artifacts aside, with the exact `mv` commands.

**Apply stages from a persisted plan and can resume** (f-4).
- **Binding.** `plan.json` records the checkout: top-level path, absolute Git dir,
  `HEAD`'s symbolic ref (a detached `HEAD` is refused) and `HEAD`'s commit.
- **Preconditions.** Every planned action carries one. Files and config values are each
  rechecked immediately before the action.
  - Untracked files (candidates, stamps, records, project state, `.agentic-flow/config`)
    carry a SHA-256 and the regular-file type. An absent file counts as done.
  - Git config values (`core.hooksPath` and the marker) carry the exact value, scope and
    origin file. An absent value counts as done.
  - **Tracked files** carry the planned bytes and mode, `B/M`. These must also be the
    index entry and the `HEAD` entry, and the worktree's executable bit must match `M`
    when `core.fileMode` is true. Each state has one rule:

    | Worktree | Index entry | Action |
    |---|---|---|
    | present, `B/M` | `B/M` | `git rm -q --` (normal case) |
    | absent | `B/M` | **removed but not staged:** stage it with `git rm -q --`, which accepts an absent tracked file |
    | absent | none | done |
    | present (any bytes) | none | **keep the file**: `reappeared-after-staged-deletion`. It may have been recreated after the deletion was staged; an empty `.gitkeep` is the obvious case. Uninstall never `rm`s it. The staged deletion remains, and the report lists both fixes: `git restore --staged -- <path>` to keep it, or `rm -- <path>` to finish |
    | anything else | anything else | keep, `changed-during-uninstall` |

    Every row also requires the `HEAD` entry to be `B/M`; the binding already fixes
    `HEAD`. A different index entry never reaches this table, because the resume gate
    refuses any staged change that is not a planned deletion (`staged-changes`).
- **No network after preparation.** Nothing in apply or resume fetches: there is no
  `clean` call, and f-5's fetch happens only during classification. A resume therefore
  keeps `--no-fetch`'s promise without persisting the flag. The plan records `no_fetch`
  only for the report.
- **Progress.** `progress` is an append-only list of completed actions.
- **Order:**
  1. Remove payload files and candidates, using the tracked-file table for tracked paths
     and `rm` for untracked ones.
  2. Prune directories left empty.
  3. Remove project state if asked.
  4. Unset `core.hooksPath`, then the marker.
  5. Remove stamps and records.
  6. Set the fence phase to `done`.
  7. Cleanup: print the reports, unlink the fence, then remove the artifacts directory.

  Until the unlink, `bin/` and the resume command work. An interruption after the unlink
  leaves an inert directory, whose path is printed before the unlink.
- **The staged set is exactly the completed deletions.** The run never commits. The only
  index changes are the `git rm` calls of actions that ran after their precondition held.
  A file kept on resume was never `git rm`'d, so it stays tracked and unstaged.
- **A resume:**
  - takes the mutex;
  - reads the fence phase;
  - in `applying`, validates `ready`, checks the binding, and accepts only staged changes
    that are deletions in `plan.json`;
  - then, for each remaining action: if it is already done, it is recorded as done; if
    its precondition holds, it runs; if the precondition fails, the item is kept and
    reported as `changed-during-uninstall`;
  - in `done`, it only finishes cleanup and skips the binding check, because cleanup
    touches neither the tree nor the index.

  The resume command, printed before the first destructive action, is
  `<common>/agentic-flow/uninstall-<nonce>/bin/agentic-flow uninstall --resume`. While the
  fence exists, `scripts/agentic-flow uninstall --resume` execs the same copy.

### Option B — infer ownership from Git history

Draft 2's rule: the adoption commit's parent lacked the path. Rejected by review. It
deletes an adopter file that was untracked at export time and committed with the stamp,
and says nothing about paths a later upgrade first ships.

### Option C — managed-region markers in contracts

These would let uninstall strip only the harness's section from a hand-merged `CLAUDE.md`.
That needs a template format change and an upgrade migration. Deferred by owner decision
(2026-11-27). Until then, the kept list and the reference report tell the adopter exactly
which lines to edit.

**Recommendation:** Option A. A false "keep" costs the adopter one manual `rm`. A false
"remove" destroys their work. Every ambiguous case keeps the file, and the adopter commits
the result themselves.

## Interface (before the implementation)

```
.agentic-flow-ownership        (f-1; harness-owned record, same limits and path checks as
                               .agentic-flow-upstream; may never be a payload destination)
  version=1
  created=<sha256>  <path>
  preexisting=<sha256>  <path>
  inherited=<sha256>  <path>
  candidate=<sha256>  <candidate path>

git config --local agentic-flow.hooksPathSetBy init|migration      (f-1)

<common>/agentic-flow/writers/<nonce>      (f-3; directory, owner = {pid,start,host})
<common>/agentic-flow/uninstall.lock       (f-3; stable empty file; flock mutex)
<common>/agentic-flow/uninstall.fence      (f-3; {v,nonce,phase,pid,start,host};
                                            phase = preparing|applying|done)
<common>/agentic-flow/uninstall-<nonce>/   (f-4; plan.json, bin/, ready, progress)

writer_register <common> <label>  # own registration, then fence check; EXIT trap removes it
writer_adopt                      # exec'd image only (owner pid == $$): re-arm the trap
uninstall_mutex <common>          # non-blocking flock on a kept descriptor
uninstall_fence_publish|set_phase|release   # under the mutex only

agentic-flow uninstall [--yes] [--json] [--keep-docs] [--remove-project-state]
                       [--no-fetch] [--claim-adoption]
agentic-flow uninstall --resume [--json]

  default            dry run: classify, print, write nothing. It may clear an abandoned
                     `preparing` fence under the mutex. On a terminal, offer to apply.
  --yes              apply without prompting (required off a terminal)
  --json             emit the plan or the result as one JSON object
  --keep-docs        keep payload files under docs/ and the root METHODOLOGY.md / ADOPTION.md
  --remove-project-state   also remove the project-owned stamps and .agentic-flow/config
  --no-fetch         skip f-5's clone (claimed legacy paths stay); apply and resume never fetch
  --claim-adoption   f-5: treat legacy paths the adoption commit added as harness-created
  --resume           continue an interrupted apply

  Every run ends with three stdout sections:
    Kept — finish by hand:            <path>  (<why>)
    Still referencing removed files:  <file>:<line>: <removed path or command>
    Shared Git state (not removed):   <dir>  <entries>  <size>  cache|record
                                      rm -rf -- '<abs dir>'
  An apply then prints:
    Staged for your review: <n> deletions.  Inspect: git status
                                            Commit:  git commit
  When a kept Makefile or workflow references removed files, the report says first that
  `make check` or CI will fail after removal.

exit 0  dry run printed, or apply finished (deletions staged)
exit 2  usage
exit 3  refused before any destructive action (names every reason)
exit 4  apply stopped part-way; the fence and plan remain; the resume command is printed
```

Plan JSON (`plan.json` and `--json`; the text report renders the same object):

```
{ "v": 1, "nonce": "<hex>", "root": "<abs>", "version": "0.21.0+3757627",
  "binding": { "toplevel": "<abs>", "git_dir": "<abs>", "ref": "refs/heads/<name>", "head": "<sha>" },
  "adoption_commit": "<sha|null>",
  "refusals":  [ { "reason": "<reason>", "subject": "<plan|lock|path>", "detail": "<text>" } ],
  "payload":   [ { "path": "<rel>", "action": "remove|keep", "tracked": bool, "sha256": "<hex>",
                   "mode": "100644|100755|null", "index_blob": "<oid|null>", "head_blob": "<oid|null>",
                   "why": "pristine|edited|mode-changed|preexisting|inherited|no-ownership-record|
                           pending-offer|keep-docs|uncommitted-change|claimed|
                           changed-during-uninstall|reappeared-after-staged-deletion",
                   "provenance": "upstream|installed-revision|none" } ],
  "candidates":[ { "path": "<rel>", "action": "remove|keep", "tracked": bool, "sha256": "<hex>",
                   "why": "recorded|legacy|edited|unrecognized" } ],
  "stamps":    [ { "path": "<rel>", "owner": "harness|project", "action": "remove|keep",
                   "tracked": bool, "sha256": "<hex>" } ],     (.agentic-flow/config included)
  "plans":     [ { "id": "<id>", "status": "open|pending", "worktree": "<abs|null>",
                   "command": "agentic-flow clean <id>" } ],        (blocking plans only)
  "no_fetch":  bool,
  "locks":     [ { "path": "<rel>", "kind": "lock|registration",
                   "state": "live|stale-local|unresolved", "owner": "<text>" } ],
  "hooks":     { "values": [ { "scope": "<scope>", "origin": "<file>", "value": "<v>" } ],
                 "marker": { "value": "<init|migration>", "origin": "<file>" } | null,
                 "action": "unset|keep", "manual": "<command|null>",
                 "chained_scanner": [ "<hook file>" ] },
  "git_state": [ { "dir": "<rel>", "class": "cache|record", "entries": n, "bytes": n,
                   "command": "<rm -rf ...>" } ],
  "kept":      [ { "path": "<rel>", "why": "<reason>" } ],
  "dangling_references": [ { "file": "<rel>", "line": n, "ref": "<removed path|agentic-flow>" } ],
  "dangling_truncated": n,
  "outside":   [ "<checklist line>" ],
  "staged":    [ "<rel>" ] }                                 (apply result only)
```

Refusal reasons: `not-git-toplevel`, `linked-worktree`, `detached-head`, `staged-changes`,
`lock-present`, `writer-active`, `uninstall-busy`, `uninstall-in-progress`,
`fence-owner-unresolved`, `recovery-damaged`, `checkout-changed`, `plan-invalid`,
`plan-open`, `no-installation`, `uncommitted-install`.

## Threat model (one paragraph)

The untrusted actors are agent stations and anyone who can write files in the tree.
Uninstall deletes the secret scanner, the hook path and the command-policy deny rules, so
**an agent that can run it can drop the safety floor**. f-2 adds deny rows for every
spelling the policy already covers, including `--resume` and the `bin/` path. The human
runs it, as with `ship` and `hold clear`.

A planted ownership or upstream record can only cause deletion of a file whose bytes equal
a hash the attacker chose, and the attacker could already delete that file. Every record
path goes through `payload_safe_path`. Symlinks are never followed or deleted through.

The fence and its artifacts are in the Git common dir. Resume validates `ready`, the
plan's shape and paths, and the binding before acting. Damaged recovery data is never
cleaned up automatically. Uninstall never commits, so the adopter's own hooks and review
see the staged result.

**Residual risk.** An exporter or CLI from a source checkout older than f-3 does not
register, so the fence cannot exclude it. If such a process changes a planned file, the
item's precondition fails and the item is kept. Files it creates are never staged.
`ADOPTION.md` says not to run an older exporter during uninstall.

f-5 runs the installed revision's own `export.sh` into scratch, the same trust `upgrade`
already places in its source, and uses only the resulting hashes.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---------------|-----------|-----------------------|--------------------|
| Clone of `.agentic-flow-source` origin (f-5, classification only) | `AGENTIC_FLOW_FETCH_TIMEOUT` (120 s) → claimed paths kept | Short SHA missing or ambiguous → kept | n/a (scratch only) |
| Installed revision's `export.sh` (f-5) | 120 s → kept | Missing `file=` row or export failure → kept | n/a |
| Fence publication / preparation | — | — | Phase `preparing`: the next `uninstall` clears it under the mutex |
| Concurrent uninstall processes | — | — | The second fails the mutex: `uninstall-busy` |
| File removal, `git rm`, config unset | — | — | Exit 4; resume applies the tracked-file state table. A file present after its staged deletion is kept and reported, never `rm`'d |
| Artifact damaged after `applying` | — | `recovery-damaged`; fence and artifacts preserved | — |
| Final cleanup | — | — | Before the fence unlink: resume in `done` finishes. After: an inert artifacts directory, whose path was printed |

Bounds: the existing record limits (2,000 paths, 4,100-byte lines) apply to the ownership
record and to `plan.json`'s lists, and `plan.json` is capped at 2 MiB. The scan reads only
`writers/` and the three lock roots, at most 2,000 entries each. The shared-state report
runs `du`-style counts per top-level directory, stopping at 100,000 entries per directory
and reporting "≥". The reference scan reads kept payload files and `.github/workflows/*`,
skips files over 1 MiB and binary files, and reports at most 20 lines per file and 200 in
total, counting the overflow. One clone per run.

## Out of scope / What NOT to build in this pass

- **Committing** (owner, 2026-11-27). v1 stages. A follow-up may add a commit built from
  completed actions, if adopters ask for it.
- **Removing shared Git state** under `<common>/agentic-flow/`: caches, the ledger,
  decisions, findings, plan records and the mutex file (owner, 2026-11-27). They are
  reported with exact commands. Automatic purge is a backlog item.
- Removing anything outside the repository. Outside items are printed only.
- Editing any kept file: custom hooks, settings, contracts, the `Makefile`, CI workflows.
- **Running `clean`** (owner, 2026-11-27). The adopter runs it for each plan the dry run
  names.
- Clearing any lock, or an override for plan guards, the fence or `recovery-damaged`.
- `--abort`. Staged deletions restore with `git restore --staged --worktree`.
- Managed-region markers (Option C), and monorepo installs whose harness root is not the
  Git top level (refused).
- Pushing, and any forge call.

## Open questions

- [x] **Uninstall acceptance:** remove only paths with install-time ownership evidence and
  pristine provenance, with the no-override plan guards and the fence. *Decided 2026-11-27
  by the owner: yes.*
- [x] **Legacy ownership.** *Decided 2026-11-27 by the owner: keep f-5.* Installs made
  before f-1 have no ownership record, so their files are `inherited`.
  `--claim-adoption` is an explicit owner assertion:
  - it applies only to `inherited` or unrecorded paths that the adoption commit added;
  - it still requires pristine bytes, and it lists each path before the prompt;
  - it never applies to `preexisting` rows.
- [x] **Commit.** *Decided 2026-11-27 by the owner: stage-only in v1.*
- [x] **Shared Git state.** *Decided 2026-11-27 by the owner: report only in v1.*
- [x] **Plan cleanup.** *Decided 2026-11-27 by the owner: the adopter runs `clean` first.
  Apply refuses with `plan-open`.*
- **Project-owned state default.** Keep it unless `--remove-project-state` is given?
  *Recommended: yes.*

## Revision history

Kept in Part A so that it does not count against Part B's word cap.

- **Draft 8 (2026-11-27)** answers the sixth review:
  1. A file present after its deletion was staged is kept as
     `reappeared-after-staged-deletion`, and the report gives both fixes. Uninstall never
     `rm`s it (scenario 7h).
  2. Removal eligibility includes the Git mode of the worktree, the index and `HEAD`. A
     mode-only edit is kept as `mode-changed` before apply, and as
     `changed-during-uninstall` on resume (scenario 7j).
  3. Scenario 7h's staged-edit case now expects the resume gate to refuse with
     `staged-changes` and leave the index and worktree unchanged.
- **Draft 7 (2026-11-27)** answers the fifth review:
  1. Borrowing is removed. Every writing process registers itself, so `init` and its
     `export` child each hold their own. Only `exec` adopts (scenario 6).
  2. The tracked-file precondition table covers both half-done states: removed but not
     staged, and staged but not removed (scenario 7h).
  3. By owner decision, the adopter runs `clean` first, and apply refuses with
     `plan-open`. This drops the fence exemption and plan recovery. Apply and resume make
     no network calls, so `--no-fetch` holds across resume (scenario 7i).
- **Draft 6 (2026-11-27)** answers the fourth review, and narrows v1 by owner decision:
  1. Stage-only apply. The private index, `commit-tree`, the ref compare-and-swap, signing
     and trailer recovery are gone. The staged set is exactly the completed deletions, so
     a file kept on resume is never deleted (scenario 7f).
  2. `init` owns its registration until it exits, and the export child borrows it.
     `exec` adopts (scenario 6).
  3. The fence carries a phase. Automatic cleanup happens only in `preparing`. In
     `applying` with damaged artifacts, uninstall refuses with `recovery-damaged` and
     preserves everything (scenario 7g).
  4. A stable mutex file is held across fence transitions. The inode retries and the
     generation protocol are gone.
  5. Shared Git state is reported with sizes and commands. Directory hashing, `trash/`
     and `--purge-ledger` are gone.
- **Draft 5:** kernel mutex, persisted completion, fenced `export.sh`/`init.sh`,
  constrained commit, refusal on uncommitted harness writes.
- **Draft 4:** writers register for their whole mutation window; recoverable preparation;
  checkout binding; legacy candidates kept; candidates discovered from ownership rows;
  removal preconditions.
- **Draft 3:** install-time ownership record; persisted, resumable plan; a fence against
  locks; candidate evidence; hook-path ownership. Draft 2's rule became Option B.
- **Draft 2:** kept pre-adoption paths; stdout kept list and reference scan.
- **Draft 1:** first draft.

---

# Part B — Implementation Brief

## Acceptance scenarios

1. **Untracked identical file at adoption.** An adopter `docs/done/.gitkeep` was untracked
   when export ran, and was committed with the version stamp. It stays as `preexisting`,
   with or without `--claim-adoption`.
2. **Upgrade meets an adopter file.** An adopter file added after adoption sits at a path
   that a later upgrade first ships with identical bytes. It stays as `preexisting`.
3. **Candidates.**
   - An untracked candidate the adopter edited stays as `edited`.
   - An unedited candidate the harness wrote is removed.
   - An adopter-supplied candidate that the apply reused stays as `legacy`, although its
     bytes match `offered=`.
   - A pending upgrade writes a candidate for a new path without updating the installation
     record. The candidate is found through its `candidate` row and removed.
4. **Hook path ownership.**
   - A global `core.hooksPath=scripts/git-hooks` stays and is reported.
   - A local value with no marker stays and is reported with the exact unset command.
   - A value that `init` set (marker present) is unset, together with the marker.
5. **Open plan.** An open plan record with a worktree:
   - the dry run lists it with `agentic-flow clean <id>`;
   - `--yes` exits 3 with `plan-open`, and the tree, Git config, refs and common-dir state
     are unchanged;
   - after the adopter runs `clean`, apply proceeds;
   - a plan `clean` refuses (unmerged, dirty) stays blocking, and uninstall offers no
     override.
6. **Racing writers.**
   - A controller that takes its lock between preflight and fence, and a `verify-step`
     paused after dispatch and before its write: either the writer refuses, or uninstall
     refuses with `writer-active` or `lock-present`. Nothing is deleted, and the record is
     written intact.
   - A writer that starts after the fence exists refuses and writes nothing.
   - `export.sh` run from a separate scaffold checkout after the fence exists refuses
     before its first write.
   - `init.sh` paused immediately after its export child returns, and before it writes the
     config or the hook path: uninstall refuses with `writer-active`.
   - **Parent killed:** `init.sh` is killed (`kill -9`) while its export child is paused
     before a write. Uninstall clears `init`'s `stale-local` registration, but refuses
     with `writer-active` on the export's own live registration. Releasing the export
     then lets its write complete.
   - Upgrade's bridged `exec` keeps exactly one registration.
   - A lock with no `owner.json`, or another host's owner, is `unresolved` and preserved.
     A `stale-local` registration is cleared.
7. **Interrupted apply.** Interrupt after the first tracked deletion, after
   `scripts/agentic-flow` is removed, and midway through stamp removal. Each time, a fresh
   `uninstall` refuses with `uninstall-in-progress` and prints the resume command, and
   `--resume` from `bin/` finishes. The final tree and index equal an uninterrupted run's.
7a. **Abandoned preparation.** Kill the run immediately after the fence is published, with
    `bin.tmp/` partly written, and before `applying`. Other commands refuse and name the
    fence. The original `scripts/agentic-flow uninstall` clears it and prints the same dry
    run. Tree, index, Git config and refs are unchanged.
7b. **Branch switch.** Interrupt after the first tracked deletion. Restore the index, then
    check out a branch with identical payload bytes. `--resume` refuses with
    `checkout-changed`, and that branch's index is unchanged.
7c. **Precondition changed.** Interrupt a `--remove-project-state` apply, then edit
    `.agentic-flow/config`. `--resume` keeps it as `changed-during-uninstall` and finishes
    everything else.
7d. **Concurrency.** Two clears of one abandoned preparation, and two resumes of one
    interrupted apply. Exactly one proceeds each time; the other gets `uninstall-busy`. A
    fence from another host is `fence-owner-unresolved`.
7e. **Interrupted cleanup.** Interrupt after `done` and before the fence unlink:
    `--resume` from `bin/` finishes, and the staged set is unchanged, even if the adopter
    committed in between. Interrupt after the unlink: no command refuses, and the printed
    artifacts path is the only leftover.
7f. **File changes between runs.** Interrupt after the first tracked deletion, then edit a
    planned tracked file that has not been removed yet. After `--resume`, that file is
    still tracked, unstaged and edited. `git diff --cached --name-status` lists only `D`
    rows for completed deletions.
7g. **Damaged recovery data.** Interrupt after the first tracked deletion, then corrupt
    `plan.json`. `uninstall` and `--resume` refuse with `recovery-damaged`, the fence and
    artifacts remain byte-identical, other commands keep refusing, and the printed
    procedure names the staged deletions.
7h. **Half-done tracked removal.** Three cases:
    - **Removed but not staged:** after a completed deletion, a test deletes the next
      planned tracked file with plain `rm`, leaving its index entry. `--resume` verifies
      the index and `HEAD` entries, including the mode, and stages the deletion.
    - **Staged edit:** same, but the test first stages other bytes for that path.
      `--resume` refuses with `staged-changes` before any per-file check, and the index
      and worktree are byte-identical before and after.
    - **Recreated after a staged deletion:** interrupt after a planned `.gitkeep`'s
      deletion is staged, then recreate it with identical (empty) bytes. `--resume` keeps
      the file as `reappeared-after-staged-deletion`, leaves the staged deletion, and
      prints both fixes. The file still exists afterwards.

    In every case `git diff --cached --name-status` lists only `D` rows for planned paths.
7j. **Mode-only edit**, with `core.fileMode=true`:
    - before the dry run, `chmod +x` a pristine, created, tracked, non-executable payload
      file: it is kept as `mode-changed`, and apply never runs `git rm` on it;
    - after an interruption, `chmod +x` a planned file that has not been removed yet:
      `--resume` keeps it as `changed-during-uninstall`.

    In both cases no `git rm` fails, and the run exits 0.
7i. **No network on resume.** Interrupt a `--no-fetch` apply, then put a `git` shim on
    `PATH` that fails the test on any `fetch`, `clone` or `ls-remote`. `--resume`
    completes without invoking it.
8. **Pristine created file.** A `created` file byte-identical to `accepted=` is removed. An
   edited `created` file and a hand-merged `CLAUDE.md` stay.
9. **Install → uninstall.** Export into an empty Git repository and commit, then run
   `uninstall --yes`. Every pristine created file and harness stamp is gone, and its
   deletion is staged. After `git commit`, the tree matches the pre-export commit apart
   from `docs/README.md` and the kept project state.
10. **Legacy claim.** A fixture with no ownership or upstream record, whose source ref has
    moved past the installed commit. `--claim-adoption` removes only files that the
    adoption commit added *and* that match the installed revision. With `--no-fetch`, an
    unreachable commit or a stampless version, all stay.
11. **Kept list.** A kept `Makefile` that calls `scripts/self-test.sh`, and a
    `.github/workflows/ci.yml` that calls `scripts/doctor.sh`. Both are listed with line
    numbers, the report warns that `make check` and CI will fail, and neither file changes.
    The shared-state section lists `ledger` as a record, with its `rm -rf` command.
12. **Policy.** `agentic-flow uninstall` is blocked for agents in all three runtimes.
13. **Uncommitted upgrade.** After an uncommitted upgrade of tracked, created, pristine
    files, the dry run lists them as `uncommitted-change`, and `--yes` refuses with
    `uncommitted-install`. Once the adopter commits, `uninstall --yes` stages their
    deletion.

## Invariants

- A dry run writes nothing. The only exception is clearing a `preparing` fence under the
  mutex.
- The fence is never ownerless. Nothing destructive happens before phase `applying`.
  Automatic cleanup of artifacts happens only in `preparing` or after `done`.
- Exactly one uninstall process at a time per common dir, enforced by the mutex.
- Every writing process holds its own registration from before its first write until it
  exits. Only an `exec`'d image of the same PID adopts one.
- Uninstall never runs `clean` and never deletes worktrees, branches or refs. Apply and
  resume make no network calls.
- A file is removed only with ownership evidence and when its precondition holds at the
  moment of removal.
- The index changes only through `git rm` of completed removals. Uninstall never commits.
- A resume acts only on a valid `plan.json` in the bound checkout, never reclassifies, and
  accepts only its own staged deletions.
- No lock is cleared, and nothing overrides `plan-open`, the fence, the scan or
  `recovery-damaged`.
- Every path that stays, and every shared-state directory, is printed. No kept file is
  modified.
- The running CLI never reads a file that the run has deleted. Bash 3.2; no new required
  tool.

```agentic-flow-plan
format: 2
id: uninstall
profile: strict
tracking: Plan: Uninstall — remove only what the harness owns
branch: configurability-phase-3
steps: f-1 f-2 f-3 f-4 f-5
policy: review.max_bounces=2 review.block_at=medium andon.station-infrastructure=hold
```

## Branch
Base: `main`. One branch and one PR for the whole brief: `configurability-phase-3`. Each
step lands as its own commit on that branch and closes its issue with `Fixes #N`.

## Definition of done (whole brief)
- Every step's DoD is met, and `make check` and `make test` are green.
- Scenarios 1–13, with 7a–7j, are covered by named tests.
- `ADOPTION.md` has a *Removing the harness* section, covering `clean` first, the
  review-and-commit step, the shared-state commands and the residual risk.
- `CHANGELOG.md` has an entry.
- A manual run in a scratch export shows the dry run, then `--yes`, then a `git status`
  that shows only staged deletions.

## Verification commands
```bash
make check                                  # per step
make test-one F=upgrade                     # uninstall tests, timed as upgrade:uninstall
make test-one F=export                      # f-1 rows; f-3 installer registration
make test-one F=hooks                       # f-2: command-policy rows
make test-one F=controller S=launch         # f-3: controller lock and registration
make test-one F=stations S=handoff          # f-3: handoff, start and clean under the fence
make test                                   # end of brief
```

---

## F-1 — Record ownership evidence when the harness writes a path
**Why first:** every later step reads this evidence, and it changes the install records,
which is the hardest part to reverse.

**Approach:**
- In `payload-apply.sh`, load, carry forward and write `.agentic-flow-ownership` alongside
  the upstream record, on every apply, pending or not. Reuse the upstream parser's limits
  and its NUL, UTF-8 and path checks. Reject unknown keys, and write atomically.
- Classify each path from the apply result and the *previous* installation record:
  - `create` → `created`;
  - otherwise, a path in the previous record with no row → `inherited`;
  - otherwise → `preexisting`.
- Write a `candidate` row only when the harness writes a candidate
  (`PAYLOAD_RESULT_CANDIDATE_ACTION=candidate`). A reused candidate keeps its existing row
  or none. `upgrade --merged` drops the rows of the candidates it removes.
- Forbid the record as a payload destination.
- `git_guard_enable` takes a source label and writes `agentic-flow.hooksPathSetBy` only
  when it actually set `core.hooksPath`.

**Test:** scenarios 1, 2 and 3 (reused, pending upgrade) as records, plus:
- `export --force` over an existing file → `preexisting`;
- an upgrade from a record-less install → all `inherited`;
- a created file the adopter deleted and the harness re-created → `created`;
- a malformed record → refused before any write;
- `init` sets the marker only when the hook path was unset.

**DoD:** every export and upgrade leaves a complete ownership record, and `init` leaves
the marker only when it set the hook path.
**Verify:** `make test-one F=export && make test-one F=upgrade`
**Risks:**
- Releases that write the record must still read older installs without it.
- Fixture counts change; measure them and update `config/test-budgets.tsv`.
**Red-first:** none
**Commit:** `Record which payload paths the harness created`

---

## F-2 — Classify ownership and report the removal as a dry run
**Why second:** it turns f-1's evidence into the plan f-4 executes. It is read-only, so
adopters can see the result before anything can delete.

**Approach:**
- Add a dispatcher entry `uninstall` and `scripts/lib/uninstall.sh`. The library sources
  `payload-apply.sh` itself (memory: `library-sources-its-dependencies`).
- `find_root` must equal the Git top level. Uninstall must run in the main worktree, with
  `HEAD` on a branch.
- Classify payload paths (the union of installation and ownership rows), candidates,
  stamps and the hook path by the Part A rules.
  - For tracked paths, compare the worktree hash, the index blob and the `HEAD` blob, and
    the Git mode of all three. The worktree's executable bit counts only when
    `core.fileMode` is true.
  - Record every precondition `plan.json` needs.
  - Anything else matching `.agentic-new*` is `unrecognized`.
- Plans: list every plan record under `<common>/agentic-flow/plans/` that is not
  `closed`, and every linked worktree, each with its `agentic-flow clean <id>` command.
  Their presence refuses apply. Uninstall reads plan records directly and calls no
  `clean` code.
- Report locks and registrations in their three states.
- Build the kept list and the reference scan. Match removed paths, removed directories as
  `<dir>/` prefixes, and `agentic-flow` as a command, within the bounds.
- Build the shared-state report: class, bounded counts, and quoted `rm -rf` commands.
- Text and `--json` render one object. Exit 0, or 3 with refusals.
- Add the command-policy deny rows ("the human uninstalls"), regenerate the native rules,
  and update `docs/reference/command-policy-coverage.md`.
- Add `upgrade:uninstall` to the wall-ceiling keys.

**Test:** scenarios 1–4, 8, 11, 13 (dry-run half) and 7j (first case) as classifications,
5, and 12. Also:
`linked-worktree`, `detached-head`, `no-installation`, a symlinked payload path,
reference-scan truncation, and `--json` validating against the shape.

**DoD:** `agentic-flow uninstall` prints a correct plan and writes nothing. Agents cannot
run it.
**Verify:** `make test-one F=upgrade && make test-one F=hooks`
**Risks:**
- The plan record format is owned by `start.sh`. Parse it with the same reader, through
  a read-only helper, rather than a second parser.
**Red-first:** `upgrade:uninstall` — scripts/tests/upgrade.sh scripts/self-test.sh
**Commit:** `Add a dry-run uninstall that classifies what the harness owns`

---

## F-3 — Fence uninstall against every shared-state writer
**Why third:** apply must not start until every writer either sees the fence or is seen by
uninstall, for its whole mutation window. Only one uninstall may change the fence.

**Approach:**
- Add `scripts/lib/fence.sh`, a payload file, with the *Interface* functions. It sources
  its own dependencies. `export.sh` and `init.sh` source the scaffold's copy.
- **Registration:**
  1. `writer_register` creates `writers/<nonce>`, writes `owner` atomically, checks for
     the fence (removing the registration and refusing with `uninstall in progress` if it
     exists), then chains an EXIT trap that removes the registration.
  2. `writer_adopt` requires the inherited registration's owner PID to equal `$$`, which
     is true only after `exec`, then re-arms the trap. It fails in any other process.
- **Call sites:**
  - the dispatcher, for every subcommand except `uninstall`, `--help` and `--version`;
  - the detached controller child, before it acknowledges;
  - `budget.sh`, and any hook that writes;
  - `export.sh` and `init.sh`, each in the target's common dir, before its first target
    write. Each registers independently, including when `init` runs `export`;
  - upgrade's bridge, which exports the variable so the `exec`'d image adopts.
- A `make check` assertion checks the inventory: every file that writes under the common
  dir's `agentic-flow/` is dispatcher-reached or registers. Use an explicit allowlist
  file.
- Keep post-lock fence checks in `controller_lock` (both paths), the handoff lock and
  `plan_worktree_lock`, as defense in depth. They have no exemption: uninstall never runs
  `clean`.
- **Mutex:** `uninstall_mutex` opens the stable `uninstall.lock` on a fixed low descriptor
  and takes a non-blocking `flock` through a short Perl call. A busy lock refuses with
  `uninstall-busy`.
- **Fence:**
  - `uninstall_fence_publish` publishes with `link(2)` (`phase=preparing`).
  - `uninstall_fence_set_phase` renames over the fence. `uninstall_fence_release` unlinks
    it. Both run under the mutex only.
  - After publishing: scan `writers/`, the lock roots and the linked worktrees, and clear
    `stale-local` registrations only. If anything is live or unresolved, release the fence
    and refuse.
  - Resolve an existing fence by its phase, using the Part A table.

**Test:** scenarios 6 and 7d, with test-only pause points (`AGENTIC_UNINSTALL_TESTING=1`
plus a named pause). Pause `verify-step` and `export.sh` after registering, and `init.sh`
right after its export child returns. Kill only `init.sh` while its export is paused.
Also:
- the mutex survives the re-exec, and is free after `kill -9` of its holder;
- `start`, `handoff` and `verify-step` refuse under the fence and write nothing;
- `writer_adopt` fails in a child process;
- a `kill -9`ed writer's registration is `stale-local` and cleared;
- the inventory assertion fails on a planted unregistered writer.

**DoD:** while any covered writer is inside its mutation window, uninstall cannot pass its
scan. Under the fence, no covered writer can start. Two uninstalls never run together.
**Verify:** `make test-one F=controller S=launch && make test-one F=stations S=handoff && make test-one F=export && make test-one F=upgrade`
**Risks:**
- A long controller run keeps its registration and blocks uninstall. That is intended.
- Registering on every CLI call adds a `mkdir` and a check. Measure them against the
  stations and controller ceilings.
- EXIT-trap chaining must not replace the existing traps in `handoff.sh`, `start.sh` and
  `controller.sh`. The mutex descriptor must not be opened close-on-exec.
**Red-first:** none
**Commit:** `Fence uninstall against every shared-state writer`

---

## F-4 — Stage the removal from a persisted plan that a retry can resume
**Why fourth:** it needs f-2's plan and f-3's mutex and fence.

**Approach:**
- `--yes`, or a `y` at the terminal prompt:
  1. Takes the mutex and publishes the fence.
  2. Recomputes the plan, and refuses if anything differs from what was shown.
  3. Refuses on any `uncommitted-change`, staged change, open plan or linked worktree.
- **Preparation**, in phase `preparing`:
  1. Write `plan.json` with the binding and the preconditions.
  2. Stage `bin.tmp/` and rename it to `bin/`.
  3. Sync, then write `ready`.
  4. Set the phase to `applying`, print the resume command, and re-exec from `bin/`.
- **Apply** in the Part A order. Check each action's precondition immediately before it,
  and append each completed action to `progress`.
- Set the phase to `done`, then clean up: print the reports and the staged summary,
  unlink the fence, and remove the artifacts directory.
- **`--resume`** follows the Part A phase table. While the fence exists,
  `scripts/agentic-flow uninstall` prints the resume command, or with `--resume` execs
  `bin/`.
- On any failure, stop with exit 4 and print the resume command.

**Test:** scenarios 3, 4 (unset), 5 (apply half), 7, 7a, 7b, 7c, 7e, 7f, 7g, 7h, 7i, 7j,
8, 9 and 13. Use a test-only fault point (`AGENTIC_UNINSTALL_TESTING=1` plus a named action),
including the point after a completed deletion. Also:
- a resume that finds a staged change outside the plan refuses;
- an interactive "no" writes nothing.

**DoD:**
- Every interruption resumes to the same final tree and index as an uninterrupted run.
- Abandoned preparations clear automatically; damaged recovery data never does.
- The index only ever gains the completed deletions.
**Verify:** `make test-one F=upgrade`
**Risks:**
- Never use `git rm --ignore-unmatch` as a shortcut. Every tracked path goes through the
  state table, so a missing index entry is a decision, not a silent skip.
- Never `rm` a tracked path whose index entry is already gone. A present file there is the
  adopter's to decide.
- The `done` cleanup must not need the binding: the adopter may commit before a resume.
**Red-first:** `upgrade:uninstall` — scripts/tests/upgrade.sh scripts/self-test.sh
**Commit:** `Stage uninstall from a persisted plan that a retry can resume`

---

## F-5 — Let the owner claim legacy paths, proven against the installed revision
**Why last:** it only turns some legacy keeps into removals, behind an explicit owner
assertion (owner decision, 2026-11-27).

**Approach:**
- `--claim-adoption` covers paths that are `inherited` or have no row, never
  `preexisting`, and only those the adoption commit added. That commit is the oldest one
  adding `.agentic-flow-version`; without one, nothing is claimed.
- When `accepted=` exists, compare against it.
- Otherwise, take the commit from `.agentic-flow-version`'s `+<sha>`, never
  `.agentic-flow-source`'s `ref`:
  - unless `--no-fetch` is given, clone the origin once (`--filter=blob:none
    --no-checkout`, under `run_with_timeout`) and resolve `<sha>^{commit}`;
  - run that revision's own `export.sh` into empty scratch, with
    `.agentic-flow-scopes-excluded`, and use its `file=` hashes.
- Claimed paths show `why=claimed` with their provenance, and the prompt lists them.

**Test:** scenario 10, plus scenario 1 with `--claim-adoption`, plus an export failure at
the installed revision, which keeps everything.

**DoD:** a legacy fixture loses exactly the claimed files that match their proven
revision, and the report names that revision.
**Verify:** `make test-one F=upgrade`
**Risks:**
- Old exporters may lack `--exclude-scope` or write an older installation format. Any
  parse failure means keep.
- Use `file://` origins in tests.
**Red-first:** none
**Commit:** `Let the owner claim legacy paths proven by the installed revision`

---

## Status / Implementation status
<!-- Finalized by the closer before the last repository commit. -->
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
