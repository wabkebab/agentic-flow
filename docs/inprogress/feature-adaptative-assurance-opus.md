<!-- TRIAGE (first pass · 2026-07-25) -->
> **Superseded:** `feature-harness-optimization.md` Part A §7 and Step F-9 own assurance
> policy and baseline implementation. This proposal remains for design history.
> **Type:** Feature · **Status:** 🟦 Proposal
> Adversarial context audit of the harness plus a counter-design: three assurance tiers held
> as **project state** and **rendered** into the contract files, so raising assurance costs
> ceremony and lowering it actually removes context. Written against
> `feature-progressive-assurance-profiles.md` (Codex); overlaps are called out explicitly.

# Feature — Adaptive assurance (context-first counter-design)

## Execution status

Not approved. Not actionable yet. This document deliberately competes with
`docs/inprogress/feature-progressive-assurance-profiles.md`; a human picks one, or merges Part B
of this one into Part B of that one. Both should not be executed.

It is also **Part 2** of a two-part decomposition: `context_optimization.md` de-duplicates the
harness first, because adding a tier axis to nine rules restated across eleven files multiplies
the duplication by three. Several steps below assume that pass has landed.

Before execution:

- [ ] Human picks between this plan and Codex's, or approves a merge of the two.
- [ ] `context_optimization.md` has landed.
- [ ] Run `plan-to-issues`; branch `codex/adaptive-assurance`.

## Tracker

- [ ] A-1 Collapse seven delivery modes into three tiers with one vocabulary.
- [ ] A-2 Give every duplicated rule exactly one home; one severity scale.
- [ ] A-3 Add a `mirror` disposition so identical agent adapters have one source.
- [ ] A-4 Hold the tier as project state, with an audited upgrade/downgrade command.
- [ ] A-5 Render tier-specific contract regions instead of branching prose.
- [ ] A-6 Make issue generation and lifecycle closure tier-aware.
- [ ] A-7 Shrink `METHODOLOGY.md`, declare the lifecycle, verify the context budget.

---

# Part A — Analysis

## Goal

The harness is correct and it is expensive. The user's complaint is token burn, and the ask is
a project-level assurance baseline (Quick / Standard / Strict) that can be raised or lowered
mid-project as the work changes.

The measurements below say the burn has two independent sources, and the profile proposal on
the table only addresses one of them:

| Source | Where the tokens go | Addressed by Codex's plan? |
|---|---|---|
| **Ceremony** | Documents, tracker + sub-issues, branch/PR, label flips, close-out — artifacts produced per change | Yes |
| **Context** | The same rules restated across 8–11 files, re-read by 3 agents on every turn of every change | **No** |

Context is the larger of the two. A small change under the current harness produces perhaps
3–4k output tokens of artifacts, and forces roughly **36k input tokens** of contract re-reading
(3 agents × `CLAUDE.md` 1.7k + `AGENTS.md` 1.0k + `METHODOLOGY.md` 6.3k + brief ~2.7k + a skill
~1.0k). Profiles that cut artifacts and *add* prose to the always-loaded files make the
dominant term worse.

## Current state — measured

### The exported context budget

Every adopted project receives **13,771 words ≈ 18.6k tokens** of harness prose (per
`config/payload.tsv`):

```
4667  METHODOLOGY.md              869  docs/templates/feature-analysis.md
 963  CLAUDE.md (from template)   742  docs/templates/security-review.md
 792  AGENTS.md (from template)   640  templates/ci/README.md
 768  .agents/…/review-execution  549  .claude/…/plan-to-issues
 768  .opencode/…/review-execution 549 .agents/…/plan-to-issues
 453  .opencode/agent/code-reviewer 454 docs/templates/product-analysis.md
 428  ADOPTION.md                 350  docs/README.md   + 5 smaller files
```

`README.md` and `ROADMAP.md` are correctly **not** exported. That discipline exists; it just
hasn't been applied inside the payload.

### Duplication — one rule, many homes

Counted across tracked markdown, excluding `docs/done/` and the proposal documents in
`docs/inprogress/`:

| Rule | Files restating it | Enforced mechanically? |
|---|---|---|
| `make check` / `test-one` / `test` triad | **11** | — |
| `Fixes #N` | **9** | — |
| Test the failure path first | **7** | no |
| `shellcheck` is required, don't treat missing as green | **7** | yes (`make test`) |
| Never push | **6** | **yes** (`block-push.sh`) |
| Validate external input at the boundary, once | **6** | no |
| The `docs/` tree diagram | **5** | yes (`docs-index.sh`) |
| No unbounded anything | **4** | no |
| Stage files by name | **5** | **yes** (`block-git-add-all.sh`) |

The pattern is sharpest where a hook already enforces the rule. "Never push" is mechanically
impossible for an agent to do — `block-push.sh` intercepts it — and it is still explained in
six files. That prose buys nothing and is paid for on every turn.

### Fragmentation — same job, divergent files

1. **`.agents/skills/review-execution/SKILL.md` and `.opencode/skills/review-execution/SKILL.md`
   are byte-identical.** 768 words shipped twice.
2. **`.claude/` and `.agents/` `plan-to-issues/SKILL.md` differ by one word** — line 28 points
   at `CLAUDE.md` in one copy and `AGENTS.md` in the other. The pointer is to *Stack profile*,
   which lives in `CLAUDE.md` in **both** cases, so the `.agents/` copy is already a live drift
   bug. 549 words duplicated to carry one wrong word.
3. **Three review contracts with three severity scales.** `review-execution/SKILL.md` grades
   `Blocker / High / Medium / Low`; `.opencode/agent/code-reviewer.md` grades
   `block / fix / nit`; `METHODOLOGY.md` §5 defines `sev:high|med|low|nit` as the scale that
   maps 1:1 onto GitHub labels. A reviewer's finding therefore cannot become an issue without a
   human translating the scale. This is a correctness defect, not just bloat.
4. **`.opencode/agent/code-reviewer.md` cites `AGENTS.md` §"Engineering standards" as
   authoritative and then restates all five standards inline anyway.** Both copies are now
   maintained, or one is stale.
5. **Root `CLAUDE.md`/`AGENTS.md` vs `templates/harness/` copies** are ~90% identical (1,755
   words mirrored). This one is *intentional* — but `CLAUDE.md` → Gotchas has to warn about it,
   and every contract change is two edits. It is a manifest problem wearing a documentation
   coat.
6. **The lifecycle grew an undeclared fifth stage by accident.** These proposals were drafted in
   `docs/plans/`, a directory `METHODOLOGY.md` §4 never declared — and `docs-index.sh` rendered
   `Stage: plans` into `docs/README.md` without complaint, legitimising it. Resolved on
   2026-07-25 by moving them to `docs/inprogress/`. The finding stands as a design point: the
   generator scans `docs/**` and skips only three names, so it converts any stray directory into
   a lifecycle stage silently. `context_optimization.md` O-5 adds the guard.

### Files carrying too much context

- **`METHODOLOGY.md` — 4,667 words, read by every role.** Roughly half of it is a second copy
  of something executable:
  - **§10 CI/CD pipeline shape (~1,900 words)** — the third description of the CI design, after
    `templates/ci/README.md` (640 w) and the runbook comments inside the three workflow files.
  - **§8 Shipped guardrails (~700 words)** — the same hook descriptions as the `Hooks` section
    in `CLAUDE.md` *and* in `templates/harness/CLAUDE.md`.
  - **§9 Assess the stack (~450 words)** — near point-for-point the Stack-profile blockquote in
    `templates/harness/CLAUDE.md:29-43`.
- **`docs/done/feature-ci-as-authority.md` — 5,897 words**, and 12,600 words of completed plans
  in `docs/done/` total. Not auto-loaded, but it is grep surface: an agent searching for how a
  rule works now hits four archived plans before the live contract.
- **`scripts/self-test.sh` — 1,120 lines**, invoked by `make check`, invoked by the Stop hook on
  every turn with a dirty tree. Measured: **10.3s per turn end**. Wall-clock, not tokens, but
  it is the per-turn tax with the widest reach.
