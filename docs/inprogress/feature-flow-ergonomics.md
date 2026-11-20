<!-- TRIAGE (first pass · 2026-11-20) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict
> Three workflow fixes the owner asked for before Phase 4: start each plan on its own branch, ship with one green CI push, and make plans, issues and review comments readable on GitHub. Part A is the analysis; Part B is the implementation brief (steps e-1 to e-9), drafted 2026-11-20 and awaiting approval. Runs before Phase 4 (`feature-harness-simplification.md`). This doc was itself drafted on its plan branch, by hand, the way e-7 will automate it.

# Feature — Flow ergonomics before Phase 4

## Tracker
- [ ] e-1 Journal markers move into a hidden block; parsers read both forms — open
- [ ] e-2 Journal comments render as readable Markdown — open
- [ ] e-3 Plan and step issue bodies render as readable Markdown — open
- [ ] e-4 Close-out is committed before the single push — open
- [ ] e-5 CI classifies paths by an explicit bookkeeping list — open
- [ ] e-6 CI reuses a green App result for identical App inputs — open
- [ ] e-7 `agentic-flow start` creates the plan branch, worktree and doc — open
- [ ] e-8 Plan commands run from the plan worktree — open
- [ ] e-9 Contracts, methodology and release notes — open

---

# Part A — Analysis

## Goal

The owner asked for three changes before Phase 4:

1. **Start.** A new feature is created on the branch that will hold its development, not on `main`, so the plan doc never lives on two branches at once.
2. **Close-out.** A plan ships with one green CI push. The close-out docs update must not re-run the App checks.
3. **Ticket text.** The plan (tracker) issue, the step issues and the review comments read well as Markdown, so a human can follow them on GitHub without decoding them.

Success:

- `agentic-flow start <id>` gives the planner a branch, a worktree and a prefilled doc; the plan is drafted, approved, issued, executed, closed out and shipped on that branch, and `main` sees it only through the PR;
- on the happy path, `ship` pushes once and CI runs once from the last implementation commit to merge-ready;
- a later push that changes only bookkeeping files (plan docs, roadmap, memory) does not run App checks when App inputs are unchanged;
- a tracker, a step issue and every journal comment render with headings, lists, code blocks and tables, with no raw machine lines in view, and every existing issue still replays.

## Current state

References are to `main` at `ebbf16a`.

### 1. Plans start on `main`

- The plan doc is drafted and revised on `main`. Phase 3's brief and four revisions (`42e387d` to `dd09d82`) are first-parent commits on `main`.
- The plan branch is created later, at `run` time: `git worktree add -b "$CT_BRANCH" "$CT_WORKTREE" HEAD` (`scripts/lib/controller.sh:674`), from whatever the caller has checked out.
- After that the same doc is edited on both sides: tracker links and status lines on `main`, close-out on the branch. The roadmap that points at the doc is edited on both too.
- `run` reads the doc from the caller's `HEAD` (`git show "HEAD:$doc"`, `controller.sh:805`). If the caller is on the plan branch, `git worktree add` fails, because a branch can be checked out in one worktree only.
- `ship` already requires `HEAD` to be the plan branch (`scripts/lib/ship.sh:180`), so it runs from the branch while `run` runs from `main`.
- Planner memory records the workarounds: commit planning docs to `main` through a temporary worktree, and run flow commands from the plan branch because `main`'s scripts can lag.

### 2. Close-out costs two full CI runs

PR #174 (Phases 2b and 3): App checks took **30 to 50 minutes** per run.

| Head | What changed | App checks |
|---|---|---|
| `29521e8` | code | failure (30 min) |
| `7304024` | code | success (30 min) |
| `3460d81` | 5 docs files only | success (**50 min**) |
| `08c66a0` | close-out: docs, `CHANGELOG.md`, `VERSION` | failure (30 min, flaky timeout) |
| `bfd72cc` | fix + docs | success (30 min) |

Two causes:

1. **The path filter sees the whole PR.** On `pull_request` events `dorny/paths-filter` lists every file the PR changes against its base, not the files of the latest push. On an implementation PR `app` is always true, so a docs-only push re-runs everything (`.github/workflows/ci.yml`, job `changes`).
2. **`ship` pushes twice by design.** On the first run it pushes the implementation and opens the PR, then runs `close-out prep --pr <url>` (`ship.sh:117-125`), because prep writes `Implementation PR: url=…` into the Status block (`close-out.sh:116`). The closer commits that, and the second `ship` pushes again (`ship.sh:129-130`). `make ship-gate` also runs locally before each of the two pushes.

The `app` filter is also incomplete. It lists `scripts/**`, `Makefile`, `config/**`, `profiles/**`, `templates/**` and the agent directories. It does not list files that the export and tests read: `METHODOLOGY.md`, `ADOPTION.md`, `VERSION`, `docs/templates/**`, `.opencode/**` (all in `config/payload.tsv`). A PR changing only `METHODOLOGY.md` skips App checks today.

The `docs` job runs `docs-index.sh --check` only. `make check` also runs `check-memory-index.sh` and `check-harness-sync.sh`, which read docs.

