<!-- TRIAGE (first pass · 2026-07-25) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> Optimize the existing harness before adding assurance profiles: reduce repeated execution,
> repeated context loading, and unnecessary role transitions without weakening any gate,
> review requirement, or source-of-truth rule.

# Feature — Context and execution optimization of the harness

## Execution status

Not approved.

This is Part 1 of the harness rescope:

- **Part 1 — this document:** optimize the current workflow and its existing concepts.
- **Part 2 — deferred:** adaptive/progressive assurance profiles.

Before execution:

- [ ] Human approves the decisions and open questions.
- [ ] Re-run the baseline measurements from a clean `main`.
- [ ] Run `plan-to-issues`.
- [ ] Create `codex/context-optimization`.

## Tracker

- [ ] O-1 Define minimal role contexts and single-source the hot-path guidance.
- [ ] O-2 Make focused verification real and remove redundant CI work.
- [ ] O-3 Remove contract drift without adding new manifest or severity concepts.
- [ ] O-4 Reduce close-out and review-bounce context boots.
- [ ] O-5 Add regression budgets, benchmark the result, and document the optimized workflow.

---

# Part A — Analysis

## Goal

Reduce elapsed time and model context consumed by the harness while preserving:

- the planner/executor/independent-reviewer separation;
- failure-path tests and per-step verification;
- the Stop hook;
- secret, staging, and no-push enforcement;
- independently shippable commits and issue traceability;
- authoritative CI;
- document lifecycle and closure evidence;
- review independence and human ownership of merge/deploy.

The optimization target is the work agents actually perform and read—not simply repository
file size.

## Measurement discipline

The original audit correctly found substantial waste, but mixed three different kinds of
numbers:

- **Measured:** file word counts and individual command timings.
- **Derived:** repeated-command totals calculated from a representative plan.
- **Modeled:** token estimates and context-boot counts.

Keep them separate.

Measurement basis used by the original audit:

- commit: `d507bf4`;
- `make check`: approximately 10.3 seconds;
- `make test`: approximately 106 seconds;
- `make test-one`: approximately 100 seconds because it runs the same full self-test;
- exported prose: 13,771 words;
- `METHODOLOGY.md`: 4,667 words at the measurement commit;
- token conversion: approximately 1.35 tokens per prose word.

The 12-minute three-step workflow and 127k-token four-step workflow are **scenario models**,
not instrumented production measurements. They remain useful for ranking, but acceptance must
compare before/after runs using the same scenario.

Before O-1 starts, record a clean baseline in this document. Do not silently replace the
measurement basis with timings from a dirty tree.

## Review corrections applied to the original proposal

### Optimize loaded context, not archive size

Two byte-identical skills shipped under different adapters are a maintenance problem, but not
automatically a token problem. Codex and OpenCode normally load their own adapter copy, not
both. A total-export word budget is useful as a coarse ceiling; role-specific hot-path budgets
are the actual KPI.

### Do not add a `mirror` manifest disposition

Adding a new payload-manifest mode, parser behavior, validation surface, and recovery cases to
delete two physical copies is negative ROI for this pass. Fix the known drift and add parity
tests with existing tools. Revisit generated mirrors only if adapter maintenance remains a
recurring defect.

### Guard the intentionally repeated `TOKEN_RE`

`init.sh`, `doctor.sh`, and `self-test.sh` each construct `TOKEN_RE` with the same split
`printf`, and `CLAUDE.md` explicitly warns that they must agree. A one-line shared helper would
replace three local expressions with a new runtime dependency for three bootstrap/diagnostic
scripts. Keep the construction local, but add an exact parity fixture so changing only one
copy fails immediately. The duplication becomes intentional and guarded rather than silent.

### Preserve `ADOPTION.md` as exported payload

Routing setup depth into `ADOPTION.md` makes it more important, not optional.
`doctor.sh` requires it and the export suite asserts it in every target. O-1 may re-scope its
content, but must not remove it from `config/payload.tsv`, mark it source-only, or leave an
adopted project without it.

### Do not add `sev:critical`