- **`make test-one F=…` is an alias for the full suite.** The harness teaches "`make check` +
  `test-one` per step, `make test` at the end," which on this repo means running the whole
  offline suite three times per step. The cheap verification lane advertised in every template
  does not exist here.

### Extra steps in the loop

Any change, however small, traverses nine handoffs: plan → approve → `plan-to-issues` →
execute → label flip → OpenCode review → label flip → Claude close-out → doc move (+ index
regen). Each arrow is a fresh agent turn that re-reads the contract files. The review bounce is
capped at three rounds, so the worst legal path re-reads them a dozen times.

### A friction datapoint found while auditing

`block-git-add-all.sh` matched a **`grep` pattern** that merely contained the forbidden string,
blocking a read-only search. Guards that pattern-match command text will keep firing on
commands that discuss the rule rather than break it. Worth a narrower match (`^\s*git\s+add`)
when A-2 is touched anyway.

## Assessment of Codex's plan

`feature-progressive-assurance-profiles.md` is well-built and most of it should
survive. Specifically **keep**:

- The **live-interface rule** (code and tests define the existing interface; the brief defines
  intent and invariants). This is the single best token idea in either document — it licenses
  briefs to stop transcribing signatures, which is where brief bloat comes from.
- **Profile ≠ authority.** CI's authority comes from the CI environment and branch protection;
  no profile flag may downgrade it.
- **Standard = exactly one step → one work issue**, no tracker.
- **Legacy profile-less docs and specs keep current behavior.**
- **F-3's engineering discipline**: profile enum validated offline, before the first `gh`
  mutation.

Where it does not deliver, adversarially:

1. **It has no project baseline.** Profile is a per-document field only. The user asked for a
   baseline chosen when a project starts; without persisted state every change re-litigates the
   tier, which is itself an extra decision turn per change — the cost the plan set out to remove.
2. **It has no upgrade/downgrade path.** The user's second requirement ("harden or soften during
   the project") is absent from the design, the DoD, and the acceptance checklist.
3. **It increases always-loaded context.** F-2 adds profile-aware prose to `CLAUDE.md`,
   `AGENTS.md`, both `templates/harness/` mirrors, both doc templates, both `plan-to-issues`
   copies and the review skill — eight files, and every agent then reads all three tiers' rules
   to locate the one in force. Estimated **+1,500 to +2,500 words** on the hot path. It reduces
   ceremony and grows context, i.e. it optimises the smaller term and worsens the larger one.
4. **It leaves seven modes standing.** F-1 keeps the Fast Fix / Planned Change / Decision /
   Emergency lane table and adds Quick / Standard / Strict beside it. Fast Fix ≡ Quick and
   Planned Change ≡ Standard-or-Strict, so the harness would ship two overlapping taxonomies —
   added fragmentation.
5. **It touches none of the measured duplication.** Not one of the nine restated rules, neither
   identical skill copy, and not the three severity scales.
6. **Its pilot is unmeasurable.** "Manually record approximate token cost for ten changes" is
   ceremony that will not be done, and if done cannot be trusted.

## Proposed approach

Three tiers, as Codex proposed. Two structural changes to how a tier exists.

### Option A — profile as branching prose (Codex's F-2)

Every contract file describes all three tiers; the agent decides which applies each turn.
Simple to write, no new machinery. Costs context permanently and makes tier-selection a
per-turn reasoning task.

### Option B — profile as project state, rendered into the contract (recommended)

Two mechanisms the harness already has, reused:

**1. State.** `.agentic-flow-assurance` holds one line: `quick`, `standard`, or `strict`. Exactly
the shape of the existing `.agentic-flow-stack`. Set by `init.sh --assurance <tier>`, changed by
`scripts/assurance.sh set <tier> --reason "<why>"`, reported by `doctor.sh`. The reason lives in
the signed commit for the state change — already durable, already dated, no new artifact.
Lowering below a hard-trigger floor is refused unless `--override` is passed with a reason.

