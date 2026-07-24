<!-- TRIAGE (first pass · 2026-07-24) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> Move the authority for "green" and "approved" from something an agent asserts to something
> the repository enforces: split doctor's portable checks from its workstation checks,
> activate CI on this repo, stamp approval as an event, and derive verification evidence from
> a CI run conclusion. Completes ROADMAP Tier 2 (2.6, 2.4-remainder, 2.1 rung 2, 2.7).

# Feature — CI as the authority for "green"

## Tracker
- [ ] F-1 Split `doctor.sh` into repo-invariant and environment scopes — open
- [ ] F-2 Activate CI on this repository — open
- [ ] F-3 Stamp approval as an event (`--approved-by`) — open
- [ ] F-4 Derive verification evidence from the CI run conclusion — open
- [ ] F-5 Render the CI runtime setup block from the stack profile — open

---

# Part A — Analysis

## Goal

Every quality signal this system produces is currently **self-reported**. `make check` is run
by an agent and reported by that agent. "Approved" is a line a human types. "Verification
evidence" is a URL someone chose to paste. The hooks that enforce the commit contract bind
Claude and Codex and nothing else — a human committing from an IDE, a different agent, or a
plain `git` invocation passes through untouched.

The goal is not more checking. It is to move the *authority* for those signals to a place
that does not depend on the good faith or correct operation of an agent: a required status
check on a pull request.

## Current state

**What already works** (do not re-implement):

- `Makefile` targets are real and green: `check`, `test`, `test-one`, `build`, `run`.
- `templates/ci/ci.yml` is a well-formed workflow with SHA-pinned actions, a path-filter
  job, a secrets scan, and a `ci-gate` fan-in job designed to be the single required check
  (`templates/ci/ci.yml:134-150`). `scripts/check-action-pins.sh` keeps the pins honest.
- `scripts/doctor.sh` verifies files, hook wiring (structurally, via `jq`), manifest
  destinations, unresolved merge candidates, Make targets, and docs-index freshness.
- `scripts/lifecycle-status.sh` derives ACTIVE / READY / BLOCKED from a doc's Status block.
- `scripts/plan-to-issues.sh` reconciles trackers idempotently and can write the tracker link
  back into a doc with `--doc`.

**The gaps**, precisely:

1. **This repository has no `.github/workflows/`.** The scaffold ships CI templates it has
   never run on itself. `doctor.sh:248-254` reports "CI template is inert" — a warning that
   has been true since the templates landed.

2. **`make check` cannot pass on a stock CI runner.** This is the blocking discovery, and it
   is not obvious from reading the Makefile. The chain:

   ```
   make check → scripts/self-test.sh → (self-test.sh:166) scripts/doctor.sh --check
              → doctor.sh:92-107 require_tool gitleaks / git-claude / git-codex
   ```

   Verified by simulating a runner PATH: `doctor.sh --check` reports **3 missing tools**
   (`gitleaks`, `git-claude`, `git-codex`) and `make check` exits non-zero. `git-claude` and
   `git-codex` are the developer's local commit-identity wrappers in `~/.local/bin`; a CI
   runner has no reason to possess them and never commits. `gitleaks` is a real tool but not
   preinstalled on `ubuntu-24.04`.

3. **Approval leaves no machine-readable trace.** `plan-to-issues.sh` has no `--approved-by`,
   so `**Approval:**` is hand-typed — while `lifecycle-status.sh` now *enforces* its presence.
   A hand-typed field that a checker depends on is exactly the bookkeeping this project exists
   to eliminate, and it has already rotted once (issue #19: a pre-schema doc recorded approval
   under `**Approved:**` and the checker called it missing).

4. **Evidence is a pasted URL, not a queried fact.** `lifecycle-status.sh:41-42` accepts any
   `https?://` in the evidence field. Nothing checks that the URL points at a green run.

5. **The CI template's runtime block is hardcoded Node** (`templates/ci/ci.yml:93-101`) while
   `make check`/`make test` are stack-agnostic. This repo — the first real adopter — is a
   bash/make project that needs *no* runtime setup, which makes the mismatch concrete.

## Proposed approach

The load-bearing decision is **how doctor becomes runnable in CI**, because everything else
is blocked behind it.

`doctor.sh` currently answers two different questions with one exit code:

- *Is this workstation equipped to do the work?* — `gitleaks`, `git-claude`, `git-codex`, `gh`.
- *Does this repository satisfy the standard?* — files present, hooks structurally wired,
  manifest destinations real, no unresolved merge candidates, Make targets real, docs index
  fresh.

