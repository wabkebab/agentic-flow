<!-- TRIAGE (first pass · 2026-11-27) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict (deletes adopter files, changes the install records, and adds a command-policy floor row; project baseline is Standard)
> Phase 3 of [harness configurability](product-harness-configurability.md) (area J): `agentic-flow uninstall`, which removes only what the harness recorded creating and still holds unchanged. A single batched `git rm` stages those deletions, verifies them, and prints a two-command undo that never overwrites. Everything else is reported with exact commands.
> Draft 12 (2026-11-27), written against `0.21.0` (`3757627`). It keeps draft 11's three-step reshape, in which Git's own rollback replaces the approved draft 10's roll-forward resume, fence and writer registration. It tightens that design: literal pathspecs, a verified outcome after `git rm`, an undo that is bound to its checkout and never overwrites, and a list file per run. See *Revision history*. The owner decisions all still hold. Next: owner re-approval, then re-run `plan-to-issues`, which updates #226–#228 and closes #229 and #230.

# Feature — Uninstall: remove only what the harness owns

## Tracker
- [ ] f-1 — Record which paths the harness created — #226
- [ ] f-2 — Classify ownership and report the removal as a dry run — #227
- [ ] f-3 — Stage the verified removal in one checked, reversible `git rm` — #228

---

# Part A — Analysis

## Goal

An adopter who stops using the harness needs a clean way out. Today the only way is to
delete files by hand. That loses either way: it leaves stamps and dead references behind,
or it deletes files the adopter changed.

The owner's goal 8 (2026-11-25) asks for a script that removes the harness cleanly. The
product analysis (area J) settled what "cleanly" means. Remove only what the harness can
prove it owns. Never override a plan guard. Print everything else as a checklist instead of
touching it.

**v1 scope (owner decisions, 2026-11-27):**
- Stage the deletions; never commit.
- Report shared Git state; never remove it.
- The adopter runs `clean` first.
- Keep project-owned settings unless `--remove-project-state` is given.
- Require an explicit claim for files from older installs.

Draft 11 adds one more rule: **remove only tracked files, in one Git operation.**
Uninstall then has a single destructive step, `git rm`, and Git can always undo it.

## Current state

- **Installation record.** `.agentic-flow-installation` lists one `file=<sha256>  <path>`
  row per installed path, hashed *after* the apply (`payload-apply.sh:228-247`). It
  includes edits, so it cannot prove a file is pristine.
- **Upstream record (since 0.20.0).** `.agentic-flow-upstream` holds `accepted=` (the
  shipped hash a path was last reconciled to) and `offered=` (the pending candidate)
  (`payload-apply.sh:417-477, 584-600`). A fresh export of `3757627` wrote 149 `accepted=`
  rows for 149 paths. Only `docs/README.md` differed, because export seeds the docs index
  after the apply.
- **Nothing records who created a path.** `same` means the destination already held
  identical bytes. That can be an adopter file, for example an untracked `.gitkeep`
  committed with the version stamp. Git history cannot tell these apart.
- **Candidates.** `.agentic-new*` files hold offered upstream bytes. A byte-identical
  existing candidate is reused, not written, but still records `offered=`
  (`payload-apply.sh:516-544`). A pending apply writes the upstream record but not the
  installation record (`export.sh:133, 170-172`; `scripts/agentic-flow:431, 447-449`).
  `init.sh` renders its own `Makefile.agentic-new` and `templates/ci/ci.yml.agentic-new`
  (`init.sh:304-309`).
- **Older installs.** Installs before 0.20.0 have no upstream record until their next
  upgrade. Their first upgrade offers candidates for files that differ, and `upgrade
  --merged` records `accepted=` for those files.
- **What a batched `git rm` does and does not guarantee.** Checked in scratch on
  2026-11-27 with Git 2.55, and by the reviewer:
  - `git rm --pathspec-from-file=<f> --pathspec-file-nul` refuses the whole batch *up
    front* when any path has a local change, including an executable-bit change when
    `core.fileMode` is true. Nothing is staged or removed.
  - It is **not** atomic past that check. If a parent directory is unwritable, it exits 0
    with every deletion staged, but the file stays in the worktree.
  - Entries are still **pathspecs**. A literal `a*` also matches `abc`, unless the command
    runs as `git --literal-pathspecs`.
