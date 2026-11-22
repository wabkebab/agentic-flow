<!-- TRIAGE (first pass · 2026-11-22) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Standard
> When a station asks for a decision and is later resumed, its packet carries neither the
> ask nor the answer. This adds the question and the owner's answer to the packet. The
> fix unblocks #192 (harness-simplification s-4). Next: owner approval, then `plan-to-issues`.

# Feature — Carry the ask and its answer into the station packet

## Tracker
- [ ] A-1 Put the open ask and its resume answer into the station packet — open

---

# Part A — Analysis

## Goal
When the owner answers a station's question, the next station run must see both the
question and the answer. Today it sees neither, so it asks again. #192 asked twice for
the same decision: the 18:30 ask was answered at 18:45, and the run that followed asked
again at 18:49, saying "the station packet contains only the resume event".

## Current state
- An ask is a transition comment from the station's bot identity, and the answer is a
  `resume` transition posted by `handoff <n> resume --as approver --body-file <f>`.
  Both bodies must be nonempty (`scripts/lib/journal.jq:19`), but replay keeps only the
  marker fields plus `comment_id`, `dbid` and `last_edited_at`
  (`journal.jq:25-26`). Comment bodies are not kept.
- `packet_cmd` (`scripts/lib/packet.sh:36`) builds the packet from the brief, the
  journal JSON, findings (reviewer only), the latest submit and the verification record
  (`packet.sh:160-165`). `packet_format` (`packet.sh:19-27`) prints these parts.
  There is no part for an ask or a resume.
- After a resume, the controller starts a new chain. It reuses the old CLI session only
  for a retry of a pending run (`controller_retry_session`, `controller.sh:660`), so a
  resumed step starts fresh with no memory of the question.