The current objective is to remove layers. A fifth severity is unrelated to elapsed time or
context loading. Normalize existing review surfaces onto the existing
**High / Medium / Low / Nit** labels and keep accepted/by-design as a separate disposition.
Production urgency belongs to incident handling, not this optimization pass.

### Do not gate lifecycle status in CI

The current CI comment is correct: the final PR cannot contain the CI URL produced by the run
that is still executing. Replacing `lifecycle-status.sh || true` with `--check` would deadlock
closure. If nobody consumes the report, remove it from CI and run lifecycle validation during
close-out.

### Keep issue comments as review feedback

The implementation document is design intent and issues are execution state. Moving findings
back into the doc Tracker would reverse the one-directional flow and add a document edit per
review round. Keep findings in the step issue comment; make the executor read the exact finding
comment and named `file:line` locations rather than the entire issue history.

### Reduce the implementation plan itself

The original brief was 9,138 words with ten steps. It would have required ten issue,
implementation, review, and close-out cycles to optimize context boots. This revision uses five
coherent steps and routes detail to each step's live files.

## Time impact and recommendations

The table is ordered by expected wall-clock return. “Saving” is a scenario estimate based on
the measured timings above; O-5 must replace it with before/after results.

| Priority | Current time cost | Impact | Suggestion | Expected saving | Correctness guard |
|---|---|---|---|---|---|
| **P0** | `make test-one F=…` ignores `F` and runs the approximately 100-second full suite once per step | **Very high** | Add named `self-test.sh --only <group>` groups and pass `F` through from the harness Makefile. Keep the full suite at brief completion | Approximately 270–290 seconds on a three-step plan if focused groups finish in 3–10 seconds | A fixture proves one group runs and unrelated groups do not; `make test` still runs every group plus shellcheck |
| **P1** | CI runs `make check`, then `doctor.sh --check --scope repo`, which runs `make check` again | **High** | Add an explicit `doctor.sh --skip-make-check` flag for callers that already ran it; CI uses it immediately after `make check`. Default doctor behavior remains unchanged | Approximately 10 seconds per CI app job | Doctor without the flag still behavior-checks `make check`; accept the flag only with `--scope repo` |
| **P1** | `lifecycle-status.sh \|\| true` parses every CI run but cannot gate and has no downstream consumer | **Medium** | Remove the CI reporting step; run `lifecycle-status.sh --check --verify-evidence` during final close-out, after a CI run URL exists | Small command saving, larger reduction in misleading output and maintenance | A close-out contract and test still require lifecycle verification before moving a doc |
| **P2** | `docs-index.sh --check` runs from the app gate, the docs-only job, and doctor | **Low / intentional** | Keep all three consumers because they answer different questions: the app gate checks a normal change, the path-filtered docs job reports on docs-only PRs, and doctor diagnoses repository invariants independently of whether its behavior check is skipped | No targeted saving | A docs-only PR still reports a required docs check; `doctor.sh --scope repo --skip-make-check` still diagnoses a stale index |
| **P2** | The Stop hook runs the fast gate on dirty turns, sometimes after an explicit check | **Medium scenario cost, high correctness value** | Keep the hook and clean-tree skip. Reduce the fast suite itself only by moving expensive export fixtures to full/focused groups; do not skip the gate based on agent claims | Workload-dependent; measure dirty-turn median rather than multiplying every turn by 10.3 seconds | Existing red/green, loop-prevention, and clean-tree fixtures remain unchanged |
| **Keep** | Final `make test` costs approximately 106 seconds | **High cost, high value** | Run once at the end of the brief and in CI. Do not remove it merely because focused tests ran per step | None; this is retained assurance | Full suite and shellcheck remain mandatory |
| **Keep** | `make build` exercises export dry-run separately | **Low cost, unique coverage** | Add dry-run regression coverage, but keep the build target and CI build step as the production assembly check | None initially | Dry-run test proves it writes nothing; build still validates the assembled payload |

## Context/token impact and recommendations

Token figures are modeled from word counts, not provider billing logs. Use them for priority
and use O-5's role bundles to prevent regression.

