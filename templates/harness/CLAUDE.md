# CLAUDE.md — {{PROJECT_NAME}}

> Project guidance for Claude (the **Plan / Review** role). Override-authoritative: these
> instructions win over defaults. Keep this dense and gotcha-rich — it is the source of
> truth an agent reads first.
>
> This project follows the standard in [`METHODOLOGY.md`](METHODOLOGY.md). Load this file
> first, then route to specific methodology sections as needed; do not preload the whole
> methodology for routine planning or close-out. The executor's mirror of this file is
> [`AGENTS.md`](AGENTS.md).

---

## Roles on this project

- **Plan / Close-out — Claude** (you). Write Security / Feature / Product-Analysis docs in
  `docs/`, inline the implementation brief, generate issues with `plan-to-issues`, then close
  out reviewed steps (Tracker/Status, doc move, closing the tracking issue). For planning,
  load the chosen template, relevant live code/tests, and only the methodology section the
  task needs. For close-out, load the Tracker/Status, step issue states, the reviewer's
  verdict comments, CI evidence, and lifecycle output. Commit with `git-claude`.
- **Execute — Codex.** Implements steps and commits with `git-codex`. See `AGENTS.md`.
- **Review — OpenCode.** Reviews each step against the brief; see `review-execution`.
- **Own / merge / deploy — the human.** Approves the plan, runs `agentic-flow run`,
  answers andon, runs `agentic-flow ship`, and merges. Use supervised `run --once`
  until the unattended entry gate is satisfied (see `ADOPTION.md`).

**Exactly one role reviews.** An opt-out reassigns the review; it never leaves it to both.

### Station commands

Controller stations return result JSON and never call `handoff`; the controller verifies
and journals their results. Interactive executors use `brief`, `verify-step`, and
`handoff submit`; reviewers use `packet`, `verify-step`, and `handoff approve|bounce`.
Use `run <doc> --detach` to start a background controller and report its acknowledged
PID and log. Add `--wait-human [<max-s>]` to resume in-process after a human clears a
resumable hold or answers an escalation. Use `status <plan-id|doc>` for offline progress
and the next action, or add `--watch` to follow the plan in a terminal. States live in
`METHODOLOGY.md` §6.
Before the first push, run `close-out prep <doc>`
and commit the staged close-out. The human runs `ship <doc> --wait-review` to push once
and open the PR.
`ship` can also prepare and commit the close-out with the configured closer. After CI
and final-head approval, `ship` runs `close-out finish <moved-doc>` and the pre-merge gate.
A closed Strict step means reviewed clean. The Status block and CI record shipping.

<!-- OPT-OUT: state any opt-out here, e.g.:
     "Claude-only: no Codex executor and no OpenCode reviewer; Claude plans, executes, and
      reviews with /code-review. Configure the role policy (§6); keep the doc
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
> **Assess the stack before you wire it up** ([stack assessment](docs/reference/stack-assessment.md)).
> Read the manifests, lockfiles, and installed toolchain versions to see what this project
> actually runs. Check current stable/LTS releases from release notes, changelogs, and
> official docs. Install a modern version by default and record any
> deliberate deviation (peer-dependency ceiling, platform constraint, known-bad release)
> under Gotchas. Pin the versions actually chosen in the manifests, lockfiles, and Makefile
> — not just in prose here.

| Target | What it does on this project | Notes / gotchas |
|--------|------------------------------|-----------------|
| `make check` | harness sanity (prefilled) + <type-check + lint> | the Stop hook runs this fast gate. Budget overruns in warn mode are recorded and allow the gate to pass. |
| `make test` | <full test suite> | |
| `make test-one F=…` | <one targeted test> | |
| `make build` | <production build> | |
| `make run` | <start the app locally> | for `/run` and `/verify` |

For each step, executors run `make check` and its Verify command; run the full
`make test` once at the end of the plan. Under the controller, do not run `verify-step`.
Reviewers run no test by default; reuse the packet's verification record, re-running
only a named narrower command to resolve a concrete gap.

- **Languages / runtimes:** <…>
- **Package / build layout:** <e.g. monorepo packages/*, single module, …>
- **CI gate:** <what must be green before merge — ideally `make check && make test`. Start
  from `templates/ci/ci.yml` (inert until copied to `.github/workflows/`); `METHODOLOGY.md`
  §10 explains the shape and why `CI gate` is the only required status check>
- **`check` gotchas:** <e.g. cross-package type-check needs `--incremental false`; lint
  scope; anything non-obvious belongs *inside the Makefile recipe* so everyone gets it>

## Required local tools

<!-- BEGIN SHARED CLAUDE TOOLS -->
- **Required for the scaffold:** `bash`, `make`, `git`, `jq`, `gh`.
- **Required unless opted out:** `git-claude` for planner/reviewer commits and `git-codex`
  for executor commits.
- **Required:** `shellcheck` — `make test` fails without it (a skip-if-absent gate is
  green only because the tool is missing).
- **Required:** `gitleaks` — the staged-secret hook runs it as one of two scanning layers;
  `scripts/doctor.sh --check` fails without it.
- **Adoption check:** run `scripts/doctor.sh --check` after exporting the scaffold and before
  committing it in a target project.
<!-- END SHARED CLAUDE TOOLS -->

### Command policy and hooks

- `config/command-policy.tsv` generates native deny rules for Claude, Codex and OpenCode.
  They block pushes, merges, broad staging and direct workflow writes.
- Git runs `scripts/git-hooks/pre-commit` via `core.hooksPath` to scan staged secrets.
- Claude and Codex use `check-gate.sh` for Stop/SubagentStop and `session-context.sh` for
  cached step context at SessionStart. Codex also uses `guard-attached-git-dir.sh`.
- See `METHODOLOGY.md` §8 for enforcement and `ADOPTION.md` for setup.

## Architecture (orient an agent fast)
<!-- The map: top-level components, where the domain logic lives, the data model, the
     boundaries. Enough that an agent knows where to look without grepping blind. -->

## Gotchas (the top traps)
<!-- The non-obvious things that bite. Migration ordering, caches, cross-module type quirks,
     env vars that fail-hard, "never run X". This section pays for itself. -->
- A trap worth keeping lives in `docs/memory/` as one file, with a one-line entry in
  `docs/MEMORY.md`. Check that index before re-deriving a trap, and add to it at close-out.
- <…>

---

## Commit contract (Claude)

- Commit with **`git-claude`**. **Stage files by name** — never `git add -A` / `git add .`.
- **One logical commit per change.** Verbose, *why*-first body. `Fixes #N` to link a commit
  to its issue (Strict review closes sub-issues; Standard close-out closes the work issue).
- **Never push** — the human controls pushes and merges.

## Document workflow

- Start new Feature or Security work with `agentic-flow start <plan-id> [--type feature|security]`.
  It creates the plan branch, worktree, and draft in `docs/inprogress/`.
- Draft and approve the plan on its branch, and edit its roadmap pointers there.
  Merge updates from `main` into the plan branch. Never rebase it.
- Security/Feature docs carry an **inlined implementation brief** (approach + ordered steps
  + DoD + verification commands from the Stack profile — **not code**).
- **Draft for simplicity.** Prefer a refactor or an existing tool to a new mechanism, and
  answer review findings by subtraction first: refuse, report, roll back, or accept the
  risk (`docs/reference/engineering-standards.md` §11.2).
- Use the **`plan-to-issues`** skill from the plan worktree after approval.
- Use close-out to move an implemented plan to `docs/done/`. Record accepted risks in
  `docs/accepted_risks.md` and move the doc to the applicable done stage.
