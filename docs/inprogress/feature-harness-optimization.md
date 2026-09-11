<!-- TRIAGE (first pass · 2026-09-11) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict. Make the harness's correctness gates prove the state they report, then
> reduce duplicated contracts, routine validation cost, and low-risk workflow ceremony. Ready for human approval;
> do not run `plan-to-issues` until approved.

# Feature — Trustworthy and proportionate harness execution

## Tracker

- [ ] F-1 Bind lifecycle closure to explicit, verified evidence — open.
- [ ] F-2 Make plan identities exact and preserve live workflow labels — open.
- [ ] F-3 Parse protected Git commands and scan the repository being committed — open.
- [ ] F-4 Remove false-green build, hook-test, and static-analysis paths — open.
- [ ] F-5 Make exported validation consume the selected adapter scope — open.
- [ ] F-6 Generate shared contracts and converge review terminology — open.
- [ ] F-7 Define assurance policy and persist the project baseline — open.
- [ ] F-8 Implement Standard issue topology and complete close-out — open.
- [ ] F-9 Measure role context and workflow costs — open.
- [ ] F-10 Reduce fast-check and fixture setup costs — open.

---

# Part A — Analysis

## Goal

The harness should spend its strongest checks and review ceremony where they buy confidence,
and every green gate should prove the claim attached to it.

This pass has two ordered goals:

1. eliminate false-green lifecycle, issue-reconciliation, hook, build, and export behavior;
2. reduce duplicated context, repeated test setup, and unnecessary workflow ceremony without
   weakening engineering standards, CI authority, or human control of push and merge.

The optimization target is the context and work actually consumed by each role. Repository-wide
word count is only a secondary proxy.

## Current state

Reviewed `main` at `87d6ae9` on 2026-09-11. The focused-test and context-routing work from
`docs/inprogress/context_optimization.md` is already present on `main`; this Feature builds on
that behavior rather than proposing it again.

### Correctness gaps

| Priority | Current behavior | Evidence and affected surface |
|---|---|---|
| High | Lifecycle fields are accepted through loose positive-word searches. Text such as “not approved” can satisfy approval or review. | `scripts/lifecycle-status.sh`, `check_field()` and the status checks near line 134. |
| High | `--check --verify-evidence` prints `UNVERIFIED` but exits zero. | `scripts/lifecycle-status.sh`, `verify_evidence()` and the final blocked counter. |
| High | A successful Actions run is trusted without proving that it belongs to this repository, the expected workflow, or the reviewed commit. | `scripts/lifecycle-status.sh`, `verify_evidence()` near line 74. |
| High | Issue lookup uses substring matching. A `step-1` lookup can select `step-10`. | `scripts/plan-to-issues.sh`, `issue_for_marker()` near line 122. |
| High | Step IDs are checked for duplicate explicit values before implicit `step-N` IDs are materialized. An implicit and explicit ID can therefore collide. | `scripts/plan-to-issues.sh`, the initial `jq` validator near line 50. |
| High | The secret hook recognizes `git -C`, but scans the hook process's current repository instead of the commit invocation's repository/index. | `scripts/hooks/scan-secrets.sh` near line 48 and its unscoped `git diff --cached`. |
| High | Push protection is a regular-expression approximation of shell syntax. Quoted `-C` paths, command terminators, and wrapper names outside its fixed list can evade it. | `scripts/hooks/block-push.sh` near line 20. |
| Medium | Reapplying a plan adds the spec's original step labels to existing issues. It can mix `agent:codex,needs-execution` back into a live reviewer state. | `scripts/plan-to-issues.sh` near line 255. |
| Medium | Claude-only export removes Codex files, while doctor and adapter-parity checks still require them. | `scripts/doctor.sh` near line 153 and `scripts/self-test.sh` near line 877. |
| Medium | Hook regression helpers accept every nonzero status as “blocked,” so a crash passes. | `scripts/self-test.sh`, `must_block()` near line 183. |
| Medium | `make build` runs several commands in one recipe without fail-fast shell behavior; the final successful `echo` can mask export failure. | `Makefile` near line 28. |
| Medium | `scripts/agentic-flow` is shipped and executable but omitted from Bash syntax and ShellCheck coverage because the globs select only `*.sh`. | `Makefile` `check` and `test` targets. |
| Medium | Reviewer red-first guidance can ask a read-only reviewer to revert and restore the live checkout, risking interference with concurrent work. | Review skill regression-verification guidance. |

The baseline `make check`, `make test`, and `make build` passed alongside reproduced defects.
The problem is therefore what the gates prove, not the number of gates.

### Duplication and inactive semantics

- The Claude and Codex copies of `plan-to-issues`, and the agent/OpenCode copies of
  `review-execution`, are byte-identical or intended to be. Parity checks detect drift only after
  maintainers edit multiple copies; they do not establish a single source.
- `.opencode/command/review.md`, `.opencode/agent/code-reviewer.md`, and the review skill use
  conflicting severity and verdict vocabularies.
- Root and exported `CLAUDE.md` / `AGENTS.md` pairs intentionally differ, but
  `scripts/check-harness-sync.sh` compares only their `##` headings. Contradictory content under
  matching headings remains invisible.
- `config/payload.tsv` validates `merge-policy`, but export behavior is selected by the global
  command mode and does not consume the row's value. The column describes semantics that do not
  exist.

### Cost still paid on routine work

