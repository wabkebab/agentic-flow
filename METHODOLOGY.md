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
> **Standard version:** [`VERSION`](VERSION) — a human-facing semver, bumped deliberately
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
  Review / Plan (Claude)
        │  produces
        ▼
  docs/inprogress/<doc>.md         Security | Feature | Product Analysis
        │   (Security & Feature docs carry an inlined Implementation Brief —
        │    the execution insights for the implementer, NOT the code)
        │
        │  human approves
        ▼
  plan-to-issues  ───────────────▶  Standard: one work issue
                                   Strict: tracker + sub-issues
        │
        ▼
  Execute (Codex)                   one branch + PR per pass; one commit + "Fixes #N"
        │                            per step; git-codex; runs handoff submit with sha
        │                            and verification on the step issue, projecting it
        │                            with handoff (see §6)
        ▼
  Review (OpenCode)                 reads the commented commit against the brief
        │                           ├─ findings ─▶ handoff bounce (§6)
        │                           └─ approved ─▶ Strict: closes the sub-issue;
        ▼                                          Standard: routes to close-out (§6)
  Close-out (Claude)                tick the Tracker, update Status, verify evidence,
        │                           move the doc, then close the named issue
        ▼
  Merge (human)  ────────────────▶  the PR. Reviewed issues are already closed;
        │                           "Fixes #N" stays for traceability.
        ▼
  doc done  ─────────────────────▶  move to docs/done/ (or docs/done/security/),
                                    update the Status section; accepted-but-not-built
                                    risks/features recorded in docs/accepted_risks.md