- **An undo that never overwrites.** Two plain Git commands undo the batch without the
  harness:
  - `git --literal-pathspecs restore --staged --source=<commit> --pathspec-from-file=<f>
    --pathspec-file-nul` puts the index entries back from the recorded commit;
  - `git checkout-index --stdin -z < <f>` writes back only files that are missing. It
    skips an existing file with "already exists, no checkout" and exits 1, so a file the
    adopter recreated or edited is never overwritten. It reads names literally.

  By contrast, `git restore --worktree` would overwrite a recreated file.
- **A deleted running script keeps running.** Bash reads the script through an open
  descriptor, and unlinking keeps the inode alive. A sourced library is read when it is
  sourced, not later.
- **Plans and locks.** `clean` owns plan removal under its own guards (`start.sh:307-405`).
  Locks are `mkdir` directories under `<common>/agentic-flow/locks/` and `worktree-locks/`.
- **Hook path.** `init` sets `core.hooksPath=scripts/git-hooks` only when it is unset
  (`git-guards.sh:11-26`). A hooks path pointing at a missing directory is harmless: Git
  finds no hooks there.
- **Kept files reference harness files.** The initialized `Makefile`, the CI template,
  `CLAUDE.md`, `AGENTS.md` and the agent hook settings call `scripts/…`, reference
  `METHODOLOGY.md`, or call `agentic-flow`. They are almost never pristine, so they are
  kept.
- **Shared Git state** under `<common>/agentic-flow/` holds caches, the ledger,
  decisions, findings and plan records. Salvage refs live under `refs/agentic-flow/`.
- **Stamps.**
  - Harness-owned: `.agentic-flow-version`, `-source`, `-source-applied`,
    `-candidate-version`, `-installation`, `-upstream`, `-scopes-excluded`,
    `-stack-candidate`, and the new `-ownership`.
  - Project-owned: `.agentic-flow-assurance`, `-assurance-audit`, `-roles`, `-stack`,
    `-review-policy`, `.agentic-flow/config`.
- **No `uninstall` exists**, and the command policy has no row for it.

## Proposed approach

### Option A — install-time ownership evidence and one reversible `git rm` (recommended)

**Ownership is recorded when the harness writes** (f-1). `.agentic-flow-ownership` is
written next to the upstream record on every apply, pending or not. It holds:

```
version=1
origin=export|upgrade          set once, when the record is first written
created=<sha>  <path>          the harness wrote this path when it did not exist
candidate=<sha>  <path>        a candidate the harness wrote (never a reused one)
```

- `origin=export`: the record was born with the install, so every path the harness
  created has a `created` row.
- `origin=upgrade`: the record was born on an existing install (a **legacy** install).
  Paths installed before then have no row, and their origin is unknown.

Rows carry forward while the path is an active manifest destination, or while the
candidate exists. A path the harness re-creates after the adopter deleted it gets a
`created` row.

**A path is removed only when all of these hold:**
- **Ownership:** it has a `created` row, or it is claimed (below). A candidate also
  qualifies through its own `candidate` row.
- **Pristine:**
  - for a payload file, the bytes match `accepted=` with no pending `offered=`;
  - for a candidate, the bytes match its row.
- **Tracked and unchanged in Git:** the worktree, the index and `HEAD` hold the same bytes
  *and* the same Git mode. The worktree's executable bit counts only when `core.fileMode`
  is true. This is exactly the condition under which the batched `git rm` cannot refuse.

These are kept and listed, with the reason:
- an untracked file that is otherwise removable, with an `rm -- <path>` command;
- a pristine created file whose index or `HEAD` differs (`uncommitted-change`). Apply
  refuses with `uncommitted-install` until the adopter commits or discards it;
- a file without ownership, an edited file, an edited, reused or unrecognized candidate,
  and a file whose mode alone changed.

