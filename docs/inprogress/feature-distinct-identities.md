<!-- TRIAGE (first pass · 2026-11-15) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict
> Phase 1 decision 1's follow-up (R-18): switch this repo to `distinct-account`, so each role posts as its own GitHub App and `single-operator-review` is retired. Prerequisite for Phase 2. The three Apps exist and mint tokens; draft for approval. Next: human review, then `plan-to-issues --doc`.

# Feature — Distinct role identities

## Tracker
- [ ] d-1 — switch the policy to distinct-account and retire single-operator review — open

---

# Part A — Analysis

## Goal

Every step verdict, handoff and close in this repo is posted by one account, `wabkebab`, so a "reviewer approved" marker proves a role claim, not a separate reviewer (accepted risk F-3, `single-operator-review`). Phase 1 shipped GitHub App identities and deferred switching this repo to them, so that its own evidence stayed valid. Phase 2's controller needs the switch for two reasons:

- Its andon @-mention notifies nobody while every comment is the owner's own.
- Its entry gate refuses unattended runs under `single-operator`.

This pass makes the switch, runs its own lifecycle entirely under the three identities, and retires the accepted risk.

## Current state

| What | State on 2026-11-15 | Where |
|---|---|---|
| Apps | `flow-implementer[bot]` (executor, App 5767660), `agentic-flow-reviewer[bot]` (reviewer, App 5767669), `flow-approver[bot]` (approver, App 5767653). Each is installed only on this repo with Issues/PRs write and Contents/Metadata read. | GitHub settings; operator identity TSV |
| Tokens | `agentic-flow token <role> --check` and `scripts/doctor.sh --check` pass for all three. | operator's machine |
| Policy | `identity-mode=single-operator`, `accepted-risk=…#single-operator-review`, with the owner and the App login listed in each of the three roles. | `.agentic-flow-review-policy` (commit `8b1b249` on `main`) |
| `handoff` | With an identity configured for `--as <role>`, it already posts with that App's token and checks the author. So every transition in this pass is App-authored, under either policy. | `scripts/lib/handoff.sh:11-21` |
| Issue creation | `plan-to-issues.sh` creates issues with the ambient `gh` login (the owner). `packet` admits only issues created by an approver login. | `scripts/plan-to-issues.sh`, `scripts/lib/packet.sh` |
| Prose | `CLAUDE.md:38-39` cites the accepted risk. `METHODOLOGY.md:142-143` and `ADOPTION.md:170` say "this pass retains single-operator mode". | as listed |
| Login form | Phase 1 normalized `slug` and `slug[bot]` in one place and tested it with fakes. No real App comment has been replayed in this repo yet. | Phase 1 open question 1 |
| Repo | Private, on a free plan, so branch protection returns 403. | `gh api …/branches/main/protection` |

## Proposed approach

One step. The policy edit is data, and the code that enforces `distinct-account` (no reviewer overlap, no accepted-risk line, App logins) shipped in `0.14.0` and `0.15.0`. The step also updates the prose that describes this repo as single-operator and retires F-3.

The proof is this pass's own lifecycle. The plan is that every transition is posted by the role's App and accepted by both read paths: `handoff` and `packet` read through `gh issue view --json`, and lifecycle reads through GraphQL. Close-out must then reach READY under `distinct-account`, and the tracker must close as `flow-approver[bot]`.

### Option A — keep the owner as a second approver (recommended)
The policy keeps `approver=wabkebab` next to `approver=flow-approver[bot]`. `plan-to-issues` keeps creating issues with the owner's login, and `packet` admission keeps working. `distinct-account` forbids only reviewer overlap, so this is valid. The cost: the owner's login can post approver-role transitions (`resume`, `close`). That is true today, and the owner holds the merge anyway.

### Option B — make `plan-to-issues` create issues as the approver App
Removes the owner from every role. It changes `plan-to-issues.sh` and its tests, and it pulls a code change into what is otherwise a configuration pass. Better done with Phase 2's controller, which already reworks who posts what.

**Recommendation:** Option A.

### Decisions this brief makes (veto at approval)

