<!-- TRIAGE (first pass · 2026-11-27) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict (deletes adopter files, changes the install records, the controller lock and the hook setup, and adds a command-policy floor row; project baseline is Standard)
> Phase 3 of [harness configurability](product-harness-configurability.md) (area J): `agentic-flow uninstall`, which removes only what the harness has recorded evidence of creating, runs behind a fence that excludes controllers and plan operations, and can resume after an interruption. Kept files are listed on stdout.
> Draft 5 (2026-11-27), written against `0.21.0` (`3757627`). It answers the third review: a kernel mutex serializes fence changes, recovery stays available until the fence is released, direct `export.sh`/`init.sh` runs are fenced, the commit holds only verified deletions, and uncommitted harness writes refuse instead of failing in `git rm`. See *Revision history*. The owner settled *Uninstall acceptance* and *Legacy ownership* (keep f-5) on 2026-11-27. Next: the reviewer's second round on draft 3, then owner approval. The project-state and commit defaults are settled at approval.

# Feature — Uninstall: remove only what the harness owns

## Tracker
- [ ] f-1 — Record ownership evidence when the harness writes a path — open
- [ ] f-2 — Classify ownership and report the removal as a dry run — open
- [ ] f-3 — Fence uninstall against every shared-state writer — open
- [ ] f-4 — Apply the removal from a persisted plan that a retry can resume — open
- [ ] f-5 — Let the owner claim legacy paths, proven against the installed revision — open

---

# Part A — Analysis

## Goal

An adopter who stops using the harness needs a clean way out. Today the only way is to
delete files by hand. That loses either way: it leaves stamps, a `core.hooksPath` that
points at a deleted directory, and Git state under the common dir, or it deletes files the
adopter changed.

The owner's goal 8 (2026-11-25) asks for a script that removes the harness cleanly. The
product analysis (area J) settled what "cleanly" means. Remove only what the harness can
prove it owns. Never override a plan guard. Print everything outside the repository, and
everything kept, as a checklist instead of touching it.

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
  cannot settle this: the adoption commit's parent has no trace of an untracked file. The
  reviewer confirmed that in a scratch repository.
- **Candidates.** `payload_apply_candidate` writes `<path>.agentic-new`, then
  `.agentic-new.<version>`, then `.agentic-new.<version>.<12-hex>`
  (`payload-apply.sh:516-544`). Only the latest offer's hash survives, in `offered=`.
  Adopters edit candidates while merging, and most candidates are untracked, so `rm`
  loses those edits.
  - **A byte-identical existing candidate is reused, not written.** When the adopter
    already has a `.agentic-new*` file with the source bytes, the apply classifies it
    `pending` and still records `offered=` (`payload-apply.sh:519-525, 598`). `offered=`
    therefore does not prove the harness wrote any candidate.
  - **A pending upgrade does not update the installation record.** Export and upgrade
    write `.agentic-flow-installation` only when nothing is pending, but they always write
    `.agentic-flow-upstream` (`export.sh:133, 170-172`, `scripts/agentic-flow:431, 447-449`).
    Paths an upgrade creates, and candidates it writes for new paths, can be missing from
    the installation record.
- **Older installs.** Installs before 0.20.0 have no `.agentic-flow-upstream` until their
  next upgrade. `.agentic-flow-version` stamps `<semver>+<short-sha>`
  (`payload-apply.sh:605-611`). `fetch_standard` clones `--depth 1 --branch <ref>`
  (`scripts/agentic-flow:161-171`), so it cannot reach a commit.
- **Locks.** All are `mkdir` directories under `<common>/agentic-flow/`:
  - `locks/controller-<plan>` publishes `owner.json` (`pid`, `start`, `host`) only *after*
    the `mkdir` succeeds (`controller.sh:68-110`). A lock can therefore exist without an
    owner. A different `host` cannot be checked locally without `--take-over`.
  - `locks/<plan>` (handoff) records only a `pid` (`handoff.sh:346-365`).
  - `worktree-locks/<plan>` (`start`/`clean`) records only an `owner` PID
    (`start.sh:71-87`).

  Nothing stops a controller, `start` or `handoff` from beginning after a preflight check.
- **Lockless writers.** Other code also writes under `<common>/agentic-flow/`:
  - `verify-step` writes `verify/<sha>.json` at the end of its run without a lock
    (`verify-step.sh:255-262`);
  - `packet` writes `decisions/` and `findings/`;
  - `doctor --stations` writes `probe/`;
  - `ledger.sh` and `andon.sh` write state caches;
  - `budget.sh` writes `state/budget-overruns`. It runs from `make check`, outside the
    dispatcher.

  A check made once at dispatch does not cover their writes.
- **Direct install writers.** `scripts/export.sh` and `scripts/init.sh` are source-only.
  They run from a scaffold checkout and target the adopter's repository from outside it.
  - They write the target's tree, its install records and its stamps.
  - `init.sh` also writes `core.hooksPath` (`init.sh:244`).
  - Neither goes through the target's dispatcher.

  `agentic-flow upgrade` goes through the dispatcher, but it `exec`s the fetched CLI
  (`payload-apply.sh:11-15`), which replaces the process image and its EXIT trap.
- **`git rm` refuses a path whose bytes differ from the index.** A successful upgrade that
  is not yet committed leaves a tracked file whose bytes match `accepted=`. Its index
  entry and `HEAD` still hold the previous release. `git rm` then fails with "has local
  modifications". This was checked in scratch on 2026-11-27.
- **`flock` on an inherited descriptor outlives the locking process.** When Bash opens a
  file on a descriptor and a child Perl process `flock`s it, the lock stays held after
  Perl exits. The kernel releases it when that descriptor closes or the Bash process dies.
  This was checked in scratch on 2026-11-27, and the harness already requires Perl.
- **Plan cleanup.** `clean` refuses a dirty worktree, a detached or mismatched branch, the
  base branch, and a branch that is not an ancestor of `origin/<base>`. It also refuses to
  run from inside the worktree it removes. It deletes the plan's salvage refs and records
  the plan closed (`start.sh:307-405`). It has a `--dry-run` that writes nothing.
- **Hook path.** `git_guard_enable` sets `core.hooksPath=scripts/git-hooks` in the
  repository-local config only when no scope sets it (`git-guards.sh:11-26`). It is called
  by `init.sh:244` and the guard migration (`guard-migration.sh:80`). ADOPTION tells
  adopters to set the same value by hand. A matching value can also come from global or
  worktree config. Today nothing records which of these happened.
- **Kept files reference harness files.** `init` fills in `CLAUDE.md`, `AGENTS.md`, the
  `Makefile` and `.agentic-flow-review-policy`, so these are almost never pristine and are
  kept. They still reference files uninstall removes:
  - the `Makefile` template's `check`, `test` and `test-one` recipes call
    `scripts/self-test.sh`, `shell-inventory.sh` and the `check-*.sh` scripts
    (`templates/harness/Makefile:19-39`);
  - the CI template runs `make check` and calls `scripts/doctor.sh`, `docs-index.sh` and
    `check-memory-index.sh` (`templates/ci/ci.yml:159-198`);
  - the contracts reference `METHODOLOGY.md`, `scripts/` and `agentic-flow`;
  - `.claude/settings.json` and `.codex/hooks.json` run `scripts/hooks/*.sh`.