**Claim for legacy installs** (`--claim-adoption`):
- It applies only when `origin=upgrade`, and only to paths with no `created` row that the
  adoption commit added. The adoption commit is the oldest commit adding
  `.agentic-flow-version`.
- Claimed paths still need `accepted=` and pristine bytes. Each is listed as `claimed`
  before the prompt.
- An install without an upstream record is told to run `agentic-flow upgrade` first.
  There is no fetch.

**Stamps and records.** Harness stamps and records are removed by the same rule:
tracked and unchanged since `HEAD`. Project-owned files are removed only with
`--remove-project-state`. Untracked ones are listed with `rm` commands.

**Apply is one Git operation, checked afterwards** (f-3). After a preflight that changes
nothing:
1. Compute the whole report.
2. Create this run's own files under `<common>/agentic-flow/`, with exclusive creation and
   no rewrites. `<id>` is a UTC timestamp plus the PID.
   - `uninstall-<id>.paths`: the NUL-separated removal list.
   - `uninstall-<id>.undo`: the exact undo text below, binding the top level, branch and
     `HEAD` commit of this checkout.

   Each run reports and uses only its own files, so concurrent runs can never swap lists.
3. Print the undo text, then run **one**
   `git --literal-pathspecs rm -q --pathspec-from-file=<paths> --pathspec-file-nul`.
4. **Verify the outcome.** For every planned path: no index entry
   (`git --literal-pathspecs ls-files` over the list) and no worktree entry (`lstat`).
   Report one of:
   - **complete**: every path is staged and gone. Print the precomputed report and exit 0.
   - **unchanged**: `git rm` refused and every path is still indexed and present. Exit 4
     with Git's message.
   - **incomplete**: anything else. Exit 4, list each incomplete path and its state, and
     print the undo text.

   Nothing in the tree is read after `git rm`, apart from these checks.

**The undo text** (also in `uninstall-<id>.undo`):
```
cd '<toplevel>' &&
test "$(git symbolic-ref -q HEAD)" = 'refs/heads/<branch>' &&
git --literal-pathspecs restore --staged --source=<commit> \
    --pathspec-from-file='<paths>' --pathspec-file-nul &&
git checkout-index --stdin -z < '<paths>'
```
- It refuses outside the recorded checkout and branch.
- Content comes from the recorded `<commit>`, so a moved `HEAD`, for example after the
  adopter committed the removal, does not change what is restored.
- It never overwrites a worktree file. Each "already exists, no checkout" line names a
  path the adopter recreated or edited. The report says to review those one by one with
  `git diff -- <path>` and `git show <commit>:<path>`.
- A staged edit to a listed path is replaced in the index by the recorded blob, but its
  worktree copy is kept. It then shows as an unstaged change, and nothing is lost.

Interruptions and concurrency:
- A later `uninstall` that finds staged deletions, all inside one existing
  `uninstall-*.paths`, refuses with `interrupted-uninstall` and prints that run's
  `.undo` file.
- Two uninstalls at once each write their own list. `git rm` serializes on `index.lock`,
  and the second run refuses on the staged changes.

**Everything else is reported, not changed:**
- untracked harness files;
- `core.hooksPath`, with `git config --local --unset core.hooksPath` when its local value
  is `scripts/git-hooks`;
- shared Git state, with `rm -rf` commands, flagging the ledger as the only copy of the
  plan journal;
- salvage refs, with `git update-ref -d` commands;
- the kept list, and every line in a kept file or `.github/workflows/*` that references a
  removed path or `agentic-flow`;
- the outside checklist: operator files, keys, labels, issues, rulesets, the CI workflow.

**Preflight refuses**, writing nothing, on:
- a harness root that is not the Git top level, or a run from a linked worktree;
- any staged change;
- any open plan record or linked worktree, listing `agentic-flow clean <id>` for each;
- any entry under the two lock roots (never cleared);
- a missing installation record;
- any `uncommitted-change`.

Apply recomputes the plan just before `git rm`. On a terminal, it refuses if the plan
differs from what the dry run showed.

### Option B — the approved draft 10 (roll-forward resume)

