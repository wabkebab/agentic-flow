# Changelog

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