**2. Rendering.** `profiles/assurance/{quick,standard,strict}.tsv` are data-only, and
`scripts/render-assurance.sh` fills a marked region in `CLAUDE.md` and `AGENTS.md` — the same
pattern as `profiles/*.tsv` + `render-stack-profile.sh` filling the Makefile today. An adopted
project's contract files contain **only the tier in force**. Switching tier re-renders both
files; that re-render *is* the upgrade/downgrade.

Why this is the right shape:

- **Context falls when assurance falls.** A Quick project's `AGENTS.md` does not carry Strict's
  decomposition rules at all. Under Option A it carries all three forever.
- **No per-turn tier reasoning.** The rules an agent reads are the rules that apply. A wrong
  tier is a visible diff in a tracked file, not a silent misclassification.
- **Upgrade/downgrade is one command with an audit trail**, and `doctor.sh` reports the tier
  next to the stack — so a fresh session knows the posture without being told.
- **It reuses two proven mechanisms** rather than inventing a third.

**Recommendation: Option B**, and it is only worth building on top of A-1 through A-3. Adding a
tier axis to a harness that restates nine rules across eleven files multiplies the duplication
by three. De-duplicate first, then make the remaining single copy tier-rendered.

### The tier contract

Same semantics as Codex's table, with the universal baseline unchanged and one column added for
what the tier *renders*:

| Concern | Quick | Standard | Strict |
|---|---|---|---|
| Use when | Small, clear, reversible, no shared contract | Ordinary product and maintenance work | Hard trigger, or explicit human choice |
| Brief | none | one-step Feature brief | full Feature/Security analysis + ordered brief |
| GitHub | none | one work issue | tracker + one sub-issue per step |
| Handoffs | 1 | 4 | 9 |
| Verification | `make check` + focused test | + regression test + CI | + failure-path test per step + full suite + CI |
| Independent review | executor self-check | one OpenCode pass | OpenCode per step |
| Local authority | explicitly non-authoritative | supporting evidence | supporting evidence |
| Rendered contract | ~450 words | ~700 words | ~1,000 words |

Hard Strict triggers, Quick eligibility conditions, Quick promotion conditions, the universal
baseline and the `Workflow: Quick / non-authoritative` report line: **adopt Codex's text
verbatim**. It is good and there is no reason to rewrite it.

### Collapsing the vocabulary (A-1)

| Today | Becomes |
|---|---|
| Fast Fix | **Quick** |
| Planned Change | **Standard** or **Strict** by decomposition |
| Decision | not a delivery lane — it is the Product Analysis *document type*; move to §3 |
| Emergency | **Quick + mandatory retro doc**, one row, not a fourth lane |

The §2 delivery-lane table is deleted and replaced by the tier table. Three names, one place.

### Where each rule lives after A-2

One home per rule, chosen by who enforces it:

| Enforced by | Home | Prose allowed elsewhere |
|---|---|---|
| A hook or script (staging, push, secrets, stop gate, action pins, docs index) | the script itself | one line naming the script |
| An agent, while writing code (the six engineering standards) | **`AGENTS.md`** — always loaded by the executor | a pointer, never a restatement |
| A human, while deciding | `METHODOLOGY.md` | — |

`METHODOLOGY.md` §11.3/§11.4 become pointers into `AGENTS.md`; §8's guardrail catalogue becomes
a six-row table (the authority is `doctor.sh` output); `code-reviewer.md` and both
`review-execution` copies drop their restatements and cite `AGENTS.md`. One severity scale
survives — `sev:high|med|low|nit`, because it is the one that already maps to labels.

### Deliberate non-goal: don't split planner from executor at Standard

The two-agent split earns its cost at Strict. At Standard, the load-bearing part is the
**independent review**, not the planner/executor separation — and collapsing plan+execute into
one session removes one full contract re-read per change. This is the largest single saving
available and also the most opinionated change here, so it is called out as its own decision
rather than smuggled into A-1. Independent review is retained at every tier above Quick.

## Interface (before the implementation)

