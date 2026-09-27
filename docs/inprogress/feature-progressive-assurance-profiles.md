<!-- TRIAGE (first pass · 2026-07-25) -->
> **Superseded:** `feature-harness-optimization.md` Part A §7 and Step F-9 own assurance
> policy and baseline implementation. This proposal remains for design history.
> **Type:** Feature · **Status:** 🟦 Proposal
> Introduce Quick, Standard, and Strict assurance profiles so routine work pays less
> ceremony while risky work retains decomposition, independent review, and traceability.

# Feature plan — Progressive assurance profiles

## Execution status

This document is actionable but not yet approved.

Before execution:

- [ ] Human approves the decisions and open questions below.
- [ ] Move this file to `docs/inprogress/feature-progressive-assurance-profiles.md`, because
      the current lifecycle, `plan-to-issues` skill, and review skill read active briefs from
      `docs/inprogress/`.
- [ ] Refresh the generated docs index with `scripts/docs-index.sh`.
- [ ] Run the `plan-to-issues` skill against the approved in-progress document.
- [ ] Create one branch for the complete pass:
      `codex/progressive-assurance-profiles`.

## Tracker

- [ ] F-1 Define the profile contract and live-interface rule.
- [ ] F-2 Make templates and agent contracts profile-aware.
- [ ] F-3 Make issue generation and lifecycle checks profile-aware.
- [ ] F-4 Document adoption and complete regression coverage.

---

# Part A — Approved design target

## Problem

The harness currently offers two delivery lanes—Fast Fix and Planned Change—but most
executable work still converges on the same formal Feature/Security document, tracking issue,
sub-issues, branch, commits, review handoff, and evidence lifecycle.

That structure is valuable for risky or ambiguous work and helps lower-capability models by
turning a large problem into bounded steps. It has poor return when a small, reversible
change costs less than the workflow used to deliver it.

The harness needs progressive assurance: preserve universal engineering and CI guarantees,
while varying planning, issue decomposition, review depth, and retained evidence according
to risk.

## Fixed decisions

The implementation must preserve these decisions:

1. **Standard is the default profile.**
2. **Quick is explicit and locally non-authoritative.**
3. **Strict is selected by hard risk triggers or an explicit human decision.**
4. **Profiles change ceremony, not engineering standards.**
5. **CI remains authoritative for merge-bound work in every profile.**
6. **Workflow profile and execution authority are separate concepts.**
7. **Existing profile-less documents and plan specs retain current behavior.**
8. **Do not recreate the removed review orchestration scripts.**
9. **OpenCode remains the independent reviewer through the existing issue-label handoff.**
10. **Code and executable tests describe existing interfaces; briefs describe intended
    behavior and invariants.**

## Universal baseline

Every profile retains the applicable existing rules:

- inspect current code, callers, tests, and configuration before editing;
- validate external input once at its boundary;
- deny authorization by default at a chokepoint;
- use structured arguments and queries instead of interpreted string construction;
- keep secrets out of source and logs;
- bound external calls, loops, and queries;
- add a regression test for a bug fix;
- run proportionate verification;
- stage files by name;
- commit through the role-specific signing wrapper;
- never push or merge as an agent;
- treat CI, not an agent's statement, as the merge authority.

Quick is a reduction in process, not permission to weaken these rules.

## Profile contract

| Concern | Quick | Standard | Strict |
|---|---|---|---|
| Use when | Small, clear, reversible local work | Ordinary product and maintenance work | Security-sensitive, irreversible, cross-cutting, or high-impact work |
| Formal brief | None | Short one-step Feature brief | Full Feature or Security analysis and ordered brief |
| GitHub topology | None | One work issue | One tracker plus one sub-issue per independently shippable step |
| Branch/PR | None while local; promote before normal merge workflow | One branch and one PR | One branch/PR per approved pass unless explicitly split |
| Test evidence | Focused test and inexpensive checks | Regression test, focused test, `make check`, CI | Failure-path tests per step, `make check` per step, full suite, CI |
| Independent review | None; executor self-check only | One OpenCode review pass | OpenCode review per step plus complete-pass review where required |
| Durable artifact | None | Issue, PR, commit, review verdict, CI | Full approval, step, review, and CI traceability |
| Local authority | Explicitly non-authoritative | Supporting evidence only | Supporting evidence only |

### Quick

Quick is eligible only when all relevant conditions are true:

