<!-- TRIAGE (first pass · 2026-09-11) -->
> **Type:** Feature · **Status:** ✅ Done
> **Assurance:** Strict. Make the harness's correctness gates prove the state they report, then
> reduce duplicated contracts, routine validation cost, and low-risk workflow ceremony. Approved
> 2026-09-20; execution is tracked on the `plan-to-issues` tracker.

# Feature — Trustworthy and proportionate harness execution

## Tracker

- [x] F-1 Parse lifecycle evidence into an exact v2 model — `7cff1f9` + `1f3706a`; #94 reviewed clean.
- [x] F-2 Bind Actions evidence to repository, workflow, and PR head — `0eb39f3`; #95 reviewed clean.
- [x] F-3 Verify review provenance and define close-out sequencing — `5b9fa4c`; #96 reviewed clean.
- [x] F-4 Make plan identities exact and preserve live workflow labels — `c6c58fe`; #97 reviewed clean.
- [x] F-5 Parse protected Git commands and scan the repository being committed — `3763101`; #98 reviewed clean.
- [x] F-6 Remove false-green build, hook-test, and static-analysis paths — `8cde022` + `9a82aff`; #99 reviewed clean.
- [x] F-7 Make exported validation consume the selected adapter scope — `5a2bf4d`; #100 reviewed clean.
- [x] F-8 Generate shared contracts and converge review terminology — `67b6dac`; #101 reviewed clean.
- [x] F-9 Define assurance policy and persist the project baseline — `f2b0650` + `07bdb3d`; #102 reviewed clean.
- [x] F-10 Implement Standard issue topology and complete close-out — `987c58b`; #103 reviewed clean at `6b738c8`; the post-approval amendment is an accepted risk (`docs/accepted_risks.md#f10-unreviewed-amendment`).
- [x] F-11 Measure role context and workflow costs — `931925b` + `36f838b`; #104 reviewed clean. Measured at `987c58b`; the user approved the table below on 2026-09-26, clearing the F-12 threshold checkpoint.
- [x] F-12 Reduce fast-check and fixture setup costs — `15483f5` + `ba2cbd9`; #105 reviewed clean.

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