| Priority | Current context cost | Impact | Suggestion | Expected reduction | Correctness guard |
|---|---|---|---|---|---|
| **P0** | Roles can preload `METHODOLOGY.md` (approximately 6.3k estimated tokens) plus both role contracts before reading the task | **Very high, every boot** | Define a minimal read set per role. Always-loaded contracts keep frequent rules inline and route topic depth to one named file; no role reads all of `METHODOLOGY.md` by default | Up to approximately 6.3k tokens per boot; original three-role model falls from approximately 27.9k toward 12k static contract tokens | Each route is explicit; executor standards stay inline in `AGENTS.md`; tests assert referenced sections/files exist |
| **P0** | Claude closes every reviewed step in a separate context boot | **Very high, repeated per step** | Let `agent:claude + needs-closing` accumulate and perform one plan-level close-out after all step issues are independently reviewed | Removes `N−1` close-out boots; three boots on a four-step plan | Lifecycle refuses completion unless every step is in the reviewed state and CI evidence exists |
| **P1** | A third findings round adds one executor boot and one reviewer boot, both reloading contracts and diff context | **High on contentious steps** | Cap automated findings returns at two, then escalate to the human. Executor reads the named findings and surrounding call sites; reviewer checks the incremental fix plus unresolved findings | Removes two boots from the worst allowed path, plus repeated diff loading | Human escalation is explicit; no finding is auto-dismissed; final verdict still requires all material findings resolved |
| **P1** | CI, adoption, lifecycle, design, coding, and review rationale are repeated in always-loaded files | **High per boot** | Route each topic to one existing on-demand home; retain only an under-80-word point-of-use rule when it applies on most turns | Target at least 50% reduction in each static role bundle | Preserve section numbers; move unique rationale before deletion; single-home map and reference checks run offline |
| **P1** | Issue bodies copy the brief's verification commands while the Makefile is executable authority | **Medium and drift-prone** | Issue body contains the step link, concise DoD, and current label state. The brief names the required Make target; the Makefile defines its behavior | Approximately 200 words per step plus fewer reconciliation reads | State explicitly: approved brief wins on intent; Makefile wins on command behavior |
| **P1** | Mechanical Stop-hook failures inject up to 40 log lines and may cause a blocked retry | **Medium per occurrence** | Recognize only stable mechanical signatures such as stale docs index; emit the exact one-line remedy. Preserve the full log-tail fallback for unknown failures | Approximately 400–600 tokens and one avoidable retry for recognized failures | Unknown failures retain current diagnostics and blocking behavior |
| **P2** | Review adapter skills exist as physical duplicates | **Low hot-path token impact; medium drift risk** | Keep current manifest semantics. Fix drift and assert intended pairs are byte-identical | No claimed token saving; saves maintenance and prevents contradictory instructions | `cmp -s` parity fixtures fail on either copy changing alone |
| **P2** | `TOKEN_RE` is constructed independently in `init.sh`, `doctor.sh`, and `self-test.sh` | **Low token impact; medium silent-drift risk** | Keep the one-line construction local to avoid a bootstrap helper dependency, but assert all three assignments are byte-identical and still recognize the same fixtures | No claimed token saving; removes a documented coordination trap | A divergent assignment fails `make check`; positive and negative placeholder fixtures still agree |
| **P2** | This implementation brief previously consumed approximately 12k estimated tokens before code or review context | **High one-time planning cost** | Keep this brief decision-focused; give each issue only its step section and live inspection routes | More than 50% reduction in plan-reading context versus the original draft | Measurement basis, stop conditions, tests, and DoD remain in every step |

## Minimal role-context contract

This is the highest-value change. It must be explicit enough that a smaller model does not
need to infer which sources matter.

### Planner / close-out

At planning time, load:

- `CLAUDE.md`;
- the selected document template;
- relevant live code and tests;
- only the methodology section linked by the task.

Do not preload:

- the entire CI runbook for a non-CI change;
- adoption instructions for an established project;
- executor or reviewer examples not needed to write the brief.

At close-out, load:

- the implementation document's Tracker/Status;
- the step issue states and review verdicts;
- CI evidence;
- lifecycle command output.

Do not reload the full analysis or methodology unless closure exposes a contradiction.

### Executor

Load:

- `AGENTS.md`;
- the issue and its linked brief step;
- `CLAUDE.md` Stack profile and Gotchas only;
- target code, direct callers/callees, and relevant tests.

Do not load all of:

- `METHODOLOGY.md`;
- unrelated brief steps;
- CI/adoption runbooks;
- complete issue-comment history when the issue links the current finding comment.

The existing rule remains:

> Code and executable tests define the existing interface. The approved brief defines the
> intended change and its invariants.

### Independent reviewer

Load:

- the `review-execution` skill;
- the approved brief step and DoD;
- base/head or the step commit;
- changed code, tests, and affected callers;
- `AGENTS.md` Engineering standards;
- actual verification output.

Do not reload `CLAUDE.md` and `METHODOLOGY.md` wholesale. The skill routes to any additional
project-specific source required by the diff.

### Issue generation

Reuse the planner's context. Running `plan-to-issues` should not require a fresh planning boot.
The skill reads the approved document and produces deterministic issue specs from it.

## Single-home routing

No new documentation directory or runbook is required.

Canonical homes:

- CI/CD behavior and workflow rationale → `templates/ci/README.md`;
- setup, stack selection, and adoption verification → `ADOPTION.md` (**must remain exported**);
- document lifecycle, naming, and stage transitions → `docs/README.md`;
- design prompts—interface, threat model, failure behavior → Feature/Security templates;
- coding and verification standards → `AGENTS.md`;
- review method, evidence, and verdict contract → `review-execution/SKILL.md`;
- hook mechanics and exceptional overrides → hook script headers;
- cross-role loop, issue topology, commit contract, and severity labels →
  `METHODOLOGY.md`.

Routing rule:

- route content larger than approximately 150 words or relevant only to a specific task;
- inline content under approximately 80 words when used on most turns;
- never keep both a summary and a full restatement;
- keep one sentence naming the canonical path;
- do not route a short frequent rule into a much larger file.

`METHODOLOGY.md` section numbers are an interface. Preserve §1–§11 and reduce routed sections
to short pointers instead of renumbering them.

## Integrity constraints

1. No optimization removes a hook, test category, review requirement, or CI gate.
2. Root and exported harness contracts may differ only where project-local configuration is
   intentional and documented.
3. A fresh export passes `make check`.
4. The Stop hook remains fast, failure-first, and loop-safe.
5. CI remains authoritative.
6. Every step remains independently reviewed before plan-level close-out.
7. The implementation doc remains design intent; issue state/comments remain execution state.
8. `config/payload.tsv` remains the only payload-membership authority.
9. `ADOPTION.md` remains an exported, doctor-required payload file.
10. The three local `TOKEN_RE` constructions remain byte-identical and behaviorally equivalent.
11. No new manifest disposition, severity level, directory, or review runtime is introduced.
12. Existing completed documents and GitHub issues are not rewritten or relabeled.

## Non-goals

- Adaptive/progressive assurance profiles.
- Automatic model selection.
- Billing-grade token instrumentation.
- Replacing OpenCode review with self-review.
- Splitting `self-test.sh` into multiple files.
- A new `handoff.sh` abstraction over one existing `gh issue edit` command.
- A generated-adapter system or `mirror` payload mode.
- A new `sev:critical` label.
- Deriving the doc Tracker from GitHub; `ROADMAP.md` retains that future work.
- Moving review findings into the implementation document.

## Decisions

Recorded 2026-07-25. O-4 is unblocked.

- ✅ **Batch Claude close-out once per plan.** Every step still receives independent review;
  only Tracker/Status edits wait until all steps are reviewed. O-4's stop condition stands: if
  batching could let a document close with an unreviewed step, keep per-step close-out.
- ✅ **Reduce automated findings returns from three to two** before human escalation. No finding
  is auto-dismissed; the third return escalates.
- ✅ **No `Critical` severity level.** The scale is **High / Medium / Low / Nit** on the existing
  `sev:high|med|low|nit` labels, with accepted/by-design kept as a separate disposition. This
  reverses an earlier planning-thread decision to adopt Critical/High/Medium/Low/Nit: a fifth
  level does not reduce elapsed time or context, and this pass removes layers rather than adding
  them. Production urgency belongs to incident handling. Recorded here because the earlier choice
  is in the thread history and O-3 would otherwise look like it contradicts it.