```

Use the station commands in §6 for every role handoff.

**A closed Strict sub-issue means "reviewed clean", not "shipped."** The reviewer closes it before
the PR merges, so GitHub issue state is deliberately *not* the shipping signal. What shipped
is recorded in the implementation doc's Status block and enforced by
`scripts/lifecycle-status.sh --doc <moved-document> --phase close-out --check --verify-evidence`
against a CI run (§10). The Strict tracker or Standard work issue stays open through
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

Approvals bind to commits: rebasing or amending a reviewed branch requires re-review.
Every approved step commit must be an ancestor of the PR head. Missing objects or
shallow history leave ancestry UNVERIFIED until the operator fetches the history.

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
fall back to ambient credentials. This pass retains single-operator mode;
changing the policy to distinct-account is a separate adoption decision.

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
merge. Every profile keeps the same engineering standards, secret and push hooks, CI
authority, and human ownership of pushing and merging. Review identity guarantees still
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
- It lives in `inprogress/` through plan → execute → review.
- It moves to `done/` (or `done/security/`) when **either**: the implementation brief's
  steps are all shipped and verified, **or** the user has accepted the risk / declined the
  feature (record that decision in `accepted_risks.md` and link it).

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

Accepted/by-design is a disposition, not a severity. Record the acceptance against the finding and move material accepted risk to `docs/accepted_risks.md`.

The only verdicts are `approved`, `changes requested`, and `pending`. Use `approved` when no required findings remain and evidence covers the brief; use `changes requested` when code or tests need a fix; use `pending` when missing scope or evidence prevents a decision. Structured review comments encode `changes requested` as `status=changes-requested`.

Use `packet <issue> --station reviewer`, `verify-step <head> --doc <doc> --step <id>`,
and `handoff <issue> approve --as reviewer --head <sha40> --body-file <review-file>`
or `handoff <issue> bounce --as reviewer --body-file <findings-file>`; states live
in `METHODOLOGY.md` §6. Pending leaves state unchanged. Never edit accepted verdicts.

Reuse evidence only when `sha` and `tree` match the reviewed head and
`verifier.implementation_sha256` matches the current `verify-step.sh`; otherwise regenerate.
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

Use the `plan-to-issues` skill (`.claude/skills/plan-to-issues/`) once a plan is
**approved**. Standard creates one work issue from its one-step brief. Strict creates
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
| step-strict | resume | approver | escalated | executing | note |
| step-strict | approve | reviewer | reviewing | approved | head=submitted |
| work-standard | submit | executor | executing | reviewing | head,head≠last-bounced-head |
| work-standard | bounce | reviewer | reviewing | executing | findings,bounces<2 |
| work-standard | bounce | reviewer | reviewing | escalated | findings,bounces=2 |
| work-standard | resume | approver | escalated | executing | note |
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
- **Every handoff carries its evidence in a journal comment.** Run `agentic-flow handoff`
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

### Shipped guardrails (in the scaffold, enforced — not convention)
`.claude/settings.json` wires hooks that mechanize the contract so it can't be quietly missed:
- **Stop / SubagentStop → `make check`** (`scripts/hooks/check-gate.sh`): blocks a turn from
  ending while the fast gate is red, feeding the failure back to the agent; if the retry is
  still red it warns and allows rather than looping forever. Only an exact green state
  stamp silently skips the gate; clean committed work is checked too. A change during a
  green run triggers one rerun; a red rerun or further change blocks. Stacks whose check
  takes over half the hook timeout must raise that timeout to accommodate both runs.
  Scoped to the *fast* gate, not the full suite. `check` ships prefilled with harness sanity
  checks; extend it with the stack's type-check + lint.
- **PreToolUse(Bash) → block `git add -A` / `git add .` / `--all`**
  (`scripts/hooks/block-git-add-all.sh`): enforces §7's "stage files by name" mechanically.
- **PreToolUse(Bash) → block `git push` / `gh pr merge`** (`scripts/hooks/block-push.sh`):
  enforces §7's "never push — the human controls all pushes and merges" mechanically.
- **PreToolUse(Bash) → scan staged content for credentials** (`scripts/hooks/scan-secrets.sh`):
  enforces §11.1's "secret scanning at the commit boundary". Blocks a commit whose staged
  diff carries a credential shape, because CI catches that one step too late — a committed
  secret has to be rotated. Runs `gitleaks` (required) **and** a local high-signal pattern
  set, always both — see §11.1 on why the second layer is not a fallback.
  `AGENTIC_ALLOW_SECRET=1` overrides a false positive, visibly.
- **PreToolUse(Bash) → route workflow writes through `handoff`**
  (`scripts/hooks/require-step-comment.sh`): blocks raw workflow label mutations,
  closing/reopening plan-stamped issues, and direct role-token calls. Claude and Codex
  use the shared lexer; OpenCode follows its reviewer contract without a hook engine.
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
  months (`--strict` to enforce, `--online` to check against GitHub). See §10.
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
  scale. Each verdict names its own reviewer, as §10's close-out check already requires.
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
- **More hooks** — beyond the six shipped hooks: a PostToolUse reminder on shared-type edits,
  a commit-message-format check, etc.
- **Memory** — persist durable decisions (this methodology, the commit contract, recurring
  review themes) so each session doesn't re-derive them.

---

## 9. Starting a project — assess the stack first

Before the first line of code on a new project (and when adopting the scaffold into a young
one), **establish what the current stack actually is, then install a modern version of it.**
An agent's default is training-data recall, which skews stale by months to years — it will
happily scaffold last year's major version and pin it.

1. **Assess what's there.** For an existing project: read the manifests and lockfiles
   (`package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod`, …) and the installed toolchain
   versions (`node -v`, `python -V`, `cargo -V`, …). Note anything already end-of-life.
2. **Check what's current.** Look up current stable releases from release notes / changelogs
   / official docs — not from memory. Note the LTS line where one exists.
3. **Choose deliberately.** Default to the current stable (or current LTS for runtimes).
   Deviate only for a stated reason — a peer dependency's ceiling, a platform constraint, a
   known-bad release — and write that reason down in `CLAUDE.md` → Gotchas.
4. **Pin it where it executes.** Versions live in the manifests, lockfiles, and `Makefile` —
   the places that run. Prose in `CLAUDE.md` explains; it doesn't pin.
5. **Verify green before building on it.** `make check && make test` on the fresh stack, so a
   later failure is attributable to your code and not the scaffold.

The same discipline applies mid-project when adding a dependency: check the current version
rather than typing the one you remember.

---

## 10. CI/CD pipeline shape

The reference structure, extracted from a working two-workflow setup. Stack-agnostic: the
*shape* is the standard, the commands inside it come from the `Makefile`.

> **Working templates ship in [`templates/ci/`](templates/ci/README.md)** — `ci.yml`,
> `deploy.yml`, and `release-native.yml`, exported **inert** so adoption never activates a
> workflow (least of all a deploy, or a release with `contents: write`) behind you. Copy
> into `.github/workflows/` and fill the `<ANGLE-BRACKET>` spots. This section is the *why*;
> those files are the *what*.

**Three workflows, three different risk postures.**

| | `ci.yml` | `deploy.yml` | `release-native.yml` |
|---|---|---|---|
| Trigger | `pull_request` | `push` to release branches + `workflow_dispatch` | push of a `v*` tag + `workflow_dispatch` |
| Concurrency group | per PR number | per ref name | none — parallel releases of different tags are fine |
| `cancel-in-progress` | **`true`** — superseded runs are waste | **`false`** — finishing a deploy beats half-deploying | n/a |
| Permissions | `contents: read` (+ `pull-requests: read` for path filtering) | `contents: read` + only the write scope the registry push needs | `contents: write` — creating the release and uploading assets needs it |

`release-native.yml` only fits a stack that compiles to a standalone native binary (Go,
Rust, a bundled Node CLI, …); a service deployed via `deploy.yml` has nothing to attach
there and should not ship both.

### Rules that apply to both

- **Pin everything.** Third-party actions by **full commit SHA** with a `# vX.Y.Z` trailing
  comment; runners by version (`ubuntu-24.04`, never `ubuntu-latest`). A tag is mutable —
  a SHA is the only pin that resists a compromised action.
