<!-- TRIAGE (first pass · 2026-11-15) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict
> Part 1 of the signing follow-up: every commit is signed by its role's key, and lifecycle and CI check that, so a step commit proves the executor's key made it. Runs after Phase 2 merges. Part 2 (role-neutral contracts and labels) is Phase 3's R-22. Draft for approval; nothing is executed.

# Feature — Role-signed commits

## Tracker
- [ ] r-1 — role signers file, signing config and `git-as` — open
- [ ] r-2 — lifecycle checks each range's signer — open
- [ ] r-3 — CI rejects unsigned and unknown-signer commits — open
- [ ] r-4 — controller stations sign as their role — open
- [ ] r-5 — require signing here and route the contracts — open

---

# Part A — Analysis

## Goal

Every commit in this repo is already signed: `git-claude`, `git-codex` and `git-opencode` each sign with their own SSH key. Nothing checks those signatures. GitHub shows them as Unverified (reason `no_user`), because `claude@danimon.local` belongs to no account. Locally, `git log --format=%G?` errors because no allowed-signers file is configured. So a step commit made by the wrong wrapper, by hand, or unsigned would pass every gate.

This pass makes signatures evidence. Each role has a published public key. Lifecycle checks that every commit in a step's range was signed by the executor key, and that plan and close-out commits were signed by the approver key. CI rejects unsigned commits and commits from unknown keys. The key follows the role, not the vendor, so a Claude executor under Phase 2's `roles` still signs as the executor.

## Current state

| What | State on 2026-11-15 | Where |
|---|---|---|
| Wrappers | `git-claude` (Claude, `claude_agent_key`), `git-codex` (Codex, `codex_agent_key`), `git-opencode` (opencode, `opencode_agent_key`). Each sets name, email and an SSH signing key. They live in the operator's `~/.local/bin` and are not in the repo. | operator machine; `~/.claude/CLAUDE.md` |
| Signatures | Present on the agent commits. Of the last 40 commits, 25 are by Claude and 13 by Codex, and none can be verified, because no `gpg.ssh.allowedSignersFile` is configured. The other 2 are GitHub merges by the owner. | `git log --format='%G? %an' -40` |
| Gates | Lifecycle checks ancestry (G-2), verdict authors and CI, but not who signed a commit. CI has the jobs `changes`, `secrets-scan`, `app`, `docs` and `ci-gate`, none of them a signature check. | `scripts/lifecycle-status.sh`, `.github/workflows/ci.yml` |
| Contracts | `CLAUDE.md` says commit with `git-claude`, and `AGENTS.md` with `git-codex`, so the vendor names the key. | root and template contracts |
| Phase 2 | Stations commit with plain `git commit` inside the controller worktree, so they are unsigned unless the launch environment sets signing. | `feature-line-controller.md` (`launch_station` environment) |

## Proposed approach

### Option A — role keys in an allowed-signers file, checked by lifecycle and CI (recommended)
- A committed `.agentic-flow-signers` file in the `ssh-keygen` allowed-signers format maps role principals to public keys.
- A repo command, `scripts/git-as <role>`, signs with the key the operator configured for that role.
- Lifecycle checks the signer per range, and CI checks that every commit has a known signer.
- No new trust root, nothing secret in the repo, and it works offline and in CI.

### Option B — have the GitHub Apps create commits through the API
GitHub signs those commits, and they show as Verified under the bot's name. It needs Contents write for the executor App, which reverses the rule that no agent token can push. It also moves commit creation off the local worktree. Rejected.

### Option C — GitHub's Verified badge only
Register the agent keys on the owner's account. The commits would then verify as the owner, which erases the roles. Rejected.

**Recommendation:** Option A.

### Decisions this brief makes (veto at approval)