Draft 10 added a persisted plan and a copy of the CLI, a phased fence, a `flock` mutex,
writer registration on every CLI call, a state table for resume, reconciliation, and a
fetch of the installed revision. It handles interruption and concurrency with no human
step. Rejected by the owner's over-engineering review (2026-11-27): Git already rolls the
same states back with one command. The fence's reasons, shared-state purge and in-run
`clean`, were cut in rounds 4 and 5, and writer registration would have imposed a
permanent cost on every CLI call.

### Option C — managed-region markers in contracts

These would let uninstall strip only the harness's section from a hand-merged
`CLAUDE.md`. Deferred by the owner. The kept list and the reference report name the lines
to edit.

**Recommendation:** Option A. Every ambiguous case keeps the file. The one destructive
step is one Git operation, verified afterwards, and undone by a printed two-command undo
that never overwrites. The adopter reviews and commits.

## Interface (before the implementation)

```
.agentic-flow-ownership     (f-1; harness record; upstream-record limits and path checks;
                             never a payload destination)
  version=1
  origin=export|upgrade
  created=<sha256>  <path>
  candidate=<sha256>  <path>

<common>/agentic-flow/uninstall-<id>.paths  (f-3; this run's NUL-separated list; created once)
<common>/agentic-flow/uninstall-<id>.undo   (f-3; this run's exact undo text; created once)

agentic-flow uninstall [--yes] [--json] [--keep-docs] [--remove-project-state] [--claim-adoption]

  default   dry run: classify and print; write nothing. On a terminal, offer to apply.
  --yes     apply without prompting (required off a terminal)
  --json    emit the plan or the result as one JSON object
  --keep-docs              keep payload files under docs/ and the root METHODOLOGY.md / ADOPTION.md
  --remove-project-state   include tracked project-owned stamps and .agentic-flow/config
  --claim-adoption         legacy installs only: claim pristine paths the adoption commit added

  Report sections, in order:
    Refusals                        (only when any; exit 3)
    Will remove (staged by git rm)  <path>  (<why>)
    Kept — finish by hand           <path>  (<why>)   [rm -- <path> for untracked harness files]
    Still referencing removed files <file>:<line>: <ref>
    Git config and refs             <command>
    Shared Git state (not removed)  <dir>  <entries>  <size>  cache|record   rm -rf -- '<dir>'
    Outside the repository          <checklist line>
  After apply:
    Undo (printed before git rm; also in <common>/agentic-flow/uninstall-<id>.undo):
      <the undo text>
    Uninstall staged <n> deletions. It does not commit.
    Review the whole index before you commit:  git status ; git diff --cached

exit 0  dry run printed, or every deletion staged and verified
exit 2  usage
exit 3  refused by preflight; nothing changed
exit 4  git rm refused (unchanged) or did not complete (incomplete paths listed, undo printed)
```

```
{ "v": 1, "root": "<abs>", "version": "<installed>", "origin": "export|upgrade|none",
  "adoption_commit": "<sha|null>",
  "refusals": [ { "reason": "<reason>", "subject": "<text>", "command": "<text|null>" } ],
  "remove":   [ { "path": "<rel>", "kind": "payload|candidate|stamp|project",
                  "why": "created|claimed", "sha256": "<hex>", "mode": "100644|100755" } ],
  "kept":     [ { "path": "<rel>", "why": "<reason>", "command": "<text|null>" } ],
  "dangling_references": [ { "file": "<rel>", "line": n, "ref": "<text>" } ],
  "dangling_truncated": n,
  "git":      [ { "what": "core.hooksPath|salvage-ref", "detail": "<text>", "command": "<text>" } ],
  "git_state":[ { "dir": "<rel>", "class": "cache|record", "entries": n, "bytes": n, "command": "<text>" } ],
  "outside":  [ "<checklist line>" ],
  "outcome":  "complete|unchanged|incomplete",                       (apply only)
  "incomplete": [ { "path": "<rel>", "index": bool, "worktree": bool } ],
  "list": "<abs paths file>", "undo_file": "<abs>", "undo": "<text>",
  "staged":   [ "<rel>" ] }                                          (apply only)
```

