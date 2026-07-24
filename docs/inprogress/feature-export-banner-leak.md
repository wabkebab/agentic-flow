<!-- TRIAGE (first pass · 2026-07-24) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> `export.sh` ships a maintainer-only banner into every adopted project's `CLAUDE.md`,
> `AGENTS.md`, and `Makefile`. Found while adopting the scaffold into `collector`; three
> known adopters already carry it. Awaiting approval to execute.

# Feature — Stop exporting the harness-template maintainer banner

## Tracker
- [ ] F-1 Move the maintainer note out of the exported harness templates, with a regression assertion — open

---

# Part A — Analysis

## Goal

An adopted project's `CLAUDE.md` is the first thing an agent reads. Right now the first two
lines it reads are addressed to somebody else — a maintainer of *this* scaffold, working in
*this* repo, on files the adopted project does not have. The adopter's own title is on line 4.

The banner is correct and useful where it was written. It is noise, and mildly misleading,
everywhere it lands.

## Current state

The banner lives in exactly three files, at lines 1–2 of each:

- `templates/harness/CLAUDE.md:1-2`
- `templates/harness/AGENTS.md:1-2`
- `templates/harness/Makefile:1-2`

```
# Pristine form - shipped by export.sh; the repo-root copy is this repo's own instance;
# contract changes must land in both.
```

`config/payload.tsv` maps each of those three to a project-root destination
(`templates/harness/CLAUDE.md → CLAUDE.md`, and so on). `export.sh` is a **pure copier** —
`cp -p` at `scripts/export.sh:141`, `:159`, `:167`, with no content transformation anywhere.
So whatever is in the template is what the adopter gets, byte for byte.

`init.sh` *does* transform content (`fill_project_name`, `scripts/init.sh:217-221`) and
verifies its own work afterwards (`:284` dies on unfilled tokens). That is a tempting place
to hang a fix, and it is the wrong one: **`export.sh` is a supported entry point on its own.**
`ADOPTION.md` calls it "the source-repository, low-level non-destructive copy command for
manual or unusual adoptions", so a strip that lives only in `init.sh` leaves a hole that is
open exactly when someone is doing something unusual.

`scripts/self-test.sh` asserts the exported payload's *presence* extensively
(`assert_file "$TARGET/CLAUDE.md"` and neighbours, `:187-212`) but never asserts anything
about exported **content**. That is why this shipped: nothing was looking.

The banner's message is already carried, in prose, where agents actually read it — the
Gotchas section of this repo's own `CLAUDE.md`:

> Contract changes to `CLAUDE.md`, `AGENTS.md`, or `Makefile` usually need matching edits
> in both the repo-root instance and `templates/harness/`.

**Known blast radius.** Every project adopted so far carries these two lines in three files:
`film-festival-manager`, `print-traffic`, and `collector` (stripped manually during the
2026-07-24 adoption, before its first commit).

## Proposed approach

### Option A — Delete the banner (do not replace it)

Rely on the `CLAUDE.md` Gotcha quoted above, which already says the same thing and is read
first by contract.

Cheapest possible change. The cost is that the reminder disappears from the point of edit: an
agent opening `templates/harness/Makefile` to change a target sees nothing telling it the root
`Makefile` needs the same edit.

### Option B — Move it to a source-only `templates/harness/README.md` (recommended)

Keep the note, put it in a file that structurally cannot be exported.

`check-payload-manifest.sh:44` scans `templates/harness` as a curated area and fails on any
file there that no manifest row covers — so a new file cannot simply be dropped in. But the
manifest already models exactly this case: `source-only` disposition, used today by
`scripts/export.sh` and `.claude/settings.local.json`. One row registers the README as
deliberately non-exported, and the existing manifest check then *enforces* that.

This is better than a strip step in `export.sh` for the same reason it is better than a fix in
`init.sh`: it makes the guarantee structural instead of textual. A strip would match on the
banner's wording, so rewording the banner would silently stop stripping it — a gate that is
green because it stopped looking, which is the failure mode `METHODOLOGY.md` §11.1 names
directly.

### Option C — Strip the banner during export

Rejected. Adds content transformation to a pure copier, and couples the copier to the exact
prose of a comment. See above.

**Recommendation: Option B.** It preserves the information, costs one file and one manifest
row, and reuses a mechanism the manifest check already enforces. Note honestly that a sibling
README is a *weaker* prompt than a comment inside the file being edited — the thing that
actually prevents the two copies drifting is the `CLAUDE.md` Gotcha plus review, not a comment.
The banner was never load-bearing; it was a note that leaked.

## Interface (before the implementation)

No runtime interface changes. The contract being changed is the export payload's content:

```
templates/harness/CLAUDE.md   line 1 becomes:  # CLAUDE.md — {{PROJECT_NAME}}
templates/harness/AGENTS.md   line 1 becomes:  # AGENTS.md — {{PROJECT_NAME}}
templates/harness/Makefile    line 1 becomes:  # Stack profile — the ONE place …

config/payload.tsv gains one row:
  templates/harness/README.md   templates/harness/README.md   source-only   none   source-only
```

New self-test invariant, stated as a property rather than a string match:

```
for each exported harness file in {CLAUDE.md, AGENTS.md, Makefile}:
    first non-empty line is that file's own title//heading
    file contains no reference to "export.sh" or "repo-root copy"
```

## Threat model (one paragraph)

No new trust boundary, no untrusted actor, no data at risk. The leaked text is a comment about
repository layout — it names `export.sh` and the existence of a root copy, neither of which is
a secret. The honest answer is: nothing. The cost of this bug is agent attention and a
confusing first impression, not exposure.

## Failure behavior

No external calls, no network, no I/O beyond local file copies that `export.sh` already
performs. Nothing to bound that is not already bounded.