- `--fast` skips export but still runs every other self-test group, including upgrade behavior.
- Adoption fixtures repeatedly build large source copies and synthetic `PATH` directories.
- Contract rules and review instructions remain repeated across entry points even when one skill
  owns the detailed procedure.
- Every executable change defaults to a full Feature/Security tracker and per-step workflow even
  when it is bounded, reversible, and carries no shared-contract or trust-boundary risk.

## Design decisions

### 1. Correctness precedes optimization

F-1 through F-5 land before contract or workflow reductions. No cost reduction may make a
correctness gate optional, convert an error into a warning, or let local evidence pose as
authoritative CI evidence.

### 2. Lifecycle evidence uses a versioned, exact schema

New Feature and Security documents carry `Evidence schema: v2`. V2 status values use explicit
keys rather than positive-word matching:

```text
- **Evidence schema:** v2
- **Tracking issue:** url=https://github.com/<owner>/<repo>/issues/<number>
- **Approval:** status=approved; by=<identity>; at=YYYY-MM-DD
- **Implementation head:** source=pr-head
- **Implementation PR:** url=https://github.com/<owner>/<repo>/pull/<number>
- **Verification evidence:** run=https://github.com/<owner>/<repo>/actions/runs/<id>; workflow=.github/workflows/ci.yml
- **Review verdict:** status=approved; by=<independent-role>; url=https://github.com/<owner>/<repo>/issues/<number>#issuecomment-<id>
- **Memory:** path=docs/memory/<entry>.md | status=n/a
```

The parser accepts only complete values from closed enums. Negated prose cannot become a
positive state. With `--verify-evidence`, the Actions API must return all of:

- `conclusion == success`;
- `repository.full_name` equal to the current GitHub repository;
- workflow path equal to the expected workflow in project CI policy;
- `head_sha` equal to the live implementation PR head and the independently reviewed head.

`Implementation head` is a resolution rule, not a SHA embedded in the document: a commit cannot
contain its own hash. Resolve it from the PR on each check and print the full resolved SHA in
verification output. Review and CI evidence for that final head live externally on GitHub.

The expected repository comes from the checkout's configured origin. The expected workflow is
recorded at adoption in project CI policy, with default `.github/workflows/ci.yml`; a Feature's
evidence field cannot override it. Changes to that policy require explicit human approval.
Resolve the PR in that repository and obtain its current head. Resolve the review comment and
require a structured approval naming that PR and full head SHA, authored by the configured
independent reviewer identity. For Strict, verify every stamped step issue is closed with an
approving review for its implementation commit, and require a final approval covering the PR
head. Labels and locally written `by=` values are not proof of review.

The approval comment's structured record contains `status=approved`, the PR number, and
`head=<40-hex-sha>`. Reviewer identities are configured by the human at adoption; the checker
compares the API-returned author identity, not a claimed author in comment text. A new commit
invalidates final-head approval and CI evidence until both cover that head. This gate applies
before merge; recording the eventual merge is a separate shipping record. Close-out documentation
commits must also receive final-head review and CI before the gate passes.

Missing tools, network failures, malformed responses, and absent fields are `UNVERIFIED`.
Resolved identity or SHA mismatches are `BLOCKED`. In strict/check mode, both states exit nonzero.

Existing schema-less documents remain readable in report mode, but are reported as legacy and
cannot pass strict evidence verification until their Status block is migrated. This avoids
silently grandfathering evidence that cannot be bound to reviewed work.

### 3. Plan identity is normalized before any GitHub call

The plan parser first produces one normalized model in which every step has a concrete ID:
explicit `steps[].id`, otherwise its positional `step-N`. Uniqueness is validated on that model
before authentication or any network mutation.

Issue discovery extracts complete identity stamps and indexes them by exact `(plan, kind,
step-id)` tuples. Substring matching is not permitted. Multiple issues with the same exact stamp
are an error requiring human resolution; choosing the first is unsafe.

Spec labels are creation defaults. Reconciliation updates title/body/spec revision, but it does
not reapply labels to an existing issue. Workflow labels belong to the live state machine.

### 4. Protected command recognition is shared and non-evaluating

Push blocking and commit-time secret scanning use one Bash 3.2-compatible lexical recognizer in
`scripts/lib/`. It recognizes command boundaries, quoting, escapes, the supported Git wrappers,
and `git` global options including quoted `-C` paths. It never uses `eval` and never executes the
input command.

The recognizer returns structured words for protected invocations. A malformed or unsupported
command that visibly targets a protected operation fails closed with a diagnostic. Benign prose
and searches remain allowed.

For a commit invocation, the hook resolves the actual worktree and index from the parsed Git
arguments, then runs both gitleaks and the high-signal staged-diff scan in that repository. A
missing repository or unreadable index blocks the commit rather than silently skipping the scan.

Hooks remain local guardrails, not the authority boundary. Human-controlled platform permissions
and branch protection remain responsible for preventing unauthorized remote writes.

### 5. Exported checks derive their required surface from the payload manifest

Export scope is data, not a one-time copy filter. Export records the selected scopes in a small
machine-readable installation-state file. Doctor, contract checks, and self-tests ask the payload
library which adapters are active before requiring files or comparing copies.