1. **No bootstrap is needed.** Both policies accept every transition this pass posts: the single-operator policy on `main` lists the App logins, and the `distinct-account` policy on the branch lists them too. The executor submits the flip commit with the executor App, so the evidence before and after the flip is App-authored.
2. **The required-review experiment is deferred.** Analysis decision 4 asks whether an App's approving review satisfies a required review. That needs branch protection, which this private repo on a free plan cannot have. It moves to the publish step (R-0f) or Phase 3's R-13, whichever comes first.
3. **F-3 is retired, not deleted.** Its anchor stays, because done docs and older policies cite it. Its status becomes "Retired" with the date and this tracker.

## Interface (before the implementation)

```
.agentic-flow-review-policy after the step
  version=1
  workflow=.github/workflows/ci.yml
  identity-mode=distinct-account
  reviewer=agentic-flow-reviewer[bot]
  executor=flow-implementer[bot]
  approver=flow-approver[bot]
  approver=wabkebab                       Option A: issue creation by the owner
  (no accepted-risk= line; distinct-account rejects one)

who posts what in this pass
  plan-to-issues --doc --apply   wabkebab (ambient)              issue bodies, not transitions
  submit                         flow-implementer[bot]           via handoff --as executor
  approve | bounce | notify      agentic-flow-reviewer[bot]      via handoff --as reviewer
  resume | close                 flow-approver[bot]              via handoff --as approver
  Approval: by=                  wabkebab                        the human's plan approval
  push, PR, merge                wabkebab                        unchanged

docs/accepted_risks.md#single-operator-review
  **Status:** Retired 2026-11-<day> — the repo runs distinct-account (tracker #<N>)
  the rest of the entry is kept as history
```

## Threat model (one paragraph)

