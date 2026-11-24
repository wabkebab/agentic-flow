# Agentic Development Methodology

> The standard plan → execute → review loop, the document lifecycle, and the
> conventions that make agentic work repeatable across projects. This file is the
> source of truth; templates in `docs/templates/` are the fill-in-the-blanks forms.
> Load this file by referenced section, not wholesale, during routine work.
>
> Stack-agnostic by design. The only project-specific thing is the **Stack profile** — the
> [`Makefile`](Makefile), the one executable source of truth for build/test/run commands.
> Everything here, in the templates, and in the hooks calls its targets: `make check`
> (fast type-check + lint gate), `make test`, `make test-one F=…`, `make build`, `make run`.
> `CLAUDE.md` explains those targets and their gotchas; the `Makefile` runs them.
>
> **Standard version:** The scaffold's `VERSION` is a human-facing semver, bumped deliberately
> on a contract change (a section here, in `CLAUDE.md`/`AGENTS.md`, or a hook/script
> behavior an adopted project depends on). `scripts/export.sh` and `scripts/init.sh` combine
> it with the exact commit as `<semver>+<sha>` (semver build-metadata syntax) and stamp it
> into a target's `.agentic-flow-version` — the semver half is what a human compares release
> notes against, the `+sha` half is what tooling diffs exactly. `scripts/doctor.sh` reports
> both halves split back apart.

---

## 1. Roles

| Role | Who (default) | Output |
|------|---------------|--------|
| **Plan / Close-out** | Claude | Analysis and implementation briefs, GitHub issues, then Tracker/Status updates, document move, and closing the tracking or Standard work issue after review. Commits with `git-claude`. |
| **Execute** | Codex | Code that satisfies the issues generated from a plan, one logical commit per step, each recorded as a comment on its step issue. Commits with `git-codex`. |
| **Review** | OpenCode | Reviews each completed step against the brief, returns findings or records approval; closes Strict sub-issues and relabels Standard work issues for close-out. Commits any review-note changes with `git-opencode`. |
| **Own / merge / deploy** | Human | Approves plans, merges PRs, controls all pushes and releases. |

**Review is a separate role on purpose.** The value is independence: the agent that wrote the
code is not the agent that judges it. Claude may still run `/code-review` (§8) as a *second*
opinion or on a whole branch, but that does not replace the reviewer's pass — and a step should
not be reviewed twice by default.

This three-agent split is the **default standard**. A project may **opt out** of either agent
role, keeping the same document lifecycle and review discipline:

- **No Codex** — configure the role policy (§6) and omit `git-codex`; Claude plans and executes.
- **No OpenCode** — configure the role policy (§6) and omit `git-opencode`; Claude reviews with
  `/code-review` or a hand-written review doc. Independence is weaker, so say so in the review
  verdict rather than implying a separate reviewer signed off.

State any opt-out at the top of the project's `CLAUDE.md`. **Exactly one role reviews** — an
opt-out reassigns the review, it never leaves it to both.

---

## 2. The loop

```
  agentic-flow start <plan-id>     creates the plan branch, worktree and draft
        │
        ▼
  Review / Plan (Claude)
        │  produces
        ▼
  docs/inprogress/<doc>.md         Security | Feature
        │   (docs carry an inlined Implementation Brief —
        │    the execution insights for the implementer, NOT the code)
        │
        │  human approves
        ▼
  plan-to-issues  ───────────────▶  Standard: one work issue
                                   Strict: tracker + sub-issues
        │
        ▼
  Execute (Codex)                   one branch + PR per pass; one commit + "Fixes #N"
        │                           per step; returns result JSON to controller
        ▼
  Review (OpenCode)                 reviews the submitted commit against the brief;
        │                           returns findings or approval to controller
        ▼
  Close-out (Claude)                tick the Tracker, update Status and commit the doc move
        │
        ▼
  ship (human)                      push once, open the PR and wait for CI and final review
        │                           then close the named issue and verify pre-merge readiness
        ▼
  Merge (human)  ────────────────▶  the PR. Reviewed issues are already closed;
        │                           "Fixes #N" stays for traceability.
        ▼
  agentic-flow clean <plan-id>     remove the merged plan branch and worktree
```

