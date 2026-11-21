# Accepted Risks & Declined Features

This file records findings and proposals that were reviewed and **intentionally accepted or
declined** rather than implemented. It is the durable answer to "why didn't we fix/build
that?" — and the place a future reader checks before re-opening a closed decision.

Each entry should be revisited if the deployment model, threat model, scale, or product
direction changes. Use `docs/templates/accepted-risk-entry.md` to add a new block.

<!-- Append accepted-risk / declined-feature blocks below, newest first. -->

<a id="flow-parallel-app-jobs"></a>
## fe-1 — Parallel App jobs deferred until CI is stable

**Status:** Declined feature
**Decision date:** 2026-11-20
**Decided by:** Human owner, when approving the flow-ergonomics brief
**Tracking:** docs/done/feature-flow-ergonomics.md; tracker #175

### Finding / proposal
The App job runs the test suite (about 16 minutes) and the exported-layout check (about
13.5 minutes) one after the other, so a green run takes about 30 minutes. Splitting them into
parallel jobs would roughly halve the wait.

### Proposed mitigation / implementation
Two App jobs with `ci-gate` requiring both. 0.19.0 instead cuts the number of App runs per plan
(one push, bookkeeping filter, App-result carry-forward).

### Acceptance rationale
CI has been unstable (runner kills, shellcheck memory), and a parallel split adds a new place
for it to fail. The owner chose to wait until CI is stable and before the repo goes public.

### Revisit if
- CI stays green for several plans in a row.
- The repo is about to go public.
- A single App run grows well beyond 30 minutes.

<a id="phase2b-closes-on-phase3-pr"></a>
## h-12 — Phase 2b ships and closes on Phase 3's PR #174

**Status:** Accepted risk
**Decision date:** 2026-11-20
**Decided by:** Human owner, at the Phase 3 close-out
**Tracking:** docs/done/feature-station-hardening.md; tracker #150; PR #161; PR #174