F-1 through F-7 land before contract or workflow reductions. No cost reduction may make a
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
- **Verification evidence:** source=final-approval-run
- **Review verdict:** source=pr-head-approval
- **Memory:** path=docs/memory/<entry>.md | status=n/a
```

The parser accepts only complete values from closed enums. Negated prose cannot become a
positive state. With `--verify-evidence`, the Actions API must return all of:

- `conclusion == success`;
- `repository.full_name` equal to the current GitHub repository;
- workflow path equal to the expected workflow in project CI policy;
- `head_sha` equal to the live implementation PR head and to the head named by the approval that
  satisfied the configured review identity mode.

`Implementation head` is a resolution rule, not a SHA embedded in the document: a commit cannot
contain its own hash. Resolve it from the PR on each check and print the full resolved SHA in
verification output. Review and CI evidence for that final head live externally on GitHub.

The expected repository comes from the checkout's configured origin. The expected workflow is
recorded at adoption in project CI policy, with default `.github/workflows/ci.yml`; a Feature's
evidence field cannot override it. Changes to that policy require explicit human approval.
Resolve the PR in that repository and obtain its current head. Query
`repos/{owner}/{repo}/actions/runs/{run_id}` for Actions evidence; that endpoint returns
`conclusion`, `head_sha`, workflow `path`, and `repository.full_name` in one bounded lookup.
Resolve the final review comment from exactly one thread: the issue named by `Tracking issue` —
the parent tracker under Strict, the sole work issue under Standard — and require a structured
approval naming that PR and full head SHA. That thread is the only place searched for the final
approval. It is the one thread v2 always names, it is the one that stays open through close-out,
and it is where the label state machine already parks `needs-closing`.

**Completeness** must be proved, not assumed — not uniqueness. Multiple verdicts for one head are
normal and are resolved by the head-scoped selection rule below, which takes the last one; what the
gate cannot tolerate is choosing from a *partial* view. Selecting "the last verdict" from a listing
that stopped early is not the last verdict at all, and a page holds at most 100 comments, so a later
verdict — the one that would actually be authoritative — could sit on a page never read.

Because verdicts are fetched over GraphQL (step 5 below), completeness is decided by **GraphQL
pagination semantics, not REST ones**. Request `comments(first: 100)` and select
`pageInfo { hasNextPage endCursor }` alongside the nodes. Then:

- `hasNextPage == true` → `UNVERIFIED`, with an instruction to resolve the thread rather than
  silently checking a prefix.
- `pageInfo` absent, or `hasNextPage` null or non-boolean → `UNVERIFIED` naming the missing
  metadata. Absent pagination information is unproven completeness, not proven completeness.
- `hasNextPage == false` → the listing is complete, **including when exactly 100 nodes are
  returned**. Node count carries no information here. Treating a full page as incomplete is a REST
  habit — there, a full page is the only hint another may follow — and porting it to GraphQL would
  reject a thread the API has explicitly reported as whole.

**A complete page is not the same as a readable one**, and `hasNextPage` only ever proves the first.
GraphQL types the connection's `nodes` as `[IssueComment]` — a nullable list of *nullable* elements
— and a GraphQL response may carry a top-level `errors` array beside a `data` block that still looks
usable. A jq selector written with the usual optional operators would skip a null entry, drop the
authoritative verdict with it, and then report a complete listing with `hasNextPage: false`. So
before any verdict is parsed, require of the response:

- **no GraphQL errors** — a present, non-empty top-level `errors` array is `UNVERIFIED` naming the
  first error's message and path, even when `data` appears complete;
- **`nodes` present and an array** — null or absent is `UNVERIFIED` naming the thread;
- **every element a non-null object** — a single null entry is `UNVERIFIED` naming its index in the
  listing, never filtered out, because a null entry is precisely one comment the gate could not
  read.

The index is the only handle a null entry has, which is why it is what gets named. These checks are
about the nodes that *were* returned; node count still carries no completeness information.

Paging the whole thread is deliberately not the answer: an unbounded comment walk breaks the
bounded-lookup guarantee, and a tracking thread long enough to overflow one page is itself a signal
that the approval record needs human attention.

**The same one-page completeness rule governs every Strict per-step review lookup.** Each step
thread is read with one `comments(first: 100)` query and fails closed to `UNVERIFIED` when
`hasNextPage` is true or its pagination metadata is missing, naming the step. No thread in this gate
is ever judged from a partial prefix.

**Verdict selection is head-scoped, on every thread.** A healthy review thread *normally* contains
contradictory verdicts: `changes requested`, a fix, then `approved`, each written against a
different commit. Treating any disagreement in a thread as a conflict would block the ordinary
workflow, so selection runs in this order:

1. Parse every structured verdict in the listing and read its `head=`.
2. **Discard every verdict whose head is not the head under evaluation** — the step's
   implementation commit for a step thread, the PR head for the final approval. Those are
   superseded history, not conflicts, and their presence is never an error.
3. Order the remaining verdicts by **`fullDatabaseId`, ascending**, and take the highest as
   authoritative. Database ids are assigned monotonically at creation, so this is an exact total
   order over *creation* with no ties and no dependence on timestamp resolution. Timestamps are
   deliberately not used for ordering: GitHub's `createdAt`/`updatedAt` have second granularity,
   so two comments in the same second tie, and mixing an edit time into the order would let a
   retroactive edit of an old comment outrank a newer comment — reordering history by touching it.

   Two properties of that field decide the implementation, and both are easy to get wrong:

   - **It is nullable, so it must be validated.** GraphQL types it as a nullable `BigInt`
     (`databaseId` is likewise a nullable `Int`); only the opaque node `id` is non-null. That id is
     an unordered identifier and cannot order anything — but select it anyway, because it is the
     only identifier guaranteed to be there, and the null-ordering-key failure below is exactly the
     case with no other name to print. A verdict whose `fullDatabaseId` is null or absent has no
     position in the order, so the thread cannot be ordered soundly: report `UNVERIFIED` naming the
     comment by its opaque `id`, never fall back to listing order or to timestamps.
   - **It is returned as a JSON string and must stay one.** `fullDatabaseId` comes back as
     `"5080540104"`, not `5080540104` — GitHub serializes `BigInt` as a string precisely because the
     value outgrows the numeric types a client is likely to reach for. Both obvious readings of that
     string are wrong. Comparing it lexicographically puts `"9"` above `"10"` and misorders a thread.
     Converting it to a number is worse, because it is silent: `jq`'s `tonumber` — the obvious way
     to do it here — yields an IEEE-754 double, and every integer above 2^53 collapses onto a
     neighbour, so two adjacent ids compare *equal* and the tie falls to whichever the sort saw
     first, which is listing order wearing a numeric disguise. Bash's `$(( ))` is exact to 2^63 but
     wraps silently past it, so it only moves the cliff. Today's ids sit well below either ceiling,
     which makes this a latent defect rather than a live one — and means a regression only sees it
     if it reaches above 2^53 deliberately.
     Instead compare the **decimal strings exactly**: validate each as a non-negative integer
     literal, strip leading zeros, then order by digit count first and lexicographically within
     equal length. That is an exact total order at any width and never materializes the value as a
     number.

   Prefer `fullDatabaseId` over `databaseId` deliberately: live comment ids already exceed the
   signed 32-bit range `Int` nominally covers — the value above is one — which is why the wider
   field exists.
4. **Editing an older comment never changes the outcome.** The authoritative record is the
   last verdict *posted* for this head, and the way to change a verdict is to post a new one. This
   is stated in the reviewer contract, not left as an implementation detail, so nobody expects an
   edit to overturn a later approval.
5. **Detect edits explicitly, never by comparing timestamps.** `updated_at != created_at` proves an
   edit but its converse proves nothing: an edit made inside the creation second is invisible at
   second granularity, so the heuristic has silent false negatives exactly where it matters. Use
   GraphQL `IssueComment.lastEditedAt`, which is null if and only if the comment has never been
   edited and carries no granularity dependence (`editor` and `userContentEdits` are available
   alongside it for diagnostics). One GraphQL query returns `pageInfo`, the non-null opaque `id`,
   `fullDatabaseId`, `body`, `author`, `createdAt`, and `lastEditedAt` for the thread's comments —
   `id` earns its place as the diagnostic name for a comment whose ordering key is null, while
   `fullDatabaseId` remains the sole ordering key — so this is still the single
   bounded comment listing the bounds allow — not an extra call. Note that `lastEditedAt` is
   *legitimately* nullable, where null means never edited; that is the field's semantics, not
   missing data, and must not be confused with the null-ordering-key failure above.
6. **If the listing cannot supply an explicit edit indicator, fail closed** with `UNVERIFIED`,
   naming the missing field. Do not fall back to the timestamp heuristic: an unsound edit check
   reported as a clean result is worse than an honest refusal, and this is precisely the ambiguous
   event ordering the gate must not guess at.
7. **If the authoritative verdict has been edited** — non-null `lastEditedAt` — the state is
   `BLOCKED`, naming the comment id and edit time. A verdict is meant to be an immutable record of
   what a reviewer concluded at a moment; once edited, the text on the record is not what was
   posted, so it cannot be trusted as either an approval or a rejection. An edit to any *other*
   verdict for the head is irrelevant: it cannot become authoritative under id ordering, and it
   cannot change which record is.
8. **Recovery is always available**, because only the authoritative record blocks. Either post a
   fresh verdict — it takes the highest id and the edited record falls back into superseded
   history — or remove the structured marker from the edited comment, after which it is prose
   rather than a verdict and drops out at step 1. The thread never reaches a state where every
   later comment is ignored; an edit costs one comment, not a permanent block.
9. That authoritative verdict must be `approved`. If it is not, the state is `BLOCKED`. If no
   verdict for the evaluated head survives step 2, the head is unreviewed: `UNVERIFIED` for a step,
   and for the final approval the existing zero-approval failure.

Id ordering leaves no tie to break, so there is no ambiguous-conflict case left to define: two
verdicts sharing one comment id cannot occur through the API and indicate malformed input —
`BLOCKED`. Print the selected verdict's opaque `id` and its `fullDatabaseId`, its `lastEditedAt`
state, and its head, so a reader can see which record was used, which were discarded as superseded,
and which were rejected as edited. Every comment named in output or in a failure is named by its
opaque `id`, which is the one identifier that survives a null ordering key.
`source=pr-head-approval`
names what the approval must cover, not where it lives: an approval posted on the PR conversation,
on a step issue, or anywhere else does not satisfy this gate. For Strict, verify every stamped
step issue is closed with an approving review for its implementation commit; those per-step
verdicts stay on their own step issues and are the separately bounded step-review lookups.
Labels and locally written `by=` values are not proof of review.

A structured record carries each field at most once. A repeated `run=`, `attempt=`, `head=`, `pr=`,
or `status=` makes the record malformed and `BLOCKED` — never resolved by preferring the first or
last occurrence, which would let a second value be smuggled past a reader who saw only one. This is
a local parse check on a record already fetched; it adds no API call, and because the run is fetched
by exact id there is no such thing as a duplicate *result* to disambiguate.

The approval comment's structured record contains `status=approved`, the PR number,
`head=<40-hex-sha>`, the Actions run URL, and `attempt=<positive-integer>` — the run attempt the
reviewer actually saw. The attempt is what makes a re-run detectable: without an expected value
recorded at approval time there is nothing to compare a later attempt against, and a re-run under
the same run ID would read as the same evidence. The single run lookup already returns `run_attempt`
beside the conclusion, so comparing it to the recorded value costs no extra call. Equality is the
only passing case: equal means the conclusion read belongs to the reviewed attempt; higher means the
run was re-run since approval and the evidence no longer describes what was reviewed; lower is
impossible from a well-formed record, since attempts only increase, and so marks a fabricated or
mistyped one. Any inequality is `BLOCKED`. A record without `attempt` cannot be bound at all.
The comment supplies
locators; the API supplies every trusted identity and outcome. A new commit invalidates final-head
approval and CI evidence until
both cover that head. This gate applies before merge; recording the eventual merge is a separate
shipping record.

GitHub authenticates accounts, not agent roles. Adoption therefore declares one review identity
mode:

- `distinct-account`: configured reviewer accounts must differ from executor and approver
  accounts; compare the API-returned comment author to that allowlist.
- `single-operator`: the same GitHub account may act in multiple roles. Require the structured
  role attestation in the comment, emit a persistent independence warning, and require an explicit
  accepted-risk entry linked from `docs/accepted_risks.md`. This proves accountable attestation,
  not reviewer independence.

No mode infers role identity from comment prose. Missing mode or configuration is `UNVERIFIED`.

One exhaustive rule separates the two failure states, and every check classifies against it rather
than restating it:

- **`UNVERIFIED` — the question could not be answered.** A missing tool, auth failure, network
  error, timeout, malformed or unparseable response, an absent document field, an absent policy
  file, or a field the API did not return. Nothing was disproved; the evidence was unavailable.
- **`BLOCKED` — the question was answered and the answer contradicts the claim.** A resolved
  repository, workflow, SHA, PR, or author mismatch; an unauthorized author; a non-approving
  authoritative verdict for the head under evaluation; an edited structured verdict that is the
  authoritative one for that head; a document
  field that parses but holds an invalid or negated value; a run whose conclusion is not `success`;
  a live run attempt that differs in either direction from the recorded one.

The discriminator is resolution, not severity: if a value was obtained and compared, disagreement
is `BLOCKED`; if no value could be obtained, it is `UNVERIFIED`. Ambiguity that is itself an
observed fact — an authoritative verdict that resolves to something other than `approved` — is a
resolved contradiction and therefore `BLOCKED`, not `UNVERIFIED`. Verdicts against superseded heads
are not ambiguity at all; head-scoped selection discards them before this rule
applies. In strict/check mode both states exit nonzero, so the distinction
governs the printed state and the operator's next action, never whether the gate passes. Every
failure-path test asserts the exact printed state, not merely a nonzero exit.

Existing schema-less documents remain readable in report mode. State precedence is explicit:
documents with any open tracker item are `ACTIVE` and field parsing does not classify them as
`LEGACY`; `LEGACY` is reported only after a fully checked tracker reaches evidence evaluation.
Such a document cannot pass strict evidence verification until its Status block is migrated.

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
`scripts/lib/`. One canonical wrapper list contains `git`, `git-claude`, `git-codex`, and
`git-opencode`; hooks and generated role documentation consume that same list so recognition and
documented commit tools cannot drift. The recognizer handles command boundaries, quoting, escapes,
and Git global options including quoted `-C` paths. It never uses `eval` or executes input.

The recognizer returns structured words for protected invocations. A malformed or unsupported
command that visibly targets a protected operation fails closed with a diagnostic. Benign prose
and searches remain allowed.

For a commit invocation, the hook resolves the actual worktree and index from the parsed Git
arguments *and* from the repository-location environment variables Git honors — `GIT_DIR`,
`GIT_WORK_TREE`, `GIT_INDEX_FILE` — whether written as leading assignments or via `env`. It then
runs both gitleaks and the high-signal staged-diff scan against exactly that repository and index.
A missing repository, an unreadable index, or a repository-affecting variable the recognizer does
not model blocks the commit rather than silently scanning a different index.

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
| Standard | Short one-step Feature brief and one work issue; no parent tracker. | One separate-role review, regression test, `make check`, proportionate broader tests, CI evidence. |
| Strict | Full Feature/Security analysis, tracker, and one sub-issue per independently shippable step. | Separate-role review per step, failure-path test per step, full suite, bound CI and close-out evidence. |

What "separate-role review" proves depends on the configured review identity mode, and the table
deliberately does not promise more than the mode can deliver. Under `distinct-account` it is
independent review: the reviewing account is provably not the executor or approver. Under
`single-operator` it is accountable, risk-accepted attestation by a separate role using one shared
account, which the tooling never reports as independent (`docs/accepted_risks.md`). The profiles
vary how much review ceremony is required; they do not vary how strong the identity proof is —
that is the identity mode's job, and it applies equally to Standard and Strict.

Standard's one work issue uses the existing executor/reviewer label pairs and comment-before-label
handoff. After approval, the reviewer records the reviewed SHA and changes that same issue to
`agent:claude,needs-closing`, leaving it open. The closer verifies final-head approval and CI,
updates/moves the one-step document, and closes the work issue. For Standard only, `Tracking issue`
in v2 identifies this work issue; no parent is created or required. At `--phase close-out` the
lifecycle checker requires its approving review and closing-ready state, not a closed issue; at
`--phase pre-merge`, run after the closer has closed it, it requires that same issue closed. The
two phases differ only in expected issue state — every evidence check is identical.
Strict retains the existing rule that reviewers close steps and only the parent receives
`needs-closing`. Plan approval for Standard is recorded on the work issue, with the approving
human identity and date, using the same evidence discipline as Strict's parent.

F-9 introduces policy and state as preparatory functionality. Standard issue creation and its
handoff activate together in F-10; until then, existing issue generation retains legacy topology.

Close-out has two explicit phases because agents cannot push and a repository commit cannot record
its own SHA:

1. The closer prepares the final Status/Tracker values, changes TRIAGE to Done, and moves the
   document plus index as the last repository change. It commits that close-out candidate and
   hands it to the human for push. The change exists only on the unmerged PR branch and makes no
   verified READY claim yet.
2. CI runs on that PR head and the configured reviewer approves that exact head in GitHub. With no
   later repository change, the closer runs strict lifecycle verification with `--doc` against
   the moved `docs/done/` file and the external PR/review/run evidence, then closes the tracking or
   Standard work issue through GitHub. The human may merge only after verification succeeds.

Any repository edit after approval restarts phase 2. The document stores resolution selectors and
the PR URL; the external GitHub review and run records supply the resolved SHA and outcomes.

Be precise about what that proves. **Neither record is immutable.** The final approval is an
ordinary issue comment, which its author or a repository admin can edit or delete. An Actions run
is no better: a run can be re-run under the same run ID, which replaces its current conclusion, and
runs can be deleted outright — both without any repository edit. A run that verified `success`
today can read `failure`, `cancelled`, or `404` tomorrow, and the `head_sha` the gate matched can
cease to be reachable through that ID.

The gate therefore establishes **point-in-time external evidence** on both sides: at the moment of
verification, an authenticated account had posted a structured approval covering this exact head,
and a run bound to that head, repository, and workflow had concluded `success`. It does not
establish durable retained provenance, and nothing in the tooling may describe either record that
way.

Two consequences follow, and both are requirements rather than caveats:

- **Bind the attempt, not just the run.** The reviewer records `attempt=` in the approval, and the
  single current-run lookup returns `run_attempt` beside the conclusion, so the two are compared
  directly — no attempt-scoped second call, which would exceed the one-Actions-lookup bound
  without proving anything more. Equal attempts mean the conclusion read belongs to the reviewed attempt;
  a higher live attempt means the run was re-run since approval and is detectable as different
  evidence rather than silently replacing what was checked.
- **Verification is only valid at the moment it runs.** Re-check immediately before merge, or rely
  on protected-branch required status checks, which GitHub evaluates at merge time and which are
  the only mechanism here that actually gates the merge. This lifecycle gate authorizes close-out;
  it is not a merge guard and must not be described as one.

Verification output records the comment id, author login, resolved head, run ID, and attempt number,
so a later reader can tell whether the records still exist in the form that was checked.

Closing that residual would need genuinely durable mechanisms — GitHub PR review objects,
protected-branch required reviews and required status checks, signed attestations, or an
append-only audit log — and each is a larger change than this pass. They are out of scope here and
belong in `docs/accepted_risks.md` alongside the `single-operator` entry, recorded as limitations
rather than left implied. Protected-branch configuration remains the human's, and this Feature
neither sets nor substitutes for it.

This makes close-out require a human push and an external review/CI round trip, and the role
contract must say so before execution begins.

Live code and executable tests define existing interfaces. Briefs define intended behavior,
invariants, failure behavior, and inspection routes; they do not freeze private signatures.

## Interface before implementation

### Lifecycle CLI

```text
scripts/lifecycle-status.sh [--check] [--verify-evidence] [--doc <exact-path>]
                           [--phase close-out|pre-merge]

