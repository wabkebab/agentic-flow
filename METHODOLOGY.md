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
