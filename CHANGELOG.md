# Changelog

## 0.21.0

- `plan-to-issues --doc` accepts repeatable `--adopt <step-id>=<number>` mappings
  for existing open issues, including `tracker` on Strict plans. It checks all mappings
  before applying and retains adopted titles, handwritten text, and live labels across
  reapply.

## 0.20.0

Harness simplification, Phase 4.

- Claude Code, Codex, and OpenCode use native deny rules generated from
  `config/command-policy.tsv`. Claude and Codex keep the Stop gate and SessionStart
  context. Codex keeps a focused guard for the attached Git-directory option.
- Git runs the staged-secret scan at pre-commit for human, agent, and scripted commits.
  Upgrade verifies the replacement guards before retiring the corresponding legacy
  agent hook entries.
- `ship` reuses a passing gate record for the same tree, gate inputs, and harness
  version. It skips a push when it confirms the destination branch already has the
  exact head. `--force-gate` invalidates the matching record and runs the gate again.
- Upgrade keeps local customizations when upstream is unchanged and creates merge
  candidates when both sides changed.
- New briefs start Part B with acceptance scenarios and cap it at 1,500 words plus
  500 per step. Red-first verification runs when the step names a selector.
  Stack assessment, CI/CD, and engineering standards now live in reference docs.

