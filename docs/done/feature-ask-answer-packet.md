<!-- TRIAGE (first pass · 2026-11-22) -->
> **Type:** Feature · **Status:** ✅ Done
> **Assurance:** Standard
> When a station asks for a decision and is later resumed, its packet carries neither the
> ask nor the answer. This adds the question and the owner's answer to the packet. The
> fix unblocks #192 (harness-simplification s-4). Next: owner approval, then `plan-to-issues`.

# Feature — Carry the ask and its answer into the station packet

## Tracker
- [x] a-1 — #199; approved=ab2199ba8ea6ba6ed9139fe386a4668421a5f143; submissions=ab2199ba8ea6ba6ed9139fe386a4668421a5f143
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
- The executor's raw findings (`packet.sh:130-134`) include every comment a reviewer
  authors after the last submit, except the bounce and hold markers. A reviewer `ask`
  therefore already reaches the next executor in full, marker included. This pass
  stops that (review P3).
- The packet limit is 3000 words, minus the controller's suffix
  (`packet.sh:49-52`). Over that limit `packet` exits 3 and the controller doesn't
  launch (`controller.sh:726`). Stations can't run `gh` (preamble), so text left out
  of the packet only reaches them as a file, as findings already do
  (`packet-findings.sh:46-68`).

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
    clipped: bool,
    file: null | {path:string, sha256:string}   (full text; set whenever clipped)
  }

Selection — scoped to the station that asked (review P1):
  S = the station being packeted (executor | reviewer)
  cutoff = seq of the last accepted `submit` (0 if none)
  ask = the last accepted `ask` with role == S and seq > cutoff, or none
  answer = the accepted `resume` at seq ask.seq+1, if any
  No ask with a different role ever appears, whatever its seq.
  Effect on the workflow sequences (config/workflow.tsv):
    submit → reviewer ask → resume → bounce → executor packet: no decision
      (reviewer ask, role mismatch)
    bounce → executor ask → resume → executor packet: decision shown
    executor ask → resume → submit → reviewer packet: no decision
    executor ask → resume → submit → bounce → executor packet: no decision
      (the ask is before the cutoff; a new work cycle starts at each submit)
Each body excludes the marker line, the `agentic-flow-run:` lines and the trailing
owner-mention line that `handoff` appends.

packet_format adds, after the brief and before "Journal:":
  "Owner decision:" then "Question (seq N):" <ask body> then "Answer (seq M):"
  <answer body>, or "Answer: none yet" when there is no resume, then
  "Full text: <path> (sha256 <hash>)" when clipped.