1. **Runs after Phase 2 merges.** Phase 2's stations commit inside `launch_station`'s environment, which does not exist until Phase 2's C-1. This pass's R-4 extends that environment. Running before Phase 2 would leave Phase 2's own dogfooded runs unsigned under an enforced check.
2. **Keys follow roles.** The principals are `executor`, `reviewer`, `approver` (planner and closer) and, optionally, `owner` (the human). On this machine, executor = `codex_agent_key`, approver = `claude_agent_key` and reviewer = `opencode_agent_key`, so every existing wrapper keeps producing valid signatures and no new key is needed.
3. **Commits are attributed to the role's App.** `git-as` sets author and committer to the role App's bot noreply address, so GitHub links each commit to the same bot that posted its handoff. The badge stays Unverified, because GitHub cannot hold a key for a bot. That is cosmetic; the harness check is what counts.
4. **Enforcement is a policy switch, off by default.** A new `signing=required|off` key in `.agentic-flow-review-policy`. Adopters get `off` and a doctor warning until they publish keys. This repo turns it on in R-5.
5. **Keys must sign without a prompt.** Unattended stations cannot answer a passphrase prompt, so each role key is either in `ssh-agent` or has no passphrase. That is recorded as an accepted risk in R-5. Separately, as with the App keys, any process running as the operator can sign as any role.

## Interface (before the implementation)

```
.agentic-flow-signers                   project-owned, committed, public keys only
  ssh-keygen allowed-signers format, one line per key:
    <role>@agentic-flow namespaces="git" <key-type> <base64-public-key> [comment]
  role ∈ executor | reviewer | approver | owner
  a role may list more than one key (rotation); a key may not appear under two roles
  `make check` validates it: known principals, namespaces="git", parseable public keys,
    no private-key material, no duplicate key across roles

.agentic-flow-review-policy
  signing=required|off                  new; absent = off

operator signing config (never in the repo)
  ${XDG_CONFIG_HOME:-~/.config}/agentic-flow/signing/<owner>/<repo>.tsv
    role  key-path  name  email
    key-path: the public key whose private half is in ssh-agent or next to it
    name/email: what author and committer show (decision 3: the App's bot name and
      its noreply address; any value is accepted, the signature is what is checked)

scripts/git-as <role> <git args…>
  git with user.name, user.email, gpg.format=ssh, commit.gpgsign=true and
    user.signingkey set from the operator config for <role>
  on `commit`, verifies that the new commit's signer principal is <role>@agentic-flow
    against .agentic-flow-signers, and exits 1 naming the mismatch if not (the commit
    stays, unpushed, for the human to amend)
  no config row for <role> → exit 6 naming the file; never commits unsigned
  keeps the Co-Authored-By trailer behavior of today's wrappers

scripts/lib/signing.sh
  signing_principal <commit>   → <role> | unsigned | unknown | bad
    git verify-commit against .agentic-flow-signers as it stands at the merge base,
    never at the commit under review, so a branch cannot add its own key and sign
    with it; then `ssh-keygen -Y find-principals` for the principal
  signing_check_range <base> <head> <role>   → ok | the first failing commit and why

lifecycle-status.sh, when signing=required (R-2)
  coverage ranges as G-2 and close-out attestation already define them:
    plan-approval range        → approver
    step k (prev head, head]   → executor
    close-out delta            → approver or owner
  any commit outside its range's role → BLOCKED "commit <sha12> signed by <principal>,
    expected <role>"; merges in the range keep today's NEEDS-REVIEW
  signing=off → one line "signatures: not enforced"

CI job `commit-signatures` (R-3), feeds `CI gate`
  for every non-merge commit in merge-base(main, head)..head: signer principal is any
  role in the base's .agentic-flow-signers; unsigned or unknown → fail naming the
  commit. Skipped, with a notice, when the policy says signing=off. No issue reads,
  no secrets.

Phase 2 launch environment (R-4)
  GIT_CONFIG_COUNT entries add gpg.format=ssh, commit.gpgsign=true,
    user.signingkey, user.name and user.email for the station's role, from the
    operator signing config
  the controller's claimed-head checks add: every commit in base_head..head is
    signed by the station's role principal; otherwise the bad-claimed-head andon
  the reviewer station never commits, so it needs no key in its environment
```

