# Agentic Development Methodology

> The standard plan → execute → review loop, the document lifecycle, and the
> conventions that make agentic work repeatable across projects. This file is the
> source of truth; templates in `docs/templates/` are the fill-in-the-blanks forms.
>
> Stack-agnostic by design. The only project-specific thing is the **Stack profile** — the
> [`Makefile`](Makefile), the one executable source of truth for build/test/run commands.
> Everything here, in the templates, and in the hooks calls its targets: `make check`
> (fast type-check + lint gate), `make test`, `make test-one F=…`, `make build`, `make run`.
> `CLAUDE.md` explains those targets and their gotchas; the `Makefile` runs them.

---

## 1. Roles

| Role | Who (default) | Output |
|------|---------------|--------|
| **Plan / Review** | Claude | Analysis & review documents (`docs/`), the inlined implementation brief, GitHub issues, code review of execution commits. Commits with `git-claude`. |
| **Execute** | Codex | Code that satisfies the issues generated from a plan, one logical commit per step. Commits with `git-codex`. |
| **Own / merge / deploy** | Human | Approves plans, merges PRs, controls all pushes and releases. |

This two-agent split is the **default standard**. A project may **opt out** (e.g.
Claude-only, no Codex): keep the same document lifecycle and review discipline, drop the
`agent:codex` labels and `git-codex`, and let Claude both plan and execute. State the
opt-out at the top of the project's `CLAUDE.md`.

---

## 2. The loop

```
  Review / Plan (Claude)
        │  produces
        ▼
  docs/inprogress/<doc>.md         Security | Feature | Product Analysis
        │   (Security & Feature docs carry an inlined Implementation Brief —
        │    the execution insights for the implementer, NOT the code)
        │
        │  human approves
        ▼
  plan-to-issues  ───────────────▶  GitHub tracking issue + one sub-issue per step
        │
        ▼
  Execute (Codex)                   branch + PR per step, "Fixes #N", git-codex
        │
        ▼
  Review (Claude)                   /code-review (+ ultra for big branches), or a
        │                           hand-written review doc; findings → fixes
        │                           (Codex or Claude), tick the findings tracker
        ▼
  Merge (human)  ────────────────▶  PR merge auto-closes #N
        │
        ▼
  doc done  ─────────────────────▶  move to docs/done/ (or docs/done/security/),
                                    update the Status section; accepted-but-not-built
                                    risks/features recorded in docs/accepted_risks.md
```

The loop is **one-directional** (doc → issues), never the reverse. The document stays the
source of design intent; issues are the disposable execution units.

---

## 3. Document types

Three types live under `docs/`. Pick the template that matches the work.

| Type | Template | Purpose | Implementation brief? |
|------|----------|---------|-----------------------|
| **Security** | `templates/security-review.md` | A security review or hardening pass. Severity-graded findings with `file:line` and a concrete fix. | **Yes — inlined.** Closes to `docs/done/security/`. |
| **Feature** | `templates/feature-analysis.md` | Designing a feature or change. Goal, current state, approach, what-not-to-build. | **Yes — inlined.** Closes to `docs/done/`. |
| **Product Analysis** | `templates/product-analysis.md` | Exploratory architecture / product / monetization analysis. Options, trade-offs, a recommendation. A **decision record**. | **No.** If it greenlights work, spin off a Feature (or Security) doc for that. |

**The implementation brief is inlined** in Security and Feature docs as a dedicated
section — it is the brief an implementing agent reads to execute precisely. It contains
the *approach and insights*, ordered steps, definition of done, and verification
commands — **not the actual code**. Keep design rationale in the analysis sections above
it; keep the *how* in the brief.

---

## 4. Document lifecycle

```
docs/
├── README.md            ← index + naming conventions (keep current)
├── accepted_risks.md    ← living register of reviewed-and-accepted risks / declined features
├── backlog/             ← identified but not started (ideas, queued analyses)
├── inprogress/          ← active: being written, executed, or reviewed
├── done/                ← completed Feature / Product analyses
│   └── security/        ← completed Security reviews
└── templates/           ← the forms in this repo; copy out, don't edit in place
```

- A doc starts in `backlog/` (or straight into `inprogress/` if work begins immediately).
- It lives in `inprogress/` through plan → execute → review.
- It moves to `done/` (or `done/security/`) when **either**: the implementation brief's
  steps are all shipped and verified, **or** the user has accepted the risk / declined the
  feature (record that decision in `accepted_risks.md` and link it).

