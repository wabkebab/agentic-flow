<!-- TRIAGE (first pass · 2026-11-27) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict (deletes adopter files, removes the secret-scan hook path and adds a command-policy floor row; project baseline is Standard)
> Phase 3 of [harness configurability](product-harness-configurability.md) (area J): `agentic-flow uninstall`, which removes only what the harness can prove it owns. It defaults to a dry run, refuses while any plan would be refused by `clean`, and makes one removal commit.
> Draft 1 (2026-11-27), written against `0.21.0` (`3757627`). Next: owner review. The *Uninstall* decision in the product analysis gates approval.

# Feature — Uninstall: remove only what the harness owns

## Tracker
- [ ] f-1 — Classify ownership and report the removal as a dry run — open
- [ ] f-2 — Apply the removal behind the plan guards in one commit — open
- [ ] f-3 — Prove older installs' provenance from the installed revision — open

---

# Part A — Analysis

## Goal

An adopter who stops using the harness needs a clean way out. Today the only way is to
delete files by hand. That loses either way: it leaves stamps, a `core.hooksPath` that
points at a deleted directory, and Git state under the common dir, or it deletes files the
adopter changed.

The owner's goal 8 (2026-11-25) asks for a script that removes the harness cleanly. The
product analysis (area J) settled what "cleanly" means. Remove a file only when the harness
can prove the adopter never changed it. Never override a plan guard. Print everything
outside the repository as a checklist instead of touching it.

## Current state

- **Installation record.** `.agentic-flow-installation` lists active scopes and one
  `file=<sha256>  <path>` row per installed path (`payload-apply.sh:228-247`). It hashes
  the destination *after* the apply, so it also records preserved edits, `kept` files and
  hand-merged contracts. It cannot prove that a file is pristine.
- **Upstream record (since 0.20.0).** `.agentic-flow-upstream` holds `accepted=` (the
  shipped source hash the file was last reconciled to) and `offered=` (a pending
  candidate) per path (`payload-apply.sh:417-477`). `payload_apply_entry` sets `accepted=`
  to the source hash for `same`, `create` and `overwrite`. It leaves `accepted=` unchanged
  for `kept`, and `upgrade --merged` promotes `offered=` to `accepted=`
  (`payload-apply.sh:489-510, 584-600`).
  - **Checked 2026-11-27:** a fresh export of `3757627` into an empty directory wrote 149
    `file=` rows and 149 `accepted=` rows. 148 matched. `docs/README.md` differs because
    export seeds the docs index after the apply (`export.sh:166-172`).
- **Older installs.** Installs made before 0.20.0 have no `.agentic-flow-upstream` until
  their next upgrade. `.agentic-flow-version` stamps `<semver>+<short-sha>`
  (`payload_compute_version`, `payload-apply.sh:605-611`). `.agentic-flow-source` records
  an origin and a ref, which may be a moving branch. `fetch_standard` clones only
  `--depth 1 --branch <ref>` (`scripts/agentic-flow:161-171`), so it cannot reach a commit.
- **Plan cleanup.** `clean` refuses a dirty worktree, a detached or mismatched branch, the
  base branch, and a branch that is not an ancestor of `origin/<base>`. It also refuses to
  run from inside the worktree it removes. It deletes the plan's salvage refs and records
  the plan closed (`start.sh:307-405`). It has a `--dry-run` that writes nothing.
- **Hooks.** `git_guard_enable` sets `core.hooksPath=scripts/git-hooks` only when it is unset
  and the project root is the Git top level. A custom path is kept and told to chain
  `scripts/git-hooks/pre-commit` (`git-guards.sh:11-26`).
- **Agent hooks.** `.claude/settings.json` and `.codex/hooks.json` run `scripts/hooks/*.sh`.
  Both are payload files, but the command-policy renderer may rewrite them, so they are
  often not pristine.
- **Shared Git state** under `$(git rev-parse --git-common-dir)/agentic-flow/`:
  - caches: `state`, `verify`, `gate`, `launches`, `probe`, `locks`, `worktree-locks`,
    `codex-home`;
  - records: `ledger`, `decisions`, `findings`, `plans`, plus the `worktrees` root;
  - refs: `refs/agentic-flow/salvage/<plan>/…`.
