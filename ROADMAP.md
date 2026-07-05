# Roadmap — evolving the agentic-flow standard

> Planned improvements to **agentic-flow itself** (not to projects built with it — that's
> why this lives at the repo root, outside `docs/`, which gets copied into new projects).
>
> **Guiding principle:** the biggest enemy of this system is **staleness from manual
> bookkeeping** (the source repo's `todo/`/`done/` folders were set up and never used;
> closure was inferred from commit messages). Every item below is ranked by how much it
> fights that — by converting a convention into a guardrail, or replacing hand-maintenance
> with derivation. Corollary: when a fix *adds* bookkeeping (paste this, tick that), prefer
> the version where the fact is **derived** (CI, `gh`, a script) even if it lands later.

## Status

- ✅ **Tier 1 — enforcement backbone** — done, branch `tier1-enforcement` (`4556f2d`).
  Executable Stack profile (`Makefile`), enforced hooks (`make check` Stop gate + `git add`
  guard), generated docs index. Tiers 2–3 build on this.
- ⬜ **Tier 1.5 — hardening the shipped guardrails** — small, batched; below.
- ⬜ **Tier 2 — close the loop honestly** — below.
- ⬜ **Tier 3 — durability & scale** — below.

---

## Tier 1.5 — hardening what already shipped (small, batch these)

Defects and gaps *in the Tier 1 guardrails themselves*. Each is under an hour; none needs
a Feature doc — one commit each, with a self-test where noted.