`ship_wait_ci` gives up after 1800 s (`ship.sh:96`). Three of the five runs above took longer than that before they finished.

### 3. Ticket text is hard to read

Step issue #166, as created by `plan-to-issues.sh:524-527`:

- The packet is written as `Profile:`, `Brief:`, `Definition of Done:` lines with no blank lines, followed by a `---` line. Markdown reads that as a setext heading, so the whole packet renders as one large H2.
- Verification commands are copied without their code fence (`brief.sh:81` drops fence lines), so `<group>` and `<tag>` are parsed as HTML and disappear.
- The brief reference is a plain `path@sha#step` string, not a link.

Tracker #165, as created by `plan-to-issues.sh:574`: a bare `## Steps` list whose lines repeat the step id (`#166 [t-1] t-1 — …`), with no goal, branch or brief link.

Journal comments, as written by `handoff_post` (`handoff.sh:79-112`) and the controller (`controller.sh:380-397`):

- The first lines are raw machine markers: `agentic-flow-transition: v=1; id=…; head=<40 hex>`, then `agentic-flow-review: …` or `Implemented in <sha>`, and an `agentic-flow-run:` line at the end.
- The summary is one dense paragraph.
- Bounce findings are flat lines, `P2 scripts/x.sh:? text`.

What reads them:

| Marker | Readers |
|---|---|
| `agentic-flow-transition:` (must be line 1) | `journal.jq` (`startswith`, line-1 regex), `handoff.sh` post lookup, `lifecycle-status.sh` |
| `agentic-flow-review:` (any line) | `journal.jq` legacy path, `lifecycle-status.sh`, `ship.sh` final approval |
| `agentic-flow-run:` (any line) | `andon.sh:197`, `packet.sh:79`, `handoff.sh:111` |
| `agentic-flow-hold:` / `-hold-clear:` (line 1) | `packet.sh:87`, controller holds |
| `<!-- agentic-flow:plan:… -->`, `<!-- agentic-flow:topology:… -->` | already hidden; `plan-to-issues.sh`, `close-out.sh` |

The two body markers already in HTML comments show the pattern works.

## Proposed approach

### Issue 1 — start on the plan branch

**Option A — `agentic-flow start` plus plan-worktree commands (recommended).** A new command creates the branch from `origin/<base>`, creates the worktree at the path the controller already uses (`<git-common-dir>/agentic-flow/worktrees/<plan-id>`), and writes the prefilled doc. Every plan-scoped command runs from that worktree. `run` learns to accept being started inside its own plan worktree. The human's main checkout stays on `main`.

**Option B — keep `main`, sync the doc at `run`.** Rejected: it keeps two copies of the doc and only moves the conflict.

**Option C — push a draft PR at `start`.** Rejected by the owner (2026-11-20): it runs CI on every plan revision. Everything stays local until `ship`.

When `main` moves, the planner merges `main` into the plan branch. Rebasing would orphan the approval revision.

### Issue 2 — one green CI push

**A — close-out before the push.** `close-out prep` stops needing the PR URL. It writes `Implementation PR: source=final-approval`, and lifecycle resolves the PR from the reviewer's final-approval marker, which already names `pr=`, `head=`, `run=` and `attempt=` (`ship.sh:150`). `ship` then:

1. preps and stages the close-out, and stops for the closer's commit, without pushing;
2. on the next run, runs `ship-gate` once, pushes once, opens the PR, waits for CI, waits for the final approval, and finishes.

**B — carry a green App result forward.** The `changes` job computes a key from the content of every App input in the PR merge checkout. Bookkeeping paths are excluded. The App job saves that key to the Actions cache when it succeeds. A later run whose key already exists skips App checks and writes the source run into the step summary. Because the key covers the merge checkout, a moved base or any App-input change gives a new key. A cache miss or error runs App checks.

**C — invert the filter.** Replace the list of App paths with a short list of bookkeeping paths. Anything else is an App input, which also fixes the payload files the filter misses today. The Docs job runs the docs checks that `make check` would otherwise only run in App.

The owner chose A + B + C (2026-11-20). A gives one push on the happy path. B covers the docs-only pushes that still happen mid-PR, such as `3460d81`. C makes B's key and the skip decision safe.

### Issue 3 — readable tickets

- **Hidden machine block.** Each journal comment starts with one HTML comment holding the markers, then the visible body:

  ```text
  <!-- agentic-flow-transition: v=1; id=…; event=approve; …; head=<sha40>
  agentic-flow-review: status=approved; step=t-1; head=<sha40>; role=reviewer
  -->
  ### ✅ Approved · t-1 — Gate cadence in the contracts
  …summary in Markdown…
  <!--
  agentic-flow-run: run=…; host=…
  -->
  ```

  Marker lines keep their exact text inside the block, so the line-based readers (`agentic-flow-review:`, `agentic-flow-run:`) match unchanged. Only the line-1 readers learn to accept an optional `<!-- ` prefix. Old comments keep replaying.