Keep the five-column manifest wire format in this pass: installed upgraders parse a fetched
manifest using their installed payload library before they can install its replacement.
Document `merge-policy` as a deprecated compatibility field, retaining existing values and
validation without promising per-row application behavior. Non-destructive apply versus global
`--force` remains the executable policy. Removing the column requires a separate versioned
migration; this Feature does not change its position or meaning for old readers.

### 6. Shared prose has one source and generated consumers

The canonical source for each identical skill and shared contract region lives under
`templates/shared/`. A renderer updates local adapter copies and the marked shared regions in
root/template contracts. `--check` compares complete generated regions, not headings. Surrounding
project-specific sections remain hand-maintained.

Review surfaces use one vocabulary:

- finding severity: High / Medium / Low / Nit, mapped to `sev:high|med|low|nit`;
- verdict: `approved`, `changes requested`, or `pending`.

The `/review` command becomes a thin scope/runtime entry point to the canonical review skill.

### 7. One assurance model, routed instead of repeated

This Feature supersedes the implementation briefs in:

- `docs/inprogress/feature-progressive-assurance-profiles.md`;
- `docs/inprogress/feature-adaptative-assurance-opus.md`.

It keeps the progressive proposal's Quick / Standard / Strict semantics and the adaptive
proposal's project baseline, but rejects both “copy all three profiles into every contract” and
“render a different full contract for every tier.” Universal engineering and authority rules stay
always loaded. Profile-specific ceremony lives once in `METHODOLOGY.md`, and issue generation
emits a bounded executor packet containing only the effective profile's requirements.

Project state:

```text
.agentic-flow-assurance       quick | standard | strict
```

Rules:

- `standard` is the default for new exports and for a missing legacy state file.
- The project value is the minimum assurance for ordinary work.
- A Feature/Security brief may raise the effective profile; it may not lower it.
- Lowering the project baseline requires a human identity and reason recorded by
  `scripts/assurance.sh set` in the tracked diff.
- Strict is mandatory for auth, secrets, destructive/data-loss behavior, migrations, public
  compatibility contracts, money/entitlements, release infrastructure, sensitive data, or an
  explicit human request.
- Quick is local and explicitly non-authoritative. It creates no claim of independent review or
  CI approval and must promote to Standard before entering the normal merge workflow.
- Profiles vary planning, issue topology, review depth, and retained evidence. They never vary
  engineering standards, secret/push hooks, or CI authority.
- A profile-less existing spec preserves today's tracker-plus-steps topology.

Topology:

| Profile | Artifact and issue shape | Review and evidence |
|---|---|---|
| Quick | No formal brief or issue; bounded local change only. | Focused test, inexpensive checks, executor self-check; report `Workflow: Quick / non-authoritative`. |
| Standard | Short one-step Feature brief and one work issue; no parent tracker. | One independent review, regression test, `make check`, proportionate broader tests, CI evidence. |
| Strict | Full Feature/Security analysis, tracker, and one sub-issue per independently shippable step. | Independent review per step, failure-path test per step, full suite, bound CI and close-out evidence. |

Standard's one work issue uses the existing executor/reviewer label pairs and comment-before-label
handoff. After approval, the reviewer records the reviewed SHA and changes that same issue to
`agent:claude,needs-closing`, leaving it open. The closer verifies final-head approval and CI,
updates/moves the one-step document, and closes the work issue. For Standard only, `Tracking issue`
in v2 identifies this work issue; no parent is created or required. The lifecycle checker requires
its approving review and closing-ready state, not a closed issue, before authorizing close-out.
Strict retains the existing rule that reviewers close steps and only the parent receives
`needs-closing`. Plan approval for Standard is recorded on the work issue, with the approving
human identity and date, using the same evidence discipline as Strict's parent.

F-7 introduces policy and state as preparatory functionality. Standard issue creation and its
handoff activate together in F-8; until then, existing issue generation retains legacy topology.

Live code and executable tests define existing interfaces. Briefs define intended behavior,
invariants, failure behavior, and inspection routes; they do not freeze private signatures.

## Interface before implementation

### Lifecycle CLI

```text
scripts/lifecycle-status.sh [--check] [--verify-evidence]

report mode:
  ACTIVE | READY | BLOCKED | UNVERIFIED | LEGACY

exit behavior:
  --check: nonzero for BLOCKED
  --check --verify-evidence: nonzero for BLOCKED, UNVERIFIED, or LEGACY
```

### Normalized plan model

```text
PlanSpec:
  id: string
  profile: standard | strict | absent(legacy strict topology)
  tracking: object required for strict/legacy; absent for standard
  labels: string[] creation defaults
  steps:
    - id: explicit value | generated step-N
      title: string
      body: string
      labels: string[] creation defaults

IdentityStamp:
  plan: string
  kind: tracker | step
  step: string | absent
  spec: hash
```

All validation, including effective IDs and profile/topology compatibility, completes before the
first `gh` call.

### Assurance CLI

```text
scripts/assurance.sh status
  prints project baseline and its source (state file or legacy default)

scripts/assurance.sh set <quick|standard|strict> [--approved-by <identity>] [--reason <text>]
  raises freely; lowering requires both audit fields; writes atomically

scripts/assurance.sh --check
  fails on an unknown value or malformed state file
```

### Export installation state

```text
.agentic-flow-installation
  version=1
  scope=core
  scope=claude
  scope=docs
  ...one bounded, validated line per included scope...
```