```
.agentic-flow-assurance                 one line: quick | standard | strict

scripts/assurance.sh
  (no args)                             print current tier and its rendered word budget
  set <tier> [--reason "<why>"]         re-render CLAUDE.md + AGENTS.md; refuse a downgrade
                                        below a hard-trigger floor without --override
  --check                               exit non-zero if state and rendered region disagree

profiles/assurance/<tier>.tsv           data only, one region per row:
  # region<TAB>text
  brief<TAB>...          issues<TAB>...        review<TAB>...
  verify<TAB>...         report<TAB>...

scripts/render-assurance.sh <tier> <file>...    fills the marked region, like
                                                 render-stack-profile.sh does for the Makefile

config/payload.tsv                      new disposition: `mirror`
  <source>  <dest1>,<dest2>  <scope>  preserve  mirror

plan-to-issues spec                     { "profile": "standard" | "strict", ... }
                                        absent → legacy topology (Codex's rule, kept)
```

## Threat model (one paragraph)

The new attack surface is **assurance downgrade**. Anything that can write
`.agentic-flow-assurance` can silently reduce required review on security-relevant work, and an
agent is a plausible author. Mitigations: the tier is a tracked file, so a change is a reviewable
diff in a signed commit; `assurance.sh` refuses to lower the tier when a hard Strict trigger
applies unless `--override` plus a reason is given; `doctor.sh --check` fails when state and
rendered region disagree, so a hand-edited contract region cannot pose as a rendered one. The
invariant that must not bend: **CI authority derives from the CI environment and branch
protection, never from this file.** Tier selection must not be readable by any CI decision — if
a workflow ever branches on it, the mitigation is gone.

## Failure behavior

| Operation | On missing input | On malformed input | On partial completion |
|---|---|---|---|
| read `.agentic-flow-assurance` | default `standard`, warn once | refuse to render, exit non-zero, name the bad value | n/a |
| `render-assurance.sh` | missing marked region → exit non-zero, no write | unknown region key in TSV → reject whole file before writing | write via temp file + atomic rename; never a half-rendered contract |
| `assurance.sh set` | no `--reason` on a downgrade → refuse | unknown tier → refuse, list valid tiers | render both files or neither |
| `plan-to-issues` | absent profile → legacy topology | unknown profile → exit before any `gh` call | existing recovery path unchanged |

Bounds: tier enum is closed (3 values); the TSV region key set is closed; rendered regions are
capped at 1,200 words and `--check` fails past that, so the budget cannot rot back.

## Out of scope

- Automatic tier selection from diff size, filenames, or model judgement.
- Model routing per tier.
- Token telemetry, and any manual pilot log.
- A new review runner or tmux orchestration.
- Different engineering standards per tier — tiers change ceremony only.
- Letting any tier disable hooks, secret scanning, or CI.
- Rewriting completed documents in `docs/done/`.
- Splitting `self-test.sh` (`ROADMAP.md` §3.5 already owns that, deliberately deferred).

## Open questions

- **[BLOCKING]** This plan or Codex's? They are not composable as written — A-1 deletes the lane
  table that Codex's F-1 preserves, and A-5 replaces the branching prose that Codex's F-2 adds.
  The merge that makes sense is: this document's A-1…A-5 plus Codex's F-3 as written.
- Does Standard keep the planner/executor split? (See the non-goal above; recommendation is no.)
- Should `make test-one` stay a full-suite alias in this repo, given every template advertises it
  as the cheap per-step lane?

---

# Part B — Implementation Brief

> **Audience:** an implementing agent (Codex). Steps are ordered so de-duplication lands before
> the tier axis is added — adding tiers first would triple the duplication A-2 removes. One
> logical commit per step; stage files by name; *why*-first bodies. Approach and insights, not
> code.

## Branch

Base: `main`. One branch, one PR: `codex/adaptive-assurance`. Each step is one commit closing
its own `Fixes #N`.

## Definition of done (whole brief)

- Three tiers, one vocabulary; the four-lane table is gone.
- Each of the nine measured rules has exactly one home; one severity scale harness-wide.
- Byte-identical adapter files have one source.
- The tier is project state with an audited upgrade/downgrade command and a `doctor.sh` line.
- Contract files carry only the tier in force; switching tier re-renders them.
- Exported prose **≤ 9,000 words** (from 13,771) and the rendered per-tier contract region
  **≤ 1,200 words**, both asserted by a test so they cannot rot back.