- **One renderer** builds the visible body from the event and the structured station result (`summary`, `findings[]`, `question`), for the controller, interactive `handoff`, holds and final approval.
- **Issue bodies** become sections with headings, a fenced code block, a linked brief and a clean step list.

## Interface (before the implementation)

```text
agentic-flow start <plan-id> [--type feature|security] [--base <branch>] [--branch <name>] [--no-fetch]
  plan-id     [a-z0-9][a-z0-9._-]*   (the brief's plan id; the worktree directory name)
  --type      feature (default) | security   → docs/templates/{feature-analysis,security-review}.md
  --base      default main; resolved as refs/remotes/origin/<base> after `git fetch origin <base>`
  --branch    default <plan-id>; must pass git check-ref-format and must not exist locally or on origin
  --no-fetch  use the existing refs/remotes/origin/<base> (or refs/heads/<base>) without fetching
  effects     worktree at <git-common-dir>/agentic-flow/worktrees/<plan-id> on a new branch;
              docs/inprogress/<type>-<plan-id>.md from the template with id, branch, Base and
              TRIAGE date filled; docs/README.md regenerated; both staged by name; no commit, no push
  stdout      worktree path, doc path, next commands
  exit        0 created · 2 usage · 3 refused (exists, invalid, unknown base) · 5 fetch failed
  on error    nothing is left behind (no branch, no worktree, no file)

plan worktree path:  plan_worktree_path <git-common-dir> <plan-id>
  one helper; controller, start and error messages share it; AGENTIC_WORKTREE_ROOT still overrides

close-out prep <doc> [--pr <url>]
  without --pr   Status gets "- **Implementation PR:** source=final-approval"
  with --pr      unchanged (url=…), for plans already pushed under the old order

lifecycle Status field "Implementation PR":
  url=https://github.com/<o>/<r>/pull/<n>      (existing)
  source=final-approval                        (new) PR number from the newest reviewer-authored
      final-approval marker on the tracking issue whose head equals the PR head; no marker → NEEDS-REVIEW;
      malformed or other repo → BLOCKED

ship phases (derived, as today):
  no PR, doc in inprogress  → prep + stage, print "commit the staged close-out, then run ship again"; no push
  no PR, doc in done        → ship-gate, push, create PR, wait CI, wait final approval, finish, pre-merge
  PR, doc in inprogress     → legacy: prep --pr <url> as today
  PR, doc in done           → as today
  CI wait bound: AGENTIC_SHIP_CI_TIMEOUT seconds, default 3600

CI (ci.yml and templates/ci/ci.yml):
  changes.outputs: app (true unless every changed file is bookkeeping), docs, app_key, app_cached
  app_key   = sha256 of `git ls-files -s` over the PR merge checkout, minus bookkeeping paths
  cache key = app-green-v1-<app_key>; value: a file naming the run URL and attempt that passed
  app job   runs when app=='true' && app_cached!='true'; saves the key only on success
  docs job  docs-index --check, check-memory-index

journal comment layout:
  line 1      "<!-- " + transition marker   (old form: transition marker without prefix)
  next lines  compatibility markers (review / Implemented in), then "-->"
  visible     "### <icon> <Event> · <step> — <title>", a facts line, the body, findings table
  last        "<!--", agentic-flow-run line, "-->"
  hold        "<!-- agentic-flow-hold: …" / "<!-- agentic-flow-hold-clear: …" with the same rule
```

## Threat model

The untrusted inputs are station-written text (summaries, findings, questions), PR contents, and anyone who can push to a PR branch.

- **Wrongly skipped App checks.** This would merge untested code. The key covers the content of every non-bookkeeping file in the merge checkout, so a skip needs byte-identical App inputs against the same base. Only the App job writes the key, and only on success. GitHub scopes PR caches to the PR's merge ref, so a fork cannot write into `main`'s scope. Someone who can edit `ci.yml` in a PR could save a forged key, but they could already make CI vacuous. `ci.yml` is an App input and is reviewed. Cache eviction or an API error falls back to running App checks.
- **Hidden markers.** Humans no longer see the markers in the rendered view. Authority stays where it is: author login plus journal replay, with edit detection unchanged. The visible header is rendered from the same values as the marker. Station text is escaped so it cannot open or close an HTML comment, forge a marker line, or create a new `@` mention.
- **`source=final-approval`.** The PR binding now comes from a marker that only a configured reviewer login can post. That marker already binds the PR number, head and run.
- **`start`.** Local only: no push and no GitHub write. It refuses to overwrite an existing branch, worktree or doc.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---|---|---|---|
| `git fetch` in `start` | exit 5 after `AGENTIC_FLOW_FETCH_TIMEOUT` (120 s); nothing created | n/a | n/a: fetch runs before any write |
| `git worktree add` / template write in `start` | n/a | n/a | remove the worktree and branch it created; exit 3 |
| Actions cache restore in `changes` | treat as miss; App runs | treat as miss; App runs | n/a |
| Actions cache save in App | warn; job result unchanged | warn | warn |
| `gh pr create` after the single push | exit 5; the next `ship` finds no PR with the doc in `done/`, pushes (no-op) and creates it | exit 5 | as timeout |
| Final-approval marker lookup | UNVERIFIED, as today | BLOCKED | n/a |
| CI wait | exit 1 after `AGENTIC_SHIP_CI_TIMEOUT`; the next `ship` resumes | exit 5, as today | n/a |