- **Outside the repository.** Operator files live under `${XDG_CONFIG_HOME:-~/.config}/agentic-flow/`
  (`config/<slug>.conf`, `roles/<slug>.tsv`, `identities/<repo>.tsv`). The forge holds
  labels, issues, rulesets, any GitHub App, and the adopter's copy of `templates/ci/ci.yml`.
- **Stamps.** Harness-owned: `.agentic-flow-version`, `-source`, `-source-applied`,
  `-candidate-version`, `-installation`, `-upstream`, `-scopes-excluded`,
  `-stack-candidate`, and `.agentic-new*` candidates. Project-owned:
  `.agentic-flow-assurance`, `-assurance-audit`, `-roles`, `-stack`, `-review-policy`,
  `.agentic-flow/config`.
- **No `uninstall`** exists. The command policy has no row for it, so an agent could run it
  and remove the secret scan and its own deny rules.

## Proposed approach

### Option A — provenance-gated removal (recommended)

Remove a payload file only when all of the following hold:
- it is listed in `.agentic-flow-installation`;
- it has an `accepted=` hash with no pending `offered=` and no `.agentic-new*` candidate;
- its current bytes hash to that `accepted=` value.

Report every other file and keep it. For installs older than 0.20.0, the `accepted=` hash
comes from re-exporting the *installed revision* (f-3). Plans go through `clean`'s own
guards with no override. Refusals happen before any write. Harness records are removed
last, so a failed run can be rerun.

### Option B — remove everything the installation record lists

This is simpler, but `file=` also matches edited, kept and hand-merged files, so it would
delete adopter work. Rejected by the product analysis.

### Option C — managed-region markers in contracts