- the requested outcome is unambiguous;
- the affected surface is small and understood;
- the change is easy to reverse;
- no shared or public contract changes;
- no authentication, authorization, secrets, migration, or data-integrity behavior;
- a focused verification command exists;
- unexpected failure has limited impact;
- no formal traceability requirement exists.

Quick workflow:

1. Inspect the implementation and closest tests.
2. Confirm no Strict trigger applies.
3. Make the bounded change.
4. Run the focused test and inexpensive relevant checks.
5. Perform an executor self-check.
6. Report exactly:

   ```text
   Workflow: Quick / non-authoritative
   Verification: <commands and outcomes>
   Promotion required: no
   ```

7. Promote to Standard before entering the normal issue/branch/OpenCode merge workflow.

Quick creates no implementation document, GitHub issue, dedicated branch, review artifact,
or CI-style evidence name. It must not be represented as reviewed or merge-authoritative.

Promote Quick immediately when work reveals unexpected coupling, a shared interface,
security or data behavior, unclear requirements, conflicting tests, missing focused
verification, repeated failed attempts, or a larger blast radius than selected.

### Standard

Standard is the default for work that does not clearly qualify for Quick and has no Strict
trigger.

A Standard brief contains:

- problem and intended observable behavior;
- boundaries and non-goals;
- invariants;
- live code surfaces to inspect;
- regression or failure-path test;
- exact verification commands;
- one implementation step and Definition of Done.

Standard workflow:

1. Write and approve the short brief.
2. Create one work issue and one branch.
3. Inspect the live implementation, callers, and tests.
4. Implement the change and regression test.
5. Run the focused test, `make check`, and proportionate broader tests.
6. Commit the step with `Fixes #N`.
7. Flip the work issue from `agent:codex,needs-execution` to
   `agent:opencode,needs-review`.
8. Receive one independent OpenCode review.
9. Re-review only if findings materially change implementation or approach.
10. Run authoritative CI and record its evidence.

A dedicated review document is optional; the issue, PR, review verdict, commit, and CI run
normally provide sufficient evidence.

### Strict

Strict is required for:

- authentication, identity, authorization, or access control;
- credentials, secrets, encryption, signing, or dependency trust;
- destructive operations or meaningful data-loss risk;
- database or persistent-data migrations;
- public APIs or externally consumed compatibility contracts;
- billing, payments, financial calculations, or entitlements;
- deployment, release, rollback, or production infrastructure;
- private, regulated, or otherwise sensitive data;
- changes spanning several architectural boundaries;
- multi-step transitions whose intermediate states must remain valid;
- changes that are difficult to reverse;
- explicitly requested high-assurance work.

Projects may add domain-specific triggers in their root `CLAUDE.md`. Reducing a profile
selected by a hard trigger requires explicit human approval and a recorded reason.

Strict workflow:

1. Write and approve the full Feature or Security analysis.
2. Record threats, failure behavior, compatibility constraints, and rollback expectations.
3. Decompose work into independently shippable steps.
4. Create a tracking issue and one sub-issue per step.
5. Before each step, re-read actual callers, callees, tests, and configuration.
6. Implement and verify one step at a time.
7. Commit each step with its own `Fixes #N`.
8. Hand each completed step to OpenCode using the existing label state machine.
9. Resolve guidance references and all material review findings.
10. Re-review materially changed implementation.
11. Run the full suite and authoritative CI.
12. Retain approval, review, verification, and CI evidence.

Strict traceability:

```text
risk or requirement
    → approved brief
    → implementation step
    → sub-issue
    → regression test
    → signed commit
    → independent review
    → authoritative CI
```

## Selection decision

```text
Does a hard Strict trigger apply?
        ├── yes → Strict
        └── no
             └── Is the work bounded, low-risk, reversible,
                 unambiguous, and free of shared-interface changes?
                     ├── yes → Quick
                     └── no  → Standard
```

When classification is uncertain, use Standard. A planner or human may always raise the
profile.

## Workflow profile versus authority

Profile answers how much planning, review, and traceability the change needs. Execution
context answers whether a result is local feedback or authoritative CI evidence.

The harness must not allow combinations such as:

```text
profile=quick
context=local
authority=ci
```

CI derives its authority from the CI environment and required status-check configuration.
A profile flag cannot downgrade it.

## Live-interface rule