report mode:
  ACTIVE | READY | BLOCKED | UNVERIFIED | LEGACY

exit behavior:
  --check: nonzero for BLOCKED
  --check --verify-evidence: nonzero for BLOCKED, UNVERIFIED, or LEGACY
  --doc: evaluate exactly one Feature/Security document, including a final file already moved
         to docs/done/ for post-push close-out verification
  --phase: which issue state the evidence must show (default close-out)
```

`--phase` exists because the required issue state differs by moment, and one rule cannot serve
both. At **close-out** the work must still be closable: Standard's work issue is open at
`agent:claude,needs-closing`, and Strict's steps are closed with the parent open. At **pre-merge**
the same document is re-verified after the closer has already closed that issue, so requiring a
non-closed issue would make the recheck impossible — the gap that made the manual pre-merge path
undefined. `pre-merge` therefore requires the tracking or work issue to be *closed*, and Strict's
steps to remain closed, while re-verifying every external evidence field — review author, head
SHA,
run, and attempt — against the live PR head exactly as close-out does. Evidence requirements never
relax between phases; only the expected issue state changes. A phase whose issue state does not
match is `BLOCKED`, naming the phase and the state it found, so running the wrong one is a clear
error rather than a silent pass.

### Review and CI policy

```text
.agentic-flow-review-policy
  version=1
  identity-mode=distinct-account | single-operator
  reviewer=<github-login>              # repeatable only in distinct-account mode
  executor=<github-login>              # repeatable
  approver=<github-login>              # repeatable
  workflow=.github/workflows/ci.yml
  accepted-risk=<docs/accepted_risks.md#anchor>  # required only for single-operator

final approval comment
  posted on the issue named by `Tracking issue` (Strict parent tracker / Standard work issue)
  agentic-flow-review: status=approved; pr=<number>; head=<40-hex-sha>;
  run=https://github.com/<owner>/<repo>/actions/runs/<id>; attempt=<positive-integer>;
  role=reviewer

per-step approval comment (Strict only)
  posted on that step's own issue, before the reviewer closes it
  agentic-flow-review: status=approved; step=<step-id>; head=<40-hex-sha>; role=reviewer
```

The policy parser rejects unknown keys, invalid logins/paths, duplicate singular keys, missing
accepted risk in single-operator mode, and overlapping reviewer/executor/approver accounts in
distinct-account mode. It is tracked project configuration and changes require human approval.

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
  file=<sha256-hex>  <installed-relative-path>
  ...one line per installed file, sorted by path...
```

`file=` records exact installed membership, which F-7 needs so an adopter's own files under a shared
manifest directory (`scripts → scripts`) are never mistaken for harness-owned. Its grammar:

- `file=` then a 64-character lowercase hex digest of the installed content, then exactly two
  spaces, then the destination-relative path. One file per line, sorted by path, so the file is
  byte-stable across exports and diffs cleanly.
- Paths are destination-relative and **path-safe**: no leading `/`, no `.` or `..` segment, no
  backslash, no NUL or newline, no control or non-UTF-8 bytes, and no symlink component. A path
  escaping the installation root is a hard failure, never a warning — this record drives file
  selection for gates and later upgrades, so a traversal here would let a manifest reach outside
  the project.
- A path may appear **at most once**; a duplicate `file=` path fails validation naming the path,
  rather than last-one-wins. Two digests for one path means the record was merged or hand-edited
  and cannot be trusted.
- Bounds: at most 2000 `file=` entries and 4096 bytes per line. Exceeding either fails validation
  with an instruction, and the writer never truncates to fit.
- Every `file=` path must fall under a destination declared by a scope present in this same state
  file; an entry outside the active scopes fails validation, so `scope=` and `file=` cannot
  disagree.

Unknown keys, duplicate keys that must be singular, unknown scopes, malformed `file=` lines, and
malformed lines generally fail validation. If installation state is absent, first read and validate
the existing
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
  role_boots, handoffs, validation_groups

per verification run:
  fast_group_count, fast_export_runs, fast_upgrade_runs, path_directory_scans,
  source_snapshot_copies, fixture_tree_copies, fixture_copied_files