Kept reasons: `edited`, `mode-changed`, `no-ownership`, `pending-offer`, `untracked`,
`uncommitted-change`, `keep-docs`, `project-state-kept`, `legacy-candidate`,
`edited-candidate`, `unrecognized-candidate`.

Refusal reasons: `not-git-toplevel`, `linked-worktree`, `staged-changes`,
`interrupted-uninstall`, `plan-open`, `lock-present`, `no-installation`,
`uncommitted-install`.

## Threat model (one paragraph)

The untrusted actors are agent stations and anyone who can write files in the tree.
Uninstall deletes the secret scanner and the command-policy deny rules, so **an agent that
can run it can drop the safety floor**. f-2 adds deny rows for every spelling the policy
covers, and the human runs it, as with `ship` and `hold clear`.

A planted ownership or upstream record can only cause deletion of a tracked file whose
bytes equal a hash the attacker chose. The attacker could already delete that file, and
the undo brings it back. Record paths go through `payload_safe_path`, symlinks are never
followed, and every Git call over the list uses literal pathspecs, so a file name can
never match a neighbor.

Uninstall never commits, so the adopter's hooks and review see the result.

**Accepted risk:** another harness process writing during the seconds apply runs is not
fenced. Locks are refused in preflight, `git rm` refuses on any change to a planned path,
and any other write shows in `git status`. `ADOPTION.md` says to run nothing else during
uninstall.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---------------|-----------|-----------------------|--------------------|
| `git rm` (one batch) | n/a | Refuses → verified `unchanged`, exit 4 | Exits 0 but an unlink failed, or the run is interrupted → verified `incomplete`, exit 4 with the paths and the undo text; the next run refuses with `interrupted-uninstall` |
| The undo (run by the adopter) | n/a | Wrong checkout or branch → its `test` guard stops it before any change | Recreated or edited paths are skipped by `checkout-index` and named for individual review |
| `git` reads (status, ls-files, config, log) | n/a | Unparseable → refuse, nothing changed | n/a |

Bounds: the record limits (2,000 paths, 4,100-byte lines) apply to the ownership record
and the removal list. The shared-state counts stop at 100,000 entries per directory. The
reference scan skips files over 1 MiB and binary files, and reports at most 20 lines per
file and 200 in total. There are no network calls.

## Out of scope / What NOT to build in this pass

- Committing, purging shared Git state, running `clean`, and removing anything outside the
  repository (owner decisions).
- Removing untracked files, changing Git config, or deleting refs. All of these are
  reported with commands.
- Resume, a fence, writer registration, or a mutex. Git's rollback and the preflight
  replace them.
- Fetching an older revision for pre-0.20 installs. Upgrade first.
- Editing kept files, managed-region markers (Option C), and monorepo installs whose
  harness root is not the Git top level (refused).

## Open questions

All owner decisions from drafts 1–10 still hold: acceptance; legacy ownership by explicit
claim; stage-only; report-only shared state; `clean` first; project state kept by
default. Draft 11 asks for one more:
- **Trade-offs of the reshape.**
  - An interrupted run needs the printed `git restore` instead of `--resume`.
  - A concurrent harness writer is not fenced (accepted risk above).
  - Untracked harness files and `core.hooksPath` need the printed commands.

  *Recommended: accept*, by approving this draft.

## Revision history

Kept in Part A so that it does not count against Part B's word cap.

- **Draft 12 (2026-11-27)** answers the review of draft 11, keeping its design:
  1. Every Git call over the list uses `--literal-pathspecs` (scenario 7, wildcard name).
  2. Success is reported only after checking each path against the index and the
     worktree. An unlink failure is reported as `incomplete` (scenario 7, unwritable
     parent).
  3. The undo is two plain Git commands, bound to the recorded checkout, branch and
     commit. It restores the index from that commit, and uses `checkout-index` without
     `-f`, which never overwrites a recreated file and names it for review.
  4. Each run writes its own `uninstall-<id>.paths` and `.undo` with exclusive creation.
     There is no shared file and no new lock.