| External call | On timeout | On malformed response | On partial success |
|---------------|-----------|-----------------------|--------------------|
| _none_        | n/a       | n/a                   | n/a                |

## Out of scope / What NOT to build in this pass

- **Retro-fixing the three already-adopted projects.** They will not self-heal, but each is a
  three-file, two-line deletion in a repo with its own review loop, and sweeping other repos
  from this one is not this pass's job. The remediation, for the record:

  ```bash
  perl -0pi -e 's/^# Pristine form - shipped by export\.sh;[^\n]*\n# contract changes must land in both\.\n\n//' \
    CLAUDE.md AGENTS.md Makefile
  ```

- **A `doctor.sh` check that flags the leaked banner in an adopted project.** Tempting, since
  it would find the three above automatically. But it is a permanent check for a transient,
  cosmetic condition — it would still be running years after the last affected repo is clean.
  Deliberately declined; if a fourth adopter turns up dirty, revisit.
- **A general "exported content is adopter-appropriate" linter.** The regression assertion in
  F-1 covers the three files that actually have this problem. A framework for a class of one
  is speculative.
- **Auditing the other exported payload files** (`METHODOLOGY.md`, `ADOPTION.md`, the docs
  templates) for similar source-repo addressing. Worth a look eventually; not blocking, and
  bundling an open-ended audit into a two-line fix is how a Fast Fix becomes a project.

## Open questions

- None blocking. Option B is a one-row manifest addition using an existing disposition; if the
  reviewer prefers Option A, drop the README and the manifest row from Step 1 and the rest of
  the step is unchanged.

---

# Part B — Implementation Brief

> **Audience:** an implementing agent (**Codex** by default). Each step is independently
> shippable and ordered so the **riskiest / most foundational work lands first.** Do the
> steps in order; **one logical commit per step; do not bundle.** Stage files by name
> (never `git add -A`). Use verbose, *why*-first commit bodies. This brief carries the
> **approach and insights — not the code.**

## Branch

Base: `main`. One branch and one PR: `feature-export-banner-leak`. This brief is a single
step, so it is one commit on that branch, closing its issue via `Fixes #N`.

## Definition of done (whole brief)

A freshly exported project's `CLAUDE.md`, `AGENTS.md`, and `Makefile` open with their own
title and contain no text addressed to a scaffold maintainer; `make check` and `make test`
green; the new self-test assertion fails if the banner is reintroduced.

## Verification commands

```bash
make check                     # per step; also enforced by the Stop hook
make test-one F=scripts/self-test.sh
make test                      # end of brief: full suite + shellcheck
```

---

## Step 1 — Move the maintainer note out of the exported harness templates

**Why first:** it is the only step. Ordered internally so the test that catches the bug is
written before the deletion that fixes it (§11.4).

**Approach (do NOT write code yet):**

1. **Write the failing assertion first.** In `scripts/self-test.sh`, in the export-invariants
   section alongside the existing `assert_file "$TARGET/CLAUDE.md"` block (`:187-212`), add a
   content assertion over the three exported harness files. Assert the *property*, not the
   banner's exact wording: the first non-empty line is the file's own heading, and the file
   contains no `export.sh` / `repo-root copy` reference. Matching the banner string verbatim
   would produce a test that passes as soon as someone rewords the banner — the same
   green-for-the-wrong-reason trap this doc rejects Option C over.
   Follow the existing `fail`/`assert_*` helper conventions (`:19-30`) rather than adding a
   new assertion style. Confirm it **fails** against the current templates before continuing.
2. **Create `templates/harness/README.md`** carrying the note the banner used to carry: these
   are the pristine forms shipped by `export.sh`, the repo-root `CLAUDE.md` / `AGENTS.md` /
   `Makefile` are this repo's own filled-in instance, and a contract change lands in both.
   Cross-reference the existing `CLAUDE.md` Gotcha rather than restating it in full.
3. **Register it `source-only` in `config/payload.tsv`** — scope `source-only`, merge-policy
   `none`, disposition `source-only`, matching the existing `scripts/export.sh` and
   `.claude/settings.local.json` rows. This is required, not optional:
   `check-payload-manifest.sh:44` scans `templates/harness` as a curated area and fails on any
   unclassified file in it. Getting this wrong turns `make check` red, so run it before moving on.
4. **Delete lines 1–2 (and the trailing blank) from all three templates.** Each file's own
   heading becomes line 1. `templates/harness/Makefile` must still begin with the
   `# Stack profile — the ONE place …` comment block that the rendered profile expects.
5. **Do not touch the repo-root `CLAUDE.md`, `AGENTS.md`, or `Makefile`.** They never carried
   the banner — this is one of the rare harness-contract changes that is genuinely
   template-only, so the usual "edit both copies" gotcha does *not* apply here.

**Test:** the assertion from sub-step 1, extended if needed so it covers all three files. It
must fail before sub-step 4 and pass after. **Failure path first:** the case that matters is
not "the export succeeded" — it is "the export succeeded *and quietly carried maintainer-only
content*", which is what shipped. Assert on content, and assert on all three files
independently; the banner reached three files precisely because a per-file human check was
done once and generalised.

**DoD:** `scripts/export.sh --dry-run` into a scratch dir, then confirm the three exported
files open with their own headings; `templates/harness/README.md` exists and is **not** in the
exported payload; `make check` and `make test` green.

**Commit:** `Stop exporting the harness-template maintainer banner`

---

## Status / Implementation status

- **Tracking issue:** _not yet created_ — run the `plan-to-issues` skill once this is approved.
- **Approval:** pending.
- **Verification evidence:** pending execution.
- **Review verdict:** pending.
- Step not yet started. The executor closes it via a PR with `Fixes #N`, records the commit SHA
  here, and ticks F-1 in the Tracker above.
