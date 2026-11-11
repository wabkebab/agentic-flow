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
- ✅ **Tier 1.5 — hardening the shipped guardrails** — done on `feature-init-and-template-split`.
  1.5.1/1.5.5 landed earlier with the export work; 1.5.2 (`42fcc94`), 1.5.3 (`9948062`),
  1.5.4 (`b2c6311`).
- 🚧 **Tier 2 — close the loop honestly** — **all but one item delivered.**
  2.1 ✅ · 2.2 ✅ · 2.4 ✅ · 2.5 ✅ · 2.7 ✅ · 2.6 🚧 (publish decided 2026-11-11; ruleset after 0.14.0 merges) ·
  2.3 ⬜. See the 2026-07-25 re-evaluation.
- 🚧 **Tier 3 — durability & scale** — below. **3.2 / 3.2a shipped on
  `codex/upgrade-surface`**; the remaining 1.0 blocker is using the tool on a real adopter
  and resolving 2.6's repo-settings authority gap.
- ✅ **Tier 4 — cost of running the standard** — new axis, opened and half-delivered by
  [#46](https://github.com/wabkebab/agentic-flow/issues/46). 4.1 ✅ · 4.2 ⬜.

### What earns 1.0 (added 2026-07-25)

`VERSION` is `0.10.0`. The backbone is 1.0-grade — hermetic tests, a single payload
authority, fresh-export-green on a stripped `PATH`, pinned actions, derived docs index,
pre-commit secret scanning, and a loop that has now run end-to-end for real twice (#16,
#46). What is missing is not quality, it is a **promise**:

> **1.0 is a compatibility promise, and you cannot promise compatibility between versions
> without a mechanism to move between them.**

So the bar is exactly two things:

1. **3.2 ships, and is used** — the upgrade surface now exists on
   `codex/upgrade-surface`; an existing adopter still needs to be migrated across a real
   contract change by the tool, not by hand. `collector` is pinned at `0.9.0+d507bf4`, the
   commit immediately *before* #46; that migration remains the exit test.
2. **2.6's authority claim becomes true** — either `main` gets a required check, or
   `METHODOLOGY.md` §10 stops calling CI authoritative for this repo.

Everything else in Tier 3 is post-1.0 by construction ("defer until felt").

**Release mechanics, decided 2026-07-25:** there are no version tags yet, and none are being
invented before 3.2 lands — adopters track `main` in the meantime. Tagging starts *after*
the upgrade surface exists, which is the right order: a tag nothing can consume is
ceremony. `v1.0.0` is then the first tag that means something, because it is the first
version an adopted project can actually be moved onto.

### Re-evaluation after #46 (2026-07-25)

#46 was not on this roadmap — it opened a **fourth axis the tier structure never
anticipated**: the cost, in wall-clock and model context, of running the standard at all.
Tiers 1–3 all ask "is the loop honest?"; none asks "what does honesty cost per step?"
That axis is now **Tier 4**.

Closing out #46 also cleared three Tier 2 items that this file still listed as open, because
they landed in #16's tail and in the semver pass without the roadmap being updated:

- **2.1 rung 2 is done** — `lifecycle-status.sh:78-112` extracts an Actions run URL and
  queries `gh run view --json conclusion`. `READY` now means *checks were green*, not *a URL
  was pasted*. It was never actually blocked on 2.6.
- **2.4 is done** — `plan-to-issues.sh --approved-by` stamps `approved-by:`/`approved-at:`
  into the tracker body, refuses to overwrite an existing approval, and writes the Approval
  line into the doc via `--doc`.
- **2.7 is done** — all four `profiles/*.tsv` carry a `ci-setup` row and
  `render-stack-profile.sh --ci` renders the workflow's setup block per stack, with
  cross-runtime leak assertions in the suite.

The lesson is the roadmap's own guiding principle turned on itself: **this file is
hand-maintained bookkeeping, and it rotted.** Three items sat marked 🚧 while their code was
merged and tested. See 4.3.

### Re-evaluation after #16 (2026-07-24)

#16 delivered the machinery Tier 2 was written to ask for — a payload manifest, hermetic
tests, truthful version state, structural doctor checks, an idempotent/resumable
`plan-to-issues`, delivery lanes, derived lifecycle qualification, and stack profiles. What
it did **not** do is make any of it *load-bearing in CI*, and that turns out to be the whole
remaining point of Tier 2:

> **Every gate in this repo is still an agent-side gate.** There is no `.github/workflows/`
> here. The Stop hook, the git-add guard, the push guard, and the secret scan all live in
> `.claude/settings.json` / `.codex/hooks.json` — which means they bind exactly one class of
> actor. A human committing from an IDE, a different agent, or anyone running plain `git`
> passes through untouched. The scaffold ships CI templates it does not itself run.

So Tier 2's honest completion is no longer about writing more scripts. It is about moving
the authority for "green" from something an agent asserts to something a repository
enforces. That reorders the remaining work — see **Suggested order**.

Three defects found during the #16 review are tracked as Fast Fix issues rather than roadmap
items (bounded, one branch/PR each, per METHODOLOGY §2): source-only directories leaking
through `export.sh` ([#17](https://github.com/wabkebab/agentic-flow/issues/17)), the payload
guard missing a new adapter directory ([#18](https://github.com/wabkebab/agentic-flow/issues/18)),
and `lifecycle-status.sh` conflating missing evidence with an unreadable Status block
([#19](https://github.com/wabkebab/agentic-flow/issues/19)).

---

## Tier 1.5 — hardening what already shipped (small, batch these)

Defects and gaps *in the Tier 1 guardrails themselves*. Each is under an hour; none needs
a Feature doc — one commit each, with a self-test where noted.

### 1.5.1 Don't export the scaffold's own working docs — ✅ done
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

### 1.5.2 check-gate log path collides across sessions — ✅ done (`42fcc94`)
- **Problem:** `check-gate.sh` writes to the fixed path `/tmp/agentic-check-gate.log` —
  two concurrent sessions (or two projects) clobber each other's failure output, so the
  agent may be shown the *other* project's errors.
- **Fix:** per-repo path (e.g. `${TMPDIR:-/tmp}/agentic-check-gate.<repo-hash>.log`) or
  `mktemp`.

### 1.5.3 git-add guard misses flags between `git` and `add` — ✅ done (`9948062`)
- **Problem:** the regex requires `git` immediately followed by `add`, so the common,
  innocent `git -C <path> add -A` (and `git -c k=v add -A`) passes the guard. The hook
  guards against sloppiness, not adversaries — but `-C` is everyday usage, not evasion.
- **Fix:** allow intervening `-C <path>` / `-c <k=v>` args in the pattern; extend the
  self-test with these cases.

### 1.5.4 self-test doesn't exercise check-gate.sh at all — ✅ done (`b2c6311`)
- **Problem:** `self-test.sh` covers export, the git-add guard, and plan-to-issues
  validation — but the Stop gate (the highest-leverage hook) has zero coverage, including
  its no-Makefile no-op and its `stop_hook_active` loop-safety path.
- **Fix:** fixture dir with a Makefile whose `check` passes/fails on demand; assert
  exit 0 / exit 2 / warn-and-allow for the three paths.

### 1.5.5 Stamp the export version (pulled forward from 3.2) — ✅ done
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

### 2.1 Capture verification evidence (don't just assert it) — ✅ done (both rungs)
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
- **Status after #16:** rung 1 landed and went further than planned. The Security/Feature
  templates carry `**Verification evidence:**` and `**Review verdict:**` lines, and
  `scripts/lifecycle-status.sh` *derives* ACTIVE / READY / BLOCKED from them rather than
  asking anyone to assert readiness — which is a better answer than the planned
  `docs-index.sh --check` tick-without-link rule, so that artifact is **dropped**.
  **Rung 2 has not moved at all**, and cannot until CI actually runs (2.6). Today the
  "evidence" a doc links is a human-chosen URL; nothing verifies it points at a green run.
  Two live examples of the gap: this repo's own `feature-harness-integrity-and-lifecycle.md`
  cites a review comment, and `feature-init-and-template-split.md` cites merged commit SHAs.
  Both are true, neither is *derived*.
- **Rung 2 landed (found merged 2026-07-25, not previously recorded here).**
  `lifecycle-status.sh --verify-evidence` extracts
  `https://github.com/<o>/<r>/actions/runs/<id>` from the Status block and resolves it with
  `gh run view --repo <o>/<r> --json conclusion`. `success` → READY; any other conclusion →
  BLOCKED; a non-run URL or absent `gh` → UNVERIFIED (reported, not fatal). All four paths
  have fixtures in the `lifecycle` self-test group behind a fake `gh` on `PATH`.
- **It was never really blocked on 2.6.** The dependency as written assumed the *scaffold's*
  CI had to exist first; in fact the query works against any adopter's runs, and this repo's
  CI arrived independently. Cost of the mis-stated edge: the item sat marked blocked for a
  cycle while being implementable.
- **Residual, small:** UNVERIFIED is the honest answer when `gh` is absent, but nothing
  distinguishes "no CI in this project" from "gh not installed here". Worth a one-line
  reason string if it ever confuses someone; not worth a plan.

### 2.2 Make `plan-to-issues.sh` idempotent — and make it write the link back — ✅ done
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
  Delivered by `scripts/plan-to-issues.sh`'s stable plan/step stamps, offline dry-run,
  `--diff`, resumable reconciliation, and `--doc` link-back.

### 2.3 docs-index issue-state sync (the "powerful layer" deferred from Tier 1) — ⬜ unblocked, partly superseded
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
- **Status after #16:** not started, but both blockers cleared and the scope shrank.
  2.2's `--doc` link-back now writes the doc→tracker link this depends on, and the
  **auto-move guardrail half is already built and better than specified** —
  `lifecycle-status.sh` evaluates closure eligibility offline, with no `gh` and no network,
  which is testable in a way the planned version wasn't. What remains is only the *ticking*:
  read live sub-issue state and update `## Tracker` boxes.
- **Scope correction:** keep the two halves separate. `lifecycle-status.sh` owns
  *qualification* (offline, deterministic); `docs-index.sh --with-issues` owns *reflection*
  (network, mutating). Merging them would drag a network dependency into the one check that
  currently runs anywhere, including in `make check` if we ever want it there.
- **Caution learned from #19:** this feature ticks boxes from issue state, and a false tick
  is worse than no tick. Land the `--diff`-style preview before the mutating flag.

### 2.4 Post-execution review template + approval as an event — ✅ done
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
- **Status after #16:** the review half is **done** — `docs/templates/review.md` ships,
  METHODOLOGY §3 gained the `Review` type row, §4 gained `review-<topic>.md`, and
  `docs-index.sh` classifies it (Type is derived from the TRIAGE line, so it needed no code
  change). The approval half is **not**: `plan-to-issues.sh` has no `--approved-by`, so
  approval still leaves no machine-readable trace.
- **Sharper than when written:** `lifecycle-status.sh` now *checks* for an approval line and
  blocks closure without one — so the field is load-bearing while still being hand-typed.
  That is the exact shape this roadmap warns about ("bookkeeping that will rot"), and #19
  showed the first rot already: a pre-schema doc recorded approval under `**Approved:**` and
  the checker called it missing. Stamping approval at `--apply` time removes the typing.
- **The approval half landed too (found merged 2026-07-25, not previously recorded here).**
  `plan-to-issues.sh --approved-by <name>` validates the value as a safe stamp, writes
  `approved-by:<name> approved-at:<date>` into the tracking issue's HTML-comment stamp, and
  the `--doc` link-back rewrites the doc's `- **Approval:**` line. Re-applying with a
  *different* name is refused rather than silently overwritten — approval is an event, so it
  can't be quietly reassigned.
- **Done when — met:** every execution traces to an approval artifact that nobody typed, and
  `lifecycle-status.sh`'s approval check now reads a field the tool wrote.

### 2.5 Ship a CI workflow template — ✅ done (its two open costs became 2.6 and 2.7)
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
- **Status after #16:** `templates/ci/{ci.yml,deploy.yml,README.md}` ship, export via the
  manifest, pin every action to a SHA with a staleness checker, and doctor reports whether
  CI is active or inert. But they ship to `templates/ci/`, **not** `.github/workflows/` — a
  deliberate reversal of the plan above, on the reasoning that adopting a harness should
  never switch on CI or a deploy behind your back. That reasoning is right.
- **The cost of that reversal was not priced in.** "Done when" is unmet: activation is
  manual, and the workflow still has `<ANGLE-BRACKET>` runtime-setup spots to fill, so a
  fresh export does *not* get a red-until-green PR. Two consequences:
  - **This repo has never run its own CI** — see the re-evaluation note. The standard does
    not practise its most important gate. → **2.6**.
  - The runtime setup block is hardcoded Node while `make check`/`make test` are now
    stack-agnostic, so a Rust or Python adopter must hand-edit a Node workflow that the
    stack profiles could render for them. → **2.7**.

### 2.6 Make CI the authoritative gate — starting with this repo — 🚧 running, not authoritative
- **Problem:** enforcement lives entirely in agent tool hooks. They bind Claude and Codex
  and nothing else — not a human in an IDE, not another agent, not plain `git`. They are
  fast feedback, not a gate. Meanwhile the one boundary that *is* agent-neutral and
  un-talkable-past — a required status check — ships inert and is switched on nowhere,
  including here. Every "green" this system reports is currently self-reported.
- **Fix, in the layering the review recommended:**
  - **Agent hooks** stay as immediate feedback (already built; keep).
  - **CI is authoritative.** Activate `templates/ci/ci.yml` on *this* repo first, running
    `make check`, `make test`, `scripts/doctor.sh --check`, `scripts/docs-index.sh --check`,
    and `scripts/lifecycle-status.sh` on PRs. Make **`CI gate`** the only required check.
  - **Optional local git hooks** last, and framed honestly: `pre-commit`/`pre-push` don't
    distribute via git and die to `--no-verify`. They're a convenience, never the gate.
    Don't build them before CI exists, or they'll be mistaken for one.
- **Why this repo first:** it is the cheapest possible dogfood (the Make targets are real
  and green today), it is prerequisite to 2.1 rung 2, and until it happens the scaffold
  recommends a discipline it does not follow.
- **Done when:** a PR against agentic-flow is red until the harness gates pass, `main` is
  protected by exactly one required check, and `doctor.sh` reports CI **active** here.
- **Status 2026-07-25 — two of three met.** `.github/workflows/ci.yml` exists and runs; the
  last five runs are `success`; `doctor.sh` prints `ok CI workflow active:
  .github/workflows/ci.yml`. The third is **not** met and is not a code problem:

  ```
  $ gh api repos/wabkebab/agentic-flow/branches/main/protection
  403: Upgrade to GitHub Pro or make this repository public to enable this feature.
  ```

  Branch protection is unavailable on a private repo on the free plan. So CI is **advisory
  here**: it reports, nothing enforces it, and a merge can still land red.
- **This is the gap between what the standard claims and what it does.** `METHODOLOGY.md`
  §10 and `CLAUDE.md` both say CI is authoritative. In this repo it currently isn't. Two
  honest resolutions, pick one:
  - **Make the repo public** (or go Pro), set `CI gate` as the single required check, and
    the claim becomes true. Cheapest, and it is the one that actually closes the item.
  - **Keep it private and unprotected** — then say so, in one line, wherever CI authority is
    claimed, and record it in `accepted_risks.md`. An untrue claim in the standard is worse
    than a stated limitation, because adopters inherit the prose.
- **Not a substitute:** local `pre-commit`/`pre-push` hooks. They don't distribute via git
  and die to `--no-verify`. The original framing stands — don't build them and let them be
  mistaken for a gate.
- **Status 2026-11-11 — resolution chosen: make the repo public** (R-0f in
  `docs/inprogress/product-harness-factory-optimization.md`). Publishing waited on the
  0.14.0 gate fixes (tracker #114), which make review evidence ignore comments from
  logins outside the review policy. After that PR merges, the human scans history for
  secrets, publishes, and adds a `main` ruleset with `CI gate` as the single required
  check (`docs/done/feature-gate-and-handoff-fixes.md`, "Publishing"). 2.6 is done when
  that ruleset is live.

### 2.7 Render the CI runtime block from the stack profile — ✅ done
- **Problem:** stack profiles made the *Makefile* data-driven, but `templates/ci/ci.yml`
  still hardcodes a Node setup block with `<ANGLE-BRACKET>` fill-ins. The contract boundary
  is supposed to be the Make target; everything above it should follow the profile. A Rust
  adopter today gets `actions/setup-node` and `npm ci` to delete by hand — the exact
  "silently rewrite/hand-edit project commands" failure the profile design avoided.
- **Fix:** give each `profiles/*.tsv` a `ci-setup` block (runtime action + version + cache +
  lockfile install command) and let `render-stack-profile.sh` emit the workflow's setup
  steps alongside the Makefile. Keep the job graph, pins, path filters, and `ci-gate` fan-in
  fixed — only the setup block varies.
- **Done when:** `init.sh --stack rust` produces a `templates/ci/ci.yml` whose setup block
  is Cargo, with no angle brackets left to fill, and the pin checker still passes.
- **Status 2026-07-25 — met (found merged, not previously recorded here).** All four
  `profiles/{node,python,rust,go}.tsv` carry a `ci-setup` row; `render-stack-profile.sh --ci`
  emits the setup steps alongside the Makefile; the job graph, pins, path filters, and
  `ci-gate` fan-in stay fixed. The `export` self-test group renders each profile and asserts
  both the expected markers *and* the absence of every other runtime's markers, so a Rust
  render leaking `setup-node` fails. A `ci-setup` value containing a literal tab is rejected
  by the renderer — the TSV would otherwise silently split into the wrong columns.

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
- **Relevance up — the first trigger has fired, and nothing noticed (2026-07-25).** F-4
  ("Template and instance copies can drift") lists **"Revisit if: a contract change ships in
  only one copy."** That happened during #46: the review severity vocabulary was normalized
  in `review-execution/SKILL.md` but not in `.opencode/agent/code-reviewer.md`, which kept
  the retired `block`/`fix`/`nit` scale and `BLOCK`/`LGTM` verdicts. It was caught by a human
  review pass, not by the trigger.
- **Cheap first version, worth doing before the scheduled agent:** F-4's condition is
  *mechanically checkable today* — that is what the new parity assertions in the `contracts`
  self-test group do. The general shape is: an accepted risk whose "Revisit if" can be
  expressed as a check should **be** that check, and the entry should link to it. Reserve the
  `/schedule` routine for the genuinely judgement-based ones ("if scale changes").
- **Immediate, non-roadmap action:** F-4 needs re-deciding rather than being inherited into
  1.0 — its trigger has fired once, and the mitigation it declined ("a strict template drift
  checker") now partly exists.

### 3.2 Upgrade as a first-class surface — ✅ shipped on `codex/upgrade-surface`
- **Problem:** adoption happens **once**; drift lasts the **lifetime of every project**. The
  system has an excellent install story (`init.sh`) and no upgrade story at all. Today,
  bringing an adopted project up to date means running `export.sh` from the standard, then
  hand-merging `.agentic-new` files with no way to ask *what changed*, *what's pending*, or
  *am I current*. This is the largest user-facing gap in the system, and it is felt now —
  the scaffold is already adopted in more than one project.
- **Why it's cheap now (it wasn't when this was written):** #16 built the whole foundation.
  `config/payload.tsv` declares what belongs and under which policy; `.agentic-flow-version`
  vs `.agentic-flow-candidate-version` distinguish *installed* from *pending*; doctor already
  fails on unresolved merge candidates. What's missing is only the surface over them.
- **Direction: pull, from the project (decided 2026-07-25).** This was ambiguous in every
  earlier draft of this item and the ambiguity mattered, so it is now explicit:

  > `export.sh` **pushes** from the standard into a target. The upgrade surface **pulls**,
  > and runs **inside the adopted project**.

  Push doesn't scale past the repos you happen to have checked out, and it puts the work on
  the person who isn't feeling the pain. "Am I current?" is asked by the project's
  maintainer, in the project, so that is where it must be answerable. Prior art is exact:
  **cruft** solved this for cookiecutter by stamping the template commit into the project
  and running `cruft update` from inside it — the same shape as `.agentic-flow-version`.

- **Fix — one command, three subcommands:**

  ```
  agentic-flow status     # offline. what am I on, what's half-applied, what's ignored
  agentic-flow diff       # read-only. what would change if I upgraded
  agentic-flow upgrade    # apply, under the existing .agentic-new policy
  ```

  Ships in the payload as `scripts/agentic-flow`, so every adopted project has it. Resolves
  the project root by walking **up from `$PWD`** for `.agentic-flow-version` — unlike
  `doctor.sh`, which resolves from its own location — so it also works symlinked onto
  `PATH`. The monorepo semantics are preserved either way: the nearest stamp upward owns
  that subtree.

- **The origin gap — the blocker nobody had written down.** An adopted project today has the
  manifest (`config/payload.tsv`, exported) and the stamp (`.agentic-flow-version`), but
  **no record of where the standard lives** and no copy of the apply logic
  (`scripts/export.sh` is `source-only`). So it knows what version it *is* and cannot
  discover what version *exists*. Two consequences:
  - **`.agentic-flow-source` must be recorded at adoption time**, holding the standard's
    origin (and the ref to track). It cannot be back-derived later — same argument that
    pulled the version stamp forward as 1.5.5, and the reason this is step one.
  - **The manifest walk has to ship** — **decided 2026-07-25: it ships.** Not by exporting
    `export.sh` whole (it also does init and placeholder work an adopted project has no use
    for) but by extracting its manifest-walk + merge-policy core into a small exported
    library that both `export.sh` (push) and `agentic-flow upgrade` (pull) call.
  - **The cost was priced, not assumed.** Shipping the applier means an adopted project
    carries code that rewrites its own harness files — a larger blast radius than anything
    currently in the payload, and probably why `export.sh` was `source-only`. Accepted
    deliberately, because the alternative is no upgrade story. Three mitigations are terms
    of the acceptance rather than nice-to-haves: `upgrade` executes nothing it fetched; a
    changed origin is a hard stop; `.agentic-new` still means no silent overwrite.
  - **Ref tracking: `main` for now, tags after this lands.** `.agentic-flow-source` line 2
    is opaque data passed to `git clone --branch`, which takes a tag or a branch
    identically — so moving a project to deliberate, tagged updates later is a one-line edit
    with no code change. Deliberately **not** designing a release process in this pass.
- **Deliberately not doing:** a full transactional render-validate-plan-apply engine; 3-way
  or automatic merge (`.agentic-new` + a human stays the policy); downgrade; multiple
  origins; the CLI self-updating. For a ~29-entry manifest, render-to-temp then move is the
  valuable 20%; the rest is machinery looking for a problem.
- **Also still here from the original item:** ~~a `Standard version:` line in
  `METHODOLOGY.md`~~ — **done**: `VERSION` holds the semver, the header names it, and the
  stamp is `<semver>+<sha>`. Still open: doctor detecting *hand-edited* harness files by
  comparing against the stamped version (distinct from unresolved candidates, which it
  already catches).
- **Done when:** running `agentic-flow status` **inside an adopted project** answers "am I
  current, what would change, and what is half-applied" without reading `export.sh` or
  having the standard checked out, and `upgrade` never advances the installed version past
  what is actually active.
- **Plan:** [`docs/inprogress/feature-upgrade-surface.md`](docs/inprogress/feature-upgrade-surface.md).
- **Status 2026-07-25 — shipped locally on `codex/upgrade-surface`.**
  The payload now includes `scripts/agentic-flow` with `status`, `diff`, and `upgrade`.
  Fresh exports record `.agentic-flow-source`; existing adopters can back-fill it from
  `ADOPTION.md`; the shared applier is exported; pull-side upgrade executes nothing fetched
  and preserves the `.agentic-new` installed/candidate stamp rule. The remaining 1.0 exit
  test is operational rather than structural: migrate `collector` from `0.9.0+d507bf4` to
  current with the tool and review the result.

#### 3.2a Adoption into an existing project is the normal case — ✅ shipped with 3.2

Split out 2026-07-25 from three real adoptions (film-festival-manager, print-traffic,
collector). `init.sh` handles greenfield well. What actually happens is a **merge**:

- Two of three needed `CLAUDE.md` / `AGENTS.md` hand-merged, because the target already had
  its own. The `.agentic-new` policy defers the conflict but offers no help resolving it,
  and these are the two files an agent reads *first*.
- A blanket `.claude/` rule in the target's `.gitignore` silently swallowed the exported
  hooks and settings — **twice, in two different projects**. The export succeeds, doctor
  passes on disk, and the harness is simply not committed. This is the highest
  cost-to-detect failure in the whole adoption path.
- One adoption found `docs/` largely uncommitted for the same reason.

Concrete, small fixes — shipped with the upgrade surface:

- **Warn when a payload path is git-ignored in the target.** One `git check-ignore` pass
  over the manifest catches every instance of the trap above. This is the single
  highest-value item in 3.2, it does not depend on the rest of it, and `agentic-flow status`
  is its natural home — "what is on disk but not actually installed" is a status question.
  Mirrored in `doctor.sh` so adoption checks catch it too.
- **`export.sh`: report a summary of what landed as `.agentic-new`** — already present and
  preserved through the shared applier extraction.
- Treat "adopt into an existing repo" as a first-class documented path in `ADOPTION.md`,
  not a footnote on the greenfield one — now documented alongside upgrade/back-fill.

### 3.3 Wire in agent memory
- **Problem:** durable decisions (the chosen stack profile, accepted risks, recurring review
  themes, the commit contract) get re-derived every session; the methodology *mentions* memory
  but nothing wires it in.
- **Fix:** a convention (and a bootstrap step) that persists the project's durable facts to
  agent memory — the Stack-profile summary, opt-outs, standing review themes — so sessions
  start informed instead of re-reading everything.
- **Artifacts:** a "Memory" section in `CLAUDE.md`; a bootstrap checklist item.
- **Done when:** a fresh session knows the project's stack, opt-outs, and contract without re-deriving them.
- **Note after #16:** `.agentic-flow-stack` now records the chosen profile on disk, so part
  of "durable facts" is already a file rather than a memory. Prefer that pattern where it
  fits — a fact in the repo beats a fact in an agent's memory, because it survives agent
  changes and is reviewable in a diff.

### 3.4 Roles as capabilities, not product names (new)
- **Problem:** the standard hardcodes *Claude* and *Codex* as proper nouns in METHODOLOGY,
  CLAUDE.md, AGENTS.md, doctor's tool checks, and the manifest's `scope` column. Swapping in
  a different agent, or running planner and executor as the same agent, means editing prose
  in a dozen places. #16 made the *payload* adapter-aware; the *roles* still aren't.
- **Fix:** describe four capabilities — planner, executor, reviewer, owner/approver — and
  bind agents to them per project (the manifest `scope` column is already the seed). Keep
  separation of duties as the invariant; let the binding vary.
- **Counterweight — do not over-abstract:** "Claude plans, Codex executes" is *legible*, and
  legibility is much of why this scaffold is adoptable. Do the indirection in code (doctor,
  manifest, hook wiring); keep the docs concrete, with the generic model as a short section
  rather than a rewrite of every sentence.
- **Done when:** adding a third agent surface is a manifest + profile change, and
  `--claude-only` stops being a special case in favour of a general binding.

### 3.5 Split `self-test.sh` when it starts hurting — ⬜ triggers fired, then defused
- **Problem:** `scripts/self-test.sh` is ~660 lines covering export invariants, hook parsing,
  the Stop gate, spec validation, a fake-`gh` reconciliation suite, and lifecycle fixtures.
  It is good, fast, and hermetic — but it is one file, and a failure in it points at a line
  number rather than a subsystem.
- **Explicitly not now.** Splitting adds structure before there is pain, and the suite runs
  in seconds. Revisit when either: a single run exceeds ~30s, or someone skips adding a test
  because finding the right section is annoying.
- **Both revisit triggers have since fired — and #46 answered them without splitting
  (2026-07-25).** The file is now **1,374 lines** (not 660) and `make test` takes **~102s**
  (not "seconds"), so on the letter of the trigger this was due. But #46 introduced named
  groups inside the one file — `export`, `contracts`, `hooks`, `plan-to-issues`, `lifecycle`
  — reachable as `make test-one F=<group>`, which delivers what the split was *for*:

  | group | time | | group | time |
  |---|---|---|---|---|
  | `hooks` | 1.5s | | `lifecycle` | 4.7s |
  | `contracts` | 2.2s | | `export` | **94s** |
  | `plan-to-issues` | 2.6s | | *full `make test`* | *102s* |

  A failure now names a subsystem, and the per-step cost dropped from ~100s to ~2s. Splitting
  into files would add a runner, a shared-fixture module, and five more paths for the same
  benefit.
- **Revised trigger — one number, not two.** The remaining pain is entirely `export`: 94s,
  92% of the full suite, because every fixture re-copies the checkout. Revisit when *that*
  becomes the bottleneck, and when you do, **the fix is probably fixture reuse, not file
  splitting** — one shared source fixture per run instead of per assertion. Splitting the
  file would not have made `export` any faster.
- **Guard that has to survive any such refactor:** the group dispatcher must not be able to
  pass having run nothing. That is what the `should_run` call-site validation and the
  end-of-run "did the promised groups execute" check exist for — a split would need to carry
  the equivalent, or `make test-one` silently becomes decoration again.
- **The early item is done:** the "every adapter file is exported or explicitly source-only"
  invariant lives in its own `scripts/check-payload-manifest.sh` (83 lines), called from
  `make check` — exactly as recommended.

---

## Tier 4 — cost of running the standard (new, 2026-07-25)

Tiers 1–3 ask *is the loop honest?* None of them asks *what does honesty cost per step?*
[#46](https://github.com/wabkebab/agentic-flow/issues/46) opened that axis after the audit
found the harness paying full-suite and full-context prices on every step. It belongs on the
roadmap because the failure mode is real and self-inflicted: **assurance that is too
expensive to run gets skipped, and a skipped gate is worse than an absent one** — it still
appears in the contract.

### 4.1 Optimize context and execution cost — ✅ done (#46, `0.10.0`)
- **Delivered:** focused self-test groups behind `make test-one F=<group>` (per-step
  verification 100s → ~2s); CI no longer runs `make check` twice; role contracts define a
  minimal read set and route by `METHODOLOGY.md §N` instead of preloading it (~6.3k modelled
  tokens off every boot); plan-level close-out instead of per-step (removes N−1 boots);
  findings returns capped at two before human escalation; one severity vocabulary across all
  review surfaces; adapter and `TOKEN_RE` parity guarded.
- **Honest accounting:** the static role files did **not** shrink (`CLAUDE.md` 1,286 → 1,370
  words) and `METHODOLOGY.md` *grew* 4,667 → 5,028 as routed detail landed in its canonical
  home. The saving is that no role loads it by default. The first draft of this claim asserted
  a 50% file reduction that had not happened — corrected during review.
- **Guard against regression:** executable word ceilings on each role bundle, set just above
  measured size so re-inlining a routed block fails `make check`.

### 4.2 Assurance profiles — ⬜ Part 2, two competing designs in `docs/inprogress/`
- **Problem:** assurance is currently one-size-fits-all. A typo fix and an auth-boundary
  change pay the same decomposition, review, and traceability cost. #46 deliberately scoped
  profiles **out** so the optimization could land first.
- **Two proposals are open and overlapping**, both `🟦 Proposal`:
  - `feature-progressive-assurance-profiles.md` — Quick / Standard / Strict tiers.
  - `feature-adaptative-assurance-opus.md` — a counter-design holding the tier as **project
    state** and *rendering* it into the contract files, so lowering assurance actually
    removes context rather than adding a conditional.
- **Decide before executing.** These are alternatives, not a sequence; shipping both would
  add exactly the layering both claim to remove. The rendering approach is more consistent
  with how `profiles/*.tsv` already work (data → rendered contract), which is a point in its
  favour, but that is a call for the human, not a foregone conclusion.
- **Hard constraint carried over from #46:** a profile may change *how much ceremony* a
  change pays. It may not make a gate, a hook, a review requirement, or CI optional.

### 4.3 Derive this roadmap's status instead of hand-maintaining it — ⬜ new
- **Problem:** this file opens by naming *staleness from manual bookkeeping* as the system's
  biggest enemy, and is itself the worst offender in the repo. On 2026-07-25, **three items
  (2.1, 2.4, 2.7) were marked open while their code was merged, tested, and shipping** — one
  of them for a full cycle, with a stale "blocked on 2.6" edge that was never true.
- **Why it matters beyond tidiness:** the Suggested order is read as a work queue. Stale
  entries send the next pass at work that is already done, and hide the one item that
  actually blocks 1.0.
- **Fix — smallest thing that works:** roadmap items that correspond to shipped behaviour
  should be **assertable**. Where an item's "Done when" is already a command
  (`--approved-by` exists, `ci-setup` renders, `--verify-evidence` resolves a run), a
  one-line check in the `contracts` group can fail when the roadmap claims otherwise. Do not
  build a general roadmap-parsing engine — tie the handful of checkable claims to their
  checks and accept prose for the rest.
- **Cheaper interim:** make roadmap reconciliation an explicit step of plan close-out, in the
  same pass that ticks the doc Tracker. Close-out already loads issue state and CI evidence,
  which is exactly what the roadmap status needs.
- **Done when:** an item cannot sit marked open while a test proves its behaviour ships.

---

## Suggested order

**Revised 2026-07-25 after #46.** The 2026-07-24 order is spent: its items 2 and 4 are done
(2.1 rung 2, 2.4, 2.7 all shipped) and item 2's premise was wrong — 2.1 was never blocked on
2.6. What is left is short, and it is no longer a queue of comparable work. **One item blocks
1.0; everything else is optional.**

1. ~~**Tier 1.5 as one batch**~~ · ~~**2.2** · **2.5** · **2.1** · **2.4** · **2.7**~~ — ✅ done.
2. **2.6's last third — a settings change, not a project.** Make the repo public (or go Pro)
   and set `CI gate` as the single required check. Ten minutes, and it converts every "green"
   in this system from self-reported to enforced. If the answer is "keep it private", that is
   fine — but then correct the CI-authority claim in `METHODOLOGY.md` §10 and `CLAUDE.md` and
   file it in `accepted_risks.md`. Do one or the other before 1.0; don't leave the claim
   standing untrue.
3. **3.2 — the upgrade surface. The only 1.0 blocker.** Start with **3.2a's git-ignore
   check**, which is an afternoon and catches the failure that has already bitten two
   projects. Then `status` → `diff` → `upgrade`, in that order — each is useful alone, and
   `status`/`diff` are read-only, so they can ship and be trusted before anything mutates.
   The exit test is migrating `collector` from `0.9.0+d507bf4` to current *with the tool*.
4. **4.2 — pick one assurance design, then execute it.** Blocked on a human decision between
   the two proposals, not on engineering. Do not start until the choice is made.
5. **2.3 last**, unchanged in position and smaller in scope — the guardrail half is built, so
   what remains is only the ticking. Land its preview mode before its mutating flag.
6. **4.3 and 3.1 opportunistically** — both are about facts that rot (this roadmap; accepted
   risks). Neither justifies its own pass; both are natural riders on the close-out of
   whatever ships next.
7. **Tier 2 exit test (dogfood):** unchanged in spirit, and now largely satisfied. #16 ran
   Feature doc → `plan-to-issues --apply` → nine execution commits on one branch →
   independent review → PR #27 → merge → derived `READY`, which is the loop end to end and
   the first time it has run for real. This is also the correct shape under METHODOLOGY §2
   as corrected 2026-07-24: one branch and one PR **per pass**, one issue and one commit
   per step — not a branch per step, which was an over-fine-grained reading briefly written
   into §2 and reverted. What #16 did **not** exercise: CI evidence (there was no CI to
   derive it from) and `--with-issues` sync. So the exit test narrows to: **CI-derived
   evidence on the pass's PR, auto-qualified to `done/`.** 2.6 is a hard prerequisite.
   **Update 2026-07-25:** the CI-evidence half is now buildable — `lifecycle-status.sh
   --verify-evidence` resolves a run URL to its conclusion (2.1 rung 2 shipped). What is
   still unexercised is `--with-issues` sync (2.3) and, strictly, the *required*-check half
   of 2.6. #46 came closer than #16: it has real CI runs, but on a repo where nothing
   enforces them.
8. **Tier 3 as each pain is felt** — except 3.2, promoted above.

Every Tier 2+ item should itself go through the loop: a Feature doc in `docs/inprogress/`
with an implementation brief, then `plan-to-issues`. Under the delivery lanes added in
METHODOLOGY §2, **2.6's remainder and 3.2a's git-ignore check are Fast Fixes** (bounded, one
PR each) and the rest are Planned Changes. (Tier 1.5 items were exempt — single-commit fixes;
a doc apiece would have been ceremony.)

---

## Retired / not worth doing

Kept short, and kept — a closed decision that isn't recorded gets reopened.

- **Splitting `self-test.sh` into multiple files** — superseded by #46's in-file groups,
  which delivered the subsystem-level failure reporting and the fast per-step run that the
  split was for. See 3.5 for the revised trigger.
- **`docs-index.sh --check` flagging ticked Tracker boxes with no `#N` link** (2.1's planned
  artifact) — dropped in favour of `lifecycle-status.sh` deriving ACTIVE/READY/BLOCKED, which
  is strictly better and already shipped.
- **`.github/workflows/agentic-flow.yml` shipped active in the payload** (2.5 as originally
  written) — deliberately reversed: adopting a harness must never switch on CI or a deploy
  behind your back. The reversal's costs became 2.6 and 2.7, both now resolved or scoped.
- **A `sev:critical` severity level** — rejected in #46. A fifth level reduces neither
  elapsed time nor context, and production urgency belongs to incident handling.
- **A `mirror` payload-manifest disposition / generated adapters** — rejected in #46.
  New parser modes and recovery cases to delete two physical copies is negative ROI; parity
  assertions cover the actual risk.
- **Local `pre-commit` / `pre-push` hooks as a gate** — they don't distribute via git and die
  to `--no-verify`. Fine as convenience, never as authority. Don't build them before 2.6, or
  they will be mistaken for it.