Only the second is portable, and only the second is meaningful on a runner.

### Option A — an explicit `--scope` flag (recommended)

`doctor.sh --check --scope repo` runs only the portable repository invariants. Default stays
`all` so existing invocations and the adoption story are unchanged. `self-test.sh:166` switches
to `--scope repo`, which makes `make check` CI-safe as a side effect.

Trade-off: one more flag to know about. In exchange, the thing CI runs is a command a
developer can run locally and get a byte-identical answer — which preserves "CI green means
the same as local green," the principle `templates/ci/ci.yml:78-79` is built on.

### Option B — auto-detect CI (`[ -n "$CI" ]`) and skip environment checks

No new flag; doctor "just works" on a runner.

Rejected. It makes behavior depend on ambient environment, so the command CI runs is *not* the
command a developer can run — the failure is invisible and unreproducible locally. It also
silently weakens doctor for anyone who happens to export `CI=1`.

### Option C — a separate `scripts/check-repo-invariants.sh`

Rejected as a first move: it duplicates doctor's check bodies or forces an extraction refactor
before the CI work can start. `--scope` gets the same separation with far less churn, and the
extraction stays available later if a second consumer appears.

**Recommendation: Option A.** It is the smallest change that unblocks F-2, it keeps one
adoption checklist rather than two, and the scope names document the distinction that was
previously implicit.

## Interface (before the implementation)

```
# F-1 — doctor scope
scripts/doctor.sh [--check] [--scope repo|env|all]     # default: all
  repo → files, hook wiring, manifest destinations, merge candidates,
         Make targets, docs index, CI posture
  env  → required tools (bash make git jq gh shellcheck gitleaks),
         adapter commit wrappers (git-claude / git-codex per execution mode)
  Exit: 0 when the selected scope is clean; 1 otherwise. Warnings never fail.

# F-3 — approval as an event
scripts/plan-to-issues.sh --apply --approved-by <name> [--doc <path>] <spec.json>
  → tracker body gains:  <!-- agentic-plan:<id> approved-by:<name> at:<ISO-8601> -->
  → with --doc, Status block gains:
     - **Approval:** <name> approved on <YYYY-MM-DD> via plan-to-issues --apply.

# F-4 — evidence derived, not pasted
scripts/lifecycle-status.sh [--check] [--verify-evidence]
  default        → current behavior: evidence field must contain a URL (offline, deterministic)
  --verify-evidence → if the URL is a GitHub Actions run, resolve its conclusion:
                      gh run view <id> --repo <owner/repo> --json conclusion --jq .conclusion
  States: READY (verified success) · UNVERIFIED (URL present, not resolvable) · BLOCKED

# F-5 — CI setup from the stack profile
profiles/<name>.tsv gains rows:   ci-setup<TAB><YAML line>
scripts/render-stack-profile.sh <profile> <Makefile> [--ci <workflow.yml>]
```

## Threat model (one paragraph)

This change introduces no new trust boundary for user data, but it does touch CI permissions,
which deserve care. The workflow keeps `permissions: contents: read, pull-requests: read` —
no write scope, no secrets, nothing a forked PR could exfiltrate. `trufflehog` scans the PR
diff and must stay `--only-verified` so the noise floor doesn't train reviewers to ignore it.
The `--verify-evidence` path in F-4 runs on a *developer's* machine using their existing `gh`
auth; it must never be added to the workflow, because a job that queries its own run's
conclusion is circular and would need a token upgrade to do it. The realistic adversary here
is not an attacker but a false sense of security: a required check that silently stops running
(a skipped job that never reports) is worse than no check, which is exactly why `ci-gate`
exists and why it must remain the *only* required check.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---|---|---|---|
| `gh run view` (F-4, local only, opt-in) | report `UNVERIFIED`, exit as if unverified — never block on network | report `UNVERIFIED` with the parse error on stderr | n/a — single call |
| `dorny/paths-filter` (GitHub Pulls API) | job fails → `ci-gate` fails (correct: unknown scope must not pass) | job fails | n/a |
| `trufflehog` scan | job fails → `ci-gate` fails | job fails | findings are all-or-nothing per run |
| `gh label create` (existing, F-3 path) | already best-effort `|| true`; unchanged | unchanged | unchanged |

Bounds: `--verify-evidence` resolves **at most one** run per document and makes no paginated
queries; `gh` calls carry no retry loop (one attempt, then `UNVERIFIED`); `ci-gate`'s result
loop is bounded by its `needs` list; CI concurrency cancels superseded runs per PR.

