<!-- TRIAGE (first pass · 2026-11-27) -->
> **Type:** Feature · **Status:** ✅ Done
> **Assurance:** Strict (deletes adopter files, changes the install records, and adds a command-policy floor row; project baseline is Standard)
> Phase 3 of [harness configurability](product-harness-configurability.md) (area J): `agentic-flow uninstall`, which removes only what the harness recorded creating and still holds unchanged. A single batched `git rm` stages those deletions and verifies them, and a rerunnable receipt script undoes them without touching adopter content. Everything else is reported with exact commands.
> Draft 15 (2026-11-27), written against `0.21.0` (`3757627`). Draft 15 stops suggesting `rm` for a file left after apply; such a file is reported for inspection. It keeps draft 11's three-step reshape: one batched `git rm` of tracked files, with literal pathspecs and a receipt per run. Verification claims only the listed deletions against the recorded `HEAD`. The receipt's undo fills in only what is missing, can be rerun after a partial undo or an incomplete apply, and never touches adopter content. See *Revision history*. The owner decisions all still hold. Next: owner re-approval, then re-run `plan-to-issues`, which updates #226–#228 and closes #229 and #230.

# Feature — Uninstall: remove only what the harness owns

## Tracker
- [x] f-1 — #232; approved=77aec3336c15a44c2c3bee02b57ee79dbb4b18a3; submissions=77aec3336c15a44c2c3bee02b57ee79dbb4b18a3
- [x] f-2 — #233; approved=14c13ad00091a86a1062ce45f00fa6ae283f3025; submissions=14c13ad00091a86a1062ce45f00fa6ae283f3025
- [x] f-3 — #234; approved=0af31a364170da695561b4f92a3d50816fe1b3ab; submissions=0af31a364170da695561b4f92a3d50816fe1b3ab,8795a61e5f48d3cb2e4fd8498979859d60ebd1e9
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
- **Undo building blocks.** Checked in scratch on 2026-11-27:
  - `git restore --staged` would overwrite a staged edit at a listed path, which the
    reviewer reproduced. `git restore --worktree` would overwrite a recreated file.
  - `git update-index -z --index-info` puts back exact `<mode> <blob>` entries recorded
    before the removal, executable bit included.
  - `git checkout-index --stdin -z` then writes those files. It reads names literally.
  - **`git ls-files` does not accept `--pathspec-from-file`.** A read-only check over
    the list passes the paths as arguments instead:
    `xargs -0 git --literal-pathspecs ls-files -z -- < <list>`.
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
2. Create this run's **receipt** under `<common>/agentic-flow/`. Each file is created
   exclusively and never rewritten. `<id>` is a UTC timestamp plus the PID.
   - `uninstall-<id>.paths`: the NUL-separated removal list.
   - `uninstall-<id>.index`: the `<mode> <blob>\t<path>` index entries of those paths,
     NUL-separated, in `update-index -z --index-info` format.
   - `uninstall-<id>.undo`: the undo script below.

   Each run reports and uses only its own receipt, so concurrent runs can never swap lists.
3. Print the receipt's undo command, then run **one**
   `git --literal-pathspecs rm -q --pathspec-from-file=<paths> --pathspec-file-nul`.
4. **Verify the outcome, and claim no more than was checked.**
   - `HEAD` must still be the recorded commit on the recorded branch. Otherwise the
     outcome is `head-moved`, exit 4.
   - For every listed path, check that it has no index entry
     (`xargs -0 git --literal-pathspecs ls-files -z --`) and no worktree entry (`lstat`).

   Report one of:
   - **complete**: every listed path is a staged deletion against the recorded commit.
     Exit 0, and print "verified N uninstall deletions against `<commit>`". The report
     says it did not review anything else in the index, and points to `git diff --cached`.
   - **unchanged**: `git rm` refused, and every path is still indexed and present. Exit 4
     with Git's message.
   - **incomplete**: anything else. Exit 4, list each path's state, and point to the
     receipt. A path that is out of the index but still in the worktree is reported for
     what the check can show:
     - **matches the recorded bytes and mode**: Git probably could not unlink it. Running
       the receipt's undo restores its index entry and leaves the file as it is;
     - **different content or mode**: it may have been recreated after `git rm`. Inspect
       it. The undo will refuse to touch it.

     Uninstall never suggests deleting a leftover file. Removing one is the adopter's
     decision, made after inspecting it.

   Nothing in the tree is read after `git rm`, apart from these checks.

