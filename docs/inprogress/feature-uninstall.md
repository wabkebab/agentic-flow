<!-- TRIAGE (first pass · 2026-11-27) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict (deletes adopter files, changes the install records, the controller lock and the hook setup, and adds a command-policy floor row; project baseline is Standard)
> Phase 3 of [harness configurability](product-harness-configurability.md) (area J): `agentic-flow uninstall`, which removes only what the harness has recorded evidence of creating, runs behind a fence that excludes controllers and plan operations, and can resume after an interruption. Kept files are listed on stdout.
> Draft 3 (2026-11-27), written against `0.21.0` (`3757627`). It answers the first review: ownership comes from install-time evidence, not history; resumable apply; a shared fence; candidate evidence; and hook-path ownership. See *Revision history*. Next: owner review. The *Uninstall* and *Legacy ownership* decisions gate approval.

# Feature — Uninstall: remove only what the harness owns

## Tracker
- [ ] f-1 — Record ownership evidence when the harness writes a path — open
- [ ] f-2 — Classify ownership and report the removal as a dry run — open
- [ ] f-3 — Fence uninstall against controllers and plan operations — open
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

Rows carry forward while the path stays installed. A row changes only when the harness
re-creates a path the adopter deleted, which makes it `created`. Rows for paths no longer
installed are dropped.

**A payload file is removed only when all of these hold:**
- it has a `created` row;
- it has an `accepted=` hash with no pending `offered=`;
- its current bytes match that `accepted=` hash.

`preexisting`, `inherited` and missing rows are kept. f-5 lets the owner claim `inherited`
and legacy paths explicitly.

**A candidate is removed only when its bytes match its `candidate` row.** A legacy
candidate with no row is removed only when its bytes match the base path's `offered=`.
Edited and unrecognized candidates are kept and listed.

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

**A fence makes apply exclusive** (f-3). Uninstall creates `<common>/agentic-flow/uninstall/`
with `mkdir`, then scans for locks. Every lock-holding operation checks for the fence after
it acquires its own lock:
- the controller lock, including recovery claims;
- the handoff lock;
- the worktree lock used by `start` and `clean`.

Each side writes its own marker before it reads the other's, so they cannot both proceed.
Uninstall refuses when any lock entry exists. It never clears a lock, and it reports each
lock as `live`, `stale-local` or `unresolved`: no owner yet, another host, or unreadable.
The dispatcher also refuses every other subcommand, except `uninstall`, `--help` and
`--version`, while the fence exists. That covers lockless writers such as `verify-step`.
Uninstall also refuses when a linked worktree exists that is not a plan worktree it will
clean. After `clean`, only the main checkout's fence-aware scripts remain.

**Apply runs from a persisted plan and can resume** (f-4). The fence directory holds:
- `owner`: nonce, pid, process start and host;
- `plan.json`: the full classification, with each planned removal's expected hash and
  whether it is tracked;
- `bin/`: a copy of the CLI and its libraries;
- `progress`: an append-only list of completed actions.

`plan.json` and `bin/` are written before the first destructive write. A retry runs
`<common>/agentic-flow/uninstall/bin/agentic-flow uninstall --resume`. Uninstall prints
this command first, and `scripts/agentic-flow uninstall` redirects to it while the fence
exists.

A resume:
- claims the fence when the previous owner is dead on this host, and refuses otherwise;
- accepts staged changes only when every one is a deletion of a tracked path in
  `plan.json`;
- does not reclassify. Each remaining action is idempotent against the plan. A planned
  file that is already absent counts as done, after its deletion is staged. A present
  file with the planned hash is removed. A present file that changed is kept and reported
  `changed-during-uninstall`.

Because classification comes from `plan.json`, losing some of the records mid-run no
longer matters. The commit carries an `Agentic-Flow-Uninstall: <nonce>` trailer, so a
resume that finds it at `HEAD` only removes the fence. The fence is removed last, after
the commit or after staging.

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

agentic-flow uninstall [--yes] [--json] [--keep-docs] [--remove-project-state]
                       [--purge-ledger] [--no-fetch] [--claim-adoption]
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
  --resume           continue an interrupted apply from <common>/agentic-flow/uninstall/

  Every run ends with two stdout sections:
    Kept — finish by hand:
      <path>  (<why>)
    Still referencing removed files:
      <file>:<line>: <removed path or command>
  When a kept Makefile or workflow references removed files, the report says first that
  `make check` or CI will fail after removal.