- **Enforce the pins with `scripts/check-action-pins.sh`.** Pins rot two ways and the check
  grades them differently. *Structure* — a tag pin, or a SHA with no version comment — is
  always fatal; it runs in `make check`. *Staleness* is only a warning there, because pins
  decay with the calendar rather than with edits, and failing the fast gate on a date would
  turn a repo red with no change to it (and, via the Stop hook, block agents from ending
  turns). Enforcement lives in a scheduled `--strict` run instead. `--online` resolves each
  pin against GitHub to prove it really is the version its comment claims and to report
  newer releases; `--stamp` records the re-verification date.
- **Least-privilege `permissions:` declared explicitly** at workflow level. Add a scope only
  where a step actually needs it, and comment *why* (e.g. path-filter actions call the Pulls
  API and fail with "Resource not accessible by integration" without `pull-requests: read`).
- **Steps stay thin — call `make` targets.** The Makefile is the one executable source of
  truth (§ top-matter); a CI step that inlines its own command sequence is a second source
  that will drift from what runs locally. Keep the YAML to checkout/setup/`make …`.
- **The workflow file is its own trigger.** Include `.github/workflows/<file>.yml` in every
  path filter, so editing CI re-runs everything it gates.
- **Ship the runbook with the workflow.** A trailing comment block listing one-time server
  setup and every required repository secret — the operational knowledge dies otherwise.

### `ci.yml` — job structure

```
changes ──┬─▶ app checks        (if changes.app)
          ├─▶ compose syntax    (if changes.docker)
          └─▶ <area N>          (if changes.<area>)
secrets-scan  (never filtered — always runs)
                    │
                    ▼
              ci-gate           needs: [everything], if: always()
```

1. **`changes`** — a path-filter job whose outputs gate the rest, so a docs-only PR doesn't
   pay for a full build. One filter per independently-testable area.
2. **Per-area jobs**, each `if: needs.changes.outputs.<area> == 'true'`.
3. **`secrets-scan`** — scans the PR diff range (`base…head`) for **verified** leaked
   secrets. Never path-filtered: a leak can land in any file.
4. **The app job runs cheapest-first, fail-fast:** checkout → set up runtime *with dependency
   caching* → **install from the lockfile** (`npm ci`, `poetry install --sync`, …, never a
   resolving install) → audit production dependencies at a severity threshold → typecheck →
   lint → test → build. Give the build dummy CI env values so it never needs real secrets.
