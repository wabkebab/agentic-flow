# AGENTS.md — <project name>

> Guidance for the **Execute** role (**Codex** by default). This is the executor's contract.
> The planner/reviewer's file is [`CLAUDE.md`](CLAUDE.md); the full process is in
> [`METHODOLOGY.md`](METHODOLOGY.md). When in doubt about the stack, read `CLAUDE.md` —
> its **Stack profile** and **Gotchas** are authoritative.

## Your job

Implement the GitHub issues generated from an approved plan. Each issue is one
**independently-shippable step** taken from the **implementation brief** inside a Security
or Feature doc (`docs/inprogress/<doc>.md`). The brief contains the *approach* — files,
order, edge cases — not finished code. Read the brief for the step before writing code.

## Required local tools

- Required for this harness: `bash`, `make`, `git`, `jq`, `gh`.
- Required for Codex execution unless the project opts out: `git-codex`.
- Run `scripts/doctor.sh --check` if the scaffold was just adopted or hook/build wiring looks
  suspicious.

## How to work a step

1. **Read the implementation brief** for the issue (linked from the issue / tracking issue).
   It gives the problem, the approach, the regression test to add, and the Definition of Done.
2. **Branch** as the brief specifies; work one step at a time, in the brief's order.
3. **Implement** the step. Add the regression test the brief asks for — it must fail against
   the old code and pass after.
4. **Verify** with the project's `make` targets (defined in the `Makefile`; explained in
   `CLAUDE.md` → Stack profile): `make check` and `make test-one F=<the step's test>` per
   step; run the full `make test` at the end. (The Stop hook runs `make check` regardless.)
5. **Commit** (see contract below), one logical commit for the step, with `Fixes #N`.
6. **Don't** refactor adjacent code, bundle steps, or expand scope. If the brief is wrong or
   underspecified, stop and flag it rather than guessing.

## Commit contract (Codex)

- Commit with **`git-codex`** (signs with the Codex key).
- **Stage files by name** — never `git add -A` / `git add .`.
- **One logical commit per step.** Don't bundle multiple steps into one commit.
- **Verbose, *why*-first commit body** — name the problem, the approach, the blast radius.
  A reviewer should understand the change from the message alone. This is the rule most
  often missed; an example follows.
- **`Fixes #N`** so the PR merge closes the issue.
- **Never push** — the human controls pushes and merges.

Example:

```
Require admin for bulk delete on kdms, cpls, and certs

The CRUD factory registered DELETE / with no role check, so any
authenticated user could wipe all KDMs/CPLs/certs in one request.
Add an optional bulk-delete middleware to the factory and opt these
three routers into requireAdmin; per-row deletes are unchanged.

Adds a regression test asserting 403 for role:user and 200 for admin.

Fixes #71
```

(`git-codex` appends `Co-Authored-By: Codex <noreply@openai.com>` automatically when the
message doesn't already carry a `Co-Authored-By:` trailer — don't hand-maintain it.)

<!-- OPT-OUT: if this project is Claude-only, there is no Codex executor and this file is
     informational only. -->
