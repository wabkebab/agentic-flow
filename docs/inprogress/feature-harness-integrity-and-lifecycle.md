<!-- TRIAGE (first pass · 2026-07-24) -->
> **Type:** Feature · **Status:** 🚧 In progress
> Harden installation and upgrades, make agent support explicit, and close the workflow
> with derived evidence. Approved by the user on 2026-07-24; execution is in progress.

# Feature — harness integrity and lifecycle

## Tracker
- [x] F-1 Drive the payload from one manifest and ship every enabled agent adapter —
  implemented on `codex/harness-integrity-and-lifecycle` (#9)
- [x] F-2 Make scaffold regression tests hermetic and parallel-safe —
  implemented on `codex/harness-integrity-and-lifecycle` (#10)
- [x] F-3 Preserve merge candidates and represent installed versions truthfully —
  implemented on `codex/harness-integrity-and-lifecycle` (#11)
- [x] F-4 Separate source-only commands and strengthen adoption diagnostics —
  implemented on `codex/harness-integrity-and-lifecycle` (#12)
- [x] F-5 Make plan-to-issues idempotent, resumable, and Bash 3.2-safe —
  implemented on `codex/harness-integrity-and-lifecycle` (#13)
- [x] F-6 Clarify workflow lanes and make lifecycle qualification derivable —
  implemented on `codex/harness-integrity-and-lifecycle` (#14)
- [ ] F-7 Add modular stack profiles and finish the documentation — open

---

# Part A — Analysis

## Goal

Make agentic-flow trustworthy as a reusable standard across projects: a project should
receive the same enabled agent behavior as this repository, concurrent verification must
not damage the checkout, repeated exports must never destroy merge work or misreport the
installed version, issue creation must be repeatable, and workflow completion should be
derived from evidence rather than manual bookkeeping.

## Current state

- `.codex/hooks.json` and `.agents/skills/plan-to-issues/SKILL.md` exist in the source but
  are absent from `scripts/export.sh`'s allow-list, so adopted projects do not receive the
  Codex behavior this repository uses.
- `scripts/self-test.sh` modifies root `CLAUDE.md` and `docs/inprogress/`; concurrent test
  runs race during cleanup and can leave the checkout modified.
- `scripts/export.sh` overwrites an existing `.agentic-new` merge candidate and always
  advances `.agentic-flow-version`, even when the active target files were not updated.
- The exported payload includes `scripts/init.sh` but excludes the `export.sh` it calls.
- `scripts/plan-to-issues.sh` can duplicate or orphan issues, requires live GitHub access
  for dry-run, and expands optional empty arrays unsafely on Bash 3.2.
- The written workflow conflicts on whether a brief or a step owns a branch/PR, and a fully
  checked tracker can remain indefinitely in `docs/inprogress/`.
- Stack adoption is hard-coded to `none|node` rather than a profile contract.

## Proposed approach

### Option A — manifest-driven, transactional evolution (recommended)

Introduce a canonical payload manifest consumed by export, doctor, and tests; render and
test exports in temporary fixtures; preserve conflicts with versioned candidate names;
track installed and candidate versions separately; make issue application reconcile by a
stable spec identity; and define agent adapters and stack profiles around a shared core.

This costs more than isolated patches, but it removes the duplicated file inventories and
ambiguous state that caused the confirmed failures.

### Option B — patch each observed defect independently

Add the two missing Codex paths, lock the self-test, refuse an occupied `.agentic-new`,
and add a duplicate-title check to issue creation. This is smaller, but leaves three
separate payload inventories, no truthful upgrade model, and brittle product-specific
behavior.

**Recommendation:** Option A, delivered as independently shippable steps so the integrity
improvements land before the lifecycle and extensibility work.

## Interface

```text
config/payload.tsv
  source<TAB>destination<TAB>scope<TAB>merge-policy

scripts/export.sh [--dry-run|--force] <target>
  fresh install: writes installed version
  unresolved conflicts: writes versioned candidates and candidate version

scripts/doctor.sh [--check]
  validates the manifest, enabled adapters, unresolved candidates, installed/candidate
  version state, Make targets, hooks, docs, and CI posture

scripts/plan-to-issues.sh [--apply|--diff] [--doc <path>] <spec.json>
  dry-run is offline; apply is identified by a stable spec id and is safe to resume

stack profiles:
  detect, render, doctor, check, test, test-one, build, run
```

## Threat model

Targets and plan specs are external input. Paths must remain confined to the target,
generated issue bodies must be passed as arguments rather than interpreted strings, and
partial filesystem or GitHub failures must preserve enough state to resume without
overwriting user work or duplicating public artifacts.

## Failure behavior

| External call | On timeout/failure | On malformed response | On partial success |
|---------------|--------------------|-----------------------|--------------------|
| filesystem export | stop before version promotion | reject manifest/spec | preserve candidates; report exact state |
| GitHub API | bounded failure with resume instructions | reject response | discover stamped artifacts and resume |
| profile command | report failed capability | reject invalid profile | do not claim adoption complete |

Bounds: every GitHub lookup is repository-scoped and paginated with an explicit limit;
profile probes use existing command timeouts; manifest expansion is bounded by its entries.

## Out of scope

- Publishing a package manager artifact or hosted service.
- Automatically merging user-modified scaffold files.
- Supporting deployment topologies beyond the existing inert reference template.
- Pushing branches, opening pull requests, merging, or deploying.

## Open questions

None blocking. The user approved the audit recommendations as a whole on 2026-07-24.

---

# Part B — Implementation Brief

> Each step is independently shippable and ordered foundational-first. Use one logical
> commit per step, stage files by name, and verify the failure path before the success path.

## Branch

`codex/harness-integrity-and-lifecycle` off `main`.

## Definition of done

Every step below is complete; fresh and update exports are deterministic and non-destructive;
enabled agent adapters ship and validate; tests can run concurrently; issue application is
idempotent and resumable; workflow state has machine-checkable qualification; stack behavior
is profile-driven; `make check`, targeted tests, and `make test` pass.

## Verification commands

```bash
make check
make test-one F=scripts/self-test.sh
make test
scripts/doctor.sh --check
```

## Step 1 — Drive the payload from one manifest and ship agent adapters

**Approach:** Add a canonical source→destination manifest with scope and merge policy.
Refactor export expansion to consume it, include `.codex` and `.agents`, and make doctor
and self-test validate the same inventory.

**Test:** A fresh export contains both agent adapters; removing a manifest-backed file or
adding an unclassified adapter fixture fails validation.

**DoD:** Payload membership is declared once and every enabled agent surface ships.
**Commit:** `Drive scaffold exports from one payload manifest`

## Step 2 — Make regression tests hermetic and parallel-safe

**Approach:** Stop editing the source checkout. Build an isolated scaffold fixture for
root-template and working-document leakage tests; ensure temporary state is unique.

**Test:** Run two self-tests concurrently and assert both pass with a clean source tree.

**DoD:** Verification never mutates repository files and is safe across concurrent agents.
**Commit:** `Make scaffold regression tests hermetic`

## Step 3 — Preserve merge candidates and report version state truthfully

**Approach:** Never overwrite an existing merge candidate. Name candidates by source
version when needed; record candidate version separately; promote installed version only
when the active payload was fully applied and verified.

**Test:** Repeated exports preserve the first candidate, create no ambiguous state, and do
not advance installed version while conflicts remain.

**DoD:** No merge work is destroyed and version files describe active versus pending state.
**Commit:** `Preserve export conflicts and installed-version truth`

## Step 4 — Separate source-only commands and strengthen diagnostics

**Approach:** Mark `init.sh` source-only or make it self-contained; validate adapter
configuration structurally; detect unresolved candidates, mode-specific wrapper
requirements, monorepo roots, and inert versus active CI.

**Test:** Exported commands are runnable; doctor fails representative broken fixtures and
passes valid default and opt-out fixtures.

**DoD:** Every shipped command works and doctor detects semantic adoption gaps.
**Commit:** `Strengthen distribution boundaries and adoption diagnostics`

## Step 5 — Make issue creation repeatable and recoverable

**Approach:** Give specs and steps stable hashes; make dry-run offline; locate existing
stamped issues before mutation; reconcile or resume instead of duplicating; remove unsafe
empty-array expansions; add `--diff` and optional status link-back.

**Test:** A fake `gh` exercises first apply, repeated apply, changed plan, partial failure,
missing labels, and malformed responses under Bash 3.2.

**DoD:** Applying the same spec twice is a no-op and partial application can resume safely.
**Commit:** `Make plan issue creation idempotent and resumable`

## Step 6 — Clarify delivery lanes and derive lifecycle qualification

**Approach:** Define Fast Fix, Planned Change, Decision, and Emergency lanes. Make one issue
own one branch and PR. Extend docs validation with approval, PR/CI evidence, review verdict,
and done-eligibility reporting without automatic mutation by default.

**Test:** Fixtures cover qualified completion, closed issues without evidence, and stale
checked trackers.

**DoD:** The workflow has unambiguous delivery units and can prove when a document may close.
**Commit:** `Define delivery lanes and derive lifecycle readiness`

## Step 7 — Add stack profiles and finish documentation

**Approach:** Extract the Node behavior behind a profile interface, retain a generic profile,
and add conservative Python, Go, and Rust profiles. Detection proposes rather than silently
overrides. Update templates, README, ADOPTION, METHODOLOGY, ROADMAP, and the docs index.

**Test:** Render every profile into a fixture and validate its Make interface without
requiring the target runtime when only rendering.

**DoD:** Stack support is extensible and all public documentation matches implemented behavior.
**Commit:** `Add modular stack profiles and document the hardened workflow`

## Status / Implementation status

- **Approval:** user approved the implementation on 2026-07-24.
- **Tracking issue:** [#16](https://github.com/wabkebab/agentic-flow/issues/16) —
  F-1 #9 · F-2 #10 · F-3 #11 · F-4 #12 · F-5 #13 · F-6 #14 · F-7 #15.
- **Verification evidence:** pending final full-suite and review evidence.
- **Review verdict:** pending.
- F-1 through F-6 implemented and verified; remaining steps proceed in tracker order.