- Legacy profile-less docs and specs behave exactly as today.
- CI authority is unchanged and unreadable from the tier file.
- `make check` and `make test` green; a fresh export passes its own default checks.

## Verification commands

```bash
make check                        # per step
make test-one F=scripts/self-test.sh
make test                         # end of brief
```

---

## A-1 — Collapse seven modes into three tiers

**Why first:** everything downstream needs one stable vocabulary.

**Inspect:** `METHODOLOGY.md` §2/§3, `README.md`, `CLAUDE.md`, `AGENTS.md`, both
`templates/harness/` mirrors.

**Approach:** replace the §2 delivery-lane table with the tier table; move *Decision* into §3 as
the Product Analysis document type; fold *Emergency* into one Quick row with a mandatory retro.
Adopt Codex's Quick eligibility list, hard Strict triggers, Quick promotion conditions, universal
baseline, `Workflow: Quick / non-authoritative` report line, tier-vs-authority separation, and
the live-interface rule **verbatim** — no rewrite. Repair internal section references that move.

**Test:** extend `self-test.sh` so an exported `METHODOLOGY.md` fails the fixture if it lacks any
of: the three tier names, the exact Quick non-authoritative string, Standard-as-default, the
hard triggers, the live-interface rule, or CI authority stated independent of tier — **and** if
it still contains "Fast Fix" or "Planned Change".

**Stop if:** collapsing Emergency into Quick would weaken any hotfix evidence requirement.

**DoD:** one tier vocabulary; no surviving lane table.
**Commit:** `Collapse delivery lanes into three assurance tiers`

---

## A-2 — One home per rule; one severity scale

**Why second:** the biggest measured saving, and it must precede the tier axis.

**Inspect:** `METHODOLOGY.md` §5/§8/§11, `CLAUDE.md`, `AGENTS.md`, both mirrors,
`.opencode/agent/code-reviewer.md`, `.opencode/command/review.md`, both `review-execution`
copies, `docs/templates/review.md`.

**Approach:** apply the "enforced by → home" table. The six engineering standards live in
`AGENTS.md` only; `METHODOLOGY.md` §11.3/§11.4 become pointers; §8's catalogue becomes a
six-row table naming each script, with `doctor.sh` output as the authority; the `Hooks` section
in `CLAUDE.md` keeps one line per hook. Reviewer surfaces cite `AGENTS.md` and delete their
restatements. Unify every review surface on `sev:high|med|low|nit`, and state the mapping to a
merge verdict once. Narrow `block-git-add-all.sh` to match a real git invocation (`^\s*git\s+add`)
rather than the string anywhere in a command — a `grep` for the rule tripped it during this audit.

**Test:** a fixture asserting each of the nine rules appears in exactly one shipped file (a
count, so a future restatement fails); a fixture asserting only one severity vocabulary is
present across review surfaces; a `block-git-add-all.sh` case proving a `grep` whose *pattern*
contains the forbidden string is allowed while the real command is still blocked.

**Stop if:** removing a restatement would leave a rule with no always-loaded home for the role
that must apply it.

**DoD:** nine rules, nine homes; one severity scale; the guard no longer fires on prose.
**Commit:** `Give every contract rule exactly one home`

---

## A-3 — `mirror` disposition in the payload manifest

**Why third:** it removes 1,317 words of duplicated skill text and makes A-5 a one-file edit
instead of a two-file one.

**Inspect:** `config/payload.tsv`, `scripts/export.sh`, `scripts/check-payload-manifest.sh`,
`scripts/doctor.sh`, `self-test.sh` export fixtures.

**Approach:** add a `mirror` disposition whose destination field is a comma-separated list, so
one source exports to N paths. Apply it to `review-execution/SKILL.md` (`.agents/` +
`.opencode/`, currently byte-identical) and `plan-to-issues/SKILL.md` (`.claude/` + `.agents/`)
— and while collapsing the latter, fix its live drift: the Stack profile lives in `CLAUDE.md`
for both agents, so the `.agents/` copy's `AGENTS.md` pointer is simply wrong. Keep
`payload.tsv` the only membership source; `check-payload-manifest.sh` must still reject an
adapter file outside the manifest, including a mirror destination.