Add this normative rule:

> Code and executable tests define the existing interface. The approved brief defines the
> intended change and its invariants.

Before every implementation step, the executor re-reads:

- the target implementation;
- direct affected callers and callees;
- relevant tests;
- configuration and environment handling;
- error propagation across the changed boundary.

Briefs should describe observable behavior, constraints, invariants, and inspection routes.
They should avoid copied private signatures, line numbers, argument order, and implementation
mechanics unless the exact shape is itself a requirement.

When live code contradicts the brief:

1. If the mismatch is only descriptive and intent remains valid, follow the live interface.
2. If it changes scope, risk, sequencing, compatibility, or required tests, stop.
3. Correct and reapprove the affected brief before continuing.

## Backward compatibility

- New Standard and Strict documents declare an assurance profile.
- New plan specs declare `profile: standard|strict`.
- Existing documents and plan specs without a profile retain the current Planned Change
  behavior.
- Existing issue markers and reconciliation identity remain valid.
- Completed documents are not rewritten.
- Security documents become Strict only when newly created from the updated template; no
  migration is inferred for historical documents.

## Out of scope

- Automatic profile selection from filenames, diff size, or model guesses.
- Automatic model routing.
- Token telemetry infrastructure.
- A new review runner or tmux orchestration.
- Different engineering standards per profile.
- Allowing Quick to disable hooks, secret scanning, or CI.
- Requiring an issue or formal artifact for Quick.
- Requiring a separate review document for Standard.
- Rewriting completed or active legacy documents.

---

# Part B — Implementation plan

## Branch and commit structure

Base: `main`.

Branch after approval:

```text
codex/progressive-assurance-profiles
```

Use one branch and one PR for the complete plan. Land one logical commit per step. After
each step:

1. run the step verification;
2. commit with `Fixes #N`;
3. flip the step issue to `agent:opencode,needs-review`;
4. address review findings before advancing where they affect the next step.

## Whole-plan Definition of Done

- Quick, Standard, and Strict have distinct, documented contracts.
- Standard is the default for new work.
- Quick is explicit and always locally non-authoritative.
- CI authority cannot be downgraded through profile selection.
- Standard reconciles one work issue.
- Strict retains tracker plus sub-issues.
- Legacy profile-less documents and specs preserve current behavior.
- Strict triggers and Quick promotion rules are shipped.
- The live-interface rule appears in planner, executor, and reviewer guidance.
- OpenCode review handoff remains the independent-review mechanism.
- Root contracts and exported pristine templates remain synchronized where intended.
- A fresh exported project contains the profile contract and passes its default checks.
- `make check` and `make test` pass.

## Verification commands

Per step:

```bash
make check
make test-one F=scripts/self-test.sh
```

At completion:

```bash
make test
```

The executor must also run any more-focused command introduced by a step's regression test.

## Executor packet

For each issue, reduce the relevant step to:

```text
Profile:
Objective:
Intended behavior:
Invariants:
Non-goals:
Live code to inspect:
Failure path to test:
Verification commands:
Stop conditions:
Definition of Done:
```

Do not paste private code signatures into the packet. The named files are inspection routes,
not assertions about their current interfaces.

---

## F-1 — Define progressive profiles and the live-interface rule

**Why first:** All later templates and scripts require one stable semantic contract.

**Files to inspect before editing:**

- `METHODOLOGY.md`
- `README.md`
- `CLAUDE.md`
- `AGENTS.md`

**Implementation:**

1. Replace or refine the Fast Fix / Planned Change discussion in `METHODOLOGY.md` with the
   three profiles while keeping Decision and Emergency behavior intact.
2. Add the selection decision, hard Strict triggers, Quick promotion conditions, universal
   baseline, and backward-compatibility rule.
3. Separate workflow profile from CI authority.
4. Add the live-interface rule to design, execution, and review guidance.
5. Describe lower-model optimization as bounded executor packets plus executable guardrails,
   not repetition of the full methodology.
6. Preserve current section anchors where possible and repair internal references if they
   move.

**Failure-first regression:** Extend `scripts/self-test.sh` so an exported methodology fails
the fixture if any of these are absent:

- all three profile names;
- the exact Quick non-authoritative label;
- Standard as default;
- Strict triggers;
- live-call-site inspection;
- CI authority remaining independent of profile.

**Stop conditions:**