Unknown keys, duplicate keys that must be singular, unknown scopes, and malformed lines fail
validation. If installation state is absent, first read and validate the existing
`.agentic-flow-scopes-excluded`; derive included scopes from that file and the manifest. Only
when both files are absent may legacy default scopes apply, with a warning. If both exist, they
must agree or validation fails before mutation. Keep the legacy exclusion file synchronized for
compatibility with installed old upgraders. Persist both only after a successful application;
dry runs and unresolved merge candidates must not advance active installation state.

### Context-cost report

```text
scripts/measure-harness.sh [--format text|json]

per role/profile:
  static_files, static_words, generated_packet_words

per representative workflow:
  role_boots, handoffs, validation_groups, fixture_copies
```

The report is deterministic and offline. It does not estimate model tokens or claim to observe
provider-side context caching.

## Threat model

The harness processes adversarially editable repository content, GitHub issue bodies, status
documents, shell command strings, and CI URLs. The worst outcomes are false authorization to
close unreviewed work, mutation of the wrong issue, committing a secret from a different
worktree, or bypassing a no-push guard. Therefore external text is parsed into closed, validated
models at one boundary; identities are exact; ambiguous duplicates fail; evidence is bound to
repository, workflow, and commit; and command text is tokenized without evaluation. Assurance
selection is also security-relevant: a tracked project baseline may be lowered only with explicit
human attribution, and no profile can change branch protection or CI authority.

## Failure behavior

| Operation | Missing/unavailable input | Malformed or ambiguous input | Partial success |
|---|---|---|---|
| Lifecycle status parsing | Missing required v2 field → `BLOCKED`. | Unknown state or duplicate field → `BLOCKED`. | No READY result until every field is valid. |
| Actions evidence lookup | Missing `gh`, auth, network, or run → `UNVERIFIED`; strict verification fails. | Repository/workflow/SHA mismatch → `BLOCKED`. | A successful conclusion with any unbound identity remains blocked. |
| Plan normalization | Missing required topology field → exit 2 before `gh`. | Duplicate normalized IDs or duplicate stamps → exit nonzero before mutation. | Existing reconciliation recovery remains idempotent; never choose an arbitrary duplicate. |
| Protected-command recognition | No protected invocation → allow. | Malformed syntax around a protected executable → block with reason. | No command is executed by the recognizer. |
| Secret scan | Repository/index cannot be resolved → block commit. | Diff/tool output malformed → block commit. | Both scanning layers must complete; one clean layer cannot mask the other's failure. |
| Export/doctor scope | Legacy state → warn and use documented default. | Unknown/contradictory scope → fail before validation. | Write installation state atomically after successful export. |
| Shared-contract render | Missing canonical source or marker → fail without rewriting. | Duplicate/unknown region → fail before rewriting. | Render to temporary files, then replace all consumers or none. |
| Assurance change | Missing state → Standard default. | Unknown tier or malformed audit args → fail without write. | Atomic state-file replacement; no half-written value. |

Bounds:

- GitHub issue discovery remains capped at 100 and fails with a clear instruction if the complete
  stamped plan set cannot be proven within that bound.
- Every parsed document field and command is read from a finite local payload; the lexical
  recognizer caps command bytes and token count and blocks protected operations beyond the cap.
- Evidence verification uses at most 100 step issues, one PR lookup, one final review-comment
  lookup, and one Actions-run lookup per document, plus bounded step-review lookups. Every outbound
  call has a 30-second deadline, with no implicit retries; timeout yields `UNVERIFIED`.
- Context measurement walks only declared bundle files and uses fixed representative scenarios.

## Proposed approach

### Option A — Patch only the reproduced defects

This is the smallest immediate change, but it leaves the contradictory contracts, inactive
manifest field, expensive fast path, and competing assurance plans in place. The next workflow
change would multiply those inconsistencies again.

### Option B — Correctness first, then bounded consolidation and assurance (recommended)

Land the reproduced correctness fixes as independently reviewable steps, make scope and shared
contracts explicit, then introduce the single routed assurance model. Each later optimization is
guarded by the corrected gates from earlier steps.

### Option C — Implement adaptive rendered contracts

Rendering complete agent contracts per assurance tier minimizes per-project prose, but adds state
coupling, atomic multi-file rewrites, and three contract variants to test. Most always-loaded
content is universal engineering guidance, so the marginal token saving does not justify that
mechanism in this pass.

**Recommendation:** Option B. It fixes demonstrated safety failures, resolves the two competing
proposals, and measures the remaining cost before considering more orchestration.

## Out of scope / What not to build in this pass

- Automatic assurance selection from diff size, paths, or model judgment.
- Model routing by assurance profile.
- Provider token telemetry or claims about hidden context-cache behavior.
- A new review runner, background daemon, or tmux orchestration.
- Different coding/security standards by profile.
- Any mechanism that lets a profile disable CI, hooks, review findings, or human push/merge
  ownership.
- Rewriting completed documents in `docs/done/`.
- Unrelated refactors of the large `scripts/self-test.sh`; only extract shared setup when it
  directly removes repeated work measured in F-7.
- Treating local hooks as a substitute for repository permissions or branch protection.

## Open questions

None. Approval of this Feature approves the design decisions above. Implementation must stop and
return to planning if live GitHub APIs cannot expose workflow path and head SHA as specified, or
if a step would weaken a universal gate to meet a cost budget.

---

# Part B — Implementation Brief