## Out of scope / What NOT to build in this pass

- **Branch protection as code.** Making `CI gate` required is a repository setting the human
  applies once; scripting it needs admin-scoped tokens for negligible benefit. F-2's DoD names
  it as a human action with the exact steps.
- **`lifecycle-status.sh --check` as a required CI gate.** It must not be. A plan's doc has all
  Tracker boxes ticked *before* the evidence exists — the PR being checked is what produces the
  evidence — so gating on it would deadlock the last PR of every plan. Run it in CI as a
  **reporting** step only (`|| true`), and say so in a comment so nobody "fixes" it later.
- **Local git `pre-commit` / `pre-push` hooks.** They don't distribute via git and die to
  `--no-verify`. Building them before CI exists invites mistaking them for a gate. Revisit only
  after F-2 lands, if at all.
- **Deploy workflow activation.** `templates/ci/deploy.yml` stays inert; this repo deploys nothing.
- **Extracting doctor's checks into separate scripts** (Option C) — deferred, not rejected.
- **Retro-verifying existing docs' evidence.** F-4 applies going forward; the two current docs
  cite a review comment and merged SHAs, which is honest for work that predates CI.

## Open questions

- **[BLOCKING] Base branch.** This work must base on `main` *after* #16 merges — it depends on
  `config/payload.tsv`, `lifecycle-status.sh`, `render-stack-profile.sh`, and the `.codex`/
  `.agents` adapters, none of which are on `main` yet. Confirm the merge before F-1 starts.
- Should `make check` keep calling doctor at all once the scope split exists, or should the
  environment scope move to `make run` (which already calls doctor)? Leaning yes-keep — the
  repo scope is cheap and catches unwired hooks early — but the executor should raise it if the
  runtime becomes noticeable.
- Does `ubuntu-24.04` ship a `jq` and `shellcheck` new enough for the suite? The template
  already notes shellcheck will be *older* than local (`templates/ci/ci.yml:106-109`); confirm
  on the first real run rather than guessing.

---

# Part B — Implementation Brief

> **Audience:** an implementing agent (**Codex** by default). Each step is independently
> shippable and ordered so the **riskiest / most foundational work lands first.** Do the
> steps in order; **one logical commit per step; do not bundle.** Stage files by name
> (never `git add -A`). Use verbose, *why*-first commit bodies. This brief carries the
> **approach and insights — not the code.**

## Branch

Base: `main` **after #16 merges** (see the blocking open question). Per METHODOLOGY §2, one
issue owns one branch and one PR: `feature-ci-as-authority-fN`. Do not stack all five steps on
one long-lived branch — that is the shape §2 now forbids, and #16 is the cautionary example.

## Definition of done (whole brief)

Every step's per-step DoD met; `make check` and `make test` green; a pull request against this
repository is **red until the harness gates pass**, `CI gate` is the only required check, and
`doctor.sh` reports CI **active** rather than inert.

## Verification commands

```bash
make check                          # fast gate (also enforced by the Stop hook)
make test-one F=scripts/self-test.sh   # targeted
make test                           # end of brief: full suite + shellcheck
scripts/doctor.sh --check           # adoption checklist (all scopes)
scripts/doctor.sh --check --scope repo   # what CI runs
```

---

## Step 1 — Split `doctor.sh` into repo-invariant and environment scopes

**Why first:** hard blocker for everything else. `make check` transitively requires
`git-claude`, `git-codex`, and `gitleaks` via `self-test.sh:166`, so **no CI job can pass
until this lands.** Verified, not assumed: a simulated runner PATH produces 3 missing tools
and a non-zero `make check`.

**Approach (do NOT write code yet):**
1. Add `--scope repo|env|all` (default `all`) to the existing flag parsing at
   `scripts/doctor.sh:10-16`. Keep `--check` orthogonal — it controls exit-code strictness,
   not which checks run.
2. Classify every existing check. **Env:** the `require_tool` block and the execution-mode
   wrapper checks (`doctor.sh:92-107`). **Repo:** everything else — required files, manifest
   destinations, merge candidates, hook wiring, Make targets, CI posture, docs index.
   Resolve ambiguity by asking "would this be true on a fresh clone with no tools installed?"
3. `gh` is a judgement call: classify it **env**. Nothing in the repo scope shells out to it.
4. Change `self-test.sh:166` to `--scope repo`. Leave lines 70 and 75 alone — those assert
   doctor *rejects* broken fixtures and must keep exercising the full path.
