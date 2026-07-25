<!-- TRIAGE (first pass · 2026-07-25) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> Give an adopted project a first-class upgrade surface — `agentic-flow status | diff |
> upgrade` — that runs **in the project** and pulls from the standard, instead of the
> standard pushing into it.

# Feature — The `agentic-flow` upgrade surface

## Tracker

- [ ] F-1 Record the standard's origin at adoption time (`.agentic-flow-source`) — open
- [ ] F-2 Extract the payload applier into a shared, exported library — open
- [ ] F-3 `agentic-flow status` — offline, read-only, plus the git-ignore trap check — open
- [ ] F-4 `agentic-flow diff` — fetch the standard, report what would change — open
- [ ] F-5 `agentic-flow upgrade` — apply under the existing `.agentic-new` policy — open
- [ ] F-6 Document the upgrade path and back-fill existing adopters — open

---

# Part A — Analysis

## Goal

An adopted project should be able to answer three questions **without having the standard
checked out and without reading `export.sh`**:

1. *What am I on, and is anything half-applied?*
2. *What would change if I upgraded?*
3. *Apply it.*

This is ROADMAP 3.2, and it is the last item between the harness and a 1.0 that means
something. 1.0 is a compatibility promise; there is currently no mechanism to move an
adopter across a contract change, so the promise cannot be made.

The pain is live, not hypothetical. `collector/.agentic-flow-version` reads
`0.9.0+d507bf4` — the commit immediately *before* the #46 optimization pass — and there is
no supported way to bring it forward. #46 changed the review severity vocabulary, made
`docs-index.sh` hard-fail on an unrecognized docs stage, and added a CI step: exactly the
class of change an upgrade command exists to carry.

## Current state

What already exists, and must not be re-implemented:

- **`config/payload.tsv`** (`export.sh:38`) is the single authority on payload membership —
  five columns: source, destination, scope, merge policy, disposition. It **is exported**,
  so an adopted project already has the map of what belongs to the harness.
- **`.agentic-flow-version`** holds `<semver>+<sha>` (`export.sh:126-132`), written only
  when nothing is pending. **`.agentic-flow-candidate-version`** holds the version of a
  half-applied update (`export.sh:178-185`). The installed/pending split is already correct.
- **The merge policy is already conservative and already tested** (`export.sh:142-176`):
  identical → skip; differs → write `<file>.agentic-new`, escalating to
  `.agentic-new.<version>` and `.agentic-new.<version>.<content-id>` rather than ever
  clobbering an occupied candidate; installed version is **not** advanced while any merge is
  outstanding.
- **`doctor.sh`** already fails on unresolved merge candidates and reports the stamp and the
  stack profile.

What is missing is only the surface over these — plus two structural gaps:

- **`scripts/export.sh` is `source-only`** (`config/payload.tsv:16`). Confirmed against a
  real adopter: `collector/scripts/` contains `doctor.sh`, `docs-index.sh`,
  `lifecycle-status.sh`, `plan-to-issues.sh`, `render-stack-profile.sh`, `self-test.sh`,
  `check-*.sh`, `hooks/` — and no `export.sh`. The project has the manifest but not the
  logic that walks it.
- **Nothing records where the standard lives.** `.agentic-flow-version` is a version, not a
  provenance. A project knows what it *is* and cannot discover what *exists*.

Direction today is therefore **push only**: `scripts/export.sh <target>` run from this repo.

## Proposed approach

### Option A — pull, from the project (recommended)

Ship `scripts/agentic-flow` in the payload. It runs in the adopted project, reads
`.agentic-flow-source` to find the standard, fetches it to a temp cache, and drives the same
manifest walk `export.sh` uses.

- Scales to any number of adopters without the maintainer tracking them.
- Puts the answer where the question is asked.
- Matches how comparable tools work — **cruft** is the exact prior art for the
  cookiecutter/template case, and it is the same stamp-then-update shape.
- Cost: the applier must ship, so an adopted project carries code that rewrites its own
  harness files.

### Option B — push, from the standard

Add `status`/`diff`/`upgrade` to this repo, taking a target path.

- Cheapest — no manifest change, no origin, no fetch, nothing new ships.
- But the maintainer must have every adopter checked out and remember to run it, and the
  project still cannot self-serve "am I current?" — which is the felt pain. It automates the
  half of the problem nobody is struggling with.

**Recommendation: Option A.** Option B is a smaller change to this repo and a
non-improvement for every project that adopted it. The decisive argument is that drift is
discovered *in the project*, usually by an agent reading a stale contract file.