> **Audience:** Codex. Steps are ordered so false-green behavior is removed before any contract
> or workflow is made smaller. Re-read the named live files, their direct callers/callees, and
> focused tests before each step. This brief specifies behavior and invariants, not finished code.

## Branch

Base: `main`. One branch and one PR for the complete brief:

```text
codex/trustworthy-proportionate-harness
```

Each step is one logical commit and one issue. Do not bundle steps. Do not push.

## Whole-brief Definition of Done

- Negative or unverified lifecycle text cannot produce READY or a zero strict-verification exit.
- CI evidence is bound to project CI policy, the live PR head, and independent approval of that head.
- Plan identity collisions and duplicate issue stamps fail before mutation; existing workflow
  labels survive reapplication.
- Push/merge protection handles ordinary quoting and command-boundary forms; commit secret scans
  use the invoked repository/index.
- Hook tests require the contractually correct exit status, export failure reaches `make build`,
  and every shipped executable is syntax-checked and ShellChecked.
- Claude-only and other scoped exports pass their own applicable doctor/contract checks.
- Intended-identical adapters and shared contract regions have one canonical source; review
  severity and verdict vocabularies agree.
- Reviewer regression verification uses an isolated temporary checkout and does not mutate the
  user's working tree.
- Quick, Standard, and Strict form one assurance model with a tracked Standard default, bounded
  executor packets, and no effect on CI authority or engineering standards.
- The two superseded assurance documents are marked superseded and point to this Feature; the
  already-executed context optimization document is not reimplemented.
- Fast-path cost is measured by actual role bundles and deterministic work counters. `--fast`
  excludes export and upgrade behavioral suites while retaining structural and critical hook
  smoke checks.
- A fresh default export, a Claude-only export, `make check`, `make test`, `make build`, and
  repository-scope doctor all pass.

## Verification commands

Run after every step:

```bash
make check
make test-one F=<step-group>
```

Run after the final step:

```bash
make test
make build
scripts/doctor.sh --check --scope repo --skip-make-check
```

Use `F=lifecycle`, `plan-to-issues`, `hooks`, `contracts`, or `export` as named below. If a step
adds a narrower selector, run it as additional evidence; do not replace the required group.

---

## Step F-1 — Bind lifecycle closure to explicit, verified evidence

**Why first:** Lifecycle READY is the final local authorization to close a plan. A false positive
there can bless every later mistake.

**Inspect immediately before editing:**

- `scripts/lifecycle-status.sh`;
- lifecycle fixtures in `scripts/self-test.sh`;
- `docs/templates/feature-analysis.md` and `docs/templates/security-review.md`;
- close-out guidance in `CLAUDE.md`, `METHODOLOGY.md`, and relevant skills;
- the current fields of active documents, for migration behavior only.

**Approach:**

1. Parse Status blocks once into a closed v2 model. Reject duplicate keys, unknown states, missing
   fields, malformed URLs, invalid head-resolution rules, and negative/free-form substitutes.
   Require full SHAs in external review evidence.
2. Add the v2 fields to new Feature and Security templates and to the close-out contract. Keep
   legacy parsing only for report/migration diagnostics.
3. Resolve project repository/CI policy and the implementation PR head. Fetch the final review
   comment and validate its author, PR, verdict, and SHA; for Strict validate closed, reviewed
   steps. Compare Actions conclusion, repository, workflow, and SHA to those independently
   established values. Add the structured review-comment contract and adoption configuration.
4. Count `UNVERIFIED` as a strict failure. Keep report mode useful when offline by distinguishing
   unavailable evidence from disproved evidence.
5. Redact tool errors so auth data or unexpected response bodies are not copied into documents.

**Failure-first test:** Extend the lifecycle group with “not approved,” “not approved by Codex,”
duplicate v2 fields, a missing `gh`, an unresolved run, wrong repository, wrong workflow, wrong
SHA, and successful matching evidence. Include a stale successful run whose SHA/workflow have
been copied into the document, an unauthorized review author, an open/unreviewed Strict step,
and a new PR commit after approval. Assert both printed state and exact exit status.

**Stop if:** The available Actions response cannot establish workflow path and head SHA. Return to
planning with the smallest additional authoritative API shape; do not fall back to conclusion-only.

**DoD:** Only complete, exact v2 evidence can be READY under strict verification; all unresolved or
mismatched evidence exits nonzero.

**Commit:** `Bind lifecycle readiness to reviewed CI evidence`

**Focused verification:** `make test-one F=lifecycle`

---

## Step F-2 — Make plan identities exact and preserve live workflow labels

**Why second:** Issue reconciliation is the harness's remote mutation boundary. It must be
deterministic before later topology changes build on it.

**Inspect immediately before editing:**

- `scripts/plan-to-issues.sh`;
- both local plan-to-issues skill adapters;
- plan-to-issues fixtures and mocked `gh` calls in `scripts/self-test.sh`;
- issue-stamp and label-state documentation.

**Approach:**

1. Normalize every implicit ID to `step-N`, then validate the complete ID set and reserved marker
   characters before authentication or a `gh` call.
2. Parse complete identity stamps from the bounded issue result into an exact index. Preserve
   compatibility with existing stamps, but never use `contains()` to select an issue.
3. Fail on duplicate exact tracker or step stamps and name the conflicting issue numbers.
4. Treat spec labels as create-only defaults. Update content/spec stamps on existing issues without
   adding, removing, or resetting workflow-state labels.