- **Shared Git state** under `<common>/agentic-flow/`:
  - caches: `state`, `verify`, `gate`, `launches`, `probe`, `locks`, `worktree-locks`,
    `codex-home`;
  - records: `ledger`, `decisions`, `findings`, `plans`, plus the `worktrees` root;
  - refs: `refs/agentic-flow/salvage/<plan>/…`.
- **Outside the repository.** Operator files live under
  `${XDG_CONFIG_HOME:-~/.config}/agentic-flow/`. The forge holds labels, issues, rulesets,
  any App, and the adopter's copy of `templates/ci/ci.yml`.
- **Stamps.** Harness-owned: `.agentic-flow-version`, `-source`, `-source-applied`,
  `-candidate-version`, `-installation`, `-upstream`, `-scopes-excluded`,
  `-stack-candidate`, and the new `-ownership`. Project-owned: `.agentic-flow-assurance`,
  `-assurance-audit`, `-roles`, `-stack`, `-review-policy`, `.agentic-flow/config`.
- **No `uninstall` exists.** The command policy has no row for it.

## Proposed approach

### Option A — install-time ownership evidence, fenced and resumable apply (recommended)

**Evidence is recorded when the harness writes, not inferred later.** A new
`.agentic-flow-ownership` record (f-1) is written next to the upstream record on every
apply:
- `created=<sha>  <path>`: the harness wrote this path when it did not exist (`create`).
- `preexisting=<sha>  <path>`: the path existed and was not in the previous installation
  record when the harness first installed it (`same`, `overwrite`, `candidate`). The file
  is the adopter's for good.
- `inherited=<sha>  <path>`: the path was already installed before ownership was
  recorded. Its origin is unknown.
- `candidate=<sha>  <candidate path>`: a merge candidate exactly as the harness wrote it.

Rows carry forward while the path is still an active manifest destination, or while the
candidate file still exists. Pending applies count, because the record is written even
when the installation record is not. A row changes only when the harness re-creates a path
the adopter deleted, which makes it `created`. Rows for other paths are dropped.

**A payload file is removed only when all of these hold:**
- it has a `created` row;
- it has an `accepted=` hash with no pending `offered=`;
- its current bytes match that `accepted=` hash;
- if it is tracked, its index entry and its `HEAD` blob both have those same bytes. The
  commit therefore deletes exactly the verified bytes, and `git rm` cannot refuse.

A created, pristine, tracked path whose index or `HEAD` differs is a harness write that
has not been committed yet, for example after an upgrade. It is reported as
`uncommitted-change`, and **apply refuses with `uncommitted-install`** until the adopter
commits or discards that change. Keeping such files would orphan harness bytes once the
records are gone.

`preexisting`, `inherited` and missing rows are kept. f-5 lets the owner claim `inherited`
and legacy paths explicitly.

The classifier walks the union of installation rows and ownership rows. A path that a
pending upgrade created is therefore still considered.

**A candidate is removed only when its bytes match its own `candidate` row.** A `candidate`
row is written only when the harness writes the file, never when it reuses an existing
one. Candidates are discovered in two ways: from the `candidate` rows, whose paths are
validated like every record path, and by name next to every installed or owned path.
Legacy candidates, which have no row, are kept, as are edited and unrecognized ones. All of
them are listed.

**`core.hooksPath` is unset only when the harness can show it set the value.** f-1 makes
`git_guard_enable` record `agentic-flow.hooksPathSetBy=<init|migration>` in the same local
config when it sets the path. Uninstall unsets both values only when all of these hold:
- `git config --show-scope --get-all core.hooksPath` returns exactly one value,
  `scripts/git-hooks`, in `local` scope from the common dir's `config`;
- no `worktree` scope overrides it;
- the marker is present.

Anything else (a global or system value, a worktree override, a local value without the
marker, several values) is kept and reported, together with the exact command to remove
it.

**Writers register; uninstall fences** (f-3). The protocol has two halves.

- **Writers register first.** Every process that may write under `<common>/agentic-flow/`
  does this for its whole mutation window:
  1. Create a registration, `writers/<nonce>`, holding `pid`, `start` and `host`.
  2. Check for the fence. If it exists, remove the registration and refuse.
  3. Do its work, then remove the registration on exit.

  Who registers:
  - **The dispatcher,** for every subcommand except `uninstall`, `--help` and
    `--version`, before dispatch and until the process exits.
  - **The detached controller child,** before it acknowledges.
  - **Writers outside the dispatcher,** through the same helper: `budget.sh`, and any hook
    that writes.
  - **The direct install writers.** `export.sh` and `init.sh` resolve the *target's* Git
    common dir and register there for their whole run, before their first write to the
    target. A non-Git target has nothing to fence.
  - **A process that `exec`s another harness entry point,** such as upgrade's bridge or
    `init` calling export. It hands its registration over through
    `AGENTIC_FLOW_WRITER_REGISTRATION`, and the new image adopts it and re-arms the EXIT
    trap instead of registering again.

  f-3 enforces this inventory with a `make check` assertion.
- **Uninstall fences first.**
  1. Publish the fence.
  2. Scan the registrations, the three lock roots and the linked worktrees.
  3. Refuse if anything is live or unresolved.

Each side writes its own marker before it reads the other's, so they cannot both proceed.
A writer that passed dispatch before the fence existed is still registered at the moment
of its last write, so uninstall sees it.

Uninstall reports each registration and lock as `live`, `stale-local` (this host, process
gone or start time changed) or `unresolved` (no owner yet, another host, or unreadable).
- It removes only `stale-local` *registrations*. They hold no state, and their process
  can no longer write.
- It never clears a lock. Any lock entry is a refusal.

Uninstall also refuses when a linked worktree exists that is not a plan worktree it will
clean. After `clean`, only the main checkout's fence-aware scripts remain.

**One uninstall at a time: a kernel mutex serializes every fence change** (f-3).
- Every uninstall process that may change the fence holds
  `<common>/agentic-flow/uninstall.lock`, non-blocking, for its whole lifetime. That
  covers a fresh apply, a resume, and a dry run that clears a stale preparation.
- The lock is taken with Perl `flock` on a descriptor the Bash process keeps open, so
  re-exec into `bin/` keeps it.
- After acquiring it, the process checks that the path still names the locked inode. If
  it does not, it retries once, then refuses with `uninstall-busy`.
- Failing to get the lock means another uninstall is alive: refuse with `uninstall-busy`.
- Holding the lock *proves* that the fence's previous owner is dead. The kernel releases
  the lock at process death, so a lock can never be stale. The fence's `pid` and `start`
  serve only as diagnostics.
- `flock` is not trusted across hosts. A fence whose `host` differs from this host is
  `unresolved` and refused with `fence-owner-unresolved`.
