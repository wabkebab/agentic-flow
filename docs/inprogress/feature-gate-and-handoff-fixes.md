<!-- TRIAGE (first pass · 2026-11-11) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict
> Phase 0 of `product-harness-factory-optimization.md`: close the gate, evidence and adopter-breakage defects that must be fixed before the repo goes public, then publish. Awaiting human approval; no issues exist yet.

# Feature — Gate and handoff fixes before publishing

## Tracker
- [ ] G-1 Accept review evidence and handoffs only from role logins — open
- [ ] G-2 Bind every approved step commit to the PR head — open
- [ ] G-3 Close the Stop-gate commit bypass and the stamp race — open
- [ ] G-4 Fail closed when a guard hook times out — open
- [ ] G-5 Keep an adopter's gate green without an installation record — open
- [ ] G-6 Ignore OS files, settle stale docs, clear labels on close — open

---

# Part A — Analysis

## Goal

The repository will be made public (decision 1 of the analysis). Before that, and before any later phase builds automation on the harness, the harness has to stop accepting evidence it cannot trust and stop letting broken work through its own gates. This pass fixes the defects the analysis found in today's code. It adds no new concepts.

## Current state

| Ref | Defect | Where |
|---|---|---|
| D-9 | In `single-operator` mode no comment author is checked. A stranger's comment on a public issue can approve a step, block close-out with a malformed marker, or redirect a step with "Implemented in <sha>". The hook reads whoever commented last. | `scripts/lifecycle-status.sh:141-152`, `:212-219`, `:228-231`; `scripts/hooks/require-step-comment.sh:24-25` |
| D-4 | A step approved at one SHA and amended afterwards still passes close-out. Nothing checks that the approved commit is in the PR. This happened on #103 (accepted risk `f10-unreviewed-amendment`). | `scripts/lifecycle-status.sh:172-286` |
| D-1 | The Stop gate exits early on a clean tree, so a turn that commits red code ends ungated. This repo hides it only because untracked `.DS_Store` files keep the tree dirty. | `scripts/hooks/check-gate.sh:20-23` |
| D-2 | The gate hashes the tree before `make check` and stamps that hash after, so an edit made during the run is certified green. | `scripts/hooks/check-gate.sh:47`, `:76` |
| D-7 | A PreToolUse hook that times out does not block the call, so a hung push or secret guard lets the command through. | `.claude/settings.json` |
| #109 | Without `.agentic-flow-installation`, `make check` in an adopter fails with `missing manifest source templates/harness/CLAUDE.md`. Every customized adopter is in this state because upgrade never writes the record (#109 part 1). Reproduced on a fresh 0.13.3 export with the record removed. | `scripts/shell-inventory.sh:18-37` |
| B-7, D-6 | Three docs in `docs/inprogress/` are stale. Closed issues keep workflow labels (#54–#59, #94, #105). `METHODOLOGY.md:330` says the merge closes issues; `:297` says it does not. | as named |

**Change from the approved analysis.** R-0b planned to remove the scaffold self-test from the adopter gate because of #113's 89.5 s measurement. That measurement was taken at `0.13.1+156aedc`, which predates F-12 (`15483f5`). At `0.13.3`, a fresh export runs `scripts/self-test.sh --fast` in 2.0 s and the whole `make check` in 5.5 s. R-0b is dropped and replaced by G-5, which fixes the adopter gate failure that is still real. #113 is closed at close-out with that measurement.

## Proposed approach

Six small steps. They run in order because two pairs depend on each other:

- G-1 and G-2 both edit `scripts/lifecycle-status.sh`. G-1 goes first because it is the publishing blocker.
- G-6 adds a root `.gitignore`, which makes this repo's tree clean and exposes the D-1 bypass. G-3 must land before it.

Close-out's own repository changes land on the branch before the final review. Publishing is a human checklist after merge, not a step issue.

### Option A — fix in place (recommended)
Change the existing scripts and contracts, with a regression test per defect. Later phases replace some of this code (R-1 replaces the hook's comment logic, R-13 shrinks lifecycle evidence). The fixes are small enough that they cost little to throw away, and the repo cannot publish without them.

### Option B — wait for Phase 1
Skip the fixes and build R-1/R-13 directly. This delays publishing by two Strict passes and leaves forgeable evidence in place meanwhile.

**Recommendation:** Option A.

## Review corrections applied (2026-11-11)

| Finding | Severity | Correction |
|---|---|---|
| G-3 let a state that changed during `make check` end the turn unverified | High | One bounded rerun; a red or still-changing state blocks; only the documented `stop_hook_active` warning may allow, and it writes no stamp |
| G-2 treated every failed ancestry check as BLOCKED | Medium | Only exit 1 in a full repository with both objects present blocks; missing objects, shallow history and git errors are UNVERIFIED with fetch guidance |
| Close-out was placed after merge | Medium | Close-out's repository changes land before the final-head review; only publishing follows the merge |
| G-3's HEAD baseline let a verified dirty tree vouch for the clean tree under it | High | Baseline removed. Only a green stamp of the complete state hash allows a silent skip. Loop safety uses a separate acknowledged-red record keyed on the full state. Regression: a fix verified, then discarded, must run and block. |

## Interface (before the implementation)

```
.agentic-flow-review-policy          version stays 1
  reviewer=<login>                   ≥1 line, now required in BOTH identity modes
  executor=<login>                   ≥1 line
  approver=<login>                   ≥1 line (the planner/closer)
  In single-operator mode one login may hold all three roles.
  distinct-account rules are unchanged.

templates/harness/.agentic-flow-review-policy
  the three lines carry an owner-login placeholder token
scripts/init.sh --owner-login <login>
  default: `gh api user --jq .login`; non-interactive without either → error

comment classification (lifecycle-status.sh and require-step-comment.sh)
  author in no role list     → ignored, never parsed, never blocks
  author in a role list      → parsed; acting outside its role → BLOCKED (as today)

lifecycle-status.sh, new outputs
  EVIDENCE   ignored <n> comment(s) from authors outside the review policy
  BLOCKED    approved step <id> commit <sha> is not an ancestor of PR head <sha>
  UNVERIFIED PR head <sha> is not in the local repository; fetch the PR branch

check-gate.sh state, in $(git rev-parse --git-dir)
  agentic-flow-check-gate-state      green stamp; full-state hash now covers HEAD^{tree};
                                     the only record that lets a stop skip the gate silently
  agentic-flow-check-gate-red        acknowledged-red state hash (new); written only under
                                     stop_hook_active; repeats the warning, never means green

.claude/settings.json
  "onFailure": "block" on block-push, scan-secrets, block-git-add-all

shell-inventory.sh, adopted project without an installation record
  walks manifest DESTINATIONS of active scopes; a missing one fails, naming the file
```

## Threat model (one paragraph)

After publishing, any GitHub user can comment on issues and open pull requests. What matters is the review evidence on step and tracking issues: approval markers, "Implemented in" handoffs, and the label pair. Today's worst case is a stranger posting an approval that makes close-out report READY for unreviewed code, or a malformed marker that blocks close-out indefinitely. G-1 makes the harness ignore every comment whose author is not in the review policy. Two things stay open. First, an interactive agent reading a thread still sees hostile text, so instructions in comments are a prompt-injection path until R-19 builds trusted packets. Second, fork pull requests run CI with a read-only token and no secrets, which is GitHub's default and sufficient here. The first is recorded as an accepted risk at close-out, with "no headless stations before R-19" as its condition.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---|---|---|---|
| `gh` comment read in `require-step-comment.sh` | hook budget 20 s; the hook exits non-zero and the call proceeds (this hook keeps fail-open, see G-4) | treat as "no qualifying comment" → block | n/a, single read |
| `gh` reads in `lifecycle-status.sh` | `bounded_gh` → UNVERIFIED (unchanged) | UNVERIFIED (unchanged) | UNVERIFIED (unchanged) |
| `git merge-base --is-ancestor` | local, no timeout | missing object → UNVERIFIED | n/a |
| `gh api user` in `init.sh` | `gh` default; failure → ask for `--owner-login` | reject a login that fails the policy regex | n/a |

Bounds: unchanged. Comment reads stay one page of 100; a longer thread is UNVERIFIED as today.

## Out of scope / What NOT to build in this pass
- #109 part 1, upgrade never stamping a customized adopter: R-14a.
- Rewriting the comment hook's check-then-act race: R-1. G-1 only filters authors.
- GitHub App logins (`name[bot]`) in the policy regex: R-18.
- Trusted packets for agents: R-19.
- #112 (Codex hooks on Windows).
- Roadmap cleanup beyond the 2.6 line: R-16.

## Open questions
- Does `onFailure: "block"` also block on a crash or a non-2 exit, and do Claude Code versions before 2.1.295 ignore the field or reject the file? G-4 confirms against the hooks reference before relying on it. If older versions reject the file, G-4 adds a doctor version check instead of shipping the field unconditionally.
- Codex has no documented equivalent of `onFailure` that this audit found. If G-4 confirms that, close-out records it as an accepted risk.

---

# Part B — Implementation Brief

> **Audience:** the implementing agent (Codex). Each step is independently shippable and ordered so the riskiest work lands first. One logical commit per step; do not bundle. Stage files by name. Why-first commit bodies. Approach and insights, not code.

## Branch
Base: `main`. One branch and one PR for the whole brief: `codex/gate-and-handoff-fixes`. Each step is one commit with `Fixes #N`. **Review fixes land as new commits; never amend a commit after its review handoff.** G-2 makes close-out reject amended approvals.

## Word ceilings: read before touching any contract file

`make check` enforces exact word ceilings, and three files are at or next to them:

| File | Words | Ceiling | Where enforced |
|---|---|---|---|
| `CLAUDE.md` (root) | 1530 | 1530 | `scripts/self-test.sh` (planner ceiling) |
| `AGENTS.md` (root) | 1088 | 1090 | `scripts/self-test.sh` (executor ceiling) |
| `.agents/skills/review-execution/SKILL.md` | 999 | 1000 | `scripts/self-test.sh:1509` |

Any wording added to these files must be offset in the same file, or the rule must go to `METHODOLOGY.md`, which has no ceiling, with the contract file routing to it. Do not raise a ceiling in this pass. Contract edits to `CLAUDE.md` and `AGENTS.md` need the matching edit in `templates/harness/`.

## Definition of done (whole brief)
- Every step's DoD is met.
- `make check`, `make test` and `make build` are green.
- `scripts/doctor.sh --check` is green in this repo and in a fresh export made with `init.sh --owner-login`.
- `scripts/lifecycle-status.sh --check --verify-evidence` on this document reaches READY at close-out, which exercises G-1 and G-2 on their own pass.

## Verification commands
```bash
make check                          # per step; also run by the Stop hook
make test-one F=<group>             # per step; group named in each step
make test                           # end of brief
make build
scripts/doctor.sh --check
```

---

## G-1 — Accept review evidence and handoffs only from role logins
**Why first:** it blocks publishing, and G-2 edits the same file.

**Approach:**
1. `scripts/lib/review-policy.sh`: require at least one `reviewer`, `executor` and `approver` login in both modes. The error names the missing key. Keep the distinct-account overlap rules. One login may hold every role in single-operator mode, which the parser already allows.
2. Add the three lines to this repo's `.agentic-flow-review-policy` (owner login `wabkebab`). In `templates/harness/.agentic-flow-review-policy`, use an owner-login placeholder token. `scripts/init.sh` fills it from `--owner-login`, falling back to `gh api user --jq .login`, and errors out in non-interactive mode when neither is available. Build any placeholder pattern in scripts with `printf`, as `init.sh:22-23` does, so no script holds a literal token.
3. `scripts/lifecycle-status.sh`: classify each comment by author **before** parsing it, in both `verify_step_review` and `verify_evidence`.
   - An author in no role list is skipped and counted, and never reaches the marker parser. Today a stranger's malformed marker produces BLOCKED at `:228-231` and `:383-390`.
   - Accept "Implemented in <sha>" only from executor logins, in both modes. Today that check runs only in distinct-account mode (`:212-219`).
   - A listed login acting outside its role still blocks, as today.
   - Print one `EVIDENCE ignored <n> …` line when anything was skipped.
4. `scripts/hooks/require-step-comment.sh`: replace "last comment" with "latest comment whose author holds the role that owns this evidence":
   - executor, for adding `needs-review`;
   - reviewer, for a bounce to `needs-execution`, for adding `needs-closing`, and for closing.

   Read the policy through `review-policy.sh`, resolving the project root with `git rev-parse --show-toplevel`. If the policy is missing or invalid, block the transition, and say which file to fix and which keys it needs.
5. Documentation:
   - `METHODOLOGY.md` §2: one paragraph saying the evidence rule now applies to any author outside the policy.
   - `ADOPTION.md`: a migration note telling existing adopters to add the three lines.
   - `docs/accepted_risks.md#single-operator-review`: update the rationale, keeping the anchor.
   - `CLAUDE.md` stays word-neutral.

**Test** (`make test-one F=lifecycle`, `F=hooks`, `F=contracts`). Failure paths first:
- A stranger's approving marker leaves the step UNVERIFIED, not READY.
- A stranger's malformed marker does not BLOCK.
- A stranger's "Implemented in <sha>" posted after the real handoff does not change the step head.
- Hook: a stranger comment after the executor's handoff still allows the relabel, and a stranger's handoff alone is blocked.
- A policy without logins fails doctor, blocks the hook with a named message, and makes lifecycle UNVERIFIED.
- `init.sh --owner-login` fills the policy; a non-interactive init with no login and no `gh` fails.

**DoD:** no comment from outside the policy can change any lifecycle or hook outcome. Existing single-operator fixtures pass once they carry logins.
**Commit:** `Accept review evidence only from logins in the review policy`

---

## G-2 — Bind every approved step commit to the PR head
**Why second:** it closes the amended-approval gap (accepted risk `f10-unreviewed-amendment`), and it needs G-1's author filtering in place.

**Approach:**
1. Pass the PR head into `verify_step_review` explicitly. Today the function relies on bash dynamic scope for `head`.
2. After a step's approval is validated, separate "the history says no" from "the history is not available to say":
   - If either object is missing (`git -C "$ROOT" cat-file -e "<sha>^{commit}"` fails for the step head or the PR head): UNVERIFIED, naming the missing SHA and the fetch to run.
   - Run `git -C "$ROOT" merge-base --is-ancestor <step-head> <pr-head>` and branch on its exit code. 0 passes. Any code other than 0 or 1 is a git error: UNVERIFIED with git's message.
   - Exit 1 in a shallow repository (`git rev-parse --is-shallow-repository` prints `true`): UNVERIFIED, because the shallow boundary can hide the ancestry. Tell the operator to run `git fetch --unshallow`.
   - Exit 1 in a full repository with both objects present: BLOCKED with both SHAs. This is the only case that blocks.
   - Apply this on both the Strict path (`verify_strict_steps`) and the Standard path (`reuse-tracking-page`).
3. Documentation:
   - `METHODOLOGY.md` §2: approvals bind to commits, so rebasing or amending a reviewed branch requires re-review.
   - `METHODOLOGY.md` §7: review fixes land as new commits.
   - `AGENTS.md` (root and template): replace an existing sentence to say "never amend a commit after its review handoff", keeping root `AGENTS.md` ≤ 1090 words.

**Test** (`make test-one F=lifecycle`, with a fixture git repo next to the fake `gh`). Failure paths first:
- An amended step (approved SHA not in the head, full history) is BLOCKED.
- A missing PR head object is UNVERIFIED.
- A missing step head object is UNVERIFIED.
- A shallow clone whose boundary hides the step commit is UNVERIFIED with the unshallow guidance, not BLOCKED.
- A git error, such as a corrupt ref passed in, is UNVERIFIED.
- An ancestor step head reaches READY.
- A Standard work issue is covered by the same check.

**DoD:** close-out cannot reach READY while any approved step commit is missing from the PR head. Missing or shallow history reports UNVERIFIED with the fetch to run, never BLOCKED.
**Commit:** `Require every approved step commit to be an ancestor of the PR head`

---

## G-3 — Close the Stop-gate commit bypass and the stamp race
**Why third:** G-6's `.gitignore` turns this repo's tree clean, which makes the bypass live here.

**Approach** (`scripts/hooks/check-gate.sh`). One rule replaces both the clean-tree exit and any notion of a HEAD baseline: **a stop is skipped only when the complete current state was verified green.** "Clean tree" and "same HEAD" are never reasons to skip on their own.
1. Remove the clean-tree early exit at `:20-23`.
2. Define the state hash over the complete state:
   - `HEAD^{tree}`, or `unborn` in a repo with no commits;
   - the existing porcelain status, `git diff HEAD` and untracked-file hashes.

   Two clean trees at different commits, or a clean tree and a dirty tree over the same commit, never share a hash.
3. **Green stamp** (`agentic-flow-check-gate-state`, as today): written only after a green run, and only when the state recomputed after the run equals the state hashed before it. A stop whose current state equals the green stamp exits 0 without running `make check`. This is the only reuse of a verification.
4. If the state changed during a green run, there may be no next turn to catch it, so the changed state must not end the turn unverified:
   - Run `make check` once more against the new state, and compare the state again after that run.
   - Green and unchanged: stamp that state and allow.
   - Red, or changed again: block with exit 2. Name the cause, either the failure output or "the tree changed during `make check`; stop editing before ending the turn".
   - The rerun is bounded to one. It fits inside the hook's 180 s timeout for this repo (1.7 s) and a fresh adopter (5.5 s). A stack whose `check` needs more than half the timeout must raise the hook timeout, and `METHODOLOGY.md` §8 says so.
5. **Acknowledged-red record** (`agentic-flow-check-gate-red`, new), kept separate from the green stamp and never read as green. When the gate is red, or the state keeps changing, and `stop_hook_active` is set, the existing loop-safety rule applies: warn and allow. The hook writes the full state hash of that red state to this record and never touches the green stamp. A later stop whose state equals this record repeats the warning and allows without re-running. A red commit made by someone else then costs one blocked stop per distinct state, not one per turn. Any other state, including the same `HEAD` with a different working tree, runs the gate.
6. Write both records atomically, as today. A record that cannot be written disables reuse for that stop: the gate runs. It never allows a skip.
7. Update the stamp paragraph in `METHODOLOGY.md` §8 (worktree isolation).

Cost: a clean state that was never verified (a fresh checkout, `git pull`, a branch switch) now runs the gate once on the next stop. That is 1.7 s here and 5.5 s in a fresh adopter.

**Test** (`make test-one F=hooks`, using a fixture `Makefile` whose `check` target writes a marker file so the test can tell whether it ran, and fails while a sentinel file is present). Failure paths first:
- **Verified fix, then discarded.** `HEAD` contains broken code. An uncommitted fix makes the stop pass. The fix is discarded (`git checkout -- .`). The next stop on the now-clean tree must run `check` and block with exit 2.
- A red commit on a clean tree blocks with exit 2.
- An edit during `make check` never lets the changed state exit 0 unverified. Edit once, with the rerun green: exit 0, and the green stamp names the final state. Edit during both runs: exit 2, no green stamp. Rerun red: exit 2. Each case asserts which state, if any, the stamp names.
- `stop_hook_active` on red: exit 0 with the warning. The red record names that state, and the green stamp is unchanged. A next stop in the same state warns without running `check`. After any edit, the next stop runs `check`.
- `stop_hook_active` with an edit during both runs: exit 0 with the warning, and the green stamp is unchanged.
- A clean state that matches the green stamp does not run `check`.
- A clean state that was never verified (fresh fixture, or `HEAD` moved to another commit) runs `check` once.
- An unwritable git dir: the gate runs on every stop and never skips.

**DoD:** a stop ends with exit 0 only in two cases. Either a green run covered exactly the final state, or the documented `stop_hook_active` warning was given for exactly that state. The green stamp is written only by a green run of the state it names.
**Commit:** `Gate committed work at Stop and stamp only the state that was checked`

---

## G-4 — Fail closed when a guard hook times out
**Why here:** it is independent of the steps around it, and is small.

**Approach:**
1. Confirm in the hooks reference (<https://code.claude.com/docs/en/hooks>, "Block the action when a hook fails") what `onFailure: "block"` covers: timeout, crash, non-2 exit. Also confirm its minimum version, 2.1.295 as of this audit, and how older versions treat the field. Quote what you find in the commit body.
2. Add `"onFailure": "block"` to the `block-push`, `scan-secrets` and `block-git-add-all` handlers in `.claude/settings.json`. Leave `require-step-comment` fail-open: it calls the network, and a GitHub outage must not block every Bash call.
3. `scripts/doctor.sh`: fail when one of the three handlers lacks the field. If older Claude Code versions reject the field, also warn when `claude --version` is below the minimum, and skip that warning when `claude` is absent.
4. Codex: check whether `.codex/hooks.json` supports an equivalent. If it does, set it. If it does not, say so in the commit body; close-out records the accepted risk.

**Test** (`make test-one F=contracts`). Failure path first: a fixture `settings.json` missing the field fails doctor. Then: the shipped file has the field on exactly those three handlers.

**DoD:** a timed-out push, secret or broad-staging guard blocks the call in Claude Code, and doctor enforces the wiring.
**Commit:** `Block guarded Bash calls when their guard hook fails or times out`

---

## G-5 — Keep an adopter's gate green without an installation record
**Why here:** every customized adopter's `make check` fails today (#109); this is the adopter-facing fix this phase can make without the upgrade redesign.

**Approach** (`scripts/shell-inventory.sh`):
1. Detect "adopted project" the way `scripts/self-test.sh` already does: `scripts/export.sh` is absent.
2. When the installation record is missing in an adopted project, walk the manifest **destinations** of export rows in active scopes, and not the sources. A missing destination in an active scope fails with `shell inventory: missing installed file <dest>; run scripts/doctor.sh`. Excluded scopes are skipped.
3. The scaffold repo keeps walking sources. When the record exists it stays the authority, as today.

**Test** (`make test-one F=contracts`, or the group that already holds shell-inventory regressions). Failure path first: an exported fixture with the installation record removed passes `shell-inventory.sh --syntax`. Today it fails with `missing manifest source templates/harness/CLAUDE.md`. Then: a deleted active-scope script fails naming the file, and a missing excluded-scope file passes.

**DoD:** `make check` is green in an adopted project that has no installation record, and still fails when an installed harness file is actually missing.
**Commit:** `Walk installed destinations when an adopter has no installation record`

---

## G-6 — Ignore OS files, settle stale docs, clear labels on close
**Why last:** the `.gitignore` depends on G-3, and the rest is hygiene.

**Approach:**
1. Add a root `.gitignore` containing `.DS_Store`. Confirm that `make build` does not export it and that `check-payload-manifest.sh` stays green.
2. `docs/inprogress/context_optimization.md`: confirm from GitHub that #46–#51 are closed. Tick its Tracker with the issue numbers, set TRIAGE to ✅ Done with one line saying it shipped in `0.10.0` under #46, and move it to `docs/done/`. Set both assurance proposals to 🕰️ Superseded and move them to `docs/done/`. Regenerate the index with `scripts/docs-index.sh`.
3. Clear workflow labels after closing an issue:
   - `review-execution/SKILL.md` and `.opencode/agent/code-reviewer.md`: after `gh issue close <N>`, remove `agent:opencode,needs-review`. The skill stays ≤ 1000 words.
   - The close-out paragraph in `CLAUDE.md` (root and template): remove `agent:claude,needs-closing` after closing. Word-neutral.
   - `scripts/plan-to-issues.sh:467`: remove workflow labels when closing a removed step.

   Remove labels after the close, because the Standard close check needs `needs-closing` present at close time.
4. `METHODOLOGY.md:330`: state the real rule. The reviewer closes Strict steps, the closer closes Standard issues and trackers, and `Fixes #N` stays for traceability.

**Test** (`make test-one F=plan-to-issues`). Failure path first: the fake `gh` records that closing a removed step also removes its workflow labels. Then `make check` (docs index, memory index, ceilings).

**DoD:** `git status` is clean in this repo after a checkout. `docs/inprogress/` holds only live documents. No contract tells an agent to leave labels on a closed issue.
**Commit:** `Ignore OS files, retire stale docs, and clear workflow labels on close`

---

# Close-out (before merge) and publishing (after merge)

## Close-out: Claude, on the PR branch, before final approval

Every repository change of this pass lands before the final-head review, so CI and the reviewer see all of it. The sequence is the one in `CLAUDE.md`.

1. Commit the close-out changes on `codex/gate-and-handoff-fixes`. Each is a repository change, so each goes through CI and the final review:
   - `VERSION` 0.14.0 and a `CHANGELOG.md` entry with migration notes: policy logins are required, `settings.json` gains `onFailure`, adopters merge both.
   - The accepted risks named above: threads are readable by interactive agents until R-19; and Codex guard hooks fail open, if G-4 confirms that.
   - The roadmap 2.6 line.
   - Status, Tracker, TRIAGE set to Done, this document moved to `docs/done/`, and the index regenerated. These go in the last commit.
2. The human pushes. CI runs on that head, and the reviewer posts the final approval for that exact head and run attempt on the tracking issue.
3. Claude runs `scripts/lifecycle-status.sh --doc docs/done/feature-gate-and-handoff-fixes.md --phase close-out --check --verify-evidence`. On READY, Claude closes the tracker without another repository edit. Two GitHub actions that are not repository changes go with it:
   - a closing comment on #113 with the 0.13.3 measurement;
   - a comment on the tracker listing the closed issues that still carry workflow labels, with the exact `gh issue edit` commands.
4. The human runs `--phase pre-merge` and merges.

Any repository edit after step 2 restarts the CI and review round.

## Publishing: human, after merge

G-1 must be on `main` before the repository is public, so this comes after the merge.

1. Scan the full history for secrets with gitleaks and trufflehog. History cannot be unpublished.
2. Decide on the private adopter names in `ROADMAP.md`, two `docs/done/` files, `scripts/self-test.sh`, and issue threads: `autohash`, `film-festival-manager`, `print-traffic`, `collector`. Issues become public with the repo. Removing a name from files is a new change through the normal workflow; it cannot be rewritten out of published history afterwards.
3. Make the repository public.
4. Add a ruleset on `main`: pull request required, `CI gate` required, no force-push or deletion. Keep the default approval requirement for first-time contributors' workflow runs.
5. Run the label-cleanup commands posted at close-out.

---

## Status / Implementation status
- **Evidence schema:** v2
- **Tracking issue:** url=https://github.com/wabkebab/agentic-flow/issues/114
- **Approval:** status=approved; by=wabkebab; at=2026-11-11
- **Implementation head:** source=pr-head
- **Implementation PR:** pending
- **Verification evidence:** source=final-approval-run
- **Review verdict:** source=pr-head-approval
- **Memory:** pending
- Close-out: finalize Status/Tracker, set TRIAGE to Done, move this document and update
  the index in the last repository commit. After human push, obtain CI and a structured
  reviewer approval on the `Tracking issue` for that exact PR head and run attempt.
  Verify this moved file with `--phase close-out`, close the tracker without another
  repository edit, then recheck with `--phase pre-merge` before human merge.