- **Draft 11 (2026-11-27):** a three-step reshape, after the owner's over-engineering
  analysis.
  - Removal is limited to tracked files, through one batched `git rm` undone by a printed
    `git restore`.
  - Dropped: the persisted plan, the CLI copy, the fence phases, the mutex, writer
    registration, resume, reconciliation, the state table, the hook-path marker and
    automatic unset, and f-5's fetch of older revisions.
  - The ownership record is simplified to `origin` plus `created` and `candidate` rows.
  - The legacy claim is folded into f-2.
- **Drafts 3–10:** eight review rounds. They added ownership evidence (kept), the fence,
  resume and their refinements (dropped in draft 11). Owner decisions narrowed the scope
  to stage-only, report-only state and `clean` first.
- **Drafts 1–2:** first draft; the kept list and the reference scan.

---

# Part B — Implementation Brief

## Acceptance scenarios

1. **Untracked identical file at adoption.** In an `origin=export` install, an adopter
   `docs/done/.gitkeep` was untracked when export ran, then committed with the stamp. It
   has no `created` row, so it is kept as `no-ownership`. `--claim-adoption` does not
   apply to `origin=export` installs.
2. **Upgrade meets an adopter file.** An adopter file sits where a later upgrade first
   ships identical bytes. It gets no `created` row and is kept.
3. **Candidates.**
   - A tracked candidate the harness wrote, unchanged, is removed.
   - The same file untracked is kept with an `rm` command.
   - An edited candidate is kept as `edited-candidate`.
   - A reused, adopter-supplied candidate is kept as `legacy-candidate`.
   - A candidate written by a pending upgrade is found through its row.
4. **Pristine and edited.**
   - A tracked `created` file whose bytes match `accepted=` is staged for deletion.
   - An edited file, a hand-merged `CLAUDE.md`, and a file whose mode alone changed are
     kept.
   - A stamp whose mode alone changed is also kept.
5. **Preflight refusals.** Each of these exits 3 with the tree, index, Git config, refs
   and common dir byte-identical:
   - an open plan (listing `agentic-flow clean <id>`);
   - a lock directory (left in place);
   - a staged change;
   - an uncommitted upgrade of a created file.
6. **Install → uninstall.**
   - Export into an empty Git repository, commit, then run `uninstall --yes`.
   - `git diff --cached --name-status` shows only `D` rows, exactly the `remove` list.
   - The command completes although `scripts/agentic-flow` was among them.
   - `core.hooksPath` is unchanged and reported with its command.
   - After `git commit`, the tree matches the pre-export commit, apart from
     `docs/README.md` and the kept project state.
7. **The batch, its check, and the undo.**
   - **Dirty file:** a test pause between the final recompute and `git rm` edits one
     planned file. `git rm` refuses, the outcome is `unchanged`, and the run exits 4.
   - **Unlink failure:** the test makes a planned file's parent directory unwritable
     (skipped when running as root). `git rm` exits 0, but the outcome is `incomplete`
     and names that path, staged but still present. The run exits 4, prints the undo
     text, and prints no success summary.
   - **Wildcard name:** a removable tracked file named `a*` sits beside a kept `abc`.
     Only `a*` is staged, and undo restores only `a*`.
   - **Undo:**
     - After a complete apply, running the printed undo restores the tree and index
       byte-identical to before.
     - With one listed path recreated with new content first, undo restores the others,
       leaves that file's content intact, and names it ("already exists, no checkout").
     - Run on another branch, its guard stops it with no change.
     - After the adopter commits the removal, undo still restores the recorded content.
   - **Interrupted:** after an `incomplete` apply, a second `uninstall` refuses with
     `interrupted-uninstall` and prints that run's `.undo` file.
   - **Concurrent:** two applies started together write different `uninstall-<id>.paths`
     files. Each report names its own file, and exactly one stages deletions.
8. **Legacy claim.** An `origin=upgrade` install, upgraded and merged.
   - `--claim-adoption` stages only pristine paths that the adoption commit added, each
     listed as `claimed`.
   - A path first shipped after adoption stays.
   - An install without an upstream record is told to upgrade first, and nothing is
     claimed.
