# CLAUDE.md — <project name>

> Project guidance for Claude (the **Plan / Review** role). Override-authoritative: these
> instructions win over defaults. Keep this dense and gotcha-rich — it is the source of
> truth an agent reads first.
>
> This project follows the standard in [`METHODOLOGY.md`](METHODOLOGY.md). Read it once;
> it defines the plan → execute → review loop, the document lifecycle, and the commit
> contract. The executor's mirror of this file is [`AGENTS.md`](AGENTS.md).

---

## Roles on this project

- **Plan / Review — Claude** (you). Write Security / Feature / Product-Analysis docs in
  `docs/`, inline the implementation brief, generate issues with `plan-to-issues`, review
  execution commits, fix or delegate fixes. Commit with `git-claude`.
- **Execute — Codex.** Implements the issues. Commits with `git-codex`. See `AGENTS.md`.
- **Own / merge / deploy — the human.** Approves plans, merges PRs, controls all pushes.

<!-- OPT-OUT: For a Claude-only project, state it here, e.g.:
     "This project is Claude-only. There is no Codex executor; Claude both plans and
      executes. Drop the agent:codex labels; keep the doc lifecycle and review discipline." -->

---

## Stack profile  ⚠️ WIRE THIS UP

> **The whole methodology depends on this.** The actual commands live in the
> [`Makefile`](Makefile) — the one executable source of truth that humans, agents, hooks,
> and CI all call. **Fill in the Makefile recipes.** This section just *explains* the
> targets and records the gotchas, so prose can't drift from what actually runs.
>
> **Before picking languages, frameworks, or libraries here, check current stable
> versions** (release notes, changelogs, official docs — not training-data recall, which
> skews stale). Pin the versions actually chosen in the Makefile / lockfiles, not just
> in prose here.

| Target | What it does on this project | Notes / gotchas |
|--------|------------------------------|-----------------|
| `make check` | <type-check + lint> | the fast gate; **run by the Stop hook** so an agent can't end a turn red |
| `make test` | <full test suite> | |
| `make test-one F=…` | <one targeted test> | |
| `make build` | <production build> | |
| `make run` | <start the app locally> | for `/run` and `/verify` |

- **Languages / runtimes:** <…>
- **Package / build layout:** <e.g. monorepo packages/*, single module, …>
- **CI gate:** <what must be green before merge — ideally `make check && make test`>
- **`check` gotchas:** <e.g. cross-package type-check needs `--incremental false`; lint
  scope; anything non-obvious belongs *inside the Makefile recipe* so everyone gets it>

### Hooks (enforced, not optional)
This project ships `.claude/settings.json` with:
- **Stop / SubagentStop → `make check`** (`scripts/hooks/check-gate.sh`) — blocks ending a
  turn while type-check/lint is red. No-ops until `make check` is filled in.
- **PreToolUse(Bash) → block `git add -A` / `.` / `--all`** (`scripts/hooks/block-git-add-all.sh`)
  — enforces "stage files by name" mechanically.

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
