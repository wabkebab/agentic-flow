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

## Stack profile  ⚠️ FILL THIS IN

> **This is the one project-specific section the whole methodology depends on.** Every
> template and the implementation briefs refer to these commands as placeholders
> (`<build>`, `<type-check>`, `<test>`, `<lint>`, `<run>`). Define them once here.

| Placeholder | Command | Notes |
|-------------|---------|-------|
| `<build>` | `<e.g. npm run build / cargo build / make>` | |
| `<type-check>` | `<e.g. npx tsc --noEmit / mypy . / cargo check>` | |
| `<test>` | `<e.g. npm run test / pytest / go test ./...>` | how to run the full suite |
| `<test one>` | `<e.g. npx vitest run path / pytest path::test>` | how to run a single targeted test |
| `<lint>` | `<e.g. eslint . / ruff check / golangci-lint run>` | |
| `<run>` | `<how to start the app locally>` | for `/run` and `/verify` |

- **Languages / runtimes:** <…>
- **Package / build layout:** <e.g. monorepo packages/*, single module, …>
- **CI gate:** <what must be green before merge>

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