5. **`ci-gate`** — the single **required status check** in branch protection:

   ```yaml
   ci-gate:
     needs: [changes, secrets-scan, app, compose-syntax]
     if: always()
     steps:
       - run: |
           for result in "${{ needs.secrets-scan.result }}" "${{ needs.app.result }}" …; do
             case "$result" in
               success|skipped) ;;
               *) echo "Upstream job ended in '$result'"; exit 1 ;;
             esac
           done
   ```

   **This job exists because path filtering and required checks conflict.** A skipped job
   never reports, so naming the per-area jobs directly as required checks would block every
   PR that legitimately skips one. The gate collapses them into one always-reporting status
   that treats `skipped` as pass and `cancelled`/`failure` as fail.

### `deploy.yml` — job structure

1. **Build & push an image**, tagged twice: a moving `latest` pointer *and* an immutable
   per-commit tag for rollback. Use registry/GHA layer caching.
2. **Deploy pulls by digest**, not by tag — the tag can be re-pointed between push and pull;
   the digest is what was actually built and tested.
3. **SSH properly:** an ssh-agent action for the key, and `known_hosts` populated from an
   `ssh-keyscan` output stored as a secret. Never `StrictHostKeyChecking=no`.
4. **Sync deploy assets through an explicit allowlist** (rsync `--include … --exclude='*'`).
   Operator-maintained state on the server — the runtime `.env`, TLS certs — must never be
   in the sync set.
