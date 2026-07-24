<!-- TRIAGE (first pass · 2026-07-24) -->
> **Type:** Feature · **Status:** 🚧 In progress
> Adds a third agent role — **Review (OpenCode)** — between Codex execution and Claude's
> final close-out, driven entirely by GitHub label flips on the step issue. Design is the
> human's, given directly; this doc exists to make the contract precise and durable in
> `CLAUDE.md`/`AGENTS.md` rather than only spoken once in chat. Approved 2026-07-24; tracked
> in #38.

# Feature — Add the OpenCode Reviewer role and its label state machine

## Tracker
- [ ] F-1 Add the Review (OpenCode) role and label state machine to CLAUDE.md/AGENTS.md, and create the GitHub labels — open (#39)

---

# Part A — Analysis

## Goal

Today the loop is two roles: Claude plans and reviews commits ad hoc (no label marks this),
Codex executes. The human wants a **named, third role — Review, played by OpenCode** — sitting
between "Codex finished implementing" and "Claude closes the doc/tracker/issue", with the
handoff at each stage visible as a **label pair on the issue itself**, not just tribal
knowledge. For now the human plays OpenCode by hand, committing any review notes with
`git-opencode` (`~/.local/bin/git-opencode`, confirmed present, signs with a dedicated SSH key
exactly like `git-claude`/`git-codex`).

## Current state

- `METHODOLOGY.md` §6 already *lists* `needs-review` and `agent:claude` in its label
  vocabulary (`METHODOLOGY.md:176-177`), but nothing sets or reads them — `plan-to-issues.sh`
  only ever emits `needs-execution` + `agent:codex` on step issues (confirmed:
  `.claude/skills/plan-to-issues/SKILL.md:43`, `scripts/plan-to-issues.sh`). Review today is
  Claude reading the diff after the fact, with no issue-level signal for whose turn it is.
- `config/payload.tsv:1` ships `METHODOLOGY.md` verbatim to every adopter (`core`/`export`,
  no `templates/harness` fork the way `CLAUDE.md`/`AGENTS.md`/`Makefile` have one). It is the
  stack-agnostic standard, not this project's own instance.
- Root `CLAUDE.md`/`AGENTS.md`, by contrast, are already the pattern for
  project-specific role customization: `CLAUDE.md:20-23` has a live "Roles on this project"
  section plus a `<!-- OPT-OUT: ... -->` comment showing how a project overrides the default
  two-role split. `templates/harness/CLAUDE.md:19-21` carries the same generic section and
  the same comment, unfilled — confirming the pattern is "generic role framework in
  `METHODOLOGY.md`, concrete instantiation in the project's own `CLAUDE.md`/`AGENTS.md`."
- GitHub labels that exist today (`gh label list`): `agent:codex`, `needs-execution`, `plan`,
  `lane:fast-fix`. **`needs-review`, `agent:claude`, `agent:opencode`, `needs-closing` do not
  exist yet** — `gh issue edit --add-label` fails on a label that hasn't been created;
  unlike `gh issue create --label`, it does not auto-create.

## Proposed approach

Given directly by the human; recorded here rather than re-derived as options:

1. **Codex, on finishing a step:** flips `agent:codex` + `needs-execution` →
   `agent:opencode` + `needs-review` on that step's issue. This happens *in addition to*
   committing with `Fixes #N` as today — the commit still closes the issue once the PR
   eventually merges; the label flip is a same-issue-stays-open status signal for who
   should act next while the PR is still under review.
2. **OpenCode (the human, for now) reviews:**
   - **Findings** → note them on the issue (a comment), flip labels back to `agent:codex` +
     `needs-execution`. Back to Codex.
   - **No findings** → flip to `agent:claude` + `needs-closing`. Claude finalizes: updates
     the doc's Tracker/Status, moves it to `docs/done/` if the whole brief is complete, and
     leaves the actual issue/PR close to the human's merge (per the existing never-merge
     contract).
3. **Cap: at most 3 review rounds.** After OpenCode has sent a step back with findings three
   times, a fourth automatic bounce is not allowed — see Open Questions for the exact
   escalation, which the human should confirm.

This is scoped to **this project's own `CLAUDE.md`/`AGENTS.md` only** — not
`METHODOLOGY.md`, not `templates/harness/`. `METHODOLOGY.md` is the stack-agnostic standard
exported to every adopter (§ above); hardcoding a specific tool (`git-opencode`) and a
specific third role into it would ship an assumption most adopters don't share. The existing
pattern already has the right seam for this: the project's own root files are where a
concrete role roster and its labels get instantiated, exactly like the two-role default
already works. If this pattern proves generally useful, generalizing `METHODOLOGY.md` to
describe "a project may add named roles beyond the default two, each bound to its own
commit-signing wrapper and label pair" is a separate, later, bigger discussion — not
bundled here.

## Interface (before the implementation)

No code interface. The "interface" here is the label state machine itself:

```
step issue lifecycle:

  agent:codex + needs-execution          (plan-to-issues default — unchanged)
        │  Codex finishes the step, commits with Fixes #N
        ▼
  agent:opencode + needs-review
        │  OpenCode (human) reviews
        ├─ findings noted as an issue comment ──▶ agent:codex + needs-execution   (loop; capped at 3 rounds)
        └─ no findings ──────────────────────────▶ agent:claude + needs-closing
                                                          │
                                                          ▼
                                          Claude updates doc Tracker/Status,
                                          moves doc to docs/done/ if complete.
                                          Human still owns the actual merge/close.
```

New GitHub labels to create (color arbitrary, matching the existing gray `#CCCCCC` scheme
used by `agent:codex`/`needs-execution`/`plan`): `agent:opencode`, `agent:claude`,
`needs-review`, `needs-closing`.