The human approves, runs `agentic-flow run`, answers andon, runs `ship`, and merges.
The controller verifies station results and performs handoffs; supervised `run --once`
skips the unattended entry gate. Interactive stations use the commands in §6.

**A closed Strict sub-issue means "reviewed clean", not "shipped."** The reviewer closes it before
the PR merges, so GitHub issue state is deliberately *not* the shipping signal. What shipped
is recorded in the implementation doc's Status block and enforced by
`scripts/lifecycle-status.sh --doc <moved-document> --phase close-out --check --verify-evidence`
against a [CI run](docs/reference/ci-cd.md). The Strict tracker or Standard work issue stays open through
close-out; use `close-out prep|finish` (§6).

**Why the handoffs carry data, not just labels.** `agentic-flow handoff` journals the
commit sha and verification for submit, or the verdict for approve/bounce. Each role then starts from the
issue instead of re-deriving state from `git log` and guesswork, and close-out can read the
whole pass off GitHub rather than asking a human what the reviewer decided. A label with no
comment behind it is a handoff that costs the next role a full re-investigation.

The final approval is a structured comment on the issue named by `Tracking issue`, after
CI has run on the final PR head. Post a new verdict to change an earlier one; never edit
a verdict comment. An edited authoritative verdict blocks close-out until a fresh verdict
is posted or its structured marker is removed. Earlier verdicts for other heads are history.
The gate authenticates the comment author, but in single-operator mode the reviewer role
is only an attestation, not proof of independence. Comments and Actions runs remain mutable:
verification is point-in-time, not a merge guard.

Approvals bind to commits. Merge base-branch updates into the plan branch to preserve
the approved revision and each approved step commit as ancestors of the PR head.
Rewriting those commits invalidates the associated evidence. Missing objects or shallow
history leave ancestry UNVERIFIED until the operator fetches the history.

`agentic-flow handoff approve|bounce` writes the step verdict on that step's issue,
using the executor's full implementation SHA (`status=changes-requested` for bounce):

```text
agentic-flow-review: status=approved; step=<step-id>; head=<40-hex-implementation-sha>; role=reviewer
```

After the final PR head is pushed and CI succeeds, copy this final approval into the
`Tracking issue` thread, using that run's current attempt:

```text
agentic-flow-review: status=approved; pr=<PR-number>; head=<40-hex-PR-head>; run=https://github.com/<owner>/<repo>/actions/runs/<run-id>; attempt=<positive-integer>; role=reviewer
```

The loop is **one-directional** (doc → issues), never the reverse. The document stays the
source of design intent; issues are the disposable execution units.

### Optional App identities