5. Print the active scope in doctor's header so a CI log says which contract was checked.

**Test:** extend `self-test.sh`'s doctor section. **Failure path first:** a fixture with a
deliberately unwired hook must still fail under `--scope repo` (proving the split didn't
silently drop a check). Then: `--scope repo` succeeds with `PATH` stripped of `gitleaks`,
`git-claude`, and `git-codex`; `--scope env` fails on that same PATH; `--scope all` equals
today's behavior. Build the stripped PATH inside the test — do not mutate the real one.

**DoD:** `scripts/doctor.sh --check --scope repo` exits 0 on a PATH containing only
`bash make git jq`; `--scope all` is unchanged; `make check` passes on that same stripped PATH.
**Commit:** `Separate doctor's portable repository checks from its workstation checks`

---

## Step 2 — Activate CI on this repository

**Why second:** the whole point of the plan, and unblocked the moment F-1 lands. Doing it here
first is the cheapest possible dogfood — the Make targets are already real and green.

**Approach:**
1. Copy `templates/ci/ci.yml` to `.github/workflows/ci.yml`. Do **not** edit the template in
   this step (F-5 does that) — the two files legitimately diverge for now.
2. **Delete the Node runtime setup block** (`templates/ci/ci.yml:89-102`) from the copy. This
   repo is bash/make; it has no runtime to set up, no lockfile, and no `npm audit`. Leave a
   one-line comment saying so, because an empty section invites someone to "restore" it.
3. Fill the path filters for this repo — `app`: `scripts/**`, `Makefile`, `config/**`,
   `profiles/**`, `templates/**`, `.claude/**`, `.codex/**`, `.agents/**`; `docs`: `docs/**`,
   `*.md`. Keep `.github/workflows/ci.yml` in **both** filters as the template does, so
   editing CI re-runs everything it gates.
4. Add `scripts/doctor.sh --check --scope repo` to the `app` job, after `make check`.
5. Add `scripts/lifecycle-status.sh` as a **non-fatal reporting** step (`|| true`) with a
   comment explaining why it must never gate — see Out of scope. Getting this wrong deadlocks
   the final PR of every future plan.
6. Re-verify the pinned action SHAs against current releases before the first run
   (`scripts/check-action-pins.sh --online`), then `--stamp`. An inherited pin is not a chosen one.
