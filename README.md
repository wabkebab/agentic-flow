# agentic-flow

A copy-paste **scaffold** for a standardized agentic development workflow: the plan →
execute → review loop, a document lifecycle, the templates that drive it, and the agent
contracts — stack-agnostic, so it drops into any project regardless of language.

It encodes one loop:

> **Plan / Review (Claude)** writes a *Security*, *Feature*, or *Product-Analysis* doc.
> Security & Feature docs carry an **inlined implementation brief** (the execution insights
> for the implementer — *not* the code). An approved brief becomes GitHub issues via
> `plan-to-issues`. **Codex executes** (one commit per step, `git-codex`). **Claude reviews
> and fixes** (`git-claude`), ticks the tracker, closes issues. The doc then moves to
> `docs/done/` — or, if the risk is accepted / the feature declined, it's recorded in
> `docs/accepted_risks.md`.

The full standard is in **[`METHODOLOGY.md`](METHODOLOGY.md)**.

## What's in here

```
README.md                         this file
METHODOLOGY.md                    the standard: roles, loop, lifecycle, conventions
CLAUDE.md                         planner/reviewer contract + the per-project Stack profile
AGENTS.md                         executor (Codex) contract + commit format
.claude/skills/plan-to-issues/    skill: approved brief → GitHub tracking issue + sub-issues
scripts/plan-to-issues.sh         the deterministic gh/jq driver the skill calls
docs/
├── README.md                     docs index + naming conventions
├── accepted_risks.md             living register of accepted risks / declined features
├── backlog/  inprogress/         lifecycle stages
├── done/  done/security/         completed (security closes under done/security)
└── templates/                    the forms — copy out, don't edit in place
    ├── security-review.md        analysis + inlined implementation brief
    ├── feature-analysis.md       analysis + inlined implementation brief
    ├── product-analysis.md       decision record (no implementation brief)
    └── accepted-risk-entry.md    one block for accepted_risks.md
```

## Bootstrap a new project

1. **Copy** `METHODOLOGY.md`, `CLAUDE.md`, `AGENTS.md`, `.claude/`, `scripts/`, and `docs/`
   into the new repo's root.
2. **Fill in the Stack profile** in `CLAUDE.md` — the build / type-check / test / lint / run
   commands. This is the *only* project-specific wiring; every template references these as
   placeholders (`<type-check>`, `<test>`, …).
3. Fill in `CLAUDE.md`'s **Architecture** and **Gotchas** as you learn the codebase.
4. Make sure `git-claude` / `git-codex` are on `PATH` (or note the opt-out in `CLAUDE.md` for
   a Claude-only project).
5. Start a doc: copy a template from `docs/templates/` into `docs/inprogress/`.

## Opt-outs

- **Claude-only** (no Codex): keep the docs + review discipline; drop `agent:codex` /
  `git-codex`. Note it at the top of `CLAUDE.md`.
- **No GitHub issues**: the in-doc Tracker checklist is a complete burndown on its own; skip
  `plan-to-issues`.