### Naming convention
- `security-<topic>.md`, `feature-<topic>.md`, `product-<topic>.md` — kebab-case topic.
- Avoid dates and model names in filenames; put those in the TRIAGE header instead.
- One topic per file. Don't accumulate unrelated findings in one doc.

### TRIAGE header
Every doc opens with a one-glance triage block so an agent (or you, months later) knows
what it is and whether it's live, without reading the whole thing:

```md
<!-- TRIAGE (first pass · YYYY-MM-DD) -->
> **Type:** Security | Feature | Product Analysis · **Status:** 🟦 Proposal | 🚧 In progress | ✅ Done | 🕰️ Superseded
> One or two lines: what this is, what's current vs historical, what (if anything) to do next.
```

### Findings / step tracker
Every Security and Feature doc carries a checklist near the top — it is the burndown the
executor ticks as commits land:

```md
## Tracker
- [x] SEC-1 Backup restore destroys QA data — fixed in <sha> (#70)
- [ ] SEC-2 KDM expiry only checks start — open (#72)
```

---

## 5. Severity legend (Security reviews)

Use these consistently; they map 1:1 onto GitHub labels and onto `plan-to-issues`.

| Symbol | Severity | Label |
|--------|----------|-------|
| 🔴 | High — exploitable / data-loss / auth bypass | `sev:high` |
| 🟠 | Medium — meaningful weakness, bounded blast radius | `sev:med` |
| 🟡 | Low — hardening, defence-in-depth, hygiene | `sev:low` |
| 🟦 | By-design / accepted — no action, or moved to `accepted_risks.md` | `sev:nit` / (none) |

Each finding states **location** (`file:line`), **what's wrong**, and a concrete **Fix:**.

---

## 6. Plan → GitHub issues

A markdown tracker is versioned and offline; GitHub issues give a live progress bar,
`Fixes #N` auto-close, and PR linkage. They're complementary — **doc = design intent,
issues = execution units**.

Use the `plan-to-issues` skill (`.claude/skills/plan-to-issues/`) once a plan is
**approved**. It creates one **tracking issue** plus one **sub-issue per
independently-shippable step**, from the implementation brief.

**Label convention (encodes the loop):**
`plan` (on the tracker) · `needs-execution` · `needs-review` · `agent:codex` ·
`agent:claude` · `sev:high|med|low|nit`.

Rules:
- One issue per independently-shippable step — not one giant issue, not one per commit.
- Issue body = the step's Definition of Done + the exact verification commands. The *why*
  and the ordering stay in the doc.
- Flow is one-directional. If the plan changes, regenerate or hand-edit issues; never
  reverse-sync issue edits into the doc.

---

## 7. Commit contract

Identity is enforced by wrapper scripts, each with its own SSH signing key:

- **Claude commits with `git-claude`.**
- **Codex commits with `git-codex`.**

Rules (both agents):
- **Stage specific files by name** — never `git add -A` / `git add .`.
- **One logical commit per step.** Don't bundle multiple steps; don't split one step across
  commits without reason.
- **Verbose, *why*-first commit bodies** — name the risk/bug, the approach, the blast
  radius. A reviewer months later should understand the change from the message alone.
- **Reference the issue** — `Fixes #N` in the PR (or commit) so merge closes it.
- **Never push.** The human controls all pushes and merges.
- The `Co-Authored-By:` trailer is **appended by the wrapper** when the message lacks one —
  don't hand-maintain it (model names in prose go stale); a trailer you write is kept as-is.

Example body:

```
Bind session and exchange JWTs to the tenant schema

Signed payloads omitted any tenant identifier, so with a shared secret a
cookie from tenant A verified at tenant B. Add `schema` to every signed
payload and reject mismatches in requireAuth. Legacy missing-claim cookies
are treated as the default tenant for one release to ease rollout.

Fixes #73
```

(The wrapper appends `Co-Authored-By: Claude <noreply@anthropic.com>` on commit.)

---

## 8. Enforcement & harness capabilities

### Shipped guardrails (in the scaffold, enforced — not convention)
`.claude/settings.json` wires hooks that mechanize the contract so it can't be quietly missed:
- **Stop / SubagentStop → `make check`** (`scripts/hooks/check-gate.sh`): blocks a turn from
  ending while the fast gate is red, feeding the failure back to the agent; if the retry is
  still red it warns and allows rather than looping forever. Skipped when the working tree
  is clean (nothing uncommitted to gate — spares no-edit turns and read-only subagents).
  Scoped to the *fast* gate, not the full suite. `check` ships prefilled with harness sanity
  checks; extend it with the stack's type-check + lint.