exit 0  dry run printed, or apply finished (committed, or staged with a stated reason)
exit 2  usage
exit 3  refused before any write (names every reason)
exit 4  apply stopped part-way; the fence and plan remain; the resume command is printed
```

Plan JSON (`plan.json` and `--json`; the text report renders the same object):

```
{ "v": 1, "nonce": "<hex>", "root": "<abs>", "version": "0.21.0+3757627",
  "adoption_commit": "<sha|null>",
  "refusals":  [ { "reason": "<reason>", "subject": "<plan|lock|path>", "detail": "<text>" } ],
  "payload":   [ { "path": "<rel>", "action": "remove|keep", "tracked": bool, "sha256": "<hex>",
                   "why": "pristine|edited|preexisting|inherited|no-ownership-record|
                           pending-offer|keep-docs|tracked-dirty|claimed",
                   "provenance": "upstream|installed-revision|none" } ],
  "candidates":[ { "path": "<rel>", "action": "remove|keep", "sha256": "<hex>",
                   "why": "recorded|offered|edited|unrecognized" } ],
  "stamps":    [ { "path": "<rel>", "owner": "harness|project", "action": "remove|keep" } ],
  "plans":     [ { "id": "<id>", "worktree": "<abs|null>", "branch": "<name|null>" } ],
  "locks":     [ { "path": "<rel>", "state": "live|stale-local|unresolved", "owner": "<text>" } ],
  "hooks":     { "values": [ { "scope": "<scope>", "origin": "<file>", "value": "<v>" } ],
                 "marker": "<init|migration|null>", "action": "unset|keep", "manual": "<command|null>",
                 "chained_scanner": [ "<hook file>" ] },
  "git_state": { "remove": [ "<dir>" ], "keep": [ "<dir>" ], "salvage_refs_kept": n },
  "kept":      [ { "path": "<rel>", "why": "<reason>" } ],
  "dangling_references": [ { "file": "<rel>", "line": n, "ref": "<removed path|agentic-flow>" } ],
  "dangling_truncated": n,
  "outside":   [ "<checklist line>" ],
  "commit":    { "action": "commit|stage-only", "reason": "<text>" } }