7. Add `.github/` to `config/payload.tsv` as **`source-only`** — this workflow is this repo's
   own instance, not payload. Adopters get the inert template. (Note issue #17: source-only
   directories don't currently exclude correctly. If #17 has not landed, use the exact file
   path `.github/workflows/ci.yml`, and add a comment pointing at #17.)

**Test:** `self-test.sh` asserts `.github/workflows/ci.yml` exists, is valid YAML, contains no
`<ANGLE-BRACKET>` placeholders, and that `ci-gate`'s `needs` list and its result loop name the
same jobs — the drift `templates/ci/ci.yml:132-133` warns about. Assert the workflow does not
leak into an export.

**DoD:** a PR against this repo runs CI; the `app` job executes `make check`, `make test`,
`make build`, and repo-scope doctor; `doctor.sh` reports CI **active** instead of inert.
**Human action, then record it here:** in branch protection, set **`CI gate`** as the *only*
required status check on `main`.
**Commit:** `Run this scaffold's own CI gate instead of only shipping the template`

---

## Step 3 — Stamp approval as an event

**Why third:** independent of CI, and it removes a hand-typed field that `lifecycle-status.sh`
already treats as load-bearing. Small, self-contained, and it stops the #19 class of rot at
the source rather than teaching the checker more spellings.

**Approach:**
1. Add `--approved-by <name>` to `plan-to-issues.sh`'s flag loop (`scripts/plan-to-issues.sh:22-39`),
   following the existing `--doc` pattern for "requires a value".
2. On `--apply`, extend the tracker's identity stamp with `approved-by` and an ISO-8601 date.
   Reuse the existing HTML-comment stamp mechanism — do not invent a second marker format, and
   do not put approval in the title.
3. When `--doc` is given, write the `- **Approval:**` line into the doc's Status block using
   the schema in `docs/templates/feature-analysis.md:138`. Match the canonical field name
   exactly; that mismatch is precisely issue #19.
4. Reconciliation must stay idempotent: re-running `--apply` preserves the original approval
   stamp rather than re-dating it. Approval is an event, not a timestamp of the last run.
5. `--approved-by` stays optional. Requiring it would break every existing spec.

**Test:** extend the fake-`gh` suite (`self-test.sh:469+`). **Failure path first:** `--approved-by`
with no value exits 2. Then: the stamp lands in the tracker body; a second `--apply` does not
change the recorded date; with `--doc`, the Status line is written in the canonical field name
and `lifecycle-status.sh` subsequently recognises it.

**DoD:** approval is recorded by the command that creates the issues, in a form
`lifecycle-status.sh` accepts, without anyone typing it.
**Commit:** `Record approval where it happens instead of asking someone to type it`

---

## Step 4 — Derive verification evidence from the CI run conclusion

**Why fourth:** needs F-2 (there must be runs to query). This is ROADMAP 2.1 rung 2 — the
difference between "a URL was pasted" and "the checks were green."

**Approach:**
1. Add `--verify-evidence` to `lifecycle-status.sh`. **Default off.** The default path must
   remain offline and deterministic — that property is why this script is testable at all, and
   why it can run anywhere.
2. When on: parse a GitHub Actions run URL out of the evidence field, resolve it with
   `gh run view <id> --repo <owner/repo> --json conclusion --jq .conclusion`, and require
   `success`.
3. Introduce **`UNVERIFIED`** as distinct from both READY and BLOCKED: a URL is present but
   could not be resolved (no `gh`, no network, not a run URL, non-`success` conclusion). Never
   let an absent network turn into a false BLOCKED — that is the #19 lesson restated.
4. Under `--check`, `UNVERIFIED` is **not** fatal; only BLOCKED is. Failing on an unreachable
   network would make the check untrustworthy in exactly the situations it matters.
5. Fold in the field-name and continuation-line handling from **#19** if that issue has not
   already landed — this step touches the same parsing code, and doing it twice is waste.

**Test:** extend the lifecycle fixtures with a fake `gh` on `PATH` (the pattern already exists
at `self-test.sh:469+`). **Failure path first:** `gh` absent → `UNVERIFIED`, exit 0 under
`--check`; conclusion `failure` → BLOCKED; a non-run URL → `UNVERIFIED`. Then the success case.
No test may touch the network.

**DoD:** with `--verify-evidence`, READY means a CI run was queried and concluded `success`;
without it, behavior is byte-identical to today.
**Commit:** `Resolve verification evidence against the CI run instead of trusting the URL`

---

## Step 5 — Render the CI runtime setup block from the stack profile

**Why last:** lowest risk, and F-2 supplies the proof it is needed — this repo had to delete a
Node block that the profile system could have omitted. Independent of F-3 and F-4.

**Approach:**
1. Add `ci-setup` rows to `profiles/*.tsv`, holding the workflow YAML lines for runtime setup
   plus lockfile install. `generic.tsv` gets **none** (that is the agentic-flow case) — make
   the renderer handle an empty block cleanly rather than emitting a stray comment.
2. Extend `render-stack-profile.sh` with `--ci <workflow.yml>` to substitute between the
   existing `# ── Replace this block…` / `# ── End runtime setup ──` markers. Keep the job
   graph, pins, filters, and `ci-gate` fixed; only the setup block varies.
3. Extend the profile validator (`render-stack-profile.sh:17-23`) to accept `ci-setup` — it
   currently rejects unknown keys, so the profiles will fail validation until this lands.
4. `init.sh` renders the CI template alongside the Makefile, honouring the existing
   pre-existing-file guard (`init.sh:258-265`): never overwrite a workflow the project has.
5. Pins stay in the template, not the profiles. `check-action-pins.sh` must keep working, and
   scattering SHAs across five profile files would guarantee drift.

**Test:** render every profile and assert the output has no `<ANGLE-BRACKET>` placeholders and
is valid YAML; assert `generic` produces a workflow with no runtime block; assert
`check-action-pins.sh` passes on each rendered result. **Failure path first:** a profile with a
malformed `ci-setup` row fails validation loudly rather than emitting a broken workflow.

**DoD:** `init.sh --stack rust` produces a CI template whose setup block is Cargo, with no
angle brackets left to fill, and the pin checker still passes.
**Commit:** `Render the CI runtime block from the stack profile like the Makefile`

---

## Status / Implementation status
- **Tracking issue:** pending — run `plan-to-issues --apply` after approval.
- **Approval:** pending.
- **Verification evidence:** pending until execution.
- **Review verdict:** pending.
- Steps not yet started. Executor closes each via a PR with `Fixes #N`, records the commit
  SHA per step here, and ticks the matching F-N box in the Tracker above.