After `scripts/agentic-flow upgrade`, resolve any merge candidates, install or refresh
the native rules for interactive Codex, and run `scripts/doctor.sh --check`.
If you use a custom `core.hooksPath`, chain the scaffold's pre-commit hook
from your existing hook. [Adoption and verification](ADOPTION.md#verify)

## 0.19.0

Flow ergonomics before Phase 4 (tracker #175).

- `agentic-flow start` creates a plan branch, linked worktree, and prefilled Feature or
  Security draft. Draft, approve, issue, and run the plan from that worktree. After a
  merge that preserves the plan's history, `agentic-flow clean` removes the worktree and
  local branch.
- Journal comments, plan and step issues, and PR bodies render as readable Markdown.
  Journal readers accept both the original plain-text markers and the hidden markers
  used by the new comments.
- For new PRs, `ship` prepares and commits close-out before its first push. CI and the
  reviewer's final approval verify the pushed head. The prepared doc resolves its PR
  from that approval.
- CI skips App checks for bookkeeping-only changes. Other changes can reuse a green
  App result for identical tracked App inputs on the PR merge checkout. CI reports
  the source run and still checks the current head.

Migration. Run `scripts/agentic-flow upgrade` and merge the contract and CI template
changes into your customized files. Existing markers and `Implementation PR: url=…`
documents continue to work. Plans with an open PR finish on the existing two-push path.
Re-run `create-tags` only when workflow labels change. This release keeps the same labels.

## 0.18.0

Test streamlining, phase 3 (tracker #165). Each test group runs once per full suite,
per-step runs are scenario-sized, a group that grows past its budget fails, and
adopters stop running the harness's internal tests on every `make test`.

- Gate cadence: `AGENTS.md`, `CLAUDE.md` and the reviewer skill now say that each step
  runs `make check` and its Verify command, and the plan runs the full `make test`
  once at the end. Under the controller, executors do not run `verify-step`, and
  reviewers run no test by default.
- `make ship-gate` runs `self-test.sh --full --all-groups` in a fresh export. It is
  the only place the exported layout gets full coverage. Everyday `make test` keeps
  the exported `--fast` suite and `make check` and no longer runs the nested full
  suite. `ship` runs `make ship-gate` on the final head before its first push. A
  failing gate stops the push and names the group. A project without the target
  gets a notice and `ship` continues. This repository's CI runs `make test` and
  `make ship-gate` as separate steps.
- Exported `make test` runs the local `contracts` and `hooks` groups. The six
  scaffold groups also run when committed, staged, unstaged or untracked edits
  touch payload-manifest destinations against the integration merge base.
  An unresolved base or Git failure runs every group; a feature branch's own
  upstream is never used as the base. `scripts/self-test.sh --full --all-groups`
  forces every group. In the scaffold source, `--full` still runs every group.
- The shipped CI app job fetches full history and exports
  `AGENTIC_BASE_REF=origin/${{ github.base_ref }}` for PR tests, so a PR's
  changed set uses a real merge base.
- `self-test.sh --full --jobs <n>` (or `AGENTIC_TEST_JOBS`) runs groups and
  controller and stations tag shards as parallel processes. The default is
  `min(shards, CPUs)`. Each shard has its own fixture root and timeout, output is
  replayed in a stable order, and every failed shard is reported. `--jobs 1` is the
  serial order. The 190-copy budget applies to the merged event stream.
- `make test-one F=stations S=launch,packet,verify,handoff` selects stations
  scenarios by tag, with the controller group's rules.
- Wall-time ceilings: `config/test-wall-ceilings.tsv` sets a ceiling in seconds for
  each group and for each controller and stations tag. A whole-group run fails when
  a group exceeds its ceiling. A `--scenario` run fails only on the tags it
  selected. `make check` fails when a group or tag has no row. A ceiling change is
  a reviewed diff to that file.
- Tests: `self-test.sh` is now a dispatcher over `scripts/tests/<group>.sh`. A
  recorded list of assertion messages keeps the split from dropping an assertion.
  An adopter-twin fixture runs upgrade, hooks and `make check` against an export with
  a customized `CLAUDE.md` and `Makefile`. The dispatcher's group imports are linted
  with `source=/dev/null`, which keeps shellcheck under about 2.5 GB.
- `verify-step` records a command that ran past `AGENTIC_VERIFY_TIMEOUT` as exit
  124 even when the command handles TERM and exits with an ordinary status, as GNU
  make does on Linux. Before, only signal exits (137, 143) counted, so a timed-out
  `make` target could be recorded as an ordinary failure. A command that succeeds
  at the deadline still records success.

Migration: run `scripts/agentic-flow upgrade`, then copy two `Makefile` changes from
`templates/harness/Makefile` by hand: the `test-one` recipe (`S=` now accepts
`F=stations`), and, if you want `ship` to run release checks before pushing, the
commented `ship-gate` target with your own command (`scripts/self-test.sh --full
--all-groups` forces every installed harness group). Exported `make test` now skips
the scaffold groups unless a harness file changed, so set `AGENTIC_BASE_REF` where
your CI's integration branch is not found automatically. Merge the new gate-cadence
paragraph into a customized `CLAUDE.md` and `AGENTS.md`.

## 0.17.0

Station hardening, phase 2b (tracker #150). Controller-run stations now fail before
launch instead of mid-step, failures are cheap to diagnose, and a step verifies only
the controller scenarios it touched.

- `agentic-flow doctor --stations [--station executor|reviewer]` probes each station
  CLI through the real launcher in a throwaway worktree: the sandbox boundary, the
  allowed and denied writes, session ids and the result format. An unattended `run`
  probes again only when `launch.sh`, the station profile, the roles row or the CLI
  version changed; `run --once` never probes. A failed probe raises the
  `station-infrastructure` hold and starts no station.
- A station that dies before it starts (non-zero exit, no session, no tokens, under
  5 s) raises the `station-infrastructure` hold instead of costing an approver
  `resume`, and does not count toward the invalid-result cap. Its note carries the exit
  code, the seconds and a redacted stderr tail. A retry after a dead session starts a
  fresh one instead of resuming the session the CLI already rejected.
- `agentic-flow hold clear <doc> <hold-id> --rebaseline` saves a salvage ref and takes
  the new plan-branch HEAD as the baseline, so a fix committed during a pending salvage
  no longer forces a reset. A resumed step keeps the red-first base of its first
  attempt.
- `verify-step` reuses a passing record for the same commit, tree, step, red base,
  command list and verifier digest, and says "reused". `--force` runs it again. The
  reviewer packet carries the record through the same freshness check.
- An invalid station result keeps `events.tail` and `stderr.tail` under the run's
  ledger directory, and the andon comment names the path and the reason.
- Verdict format: a CLI that cannot enforce the result schema (OpenCode) is told to end
  with only the result JSON. The stated limits are 2000 characters for `summary` and
  1200 for a question or finding. Longer text up to 8000 and 4000 is accepted with a
  recorded warning; a refused result names the rule and the measured value.
- `metrics` reports known token usage with a count of the runs whose usage is unknown,
  and `run` no longer repairs the hold projection when it is already correct.
- Tests: `make test-one F=controller S=launch,ledger,recovery,ship,andon` selects
  controller scenarios by tag, and `AGENTIC_TEST_TIMING=1` prints per-block and
  slowest-call timings. The full-mode copy budget no longer counts the source snapshot;
  its limit is 190 test copies, and a failure prints the count. A full `make test`
  takes about 80 minutes.

Migration: run `scripts/agentic-flow upgrade` and copy the `test-one` recipe (`S=`)
from `templates/harness/Makefile` into your `Makefile` by hand. Run
`agentic-flow doctor --stations` once on the operator machine against the real CLIs
before the next unattended `run`. The reviewer contract now names both verifier files
(`verify-step.sh` and `verify-record.sh`) in the freshness digest.

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