## Threat model (one paragraph)

None. This is a process/label convention affecting who edits a GitHub issue's metadata and
in what order. No new trust boundary, no code path, no data at risk. The only "actor" risk
is a mislabeled issue causing the wrong role to pick up work — a workflow inconvenience, not
a security concern.

## Failure behavior

No external calls beyond `gh issue edit`/`gh label create`, which are already how this
project's existing labels were applied. Bounds:

| External call | On timeout | On malformed response | On partial success |
|---------------|-----------|-----------------------|--------------------|
| `gh label create` | human/agent retries manually | `gh` reports the error; not silently swallowed | re-running is idempotent (`gh label create --force` or a pre-check) |
| `gh issue edit --add-label/--remove-label` | human/agent retries manually | `gh` reports the error, including "label not found" if creation was skipped | re-running is idempotent — same end-state labels |

## Out of scope / What NOT to build in this pass

- **Automating OpenCode itself.** The human plays this role by hand for now; nothing here
  builds an actual OpenCode agent invocation. When that changes, it's a different, later doc.
- **`METHODOLOGY.md` generalization** (see Proposed approach) — a real idea, not this pass's job.
- **Enforcing the 3-round cap in tooling.** No script currently counts label-flip round
  trips; this pass documents the rule as agent/human discipline, not a mechanical gate. Worth
  a script if it's ever violated in practice — speculative today.
- **Retro-labeling already-open issues.** Only new step issues (created after this lands)
  follow the new state machine; nothing here back-fills labels onto issues opened earlier
  under the two-role convention.

## Open questions

- **[BLOCKING-ish, but proceeding under a stated assumption]** What happens on the 4th
  round, when OpenCode still has findings after 3 fix cycles? Assumption used in the brief
  below: **escalate to the human explicitly** (Claude or OpenCode flags it, no further
  automatic bounce to Codex) rather than silently continuing or silently stopping. Correct
  this if the intent was different (e.g., hard-stop with no labels changed, or Claude takes
  over the fix directly).
- Does "3 reviews" mean 3 total OpenCode review passes on a step, or 3 round-trips
  (OpenCode→Codex→OpenCode counted as one round)? Brief assumes **3 passes that found
  findings** — i.e., the cap is hit when OpenCode would be sending it back a 4th time.

---

# Part B — Implementation Brief

> **Audience:** Claude (this is a docs-only contract change to Claude's and Codex's own
> project files; no code, so no Codex-executed step in the usual sense — Claude does this
> one directly). One step.

## Branch

Base: `main`. One branch and one PR: `feature-opencode-reviewer-role`.

## Definition of done (whole brief)

`CLAUDE.md` and `AGENTS.md` state the OpenCode Reviewer role and the exact label state
machine (including the 3-round cap and its escalation); the four new GitHub labels exist;
`make check` and `make test` stay green (docs-only change, but the gate still runs).

## Verification commands

```bash
make check
make test
gh label list --limit 100   # confirm agent:opencode, agent:claude, needs-review, needs-closing exist
```

---

## Step 1 — Add the Review (OpenCode) role and label state machine

**Why first:** it is the only step.

**Approach (do NOT write code — this step is prose plus `gh label create`):**

1. **`CLAUDE.md` → "Roles on this project"** (`CLAUDE.md:12-18`): add a fourth bullet,
   **Review — OpenCode** (human-operated today), naming `git-opencode` and summarizing its
   job: read the step's diff against the brief, note findings as an issue comment or flip to
   closing. Add a short subsection (or extend the same section) spelling out the label state
   machine from Part A's Interface diagram, including the 3-round cap and the escalation
   from Open Questions once confirmed. This is the section Claude reads to know what
   `agent:claude` + `needs-closing` means for its own next action.
2. **`AGENTS.md` → "How to work a step"** (`AGENTS.md:22-31`, step 5, the commit step): add
   the explicit instruction that finishing a step means, *in addition to* the existing
   `Fixes #N` commit, flipping the issue's labels from `agent:codex`+`needs-execution` to
   `agent:opencode`+`needs-review` via `gh issue edit <N> --add-label
   "agent:opencode,needs-review" --remove-label "agent:codex,needs-execution"`. This is the
   one piece of the loop Codex actually has to act on mechanically — the rest is
   Claude/OpenCode/human coordination.
3. **Do NOT touch `METHODOLOGY.md` or `templates/harness/{CLAUDE,AGENTS}.md`** — see Part A;
   this is a project-instance customization, not a change to the exported standard.
4. **Create the four GitHub labels** (`gh label create agent:opencode --color CCCCCC`, same
   for `agent:claude`, `needs-review`, `needs-closing`) — required before any `gh issue edit
   --add-label` on them can succeed; confirmed missing via `gh label list`.

**Test:** none in the usual code sense. Verify by re-reading the finished `CLAUDE.md`/
`AGENTS.md` sections for internal consistency with Part A's Interface diagram, and by
`gh label list` showing all four new labels.

**DoD:** `CLAUDE.md` and `AGENTS.md` updated; four labels exist; `make check`/`make test`
still green (nothing in this step touches code, but the gate must not regress).

**Commit:** `Add the OpenCode Reviewer role and its label state machine`

---

## Status / Implementation status

- **Tracking issue:** [https://github.com/wabkebab/agentic-flow/issues/38](https://github.com/wabkebab/agentic-flow/issues/38).
- **Approval:** wabkebab approved on 2026-07-24 via plan-to-issues --apply.
- **Verification evidence:** pending.
- **Review verdict:** pending.
- Step not yet started.