## Open questions

- Should `README.md`'s large source-tree inventory be reduced to entry points? It is
  source-only and therefore not a hot-path exported cost. Recommendation: defer unless a
  drift defect is found.

---

# Part B — Implementation Brief

> **Audience:** Codex. One branch and one PR. Each step is one coherent commit and one issue.
> Re-read the named live files and call sites immediately before the step; this document
> describes intent, not current private interfaces.

## Branch

Base: `main`.

```text
codex/context-optimization
```

## Whole-plan Definition of Done

- Focused verification no longer runs the full suite.
- The full suite and CI coverage remain intact.
- CI no longer repeats `make check`.
- Each role has a tested minimal static context bundle.
- No role preloads all of `METHODOLOGY.md` by default.
- Existing duplicated adapters cannot drift silently.
- One existing severity vocabulary is used across review surfaces.
- Normal four-step close-out uses one Claude close-out boot instead of four.
- Review escalation preserves every finding while bounding automatic bounces.
- Before/after timing and context measurements are recorded using the same scenarios.
- Fresh export, `make check`, `make test`, doctor, and CI-equivalent checks pass.

## Whole-plan verification

```bash
make check
make test
make build
scripts/doctor.sh --check --scope repo --skip-make-check
```

Focused verification groups introduced by O-2:

```bash
make test-one F=contracts
make test-one F=hooks
make test-one F=plan-to-issues
make test-one F=lifecycle
make test-one F=export
```

---

## O-1 — Define minimal role contexts and route hot-path guidance

**Why first:** Avoiding wholesale methodology reads produces an immediate token reduction
without changing executable behavior.

**Inspect immediately before editing:**

- `METHODOLOGY.md`;
- root and `templates/harness/` `CLAUDE.md` / `AGENTS.md`;
- `.agents/skills/review-execution/SKILL.md`;
- `.opencode/agent/code-reviewer.md`;
- Feature, Security, and Review templates;
- `ADOPTION.md`, `docs/README.md`, and `templates/ci/README.md`;
- every live `METHODOLOGY.md §N` reference.

**Approach:**

1. Add the minimal read sets from Part A to the applicable role contracts.
2. Remove instructions that preload all of `METHODOLOGY.md`; route to relevant sections.
3. Move CI, adoption, lifecycle, design, coding, and review depth to the canonical homes
   listed above.
4. Keep frequent executor standards inline in `AGENTS.md`.
5. Keep §1–§11 headings and numbers. Routed sections become short pointers.
6. Move unique rationale before deleting a duplicate.
7. Do not change current role ownership or the OpenCode label state machine in this step.

**Failure-first tests:**

- every `METHODOLOGY.md §N` reference resolves;
- exported role contracts contain their minimal read set;
- executor standards remain present in exported `AGENTS.md`;
- topic-owner assertions find one canonical home for each routed block;
- a fresh export contains every destination document.

**Stop if:**

- a required rule would become available only after a model guesses the correct file;
- a section-number change would break existing references;
- project-local OpenCode behavior would be exported unintentionally.
- `ADOPTION.md` would be removed from the payload or changed to source-only.

**DoD:** Static role bundles are at least 50% smaller than the measured baseline, every route
resolves, `ADOPTION.md` remains present in a fresh export, and no executable behavior changes.

**Commit:** `Route agent context to its point of use`

---

## O-2 — Make focused verification real and remove redundant CI work

**Why second:** This is the largest measured wall-clock saving and gives later steps fast,
truthful per-step verification.

**Inspect immediately before editing:**

- `Makefile` and `templates/harness/Makefile`;
- `scripts/self-test.sh` mode parsing and section boundaries;
- `scripts/doctor.sh` argument parsing and final `make check`;
- `.github/workflows/ci.yml`;
- `templates/ci/ci.yml`;
- `scripts/lifecycle-status.sh`;
- all Make-target references in role contracts and templates.

**Approach:**

1. Add stable self-test groups such as `export`, `hooks`, `plan-to-issues`, `lifecycle`, and
   `contracts`, using functions or bounded section dispatch inside the existing file.