**Test:** export fixture asserting both mirror destinations exist and are byte-identical to the
source; a manifest fixture rejecting a mirror row whose destination list is malformed or whose
source is missing; a fixture proving a stray adapter outside the manifest still fails.

**Stop if:** a mirror destination legitimately needs to differ — then it is not a mirror and the
divergence needs a stated reason.

**DoD:** one source per identical adapter; export unchanged from a target's point of view.
**Commit:** `Export identical agent adapters from one source`

---

## A-4 — The tier as project state

**Why fourth:** the rendering step in A-5 needs something to read.

**Inspect:** `.agentic-flow-stack` handling in `scripts/init.sh` and `scripts/doctor.sh`,
`config/payload.tsv`, `ADOPTION.md`.

**Approach:** add `.agentic-flow-assurance` (one line, closed enum) and `scripts/assurance.sh`
with `set` / bare-report / `--check`. `init.sh --assurance <tier>` writes it, defaulting to
`standard`; absent file reads as `standard` with a one-time warning. A downgrade below a hard
Strict trigger requires `--override` **and** `--reason`; the reason goes in the commit message
for the state change, not into a new artifact. `doctor.sh` reports the tier beside the stack and
`--check` fails when state and rendered region disagree. Bash 3.2 only: no associative arrays,
no `mapfile`.

**Test:** unknown tier refused with the valid list; downgrade without `--override` refused;
downgrade with `--override` but no `--reason` refused; missing file defaults to `standard` and
warns once; `doctor.sh --check` fails on a state/render mismatch and passes when consistent.

**Stop if:** any CI workflow would need to read the tier — that breaks the threat-model
invariant and the design must change instead.

**DoD:** a tracked, validated, audited project tier that `doctor.sh` reports.
**Commit:** `Hold the assurance tier as audited project state`

---

## A-5 — Render tier-specific contract regions

**Why fifth:** this is the mechanism that makes lowering assurance actually remove context.

**Inspect:** `scripts/render-stack-profile.sh` (the pattern to copy), `profiles/*.tsv` (the data
shape), `templates/harness/CLAUDE.md`, `templates/harness/AGENTS.md`, `docs/templates/*`.

**Approach:** add `profiles/assurance/{quick,standard,strict}.tsv` with a closed region-key set
(`brief`, `issues`, `verify`, `review`, `report`) and `scripts/render-assurance.sh` filling a
marked region in `CLAUDE.md` and `AGENTS.md`, exactly as the stack renderer fills the Makefile.
Write via temp file + atomic rename; reject an unknown region key before touching anything.
Wire it into `init.sh` and `assurance.sh set`. The Feature template gains `Assurance tier` and
`Selection rationale`; the Security template declares Strict; Standard means exactly one
implementation step.

**Test:** each tier renders and its region stays ≤1,200 words (failure-first: a fixture with an
over-budget TSV must fail); an unknown region key is rejected with no write; a missing marked
region exits non-zero with no write; a mid-render failure leaves the original file intact;
switching Strict → Quick and back is idempotent; a Quick-rendered `AGENTS.md` contains **no**
Strict decomposition text.

**Stop if:** a rule genuinely must appear in all three tiers — then it belongs in the unrendered
universal baseline, not in the tier data.

**DoD:** the contract in force is the only contract present; switching tier re-renders it.
**Commit:** `Render the assurance tier into the agent contracts`

---

## A-6 — Tier-aware issue generation and lifecycle

**Why sixth:** it mutates the live GitHub boundary and must follow settled policy.

**Inspect:** `scripts/plan-to-issues.sh`, the (now single-source) `plan-to-issues/SKILL.md`,
`scripts/lifecycle-status.sh`, every plan-reconciliation and lifecycle fixture in
`self-test.sh`.