### 1.5.1 Don't export the scaffold's own working docs ⚠️ blocks dogfooding
- **Problem:** `export.sh` allow-lists `docs` wholesale — including `inprogress/`,
  `backlog/`, and `done/`. The moment this repo follows its own closing rule ("every
  roadmap item goes through the loop: a Feature doc in `docs/inprogress/`"), that doc
  leaks into **every future export**. Today it only works because `docs/` is empty.
- **Fix:** export only the skeleton — `docs/templates/`, `docs/README.md` (with a freshly
  seeded empty index), `docs/accepted_risks.md`, and the empty stage dirs (`.gitkeep`s).
  Exclude all other `docs/` content.
- **Done when:** `self-test.sh` puts a dummy doc in `docs/inprogress/`, exports, and
  asserts it is absent from the target. Until this lands, dogfooding (the Tier 2 exit
  test) is blocked.

### 1.5.2 check-gate log path collides across sessions
- **Problem:** `check-gate.sh` writes to the fixed path `/tmp/agentic-check-gate.log` —
  two concurrent sessions (or two projects) clobber each other's failure output, so the
  agent may be shown the *other* project's errors.
- **Fix:** per-repo path (e.g. `${TMPDIR:-/tmp}/agentic-check-gate.<repo-hash>.log`) or
  `mktemp`.

### 1.5.3 git-add guard misses flags between `git` and `add`
- **Problem:** the regex requires `git` immediately followed by `add`, so the common,
  innocent `git -C <path> add -A` (and `git -c k=v add -A`) passes the guard. The hook
  guards against sloppiness, not adversaries — but `-C` is everyday usage, not evasion.
- **Fix:** allow intervening `-C <path>` / `-c <k=v>` args in the pattern; extend the
  self-test with these cases.

### 1.5.4 self-test doesn't exercise check-gate.sh at all
- **Problem:** `self-test.sh` covers export, the git-add guard, and plan-to-issues
  validation — but the Stop gate (the highest-leverage hook) has zero coverage, including
  its no-Makefile no-op and its `stop_hook_active` loop-safety path.
- **Fix:** fixture dir with a Makefile whose `check` passes/fails on demand; assert
  exit 0 / exit 2 / warn-and-allow for the three paths.

### 1.5.5 Stamp the export version (pulled forward from 3.2)
- **Problem:** a target has no record of which scaffold version it started from, so drift
  (3.2) can never be measured. The stamp costs one line *now*; retrofitting it later can't
  recover history.
- **Fix:** `export.sh` writes the source commit (`git -C "$SRC" rev-parse --short HEAD`)
  into the target — e.g. `.agentic-flow-version` — and `doctor.sh` reports it.
- **Done when:** every fresh export carries the stamp and `doctor.sh` prints it.

---

## Tier 2 — close the loop honestly

Tier 1 made the gates real; Tier 2 makes the *reporting* real — so "done" and "approved"
mean something verifiable, and the loop can't double-fire or skip review.

**Ordering note:** 2.2 unblocks 2.3 (it creates the doc→tracker link); 2.5 unblocks the
honest version of 2.1 (CI is where evidence gets derived instead of pasted); 2.1 gates
2.3's auto-move. The suggested order at the bottom follows these edges.

### 2.1 Capture verification evidence (don't just assert it)
- **Problem:** implementation briefs say "`make check` / `make test` must be green," but
  nothing records that they were actually run. "Tests pass" is currently a claim, not a fact.
- **Fix — in two rungs, honest about which is which:**
  - **Rung 1 (convention):** the executor attaches evidence — a CI run link, or failing
    that pasted command output — to the **PR** (one canonical home; the doc's Status links
    to the PR rather than duplicating output, which would rot). A step's Tracker box can't
    be ticked without an evidence link on its PR.
  - **Rung 2 (derivation — the real fix, needs 2.5):** a required CI check on the PR *is*
    the evidence; `gh pr checks` state is queryable, un-fakeable, and needs no bookkeeping.
    Pasted output is a stopgap: it's still self-reported and still manual — exactly the
    failure mode this roadmap exists to kill.
- **Artifacts:** a "Verification evidence" line in the Security/Feature templates' Status
  block (a *link*, not a paste target); `AGENTS.md` step 4–5 making the evidence link part
  of the PR; a `docs-index.sh --check` rule flagging ticked Tracker boxes whose entry
  carries no `#N`/PR link.
- **Done when:** a closed step in any doc traces to a PR whose checks (or attached output)
  prove the verification commands ran green.

### 2.2 Make `plan-to-issues.sh` idempotent — and make it write the link back
- **Problem:** running `--apply` twice creates a *second* full set of issues. The script
  warns about this but doesn't prevent it — one fat-finger doubles the tracker. Separately,
  the doc→tracker link (`[#NN](url)` in Status) — which 2.3 depends on — is written by hand
  today: the script creates the issue and then trusts a human to record it.
- **Fix:**
  - **Guard:** stamp each generated issue with a spec hash in its body (title search is
    brittle — titles get edited); on `--apply`, look the stamp up first and refuse with
    "tracker #N already exists for this spec." Title search is the fallback, not the key.
  - **Reconcile, defined:** a `--check`/`--diff` mode that reports what *would* change vs.
    existing issues. When a plan legitimately changes: new steps are **appended** as new
    sub-issues, changed step bodies are **edited in place**, and removed steps are
    **closed with a comment** — never deleted, so history survives. (This also gives
    METHODOLOGY §6's "regenerate or hand-edit" a defined, non-duplicating meaning.)
  - **Close the link loop:** on successful `--apply`, print the exact Status lines to
    paste — or, with a flag, insert the tracking link into the doc's Status section
    directly. The doc→tracker convention stops being hand-maintained.
- **Artifacts:** `scripts/plan-to-issues.sh` (hash stamp + lookup + `--diff` + link-back);
  SKILL.md note; self-test coverage via a `gh` shim on `PATH` (see 2.3's note — the same
  shim serves both).
- **Done when:** a second `--apply` of the same spec is a no-op; a changed spec reconciles
  instead of duplicating; the doc's tracker link exists without a human typing it.

### 2.3 docs-index issue-state sync (the "powerful layer" deferred from Tier 1)
- **Problem:** a doc's `## Tracker` checkboxes are still ticked by hand; "closure inferred
  from commit messages" persists. The index reflects TRIAGE headers but not live issue state.
- **Fix:** extend `scripts/docs-index.sh` with a `--with-issues` mode that reads each doc's
  linked tracking issue (the link 2.2 now writes), queries sub-issue open/closed state via
  `gh`, and ticks the Tracker boxes accordingly. Read-only by default; mutation behind an
  explicit flag.
- **Auto-move guardrail:** "every sub-issue closed" is **necessary but not sufficient** to
  move a doc to `done/` — METHODOLOGY §4 requires *shipped and verified*, and a PR merge
  auto-closes its issue whether or not verification evidence (2.1) exists. So: flag
  all-closed docs always; auto-move (behind the flag) only when each step also carries its
  2.1 evidence link. Otherwise the sync would mechanize the exact dishonesty Tier 2 is
  meant to kill.
- **Artifacts:** `scripts/docs-index.sh` (`--with-issues`); depends on 2.2's link-back and
  2.1's evidence convention.
- **Testing note (revised):** most of this *is* testable offline — self-test can put a fake
  `gh` shim on `PATH` that replays fixture JSON, exercising parsing, matching, tick logic,
  and the auto-move guard. Only the final pass against the live API needs a real repo.
- **Done when:** `--with-issues` makes a doc's Tracker mirror GitHub without anyone ticking
  boxes, and a doc cannot auto-close without evidence.

### 2.4 Post-execution review template + approval as an event
- **Problem:** the three *input* docs are templated, but the *review that comes back* after
  execution isn't standardized — and "human approves the plan" is a verbal step with no
  marker, so approval is a vibe, not an event.
- **Fix (two parts, decision made — no "and/or"):**
  - **Approval = running `plan-to-issues --apply`.** Issues don't exist until the human
    says go; no issues, no execution. That's the enforceable boundary, so it's *the*
    approval event — an "Approved-by" line a human remembers to write is bookkeeping that
    will rot. To make the event leave a trace, `--apply` records it: an `--approved-by
    <name>` flag stamped into the tracking issue body, and the approval line included in
    the Status text the script writes back (2.2's link-back does the writing).
  - **A review template** (`docs/templates/review.md`): severity-graded findings on the
    *executed* code with a findings tracker, so a hand-written architectural review has
    the same shape as `/code-review` output. (For routine reviews, prefer `/code-review`;
    reserve the template for architecture-level passes.) Findings that warrant fixes flow
    back through the existing machinery: a findings spec → `plan-to-issues` with `sev:*`
    labels (METHODOLOGY §5 already maps severities to labels 1:1).
  - **Give review docs a home:** naming (`review-<topic>.md`), a `Type: Review` TRIAGE
    line so `docs-index.sh` classifies them (today they'd render as `—`), and a lifecycle
    (they close to `done/` alongside the doc they review). METHODOLOGY §4's naming list
    and §3's type table get the fourth row.
- **Artifacts:** `docs/templates/review.md`; `--approved-by` in `plan-to-issues.sh`;
  METHODOLOGY §2/§3/§4/§6 wording; docs-index type handling.
- **Done when:** every execution traces to an explicit approval artifact, and reviews land
  in a consistent, indexed, trackable shape.

### 2.5 Ship a CI workflow template (new)
- **Problem:** ADOPTION.md says "add `make check`, `make test`, and `docs-index --check`
  to CI where practical" — prose, so it mostly won't happen. Yet CI is the one place
  evidence gets **derived** rather than asserted (2.1's rung 2), and the only gate the
  agents can't talk their way past.
- **Fix:** ship `.github/workflows/agentic-flow.yml` in the scaffold: `make check`,
  `make test`, `scripts/docs-index.sh --check`, `scripts/doctor.sh --check` on PRs.
  Add `.github` to `export.sh`'s allow-list (it isn't there today — check this, it's the
  kind of silent gap the allow-list invites). Doctor gains a "CI workflow present" check.
  Keep it vanilla GitHub Actions; projects on other CI keep the Make targets as the
  contract and translate.
- **Done when:** a fresh export opens PRs that are red until check/test/docs-index/doctor
  are green, with no per-project CI authoring.

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
- **Fix:** the version stamp moved to **1.5.5** (it must exist from day one to be useful).
  What stays here: a `Standard version:` line in `METHODOLOGY.md`, continued expansion of
  `scripts/doctor.sh`, detection of hand-edited harness files (compare against the stamped
  source version), and a re-sync helper — likely `export.sh` run *from* the standard *at*
  the project, leaning on the existing `.agentic-new` merge flow rather than new machinery.
- **Artifacts:** version line in `METHODOLOGY.md`; `scripts/doctor.sh`; a CI/`--check` entry.
- **Done when:** `scripts/doctor.sh` passes on a conformant project and names the gaps
  (including "harness drifted from stamped version") on a drifted one.

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

1. **Tier 1.5 as one batch** — small fixes to things already shipped; 1.5.1 in particular
   blocks dogfooding and gets worse the longer `docs/` stays in the export allow-list.
2. **Tier 2: 2.2 → 2.5 → 2.1 → 2.4 → 2.3.** 2.2 removes a live footgun and creates the
   link 2.3 needs; 2.5 is small and gives 2.1 its derivation target; 2.3 lands last because
   it depends on both 2.2 (link) and 2.1 (evidence gate) — but note its logic is
   self-testable offline via a `gh` shim, so "needs a live repo" only applies to the final
   verification pass.
3. **Tier 2 exit test (dogfood):** Tier 2 isn't done when its items merge — it's done when
   **one real feature has run the whole loop end-to-end** on a live `gh` repo: Feature doc →
   `plan-to-issues --apply` (approval event) → execution PRs with CI evidence →
   `--with-issues` sync → auto-qualified move to `done/`. Everything so far is tested
   offline; nothing has yet proven the loop *as a loop*. Requires 1.5.1 first if the
   dogfood target is this repo.
4. **Tier 3 only as each pain is felt.**

Every Tier 2+ item should itself go through the loop: a Feature doc in `docs/inprogress/`
with an implementation brief, then `plan-to-issues`. (Tier 1.5 items are exempt — they're
single-commit fixes; a doc apiece would be ceremony.)