### Shape of the command

One entry point with subcommands, not three scripts — the subcommands share root
resolution, manifest parsing, origin handling, and the fetch cache, and three scripts would
either duplicate that or need a fourth file to hold it.

Root resolution walks **up from `$PWD`** looking for `.agentic-flow-version`. This is a
deliberate departure from `doctor.sh:24-27`, which resolves from its own location — that is
right for doctor (a harness in a monorepo subdirectory owns that subdirectory) and wrong
here, because a CLI must work when symlinked onto `PATH`. The upward walk preserves the same
monorepo semantics: the nearest stamp above you owns the subtree.

## Interface (before the implementation)

```text
agentic-flow status  [--json]
agentic-flow diff    [--ref <ref>] [--json]
agentic-flow upgrade [--ref <ref>] [--force] [--yes]
agentic-flow --help | --version

Exit codes (shared):
  0  clean / nothing to do
  1  action needed  (status: candidates pending or payload git-ignored;
                     diff: changes available)
  2  usage or environment error (no project root, no origin, fetch failed)
```

New file in the target, written at adoption time:

```text
.agentic-flow-source        # exported? no — written by export.sh/init.sh into the target
  line 1: origin   https://github.com/wabkebab/agentic-flow
  line 2: ref      main
```

Two lines, same shape as `.agentic-flow-version`/`.agentic-flow-stack` — a flat file the
existing scripts can read with `sed -n '1p'`, not a config format.

Shared library extracted from `export.sh` (exported; both push and pull call it):

```text
scripts/lib/payload-apply.sh
  payload_load_manifest  <manifest-path>     -> ITEM_SRCS/ITEM_DSTS/EXCLUDE_PATHS
  payload_expand_files   <src-root>          -> FILES/DESTS
  payload_apply_entry    <src> <dst> <mode>  -> create|overwrite|candidate|pending|same
  payload_stamp_version  <src-root> <dst-root> <pending-count>
```

`mode` ∈ `apply|dry-run|force`. `payload_apply_entry` returns the classification as its
only output, so `status`, `diff`, `upgrade`, and `export.sh` all render from one decision.

## Threat model (one paragraph)

`upgrade` introduces a new trust boundary: an adopted project fetches and writes files from
a remote origin. The untrusted input is `.agentic-flow-source` (in-repo, so it is
review-visible and changing it is a reviewable diff) and the fetched content. The realistic
worst case is a compromised or substituted origin overwriting `CLAUDE.md`, `AGENTS.md`, the
hooks, and `.claude/settings.json` — which is instruction injection against every future
agent session in that project, and the hooks are the enforcement layer. Three mitigations,
all cheap: **(1)** `upgrade` copies manifest-declared files and **executes nothing** it
fetched — note that `export.sh:199-205` currently runs the target's `docs-index.sh` after
copying, which after an upgrade is freshly fetched code, so the pull path must not inherit
that; **(2)** a changed origin is a hard stop, not a warning — if `.agentic-flow-source`
differs from what the last upgrade recorded, refuse and require `--force`; **(3)** the
existing `.agentic-new` policy means an upgrade never silently rewrites a file the project
has customized, so the blast radius on a real project is smaller than on a pristine one.
No secrets or user data are involved; there is no auth and no network write.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---|---|---|---|
| `git ls-remote <origin>` (status, optional) | 10s cap → report `remote unknown`, exit 0; never blocks the offline answer | unparseable → same as timeout | n/a (single ref read) |
| `git clone --depth 1 --branch <ref>` (diff/upgrade) | 120s cap → `exit 2`, cache left absent | missing ref / not a repo → `exit 2` naming the origin and ref | partial clone → discard the temp dir; never populate the cache from a failed fetch |
| file copy into the target (upgrade) | n/a | n/a | **this is the real one** — see below |

**Partial application is the failure that matters.** `upgrade` walks ~29 manifest entries;
a failure at entry 15 leaves the project half-new. The existing design already handles this
correctly and the pull path must preserve it rather than invent something: the installed
version is only advanced when nothing is pending, so a half-applied tree keeps the *old*
`.agentic-flow-version` and gains `.agentic-flow-candidate-version`. Re-running `upgrade` is
therefore idempotent and resumable — identical files are skipped, an occupied merge
candidate whose content already matches is reused rather than duplicated
(`export.sh:151-168`).

Bounds: fetch depth 1, single ref, 120s clone timeout, 10s `ls-remote` timeout; the temp
cache is `mktemp -d` and removed on `EXIT`; the manifest is bounded by its own file.