**The undo is a receipt script that only fills in what is missing, and can be rerun.**
Run it with `bash <common>/agentic-flow/uninstall-<id>.undo`. Like the rest of the
receipt, it uses only Git, so it works after the harness is gone. It:
1. `cd`s to the recorded top level.
2. Requires the recorded branch, with `HEAD` at the recorded commit. If either moved, it
   restores nothing. It says that restoring after a commit or branch change is a manual
   operation, for example `git checkout <commit> -- <path>`, and names the commit.
3. Classifies every listed path against its recorded `<mode> <blob>`:

   | Index entry | Worktree file | Action |
   |---|---|---|
   | none | none | restore both |
   | none | recorded bytes and mode | restore the index entry only (Git could not unlink it) |
   | recorded | none | restore the file only (a partly finished undo) |
   | recorded | recorded bytes and mode | already restored |
   | anything else | anything else | the adopter changed it: list it, restore **nothing**, exit 3 |

   The file's mode counts only when `core.fileMode` is true.
4. Runs one `git update-index -z --index-info` over the entries it needs, then
   `git checkout-index --stdin -z` (no `-f`) over the files it needs.
5. Classifies every path again. If any is not fully restored, it lists those paths as
   **partial**, exits 4, and says "fix the cause, then run this undo again". The rerun
   picks up exactly where this one stopped.

**Undo is not atomic.** If `checkout-index` fails on one file, for example in an
unwritable directory, the index entries are already back. The undo says so, names what
is left, and a rerun or `git checkout-index -- <path>` finishes it. It never overwrites a
staged entry or a worktree file. The same script also rolls back an `incomplete` apply,
because a file Git failed to unlink is in the "none / recorded" state.

**No inference about interrupted runs.** A later `uninstall` that finds staged changes
refuses with the ordinary `staged-changes`. Its message says: if this is an interrupted
uninstall, run the undo command that apply printed. It lists the receipt files present,
with their times, as information only. It never matches staged paths to a receipt.

Two uninstalls at once each write their own receipt. `git rm` serializes on `index.lock`,
and the second refuses on the staged changes.

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
step is one Git operation, verified afterwards. A receipt script undoes it by filling in
only what is missing, can be rerun, and never touches adopter content. The adopter
reviews and commits.

## Interface (before the implementation)

```
.agentic-flow-ownership     (f-1; harness record; upstream-record limits and path checks;
                             never a payload destination)
  version=1
  origin=export|upgrade
  created=<sha256>  <path>
  candidate=<sha256>  <path>

<common>/agentic-flow/uninstall-<id>.paths  (f-3 receipt; NUL-separated list; created once)
<common>/agentic-flow/uninstall-<id>.index  (f-3 receipt; "<mode> <blob>\t<path>" NUL records)
<common>/agentic-flow/uninstall-<id>.undo   (f-3 receipt; rerunnable undo script; bash, Git only;
                                             exit 0 restored, 3 refused (nothing changed), 4 partial)

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
    Undo now, before you change anything:  bash '<common>/agentic-flow/uninstall-<id>.undo'
                                           (printed before git rm)
    Verified <n> uninstall deletions against <commit>. Uninstall does not commit, and did
    not review anything else in the index:  git status ; git diff --cached

exit 0  dry run printed, or every listed deletion verified against the recorded commit
exit 2  usage
exit 3  refused by preflight; nothing changed
exit 4  git rm refused (unchanged), did not complete (incomplete), or HEAD moved (head-moved)
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
  "outcome":  "complete|unchanged|incomplete|head-moved",            (apply only)
  "commit":   "<recorded HEAD sha>",
  "incomplete": [ { "path": "<rel>", "index": bool, "worktree": bool } ],
  "receipt":  { "paths": "<abs>", "index": "<abs>", "undo": "<abs>" },
  "verified_deletions": [ "<rel>" ] }        (apply only; claims nothing about other staged paths)
```

Kept reasons: `edited`, `mode-changed`, `no-ownership`, `pending-offer`, `untracked`,
`uncommitted-change`, `keep-docs`, `project-state-kept`, `legacy-candidate`,
`edited-candidate`, `unrecognized-candidate`.

Refusal reasons: `not-git-toplevel`, `linked-worktree`, `staged-changes` (lists any
receipts present, without matching them), `plan-open`, `lock-present`, `no-installation`,
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
| `git rm` (one batch) | n/a | Refuses → verified `unchanged`, exit 4 | Exits 0 but an unlink failed, or the run is interrupted → verified `incomplete`, exit 4 with each path's state. A leftover that matches the receipt can be rolled back with its undo; one with other content is to be inspected. No `rm` is ever suggested. The next run refuses with `staged-changes` |
| `HEAD` moves during apply | n/a | n/a | → `head-moved`, exit 4. Nothing is claimed as verified |
| The undo script (run by the adopter) | n/a | Moved checkout, branch or `HEAD`, or adopter content at a listed path → restores nothing, exit 3, names the paths or the manual route | `checkout-index` fails on some file → `partial`, exit 4, listing what is left; a rerun finishes it |
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