Bounds: fetch 120 s; PR visibility 120 s (unchanged); CI wait 3600 s by default; GitHub comment body ≤ 65,536 characters (the renderer truncates the summary first and says so); findings table ≤ 100 rows (the schema cap); step packet ≤ 800 words (unchanged).

## Out of scope / What NOT to build in this pass

- A draft PR or any push at `start` (owner decision, 2026-11-20).
- `start` for Product Analysis docs: they have no implementation branch and stay as they are.
- Rewriting bodies or comments on existing issues. Re-applying a plan keeps preserving existing bodies.
- Any change to journal events, states, authorization or edit detection.
- Phase 4 items: R-12 hooks, R-13 native PR review, R-22 role-named labels, R-23 single state record.
- Automating the `main` → plan-branch merge.
- Making App checks themselves faster.

## Open questions

- Is `docs/README.md` bookkeeping? It is in the payload and changes at every close-out. e-5 audits whether export or tests read its content. If they do, it stays an App input; that is safe, because after e-4 the close-out rides the single push anyway.
- Release number: `0.19.0`, as a minor release with a migration note (old markers keep working). The owner confirms at approval.
- Icons in comment headings (✅ 🔁 📦 ❓): default yes. The owner can veto at approval.

---

# Part B — Implementation Brief

> **Audience:** the implementing agent (Codex). Steps run read-compatibility first (e-1), then the two writers (e-2, e-3), then close-out and CI (e-4 to e-6), then the start flow (e-7, e-8), then contracts and release notes (e-9). One logical commit per step; do not bundle. Stage files by name. Why-first commit bodies. The brief carries intent, interface, invariants and acceptance scenarios; you choose files and functions.

```agentic-flow-plan
id: flow-ergonomics
profile: strict
tracking: Plan: Flow ergonomics before Phase 4
branch: pre-phase-4
steps: e-1 e-2 e-3 e-4 e-5 e-6 e-7 e-8 e-9
```

## Prerequisite