## Out of scope / What NOT to build in this pass

- A transactional render-validate-plan-apply engine. Render-to-temp then move is the
  valuable 20% for a ~29-entry manifest.
- Automatic or 3-way merge. `.agentic-new` plus a human stays the policy — a bad auto-merge
  of `CLAUDE.md` is worse than a conflict.
- Downgrade / pinning to an arbitrary older version.
- Multiple origins, forks, or private-registry auth.
- The CLI updating itself out of band (it is payload; it upgrades with everything else).
- `export.sh` changing its own push behavior beyond calling the extracted library.
- Deriving `.agentic-flow-source` for projects that lack it — F-6 documents a one-line
  back-fill instead. Guessing provenance is exactly the kind of inference this repo avoids.

## Decisions

Recorded 2026-07-25. Both blocking questions are answered; the plan is unblocked.

- ✅ **The applier ships.** `scripts/lib/payload-apply.sh` becomes exported payload, so an
  adopted project carries code that rewrites its own harness files. This is the larger
  blast radius named in the Threat model and it is accepted deliberately, because the
  alternative is no upgrade story at all. The three mitigations are therefore **not
  optional and not nice-to-have** — they are the terms on which this was accepted:
  1. `upgrade` copies manifest-declared files and executes nothing it fetched (F-5.3);
  2. a changed origin is a hard stop requiring `--force` (F-5.4);
  3. the `.agentic-new` policy stands — no automatic overwrite of a customized file.
  Any step that cannot hold all three should stop and escalate rather than ship without one.
- ✅ **Track `main` by default.** `.agentic-flow-source` line 2 is `main` for now. F-1 must
  still read the ref as data rather than assuming a branch, because:
- ✅ **Tags come after this implementation lands.** Once `v<semver>` tags exist, a project
  switches to deliberate updates by editing one line of `.agentic-flow-source` — no code
  change, no migration. This is why F-1 writes the ref as a plain second line and F-4/F-5
  pass it to `git clone --branch`, which accepts a tag or a branch identically. **Do not
  design a release process in this pass**; just don't foreclose one.

## Open questions

- Should `status` reach the network at all by default? **Recommendation: no.** Offline by
  default, `--check-remote` to compare against the origin. An offline command that
  occasionally hangs on DNS is worse than one that says less.
- Should `agentic-flow` be on `PATH` (symlink from `~/.local/bin`, like `git-claude`) or
  always invoked as `scripts/agentic-flow`? Not blocking — the upward root walk makes both
  work. Document `scripts/agentic-flow` as canonical.

---

# Part B — Implementation Brief

> **Audience:** Codex. One branch and one PR. Each step is one coherent commit and one
> issue. Re-read the named live files immediately before the step; this document describes
> intent, not current private interfaces.

## Branch

Base: `main`.

```text
codex/upgrade-surface
```

## Whole-brief Definition of Done

- `agentic-flow status` answers installed / candidate / pending / stack / adapters offline,
  in an adopted project, with no copy of the standard present.
- `agentic-flow diff` reports what an upgrade would change, writing nothing.
- `agentic-flow upgrade` applies under the existing `.agentic-new` policy and never advances
  the installed version while anything is pending.
- `export.sh` behaviour is **unchanged** — same output, same counters, same stamps — while
  sharing one applier with the pull path.
- A payload path that is git-ignored in the target is reported, not silently skipped.
- `collector` is upgradeable from `0.9.0+d507bf4` to current **by the tool**.

## Whole-brief verification

```bash
make check
make test
make build
make test-one F=export
make test-one F=upgrade      # new group, added in F-3
scripts/doctor.sh --check --scope repo --skip-make-check
```

---

## F-1 — Record the standard's origin at adoption time

**Why first:** it is the one fact that **cannot be retrofitted**. Every later step depends on
it, and the same argument pulled the version stamp forward as ROADMAP 1.5.5.

**Inspect immediately before editing:** `scripts/export.sh` stamp block (~`:126-190`);
`scripts/init.sh`; `scripts/doctor.sh` version-reporting section; `config/payload.tsv`;
`ADOPTION.md`.

**Approach:**