- **Draft 15 (2026-11-27)** answers the review of draft 14. An `incomplete` apply no
  longer suggests `rm -- <path>` for a leftover file, because the file may have been
  recreated with new content after `git rm`. A leftover is reported as matching the
  receipt (undo restores its index entry) or as different content (inspect it; undo
  refuses). Scenario 7 recreates a file between `git rm` and the check.
- **Draft 14 (2026-11-27)** answers the review of draft 13, keeping the one-batch apply:
  1. The undo is no longer all-or-nothing. It classifies each listed path against the
     receipt, fills in only missing index entries and files, re-checks, and reports a
     `partial` undo that a rerun finishes. It still restores nothing when any listed path
     holds adopter content.
  2. An `incomplete` apply now has working routes: finish by hand, or run the same undo,
     which restores only the index entry of a file Git failed to unlink. The test follows
     the route and checks that the file is preserved.
  3. Restoration is asserted with `git ls-files --stage`, file contents and modes, and
     the staged diff, never raw index bytes. Preflight's "unchanged" uses the same
     definition.
  - All of this was checked in scratch with an unwritable directory, both during the
    undo and during the apply.
- **Draft 13 (2026-11-27)** answers the review of draft 12:
  1. The undo is a receipt script that checks first, then restores everything or
     nothing. It requires the recorded `HEAD`, refuses if any listed path is staged or
     present, then restores the recorded index entries (`update-index --index-info`) and
     the files (`checkout-index`). Restoring after a commit is a manual operation.
     Checked in scratch, including distinct staged and unstaged edits.
  2. There is no receipt matching. Staged changes get the ordinary `staged-changes`
     refusal, which points to the undo the apply printed.
  3. Verification checks that `HEAD` is unchanged (otherwise `head-moved`) and claims only
     the listed deletions.
  - The scratch check also showed that `git ls-files` does not accept
    `--pathspec-from-file`, which draft 12's verification relied on. Checks over the list
    now use `xargs -0 git --literal-pathspecs ls-files -z --`.
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
5. **Preflight refusals.** Each of these exits 3 with the Git state unchanged. That means
   the same `git ls-files --stage`, the same staged diff, the same worktree contents and
   modes, Git config and refs, and an unchanged common dir. Raw index bytes are not
   compared, because Git may rewrite stat data:
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
     and names that path, staged but still present. The run exits 4, points to the
     receipt, and prints no success summary.
     - The test then follows the printed rollback: it restores write access and runs the
       receipt's undo.
     - The file Git failed to remove is preserved, with the same bytes and mode, and only
       its index entry is restored.
     - Every path's Git entry, contents and mode match the pre-apply state.
     - The output contains no `rm` command for the leftover path.
   - **Recreated between `git rm` and the check:** a test pause after `git rm` writes
     new content at one removed path. The outcome is `incomplete`, and that path is
     reported as "different content: inspect it", with no `rm` command. The receipt's
     undo then exits 3 and restores nothing, and the new content survives unchanged.
   - **Wildcard name:** a removable tracked file named `a*` sits beside a kept `abc`.
     Only `a*` is staged, and undo restores only `a*`.
   - **Scoped verification:**
     - A test pause between `git rm` and the final check makes a commit. The outcome is
       `head-moved`, exit 4, and nothing is claimed as verified.
     - The same pause instead stages an unrelated edit. The outcome is `complete`, and
       `verified_deletions` lists only the uninstall paths. The report says the rest of
       the index was not reviewed.
   - **Undo.** "Restored" means three things, never raw index bytes:
     `git ls-files --stage` equals its pre-apply output; every listed file has its
     pre-apply contents and mode; and `git diff --cached` is empty.
     - After a complete apply, `bash <receipt>.undo` exits 0, and everything is restored.
     - **Partial undo:** a listed file's directory is recreated unwritable before the
       undo. Undo exits 4 and lists that path as index restored, file missing. After
       write access is restored, a rerun exits 0, and everything is restored.
     - **Distinct staged and unstaged edits:** a listed path gets one edit staged and a
       different edit in the worktree. Undo exits 3, restores nothing at all, and lists
       that path. Both edits survive, the staged blob and the worktree bytes unchanged.
     - A listed path recreated with other content, unstaged, also makes undo exit 3
       without restoring anything.
     - After the adopter commits the removal, or on another branch, undo restores nothing
       and names the manual route from the recorded commit.
   - **Interrupted:** after an `incomplete` apply, a second `uninstall` refuses with
     plain `staged-changes`. It lists the receipts present without choosing one, and
     tells the adopter to run the undo their apply printed.
   - **Concurrent:** two applies started together write different receipts. Each report
     names its own, and exactly one stages deletions.
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
- Apply's only changes are this run's receipt in the common dir and one `git rm`. It
  never commits, never changes Git config or refs, and never removes an untracked file.
