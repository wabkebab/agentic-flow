# CLAUDE.md — {{PROJECT_NAME}}

> Project guidance for Claude (the **Plan / Review** role). Override-authoritative: these
> instructions win over defaults. Keep this dense and gotcha-rich — it is the source of
> truth an agent reads first.
>
> This project follows the standard in [`METHODOLOGY.md`](METHODOLOGY.md). Read it once;
> it defines the plan → execute → review loop, the document lifecycle, and the commit
> contract. The executor's mirror of this file is [`AGENTS.md`](AGENTS.md).

---

## Roles on this project

- **Plan / Close-out — Claude** (you). Write Security / Feature / Product-Analysis docs in
  `docs/`, inline the implementation brief, generate issues with `plan-to-issues`, then close
  out reviewed steps (Tracker/Status, doc move). Commit with `git-claude`.
- **Execute — Codex.** Implements the issues. Commits with `git-codex`. See `AGENTS.md`.
- **Review — OpenCode.** The independent per-step review: reads the diff against the brief and
  either returns findings to Codex or marks the step ready for close-out. Commits review notes
  with `git-opencode`. See `METHODOLOGY.md` §1 and the label pairs in §6.
- **Own / merge / deploy — the human.** Approves plans, merges PRs, controls all pushes.

**Exactly one role reviews.** An opt-out reassigns the review; it never leaves it to both.

<!-- OPT-OUT: state any opt-out here, e.g.:
     "Claude-only: no Codex executor and no OpenCode reviewer; Claude plans, executes, and
      reviews with /code-review. Drop the agent:codex / agent:opencode labels; keep the doc
      lifecycle and review discipline."
     "No OpenCode: Claude reviews with /code-review. Independence is weaker — say so in the
      review verdict rather than implying a separate reviewer signed off." -->

---

## Stack profile  ⚠️ WIRE THIS UP

> **The whole methodology depends on this.** The actual commands live in the
> [`Makefile`](Makefile) — the one executable source of truth that humans, agents, hooks,
> and CI all call. **Fill in the Makefile recipes.** This section just *explains* the
> targets and records the gotchas, so prose can't drift from what actually runs.
> `init.sh --stack generic|node|python|go|rust` renders a conservative starting profile
> into the Makefile. Treat it as a proposal: verify the commands against this project's
> manifests and scripts before considering adoption complete.
>
> **Assess the stack before you wire it up** (`METHODOLOGY.md` §9). Read the manifests,
> lockfiles, and installed toolchain versions to see what this project actually runs; check
> current stable/LTS releases from release notes, changelogs, and official docs — *not*
> training-data recall, which skews stale. Install a modern version by default; record any
> deliberate deviation (peer-dependency ceiling, platform constraint, known-bad release)
> under Gotchas. Pin the versions actually chosen in the manifests, lockfiles, and Makefile
> — not just in prose here.

| Target | What it does on this project | Notes / gotchas |
|--------|------------------------------|-----------------|
| `make check` | harness sanity (prefilled) + <type-check + lint> | the fast gate; **run by the Stop hook** so an agent can't end a turn red |
| `make test` | <full test suite> | |
| `make test-one F=…` | <one targeted test> | |
| `make build` | <production build> | |
| `make run` | <start the app locally> | for `/run` and `/verify` |

- **Languages / runtimes:** <…>
- **Package / build layout:** <e.g. monorepo packages/*, single module, …>
- **CI gate:** <what must be green before merge — ideally `make check && make test`. Start
  from `templates/ci/ci.yml` (inert until copied to `.github/workflows/`); `METHODOLOGY.md`
  §10 explains the shape and why `CI gate` is the only required status check>
- **`check` gotchas:** <e.g. cross-package type-check needs `--incremental false`; lint
  scope; anything non-obvious belongs *inside the Makefile recipe* so everyone gets it>

## Required local tools

- **Required for the scaffold:** `bash`, `make`, `git`, `jq`, `gh`.
- **Required unless opted out:** `git-claude` for planner/reviewer commits and `git-codex`
  for executor commits.
- **Required:** `shellcheck` — `make test` fails without it (a skip-if-absent gate is
  green only because the tool is missing).
- **Required:** `gitleaks` — the staged-secret hook runs it as one of two scanning layers;
  `scripts/doctor.sh --check` fails without it.
- **Adoption check:** run `scripts/doctor.sh --check` after exporting the scaffold and before
  committing it in a target project.

### Hooks (enforced, not optional)
This project ships `.claude/settings.json` with:
- **Stop / SubagentStop → `make check`** (`scripts/hooks/check-gate.sh`) — blocks ending a
  turn while type-check/lint is red (one blocked retry, then warn-and-allow; skipped when
  the working tree is clean). `check` ships prefilled with harness sanity checks; extend
  it with the stack's type-check + lint.
- **PreToolUse(Bash) → block `git add -A` / `.` / `--all`** (`scripts/hooks/block-git-add-all.sh`)
  — enforces "stage files by name" mechanically.
- **PreToolUse(Bash) → block `git push` / `gh pr merge`** (`scripts/hooks/block-push.sh`)
  — enforces "never push; the human controls pushes and merges" mechanically.
- **PreToolUse(Bash) → scan staged content before a commit** (`scripts/hooks/scan-secrets.sh`)
  — blocks a commit whose staged diff looks like it carries a credential. CI-side scanning
  is one step too late: a committed secret must be rotated, not just removed. Runs **two
  layers, both always**: `gitleaks`, plus a local high-signal pattern set — the local set is
  not a fallback, it covers what gitleaks' default config allowlists (documented sample
  keys). Override a false positive with `AGENTIC_ALLOW_SECRET=1` on the commit.

## Architecture (orient an agent fast)
<!-- The map: top-level components, where the domain logic lives, the data model, the
     boundaries. Enough that an agent knows where to look without grepping blind. -->

## Gotchas (the top traps)
<!-- The non-obvious things that bite. Migration ordering, caches, cross-module type quirks,
     env vars that fail-hard, "never run X". This section pays for itself. -->
- <…>

---

## Commit contract (Claude)

- Commit with **`git-claude`**. **Stage files by name** — never `git add -A` / `git add .`.
- **One logical commit per change.** Verbose, *why*-first body. `Fixes #N` to close issues.
- **Never push** — the human controls pushes and merges.

## Document workflow

- New work → copy the matching template from `docs/templates/` into `docs/inprogress/`.
- Security/Feature docs carry an **inlined implementation brief** (approach + ordered steps
  + DoD + verification commands from the Stack profile — **not code**).
- Approved plan → run the **`plan-to-issues`** skill.
- On done (shipped & verified, or risk accepted) → move the doc to `docs/done/`
  (or `docs/done/security/`); record accepted risks in `docs/accepted_risks.md`.
