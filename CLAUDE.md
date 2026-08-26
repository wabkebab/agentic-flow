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
  Tracker/Status, step issue states, the reviewer's verdict comments, CI evidence, and
  lifecycle output — then close the tracking issue. Commit with `git-claude`.
- **Execute — Codex.** Implements the issues. Commits with `git-codex`. See `AGENTS.md`.
- **Review — OpenCode.** Human-operated today, or via `/review`
  (`.opencode/agent/code-reviewer.md`) / the `review-execution` skill when OpenCode is
  available as an agent. Reviews each Codex step against the brief; the state machine below
  is the contract. Commits review notes with `git-opencode`.
- **Own / merge / deploy — the human.** Approves plans, merges PRs, controls all pushes.

### Step issue label state machine

Step issues move by label pair:

```
agent:codex + needs-execution          (plan-to-issues default)
      │  Codex commits with Fixes #N, then comments the sha +
      │  the verification it ran on the step issue
      ▼
agent:opencode + needs-review
      │  OpenCode reviews that commit against the brief
      ├─ findings noted as an issue comment ──▶ agent:codex + needs-execution
      │                                           (loop; capped at 2 findings returns)
      └─ approved ──▶ comments the verdict, then CLOSES the step issue.
                      On the last open step, also sets the TRACKING issue to
                      agent:claude + needs-closing and leaves it open.
                                  │
                                  ▼
                  Claude ticks the Tracker, updates Status with review and CI
                  evidence, moves the doc to docs/done/, then closes the
                  tracking issue. The human still owns the PR merge.
```

After two findings returns, a third escalates to the human instead of returning it to Codex
again or silently stopping.

**Step issues never reach `needs-closing`** — the reviewer closes them, so that pair lives
only on the tracker. A closed step means *reviewed clean*, not *shipped*; the doc's Status
block plus CI evidence is the shipping record (`METHODOLOGY.md` §2).

Close-out is batched: closed steps accumulate while the tracker stays open. Then one pass
ticks the Tracker, records review and CI evidence, runs
`scripts/lifecycle-status.sh --check --verify-evidence`, moves the doc, and closes the
tracker — only when every step qualifies. Confirm the steps are actually closed; the tracker
label is a notification, not the authority.

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
| `make test-one F=…` | one focused harness group (`export`, `contracts`, `hooks`, `plan-to-issues`, `lifecycle`, or `upgrade`) | the Makefile owns exact behavior |
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
This project ships `.claude/settings.json` with five hooks that mechanize the contract —
full mechanism and rationale for each in `METHODOLOGY.md` §8:
- **Stop / SubagentStop → `make check`** (`scripts/hooks/check-gate.sh`)
- **PreToolUse(Bash) → block `git add -A` / `.` / `--all`** (`scripts/hooks/block-git-add-all.sh`)
- **PreToolUse(Bash) → block `git push` / `gh pr merge`** (`scripts/hooks/block-push.sh`)
- **PreToolUse(Bash) → scan staged content before a commit** (`scripts/hooks/scan-secrets.sh`)
  — override a false positive with `AGENTIC_ALLOW_SECRET=1` on the commit.
- **PreToolUse(Bash) → require a comment before a step issue relabels**
  (`scripts/hooks/require-step-comment.sh`) — Claude/Codex only; **OpenCode has no hook
  engine here**, so its side still relies on `.opencode/agent/code-reviewer.md`.

## Architecture (orient an agent fast)

`scripts/export.sh` copies the manifest-declared scaffold payload into a target project.
Pristine root harness files are sourced from `templates/harness/`, while this repo's root
`CLAUDE.md`, `AGENTS.md`, and `Makefile` are its own filled-in instance. Data-only files in
`profiles/` render stack-specific Make recipes. `scripts/doctor.sh` reports adoption gaps,
`scripts/self-test.sh` covers offline regressions, and the hooks in `scripts/hooks/`
enforce the local stop gate, named staging, and no-push contract.

## Gotchas (the top traps)

- A trap worth keeping lives in `docs/memory/` as one file, with a one-line entry in
  `docs/MEMORY.md`. Check that index before re-deriving a trap, and add to it at close-out.
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
- **One logical commit per change.** Verbose, *why*-first body. `Fixes #N` links a commit to
  its step issue — the reviewer does the closing.
- **Never push** — the human controls pushes and merges.

## Document workflow

- New work → copy the matching template from `docs/templates/` into `docs/inprogress/`.
- Security/Feature docs carry an **inlined implementation brief** (approach + ordered steps
  + DoD + verification commands from the Stack profile — **not code**).
- Approved plan → run the **`plan-to-issues`** skill.
- On done (shipped & verified, or risk accepted) → move the doc to `docs/done/`
  (or `docs/done/security/`); record accepted risks in `docs/accepted_risks.md`.