2. Add `self-test.sh --only <group>`.
3. Make this repo's `test-one F=<group>` run exactly one group. Preserve `F` as an opaque
   project-specific selector in exported Makefiles.
4. Keep `make test` running every group plus shellcheck.
5. Add explicit `doctor.sh --skip-make-check`. Default behavior remains unchanged.
6. In active and template CI, run `make check`, then doctor with the explicit skip.
7. Keep doctor's direct docs-index validation because it is part of doctor's own
   repository-invariant diagnosis. It must remain available even when a caller explicitly
   skips the separate behavior check.
8. Remove the non-gating lifecycle report from CI. Require lifecycle verification in O-4
   close-out instead.
9. Add export dry-run regression coverage; keep `make build`.

**Failure-first tests:**

- `test-one F=hooks` runs hooks and not export/plan/lifecycle groups;
- unknown or missing group fails clearly;
- full mode runs every group;
- doctor invokes `make check` by default;
- doctor does not invoke it when the explicit skip is present;
- CI orders the explicit fast gate before skipped-check doctor;
- lifecycle validation remains required by the close-out contract;
- export dry-run writes nothing.

**Stop if:**

- grouping requires splitting `self-test.sh` into multiple files;
- a focused group depends on state initialized only by an unrelated group;
- CI could call skip without first running the equivalent gate.

**DoD:** Three focused per-step calls no longer spend approximately 300 seconds on the full
suite; CI runs `make check` once; full verification remains unchanged.

**Commit:** `Make focused verification actually focused`

---

## O-3 — Remove contract drift without adding new concepts

**Why third:** Duplicated contract files have already diverged, but their physical duplication
is not the primary token cost. Fix correctness with parity and canonical references rather
than expanding manifest semantics.

**Inspect immediately before editing:**

- both `review-execution/SKILL.md` copies;
- both `plan-to-issues/SKILL.md` copies;
- `.opencode/agent/code-reviewer.md`;
- `.opencode/command/review.md`;
- `docs/templates/review.md`;
- `docs/templates/security-review.md`;
- `METHODOLOGY.md` severity section;
- `scripts/plan-to-issues.sh`;
- the `TOKEN_RE` assignments in `scripts/init.sh`, `scripts/doctor.sh`, and
  `scripts/self-test.sh`;
- adapter export fixtures.

**Approach:**

1. Fix the `plan-to-issues` copy that points at the wrong Stack-profile owner.
2. Keep current adapter paths and manifest dispositions.
3. Add parity checks for pairs intended to be identical.
4. Normalize review output to **High / Medium / Low / Nit**, mapped to the existing
   `sev:high|med|low|nit`.
5. Treat accepted/by-design as disposition, not severity.
6. Define merge blocking once: High blocks; Medium requires resolution or explicit
   acceptance; Low/Nit do not block.
7. Make reviewer surfaces cite `AGENTS.md` Engineering standards instead of restating them.
8. Keep reviewer-specific value: base/head resolution, caller tracing, evidence discipline,
   severity, and verdict.
9. Keep the three `TOKEN_RE` constructions local, but add a parity assertion over their
   assignment lines and retain behavioral placeholder fixtures. Update the `CLAUDE.md`
   coordination warning to name the guard.

**Failure-first tests:**

- intended adapter pairs fail when one copy changes;
- the surviving plan-to-issues guidance names `CLAUDE.md` as Stack-profile owner;
- one severity vocabulary appears across review surfaces;
- every emitted `sev:*` label is accepted offline;
- accepted risk is not parsed as a severity;
- reviewer surfaces do not restate the executor standards.
- a deliberately changed `TOKEN_RE` assignment fails before export or doctor behavior can
  diverge;
- all three scripts accept and reject the same placeholder fixtures.

**Stop if:**

- two adapter copies legitimately require different instructions;
- unifying severity would relabel existing issues or reinterpret completed findings.

**DoD:** No known contract drift, one existing severity scale, guarded `TOKEN_RE` parity, no
new manifest mode or label, and smaller reviewer static context.

**Commit:** `Unify duplicated review contracts without new layers`

---

## O-4 — Reduce close-out and review-bounce context boots

