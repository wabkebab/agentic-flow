# Changelog

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