Budget — measured, never assumed (reviews P2, then P1 and P3 on be83586):
  All sizes are packet_measure values (the larger of the JSON word count and the
  rendered word count, packet.sh:28-33) against `word_limit`, which is already reduced
  by the controller's suffix (PACKET_SUFFIX_FILE, packet.sh:49-52).
  base     = the packet without findings source, findings index and decision
  overhead = measure(base + a decision shell) − measure(base), where the shell has
             both labels, empty bodies each ending "[clipped]", `clipped:true` and
             `file` set to the real destination path with a 64-character hash
             placeholder. Every label, marker, JSON field and file reference is
             therefore counted, and only the prose is left to fit.
  space    = word_limit − measure(base)
  intact   = measure(base + the unclipped decision, no file) − measure(base)
  Reserve (if no ask is selected, reserve = 0 and nothing below changes):
    a. If the prose is ≤ 600 words and intact ≤ space, then reserve = intact. Nothing is
       clipped, no file is written, and no floor applies. A short pair fits even with
       fewer than 80 words of space (review P2 on 23b88bb).
    b. Otherwise clipping is required: prose_room = space − overhead (overhead is taken
       off first, before any prose is allocated), and
       reserve = overhead + min(600, prose_room). Only here does the floor apply: if
       prose_room < 80, exit 3 through the existing "packet exceeds 3000 words …;
       largest part: <part>" message. It never launches without the decision.
    So reserve ≤ space always holds.
  Fit order (the decision is reserved before findings are sized):
    1. If base + full findings + reserve fits, keep the full findings inline.
    2. Otherwise drop the findings source. index_budget = space − reserve. If
       index_budget < 12 (the footer reserve packet_findings_index already uses,
       packet-findings.sh:78), omit `findings_index` entirely, so the packet carries
       only the findings file reference. packet_findings_index emits its footer even at
       zero or negative budgets, so it must not be called then (review P1 on
       23b88bb). Otherwise call it with index_budget. The full findings are still in
       their file, as today.
    3. Fit the decision into what remains: in case a, the intact pair; in case b,
       body = word_limit − measure(packet so far) − overhead, capped at 600. The
       question is guaranteed min(words(question), max(60, 40% of body)) words; the
       answer gets the rest; any share one body doesn't use goes to the other. A
       clipped body keeps its first words and ends with "[clipped]".
    4. Measure the result. The helper's own word count and the measured, serialized
       size can differ (at index_budget = 12 the footer measured 13), so only the
       measurement counts. If the packet is over by n words, give up space in this
       order, re-measuring after each change, with at most 3 passes in total:
       i.  The optional index first (review P2 on e874ef8): regenerate it with
           index_budget − n, or omit it when that is under 12. The decision is
           untouched, so an intact decision that fit without the index stays intact.
       ii. Only when no index is left: in case a, switch to case b; in case b,
           shrink body by n and re-clip. The floor is checked only at this point.
       The existing over-limit check stays as the final guard.

Full text when clipped — no gh needed:
  Write the unclipped question and answer as Markdown to
  <git-common-dir>/agentic-flow/decisions/<plan>/<issue>/<ask seq>.md. Copy it to the
  station scratch dir (PACKET_FINDINGS_DIR) as decision.md, and name the path in the
  packet.
  Publisher split (review P2 on be83586), because packet_findings_publish runs
  `jq length` on its source (packet-findings.sh:59) and refuses Markdown:
    packet_publish_file source dest [scratch-dir scratch-name] → {path, sha256}
      the existing staging, symlink refusal, atomic move, sha256 checks and optional
      scratch copy (packet-findings.sh:47-65), with no knowledge of the content
    packet_findings_publish source dest [scratch-dir] → {path, count, sha256}
      a thin wrapper: packet_publish_file(…, scratch-dir, findings.json), then adds
      count = jq length source. Same arguments, output shape and key order as now.
  The decision calls packet_publish_file directly with scratch-name decision.md.
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
| decision file publish (local disk) | n/a | n/a | hash mismatch or write failure → exit 3, `packet: cannot deliver decision for #<n> ask <seq>`; never launch with a clipped decision and no file |

Bounds: the decision part has at most 2 bodies. Its inline prose is at most 600 words,
and the whole rendered part (labels and file reference included) never exceeds what
remains under the packet limit after the controller's suffix. The decision is reserved
before the findings index is sized. The fit is verified by measurement, with at most 3
shrink passes. The full text goes in one file per ask. The overall 3000-word limit is
unchanged.

## Out of scope / What NOT to build in this pass
- Answering by a plain comment on the ticket, structured options in asks, and
  back-and-forth clarification. Those are in the separate `ticket-answers` plan.
- Reusing the CLI session on resume (Option C).
- Showing older ask/resume pairs. Only the latest ask from this station in the current
  submit cycle counts.
- Passing a reviewer-side decision on to the executor. A decision made during review
  stays with the reviewer, and the reviewer's bounce findings carry anything the
  executor needs to act on.
- The owner's note on a resume after the bounce cap. That escalation has no ask; it
  can be a follow-up.