- **PreToolUse(Bash) → block `git add -A` / `git add .` / `--all`**
  (`scripts/hooks/block-git-add-all.sh`): enforces §7's "stage files by name" mechanically.
- **PreToolUse(Bash) → block `git push` / `gh pr merge`** (`scripts/hooks/block-push.sh`):
  enforces §7's "never push — the human controls all pushes and merges" mechanically.
- **`scripts/docs-index.sh`** keeps `docs/README.md`'s index derived from each doc's TRIAGE
  header (run it, or `--check` in CI) so the index can't go stale by hand.
- **`scripts/init.sh`** is the adoption path: export the scaffold, fill machine tokens,
  apply stack/opt-out flags, stamp the source version, and print the doctor report.
- **`scripts/doctor.sh`** is the adoption checklist for a copied scaffold: required files,
  hook wiring, required tools, real Make targets, and docs-index freshness.
- **`scripts/self-test.sh`** exercises the scaffold's offline invariants, especially export
  behavior and hook behavior.

### Optional capabilities
These make the handoff explicit and parallel instead of sequential:

- **Plan mode** (`EnterPlanMode` / `ExitPlanMode`) — design and get approval *before* any
  file changes. Matches "Claude designs, then hands off."
- **`Explore` / `Plan` subagents** — fan-out research before writing a plan.
- **Worktrees** (`isolation: "worktree"`) — run execution and review on isolated worktrees
  of the same branch so review can start while execution continues.
- **`/code-review`** (`low|medium|high|max`, and **`ultra`** for a deep multi-agent cloud
  review of a whole branch) — the productized version of a hand-written review doc. Keep
  hand-written reviews for architecture-level passes.
- **`/security-review`** — a security pass on the pending branch diff; complements a
  Security doc.
- **`/verify` and `/run`** — drive the app to confirm a fix behaves, not just that tests pass.
- **More hooks** — beyond the shipped two: a PostToolUse reminder on shared-type edits, a
  commit-message-format check, etc.
- **Memory** — persist durable decisions (this methodology, the commit contract, recurring
  review themes) so each session doesn't re-derive them.

---

## 9. Starting a project — assess the stack first

Before the first line of code on a new project (and when adopting the scaffold into a young
one), **establish what the current stack actually is, then install a modern version of it.**
An agent's default is training-data recall, which skews stale by months to years — it will
happily scaffold last year's major version and pin it.

1. **Assess what's there.** For an existing project: read the manifests and lockfiles
   (`package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod`, …) and the installed toolchain
   versions (`node -v`, `python -V`, `cargo -V`, …). Note anything already end-of-life.
2. **Check what's current.** Look up current stable releases from release notes / changelogs
   / official docs — not from memory. Note the LTS line where one exists.
3. **Choose deliberately.** Default to the current stable (or current LTS for runtimes).
   Deviate only for a stated reason — a peer dependency's ceiling, a platform constraint, a
   known-bad release — and write that reason down in `CLAUDE.md` → Gotchas.
4. **Pin it where it executes.** Versions live in the manifests, lockfiles, and `Makefile` —
   the places that run. Prose in `CLAUDE.md` explains; it doesn't pin.
5. **Verify green before building on it.** `make check && make test` on the fresh stack, so a
   later failure is attributable to your code and not the scaffold.

The same discipline applies mid-project when adding a dependency: check the current version
rather than typing the one you remember.

---

## 10. CI/CD pipeline shape

The reference structure, extracted from a working two-workflow setup. Stack-agnostic: the
*shape* is the standard, the commands inside it come from the `Makefile`.

> **Working templates ship in [`templates/ci/`](templates/ci/README.md)** — `ci.yml` and
> `deploy.yml`, exported **inert** so adoption never activates a workflow (least of all a
> deploy) behind you. Copy into `.github/workflows/` and fill the `<ANGLE-BRACKET>` spots.
> This section is the *why*; those files are the *what*.

**Two workflows, two different risk postures.**

| | `ci.yml` | `deploy.yml` |
|---|---|---|
| Trigger | `pull_request` | `push` to release branches + `workflow_dispatch` |
| Concurrency group | per PR number | per ref name |
| `cancel-in-progress` | **`true`** — superseded runs are waste | **`false`** — finishing a deploy beats half-deploying |
| Permissions | `contents: read` (+ `pull-requests: read` for path filtering) | `contents: read` + only the write scope the registry push needs |

