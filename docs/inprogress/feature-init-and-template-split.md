<!-- TRIAGE (first pass · 2026-07-05) -->
> **Type:** Feature · **Status:** 🚧 In progress
> Split the harness into pristine templates (`templates/harness/`) vs this repo's own
> filled-in instance, and add `scripts/init.sh` — a flag-driven (optionally interactive)
> adopter that replaces ADOPTION.md's manual checklist. Unblocks dogfooding. Approved and
> issued ([tracker #8](https://github.com/wabkebab/agentic-flow/issues/8)); base branch
> `main`. Next: executor works F-1 → F-7 in order.

# Feature — init script + template/instance split

## Tracker
- [ ] F-1 Export only the docs skeleton, never working docs — open (#1)
- [ ] F-2 Stamp the export version; doctor reports it — open (#2)
- [ ] F-3 Split pristine harness templates from the repo's live files — open (#3)
- [ ] F-4 Fill in this repo's own instance so it passes its own doctor — open (#4)
- [ ] F-5 `init.sh` non-interactive core (flags, token fill, presets, doctor) — open (#5)
- [ ] F-6 `init.sh` interactive layer for human runs — open (#6)
- [ ] F-7 Trim ADOPTION.md to a pointer; update README / METHODOLOGY — open (#7)

---

# Part A — Analysis

## Goal

Adopting agentic-flow into a repo — brand-new or existing — should be **one command**:
interactive when a human runs it, fully flag-driven when an agent or CI runs it, and
finished only when `doctor.sh` verifies the result. And the scaffold repo itself should be
a **true instance of its own standard** (real CLAUDE.md, real Makefile recipes, green
`doctor --check`), which today is structurally impossible because the same files are
simultaneously the shipped blank forms and this repo's live configuration.

## Current state

- **Adoption is an 8-step prose checklist** (`ADOPTION.md`) around `scripts/export.sh`.
  By this repo's own guiding principle (ROADMAP.md, "prose, so it mostly won't happen"),
  most of it won't be followed. `doctor.sh` verifies the end state but nothing *produces*
  that end state mechanically.
- **Template and instance are the same bytes.** Root `CLAUDE.md` (`<project name>`,
  "⚠️ WIRE THIS UP"), `AGENTS.md`, and `Makefile` are both the export payload
  (`scripts/export.sh:38-48` ITEMS list) and what agents read when working on this repo.
  Consequences, already observed:
  - The source repo's real `check` recipe shipped to targets and broke every fresh export
    (fixed in `244486b`, but the mechanism that caused it is still in place).
  - `doctor.sh --check` fails on this repo (placeholder `test`/`test-one`/`build`/`run`),
    so the scaffold can't pass its own adoption checklist.
  - The Tier 2 exit test (dogfood: run one real feature through the loop on this repo) is
    structurally blocked: filling in this repo's files corrupts the export payload.
- **`export.sh` allow-lists `docs/` wholesale** (ROADMAP 1.5.1): the moment this repo has a
  doc in `docs/inprogress/` — *this document* — it leaks into every export. This feature doc
  is itself the first victim; F-1 must land before anything else.
- **No version stamp** (ROADMAP 1.5.5): a target can't tell which scaffold version it
  started from, so drift can never be measured.

## Proposed approach

### Option A — split + flag-driven `init.sh` on top of `export.sh` (recommended)
Move the pristine forms to `templates/harness/{CLAUDE.md,AGENTS.md,Makefile}` with
machine-fillable tokens; `export.sh` ships those to the root of the target (source path ≠
destination path). Root copies become this repo's real instance. `scripts/init.sh` is a thin
orchestrator: parse flags → call `export.sh` → fill tokens → apply opt-out / stack preset →
stamp version → run `doctor.sh`. Interactivity is a TTY-only prompt layer that fills the
same flags — the core never requires a human.
*Trade-off:* two copies of CLAUDE.md/AGENTS.md/Makefile can drift (template vs instance).
Accepted: the drift surface is small, one-directional (contract changes are rare), and
called out as a gotcha; the alternative (one copy) is the current, worse disease.

### Option B — interactive wizard only, no split
Smaller diff, but it automates applying files that are still conflated — the wizard would
ship this repo's live config, re-creating the `244486b` class of bug. And an
interactive-only script can't be driven by the agents that are this system's primary
adopters, nor covered by self-test. Rejected.

**Recommendation:** Option A. The split is what makes the wizard safe, and the wizard is
what makes the split pay for itself (ADOPTION.md becomes executable; ROADMAP 1.5.1 and
1.5.5 land as steps of this brief).

## Out of scope / What NOT to build in this pass

- **Plugin/marketplace distribution** — a separate roadmap-level decision; this feature
  keeps the copy-based model and just hardens it.
- **Stack presets beyond `node` and `none`** — add python/go/rust when a real adoption
  needs them. No auto-derivation of recipes from `package.json` scripts in v1; the preset
  writes the standard recipes and init prints "verify these match your scripts."
- **CI workflow template** (ROADMAP 2.5), **issue-state sync** (2.3), **re-sync of drifted
  targets** (3.2) — the version stamp here is 3.2's prerequisite, not its implementation.
- **Automated tests of the interactive TTY path** — self-test covers the flag path only;
  the prompt layer is a thin shim over it by design.

## Open questions

- **Base branch: `main`** (resolved — human chose `main` over `tier1-enforcement` at
  approval). ⚠️ The Tier 1 + hardening work (including the `244486b` export fix and the
  push-guard hook) currently lives only on `tier1-enforcement`, unmerged. F-1 and F-3 build
  directly on that export behavior — so either `tier1-enforcement` must merge to `main`
  before/at the start of execution, or the executor branches from a `main` that already
  contains it. Flag to the human if `main` still lacks the Tier 1 commits when execution starts.
- Instance Makefile semantics for this repo (F-4) — proposal, confirm or amend:
  `test` = full `self-test.sh` (+ `shellcheck` over `scripts/` when installed);
  `test-one` = the same suite (no finer offline granularity exists; recipe says so);
  `build` = `export.sh --dry-run` into a temp dir (validates the payload assembles);
  `run` = `doctor.sh` report (the scaffold's "app" is its checks).

---

# Part B — Implementation Brief

> **Audience:** an implementing agent (**Codex** by default). Each step is independently
> shippable and ordered so the **riskiest / most foundational work lands first.** Do the
> steps in order; **one logical commit per step; do not bundle.** Stage files by name
> (never `git add -A`). Use verbose, *why*-first commit bodies. This brief carries the
> **approach and insights — not the code.**

## Branch
`feature-init-and-template-split` off `main` (confirmed at approval — but see the base-branch
note in Part A's Open questions: `main` must contain the Tier 1 work before execution).

## Definition of done (whole brief)

- `scripts/init.sh <dir> --name foo --stack node --yes` on an empty dir yields: no unfilled
  tokens, name stamped, version stamp present, hooks wired, `make check` green in the
  target, `doctor.sh --check` green except recipes the preset can't know.
- The same command against a repo with a pre-existing `CLAUDE.md` preserves it and writes
  `.agentic-new` (existing `export.sh` merge flow intact).
- The export payload provably contains no instance content: self-test edits root
  `CLAUDE.md`, plants a doc in `docs/inprogress/`, exports, and asserts the target got the
  pristine template and no working docs.
- **This repo passes `scripts/doctor.sh --check` fully** — the dogfood blocker is gone.
- `make check` and `make test` green; ADOPTION.md no longer contains a manual checklist
  that duplicates what `init.sh` does.

## Verification commands
```bash
make check                      # per step (harness sanity; enforced by the Stop hook)
scripts/self-test.sh            # per step — every step below extends it
scripts/doctor.sh --check       # F-4 onward: must be fully green on this repo
```
Manual, end of brief: run `init.sh` into a scratch dir twice (empty dir; dir with a
pre-existing CLAUDE.md) and read the doctor report it prints.

## Gotchas (read before starting)

- **bash 3.2** is the floor (macOS `/bin/bash`): no `mapfile`, no `declare -A`, and
  `"${arr[@]}"` on an *empty* array trips `set -u`. `export.sh` shows the working idioms.
- The Stop hook runs `make check`, which runs `self-test.sh` — if you change export
  behavior and the self-test together in an inconsistent state, you can't end the turn.
  Change test + behavior within the same step.
- Hooks block `git add -A`/`.` and `git push` mechanically. Commit with `git-codex`.
- `export.sh --help` prints itself via `sed -n '2,18p'` — if you grow its header comment,
  adjust that range or help output truncates/overflows silently.

---

## Step 1 — Export only the docs skeleton (ROADMAP 1.5.1)
**Why first:** every later step adds self-tests that export; until this lands, *this very
document* leaks into each test export and into any real adoption. It is also the smallest
independent fix.

**Approach:**
1. In `scripts/export.sh`, replace the wholesale `docs` entry in `ITEMS` with the skeleton
   only: `docs/templates`, `docs/README.md`, `docs/accepted_risks.md`, and the four
   `.gitkeep`s (`backlog/`, `inprogress/`, `done/`, `done/security/`). Everything else under
   `docs/` is excluded by construction (allow-list, not deny-list — the deny-list is the
   "silent gap" ROADMAP 2.5 warns about).
2. The existing post-export `docs-index.sh` run already reseeds the target's index to empty;
   keep it — it's what makes the copied README's generated block correct again.

**Test:** extend `self-test.sh` export section: create `docs/inprogress/dummy-feature.md`
inside a *copy* of the scaffold? No — simpler and honest: plant the dummy doc in the real
`docs/inprogress/` under a `trap`-cleaned name, export, assert it is absent from the target
and that `docs/templates/feature-analysis.md` is present. (`make check` runs docs-index
`--check`; regenerate/restore the index inside the test or the gate goes red — cleanest is
to plant, export, assert, remove, and never run docs-index while the dummy exists.)

**DoD:** a fresh export contains the four stage dirs, templates, README (empty index),
accepted_risks.md — and no other `docs/` content, proven by self-test.
**Commit:** `Export only the docs skeleton, never working docs`

---

## Step 2 — Stamp the export version; doctor reports it (ROADMAP 1.5.5)
**Why second:** one line that can't be retrofitted — every export that happens without it
loses history forever. Later steps' self-tests also want to assert its presence.

**Approach:**
1. `export.sh` writes `.agentic-flow-version` at the target root containing
   `git -C "$SRC" rev-parse --short HEAD` (fall back to `unknown` outside a git checkout —
   keep the script usable from a tarball).
2. `doctor.sh` prints the stamp when present (`ok  scaffold version: <sha>`), warns when
   absent. A warning, not a failure — pre-stamp adoptions exist.
3. Add the file to the export summary output so humans see it happened.

**Test:** self-test asserts the file exists in a fresh export and matches
`git rev-parse --short HEAD` of the source.

**DoD:** every fresh export carries the stamp; doctor reports it.
**Commit:** `Stamp exports with the source scaffold version`

---

## Step 3 — Split pristine harness templates from the repo's live files
**Why third:** the foundational structural change; everything after (instance fill, init)
depends on the two copies existing. Riskiest step — it changes what `export.sh` ships.

**Approach:**
1. Create `templates/harness/CLAUDE.md`, `templates/harness/AGENTS.md`,
   `templates/harness/Makefile` — byte-for-byte the *current* root files, with one change:
   replace `<project name>` placeholders with the single machine-fillable token
   `{{PROJECT_NAME}}` (both files' H1 lines). v1 has exactly one token; do not invent more.
2. Teach `export.sh` a source→destination mapping: these three ship *from*
   `templates/harness/` *to* the target root. bash-3.2-safe idiom: extend `ITEMS` entries
   to `src=dst` pairs (paths here never contain `=`) and split on the first `=`; entries
   without `=` keep src=dst. `templates/harness/` itself must NOT be exported as a
   directory (targets get the filled root files only — exclude it the same allow-list way
   `docs/` is handled after Step 1).
3. Root `CLAUDE.md`/`AGENTS.md`/`Makefile` are untouched in this step (still placeholders);
   only the payload source moves. Add a header comment in each `templates/harness/` file:
   "pristine form — shipped by export.sh; the repo-root copy is this repo's own instance;
   contract changes must land in both."
4. `doctor.sh`: fail if the *target's* `CLAUDE.md`/`AGENTS.md` still contain `{{` — an
   unfilled token means init/fill never ran. (This repo's root files won't contain tokens
   after F-4.)

**Test:** self-test appends a sentinel line to root `CLAUDE.md` (restore via trap), exports,
asserts the target's `CLAUDE.md` lacks the sentinel and *contains* `{{PROJECT_NAME}}` —
proving the payload comes from `templates/harness/`, not the root.

**DoD:** exports ship pristine tokenized forms regardless of root-file state; doctor flags
unfilled tokens.
**Commit:** `Ship harness files from pristine templates, not the repo root`

---

## Step 4 — Fill in this repo's own instance; pass our own doctor
**Why fourth:** the payoff of Step 3 and the dogfood unblock. Safe only now that root files
are no longer the payload.

**Approach:**
1. Root `CLAUDE.md`: project name `agentic-flow`; Stack profile table describing the *real*
   targets (see Open questions proposal); Architecture (one paragraph: export → init →
   doctor → hooks, where each lives); Gotchas — at minimum: the template/instance dual-copy
   rule, the bash 3.2 floor, the `sed`-range help trick, and "the Stop hook runs self-test,
   so export behavior and its tests must change together."
2. Root `AGENTS.md`: project name; keep the two-agent contract (Codex executes this repo).
3. Root `Makefile`: real `test` / `test-one` / `build` / `run` per the Open-questions
   proposal (as confirmed by the human). No `TODO: define` strings remain.
4. `docs/accepted_risks.md`: add an entry (use `docs/templates/accepted-risk-entry.md`) for
   the accepted template↔instance drift risk, revisit-if: "a third copy appears, or a
   contract change ships in only one copy."

**Test:** `scripts/doctor.sh --check` exits 0 on this repo — add that single line to
self-test's scaffold-only section (it is the regression test for "we conform to
ourselves"). Note: doctor runs `make check`, which runs self-test — doctor inside self-test
must therefore skip or shallow that entry to avoid recursion; gate it with an env guard
(e.g. `AGENTIC_SELFTEST=1` set by self-test, checked by doctor's make-check entry).

**DoD:** this repo passes its own full adoption checklist.
**Commit:** `Make agentic-flow a conformant instance of its own standard`

---

## Step 5 — `init.sh` non-interactive core
**Why fifth:** the user-visible feature; everything it composes now exists.

**Approach:**
1. `scripts/init.sh [flags] <target-dir>` — flags: `--name <kebab>` (required
   non-interactively), `--stack node|none` (default `none`), `--claude-only`, `--git-init`
   (allowed only when target isn't a git repo), `--yes` (suppress prompts; with missing
   required flags → error, never guess), `--dry-run` (delegates to export's).
2. Sequence: validate target (refuse the scaffold repo itself, mirror `export.sh:66`) →
   optional `git init` → call `export.sh` (do not reimplement copying) → fill
   `{{PROJECT_NAME}}` in the target's `CLAUDE.md`/`AGENTS.md` **and in any freshly written
   `.agentic-new` siblings** (pre-existing files are never touched) → `--claude-only`:
   replace the `<!-- OPT-OUT … -->` comment block in both files with the standard opt-out
   sentence from METHODOLOGY §1 → `--stack node`: uncomment/write the npm recipes in the
   target Makefile's `test`/`test-one`/`build`/`run` (check keeps its prefilled harness
   sanity), then print "verify these match package.json" → run `doctor.sh` (report mode)
   and print its output as the next-steps summary.
3. Exit code: nonzero only on structural failures (export failed, tokens still present,
   hooks not wired). Placeholder recipes with `--stack none` are expected, not an error.
4. Stack detection (`package.json` present → default answer `node`) only *chooses defaults*;
   it never overrides an explicit `--stack`.
5. bash 3.2 discipline throughout (see Gotchas).

**Test:** self-test, scaffold section: (a) init into an empty scratch dir with
`--name demo-proj --stack none --yes`; assert no `{{` anywhere, name present in both files,
version stamp present, `make check` green *in the target*; (b) init into a dir with a
pre-existing differing `CLAUDE.md`; assert original preserved, `.agentic-new` exists and is
token-filled; (c) missing `--name` with `--yes` → nonzero exit and a usage message.

**DoD:** one command takes an empty dir or an existing repo to a doctor-verified harness
without a human answering anything.
**Commit:** `Add init.sh: one-command, flag-driven scaffold adoption`

---

## Step 6 — `init.sh` interactive layer
**Why sixth:** sugar over a working core; must never be load-bearing.

**Approach:**
1. When stdin is a TTY and `--yes` is absent, prompt for each *missing* flag: name
   (validate kebab-case, non-empty), stack (default from detection), claude-only (default
   no), git-init (asked only when applicable). Every prompt states the flag it fills, so
   the interactive run teaches the scriptable one.
2. Non-TTY without `--yes` behaves as `--yes` (CI pipes must never hang on a prompt).
3. No prompt may exist without a corresponding flag — enforced by review, stated in the
   script header.

**Test:** self-test covers only the non-TTY fallback (pipe stdin from `/dev/null`, assert
no hang and same result as `--yes`). The TTY path is manually verified once (`make run`
n/a — just run it) and stays out of automated scope per Part A.

**DoD:** a human running bare `init.sh <dir>` gets a short interview; agents and CI are
unaffected.
**Commit:** `Add interactive prompt layer to init.sh`

---

## Step 7 — Make init the documented path; trim the prose it replaces
**Why last:** documentation follows behavior; doing it earlier documents vapor.

**Approach:**
1. `ADOPTION.md`: reduce to — required tools, `scripts/init.sh` usage + flags, "doctor.sh
   is the verifier," and the CI note. Delete the 8-step manual checklist (init *is* the
   checklist now; keeping both is the drift the roadmap forbids).
2. `README.md` "Bootstrap a new project": lead with `init.sh`; keep `export.sh` documented
   as the low-level/manual path. Update the tree listing (templates/harness/, init.sh).
3. `METHODOLOGY.md` §8: add init.sh to shipped guardrails, one line.
4. Regenerate the docs index; move nothing (this doc stays in `inprogress/` until the
   whole Tracker is ticked and verified).

**Test:** none beyond `make check` (docs-index freshness is already gated). Grep-assert in
self-test that ADOPTION.md no longer contains the literal "Checklist" numbered section —
optional, skip if it feels like ceremony.

**DoD:** a newcomer reading README/ADOPTION is routed to one command; no duplicate manual
checklist survives.
**Commit:** `Document init.sh as the adoption path; trim ADOPTION.md to match`

---

## Status / Implementation status
- **Tracking issue:** [#8](https://github.com/wabkebab/agentic-flow/issues/8) — sub-issues:
  F-1 #1 · F-2 #2 · F-3 #3 · F-4 #4 · F-5 #5 · F-6 #6 · F-7 #7.
- **Approved:** issues created via `plan-to-issues --apply` (the approval event). Base branch
  `main`.
- Steps not yet started. Executor closes each via a PR with `Fixes #N`, records the commit
  SHA per step here, and ticks the matching F-N box in the Tracker above.