These would let uninstall strip only the harness's section from a hand-merged `CLAUDE.md`.
That is useful later, but it needs a template format change and an upgrade migration.
Deferred (see the product analysis's open question).

**Recommendation:** Option A. A false "keep" costs the adopter one manual `rm`. A false
"remove" destroys their work. Every ambiguous case keeps the file.

## Interface (before the implementation)

```
agentic-flow uninstall [--yes] [--json] [--keep-docs] [--remove-project-state]
                       [--purge-ledger] [--no-fetch]

  default            dry run: print the classified plan, write nothing.
                     On a terminal, offer to apply after the report.
  --yes              apply without prompting (required off a terminal)
  --json             emit the plan (or the applied result) as one JSON object
  --keep-docs        keep payload files under docs/ and the root METHODOLOGY.md / ADOPTION.md
  --remove-project-state
                     also remove the project-owned stamps and .agentic-flow/config
  --purge-ledger     also remove ledger, decisions, findings and plan records; refused
                     while any plan record is open or pending
  --no-fetch         no network: plan guards use local origin/<base>; f-3's fallback is skipped

exit 0  dry run printed, or apply finished (committed, or staged with a stated reason)
exit 2  usage
exit 3  refused before any write (names every reason)
exit 4  apply failed part-way; harness records kept; rerun converges
```

Plan JSON (also what the dry-run text renders):

```
{ "root": "<abs>", "version": "0.21.0+3757627", "apply": false,
  "refusals":  [ { "reason": "plan-refused", "plan": "<id>", "detail": "<clean's error>" } ],
  "payload":   [ { "path": "<rel>", "action": "remove|keep",
                   "why": "pristine|edited|pending-offer|candidate|no-provenance|
                           unlisted|keep-docs|tracked-dirty" ,
                   "provenance": "upstream|installed-revision|none" } ],
  "candidates":[ "<rel>.agentic-new…" ],
  "stamps":    [ { "path": "<rel>", "owner": "harness|project", "action": "remove|keep" } ],
  "plans":     [ { "id": "<id>", "worktree": "<abs|null>", "branch": "<name|null>" } ],
  "hooks":     { "core_hooks_path": "<value|null>", "action": "unset|keep",
                 "chained_scanner": [ "<hook file>" ] },
  "agent_hooks_dangling": [ "<kept settings file that runs a removed script>" ],
  "git_state": { "remove": [ "<dir>" ], "keep": [ "<dir>" ], "salvage_refs_kept": n },
  "outside":   [ "<checklist line>" ],
  "commit":    { "action": "commit|stage-only", "reason": "<text>" } }
```

Refusal reasons: `not-git-toplevel`, `linked-worktree` (run from the main checkout),
`staged-changes`, `live-controller`, `plan-refused`, `purge-with-open-plan`,
`no-installation`, `tracked-dirty`.

## Threat model (one paragraph)

The untrusted actors are agent stations and anyone who can write files in the tree.
Uninstall deletes the secret scanner, the hook path and the command-policy deny rules, so
**an agent that can run it can drop the safety floor**. f-1 adds deny rows for every
spelling the policy already covers (`scripts/agentic-flow uninstall`,
`./scripts/agentic-flow uninstall`, `agentic-flow uninstall`,
`rtk proxy scripts/agentic-flow uninstall`). The human runs it, as with `ship` and
`hold clear`. A planted `.agentic-flow-upstream` can only cause deletion of a file whose
bytes equal a hash the attacker chose, and the attacker could already delete that file.
Every record path goes through the existing `payload_safe_path` checks, and symlinks are
never followed or deleted through. The installed-revision fallback runs that revision's
own `export.sh` into a private scratch directory. That is the same trust that `upgrade`
already places in its source. The result is used only as hashes, never copied into the
tree.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---------------|-----------|-----------------------|--------------------|
| `git fetch` for plan guards (`clean`) | `clean`'s own fetch error → `plan-refused`, no write | same | n/a (read-only in preflight) |
| Clone of `.agentic-flow-source` origin (f-3) | `AGENTIC_FLOW_FETCH_TIMEOUT` (120 s) → every fallback path `no-provenance`, kept | Short SHA missing or ambiguous → kept | n/a (scratch only) |
| Installed revision's `export.sh` into scratch | 120 s → kept | Missing `file=` row or export failure → kept | n/a |
| `clean` per plan during apply | — | — | Earlier plans stay cleaned; exit 4; rerun skips closed plans |
| File removal / `git rm` | — | — | Exit 4 with records intact; rerun reclassifies the remaining files |
| `git commit` | — | Hook rejects → removal stays staged, exit 0 with `stage-only` and the hook's output | — |

Bounds: the existing record limits (2,000 paths, 4,100-byte lines) apply. Plan records are
scanned up to the existing `plan_find_branch` bound. Empty-directory pruning walks only the
parents of removed files and stops at the root. The JSON lists at most one entry per
installed path. One clone per run.

## Out of scope / What NOT to build in this pass

- Removing anything outside the repository: operator files, keychain entries, labels,
  issues, rulesets, Apps, or the adopter's CI workflow. These are printed only.
- Editing a custom hook to unchain the scanner, or editing kept settings files.
- Managed-region markers (Option C).
- Monorepo installs whose harness root is not the Git top level. They are refused in v1.
- Pushing, and any override flag for plan guards.
- A forge call. Uninstall is local apart from the optional fetches.

## Open questions

- [BLOCKING] **Uninstall acceptance** (product analysis): remove only on pristine
  provenance (`accepted=`, or the installed revision's re-export for older installs), with
  the no-override plan guards. *Recommended: yes.*
- **Project-owned state default.** Keep it unless `--remove-project-state` is given?
  *Recommended: yes.* These files hold the adopter's own choices, and leaving them costs
  six small files.
- **Commit.** Commit by default (subject `Remove the agentic-flow harness`, the human's own
  identity), and fall back to staging only when a custom hook still chains the removed
  scanner? *Recommended: yes.*
- **Monorepo subdirectory installs:** refuse in v1? *Recommended: yes.* `init` never
  configures hooks there, and the common-dir state is shared with the parent repository.

---

# Part B — Implementation Brief

## Acceptance scenarios

1. Given an upgraded fixture with a custom `core.hooksPath` whose `pre-commit` chains the
   scanner, and an unmerged plan branch with a dirty worktree, when `uninstall --yes`
   runs, then it exits 3 naming the plan, and the tree, Git config, refs and common-dir
   state are byte-identical.
2. Given that fixture after the plan is cleaned, when `uninstall --yes` runs, then
   `core.hooksPath` and the custom hook are unchanged and reported, the ledger directory
   remains, and the removal is staged but not committed, with `stage-only` naming the
   chaining hook.
3. Given a payload file edited locally and then carried through an upgrade in which its
   source did not change (`kept`), when uninstall runs, then the file stays with
   `why=edited`.
4. Given `CLAUDE.md` merged by hand through `upgrade --merged`, then it stays.
5. Given a file byte-identical to its `accepted=` content, then it is removed.
6. Given an export into an empty Git repository, committed, when `uninstall --yes` runs,
   then every pristine payload file and every harness stamp is gone, and one commit exists.
   The tree matches the pre-export commit apart from `docs/README.md` and the kept
   project state.
7. Given a fixture without `.agentic-flow-upstream`, whose `.agentic-flow-source` ref has
   moved past the installed commit and changed a file, when uninstall runs, then only files
   identical to the *installed* revision are removed. With `--no-fetch`, or an
   unreachable or stampless version, every such file is kept.
8. Given `--purge-ledger` with an open plan record, then exit 3 `purge-with-open-plan`.
9. Given an agent hook command `agentic-flow uninstall`, then the native policy blocks it.

## Invariants

- No write happens before every refusal check has passed (scenario 1's tree digest).
- A file that is not proven pristine is never removed. Symlinks are never followed.
- No flag overrides a `clean` refusal.
- `.agentic-flow-version`, `-installation` and `-upstream` are removed last, so a failed
  apply can be rerun and converges.
- Only the paths the run removed are staged, by name. Existing staged changes are refused,
  never swept in.
- The running CLI never reads a file that the run has deleted.
- Bash 3.2; no new required tool.

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
Every step's DoD is met, and `make check` and `make test` are green. Scenarios 1–9 are
covered by named tests. `ADOPTION.md` has a *Removing the harness* section, and
`CHANGELOG.md` has an entry. A manual run in a scratch export shows the dry-run report,
then `--yes`, then a clean `git status`.

## Verification commands
```bash
make check                 # per step
make test-one F=upgrade    # uninstall tests live in the upgrade group, timed as upgrade:uninstall
make test-one F=hooks      # f-1: command-policy rows
make test                  # end of brief
```

---

## F-1 — Classify ownership and report the removal as a dry run
**Why first:** every later decision reads this classification. Shipping it read-only lets
adopters see what uninstall *would* do before anything can delete.

**Approach:**
- Add a dispatcher entry `uninstall` and a library `scripts/lib/uninstall.sh`. The library
  sources `payload-apply.sh` and `start.sh` itself (memory:
  `library-sources-its-dependencies`).
- Root resolution: `find_root`, which must equal `git rev-parse --show-toplevel`. The run
  must start in the main worktree; a linked worktree is refused with `linked-worktree`.
- Payload: read `.agentic-flow-installation` (absent → refuse `no-installation`) and
  `payload_upstream_load` in a new read-only mode. Classify each listed path as Part A's
  rule says. `--keep-docs` downgrades removals under `docs/` and the root methodology
  files.
  - A tracked path whose index entry differs from `HEAD` is `tracked-dirty`. Refuse it.
  - Candidates are `.agentic-new*` files next to listed paths.
- Stamps: one list per owner, defined once in the library (Part A).
- Plans: for every record under `<common>/agentic-flow/plans/` that is not `closed`, and
  every worktree under `worktrees/`, run `clean`'s checks in dry-run mode. Pass
  `--no-fetch` through. Collect every refusal, not just the first.
- Hooks: read `core.hooksPath`. If it equals `scripts/git-hooks`, it will be unset.
  Otherwise list hook files under it that mention `scripts/git-hooks/pre-commit`.
- Kept settings files under `.claude/`, `.codex/` and `.opencode/` that reference a
  `scripts/hooks/` file due for removal → `agent_hooks_dangling`.
- Live controller: a held lock under `locks/` whose owner is alive → `live-controller`.
- Git state: split caches from records as Part A lists them; count salvage refs.
- Outside: the fixed checklist. Warn first when a ruleset may require the **CI gate**
  check. This is text only, with no forge call.
- Text and `--json` render the same object. Exit 0 with a report, or 3 with refusals.
- Add the four command-policy deny rows ("the human uninstalls"), regenerate the native
  rules, and update `docs/reference/command-policy-coverage.md`.
- Add `upgrade:uninstall` to the wall-ceiling keys.

**Test:** scenarios 1 (dry-run half: refusal with an unchanged tree digest), 3, 4, 5 (as
classifications), 8 and 9. Also: `linked-worktree`, `no-installation`, a symlinked payload
path (kept, not followed), and `--json` validating against the interface shape.

**DoD:** `agentic-flow uninstall` prints a correct plan and never writes. The command
policy blocks it for agents in all three runtimes.
**Verify:** `make test-one F=upgrade && make test-one F=hooks`
**Risks:**
- `clean`'s functions use globals set in `plan_worktree_cmd`. Call them through a
  subshell wrapper per plan, not by re-sourcing state.
- The upgrade group's fixture count grows. Measure it and update `config/test-budgets.tsv`
  in the same commit.
**Red-first:** `upgrade:uninstall` — scripts/tests/upgrade.sh scripts/self-test.sh
**Commit:** `Add a dry-run uninstall that classifies what the harness owns`

---

## F-2 — Apply the removal behind the plan guards in one commit
**Why second:** it acts on f-1's classification and needs none of f-3's network path.

**Approach:**
- `--yes`, or a `y` at the terminal prompt, applies. Recompute the plan and refuse again if
  anything changed.
- Before the first write, copy `scripts/agentic-flow` and the libraries it sources into a
  private temp directory, and re-exec with a marker argument, as upgrade's bridge does
  (`validate_bridge`).
- Apply order:
  1. Run `clean` for each plan.
  2. Remove pristine payload files and candidates. Use `git rm -q --` for tracked paths and
     `rm` for untracked ones.
  3. Prune directories left empty.
  4. Remove project state if asked.
  5. Unset `core.hooksPath` only if its value is `scripts/git-hooks`.
  6. Remove cache directories, and the `--purge-ledger` record set if asked.
  7. Remove harness stamps; the three records come last.
- Commit with the fixed subject and a body listing kept files. Use `stage-only` when a
  chaining hook exists or the commit fails.
- On any failure, stop. Leave the records in place and exit 4 with the step that failed.

**Test:** scenarios 1 (apply half), 2, 5, 6 and 8. Also:
- the rerun after an injected failure between steps 2 and 7 converges;
- the running CLI survives deleting its own files (the pattern at `upgrade.sh:402-421`);
- pre-existing staged changes cause a refusal;
- an interactive "no" writes nothing.

**DoD:** scenario 6 leaves one commit and a clean `git status`. No refusal case changes
the tree digest.
**Verify:** `make test-one F=upgrade`
**Risks:**
- `clean` refuses to run from inside the worktree it removes. Uninstall already requires
  the main worktree.
- Deleting `scripts/git-hooks` before committing: unset the hook path first, or the
  commit runs a missing hook.
- `git rm` on a path that has gone missing must not abort the batch.
**Red-first:** `upgrade:uninstall` — scripts/tests/upgrade.sh scripts/self-test.sh
**Commit:** `Apply uninstall behind the plan guards in one removal commit`

---

## F-3 — Prove older installs' provenance from the installed revision
**Why last:** it only turns some `no-provenance` keeps into removals. Everything before it
is already safe without it.

**Approach:**
- For listed paths with no upstream row (older installs), take the commit from
  `.agentic-flow-version`'s `+<sha>`. Never use `.agentic-flow-source`'s `ref`.
- Unless `--no-fetch` is given, clone the recorded origin once
  (`--filter=blob:none --no-checkout`, under `run_with_timeout`) into a private temp
  directory. Resolve `<sha>^{commit}`; a missing or ambiguous commit leaves those paths
  kept.
- Check out that commit in scratch and run *its* `scripts/export.sh` into an empty scratch
  target. Pass the `--exclude-scope=` values from `.agentic-flow-scopes-excluded`.
- Use the scratch target's `.agentic-flow-installation` hashes as the `accepted=` values
  for those paths (`provenance=installed-revision`).
- Report the revision used.

**Test:** scenario 7, in three variants:
- the source ref has moved and changed a file → only files identical to the installed
  revision are removed;
- `--no-fetch` → all kept;
- the stamp has no `+sha`, or the commit is unreachable → all kept.
Also: an export failure at that revision keeps everything and still exits 0 for a dry run.

**DoD:** an older-install fixture loses exactly the files identical to its installed
revision, and the report says which revision proved them.
**Verify:** `make test-one F=upgrade`
**Risks:**
- Old exporters may lack `--exclude-scope` or write a different installation format. Any
  parse failure means keep.
- Local `file://` origins in tests must not need network access.
**Red-first:** `upgrade:uninstall` — scripts/tests/upgrade.sh scripts/self-test.sh
**Commit:** `Prove older installs' provenance from their installed revision`

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
