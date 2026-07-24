<!-- TRIAGE (first pass · 2026-07-24) -->
> **Type:** Feature · **Status:** 🚧 In progress
> Move the authority for "green" and "approved" from something an agent asserts to something
> the repository enforces: split doctor's portable checks from its workstation checks,
> activate CI on this repo, stamp approval as an event, and derive verification evidence from
> a CI run conclusion. Completes ROADMAP Tier 2 (2.6, 2.4-remainder, 2.1 rung 2, 2.7).

# Feature — CI as the authority for "green"

## Tracker
- [x] F-1 Split `doctor.sh` into repo-invariant and environment scopes — fixed in f14069a (#22)
- [x] F-2 Activate CI on this repository — fixed in cef93b8 (#23)
- [x] F-3 Stamp approval as an event (`--approved-by`) — fixed in b13a5d9 (#24)
- [x] F-4 Derive verification evidence from the CI run conclusion — fixed in 82a5265 (#25)
- [x] F-5 Render the CI runtime setup block from the stack profile — fixed in 7f91faa (#26)

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
  → EXTEND the existing tracker stamp — do NOT introduce a second marker:
      before:  <!-- agentic-flow:plan:<id> tracker spec:<hash> -->
      after:   <!-- agentic-flow:plan:<id> tracker spec:<hash> approved-by:<name> approved-at:<ISO-8601> -->
    The lookup key is the PREFIX "agentic-flow:plan:<id> tracker" (plan-to-issues.sh:114-120,
    a jq `contains` substring match), so appending fields after spec: is safe.
  → with --doc, Status block gains:
     - **Approval:** <name> approved on <YYYY-MM-DD> via plan-to-issues --apply.

# F-4 — evidence derived, not pasted
scripts/lifecycle-status.sh [--check] [--verify-evidence]
  default        → current behavior: evidence field must contain a URL (offline, deterministic)
  --verify-evidence → if the URL is a GitHub Actions run, resolve its conclusion:
                      gh run view <id> --repo <owner/repo> --json conclusion --jq .conclusion
  States, by what we actually learned:
    READY      → resolved, conclusion == success
    BLOCKED    → resolved, conclusion != success  ← a known-red run is a hard block
    UNVERIFIED → could NOT resolve (no gh, no network, not a run URL). Absence of an
                 answer, never a negative answer. Non-fatal under --check.

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

- ~~**[BLOCKING] Base branch.**~~ **Resolved 2026-07-24 — #16 merged** (PR #27). `main` now
  carries `config/payload.tsv`, `lifecycle-status.sh`, `render-stack-profile.sh`, and the
  `.codex`/`.agents` adapters this brief depends on. Base directly on `main`.
- Should `make check` keep calling doctor at all once the scope split exists, or should the
  environment scope move to `make run` (which already calls doctor)? Leaning yes-keep — the
  repo scope is cheap and catches unwired hooks early — but the executor should raise it if the
  runtime becomes noticeable.
- **Resolved — do not leave this to the first run.** Earlier drafts said "confirm on the first
  real run" whether the runner has `jq`/`shellcheck`. That makes CI activation trial-and-error,
  and `make test` hard-fails without `shellcheck` by design (`Makefile:19`). F-2 step 4 now
  asserts and installs the required tools explicitly. What genuinely remains unknown is only
  the shellcheck *version* — the template already notes CI's will be older than local
  (`templates/ci/ci.yml:106-109`), so local green stays the stricter claim. If the older
  release flags something local does not, fix the finding rather than pinning CI backwards.

---

# Part B — Implementation Brief

> **Audience:** an implementing agent (**Codex** by default). Each step is independently
> shippable and ordered so the **riskiest / most foundational work lands first.** Do the
> steps in order; **one logical commit per step; do not bundle.** Stage files by name
> (never `git add -A`). Use verbose, *why*-first commit bodies. This brief carries the
> **approach and insights — not the code.**

## Executor calibration

Before implementing each step, re-read the current call sites and constants named by that step.
Treat line numbers and quoted marker shapes in this brief as **orientation, not authority**. If
the brief conflicts with the live code, **preserve the live contract** unless the step
explicitly says to change it, and record the discrepancy before coding.

This is not boilerplate caution. Review of this brief found four defects of exactly this kind,
every one of them in a passage that *looked* precise:

| What the brief asserted | What the code does | Failure it would have caused |
|---|---|---|
| stamp marker `agentic-plan:<id>` | `agentic-flow:plan:<id> tracker` (`plan-to-issues.sh:74,120`) | duplicate issues — resumption breaks |
| tracker body is appended to | body is **replaced** wholesale (`:180-181`) | approval silently erased on re-run |
| `init.sh` renders CI "alongside the Makefile" | adoption must create **no** workflow (`self-test.sh:109-112`) | activates CI in every adopted project |
| `apt-get install -y` | runners need `sudo` + a refreshed index | red CI on an unrelated PR |

The pattern: **quoted implementation details rot; stated intent does not.** Where this brief
explains *why* a constraint exists, trust it. Where it quotes a name, a line number, or a
command shape, verify it first — the quote was accurate when written and may not be when read.

If a discrepancy is material, note it in the step's commit body rather than fixing it silently.
A brief that was wrong is useful information about the brief.

## Branch

Base: `main` (#16 has merged). Per METHODOLOGY §2, one branch and one PR for the whole brief:
`feature-ci-as-authority`. Each step lands as its own commit on that branch, closing its issue
via `Fixes #N` when the PR merges — steps are the tracking/commit granularity, not the
branch/PR granularity. This is the same shape #16 itself shipped as (nine execution commits,
one branch, one PR — #27).

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
5. Print the active scope in doctor's header **only when a non-default scope was explicitly
   selected** (`--scope repo` / `--scope env`). The default `all` run must print exactly what
   it prints today — otherwise the "byte-identical" DoD below is unsatisfiable, and every
   adopter's expected doctor output changes for no benefit. A CI log still says which contract
   was checked, because CI always passes `--scope repo` explicitly.

**Test:** extend `self-test.sh`'s doctor section. **Failure path first:** a fixture with a
deliberately unwired hook must still fail under `--scope repo` (proving the split didn't
silently drop a check). Then: `--scope repo` succeeds on the stripped PATH defined below;
`--scope env` fails on that same PATH; `--scope all` equals today's behavior. Build the
stripped PATH inside the test — do not mutate the real one.

**Define "stripped PATH" by subtraction, not by enumeration.** It is a normal PATH with
exactly these removed: `gitleaks`, `git-claude`, `git-codex`, `gh`, `shellcheck`. It is *not*
"only `bash make git jq`" — the harness scripts legitimately use ordinary Unix tools
(`sed`, `awk`, `grep`, `find`, `date`, `mktemp`, `wc`, `tr`, `sort`, `cmp`), and
`check-action-pins.sh:66` optionally uses `python3` for date arithmetic. Enumerating an
allow-list would produce a test that fails for reasons having nothing to do with this change.

**Note:** `make check` does **not** need the `shellcheck` binary — `self-test.sh:230-242`
asserts the Makefile *recipe text* runs shellcheck rather than invoking it, deliberately, to
avoid unbounded recursion. Only `make test` needs the tool. Keep it out of the stripped PATH
anyway: that asymmetry is worth having a test pin down.

**DoD:** `scripts/doctor.sh --check --scope repo` and `make check` both exit 0 on the stripped
PATH above; `scripts/doctor.sh --check --scope env` exits non-zero on it; `--scope all` is
byte-identical to today's behavior on a full PATH.
**Commit:** `Separate doctor's portable repository checks from its workstation checks`

---

## Step 2 — Activate CI on this repository

**Why second:** the whole point of the plan, and unblocked the moment F-1 lands. Doing it here
first is the cheapest possible dogfood — the Make targets are already real and green.

**Approach:**
1. Copy `templates/ci/ci.yml` to `.github/workflows/ci.yml`. Do **not** edit the template's
   *content* in this step (F-5 does that) — the two files legitimately diverge for now. One
   deliberate exception, see point 7: `--stamp` will rewrite the template's date line, and
   that is allowed.
2. **Delete the Node runtime setup block** (`templates/ci/ci.yml:89-102`) from the copy. This
   repo is bash/make; it has no runtime to set up, no lockfile, and no `npm audit`. Leave a
   one-line comment saying so, because an empty section invites someone to "restore" it.
3. Fill the path filters for this repo — `app`: `scripts/**`, `Makefile`, `config/**`,
   `profiles/**`, `templates/**`, `.claude/**`, `.codex/**`, `.agents/**`; `docs`: `docs/**`,
   `*.md`. Keep `.github/workflows/ci.yml` in **both** filters as the template does, so
   editing CI re-runs everything it gates.
4. **Preflight the runner's tools explicitly — do not discover them by failing.** Add a step
   *before* `make check` that asserts `bash make git jq shellcheck` are present, prints their
   versions, and installs only what is actually missing. **Name the command shape exactly** —
   GitHub-hosted runners execute as a non-root user with passwordless `sudo`, and the package
   index is stale on a fresh image, so bare `apt-get install` either fails on permissions or
   installs from a stale index:

   ```bash
   missing=""
   for t in bash make git jq shellcheck; do
     command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
   done
   if [ -n "$missing" ]; then
     sudo apt-get update -qq
     # shellcheck disable=SC2086  # word splitting is intended here
     sudo apt-get install -y $missing
   fi
   for t in bash make git jq shellcheck; do
     command -v "$t" >/dev/null || { echo "preflight: $t still missing" >&2; exit 1; }
   done
   ```

   Install *conditionally*, not unconditionally: on an image that already has everything, an
   unconditional `apt-get update` adds ~15s to every run for nothing. Reasons this step is not
   optional:
   - `make test` **hard-fails** without `shellcheck` by design (`Makefile:19`) — the recipe
     refuses to skip a lint whose tool is absent, because that reports green for the wrong
     reason. On a runner that lacks it, CI is red for a reason unrelated to the change.
   - `self-test.sh` needs `jq` (the fake-`gh` fixture builds JSON with it).
   - `gitleaks` is **not** required: the secrets scan runs as its own `trufflehog` job, and
     after F-1 the repo scope no longer asks for it. Do not install it.
   - `git-claude` / `git-codex` must **never** be installed on a runner. They are commit
     identity wrappers; a runner does not commit. F-1 is what makes their absence fine.
   `ubuntu-24.04` is believed to preinstall `jq` and `shellcheck`
   (`templates/ci/ci.yml:106-109` asserts the latter), but *assert it in the workflow* rather
   than relying on the claim — an image's preinstalled set changes without notice, and the
   failure mode is a confusing red on an unrelated PR.
5. Add `scripts/doctor.sh --check --scope repo` to the `app` job, after `make check`.
6. Add `scripts/lifecycle-status.sh` as a **non-fatal reporting** step (`|| true`) with a
   comment explaining why it must never gate — see Out of scope. Getting this wrong deadlocks
   the final PR of every future plan.
7. Re-verify the pinned action SHAs against current releases before the first run
   (`scripts/check-action-pins.sh --online`), then `--stamp`. An inherited pin is not a chosen
   one. **Expect this to modify `templates/ci/*.yml` as well as `.github/workflows/*.yml`** —
   `check-action-pins.sh:53-58` scans both directories and `:96-99` rewrites every stamped
   file it finds. That is intended and allowed here: the stamp records *when the pins were
   last verified*, and they were verified by the same act. **Stage every stamped workflow file
   by name** — once the workflow is copied there are at least **three**: `.github/workflows/ci.yml`,
   `templates/ci/ci.yml` (`:10`), and `templates/ci/deploy.yml` (`:11`). `deploy.yml` is easy to
   miss because this step never otherwise touches it, and leaving it unstaged produces a dirty
   tree that the Stop gate will flag. Do **not** add a scope flag to `check-action-pins.sh` to
   avoid this — a stamp that lies about the template is worse than a three-file diff.
8. Add `.github/` to `config/payload.tsv` as **`source-only`** — this workflow is this repo's
   own instance, not payload. Adopters get the inert template. (Note issue #17: source-only
   directories don't currently exclude correctly. If #17 has not landed, use the exact file
   path `.github/workflows/ci.yml`, and add a comment pointing at #17.)

**Test:** `self-test.sh` asserts `.github/workflows/ci.yml` exists, contains no
`<ANGLE-BRACKET>` placeholders, and that `ci-gate`'s `needs` list and its result loop name the
same jobs — the drift `templates/ci/ci.yml:132-133` warns about, already covered at
`self-test.sh:113+` for the template. Assert the workflow does not leak into an export.

**"Valid YAML" — assert structure, not a parse.** The repo's required tools are `bash make git
jq gh shellcheck gitleaks`; **no YAML parser is among them**, and none may be added for this.
`yq` is absent here, and while `python3`+PyYAML happens to exist on this machine and on
GitHub's images, depending on it would make the suite pass or fail based on what a developer
happens to have installed — the opposite of the hermetic property #16 just bought. So assert
what `bash`/`grep`/`awk` can actually check:
- no literal tab characters (YAML forbids tabs for indentation — and the profiles are **TSV**,
  so a stray tab surviving into rendered output is a live risk in F-5, not a theoretical one);
- required top-level keys present (`name:`, `on:`, `permissions:`, `jobs:`);
- every `uses:` pinned to a 40-char SHA with a version comment (`check-action-pins.sh` already
  does this — call it rather than reimplementing);
- the `ci-gate` needs↔loop parity check above;
- indentation is spaces-only and the setup-block markers are balanced (both present, or both
  absent for `generic`).

If a parser *is* present, use it opportunistically behind `command -v` as an extra assertion —
never as a required one. And note the backstop: **GitHub is the real parser.** An invalid
workflow does not run at all, which surfaces immediately on the first PR and is precisely the
kind of feedback F-2 exists to obtain.

**DoD (executor — all verifiable locally, no push):**
- `.github/workflows/ci.yml` exists, passes the structural assertions defined in this step's
  Test section (no tabs, required top-level keys, pinned `uses:`, no `<ANGLE-BRACKET>`
  placeholders), and its `ci-gate` `needs` list matches its result loop.
- Every command the workflow runs passes locally: `make check`, `make test`, `make build`,
  `scripts/doctor.sh --check --scope repo`.
- `scripts/check-action-pins.sh` passes; **every stamped workflow/template file** carries a
  refreshed stamp and is staged by name — at least `.github/workflows/ci.yml`,
  `templates/ci/ci.yml`, and `templates/ci/deploy.yml`. Verify by listing what `--stamp`
  actually rewrote rather than by recalling this list.
- `scripts/doctor.sh` reports CI **active** instead of inert.
- The workflow does not appear in an export (`config/payload.tsv` marks it source-only).
- `self-test.sh` covers the assertions above.

**Acceptance (human, post-merge — this step is not "done" until these hold, but the executor
cannot perform them under the never-push contract):**
1. Push the branch and open a PR; confirm CI actually runs and is red on a deliberate break.
2. In branch protection on `main`, set **`CI gate`** as the *only* required status check.
3. Record the first green run's URL in this doc's Status block — it is the first genuinely
   derived verification evidence this project has produced, and F-4 consumes exactly this.

**Commit:** `Run this scaffold's own CI gate instead of only shipping the template`

---

## Step 3 — Stamp approval as an event

**Why third:** independent of CI, and it removes a hand-typed field that `lifecycle-status.sh`
already treats as load-bearing. Small, self-contained, and it stops the #19 class of rot at
the source rather than teaching the checker more spellings.

**Approach:**
1. Add `--approved-by <name>` to `plan-to-issues.sh`'s flag loop (`scripts/plan-to-issues.sh:22-39`),
   following the existing `--doc` pattern for "requires a value".
2. On `--apply`, **extend the existing `TRACK_STAMP`** (`plan-to-issues.sh:120-121`) by
   appending `approved-by:` and `approved-at:` fields *inside that same HTML comment*. Do not
   invent a second marker, and do not put approval in the title.
   - The tracker is discovered by `issue_for_marker` (`:114-118`) doing a jq `contains` match
     on the **prefix** `agentic-flow:plan:<id> tracker`. Appending after `spec:<hash>` leaves
     that prefix intact, so reconciliation keeps working. Prepending or renaming the marker
     would break resumption for every existing tracker — the failure would look like
     "plan-to-issues suddenly creates duplicate issues."
3. When `--doc` is given, write the `- **Approval:**` line into the doc's Status block using
   the schema in `docs/templates/feature-analysis.md:138`. Match the canonical field name
   exactly; that mismatch is precisely issue #19.
4. Reconciliation must stay idempotent: re-running `--apply` preserves the original approval
   rather than re-dating it. Approval is an event, not a timestamp of the last run.
   **Mind the overwrite.** On the update path the tracker body is *replaced* wholesale with
   `TRACK_DESIRED` (`plan-to-issues.sh:180-181`). So approval stored in the body is destroyed
   by the next `--apply` unless it is deliberately carried forward: parse `approved-by:` /
   `approved-at:` out of the **fetched** `existing_tracker` body and re-emit them when
   composing `TRACK_DESIRED`. A later `--approved-by` with a *different* name on an
   already-approved plan should be refused (or warn loudly and keep the original) rather than
   silently rewriting who approved it — that field is the audit trail.
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
3. Introduce **`UNVERIFIED`** as distinct from both READY and BLOCKED, and split strictly on
   *did we get an answer*, not *was the answer good*:
   - resolved + `success` → **READY**
   - resolved + anything else (`failure`, `cancelled`, `timed_out`) → **BLOCKED**. A run we
     queried and found red is the strongest possible evidence that the doc is not done;
     treating it as merely unverified would be a downgrade of real information.
   - could not resolve — no `gh`, no network, URL is not an Actions run → **UNVERIFIED**.
   The rule in one line: **UNVERIFIED means "no answer", never "a bad answer".**
4. Under `--check`, `UNVERIFIED` is **not** fatal; BLOCKED is. Failing on an unreachable
   network would make the check untrustworthy in exactly the situations it matters — but a
   resolved red run must fail, or `--verify-evidence` is decorative.
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
4. `init.sh` renders the profile's setup block into the adopted project's
   **`templates/ci/ci.yml`** — the inert copy — and **never** into `.github/workflows/`.
   Honour the existing pre-existing-file guard (`init.sh:258-265`) exactly as the Makefile
   path does.

   **This is a hard constraint, not a preference.** `self-test.sh:109-112` asserts that
   adoption creates neither `.github/workflows/ci.yml` nor `deploy.yml`, with the reasoning
   in the comment: *"adopting the harness must never activate a workflow — least of all
   deploy.yml — behind the adopter's back."* `templates/ci/README.md` makes the same promise.
   Rendering a *better* template does not earn the right to activate it; a Cargo setup block
   the adopter never asked to run is still a workflow they did not consent to. F-2 activating
   CI **on this repo** is a decision this repo's owner made about this repo — it is not
   precedent for adopters.

   Do **not** add an opt-in activation flag in this step either. If one is ever wanted it is a
   separate change with its own consent story (what does it do to `deploy.yml`? to a project
   that already has CI?), and bundling it here would smuggle a policy change into a rendering
   improvement.
5. Pins stay in the template, not the profiles. `check-action-pins.sh` must keep working, and
   scattering SHAs across five profile files would guarantee drift.
6. **Scope: replace the whole runtime setup block; leave only the path-filter placeholders.**

   **The unit of substitution is the BLOCK, not the angle bracket.** Everything between
   `# ── Replace this block…` (`:89`) and `# ── End runtime setup ──` (`:102`) is discarded and
   re-emitted from the profile — `actions/setup-node`, `npm ci`, and `npm audit` included. For
   `--stack rust` the result must contain a Cargo toolchain setup and a `--locked` install and
   **no trace of Node**. Substituting only the `<MAJOR, e.g. 22>` version placeholder inside a
   surviving Node block would leave every Rust project running `setup-node` — which is the
   precise defect this step exists to remove.

   What is *not* rendered is the path-filter block, and only that:
   - `:49` `<SRC DIRS>` — **project-specific and not derivable.** A Rust project may use
     `src/**`, `crates/**`, or workspace members; no profile can know which.
   - `:50` `<MANIFEST + LOCKFILE>` — stack-derived in principle (the profiles' `detect` rows
     already name `Cargo.toml`, `package.json`, `go.mod`, `pyproject.toml`), but left alone
     anyway: it is *adjacent* to `:49` in the same block, so the human edits that block either
     way and pre-filling one line of it saves nothing real. Not worth new profile row types in
     the last and lowest-risk step.

   Update the template's header comment (`:3-4`) to say the runtime block is now filled by the
   stack profile and the path filters remain the adopter's to complete at activation. This is
   consistent with the template shipping inert: activation was always a deliberate human step.

**Test:** render every profile and assert, using the structural checks defined in F-2 (**not** a
YAML parser). **Failure path first, and make it the cross-contamination case:** a non-Node
profile's rendered output must contain **no** `setup-node`, `npm`, or `node-version` anywhere —
that assertion is what distinguishes "replaced the block" from "substituted the version inside
the Node block", and the second is a plausible misreading that produces working-looking YAML.
Generalise it: for each profile, no *other* profile's toolchain markers may appear.
Then: **no angle-bracket placeholder remains between the runtime-setup markers**;
the two path-filter placeholders (`:49`, `:50`) are still present and unmodified; `generic`
produces a workflow with no runtime block and no orphaned marker comments;
`check-action-pins.sh` passes on each rendered result; adoption still creates no
`.github/workflows/*`. **Failure path first:** a profile with a malformed `ci-setup` row fails
validation loudly rather than emitting a broken workflow, and a `ci-setup` value containing a
literal tab is rejected — see F-2's tab note.

Scope the placeholder assertion to the runtime block, not the whole file. A whole-file "no
angle brackets" check would fail by design and invite someone to "fix" it by gutting the path
filters.

**This does not contradict F-2**, which asserts *zero* angle brackets. The two steps assert
about different files: F-2 covers `.github/workflows/ci.yml`, the **activated** copy, where a
human filled the path filters for this specific repo (F-2 step 3). F-5 covers
`templates/ci/ci.yml`, the **inert** template, where those filters cannot be filled because no
project has been chosen yet. Activated ⇒ complete; inert ⇒ runtime resolved, project details
pending.

**DoD:** `init.sh --stack rust` produces an **inert** `templates/ci/ci.yml` in the target whose
runtime setup block is Cargo — **with no Node artifacts surviving anywhere in the file** and no
runtime placeholder left; the path-filter placeholders remain for the adopter to complete at
activation, and the template's header comment says so; `.github/workflows/` is not created; the
pin checker still passes.
**Commit:** `Render the CI runtime block from the stack profile like the Makefile`

---

## Status / Implementation status
- **Tracking issue:** [#21](https://github.com/wabkebab/agentic-flow/issues/21) — sub-issues:
  F-1 #22 · F-2 #23 · F-3 #24 · F-4 #25 · F-5 #26.
- **Approval:** user approved on 2026-07-24; issues created via `plan-to-issues --apply`
  (the approval event, METHODOLOGY §6). Hand-written because `--approved-by` does not exist
  yet — it is **F-3 of this very plan**. When F-3 lands, this line becomes machine-written.
- **Verification evidence:** pending until execution.
- **Review verdict:** pending.
- **Execution commits:** F-1 `f14069a`; F-2 `cef93b8`; F-3 `b13a5d9`; F-4 `82a5265`;
  F-5 this commit.
- F-1 through F-5 implemented locally on `feature-ci-as-authority-f1`.
  Executor closes each step via a PR with `Fixes #N`, records the commit SHA per step here,
  and ticks the matching F-N box in the Tracker above.