1. `export.sh` writes `.agentic-flow-source` into the target: origin on line 1, ref on line
   2. Derive the origin from `git -C "$SRC" remote get-url origin`; if there is no remote,
   write nothing and say so rather than inventing a value. The ref defaults to `main` per
   Decisions — but **read and write it as opaque data**, never branch-specific logic:
   `git clone --branch` takes a tag or a branch identically, and tags are coming after this
   plan lands. A test asserting `ref = main` is testing the default, not the mechanism;
   include a fixture with a tag-shaped ref so the assumption cannot creep in.
2. Never overwrite an existing `.agentic-flow-source` — a project may deliberately track a
   fork. Report when the derived origin differs from the recorded one.
3. `doctor.sh` reports the recorded origin alongside the version stamp, and warns when a
   stamped project has no origin (the state every current adopter is in).
4. Do **not** add it to `config/payload.tsv`. It is generated target state, like
   `.agentic-flow-version` — not payload. Confirm `check-payload-manifest.sh` stays green.

**Failure-first tests:** export into a fixture with no git remote writes no source file and
does not fail; an existing `.agentic-flow-source` survives a re-export unchanged; doctor
warns on a stamped project with no origin; the file is absent from a `--dry-run` target.

**Stop if:** deriving the origin requires network access, or the file would need to become a
manifest entry to be written.

**DoD:** a fresh export records origin and ref; re-export preserves a hand-edited one; doctor
surfaces both.
**Commit:** `Record the standard's origin in exported projects`

---

## F-2 — Extract the payload applier into a shared, exported library

**Why second:** both directions must walk the manifest identically. Extracting *before*
writing the pull path is what prevents a second, subtly different copy — the exact drift
`accepted_risks.md` F-4 is about, and the drift #46 found for real.

**Inspect immediately before editing:** all of `scripts/export.sh`; the `export` self-test
group; `config/payload.tsv`; `scripts/check-payload-manifest.sh`.

**Approach:**

1. Create `scripts/lib/payload-apply.sh` — a sourced library, not an executable — holding
   manifest load, file expansion, per-entry classification, and version stamping.
   Signatures are in Part A's Interface section.
2. `export.sh` becomes a thin caller. **Its output must not change**: same `create` /
   `overwrite` / `exists →` lines, same counters, same summary, same next-steps text. The
   existing export tests are the regression suite — if any needs editing, the extraction
   changed behaviour and is wrong.
3. Keep Bash 3.2 compatibility: parallel arrays, no `mapfile`, no associative arrays, and
   care with empty arrays under `set -u` (`CLAUDE.md` → Gotchas).
4. Add `scripts/lib` to `config/payload.tsv` as `core preserve export`. Leave
   `scripts/export.sh` `source-only` — push-side init and placeholder work has no use in an
   adopted project.
5. Confirm the library is `bash -n` clean and shellcheck-clean; `make check` lints
   `scripts/*.sh` and `scripts/hooks/*.sh`, so extend those globs to `scripts/lib/*.sh` in
   both the `Makefile` and `templates/harness/Makefile` or the new file is unlinted.

**Failure-first tests:** the entire existing `export` group passes **unmodified**; a fresh
export contains `scripts/lib/payload-apply.sh`; the manifest guard fails if `scripts/lib`
exists but is undeclared; sourcing the library twice is harmless.

**Stop if:** preserving `export.sh`'s exact output requires the library to know it is being
called by `export.sh`. That means the seam is in the wrong place — move the rendering out,
keep only the classification in.

**DoD:** one applier, two callers-to-be, byte-identical export behaviour, library exported.
**Commit:** `Extract the payload applier from export.sh`

---

## F-3 — `agentic-flow status`, offline and read-only

**Why third:** the first user-visible value, it needs no network, and it is the safest thing
to ship first — a project can trust it before anything mutates.

**Inspect immediately before editing:** `scripts/doctor.sh` root resolution (`:24-27`) and
its version/candidate reporting; `scripts/lib/payload-apply.sh` from F-2;
`scripts/self-test.sh` group dispatcher (`should_run`, ~`:170`).

**Approach:**

1. Create `scripts/agentic-flow` with subcommand dispatch and `--help` / `--version`.
   Unknown subcommand → usage on stderr, `exit 2`. Add it to `config/payload.tsv` as
   `core preserve export`.
2. Resolve the project root by walking **up from `$PWD`** for `.agentic-flow-version`; stop
   at the filesystem root; `exit 2` with a clear message when not found. Note in a comment
   why this differs from `doctor.sh` (PATH invocation) and that the nearest stamp upward
   owns the subtree.
3. `status` reports, offline: installed version; candidate version if half-applied; every
   unresolved `*.agentic-new*` path; stack profile; adapter set present; recorded origin
   and ref, or a clear "no origin recorded" when absent.