`main` at `ebbf16a` (PR #174 merged). `.agentic-flow-review-policy` says `identity-mode=distinct-account`; if it does not, stop and tell the human.

## Branch
Base: `main`. One branch and one PR for the whole brief: `pre-phase-4`. Each step is one commit with `Fixes #N`. Review fixes land as new commits; never amend after a handoff. The branch is already checked out in the plan worktree at `.git/agentic-flow/worktrees/flow-ergonomics`; the controller reuses it. Do not check `pre-phase-4` out anywhere else. If `main` moves, merge it in; never rebase.

## Word ceilings

| File | Ceiling | Now |
|---|---|---|
| `CLAUDE.md` (root) | 1530 | 1322 |
| `AGENTS.md` (root) | 1090 | 956 |
| `.agents/skills/review-execution/SKILL.md` | 1000 | 976 |

Do not raise a ceiling. Only e-9 edits contracts; leave the reviewer skill alone unless a sentence in it becomes false. A contract edit to `CLAUDE.md`, `AGENTS.md` or the `Makefile` needs the matching edit in `templates/harness/`.

## Invariants (every step)
- Bash 3.2: no `mapfile`, no associative arrays, guard empty arrays under `set -u`.
- Payload membership lives in `config/payload.tsv` only.
- No literal placeholder or credential-shaped string in any file; build them with `printf`.
- Every journal, plan stamp and topology marker written before this plan still parses, replays and verifies exactly as before. Fixtures in the old form stay in the tests.
- No GitHub write or push outside the existing `handoff`, `plan-to-issues`, `ship` and `close-out` paths. `start` writes nothing remote.
- Hermetic tests: fake `gh`, fake `git` remotes and fake CLIs on `PATH`; no network.
- CI changes keep `ci-gate` the only required check, and keep every job in its `needs` and its loop.
- Copy budget and wall-time ceilings: no step raises them. A new scenario needs a ceiling line in `config/test-wall-ceilings.tsv` sized from its measured time.

## Definition of done (whole brief)
- Every step's DoD is met and all 13 acceptance scenarios pass as tests.
- `make check`, `make test`, `make ship-gate`, `make build` and `scripts/doctor.sh --check` are green here and in a fresh export.
- This plan's own PR ships with **one** push and **one** CI run from the last step commit to merge-ready, unless a final-review bounce forces another. The close-out records the push count and CI run URLs.
- The tracker, the step issues and the journal comments that this plan's own run creates render cleanly on GitHub. The close-out links one of each.
- Steps e-1 to e-9 ran through `agentic-flow run` from the plan worktree.

## Acceptance scenarios (written at Spec; the executor does not edit these)

**Issue 3 — readable tickets**
1. **Both marker forms replay.** For every journal event (submit, approve, bounce, ask, resume, notify, close) and for hold and hold-clear, a comment in the old form and the same comment in the hidden-block form give identical replay output from `journal.jq`, identical `handoff` post lookup, identical lifecycle verdicts and identical `packet` and `andon` reads. A hidden-block comment whose first line is not exactly `<!-- ` plus a valid marker is skipped, as a malformed old-form comment is today. A comment from an unauthorized login is ignored in both forms.
2. **Journal comments read well.** `handoff` and the controller write the hidden-block form. In the rendered Markdown, the first visible line is a level-3 heading naming the event, step id and step title. A bounce shows a findings table (Severity, Location, Finding) with `|` escaped, newlines flattened and the location in backticks. Station-supplied text containing `<!--`, `-->`, a marker line, `@someone` or `<placeholder>` is rendered inert: no comment opens or closes, no second marker is parsed, no mention is created, and the placeholder stays visible. The andon mention the harness adds still notifies.
3. **Step issues read well.** A step issue body has, in order: a heading with the step id and title; a facts line linking the tracker, the profile and the brief (a GitHub link to the doc at the approved revision); sections for Definition of done, Verify, Verification commands (in a fenced block, so `<group>` survives) and Risks; then the existing hidden stamps. No line is parsed as a setext heading. The packet is still ≤ 800 words, and the packet the controller hands to a station holds the same facts as before.
4. **The tracker reads well.** The tracker body has a title heading, a facts line (profile, branch → base, linked brief at the approved revision), the plan's tracking body when present, and a `### Steps` task list whose lines still carry the parsed `#N [id]` tokens without repeating the id in the visible title. `plan-to-issues` discovery and re-apply work on new trackers and on trackers in the old layout.

**Issue 2 — one green CI push**
5. **Prep without a PR.** `close-out prep <doc>` with no `--pr` writes `Implementation PR: source=final-approval`, moves and stages the doc and the index, and touches nothing else. `--pr <url>` behaves as today.
6. **Lifecycle resolves the PR from the final approval.** With `source=final-approval`, lifecycle `--phase close-out` returns READY when the newest reviewer-authored final-approval marker names a PR in the origin repo whose head equals the marker's head and the run passed. With no marker it returns NEEDS-REVIEW. With a marker from a non-reviewer login, it ignores that marker. With a marker for another repo or a malformed one, it returns BLOCKED. Docs with `url=` verify as before.
7. **One push on the happy path.** Start from a branch whose steps are all approved, the doc in `inprogress/`, and no PR. A fake `git` and `gh` record calls. `ship` stages the close-out and stops with no push. After the closer's commit, `ship` runs `ship-gate` once, pushes once, creates the PR once, waits for CI, waits for the final approval, finishes and passes pre-merge. In total: exactly one `git push` and one `make ship-gate`. A plan that already has a PR with the doc in `inprogress/` follows the old two-push path.
8. **Docs-only pushes skip App checks.** In `ci.yml` and `templates/ci/ci.yml`, `app` is true unless every changed file matches the bookkeeping list. A test parses both workflows and asserts that: the list is the same in both; no bookkeeping glob matches a `config/payload.tsv` source except `.gitkeep` files (and `docs/README.md` only if e-5's audit allows it); and `ci-gate` still needs every job. A PR changing only `METHODOLOGY.md` now sets `app=true`.
9. **Carry-forward is content-addressed.** The key computation, run as a script on fixtures, gives the same key for two trees that differ only in bookkeeping paths. It gives a different key when any App input changes (one byte, a mode change, a rename, an added or deleted file), and a different key when the base content differs. The App job is skipped only when the key is already in the cache, and the run summary names the source run. A cache lookup that errors runs App checks.
10. **CI wait bound.** `ship` waits up to `AGENTIC_SHIP_CI_TIMEOUT` (default 3600 s) for CI. An invalid value exits 2.

**Issue 1 — start on the plan branch**
11. **`start` creates the plan.** In a fixture repo with a fake origin, `agentic-flow start demo-plan --base main` fetches, creates branch `demo-plan` from `origin/main` (not from the caller's `HEAD`), a worktree at the plan worktree path, and `docs/inprogress/feature-demo-plan.md`. That doc has the plan block's `id` and `branch`, the Branch section's `Base:` and the TRIAGE date filled. The doc and `docs/README.md` are staged, nothing is committed, and nothing is pushed. `--type security` uses the security template. The caller's checkout and branch are unchanged.
12. **`start` refuses and cleans up.** An existing local or remote branch, an existing worktree path, an existing doc, an invalid id or branch name, or an unknown base each exit 3 with nothing created. A fetch that times out or fails exits 5 with nothing created. A failure after the worktree is created removes the worktree and the branch.
13. **Commands run from the plan worktree.** From the worktree `start` made, with the doc approved there: `plan-to-issues`, `run --once`, `close-out prep` and `ship` work. `run` reuses the worktree and creates no second one. `run` refuses to start when the plan worktree has uncommitted changes, naming them. `run` from `main`, when the doc exists only on the plan branch, exits 3 and prints the plan worktree path to `cd` into. A plan whose doc is on `main` (the old flow) still runs from `main` as today.

## Verification commands
```bash
make check                          # per step; also run by the Stop hook
make test-one F=<group>             # the group a step names
make test-one F=controller S=<tag>  # controller scenarios
make test-one F=stations S=<tag>    # stations scenarios
make test                           # end of brief
make ship-gate
make build
scripts/doctor.sh --check
```

**Station sandbox.** The executor's sandbox cannot run `ps`, so tests that run `scripts/lib/recovery.pl` fail there with `cannot read live process start time`. Do not weaken the sandbox or skip the test. The controller's own `verify-step` runs those groups outside the sandbox.

---

## e-1 — Journal markers move into a hidden block; parsers read both forms
**Why first:** every later writer depends on readers that accept the new form, and read compatibility is the riskiest contract here. It ships with no change in what is written.

**Approach:**
1. Teach every line-1 marker reader to accept an optional `<!-- ` prefix: `journal.jq` (the `startswith` gate and the transition regex), the post lookup in `handoff.sh`, `lifecycle-status.sh`, and the hold filters in `packet.sh` and the controller. The marker text after the prefix is unchanged.
2. Line-based readers (`agentic-flow-review:`, `agentic-flow-run:`, `Implemented in`) need no change, because inside the block those lines keep their exact text. Confirm that with tests rather than assuming it.
3. The "one marker per comment" rule in `handoff_post` (drop a body line identical to the marker, keep and block a different one) must see markers in either form.
4. Put the prefix rule in one shared place (a jq function and one shell helper), not as copies.

**Test:** scenario 1. Write each fixture once in each form and compare outputs. Failure path first: a near-miss prefix (`<!--agentic-flow-transition:`, a marker on line 2, a block opened twice), and an unauthorized author.

**DoD:** scenario 1 passes; no writer changed; every existing journal fixture passes unchanged.
**Verify:** `make test-one F=stations S=handoff`
**Risks:** a reader missed (grep every `agentic-flow-` marker family before you finish); the regex accepting text after the marker on line 1; `andon` and `packet` reading run markers from a block.
**Red-first:** `scripts/self-test.sh --only stations --scenario handoff` — scripts/tests/stations.sh
**Commit:** `Read journal markers inside a hidden HTML comment as well as bare`

## e-2 — Journal comments render as readable Markdown
**Why second:** it is the most-read text, and e-1 made the new form safe to write.

**Approach:**
1. Add one renderer (a shell or jq library under `scripts/lib/`) that takes the event, step id, step title, head and the body parts (summary, findings, question, warnings, andon mention) and returns the comment. Layout is in the Interface.
2. Route every writer through it: `handoff_post` (interactive bodies are treated as a summary), the controller's station bodies (`controller.sh` near the bounce findings line), holds and hold-clears, and `ship_final_approve`. The final approval gets a heading naming the PR, short head and run attempt.
3. Escaping applies to station- and human-supplied text, outside inline code and fenced blocks: neutralize `<!--` and `-->`, keep bare `<word>` visible, break `@` mentions, and reject or neutralize a marker line. In table cells, escape `|`, flatten newlines and wrap the location in backticks. Truncate the summary first to stay under 65,536 characters, and say so in the comment.
4. Update the station prompt (`config/stations/preamble.md` or the result-schema description) so stations write `summary` as short Markdown: a sentence, then bullets. Keep the schema shape and limits.

**Test:** scenario 2, rendered for every event against golden files. Failure path first: hostile summaries (comment openers and closers, marker lines, mentions, a 70 KB summary, a pipe-heavy finding). Re-run scenario 1 on renderer output.

**DoD:** scenarios 1 and 2 pass; every comment the harness writes comes from the renderer.
**Verify:** `make test-one F=stations S=handoff` and `make test-one F=controller S=ship`
**Risks:** a changed byte in the marker breaking journal ids; the andon mention escaped by mistake; renderer output exceeding the comment limit after escaping.
**Red-first:** `scripts/self-test.sh --only stations --scenario handoff` — scripts/tests/stations.sh
**Commit:** `Render journal comments as Markdown with the markers in a hidden block`

## e-3 — Plan and step issue bodies render as readable Markdown
**Why third:** same renderer conventions, separate writer (`plan-to-issues.sh`), and no state-machine risk.

**Approach:**
1. Before changing layout, audit every reader of issue bodies (`plan-to-issues.sh` discovery and re-apply, `packet.sh`, `brief.sh`, `close-out.sh`, `lifecycle-status.sh`). Anything parsed from a visible line must keep its token (`#N [id]` in the task list) or move into a hidden stamp first. Record the audit in the commit body.
2. Build the step body and tracker body as in scenarios 3 and 4. Keep the verification section's fence (`brief.sh` currently drops fence lines; keep them for the issue body). The brief link points at `https://github.com/<repo>/blob/<approved-rev>/<doc>`.
3. Re-apply of an existing plan keeps preserving existing bodies (the approval-only path). New layout applies to newly created issues and to bodies `plan-to-issues` already rewrites.

**Test:** scenarios 3 and 4, golden bodies for Strict and Standard. Failure path first: a brief whose sections contain `---`, `<placeholder>`, pipes and backticks; an old-layout tracker on re-apply.

**DoD:** scenarios 3 and 4 pass; the packet word cap still holds; old-layout trackers re-apply cleanly.
**Verify:** `make test-one F=plan-to-issues`
**Risks:** breaking task-list discovery; the word cap now counting heading words; a stamp moved out of the body's last lines.
**Red-first:** `scripts/self-test.sh --only plan-to-issues` — scripts/tests/plan-to-issues.sh
**Commit:** `Render plan and step issue bodies as Markdown sections`

## e-4 — Close-out is committed before the single push
**Why fourth:** it removes the second push and ships this plan's own close-out.

**Approach:**
1. `close-out prep`: `--pr` becomes optional; without it, write `source=final-approval` (Interface).
2. `lifecycle-status.sh`: accept `source=final-approval` and resolve the PR as scenario 6 says. Reuse the existing final-approval verification and do not add a second parser. `--validate-doc-status` accepts the new value.
3. `ship.sh`: the phases in the Interface. When there is no PR and the doc is in `inprogress/`, prep and stop without a gate or push. When there is no PR and the doc is in `done/`, run the gate, push, create the PR and continue as the existing PR path. Keep the legacy path for plans already pushed.
4. Replace the 1800 s CI wait with `AGENTIC_SHIP_CI_TIMEOUT` (default 3600, validated as a positive integer).
5. The feature and security templates' Status close-out text describes the new order. Keep the field list.

**Test:** scenarios 5, 6, 7 and 10. Failure path first: `gh pr create` failing after the push, then `ship` re-run; a final approval from a non-reviewer; CI failing on the single run.

**DoD:** scenarios 5, 6, 7 and 10 pass; `url=` docs in `docs/done/` still verify.
**Verify:** `make test-one F=controller S=ship` and `make test-one F=lifecycle`
**Risks:** `ship` pushing a branch whose close-out commit is missing (a dirty-tree check must stop it); lifecycle trusting a marker from the wrong PR; the old path regressing for in-flight plans.
**Red-first:** `scripts/self-test.sh --only controller --scenario ship` — scripts/tests/controller.sh
**Commit:** `Commit the close-out before the first push so a plan ships with one CI run`

## e-5 — CI classifies paths by an explicit bookkeeping list
**Why fifth:** e-6's key needs a correct definition of App inputs, and today's filter misses payload files.

**Approach:**
1. In `ci.yml` and `templates/ci/ci.yml`, define `app` as "any changed file outside the bookkeeping list". Use `predicate-quantifier: every` with negated globs, or an equivalent. Start the list with `docs/inprogress/**`, `docs/done/**`, `docs/backlog/**`, `docs/memory/**`, `docs/MEMORY.md`, `ROADMAP.md`, `README.md` and `docs/agentic-flow-explained.html`. Audit `docs/README.md`, `CHANGELOG.md` and `docs/accepted_risks.md`: each is bookkeeping only if no export step, script or test reads its content. Record the decision for each in the commit body.
2. Keep the list in one place per workflow, and add the check in scenario 8 (same list in both, no payload overlap) to `make check`.
3. The Docs job runs `docs-index.sh --check` and `check-memory-index.sh`.
4. The template comments tell adopters how to extend the list.

**Test:** scenario 8. Failure path first: a glob that matches a payload file, the lists drifting between the two workflows, a job dropped from `ci-gate`.

**DoD:** scenario 8 passes; `check-action-pins.sh` passes.
**Verify:** `make check`
**Risks:** a bookkeeping glob that hides an App input; the template diverging from this repo's file in ways the sync check does not see.
**Red-first:** `scripts/self-test.sh --only contracts` — scripts/tests/contracts.sh
**Commit:** `Run App checks unless every changed file is bookkeeping`

## e-6 — CI reuses a green App result for identical App inputs
**Why sixth:** it covers mid-PR docs-only pushes once e-5 defines App inputs.

**Approach:**
1. Add a script under `scripts/` that prints the App-input key for a checkout: the sha256 of `git ls-files -s` over every path not in the bookkeeping list. It reads the bookkeeping list from the same source e-5 checks. CI runs this script; it does not copy the logic inline.
2. The `changes` job computes the key on the PR merge checkout and restores `app-green-v1-<key>` from the Actions cache, pinned by SHA like every other action. It exposes `app_cached`.
3. The App job runs when `app=='true' && app_cached!='true'`. After all its steps succeed, it saves the key with a file naming the run URL and attempt. On a cache hit, `changes` writes the source run to the step summary.
4. Do the same in `templates/ci/ci.yml`, with the key script shipped in the payload (it is under `scripts/`). Re-stamp the action pins.

**Test:** scenario 9, with the key script tested on fixture repos. Failure path first: a mode-only change, a rename, a deleted App file, a base-content change, a cache error.

**DoD:** scenario 9 passes; `ci-gate` still treats a skipped App job as pass and a failed or cancelled one as fail.
**Verify:** `make test-one F=contracts`
**Risks:** keying on the PR head instead of the merge checkout (misses base moves); saving the key before every App step has passed; cache scope assumptions for forks.
**Red-first:** `scripts/self-test.sh --only contracts` — scripts/tests/contracts.sh
**Commit:** `Skip App checks when a green run already covered identical App inputs`

## e-7 — `agentic-flow start` creates the plan branch, worktree and doc
**Why seventh:** independent of the CI work, and e-8 builds on its worktree layout.

**Approach:**
1. Add `start` to `scripts/agentic-flow` with the Interface's flags, exits and effects, in a new `scripts/lib/start.sh`.
2. Move the plan worktree path into one helper that the controller and `start` both use. `AGENTIC_WORKTREE_ROOT` keeps overriding it.
3. Fill the template by replacing its known fields (plan block `id`, `branch`, the Branch section's `Base:` and the TRIAGE date). Leave every other placeholder for the planner. Fetch with the existing `run_with_timeout` and `AGENTIC_FLOW_FETCH_TIMEOUT`.
4. On any failure after the first write, remove what was created, in reverse order.

**Test:** scenarios 11 and 12 with a fake origin. Failure path first: every refusal in scenario 12, then fetch timeout, then a template write failure after the worktree exists.

**DoD:** scenarios 11 and 12 pass; `agentic-flow --help` lists `start`.
**Verify:** `make test-one F=controller S=launch`
**Risks:** creating the branch from the caller's `HEAD` instead of the base; leaving a half-made worktree; a template field missed after a template edit (assert the filled fields).
**Red-first:** `scripts/self-test.sh --only controller --scenario launch` — scripts/tests/controller.sh
**Commit:** `Add agentic-flow start: plan branch, worktree and prefilled doc`

## e-8 — Plan commands run from the plan worktree
**Why eighth:** it completes Issue 1 by making `run` work where `start` puts the planner.

**Approach:**
1. The controller accepts being started inside its own plan worktree (its top level is the plan worktree path and its branch is the plan branch). It reuses the worktree without `worktree add`.
2. Before any station runs, `run` refuses a dirty plan worktree and names the changed files. Its own restore (`reset --hard`/`clean -fd` on `restore_required`) is unchanged.
3. When `HEAD:<doc>` is missing, `run` looks for exactly one local branch that has the doc. If it finds one, it exits 3 with the plan worktree path to `cd` into; otherwise it exits 3 as today. It never switches branches itself.
4. Confirm that `plan-to-issues`, `close-out` and `ship` work from the worktree, and fix any assumption that the caller is the main checkout.

**Test:** scenario 13. Failure path first: a dirty worktree, the doc only on the plan branch with `run` called from `main`, two branches holding the doc.

**DoD:** scenario 13 passes; the old run-from-`main` flow still passes every controller scenario.
**Verify:** `make test-one F=controller S=launch` and `make test-one F=plan-to-issues`
**Risks:** the `reset --hard` path deleting planner edits (the dirty check must run first); ownership checks failing because the caller's root and the worktree are the same path.
**Red-first:** `scripts/self-test.sh --only controller --scenario launch` — scripts/tests/controller.sh
**Commit:** `Run plan commands from the plan worktree`

## e-9 — Contracts, methodology and release notes
**Why last:** it documents the behavior the earlier steps shipped.

**Approach:**
1. `CLAUDE.md` Document workflow: new work starts with `agentic-flow start`. Plans are drafted, approved and issued on the plan branch; roadmap pointers for the plan are edited there too; `main` is merged in, never rebased. Mirror this in `templates/harness/CLAUDE.md`, and add one line to `AGENTS.md` (and its template) saying the executor works in the plan worktree.
2. Close-out wording (`CLAUDE.md` Station commands): `close-out prep <doc>` without `--pr`, commit, then `ship` pushes once.
3. `METHODOLOGY.md` (the document workflow and close-out sections, and §10 CI): the start flow, the one-push order, the bookkeeping list and the carry-forward rule. Keep shared blocks in sync with `render-shared.sh`.
4. `ADOPTION.md`: adopters extend the bookkeeping list and get carry-forward from the template.
5. `CHANGELOG.md` `0.19.0` with migration notes: old markers and `url=` docs keep working; existing open plans finish on the old two-push path; adopters re-run `create-tags` only if labels changed (none should). Bump `VERSION`.
6. `docs/memory/`: one trap about rebasing a plan branch after approval.

**Test:** contracts and sync checks; word ceilings.

**DoD:** every contract and sync check passes under its ceiling; the root and template copies match.
**Verify:** `make test-one F=contracts`
**Risks:** a ceiling overrun; a root/template drift; the methodology describing a behavior no step built.
**Red-first:** none
**Commit:** `Document the start flow, one-push close-out and readable tickets; release 0.19.0`

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
- Close-out: finalize Status/Tracker, set TRIAGE to Done, move this document and update
  the index in the last repository commit. After human push, obtain CI and a structured
  reviewer approval on the `Tracking issue` for that exact PR head and run attempt.
  Verify this moved file with `--phase close-out`, close the tracker without another
  repository edit, then recheck with `--phase pre-merge` before human merge.