- The four earlier resumes (#154 three times, #158 once) succeeded either because the
  answer didn't change what the station would have done, or because a session was
  reused. Neither is guaranteed.
- `packet.sh:108` already holds the normalized comment list for the issue, with
  `agentic-flow-run:` lines removed, so the bodies are available without another
  GitHub read.

## Proposed approach

### Option A — Add a `decision` part to the packet (recommended)
Read the latest `ask` and the `resume` that answers it from the journal's `.accepted[]`,
take their bodies from the comment list already loaded, and add them as one bounded
packet part. This needs no new GitHub I/O and no journal schema change, and both
stations get it.

### Option B — Keep bodies in the journal replay
Make `journal.jq` keep `body` on accepted ask and resume entries. Every journal consumer
would then carry larger state, and the per-issue caches and ledger records would grow.
This is more surface area than the packet needs.

### Option C — Reuse the station's CLI session on resume
Resume the asking session, so it keeps its own context, and add the answer to the prompt.
This depends on the CLI, a live session and an unchanged launcher fingerprint, and it
still needs the answer text. It's fragile and doesn't replace Option A.

**Recommendation:** A. It's the smallest change that makes the answer reach the station
in every case, it reads data already in memory, and Option C could be added later.

## Interface (before the implementation)
```
packet JSON (v stays 1; additive field):
  decision: null | {
    ask:    {seq:int, role:"executor"|"reviewer", comment_id:string, body:string},
    answer: {seq:int, comment_id:string, body:string} | null,
    truncated: bool
  }

Selection: the last accepted `ask` whose seq is greater than the seq of the last
accepted `submit` for an executor packet (or the last accepted `submit` itself for a
reviewer packet), together with the `resume` at seq ask.seq+1 if one is accepted.
Each body excludes the marker line, the `agentic-flow-run:` lines and the trailing
owner-mention line that `handoff` appends.

packet_format adds, after the brief and before "Journal:":
  "Owner decision:" then "Question (seq N):" <ask body> then "Answer (seq M):"
  <answer body>, or "Answer: none yet" when there is no resume.

Word budget: the decision part is capped at 600 words in total. If it's over, keep the
start of the answer in full first, then the start of the question, and set
`truncated:true`, naming the comment ids so the station can read them.
```

## Threat model (one paragraph)
No new trust boundary. Ask bodies come from the policy executor or reviewer identities,
and resume bodies from policy approvers. The journal already rejects transitions from
anyone else (`journal.jq:4-8`, `:14`), so selecting from `.accepted[]` inherits that
check. A plain comment from a non-policy author never enters the decision part. The
text is untrusted prose for the station, as findings already are. The preamble
already ranks the packet above project files. The part adds no instruction authority
beyond "this is the owner's answer to the question".

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---------------|-----------|-----------------------|--------------------|
| none new (uses the comment list `handoff_read` already loaded) | n/a | an accepted ask or resume whose `comment_id` is missing from the comment list → packet refuses with exit 3 and `packet: decision comment <id> not found; retry` | n/a |

Bounds: the decision part has at most 2 bodies and is capped at 600 words. The overall
3000-word packet limit is unchanged, and the decision part counts toward it.

## Out of scope / What NOT to build in this pass
- Answering by a plain comment on the ticket, structured options in asks, and
  back-and-forth clarification. Those are in the separate `ticket-answers` plan.
- Reusing the CLI session on resume (Option C).
- Showing older ask/resume pairs. Only the latest ask in the current submit cycle counts.

## Open questions
- None blocking. The 600-word cap is a judgment call: the ask is capped at 1200
  characters by the schema (`config/stations/result.schema.json:76`), so most of the
  budget goes to the answer.

---

# Part B — Implementation Brief

> **Audience:** an implementing agent (**Codex** by default). One step, one logical
> commit. Stage files by name. Why-first commit body. Approach, not code.

```agentic-flow-plan
id: ask-answer-packet
profile: standard
branch: ask-answer-packet
steps: a-1
```

## Branch
Base: `main`. Branch `ask-answer-packet`. One commit, closing the work issue via
`Fixes #N`. After it merges, the owner merges `main` into `phase-4` so the
harness-simplification controller picks it up for #192.

## Definition of done (whole brief)
The A-1 DoD is met, and `make check` and `make test` pass. Manually:
`scripts/agentic-flow packet 192 --station executor` on the plan branch, after `main`
is merged in, shows the "Owner decision:" section with the 18:49 question and no answer yet.

## Verification commands
```bash
make check
make test-one F=stations S=packet
make test
```

---

## A-1 — Put the open ask and its resume answer into the station packet
**Why:** a resumed station can't act on an answer it never receives. This is the
smallest fix and it's the one blocking #192.

**Approach (do NOT write code yet):**
1. In `packet_cmd`, after `journal` and `comments` are set (`packet.sh:105-110`),
   select the ask/resume pair from `.accepted[]` as described in the Interface. Then
   look up each body by `comment_id` in `$comments`. Strip the
   `agentic-flow-transition` marker block, the heading and "Role: … · Transition: …"
   lines, and the trailing owner-mention and run lines `handoff` adds. Keep the
   question/answer prose.
2. Add `decision` to the packet JSON built at `packet.sh:161-165`, and print it in
   `packet_format` where the Interface says. Apply the 600-word cap before the overall
   word measurement, so the existing "largest part" message can name `decision`. Add
   `decision` to the part list at `packet.sh:179`.
3. Bash 3.2 and `set -u`: no associative arrays. Keep all selection inside `jq`.
4. Add one sentence to `config/stations/preamble.md`: when the packet has an Owner
   decision, the answer is the owner's instruction for this step, and the station must
   not ask the same question again. Check the preamble word ceilings first. Add the
   matching edit under `templates/` if the preamble is mirrored there.

**Test:** extend the `packet` scenario in `scripts/tests/stations.sh` (`:1148`).
Failure path first: an accepted resume whose comment is missing from the fixture
comments → exit 3 and no leaked content (reuse `packet_refused`). Then:
(a) ask followed by resume → executor packet shows both bodies and no marker or run
lines; (b) ask with no resume yet → "Answer: none yet";
(c) an ask from before the latest submit is not shown;
(d) a plain comment from a non-policy author after the ask doesn't appear;
(e) an oversized answer is truncated with `truncated:true` and the comment id named;
(f) reviewer packet after a reviewer ask/resume shows the pair.

**DoD:** both station packets carry the latest ask and its answer within the current
submit cycle, bounded and stripped of markers. The packet scenario covers the cases above.
**Verify:** `make test-one F=stations S=packet`
**Risks:**
- Stripping by line pattern could eat answer prose that starts like a marker. Match
  the exact marker and heading forms `handoff_render` emits, not prefixes.
- Interactive executors read `brief`, not `packet`. If `brief` is their only input,
  note the gap in the commit body. Don't extend `brief` in this step.
**Red-first:** `scripts/self-test.sh --only stations` — scripts/self-test.sh scripts/tests/stations.sh
**Commit:** `Carry the open ask and its answer into the station packet`

---

## Status / Implementation status
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