5. Make the 100-issue discovery bound explicit: if results indicate truncation or the expected
   stamped set cannot be established, stop without mutation and explain how to narrow/repair it.

**Failure-first test:** Add fixtures for explicit `step-1` plus implicit first step, `step-1` versus
`step-10`, duplicate remote stamps, a full 100-result page, reviewer labels on reapply, and a clean
idempotent reapply. Assert zero mutating `gh` calls for every validation/ambiguity failure.

**DoD:** One normalized ID maps to at most one exact issue; collision and ambiguity are errors;
reapply cannot regress a step's workflow state.

**Commit:** `Make plan reconciliation identity exact`

**Focused verification:** `make test-one F=plan-to-issues`

---

## Step F-3 — Parse protected Git commands and scan the invoked repository

**Why third:** The secret and no-push hooks guard irreversible boundaries and currently share the
same fragile command-text assumptions.

**Inspect immediately before editing:**

- `scripts/hooks/block-push.sh`;
- `scripts/hooks/scan-secrets.sh`;
- `scripts/hooks/block-git-add-all.sh` and `require-step-comment.sh` for shared recognition needs;
- `scripts/lib/` conventions;
- hook fixtures in `scripts/self-test.sh`;
- `.claude/settings.json` and `.codex/hooks.json` matcher behavior.

**Approach:**

1. Add one non-evaluating, bounded Bash lexical recognizer for command boundaries, quotes, escapes,
   supported wrappers, Git global options, and `gh pr merge`.
2. Route push/merge blocking and commit detection through it. Reuse it in other command hooks only
   where it removes a demonstrated duplicate parser; do not broaden this into a shell interpreter.
3. Resolve the commit invocation's repository and index from its parsed working-directory/global
   arguments. Run gitleaks and staged-diff patterns with explicit argument arrays in that context.
4. Fail closed when a protected operation is recognizable but parsing, repository resolution, or a
   required scan fails. Preserve the documented intentional false-positive override for scanning.
5. Keep diagnostics value-free: print command shape and repository path, never staged secret text.

**Failure-first test:** Cover `git push;`, quoted and escaped `git -C` paths, supported wrappers,
multiple shell commands, malformed quotes around a protected command, benign searches mentioning
the rule, and a commit directed at another repository containing a staged synthetic secret. Assert
exit 2 for blocks and prove both scanning layers run against the target repository.

**Stop if:** Reliable recognition would require executing or `eval`-ing user input, or adding a new
runtime dependency to exported hooks. Keep the guard conservative and return to design.

**DoD:** Ordinary protected command forms cannot bypass the hooks, benign prose remains allowed,
and cross-repository commits scan the correct index.

**Commit:** `Parse protected Git commands before enforcing hooks`

**Focused verification:** `make test-one F=hooks`

---

## Step F-4 — Remove false-green build, hook-test, and static-analysis paths

**Why fourth:** The remaining local gates must report their own failures accurately before they are
used to guard generated contracts and assurance behavior.

**Inspect immediately before editing:**

- root and template `Makefile`;
- `must_block()` / `must_block_nojq()` and result helpers in `scripts/self-test.sh`;
- executable inventory in `config/payload.tsv`;
- `scripts/agentic-flow` and ShellCheck output;
- contract/sync checks called by `make check`.

**Approach:**

1. Make block assertions require exit 2. Report zero as “allowed” and any other status as “hook
   crashed/wrong contract,” preserving stderr for diagnosis.
2. Make multi-command build recipes explicitly fail fast so export failure reaches Make.
3. Derive or explicitly enumerate shipped shell executables in one Make variable/helper used by
   both syntax and ShellCheck. Include extensionless `scripts/agentic-flow` without double-running
   directory entries already covered.
4. Resolve real ShellCheck findings in the executable or add the narrowest justified directive;
   do not skip the file or globally suppress warning classes.
5. Mirror behavior changes into the exported Makefile through the shared-contract mechanism
   available at this step, or by the existing paired edit until F-6 lands.

**Failure-first test:** Add a hook stub exiting 1, an export stub exiting 1 followed by a successful
echo, and an intentional syntax/ShellCheck defect in an isolated copy of `scripts/agentic-flow`.
Each must make its owning gate fail for the intended reason.

**DoD:** Tests distinguish a policy block from a crash; build cannot mask export failure; every
shipped shell entry point is parsed and statically analyzed.

**Commit:** `Make local harness gates fail for the right reason`

**Focused verification:** `make test-one F=hooks` and `make test-one F=contracts`

---

## Step F-5 — Make exported validation consume the selected adapter scope

**Why fifth:** Export scope already controls copied files; validation must describe that same
installation before shared adapters and assurance state add more scoped data.

**Inspect immediately before editing:**

- `config/payload.tsv`;
- `scripts/lib/payload-apply.sh`;
- `scripts/export.sh`, `scripts/init.sh`, and `scripts/agentic-flow` upgrade flow;
- `scripts/doctor.sh`, `scripts/check-payload-manifest.sh`, and adapter parity checks;
- Claude-only/export fixtures in `scripts/self-test.sh`.

**Approach:**

1. Preserve the five-column manifest and mark `merge-policy` as deprecated compatibility metadata.
   Keep old parsers able to consume new payloads; preserve non-destructive and force behavior.
2. Have export compute, validate, and atomically record the included scope set. Do not infer scope
   later from whichever files happen to exist.