### Finding / proposal
Phase 2b's PR #161 stays red at `4cfefaa`. `shellcheck -x` followed every `source`
and ran out of memory on the CI runner, and h-12's per-file split did not bound it.
The fix, `7304024`, is on `phase-3` (#173). Phase 2b's brief names branch `phase-2b`,
so `ship` and `final-approve` refuse to run for it on `phase-3` (`scripts/lib/ship.sh`,
branch check).

### Proposed mitigation / implementation
Cherry-pick the fix onto `phase-2b`, get #161 green, and ship Phase 2b alone first, as
Phase 3's Prerequisite planned. The alternative was teaching `ship` to accept a doc
whose Implementation PR is on the current branch, which is a reviewed code change.

### Acceptance rationale
`phase-3` contains every Phase 2b commit, and #174's CI runs the whole suite on them.
#174 merges as a merge commit, not a squash, so GitHub also marks #161 merged. Phase
2b's close-out is prepped on `phase-3` with #174 as its Implementation PR. The reviewer
posts the final-head approval on #150 by hand, in the format `final-approve` writes,
and `close-out finish` (which has no branch check) then closes #150. #174's CI stands
in for h-12's DoD clause "the next CI run on PR #161 finishes the Test suite step".

### Revisit if
- Another plan has to ship on a later plan's PR. Then make `ship` and `final-approve`
  accept it rather than repeating the manual marker.

<a id="phase2b-h1-timing-not-captured"></a>
## h-1 — Phase 2b's per-step controller timings were not captured

**Status:** Accepted risk
**Decision date:** 2026-11-17
**Decided by:** Human owner, on the P3 finding from the h-2 review
**Tracking:** docs/done/feature-station-hardening.md; tracker #150; issue #152

### Finding / proposal
Phase 2b's DoD asked for the controller group's wall time per step, before (h-1's
per-scenario profile) and after (`S=` runs). h-1's profile was never captured, so
those per-step times are not reported.

### Proposed mitigation / implementation
Check out the pre-h-2 commit, run the controller group with `AGENTIC_TEST_TIMING=1`
to rebuild the profile, then time each step's `S=` selection.

### Acceptance rationale
The only comparison recorded is the full `make test`: about 32 minutes at `b6c1962`
and about 80 minutes at `0a85379`. Phase 3 then replaced per-step timing with
reviewed wall-time ceilings per group and tag (`config/test-wall-ceilings.tsv`), so
growth now fails a run instead of needing a report.

### Revisit if
- A later phase needs a before-and-after per-step cost that the ceilings cannot show.

<a id="phase2-merged-before-final-approval"></a>
## C-8 — Phase 2 merged before final-head approval

**Status:** Accepted risk
**Decision date:** 2026-11-17
**Decided by:** Human owner, at the Phase 2 close-out
**Tracking:** docs/done/feature-line-controller.md; tracker #138; PR #149

### Finding / proposal
PR #149 (`3cb787d`) merged before `close-out prep` and the reviewer's `final-approve` ran.
The PR head `4531232` therefore has no final-head approval marker, and `final-approve`
exits 3 because no open PR remains. `lifecycle-status.sh --phase close-out` reports
`UNVERIFIED`, and the tracker's close transition is guarded by `lifecycle-ready`.

### Proposed mitigation / implementation
Open a close-out PR from a branch off `main`, have the reviewer approve its head, and run
`close-out finish` against it (the declined alternative). Phase 2's own head would still
stay unattested.

### Acceptance rationale
Every step (c-1 to c-7, issues #139-#145) was reviewed and approved clean, and CI
concluded success on the PR head (run 44075205553, attempt 1). The missing piece is the
single final-head attestation. The close-out commits on `main` (`2a20883`, `d626a41`)
are bookkeeping, the 0.16.0 release notes and a roadmap update. The owner closes #138
by hand, because the gate has no bypass.

### Revisit if
- A second plan merges ahead of `ship` reporting READY. Then make the merge order a
  hook or required check, not a convention.
- Phase 4 R-13 lands native PR reviews required on `main`, which makes this impossible.

<a id="opencode-station-network"></a>
## C-1 — OpenCode stations can reach the network

**Status:** Accepted risk
**Decision date:** 2026-11-15
**Decided by:** Human approval of line-controller decision 9, tracker #138
**Tracking:** docs/inprogress/feature-line-controller.md; step #139

### Finding / proposal
OpenCode 2.3.0 has command deny rules but no OS sandbox or network switch.
Station shell commands can reach the network with the operator's rights, including
credentials read from HOME. Environment scrubbing alone does not prevent that.

### Proposed mitigation / implementation
The station gets packet input, no inherited GitHub token, an empty GH_CONFIG_DIR,
a disabled push URL and credential helper, and the activated deny profile.
Unattended preflight requires this accepted entry and warns on every run.

### Acceptance rationale
The owner keeps OpenCode as the default reviewer to preserve model diversity.
Command deny rules cannot stop arbitrary alternate network clients or credential
reads. Operators can reassign either station or make it manual.

OpenCode can also write the verify and ledger directories in the Git common
directory: its command rules do not enforce a filesystem boundary. The station
probe reports these properties as `unenforced`. This is accepted under the
controller's ordering: verification records name a commit and tree, the reviewer
sees only a head already verified, and the sandboxed executor cannot write these
directories. The reviewer cannot know a future head's SHA to prepare its record.

### Revisit if
- OpenCode ships a sandbox or network switch.
- A station makes an unexpected network call.
- The repository holds secrets beyond the App keys.

<a id="agent-thread-prompt-injection"></a>
## D-9 — Interactive agents still read raw issue threads

**Status:** Accepted risk
**Decision date:** 2026-11-11
**Decided by:** Human approval of the gate-fix brief, tracker #114
**Tracking:** docs/done/feature-gate-and-handoff-fixes.md; R-19 in
docs/inprogress/product-harness-factory-optimization.md

### Finding / proposal
Once the repository is public, any GitHub user can comment on step and tracking issues.
G-1 stops those comments from changing lifecycle or hook outcomes, but an agent that reads
the thread with `gh issue view` still sees the text. Instructions planted in a comment are
a prompt-injection path into Claude, Codex or OpenCode.

### Proposed mitigation / implementation
S-7 supplies `agentic-flow packet`: admission requires an approver-created step,
an approved revision present locally, and a readable journal. The packet uses the
approved brief and role-relevant policy-authored comments only; outsiders are
counted and dropped without quoting their text. Reviewer packets preserve verifier
provenance and refuse stale records for reuse. Each packet is capped at 3,000 words.

The exported `config/stations/` profiles deny direct GitHub CLI/web reads in Claude
and OpenCode; the Codex profile disables sandbox network access, web search and
GitHub-token inheritance. These are explicit launch inputs, not changes to an
interactive session's settings. See `config/stations/README.md` for activation,
version compatibility and isolation limits.

### Acceptance rationale
Interactive agents can still read raw threads. Policy-authored text is trusted by
identity, not screened for instructions. Claude/OpenCode command permissions do
not provide an OS network boundary or stop every alternate program from reaching
GitHub. Codex environment filtering does not remove on-disk credentials or inherited
connectors. The controller clears inherited credentials, supplies an empty GH_CONFIG_DIR, disables
push and credential helpers, and activates station profiles; unattended entry checks their
effective isolation. OpenCode lacks an OS network boundary, accepted separately under
[opencode-station-network](#opencode-station-network). On-disk credentials and connected
tools remain a risk. The packet is not proof of complete process isolation.

### Revisit if
- Controller isolation or station profile activation changes; packet-only admission is not sufficient.
- A hostile comment is observed steering an interactive agent or a policy identity.

<a id="codex-guard-fail-open"></a>
## G-4 — Codex guard hooks fail open on error or timeout

**Status:** Accepted risk
**Decision date:** 2026-11-11
**Decided by:** Human approval of the gate-fix brief, tracker #114 (conditional on G-4's
finding)
**Tracking:** docs/done/feature-gate-and-handoff-fixes.md; step #118

### Finding / proposal
G-4 set `"onFailure": "block"` on the Claude push, staged-secret and broad-staging guards.
The Codex hooks documentation lists no equivalent, and says a `PreToolUse` error, timeout
or malformed response can let the tool run. A hung or crashed guard under Codex therefore
lets `git push`, a secret-bearing commit or `git add -A` through. Claude Code before
v2.1.295 ignores the field, with the same result.

### Proposed mitigation / implementation
A Codex-side failure policy if one ships, or a wrapper that runs the guard and refuses the
command itself when the guard does not answer.

### Acceptance rationale
The guards are fast local scripts with no network calls, so failure is rare. Pushes and
merges stay with the human, and `CI gate` re-runs the gates on every PR head. A secret
committed past a failed guard is caught only by the human before pushing; publishing step 1
scans the full history with gitleaks and trufflehog.

### Revisit if
- Codex documents a hook failure policy.
- A guard is observed failing or timing out under Codex.

<a id="recordless-inventory-sweep"></a>
## G-5 — A recordless adopter's gate also checks the adopter's own scripts

**Status:** Accepted risk
**Decision date:** 2026-11-11
**Decided by:** Proposed at close-out from the G-5 review; pending the human owner's
confirmation at merge
**Tracking:** docs/done/feature-gate-and-handoff-fixes.md; step #119; #109

### Finding / proposal
Without `.agentic-flow-installation`, `shell-inventory.sh` walks the manifest destinations
of active export rows. Directory destinations such as `scripts/` and `.claude/skills/` are
walked whole, so `--syntax` and `--lint` also cover adopter-owned shell files there. An
adopter script with a syntax error fails `make check`, which a project with a record does
not.

### Proposed mitigation / implementation
Restrict the walk to files the scaffold ships. The precise helper,
`payload_destination_files`, skips missing files and never expands directories, so it
cannot report a missing installed file; a fix needs a per-file list, which R-14a's per-file
hashes provide.

### Acceptance rationale
Before G-5 the recordless gate failed on every run (#109), so no adopter regresses. The
extra coverage fails closed on real syntax errors, never open.

### Revisit if
- An adopter reports a false gate failure from its own scripts.
- R-14a lands and every upgraded adopter carries an installation record.

<a id="f10-unreviewed-amendment"></a>
## F-10 — Post-approval amendment `987c58b` was not re-reviewed

**Status:** Accepted risk
**Decision date:** 2026-09-27
**Decided by:** wabkebab (human owner)
**Tracking:** docs/done/feature-harness-optimization.md; tracker #93, step #103

### Finding / proposal
OpenCode approved F-10 at `6b738c8` and closed #103. Codex then amended the commit to
`987c58b` to address that review's Low finding and Nit. Nobody reviewed the amendment
(12 lines across `scripts/hooks/require-step-comment.sh`, `scripts/self-test.sh`, and both
`CLAUDE.md` copies). F-11 and F-12 were reviewed on top of it, but only their own ranges.

### Proposed mitigation / implementation
Have the reviewer re-review `6b738c8..987c58b` before close-out.

### Acceptance rationale
The delta only applies the reviewer's own requested fixes. The hook change widens a
fail-closed match from the whole comment to one marker line, which is the lifecycle parser's
rule, and it adds regressions for prose before and after the marker. Every later step's
`make check`, focused hook groups, and full suite ran with it in place.

### Revisit if
- A Standard handoff is wrongly allowed or blocked by `require-step-comment.sh`.

<a id="harness-optimization-branch-split"></a>
## #93 — Harness optimization executed across per-step branches

**Status:** Accepted risk
**Decision date:** 2026-09-27
**Decided by:** wabkebab (human owner)
**Tracking:** docs/done/feature-harness-optimization.md; tracker #93

### Finding / proposal
Part B names one branch, `codex/trustworthy-proportionate-harness`. That branch stopped at
`0eb39f3` with an uncommitted draft in the F-2 worktree, so Codex continued on stacked
branches `…-f3` through `…-f12`. The finished history is one linear chain,
`87d6ae9..ba2cbd9`, on `codex/trustworthy-proportionate-harness-f12`.

### Proposed mitigation / implementation
Discard the stale draft and fast-forward the named branch to the chain head.

### Acceptance rationale
The chain is linear and each step is still one reviewed logical commit plus its review fixes.
The PR is opened from `…-f12`. The draft left in the named branch's worktree has no content
difference from `0eb39f3` (`git diff HEAD` is empty), so nothing is lost by leaving it.
The human can clean up the named branch and its worktree.

### Revisit if
- Another Strict brief is executed across stacked branches; the single-branch rule then
  needs enforcement rather than a per-plan exception.

<a id="single-operator-review"></a>
## F-3 — One GitHub account can attest to multiple agent roles

**Status:** Retired 2026-11-15 — the repo runs distinct-account (tracker #146)
**Decision date:** 2026-09-25
**Decided by:** Human approval of the harness optimization brief, tracker #93
**Tracking:** issue #96

### Finding / proposal

This installation uses one GitHub credential for its agent roles. GitHub authenticates
the account that posts a verdict, but cannot prove that a different person reviewed it.

### Acceptance rationale

The lifecycle gate requires a structured reviewer role claim and records the API author.
Policy role logins restrict whose comments qualify as evidence in both identity modes.
The result is accountable single-operator attestation, with a persistent warning; it is
not independent review. Revisit when separate reviewer credentials are available.

<a id="mutable-external-evidence"></a>
## F-3 — Review comments and Actions runs can change after verification

**Status:** Accepted risk
**Decision date:** 2026-09-25
**Decided by:** Human approval of the harness optimization brief, tracker #93
**Tracking:** issue #96

### Finding / proposal

An issue-comment verdict can be edited or deleted, and an Actions run can be re-run or
deleted without a repository edit. The gate checks the current comment, run attempt,
head, repository, workflow, and conclusion when invoked. It cannot preserve those
external records or guard a later merge.

### Acceptance rationale

The closer checks immediately before closing the tracker; the human checks again
immediately before merge or uses protected-branch required checks. Durable evidence
would require stronger GitHub review or attestation mechanisms beyond this pass.

## F-4 — Template and instance copies can drift

**Status:** Accepted risk
**Decision date:** 2026-07-05
**Decided by:** Human approval of tracker #8
**Tracking:** docs/inprogress/feature-init-and-template-split.md; issue #4

### Finding / proposal
The scaffold now keeps pristine exported forms in `templates/harness/` and this repo's own
filled-in files at the root. That split prevents instance details from leaking into new
adoptions, but it creates a small risk that contract changes land in only one copy.

### Proposed mitigation / implementation
A heavier synchronization mechanism could derive one copy from the other or add a strict
template drift checker for every contract line. This pass keeps the split explicit and
documents the dual-copy rule in the root guidance.

### Acceptance rationale
The copied surface is limited to `CLAUDE.md`, `AGENTS.md`, and `Makefile`, and contract
changes are expected to be rare and reviewed. The alternative was continuing to ship this
repo's live instance as the adoption payload, which had already blocked dogfooding.

### Revisit if
- A third copy of the harness contract appears.
- A contract change ships in only one copy.