```

Refusal reasons: `not-git-toplevel`, `linked-worktree`, `staged-changes`, `lock-present`,
`uninstall-in-progress`, `fence-owner-unresolved`, `plan-refused`, `purge-with-open-plan`,
`no-installation`, `tracked-dirty`.

## Threat model (one paragraph)

The untrusted actors are agent stations and anyone who can write files in the tree.
Uninstall deletes the secret scanner, the hook path and the command-policy deny rules, so
**an agent that can run it can drop the safety floor**. f-2 adds deny rows for every
spelling the policy already covers, `--resume` and the fence's `bin/` path included. The
human runs it, as with `ship` and `hold clear`.

A planted ownership or upstream record can only cause deletion of a file whose bytes equal
a hash the attacker chose, and the attacker could already delete that file. Every record
path goes through `payload_safe_path`. Symlinks are never followed or deleted through.

The fence directory is in the Git common dir, outside the tree. Resume validates
`plan.json`'s shape and paths again before acting on it.

f-5 runs the installed revision's own `export.sh` into scratch. That is the same trust that
`upgrade` already places in its source, and only the resulting hashes are used.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---------------|-----------|-----------------------|--------------------|
| `git fetch` for plan guards (`clean`) | `plan-refused`, fence released, no write | same | n/a (preflight) |
| Clone of `.agentic-flow-source` origin (f-5) | `AGENTIC_FLOW_FETCH_TIMEOUT` (120 s) → claimed paths kept | Short SHA missing or ambiguous → kept | n/a (scratch only) |
| Installed revision's `export.sh` (f-5) | 120 s → kept | Missing `file=` row or export failure → kept | n/a |
| `clean` per plan during apply | — | — | Exit 4; resume skips closed plans |
| File removal / `git rm` | — | — | Exit 4; resume treats absent planned files as done and stages them |
| Stamp and record removal | — | — | Exit 4; resume reads `plan.json`, not the records |
| `git commit` | — | Hook rejects → staged, `stage-only`, fence removed, exit 0 | Commit landed but fence removal failed → resume sees the trailer and removes the fence |

Bounds: the existing record limits (2,000 paths, 4,100-byte lines) apply to the ownership
record and to `plan.json`'s path lists. `plan.json` is capped at 2 MiB. The lock scan
reads only the three lock roots. The reference scan reads kept payload files and
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

- [BLOCKING] **Uninstall acceptance** (product analysis): remove only paths with install-time
  ownership evidence and pristine provenance, with the no-override plan guards and the
  fence. *Recommended: yes.*
- [BLOCKING] **Legacy ownership.** Every install made before f-1 has no ownership record,
  so its existing files become `inherited`. Without f-5, uninstall removes none of them,
  only stamps and state.
  - *Recommended:* keep f-5. `--claim-adoption` is an explicit owner assertion. It applies
    only to `inherited` or unrecorded paths that the adoption commit added, still requires
    pristine bytes, and is listed path by path before the prompt.
  - It never applies to `preexisting` rows. It does not apply to paths first shipped
    after adoption, because the adoption commit did not add them.
  - *Alternative:* drop f-5 and keep every legacy file.
- **Project-owned state default.** Keep it unless `--remove-project-state` is given?
  *Recommended: yes.*
- **Commit.** Commit by default with the adopter's own identity, and stage only when a
  custom hook still chains the removed scanner? *Recommended: yes.*

---

# Part B — Implementation Brief

## Acceptance scenarios

1. **Untracked identical file at adoption.** Given an adopter `docs/done/.gitkeep` that
   was untracked when export ran and was committed with the version stamp, when uninstall
   runs, then it stays as `preexisting`. With `--claim-adoption` it also stays.
2. **Upgrade meets an adopter file.** Given an adopter file added after adoption at a path
   that a later upgrade first ships with identical bytes, then it stays as `preexisting`.
3. **Edited candidate.** Given an untracked `CLAUDE.md.agentic-new` that the adopter
   edited, when `uninstall --yes` runs, then it stays and is listed as `edited`. An
   unedited candidate beside another path is removed.
4. **Hook path ownership.**
   - A global `core.hooksPath=scripts/git-hooks` stays and is reported.
   - A local value set before adoption has no marker. It stays and is reported with the
     exact unset command.
   - A value set by `init` (marker present) is unset, together with the marker.
5. **Plan guard.** Given an unmerged plan branch with a dirty worktree, then exit 3 names
   the plan, and the tree, Git config, refs and common-dir state are byte-identical.
6. **Racing controller.** Given a controller that takes its lock between uninstall's
   preflight and its fence:
   - the controller refuses with `uninstall in progress`, or uninstall refuses with
     `lock-present`, and nothing is deleted;
   - a lock with no `owner.json`, or with another host's owner, is reported `unresolved`
     and left in place.
7. **Interrupted apply.** Interrupt the apply at each of these points:
   - after the first tracked deletion;
   - after `scripts/agentic-flow` is removed;
   - midway through stamp removal.

   Each time, a fresh `uninstall` refuses with `uninstall-in-progress` and prints the
   resume command, and `--resume` from the fence's `bin/` finishes with one commit. The
   final tree equals an uninterrupted run's.
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

## Invariants

- A dry run writes nothing, not even the fence.
- No destructive write happens before the fence exists, the lock scan is clean, and
  `plan.json` and `bin/` are durable.
- A file is removed only when there is ownership evidence (`created`, a matching
  `candidate`, or an owner claim) and its current bytes match the hash the plan recorded.
  Symlinks are never followed.
- No lock is ever cleared, and no flag overrides `clean`, the fence or the lock scan.
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
Every step's DoD is met, and `make check` and `make test` are green. Scenarios 1–12 are
covered by named tests. `ADOPTION.md` has a *Removing the harness* section, and
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
- Each candidate the harness writes gets a `candidate` row. `upgrade --merged` drops the
  rows of the candidates it removes.
- Forbid the record as a payload destination, as the upstream record is.
- `git_guard_enable` takes a source label and, only when it actually set
  `core.hooksPath`, writes `agentic-flow.hooksPathSetBy` to the same local config.

**Test:** scenarios 1 and 2 as records, plus:
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
  - A tracked path whose index differs from `HEAD` is refused as `tracked-dirty`.
  - Candidates are files matching the three names the library writes, next to listed
    paths. Anything else matching `.agentic-new*` is `unrecognized`.
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

**Test:** scenarios 1–4, 8 and 11 as classifications, 5 (refusal, tree digest unchanged)
and 12. Also: `linked-worktree`, `no-installation`, a symlinked payload path, the
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

## F-3 — Fence uninstall against controllers and plan operations
**Why third:** apply must not start until every racing writer either sees the fence or is
seen by uninstall.

**Approach:**
- Add `fence_check <common>` to a small shared library. It fails with
  `uninstall in progress (<fence>)` when `<common>/agentic-flow/uninstall` exists.
- Call it right after each lock is acquired, and release the lock on failure:
  - `controller_lock`, on both the `mkdir` path and the claim path;
  - the handoff lock;
  - `plan_worktree_lock`, exempting `clean` calls made by the fence owner, which pass the
    fence nonce internally.
- The dispatcher refuses every other subcommand while the fence exists, apart from
  `uninstall`, `--help` and `--version`.
- `uninstall_fence_acquire`:
  - create the fence with `mkdir`, then write `owner`;
  - scan `locks/`, `worktree-locks/` and the linked worktrees;
  - when anything is present, remove the fence and refuse with `lock-present`, listing
    each lock and its state. Locks are never touched.

**Test:** scenario 6, made deterministic with a test-only pause point
(`AGENTIC_UNINSTALL_TESTING=1` plus a named pause). Also:
- `start`, `handoff` and `verify-step` refuse while the fence exists;
- a controller lock with no owner, and one owned by another host, are each `unresolved`
  and preserved;
- releasing the fence after a refusal leaves the tree digest unchanged.

**DoD:** with the fence in place, no fence-aware operation can start. With any lock
present, uninstall cannot acquire the fence.
**Verify:** `make test-one F=controller S=launch && make test-one F=stations S=handoff && make test-one F=upgrade`
**Risks:**
- A controller holding its lock across a long station run makes uninstall refuse. That is
  intended.
- The exemption for the fence owner's own `clean` must not be reachable from the CLI.
**Red-first:** none
**Commit:** `Fence uninstall against controllers and plan operations`

---

## F-4 — Apply the removal from a persisted plan that a retry can resume
**Why fourth:** it needs f-2's plan and f-3's fence.

**Approach:**
- `--yes`, or a `y` at the terminal prompt, acquires the fence, then recomputes the plan.
  If anything differs from what was shown, it releases the fence and refuses.
- Write `plan.json` and the `bin/` copy (CLI plus sourced libraries), sync them, then
  re-exec from `bin/`.
- Apply order. Append each completed action to `progress`:
  1. Run `clean` for each plan.
  2. Remove planned payload files and candidates, each after rechecking its hash. Use
     `git rm -q --` for tracked paths and `rm` for untracked ones.
  3. Prune directories left empty.
  4. Remove project state if asked.
  5. Unset `core.hooksPath` and its marker when the plan says so.
  6. Remove cache directories, keeping `uninstall/`, and the `--purge-ledger` set if
     asked.
  7. Remove stamps and records.
  8. Commit with the trailer, or stage only.
  9. Print the kept and reference sections against the resulting tree.
  10. Remove the fence.
- `--resume` follows the Part A rules. `scripts/agentic-flow uninstall`, while the fence
  exists, prints the resume command or, with `--resume`, execs `bin/`.
- On any failure, stop with exit 4 and print the resume command.

**Test:** scenarios 3, 4 (unset), 5 (apply half), 7, 8 and 9. Also:
- a resume finds a staged change outside the plan → refused;
- a planned file changes between runs → kept as `changed-during-uninstall`;
- a commit landed but the fence remained → the resume only removes the fence;
- an interactive "no" writes nothing.

Use a test-only fault point, `AGENTIC_UNINSTALL_TESTING=1` plus a named action.

**DoD:** each interruption in scenario 7 resumes to the same final tree as an
uninterrupted run. Every refusal leaves the tree digest unchanged.
**Verify:** `make test-one F=upgrade`
**Risks:**
- Unset the hook path before committing, or the commit runs a missing hook.
- `git rm` on a path that has gone missing must not abort the batch. Use
  `--ignore-unmatch` per path.
**Red-first:** `upgrade:uninstall` — scripts/tests/upgrade.sh scripts/self-test.sh
**Commit:** `Apply uninstall from a persisted plan that a retry can resume`

---

## F-5 — Let the owner claim legacy paths, proven against the installed revision
**Why last:** it only turns some legacy keeps into removals, behind an explicit owner
assertion. Drop it if the owner chooses to keep every legacy file.

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

## Revision history

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
