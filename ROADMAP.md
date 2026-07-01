# Roadmap — evolving the agentic-flow standard

> Planned improvements to **agentic-flow itself** (not to projects built with it — that's
> why this lives at the repo root, outside `docs/`, which gets copied into new projects).
>
> **Guiding principle:** the biggest enemy of this system is **staleness from manual
> bookkeeping** (the source repo's `todo/`/`done/` folders were set up and never used;
> closure was inferred from commit messages). Every item below is ranked by how much it
> fights that — by converting a convention into a guardrail, or replacing hand-maintenance
> with derivation.

## Status

- ✅ **Tier 1 — enforcement backbone** — done, branch `tier1-enforcement` (`4556f2d`).
  Executable Stack profile (`Makefile`), enforced hooks (`make check` Stop gate + `git add`
  guard), generated docs index. Tiers 2–3 build on this.
- ⬜ **Tier 2 — close the loop honestly** — below.
- ⬜ **Tier 3 — durability & scale** — below.

---

## Tier 2 — close the loop honestly

Tier 1 made the gates real; Tier 2 makes the *reporting* real — so "done" and "approved"
mean something verifiable, and the loop can't double-fire or skip review.

### 2.1 Capture verification evidence (don't just assert it)
- **Problem:** implementation briefs say "`make check` / `make test` must be green," but
  nothing records that they were actually run. "Tests pass" is currently a claim, not a fact.
- **Fix:** require the executor to paste the `make check` / `make test` output (or a CI run
  link) into the doc's **Status / Implementation status** section — or the PR — before a step
  counts as done. A step's checkbox can't be ticked without evidence attached.
- **Artifacts:** a "Verification evidence" sub-section in the Security/Feature templates'
  Status block; a note in `AGENTS.md` step 4 making evidence part of the commit/PR.
  Optionally a hook or `docs-index.sh --check` rule that flags ticked steps lacking evidence.
- **Done when:** a closed step in any doc carries the command output or CI link that proves it.

### 2.2 Make `plan-to-issues.sh` idempotent
- **Problem:** running `--apply` twice creates a *second* full set of issues. The script
  warns about this but doesn't prevent it — one fat-finger doubles the tracker.
- **Fix:** before creating, search for an existing tracking issue by title (`gh issue list
  --search`) or stamp each generated issue with a spec hash in its body; on a match, refuse
  with a diff ("tracker #N already exists for this spec") instead of duplicating. Add a
  `--check`/`--diff` mode that reports what *would* change vs. existing issues.
- **Artifacts:** `scripts/plan-to-issues.sh` (guard + hash stamp); SKILL.md note.
- **Done when:** a second `--apply` of the same spec is a no-op (or a reconcile), not a dupe.

### 2.3 docs-index issue-state sync (the "powerful layer" deferred from Tier 1)
- **Problem:** a doc's `## Tracker` checkboxes are still ticked by hand; "closure inferred
  from commit messages" persists. The index reflects TRIAGE headers but not live issue state.
- **Fix:** extend `scripts/docs-index.sh` with a `--with-issues` mode that reads each doc's
  linked tracking issue, queries sub-issue open/closed state via `gh`, and ticks the Tracker
  boxes accordingly — and flags (or, behind a flag, auto-moves) a doc to `done/` once every
  sub-issue is closed. Read-only by default; mutation behind an explicit flag.
- **Artifacts:** `scripts/docs-index.sh` (`--with-issues`); needs a stable doc→tracker link
  convention (already present in the Status section's `[#NN](url)`).
- **Done when:** `--with-issues` makes a doc's Tracker mirror GitHub without anyone ticking boxes.
- **Note:** can't be tested in an offline scaffold; verify against a real repo with `gh`.

### 2.4 Post-execution review template + a real approval artifact
- **Problem:** I templated the three *input* docs, but the *review that comes back* after
  execution (the `fable_review.md` / `310526_opus48.md` equivalent) isn't standardized — and
  "human approves the plan" is a verbal step with no marker, so approval is a vibe, not an event.
- **Fix (two parts):**
  - A lightweight **review template** (`docs/templates/review.md`): severity-graded findings
    on the *executed* code, with a findings tracker, so a hand-written architectural review
    has the same shape as `/code-review` output. (For routine reviews, prefer `/code-review`;
    reserve the template for architecture-level passes.)
  - An **approval gate as an event:** make "running `plan-to-issues`" the approval boundary
    (issues don't exist until the human says go), and/or an `approved` label / a checked
    "Approved-by" line in the doc's Status. No issues, no execution.
- **Artifacts:** `docs/templates/review.md`; an "Approval" line in the Security/Feature
  templates' Status; METHODOLOGY §2/§6 wording.
- **Done when:** every execution traces to an explicit approval artifact, and reviews land in
  a consistent, trackable shape.

---

## Tier 3 — durability & scale (defer until felt)

Tier 3 keeps the system honest *over time* and *across many projects*. Don't pre-build it —
adopt each piece when the pain is real.

### 3.1 Accepted-risk revisit mechanism
- **Problem:** `accepted_risks.md` entries say "revisit if scale/threat-model changes," but
  nothing ever triggers the revisit. Accepted risks silently rot into forgotten risks.
- **Fix:** a scheduled agent (`/schedule`) that periodically re-reads `accepted_risks.md`,
  re-checks each entry's "Revisit if" conditions against current code/scale, and opens an
  issue (or pings) when one trips. At minimum, a date-stamped review cadence.
- **Artifacts:** a routine definition; a convention that every accepted-risk entry has
  machine-checkable-ish "Revisit if" triggers.
- **Done when:** no accepted risk goes more than one cadence without a deliberate re-look.

### 3.2 Anti-drift for the scaffold itself
- **Problem:** because agentic-flow is **copy-paste**, projects diverge from the canonical
  standard over time; there's no way to tell which version a project started from or whether
  it still conforms.
- **Fix:** a **version stamp** in `METHODOLOGY.md` (e.g. `Standard version: 1.x`) and continued
  expansion of **`scripts/doctor.sh`**, which now checks required files, hook wiring, required
  tools, real `make` targets, and docs-index freshness. Future work: detect hand-edited
  templates and add a re-sync helper that diffs a project's harness against the current
  standard.
- **Artifacts:** version line in `METHODOLOGY.md`; `scripts/doctor.sh`; a CI/`--check` entry.
- **Done when:** `scripts/doctor.sh` passes on a conformant project and names the gaps on a drifted one.

### 3.3 Wire in agent memory
- **Problem:** durable decisions (the chosen stack profile, accepted risks, recurring review
  themes, the commit contract) get re-derived every session; the methodology *mentions* memory
  but nothing wires it in.
- **Fix:** a convention (and a bootstrap step) that persists the project's durable facts to
  agent memory — the Stack-profile summary, opt-outs, standing review themes — so sessions
  start informed instead of re-reading everything.
- **Artifacts:** a "Memory" section in `CLAUDE.md`; a bootstrap checklist item.
- **Done when:** a fresh session knows the project's stack, opt-outs, and contract without re-deriving them.

---

## Suggested order

Tier 2 in order **2.2 → 2.1 → 2.4 → 2.3** (2.2 is small and removes a live footgun; 2.3 needs
a live `gh` repo to verify, so it lands last in the tier). Tier 3 only as each pain is felt.
Every item should itself go through the loop: a Feature doc in `docs/inprogress/` with an
implementation brief, then `plan-to-issues`.