4. **Fold in ROADMAP 3.2a's check:** run `git check-ignore` over the manifest's destination
   paths and report any that are git-ignored in the target. This is the trap that silently
   swallowed the payload in two separate adoptions (a blanket `.claude/` rule) — export
   succeeds, doctor passes on disk, and the harness is never committed. Mirror the same
   check in `doctor.sh`.
5. Exit codes per Part A: `0` clean, `1` action needed, `2` usage/environment.
6. Add a new `upgrade` self-test group to `scripts/self-test.sh` via `should_run upgrade`,
   register it in `SELF_TEST_GROUPS`, and add it to `make test-one`'s usage line, the
   `CLAUDE.md` Stack-profile table, and `ADOPTION.md`'s group list. The dispatcher's
   call-site validation will fail loudly if the label is wrong — that is intended.

**Failure-first tests:** `status` outside any adopted project exits 2 with a usable message;
from a nested subdirectory it finds the root above; a project with a pending candidate exits
1 and names the file; a payload path matched by a blanket `.claude/` gitignore rule is
reported and exits 1; a clean project exits 0; `status` makes **no network call** (assert
under a `PATH` with no `git` remote access, reusing the `path_without_tools` helper).

**Stop if:** the upward walk can escape a monorepo subtree and claim a parent project's
harness, or `status` needs to write anything.

**DoD:** `scripts/agentic-flow status` answers all three offline questions in `collector`
as-is, and reports the git-ignore trap.
**Commit:** `Add agentic-flow status`

---

## F-4 — `agentic-flow diff`

**Why fourth:** it introduces the fetch and the cache but still writes nothing to the
project, so the risky machinery lands one step before anything mutates.

**Inspect immediately before editing:** F-2's library; F-3's root resolution and origin
reading; `export.sh`'s dry-run path.

**Approach:**

1. Fetch the standard with `git clone --depth 1 --branch <ref> <origin>` into a `mktemp -d`
   cache, removed on `EXIT`. Apply the bounds from Part A's Failure behavior table.
2. Refuse to proceed when no origin is recorded, naming F-6's back-fill line. Do not guess.
3. Drive F-2's applier in **dry-run** mode with the fetched clone as source and the project
   as destination; render per-entry classification (`same` / `create` / `would-merge`) and a
   summary. Report the version delta as `installed → available`.
4. `--ref <ref>` overrides the recorded ref for one run without rewriting the file.
5. Exit `1` when changes are available, `0` when already current, `2` on fetch failure.

**Failure-first tests:** no origin recorded → exit 2 naming the back-fill; unreachable
origin → exit 2, no cache left behind, project untouched; a missing ref → exit 2 naming
origin and ref; against a same-version clone → exit 0, "already current"; **the project tree
is byte-identical before and after** every `diff` invocation (assert with a checksum over
the tree, not by eyeballing output).

**Stop if:** producing a legible diff needs the applier to expose more than the
classification — render in the CLI, decide in the library.

**DoD:** `diff` reports what would change, from the project, writing nothing.
**Commit:** `Add agentic-flow diff`

---

## F-5 — `agentic-flow upgrade`

**Why fifth:** everything it needs exists by now; it is the only mutating step and lands
last on purpose.

**Inspect immediately before editing:** F-2's library; F-4's fetch; `export.sh:142-190`
(merge candidates and the stamp rule).

**Approach:**

1. Reuse F-4's fetch, then drive the applier in **apply** mode. `--force` maps to the
   existing force policy; require `--yes` or a confirmation prompt before any write.
2. **Preserve the stamp rule exactly** (`export.sh:178-190`): advance
   `.agentic-flow-version` only when nothing is pending, otherwise write
   `.agentic-flow-candidate-version`. Do not reimplement — call F-2's stamping.
3. **Execute nothing that was fetched.** `export.sh:199-205` runs the target's
   `docs-index.sh` after copying; on the pull path that would be freshly fetched code, so
   print the command for the human instead. Threat model, mitigation (1).
4. **A changed origin is a hard stop.** If `.agentic-flow-source` differs from the origin
   recorded at the last upgrade, refuse and require `--force`. Threat model, mitigation (2).
5. Print the same next-steps guidance `export.sh` does when merge candidates remain.

**Failure-first tests:** an upgrade interrupted mid-walk leaves the *old* installed version
plus a candidate, and re-running resumes without duplicating candidates; an occupied merge
candidate with different content is never clobbered; a changed origin refuses without
`--force`; the fetched clone's scripts are never executed (fixture: a clone whose
`docs-index.sh` writes a sentinel — assert the sentinel is absent); a project with pending
candidates does not get its installed version advanced.