3. Add payload-library queries for active scopes and required destinations. Use them in doctor,
   parity checks, upgrade, and contract tests.
4. Migrate `.agentic-flow-scopes-excluded` before considering defaults. Reject conflicts between
   old/new state, keep the old file synchronized, and do not advance state on partial application.
5. Test exclusions in combinations, not only Claude-only, so core/docs/CI invariants remain clear.

**Failure-first test:** A Claude-only fixture and at least one other excluded-scope fixture must pass
their applicable checks, fail when an active-scope file is missing, and ignore parity requirements
for inactive adapters. Malformed installation state and unknown manifest scopes fail before copy or
upgrade mutation. Start an upgrade using an unmodified pre-change installed CLI and payload library
against the new source; test default and Claude-only installations, including pending candidates.
Assert excluded adapters stay excluded, the old parser accepts the manifest, and installation
state advances only when the payload is applied successfully.

**DoD:** Export, doctor, upgrade, and tests derive one adapter surface from manifest plus recorded
scope; existing upgraders remain compatible and the retained deprecated column is documented
accurately rather than presented as executable per-file policy.

**Commit:** `Align exported validation with active adapter scopes`

**Focused verification:** `make test-one F=export` and `make test-one F=contracts`

---

## Step F-6 — Generate shared contracts and converge review terminology

**Why sixth:** With trustworthy gates and scope-aware consumers, duplication can be removed without
creating exports that fail under supported modes.

**Inspect immediately before editing:**

- plan-to-issues and review-execution skill copies;
- create-tags skill copies;
- `.opencode/agent/code-reviewer.md` and `.opencode/command/review.md`;
- root/template `CLAUDE.md` and `AGENTS.md`;
- `scripts/check-harness-sync.sh` and existing parity tests;
- `config/payload.tsv` and export fixtures;
- `METHODOLOGY.md` severity and review sections.

**Approach:**

1. Move intended-identical skill bodies and genuinely shared contract regions to canonical files
   under `templates/shared/`. Keep adapter metadata or entry shims only where a platform requires
   them.
2. Add a deterministic renderer with `--check`. Validate all markers and canonical inputs before
   replacing any consumer; use temporary files and all-or-none replacement.
3. Replace heading-only synchronization with complete generated-region equality while preserving
   declared project-specific surrounding content.
4. Make export copy canonical content to each active adapter destination without introducing a
   second membership list outside `config/payload.tsv`.
5. Normalize every review surface to High/Medium/Low/Nit and approved/changes requested/pending.
   Retain severity-to-label and severity-to-verdict mapping in one canonical review contract.
6. Reduce `/review` to scope selection and invocation of the canonical skill. Remove duplicated
   engineering standards while leaving a precise route to their authoritative home.
7. Replace any “revert, run, restore” red-first procedure with a temporary detached checkout or
   equivalent isolated fixture. Cleanup must target only the exact temporary directory created by
   the reviewer, and failure to create isolation leaves the verdict pending rather than mutating
   the live checkout.

**Failure-first test:** Modify one generated consumer, one shared region under an unchanged heading,
one severity word, and one adapter excluded by scope. The first three must fail the correct sync
check; the inactive adapter must not be required. A render into a missing/duplicate-marker fixture
must leave every file byte-identical. Contract fixtures must reject review guidance that uses
revert/restore against the live checkout and require an isolated red-first path.

**DoD:** Shared text is authored once, complete generated regions cannot drift, supported scoped
exports remain green, review commands/agents/skills issue the same severity and verdict terms, and
review verification preserves the user's checkout byte-for-byte.

**Commit:** `Generate shared agent and review contracts`

**Focused verification:** `make test-one F=contracts` and `make test-one F=export`

---

## Step F-7 — Define assurance policy and persist the project baseline

**Why seventh:** Policy and validated state are prerequisites for changing issue topology.

**Inspect:** Methodology delivery lanes, root/template role contracts, export/init/upgrade,
doctor, and both historical assurance proposals.

**Approach:**

1. Define Quick/Standard/Strict once in methodology using Part A's rules. Preserve universal
   engineering requirements and human push/merge ownership. Keep Decision as a document type and
   Emergency's retrospective obligation.
2. Add the assurance CLI and tracked baseline. Default missing state to Standard, validate the
   enum, and require human attribution/reason on a downgrade. Store those audit fields in a
   documented companion record so they survive after the command exits; claimed attribution is
   not machine authentication of approval.
3. Integrate state with adoption, doctor, and upgrade without overwriting an adopter's baseline.
4. Keep issue generation on its existing topology until F-8. Clearly document this transition.
   Mark the competing proposals superseded by this approved brief without deleting their history.

**Failure-first test:** Invalid state, malformed audit metadata, unaudited downgrade, and upgrade
over a customized baseline. Test a successful raise and attributed downgrade. Assert no CI
workflow uses assurance state to reduce required checks.

**DoD:** Policy has one canonical home; baseline changes are validated and auditable; existing
issue workflows remain operational pending F-8.

**Commit:** `Define assurance policy and persist project baselines`

**Focused verification:** `make test-one F=contracts`, `make test-one F=export`, and
`make test-one F=upgrade`.

---

## Step F-8 — Implement Standard issue topology and complete close-out

**Why eighth:** Activate issue creation, handoff, and closure together so no new issue shape is
introduced without a path through review and close-out.

