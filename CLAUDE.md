# CLAUDE.md — agentic-flow

> Project guidance for Claude (the **Plan / Review** role). Override-authoritative: these
> instructions win over defaults. Keep this dense and gotcha-rich — it is the source of
> truth an agent reads first.
>
> This project follows the standard in [`METHODOLOGY.md`](METHODOLOGY.md). Load this file
> first, then route to specific methodology sections as needed; do not preload the whole
> methodology for routine planning, review, or close-out. The executor's mirror of this
> file is [`AGENTS.md`](AGENTS.md).

---

## Roles on this project

- **Plan / Review — Claude** (you). Write Security / Feature / Product-Analysis docs in
  `docs/`, inline the implementation brief, generate issues with `plan-to-issues`, review
  execution commits, fix or delegate fixes. For planning, load the chosen template, relevant
  live code/tests, and only the methodology section the task needs. For close-out, load the
  Tracker/Status, step issue states, review verdicts, CI evidence, and lifecycle output.
  Commit with `git-claude`.
- **Execute — Codex.** Implements the issues. Commits with `git-codex`. See `AGENTS.md`.
- **Review — OpenCode.** Human-operated today, or via the `/review` command
  (`.opencode/agent/code-reviewer.md`) / the `review-execution` skill
  (`.opencode/skills/review-execution/SKILL.md`) when OpenCode itself is available as an
  agent. Reviews each completed Codex step by reading the diff against the implementation
  brief, then either records findings as an issue comment and sends the step back to Codex,
  or marks it ready for Claude close-out. Commits any review-note changes with `git-opencode`.
- **Own / merge / deploy — the human.** Approves plans, merges PRs, controls all pushes.

### Step issue label state machine

Step issues move by label pair:

```
agent:codex + needs-execution          (plan-to-issues default)
      │  Codex finishes the step, commits with Fixes #N
      ▼
agent:opencode + needs-review
      │  OpenCode (human) reviews
      ├─ findings noted as an issue comment ──▶ agent:codex + needs-execution
      │                                           (loop; capped at 2 findings returns)
      └─ no findings ──────────────────────────▶ agent:claude + needs-closing
                                                      │
                                                      ▼
                                      Claude updates doc Tracker/Status,
                                      moves doc to docs/done/ if complete.
                                      Human still owns the actual merge/close.
```

After OpenCode sends a step back with findings twice, a third return escalates to the human
explicitly instead of sending it back to Codex again or silently stopping.

Close-out is batched at the plan level: reviewed steps may sit at
`agent:claude + needs-closing` until all steps are reviewed. Then do one close-out pass that
ticks the Tracker, records review and CI evidence, runs
`scripts/lifecycle-status.sh --check --verify-evidence`, and moves the doc only when every
step qualifies.

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
| `make check` | Bash syntax for shipped scripts, docs index freshness, action-pin structure, and `scripts/self-test.sh` | the fast gate; **run by the Stop hook** so an agent can't end a turn red |
| `make test` | full offline scaffold regression suite, plus `shellcheck` over `scripts/` | no network or GitHub writes; **fails if `shellcheck` is missing** rather than skipping |
| `make test-one F=…` | one focused harness group (`export`, `contracts`, `hooks`, `plan-to-issues`, or `lifecycle`) | the Makefile owns exact behavior |
| `make build` | dry-run export into a temporary directory | validates the payload assembles without writing a real target |
| `make run` | `scripts/doctor.sh` report mode | the scaffold's "app" is its adoption report |

- **Languages / runtimes:** POSIX-ish shell with Bash 3.2 compatibility for shipped scripts.
- **Package / build layout:** single scaffold repo; reusable payload lives in scripts,
  docs skeleton, hooks, and `templates/harness/`.
- **CI gate:** `make check && make test`.
- **`check` gotchas:** the regression suite copies the current checkout into unique
  temporary fixtures, so concurrent checks are supported and must leave the source clean.

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

`scripts/export.sh` copies the manifest-declared scaffold payload into a target project.
Pristine root harness files are sourced from `templates/harness/`, while this repo's root
`CLAUDE.md`, `AGENTS.md`, and `Makefile` are its own filled-in instance. Data-only files in
`profiles/` render stack-specific Make recipes. `scripts/doctor.sh` reports adoption gaps,
`scripts/self-test.sh` covers offline regressions, and the hooks in `scripts/hooks/`
enforce the local stop gate, named staging, and no-push contract.

## Gotchas (the top traps)

- Contract changes to `CLAUDE.md`, `AGENTS.md`, or `Makefile` usually need matching edits
  in both the repo-root instance and `templates/harness/`.
- Payload membership belongs in `config/payload.tsv`; do not add another file list to
  export, doctor, or tests.
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
  can quote GitHub Actions `dollar-brace` expressions without tripping it. `make check`
  asserts the local assignments stay byte-identical.
- **Same rule for anything credential-shaped.** `scan-secrets.sh` reads the staged diff, so
  a real-looking key or a quoted `password = "…"` written literally into any file — hook
  patterns, test fixtures, docs examples — blocks every commit that touches that file.
  Assemble them with `printf` (see the fixtures in `self-test.sh`). Both scripts learned
  this the hard way; the pattern set is written split for exactly this reason.

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
