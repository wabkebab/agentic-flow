# Changelog

## 0.16.0

Line controller, phase 2 (tracker #138). A local controller starts each LLM station
headless from the journal, so the human approves the plan, ships and answers andon
calls instead of relaying output between stations.

- `agentic-flow run <doc> [--once]` owns the plan worktree and branch, starts the
  executor and reviewer headless, checks each verdict against a schema, resumes a
  station's own session after a bounce, and recovers from the journal and run ledger
  after a crash. Anything it cannot recover is raised as andon, never guessed at.
- Station assignment lives in `config/roles.tsv`, with operator and project overrides
  in `.agentic-flow-roles`; inspect or change it with `agentic-flow roles`.
- `agentic-flow ship <doc>` pushes, opens the PR, waits for CI and the final-head
  approval, then runs close-out. `final-approve` is the reviewer's approval of the
  final head; `ship` exits 11 until it exists when the close-out delta is not
  bookkeeping only. `approve` records plan approval and `hold clear` releases a hold.
- `handoff` gains `ask` and `resume`: a station's open question moves the issue to
  `escalated` with the question as evidence and notifies the owner. `resume` returns
  to the state the issue left, `reviewing` after a reviewer's question.
- `agentic-flow metrics` reports lead time, bounces, first-pass yield and tokens per
  step from the run ledger.
- Stations launch without GitHub credentials, in isolated groups, behind an entry gate
  that refuses to run when the profile or identities are missing. The Codex station
  profile is installed from `config/stations/`. The `opencode-station-network`
  accepted risk (`docs/accepted_risks.md`) records OpenCode's remaining network access.
- The role contracts now route to the controller, ship and andon; `METHODOLOGY.md`
  no longer describes a person starting each station.

Migration: run `scripts/agentic-flow upgrade` and merge `CLAUDE.md`, `AGENTS.md`,
`Makefile` and `.claude/settings.json` by hand. Add `owner=<login>` to
`.agentic-flow-review-policy`. Run `agentic-flow roles` and confirm each station's CLI,
install the Codex station profile, and read the `opencode-station-network` risk before
enabling unattended runs. Without App identities and installed profiles, keep using
`run --once` with the gate.

## 0.15.0

Deterministic stations, phase 1 (tracker #124). Each mechanical station is a command
with one workflow definition, a journal it can recover from, and trusted inputs.

- `config/workflow.tsv` defines states, transitions and labels once. `render-shared.sh`
  renders them into `METHODOLOGY.md` section 6, and `make check` fails when the render
  is stale. Role contracts route to the station commands instead of restating states.
- `agentic-flow handoff` is the only way for agents to move a workflow issue. It journals
  each transition on the thread and is idempotent and race-safe. Raw workflow label
  edits are now blocked for agents by the hook.
- `plan-to-issues --doc` reads the approved brief, and plan approval authorizes apply.
  The new `needs-human` label (bounce-cap escalation) is created by `create-tags`.
- `agentic-flow brief` and `packet` give a role one step, built from the approved brief
  and policy-authored comments only. A `SessionStart` hook in `.claude/settings.json`
  injects the cached step context.
- `agentic-flow verify-step` verifies a step in a clean detached worktree and records
  the run. Profiles gain a `verify-prepare` row. Red-first: a non-zero exit with the
  assertion signature is red, except timeout 124 and interrupts 130/143, which are
  invalid. Exit 0 is green; missing or mismatched signatures are invalid.
- `agentic-flow close-out prep|finish` scripts close-out and attests the final head when
  its delta is bookkeeping only.
- GitHub App identities and per-role tokens are supported (`agentic-flow token`).

Migration: run `scripts/agentic-flow upgrade`, merge `CLAUDE.md`, `AGENTS.md`, `Makefile`
and `.claude/settings.json` by hand, add the `verify-prepare` profile row, and run
`scripts/create-tags.sh`. Use `handoff` for every workflow move from now on.

## 0.14.0

Gate and handoff fixes before publishing (tracker #114).

- Accept review evidence and step handoffs only from logins listed in
  `.agentic-flow-review-policy`, in both identity modes. Comments from
  anyone else are counted and ignored by `lifecycle-status.sh` and
  `require-step-comment.sh`; "Implemented in" handoffs count only from
  executor logins. `init.sh --owner-login <login>` fills the policy.
- Close-out blocks when an approved step commit is not an ancestor of the
  PR head (an amended or rebased approval). Missing objects and shallow
  history report UNVERIFIED with the fetch to run.
- The Stop gate no longer skips a clean tree. It hashes the full state,
  including `HEAD^{tree}`, stamps only a state that stayed unchanged
  across a green run, reruns once when the tree changed during the run,
  and keeps a separate acknowledged-red record for loop safety.
- The push, staged-secret and broad-staging guard hooks block the call
  when the hook fails or times out (`onFailure: "block"`); doctor
  enforces it.
- `make check` in an adopted project without `.agentic-flow-installation`
  walks installed destinations instead of failing on scaffold sources
  (#109's gate failure; the upgrader still does not write the record).
- The reviewer and closer contracts remove workflow labels after closing
  an issue, and `plan-to-issues.sh` does the same for a removed step.
  `METHODOLOGY.md` now states who closes which issue.

**Migration (both files are preserve payload; merge the candidates):**

- `.agentic-flow-review-policy` now requires at least one `reviewer=`,
  `executor=` and `approver=` login, including in single-operator mode,
  where one login may hold all three. Until you add them, doctor fails,
  the step-comment hook blocks relabels with a named message, and
  lifecycle evidence is UNVERIFIED. See `ADOPTION.md`.
- `.claude/settings.json` adds `"onFailure": "block"` to the
  `block-git-add-all`, `block-push` and `scan-secrets` handlers; doctor
  fails without it. Claude Code enforces the field from v2.1.295; older
  versions ignore it, so those guards stay fail-open there. Codex hooks
  have no equivalent and stay fail-open
  (`docs/accepted_risks.md#codex-guard-fail-open`).
- Review fixes land as new commits. Amending an approved step commit now
  blocks close-out until it is re-reviewed.

## 0.13.3

- Reduce false blocks in the push, broad-staging, and staged-secret hooks:
  unparseable commands now require the relevant protected operation rather
  than any mention of Git or GitHub CLI. Unparseable commits retain the
  push hook's fail-closed control from issue #110.
- Treat quoted-delimiter heredoc bodies as literal data, including `<<-`
  variants, while still checking commands after the closing delimiter.
- Return exit 0 instead of hook-error exit 1 for unparseable commands with
  no relevant protected operation.