9. **Kept list and references.** A kept `Makefile` calling `scripts/self-test.sh`, and a
   `.github/workflows/ci.yml` calling `scripts/doctor.sh`, are listed with line numbers,
   under a warning that `make check` and CI will fail. The shared-state section lists
   `ledger` as a record, with its command.
10. **Policy.** `agentic-flow uninstall` is blocked for agents in all three runtimes.

## Invariants

- A dry run writes nothing.
- Apply's only changes are this run's two files in the common dir and one `git rm`. It
  never commits, never changes Git config or refs, and never removes an untracked file.
- Every Git call over the list uses literal pathspecs.
- Success is reported only after verification: every listed path has no index entry and
  no worktree entry. The staged set is then exactly the `remove` list. Every path in it
  was tracked, owned, and identical in bytes and mode across the worktree, the index and
  `HEAD`.
- The printed undo is bound to the recorded checkout, branch and commit, and never
  overwrites a worktree file.
- No flag overrides a preflight refusal. No lock is cleared. There are no network calls.
- Every kept path, and every shared-state directory, is printed with its reason or
  command.
- Nothing in the tree is read after `git rm`. Bash 3.2; no new required tool.

```agentic-flow-plan
format: 2
id: uninstall
profile: strict
tracking: Plan: Uninstall — remove only what the harness owns
branch: configurability-phase-3
steps: f-1 f-2 f-3
policy: review.max_bounces=2 review.block_at=medium andon.station-infrastructure=hold
```

## Branch
Base: `main`. One branch and one PR for the whole brief: `configurability-phase-3`. Each
step lands as its own commit on that branch and closes its issue with `Fixes #N`.

## Definition of done (whole brief)
- Every step's DoD is met, and `make check` and `make test` are green.
- Scenarios 1–10 are covered by named tests.
- `ADOPTION.md` has a *Removing the harness* section: run `clean` first; dry run; apply;
  review and commit; the undo command; the printed follow-up commands; the accepted risk.
- `CHANGELOG.md` has an entry.
- A manual run in a scratch export shows the dry run, then `--yes`, then a `git status`
  with only staged deletions.

## Verification commands
```bash
make check                  # per step
make test-one F=upgrade     # uninstall tests, timed as upgrade:uninstall
make test-one F=export      # f-1: ownership rows on export
make test-one F=hooks       # f-2: command-policy rows
make test                   # end of brief
```

---

## F-1 — Record which paths the harness created
**Why first:** f-2 and f-3 rely on this evidence, and the install records are the hardest
part to change later.

**Approach:**
- In `payload-apply.sh`, load, carry forward and write `.agentic-flow-ownership` next to
  the upstream record, on every apply, pending or not.
  - Reuse the upstream parser's limits and its NUL, UTF-8 and path checks.
  - Reject unknown keys, and write atomically.
- Set `origin` only when the record is first written:
  - `export` when there was no previous installation record;
  - `upgrade` otherwise.
- Add a `created` row only for the `create` classification. Add a `candidate` row only
  when the harness writes a candidate (`PAYLOAD_RESULT_CANDIDATE_ACTION=candidate`), never
  for a reused one. `upgrade --merged` drops the rows of the candidates it removes.
- Forbid the record as a payload destination.

**Test:** scenarios 1, 2 and 3 (reused, pending) as records, plus:
- an `export --force` over an existing file writes no `created` row;
- an upgrade of a record-less install sets `origin=upgrade` with no rows for existing
  paths;
- a re-created path gets a `created` row;
- a malformed record is refused before any write.

**DoD:** every export and upgrade leaves a complete ownership record with the right
`origin`.
**Verify:** `make test-one F=export && make test-one F=upgrade`
**Risks:**
- Releases that write the record must still read older installs without it.
- Fixture counts change; measure them and update `config/test-budgets.tsv`.
**Red-first:** none
**Commit:** `Record which payload paths the harness created`

---

## F-2 — Classify ownership and report the removal as a dry run
**Why second:** it produces the exact removal list that f-3 stages. Being read-only, it is
useful on its own.

