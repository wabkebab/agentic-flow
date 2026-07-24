# CLAUDE.md — agentic-flow

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

## Stack profile

> **The whole methodology depends on this.** The actual commands live in the
> [`Makefile`](Makefile) — the one executable source of truth that humans, agents, hooks,
> and CI all call. This section just *explains* the
> targets and records the gotchas, so prose can't drift from what actually runs.

| Target | What it does on this project | Notes / gotchas |
|--------|------------------------------|-----------------|
| `make check` | Bash syntax for shipped scripts, docs index freshness, and `scripts/self-test.sh` | the fast gate; **run by the Stop hook** so an agent can't end a turn red |
| `make test` | full offline scaffold regression suite, plus `shellcheck` over `scripts/` when installed | no network or GitHub writes |
| `make test-one F=…` | same offline suite; this harness has no finer-grained test runner yet | accepts `F` for interface compatibility and prints it |
| `make build` | dry-run export into a temporary directory | validates the payload assembles without writing a real target |
| `make run` | `scripts/doctor.sh` report mode | the scaffold's "app" is its adoption report |

- **Languages / runtimes:** POSIX-ish shell with Bash 3.2 compatibility for shipped scripts.
- **Package / build layout:** single scaffold repo; reusable payload lives in scripts,
  docs skeleton, hooks, and `templates/harness/`.
- **CI gate:** `make check && make test`.
- **`check` gotchas:** `scripts/self-test.sh` mutates root `CLAUDE.md` briefly to prove
  exports come from `templates/harness/`; do not run multiple self-tests in parallel.

## Required local tools

- **Required for the scaffold:** `bash`, `make`, `git`, `jq`, `gh`.
- **Required unless opted out:** `git-claude` for planner/reviewer commits and `git-codex`
  for executor commits.
- **Recommended:** `shellcheck`.
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

## Architecture (orient an agent fast)

`scripts/export.sh` copies the allow-listed scaffold payload into a target project.
Pristine root harness files are sourced from `templates/harness/`, while this repo's root
`CLAUDE.md`, `AGENTS.md`, and `Makefile` are its own filled-in instance. `scripts/doctor.sh`
reports adoption gaps, `scripts/self-test.sh` covers offline regressions, and the hooks in
`scripts/hooks/` enforce the local stop gate, named staging, and no-push contract.

## Gotchas (the top traps)

- Contract changes to `CLAUDE.md`, `AGENTS.md`, or `Makefile` usually need matching edits
  in both the repo-root instance and `templates/harness/`.
- Keep scripts Bash 3.2 compatible for macOS: no `mapfile`, no associative arrays, and be
  careful with empty arrays under `set -u`.
- `export.sh --help` prints a fixed `sed -n` header range; update that range when changing
  the help comment.
- The Stop hook runs `make check`, which runs `self-test.sh`; export behavior and its tests
  need to stay consistent within the same commit.
- `init.sh`/`doctor.sh`/`self-test.sh` scan exported files for unfilled placeholders and
  must agree on the pattern. They build it with `printf` so the scripts never contain a
  literal placeholder that would self-match — keep that trick when editing, comments
  included. The pattern is deliberately narrow (double-brace UPPER_SNAKE) so shipped docs
  can quote GitHub Actions `dollar-brace` expressions without tripping it.

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