- Every Git call over the list uses literal pathspecs.
- Success is reported only after verifying two things: `HEAD` is still the recorded
  commit, and every listed path has no index entry and no worktree entry. The claim
  covers exactly those deletions, never the rest of the index. Every listed path was
  tracked, owned, and identical in bytes and mode across the worktree, the index and
  `HEAD`.
- The undo is bound to the recorded checkout, branch and `HEAD`. It never overwrites a
  staged entry or a worktree file, and restores nothing if any listed path holds
  adopter content. It is not atomic: a partial undo is reported, and rerunning it
  finishes the job.
- Uninstall never infers which run left staged changes.
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
  3. Create this run's receipt (`.paths`, `.index`, `.undo`) with exclusive creation.
     Capture `.index` from the index before `git rm`. Generate `.undo` from one fixed
     template implementing the Part A state table and the final re-check, then print its
     command.
  4. Run one `git --literal-pathspecs rm -q --pathspec-from-file=<paths>
     --pathspec-file-nul`.
  5. Check that `HEAD` is still the recorded commit, then check every listed path with
     `xargs -0 git --literal-pathspecs ls-files -z --` and `lstat`. Report `complete`,
     `unchanged`, `incomplete` or `head-moved`, as Part A describes.
- Preflight's `staged-changes` refusal lists any receipts present, as information only.
- Test-only pause points (`AGENTIC_UNINSTALL_TESTING=1`) sit before `git rm` and before
  the final check.

**Test:** scenarios 4 and 5 (apply half), 6 and 7. Also: an interactive "no" writes
nothing; a `remove` list that is empty exits 0, writes no files and runs no `git rm`.

**DoD:** apply removes the `remove` list in one Git operation. It reports success only
after verifying `HEAD` and every listed path, and claims nothing beyond those paths.
Refused, incomplete or moved runs exit 4 with what happened, and a route that works. The
receipt's undo fills in only missing entries and files, refuses on adopter content or a
moved `HEAD`, reports a partial undo, and finishes on a rerun. The run completes even
though the CLI's own files are among the deletions.
**Verify:** `make test-one F=upgrade`
**Risks:**
- After `git rm`, nothing may source or read a tree file. Load every library and render
  the report first.
- Never use `git restore` in the undo. `--staged` overwrites staged edits, and
  `--worktree` overwrites recreated files.
- `git ls-files` does not accept `--pathspec-from-file`. Use `xargs -0 … --` with
  `--literal-pathspecs`.
- Tests compare `git ls-files --stage`, file contents and modes, and the staged diff.
  They never compare raw index bytes.
- The undo script never names individual paths; they stay in the NUL receipt files. Quote
  only the top level, the branch, the commit and the receipt paths, with `printf %q`.
**Red-first:** `upgrade:uninstall` — scripts/tests/upgrade.sh scripts/self-test.sh
**Commit:** `Stage uninstall as one reversible git rm`

---

## Status / Implementation status
<!-- Finalized by the closer before the last repository commit. -->
- **Evidence schema:** v2
- **Tracking issue:** url=https://github.com/wabkebab/agentic-flow/issues/231
- **Approval:** status=approved; by=wabkebab; at=2026-11-27; rev=57b6138ccc07b2c87462284f7690c157976a5d3d
- **Implementation head:** source=pr-head
- **Implementation PR:** source=final-approval
- **Verification evidence:** source=final-approval-run
- **Review verdict:** source=close-out-attestation
- **Memory:** status=n/a
- Close-out: `ship` finalizes Status and Tracker, sets TRIAGE to Done, and commits this
  document's move and the updated index before the first push. It opens the PR and
  waits for CI. The reviewer runs `final-approve` to record the PR, head, and run attempt
  on the tracking issue. `ship` verifies that evidence, closes the issue, and runs
  the pre-merge check before the human merges. If a closer command is unavailable,
  commit the staged close-out and rerun `ship`.
