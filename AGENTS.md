# AGENTS.md — agentic-flow

> Guidance for the **Execute** role (**Codex** by default). This is the executor's contract.
> The planner/reviewer's file is [`CLAUDE.md`](CLAUDE.md); the full process is in
> [`METHODOLOGY.md`](METHODOLOGY.md). Do not preload the whole methodology by default:
> load this file, the issue, the linked brief step, `CLAUDE.md` Stack profile/Gotchas,
> target code, direct callers/callees, and relevant tests. Route to methodology sections
> only when the brief or a local rule cites them.

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
2. **Branch** as the brief specifies; work one step at a time, in the brief's order. The
   whole brief ships as **one branch and one PR** — each step is one issue and one commit
   on that branch, closed by the reviewer once that step passes review. If the brief instead calls for
   a separate branch/PR per step (unusual — only for a pass too large to hold on one
   branch), follow that explicitly; don't split by default.
3. **Implement** the step. Add the regression test the brief asks for — it must fail against
   the old code and pass after.
4. **Verify** with the project's `make` targets (defined in the `Makefile`; explained in
   `CLAUDE.md` → Stack profile): `make check` and `make test-one F=<the step's focused
   selector>` per step; run the full `make test` at the end. (The Stop hook runs
   `make check` regardless.)
5. **Commit** (see contract below), one logical commit for the step, with `Fixes #N`.
   Then hand the issue to OpenCode review — **comment first, relabel second**:

   ```bash
   gh issue comment <N> --body "Implemented in <sha>.
   <what changed; anything the reviewer should look at first>

   Verification: <commands run, with results>"

   gh issue edit <N> --add-label "agent:opencode,needs-review" \
                     --remove-label "agent:codex,needs-execution"
   ```

   The comment is not optional: without it the reviewer re-derives the step's commit from
   `git log`, and close-out does it again later. Name the real sha(s) and only verification
   you actually ran. The **reviewer** closes the issue on approval — do not close it
   yourself, and do not expect the merge to.
6. **Don't** refactor adjacent code, bundle steps, or expand scope. If the brief is wrong or
   underspecified, stop and flag it rather than guessing.

## Engineering standards (METHODOLOGY.md §11)

Non-negotiable while implementing a step. These are the rules a reviewer would otherwise
have to catch by hand:

- **Validate external input at the boundary, once** — parse into a validated type at the
  edge; interior code trusts its inputs. Scattered defensive checks are the anti-pattern.
- **Never build strings that get interpreted** — parameterized queries, argument arrays for
  subprocesses, no concatenated HTML or paths.
- **Deny by default at a chokepoint** — authorization in middleware/decorator, not per
  handler. Per-handler means one eventually gets missed, silently.
- **Secrets from config, never literals** — including in tests, including "temporarily".
  A commit hook enforces this; do not work around it without saying why.
- **No unbounded anything** — every query has a limit, every loop over external data a cap,
  every outbound request a timeout.
- **Test the failure path first** — timeout, malformed, unauthorized. A step whose tests
  only cover success is not done.

If the brief conflicts with any of these, stop and flag it — do not silently pick one.

## Commit contract (Codex)

- Commit with **`git-codex`** (signs with the Codex key).
- **Stage files by name** — never `git add -A` / `git add .`.
- **One logical commit per step.** Don't bundle multiple steps into one commit.
- **Verbose, *why*-first commit body** — name the problem, the approach, the blast radius.
  A reviewer should understand the change from the message alone. This is the rule most
  often missed; an example follows.
- **`Fixes #N`** links the commit to its step issue. The reviewer does the closing; keep the
  trailer for traceability.
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
