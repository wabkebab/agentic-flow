<!-- TRIAGE (first pass · 2026-11-11) -->
> **Type:** Product Analysis · **Status:** ✅ Decided
> Audit of the harness at `0.13.3` (`757d299`) against current model and CLI capabilities, with a phased remediation plan that turns the human from relay into supervisor. Decided 2026-11-11; the four Feature briefs it lists are not written yet and nothing is executed.

# Product Analysis — Harness optimization and the software-factory step

## Goal / context

Decide how to change the harness so that it:

1. uses what current models and agent CLIs can do,
2. stops repeating steps,
3. moves work between models without the human relaying it,
4. spends fewer tokens,
5. loses its race conditions and over-engineered parts,
6. borrows what is useful from "software factory" practice.

The audit read the role contracts, `METHODOLOGY.md`, every script and hook, the CI workflow, the issue history (#1–#113), the accepted-risk register and the roadmap. Timings were taken on this machine on 2026-11-11.

**Headline.** The harness is honest and well tested, and the human is its conveyor belt. Every handoff between Claude, Codex and OpenCode is started by hand, and the most expensive model does the bookkeeping. The label state machine is already a work queue. Nothing consumes it. The largest gains come from adding a small line controller and making the mechanical stations deterministic scripts. More review ceremony would not have caught the defects that escaped (see F-1).

## What the evidence says

### Baselines

| Measure | Value | Source |
|---|---|---|
| Fast gate here | 1.7 s | `time make check` |
| Fast gate in an adopter | 89.5 s per turn | #113 (autohash) |
| Four PreToolUse hooks per Bash call | 90–132 ms | timed with a small and a 6 KB command |
| Static role bundles | 1,692 / 2,780 / 2,691 words; ceilings 1,700 / 2,800 / 2,700 | `scripts/measure-harness.sh` |
| Feature brief size | 1.7k–16.7k words | `wc -w docs/done/*.md` |
| `scripts/self-test.sh` | 3,905 lines, 212 KB; touched by 109 of 171 non-merge commits | `git rev-list --count` |
| Last Strict pass (#93) | 12 steps, 7 days open, close-out 11:06 → 19:52 on the last day | issue timestamps |
| Human touches, one Standard change | about 12, of which 3 are decisions | counted from the contract (table in A-1) |
| Defects that escaped the last passes | #109, #110, #113 | open and closed bug issues |
| Branch protection | unavailable: private repo on the free plan | `gh api …/branches/main/protection` returns 403 |

### What works and should stay

- The `Makefile` as the one executable source of truth.
- Label pairs as a queue, and the one-directional doc → issues flow.
- The bounce cap of two before the human is called.
- A reviewer on a different model family (`glm-5.2`). Model diversity is real independence, which account names are not.
- Hermetic tests against a fake `gh`.
- The never-push rule.
- Hook latency. It is not a problem and needs no work.

---

## Findings

Severity uses the project scale from `METHODOLOGY.md` §5.

### A. Flow: the human is the message bus

**A-1 (High). No station pulls its own work.** All seven comments on #99 come from one account, and `CLAUDE.md` describes the reviewer as "human-operated today". One Standard change needs these touches:

| # | Touch | Decision? |
|---|---|---|
| 1 | Ask Claude for the plan | — |
| 2 | Approve the plan | yes |
| 3 | Approve `plan-to-issues --apply` | repeats 2 |
| 4 | Start Codex on the issue | — |
| 5 | Start OpenCode on the review | — |
| 6–7 | Relay a bounce and its re-review | — |
| 8 | Start Claude's close-out prep | — |
| 9 | Push, open the PR | yes |
| 10 | Start OpenCode's final approval after CI | — |
| 11 | Start Claude's verify-and-close | — |
| 12 | Pre-merge check, merge | yes |

A 12-step Strict pass multiplies rows 4–7 by twelve.

**A-2 (Medium). One decision is approved twice.** The plan is approved, then `--apply` needs a second go-ahead "in this turn" (`plan-to-issues/SKILL.md` step 5), then `--approved-by` records it a third time.

**A-3 (Medium). Close-out is mechanical work done by the planner model.** Ticking the Tracker, filling Status, setting TRIAGE, moving the doc, regenerating the index and closing the issue are all deterministic. On #93 this took most of a day.

**A-4 (Medium). The final approval is a second LLM review to prove a fact a script can prove.** The per-step verdicts already bind to SHAs. What the final verdict adds is "the PR head holds those commits plus the close-out commit, and CI is green on it". That is an ancestry check, a path-scoped diff and one API call.

### B. Duplicated steps

**B-1 (Medium). `make check` runs four or more times per step.** The executor runs it, the Stop hook runs it, the reviewer runs it, CI runs it. The reviewer cannot reuse the executor's result because nothing records which tree it covered.

**B-2 (Medium). The red-first proof is done by hand twice.** The executor shows it, then the reviewer rebuilds a detached worktree and repeats it over several tool calls (`review-execution/SKILL.md`). The procedure is fixed and belongs in a script.

**B-3 (Medium). The comment hook causes duplicate comments.** `require-step-comment.sh:24-25` reads only the last comment. On #99 the executor posted "Addressed both review findings in 9a82aff…" at 16:00:45 and then "Implemented in 9a82aff… the preceding comment contains…" at 16:01:15, only to satisfy the regex. The reviewer did the same at 16:15:04 and 16:15:11.

**B-4 (Medium). The state machine is written in at least eight places and implemented in two more.** Prose: `CLAUDE.md`, `METHODOLOGY.md` §2 and §6, `code-reviewer.md`, `review-execution/SKILL.md`, `plan-to-issues/SKILL.md`, `docs/README.md`, `ADOPTION.md`, and the 58 KB hand-maintained HTML explainer. Code: `require-step-comment.sh` and `lifecycle-status.sh`. They have already drifted: `METHODOLOGY.md:330` says the merge closes the issue, and `:297` says it does not.

**B-5 (Low). An LLM retypes the brief into JSON.** `plan-to-issues` asks the planner to copy each step's DoD, verification and risks into `packet` strings. That is a transcription job with a drift risk.

**B-6 (Low). The reviewer contract is loaded twice and measured once.** OpenCode loads `code-reviewer.md` (957 words) as the agent prompt and `SKILL.md` (999 words) on top. They overlap on the verdict format, the red-first paragraph and the label moves. `measure-harness.sh` counts only the skill, so the real reviewer bundle is about 3,650 words against a reported 2,691.

**B-7 (Medium). "Is it done?" has six homes.** The doc Tracker, the GitHub tracker task list, the sub-issues, the TRIAGE status, the generated index and `ROADMAP.md`. Three of the three docs in `docs/inprogress/` are stale today: `context_optimization.md` is "In progress" with every box unticked for a pass the roadmap calls shipped at `0.10.0`, and both assurance proposals say "Proposal" while their own headers say superseded.

### C. Token consumption

**C-1 (Medium). The harness measures the cheap part.** Static role bundles are roughly 2–4k tokens per boot. The costs nobody measures are the number of cold boots, the size of the brief each role reads, and bounces. The #93 brief is about 22k tokens and there is no tool to hand a role one step of it.

**C-2 (Medium). Every handoff is a cold boot.** A Strict step is three boots by the harness's own count, plus two per bounce. Both `codex exec resume` and `opencode run --session` exist in the installed versions and neither is used, so a bounce fix re-derives everything the first session knew.

**C-3 (Low). The word ceilings sit at 99.5% of capacity.** Any clarifying sentence in a contract trips the gate. This turns a contract fix into a trimming exercise.

**C-4 (Medium). `self-test.sh` cannot be loaded whole.** At about 55k tokens it is larger than every instruction file combined, and nearly two thirds of all commits edit it. The roadmap's decision not to split it (3.5) was made on run time at 1,374 lines. The cost that grew since is edit locality for agents.

**C-5 (Medium). Adopters pay 90 s per turn to re-test vendored code (#113).** This also sits close to the Stop hook's 180 s timeout, and a timed-out Stop hook renders no decision, so a slow gate passes silently.

**C-6 (Low). Hook false blocks cost turns.** #109 and #110 document commands blocked because they mention git near a substitution. The working rule on this machine is "write the command to a file and run that", which also walks around the push guard (see E-2).

### D. Race conditions and correctness

**D-1 (High). Committing bypasses the Stop gate.** `check-gate.sh:20-23` exits 0 on a clean tree before anything else. The contract tells agents to commit each step, so a step committed with a red `make check` ends the turn ungated. This repo hides it by accident: there is no root `.gitignore`, so `.DS_Store` keeps the tree dirty.
Fix: record `HEAD` at `SessionStart`, and skip only when the tree is clean and `HEAD` is unchanged, or when the stamp matches a state hash that includes `HEAD^{tree}`.

**D-2 (Low). The green stamp can certify a tree that was never checked.** The state hash is computed at `:47` before `make check` and written at `:76` after it. An edit that lands during the run is stamped green.
Fix: recompute after the run and stamp only when both hashes agree.

**D-3 (Medium). The comment hook is racy and loose.**
- It is a check-then-act on the last comment, so any comment landing in between causes a false block.
- `grep -Eiq 'approved'` (`:84`) accepts "not approved". `'changes requested|finding'` (`:46`) accepts "no findings".
- It parses the command with its own regex and not the shared lexer. `gh issue edit --add-label needs-review 12` and any `gh api` call pass straight through.

**D-4 (Medium). An approved commit can be amended and still close.** This already happened (accepted risk F-10). No script runs `git merge-base --is-ancestor <approved-sha> <pr-head>`.
Fix: require that ancestry for every step verdict at close-out, and make review fixes new commits.

**D-5 (Medium). The harness requires one branch per pass and creates none.** #93 ran across stacked per-step branches because a worktree held an uncommitted draft (accepted risk). Whoever starts the executor should own the worktree and branch.

**D-6 (Low). Label moves are not compare-and-swap, and labels are never cleared.** #94 is closed with `agent:codex,needs-execution`, #105 with `agent:opencode,needs-review`, #54–#59 with `needs-closing`. A dispatcher cannot trust the queue until each transition sets the whole pair and close clears it.

**D-7 (Low). Guard hooks fail open on timeout.** `require-step-comment.sh` makes up to three network calls inside a 20 s budget. A timed-out PreToolUse hook does not block unless `onFailure` is set to `block`, which Claude Code supports from 2.1.295 (2.1.322 is installed).

**D-8 (Low). Codex guards disappear silently.** `AGENTS.md` notes that any hook change un-trusts the Codex hooks until `/hooks` is run again, and `doctor.sh` cannot see trust.

**D-9 (High, added 2026-11-11 after the decision to publish). On a public repo, strangers can post evidence and instructions.** In `single-operator` mode no script checks who wrote a comment: `lifecycle-status.sh:141-152` only requires a non-empty author and the text `role=reviewer`, and the handoff author check at `:212-219` runs only in `distinct-account` mode. `require-step-comment.sh` checks no author at all. Anyone with a GitHub account can comment on a public issue, so a stranger can post an approving marker, a blocking one, or an "Implemented in <sha>" line that redirects a step. The same threads are read by agents, which under decision 2 run with auto-approved permissions, so a public comment is also a prompt-injection path.
Fix in two parts: before the repo goes public, accept markers and handoffs only from logins on the role allow-list (R-0g); before any station runs headless, build each agent's input from trusted sources instead of letting it read the raw thread (R-19).

### E. Over-engineering

**E-1 (Medium). The strongest machinery guards the weakest link.** `lifecycle-status.sh` is 635 lines, with about 560 lines of tests. It authenticates verdict authors, detects edited comments, binds run attempts and compares unbounded decimal strings. The same GitHub account posts every role, the script is "not a merge guard" by its own description, and the repo has no branch protection. What carries weight is CI's conclusion on the head, ancestry, and a parseable Status block.

**E-2 (Medium). A 345-line shell lexer in Bash 3.2 guards against a cooperative agent.** `hook-command.sh` has needed repeated false-positive fixes (#109, #110, release `0.13.3`). It does not stop `bash script.sh`, which is the documented workaround for its own false blocks. Claude Code's permission `deny` rules and the hook `if` filter already match subcommands and substitutions, and a disabled `pushurl` in agent worktrees stops a push for every agent without parsing anything.

**E-3 (Medium). Upgrade cannot converge for a real adopter (#109).** Harness text and project text share `CLAUDE.md`, `AGENTS.md`, the `Makefile` and `settings.json`, so those files always differ from upstream and the version stamp never advances. `payload-apply.sh` and the upgrade CLI (about 900 lines) exist to manage a merge that a file split would remove.

**E-4 (Low). Smaller items.**
- The no-`jq` JSON decoder in `hook-command.sh:20-45`, although `jq` is a required tool.
- The assurance downgrade audit file, where the git diff of a one-word file is already the audit.
- The deprecated `merge-policy` manifest column.
- `ROADMAP.md` at 51 KB, which states `VERSION` is `0.10.0` and marks Tier 4 done with 4.2 open.

### F. Fit with current models and factory practice

**F-1 (High). Every escaped defect was an adopter-environment failure.** #109 (upgrade on a customized project), #110 (hooks on real commit commands) and #113 (gate cost in an adopter) all passed per-step review and structured verdicts. What was missing was an end-to-end scenario run against a realistic adopter. In factory terms the line has inspection and no final test. This is the StrongDM "holdout scenario" idea: acceptance scenarios the builder cannot edit, run against a stand-in for the real environment.

**F-2 (Medium). Briefs specify what current executors work out themselves.** The template asks for files, functions and order per step, which is how a brief reaches 16.7k words. The planner's leverage is intent, interface, invariants, out-of-scope and acceptance scenarios.

**F-3 (Medium). Verdicts are prose scraped by regex.** `claude -p --output-format json --json-schema`, `codex exec` and `opencode run --format json` can all return a schema-checked verdict. That removes the "literally says approved" class of rule.

**F-4 (Low). Roles are product names with one pinned model.** There is no per-station choice of CLI, model, effort or budget (roadmap 3.4).

**F-5 (Low). Native hook events are unused.** `SessionStart` could inject "plan X, step Y, state Z" and save the orientation reads. `WorktreeCreate` could own worktree setup.

---

## Options

### Option 1 — Trim only
- **What it is:** fix the D findings, remove the duplicates in B, leave the human as dispatcher.
- **Pros:** small, no new concept, no new trust decision.
- **Cons / risks:** human touches stay at about 12 per change. The token cost of cold boots stays.
- **Cost / effort:** days.
- **Right for:** a harness that will only ever run interactively.

### Option 2 — Local line controller with deterministic stations (recommended)
- **What it is:** Option 1, plus scripts for the mechanical stations and a local `agentic-flow run` that reads the label queue and starts the right CLI headless in a per-plan worktree. The human approves the spec, pushes and merges, and is called on andon conditions.
- **Pros:** about 3 touches per change. Fewer LLM sessions. Keeps never-push and human merge. Works with a private repo.
- **Cons / risks:** agents run with auto-approved permissions inside a worktree, which is a posture decision. A new 300–500 line component has to be tested.
- **Cost / effort:** two to three Feature passes.
- **Right for:** one operator supervising several agents, which is this project.

### Option 3 — Event-driven factory in GitHub Actions
- **What it is:** label events trigger agents in CI, and agents push branches.
- **Pros:** runs with the laptop closed.
- **Cons / risks:** breaks never-push. Puts model credentials in CI. Needs branch protection, which this repo cannot have today.
- **Cost / effort:** high, plus a paid plan or a public repo.
- **Right for:** later, if Option 2's controller proves stable.

### Option 4 — Single-vendor collapse
- **What it is:** Claude subagents play all three roles.
- **Pros:** one hook engine, one cache, the simplest controller.
- **Cons / risks:** loses reviewer model diversity, which is the most real independence the harness has.
- **Cost / effort:** low.
- **Right for:** adopters without Codex or OpenCode. It already exists as an opt-out.

## Comparison

| Dimension | 1 Trim | 2 Local controller | 3 CI factory | 4 Single vendor |
|---|---|---|---|---|
| Human touches per Standard change | ~12 | ~3 + andon | ~2 + andon | ~3 + andon |
| LLM sessions per Standard change | 6 | 3 | 3 | 3 |
| Never-push kept | yes | yes | no | yes |
| Reviewer model diversity | yes | yes | yes | no |
| New trust decision | none | headless auto-approve in a worktree | agent credentials in CI | same as 2 |
| Reversible | fully | fully (controller is optional) | hard | fully |

Session counts are derived from the contract. Tokens per session were not measured; R-10 is what makes them measurable.

---

## Recommendation

**Recommended:** Option 2, delivered in four phases with Option 1's fixes first. The dimension that tips it is human touches, and it keeps both invariants that matter here: the human pushes and merges, and a different model reviews.

### Target line

```
intake → Spec → Kit → Build → Verify → Review → Close → Release
         LLM    script  LLM     script    LLM     script   human
         (top)          (exec)            (diverse)
```

The human approves at Spec, releases at Release, and answers andon calls. Every arrow is a controller transition, not a person.

### Phase 0 — Fast fixes (no design decision, one commit each)

| ID | Change | Fixes |
|---|---|---|
| R-0a | Stop gate: close the commit bypass and the stamp race | D-1, D-2 |
| R-0b | Adopter `make check` template drops the scaffold self-test and compares the per-file hashes already stored in `.agentic-flow-installation` | C-5, #113 |
| R-0c | Close-out requires `--is-ancestor` for every approved step SHA | D-4 |
| R-0d | Set `onFailure: block` on the push and secret hooks | D-7 |
| R-0e | Hygiene: resolve the three stale docs, add a source-only root `.gitignore`, clear workflow labels on close, fix `METHODOLOGY.md:330` | B-7, D-6 |
| R-0f | Publish the repo and make `CI gate` the single required check on `main` (decided 2026-11-11) | E-1 |
| R-0g | Before publishing: every marker and handoff comment is accepted only from a login listed for that role in `.agentic-flow-review-policy`, in both the hook and the lifecycle script. Until R-18 lands the list holds the owner's login. | D-9 |

### Phase 1 — Deterministic stations

| ID | Change | Fixes |
|---|---|---|
| R-1 | `agentic-flow handoff <issue> <event>`: checks the expected current state, posts the structured comment, sets the whole label pair, closes when due. Every transition carries an identifier (`plan/step/event/sha`) in its comment. The comment is the journal, and labels, open or closed state and tracker notification are all derived from the latest valid transition in it, never from the transition being retried. A retried handoff whose identifier is already on the thread posts nothing: if it is the latest transition it re-derives the state, and if a later transition has superseded it, it is a no-op that reports "superseded". A handoff that is not a legal successor of the latest transition is rejected. The hook shrinks to blocking raw edits of workflow labels. | B-3, D-3, D-6 |
| R-2 | `config/workflow.tsv` as the single definition of states, transitions and required evidence. The hook, lifecycle and controller read it. The prose sections render from it through `render-shared.sh`. | B-4 |
| R-3 | A structured steps block in the brief. `plan-to-issues` reads it directly. Plan approval is the apply authorization. | A-2, B-5 |
| R-4 | `agentic-flow verify-step <sha>`: runs `make check`, the focused test and the red-first proof in a clean detached worktree of the named SHA, never in the working tree, so staged, unstaged and untracked files cannot be certified. The record holds the SHA, its tree hash, the red-first base SHA, each command with its exit code and an output digest, and tool versions. The reviewer reuses a record only when it names the SHA under review. | B-1, B-2 |
| R-5 | `agentic-flow close-out prep` and `finish`. The final attestation becomes ancestry, CI's conclusion on the head and a close-out delta limited to an allow-list: the doc's rename from `inprogress/` to `done/`, its TRIAGE status line, Tracker ticks and Status fields with the rest of the file byte-identical, and the generated region of `docs/README.md`. Anything else sends the delta to the reviewer. That includes contracts, skills, templates, memory entries, accepted risks, and any brief's analysis, steps or acceptance criteria, because Markdown here is agent instruction. | A-3, A-4 |
| R-6 | `agentic-flow brief <doc> <step>` prints the shared header and one step. A `SessionStart` hook injects the current plan, step and state. | C-1, F-5 |
| R-19 | Trusted packet builder, a prerequisite for any headless station. A station's input is built by the harness from the brief slice at the approved commit, the R-4 record, and comments whose author is on the role allow-list. Comments from anyone else are dropped, not summarized. Stations are denied raw thread reads (`gh issue view`, `gh pr view`, the comments API). A resumed session receives a new packet, never the thread. The queue admits only issues that carry a plan stamp and were created by an allow-listed login. | D-9 |
| R-18 | Role identities (decided 2026-11-11): separate GitHub identities for planner/closer, implementor and reviewer, with the human owner as PR author and merger. Switch the policy to `distinct-account`. No new key is needed: the existing `approver` key is the planner/closer identity (owner's definition, 2026-11-11), `executor` is the implementor and `reviewer` is the reviewer. Document that mapping, since no prose defines `approver` today and `--approved-by` in `plan-to-issues` means something else (the human approving the plan). Each station gets its own token from the operator's keychain, never from the repo. No agent identity gets `contents: write`, so no agent token can push. Retire the `single-operator-review` accepted risk. | D-9, E-1 |

### Phase 2 — Line controller

| ID | Change | Fixes |
|---|---|---|
| R-7 | `config/roles.tsv`: station → CLI, model, effort, turn and cost budget | F-4 |
| R-8 | `agentic-flow run`: reads open issues by label pair, creates one worktree and branch per plan, starts the station's CLI headless, takes a schema-checked JSON result, calls `handoff`. Resumes the same session on a bounce. One plan in flight per worktree. | A-1, C-2, D-5, F-3 |
| R-20 | Controller ownership and recovery, a prerequisite for unattended runs. One controller owns a plan at a time, through an atomic lock in the git common directory that records pid and start time; a second controller refuses to start, and a lock whose process is gone is taken over only after reconciliation. The ledger records an intent before a station starts and a result after. On start the controller reconciles every issue that carries the plan's stamp, open or closed. For each one the latest valid journal transition decides the label pair and the open or closed state, so an approved step that was never closed is closed and a closed step still carrying workflow labels is cleaned. Plan-level effects are reconciled the same way: when every step is approved and the tracker has no notification transition, the controller posts it, with its own identifier so a second pass does nothing. A step with a commit and no handoff gets its handoff, and an intent without a result is inspected before anything is re-run. A state the journal cannot explain, such as an issue a person reopened, raises andon and is not "repaired". Controllers on two machines for one plan are out of scope and refused. | A-1, D-6 |
| R-9 | Andon: two bounces, a `pending` verdict, a blown budget, a gate still red after retry, or an executor "brief is wrong" stop sets `needs-human` and notifies. The controller never pushes. Notification channel (added 2026-11-12): a label change notifies nobody, so the escalation comment @-mentions the configured human owner. GitHub delivers that as a mention, which can be routed to a phone apart from routine bot comments. This depends on R-18: GitHub never notifies an account about its own comments, and under `single-operator` every comment is the owner's. The local controller also raises a desktop notification, and `agentic-flow brief` and the `SessionStart` hook list `escalated` issues first. | A-1 |
| R-21 | Open questions from a station (added 2026-11-12). Today an executor's "brief is wrong" stop and a reviewer's `pending` verdict are only comments: the label pair is unchanged, it reads as "still working", and nobody is notified. Make each one a journaled `handoff` event (`ask`) that moves the issue to `escalated` with the question as evidence, so R-9 can fire. An `ask` does not count toward the bounce cap. `resume` returns the issue to the state it left: `reviewing` after a reviewer's question, where Phase 1 always returns to `executing`. When the answer changes the approved brief, R-3's revision binding requires re-approval; define a short re-approval path for a clarification so it does not cost a full review round. | A-1 |
| R-10 | A run ledger (JSONL: station, model, tokens, duration, verdict) and `agentic-flow status`. KPIs: lead time, first-pass yield, bounce rate, escape rate, human touches, tokens per step. These replace the word ceilings and the hand-kept roadmap status. | C-1, C-3 |
| R-11 | `agentic-flow ship`, run by the human: push, open the PR, wait for CI, run `close-out finish`. | A-1 |

**Entry gate for unattended runs.** R-8 stays behind a manual `--once` mode until R-18, R-19 and R-20 have landed with failure-path tests:

- two controllers on one plan;
- a crash between comment and label;
- a crash mid-station;
- a crash after closing the last step and before the tracker is notified;
- a replayed handoff after a later transition, which must change nothing;
- a hostile comment on a thread.

### Phase 3 — Remove what the above makes redundant

| ID | Change | Fixes |
|---|---|---|
| R-12 | Replace the lexer hooks with permission `deny` rules, `if`-filtered thin hooks, and a disabled `pushurl` in agent worktrees. Confirm the Codex and OpenCode equivalents before deleting. | E-2, C-6, D-8 |
| R-13 | With R-18 in place: the final approval becomes a native PR review by the reviewer identity, required on `main` together with `CI gate` and dismissed on a new push. Step verdicts stay as issue comments, because steps are reviewed before the PR exists, and are accepted only from the reviewer login. Delete edit detection, run-attempt binding and the role-claim check. Lifecycle keeps the Status block, ancestry and the step-verdict lookup. | E-1 |
| R-14a | Non-breaking: classify an upgrade file as a candidate only when upstream changed since the per-file hash recorded at the last upgrade. | E-3, #109 |
| R-14b | Breaking, at 1.0: split harness-owned from project-owned files. `AGENTS.md` becomes fully harness-owned (it differs from the template only by project name). `CLAUDE.md` keeps Stack profile, tools, Architecture and Gotchas and imports a harness-owned file for the rest. The `Makefile` includes `harness.mk`. Hook entries in `settings.json` are merged by key with `jq`. Upgrade becomes overwrite. | E-3, #109 |
| R-15 | Split `self-test.sh` into `tests/<group>.sh`. Add an adopter-twin fixture (customized `CLAUDE.md` and `Makefile`, realistic commit commands) and run upgrade, hooks and `make check` against it as holdout scenarios. | C-4, F-1 |
| R-16 | Docs diet: one reviewer contract, `METHODOLOGY.md` §9–§11 moved to reference files, roadmap cut to the open queue, the HTML explainer generated or dropped. | B-4, B-6, E-4 |
| R-17 | Scenario-first brief template with a word cap. Acceptance scenarios are written at Spec and the executor cannot edit them. | F-1, F-2 |

### Expected effect

| Measure | Now | After Phase 2 |
|---|---|---|
| Human touches, Standard change | ~12 | 3 + andon |
| LLM sessions, Standard change | 6 | 3 |
| `make check` runs per step | 4+ | 2 |
| Adopter gate per turn | 89.5 s | a few seconds |
| Homes for the state machine | 8 prose + 2 code | 1 data file |

**Defer:**
- Option 3. Revisit once the controller has run three passes without a controller defect.
- Removing the human merge.
- A default multi-reviewer ensemble.
- Any further attestation work.

## Review corrections applied (2026-11-11)

The reviewer raised four gaps in the first version of the plan. All four were accepted.

| Finding | Severity | Correction |
|---|---|---|
| R-4 keyed evidence by commit SHA while verification could run in a dirty tree | High | R-4 now runs in a clean detached worktree of the named SHA and records commands and the red-first base |
| R-5 exempted a "docs-only" delta from review, and Markdown here includes contracts, skills and acceptance criteria | High | R-5 now exempts only named close-out fields and the generated index; everything else is reviewed |
| R-1 and R-8 had no ownership, idempotency or crash recovery | High | Transition identifiers and journal-then-labels ordering in R-1; new R-20; entry gate for unattended runs |
| R-0g covered evidence parsing only, and D-9's packet construction was never a deliverable | Medium | New R-19, required before any headless station, covering resumed sessions and queue admission |

A second review round confirmed R-4, R-5 and R-19 and raised two recovery gaps. Both were accepted.

| Finding | Severity | Correction |
|---|---|---|
| Replaying an old handoff could restore stale labels | Medium | R-1 derives state from the latest valid transition; a superseded retry is a no-op; illegal successors are rejected |
| Recovery looked only at open issues, so a crash after the last close could strand the plan and leave stale labels | Medium | R-20 reconciles every stamped issue, open or closed, plus the tracker notification as its own journaled transition |

One cost follows from the R-4 correction: a clean worktree has no installed dependencies, so stacks with a heavy install step need a dependency cache or the saving in B-1 shrinks. The Phase 1 brief has to settle that per stack profile.

## Decisions to make up front

1. **Repo setting (R-0f).** Decided 2026-11-11 by the human owner: the repo will be published. R-0g must land first (D-9).
2. **Headless posture (R-8).** Decided 2026-11-11: yes, auto-approved permissions inside a plan worktree with push disabled.
3. **One approval (R-3).** Decided 2026-11-11: yes, approving the plan authorizes issue creation.
4. **Evidence scope (R-13, R-18).** Decided 2026-11-11: separate identities for planner/closer, implementor and reviewer. Two things to settle while building R-18:
   - *Identity type.* GitHub's terms allow one free machine account beside a personal account, so three machine users are not an option on free accounts. Three GitHub Apps fit: each has its own bot login, short-lived tokens and per-App permissions.
   - *Does an App's approval satisfy a required review?* Community reports say it does. No official statement was found. Prove it on a test PR before R-13 deletes the comment-based final approval.
5. **File split (R-14).** Decided 2026-11-11: R-14a now, R-14b at the 1.0 boundary. R-14b needs one manual migration per adopter.
6. **Per-step review in Strict.** Kept as recommended, since #99 shows it finds real defects. The controller removes its human cost, not its token cost. The owner has not commented on this one.

## If approved → next docs

- [x] `docs/done/feature-gate-and-handoff-fixes.md` — Phase 0 (Strict, because it changes gates and review provenance). Drafted 2026-11-11; shipped as `0.14.0` in PR #121, tracker #114. R-0b was replaced by G-5: #113's 89.5 s was measured at `0.13.1`, before F-12, and a fresh `0.13.3` export runs `make check` in 5.5 s.
- [ ] `docs/inprogress/feature-deterministic-stations.md` — Phase 1 (Strict). Drafted 2026-11-12; awaiting approval. Defers flipping this repo to `distinct-account` to a one-step follow-up pass, so this pass's own evidence stays valid.
- [ ] `docs/inprogress/feature-line-controller.md` — Phase 2 (Strict)
- [ ] `docs/inprogress/feature-harness-simplification.md` — Phase 3 (Strict; R-14 is a public compatibility change)

## Sources

- Claude Code hooks reference (`if`, `onFailure`, `SessionStart`, `WorktreeCreate`, timeout behavior): <https://code.claude.com/docs/en/hooks>
- Software factory, holdout scenarios, digital twins: <https://simonwillison.net/2026/Feb/7/software-factory/>
- Headless modes checked locally: `claude` 2.1.322, `codex-cli` 0.167.0 (`codex exec`, `resume`, `review`), `opencode` 2.2.7 (`opencode run --agent --format json --session`)

- GitHub terms on machine accounts: <https://docs.github.com/en/site-policy/github-terms/github-terms-of-service>
- Community report that a GitHub App's review counts toward required approvals: <https://github.com/orgs/community/discussions/181487>

Not verified: Codex's and OpenCode's native command-deny rules (R-12), tokens per session for any role, and whether a GitHub App's approving review satisfies a required review (decision 4).

## Status

- **Decision:** accepted 2026-11-11: Option 2, with decisions 1–5 as recorded above. Decision 6 stands as recommended. Approved by the human owner on 2026-11-11 after two review rounds, with all six review findings applied.
- **Decided by:** wabkebab (human owner).