`approver` means the planner/closer identity, distinct from `--approved-by`, which
records the human's plan approval. Create three GitHub Apps with Issues/Pull
requests write and Contents/Metadata read, install each on only the target
repository, and store each RSA key in the workstation keychain. Configure role,
canonical `slug[bot]` login, App ID, installation ID and key-ref in the operator's
repository-specific identity TSV; add the logins to the review policy.
[ADOPTION.md](ADOPTION.md#github-app-role-identities-optional) gives the setup and
file location. `agentic-flow token <role> --check` mints a repository-scoped token
and validates permissions without printing it. Configured identity failures never
fall back to ambient credentials. Switching to distinct-account is an adoption
decision that removes the accepted-risk= line from the policy.

### Assurance profiles

The tracked `.agentic-flow-assurance` file holds the project's minimum profile: `quick`,
`standard`, or `strict`. A missing file in a legacy adoption means Standard. New adoptions
start at Standard. Run `scripts/assurance.sh status` to see the value and its source, or
`scripts/assurance.sh --check` to validate the state. `set <profile>` raises it. A downgrade
requires `--approved-by <human-identity> --reason <text>` and appends a dated transition to
`.agentic-flow-assurance-audit`. Commit both files. These arguments record claimed human
approval in the diff; the CLI cannot authenticate the claimant. Review the claim before
accepting a downgrade. A Feature/Security brief may raise the effective profile above this
baseline, never lower it.

| Profile | Use and artifact | Review and evidence |
|---------|------------------|---------------------|
| **Quick** | Explicitly selected bounded local work, with no formal brief or issue. | Focused test, inexpensive checks, executor self-check, and a `Workflow: Quick / non-authoritative` report. It carries no independent review or CI approval claim and must promote to Standard before the normal merge workflow. |
| **Standard** | One-step Feature brief and one work issue, with no parent tracker. | Separate-role review, regression test, `make check`, proportionate broader tests, and CI evidence. |
| **Strict** | Full Feature/Security analysis, tracker, and one sub-issue per independently shippable step. | Separate-role review and failure-path test per step, full suite, bound CI and close-out evidence. |

Strict is mandatory for authentication, secrets, destructive or data-loss behavior,
migrations, public compatibility contracts, money or entitlements, release infrastructure,
sensitive data, or an explicit human request. Quick is local and never authorizes a push or
merge. Every profile keeps the same engineering standards, command policy, pre-commit scan,
CI authority, and human ownership of pushing and merging. Review identity guarantees still
depend on the configured review identity mode, not the profile.

Profiled specs activate the matching issue topology. A profile-less existing spec retains
the legacy tracker-plus-steps topology. The driver rejects topology-changing reapply
before mutation. Quick remains local; promoting it into the normal merge workflow requires
a Standard or Strict brief and its review and evidence.

Decision remains a Product Analysis document type; approved implementation work then takes
the applicable assurance profile. Emergency restoration may proceed as a hotfix, followed
by a retrospective Feature/Security document and the applicable evidence and review.

An independently-shippable step is the **tracking** unit — one issue, one logical commit,
closed by the reviewer under Strict, or the closer under Standard. The **shipping** unit is coarser: a whole
Feature/Security pass ships as **one branch and one PR**, so a reviewer sees the complete
arc of the pass instead of fragments merged out of order. "Independently shippable" still
means each step must stand alone as a coherent, working commit — if two proposed steps can't
be reviewed and merged in that order within the pass, they are one step.

---

Review evidence is accepted only from logins in the review policy. Comments
from authors outside all configured roles are ignored before parsing; executor
handoffs require an executor login and verdicts require a reviewer login.


## 3. Document types

Four types live under `docs/`. Pick the template that matches the work.

| Type | Template | Purpose | Implementation brief? |
|------|----------|---------|-----------------------|
| **Security** | `templates/security-review.md` | A security review or hardening pass. Severity-graded findings with `file:line` and a concrete fix. | **Yes — inlined.** Closes to `docs/done/security/`. |
| **Feature** | `templates/feature-analysis.md` | Designing a feature or change. Goal, current state, approach, what-not-to-build. | **Yes — inlined.** Closes to `docs/done/`. |
| **Product Analysis** | `templates/product-analysis.md` | Exploratory architecture / product / monetization analysis. Options, trade-offs, a recommendation. A **decision record**. | **No.** If it greenlights work, spin off a Feature (or Security) doc for that. |
| **Review** | `templates/review.md` | Post-execution architectural or hand-written review with findings, evidence, and a verdict. | **No.** Required fixes follow the applicable assurance profile; a Quick local fix must promote to Standard before the normal merge workflow, or use a new approved brief when required. |

**The implementation brief is inlined** in Security and Feature docs as a dedicated
section — it is the brief an implementing agent reads to execute precisely. It contains
the *approach and insights*, ordered steps, definition of done, and verification
commands — **not the actual code**. Keep design rationale in the analysis sections above
it; keep the *how* in the brief.

---

## 4. Document lifecycle

```
docs/
├── README.md            ← index + naming conventions (keep current)
├── accepted_risks.md    ← living register of reviewed-and-accepted risks / declined features
├── backlog/             ← identified but not started (ideas, queued analyses)
├── inprogress/          ← active: being written, executed, or reviewed
├── done/                ← completed Feature / Product analyses
│   └── security/        ← completed Security reviews
└── templates/           ← the forms in this repo; copy out, don't edit in place
```

- A doc starts in `backlog/` (or straight into `inprogress/` if work begins immediately).
- To begin Feature or Security work, run `agentic-flow start <plan-id>` with `--type security`
  for Security work. It creates the branch from the selected base (`main` by default), a linked
  worktree, and a prefilled draft under `inprogress/`. It stages the draft and docs index.
- Draft and commit the plan in that worktree. Record the human's approval of the plan commit,
  issue the approved steps, and edit the plan's roadmap pointers on the same branch. Merge
  base-branch updates into the plan branch and preserve its history. Run plan commands from
  that worktree, including `agentic-flow run` with a clean checkout.
- The doc stays in `inprogress/` through plan → execute → review. Close-out prepares the move
  to `done/` before the first push (§6). If the user accepts the risk or declines the feature,
  record the decision in `accepted_risks.md`, link it, and move the doc to the applicable done stage.

### Naming convention
- `security-<topic>.md`, `feature-<topic>.md`, `product-<topic>.md`,
  `review-<topic>.md` — kebab-case topic.
- Avoid dates and model names in filenames; put those in the TRIAGE header instead.
- One topic per file. Don't accumulate unrelated findings in one doc.

### TRIAGE header
Every doc opens with a one-glance triage block so an agent (or you, months later) knows
what it is and whether it's live, without reading the whole thing:

```md
<!-- TRIAGE (first pass · YYYY-MM-DD) -->
> **Type:** Security | Feature | Product Analysis · **Status:** 🟦 Proposal | 🚧 In progress | ✅ Done | 🕰️ Superseded
> One or two lines: what this is, what's current vs historical, what (if anything) to do next.
```

### Findings / step tracker
Every Security and Feature doc carries a checklist near the top — it is the burndown the
executor ticks as commits land:

```md
## Tracker
- [x] SEC-1 Backup restore destroys QA data — fixed in <sha> (#70)
- [ ] SEC-2 KDM expiry only checks start — open (#72)
```

---

## 5. Severity legend

<!-- BEGIN SHARED REVIEW CONTRACT -->
Use one finding scale for Security reviews, step reviews, and ordinary diffs:

- **High** (`sev:high`) — common path is incorrect or a serious regression has no safe workaround. Blocks merge.
- **Medium** (`sev:med`) — real defect under a bounded condition, or required failure-path coverage is missing. Requires a fix or explicit accepted-risk disposition.
- **Low** (`sev:low`) — concrete, limited correctness or operability risk worth fixing before closure. Does not block.
- **Nit** (`sev:nit`) — wording, clarity, or tiny hygiene issue. Does not block.

Accepted/by-design is a disposition. Record acceptance and move material risk to `docs/accepted_risks.md`.

Verdicts: `approved` when no required findings remain and evidence covers the brief; `changes requested` when fixes are needed; `pending` when missing scope or evidence prevents a decision. Structured review comments encode `changes requested` as `status=changes-requested`.

Controller reviewers return the station result JSON and never call `handoff`; the controller
verifies and journals the verdict. Interactively, use `packet <issue> --station reviewer`,
`verify-step <head> --doc <doc> --step <id>`,
and `handoff <issue> approve --as reviewer --head <sha40> --body-file <review-file>`
or `handoff <issue> bounce --as reviewer --body-file <findings-file>`; states live
in `METHODOLOGY.md` §6. Pending leaves state unchanged. Never edit accepted verdicts.

Reuse evidence only when `sha` and `tree` match the reviewed head and
`verifier.implementation_sha256` matches the current verifier digest (`verify-step.sh` plus `verify-record.sh`); otherwise regenerate.
Inspect signature-source provenance and red-first output. Exit 0 is green; nonzero
with an assertion-signature match is red, except timeout 124 and interrupts 130/143,
which are invalid. Missing or mismatched signatures are invalid and prevent approval.
Prefer raw runners: make masks recipe failures as exit 2; Cargo assertions exit 101.

Handoff writes `agentic-flow-review: status=approved|changes-requested; step=<id>;
head=<sha40>; role=reviewer` compatibility markers. The journal selects accepted evidence;
edited accepted approval blocks verification. The API author proves the account;
`role=reviewer` attests the role, not independence in single-operator mode.
Final-head approval belongs on the document's Tracking issue (§2):
`agentic-flow-review: status=approved; pr=<number>; head=<sha40>;
run=https://github.com/<owner>/<repo>/actions/runs/<id>; attempt=<positive-integer>;
role=reviewer`. A new head or run attempt requires new approval.
<!-- END SHARED REVIEW CONTRACT -->

Each finding states **location** (`file:line`), **what's wrong**, and a concrete **Fix:**.

---

## 6. Plan → GitHub issues

A markdown tracker is versioned and offline; GitHub issues give a live progress bar,
issue state, and PR linkage. They're complementary — **doc = design intent,
issues = execution units**.

Use the `plan-to-issues` skill (`.claude/skills/plan-to-issues/`) in the plan worktree once
the plan is **approved**. Standard creates one work issue from its one-step brief. Strict creates
one tracker plus one sub-issue per independently shippable step. Existing specs without
a profile keep the legacy tracker and steps.

<!-- BEGIN SHARED WORKFLOW -->
Generated from `config/workflow.tsv`; edit the data, then run `scripts/render-shared.sh`.

| Topology | State | Labels | Issue status |
|---|---|---|---|
| step-strict | executing | agent:codex,needs-execution | open |
| step-strict | reviewing | agent:opencode,needs-review | open |
| step-strict | escalated | needs-human | open |
| step-strict | approved | - | closed |
| work-standard | executing | agent:codex,needs-execution | open |
| work-standard | reviewing | agent:opencode,needs-review | open |
| work-standard | escalated | needs-human | open |
| work-standard | closing | agent:claude,needs-closing | open |
| work-standard | closed | - | closed |
| tracker | open | plan | open |
| tracker | closing | plan,agent:claude,needs-closing | open |
| tracker | closed | plan | closed |

| Topology | Event | Role | From | To | Requires |
|---|---|---|---|---|---|
| step-strict | submit | executor | executing | reviewing | head,head≠last-bounced-head |
| step-strict | bounce | reviewer | reviewing | executing | findings,bounces<2 |
| step-strict | bounce | reviewer | reviewing | escalated | findings,bounces=2 |
| step-strict | ask | executor | executing | escalated | question |
| step-strict | ask | reviewer | reviewing | escalated | question |
| step-strict | resume | approver | escalated | executing | note,return=executing |
| step-strict | resume | approver | escalated | reviewing | note,return=reviewing |
| step-strict | approve | reviewer | reviewing | approved | head=submitted |
| work-standard | submit | executor | executing | reviewing | head,head≠last-bounced-head |
| work-standard | bounce | reviewer | reviewing | executing | findings,bounces<2 |
| work-standard | bounce | reviewer | reviewing | escalated | findings,bounces=2 |
| work-standard | ask | executor | executing | escalated | question |
| work-standard | ask | reviewer | reviewing | escalated | question |
| work-standard | resume | approver | escalated | executing | note,return=executing |
| work-standard | resume | approver | escalated | reviewing | note,return=reviewing |
| work-standard | approve | reviewer | reviewing | closing | head=submitted |
| work-standard | close | approver | closing | closed | lifecycle-ready |
| tracker | notify | reviewer | open | closing | all-steps-approved |
| tracker | close | approver | closing | closed | lifecycle-ready |
<!-- END SHARED WORKFLOW -->

`handoff` replays the journal; labels and issue status are projections, never evidence.
The create-tags command provisions workflow labels at adoption. Plan reapply preserves
live state. Resume requires an approver's note after escalation.

Rules:
- One issue per independently-shippable step — not one giant issue, not one per commit.
- Issues are the tracking granularity, not the shipping granularity. A step issue is closed
  by the **reviewer**, on an approving verdict, before the PR merges; its commit still
  carries `Fixes #N` for traceability, but the merge no longer does the closing. The whole
  plan ships as **one branch and one PR** — a Feature/Security pass is the review unit, not
  each step. Split a pass across multiple PRs only when the brief says so explicitly (e.g. a
  pass too large or long-running to hold on one branch); don't default to a branch per step.
- **Every handoff carries its evidence in a journal comment.** The controller writes it
  for its stations. Interactively, run `agentic-flow handoff`
  with `submit --as executor --head <sha40>`, `approve --as reviewer --head <sha40>`, or
  `bounce --as reviewer`, and `--body-file <evidence-file>`. Retry the same request after
  failure. Use `reconcile` to repair projections and pending tracker notifications.
  The journal decides state; labels and issue open/closed state are projections.
- Profiled specs supply `packet.brief`, `packet.definition_of_done`,
  `packet.verification`, and `packet.risks` for each step. These come from the approved
  brief and render into the issue's executor packet. The driver rejects packets over
  800 words; it never truncates acceptance criteria.
- Issue body = the step link, concise Definition of Done, and current labels. The approved
  brief owns intent; the `Makefile` owns executable command behavior, so do not copy Make
  recipes into issue bodies.
- Flow is one-directional. If the plan changes, regenerate or hand-edit issues; never
  reverse-sync issue edits into the doc.

### Close-out and shipping

1. After all steps are approved, use `agentic-flow close-out prep <doc>` in the plan worktree
   and commit the staged doc move and index. Prep writes `Implementation PR: source=final-approval`
   so the PR can be resolved from the reviewer's final approval after it exists. On a clean
   worktree with no PR, `ship` can prepare and commit this change using `AGENTIC_CLOSER_COMMIT`
   (defaults to `git-claude` when installed). If no closer command is available, `ship` stages
   the close-out and stops before pushing so the closer can commit it.
2. The human runs `agentic-flow ship <doc> --wait-review`. It runs `make ship-gate` when
   available, pushes the prepared head once, opens the PR, and waits for CI and final review.
   On a re-run, it reuses a green gate record for the same tree, gate inputs, and harness
   version. `--force-gate` clears the matching record and reruns the gate. It skips the push
   when it can confirm that the branch at the configured push destination already has the
   exact head. A review bounce that changes the head requires another push and fresh evidence.
3. After CI succeeds, the reviewer records final approval for that PR, head, run, and attempt
   with `agentic-flow final-approve <moved-doc>`. `ship` finishes close-out, closes the tracker
   or Standard work issue, and checks pre-merge readiness. The human merges and runs
   `agentic-flow clean <plan-id>`. Cleanup requires the plan tip to be an ancestor of the base.

Plans with an open PR from the previous two-push workflow finish on that path. `ship` prepares
the in-progress doc with `close-out prep <doc> --pr <url>`. The closer commits it and the human
runs `ship` again to push and verify the final head. Existing `Implementation PR: url=…`
documents continue to verify.

---

## 7. Commit contract

Review fixes land as new commits; never amend a commit after its review handoff.

Identity is enforced by wrapper scripts, each with its own SSH signing key:

- **Claude commits with `git-claude`.**
- **Codex commits with `git-codex`.**

Rules (both agents):
- **Stage specific files by name** — never `git add -A` / `git add .`.
- **One logical commit per step.** Don't bundle multiple steps; don't split one step across
  commits without reason.
- **Verbose, *why*-first commit bodies** — name the risk/bug, the approach, the blast
  radius. A reviewer months later should understand the change from the message alone.
- **Reference the issue** — keep `Fixes #N` in the PR or commit for traceability.
  The reviewer closes Strict steps; the closer closes Standard work issues and trackers.
  Use `close-out finish` (§6) to close and reconcile workflow labels.
- **Never push.** The human controls all pushes and merges.
- The `Co-Authored-By:` trailer is **appended by the wrapper** when the message lacks one —
  don't hand-maintain it (model names in prose go stale); a trailer you write is kept as-is.

Example body:

```
Bind session and exchange JWTs to the tenant schema

Signed payloads omitted any tenant identifier, so with a shared secret a
cookie from tenant A verified at tenant B. Add `schema` to every signed
payload and reject mismatches in requireAuth. Legacy missing-claim cookies
are treated as the default tenant for one release to ease rollout.

Fixes #73
```

(The wrapper appends `Co-Authored-By: Claude <noreply@anthropic.com>` on commit.)

---

## 8. Enforcement & harness capabilities

### Shipped guardrails

- **Native command policy.** `config/command-policy.tsv` generates deny rules for Claude
  Code, Codex, and OpenCode. These reserve push and merge for the human, enforce named
  staging, and route workflow writes through the lifecycle commands. The controller loads
  the station rules. Codex also uses `scripts/hooks/guard-attached-git-dir.sh` for the
  attached Git-directory option. Install the Codex rules for interactive sessions.
  [Adoption and verification](ADOPTION.md#verify)
- **Git pre-commit secret scan.** Set `core.hooksPath` to `scripts/git-hooks`, or chain
  `scripts/git-hooks/pre-commit` from your existing pre-commit hook and propagate its exit
  status. This scans staged content in human, agent, and scripted commits. The scan requires
  both `gitleaks` and the local high-signal pattern set. Use `AGENTIC_ALLOW_SECRET=1` on the
  commit to override a false positive. See the
  [scanner layering rule](docs/reference/engineering-standards.md#111-automate-what-a-human-should-never-review).
- **Stop / SubagentStop → `make check`** (`scripts/hooks/check-gate.sh`): blocks a turn from
  ending while the fast gate is red, feeding the failure back to the agent; if the retry is
  still red it warns and allows rather than looping forever. Only an exact green state
  stamp silently skips the gate; clean committed work is checked too. A change during a
  green run triggers one rerun; a red rerun or further change blocks. Stacks whose check
  takes over half the hook timeout must raise that timeout to accommodate both runs.
  Scoped to the *fast* gate, not the full suite. `check` ships prefilled with harness sanity
  checks; extend it with the stack's type-check + lint.
- **SessionStart** (`scripts/hooks/session-context.sh`) gives Claude and Codex cached step
  context when available. Review and trust Codex's project hooks with `/hooks` after adoption
  or a hook change.
- **`scripts/docs-index.sh`** keeps `docs/README.md`'s index derived from each doc's TRIAGE
  header (run it, or `--check` in CI) so the index can't go stale by hand.
- **`scripts/check-payload-manifest.sh`** fails when an agent adapter, harness template, or
  stack profile exists outside the canonical payload manifest.
- **`scripts/lifecycle-status.sh`** derives whether active trackers are still active, ready
  to close, or blocked on approval, tracking, CI evidence, or review. `--check` makes missing
  closure evidence fatal without moving files automatically.
- **`scripts/init.sh`** is the adoption path: export the scaffold, fill machine tokens,
  apply a data-driven generic/Node/Python/Go/Rust stack profile plus opt-out flags, stamp
  the source version, and print the doctor report. Detection proposes; explicit flags win.
- **`scripts/doctor.sh`** is the adoption checklist for a copied scaffold: required files,
  agent-adapter hook wiring, required tools, stack/version state, unresolved update
  candidates, real Make targets, CI posture, and docs-index freshness.
- **`scripts/check-action-pins.sh`** keeps GitHub Actions pinned to immutable SHAs with a
  readable version comment (fatal), and nags when the pins haven't been re-verified in
  months (`--strict` to enforce, `--online` to check against GitHub). See the [CI/CD reference](docs/reference/ci-cd.md).
- **`scripts/self-test.sh`** exercises the scaffold's offline invariants, especially export
  behavior and hook behavior.

### Optional capabilities
These make the handoff explicit and parallel instead of sequential:

- **Plan mode** (`EnterPlanMode` / `ExitPlanMode`) — design and get approval *before* any
  file changes. Matches "Claude designs, then hands off."
- **`Explore` / `Plan` subagents** — fan-out research before writing a plan.
- **Worktrees** (`isolation: "worktree"`) — run execution and review on isolated worktrees
  of the same branch so review can start while execution continues. Fanning out at all is
  optional; **isolation stops being optional once two agents edit at the same time.**
  Subagents without it share the parent's working directory, so one can stage or overwrite
  another's half-finished edit, and a green `make check` covers whatever mixture of both
  changes was on disk at the time. The Stop gate does not save you: its state stamp lives in
  the shared git-dir and covers HEAD’s tree plus staged, unstaged and untracked content.
  It is written atomically only when the state is unchanged across a green run. A separate
  acknowledged-red record repeats the loop-safety warning for that exact state and never
  counts as green. Unwritable records disable reuse. Even a stable mixture certifies neither
  individual change. A read-only fan-out (`Explore` / `Plan`) needs no isolation.
- **`/code-review`** (`low|medium|high|max`, and **`ultra`** for a deep multi-agent cloud
  review of a whole branch) — a whole-branch or second-opinion pass, **not** a substitute for
  §1's independent per-step review, and the reviewer's role if a project opts out of OpenCode.
  Keep hand-written review docs for architecture-level passes.
- **Multi-reviewer ensemble** — N reviewers over the *same* diff, when independence *between
  reviewers* is worth paying for: an architecture-level pass, a security-critical change, or
  a branch already shipping. Never a default, never a substitute for §1's per-step review.
  Severity and verdict vocabulary come from §5 unchanged — an ensemble adds reviewers, not a
  scale. Each verdict names its own reviewer, for [close-out](#close-out-and-shipping).
  **Aggregation is not a vote.** One named arbiter re-checks every `high` finding, and every
  finding the reviewers disagree on, against the source before it counts; disagreement is
  settled by that check, and unresolved disagreement is reported as unresolved rather than
  averaged away. Two things an ensemble does not fix: reviewers drawn from similar models
  share blind spots, so a plausible-but-false premise can be held unanimously and survive a
  vote; and agreement is not verification, so N-of-N convergence still needs the arbiter's
  source-check. If you will not fund that check, run one reviewer and spend the rest on tests.
- **`/security-review`** — a security pass on the pending branch diff; complements a
  Security doc.
- **`/verify` and `/run`** — drive the app to confirm a fix behaves, not just that tests pass.
- **Project hooks** can remind agents about shared-type edits or enforce commit message format.
- **Memory** — persist durable decisions (this methodology, the commit contract, recurring
  review themes) so each session doesn't re-derive them.

---

## 9. Starting a project — assess the stack first

See [Starting a project — assess the stack first](docs/reference/stack-assessment.md).

## 10. CI/CD pipeline shape

See [CI/CD pipeline shape](docs/reference/ci-cd.md).

## 11. Engineering standards

See [Engineering standards](docs/reference/engineering-standards.md).