**Stop if:** resumability requires state beyond `.agentic-flow-candidate-version` and the
`.agentic-new` files already on disk. The existing two-file design is sufficient; anything
more is the transactional engine this brief excludes.

**DoD:** `collector` upgrades from `0.9.0+d507bf4` to current with the tool, conflicts land
as `.agentic-new`, and the installed version advances only once they are resolved.
**Commit:** `Add agentic-flow upgrade`

---

## F-6 — Document the path and back-fill existing adopters

**Why last:** it describes finished behaviour.

**Inspect immediately before editing:** `ADOPTION.md`; `README.md`; `docs/README.md`;
`templates/ci/README.md`; `CLAUDE.md` Stack-profile table.

**Approach:**

1. `ADOPTION.md` gains an **Upgrading** section: the three subcommands, the offline/network
   split, what `.agentic-new` means and how to resolve it, and the one-line back-fill for
   projects adopted before F-1 (write `.agentic-flow-source` by hand — two lines).
2. Document "adopt into an existing project" as a first-class path, not a footnote on the
   greenfield one, and call out the blanket-`.claude/` gitignore trap explicitly with
   `agentic-flow status` as the detector. This is ROADMAP 3.2a's documentation half.
3. Update ROADMAP 3.2 / 3.2a status with what shipped, per ROADMAP 4.3 — this file's
   reconciliation is part of close-out, not a later cleanup.

**Failure-first tests:** the docs-index stays derived and `make check` green; every
`METHODOLOGY.md §N` reference added still resolves (the `contracts` group already asserts
this); no new unfilled placeholder pattern is introduced.

**DoD:** a maintainer with a pre-F-1 project can get to a working `agentic-flow status` by
following `ADOPTION.md` alone.
**Commit:** `Document the upgrade surface and the back-fill for existing adopters`

---

## Status / Implementation status

<!-- Keep every `- **Field:**` value on ONE physical line. `plan-to-issues.sh --doc` rewrites
     the first line of a field and leaves wrapped continuation lines orphaned — it did
     exactly that here on 2026-07-25. Put context in prose below, not in a wrapped value. -->

- **Tracking issue:** [#53](https://github.com/wabkebab/agentic-flow/issues/53) — sub-issues: F-1 #54 · F-2 #55 · F-3 #56 · F-4 #57 · F-5 #58 · F-6 #59.
- **Approval:** wabkebab approved on 2026-07-25 via plan-to-issues --apply.
- **Verification evidence:** local whole-brief verification green on 2026-07-25: `make check`; `make test`; `make build`; `make test-one F=export`; `make test-one F=upgrade`; `scripts/doctor.sh --check --scope repo --skip-make-check`.
- **Review verdict:** pending.
- **Branch:** `codex/upgrade-surface` — created locally at the merged tip of #52; not yet pushed.

Approval covers both the design decisions recorded in Part A (ship the applier as exported
payload; track `main`, tag after this lands) and execution of the brief. Running
`plan-to-issues --apply` *is* the approval event under METHODOLOGY §6 — no issues, no
execution.
- **Related:** ROADMAP 3.2 (this plan), 3.2a (folded into F-3 and F-6), 1.5.5 (the version
  stamp this builds on), `accepted_risks.md` F-4 (the drift F-2 is structured to prevent).
- F-1 implemented in `d2a80c9` (`Fixes #54`): fresh exports record `.agentic-flow-source`; re-export preserves project-edited provenance; doctor reports/warns on source state.
- F-2 implemented in `ed25563` (`Fixes #55`): `scripts/lib/payload-apply.sh` is the shared exported applier and `export.sh` now renders around its classifications.
- F-3 implemented in `9f60b52` (`Fixes #56`): `scripts/agentic-flow status` is offline/read-only and mirrors the git-ignore payload trap into doctor.
- F-4 implemented in `8cd499f` (`Fixes #57`): `scripts/agentic-flow diff` fetches the recorded source/ref into a temp cache and reports read-only classifications.
- F-5 implemented in `cde2af2` (`Fixes #58`): `scripts/agentic-flow upgrade` applies under the `.agentic-new` policy, requires confirmation, executes nothing fetched, and refuses changed origins without `--force`.
- F-6 implemented in this branch: documentation/back-fill guidance and ROADMAP reconciliation.