**Approach:** **adopt Codex's F-3 as written** — optional `profile` enum validated offline before
the first `gh` mutation; `standard` requires exactly one step and reconciles one stamped work
issue; `strict` keeps the tracker + sub-issue topology; absent profile keeps legacy topology;
`--doc` rejects a spec whose profile conflicts with the document. Preserve identity stamps,
bounded discovery, dry-run, diff, approval stamping, recovery, and rerun behavior. Make
lifecycle closure tier-aware; Quick has no document lifecycle. The one addition here: when
`.agentic-flow-assurance` exists, a spec below the project baseline is refused unless the
document records an explicit downgrade rationale.

**Test:** Codex's twelve failure-first cases verbatim, plus: a spec below the project baseline
is refused offline; the same spec is accepted when the document records a downgrade rationale.

**Stop if:** the single-issue path cannot reuse stable identity without title lookup, or
Standard reconciliation could touch existing Strict/legacy issues.

**DoD:** Standard creates one recoverable work issue; Strict and legacy unchanged; closure
requirements match the tier.
**Commit:** `Apply assurance tiers to issue generation and lifecycle`

---

## A-7 — Shrink `METHODOLOGY.md`, declare the lifecycle, verify the budget

**Why last:** the budget can only be asserted once the content has stopped moving.

**Inspect:** `METHODOLOGY.md` §4/§8/§9/§10, `templates/ci/README.md`, `templates/ci/*.yml`,
`README.md`, `ADOPTION.md`, `docs/README.md`, `scripts/docs-index.sh`, `config/payload.tsv`.

**Approach:** **most of this step is `context_optimization.md` O-1…O-5 and O-8** — if that pass
has landed, the routing, the §8/§9/§10/§11 reductions, the lifecycle single-sourcing, and the
budget guard already exist, and this step reduces to: add the `README.md` tier comparison and
decision tree, extend the budget guard to cover the rendered tier regions, refresh
`docs/README.md`. If Part 1 has **not** landed, do its O-1…O-5 here and drop the tier-specific
work until it has.

Two corrections to earlier drafts of this step, from reading the scripts: `METHODOLOGY.md`
section numbers must **not** be renumbered (~40 `§N` references live in hooks, CI templates,
doc templates, and skills — two of them print in user-visible hook messages), and `ADOPTION.md`
must **stay exported** because `scripts/doctor.sh:134` calls `require_file ADOPTION.md`. Re-scope
it rather than dropping it — see Part 1 O-2.

**Test:** a budget fixture asserting exported prose ≤9,000 words and `METHODOLOGY.md` ≤2,600
words (failure-first: it must fail against today's 13,771 / 4,667); a fixture asserting no
lifecycle stage is rendered by `docs-index.sh` that `METHODOLOGY.md` §4 does not declare; the
fresh-export checks stay green.

**Stop if:** shrinking §10 would delete rationale that exists in no other file — move it, never
drop it.

**DoD:** the budget is enforced by a test; the declared lifecycle matches the generated one; a
fresh export is green.
**Commit:** `Shrink the methodology to its non-duplicated core`

---

# Expected outcome

| | Today | After |
|---|---|---|
| Exported harness prose | 13,771 w (~18.6k tok) | ≤9,000 w (~12.2k tok) |
| `METHODOLOGY.md` | 4,667 w | ≈2,300 w |
| Always-loaded contract, Quick project | 1,755 w (all rules) | ≈900 w (Quick only) |
| Handoffs for a small change | 9 | 1 |
| Contract input per small change (3 agents) | ~36k tok | ~6k tok (1 agent, Quick) |
| Rules with more than one home | 9 | 0 |
| Severity scales | 3 | 1 |
| Byte-identical shipped files | 2 pairs | 0 |

The ceremony reduction is Codex's contribution; the context reduction is this document's. Both
are needed, and the second one is larger.

# Status / evidence

- **Approval:** pending — and mutually exclusive with `feature-progressive-assurance-profiles.md`
  as written; see Open questions.
- **Tracking issue:** pending.
- **Branch:** pending activation.
- **Verification evidence:** pending implementation.
- **Review verdict:** pending.
- **Audit basis:** measurements taken at `d507bf4` on 2026-07-25 — word counts over tracked
  files, restatement counts by grep across tracked markdown excluding `docs/done/` and
  the proposal docs, and a timed `make check` (10.3s).