- Every fence change happens under the lock, after re-reading the fence and checking that
  its generation, `{nonce, gen}`, is still the one observed. These changes are: publish,
  clear a stale preparation, take over for resume, and release. A changed generation
  restarts resolution from the beginning.
- Clearing uses `unlink`. Take-over writes a new fence with `gen+1` and renames it over the
  path, so the fence never disappears while an apply is incomplete.

**The fence is never ownerless, and setup has a recoverable preparation state** (f-3,
f-4).
- The fence is a regular file, `<common>/agentic-flow/uninstall.fence`, holding `nonce`,
  `gen`, `pid`, `start` and `host`. It is published by `link(2)` from a fully written temp
  file, the same pattern `controller_acknowledge` uses. It exists either complete or not
  at all.
- Artifacts go in `<common>/agentic-flow/uninstall-<nonce>/`:
  1. `plan.json`;
  2. `bin/`, staged as `bin.tmp/` and renamed into place;
  3. `ready`, written last. `ready` records the SHA-256 of `plan.json` and of the `bin/`
     manifest.

  **No destructive action happens before `ready` exists.** That is the boundary.
- A fence without a valid `ready` is in *preparation*. Any `uninstall` invocation,
  including from the original `scripts/agentic-flow`, which is still intact by
  construction, resolves it under the mutex:
  - mutex busy → refuse with `uninstall-busy`;
  - another host → refuse with the manual removal commands;
  - otherwise, after the generation check, delete the artifacts directory, then unlink
    the fence, report "abandoned preparation cleared", and continue.

  Every other command keeps refusing while the fence exists, and names it.

**Apply runs from a persisted plan and can resume** (f-4).

Contents of the plan:
- **Binding.** `plan.json` records the checkout: top-level path, absolute Git dir,
  `HEAD`'s symbolic ref (a detached `HEAD` is refused at preflight) and `HEAD`'s commit.
- **Preconditions.** Every planned action carries one, and a resume checks it again:

  | Item | Precondition | Already done when |
  |---|---|---|
  | File (payload, candidate, stamp, record, project state, `.agentic-flow/config`) | SHA-256, file type, tracked flag | absent; a tracked file also needs its deletion staged |
  | Git config value (`core.hooksPath`, the marker) | exact value, scope and origin file | absent |
  | Common-dir directory (caches, `--purge-ledger` records) | bounded manifest digest of relative paths, types and content hashes | moved into the artifacts' `trash/` or absent |
  | Plan | `clean`'s own checks, which it reruns | its record is `closed` |

  A directory over the manifest bound (10,000 entries or 1 GiB) is classified `keep`, and
  the report gives the manual command.
- **Progress.** `progress` is an append-only list of completed actions.

How apply removes things:
- A directory is removed by first renaming it, atomically, into the artifacts' `trash/`.
  It is therefore either untouched, and checked, or done. `trash/` is emptied at the end.
- Files are removed one by one. Git config keys are unset one by one, `core.hooksPath`
  before the marker.

A retry runs the resume command, which uninstall prints before its first destructive
action: `<common>/agentic-flow/uninstall-<nonce>/bin/agentic-flow uninstall --resume`.
While the fence exists, `scripts/agentic-flow uninstall --resume` execs the same copy.

A resume:
- takes the mutex, refusing with `uninstall-busy` if another uninstall is alive, then takes
  over the fence (`gen+1`) after the generation check;
- validates `ready` against the hashes of `plan.json` and the `bin/` manifest;
- **checks the binding**: same top level and Git dir, same symbolic ref, and `HEAD`
  equal to the planned commit. A `HEAD` whose first parent is the planned commit and
  whose message carries this nonce's trailer is also accepted, because the commit already
  landed. Anything else refuses with `checkout-changed`;
- accepts staged changes only when every one is a deletion of a tracked path in
  `plan.json`;
- does not reclassify. It checks each remaining action's precondition:
  - already done → recorded as done;
  - precondition holds → executed;
  - precondition fails → kept and reported `changed-during-uninstall`.

A resume of a run that already reached `done` skips all of this and only finishes the
cleanup below. Cleanup touches nothing in the tree or the index, so it needs no binding
check.

**The commit contains exactly the verified deletions** (f-4). It is built in a private
index, never from the adopter's index:
1. Check the binding again.
2. Point `GIT_INDEX_FILE` at the artifacts' `index` and run `git read-tree <bound HEAD>`.
3. Remove exactly the planned tracked paths from that index.
4. Run `git write-tree`, then `git commit-tree -p <bound HEAD>` with the trailer, the
   adopter's identity, and `-S` when `commit.gpgSign` is set.
5. Verify that `git diff-tree --no-renames --name-status <bound HEAD> <new>` lists only
   `D` rows and equals the planned tracked set.
6. Run `git update-ref refs/heads/<bound ref> <new> <bound HEAD>`. That
   compare-and-swap fails if the branch moved.

The adopter's real index already holds the same deletions from `git rm`. Anything else the
adopter staged during apply stays staged and is never committed; the report lists it. Hooks
do not run for this deletion-only commit. The report says so, and lists any custom hook
that still chains the removed scanner, because the adopter's next commit will hit it.
`--stage-only` skips steps 2–6 and leaves the deletions staged.

**Completion is persisted, and recovery stays available until the fence is released**
(f-4). After the commit, or after staging, the run publishes `done` in the artifacts. It
holds the outcome: the commit SHA, or `stage-only` with the staged set. Then:
1. Print the kept and reference sections.
2. Empty `trash/`.
3. Under the mutex, after the generation check, unlink the fence.
4. Remove the artifacts directory, including `bin/`.
5. Remove `uninstall.lock`.

Until step 3, `ready`, `done`, `plan.json` and `bin/` all exist, so the resume command
works. An interruption after step 3 leaves an inert directory, not a blocking fence. The
run prints its path before step 3.

### Option B — infer ownership from Git history

Draft 2's rule: the adoption commit's parent lacked the path. Rejected by review. It
deletes an adopter file that was untracked at export time and committed with the stamp, and
it says nothing about paths a later upgrade first ships.

### Option C — managed-region markers in contracts

These would let uninstall strip only the harness's section from a hand-merged `CLAUDE.md`.
That needs a template format change and an upgrade migration. Deferred by owner decision
(2026-11-27). Until then, the kept list and the reference report tell the adopter exactly
which lines to edit.

**Recommendation:** Option A. A false "keep" costs the adopter one manual `rm`. A false
"remove" destroys their work. Every ambiguous case keeps the file.

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