## Open questions
- None blocking. The 600-word cap and the 40% share for the question are judgment
  calls. The ask is capped at 1200 characters by the schema
  (`config/stations/result.schema.json:76`), so the question rarely needs its full share.

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
1. Put the selection and the body join in one function, `packet_decision` in
   `scripts/lib/packet.sh`. It takes the station, the journal JSON and the comment
   list as separate inputs and returns the unclipped `{ask, answer}` or null, or fails
   with the "not found" error. Keeping the two inputs separate is what lets the test
   reach the mismatch (review P4). Selection follows the Interface rules exactly: the
   role must equal the station, and seq must be after the last submit. Strip the
   `agentic-flow-transition` marker block, the heading and "Role: … · Transition: …"
   lines, and the trailing owner-mention and run lines `handoff` adds. Keep the prose.
2. Executor findings collector (`packet.sh:130-134`): also drop any comment whose
   marker line is an `agentic-flow-transition` (the bounce comment is already
   delivered separately through `bounce_id` and the findings file). Today a reviewer
   ask after the submit lands in the executor's raw findings, marker and all
   (review P3).
3. Rework the fit block (`packet.sh:166-185`) into the Interface's fit order: measure
   the base. Measure the intact decision first. If it fits (and is ≤ 600 words of
   prose), reserve exactly that. Otherwise subtract the measured overhead of a shell
   decision rendered through `packet_format` and measured with `packet_measure`,
   then reserve the clipped prose. Only then decide between inline findings and the
   findings index. Omit the index when its budget is under 12; otherwise pass it its
   budget. Fit the decision last, then verify by measuring. On an overshoot, trim or
   omit the index before touching the decision. Clip only when no index is left, at
   most 3 passes in all. The 80-word floor applies only when clipping is required. Below it, exit 3
   through the existing over-limit message. Add `decision` to the part list at `packet.sh:179` so that
   message can name it. With no selected ask, the reserve is 0 and the fit block
   must behave exactly as it does now.
4. Split the publisher as the Interface describes: `packet_publish_file` holds the
   content-agnostic copy and hash logic, and `packet_findings_publish` becomes a
   wrapper that adds `count`. When anything is clipped, publish the decision with
   `packet_publish_file` (scratch name `decision.md`), set `decision.file`, and print
   the "Full text:" line.
5. Bash 3.2 and `set -u`: no associative arrays. Keep all selection inside `jq`.
6. Preamble (`config/stations/preamble.md`): extend the findings-file sentence to
   cover the decision file. Add one sentence: when the packet has an Owner decision,
   the answer is the owner's instruction for this step and the station must not ask
   the same question again. Check the preamble word ceilings first. Add the matching
   edit under `templates/` if the preamble is mirrored there.

**Test:** extend the `packet` scenario in `scripts/tests/stations.sh` (`:1148`).
Failure paths first:
(f1) call `packet_decision` directly with a journal whose accepted entries include a
  resume at ask.seq+1, and a comment list that lacks that resume's comment →
  nonzero exit with "decision comment <id> not found", and no output (review P4);
(f2) a decision-file publish failure (an unwritable destination) → exit 3, and no packet;
(f3) role scoping: submit → reviewer ask → resume → bounce. The executor packet,
  checked as the whole formatted output and the JSON, contains no "Owner decision",
  no part of the reviewer ask's body and no `event=ask` marker (P1 and P3 together);
(f4) exact fit, with a `PACKET_SUFFIX_FILE` present: a fixture whose final packet,
  clipped decision included, measures exactly `word_limit` (by `packet_measure`, both
  JSON and rendered) → exit 0, and the question is present. Add one word to the
  suffix → exit 0 with the decision one word shorter. Shrink the margin until the
  prose budget is under 80 → exit 3 naming the largest part. Also the review's case: a
  ~2,700-word base with a 300-word decision → exit 0 (P1 on be83586);
(f5) a Markdown decision publishes through `packet_publish_file` with matching sha256
  in the durable and scratch copies. A findings publish through the wrapper returns
  the same `{path,count,sha256}` shape as before, compared against a fixture captured
  from the current helper (P2 on be83586);
