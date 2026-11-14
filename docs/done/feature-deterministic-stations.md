<!-- TRIAGE (first pass · 2026-11-12) -->
> **Type:** Feature · **Status:** ✅ Done
> **Assurance:** Strict
> Phase 1 of `product-harness-factory-optimization.md` (R-1–R-6, R-18, R-19): turn the mechanical stations into deterministic `agentic-flow` commands so a later controller can drive them. Draft for approval; nothing is executed. Next: human review, then `plan-to-issues`.

# Feature — Deterministic stations

## Tracker
- [x] s-1 — #125; approved=495d7664f12c7d83a65708c711b8a84a90e21649; submissions=495d7664f12c7d83a65708c711b8a84a90e21649
- [x] s-2 — #126; approved=60d70fe16d2b96404564e97de25dba88b3545641; submissions=60d70fe16d2b96404564e97de25dba88b3545641
- [x] s-3 — #127; approved=fa9c0df0fb565835594279dc8bc34a48c3b1096b; submissions=0e7cdde98d2a27eeb18fe84f871cf341fe4b3559,fa9c0df0fb565835594279dc8bc34a48c3b1096b
- [x] s-4 — #128; approved=4d17db14825484ea5aa3951bbbfebe28511cc6e2; submissions=4d17db14825484ea5aa3951bbbfebe28511cc6e2
- [x] s-5 — #129; approved=bae40b8ff0c00db3813c802165c929533821e88b; submissions=36b42f1bc0c75c0caf5e4940fa8b6bd66d5d212b,bae40b8ff0c00db3813c802165c929533821e88b
- [x] s-6 — #130; approved=500400eaa230206d5251d9aa70bf57f28aa473d8; submissions=500400eaa230206d5251d9aa70bf57f28aa473d8
- [x] s-7 — #131; approved=fc7b773de055ac4d019f65133bde739cc24dcace; submissions=fc7b773de055ac4d019f65133bde739cc24dcace
- [x] s-8 — #132; approved=91cc9830c70631744f1cf19af24eb03a9bd99bbb; submissions=91cc9830c70631744f1cf19af24eb03a9bd99bbb
- [x] s-9 — #133; approved=99642c4a50a9d30dd0609aec417f92bbed2daaac; submissions=99642c4a50a9d30dd0609aec417f92bbed2daaac
---

# Part A — Analysis

## Goal

Every handoff in the harness today is a person typing a `gh` command that a regex hook then second-guesses, and every bookkeeping station is an expensive model doing deterministic work. Phase 2 will add a controller that drives the line without the human relaying. That controller can only be as reliable as the stations it calls. This pass makes each mechanical station a script with one interface, one definition of the workflow, a journal it can recover from, and inputs it can trust. It adds no controller and changes nothing about who pushes or merges.

Success, in the analysis's terms:

- one definition of the state machine, read by code and rendered into prose (B-4);
- one command per transition, idempotent and race-safe (B-3, D-3, D-6);
- one approval per plan (A-2, B-5);
- the executor's verification reusable by the reviewer, with red-first scripted (B-1, B-2);
- close-out run by a script, and the final LLM review needed only when the close-out delta is more than bookkeeping (A-3, A-4);
- a role reads one step, not the whole brief (C-1, F-5);
- station inputs built only from trusted sources, and identities that can be told apart (D-9, E-1).

## Current state