## Threat model (one paragraph)

The signers file holds public keys only, and the private keys stay in the operator's `~/.ssh` or `ssh-agent`. Reading the signers file from the merge base stops a branch from adding its own key and then signing as a role with it. A change to the signers file therefore lands only on `main`, after review. What a valid signature proves: the commit was made with that role's key on a machine holding it. What it does not prove: which model wrote the content, or that the operator's other processes did not use the key. Every role key sits on one machine, like the App keys (Phase 1's threat model, unchanged). The value is catching honest mistakes, such as a hand-made commit in a step range, the wrong wrapper, an unsigned station commit, or a rebased commit signed by someone else. It also gives CI a provenance check it can run without secrets. Passphrase-less or agent-held keys are needed for unattended runs (decision 5).

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---|---|---|---|
| `git verify-commit` / `ssh-keygen -Y` | n/a (local) | malformed signature → `bad`, BLOCKED | n/a |
| signers file at the merge base missing | n/a | missing or invalid → lifecycle UNVERIFIED and the CI job fails, naming the file | n/a |
| `git-as` signing (`ssh-keygen -Y sign` through git) | agent not reachable → git fails; `git-as` exits 1, no commit | n/a | committed but signer mismatch → exit 1 naming it; nothing pushed |

Bounds: one `verify-commit` per commit in the PR range; CI's range is bounded by the PR's commit list (GitHub's 250-commit page, refuse above it).

## Out of scope / What NOT to build in this pass

- Role-neutral contracts, role-named labels and a non-Claude planner: Phase 3's R-22.
- GitHub's Verified badge for agent commits (Options B and C).
- Signing tags or releases.
- Re-signing or re-checking history before this pass: checks cover each pass's own range only.
- Removing the operator's global wrappers: they keep working in other projects. In this repo, contracts route to `git-as`.

## Open questions

- Does `git verify-commit` report the principal the same way across git 2.34 to 2.55 and OpenSSH 8.x to 10.x? R-2 pins the behavior with fixtures generated at test time, using `ssh-keygen` from the runner's own toolchain.
- Should `owner` signatures be accepted inside a step range for a human hand-fix? The brief says no: a human fix in a step range is an executor job or a re-plan. Say so at approval if you disagree.

---

# Part B — Implementation Brief

> **Audience:** the implementing agent (Codex). Foundations first, then the gates, then the station, then enforcement. One logical commit per step; stage files by name; why-first commit bodies.

```agentic-flow-plan
id: role-signing
profile: strict
tracking: Plan: Role-signed commits
branch: role-signing
steps: r-1 r-2 r-3 r-4 r-5
```

## Prerequisite
Phase 2 (`feature-line-controller.md`, tracker #138) is merged (decision 1), and so is the identity flip (tracker #146). Otherwise stop and tell the human.

## Branch
Base: `main`. One branch and one PR: `role-signing`. Each step is one commit with `Fixes #N`. Review fixes land as new commits; never amend after a handoff.

## Invariants
- Bash 3.2; payload membership in `config/payload.tsv` only. `.agentic-flow-signers` is project-owned and never a payload destination.
- No key material in any committed fixture: tests generate throwaway keys with `ssh-keygen` at run time, and no file contains a literal public or private key (see `CLAUDE.md` Gotchas on credential-shaped strings).
- The signers file is always read from the merge base, never from the commit under review.
- Hermetic tests; no network in `make test`.

## Definition of done (whole brief)
- Every step's DoD is met. `make check`, `make test`, `make build` and `scripts/doctor.sh --check` are green here and in a fresh export.
- All nine acceptance scenarios below pass as tests.
- This pass's own close-out runs with `signing=required` (set in R-5) and is READY: every step commit is signed by the executor principal and every close-out commit by the approver principal.

## Acceptance scenarios (written at Spec; the executor does not edit these)
1. **Role per range.** In a fixture plan, every step commit signed by the executor key gives READY. One step commit signed by the approver key gives BLOCKED, naming the commit, `approver` and the expected `executor`.
2. **Unsigned and unknown.** An unsigned commit in a step range is BLOCKED "unsigned". A commit signed by a key missing from the signers file is BLOCKED "unknown signer".
3. **Branch cannot add its own key.** A branch adds a new key under `executor` to `.agentic-flow-signers` and signs a step commit with it. Lifecycle and the CI job both reject it, because they read the signers file from the merge base.
4. **Close-out delta.** Close-out commits signed by the approver or the owner pass. One signed by the executor is BLOCKED.
5. **Policy off.** With `signing=off`, lifecycle prints "signatures: not enforced" and the CI job skips with a notice; nothing else changes.
6. **`git-as`.** `git-as executor commit` produces a commit signed by the executor principal, with the configured name and email and the trailer. With no config row it exits 6 and creates no commit. With a key that the signers file lists under another role, it exits 1 naming the mismatch.
7. **CI job.** On a fixture PR range, an unsigned non-merge commit fails `commit-signatures` naming it. A clean range passes. Merges are skipped.
8. **Station signs as its role.** Under Phase 2's controller, with a fake executor station on claude, the station's `git commit` is signed by the executor principal, not by a vendor key. A station commit signed by any other principal raises the bad-claimed-head andon, and no submit is posted.
9. **Signers file validation.** `make check` fails on an unknown principal, a missing `namespaces="git"`, a key listed under two roles, or private-key material in the file.

## Verification commands
```bash
make check
make test-one F=signing
make test-one F=lifecycle
make test-one F=controller
make test
make build
scripts/doctor.sh --check
```

---

## R-1 — Publish role keys and sign with `git-as`
**Why first:** every later check reads the signers file and the operator config, and every commit from here on can use `git-as`.

**Approach:**
1. `.agentic-flow-signers` format and validation in `make check`, per the Interface. Generate this repo's file from the three existing public keys (decision 2) in this step, and add the owner key only if the human supplies one.
2. The `signing=` policy key in the parser and doctor. Doctor warns when it is `off`, and fails when it is `required` with no signers file.
3. The operator signing config and `scripts/git-as`. Doctor checks that each configured key is in the signers file under its role and can sign without a prompt (a dry `ssh-keygen -Y sign` of a fixed string).
4. A new `signing` test group in `scripts/tests/signing.sh`, wired into `self-test.sh` and the `Makefile` usage line.

**DoD:** scenarios 6 and 9 pass. Doctor reports each role's key status.
**Verify:** `make test-one F=signing` and `make check`
**Red-first:** `scripts/self-test.sh --only signing` — scripts/self-test.sh scripts/tests/signing.sh
**Risks:** a literal key landing in a fixture (generate at test time); a passphrase prompt hanging doctor (time-box it and report "needs agent"); `git-as` silently falling back to unsigned.
**Commit:** `Publish role signing keys and commit through git-as`

---

## R-2 — Check each range's signer in lifecycle
**Why second:** it is the gate that gives the signatures meaning.

**Approach:**
1. `scripts/lib/signing.sh` per the Interface, reading the signers file from the merge base.
2. Lifecycle applies it to the ranges G-2 and close-out attestation already compute: plan approval → approver, steps → executor, close-out delta → approver or owner. No new range logic.
3. With `signing=off`, one informational line and no change in verdicts.

**DoD:** scenarios 1–5 pass, the CI half of scenarios 3 and 5 excepted (R-3). Every existing lifecycle fixture passes unchanged under `signing=off`.
**Verify:** `make test-one F=signing` and `make test-one F=lifecycle`
**Red-first:** `scripts/self-test.sh --only signing` — scripts/self-test.sh scripts/tests/signing.sh
**Risks:** reading the signers file from HEAD (scenario 3); git-version differences in `%GS` (pin with generated fixtures); a merge commit in the range (keep today's NEEDS-REVIEW).
**Commit:** `Check that each lifecycle range was signed by its role`

---

## R-3 — Reject unsigned and unknown-signer commits in CI
**Why third:** CI is the check that runs without the operator's machine.

**Approach:**
1. A `commit-signatures` job in `.github/workflows/ci.yml`, feeding `CI gate`, running `signing_check_range` with "any role" over the PR range. Pin actions per `check-action-pins.sh`.
2. The same job in `templates/ci/ci.yml` for adopters, skipping with a notice under `signing=off`.

**DoD:** scenario 7 and the CI halves of scenarios 3 and 5 pass against fixtures. The job is green on this PR.
**Verify:** `make test-one F=signing` and `make check`
**Red-first:** `scripts/self-test.sh --only signing` — scripts/self-test.sh scripts/tests/signing.sh
**Risks:** a shallow checkout missing the merge base (fetch depth); fork PRs (no secrets are needed, so they run the same).
**Commit:** `Reject unsigned and unknown-signer commits in CI`

---

## R-4 — Sign controller station commits as the station's role
**Why fourth:** it extends Phase 2's launch environment, which must exist first.

**Approach:**
1. Add the signing entries to `launch_station`'s environment from the operator signing config, keyed by station role, never by CLI.
2. Add the signer check to the controller's claimed-head checks.
3. `launch_preflight` fails an executor station whose role key is missing or cannot sign without a prompt.

**DoD:** scenario 8 passes. Phase 2's controller scenarios still pass with signing configured.
**Verify:** `make test-one F=controller` and `make test-one F=signing`
**Red-first:** `scripts/self-test.sh --only controller` — scripts/self-test.sh scripts/tests/controller.sh
**Risks:** the key path visible in the station environment (a public path only; the private half stays in the agent); a reassigned executor CLI signing with a vendor key (the role decides).
**Commit:** `Sign station commits with the station role's key`

---

## R-5 — Require signing here and route the contracts to `git-as`
**Why last:** enforcement flips only after every path can sign.

**Approach:**
1. Set `signing=required` in this repo's policy.
2. `CLAUDE.md`, `AGENTS.md`, the reviewer contracts and their templates: commit with `scripts/git-as <role>`. Keep this word-neutral; contract ceilings are not raised.
3. `ADOPTION.md`: publishing keys, the operator config, `ssh-agent`, and the policy switch.
4. Add accepted risk `role-keys-one-machine` (decision 5 and the threat model).

**DoD:** this pass's own close-out evidence is READY under `signing=required`. Doctor passes. `check-harness-sync.sh` passes.
**Verify:** `make test-one F=contracts` and `scripts/doctor.sh --check`
**Red-first:** none
**Risks:** flipping enforcement before this pass's earlier steps are verified as executor-signed (check them with `signing_check_range` before committing the flip); root and template drift.
**Commit:** `Require role signatures here and commit through git-as`

---

# Close-out

Claude, on `role-signing`, after the last approval, committing with `scripts/git-as approver`:

1. `VERSION` 0.17.0 and a `CHANGELOG.md` entry: the signers file, `git-as`, the `signing=` policy key (off by default), the CI job, and migration notes for adopters.
2. `agentic-flow ship`. The CHANGELOG makes the delta non-bookkeeping, so the reviewer runs `agentic-flow final-approve` (Phase 2) for the final head.
3. After the merge, on `main`: update `product-harness-factory-optimization.md`'s next-docs list.

---

## Status / Implementation status
- **Evidence schema:** v2
- **Tracking issue:** pending
- **Approval:** pending
- **Implementation head:** source=pr-head
- **Implementation PR:** pending
- **Verification evidence:** source=final-approval-run
- **Review verdict:** source=close-out-attestation
- **Memory:** pending
- Close-out: finalize Status/Tracker, set TRIAGE to Done, move this document and update
  the index in the last repository commit. After human push, obtain CI and a structured
  reviewer approval on the `Tracking issue` for that exact PR head and run attempt.
  Verify this moved file with `--phase close-out`, close the tracker without another
  repository edit, then recheck with `--phase pre-merge` before human merge.