5. **Wait for readiness, then verify from outside:** `up -d --wait --wait-timeout N`, then an
   external healthcheck against the public URL with bounded retries and backoff. Skip
   gracefully (don't fail) when the URL secret isn't configured.
6. **Gate optional stacks** (monitoring, workers) on their own path filter *or* a
   `workflow_dispatch` input, so routine app deploys don't restart them.

### `release-native.yml` — job structure

```
create-release ──┬─▶ build-linux    (matrix: target triples)
                  ├─▶ build-macos    (matrix: target triples)
                  └─▶ build-windows
```

1. **`create-release`** resolves the tag once — from the pushed ref, or from a
   `workflow_dispatch` input so a failed platform can be re-run without re-tagging — and
   creates the (draft-free) GitHub release every build job then uploads to. A hyphen in the
   tag (`v1.2.3-rc1`) marks it prerelease automatically via SemVer's own convention, so
   there is nothing separate to keep in sync.
2. **One job per OS**, matrixed over target triples within a job where cross-compilation
   supports it (e.g. Rust). Packaging genuinely differs per OS — archive format, binary
   extension, shell — which is why these are three explicit jobs, not one OS-matrixed job
   branching three ways internally.
3. **Each platform job**: checkout → native build (stack-specific, the fill-in block) →
   smoke-test the binary exists and is executable → package into an archive → upload it to
   the release created in step 1.
4. **No `ci-gate`-style aggregation job.** Unlike `ci.yml`, nothing here is a required
   status check gating a merge — a failed platform build fails its own job, visibly, and
   can be re-run individually via `workflow_dispatch` without re-running the others.

### Wiring it to the harness

CI green must mean the same thing as local green: the CI gate is `make check && make test`
(§ Stack profile in `CLAUDE.md`), plus `scripts/docs-index.sh --check` where practical. If a
CI step needs a command that isn't a Make target, that's a signal the Makefile is incomplete
— add the target and call it, rather than growing logic in YAML.

---

## 11. Engineering standards

The practices that make review cheap and bugs rare. §1–§10 cover *process*; this covers the
work itself. Ordered by when it applies, not by importance.

### 11.1 Automate what a human should never review

Anything a machine can catch must not cost review attention. In value-per-effort order:

1. **Linter + formatter, failing the build.** Ends style argument permanently and catches a
   real bug class — unused variables, shadowing, unreachable code. Formatting is not a
   review topic.
2. **Static analysis / type checking, strict mode on.** The single highest-yield item if the
   language has it. Strict from day one; retrofitting strictness onto a grown codebase is a
   project, not a setting.
3. **Dependency scanning, blocking on high severity.** `npm audit`, `pip-audit`,
   `cargo audit`, Dependabot — whatever fits. In CI (§10 shows the step), not on a human's
   memory.
4. **Secret scanning at the commit boundary.** The scaffold ships this as a hook
   (`scripts/hooks/scan-secrets.sh`) rather than CI-only, because *CI is one step too late*:
   a secret that reaches a commit must be rotated, and rewriting history does not un-leak
   it. The hook fails at the last moment the fix is still free.

   **Layer scanners; never let one substitute for another.** The hook runs `gitleaks` *and*
   a local pattern set, always both. Treating the local set as a fallback made the hook
   weaker on machines that had gitleaks, whose default config allowlists documented sample
   credentials — a staged AWS example key came back clean and nothing else ran. Any gate
   whose strength depends on which tools happen to be installed will eventually be green for
   the wrong reason: see also `make test` silently skipping `shellcheck`.

> **The ratchet:** when a reviewer catches the same *class* of issue twice, it stops being a
> review comment and becomes a lint rule, a type, or a test. A review that repeats itself is
> a missing automation.

Wire each of these into `make check` / `make test` so local and CI enforce identically —
never into CI alone, or the feedback arrives after the context is gone.

### 11.2 Design stage — before any code

These go in the Feature/Security doc (Part A), not in the implementer's head:

- **Write the interface before the implementation.** Function signatures, endpoint
  contracts, data shapes. Most architecture problems are visible here, where they cost
  nothing to fix, and invisible once there's code to be attached to.
- **Threat-model in one paragraph.** Who are the untrusted actors, what data actually
  matters, what is the worst thing an attacker could do. Ten minutes, mandatory for anything
  touching auth, money, or user data. The Security template has a slot; the Feature template
  now does too.
- **Decide the failure behavior up front.** For each external call: what happens on timeout,
  on a malformed response, on partial success. Decided during coding, these become ad-hoc
  guesses that no one revisits.

### 11.3 Coding stage

- **Validate at the boundary, once.** All external input — HTTP, files, env, DB rows — is
  parsed into a validated type at the edge. Interior code then trusts its inputs. Defensive
  checks scattered through the interior is the anti-pattern: it never adds up to a guarantee,
  and it hides where the real contract is.
- **Never build strings that get interpreted.** Parameterized queries, argument *arrays* for
  subprocesses, no string-concatenated HTML or paths. This removes most of the injection
  category by construction rather than by vigilance.
- **Deny by default, at a chokepoint.** Authorization in middleware or a decorator, not
  per-handler. Per-handler means you will eventually miss one, and the miss is silent.
- **Secrets from config, never literals.** Including in tests. Including "temporarily" — the
  commit boundary is where temporary becomes permanent.
- **No unbounded anything.** Every query has a limit, every loop over external data has a
  cap, every outbound request has a timeout.
- **Make illegal states unrepresentable** where the language allows it. A type that cannot
  hold the bad value needs no runtime check and no test.

### 11.4 Verification

- **Test the failure path first.** Everyone tests the happy path; the bugs are in the other
  one. If a step's tests only cover success, the step is not done.
- **Every bug fix starts with a failing test that reproduces it.** This is already the
  contract for Security fixes (§3) — it applies to every fix. It prevents the regression and,
  more importantly, forces understanding the cause instead of pattern-matching a change that
  makes the symptom go away.
- **Test behavior, not implementation.** If a refactor that preserves behavior breaks the
  tests, the tests were asserting the wrong thing and are now blocking the cleanup.

### 11.5 Review

- **Small diffs.** A 200-line PR gets a real review; a 2000-line one gets a rubber stamp.
  This is the highest-leverage habit available, solo or not — it's why §7 requires one
  logical commit per step and §6 requires one issue per independently-shippable step.
- **Explain the change in writing before submitting.** Half the problems surface while
  writing the explanation. The *why*-first commit body (§7) is where this goes — it is not
  ceremony, it is the review you give yourself.
- **Use a checklist, not vibes.** Minimum viable version, applied to every change:
  1. Is all external input validated at the boundary?
  2. Are the failure paths handled — timeout, malformed, partial?
  3. Is there enough logging to debug this at 2am without a debugger?