- A proposed edit weakens an existing commit, secret-scanning, review-handoff, or CI rule.
- Delivery-profile semantics conflict with Decision or Emergency lanes.

**DoD:** `METHODOLOGY.md` provides one unambiguous profile contract and interface-truth rule.

**Commit:** `Define progressive assurance profiles`

---

## F-2 — Make templates and agent contracts profile-aware

**Why second:** Humans and agents need concise profile-specific inputs before automation can
interpret a profile safely.

**Files to inspect before editing:**

- `CLAUDE.md`
- `AGENTS.md`
- `templates/harness/CLAUDE.md`
- `templates/harness/AGENTS.md`
- `docs/templates/feature-analysis.md`
- `docs/templates/security-review.md`
- `docs/templates/review.md`
- `.agents/skills/review-execution/SKILL.md`

**Implementation:**

1. Update planner guidance to select a profile before preparing execution artifacts.
2. Update executor guidance to:
   - accept explicitly labeled Quick local work without a formal brief;
   - require normal handoff for Standard and Strict;
   - inspect live call sites before every step;
   - promote Quick when its assumptions fail;
   - never claim Quick output is authoritative.
3. Keep the existing OpenCode label handoff for Standard and Strict.
4. Update the Feature template with:
   - `Assurance profile`;
   - `Selection rationale`;
   - Standard-optional and Strict-required sections;
   - a rule that Standard contains exactly one implementation step.
5. Make the Security template declare Strict by default.
6. Update the Review template and `review-execution` skill to check the declared profile and
   live interfaces. Strict review records guidance resolution and durable evidence.
7. Keep root and `templates/harness/` copies behaviorally synchronized, except for explicit
   project-local customizations such as the concrete OpenCode role.

**Failure-first regression:**

- An exported fixture without profile-selection guidance fails.
- An exported executor contract without the Quick non-authoritative label fails.
- A Feature template missing profile or selection rationale fails.
- A Security template not defaulting to Strict fails.
- The review skill missing live-interface tracing fails.

**Stop conditions:**

- Supporting Standard would require a second Feature document type.
- Updating pristine templates would accidentally export project-specific OpenCode tooling
  where the current project intentionally keeps it local.

**DoD:** Planner, executor, reviewer, and templates express consistent profile behavior in
this repository and fresh exports.

**Commit:** `Make agent contracts profile-aware`

---

## F-3 — Apply profiles to issue generation and lifecycle checks

**Why third:** This changes the live issue-reconciliation boundary and therefore follows the
settled policy and templates.

**Files and call sites to inspect before editing:**

- `scripts/plan-to-issues.sh`
- `.agents/skills/plan-to-issues/SKILL.md`
- `.claude/skills/plan-to-issues/SKILL.md`
- `scripts/lifecycle-status.sh`
- all `scripts/self-test.sh` plan-reconciliation and lifecycle fixtures
- callers documented in `METHODOLOGY.md`, `CLAUDE.md`, and `AGENTS.md`

**Plan-spec interface:**

```json
{
  "profile": "standard | strict",
  "tracking": {},
  "steps": []
}
```

Rules:

- `standard` requires exactly one step and reconciles one stamped work issue;
- `strict` preserves the current tracker-plus-sub-issues topology;
- a missing profile preserves legacy topology;
- `--doc` rejects a spec whose profile conflicts with the document;
- validation happens before the first GitHub mutation.

**Implementation:**

1. Extend offline spec validation with the optional profile enum.
2. For Standard, combine plan context, the single step DoD, exact verification commands,
   and execution labels into one idempotently reconciled work issue.
3. Preserve stable identity stamps, bounded discovery, dry-run, diff, approval stamping,
   recovery, and rerun behavior.
4. Preserve Strict and legacy tracker/sub-issue behavior.
5. Update both plan-to-issues skill copies:
   - Quick never invokes the skill;
   - Standard emits one step and one work issue;
   - Strict emits the existing ordered topology;
   - live GitHub mutation still requires explicit approval.
6. Make lifecycle closure profile-aware:
   - Standard: approval, work-issue link, CI evidence, review verdict;
   - Strict: Standard fields plus resolved guidance and durable review evidence;
   - legacy: current closure schema;
   - Quick: no document lifecycle.
7. Keep parsing deterministic and offline. Do not add a general review runner.

**Failure-first regression cases:**

