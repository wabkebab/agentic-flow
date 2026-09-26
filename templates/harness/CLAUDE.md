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
- **Execute — Codex.** Implements the issues, recording each step's commit as a comment on
  its issue. Commits with `git-codex`. See `AGENTS.md`.
- **Review — OpenCode.** The independent per-step review: reads the commit Codex recorded
  against the brief, then either returns findings to Codex or records an approving verdict
  and closes the step issue. Commits review notes with `git-opencode`. See `METHODOLOGY.md`
  §1 and the label pairs in §6.
- **Own / merge / deploy — the human.** Approves plans, merges PRs, controls all pushes.

**Exactly one role reviews.** An opt-out reassigns the review; it never leaves it to both.

<!-- OPT-OUT: state any opt-out here, e.g.:
     "Claude-only: no Codex executor and no OpenCode reviewer; Claude plans, executes, and
      reviews with /code-review. Drop the agent:codex / agent:opencode labels; keep the doc
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
> **Assess the stack before you wire it up** (`METHODOLOGY.md` §9). Read the manifests,
> lockfiles, and installed toolchain versions to see what this project actually runs; check
> current stable/LTS releases from release notes, changelogs, and official docs — *not*
> training-data recall, which skews stale. Install a modern version by default; record any
> deliberate deviation (peer-dependency ceiling, platform constraint, known-bad release)
> under Gotchas. Pin the versions actually chosen in the manifests, lockfiles, and Makefile
> — not just in prose here.

| Target | What it does on this project | Notes / gotchas |
|--------|------------------------------|-----------------|
| `make check` | harness sanity (prefilled) + <type-check + lint> | the fast gate; **run by the Stop hook** so an agent can't end a turn red |
| `make test` | <full test suite> | |
| `make test-one F=…` | <one targeted test> | |
| `make build` | <production build> | |
| `make run` | <start the app locally> | for `/run` and `/verify` |

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

### Hooks (enforced, not optional)
This project ships `.claude/settings.json` with five hooks that mechanize the contract —
full mechanism and rationale for each in `METHODOLOGY.md` §8:
- **Stop / SubagentStop → `make check`** (`scripts/hooks/check-gate.sh`)
- **PreToolUse(Bash) → block `git add -A` / `.` / `--all`** (`scripts/hooks/block-git-add-all.sh`)
- **PreToolUse(Bash) → block `git push` / `gh pr merge`** (`scripts/hooks/block-push.sh`)
- **PreToolUse(Bash) → scan staged content before a commit** (`scripts/hooks/scan-secrets.sh`)
  — override a false positive with `AGENTIC_ALLOW_SECRET=1` on the commit.
- **PreToolUse(Bash) → require a comment before a step issue's label flips**
  (`scripts/hooks/require-step-comment.sh`) — Claude/Codex only; **OpenCode has no hook
  engine in this stack**, so the reviewer side still relies on
  `.opencode/agent/code-reviewer.md` being followed, not on mechanical enforcement.

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
  to its step issue (the reviewer closes step issues; the trailer is for traceability).
- **Never push** — the human controls pushes and merges.

## Document workflow

- New work → copy the matching template from `docs/templates/` into `docs/inprogress/`.
- Security/Feature docs carry an **inlined implementation brief** (approach + ordered steps
  + DoD + verification commands from the Stack profile — **not code**).
- Approved plan → run the **`plan-to-issues`** skill.
- The reviewer closes each step issue on approval; `agent:claude + needs-closing` lands on
  the **tracking** issue, not the steps. After every step is reviewed, prepare the final
  Status/Tracker, set TRIAGE to Done, move the document to `docs/done/`, update the index,
  and commit that as the last repository edit. The human pushes; CI and a reviewer approve
  the exact PR head. Verify with `scripts/lifecycle-status.sh --doc docs/done/<doc>.md
  --phase close-out --check --verify-evidence`, then close the tracker without another
  repository edit. The human rechecks with `--phase pre-merge` immediately before merge
  (or relies on protected-branch required checks). That phase expects the tracker closed.
  Any edit after approval restarts the external round. Verification is point-in-time and
  does not guard a later merge. A closed step is *reviewed clean*, not *shipped*.
- On done (shipped & verified, or risk accepted) → move the doc to `docs/done/`
  (or `docs/done/security/`); record accepted risks in `docs/accepted_risks.md`.
