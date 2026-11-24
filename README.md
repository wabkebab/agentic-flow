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
The [workflow explainer](docs/agentic-flow-explained.html) follows a plan from start through cleanup.

## What's in here

```
README.md                         this file
METHODOLOGY.md                    the standard: roles, loop, lifecycle, conventions, enforcement
ADOPTION.md                       init.sh usage, flags, and verification notes
CLAUDE.md                         planner/reviewer contract + the Stack-profile explainer
AGENTS.md                         executor (Codex) contract + commit format
Makefile                          the Stack profile: make check / test / test-one / build / run
.claude/settings.json             Claude deny rules and Stop / SubagentStop / SessionStart hooks
.claude/skills/plan-to-issues/    skill: approved brief → GitHub tracking issue + sub-issues
.codex/hooks.json                 Codex lifecycle hooks and attached Git-directory guard
.agents/skills/plan-to-issues/    Codex skill mirror
config/payload.tsv                canonical source→destination export manifest
config/command-policy.tsv         source of native deny rules for Claude Code, Codex, and OpenCode
profiles/                         data-only generic / Node / Python / Go / Rust stack profiles
scripts/export.sh                 copy the standard into a target project (non-destructive)
scripts/init.sh                   one-command scaffold adoption; wraps export + token fill + doctor
scripts/plan-to-issues.sh         the deterministic gh/jq driver the skill calls
scripts/docs-index.sh             regenerate docs/README.md's index from TRIAGE headers
scripts/check-payload-manifest.sh  reject unclassified adapter/template/profile files
scripts/lifecycle-status.sh       derive ACTIVE / READY / BLOCKED / UNVERIFIED / LEGACY document state
scripts/doctor.sh                 adoption checklist / scaffold health check
scripts/agentic-flow              adopted-project status / diff / upgrade command
scripts/self-test.sh              offline regression checks for this scaffold
scripts/hooks/                    agent hooks and legacy upgrade fallbacks
scripts/git-hooks/pre-commit      staged-secret scan for Git commits
templates/harness/                pristine CLAUDE/AGENTS/Makefile forms shipped by export.sh
ROADMAP.md                        open scaffold work and pending decisions
docs/
├── README.md                     docs index + naming conventions
├── accepted_risks.md             living register of accepted risks / declined features
├── backlog/  inprogress/         lifecycle stages
├── done/  done/security/         completed (security closes under done/security)
└── templates/                    the forms — copy out, don't edit in place
    ├── security-review.md        analysis + inlined implementation brief
    ├── feature-analysis.md       analysis + inlined implementation brief
    ├── product-analysis.md       decision record (no implementation brief)
    ├── review.md                 post-execution findings, evidence, and verdict
    └── accepted-risk-entry.md    one block for accepted_risks.md
```

## Bootstrap a new project

Run `init.sh` from this scaffold repo:

```bash
scripts/init.sh /path/to/target-project --name my-project --stack node --yes
```

It copies the allow-list, fills the project name, preserves differing existing files as
`<file>.agentic-new`, applies the requested stack/opt-out flags, writes the scaffold version
stamp (`<semver>+<sha>` from [`VERSION`](VERSION) plus the exact commit — see `ADOPTION.md`),
and prints the doctor report. In a Git checkout it sets an unset `core.hooksPath` to
`scripts/git-hooks` so Git scans staged secrets before each commit. If you use a custom
hooks path, chain `scripts/git-hooks/pre-commit` from your existing pre-commit hook.

Stack profiles are `generic`, `node`, `python`, `go`, and `rust`; `none` remains an alias
for `generic`. Detection proposes a profile from project manifests but never overrides an
explicit flag. Use `--claude-only` for projects that opt out of Codex execution and omit
`--yes` in a terminal for prompts. `scripts/export.sh` remains the source-repository,
low-level non-destructive copy command for manual or unusual adoptions.

Install the native rules for interactive Codex, then run `scripts/doctor.sh --check`.
Fill in `CLAUDE.md`'s **Architecture** and **Gotchas** as you learn the codebase,
start a doc from `docs/templates/`, and keep the index current with `scripts/docs-index.sh`.

See [`ADOPTION.md`](ADOPTION.md) for flags and verification.

## Upgrade an adopted project

Fresh adoptions record the standard's origin in `.agentic-flow-source`. From inside an
adopted project:

```bash
scripts/agentic-flow status
scripts/agentic-flow diff
scripts/agentic-flow upgrade --yes
```

`status` is offline and read-only. `diff` and `upgrade` fetch the recorded source/ref into a
temporary cache. `diff` is read-only. `upgrade` keeps customized files whose upstream
version is unchanged and uses `.agentic-new` candidates when both sides changed. It
also activates the native rules and verifies the Git pre-commit scan before retiring
the corresponding legacy hook entries. Follow the [upgrade instructions](ADOPTION.md#upgrading).

## Answer a station's question

When a station stops with an `ask`, the controller raises andon on the step's issue.
Answer it from the plan worktree:

```bash
scripts/agentic-flow handoff <issue> resume --as approver --body-file <note>
```

The step returns to the station that asked. Its next packet includes the question and
your note under "Owner decision", so the station acts on the answer instead of asking
again. Only that station's latest ask since the last submit is carried, so a reviewer's
question stays with the reviewer. A long exchange is clipped in the packet, and the full
text is delivered as `decision.md` in the station's scratch directory.

## Resume shipping

Run `scripts/agentic-flow ship <doc> --wait-review` from the plan worktree. A re-run
reuses a passing `make ship-gate` record for the same tree, gate inputs, and harness
version. It skips pushing when the destination branch is confirmed at the current
head. Use `--force-gate` to rerun the optional gate.

## Required tools

- **Required:** `bash`, `make`, `git`, `jq`, `gh`.
- **Project wrappers:** `git-claude` and `git-codex` unless the project explicitly opts out.
- **Required:** `shellcheck` — `make test` lints `scripts/` with it and fails if it is absent.
- **Required:** `gitleaks` — one of the two layers in the staged-secret commit hook.

For adopted projects, `scripts/doctor.sh` is the verifier and can be used in CI.

## Opt-outs

- **Claude-only** (no Codex): keep the docs + review discipline; configure the role policy (METHODOLOGY.md §6) and omit
  `git-codex`. Note it at the top of `CLAUDE.md`.
- **No GitHub issues**: the in-doc Tracker checklist is a complete burndown on its own; skip
  `plan-to-issues`.
