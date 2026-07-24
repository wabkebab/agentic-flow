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
- 🚧 **Tier 2 — close the loop honestly** — **~60% delivered** by the harness-integrity plan
  ([#16](https://github.com/wabkebab/agentic-flow/issues/16), branch
  `codex/harness-integrity-and-lifecycle`). 2.2 ✅ · 2.1 🚧 · 2.4 🚧 · 2.5 🚧 · 2.3 ⬜.
  See the re-evaluation note below — the remaining gap is narrower but sharper than it looks.
- ⬜ **Tier 3 — durability & scale** — below. **3.2 has been rescoped and promoted**: the
  manifest and installed/candidate version split now make an upgrade surface cheap, and it
  is the largest *user-facing* gap in the system.

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

### 2.1 Capture verification evidence (don't just assert it) — 🚧 rung 1 done, rung 2 blocked
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
- **Remaining:** make `lifecycle-status.sh` recognise a CI run URL specifically and query
  its conclusion via `gh run view --json conclusion`, so READY means "checks were green,"
  not "a URL was pasted." Depends on 2.6.

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

### 2.4 Post-execution review template + approval as an event — 🚧 template done, approval trace missing
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
- **Remaining:** `--approved-by <name>` on `plan-to-issues.sh`, stamped into the tracker body
  and written into the doc's Status block by the existing `--doc` link-back.

### 2.5 Ship a CI workflow template — 🚧 shipped, but deliberately inert
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

### 2.6 Make CI the authoritative gate — starting with this repo (new)
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

### 2.7 Render the CI runtime block from the stack profile (new)
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

### 3.2 Upgrade as a first-class surface — **rescoped and promoted** (was "anti-drift")
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
- **Fix — three commands, mirroring the review's install/upgrade split:**
  - `status` — installed version, candidate version if an update is half-applied, unresolved
    merge candidates, stack profile, and adapter set. Mostly a re-presentation of facts
    doctor already computes.
  - `diff` — what a re-export *would* change, per manifest entry, without writing. `export.sh
    --dry-run` already computes this; it just isn't legible.
  - `upgrade` — apply, preserving conflicts under the existing `.agentic-new` policy, and
    advance `.agentic-flow-version` only when nothing is left pending (that rule already
    exists in `export.sh`; the command makes it visible).
- **Deliberately not doing:** a full transactional render-validate-plan-apply engine. For a
  ~25-entry manifest, render-to-temp then move is the valuable 20%; the rest is machinery
  looking for a problem.
- **Also still here from the original item:** a `Standard version:` line in `METHODOLOGY.md`,
  and doctor detecting *hand-edited* harness files by comparing against the stamped version
  (distinct from unresolved candidates, which it already catches).
- **Done when:** an adopted project can answer "am I current, what would change, and what is
  half-applied" without reading `export.sh`, and `upgrade` never advances the installed
  version past what is actually active.

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

### 3.5 Split `self-test.sh` when it starts hurting (new, deliberately deferred)
- **Problem:** `scripts/self-test.sh` is ~660 lines covering export invariants, hook parsing,
  the Stop gate, spec validation, a fake-`gh` reconciliation suite, and lifecycle fixtures.
  It is good, fast, and hermetic — but it is one file, and a failure in it points at a line
  number rather than a subsystem.
- **Explicitly not now.** Splitting adds structure before there is pain, and the suite runs
  in seconds. Revisit when either: a single run exceeds ~30s, or someone skips adding a test
  because finding the right section is annoying.
- **One thing worth doing early regardless:** keep the invariant that every adapter file is
  either exported or explicitly source-only ([#18](https://github.com/wabkebab/agentic-flow/issues/18))
  as its own script, not buried in the suite — it is the check most likely to be wanted
  standalone in CI.

---

## Suggested order

**Revised 2026-07-24 after #16.** The old order (2.2 → 2.5 → 2.1 → 2.4 → 2.3) is spent:
2.2 is done, 2.5 shipped inert, and 2.1/2.4 are each one small piece short. The binding
constraint moved from *scripts* to *authority*.

1. ~~**Tier 1.5 as one batch**~~ — ✅ done.
2. **2.6 — activate CI here, first.** Small, unblocks 2.1 rung 2, and ends the situation
   where the standard recommends a gate it doesn't run. Nothing else in Tier 2 means much
   until "green" is enforced by something other than an agent's word.
3. **3.2 — the upgrade surface — pulled forward out of Tier 3.** Ranked above the rest of
   Tier 2 deliberately. Tier 2 improves the loop *for a project already on the standard*;
   3.2 is what every adopted project needs *every time the standard changes*, and the
   foundation for it landed in #16, so it is now mostly surfacing work. Drift is the pain
   that is actually being felt.
4. **2.4's remainder (`--approved-by`), then 2.1 rung 2, then 2.7.** Each is small.
   `--approved-by` removes a hand-typed field that a checker already enforces; 2.1 rung 2
   turns a pasted URL into a queried CI conclusion; 2.7 finishes the stack-profile idea.
5. **2.3 last**, unchanged in position but smaller in scope — the guardrail half is built,
   so what's left is the ticking. Land its preview mode before its mutating flag.
6. **Tier 2 exit test (dogfood):** unchanged in spirit, and now largely satisfied. #16 ran
   Feature doc → `plan-to-issues --apply` → nine execution commits on one branch →
   independent review → PR #27 → merge → derived `READY`, which is the loop end to end and
   the first time it has run for real. This is also the correct shape under METHODOLOGY §2
   as corrected 2026-07-24: one branch and one PR **per pass**, one issue and one commit
   per step — not a branch per step, which was an over-fine-grained reading briefly written
   into §2 and reverted. What #16 did **not** exercise: CI evidence (there was no CI to
   derive it from) and `--with-issues` sync. So the exit test narrows to: **CI-derived
   evidence on the pass's PR, auto-qualified to `done/`.** 2.6 is a hard prerequisite.
7. **Tier 3 as each pain is felt** — except 3.2, promoted above.

Every Tier 2+ item should itself go through the loop: a Feature doc in `docs/inprogress/`
with an implementation brief, then `plan-to-issues`. Under the delivery lanes added in
METHODOLOGY §2, **2.6 is a Fast Fix** (bounded, one PR) and the rest are Planned Changes.
(Tier 1.5 items were exempt — single-commit fixes; a doc apiece would have been ceremony.)