(f6) oversized findings plus a resumed executor ask (bounce → executor ask → resume,
  with findings large enough to need the index): exit 0, the decision gets at least
  its reserve (prose ≥ 80 words, or its full length if shorter), the index shrinks
  instead, and the packet names both the findings file and the decision file
  (P3 on be83586);
(f7) exact fit beside the findings file reference: findings that need the index, and a
  margin where index_budget < 12 → exit 0, no `findings_index` key, no "index shows"
  footer, the findings file line present, the decision fitted, and the packet
  measuring exactly `word_limit` (P1 on 23b88bb);
(f8) a complete short pair that fits in full with fewer than 80 words of space
  → exit 0, nothing clipped, `clipped:false`, `file:null`, and no decision file written.
  The same space with a longer answer that needs clipping → exit 3 naming the
  largest part (P2 on 23b88bb);
(f9) index_budget exactly 12, with an intact decision that fits without the index
  (the review's probe: a 74-word packet under an 86-word limit) → exit 0, the decision
  intact (`clipped:false`), the index shrunk or omitted, no decision file, and the
  measured packet ≤ `word_limit` (P2 on e874ef8);
Then: (a) bounce → executor ask → resume → the executor packet shows both bodies,
with no marker or run lines; (b) an ask with no resume yet → "Answer: none yet";
(c) executor ask → resume → submit → bounce → the executor packet has no decision;
(d) a plain comment from a non-policy author after the ask doesn't appear;
(e) an oversized answer is clipped, and the decision file holds the full text with a
matching sha256 in both the durable and scratch copies; (g) the reviewer packet after
a reviewer ask and resume shows the pair.

**DoD:** each station's packet carries only its own latest ask and its answer for the
current submit cycle. That part fits in the remaining budget, with the full text in a
file when clipped. Executor findings never include transition comments. The packet
scenario covers the cases above.
**Verify:** `make test-one F=stations S=packet`
**Risks:**
- Stripping by line pattern could eat answer prose that starts like a marker. Match
  the exact marker and heading forms `handoff_render` emits, not prefixes.
- Interactive executors read `brief`, not `packet`. If `brief` is their only input,
  note the gap in the commit body. Don't extend `brief` in this step.
- Splitting the publisher must leave the findings path byte-for-byte unchanged:
  same arguments, output keys and exit statuses. The existing findings cases in the
  packet scenario must still pass, and (f5) pins the shape.
- Reordering the fit block changes when findings are inlined versus indexed. With no
  selected ask, the reserve is 0 and the old behaviour must hold. The existing
  near-limit findings cases are the regression for that.
**Red-first:** `scripts/self-test.sh --only stations --scenario packet` — scripts/self-test.sh scripts/tests/stations.sh
**Commit:** `Carry the open ask and its answer into the station packet`

---

## Status / Implementation status
- **Evidence schema:** v2
- **Tracking issue:** url=https://github.com/wabkebab/agentic-flow/issues/199
- **Approval:** status=approved; by=wabkebab; at=2026-11-22; rev=b424cb26476b2c3a0348cf8cc4b091ca09f0dbda
- **Implementation head:** source=pr-head
- **Implementation PR:** source=final-approval
- **Verification evidence:** source=final-approval-run
- **Review verdict:** source=close-out-attestation
- **Memory:** path=docs/memory/close-out-after-merged-pr.md
- Close-out: `ship` finalizes Status and Tracker, sets TRIAGE to Done, and commits this
  document's move and the updated index before the first push. It opens the PR and
  waits for CI. The reviewer runs `final-approve` to record the PR, head, and run attempt
  on the tracking issue. `ship` verifies that evidence, closes the issue, and runs
  the pre-merge check before the human merges. If a closer command is unavailable,
  commit the staged close-out and rerun `ship`.