```

`source_snapshot_copies` counts immutable snapshots built per process; `fixture_tree_copies` counts
every full-tree materialization including those derived from a snapshot; `fixture_copied_files`
counts individual copy operations. The three are reported together because the first can fall to 1
while the other two are unchanged.

Role ceilings are derived, never chosen: the ceiling for a role is its measured baseline at the
recorded revision rounded up to the next 100 words, with no headroom. The 800-word executor-packet
maximum is an absolute cap and is not derived from measurement.

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
human attribution, and no profile can change branch protection or CI authority. In a
single-operator installation, GitHub account identity cannot establish separation between agent
roles; the accepted-risk record and persistent warning prevent that procedural attestation from
being misreported as independent review.

## Failure behavior

| Operation | Missing/unavailable input | Malformed or ambiguous input | Partial success |
|---|---|---|---|
| Lifecycle status parsing | Missing required v2 field → `BLOCKED`. | Unknown state or duplicate field → `BLOCKED`. | No READY result until every field is valid. |
| Actions evidence lookup | Missing `gh`, auth, network, or run → `UNVERIFIED`; strict verification fails. | Repository/workflow/SHA mismatch → `BLOCKED`. | A successful conclusion with any unbound identity remains blocked. |
| Review evidence lookup | Policy file, comment, or account data the API could not supply, a thread that overflows one page, a listing with no explicit edit indicator, or no verdict at all for the evaluated head → `UNVERIFIED`. | Stale SHA, unauthorized author, an authoritative head-scoped verdict that is not `approved`, an authoritative verdict that has been edited, or invalid identity-mode configuration → `BLOCKED`, the edited case recoverable by posting a fresh verdict or removing the edited comment's marker. Verdicts for superseded heads are discarded, not conflicts; multiple verdicts for one head are resolved latest-wins, not rejected. | Single-operator evidence remains an attestation with a warning; it is never reported as independent. |
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
  lookup — a single bounded comment listing on the `Tracking issue` thread capped at 100 comments,
  carrying `pageInfo`, the opaque `id`, `fullDatabaseId`, `body`, `author`, `createdAt`, and
  `lastEditedAt`, never a
  repository-wide comment search and never a multi-page walk; a thread that does not fit one page
  is `UNVERIFIED` rather than partially checked, as is one whose response carries GraphQL errors or
  any null node — and one Actions-run lookup per document, plus
  bounded step-review lookups — one `comments(first: 100)` query per step thread, each subject to
  the same `hasNextPage` and node-readability fail-closed rules. Every outbound
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
  directly removes repeated work measured in F-12.
- Treating local hooks as a substitute for repository permissions or branch protection.

## Resolved review decisions

- This repository uses `single-operator` review identity initially because its agent roles share
  one GitHub credential. Approval of this Feature accepts documenting that limitation through the
  existing accepted-risk process; F-3 must add the concrete entry before the new gate is enabled.
- `ACTIVE` takes precedence over `LEGACY`; only a fully checked legacy tracker reaches evidence
  migration enforcement.
- Actions identity comes from `repos/{owner}/{repo}/actions/runs/{run_id}`, not the narrower
  `gh run view --json` field set.
- Neither side of the evidence is immutable: the final approval is an editable issue comment, and an
  Actions run can be re-run under the same ID or deleted. The gate therefore proves point-in-time
  external evidence, binds the run attempt, and authorizes close-out rather than guarding the merge;
  protected-branch required checks remain the only merge-time gate. Durable mechanisms (PR review
  objects, required reviews, signed attestations) are out of scope for this pass and are recorded as
  accepted risks in F-3 rather than implied away.
- Listing *completeness* — not approval uniqueness — is what one `comments(first: 100)` GraphQL
  query must prove, via `pageInfo.hasNextPage`, on the tracking thread and on every Strict step
  thread alike. A full page of 100 nodes with `hasNextPage == false` is complete; only a true
  `hasNextPage` or missing pagination metadata fails closed. Multiple verdicts per head are
  expected and resolved by latest-wins selection; a partial listing is what makes that selection
  meaningless. A thread that overflows one page reports
  `UNVERIFIED` and asks for human resolution; the gate never walks unbounded pages and never accepts
  an approval found on a partial prefix. Completeness is necessary but not sufficient: the same
  response must also carry no top-level GraphQL errors and no null node, since `nodes` is typed as a
  nullable list of nullable elements and a skipped null is an unread comment on a listing that would
  otherwise report itself whole.
- The reviewer records `attempt=` in the approval alongside `run=`. Without an expected attempt
  there is nothing a later re-run can be compared against, so an approval lacking it is
  `UNVERIFIED` rather than accepted on the run ID alone.
- Close-out and the pre-merge recheck are distinct phases of one checker, differing only in the
  issue state they expect — open and closing-ready, then closed. Evidence requirements are identical
  in both; the sequence is verify → close → re-verify → merge.
- Inventories that gates depend on are derived from `config/payload.tsv`'s **source tree** and
  asserted complete — never hand-enumerated, never from the filesystem at large, and never by
  walking a destination directory, since shared rows like `scripts → scripts` would absorb adopter
  files. The scaffold derives from its source tree in F-6; adopters get exact recorded installation
  membership in F-7.
- Review verdicts are selected head-scoped, and multiple verdicts per head are expected rather than
  rejected: verdicts for superseded commits are ordinary review history and are discarded, and among
  the verdicts for the evaluated head the highest `fullDatabaseId` — exact creation order, with no
  dependence on second-granularity timestamps, validated as a non-null integer-valued string and
  compared as an exact decimal string by digit count then lexicographic value, never converted to a
  float that would collapse adjacent ids above 2^53 — is authoritative. A `changes requested` → fix → `approved` cycle
  therefore passes, while a later
  `changes requested` supersedes an earlier approval. Edits are detected by GraphQL `lastEditedAt`,
  never by comparing second-granularity timestamps, which cannot see an edit made inside the creation
  second; a listing without an explicit edit indicator is `UNVERIFIED` rather than guessed at. An
  edited record blocks only when it is the authoritative one — an edit cannot be read safely as
  either an approval or a rejection — and is always recoverable by posting a fresh verdict or
  unmarking the edited comment, so an edit costs one comment rather than deadlocking the thread.
  Editing an older comment never changes the outcome; to change a verdict, post a new one.
- Attempt binding costs no extra API call: the single run lookup returns `run_attempt` beside the
  conclusion, so it is compared to the recorded value directly rather than through a second
  attempt-scoped query. Equality is the only passing case — a higher live attempt is a re-run, a
  lower one is a malformed record, and both are `BLOCKED`.
- Role ceilings follow a formula fixed before approval — measured baseline rounded up to the next
  100 words, no headroom — and the measured table needs human sign-off in F-11 before F-12 may
  treat it as a gate. The executor computes those numbers; it does not choose them.

No design question remains for execution. Stop and return to planning only if the named API no
longer exposes repository, workflow path, conclusion, and head SHA, or if a cost budget would
require weakening a universal gate.

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

## Precondition owned outside this tracker

`docs/inprogress/context_optimization.md` is implemented but still awaits independent re-review
and authoritative CI under its existing tracking issue
[#46](https://github.com/wabkebab/agentic-flow/issues/46). That tracker remains the owner; this
Feature does not duplicate its close-out as another issue. Complete its pending review and normal
lifecycle close-out before starting this branch. The two competing assurance proposals remain
owned by F-9, which marks them superseded after this Feature is approved.

## Whole-brief Definition of Done

- Negative or unverified lifecycle text cannot produce READY or a zero strict-verification exit.
- CI evidence is bound to project CI policy, the live PR head, and an authenticated approval of that
  head that satisfies the configured review identity mode: reviewer-account independence under
  `distinct-account`, and risk-accepted accountable attestation — never reported as independent —
  under `single-operator`, which is the mode this repository adopts.
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
- Fast-path cost is measured by actual role bundles and deterministic work counters, with role
  ceilings derived by the fixed formula and the measured baseline human-approved before it gates
  anything. `--fast` excludes export and upgrade behavioral suites while retaining structural and
  critical hook smoke checks, and fixture copying falls on both tree and per-file counters rather
  than on snapshot count alone.
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

## Step F-1 — Parse lifecycle evidence into an exact v2 model

**Why first:** Exact local parsing removes the reproduced false positives and establishes the
model used by remote evidence checks.

**Inspect immediately before editing:**

- `scripts/lifecycle-status.sh`;
- lifecycle fixtures in `scripts/self-test.sh`;
- Feature and Security templates;
- the `--doc` Status writer in `scripts/plan-to-issues.sh` (the `- **Tracking issue:**` and
  `- **Approval:**` rewrite near lines 302–320);
- current active-document fields for migration behavior.

**Approach:**

1. Parse a Status block once into the closed v2 model. Reject duplicate keys, unknown states,
   malformed values, and negative/free-form substitutes.
2. Add v2 fields and resolution selectors to new Feature/Security templates and close-out guidance.
   Preserve schema-less parsing only for migration reports. Add `--doc <exact-path>` so a final
   moved document can be verified after its close-out commit is pushed; default discovery remains
   limited to `docs/inprogress/`.
3. Make state precedence explicit: an open tracker returns `ACTIVE` before evidence schema
   evaluation; `LEGACY` applies only to a fully checked tracker. Add `--phase close-out|pre-merge`
   with `close-out` as the default, carrying only the expected-issue-state difference described in
   Part A; evidence checks are shared by both phases and may not diverge.
4. Count `UNVERIFIED` and `LEGACY` as nonzero under
   `--check --verify-evidence`. Keep offline report mode diagnostic and redact parser/tool errors.
5. **Make `plan-to-issues --apply --doc` write v2, in this same step.** Its Status writer currently
   emits a Markdown link for `Tracking issue` and the prose `<name> approved on <date> via
   plan-to-issues --apply.` for `Approval` — neither parses as v2. Applying an approved plan to a
   v2 template would therefore overwrite that document's own schema with values the new parser
   rejects, so the first document born under v2 would be invalid the moment its tracker closed.
   Emit `url=<tracking-issue-url>` and `status=approved; by=<identity>; at=YYYY-MM-DD`, and leave
   the remaining v2 fields at their template selectors. This must land with the parser, not later:
   any gap between them is a window in which every applied plan corrupts its own Status block.
6. **Validate the document before authenticating or calling `gh`, not when the writer is reached.**
   Today `--doc` is handled only after every issue has been created, edited, and closed
   (`scripts/plan-to-issues.sh:302`), so rejecting a document there would leave the remote already
   mutated and the local record untouched — the worst of both. Move schema detection and writer
   validation into the pre-flight block beside the existing spec validation, before the first
   network call. Pre-flight must check: the document exists and is writable; its schema version is
   one the writer supports; and `--approved-by` matches a v2-safe grammar, since that value is
   interpolated into a `;`-delimited field — reject newlines, `;`, `-->`, and leading/trailing
   whitespace rather than emitting a field that will not parse back.
7. Define legacy-document behavior explicitly instead of leaving it to the writer's discretion: a
   schema-less document is refused with a migration instruction naming the v2 template, and is never
   half-rewritten into a mix of legacy prose and v2 keys. Applying a plan is not a migration path.

**Failure-first test:** “not approved,” “not approved by Codex,” duplicate/missing/unknown v2
fields, a fully checked legacy document, an open legacy document, and unresolved evidence. Assert
the exact printed state and exit status; the open legacy fixture must be ACTIVE. Add phase fixtures:
the same document must pass `--phase close-out` while its issue is open at `needs-closing` and
`--phase pre-merge` once it is closed, and each phase must report `BLOCKED` naming the phase when
run against the other's issue state. Add an
apply-to-v2-document regression: run `plan-to-issues --apply --doc` against a v2 template with
mocked `gh`, then assert the resulting Status block parses clean under the new v2 model and that
the written `Tracking issue` and `Approval` values match the exact v2 grammar. Add rejection cases —
an unrecognized schema version, a schema-less legacy document, a missing or unwritable `--doc`
path, and `--approved-by` values containing a newline, a `;`, or surrounding whitespace — and for
each **assert zero mutating `gh` calls**, proving the refusal happens before authentication rather
than after reconciliation.

**DoD:** Negated or malformed values cannot satisfy v2, strict verification fails unresolved
evidence, active legacy work continues without premature migration failure, a document produced by
`plan-to-issues --apply --doc` is valid v2 by construction, and any document the writer will not
accept is refused before the first `gh` call with nothing created or edited.

**Commit:** `Parse lifecycle evidence into an exact model`

**Focused verification:** `make test-one F=lifecycle`

---

## Step F-2 — Bind Actions evidence to repository, workflow, and PR head

**Why second:** A syntactically valid run URL proves nothing until it is tied to project policy and
the work under review.

**Inspect immediately before editing:** lifecycle verification, adoption CI policy, PR/run mocks,
remote-origin handling, and CI templates.

**Approach:**

1. **Create the CI half of `.agentic-flow-review-policy` in this step**, since F-2's own DoD depends
   on an authoritative expected workflow and no policy file exists yet. Add the file with `version`
   and `workflow`, its parser, its validation (unknown keys, duplicate singular keys, invalid
   workflow path), adoption/export/doctor wiring, and this repository's own `workflow=
   .github/workflows/ci.yml`. Accept and ignore identity keys so F-3 can add them without a format
   break; a missing policy file is `UNVERIFIED`, never a silent default. F-3 adds `identity-mode`,
   the account lists, `accepted-risk`, and all identity enforcement.
2. Resolve the expected repository from the configured origin, expected workflow from that policy,
   and current head from `Implementation PR`.
3. Query `repos/{owner}/{repo}/actions/runs/{run_id}` with a 30-second deadline and no implicit
   retries. Compare `repository.full_name`, workflow `path`, `head_sha`, and `conclusion`, and
   compare its `run_attempt` against the `attempt=` value recorded in the approval comment. **One
   lookup does both jobs**: the current-run object carries `run_attempt` alongside `conclusion`,
   `head_sha`, `path`, and `repository.full_name`, so if the live `run_attempt` equals the recorded
   one, the conclusion just read *is* the reviewed attempt's and no attempt-scoped second call is
   needed. **Equality is the sole passing case; any inequality is `BLOCKED`.** A higher live attempt
   means the run was re-run since approval and the evidence no longer describes what was reviewed. A
   *lower* live attempt is impossible from a well-formed record — attempts only increase — so it
   means the recorded value was fabricated, mistyped, or copied from another run; treat it as a
   malformed record and block rather than passing it as "not a re-run." Do not add an attempt-scoped
   lookup on top of the run lookup — it would exceed the one-Actions-lookup bound for no added
   proof. An approval record with no `attempt=` field cannot be bound and is `UNVERIFIED`, not
   accepted on the run ID alone. A deleted or unreachable run is `UNVERIFIED`; a conclusion that is
   not `success` is `BLOCKED`.
4. Obtain the run locator from the structured final approval comment on the `Tracking issue`
   thread, selected by `source=pr-head-approval` under Part A's head-scoped selection rule: discard
   verdicts for superseded heads, take the remaining verdict for the PR head with the highest
   `fullDatabaseId` (validated non-null, compared as an exact decimal string), and reject it if
   `lastEditedAt`
   shows that authoritative record has been edited. Verify its run through the
   Actions-run endpoint. Reject a head with no surviving approval; print the selected comment id,
   the resolved run URL, and the full SHA.
5. At this step the comment is an **untrusted locator only**: it names which run to fetch, and
   nothing it asserts is believed. Author identity, role attestation, and the identity-mode rules
   arrive in F-3, so F-2 must not report a verdict as reviewed or independent.

   **A warning is not enough; the state itself must be capped.** Part A classifies review evidence
   the checker cannot resolve as `UNVERIFIED`, and through the whole F-2 window there is no identity
   configuration to resolve it against — F-2 deliberately accepts and ignores those policy keys so
   F-3 can add them. So F-2's review-evidence component is **`UNVERIFIED` by construction**:
   `READY` is unreachable, and `--check --verify-evidence` therefore exits nonzero under the
   existing CLI contract, which already makes `UNVERIFIED` a nonzero exit. No new exit rule is
   needed — what was missing was saying which state F-2 reports. A resolved CI mismatch still
   reports `BLOCKED`, which outranks the cap; the cap only forbids passing.

   This is not a limitation to work around. F-2's product is the CI binding — a run proved to match
   repository, workflow, head, and attempt — with the approval reduced to an unauthenticated pointer
   at that run. An F-2 that reported `READY` would mean any account able to comment on the tracker
   could name a passing run and clear the gate, which is precisely the hole F-3 closes. The output
   says the approval is unauthenticated pending F-3 *and* names that as the reason for the state.
   Every trusted value still comes from the API.
6. Classify unavailable API/tool/network data as UNVERIFIED and resolved mismatches as BLOCKED,
   per the exhaustive rule in Part A. Never accept workflow or repository identity supplied only by
   the Feature document.

**Failure-first test:** Wrong repository, workflow, SHA, failed run, unavailable API, a verdict
record carrying two `run=` fields or two `attempt=` fields (malformed — reject without a second
lookup; a single `actions/runs/{run_id}` fetch cannot return duplicates, so there is no
duplicate-run search to perform), a copied unrelated successful run, a re-run that changed the
conclusion under the
same run ID, an approval record missing `attempt=` entirely, a live `run_attempt` advanced past the
recorded one, a recorded attempt *higher* than the live one (a malformed or fabricated record), and
a deleted run. Assert the printed state for each — a missing `attempt=` or an unreachable run is
`UNVERIFIED`, while any attempt inequality in either direction and any non-`success` conclusion is
`BLOCKED` —
and assert exactly one Actions API call per document across all of them, so the attempt comparison
never smuggles in a second lookup.
Add a correctly formed final approval posted
on the PR conversation and another on a step issue instead of the `Tracking issue` thread: both
must fail to satisfy the gate. Add pagination regressions: a thread returning exactly 100 comments,
with `hasNextPage: true`, and one whose response omits `pageInfo` entirely — both must report
`UNVERIFIED` rather than accepting an approval found on the first page, including the case where
that first page holds a valid-looking approval. Add the **inverse** case, which the REST heuristic
got wrong: exactly 100 nodes with `hasNextPage: false` must be treated as a *complete* listing and
pass, since node count carries no completeness information in GraphQL. Add **node-readability**
regressions, which `hasNextPage` alone does not cover: a response carrying a non-empty top-level
`errors` array beside usable-looking `data`, one whose `nodes` is null, and one whose `nodes`
contains a null entry beside an otherwise valid approval — all three `UNVERIFIED`, the last naming
the null entry's index, and none of them accepted from a listing silently filtered down to its
non-null members. Add ordering-key cases: a
verdict with a null `fullDatabaseId` must be `UNVERIFIED` naming the comment by its opaque `id`; a
thread whose ids order differently as raw strings than by digit count (`"9"` versus `"10"`) must
select the larger; and a thread whose two ids are **adjacent above 2^53** — `"9007199254740993"`
and `"9007199254740992"`, a pair no double can tell apart — presented newest-first, so listing
order cannot stand in for the comparison, must still select the higher. Include one exact match and assert one bounded Actions-run lookup per selected run and
exactly one `comments(first: 100)` query on the tracking thread.
Add the **no-premature-READY** regression, which is what stops this step from shipping the hole it
exists to narrow: a fully correct fixture — matching repository, workflow, and head, a `success`
conclusion, an exactly equal live attempt, and a well-formed approval on the tracking thread — must
still print `UNVERIFIED` and exit nonzero under `--check --verify-evidence`, naming the
unauthenticated approval as the reason. Assert no F-2 fixture reaches `READY` at all, and that the
same fixture with a resolved CI mismatch prints `BLOCKED` rather than `UNVERIFIED`, proving the cap
forbids passing without masking a resolved failure.

**Stop if:** The named endpoint no longer exposes repository, workflow path, conclusion, and head
SHA. Return to planning rather than falling back to conclusion-only.

**DoD:** Strict verification accepts CI only when project policy, PR head, and the Actions run agree
and the live run attempt equals the recorded one exactly; the final approval is read from the
`Tracking issue` thread alone and is refused
when the thread cannot be listed completely within one page; and review evidence stays `UNVERIFIED`
until F-3 lands, so `READY` is unreachable and `--check --verify-evidence` exits nonzero even on a
perfectly bound run, with the output naming the unauthenticated approval as the reason.

**Commit:** `Bind CI evidence to the implementation head`

**Focused verification:** `make test-one F=lifecycle`

---

## Step F-3 — Verify review provenance and define close-out sequencing

**Why third:** GitHub can authenticate the account that attests to a review; the contract must
state precisely when that establishes independence and when it does not.

**Inspect immediately before editing:** lifecycle/review fixtures, adoption configuration,
`CLAUDE.md`, `METHODOLOGY.md`, root/template role state machines, review skill/agent/command,
accepted-risk template/register, and step-issue stamps.

**Approach:**

1. Implement the two review identity modes in Part A. In `distinct-account`, validate the
   API-returned author against the reviewer allowlist and against executor/approver accounts. In
   `single-operator`, validate accountable role attestation, emit the persistent warning, and
   require the linked accepted-risk entry. Do not describe single-operator mode as independent.
2. Validate the structured final approval — still read only from the `Tracking issue` thread — against
   the live PR number and full head SHA, and lift F-2's `UNVERIFIED` cap — retiring both the
   "unauthenticated pending F-3" reporting and the state it forced — now that provenance is
   checked, so review evidence can reach a passing state for the first time. For Strict, validate every bounded stamped step as closed with an
   approving review on that step's own issue covering its implementation commit, reading each step
   thread with the same one-page completeness rule and the same head-scoped selection rule as the
   tracker — verdicts against superseded commits are normal history and must never be treated as
   conflicts, and an edited record blocks only when it is the authoritative one, detected by
   `lastEditedAt` rather than timestamp comparison, with the same fresh-verdict recovery path.
   Classify strictly
   by Part A's exhaustive rule: authorship or evidence the API could not supply is UNVERIFIED, while
   a resolved contradiction — an unauthorized author, an author differing from the comment's claim,
   an authoritative head-scoped verdict that is not `approved`, or a stale SHA — is BLOCKED. Do
   not report an observed conflict as merely unverified.
3. Put the two-phase close-out sequence from Part A into planner, reviewer, templates, and lifecycle
   guidance. The preparatory document move/index commit is the last repository change; after human
   push, CI and review approve that exact head; then the closer verifies the moved document with
   `--doc` and closes the GitHub tracker without another repository edit. State in that contract
   that verification is point-in-time: it authorizes close-out at the moment it runs and is not a
   merge guard. The human re-runs it immediately before merge with `--phase pre-merge`, or relies on
   protected-branch required status checks, which are what GitHub actually evaluates at merge time.
   Define that sequence concretely so the recheck has a defined path: verify at `--phase close-out`
   → close the issue → re-verify the same document at `--phase pre-merge`, which expects the issue
   closed → merge. Without the phase distinction the recheck would demand a non-closed issue that
   close-out has just closed, and could never pass.
4. State the posting location **and the exact record fields** in the reviewer-facing contract —
   review skill, `code-reviewer.md`, `/review`, and the role state machines — so the side that
   writes the approval and the side that reads it agree. Final approvals go on the `Tracking issue`
   and must carry `attempt=` alongside `run=`; per-step approvals go on their own step issue. A
   checker that searches one thread while the contract tells reviewers to post on another, or that
   requires a field reviewers were never told to write, is the failure this step exists to prevent.
   Give reviewers a copyable template so the attempt number is recorded as a matter of course, and
   state plainly that a verdict is changed by posting a new comment, never by editing an old one —
   an edit to a superseded comment is ignored, and an edit to the authoritative one blocks until a
   fresh verdict is posted.
5. Add this repository's single-operator accepted-risk entry as part of this commit and link it from
   the adopted review-identity configuration. Record the mutable-comment limitation from Part A in
   the same register, alongside the re-runnable/deletable-run limitation: the gate proves
   point-in-time external evidence on both sides, not durable provenance. Verification output must
   carry the comment's opaque `id`, author login, resolved head, run ID, and attempt number, and no
message may
   call either the review record or the run immutable, permanent, or a merge guard.

**Failure-first test:** Unauthorized and ambiguous authors, claimed identity differing from API
author, missing accepted risk, open/unreviewed Strict step, stale review after a new PR commit, and
both configured identity modes. Assert F-2's unauthenticated-approval reporting is gone and that a
correctly authored approval on the wrong thread still fails. Re-run F-2's no-premature-READY fixture
with identity configured and an authorized author: it must now reach `READY` with a zero strict
exit, proving F-3 lifts the `UNVERIFIED` cap rather than inheriting it. Assert the exact printed state for each
case against Part A's rule — in particular that a later `changes requested` superseding an earlier
`approved` on the same head prints `BLOCKED`, while an API that cannot return the author prints
`UNVERIFIED`. Add per-step pagination
regressions mirroring the tracker's: a step thread signalling `hasNextPage: true` and one missing
`pageInfo`, both `UNVERIFIED` naming the step, with no approval accepted from a partial prefix; and
a step thread of exactly 100 nodes with `hasNextPage: false`, which must pass as complete. Mirror
F-2's node-readability cases per step as well: a step response carrying a top-level `errors` array,
and one with a null node beside a valid approval, must each be `UNVERIFIED` naming the step rather
than a verdict parsed from the readable remainder.
Add head-scoping regressions on both thread kinds: a normal `changes requested` at an old head
followed by `approved` at the current head must pass, proving ordinary review history is not read as
conflict; `approved` at an old head with nothing at the current head must not pass; and `approved`
then a later `changes requested` at the same head must be `BLOCKED`, proving last-posted-wins
ordering.
Add **same-second** regressions, which are what the timestamp model got wrong: `approved` and
`changes requested` sharing one `created_at` at the same head with the rejection carrying the higher
`fullDatabaseId` (must be `BLOCKED`, proving id ordering decides and timestamps are not consulted);
and an
authoritative verdict edited *within its creation second*, so `created_at == updated_at` while
`lastEditedAt` is non-null (must be `BLOCKED`, proving edits are detected by the explicit field and
not by comparing timestamps — under the old heuristic this case passed silently).
Add **edited-verdict** regressions: an older `approved` edited into `changes requested` for the
current head after a newer `approved` must **pass** on the newer approval, proving a retroactive
edit to a superseded comment cannot reorder history; and the authoritative verdict itself edited
must be `BLOCKED` naming its comment id. Add **missing-field** regressions: a listing that cannot
supply `lastEditedAt` must be `UNVERIFIED` naming the field, never silently falling back to a
timestamp comparison; and one whose authoritative verdict has a null `fullDatabaseId` must be
`UNVERIFIED` naming the comment by its opaque `id`, never falling back to listing order. Mirror the
**adjacent-ids-above-2^53** case on a step thread, reverse-ordered in the listing, to prove step
selection compares decimal strings rather than floats there too. Add the two **recovery**
regressions, which are what keep that block from
being permanent: from the blocked state, (a) posting a fresh unedited verdict must resolve it —
`approved` yields the passing state, `changes requested` yields `BLOCKED` on the verdict rather than
on the edit — and (b) removing the structured marker from the edited comment must resolve it by
dropping that record from the listing entirely. Assert the selected comment id and its edit state are
printed, and that rejected-as-edited records are named separately from discarded-as-superseded
ones. Assert a final approval lacking `attempt=` is refused.
Model the close-out
sequence and assert any repository edit after approval invalidates readiness.

**DoD:** Review evidence is bound to the PR head and authenticated account; verdict order comes from
a `fullDatabaseId` validated non-null and compared as an exact decimal string — never as a float —
and edit state from `lastEditedAt`, never from
second-granularity timestamps, with a null ordering key or missing edit indicator failing closed;
thread completeness is decided by `pageInfo.hasNextPage` rather than node count, and a complete
listing is still refused if it carries GraphQL errors or any null node; an edited
authoritative record blocks but is always recoverable
by a fresh verdict or by unmarking the edited comment; the tool states the single-operator limitation
honestly; close-out has no self-invalidating document update.

**Commit:** `Verify review provenance before lifecycle close-out`

**Focused verification:** `make test-one F=lifecycle` and `make test-one F=contracts`

---

## Step F-4 — Make plan identities exact and preserve live workflow labels

**Why fourth:** Issue reconciliation is the harness's remote mutation boundary. It must be
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
6. Leave F-1's v2 Status writer intact. This step changes how issues are identified, not what the
   `--doc` writer emits; keep its regression test passing unchanged.

**Failure-first test:** Add fixtures for explicit `step-1` plus implicit first step, `step-1` versus
`step-10`, duplicate remote stamps, a full 100-result page, reviewer labels on reapply, and a clean
idempotent reapply. Assert zero mutating `gh` calls for every validation/ambiguity failure, and
re-run F-1's apply-to-v2-document regression against the rewritten reconciliation path.

**DoD:** One normalized ID maps to at most one exact issue; collision and ambiguity are errors;
reapply cannot regress a step's workflow state.

**Commit:** `Make plan reconciliation identity exact`

**Focused verification:** `make test-one F=plan-to-issues`

---

## Step F-5 — Parse protected Git commands and scan the invoked repository

**Why fifth:** The secret and no-push hooks guard irreversible boundaries and currently share the
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
   Git global options, and `gh pr merge`. Define `git`, `git-claude`, `git-codex`, and
   `git-opencode` in one canonical wrapper list consumed by hooks and generated role docs.
2. Route push/merge blocking and commit detection through it. Reuse it in other command hooks only
   where it removes a demonstrated duplicate parser; do not broaden this into a shell interpreter.
3. Resolve the commit invocation's repository and index from its parsed working-directory/global
   arguments. Run gitleaks and staged-diff patterns with explicit argument arrays in that context.
4. **Arguments are not the only way to move the index.** Git also takes its repository location from
   the environment — `GIT_DIR`, `GIT_WORK_TREE`, and `GIT_INDEX_FILE` — and those can be set as
   leading `VAR=value` assignments or through `env`, so `GIT_INDEX_FILE=/tmp/other git commit`
   commits an index the scanner never reads. The recognizer must therefore tokenize leading
   assignments and `env` invocations ahead of the command word, and the hook must either propagate
   all three into the scan context so it reads exactly the index the commit will use, or fail closed
   with a diagnostic naming the variable. Propagation is preferred; silently scanning the default
   index while the commit uses another is the defect this step exists to remove. Treat any
   repository-affecting variable the recognizer does not model as fail-closed, so a future Git
   variable degrades to a block rather than a bypass.
5. Fail closed when a protected operation is recognizable but parsing, repository resolution, or a
   required scan fails. Preserve the documented intentional false-positive override for scanning.
6. Keep diagnostics value-free: print command shape, repository path, and variable names — never
   staged secret text and never an environment value.

**Failure-first test:** Cover `git push;`, quoted and escaped `git -C` paths, all four wrappers,
multiple shell commands, malformed quotes around a protected command, benign searches mentioning
the rule, and a commit directed at another repository containing a staged synthetic secret. Add one
case per repository-location variable — `GIT_DIR=… git commit`, `GIT_WORK_TREE=… git commit`,
`GIT_INDEX_FILE=… git commit` — plus `env GIT_INDEX_FILE=… git commit` and a combination of two,
each staging a synthetic secret in the redirected index: every one must block, and none may report
clean by scanning the default index. Assert exit 2 for blocks and prove both scanning layers run
against the target repository and index.

**Stop if:** Reliable recognition would require executing or `eval`-ing user input, or adding a new
runtime dependency to exported hooks. Keep the guard conservative and return to design.

**DoD:** Ordinary protected command forms cannot bypass the hooks, benign prose remains allowed,
and cross-repository commits scan the correct index — including when the repository, work tree, or
index is redirected by environment assignment rather than by argument.

**Commit:** `Parse protected Git commands before enforcing hooks`

**Focused verification:** `make test-one F=hooks`

---

## Step F-6 — Remove false-green build, hook-test, and static-analysis paths

**Why sixth:** The remaining local gates must report their own failures accurately before they are
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
3. **Derive** the shipped shell inventory; do not enumerate it. A hand-maintained list shared by both
   gates is still a list someone can forget to extend — the same omission that left
   `scripts/agentic-flow` unchecked, merely relocated.
4. Derive it from **`config/payload.tsv`, not the filesystem at large**. This Makefile is exported
   into adopter repositories, so "every tracked file with a shell shebang" would put the adopter's
   own scripts under the harness's syntax and ShellCheck gates — the harness silently taking
   ownership of code it does not own, and failing their build on their style.
5. Derive membership from the **source-side manifest tree**, never by enumerating a destination
   directory. `payload_destination_files()` is not the helper to reuse as-is: at
   `scripts/lib/payload-apply.sh:91` it walks `$root/$destination` with `find` whenever that
   directory exists, so for a shared row like `scripts → scripts` it returns every file the adopter
   has put under `scripts/` — exactly the over-capture this step must avoid. Instead walk the
   manifest's *source* trees, honoring `source-only` rows and excluded scopes, and map each relative
   path onto its declared destination. That set is the harness's own file list by construction and
   cannot absorb a neighbouring adopter file. Then keep the members that exist locally and begin
   with a shell shebang. In this repo that selects the nineteen mode-`100755` scripts plus
   `scripts/lib/*.sh` — mode 644, sourced, still needing a parse — which a `*.sh` glob misses at the
   extensionless CLI and a mode-only rule misses at the libraries.
6. The source tree exists in this scaffold but not in an adopter, so scope this step to the
   scaffold's own gate and leave the exported Makefile on its current explicit globs, marked for
   F-7. F-7 already records installation state; extend it to record **exact installed file
   membership**, and switch the exported gate to that record there. Do not guess adopter membership
   from a directory walk in the meantime — a conservative explicit list is wrong-but-bounded, while
   a destination walk is wrong-and-expanding. Use one helper for both scaffold gates, deduplicating
   paths already covered by a directory row.
7. Add a completeness assertion so derivation cannot silently regress: independently recompute the
   manifest-derived shell set and fail if any member is absent from the checked inventory. Sharing
   one list between two gates proves they agree, not that either is complete; only a check against
   the manifest proves that.
8. Resolve real ShellCheck findings in the executable or add the narrowest justified directive;
   do not skip the file or globally suppress warning classes.
9. Mirror behavior changes into the exported Makefile by the existing paired edit. Mark the exact
   shared block so F-8 adopts and verifies it as a generated region.

**Failure-first test:** Add a hook stub exiting 1, an export stub exiting 1 followed by a successful
echo, and an intentional syntax/ShellCheck defect in an isolated copy of `scripts/agentic-flow`.
Each must make its owning gate fail for the intended reason. Add a **new manifest-declared
extensionless executable** carrying a shell shebang and a deliberate syntax error: both `bash -n`
and ShellCheck must pick it up with no edit to any inventory, and the completeness assertion must
fail if the derivation is narrowed to miss it. In the same fixture add an **adopter-owned**
`scripts/their-deploy.sh` — placed under the shared `scripts` manifest row, absent from the source
tree, containing both a syntax error and ShellCheck findings: neither gate may report it. That file
is the direct regression against a destination-directory walk, which would capture it; assert it
stays out even though its parent directory is manifest-declared.

**DoD:** Tests distinguish a policy block from a crash; build cannot mask export failure; and every
shipped shell entry point in this scaffold is parsed and statically analyzed because the inventory
is derived from the manifest's source tree and asserted complete — a newly added harness executable
is covered without anyone remembering to list it, and a file an adopter places under a shared
manifest directory is never swept in. The exported Makefile's inventory moves to recorded
installation membership in F-7.

**Commit:** `Make local harness gates fail for the right reason`

**Focused verification:** `make test-one F=hooks` and `make test-one F=contracts`

---

## Step F-7 — Make exported validation consume the selected adapter scope

**Why seventh:** Export scope already controls copied files; validation must describe that same
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
6. Record **exact installed file membership** in installation state, not just scopes, using the
   `file=<sha256>  <path>` grammar, validation, bounds, duplicate handling, and path-safety rules
   defined in Part A's interface — the state parser rejects unknown keys, so this representation has
   to be part of the format rather than added ad hoc. Switch the exported Makefile's shell inventory
   to it (deferred here from F-6, whose source-side derivation works only in the scaffold).
   Membership comes from the applied source tree at export time; a destination-directory walk must
   not be used, since shared rows like `scripts → scripts` would absorb adopter-owned files. Write
   entries sorted by path so the record is byte-stable, and add a doctor check that flags membership
   drift — a recorded file missing, or its digest changed — without treating unrecorded adopter
   files as drift.
7. Update `docs/memory/manifest-validation-duplicated.md` and its index line to record the durable
   compatibility trap: the column is validated but not applied, and removal requires a versioned
   old-upgrader migration.

**Failure-first test:** Cover the `file=` grammar directly: a malformed digest, a wrong-length
digest, a duplicate path, a path with a `..` segment, an absolute path, a symlinked component, an
entry outside the recorded scopes, and an over-bound entry count — each must fail validation naming
the offending line, with no state advanced. Assert a recorded membership set omits an adopter file
placed under a shared manifest directory, that entries are written sorted and byte-stable across two
exports, and that doctor reports a changed digest as drift while ignoring unrecorded adopter files.
A Claude-only fixture and at least one other excluded-scope fixture must pass
their applicable checks, fail when an active-scope file is missing, and ignore parity requirements
for inactive adapters. Malformed installation state and unknown manifest scopes fail before copy or
upgrade mutation. Start an upgrade using an unmodified pre-change installed CLI and payload library
against the new source; test default and Claude-only installations, including pending candidates.
Assert excluded adapters stay excluded, the old parser accepts the manifest, and installation
state advances only when the payload is applied successfully.

**DoD:** Export, doctor, upgrade, and tests derive one adapter surface from manifest plus recorded
scope and exact file membership, so an adopter's own files under shared directories are never
treated as harness-owned; existing upgraders remain compatible and the retained deprecated column
is documented accurately rather than presented as executable per-file policy.

**Commit:** `Align exported validation with active adapter scopes`

**Focused verification:** `make test-one F=export` and `make test-one F=contracts`

---

## Step F-8 — Generate shared contracts and converge review terminology

**Why eighth:** With trustworthy gates and scope-aware consumers, duplication can be removed without
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
   Include the root/template Makefile block marked in F-6; its paired hand-edit must become
   byte-covered by a generated region before this step is complete.
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

## Step F-9 — Define assurance policy and persist the project baseline

**Why ninth:** Policy and validated state are prerequisites for changing issue topology.

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
4. Keep issue generation on its existing topology until F-10. Clearly document this transition.
   Mark the competing proposals superseded by this approved brief without deleting their history.

**Failure-first test:** Invalid state, malformed audit metadata, unaudited downgrade, and upgrade
over a customized baseline. Test a successful raise and attributed downgrade. Assert no CI
workflow uses assurance state to reduce required checks.

**DoD:** Policy has one canonical home; baseline changes are validated and auditable; existing
issue workflows remain operational pending F-10.

**Commit:** `Define assurance policy and persist project baselines`

**Focused verification:** `make test-one F=contracts`, `make test-one F=export`, and
`make test-one F=upgrade`.

---

## Step F-10 — Implement Standard issue topology and complete close-out

**Why tenth:** Activate issue creation, handoff, and closure together so no new issue shape is
introduced without a path through review and close-out.

**Inspect:** Normalized plan parser, plan-to-issues adapters, lifecycle checker,
`scripts/hooks/require-step-comment.sh`, Feature/Security templates, `METHODOLOGY.md` §6,
root/template role state machines, `.opencode/agent/code-reviewer.md`,
`.opencode/command/review.md`, and both review-skill adapters.

**Approach:**

1. Add explicit profile validation before GitHub calls. Standard requires exactly one step and
   creates one work issue; Strict retains parent plus steps; absent profile retains legacy
   topology. Reject per-brief downgrades below the project baseline.
2. Define Standard identity as the existing exact plan/step stamp for its sole step. Store approval
   metadata there. Reapply preserves its live labels; changing an existing plan's topology is
   rejected with a migration-required diagnostic, without creating or closing issues.
3. Implement Part A's Standard handoff: reviewer approval leaves the work issue open with
   `agent:claude,needs-closing`; closer records final-head evidence and closes it. Update the
   handoff hook and every review/state-machine statement in the same commit. Add a
   comment-before-`needs-closing` branch to `require-step-comment.sh`; Standard's approval handoff
   must be gated like implementation and findings handoffs. Replace the universal “step issues
   never reach needs-closing” claim with a topology-aware invariant: Strict sub-issues close on
   review, while Standard's sole work issue reaches needs-closing and remains open for close-out.
4. Make lifecycle validation interpret Standard's `Tracking issue` as the work issue. Verify
   approval and review evidence without requiring a nonexistent parent, honoring `--phase`: an open
   `needs-closing` work issue at `close-out`, that same issue closed at `pre-merge`. Exercise the
   full verify → close → re-verify → merge sequence so the post-close recheck has a tested path.
5. Emit the bounded executor packet described in Part A from explicit spec fields, with documented
   required fields and a maximum of 800 words. Reject overflow instead of truncating requirements.
   Update both the spec contract and adapters so required packet data has a defined input source.

**Failure-first test:** Standard with zero/two steps, Strict without a parent specification,
downgrade below baseline, topology-changing reapply, missing review, stale final-head evidence,
and packet overflow. Exercise a full mocked Standard create → execute → review → close-out
sequence including the post-close `--phase pre-merge` recheck; assert one issue only, the required
approving comment before needs-closing, and no premature closure. Exercise legacy and Strict flows
and assert their issue-state rules remain unchanged.

**DoD:** Standard is usable through closure; exact identity, approval evidence, labels, and
idempotence hold for each supported topology.

**Commit:** `Support Standard issues through review and close-out`

**Focused verification:** `make test-one F=plan-to-issues`, `make test-one F=lifecycle`,
`make test-one F=hooks`, and `make test-one F=contracts`.

---

## Step F-11 — Measure role context and workflow costs

**Why eleventh:** Establish repeatable measurements before changing suite setup and dispatch.

**Inspect:** Role read sets, generated contracts/packets, self-test dispatch and fixture setup,
README/ADOPTION, and this document's acceptance criteria.

**Approach:**

1. Add the offline text/JSON measurement interface in Part A. List actual bundle files by role;
   count shared files once per load scenario and packet words separately.
2. Distinguish measured words and executed work counters from modeled role boots/handoffs.
   Fix the representative scenarios and record the checkout revision and commands.
3. Record baseline fast/full group dispatch and fixture-copy counts for F-12. Emit the named
   counters `fast_group_count`, `fast_export_runs`, `fast_upgrade_runs`, `source_snapshot_copies`,
   `path_directory_scans`, and — so a reduction in snapshots cannot hide unchanged copying —
   `fixture_tree_copies` (every full-tree materialization, snapshot or derived) and
   `fixture_copied_files` (total per-file copy operations across all fixtures).
4. Derive role ceilings by a formula fixed here, not by executor judgement: **ceiling = the measured
   baseline at the recorded revision, rounded up to the next 100 words, with no added headroom.**
   The executor computes and records; it does not choose. Retain the 800-word packet maximum from
   F-10 as an absolute cap independent of measurement — a measured baseline above it is a finding,
   not a new ceiling.
5. Record the resulting table in this document and **stop for human approval of those numbers before
   they become gates.** Until a human confirms the recorded table, F-11 emits measurements and
   F-12 may not cite them as thresholds. This is the checkpoint that keeps the acceptance bar from
   being self-selected after approval; note it in the Tracker entry when F-11 is executed.
6. Record results in this document; do not add timing assertions or claim provider token telemetry.

**Failure-first test:** Missing bundle input, invalid output format, a fixture exceeding a role
ceiling, duplicate shared-file counting, and a packet exceeding the absolute 800-word cap. Assert
deterministic output for unchanged inputs, and that `fixture_tree_copies` and
`fixture_copied_files` both move when a fixture is added, so neither can be satisfied by reducing
snapshots alone.

**DoD:** A reproducible baseline exists, every ceiling follows the fixed formula rather than a
chosen value, the measured numbers are human-approved before F-12 treats them as gates, and
measurement does not change test dispatch or workflow behavior.

**Commit:** `Measure harness context and verification work`

**Focused verification:** `make test-one F=contracts`.

### F-11 measured baseline — approved 2026-09-26

Recorded source revision: `987c58b01b3121f2e1c093392a628f9834d5a429` (completed F-10),
with the F-11 reporter and this document still untracked at measurement time. Re-run offline
from the F-11 checkout with `scripts/measure-harness.sh --format json`; the command runs the
fast and full self-test modes and reports completed work events. The reconciliation below
explains the counters that change after the measurement checkout. Word counts use `wc -w`
on each listed startup file once per role load. Generated packet
words come from the Standard issue fixture produced in the plan-to-issues group. Modelled
workflow counts are separate from measured words and executed work. No provider token counts,
cache behavior, or timing is inferred.

| Role | Startup files | Static words | Formula | Ceiling | Packet words |
|---|---|---:|---|---:|---:|
| Planner | `CLAUDE.md`, `docs/MEMORY.md` | 1,692 | `ceil(1692 / 100) × 100` | 1,700 | 0 |
| Executor | `AGENTS.md`, `CLAUDE.md`, `docs/MEMORY.md` | 2,780 | `ceil(2780 / 100) × 100` | 2,800 | 37 |
| Reviewer | `CLAUDE.md`, `.agents/skills/review-execution/SKILL.md`, `docs/MEMORY.md` | 2,691 | `ceil(2691 / 100) × 100` | 2,700 | 0 |

The executor packet remains subject to the independent 800-word absolute maximum.
The example Standard step models three role boots, two handoffs, and two validation groups;
the example Strict step models three role boots, two handoffs, and three validation groups.
Those workflow numbers describe a representative sequence; they are not observed agent activity.

| Run | Groups | Export group | Upgrade group | Source snapshots | PATH directory scans | Fixture trees | Copied files |
|---|---:|---:|---:|---:|---:|---:|---:|
| Fast | 5 | 0 | 1 | 0 | 25 | 1 | 67 |
| Full | 6 | 1 | 1 | 2 | 251 | 3 | 595 |

The full and fast event totals include fixture work performed by nested self-test probes.
`fixture_tree_copies` includes the two full source snapshots and recursive fixture copies;
`fixture_copied_files` counts each completed file copy, including files copied in those trees.
`path_directory_scans` depends on the number of existing directories in the invoking shell's
`PATH`; 25/251 reflects the measurement shell, while the reviewer reproduced 24/241 with a
different `PATH`. In the committed F-11 checkout this document is tracked and enters both full
source snapshots (+2 copied files). Correcting multi-source `cp` accounting after review adds
one fast and ten full copied files across nested test runs, so the corrected reporter yields
68 fast and 607 full copied files on the measurement shell's `PATH`.
The user approved this measured table and its formula-derived ceilings on 2026-09-26 in the
F-11 execution conversation. The approved table above, rather than a fresh report from a
different checkout or `PATH`, is the authoritative F-12 threshold baseline. Since copy counters
are integers, F-12's at-most-half limits are fast trees 0/files 33 and full trees 1/files 297.

---

## Step F-12 — Reduce fast-check and fixture setup costs

**Why twelfth:** Optimize against F-11's measurements while retaining the corrected gates.

**Inspect:** Self-test mode/group dispatch, adoption fixtures, `path_without_tools()`, Makefile,
CI, and F-11 measurement output.

**Approach:**

1. Define the fast-mode inventory explicitly: structural/contract checks and a named critical hook
   smoke set. Keep every behavioral regression in full mode and its focused group. Export and
   upgrade behavior must not run in fast mode.
2. Reuse one immutable source snapshot per process; derive mutable fixture copies from it so
   adversarial tests cannot contaminate later cases.
3. Replace whole-PATH enumeration with a declared minimal tool set, preserving missing-tool tests.
4. Compare the same F-11 scenarios before/after, using only the human-approved baseline table. The
   final deterministic counters must be: `fast_group_count=4`, `fast_export_runs=0`,
   `fast_upgrade_runs=0`, `source_snapshot_copies=1`, and `path_directory_scans=0`.
5. `source_snapshot_copies=1` alone is satisfiable while still copying the tree repeatedly for
   derived fixtures, so it is not the acceptance bar on its own. Additionally require
   `fixture_tree_copies` and `fixture_copied_files` each at most half their F-11 baseline, and
   state how derived fixtures avoid re-copying — sharing the read-only snapshot, or copying only
   the subtree a case mutates. Whole-tree copies per derived fixture do not meet this step even
   with one snapshot. Keep unchanged full-suite group coverage; record elapsed timings as
   observations only.

**Failure-first test:** Fast dispatch entering export/upgrade, a full-mode group accidentally
omitted, missing required fixture tools, and one fixture's mutation leaking into another.
Add a case that keeps `source_snapshot_copies=1` while re-copying the whole tree per fixture: it
must fail on `fixture_tree_copies`. Check focused selectors remain independent and every removed
fast regression still runs in full.

**Stop if:** Savings require removing correctness coverage from the full suite or weakening a hook.

**DoD:** All five named counters equal the required values, both fixture-copy counters are at most
half their approved baseline, fixtures remain isolated, full-suite group coverage and budgets hold,
and all whole-brief verification commands pass.

**Commit:** `Reduce routine harness verification cost`

**Focused verification:** `make test-one F=contracts`, `make test-one F=hooks`,
`make test-one F=export`, and `make test-one F=upgrade`; then the full suite.

---

## Status / Implementation status

- **Evidence schema:** v2
- **Tracking issue:** url=https://github.com/wabkebab/agentic-flow/issues/93
- **Approval:** status=approved; by=wabkebab; at=2026-09-20
- **Implementation head:** source=pr-head
- **Implementation PR:** url=https://github.com/wabkebab/agentic-flow/pull/106
- **Verification evidence:** source=final-approval-run
- **Review verdict:** source=pr-head-approval
- **Memory:** status=n/a
- This Feature supersedes the implementation briefs in
  `feature-progressive-assurance-profiles.md` and `feature-adaptative-assurance-opus.md`.
- All twelve steps are reviewed clean on `codex/trustworthy-proportionate-harness-f12`
  (`87d6ae9..ba2cbd9`), not on the single branch named in Part B; see
  `docs/accepted_risks.md#harness-optimization-branch-split`. Close-out needs CI on the PR
  head, a structured reviewer approval of that head on #93, then `--phase close-out` and
  closing #93.
