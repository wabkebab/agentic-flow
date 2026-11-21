<!-- TRIAGE (first pass · 2026-11-21) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict
> Phase 4 of `product-harness-factory-optimization.md`: remove what Phases 0–3 and flow-ergonomics made redundant. This brief takes the non-breaking items (R-12, R-14a, R-16 in part, R-17, R-24, R-25, R-26, R-27). It proposes moving the breaking 1.0 items (R-14b, R-22), the native-review item (R-13, blocked while the repo is private) and the state-store item (R-23, which needs re-measuring) to later briefs. Drafted 2026-11-21 on branch `phase-4`; owner decisions recorded the same day; awaiting review.

# Feature — Harness simplification (Phase 4)

## Tracker
- [ ] s-1 Ship gate runs what CI runs — open
- [ ] s-2 `ship` skips a gate and a push it has already done — open
- [ ] s-3 `ship` adopts a PR opened by hand — open
- [ ] s-4 Native deny rules for every agent CLI, alongside the hooks — open
- [ ] s-5 Lexer hooks removed; the secret scan moves to a git pre-commit hook — open
- [ ] s-6 Upgrade proposes a file only when upstream changed it — open
- [ ] s-7 Scenario-first brief template with a word cap; red-first opt-in — open
- [ ] s-8 Methodology reference split, roadmap cut to the open queue, explainer rewritten — open
- [ ] s-9 Contracts, adoption notes and release notes — open

---

# Part A — Analysis

## Goal

Phase 4 was planned in the 2026-11-11 roadmap as "remove what the above makes redundant". Since then, Phases 0–3 and flow-ergonomics have shipped. Phase 4 also picked up three follow-ups from shipping PR #185 (R-25 to R-27). The owner's goals for this pass:

1. **Less harness to carry.** Delete code whose job is now done better by something else: the 345-line Bash command lexer, upgrade conflicts on files upstream never changed, and instruction text an agent never needs.
2. **A `ship` that doesn't waste the human's time.** One `ship` run should equal one CI run. It shouldn't repeat a 15-minute gate it has already passed, and it shouldn't need a hardware-key touch at an unpredictable moment.
3. **Briefs that say what matters.** Acceptance scenarios lead, with a word cap. Red-first runs only where it proves something.

Success:

- After `ship-gate` passes locally, CI's Test suite and Exported-layout jobs cannot fail on a check the gate skipped (copy budget, shellcheck).
- A second `ship` run on an unchanged, already-pushed head runs no gate and no push. It goes straight to waiting for CI and review.
- No agent session runs `git push`, `git add -A` or a raw workflow-label edit, enforced by each CLI's own permission rules. The lexer and the three hooks built on it are gone.
- `agentic-flow upgrade` on an adopter whose `CLAUDE.md` is customized, after an upstream release that left `CLAUDE.md` unchanged, writes no `.agentic-new` candidate for it (#109).
- The next brief written from the template states its acceptance scenarios before its steps and fits the cap.

## Current state

References are to `phase-4` at `41638d4` (`main` at `3a8930a` plus the follow-up notes).

### What this brief inherits

| Item | Status before this pass | Evidence |
|---|---|---|
| R-12 push isolation for headless stations | **Done** for controller stations: the launcher sets `remote.<r>.pushurl=no-push://disabled` through `GIT_CONFIG_*` and probes it | `scripts/lib/launch.sh:44`, `:236` |
| R-12 lexer hooks | Still in place: `hook-command.sh` (345 lines) feeds `block-push.sh`, `block-git-add-all.sh`, `require-step-comment.sh` and `scan-secrets.sh`, in both `.claude/settings.json` and `.codex/hooks.json` | `scripts/lib/hook-command.sh` |
| R-13 native PR review | **Blocked.** The repo is still private on the free plan, so branch protection and rulesets return 403. R-0f (publish) has not happened | `gh api …/branches/main/protection` → 403 (2026-11-21) |
| R-14a upgrade classification | `.agentic-flow-installation` records `file=<sha256>  <path>` of each installed file. `payload_apply` writes an `.agentic-new` candidate whenever the destination differs from upstream, without checking whether upstream changed | `scripts/lib/payload-apply.sh:228`, `:393-431` |
| R-17 executor cannot edit scenarios | **Already enforced.** Approval binds the normalized brief to a revision, and `ship` refuses a closed doc whose normalized brief differs (it refused flow-ergonomics' close-out for a one-sentence edit) | `scripts/lib/ship.sh:161-166` |
| R-23 state drift | **Not seen on the last run.** flow-ergonomics wrote 121 ledger records for 9 steps, with zero holds and zero `repaired` lines. Phase 2b had printed `repaired #150: hold-projection` two or three times per run | `.git/agentic-flow/ledger/flow-ergonomics.jsonl`; controller output |
| R-24 red-first opt-in | **Mostly done.** `brief.sh` accepts `**Red-first:** none` and `verify-step` runs red-first only when commands are listed. The template still shows a selector by default, so every step gets one | `scripts/lib/brief.sh:73-83`, `scripts/lib/verify-step.sh:180-206` |

### Ship (R-25, R-26, R-27)

PR #185 (flow-ergonomics) shipped on 2026-11-21. Getting from "all steps approved" to "merge" took:

- **Five ship-gate runs** of about 15 minutes each. Two failed on real defects: the `andon.sh` source bug and wall-time ceilings. Three passed and then failed at the push, two on an SSH agent that refused to sign and one on a dropped connection.
- **Three CI runs** of about 30 minutes each. Two failed on checks the gate does not run: the source-layout copy budget (194 copies against 190) and shellcheck SC2100.
- A PR opened by hand from the push link, so its body was empty and e-4's readable PR body went unused.

The causes in code:

- `self-test.sh` checks the copy budget only `elif [ -f "$ROOT/scripts/export.sh" ]`, which is never true in the exported layout `ship-gate` uses (`scripts/self-test.sh:343-352`).
- `make ship-gate` runs `self-test.sh --ship-gate` and never `scripts/shell-inventory.sh --lint`, which `make test` runs (`Makefile:20-23`, `:35-36`).
- `ship_run` always calls `ship_gate`, then `git push`, then creates the PR if `SHIP_PR` is null (`scripts/lib/ship.sh:198-206`). Nothing records a gate result, nothing compares the remote branch with the head, and an existing PR keeps whatever body it was given.

### Hooks (R-12)

The four PreToolUse hooks parse every Bash command with a hand-written lexer to decide whether it is a `git push`, a `git add -A`, a workflow-label write or a commit. Its false blocks (#109, #110) led to the working rule "write the command to a file and run that". That rule walks around the same guards. All three agent CLIs now have native command rules:

- **Claude Code:** `permissions.deny` patterns in `.claude/settings.json` (for example `Bash(git push:*)`), plus an `if` filter on a hook so it runs only for matching commands.
- **Codex:** `prefix_rule(pattern=[…], decision="forbidden")` in a rules file. The operator's `~/.codex/rules/default.rules` already uses `prefix_rule`. The controller gives stations their own `CODEX_HOME` (`.git/agentic-flow/codex-home`), and an untrusted project ignores project-local config, so the rules have to be written where each mode reads them.
- **OpenCode:** `permission.bash` patterns per agent. `code-reviewer.md` already sets `edit: deny` and `bash: ask`.

None of these follows a command into a script it calls. That is intended: `scripts/agentic-flow handoff` must still run `gh`, and the agents are cooperative. The threat the hooks really guard against is an agent's mistake, not an attack (Threat model).

### Upgrade (R-14a, #109)

Every adopter customizes `CLAUDE.md`, `AGENTS.md`, `Makefile` and `.claude/settings.json`. Upgrade compares the adopter's file with the new upstream file, finds them different (because of the customization), and writes an `.agentic-new` candidate on every upgrade, even when upstream did not change that file. The adopter merges by hand, the version stamp waits on that merge, and #109 stays open. The installation record already holds a hash of each installed file. It lacks the upstream hash the file was installed from.

### Briefs and docs (R-16 in part, R-17, R-24)

The last four Strict briefs had Part A of 3,000–8,900 words and Part B of 4,200–8,100 words. `METHODOLOGY.md` is 7,396 words, and §9–§11 (stack assessment, CI shape, engineering standards) are reference material that no routine planning, execution or review step loads. The roadmap is 45 KB, and most of it is decided history. `docs/agentic-flow-explained.html` is hand-maintained, outside the payload, and describes the 0.14 flow (B-4).

## Proposed approach

### Scope: what this pass takes, and what it hands on

The roadmap lists twelve Phase 4 items. Taking them in one brief would mix three breaking changes into a pass that should be easy to review and revert. The recommendation is to split:

| Item | This brief | Later | Why |
|---|---|---|---|
| R-25, R-26, R-27 | s-1 to s-3 | | They cost the most on the last ship and they're contained in `ship.sh` and `self-test.sh` |
| R-12 | s-4, s-5 | | Non-breaking: the guarded behaviour stays, only the mechanism changes |
| R-14a | s-6 | | Non-breaking and fixes #109's main symptom |
| R-17, R-24 | s-7 | | Template and parser; the tooling exists |
| R-16 | s-8, without the reviewer-contract merge | Reviewer-contract merge goes with R-22 | Merging the reviewer files now would be redone by R-22's role-named files |
| R-14b, R-22 | | **1.0 brief** | Both breaking, both rework `CLAUDE.md`/`AGENTS.md`/`Makefile`; the roadmap already says to plan them together |
| R-13 | | **After publishing (R-0f)** | Required reviews and branch protection return 403 on this private repo; nothing to build against |
| R-23 | | **Re-measure first** | The drift that motivated it did not occur on the last run; a store removal in the controller core needs a measured reason |

### Ship (s-1 to s-3)

**s-1, gate parity.** Two ways to close the gap:

- **Option A (chosen 2026-11-21): the exported run gets its own copy budget, and the gate runs the lint.** The exported full run already logs `fixture_file_copy` events; only the assertion is skipped. Measure the exported count, approve it as the exported budget, and assert it in the exported layout as well. Add `shell-inventory.sh --lint` to `ship-gate`; it took about 75 s in CI. A new fixture copy raises both counts, so either budget catches it. This adds about 1.5 minutes to the gate.
- **Option B (rejected): `ship` runs `make test` as well.** This is exact parity with CI's Test suite on macOS, but it adds about 20 minutes (1,173 s) to a 17-minute gate. It catches nothing Option A misses in the record so far: both #185 failures are caught by A, and #174's Linux-only timeout is caught by neither. If a source-layout-only failure ever escapes, switching to B is a one-line change.

**s-2, `ship` skips what it has done.**

- **Gate record.** A green gate writes a record keyed by the head's tree hash, a hash of the gate's implementation (the Makefile target, `self-test.sh` and the groups) and the harness version. This works like the verify record (R-4/T-1). The next `ship` run skips the gate when a record matches. `--force-gate` re-runs it.
- **Push.** Before pushing, `ship` reads the remote branch head over the GitHub API, which uses HTTPS and needs no SSH key. If the remote branch already equals the head, it skips the push.
- **Push prompt.** Right before a real push, `ship` raises the same desktop notification as andon and prints "pushing — touch your key now". That way a gate that ran for 15 minutes doesn't leave a hardware-key prompt unattended.

**s-3, PR adoption.**

- When `SHIP_PR` resolves to an open PR for the branch whose body is empty or is GitHub's default, `ship` writes the generated body with `gh pr edit --body-file`.
- A non-empty body is left alone, and `ship` prints that it kept it.
- A PR whose base differs from the brief's base stops `ship` with exit 3. A different title only prints a warning.

### Hooks (s-4, s-5)

Replace in two steps so the guard never lapses:

1. **s-4 adds the native rules next to the hooks.** Generate them from one list, `config/command-policy.tsv`, which holds the command prefix, the decision and the reason:
   - Claude: `permissions.deny`.
   - Codex: a `.rules` file. The station launcher installs it into the station `CODEX_HOME`, and `doctor` checks that the interactive `~/.codex/rules/` has it.
   - OpenCode: `permission.bash` in the agent files.

   `doctor --stations` (P-1) proves each CLI refuses a denied command through the real launcher.
2. **s-5 deletes the lexer and the three hooks it drives** (`block-push.sh`, `block-git-add-all.sh`, `require-step-comment.sh`), once s-4's probe shows each CLI refuses on its own.
   - The secret scan has to run on every commit, whichever agent or human makes it. It moves to a git `pre-commit` hook installed through `core.hooksPath`, which is vendor-neutral and needs no parsing.
   - `git commit --no-verify` and `-n` go on the deny list.
   - `check-gate.sh` (Stop) and `session-context.sh` (SessionStart) stay; they don't use the lexer.

### Upgrade (s-6)

Add `upstream=<sha256>  <path>` lines to `.agentic-flow-installation`. These are the hashes of the upstream files the installed files came from. Each payload file is then classified on upgrade:

| Adopter file vs new upstream | New upstream vs recorded upstream | Result |
|---|---|---|
| same | any | `same` |
| different | same (upstream unchanged) | `kept`: no candidate; the record keeps the old upstream hash |
| different, and adopter file equals recorded upstream (never customized) | different | `overwrite` |
| different, customized | different | candidate, as today |

A record without `upstream=` lines is an older installation, so it behaves as today, and the first upgrade after this pass writes the lines.

### Briefs and docs (s-7, s-8)

- **s-7 template.** Change `docs/templates/feature-analysis.md` and `security-review.md`:
  - Part B starts with Acceptance scenarios, then Invariants.
  - Steps lose the "which files, which functions" prompt. They keep Why, Approach (intent only), Test, DoD, Verify, Risks and Red-first.
  - `**Red-first:**` defaults to `none`. A step that adds a regression test names its selector.
  - `brief.sh` enforces a Part B word cap of **1,500 + 500 × steps** (owner's choice, 2026-11-21). The 1,500 covers the shared sections (scenarios, invariants, verification); 500 per step matches the median step of the controller-run briefs (518–647 words). Against past briefs it passes distinct-identities, deterministic-stations, test-streamlining and flow-ergonomics, and rejects station-hardening (8,021 > 7,500) and line-controller (5,278 > 5,000). Part A stays uncapped; the 800-word step packet cap is unchanged.
  - The approval binding already makes the scenarios uneditable; the template says so.
- **s-8 docs.**
  - Move `METHODOLOGY.md` §9–§11 to `docs/reference/` files and leave one-line pointers.
  - Cut the roadmap to the open queue plus a link to a `docs/done/` history file.
  - Rewrite `docs/agentic-flow-explained.html` by hand for the current flow (owner's choice, 2026-11-21). It is 59 KB in 11 sections, last changed in substance at 0.14.0, and never mentions `agentic-flow run`, the controller, `ship`, `start`, `verify-step`, andon or the journal. To stop it drifting again, a contracts test checks that it names every subcommand in `scripts/agentic-flow`'s usage text.

## Interface (before the implementation)

```
# s-1  Makefile
ship-gate: self-test.sh --ship-gate, then scripts/shell-inventory.sh --lint
# self-test.sh: in the exported layout, assert fixture_file_copy <= EXPORTED_LIMIT
#   (measured on the s-1 commit, approved in the commit body; source limit stays 194)

# s-2  gate record
<git-common-dir>/agentic-flow/gate/<plan>.json
{ "v":1, "tree":"<sha40>", "gate_hash":"<sha256>", "harness":"<version>",
  "passed_at":<epoch> }
ship ... [--force-gate]         # ignore a matching record
# remote head check: gh api repos/<repo>/git/ref/heads/<branch> -> .object.sha
#   404 -> push; equal -> skip push; other -> push (fast-forward only, as today)

# s-3  ship output lines
PR #<n>: wrote generated body | kept existing body | base <x> differs from brief base <y> (exit 3)

# s-4  config/command-policy.tsv   (tab-separated; one source for all CLIs)
prefix<TAB>decision<TAB>reason
git push	deny	the human pushes
gh pr merge	deny	the human merges
git add -A	deny	stage files by name
git add .	deny	stage files by name
git add --all	deny	stage files by name
git commit --no-verify	deny	the secret scan runs in pre-commit
git commit -n	deny	the secret scan runs in pre-commit
gh issue edit	deny	workflow writes go through handoff
gh issue close	deny	workflow writes go through handoff
gh issue reopen	deny	workflow writes go through handoff
gh label	deny	workflow writes go through handoff
scripts/render-command-policy.sh --check   # rendered files match the TSV

# s-5  git hook
core.hooksPath=scripts/git-hooks ; scripts/git-hooks/pre-commit -> scripts/hooks/scan-secrets.sh --staged

# s-6  .agentic-flow-installation (added lines)
upstream=<sha256>  <path>
# payload_apply classification adds: kept

# s-7  brief.sh
bad("Part B is N words; cap C")         # C = 1500 + 500 * steps; counts '# Part B' up to '## Status'
```

## Threat model

There is no new trust boundary. The guards in s-4 and s-5 stop a **cooperative agent's mistakes** (a push, a blanket stage, a raw label edit, a skipped secret scan). They aren't meant to stop an agent that tries to evade them, and neither was the lexer: `bash script.sh` always walked around it (E-2).

The real controls stay as they are:
- Stations get no push credential (`launch.sh` disables pushurl and gives no `contents: write` token).
- Identities are distinct per role.
- The human merges.
- Public comments pass the trusted packet builder (R-19).

What changes:
- **Secret scan.** It moves from an agent-only hook to a git hook. It now also covers human commits and commits made from inside a script, which the PreToolUse hook missed.
- **Lost check.** `require-step-comment.sh`'s check that a commit-closing step has a comment is dropped. That check predates `handoff`: `handoff submit` now owns step evidence, and the controller verifies `Fixes #N` on the head.
- **Remote head check.** s-2 reads the remote branch over the API with the operator's existing `gh` token, which is read-only use of an existing credential.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---|---|---|---|
| `gh api …/git/ref/heads/<branch>` (s-2) | push as today (the push is then a no-op or fast-forward) | push as today | n/a |
| `gh pr edit --body-file` (s-3) | `ship` warns and continues; the PR keeps its body | same | n/a |
| Desktop notification (s-2) | ignored; the printed line remains | ignored | n/a |
| Gate record read (s-2) | n/a | missing or invalid record → run the gate | a record for another tree is ignored |
| Codex/OpenCode rule install (s-4) | n/a | `doctor --stations` fails the station probe and names the CLI | a CLI that ignores the rule keeps its hook until s-5's probe passes |
| `pre-commit` hook (s-5) | `scan-secrets.sh` keeps its bounded gitleaks run | a scan error blocks the commit (fail closed, as today) | n/a |

Bounds: the gate record is one file per plan. The policy TSV is capped at 100 rows by the renderer. Upgrade reads one record line per payload file.

## Out of scope / What NOT to build in this pass

- R-13 native PR review, until the repo is public and branch protection exists.
- R-14b file split and R-22 role-neutral roles. Both are breaking, and they go into one 1.0 brief.
- R-23 removing state stores. Re-measure drift over the next two controller runs first.
- Merging the two reviewer contract files (R-16 part). That happens with R-22.
- Parallel App jobs in CI. They are deferred until CI is stable (accepted risk `fe-1`).
- Any change to the controller's journal, ledger or recovery.
- A `ship` that pushes over HTTPS by default. The operator's git protocol stays theirs. s-2 only makes the push short and announced.

## Decisions (owner, 2026-11-21)

- **Scope split:** accepted. R-13, R-14b, R-22 and R-23 are out of this brief.
- **s-1:** Option A (exported copy budget plus lint).
- **Explainer:** rewrite by hand for the current flow, with a contracts test against drift.
- **Role-signing:** `feature-role-signing.md` ships after the 1.0 brief that reworks roles.
- **Brief word cap:** Part B at 1,500 + 500 × steps.

## Open questions

- None blocking.

---

# Part B — Implementation Brief

> **Audience:** the implementing agent (Codex). The steps run in this order:
> 1. ship fixes first, so this plan's own close-out benefits (s-1 to s-3);
> 2. then the guard swap, with the new rules added before the old hooks are removed (s-4, s-5);
> 3. then upgrade (s-6), briefs and docs (s-7, s-8), and contracts and release notes (s-9).
>
> One logical commit per step; do not bundle. Stage files by name. Write why-first commit bodies. The brief carries intent, interface, invariants and acceptance scenarios; you choose files and functions.

```agentic-flow-plan
id: harness-simplification
profile: strict
tracking: Plan: Harness simplification (Phase 4)
branch: phase-4
steps: s-1 s-2 s-3 s-4 s-5 s-6 s-7 s-8 s-9
```

## Prerequisite

`main` at `3a8930a` (PR #185 merged), merged into `phase-4`. `.agentic-flow-review-policy` says `identity-mode=distinct-account`; if it does not, stop and tell the human.

## Branch
Base: `main`. One branch and one PR for the whole brief: `phase-4`. Each step is one commit with `Fixes #N`. Review fixes land as new commits; never amend after a handoff. The branch is checked out in the plan worktree at `.git/agentic-flow/worktrees/harness-simplification`. Do not check it out anywhere else. If `main` moves, merge it in; never rebase.

## Acceptance scenarios (written at Spec; the executor does not edit these)

**Ship**
1. **The gate fails where CI would.** In a fixture, add one fixture copy beyond the exported budget: `make ship-gate` fails, naming the exported count and limit. Add a shellcheck warning to a shipped script: `make ship-gate` fails in the lint phase. With neither, the gate passes. The source-layout limit (194) and its tests are unchanged.
2. **A gated head is not gated again.** A `ship --wait-review` run that passes the gate writes the record. A second run on the same head runs no `make ship-gate` (the fake `make` records calls) and reaches the CI wait. Any of these runs the gate again:
   - a commit that changes the tree;
   - a change to `self-test.sh`;
   - a different harness version;
   - a corrupt record;
   - `--force-gate`.
3. **A pushed head is not pushed again.** When the fake API reports the remote branch at the head, `ship` makes no `git push`. When it reports another SHA, or 404, or the API fails, `ship` pushes as today. Before a real push, `ship` prints the key-touch line and calls the desktop notifier once.
4. **A hand-made PR gets the generated body.** An open PR with an empty body gets `gh pr edit --body-file` with the scenario-14 body (flow-ergonomics). A PR with a non-empty body is untouched, and `ship` says it kept it. A PR whose base differs from the brief exits 3 before any push or edit. A failed `gh pr edit` warns and continues.

**Guards**
5. **One policy, three renderings.** `config/command-policy.tsv` renders to Claude `permissions.deny`, a Codex `.rules` file and OpenCode `permission.bash`. `render-command-policy.sh --check` fails when any rendered file differs from the TSV. The same holds in `templates/harness/` and in a fresh export.
6. **Each CLI refuses on its own.** With the hooks disabled, the station probe for each assigned CLI (fake CLIs in tests; the real CLIs in `doctor --stations`) is asked to run `git push`, `git add -A` and `gh issue edit 1 --add-label x`. Each is refused by the CLI's own rule. `scripts/agentic-flow handoff …` and `git-codex commit` / `git-claude commit` with named files are allowed.
7. **The secret scan covers every commit.** A commit that stages a credential-shaped fixture (built with `printf`) is blocked by the `pre-commit` hook. That holds for a commit from a script, a commit from a station and a human `git commit`. `AGENTIC_ALLOW_SECRET=1` still overrides. After s-5, `hook-command.sh`, `block-push.sh`, `block-git-add-all.sh` and `require-step-comment.sh` no longer exist, no settings file references them, and `doctor --check` reports no missing hook.

**Upgrade**
8. **Untouched upstream, customized file: no candidate.** In an adopter twin with a customized `CLAUDE.md`:
   - An upgrade to a release whose upstream `CLAUDE.md` is byte-identical to the recorded `upstream=` hash writes no `.agentic-new` file and reports `kept`, and the version stamp advances.
   - An upgrade where upstream changed writes a candidate, as today.
   - A file the adopter never changed is overwritten.
   - An installation record without `upstream=` lines behaves exactly as today, and that first upgrade writes the lines.

**Briefs and docs**
9. **Template and cap.** A brief from the new template parses and has Acceptance scenarios before the first step. Red-first lines are `none` except in steps that name a selector. A Part B over 1,500 + 500 × steps words fails `brief_parse`, naming the count and the cap; exactly the cap passes. Every approved brief in `docs/done/` still normalizes to its recorded hash; the cap applies only to briefs approved after this pass (a brief with an `Approval:` rev before the s-7 commit is exempt).
10. **Reference split.** `METHODOLOGY.md` §9–§11 live in `docs/reference/` with pointers left behind. The roadmap holds only open items and a history link. The explainer describes the current flow, and a contracts test fails when a subcommand in `scripts/agentic-flow`'s usage text is missing from it. `scripts/docs-index.sh`, `check-harness-sync.sh` and the payload manifest agree with the new paths, in this repo and in a fresh export.

## Invariants (every step)
- Bash 3.2: no `mapfile`, no associative arrays; guard empty arrays under `set -u`.
- Payload membership lives in `config/payload.tsv` only.
- No literal placeholder or credential-shaped string in any file; build them with `printf`.
- A library sources every library whose functions it calls (memory `library-sources-its-dependencies`).
- Hermetic tests: fake `gh`, fake `git` remotes and fake CLIs on `PATH`; no network.
- No guard lapses between steps. Until s-5 lands, the hooks stay in place and working.
- Copy budget and wall-time ceilings: no step raises them, except s-1, which records the exported budget once. A new scenario needs a ceiling line sized from its measured time.
- Before handing off, run `scripts/shell-inventory.sh --lint` as well as the step's Verify (memory `lint-before-push`).

## Definition of done (whole brief)
- Every step's DoD is met and all 10 acceptance scenarios pass as tests.
- `make check`, `make test`, `make ship-gate`, `make build` and `scripts/doctor.sh --check` are green here and in a fresh export.
- This plan's own `ship` runs the gate once and pushes once. A re-run after the final review runs neither. The close-out records gate runs, pushes and CI runs.
- #109 can be closed with a link to scenario 8's test.

## Verification commands
```bash
make check                          # per step; also run by the Stop hook
make test-one F=<group>             # the group a step names
make test-one F=controller S=<tag>  # controller scenarios
make test                           # end of brief
make ship-gate
make build
scripts/shell-inventory.sh --lint
scripts/doctor.sh --check
```

**Station sandbox.** The executor's sandbox cannot run `ps`, so tests that run `scripts/lib/recovery.pl` fail there. Do not weaken the sandbox or skip the test. The controller's own `verify-step` runs those groups outside the sandbox.

---

## s-1 — Ship gate runs what CI runs
**Why first:** every later step ships through this gate, and the last ship lost two CI rounds to its gaps.

**Approach:**
1. Make the copy-budget assertion run in the exported layout against its own limit. Measure the exported count on this commit and state it in the commit body. Keep the source-layout limit and its boundary tests unchanged.
2. Add `scripts/shell-inventory.sh --lint` to `make ship-gate` in the repo `Makefile` and the harness template, and have the exported project's `ship-gate` run it the same way.
3. Add a boundary test for the exported limit (limit passes, limit+1 fails), shaped like the source-layout test in `contracts.sh`.

**Test:** scenario 1. Failure path first: one copy over the exported limit; a shellcheck warning in a shipped script.

**DoD:** scenario 1 passes; the source-layout copy tests are unchanged.
**Verify:** `make test-one F=contracts`
**Risks:** an exported count that varies between runs (measure twice); the lint running before the suite and hiding suite failures; template and root `Makefile` drifting.
**Red-first:** `scripts/self-test.sh --only contracts` — scripts/tests/contracts.sh
**Commit:** `Run the copy budget and shellcheck inside the ship gate`

## s-2 — `ship` skips a gate and a push it has already done
**Why second:** the gate is now the slowest part of `ship`, and the last ship ran it five times.

**Approach:**
1. Write the gate record (Interface) after a green gate. Before gating, skip when the record matches the head tree, the gate hash and the harness version. Define the gate hash as the hash of the files the gate runs, listed in one place.
2. Read the remote branch head over the API before pushing. Skip the push when it equals the head. On any error, push as today.
3. Before a real push, call the existing desktop notifier (`andon_desktop` or a shared helper) and print one line asking for the key touch.
4. Add `--force-gate` to `ship` and the CLI usage text.

**Test:** scenarios 2 and 3. Failure path first: a corrupt record, an API 500, a record for another tree.

**DoD:** scenarios 2 and 3 pass; the single-push scenario 7 from flow-ergonomics still passes.
**Verify:** `make test-one F=controller S=ship`
**Risks:** a record that outlives a gate change (missing a file from the gate hash); skipping a push when the remote is a different repo; the notifier failing the run.
**Red-first:** `scripts/self-test.sh --only controller --scenario ship` — scripts/tests/controller.sh
**Commit:** `Skip the ship gate and push when the head was already gated and pushed`

## s-3 — `ship` adopts a PR opened by hand
**Why third:** same file and fixtures as s-2; small.

**Approach:**
1. When `ship` resolves an existing open PR for the branch, decide from its body. An empty body, or GitHub's default template body, gets the generated body. Anything else is kept.
2. Check the PR's base against the brief's base before any push or edit; a mismatch exits 3.
3. Reuse the e-4 PR body renderer; do not add a second one.

**Test:** scenario 4. Failure path first: a base mismatch, and a failed `gh pr edit`.

**DoD:** scenario 4 passes.
**Verify:** `make test-one F=controller S=ship`
**Risks:** overwriting a body the human wrote; editing a PR from a fork or another repo.
**Red-first:** `scripts/self-test.sh --only controller --scenario ship` — scripts/tests/controller.sh
**Commit:** `Write the generated body into a PR opened by hand`

## s-4 — Native deny rules for every agent CLI, alongside the hooks
**Why fourth:** the hooks can only go once each CLI is shown to refuse on its own; this step adds that proof without removing anything.

**Approach:**
1. Add `config/command-policy.tsv` (Interface) and a renderer, `scripts/render-command-policy.sh`, with `--check`. It writes:
   - Claude `permissions.deny` into `.claude/settings.json`, merged by key;
   - a Codex rules file shipped in the payload and installed by the launcher into the station `CODEX_HOME`;
   - `permission.bash` entries in the OpenCode agent files.
2. Before writing, confirm each CLI's rule syntax and matching against the installed versions with a fake-free local probe, and record the versions in the commit body. If a CLI cannot express a rule, stop and report; do not write a partial policy.
3. Extend `doctor --stations` and `doctor --check`:
   - the station probe asks each CLI to run a denied command and expects a refusal;
   - `--check` fails when the rendered files differ from the TSV, or when the interactive `~/.codex/rules/` lacks the policy. That check reports a warning with the install command; it is not a failure.
4. Add the renderer and the TSV to the payload and the harness sync check.

**Test:** scenarios 5 and 6 (fake CLIs that honour or ignore rules). Failure path first: a CLI that ignores the rule (the probe must fail), a TSV row with a tab inside the prefix, and a rendered file edited by hand.

**DoD:** scenarios 5 and 6 pass with the hooks still active.
**Verify:** `make test-one F=stations S=launch` and `make test-one F=hooks`
**Risks:** a rule pattern that also blocks `scripts/agentic-flow handoff` or the `git-codex` wrapper; Codex ignoring project-local rules in untrusted mode (install into the station `CODEX_HOME`, do not rely on project config); clobbering user settings when merging Claude settings.
**Red-first:** `scripts/self-test.sh --only stations --scenario launch` — scripts/tests/stations.sh
**Commit:** `Add one command policy rendered into each agent CLI's own deny rules`

## s-5 — Lexer hooks removed; the secret scan moves to a git pre-commit hook
**Why fifth:** s-4 proved the replacement; this deletes the largest single piece of harness code.

**Approach:**
1. Add `scripts/git-hooks/pre-commit`, which runs the existing secret scan on the staged diff, and set `core.hooksPath` in `init.sh`, in the adoption steps and in `doctor --check`. Keep `AGENTIC_ALLOW_SECRET=1`.
2. Remove the PreToolUse entries for `block-push.sh`, `block-git-add-all.sh`, `require-step-comment.sh` and `scan-secrets.sh` from `.claude/settings.json` and `.codex/hooks.json` (root and template). Delete `block-push.sh`, `block-git-add-all.sh`, `require-step-comment.sh` and `hook-command.sh`, and their tests.
3. Keep `check-gate.sh` and `session-context.sh`.
4. Leave the `CLAUDE.md`/`AGENTS.md` wording to s-9. Here, only remove what references a deleted file.

**Test:** scenario 7. Failure path first: a credential-shaped fixture committed from a script, from a station and by a human; and `--no-verify` refused by each CLI's policy.

**DoD:** scenarios 5 to 7 pass; no file references a deleted hook; `make test` group counts and wall-time ceilings shrink and are updated in the same commit.
**Verify:** `make test-one F=hooks` and `make test-one F=export`
**Risks:** a worktree that does not inherit `core.hooksPath` (set it in the common config); an adopter's existing `core.hooksPath` (husky and similar) overwritten — detect and refuse, telling the human to chain it; losing a hook check that has no rule equivalent (list each deleted check and its replacement in the commit body).
**Red-first:** `scripts/self-test.sh --only hooks` — scripts/tests/hooks.sh
**Commit:** `Replace the command-lexer hooks with native deny rules and a pre-commit secret scan`

## s-6 — Upgrade proposes a file only when upstream changed it
**Why sixth:** independent of the guards; fixes #109's recurring candidates.

**Approach:**
1. Record `upstream=<sha256>  <path>` for each installed payload file, at install and at upgrade. Keep the existing `file=` lines.
2. Add the `kept` classification (table in Part A) to `payload_apply` and report it in the upgrade summary. A file kept this way keeps its old `upstream=` hash, so the next upstream change is still detected.
3. The version stamp advances when no candidate was written, so an adopter no longer promotes `.agentic-flow-candidate-version` by hand after a merge in which upstream changed nothing.

**Test:** scenario 8 on the adopter twin fixture (R-15). Failure path first: a record without `upstream=` lines; an `upstream=` hash for a file no longer in the payload; a path traversal in a record line.

**DoD:** scenario 8 passes; existing upgrade tests pass unchanged.
**Verify:** `make test-one F=upgrade`
**Risks:** marking a customized file `kept` when upstream changed only in whitespace (hash bytes, never normalize); recording the adopter's hash as upstream.
**Red-first:** `scripts/self-test.sh --only upgrade` — scripts/tests/upgrade.sh
**Commit:** `Keep customized files on upgrade when upstream did not change them`

## s-7 — Scenario-first brief template with a word cap; red-first opt-in
**Why seventh:** template and parser only; after the code steps so this brief's own steps are not reshaped mid-run.

**Approach:**
1. Reorder `docs/templates/feature-analysis.md` and `security-review.md` Part B as in Part A. `**Red-first:**` defaults to `none` with a one-line note on when to name a selector.
2. Add the Part B cap to `brief.sh` with the exemption in scenario 9. Do not change normalization, so approved briefs keep their hashes.
3. Update the planner contract text that tells the planner what a step must contain (s-9 edits the contracts; here, only the template's own comments).

**Test:** scenario 9. Failure path first: a Part B one word over the cap for its step count; an approved legacy brief over the cap.

**DoD:** scenario 9 passes; every brief in `docs/done/` still parses.
**Verify:** `make test-one F=plan-to-issues`
**Risks:** the cap counting the plan block or the Status section; the exemption keyed on something an executor can edit.
**Red-first:** `scripts/self-test.sh --only plan-to-issues` — scripts/tests/plan-to-issues.sh
**Commit:** `Lead briefs with acceptance scenarios, cap Part B, and make red-first opt-in`

## s-8 — Methodology reference split, roadmap cut to the open queue, explainer rewritten
**Why eighth:** docs only, after every behaviour change so the moved text is final.

**Approach:**
1. Move `METHODOLOGY.md` §9–§11 into `docs/reference/`, one file per section, and leave a one-line pointer for each. Fix every inbound link.
2. Move the roadmap's decided history into `docs/done/` (the docs-index rules decide the file name and stage) and keep only open items, decisions still pending and links.
3. Rewrite `docs/agentic-flow-explained.html` for the current flow: start, plan and approval, plan-to-issues, the controller's stations, journal and holds, andon, `verify-step`, close-out and `ship`, `clean`. Keep its existing style. Add the contracts test from scenario 10.
4. Update `config/payload.tsv`, the docs index and `check-harness-sync.sh` for the new paths.

**Test:** scenario 10. Failure path first: a dangling link (add a link check over `docs/` and the root Markdown if none exists).

**DoD:** scenario 10 passes; `METHODOLOGY.md` shrinks by the three sections.
**Verify:** `make test-one F=export` and `make check`
**Risks:** an exported adopter losing a file it links to; the docs index rejecting a new root-level file (memory `docs-index-stage-allowlist`); the explainer test matching a subcommand name inside unrelated text.
**Red-first:** none
**Commit:** `Move methodology reference sections out, cut the roadmap to the open queue, rewrite the explainer`

## s-9 — Contracts, adoption notes and release notes
**Why last:** describes the shipped behaviour once.

**Approach:**
1. `CLAUDE.md`, `AGENTS.md` (root and `templates/harness/`): replace the six-hooks list with the command policy, the git pre-commit hook, the Stop gate and the SessionStart hook. Remove the lexer gotchas. Do not raise a contract word ceiling.
2. `METHODOLOGY.md` §8, `ADOPTION.md` and `README.md`: describe the policy, `core.hooksPath` and the `ship` re-run behaviour.
3. `CHANGELOG.md` `0.20.0` and `VERSION`. Note the adopter actions: run `doctor --check` and install the Codex rules for interactive use.

**Test:** the contracts group, harness-sync and measure-harness checks.

**DoD:** the docs describe what ships; `make check` and `make test` pass.
**Verify:** `make test-one F=contracts`
**Risks:** root and template contracts drifting; a word ceiling raised instead of text cut.
**Red-first:** none
**Commit:** `Document the command policy, pre-commit secret scan and ship re-runs; release 0.20.0`

---

## Status / Implementation status
<!-- Finalized by the closer before the last repository commit. -->
- **Evidence schema:** v2
- **Tracking issue:** pending
- **Approval:** pending
- **Implementation head:** source=pr-head
- **Implementation PR:** pending
- **Verification evidence:** source=final-approval-run
- **Review verdict:** source=close-out-attestation
- **Memory:** pending
- Close-out: `ship` finalizes Status and Tracker, sets TRIAGE to Done, and commits this
  document's move and the updated index before the first push. It opens the PR and
  waits for CI. The reviewer runs `final-approve` to record the PR, head, and run attempt
  on the tracking issue. `ship` verifies that evidence, closes the issue, and runs
  the pre-merge check before the human merges. If a closer command is unavailable,
  commit the staged close-out and rerun `ship`.
