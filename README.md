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
METHODOLOGY.md                    the standard: roles, loop, lifecycle, conventions, enforcement
ADOPTION.md                       tool requirements + checklist for exported projects
CLAUDE.md                         planner/reviewer contract + the Stack-profile explainer
AGENTS.md                         executor (Codex) contract + commit format
Makefile                          the Stack profile: make check / test / test-one / build / run
.claude/settings.json             enforced hooks (Stop→make check; block git add -A)
.claude/skills/plan-to-issues/    skill: approved brief → GitHub tracking issue + sub-issues
scripts/export.sh                 copy the standard into a target project (non-destructive)
scripts/plan-to-issues.sh         the deterministic gh/jq driver the skill calls
scripts/docs-index.sh             regenerate docs/README.md's index from TRIAGE headers
scripts/doctor.sh                 adoption checklist / scaffold health check
scripts/self-test.sh              offline regression checks for this scaffold
scripts/hooks/                    the two hook scripts settings.json calls
ROADMAP.md                        planned evolution of the standard (Tier 2 / Tier 3)
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

1. **Export the standard** into the new repo:
   ```bash
   scripts/export.sh /path/to/target-project        # non-destructive; --dry-run to preview
   ```
   It copies the allow-list (METHODOLOGY/CLAUDE/AGENTS/Makefile, `.claude/settings.json`,
   `.claude/skills`, `scripts`, `docs`) and leaves this repo's own meta behind. It never
   clobbers an existing harness file — a differing file is written as `<file>.agentic-new`
   for you to merge (use `--force` to overwrite). (Or copy by hand if you prefer.)
2. **Fill in the `Makefile`** — the `check` / `test` / `test-one` / `build` / `run` recipes.
   This is the *only* project-specific wiring; every template and hook calls these targets.
   Then explain them + their gotchas in `CLAUDE.md`'s **Stack profile** section.
3. Fill in `CLAUDE.md`'s **Architecture** and **Gotchas** as you learn the codebase.
4. Make sure `git-claude` / `git-codex` are on `PATH` (or note the opt-out in `CLAUDE.md` for
   a Claude-only project). The hooks in `.claude/settings.json` are active on copy.
5. Start a doc: copy a template from `docs/templates/` into `docs/inprogress/`, then keep the
   index current with `scripts/docs-index.sh`.
6. Run `scripts/doctor.sh --check` in the target repo before committing the harness. It checks
   required files, hook wiring, required tools, real Make targets, and docs-index freshness.

See [`ADOPTION.md`](ADOPTION.md) for the full checklist.

## Required tools

- **Required:** `bash`, `make`, `git`, `jq`, `gh`.
- **Project wrappers:** `git-claude` and `git-codex` unless the project explicitly opts out.
- **Recommended:** `shellcheck` for stricter shell linting.

For exported projects, `scripts/doctor.sh` is the adoption checklist and can be used in CI.

## Opt-outs

- **Claude-only** (no Codex): keep the docs + review discipline; drop `agent:codex` /
  `git-codex`. Note it at the top of `CLAUDE.md`.
- **No GitHub issues**: the in-doc Tracker checklist is a complete burndown on its own; skip
  `plan-to-issues`.