| Ref | What exists today | Where |
|---|---|---|
| B-4 | The state machine is prose in eight files and code in two: the hook's regexes and `lifecycle-status.sh`'s marker parser. No data file. | `CLAUDE.md`, `METHODOLOGY.md` §2/§6, `.opencode/agent/code-reviewer.md`, `.agents/skills/review-execution/SKILL.md`, `templates/shared/plan-to-issues.SKILL.md`, `docs/README.md`, `ADOPTION.md`; `scripts/hooks/require-step-comment.sh`, `scripts/lifecycle-status.sh:112-286` |
| B-3, D-3, D-6 | Transitions are raw `gh issue edit` calls. The hook regex-matches the command, reads the latest role-login comment, and greps it (`approved` accepts "not approved"). `gh api` and `--add-label needs-review 12` orderings pass. Labels are added, never swapped, and survive close. Since G-1 the hook filters authors by the policy. | `scripts/hooks/require-step-comment.sh:20-108` |
| A-2, B-5 | Approving a plan takes three acts: the plan, the in-turn go-ahead for `--apply`, and `--approved-by`. The planner retypes each step's DoD, verification and risks into JSON `packet` strings. | `templates/shared/plan-to-issues.SKILL.md` steps 2 and 5; `scripts/plan-to-issues.sh:50-80` |
| B-1, B-2 | `make check` runs at least four times per step. The reviewer rebuilds a detached worktree by hand to repeat the red-first proof. Nothing records which tree a run covered. | `.agents/skills/review-execution/SKILL.md:50-52` |
| A-3, A-4 | Close-out is done by Claude: Tracker, Status, TRIAGE, move, index, close. A second LLM review then approves the final head, although the step verdicts already bind to SHAs (G-2) and the rest is an ancestry check, a diff and a CI lookup. | `CLAUDE.md` close-out paragraph; `scripts/lifecycle-status.sh:340-545` |
| C-1, F-5 | Each role reads the whole brief (the #93 brief is ~22k tokens). No `SessionStart` hook. | `.claude/settings.json` (PreToolUse, Stop, SubagentStop only) |
| D-9 | Agents read raw threads. Accepted as `agent-thread-prompt-injection` with "no headless stations before R-19". | `docs/accepted_risks.md#agent-thread-prompt-injection` |
| E-1, R-18 | One login holds every role (`single-operator`). The policy regex rejects App logins (`slug[bot]`). No prose defines `approver`. | `.agentic-flow-review-policy`; `scripts/lib/review-policy.sh` (login regex) |

What already works and must not be re-implemented: the policy parser and its role lists (`scripts/lib/review-policy.sh`), the stable plan and step stamps and reconcile logic in `scripts/plan-to-issues.sh`, the G-2 ancestry check and `bounded_gh` in `lifecycle-status.sh`, the shared-region renderer (`scripts/render-shared.sh`), the shell lexer (`scripts/lib/hook-command.sh`), and the docs index (`scripts/docs-index.sh`).

## Proposed approach

Nine steps, one per station plus the shared foundations. Foundations first, so each later station is built on them instead of retrofitted:

- S-1 (workflow data) and S-2 (identities) are read by every later step.
- S-3 (handoff and journal) is the riskiest step and the one Phase 2 depends on most.
- S-4 and S-5 make the brief machine-readable. S-6 and S-7 consume that.
- S-8 consumes the journal, S-6's records and S-4's plan block.
- S-9 rewrites the prose last, once the commands it routes to exist.

### Option A — `agentic-flow` subcommands over shared libraries (recommended)
Each station is a subcommand of the existing `scripts/agentic-flow` CLI, backed by a library in `scripts/lib/` (`workflow.sh`, `journal.sh`, `identity.sh`, `brief.sh`). Hooks, `lifecycle-status.sh`, `plan-to-issues.sh` and Phase 2's controller all source the same libraries. Bash 3.2, `jq`, `gh`, `git`, as today.

### Option B — a second language for the new stations
A Python or Go tool would make JSON and concurrency easier. It adds a runtime adopters must install, splits the test harness, and breaks the "one toolchain" rule in `CLAUDE.md`. Not worth it at this size; revisit if Phase 2's controller outgrows shell.

**Recommendation:** Option A.

### Decisions this brief makes (veto at approval)

1. **This repo stays `single-operator` for this pass.** S-2 ships App identity support and tests it against fakes. Flipping this repo to `distinct-account` is a one-step follow-up pass right after this merge. Flipping mid-pass would invalidate this pass's own evidence: every earlier handoff and verdict was posted by `wabkebab`, which `distinct-account` would reject or flag as overlapping. The follow-up is the first pass run fully under the three identities, retires `single-operator-review`, and proves on a test PR whether an App's approving review satisfies a required review (decision 4 of the analysis, needed before R-13).
2. **Add a `needs-human` label now**, used only for the existing bounce cap (the third findings return). The journal needs a state for it. R-9 widens its use in Phase 2. `create-tags` grows to seven labels.
3. **Stations never call GitHub themselves in Phase 2.** The controller calls `handoff`; the station returns JSON. So S-7's station profiles grant no GitHub credential and deny `gh` outright, rather than filtering which `gh` subcommands pass.
4. **The verification record is convenience, not proof.** CI on the PR head stays authoritative. The reviewer reuses an S-6 record only when it names the exact SHA and tree under review.
5. **New tests live in their own file.** The new `stations` group goes in `scripts/tests/stations.sh`, sourced by `scripts/self-test.sh`, not in the 3,900-line monolith (C-4). R-15 moves the rest later.
6. **This pass migrates its own issues rather than being exempt.** S-1 and S-2 run on today's hand-written handoffs. From S-3's commit on, every handoff uses `handoff`, whose legacy prefix reads the earlier evidence. After S-4, a reapply stamps the approved revision. See "Bootstrap (this pass only)" in Part B.

## Review corrections applied (2026-11-12)

| Finding | Severity | Correction |
|---|---|---|
| Replay did not stop a stale writer: a paused submit could overwrite the labels a later bounce had set | P1 | A per-plan lock serializes harness writers. Labels are written only from a replay after the last read, and a post-write check repeats on drift. Labels are declared a projection that no decision reads. Scenario 7 tests successive transitions, not only competing ones. |
| Approval carried forward to changed plans, because the approved commit was "the last commit touching the doc" | P1 | `Approval` carries `rev=`, and apply requires the normalized doc at HEAD to equal it at `rev`. Scenario 9 tests a committed content change that leaves the field untouched. |
| This pass could not satisfy its own journal and stamp requirements | P1 | A legacy prefix maps policy-authored legacy evidence onto the journal with the same legality rules, or marks the issue UNJOURNALED. A four-stage bootstrap recovers the approved revision and migrates the stamps with a checked `--diff`. Scenario 10 tests it. |
| A retried last approval returned before notifying the tracker | P1 | Every `handoff` run, no-op and superseded included, reconciles plan effects, and the notify id makes it once-only. Scenario 8 tests that crash window. |
| Red-first had no declared inputs, and a new group could not run on its base | P2 | Every step declares selector and paths, including runner wiring. An assertion signature separates `red` from `invalid`. Scenario 11 tests it. |

Second round:

| Finding | Severity | Correction |
|---|---|---|
| Stamping `approved=` ended legacy eligibility, so S-1 and S-2 reverted to executing | P1 | Eligibility is fixed at creation by the absence of `journal=v1`, which no reapply changes. Bootstrap stage 4 compares replay before and after the migration. Scenarios 14 and 15 test it. |
| Transition ids collided across legitimate cycles (head-less bounces, repeated resumes) | P1 | Ids carry a per-issue seq, which also serves as the compare-and-swap. Retry identity is "the latest accepted transition equals the request", which is sound because `make check` forbids self-loops. Stale replays are detected with `--after`. Scenario 12 runs three cycles, two escalations and two resumes. |
| A `reconcile` by any role could not post a reviewer-authored notify | P2 | Plan effects post under the role workflow.tsv assigns to them, minted from the operator's identity config, never the caller's. When that identity is absent, exit 7 names the recovery command. Scenario 13 uses disjoint logins. |
| Scenario 3 expected exit 4 where the lock makes the second approval a no-op | P2 | Split into 3a, same machine with the lock (exit 0, one comment), and 3b, lock bypassed (exit 4, the loser skipped by seq). |

Third round:

| Finding | Severity | Correction |
|---|---|---|
| Lifecycle read the latest verdict marker, so a race-losing comment's compatibility line could block close-out while the journal said approved | P1 | For journaled issues, lifecycle selects evidence only from accepted transitions through the shared `journal_replay`, then runs every existing check (author, overlap, edit, head, ancestry) on that comment. Purely legacy issues and final-head markers keep today's reader. Lands in S-3, the step that introduces the losing comments. Scenario 3b now runs through lifecycle in both directions. |
| Close-out assumed a tracker, which Standard does not have | P2 | `prep` and `finish` choose the close target by profile: the tracker for Strict, the sole work issue (already lifecycle's tracking page) for Standard. Legacy topology is refused. Scenario 16 runs Standard end to end, and 17 runs Strict. |

## Interface (before the implementation)

```
config/workflow.tsv                         harness-owned, exported (core), read by code
  # kind=state
  state  <topology>  <state>  <labels,comma>  <open|closed>
    topology ∈ step-strict | work-standard | tracker
    step-strict:   executing   agent:codex,needs-execution   open
                   reviewing   agent:opencode,needs-review   open
                   escalated   needs-human                   open
                   approved    -                             closed
    work-standard: executing / reviewing / escalated as above
                   closing     agent:claude,needs-closing    open
                   closed      -                             closed
    tracker:       open        plan                          open
                   closing     plan,agent:claude,needs-closing  open
                   closed      plan                          closed
  # kind=transition
  transition  <topology>  <event>  <role>  <from>  <to>  <requires,comma|->
    submit   executor  executing → reviewing          head,head≠last-bounced-head
    bounce   reviewer  reviewing → executing          findings,bounces<2
    bounce   reviewer  reviewing → escalated          findings,bounces=2
    resume   approver  escalated → executing          note
    approve  reviewer  reviewing → approved|closing   head=submitted
    notify   reviewer  open      → closing  (tracker) all-steps-approved
    close    approver  closing   → closed             lifecycle-ready
  `bounces` counts bounces since the issue's last resume (or since creation).
  Invariant, checked by make check: no transition has from == to, so the same event
  can never legally follow itself. Retry detection (below) depends on it.
  Workflow labels = the union of every state's labels minus `plan`.

scripts/lib/workflow.sh
  workflow_load <root>                       validates the file; fails naming the bad line
  workflow_state_labels <topology> <state>
  workflow_successor <topology> <state> <event> <bounces>   → next state, or fail
  workflow_labels                            all workflow labels, one per line

scripts/lib/journal.sh                       the thread is the journal
  transition line, one per handoff comment, first line of the body:
    agentic-flow-transition: v=1; id=<plan>/<step|tracker>/<seq>/<event>;
      event=<event>; from=<state>; role=<role>; head=<sha40|none>
    seq = 1 + the number of transitions already accepted on this issue, counting
      legacy-prefix transitions. Every occurrence therefore has its own id: three
      bounce cycles are …/2/bounce, …/4/bounce, …/6/bounce, and a second resume
      never collides with the first.
  journal_replay <comments-json> <topology>
    input: a normalized array of {id, dbid, author, created_at, last_edited_at, body}.
      An adapter exists for each read path, `gh issue view --json` and the GraphQL
      nodes lifecycle-status already fetches, so handoff, packet and lifecycle all
      share one replay. The author is normalized once (S-2).
    walks comments oldest first; keeps a transition only if
      author ∈ the policy's list for <role>, line parses, seq == accepted count + 1,
      from == derived state, and event is legal from it (workflow_successor)
    prints: state, latest accepted transition (seq, event, role, head), bounces,
      submitted head, approved head, skipped count, and every accepted
      transition with its comment id, dbid and last_edited_at

lifecycle evidence for journaled issues
  journaled = stamp carries journal=v1, OR the thread holds at least one accepted
    transition line. A purely legacy issue keeps today's reader unchanged.
  for a journaled step or work issue, verify_step_review selects evidence ONLY from
    accepted transitions: the step head is the accepted approve's head, and the
    verdict is that approve comment's compatibility line. Compatibility lines on
    skipped comments (race losers, strangers, out-of-role logins) are never read.
  the issue must replay `approved` (Strict) or `closing`/`closed` (Standard);
    otherwise the step is BLOCKED "journal state <state>".
  every existing check then runs on the selected comment unchanged: author
    authorization and the distinct-account overlap, the edit check
    (last_edited_at set → BLOCKED), head format, and the G-2 ancestry check
  final-head markers on the tracker or work issue (pr=, run=, attempt=) are not
    transitions and keep today's reader
  A comment that fails any rule is skipped and counted, never parsed further. Two
  posts that both claim seq n: the first in comment order is accepted, and the
  second fails the seq rule. Seq is the compare-and-swap.
  The journal is the only authority. Labels and open/closed state are a projection of
  it: every reader that decides anything (handoff, packet, close-out, the state cache,
  Phase 2's controller) replays the journal and never trusts labels.

  legacy prefix — eligibility is fixed when an issue is created, and no later
    migration changes it:
    from S-3 on, every issue plan-to-issues creates gets `journal=v1` in its stamp;
    an issue whose stamp lacks journal=v1 is legacy-eligible for its whole life;
    reapply, including S-4's `approved=` migration, never adds or removes journal=.
    So stamping the approved revision cannot discard earlier evidence.
    initial state: executing (step-strict, work-standard) / open (tracker)
    policy-authored evidence before the first transition line maps, in comment order:
      executor  "Implemented in <sha40>"                            → submit head=<sha>
      reviewer  agentic-flow-review: status=changes-requested; step; head → bounce
      reviewer  agentic-flow-review: status=approved; step; head (no pr=) → approve
      a submit while reviewing (findings posted as prose)  → an implied bounce, counted
      final-head markers (pr=, run=)                         → not a transition
    each mapped item must be a legal successor, and an approve's head must equal the
      latest submitted head; otherwise the issue is UNJOURNALED and handoff, prep and
      packet refuse, naming the comment id. Close-out then uses today's lifecycle
      evidence path, whose rules this pass does not change.
    mapping stops at the first transition line; later legacy markers are not read.
    each mapped item takes the next seq, so the first real transition after a
      legacy prefix of k items carries seq k+1.
    labels and closed state are never evidence for the prefix.
    on a journal=v1 issue, legacy-format lines are never mapped.

plan lock   $(git rev-parse --git-common-dir)/agentic-flow/locks/<plan>
  atomic mkdir; holds pid and start time; a lock whose pid is gone is taken over;
  waits ≤ 30 s, then exit 5. Shared by every worktree of the repository, so every
  harness writer on this machine is serialized per plan. Two machines on one plan
  are out of scope (R-20 refuses them); step 5 below still catches their writes.

agentic-flow handoff <issue> <event> --as <role> [--head <sha>] [--after <seq>]
                     [--body-file <f>]
agentic-flow handoff <issue> reconcile [--json]  no --as; posts only plan effects (step 4);
                                              --json prints the replay of every issue read
  --as must equal the event's role in workflow.tsv; the requested transition is
    posted with that role's identity (S-2).
  --after <seq>: the latest accepted seq the caller decided against. Optional
    interactively; Phase 2's controller always passes it.
  0. read the issue body for its plan stamp (no stamp → exit 3); take that plan's lock
  every later step runs under the plan lock:
  1. read the issue (one page of 100 comments; more → refuse); replay
  2. with an event, the request is (event, role, head):
       latest accepted transition equals the request → a retry whose post already
         landed: post nothing. Safe because no event can follow itself.
       --after given and below the latest seq:
         the transition at after+1 equals the request → print "superseded", post nothing
         otherwise → exit 4 "lost race to <id at after+1>", post nothing
       not a legal successor → exit 3, no writes, naming the state and legal events
       otherwise post one comment with seq = latest + 1 (transition line +
         compatibility lines + body), re-read and replay; if it was not accepted
         (another post took that seq) → remember exit 4
  3. reconcile the issue: write the label pair (one edit: add the target's labels,
     remove every other workflow label) and close or reopen, from the replay made
     after the LAST read. Never from the requested transition, and never from a
     replay made before the post. Label edits are not evidence, so any configured
     identity, or the ambient login, may make them.
  4. reconcile plan effects, on every run including no-op, superseded and
     `reconcile` runs: for a step-strict plan whose steps all replay as approved
     while the tracker replays as `open`, post `notify` on the tracker and reconcile
     it as in 3. Idempotent by state: once notified the tracker is `closing`, and
     notify is no longer legal.
     A plan effect is posted with the identity of the role workflow.tsv assigns to
     it (notify: reviewer), never the caller's. handoff mints that token from the
     operator identity config. In single-operator mode, the ambient login holds
     every role.
     If that role has no identity on this machine and the ambient login does not
     hold the role, skip the effect, finish steps 5–6, and exit 7, printing
     "plan effect pending: notify on #<tracker>; run
     `agentic-flow handoff <tracker> reconcile` where the reviewer identity is
     configured". The journal still says the tracker is open, so nothing is lost.
  5. verify: re-read every issue written in 3–4 and replay it. If labels or state
     differ from the projection (a writer outside the lock: another machine, the web
     UI), repeat 3–5 at most twice, then exit 5 "labels did not converge".
  6. write the local state cache; release the lock
  compatibility lines kept until R-13:
    submit  → "Implemented in <sha40>"
    approve → "agentic-flow-review: status=approved; step=<id>; head=<sha40>; role=reviewer"
    bounce  → "agentic-flow-review: status=changes-requested; step=<id>; head=<sha40>; role=reviewer"
  test seam: AGENTIC_HANDOFF_FAULT=<point> makes handoff pause or exit at a named
    point (after-replay, after-post, after-labels, before-notify); read only by tests
  exit: 0 done/no-op · 2 usage · 3 illegal · 4 lost race · 5 GitHub/identity/lock
        failure · 7 done, but a plan effect is pending on an identity this machine lacks

local state cache   $(git rev-parse --git-common-dir)/agentic-flow/state/<plan>.tsv
  issue  step  state  latest-id  head  updated-at       written by handoff only

operator identity config (never in the repo)
  ${XDG_CONFIG_HOME:-~/.config}/agentic-flow/identities/<owner>/<repo>.tsv
    role  login  app-id  installation-id  key-ref
    key-ref names a keychain item (macOS `security`, Linux `secret-tool`)
agentic-flow token <role> [--check]
  mints an installation token restricted in the request to this repository and to
    issues:write, pull_requests:write, contents:read, metadata:read
  --check also asserts the returned permissions carry no contents:write
  no identity configured for <role> → exit 6 "no identity"; callers then use the
    ambient `gh` login only if that login holds <role> in the policy
  identity configured but minting fails → exit 5; never fall back to the ambient login
.agentic-flow-review-policy
  login regex also accepts <app-slug>[bot]; reviewer/executor/approver as today
  approver = the planner/closer identity (documented; distinct from --approved-by)

brief plan block (in Part B, once per brief; a fenced block, info string agentic-flow-plan)
    id: <plan-id>
    profile: standard|strict
    tracking: <tracker title>              strict only
    branch: <branch>
    steps: <step-id> <step-id> …           order = execution order
  each step section:  ## <ID> — <title>, where lowercase(<ID>) is the step id
    required labels:  **DoD:**  **Verify:**  **Risks:**
    red-first, one line per proof (repeatable), or `**Red-first:** none`:
      **Red-first:** `<selector>` — <path> [<path> …]
        selector: a command run from the worktree root
        paths: files copied from the step's commit onto the red base. They must
          include the runner wiring the selector needs (for a new self-test group:
          scripts/self-test.sh and the group's file).
      `none` declares a step with no behavior change; the reviewer judges that claim.

approval binds to a revision, not to a field
  Status field:  Approval: status=approved; by=<login>; at=<date>; rev=<sha40>
    rev = the commit whose plan doc the human approved; the approval line lands in a
    later commit. rev= is optional for older v2 docs and required by --doc --apply.
  brief_normalize <doc-text> (scripts/lib/brief.sh, also used by S-8): removes the
    bookkeeping regions, which are the TRIAGE Status line, the Tracker lines and the
    eight Status field lines. Everything else is compared byte for byte.
  the plan is approved at HEAD only when rev exists, is an ancestor of HEAD, and
    brief_normalize(doc@HEAD) == brief_normalize(doc@rev).
    Otherwise: "approval is for <rev12>; the plan changed at <sha12>: re-approve".

scripts/plan-to-issues.sh --doc <doc> [--apply|--diff]   (no spec file)
  builds the spec from the plan block at rev; packet fields are extracted, never retyped:
    brief ← <doc>@<rev>#<heading> · definition_of_done ← DoD
    verification ← Verify + the brief's Verification commands · risks ← Risks
  --apply requires a committed, clean doc that is approved at HEAD (above); stamps
  rev on every issue: <!-- agentic-flow:plan id=<id> approved=<rev> [journal=v1] -->
  (journal=v1 is written only when an issue is created, from S-3 on; see legacy prefix)
  reapply on an existing plan adds or updates approved= in place, preserving the
  live label state; this is also the migration for a legacy plan
  the JSON spec path stays for legacy plans and Security docs without a block

agentic-flow brief <doc> <step-id> [--at <sha>] [--analysis]
  prints: title, Part B preamble (Branch, word ceilings, DoD, Verification),
  then the one step section; --analysis adds Part A. Default --at: the approved sha.

scripts/hooks/session-context.sh   (SessionStart; Claude, and Codex if supported)
  branch → the inprogress doc whose plan block names it → cached state
  prints ≤ 120 words: plan, doc, open step, state, the next command. No network.
  Any error or no match → prints nothing, exit 0.

agentic-flow verify-step <sha> [--doc <doc> --step <id>] [--red-base <sha>] [--json]
  runs in a fresh `git worktree add --detach` of <sha>; always removed
  order: make verify-prepare (if defined) → make check → step's Verify target
         → for each Red-first line: worktree at red base + its paths from <sha>,
            run its selector
  red-first status per line:
    red      exit 1 and the output matches the project's assertion signature
    invalid  any other non-zero exit, or no signature line (wiring, usage, syntax)
    green    exit 0
  the step passes red-first only when every line is red; with `none` it is
    not-declared, and with no Red-first label and no --step it is not-declared too
  assertion signature: RED_FIRST_SIGNATURE, an ERE declared once per project
    (this repo: ^self-test failed: , the prefix of fail() in self-test.sh),
    rendered from a profile `red-first-signature` row; absent → every non-zero
    exit is `invalid`, so a project must declare it before red-first can pass
  red base: parent of the step's first commit (from the journal) with --step,
            else <sha>^
  record  $(git rev-parse --git-common-dir)/agentic-flow/verify/<sha40>.json
    { v:1, sha, tree, red_base, harness_version, started,
      commands:[{cmd, exit, seconds, output_sha256}],
      red_first:[{selector, paths, exit, status: red|invalid|green, tail[≤40 lines]}]
                | "not-declared",
      prepare:{cmd, exit, seconds}, tools:{bash, git, make, jq} }
  exit 0 = check and Verify green, red-first red or not declared; 1 otherwise
profiles/*.tsv gain an optional `verify-prepare` row (node: npm ci --prefer-offline;
  rust: shared CARGO_TARGET_DIR under the git common dir; python: its ci-setup
  install with the pip cache; generic, go: none) and an optional
  `red-first-signature` row (generic: none; S-6 confirms each runner's real
  failure line before shipping a value, e.g. cargo's `test result: FAILED`,
  go's `--- FAIL`, pytest's `FAILED`, vitest's `FAIL`)

agentic-flow packet <issue> --station executor|reviewer [--json]
  admission: issue carries a plan stamp; created by an approver login; the
    stamped approved sha exists locally. Otherwise refuse, exit 3.
  content:   brief slice at the approved sha (S-5) · journal state ·
             executor: reviewer findings since the latest submit ·
             reviewer: the latest submit comment + the S-6 record for its head,
                       or "no record; run verify-step" ·
             "dropped <n> comment(s) from authors outside the policy" (count only)
  cap: 3,000 words; over → refuse naming the largest part
station profiles (shipped, used by Phase 2's controller)
  claude:   settings file with permissions.deny for Bash(gh:*), WebFetch(domain:github.com)
  codex:    exec profile with network disabled and no GH_TOKEN in the environment
  opencode: agent permission denying `gh *`

agentic-flow close-out prep <doc> --pr <url>
  the close target and its precondition come from the plan block's profile:
    strict:   target = the tracker; every step replays `approved` and the tracker
              replays `closing`
    standard: target = the sole work issue, which is also the Tracking issue (as
              lifecycle's reuse-tracking-page path already treats it); it replays
              `closing`. No tracker and no notify exist.
    legacy topology: refuse; close out by hand
  writes:   Tracker ticks (issue #, approved sha, review-fix shas; Standard has
            exactly one line), Status fields with `Tracking issue` = the target's
            URL, TRIAGE → ✅ Done, git mv to docs/done/, docs-index.sh; stages by
            name; never commits. Re-running on a done doc changes nothing.
agentic-flow close-out finish <doc>
  runs lifecycle-status --phase close-out --check --verify-evidence; on READY,
  `handoff <target> close --as approver` (closing → closed for both topologies,
  which also removes the workflow labels)
  a final-head `pr-head-approval` fallback verdict, when needed, is read from the
  target: the tracker for Strict, the work issue for Standard (as today)
coverage for Standard is the same rule with one step: the work issue's accepted
  approval covers (end of the plan-approval range, its approved head]
lifecycle-status.sh: new `Review verdict: source=close-out-attestation`
  READY when all hold on the PR head:
    every approved step head is an ancestor (G-2, unchanged)
    the policy workflow's latest attempt on the head concluded success
    coverage: base = merge-base(main, head); the plan approval covers commits
      before the first step that touch only the plan doc and leave
      brief_normalize(doc) equal to brief_normalize(doc@rev); step k's verdict covers
      (step k-1 approved head, step k approved head]; the rest is the close-out delta
    the close-out delta is within the allow-list:
      the plan doc's rename inprogress/ → done/ with brief_normalize unchanged;
      the generated region of docs/README.md
  otherwise: falls back to a `pr-head-approval` verdict for this exact head and
    attempt; without one → NEEDS-REVIEW listing each uncovered path
  any merge commit in base..head → NEEDS-REVIEW (no attestation through merges)
```

## Threat model (one paragraph)

The repository is public, so any GitHub user can comment. The assets are the journal (which decides labels, close and close-out), the brief at its approved commit (which instructs agents), and the App private keys. A stranger's transition line is skipped by `journal_replay` because the author holds no role. Labels are a projection of the journal, so a label someone sets by hand misleads nobody who decides, and the next `handoff` on the plan repairs it. A policy login acting outside its role is skipped too, and the skip is counted and printed. A forged "approved" therefore cannot move a step. Stranger text never reaches a station through `packet`. Interactive agents can still read threads; that accepted risk stays open, narrowed, until stations run headless with the S-7 profiles. App keys live in the operator's keychain and never in the repo. Every token is requested with an explicit permission set, so no agent token can push even if an App is misconfigured. Minting failure never falls back to the owner's token, which would silently re-merge the identities. Four residual risks remain. On the operator's machine, any process running as that user can reach every role's key. Separate identities make provenance legible and stop honest mistakes, but they do not stop a hostile local agent. The hook blocks agents from calling `agentic-flow token` directly, and Phase 2's headless stations hold no credential at all. The S-6 record is a local file the executor could alter; it is convenience evidence, and CI on the head is authoritative. Close-out attestation removes an LLM review for allow-listed deltas, and Markdown here is agent instruction, so the allow-list is byte-exact and any parse doubt falls back to review. `verify-step` runs `make` on the step's own commit, which is the same trust as running the tests today.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---|---|---|---|
| `gh` issue read in `handoff` / `packet` | 20 s via `bounded_gh`; exit 5, no writes | exit 5, no writes | more than 100 comments → refuse, exit 5 |
| plan lock in `handoff` | wait ≤ 30 s, then exit 5, no reads or writes | a lock with no live pid is taken over | n/a |
| `gh` comment post in `handoff` | re-read the thread; if the id is there, continue from reconcile, else exit 5. Never post twice. | n/a | posted but labels failed: exit 5; any later `handoff` on the plan (the same one, `reconcile`, or another event) reconciles labels and plan effects from the journal |
| `gh` label edit / close | exit 5; the journal still decides the state | n/a | one edit sets the whole pair; close/reopen is a second idempotent call; the post-write check repeats at most twice, then exit 5 |
| tracker notify after the last approval | exit 5 | n/a | crash after the last step closed and before notify: the next `handoff` on any issue of the plan, including a retry of the same approve or a `reconcile` run by any role, posts the notify once under the reviewer identity, or exits 7 naming the command if that identity is not on this machine |
| App token mint (`openssl` + API) | exit 5 | exit 5 | token returned with broader permissions than requested → `--check` fails, exit 5 |
| `git worktree add` in `verify-step` | n/a (local) | n/a | failure → no record, exit 1; the worktree is always removed and pruned |
| each `verify-step` command | `AGENTIC_VERIFY_TIMEOUT`, default 1800 s → exit 124 recorded, step fails | n/a | a record is written only after every command finished |
| CI conclusion lookup in lifecycle | UNVERIFIED (as today) | UNVERIFIED | run pending or in progress → NOT READY "CI pending" |
| SessionStart hook | must finish < 1 s; no network | prints nothing | prints nothing |

Bounds: one page of 100 comments per issue read; 20 s per `gh` call; 30 s lock wait; one handoff writes at most two issues (step and tracker) and repeats its post-write check at most twice; packet ≤ 3,000 words; SessionStart output ≤ 120 words; one verify worktree per run.

## Out of scope / What NOT to build in this pass
- The controller (`agentic-flow run`, R-8), `config/roles.tsv` (R-7), andon notifications (R-9; only the bounce cap's `escalated` state lands here), the run ledger (R-10), `ship` (R-11).
- Reconciling every stamped issue after a crash (R-20). `handoff` is idempotent per transition; plan-wide recovery is Phase 2.
- Flipping this repo to `distinct-account` and retiring `single-operator-review`: the follow-up pass (decision 1).
- Replacing the lexer hooks with permission rules (R-12), native PR reviews (R-13), the upgrade file split (R-14), splitting the existing `self-test.sh` (R-15), the docs diet and the HTML explainer (R-16), the scenario-first template and word cap (R-17). S-4 adds only the labels its parser needs.
- Removing the compatibility marker lines that `lifecycle-status.sh` still reads.

## Open questions
- Which login form does each read path return for an App author? GraphQL (`gh issue view --json comments`) may report `slug` where REST reports `slug[bot]`. S-2 confirms against a real App comment and normalizes in one place.
- Does Codex support a `SessionStart` hook, and can its exec profile and OpenCode's agent permissions deny `gh` as S-7 needs? The analysis did not verify either. Where not, close-out records an accepted risk naming the gap.
- Is 3,000 words the right packet cap? It fits every step of this brief. Phase 2's ledger will measure it.

---

# Part B — Implementation Brief

> **Audience:** the implementing agent (Codex). Steps are ordered foundations first, riskiest station next. One logical commit per step; do not bundle. Stage files by name. Why-first commit bodies. The brief carries intent, interface, invariants and acceptance scenarios; you choose files and functions.

```agentic-flow-plan
id: deterministic-stations
profile: strict
tracking: Plan: Deterministic stations
branch: phase-1
steps: s-1 s-2 s-3 s-4 s-5 s-6 s-7 s-8 s-9
```

This pass's own issues are created with today's JSON-spec path, because S-4 builds the block reader. The block above and each step's labels are the format S-4 introduces. They are written here so the brief is valid input once S-4 lands, and S-4 and S-6 use this brief as their own test input.

## Bootstrap (this pass only)

This pass builds the journal that its own close-out reads. It is therefore migrated in four stages, each checked by a command, and gets no exemption:

1. **Approval.** When the human approves this brief, Claude commits the Approval line in today's validated format (`status=approved; by=…; at=…`). The approved revision goes in that commit's body as `Approved revision: <sha40>`, meaning the commit whose brief the human read. Today's validator rejects `rev=`, so the field cannot carry it yet.
2. **S-1, S-2.** Today's process: `plan-to-issues.sh --apply --approved-by` from a hand-written JSON spec, hand-written handoff comments, the current hook. Reviewers post the structured step marker for every verdict, including `status=changes-requested` for a bounce, so the legacy prefix maps them exactly.
3. **S-3 onward.** Once S-3's commit is on the branch, its hook blocks raw workflow label edits, so every handoff in this pass, including S-3's own submit, goes through `agentic-flow handoff`. Before the first one, run `agentic-flow handoff <N> reconcile` on the tracker and on each step issue. It must report every issue as journaled: S-1 and S-2 approved, S-3 executing, the rest executing. Any UNJOURNALED issue stops the pass and goes to the human.
4. **After S-4 is approved.** In one commit that changes only the Status field, Claude adds `rev=<the sha from stage 1>` to Approval.
   - Save `agentic-flow handoff <N> reconcile`'s replay output (`--json`) for the tracker and every step.
   - Run `scripts/plan-to-issues.sh --doc docs/inprogress/feature-deterministic-stations.md --diff`. It must show only `approved=` stamp additions: no `journal=` change, no label change.
   - Run `--apply`, then the same replays again. Every derived state, seq, bounce count and head must equal the saved output. Any difference stops the pass and goes to the human.

   This pass's issues were created before S-3, so they never carry `journal=v1` and stay legacy-eligible. That check passes only if the brief at HEAD normalizes equal to the approved revision. A review correction to the brief after approval is a content change, so it needs a new approval and a new `rev`, by design. From here `packet` admits this pass's issues.

If any stage fails, close-out falls back to today's lifecycle evidence path, which this pass leaves unchanged. The Status block keeps `source=pr-head-approval` for that reason.

## Branch
Base: `main`. One branch and one PR for the whole brief: `phase-1`. Each step is one commit with `Fixes #N`. Review fixes land as new commits; never amend after a handoff (G-2 rejects it).

## Word ceilings: read before touching any contract file

| File | Words | Ceiling | Enforced by |
|---|---|---|---|
| `CLAUDE.md` (root) | 1515 | 1530 | `scripts/self-test.sh` (planner) |
| `AGENTS.md` (root) | 1088 | 1090 | `scripts/self-test.sh` (executor) |
| `.agents/skills/review-execution/SKILL.md` | 996 | 1000 | `scripts/self-test.sh` (reviewer) |

Do not raise a ceiling. S-9 should shrink these files, since prose is replaced by commands. Any other contract edit before S-9 must be word-neutral. Contract edits to `CLAUDE.md` and `AGENTS.md` need the matching edit in `templates/harness/`.

## Invariants (every step)
- Bash 3.2: no `mapfile`, no associative arrays, guard empty arrays under `set -u`.
- New payload files are declared in `config/payload.tsv` only.
- No literal placeholder or credential-shaped string in any file; build them with `printf` (see `CLAUDE.md` Gotchas).
- Every GitHub write goes through `handoff` or `plan-to-issues.sh`. No new raw `gh issue edit` in contracts.
- Hermetic tests against the fake `gh`; no network in `make test`.

## Definition of done (whole brief)
- Every step's DoD is met.
- `make check`, `make test`, `make build` and `scripts/doctor.sh --check` are green here and in a fresh export.
- The seventeen acceptance scenarios below pass as tests.
- Every stage of "Bootstrap (this pass only)" completed, so close-out prep runs on this pass's own journal.
- A role can complete a Strict step on this repo using only `brief`, `packet`, `verify-step` and `handoff`, with no raw `gh issue edit`.

## Acceptance scenarios (written at Spec; the executor does not edit these)
1. **Replay.** A handoff whose transition is already latest on the thread, with labels missing (crash between comment and label), restores the labels and posts nothing.
2. **Superseded replay.** A submit retried with `--after <seq>` after a later bounce changes nothing and prints `superseded`. A different request with the same stale `--after` exits 4.
3. **Concurrent approvals.**
   - **3a, same machine, lock held.** Two identical approvals start together. The second waits for the lock, finds the first as the latest accepted transition, posts nothing and exits 0. The thread has one approval comment.
   - **3b, lock bypassed, simulating a second machine.** Two approvals, or an approve and a bounce, both post with the same seq. Replay accepts the first in comment order and skips the other. The losing process exits 4 naming the winner, the labels match the winner, and the skipped comment stays on the thread, counted in `skipped`.
   - **3b, carried through lifecycle.**
     - An accepted approve followed by a losing bounce, whose comment carries a `status=changes-requested` compatibility line: `lifecycle-status --verify-evidence` takes the step from the accepted approve and reaches READY, given the other evidence. Today's latest-marker reader would block here, and the test shows that too.
     - The reverse, an accepted bounce and a losing approve: the step is BLOCKED with "journal state executing", never READY.
4. **Hostile thread.** A stranger posts a valid-looking approve transition and an instruction comment. The step does not move, `packet` omits both and reports `dropped 2`, and the hook still blocks a raw label edit.
5. **Amended approval.** A step amended after approval blocks close-out (G-2, unchanged), and `close-out finish` does not close the tracker.
6. **Smuggled instruction.** A close-out delta that changes one sentence of a brief's Approach section is NEEDS-REVIEW, not attested.
7. **Successive transitions race.** A submit pauses after its replay (`AGENTIC_HANDOFF_FAULT=after-replay`). A bounce for the same step is attempted meanwhile. On one machine, the bounce waits for the lock, then sees the submit and applies `executing`. With the lock bypassed to simulate a second writer, the submit's post-write check finds the bounce and rewrites `executing`. Either way the final labels are `executing`, never `reviewing`.
8. **Notify crash window.** The last Strict approval exits at `before-notify` after closing its step. Retrying the same approve posts the tracker notify exactly once and sets the tracker to `closing`. A second retry and a `reconcile` both change nothing.
9. **Approval drift.** A committed edit to one sentence of a step's Approach that leaves the Approval field untouched makes `plan-to-issues --doc --apply` refuse with "re-approve". A commit that changes only Tracker or Status lines does not.
10. **Legacy migration.** A thread holding a legacy submit, a prose-only findings comment, a resubmit and a legacy approved marker replays as approved with one bounce. The same thread with the approve's head different from the latest submit is UNJOURNALED, and `handoff`, `prep` and `packet` refuse it, naming the comment.
11. **Red-first wiring.** A step whose new test group is unknown to the base's runner, with the runner not declared among its paths, reports red-first `invalid`, not `red`. With the runner declared, it reports `red`.
12. **Repeated cycles.**
    - Three submit/bounce cycles on one step, the bounces head-less as Phase 2 will post them, produce three distinct bounce ids. Bounce counts run 1 and 2, and the third bounce goes to `escalated`.
    - A resume, then three more cycles: a second escalation and a second resume, every id distinct, and every transition accepted.
    - A submit of the head the last bounce was made against is refused with exit 3.
13. **Disjoint identities.** With different reviewer, executor and approver logins:
    - The executor runs `reconcile` in the notify crash window with the reviewer identity configured. The notify is posted under the reviewer login and accepted.
    - The same run with no reviewer identity on the machine exits 7 with the recovery command and posts nothing. Re-running where the reviewer identity exists completes it.
    - An executor-authored notify, injected directly, is skipped by replay.
14. **Migration preserves replay.** For a legacy plan with approved, bounced and executing steps, replay output is captured before `plan-to-issues --doc --apply` adds `approved=` and compared after. Every state, seq, bounce count and head is identical, and no stamp gains or loses `journal=`.
15. **Legacy eligibility is fixed at creation.** A `journal=v1` issue whose thread contains a legacy-format approved marker from a reviewer login ignores the marker. A legacy issue whose stamp later gains `approved=` still reads its prefix.
16. **Standard close-out, end to end.**
    - `plan-to-issues --doc --apply` creates one `journal=v1` work issue. It goes submit, bounce, submit, approve, and lands in `closing` with `agent:claude,needs-closing`, open, and no notify attempted.
    - `close-out prep` writes one Tracker tick and `Tracking issue` = the work issue, moves the doc and regenerates the index.
    - With a fake PR and CI green on the head, `finish` attests a prep-only delta as READY and closes the work issue through `handoff close`. The issue ends closed with no workflow labels.
    - The same run with a CHANGELOG edit in the delta is NEEDS-REVIEW until a reviewer's final-head marker for that head and attempt is on the work issue. Then it is READY and closes.
17. **Strict close-out, end to end.** The Strict counterpart of 16, with two steps. The last approval notifies the tracker, `prep` ticks both lines, and `finish` closes the tracker, not a step.

## Verification commands
```bash
make check                          # per step; also run by the Stop hook
make test-one F=<group>             # per step; group named in each step
make test                           # end of brief
make build
scripts/doctor.sh --check
```

---

## S-1 — Define the workflow once in `config/workflow.tsv`
**Why first:** every later step reads it, and nothing reads it yet, so it lands without changing behavior.

**Approach:**
1. Write `config/workflow.tsv` as specified in the Interface, plus `scripts/lib/workflow.sh`. Declare the file in `config/payload.tsv` (core).
2. `make check` validates the file: every transition's `from` and `to` exist for its topology; no transition has `from` equal to `to`; every state is reachable from `executing` or `open`; labels are known; the TSV is tab-separated with no trailing fields.
3. `make check` asserts that the label names the hook and `lifecycle-status.sh` still hard-code equal `workflow_labels`, so drift fails before S-3 removes the hard-coding.
4. Add `needs-human` to `scripts/create-tags.sh` and the `create-tags` skill source in `templates/shared/` (decision 2), with `render-shared.sh` re-run.

**DoD:** the file and library exist, validate, and are exported. Behavior is unchanged.
**Verify:** `make test-one F=contracts`
**Red-first:** `scripts/self-test.sh --only contracts` — scripts/self-test.sh
**Risks:** a malformed row must fail `make check` naming file and line, not just exit non-zero. Unreachable states, duplicate transitions and an unknown label each need a failing fixture.
**Commit:** `Define the issue workflow once as data the scripts can read`

---

## S-2 — Accept GitHub App identities and mint a scoped token per role
**Why second:** S-3 must post as the right identity from its first version.

**Approach:**
1. `scripts/lib/review-policy.sh`: accept `<app-slug>[bot]` logins. Keep every other rule.
2. `scripts/lib/identity.sh` and `agentic-flow token <role> [--check]` per the Interface. JWT signing uses `openssl`; the key comes from the keychain item named by `key-ref`. The token request names the repository and the four permissions explicitly. Never print a key; never write a token to disk.
3. Resolve the open question on login forms: find which form `gh issue view --json comments` and the REST comments API return for an App author, and normalize in one function that both the hook and lifecycle use.
4. `scripts/doctor.sh`: when an identity file exists for this repo, check that each role's login is in the policy and that `token --check` passes. Skip quietly when no file exists.
5. `ADOPTION.md` and `METHODOLOGY.md` §2: how to create three Apps (permissions: Issues and Pull requests write, Contents and Metadata read), install them on one repository, store each key, and write the identity file. Define `approver` as the planner/closer identity, and say that `--approved-by` names the human who approved the plan.

**DoD:** with a fake keychain and a fake GitHub, `token` mints for a configured role, refuses an unconfigured one with exit 6, and never falls back when minting fails.
**Verify:** `make test-one F=contracts`
**Red-first:** `scripts/self-test.sh --only contracts` — scripts/self-test.sh
**Risks:** failure paths first. A mint failure with an identity configured must exit 5, not use the ambient login. A token response that includes `contents: write` must fail `--check`. A `[bot]` login must not widen the regex to accept arbitrary brackets.
**Commit:** `Accept GitHub App logins and mint a scoped token per role`

---

## S-3 — Move issues only through `agentic-flow handoff`, journaled on the thread
**Why third:** it is the riskiest station, and the hook, close-out, packets and the Phase 2 controller all depend on it.

**Approach:**
1. `scripts/lib/journal.sh` and `agentic-flow handoff` per the Interface, including the legacy prefix and `reconcile`. Derivation is pure: given the issue JSON and the policy, `journal_replay` decides the state. All GitHub reads and writes stay in `handoff`, so replay is testable offline.
2. Two layers, for two problems. GitHub's comment order decides which transition is accepted (competing transitions). The plan lock plus the post-write check decide what the labels say (a stale writer). Labels are always written from a replay made after the last read, never from the transition just requested. Plan effects are reconciled on every run, so a retry repairs a crash at any point.
3. Create `scripts/tests/stations.sh` and wire a `stations` group into `scripts/self-test.sh` (the `--only` list and its call-site check) and the `Makefile` usage line.
4. The role check: with an identity configured for `--as <role>`, post with that role's token and confirm the posted comment's author is the configured login before any label write. Without one, the ambient login must hold `<role>` in the policy.
5. Shrink `scripts/hooks/require-step-comment.sh` to one rule, using the shared lexer (`scripts/lib/hook-command.sh`). Block an agent's Bash command that adds or removes a workflow label (`workflow_labels`) through `gh issue edit` or `gh api`, or that closes or reopens a plan-stamped issue. The message names the `handoff` command to use instead. Close and reopen need one stamp read; if it fails, block, since closing is rare. Also block an agent's direct `agentic-flow token` call: `handoff` mints tokens internally, and no contract needs a raw token. Rename the hook if its name no longer fits, and update `.claude/settings.json`, `.codex/hooks.json` and doctor together.
6. `scripts/plan-to-issues.sh`: write `journal=v1` into the stamp of every issue it creates from this commit on. Reapply preserves whatever `journal=` value an existing stamp has.
7. `lifecycle-status.sh`: in the same commit that starts posting compatibility lines on comments that can lose a race, make `verify_step_review` select evidence from accepted journal transitions for journaled issues, per "lifecycle evidence for journaled issues" in the Interface. Source `scripts/lib/journal.sh` and feed it the GraphQL nodes lifecycle already fetches. Keep every existing check on the selected comment: author, overlap, edit, head and ancestry. Purely legacy issues and final-head markers keep today's reader byte for byte.

**DoD:** acceptance scenarios 1–4 (including 3b through lifecycle), 7, 8, 10, 12, 13 and 15 pass. The existing lifecycle fixtures pass unchanged. No contract or hook still requires a hand-written handoff comment. Bootstrap stage 3 succeeds on this pass's issues.
**Verify:** `make test-one F=stations`, `make test-one F=hooks` and `make test-one F=lifecycle`
**Red-first:** `scripts/self-test.sh --only stations` — scripts/self-test.sh scripts/tests/stations.sh
**Red-first:** `scripts/self-test.sh --only hooks` — scripts/self-test.sh
**Red-first:** `scripts/self-test.sh --only lifecycle` — scripts/self-test.sh
**Risks:** failure paths first: a lost race, a race-losing comment's compatibility line reaching lifecycle (scenario 3b), an edited accepted approval (BLOCKED, as today), a stale writer (scenario 7, with and without the lock), an illegal successor, a post that timed out after it landed, a stale lock from a dead pid, a thread over 100 comments, a role login acting outside its role, a third bounce reaching `escalated`, the notify crash window (scenario 8), id uniqueness across cycles (scenario 12), a plan effect whose identity is absent (scenario 13), and a resubmit of the last bounced head being refused with exit 3. The hook must not block the human-facing `gh issue view`.
**Commit:** `Move workflow issues only through a journaled, idempotent handoff`

---

## S-4 — Read the plan from the brief; plan approval authorizes apply
**Why fourth:** S-5, S-7 and S-8 slice the brief by its plan block and approved commit.

**Approach:**
1. Plan-block, step-section, Red-first and `brief_normalize` parsing go in `scripts/lib/brief.sh`. Parsing is strict. A missing required label, a duplicate step id, a `steps:` entry with no section, a section with no entry, or a malformed Red-first line fails, naming the line.
2. `lifecycle-status.sh` `valid_value`: accept an optional `; rev=<sha40>` on `Approval`.
3. `scripts/plan-to-issues.sh --doc <doc>` builds the spec from the doc at `rev` per the Interface, then runs the existing reconcile path. `--approved-by` comes from the `Approval` field. The plan stamp gains `approved=<rev>`. Reapply adds or updates the stamp in place on existing issues; that is the legacy migration.
4. `--apply` refuses when the doc is uncommitted or dirty, when `Approval` lacks `status=approved` or `rev`, or when the plan is not approved at HEAD (Interface). The refusal names `rev` and the first commit that changed the normalized text.
5. Skill source (`templates/shared/plan-to-issues.SKILL.md`): replace steps 2 and 5 with "when the human approves, record `Approval` with `rev=` set to the commit they read, commit, run `--doc --apply`". Re-render. Keep the JSON path documented for legacy plans and Security docs.
6. `docs/templates/feature-analysis.md` and `security-review.md`: add the plan block and the per-step `**Verify:**`, `**Risks:**`, `**Red-first:**` labels. Nothing else in the templates changes (R-17).

**DoD:** acceptance scenarios 9 and 14 pass. A fixture copy of this brief with `rev` set dry-runs through `--doc` to the same issue set its hand-written spec produced, with each packet under 800 words. Bootstrap stage 4 then succeeds on this pass's live issues.
**Verify:** `make test-one F=plan-to-issues`
**Red-first:** `scripts/self-test.sh --only plan-to-issues` — scripts/self-test.sh
**Risks:** an unapproved, dirty or uncommitted doc must not apply. Neither may a doc whose `rev` is not an ancestor of HEAD, nor one whose normalized text changed after `rev` while the Approval field was untouched. A packet field must be byte-equal to the brief text at `rev`, so check one field per label against `git show`. A legacy JSON spec must reconcile exactly as before.
**Commit:** `Build issue specs from the brief and treat plan approval as the apply go-ahead`

---

## S-5 — Hand a role one step: `agentic-flow brief` and a SessionStart hook
**Why fifth:** S-7's packet embeds this slice.

**Approach:**
1. `agentic-flow brief` per the Interface, on `scripts/lib/brief.sh`. It reads the doc at `--at` with `git show`, so a later uncommitted edit cannot change what a role is told.
2. `scripts/hooks/session-context.sh` on `SessionStart` in `.claude/settings.json`, reading only the local state cache that `handoff` writes. Wire it in `.codex/hooks.json` if Codex supports the event; otherwise `AGENTS.md` routes to `agentic-flow brief` (word-neutral until S-9).
3. Doctor checks the wiring like the other hooks.

**DoD:** on this repo's branch, a new session prints the plan, the open step, its state and the next command. On `main` it prints nothing.
**Verify:** `make test-one F=stations` and `make test-one F=hooks`
**Red-first:** `scripts/self-test.sh --only stations` — scripts/self-test.sh scripts/tests/stations.sh
**Red-first:** `scripts/self-test.sh --only hooks` — scripts/self-test.sh
**Risks:** the hook must never block or slow a session: a missing cache, a corrupt cache, a detached HEAD, two docs naming one branch (print nothing and let doctor warn), and a missing `jq` each exit 0 within the bound.
**Commit:** `Give each role its step slice and inject the current step at session start`

---

## S-6 — Verify a step in a clean worktree of its commit
**Why sixth:** S-7's reviewer packet carries this record.

**Approach:**
1. `agentic-flow verify-step` per the Interface. The worktree comes from the commit, never the working tree, so staged, unstaged and untracked files cannot be certified.
2. Add the `verify-prepare` and `red-first-signature` rows to each profile and to `render-stack-profile.sh`. Add a no-op `verify-prepare` target and `RED_FIRST_SIGNATURE` to this repo's `Makefile` and `templates/harness/Makefile`; this repo's value matches `fail()` in `scripts/self-test.sh`. Settle the per-stack dependency cache here, as the analysis requires.
3. Red-first reads the step's Red-first lines from the brief at `rev` (`--doc --step`). It classifies each line as red, invalid or green per the Interface, and keeps the last 40 output lines so the reviewer can see why the old code failed. A failure without the assertion signature, such as an unknown group, a missing file or a syntax error, is `invalid` and fails the step. It is never counted as red.
4. Reviewer contract (word-neutral until S-9): reuse a record only when its `sha` and `tree` match the reviewed head; otherwise run `verify-step` once.

**DoD:** acceptance scenario 11 passes. `verify-step <S-5 head> --doc <this brief> --step s-5` produces a record whose `tree` equals `git rev-parse <sha>^{tree}`, with both of S-5's declared Red-first lines `red` against S-4's head. An uncommitted edit in the main worktree does not change the result.
**Verify:** `make test-one F=stations`
**Red-first:** `scripts/self-test.sh --only stations` — scripts/self-test.sh scripts/tests/stations.sh
**Risks:** failure paths first: a dirty main tree must not leak into the run; a command timeout records 124 and fails; a red-first that passes on the base fails the step; a red-first that fails without the signature is `invalid`; a project with no signature cannot pass red-first; the worktree is removed after an interrupt (trap on INT and TERM); a missing `verify-prepare` target is skipped, not an error.
**Commit:** `Verify a step in a clean detached worktree and record what ran`

---

## S-7 — Build station input only from trusted sources
**Why seventh:** it is the prerequisite for any headless station, and it needs S-3's journal, S-5's slice and S-6's record.

**Approach:**
1. `agentic-flow packet` per the Interface. Admission runs first; a refused issue yields no packet content at all.
2. Comments from authors outside the policy are counted and dropped, never summarized or quoted. Comments from policy logins are included only where the station's role needs them.
3. Ship the three station profiles (decision 3) under a harness-owned path declared in `config/payload.tsv`. Prove the Claude one with a test that loads it and checks the deny list. For Codex and OpenCode, confirm the mechanism; where it does not exist, say so in the commit body for the close-out accepted risk.
4. Update `docs/accepted_risks.md#agent-thread-prompt-injection` with what this narrows: headless stations can now get trusted input, and interactive reads remain.

**DoD:** acceptance scenario 4's packet half passes. A packet for an issue created by a non-approver login, without an `approved=` stamp, or UNJOURNALED is refused.
**Verify:** `make test-one F=stations`
**Red-first:** `scripts/self-test.sh --only stations` — scripts/self-test.sh scripts/tests/stations.sh
**Risks:** a stranger comment that copies a policy login's text, an edited comment (use the current body; author is what decides), a packet over the cap, a stamped sha missing locally (refuse with the fetch to run).
**Commit:** `Build station packets from the approved brief and policy-authored comments only`

---

## S-8 — Script close-out and attest a bookkeeping-only final delta
**Why eighth:** it consumes the journal, the plan block and the G-2 ancestry check.

**Approach:**
1. `agentic-flow close-out prep` and `finish` per the Interface, with the close target and precondition chosen by the plan block's profile: the tracker for Strict, the sole work issue for Standard. `prep` refuses without a real PR URL (memory `close-out-needs-pr-first`) and refuses legacy topology.
2. `lifecycle-status.sh`: add `source=close-out-attestation` to the `Review verdict` field validator and implement the coverage and allow-list rules. Existing sources keep their semantics. The doc comparison is S-4's `brief_normalize`, not a second implementation. Anything it cannot parse is NEEDS-REVIEW.
3. `prep` reads step state from the journal, including the legacy prefix. An UNJOURNALED step makes `prep` refuse and name it; the closer then finishes by hand on today's evidence path.
4. `docs/templates/*`: the Status block defaults to `source=close-out-attestation`.
5. Close-out paragraph in `CLAUDE.md` (root and template): word-neutral here; S-9 rewrites it.

**DoD:** acceptance scenarios 5, 6, 16 and 17 pass. A pass whose close-out delta is only `prep`'s output reaches READY without a reviewer comment once CI is green on the head. A delta that adds a CHANGELOG entry needs one. `prep` dry-runs on this pass's own tracker (bootstrap stage 3 journal).
**Verify:** `make test-one F=lifecycle` and `make test-one F=stations`
**Red-first:** `scripts/self-test.sh --only lifecycle` — scripts/self-test.sh
**Red-first:** `scripts/self-test.sh --only stations` — scripts/self-test.sh scripts/tests/stations.sh
**Risks:** failure paths first: a merge from `main` inside the range, a step range with a gap (a commit between two approved heads that no verdict covers), CI pending, CI green on an earlier attempt and red on the latest, a whitespace-only change outside the allowed lines, and `prep` re-run on a done doc.
**Commit:** `Script close-out and attest the final head when its delta is bookkeeping`

---

## S-9 — Render the state machine into the contracts and route them to the commands
**Why last:** the prose can route to the commands only once they exist.

**Approach:**
1. Generate `templates/shared/workflow.md` from `config/workflow.tsv`, either as a renderer or a `render-shared.sh` mode. `make check` fails when it is stale. Render it into one `WORKFLOW` region in `METHODOLOGY.md` §6.
2. Every other home named in B-4 (`CLAUDE.md`, `AGENTS.md`, `code-reviewer.md`, the review-execution skill, the plan-to-issues skill, `docs/README.md`, `ADOPTION.md`) drops its own state-machine description. Each keeps one routing sentence: which commands that role runs, and that the states live in `METHODOLOGY.md` §6. Executor: `brief`, `verify-step`, `handoff submit`. Reviewer: `packet`, `verify-step`, `handoff approve|bounce`. Closer: `close-out prep|finish`.
3. Fold the B-6 overlap while there: the verdict format and red-first paragraph live once, in `templates/shared/review-contract.md`.
4. Leave `docs/agentic-flow-explained.html` as it is (R-16), but add one line to its top saying `METHODOLOGY.md` §6 is authoritative.

**DoD:** a grep for the label names outside `config/workflow.tsv`, the rendered region and the tests finds only routing sentences. All three role bundles are below their pre-pass word counts.
**Verify:** `make test-one F=contracts`
**Red-first:** `scripts/self-test.sh --only contracts` — scripts/self-test.sh
**Risks:** the root and template copies must stay in step (`check-harness-sync.sh`). Ceilings must not be raised. Rendered regions must survive `render-shared.sh --check` in an exported project, where the sources are absent.
**Commit:** `Render the workflow once and route every contract to the station commands`

---

# Close-out

Claude, on `phase-1`, before final approval; the sequence is the one in `CLAUDE.md`:

1. Close-out commits: `VERSION` 0.15.0 and a `CHANGELOG.md` entry with migration notes (raw workflow label edits are now blocked for agents; `plan-to-issues --doc`; the new template labels; the `SessionStart` hook in `settings.json`; the `verify-prepare` profile row; the `needs-human` label). Add any accepted risks from S-5 or S-7.
2. Use `agentic-flow close-out prep` for Status, Tracker, TRIAGE, move and index, in the last commit. It reads this pass's journal, which bootstrap stage 3 established; if it refuses, finish by hand as in Phase 0. The CHANGELOG makes the delta non-bookkeeping, so this pass still takes a reviewer verdict on the final head.
3. The human pushes. CI and the reviewer verdict follow for that head. `agentic-flow close-out finish` closes the tracker.
4. Open the follow-up identity-flip pass (decision 1).

---

## Status / Implementation status
- **Evidence schema:** v2
- **Tracking issue:** url=https://github.com/wabkebab/agentic-flow/issues/124
- **Approval:** status=approved; by=wabkebab; at=2026-11-12; rev=a4c4438a8f52d71dcc8f52bb2341adcc4f42814b
- **Implementation head:** source=pr-head
- **Implementation PR:** url=https://github.com/wabkebab/agentic-flow/pull/134
- **Verification evidence:** source=final-approval-run
- **Review verdict:** source=close-out-attestation
- **Memory:** status=n/a
- Close-out: finalize Status/Tracker, set TRIAGE to Done, move this document and update
  the index in the last repository commit. After human push, obtain CI and a structured
  reviewer approval on the `Tracking issue` for that exact PR head and run attempt.
  Verify this moved file with `--phase close-out`, close the tracker without another
  repository edit, then recheck with `--phase pre-merge` before human merge.