**Approach:**
- Add a dispatcher entry `uninstall` (dry run only in this step) and
  `scripts/lib/uninstall.sh`, which sources `payload-apply.sh` itself.
- Classify payload paths (the union of installation and ownership rows), candidates,
  stamps and project state by the Part A rule.
  - For each tracked path, compare bytes and Git mode across the worktree, the index and
    `HEAD`.
  - Candidates come from `candidate` rows and from the three library names next to
    installed paths. Any other `.agentic-new*` file is `unrecognized-candidate`.
- Implement `--claim-adoption`, `--keep-docs` and `--remove-project-state`.
- Run every preflight check and report each refusal with its command.
- Build the kept list, the reference scan (within the bounds), the Git config and refs
  section, the shared-state report and the outside checklist. Text and `--json` render
  one object.
- Add the command-policy deny rows ("the human uninstalls"), regenerate the native rules,
  and update `docs/reference/command-policy-coverage.md`.
- Add `upgrade:uninstall` to the wall-ceiling keys.

**Test:** scenarios 1–5, 8, 9 and 10 as dry-run output. Also: `not-git-toplevel`,
`linked-worktree`, `no-installation`, a symlinked payload path, reference-scan
truncation, and `--json` against the shape.

**DoD:** `agentic-flow uninstall` prints a correct plan and every follow-up command, and
writes nothing. Agents cannot run it.
**Verify:** `make test-one F=upgrade && make test-one F=hooks`
**Risks:**
- Plan records are owned by `start.sh`. Read them through a read-only helper there, not
  a second parser.
**Red-first:** `upgrade:uninstall` — scripts/tests/upgrade.sh scripts/self-test.sh
**Commit:** `Add a dry-run uninstall that classifies what the harness owns`

---

## F-3 — Stage the verified removal in one checked, reversible `git rm`
**Why last:** it adds the only destructive step to f-2's plan.

**Approach:**
- `--yes`, or a `y` at the terminal prompt:
  1. Rerun preflight and recompute the plan. On a terminal, refuse if it differs from
     what was shown.
  2. Render the full report into memory.
  3. Create this run's `uninstall-<id>.paths` and `.undo` with exclusive creation, then
     print the undo text.
  4. Run one `git --literal-pathspecs rm -q --pathspec-from-file=<paths>
     --pathspec-file-nul`.
  5. Verify every listed path (no index entry, no `lstat` entry). Report `complete`,
     `unchanged` or `incomplete` as Part A describes.
- Preflight treats staged deletions that all fall inside one existing
  `uninstall-*.paths` as `interrupted-uninstall`, and prints that run's `.undo` file.
- A test-only pause point (`AGENTIC_UNINSTALL_TESTING=1`) sits between steps 3 and 4.

**Test:** scenarios 4 and 5 (apply half), 6 and 7. Also: an interactive "no" writes
nothing; a `remove` list that is empty exits 0, writes no files and runs no `git rm`.

**DoD:**
- Apply stages exactly the `remove` list in one Git operation, and reports success only
  after verifying it.
- Incomplete or refused batches exit 4 with what happened.
- The undo is bound to its checkout, never overwrites, and names the paths to review.
- The run completes even though the CLI's own files are among the deletions.
**Verify:** `make test-one F=upgrade`
**Risks:**
- After `git rm`, nothing may source or read a tree file. Load every library and render
  the report first.
- Never use `git restore --worktree` in the undo, because it overwrites recreated files.
  `checkout-index` without `-f` is the non-overwriting half.
- The undo text never names individual paths; they stay in the NUL list file. Quote only
  the top level, the branch and the list path, with `printf %q`, because a checkout path
  may contain quotes or spaces.
**Red-first:** `upgrade:uninstall` — scripts/tests/upgrade.sh scripts/self-test.sh
**Commit:** `Stage uninstall as one reversible git rm`

---

## Status / Implementation status
<!-- Finalized by the closer before the last repository commit. -->
- **Evidence schema:** v2
- **Tracking issue:** url=https://github.com/wabkebab/agentic-flow/issues/225
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