<common>/agentic-flow/writers/<nonce>          (f-3; directory: owner = {pid,start,host})
<common>/agentic-flow/uninstall.lock           (f-3; flock mutex, held for an uninstall's lifetime)
<common>/agentic-flow/uninstall.fence          (f-3; file published by link(2): {v,nonce,gen,pid,start,host})
<common>/agentic-flow/uninstall-<nonce>/       (f-4; plan.json, bin/, ready, progress, index, trash/, done)

writer_register <common> <label>    # mkdir registration, then fence check; trap removes it
writer_adopt                        # take over AGENTIC_FLOW_WRITER_REGISTRATION after exec
writer_release                      # explicit early release (rarely needed)
uninstall_mutex <common>            # non-blocking flock on a kept descriptor, inode-checked
uninstall_fence_acquire <common>    # under the mutex: resolve, publish, scan; refuse or proceed
uninstall_fence_change <common> <observed nonce:gen> clear|takeover|release

agentic-flow uninstall [--yes] [--json] [--keep-docs] [--remove-project-state]
                       [--purge-ledger] [--no-fetch] [--claim-adoption] [--stage-only]
agentic-flow uninstall --resume [--yes] [--json]

  default            dry run: classify, print, write nothing (no fence).
                     On a terminal, offer to apply after the report.
  --yes              apply without prompting (required off a terminal)
  --json             emit the plan or the result as one JSON object
  --keep-docs        keep payload files under docs/ and the root METHODOLOGY.md / ADOPTION.md
  --remove-project-state   also remove the project-owned stamps and .agentic-flow/config
  --purge-ledger     also remove ledger, decisions, findings and plan records
  --no-fetch         no network: plan guards use local origin/<base>; f-5's fetch is skipped
  --claim-adoption   f-5: treat legacy paths the adoption commit added as harness-created
  --stage-only       leave the verified deletions staged instead of committing them
  --resume           continue an interrupted apply from <common>/agentic-flow/uninstall-<nonce>/

  Every run ends with two stdout sections:
    Kept — finish by hand:
      <path>  (<why>)
    Still referencing removed files:
      <file>:<line>: <removed path or command>
  When a kept Makefile or workflow references removed files, the report says first that
  `make check` or CI will fail after removal.

exit 0  dry run printed, or apply finished (committed, or staged with --stage-only)
exit 2  usage
exit 3  refused before any write (names every reason)
exit 4  apply stopped part-way; the fence and plan remain; the resume command is printed
```

Plan JSON (`plan.json` and `--json`; the text report renders the same object):

```
{ "v": 1, "nonce": "<hex>", "root": "<abs>", "version": "0.21.0+3757627",
  "binding": { "toplevel": "<abs>", "git_dir": "<abs>", "ref": "refs/heads/<name>", "head": "<sha>" },
  "adoption_commit": "<sha|null>",
  "refusals":  [ { "reason": "<reason>", "subject": "<plan|lock|path>", "detail": "<text>" } ],
  "payload":   [ { "path": "<rel>", "action": "remove|keep", "tracked": bool, "sha256": "<hex>",
                   "index_blob": "<oid|null>", "head_blob": "<oid|null>",
                   "why": "pristine|edited|preexisting|inherited|no-ownership-record|
                           pending-offer|keep-docs|uncommitted-change|claimed",
                   "provenance": "upstream|installed-revision|none" } ],
  "candidates":[ { "path": "<rel>", "action": "remove|keep", "tracked": bool, "sha256": "<hex>",
                   "why": "recorded|legacy|edited|unrecognized" } ],
  "stamps":    [ { "path": "<rel>", "owner": "harness|project", "action": "remove|keep",
                   "tracked": bool, "sha256": "<hex>" } ],     (.agentic-flow/config included)
  "plans":     [ { "id": "<id>", "worktree": "<abs|null>", "branch": "<name|null>" } ],
  "locks":     [ { "path": "<rel>", "kind": "lock|registration", "state": "live|stale-local|unresolved",
                   "owner": "<text>" } ],
  "hooks":     { "values": [ { "scope": "<scope>", "origin": "<file>", "value": "<v>" } ],
                 "marker": { "value": "<init|migration>", "origin": "<file>" } | null,
                 "action": "unset|keep", "manual": "<command|null>",
                 "chained_scanner": [ "<hook file>" ] },
  "git_state": { "remove": [ { "dir": "<rel>", "digest": "<hex>", "entries": n } ],
                 "keep":   [ { "dir": "<rel>", "why": "record|over-bound" } ], "salvage_refs_kept": n },
  "kept":      [ { "path": "<rel>", "why": "<reason>" } ],
  "dangling_references": [ { "file": "<rel>", "line": n, "ref": "<removed path|agentic-flow>" } ],
  "dangling_truncated": n,
  "outside":   [ "<checklist line>" ],
  "commit":    { "action": "commit|stage-only", "tracked_deletions": [ "<rel>" ],
                 "hooks_skipped": true, "unrelated_staged": [ "<rel>" ] } }

done (f-4, written once): { "nonce": "<hex>", "outcome": "commit|stage-only",
                            "commit": "<sha|null>", "staged": [ "<rel>" ] }
```

Refusal reasons: `not-git-toplevel`, `linked-worktree`, `detached-head`, `staged-changes`,
`lock-present`, `writer-active`, `uninstall-busy`, `uninstall-in-progress`,
`fence-owner-unresolved`, `checkout-changed`, `plan-invalid`, `plan-refused`,
`purge-with-open-plan`, `no-installation`, `uncommitted-install`.

## Threat model (one paragraph)

The untrusted actors are agent stations and anyone who can write files in the tree.
Uninstall deletes the secret scanner, the hook path and the command-policy deny rules, so
**an agent that can run it can drop the safety floor**. f-2 adds deny rows for every
spelling the policy already covers, `--resume` and the fence's `bin/` path included. The
human runs it, as with `ship` and `hold clear`.

A planted ownership or upstream record can only cause deletion of a file whose bytes equal
a hash the attacker chose, and the attacker could already delete that file. Every record
path goes through `payload_safe_path`. Symlinks are never followed or deleted through.

The fence and its artifacts are in the Git common dir, outside the tree. Resume validates
`ready`'s hashes, `plan.json`'s shape and paths, and the checkout binding before acting.
A plan moved to another branch or checkout cannot commit there. The commit is built from
`HEAD` plus the planned deletions only, so nothing staged by anyone else can enter it.

**Residual risk.** An exporter or CLI from a source checkout older than f-3 does not
register, so the fence cannot exclude it. If such a process changes a planned file, the
item's precondition no longer holds and the item is kept. Files it creates are never in
the commit. `ADOPTION.md` says not to run an older exporter against a repository during
uninstall.

f-5 runs the installed revision's own `export.sh` into scratch. That is the same trust that
`upgrade` already places in its source, and only the resulting hashes are used.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---------------|-----------|-----------------------|--------------------|
| `git fetch` for plan guards (`clean`) | `plan-refused`, fence released, no write | same | n/a (preflight) |
| Clone of `.agentic-flow-source` origin (f-5) | `AGENTIC_FLOW_FETCH_TIMEOUT` (120 s) → claimed paths kept | Short SHA missing or ambiguous → kept | n/a (scratch only) |
| Installed revision's `export.sh` (f-5) | 120 s → kept | Missing `file=` row or export failure → kept | n/a |
| `clean` per plan during apply | — | — | Exit 4; resume skips closed plans |
| Fence publication / artifact writes | — | — | Before `ready`: the next `uninstall` takes the mutex and clears the preparation; nothing destructive happened |
| Concurrent uninstall processes | — | — | The second fails the mutex: `uninstall-busy`, no fence change |
| File removal / `git rm` | — | — | Exit 4; resume treats absent planned files as done and stages them |
| Stamp, record, config or state removal | — | — | Exit 4; resume checks each item's persisted precondition, not the records |
| Constrained commit (`commit-tree` + compare-and-swap `update-ref`) | — | Diff check fails, or the compare-and-swap loses → exit 4, no ref change; resume rechecks the binding | `update-ref` landed but `done` was not written → resume sees the trailer at the bound ref, writes `done`, cleans up |
| Final cleanup | — | — | Before the fence unlink: resume, in the `done` state, finishes cleanup. After: an inert artifacts directory, whose path was printed |

Bounds: the existing record limits (2,000 paths, 4,100-byte lines) apply to the ownership
record and to `plan.json`'s path lists. `plan.json` is capped at 2 MiB. Directory
manifests stop at 10,000 entries or 1 GiB; past that the directory is kept. The scan reads
only `writers/` and the three lock roots, at most 2,000 entries each. The reference scan reads kept payload files and
`.github/workflows/*`, skips files over 1 MiB and binary files, and reports at most 20
lines per file and 200 in total, counting the overflow. One clone per run.

## Out of scope / What NOT to build in this pass

- Removing anything outside the repository. Outside items are printed only.
- Editing any kept file: custom hooks, settings, contracts, the `Makefile`, CI workflows.
  The lines to fix are listed instead.
- Clearing any lock, or an override for plan guards or the fence.
- `--abort`. Before the commit, tracked removals restore with `git restore --staged
  --worktree`. Removed untracked files were byte-identical to recorded harness output, and
  the next export recreates them.
- Managed-region markers (Option C).
- Monorepo installs whose harness root is not the Git top level. They are refused.
- Pushing, and any forge call.

## Open questions

- [x] **Uninstall acceptance** (product analysis): remove only paths with install-time
  ownership evidence and pristine provenance, with the no-override plan guards and the
  fence. *Decided 2026-11-27 by the owner: yes.*
- [x] **Legacy ownership.** *Decided 2026-11-27 by the owner: keep f-5.* Every install
  made before f-1 has no ownership record,
  so its existing files become `inherited`. Without f-5, uninstall removes none of them,
  only stamps and state.
  - *Chosen:* keep f-5. `--claim-adoption` is an explicit owner assertion. It applies
    only to `inherited` or unrecorded paths that the adoption commit added, still requires
    pristine bytes, and is listed path by path before the prompt.
  - It never applies to `preexisting` rows. It does not apply to paths first shipped
    after adoption, because the adoption commit did not add them.
  - *Rejected alternative:* drop f-5 and keep every legacy file.
- **Project-owned state default.** Keep it unless `--remove-project-state` is given?
  *Recommended: yes.*
- **Commit.** Commit by default with the adopter's own identity, through the constrained,
  deletion-only commit, which runs no hooks. Offer `--stage-only` for adopters who want to
  commit it themselves. *Recommended: yes.*

## Revision history

Kept in Part A so that it does not count against Part B's word cap.

- **Draft 5 (2026-11-27)** answers the third review:
  1. A kernel `flock` mutex, held for each uninstall's lifetime, serializes every fence
     change. Changes are made only after a `{nonce, gen}` recheck. Take-over renames over
     the fence and never unlinks it (scenario 7d).
  2. `done` is persisted after the commit or staging. The fence is released before the
     artifacts are deleted, so `bin/` stays usable until then (scenario 7e, committed and
     stage-only).
  3. `export.sh` and `init.sh` register in the target's common dir for their whole run.
     `exec` hand-over keeps one registration across upgrade's bridge. The residual risk
     from pre-f-3 exporters is stated (scenario 6).
  4. The commit is built in a private index from the bound `HEAD` plus the planned
     deletions, checked by a diff, and landed by a compare-and-swap `update-ref`.
     Unrelated staged changes stay out (scenario 7f). `--stage-only` replaces the
     hook-based fallback.
  5. A tracked path is removable only when the worktree, the index and `HEAD` all hold the
     pristine bytes. An uncommitted upgrade refuses with `uncommitted-install`
     (scenario 13).
- **Draft 4 (2026-11-27)** answers the second review:
  1. Writers register for their whole mutation window. Dispatcher subcommands, the
     detached controller child, `budget.sh` and writing hooks all register, and a
     `make check` inventory enforces it. `verify-step` paused before its write is in
     scenario 6.
  2. The fence is a `link(2)`-published file and is never ownerless. Artifacts become
     valid only with `ready`, and nothing destructive happens before it. The original CLI
     clears a stale preparation (scenario 7a).
  3. `plan.json` binds the top level, Git dir, ref and `HEAD`. These are checked at
     resume and again before the commit (scenario 7b).
  4. Legacy and reused candidates are kept. `candidate` rows are written only for files
     the harness actually wrote (scenario 3).
  5. Candidates and created paths are discovered from ownership rows as well, which
     covers pending upgrades (scenario 3).
  6. Every persisted removal carries a precondition: file hash and type, config value and
     origin, or directory manifest. Directories are removed by an atomic move into
     `trash/` (scenario 7c).
- **Draft 3 (2026-11-27)** answers the first review:
  1. Ownership comes from an install-time record (`created` / `preexisting` /
     `inherited`), not adoption history. Both untracked-adopter histories are scenarios
     1 and 2. f-1 is added.
  2. Apply runs from a persisted plan in the fence, with a `bin/` copy of the CLI, and
     `--resume` accepts only its own staged deletions. The three interruptions are
     scenario 7.
  3. A fence with write-then-read ordering against the controller, handoff and worktree
     locks. Unresolved locks are reported and preserved. f-3 is added.
  4. Candidates need a matching `candidate` row, or `offered=` for legacy candidates.
     Edited and unrecognized candidates are kept.
  5. `core.hooksPath` is unset only with one local value and the harness's marker. Global
     and pre-existing local values are reported.

  Draft 2's rule is now Option B (rejected). Legacy installs move behind the explicit
  `--claim-adoption` (f-5, a blocking decision).
- **Draft 2 (2026-11-27):** keeps paths that existed before the adoption commit; adds the
  stdout kept list and the reference scan. Option C stays deferred.
- **Draft 1 (2026-11-27):** first draft.

---

# Part B — Implementation Brief

## Acceptance scenarios

1. **Untracked identical file at adoption.** Given an adopter `docs/done/.gitkeep` that
   was untracked when export ran and was committed with the version stamp, when uninstall
   runs, then it stays as `preexisting`. With `--claim-adoption` it also stays.
2. **Upgrade meets an adopter file.** Given an adopter file added after adoption at a path
   that a later upgrade first ships with identical bytes, then it stays as `preexisting`.
3. **Candidates.**
   - An untracked `CLAUDE.md.agentic-new` that the adopter edited stays as `edited`.
   - An unedited harness-written candidate beside another path is removed.
   - An adopter-supplied `.agentic-new` that already held the exact source bytes, and
     that the apply reused, has no `candidate` row. It stays as `legacy`, although its
     bytes match `offered=`.
   - **Pending upgrade.** An upgrade introduces a new path whose destination differs, so
     it writes a candidate and leaves the installation record unchanged. The candidate is
     found through its `candidate` row and removed. A path that upgrade created is found
     through its `created` row.
4. **Hook path ownership.**
   - A global `core.hooksPath=scripts/git-hooks` stays and is reported.
   - A local value set before adoption has no marker. It stays and is reported with the
     exact unset command.
   - A value set by `init` (marker present) is unset, together with the marker.
5. **Plan guard.** Given an unmerged plan branch with a dirty worktree, then exit 3 names
   the plan, and the tree, Git config, refs and common-dir state are byte-identical.
6. **Racing writers.**
   - A controller that takes its lock between uninstall's preflight and its fence: either
     the controller refuses with `uninstall in progress`, or uninstall refuses, and
     nothing is deleted.
   - A `verify-step` paused after dispatch and before its first write, while uninstall
     publishes its fence: uninstall refuses with `writer-active`, and the verification
     record is written intact.
   - Reversed order (fence first, then the writer starts): the writer refuses and writes
     nothing.
   - A lock with no `owner.json`, or with another host's owner, is `unresolved` and left
     in place. A `stale-local` registration is cleared.
   - `scripts/export.sh` (and `init.sh`) is run from a separate scaffold checkout,
     targeting the repository, after uninstall holds the fence. It refuses before its
     first write, and the target's tree, records and Git config are unchanged.
   - An export paused after registering and before its first write blocks uninstall with
     `writer-active`.
   - An upgrade's bridged `exec` keeps exactly one registration.
7. **Interrupted apply.** Interrupt the apply at each of these points:
   - after the first tracked deletion;
   - after `scripts/agentic-flow` is removed;
   - midway through stamp removal.

   Each time, a fresh `uninstall` refuses with `uninstall-in-progress` and prints the
   resume command, and `--resume` from the artifacts' `bin/` finishes with one commit.
   The final tree equals an uninterrupted run's.
7a. **Interrupted preparation.** Kill the run at each of these points:
    - immediately after the fence is published;
    - after `plan.json`, with `bin.tmp/` partly written;
    - before `ready`.

    Each time, other commands refuse and name the fence. Running `scripts/agentic-flow
    uninstall` from the original CLI clears the stale preparation and produces the same
    dry-run report. The tree, Git config and refs are unchanged.
7b. **Branch switch.** Interrupt an apply after the first tracked deletion. Restore the
    index, then check out another branch with identical payload bytes and a clean index.
    `--resume` refuses with `checkout-changed`, and that branch's `HEAD` is unchanged.
    Switching back and resuming finishes on the original branch.
7c. **Precondition changed.** Interrupt a `--remove-project-state` apply before project
    state, then edit `.agentic-flow/config`. `--resume` keeps the file, reports it as
    `changed-during-uninstall`, and finishes everything else. A cache directory that a
    test writes into after the interruption is likewise kept.
7d. **Concurrent recovery.**
    - Two processes clear the same stale preparation at once.
    - Two processes resume the same interrupted apply at once.

    In each case exactly one proceeds and the other refuses with `uninstall-busy`. The
    fence's generation advances once, and no fence is unlinked while an apply is
    incomplete. A fence whose `host` differs is refused as `fence-owner-unresolved`.
7e. **Interrupted cleanup.** For a committed run and a `--stage-only` run, interrupt:
    - after `done`;
    - after emptying `trash/`;
    - after the fence unlink.

    Before the unlink, `--resume` from `bin/` (the original CLI is gone) finishes cleanup
    and leaves the commit or the staged set unchanged. After the unlink, no command
    refuses because of uninstall, and the printed artifacts path is the only leftover.
7f. **Unrelated staged change.** Between a resume's index check and its commit, a test
    hook runs `git add` on an unrelated file. The uninstall commit contains only the
    planned deletions. The unrelated file is still staged afterwards and is listed in
    `unrelated_staged`.
8. **Pristine created file.** Given a `created` file byte-identical to `accepted=`, then
   it is removed. An edited `created` file, and a hand-merged `CLAUDE.md`, stay.
9. **Install → uninstall.** Given an export into an empty Git repository, committed, when
   `uninstall --yes` runs, then every pristine created file and every harness stamp is
   gone, and one commit exists. The tree matches the pre-export commit apart from
   `docs/README.md` and the kept project state.
10. **Legacy claim.** Given a fixture with no ownership or upstream record, whose source
    ref has moved past the installed commit, when `uninstall --claim-adoption` runs, then
    only files the adoption commit added *and* identical to the installed revision are
    removed. With `--no-fetch`, an unreachable commit or a stampless version, all stay.
11. **Kept list.** Given an initialized fixture whose kept `Makefile` calls
    `scripts/self-test.sh` and whose `.github/workflows/ci.yml` calls `scripts/doctor.sh`,
    then stdout lists both with their line numbers and warns that `make check` and CI
    will fail. Neither file changes.
12. **Policy.** `agentic-flow uninstall` is blocked for agents in all three runtimes.
13. **Uncommitted upgrade.** Given an upgrade that rewrote tracked, created, pristine
    files and was not committed, the dry run lists those files as `uncommitted-change`.
    `--yes` refuses with `uncommitted-install` and writes nothing. After the adopter
    commits the upgrade, `uninstall --yes` removes them, and `git rm` never fails.

## Invariants

- A dry run writes nothing, not even the fence. It may only clear a `stale-local`
  preparation.
- The fence never exists without its owner. No destructive write happens before `ready`
  is valid. Before `ready`, the original CLI can always clear the preparation.
- At most one uninstall process lives per common dir, enforced by the kernel mutex. Every
  fence change happens under it, after a generation check.
- Until the fence is released, `ready`, `plan.json` and `bin/` exist, so the resume
  command always works.
- The uninstall commit's diff against the bound `HEAD` is exactly the planned tracked
  deletions. Every one of them was verified identical in the worktree, the index and
  `HEAD`.
- Every covered writer is registered from before its first write until after its last.
- A file is removed only when there is ownership evidence (a `created` row, its own
  `candidate` row, or an owner claim) and its current bytes match the hash the plan
  recorded. Symlinks are never followed.
- Every persisted removal carries a precondition. A resume removes an item only while its
  precondition holds.
- A resume, and the commit, happen only in the bound checkout, on the bound ref, at the
  bound `HEAD`.
- No lock is ever cleared, and no flag overrides `clean`, the fence or the scan.
- A resume never reclassifies. It acts only on `plan.json` and accepts only its own staged
  deletions.
- Every path that stays is printed on stdout with its reason. No kept file is modified.
- The running CLI never reads a file that the run has deleted.
- Bash 3.2; no new required tool.

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
Every step's DoD is met, and `make check` and `make test` are green. Scenarios 1–13, with
7a–7f, are covered by named tests. `ADOPTION.md` has a *Removing the harness* section, and
`CHANGELOG.md` has an entry naming the new record and the fence. A manual run in a scratch
export shows the dry-run report, then `--yes`, then a clean `git status`.

## Verification commands
```bash
make check                                  # per step
make test-one F=upgrade                     # uninstall tests, timed as upgrade:uninstall
make test-one F=export                      # f-1: ownership rows on export
make test-one F=hooks                       # f-2: command-policy rows
make test-one F=controller S=launch         # f-3: controller lock and fence
make test-one F=stations S=handoff          # f-3: handoff, start and clean under the fence
make test                                   # end of brief
```

---

## F-1 — Record ownership evidence when the harness writes a path
**Why first:** every later step reads this evidence, and it changes the install records,
which is the hardest part to reverse.

**Approach:**
- In `payload-apply.sh`, load, carry forward and write `.agentic-flow-ownership` alongside
  the upstream record. Reuse its parser limits and its NUL, UTF-8 and path checks. Reject
  unknown keys. Write it atomically, at the point where `payload_upstream_write` runs.
- Classify each path from the apply result and the *previous* installation record:
  - `create` → `created`;
  - otherwise, a path already in the previous record with no row → `inherited`;
  - otherwise → `preexisting`.
- A candidate gets a `candidate` row only when the harness writes it
  (`PAYLOAD_RESULT_CANDIDATE_ACTION=candidate`). A reused candidate (`pending`) keeps the
  row it already has, or stays without one. `upgrade --merged` drops the rows of the
  candidates it removes.
- The ownership record is written on every apply, pending or not, alongside the upstream
  record, so rows exist for paths and candidates that the installation record does not
  list yet.
- Forbid the record as a payload destination, as the upstream record is.
- `git_guard_enable` takes a source label and, only when it actually set
  `core.hooksPath`, writes `agentic-flow.hooksPathSetBy` to the same local config.

**Test:** scenarios 1, 2 and 3 (the reused and pending-upgrade cases) as records, plus:
- an `export --force` over an existing file → `preexisting`;
- an upgrade from a record-less install → all `inherited`;
- an adopter deletes a created file and the harness re-creates it → `created`;
- a malformed record or an unsafe path → refused before any write;
- `init` sets the marker only when the path was unset (scenario 4's setup).

**DoD:** every export and upgrade leaves a complete ownership record. `init` leaves the
marker only when it set the hook path.
**Verify:** `make test-one F=export && make test-one F=upgrade`
**Risks:**
- Older installed libraries never read this file. Releases that write it must still read
  older installs without it.
- Fixture counts change; measure them and update `config/test-budgets.tsv`.
**Red-first:** none
**Commit:** `Record which payload paths the harness created`

---

## F-2 — Classify ownership and report the removal as a dry run
**Why second:** it turns f-1's evidence into the plan that f-4 executes. It is read-only,
so adopters can see what would happen before anything can delete.

**Approach:**
- Add a dispatcher entry `uninstall` and a library `scripts/lib/uninstall.sh`. The library
  sources `payload-apply.sh` and `start.sh` itself (memory:
  `library-sources-its-dependencies`).
- Root resolution: `find_root` must equal the Git top level, and the run must be in the
  main worktree.
- Classify payload paths, candidates, stamps and the hook path by the Part A rules.
  - Payload paths are the union of installation rows and ownership rows.
  - For a tracked path, compare the worktree hash, the index blob and the `HEAD` blob. A
    created, pristine path where they disagree is `uncommitted-change`, and apply refuses
    with `uncommitted-install`.
  - Candidates come from `candidate` rows and from the three library names next to every
    installed or owned path. Anything else matching `.agentic-new*` is `unrecognized`.
  - Record the precondition data the plan needs: hashes, tracked flags, config origins and
    directory manifests.
- A detached `HEAD` is refused with `detached-head`.
- Plans: run `clean`'s checks in dry-run mode for every record that is not `closed`.
  Collect every refusal, not just the first.
- Report locks in their three states (f-3 makes their presence a refusal on apply).
- Build the kept list, and run the reference scan over the kept files and
  `.github/workflows/*`. Match each removed path, each removed directory as a `<dir>/`
  prefix, and `agentic-flow` used as a command. Apply the bounds.
- Text and `--json` render one object. Exit 0 with a report, or 3 with refusals.
- Add the command-policy deny rows ("the human uninstalls"), regenerate the native rules,
  and update `docs/reference/command-policy-coverage.md`.
- Add `upgrade:uninstall` to the wall-ceiling keys.

**Test:** scenarios 1–4, 8, 11 and 13 (dry-run half) as classifications, 5 (refusal,
tree digest unchanged) and 12. Also: `linked-worktree`, `no-installation`, a symlinked payload path, the
reference-scan truncation, and `--json` validating against the shape.

**DoD:** `agentic-flow uninstall` prints a correct plan and never writes. Agents cannot run
it.
**Verify:** `make test-one F=upgrade && make test-one F=hooks`
**Risks:**
- `clean`'s functions use globals set in `plan_worktree_cmd`. Call them through a
  per-plan subshell wrapper.
**Red-first:** `upgrade:uninstall` — scripts/tests/upgrade.sh scripts/self-test.sh
**Commit:** `Add a dry-run uninstall that classifies what the harness owns`

---

## F-3 — Fence uninstall against every writer
**Why third:** apply must not start until every writer that could touch shared state
either sees the fence or is seen by uninstall, for the writer's whole mutation window.

**Approach:**
- Add `scripts/lib/fence.sh` with the functions named in *Interface*. It sources its own
  dependencies. Ship it in the payload, and have `export.sh` and `init.sh` source the
  scaffold's copy.
- `uninstall_mutex`:
  1. Open `uninstall.lock` on a fixed descriptor that the process keeps.
  2. Take `flock(LOCK_EX|LOCK_NB)` through a short Perl call.
  3. Compare the path's inode with the descriptor's; on a mismatch, retry once.
  4. If the lock is busy, refuse with `uninstall-busy`.

  The descriptor survives the re-exec into `bin/`.
- `uninstall_fence_change` re-reads the fence under the mutex, compares
  `{nonce, gen}` with the observed value, and only then clears it (`unlink`), takes it over
  (write `gen+1`, then rename over the path) or releases it. A mismatch restarts
  resolution.
- `writer_register`:
  1. `mkdir writers/<nonce>`.
  2. Write `owner` atomically.
  3. Check for `uninstall.fence`. If it exists, remove the registration and fail with
     `uninstall in progress (<fence>)`.
  4. Install an EXIT trap that removes the registration. It chains any existing trap.
- Call sites:
  - **The dispatcher,** for every subcommand except `uninstall`, `--help` and
    `--version`, before dispatch. This covers `verify-step`, `packet`, `handoff`, `start`,
    `clean`, `run`, `doctor --stations` and the rest.
  - **The detached controller child,** before it acknowledges.
  - **Writers outside the dispatcher:** `budget.sh`, and any hook script that writes under
    the common dir.
  - **`export.sh` and `init.sh`:** after resolving the target, and before their first
    write to it. They register in the target's common dir. `init` hands its registration
    to the export it runs.
  - **`exec` hand-over:** upgrade's bridge, and every other harness `exec` into another
    entry point, pass `AGENTIC_FLOW_WRITER_REGISTRATION`, and the new image calls
    `writer_adopt`.
  - Add a `make check` assertion that every file writing under `agentic-flow/` in the
    common dir is either dispatcher-reached or registers itself. Use an explicit allowlist
    file and no new list in the scripts.
- Keep the post-lock `fence` checks in `controller_lock` (both paths), the handoff lock and
  `plan_worktree_lock`, as defense in depth. `clean` runs under uninstall without
  registering: the fence owner passes the nonce through an internal function argument
  that the CLI cannot reach.
- `uninstall_fence_acquire`, holding the mutex:
  1. Resolve any existing fence: preparation, in progress, or unresolved.
  2. Publish the fence with `link(2)` from a complete temp file (`gen=1`).
  3. Scan `writers/`, `locks/`, `worktree-locks/` and the linked worktrees. Clear
     `stale-local` registrations only.
  4. If anything is live or unresolved, remove the fence and refuse with `writer-active`
     or `lock-present`, listing each entry and its state.

**Test:** scenarios 6 and 7d, made deterministic with test-only pause points
(`AGENTIC_UNINSTALL_TESTING=1` plus a named pause). The paused-writer cases pause
`verify-step` and `export.sh` after registering and before their first write. Also:
- the mutex survives a re-exec, and is free after `kill -9` of its holder;
- a recycled lock-file inode is detected;
- `start`, `handoff` and `verify-step` refuse while the fence exists, and write nothing;
- a controller lock with no owner, and one owned by another host, are `unresolved` and
  preserved;
- a `kill -9`ed writer's registration is `stale-local` and cleared;
- a refused acquisition leaves the tree digest unchanged;
- the inventory assertion fails on a planted unregistered writer.

**DoD:** while a covered writer, including a direct export or init, is in its mutation
window, uninstall cannot pass its scan. While the fence exists, no covered writer can
start. Two uninstall processes never change the fence concurrently.
**Verify:** `make test-one F=controller S=launch && make test-one F=stations S=handoff && make test-one F=export && make test-one F=upgrade`
**Risks:**
- A long controller run keeps its registration and makes uninstall refuse. That is
  intended.
- Registering every subcommand adds a `mkdir` and a check to each CLI call. Measure it
  against the stations and controller ceilings.
- EXIT-trap chaining must not replace the existing traps in `handoff.sh`, `start.sh` and
  `controller.sh`.
- Bash must not open the mutex descriptor close-on-exec. Use a low fixed descriptor, and
  test the re-exec.
**Red-first:** none
**Commit:** `Fence uninstall against every shared-state writer`

---

## F-4 — Apply the removal from a persisted plan that a retry can resume
**Why fourth:** it needs f-2's plan and f-3's fence.

**Approach:**
- `--yes`, or a `y` at the terminal prompt, takes the mutex and acquires the fence (f-3),
  then recomputes the plan. If anything differs from what was shown, it releases the fence
  and refuses. Any `uncommitted-change` refuses with `uncommitted-install` before
  preparation.
- **Preparation:**
  1. Write `plan.json` with the binding and every precondition.
  2. Stage `bin.tmp/` (the CLI plus the libraries it sources) and rename it to `bin/`.
  3. Sync, then publish `ready` with the hashes.
  4. Print the resume command, then re-exec from `bin/`.

  Every invocation resolves an interrupted preparation (Part A).
- **Apply order.** Check the binding first. Append each completed action to `progress`,
  and check each action's precondition before it runs:
  1. Run `clean` for each plan.
  2. Remove planned payload files and candidates. A tracked path's precondition covers
     the worktree hash, the index blob and the `HEAD` blob, so `git rm -q --` cannot
     refuse. Use `rm` for untracked paths.
  3. Prune directories left empty.
  4. Remove project state if asked.
  5. Unset `core.hooksPath`, then its marker, when the plan says so.
  6. Rename cache directories into `trash/`, and the `--purge-ledger` set if asked.
  7. Remove stamps and records.
  8. Build the constrained commit (Part A), or stage only.
  9. Publish `done`.
  10. Run the cleanup sequence (Part A): print the reports, empty `trash/`, release the
      fence, remove the artifacts, remove the lock file.
- `--resume` follows the Part A rules. While the fence exists, `scripts/agentic-flow
  uninstall` prints the resume command, or with `--resume` execs `bin/`.
- On any failure, stop with exit 4 and print the resume command.

**Test:** scenarios 3, 4 (unset), 5 (apply half), 7, 7a, 7b, 7c, 7e, 7f, 8, 9 and 13.
Also:
- a resume finds a staged change outside the plan → refused;
- a planned file changes between runs → kept as `changed-during-uninstall`;
- `update-ref` landed but `done` is missing → the resume writes `done` and cleans up;
- the bound branch moved before `update-ref` → the compare-and-swap fails, and the ref
  is unchanged;
- an interactive "no" writes nothing.

Use a test-only fault point, `AGENTIC_UNINSTALL_TESTING=1` plus a named action.

**DoD:** each interruption in scenario 7 resumes to the same final tree as an
uninterrupted run. Each interruption in 7a is cleared by the original CLI. A resume
outside the bound checkout and `HEAD` never commits. Every refusal leaves the tree digest
unchanged.
**Verify:** `make test-one F=upgrade`
**Risks:**
- `git commit-tree` runs no hooks. The report must say so, and list chained custom hooks
  that will fail on the adopter's next commit.
- The private index must start from the bound `HEAD`, never from a copy of the adopter's
  index.
- `git rm` on a path that has gone missing must not abort the batch. Use
  `--ignore-unmatch` per path.
**Red-first:** `upgrade:uninstall` — scripts/tests/upgrade.sh scripts/self-test.sh
**Commit:** `Apply uninstall from a persisted plan that a retry can resume`

---

## F-5 — Let the owner claim legacy paths, proven against the installed revision
**Why last:** it only turns some legacy keeps into removals, behind an explicit owner
assertion. The owner chose to keep it on 2026-11-27.

**Approach:**
- `--claim-adoption` covers paths that are `inherited` or have no ownership row, never
  `preexisting`, and only those the adoption commit added. The adoption commit is the
  oldest commit adding `.agentic-flow-version`; without one, nothing is claimed.
- When `accepted=` exists, compare against it.
- Otherwise, take the commit from `.agentic-flow-version`'s `+<sha>`, never
  `.agentic-flow-source`'s `ref`.
  - Unless `--no-fetch` is given, clone the origin once (`--filter=blob:none
    --no-checkout`, under `run_with_timeout`) and resolve `<sha>^{commit}`.
  - Run that revision's own `export.sh` into empty scratch, with
    `.agentic-flow-scopes-excluded`, and use its `file=` hashes.
- Claimed paths show `why=claimed` with their provenance, and the prompt lists them
  before applying.

**Test:** scenario 10, plus:
- scenario 1 with `--claim-adoption` (`preexisting` stays);
- an export failure at the installed revision keeps everything.

**DoD:** a legacy fixture loses exactly the claimed files that are identical to their
proven revision, and the report names that revision.
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
