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
ADOPTION.md                       init.sh usage, flags, and verification notes
CLAUDE.md                         planner/reviewer contract + the Stack-profile explainer
AGENTS.md                         executor (Codex) contract + commit format
Makefile                          the Stack profile: make check / test / test-one / build / run
.claude/settings.json             enforced hooks (Stop→make check; block git add -A; block git push)
.claude/skills/plan-to-issues/    skill: approved brief → GitHub tracking issue + sub-issues
scripts/export.sh                 copy the standard into a target project (non-destructive)
scripts/init.sh                   one-command scaffold adoption; wraps export + token fill + doctor
scripts/plan-to-issues.sh         the deterministic gh/jq driver the skill calls
scripts/docs-index.sh             regenerate docs/README.md's index from TRIAGE headers
scripts/doctor.sh                 adoption checklist / scaffold health check
scripts/self-test.sh              offline regression checks for this scaffold
scripts/hooks/                    the two hook scripts settings.json calls
templates/harness/                pristine CLAUDE/AGENTS/Makefile forms shipped by export.sh
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

Run `init.sh` from this scaffold repo:

```bash
scripts/init.sh /path/to/target-project --name my-project --stack none --yes
```

It copies the allow-list, fills the project name, preserves differing existing files as
`<file>.agentic-new`, applies the requested stack/opt-out flags, writes the scaffold version
stamp, and prints the doctor report. The hooks in `.claude/settings.json` are active on copy.

Use `--stack node` for npm-oriented Makefile recipes, `--claude-only` for projects that opt
out of Codex execution, and omit `--yes` in a terminal for prompts. `scripts/export.sh`
remains the low-level non-destructive copy command for manual or unusual adoptions.

After adoption, fill in `CLAUDE.md`'s **Architecture** and **Gotchas** as you learn the
codebase, start a doc from `docs/templates/`, and keep the index current with
`scripts/docs-index.sh`.

See [`ADOPTION.md`](ADOPTION.md) for flags and verification.

## Required tools

- **Required:** `bash`, `make`, `git`, `jq`, `gh`.
- **Project wrappers:** `git-claude` and `git-codex` unless the project explicitly opts out.
- **Required:** `shellcheck` — `make test` lints `scripts/` with it and fails if it is absent.
- **Required:** `gitleaks` — one of the two layers in the staged-secret commit hook.

For adopted projects, `scripts/doctor.sh` is the verifier and can be used in CI.

## Opt-outs

- **Claude-only** (no Codex): keep the docs + review discipline; drop `agent:codex` /
  `git-codex`. Note it at the top of `CLAUDE.md`.
- **No GitHub issues**: the in-doc Tracker checklist is a complete burndown on its own; skip
  `plan-to-issues`.