- reject an unknown profile without calling `gh`;
- reject Standard with zero or multiple steps;
- reject a spec/document profile mismatch before mutation;
- create exactly one Standard issue;
- rerun Standard without duplication;
- recover a partially created Standard issue;
- preserve current Strict tracker/sub-issue reconciliation;
- preserve profile-less legacy behavior;
- block Strict closure with unresolved guidance;
- block Strict closure without review evidence;
- accept Strict closure when both are present;
- keep Standard independent of Strict-only fields.

**Stop conditions:**

- The single-issue path cannot reuse stable identity without title-based lookup.
- Standard reconciliation could close or edit existing Strict/legacy issues.
- Profile validation would require a network request.

**DoD:** Standard creates one recoverable work issue; Strict and legacy behavior remain
stable; lifecycle requirements match the declared profile.

**Commit:** `Apply assurance profiles to issue lifecycle`

---

## F-4 — Document adoption and verify the complete workflow

**Why last:** Adoption guidance must describe stabilized executable behavior.

**Files to inspect before editing:**

- `README.md`
- `ADOPTION.md`
- `docs/README.md`
- `templates/ci/README.md`
- `.github/workflows/ci.yml`
- `templates/ci/ci.yml`
- `scripts/doctor.sh`
- `scripts/self-test.sh`
- `config/payload.tsv`

**Implementation:**

1. Add a one-screen profile comparison and decision tree to the main README.
2. Document Standard as default, Quick as explicit, and project-local Strict triggers.
3. Explain that merge-bound Quick work is promoted to Standard under the current
   issue/OpenCode workflow.
4. Document Standard and Strict `plan-to-issues` examples.
5. Keep CI calling Make targets. Do not create a workflow-profile CI matrix.
6. Update doctor only if a new shipped file or invariant genuinely needs adoption
   validation.
7. Keep `config/payload.tsv` as the only export-membership source.
8. Refresh `docs/README.md`.
9. Run the full test suite and an independent `review-execution` review focused on downgrade
   paths, legacy reconciliation, and duplicated sources of profile truth.

**Regression and export verification:**

- A fresh export contains the profile-aware methodology, templates, and agent contracts.
- Its default Make targets remain green.
- CI cannot be configured as Quick through the new profile field.
- Quick output never uses CI artifact wording.
- Existing profile-less fixtures still pass.

**Pilot:** For the next ten representative changes, manually record:

- selected profile;
- first-pass success;
- retries;
- review findings;
- approximate elapsed time;
- approximate token cost.

Use the pilot to decide whether the profiles improve ROI before adding automation or more
profile options.

**Stop conditions:**

- Documentation implies Quick bypasses CI, hooks, secret scanning, or engineering standards.
- Adoption would silently rewrite existing active documents.

**DoD:** An adopter can select a profile from the README, a fresh export contains matching
contracts, CI authority is unchanged, and the full harness suite passes.

**Commit:** `Document progressive assurance adoption`

---

# Acceptance checklist

## Behavior

- [ ] Quick is explicit and prints `Quick / non-authoritative`.
- [ ] Standard is the default for new work.
- [ ] Strict is selected by hard triggers or human choice.
- [ ] Quick promotion preserves investigation but adds missing Standard requirements.
- [ ] Standard creates one work issue.
- [ ] Strict creates a tracker plus independently shippable step issues.
- [ ] OpenCode review handoff works for Standard and Strict.
- [ ] CI remains authoritative regardless of profile.

## Compatibility

- [ ] Existing profile-less documents keep their current lifecycle.
- [ ] Existing profile-less specs keep tracker/sub-issue reconciliation.
- [ ] Existing identity stamps remain discoverable.
- [ ] Completed documents are not rewritten.
- [ ] Root and exported contracts agree where intended.

## Verification

- [ ] Failure-first profile validation tests pass.
- [ ] Standard reconciliation tests pass.
- [ ] Strict reconciliation tests pass unchanged or with explicitly justified updates.
- [ ] Lifecycle profile tests pass.
- [ ] Fresh-export tests pass.
- [ ] `make check` passes after every step.
- [ ] `make test` passes at completion.
- [ ] Independent review verdict is approved.
- [ ] Authoritative CI is green.

# Status / evidence

- **Approval:** pending.
- **Tracking issue:** pending.
- **Branch:** pending activation.
- **Verification evidence:** pending implementation.
- **Review verdict:** pending.