**Why fourth:** O-1 reduces cost per boot; this step reduces boot count. It changes lifecycle
behavior; both required approvals were granted 2026-07-25 (see Decisions), so it is unblocked.
The stop conditions below still govern — an approval to batch is not permission to let an
unreviewed step through.

**Inspect immediately before editing:**

- root and exported role state machines;
- `METHODOLOGY.md` loop and label pairs;
- `AGENTS.md` issue handoff;
- review skill;
- plan-to-issues issue-body construction;
- lifecycle status and close-out fields;
- Stop-hook diagnostics and tests.

**Approach:**

1. Keep per-step independent OpenCode review.
2. After approval, leave each step issue at `agent:claude + needs-closing`.
3. Run Claude close-out once when all plan steps are reviewed:
   - update all Tracker entries;
   - record review verdicts;
   - verify CI evidence;
   - run lifecycle verification;
   - move the doc only when every step qualifies.
4. Change the automatic findings-return cap from three to two. A third return escalates to
   the human without discarding findings.
5. For a returned step, Codex reads the exact finding comment, named locations, surrounding
   code, and affected callers—not the complete issue history and full branch.
6. OpenCode reviews the incremental fix and unresolved findings; the final approval remains
   responsible for the complete step contract.
7. Issue body carries the brief-step link and concise DoD, but no copied Make commands.
   The approved brief owns intent; the Makefile owns command behavior.
8. Recognize stable mechanical Stop-hook failures and print one-line remedies. Unknown
   failures keep the current log-tail fallback.

**Failure-first tests:**

- N reviewed step issues require one close-out pass, not N;
- no doc can close while any step lacks a review-approved state;
- a third findings return escalates instead of bouncing automatically;
- issue bodies link the brief and contain no copied Make recipe;
- recognized mechanical failures emit one remedy;
- unknown Stop-hook failures retain the diagnostic tail and blocking behavior.

**Stop if:**

- batched close-out can hide an unreviewed step;
- issue state cannot distinguish review-approved from merely implemented;
- scoped re-review could approve without checking the completed step contract.

**DoD:** A normal four-step plan removes three close-out boots; the worst allowed findings
path removes one executor/reviewer pair; evidence and review correctness remain intact.

**Commit:** `Reduce context boots in review and close-out`

---

## O-5 — Guard and measure the optimized harness

**Why last:** Budgets should protect the stabilized result, not force implementation toward
arbitrary draft numbers.

**Inspect immediately before editing:**

- `scripts/self-test.sh`;
- `scripts/docs-index.sh`;
- context owners changed in O-1;
- Make and CI paths changed in O-2;
- adapter parity from O-3;
- lifecycle paths from O-4;
- README and adoption documentation.

**Approach:**

1. Add role-bundle word ceilings for planner, executor, and reviewer static context.
   Dynamic brief, diff, and test output are measured separately.
2. Keep a looser total-export ceiling as a regression alarm, not the primary KPI.
3. Add reference-resolution checks for every `METHODOLOGY.md §N` link.
4. Add an undeclared-doc-stage failure fixture.
5. Retain adapter parity and role-contract presence checks.
6. Narrow `block-git-add-all.sh` only if its current matcher still blocks a read-only search
   containing the forbidden text; preserve real-command coverage.
7. Document the role read sets and focused verification groups in README/ADOPTION.
8. Benchmark the same three-step and four-step scenarios before and after.
9. Record one bounded benchmark in the implementation evidence:
   - five repetitions of `make check`, each focused group, and `make test` on the same
     machine, reporting median elapsed time;
   - deterministic word counts for each static role bundle;
   - the state-machine transition count for the same synthetic four-step plan before and
     after O-4.
   Do not create an ongoing manual pilot log.

**Failure-first tests:**

- each static role bundle exceeds its ceiling when the old duplicate block is restored;
- a broken section reference fails;
- an undeclared docs stage fails;
- an intentional adapter mismatch fails;
- a read-only search is allowed while real broad staging remains blocked;
- fresh export passes its own default check.

**Stop if:**

- a budget can pass only by deleting unique rationale or required instructions;
- a word-count assertion becomes a substitute for behavioral verification;
- measurements compare different workflows or machines without labeling the difference.