This pass narrows trust. After it, the owner's login can no longer post a transition that counts as a reviewer verdict or an executor submit. A forged or mistaken "approved" from the owner's account, or from an agent holding the owner's ambient `gh` login, is skipped by replay and counted. What stays: the three App keys sit in one operator's keychain, so a process running as that user can reach every role. Separate identities make provenance legible and stop honest mistakes, but they do not stop a hostile local agent (Phase 1's threat model, unchanged). The owner keeps approver rights under Option A. A wrong policy edit could lock every role out. That is caught before merge, because this pass's own close-out runs under the new policy.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---|---|---|---|
| App token mint inside `handoff` | exit 5, no post (Phase 1) | exit 5 | never falls back to the owner's login |
| replay of a real App comment | n/a | login form not normalized → the transition is skipped and the step does not move. Stop and report; do not hand-post. | n/a |
| lifecycle under `distinct-account` | UNVERIFIED (as today) | UNVERIFIED | a transition by the owner in a reviewer or executor role → skipped, NOT READY naming it |

Bounds: unchanged from Phase 1.

## Out of scope / What NOT to build in this pass

- Option B (`plan-to-issues` as the approver App).
- Publishing the repo, branch protection, and the required-review experiment (decision 2).
- Any change to `handoff`, `packet`, lifecycle or the hooks. If the login form breaks replay, that is a finding for a fix pass, not a change in this step.
- Renaming keychain items. The operator's key-ref names are local and cosmetic.

## Open questions

- None blocking. The real-App replay (acceptance scenario 2) is the one live unknown, and it is checked on this pass's own first submit.

---

# Part B — Implementation Brief

> **Audience:** the implementing agent (Codex). One step, one commit. Stage files by name. Why-first commit body.

```agentic-flow-plan
id: distinct-identities
profile: strict
tracking: Plan: Distinct role identities
branch: identity-flip
steps: d-1
```

## Branch
Base: `main`. One branch and one PR: `identity-flip`. The step is one commit with `Fixes #N`. Review fixes land as new commits; never amend after a handoff.

## Invariants
- Every workflow transition goes through `agentic-flow handoff --as <role>` on a machine where that role's identity is configured. Never post a transition or verdict by hand, and never with `gh` as the owner.
- Before every handoff, `agentic-flow handoff <issue> reconcile --json` shows `skipped` = 0 on the tracker and on the step issue. Anything else stops the pass.
- No contract word ceiling is raised. Root and template copies stay in step.

## Definition of done (whole brief)
- d-1's DoD is met. `make check`, `make test`, `make build` and `scripts/doctor.sh --check` are green.
- All five acceptance scenarios hold, and their evidence is quoted in the close-out.
- `lifecycle-status.sh --phase close-out --check --verify-evidence` is READY under `distinct-account`, and `close-out finish` closes the tracker as `flow-approver[bot]`.

## Acceptance scenarios (written at Spec; the executor does not edit these)
1. **App-authored journal.** Every accepted transition on the tracker and the step issue is authored by the App for its role, as listed in the Interface. `reconcile --json` shows `skipped` = 0 at close-out.
2. **Both read paths accept a real App comment.** After the first submit, `packet <step> --station reviewer` shows the submit, and `lifecycle-status --verify-evidence` reads the approve from GraphQL without flagging the author.
3. **The owner no longer counts as reviewer.** A hermetic test runs this repo's new policy file with a reviewer-role transition by `wabkebab`. The transition is skipped and counted. The test may already exist; if so, point it at the real policy file and do not add a duplicate.
4. **A mention reaches the owner.** The reviewer's approve body ends with `@wabkebab review identities verified`. `gh api /notifications` as the owner lists a mention on the step issue, which proves the R-9 channel Phase 2 depends on. Quote the notification's reason and URL.
5. **Doctor and tokens.** `scripts/doctor.sh --check` passes under `distinct-account`, with ok rows for all three identities.

## Verification commands
```bash
make check
make test-one F=contracts
make test-one F=lifecycle
make test
make build
scripts/doctor.sh --check
```

---

## D-1 — Switch this repo to distinct-account and retire single-operator review
**Why one step:** the enforcing code shipped already; this is data plus the prose that describes it.

**Approach:**
1. Rewrite `.agentic-flow-review-policy` to match the Interface.
2. Retire `docs/accepted_risks.md#single-operator-review` (decision 3).
3. `CLAUDE.md:38-39`: replace the accepted-risk sentence with one saying each role posts as its own App and the owner approves, pushes and merges. Keep it word-neutral. Check whether `templates/harness/CLAUDE.md` carries the same sentence, and leave the template generic if it does not.
4. `METHODOLOGY.md:142-143` and `ADOPTION.md:170`: drop "this pass retains single-operator mode". Say that switching to `distinct-account` is an adoption decision that removes the `accepted-risk=` line. The reviewer contracts' "not independence in single-operator mode" sentences stay, because they are still true for adopters in that mode.
5. Scenario 3's test, only if one does not already cover it.

**DoD:** scenarios 3 and 5 pass at the step commit. Scenarios 1, 2 and 4 are checked live during this pass's own handoffs.
**Verify:** `make test-one F=contracts` and `make test-one F=lifecycle`
**Red-first:** none
**Risks:** a policy typo that locks out a role (doctor and every handoff would fail: stop, do not hand-post); the GraphQL login form for a real App (scenario 2); `check-harness-sync.sh` drift between the root and template contracts; a done doc's Status that cites the retired anchor (the anchor stays).
**Commit:** `Run this repo under distinct App identities and retire single-operator review`

---

# Close-out

Claude, on `identity-flip`, after the step is approved and the tracker is notified:

1. Close-out commits: a `CHANGELOG.md` entry under an `Unreleased` heading saying this repo now runs `distinct-account`, with no adopter migration. Do not bump `VERSION`; no shipped payload changed except prose.
2. `agentic-flow close-out prep`, then the human pushes. CI runs, and `close-out finish` closes the tracker as `flow-approver[bot]`.
3. Update `product-harness-factory-optimization.md`'s next-docs list. Note in `feature-line-controller.md`'s Prerequisite that it is met.

---

## Status / Implementation status
- **Evidence schema:** v2
- **Tracking issue:** pending
- **Approval:** pending
- **Implementation head:** source=pr-head
- **Implementation PR:** pending
- **Verification evidence:** source=final-approval-run
- **Review verdict:** source=close-out-attestation
- **Memory:** pending
- Close-out: finalize Status/Tracker, set TRIAGE to Done, move this document and update
  the index in the last repository commit. After human push, obtain CI and a structured
  reviewer approval on the `Tracking issue` for that exact PR head and run attempt.
  Verify this moved file with `--phase close-out`, close the tracker without another
  repository edit, then recheck with `--phase pre-merge` before human merge.