### Rules that apply to both

- **Pin everything.** Third-party actions by **full commit SHA** with a `# vX.Y.Z` trailing
  comment; runners by version (`ubuntu-24.04`, never `ubuntu-latest`). A tag is mutable —
  a SHA is the only pin that resists a compromised action.
- **Least-privilege `permissions:` declared explicitly** at workflow level. Add a scope only
  where a step actually needs it, and comment *why* (e.g. path-filter actions call the Pulls
  API and fail with "Resource not accessible by integration" without `pull-requests: read`).
- **Steps stay thin — call `make` targets.** The Makefile is the one executable source of
  truth (§ top-matter); a CI step that inlines its own command sequence is a second source
  that will drift from what runs locally. Keep the YAML to checkout/setup/`make …`.
- **The workflow file is its own trigger.** Include `.github/workflows/<file>.yml` in every
  path filter, so editing CI re-runs everything it gates.
- **Ship the runbook with the workflow.** A trailing comment block listing one-time server
  setup and every required repository secret — the operational knowledge dies otherwise.

### `ci.yml` — job structure

```
changes ──┬─▶ app checks        (if changes.app)
          ├─▶ compose syntax    (if changes.docker)
          └─▶ <area N>          (if changes.<area>)
secrets-scan  (never filtered — always runs)
                    │
                    ▼
              ci-gate           needs: [everything], if: always()
```

1. **`changes`** — a path-filter job whose outputs gate the rest, so a docs-only PR doesn't
   pay for a full build. One filter per independently-testable area.
2. **Per-area jobs**, each `if: needs.changes.outputs.<area> == 'true'`.
3. **`secrets-scan`** — scans the PR diff range (`base…head`) for **verified** leaked
   secrets. Never path-filtered: a leak can land in any file.
4. **The app job runs cheapest-first, fail-fast:** checkout → set up runtime *with dependency
   caching* → **install from the lockfile** (`npm ci`, `poetry install --sync`, …, never a
   resolving install) → audit production dependencies at a severity threshold → typecheck →
   lint → test → build. Give the build dummy CI env values so it never needs real secrets.
5. **`ci-gate`** — the single **required status check** in branch protection:

   ```yaml
   ci-gate:
     needs: [changes, secrets-scan, app, compose-syntax]
     if: always()
     steps:
       - run: |
           for result in "${{ needs.secrets-scan.result }}" "${{ needs.app.result }}" …; do
             case "$result" in
               success|skipped) ;;
               *) echo "Upstream job ended in '$result'"; exit 1 ;;
             esac
           done
   ```

   **This job exists because path filtering and required checks conflict.** A skipped job
   never reports, so naming the per-area jobs directly as required checks would block every
   PR that legitimately skips one. The gate collapses them into one always-reporting status
   that treats `skipped` as pass and `cancelled`/`failure` as fail.

### `deploy.yml` — job structure

1. **Build & push an image**, tagged twice: a moving `latest` pointer *and* an immutable
   per-commit tag for rollback. Use registry/GHA layer caching.
2. **Deploy pulls by digest**, not by tag — the tag can be re-pointed between push and pull;
   the digest is what was actually built and tested.
3. **SSH properly:** an ssh-agent action for the key, and `known_hosts` populated from an
   `ssh-keyscan` output stored as a secret. Never `StrictHostKeyChecking=no`.
4. **Sync deploy assets through an explicit allowlist** (rsync `--include … --exclude='*'`).
   Operator-maintained state on the server — the runtime `.env`, TLS certs — must never be
   in the sync set.
5. **Wait for readiness, then verify from outside:** `up -d --wait --wait-timeout N`, then an
   external healthcheck against the public URL with bounded retries and backoff. Skip
   gracefully (don't fail) when the URL secret isn't configured.
6. **Gate optional stacks** (monitoring, workers) on their own path filter *or* a
   `workflow_dispatch` input, so routine app deploys don't restart them.

### Wiring it to the harness

CI green must mean the same thing as local green: the CI gate is `make check && make test`
(§ Stack profile in `CLAUDE.md`), plus `scripts/docs-index.sh --check` where practical. If a
CI step needs a command that isn't a Make target, that's a signal the Makefile is incomplete
— add the target and call it, rather than growing logic in YAML.