**DoD:** Optimization cannot silently regress, before/after evidence is recorded, and all
existing functional gates remain green.

**Commit:** `Guard and measure the context optimization`

---

# Acceptance criteria

## Correctness

- [x] No hook or CI authority is removed.
- [ ] Every implementation step remains independently reviewed.
- [x] Full tests and shellcheck still run at brief completion and in CI.
- [x] Fresh exports remain self-consistent and green.
- [x] `ADOPTION.md` remains exported and required by doctor.
- [x] `TOKEN_RE` cannot diverge silently between init, doctor, and self-test.
- [x] Legacy documents, issue markers, and labels retain their meaning.
- [x] No new manifest mode, severity label, or review runtime is introduced.

## Time

- [x] `test-one` runs one named group.
- [x] CI invokes `make check` once.
- [x] The three-step benchmark drops materially from the approximately 12-minute modeled
      baseline; target: at most 7 minutes on the same machine.
- [x] Any retained duplicate check has a documented distinct concern.

## Context

- [x] No role preloads all of `METHODOLOGY.md`.
- [x] Static role bundles are at least 50% smaller than the measured baseline.
- [x] Four reviewed steps require one plan close-out context.
- [x] Two findings returns are the maximum before human escalation, if approved.
- [x] Issue bodies do not copy executable verification commands.
- [x] Recognized mechanical Stop failures emit a one-line remedy.

## Evidence

- [x] Baseline commit, machine, and commands are recorded.
- [x] Before/after measurements use the same scenarios.
- [x] `make check`, `make test`, `make build`, and doctor pass.
- [ ] Independent review verdict is approved.
- [ ] Authoritative CI is green.

# Status / evidence

- **Approval:** decisions approved by the human 2026-07-25 — close-out batching, findings cap
  three → two, no `Critical` severity level (see Decisions), and whole-plan execution via
  issue #46.
- **Tracking issue:** [https://github.com/wabkebab/agentic-flow/issues/46](https://github.com/wabkebab/agentic-flow/issues/46).
- **Branch:** `codex/context-optimization`.
- **Verification evidence:** local verification passed 2026-07-25:
  - `make check`
  - `make test`
  - `make build`
  - `scripts/doctor.sh --check --scope repo --skip-make-check`
  - `make test-one F=contracts`
  - `make test-one F=hooks`
  - `make test-one F=plan-to-issues`
  - `make test-one F=lifecycle`
  - `make test-one F=export`
- **Review verdict:** pending.
- **Measurement basis:** original audit at `d507bf4`, 2026-07-25. Re-run from clean `main`
  before implementation measured `make check` at 11.72s from an archived clean tree; archived
  `make test` / `test-one` could not complete because the export fixture expects Git metadata,
  so the original clean-main full-suite measurements remain the before comparison.
- **Benchmark after implementation:** same machine, five repetitions unless noted:
  - `make check`: median 9.58s (9.53, 9.54, 9.58, 9.68, 10.07)
  - `make test-one F=contracts`: median 1.59s (1.58, 1.59, 1.59, 1.59, 1.62)
  - `make test-one F=hooks`: median 1.27s (1.26, 1.27, 1.27, 1.27, 1.27)
  - `make test-one F=plan-to-issues`: median 2.11s (2.10, 2.11, 2.11, 2.12, 2.15)
  - `make test-one F=lifecycle`: median 3.95s (3.94, 3.95, 3.95, 3.95, 3.96)
  - `make test-one F=export`: median 73.73s (73.38, 73.45, 73.73, 74.43, 75.07)
  - `make test`: median 84.15s (83.85, 83.93, 84.15, 84.26, 85.37)
- **Static role bundles after implementation:** planner `CLAUDE.md` 1,362 words; executor
  `AGENTS.md` 791 words; reviewer skill 738 words. Executable ceilings compare each bundle
  against half of its former full-methodology baseline.
- **State-machine transition model:** four reviewed steps now require four Codex handoffs,
  four OpenCode reviews, and one Claude close-out pass, instead of four Claude close-out
  passes. A third findings return escalates to the human.