**Inspect:** Normalized plan parser, plan-to-issues adapters, lifecycle checker, review contract,
handoff hook, Feature/Security templates, and root/template role state machines.

**Approach:**

1. Add explicit profile validation before GitHub calls. Standard requires exactly one step and
   creates one work issue; Strict retains parent plus steps; absent profile retains legacy
   topology. Reject per-brief downgrades below the project baseline.
2. Define Standard identity as the existing exact plan/step stamp for its sole step. Store approval
   metadata there. Reapply preserves its live labels; changing an existing plan's topology is
   rejected with a migration-required diagnostic, without creating or closing issues.
3. Implement Part A's Standard handoff: reviewer approval leaves the work issue open with
   `agent:claude,needs-closing`; closer records final-head evidence and closes it. Update the
   handoff hook and review guidance in the same commit. Strict step closure remains distinct.
4. Make lifecycle validation interpret Standard's `Tracking issue` as the work issue. Verify
   approval and review evidence without requiring a nonexistent parent or pre-closed work issue.
5. Emit the bounded executor packet described in Part A from explicit spec fields, with documented
   required fields and a maximum of 800 words. Reject overflow instead of truncating requirements.
   Update both the spec contract and adapters so required packet data has a defined input source.

**Failure-first test:** Standard with zero/two steps, Strict without a parent specification,
downgrade below baseline, topology-changing reapply, missing review, stale final-head evidence,
and packet overflow. Exercise a full mocked Standard create → execute → review → close-out
sequence; assert one issue only and no premature closure. Exercise legacy and Strict flows too.

**DoD:** Standard is usable through closure; exact identity, approval evidence, labels, and
idempotence hold for each supported topology.

**Commit:** `Support Standard issues through review and close-out`

**Focused verification:** `make test-one F=plan-to-issues`, `make test-one F=lifecycle`,
`make test-one F=hooks`, and `make test-one F=contracts`.

---

## Step F-9 — Measure role context and workflow costs

**Why ninth:** Establish repeatable measurements before changing suite setup and dispatch.

**Inspect:** Role read sets, generated contracts/packets, self-test dispatch and fixture setup,
README/ADOPTION, and this document's acceptance criteria.

**Approach:**

1. Add the offline text/JSON measurement interface in Part A. List actual bundle files by role;
   count shared files once per load scenario and packet words separately.
2. Distinguish measured words and executed work counters from modeled role boots/handoffs.
   Fix the representative scenarios and record the checkout revision and commands.
3. Record baseline fast/full group dispatch and fixture-copy counts for F-10. Establish numeric
   role ceilings from measured bundles and retain the 800-word packet maximum from F-8.
4. Record results in this document; do not add timing assertions or claim provider token telemetry.

**Failure-first test:** Missing bundle input, invalid output format, a fixture exceeding a role
ceiling, and duplicate shared-file counting. Assert deterministic output for unchanged inputs.

**DoD:** Reproducible baseline and numeric budgets exist before optimization; measurement does not
change test dispatch or workflow behavior.

**Commit:** `Measure harness context and verification work`

**Focused verification:** `make test-one F=contracts`.

---

## Step F-10 — Reduce fast-check and fixture setup costs

**Why tenth:** Optimize against F-9's measurements while retaining the corrected gates.

**Inspect:** Self-test mode/group dispatch, adoption fixtures, `path_without_tools()`, Makefile,
CI, and F-9 measurement output.

**Approach:**

1. Define the fast-mode inventory explicitly: structural/contract checks and a named critical hook
   smoke set. Keep every behavioral regression in full mode and its focused group. Export and
   upgrade behavior must not run in fast mode.
2. Reuse one immutable source snapshot per process; derive mutable fixture copies from it so
   adversarial tests cannot contaminate later cases.
3. Replace whole-PATH enumeration with a declared minimal tool set, preserving missing-tool tests.
4. Compare the same F-9 scenarios before/after. Require fewer fast-mode behavioral groups and less
   tool-discovery work, with unchanged full-suite regression coverage. Record elapsed timings as
   observations only; retain deterministic work counters as regression gates.

**Failure-first test:** Fast dispatch entering export/upgrade, a full-mode group accidentally
omitted, missing required fixture tools, and one fixture's mutation leaking into another.
Check focused selectors remain independent and every removed fast regression still runs in full.

**Stop if:** Savings require removing correctness coverage from the full suite or weakening a hook.

**DoD:** Fast-mode work decreases demonstrably, fixtures remain isolated, budgets hold, and all
whole-brief verification commands pass.

**Commit:** `Reduce routine harness verification cost`

**Focused verification:** `make test-one F=contracts`, `make test-one F=hooks`,
`make test-one F=export`, and `make test-one F=upgrade`; then the full suite.

---

## Status / Implementation status

- **Evidence schema:** v2
- **Tracking issue:** pending approval and `plan-to-issues`.
- **Approval:** status=pending.
- **Implementation head:** pending.
- **Implementation PR:** pending.
- **Verification evidence:** pending.
- **Review verdict:** status=pending.
- **Memory:** status=n/a.
- **Supersedes:** the implementation briefs in
  `feature-progressive-assurance-profiles.md` and `feature-adaptative-assurance-opus.md` after
  approval; until then, all three remain proposals and none should be executed.
- Steps not started. The executor records each reviewed commit and issue in the Tracker; close-out
  migrates this Status block to the exact v2 evidence values defined above.
