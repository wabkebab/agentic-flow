<!-- TRIAGE (first pass · 2026-11-26) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict (changes journal replay and the controller; project baseline is Standard)
> Phase 2 of [harness configurability](product-harness-configurability.md) (areas A, C and K): one validated config surface with override tiers, a per-plan policy pin that replay reads from each issue, one severity scale with an enforceable blocking threshold, warn-or-stop test budgets, and a bounded retry for pre-launch station failures. Draft 1, written against `0.21.0` (`97c6ebe`). All three gating decisions are settled (2026-11-26): the split safety floor, C-1's override tiers, and pins immutable once issues are stamped. Every question under *Open questions* is now decided, including CI wall time defaulting to `warn` here and for adopters. Next: owner review and approval.

# Feature — Config surface, plan-pinned policy and budget modes

## Tracker
- [ ] F-1 Replay each issue under its own policy pin — open
- [ ] F-2 Add the config registry, loader and `agentic-flow config` — open
- [ ] F-3 Capture the pin at approval and refuse to change it — open
- [ ] F-4 Use one severity scale and enforce the pinned blocking threshold — open
- [ ] F-5 Give test budgets a warn or stop mode — open
- [ ] F-6 Retry pre-launch station failures when the pin allows it — open

---

# Part A — Analysis

## Goal

The owner wants to *configure* the harness instead of hand-editing it. This phase covers
the settings that change what a gate or a replay means:

- how many bounces a step gets before it goes to a human;
- which finding severities must be fixed;
- what the line does on each kind of andon;
- whether a test budget overrun warns or stops the flow;
- the controller turn cap and the packet word limit.

The product analysis settled the shape: one flat `key=value` file, override tiers, and
plan pinning so that every reader derives the same state from the same issue. This brief
turns that into code. It does not move existing dotfiles, roles or notifications into the
new file (see *Out of scope*).

## Current state

- **Bounce limit.** It is hardcoded at 2 in four places:
  - the `bounces<2` / `bounces=2` requirement tokens in `config/workflow.tsv`, which the
    validator accepts as the only legal bounce requirements (`scripts/lib/workflow.sh:45-46`);
  - `workflow_successor` (`workflow.sh:98`), called by `handoff_render` and the handoff
    legality check (`scripts/lib/handoff.sh:109, 421`);
  - replay's `successor` (`scripts/lib/journal.jq:9-10`);
  - `controller_decide`'s escalation test, `bounces -ge 2` (`scripts/lib/controller.sh:553`).

  `status` derives the displayed limit by parsing the literal out of `workflow.tsv`
  (`scripts/lib/status.jq:117-118`).
- **Issue stamps.** Identity lives on one line,
  `<!-- agentic-flow:plan:<id> <tracker|step:id> spec:<hash> journal=v1 approved=<sha> … -->`,
  matched by `TRACK_STAMP_RE` / `STEP_STAMP_RE` (`scripts/plan-to-issues.sh:358-359`) and
  by `journal_stamp` (`scripts/lib/journal.sh:11-19`). Topology is a *separate* marker line,
  `<!-- agentic-flow:topology:standard|strict -->`, which `journal_context` reads with an
  exact-line match (`journal.sh:29-31`). `plan-to-issues` refuses a topology change before
  any mutation (`plan-to-issues.sh:469-489`).
- **Plan block.** `brief_parse` accepts only `id|profile|tracking|branch|base|steps|format`
  (`scripts/lib/brief.sh:64`) and emits the spec JSON that `plan-to-issues` hashes into
  `spec:` (`plan-to-issues.sh:168`). `approve` refuses a clarification that changes `id`,
  `profile`, `branch` or step ids (`scripts/lib/approve.sh:28-33`).
  `controller_check` exits 3 when stamped issues differ from the approved plan
  (`controller.sh:32-46`).
- **Severity.** Three vocabularies:
  - station results use `P1|P2|P3` (`config/stations/result.schema.json`,
    `scripts/lib/ledger.pl:146`);
  - the review contract and the reviewer agent use High / Medium / Low / Nit with
    `sev:high|med|low|nit` labels, and say High blocks, Medium needs a fix or an accepted
    risk, Low and Nit do not block (`templates/shared/review-contract.md:3-6`);
  - the product analysis proposed `critical > major > minor > nit`.

  **Nothing enforces severity today.** `result-check` only requires at least one finding on
  a bounce (`ledger.pl:151`); an approve may carry any finding and a bounce may carry only
  nits. The analysis's phrase "legacy: P1–P3 blocking" overstates the code: the legacy rule
  is the reviewer's judgment, unchecked.
- **Andon.** Fourteen hold reasons, each a fixed `hold`. `station-infrastructure` is raised
  at four sites. Three of them fail **before** the intent record is written: the probe
  (`controller.sh:796`), the launch preflight (`:801`) and the launcher fingerprint
  (`:880`). The fourth fails after the intent (`:940`).
- **Other knobs.** `CT_TURN_CAP=50` (`controller.sh:1018`); `word_limit=3000`
  (`scripts/lib/packet.sh:190`, message at `:85`).
- **Budgets.** Wall-time ceilings come from `config/test-wall-ceilings.tsv` and an overrun
  always fails (`scripts/self-test.sh:322-330`). Fixture copy limits are literals: 33 fast,
  199 full (`self-test.sh:342, 355`), 122 exported (`:593`). `make check` runs
  `self-test.sh --fast`, so the Stop hook enforces the fast fixture limit.
- **Verification reuse.** `verify_record_key` has no budget field
  (`scripts/lib/verify-record.sh:17-32`). CI's green App cache is keyed by
  `scripts/app-input-key.sh`, a hash of every tracked file outside the bookkeeping filter,
  so any committed config or budget file is already part of that key.
- **Existing operator layer.** `roles` already resolves harness → project → operator, with
  the operator file at `${XDG_CONFIG_HOME:-$HOME/.config}/agentic-flow/roles/<owner>/<repo>.tsv`
  derived from `origin` (`scripts/lib/roles.sh:31-41`).

## Proposed approach

### Option A — Registry-driven config, pin as a separate issue marker (recommended)

- One reviewed registry, `config/config-keys.tsv`, names every key with its tier, type,
  range and default. One loader resolves the effective value and its source. No consumer
  parses a config file itself.
- Plan-pinned keys are copied into the plan block at `start` and checked against the
  project config at the approved revision. `plan-to-issues` writes them to each issue as
  a separate marker line, `<!-- agentic-flow:policy:v1 … -->`, next to the topology marker.
- Replay reads the limit from that line, never from the active config. A missing line is
  the implicit legacy pin.

Pros:
- The identity stamp, its regexes and every `spec:` hash of existing issues stay
  byte-identical, because the pin is a new line and the spec JSON gains `policy` only when
  the plan block has one.
- It reuses the topology marker's proven immutability pattern.

Cons:
- It adds one more marker line per issue. An older harness ignores it, so mixed versions
  diverge on non-legacy pins (see *Threat model*).

### Option B — Pin inside the identity stamp

This changes `TRACK_STAMP_RE`, `STEP_STAMP_RE`, `journal_stamp` and `migrate_approval_body`
together. An older harness would reject every new stamp as malformed. It is rejected for
its blast radius.

### Option C — Replay reads the active config

This is rejected by the product analysis: two operators with different config would
derive different states from one journal.

**Recommendation:** Option A.

## Interface (before the implementation)

```
agentic-flow config [list] [--json]
agentic-flow config get <key>                      # effective value only
agentic-flow config explain <key>                  # value, source, tier, range, who may override
agentic-flow config set <key> <value> [--scope project|operator]
agentic-flow config unset <key> [--scope project|operator]
  exit 0 ok · 2 usage or invalid value · 3 unknown key or wrong tier for the scope · 5 I/O
  set/unset write atomically, keep comments and order, and never stage or commit.
  Agents are denied set/unset by the command policy, like approve.

Files (same grammar: '#' comments, blank lines, key=value; ≤ 64 KiB, ≤ 256 lines,
key ≤ 64 chars, value ≤ 256 chars; unknown or duplicate key = error with file:line)
  config/config-keys.tsv        registry: key, tier, type, default, summary   (payload, core)
  .agentic-flow/config          project file, committed; absent = all defaults (project-owned)
  ${XDG_CONFIG_HOME:-~/.config}/agentic-flow/config/<owner>/<repo>.conf     operator file
  AGENTIC_FLOW_<KEY>            env; KEY = upper(key) with '.' and '-' → '_'
  config/test-budgets.tsv       fixture copy limits (payload, core)

scripts/lib/config.sh
  config_load <root> [local|ci] -> CONFIG_JSON {<key>:{value,source,tier}}
  config_get <key>              -> value from CONFIG_JSON
  config_pin <root> [<rev>]     -> canonical pin text from the project file at <rev>

Plan block (format 2), written by start, compared by plan-to-issues and approve:
  policy: review.max_bounces=2 review.block_at=medium andon.station-infrastructure=hold

Issue marker (one per issue; absent = legacy pin):
  <!-- agentic-flow:policy:v1 review.max_bounces=2 review.block_at=medium andon.station-infrastructure=hold -->
Legacy pin: review.max_bounces=2 review.block_at=judgment andon.station-infrastructure=hold

workflow.tsv bounce requirements: findings,bounces<limit · findings,bounces=limit
workflow_successor <topology> <state> <event> <bounces> [<return>] [<limit>=2]
verify_record_key: + budget_policy_sha256
```

### C-1 Registry and tiers

| Key | Tier | Type | Default | Consumer |
|---|---|---|---|---|
| `review.max_bounces` | plan | int 1–5 | 2 | pin → replay, `controller_decide`, `status` |
| `review.block_at` | plan | `judgment\|high\|medium\|low` | `medium` | pin → `controller_decide`, reviewer packet |
| `andon.station-infrastructure` | plan | `hold\|retry:1\|retry:2\|retry:3` | `hold` | pin → controller (f-6) |
| `packet.word_limit` | project | int 1500–6000 | 3000 | `packet.sh` |
| `budget.fixtures.mode` | project | `stop\|warn` | `stop` | `self-test.sh` |
| `budget.wall.mode.ci` | project | `stop\|warn` | `warn` | `self-test.sh` under `CI=true` |
| `budget.wall.mode.local` | operator | `stop\|warn` | `warn` | `self-test.sh` |
| `budget.wall.scale` | operator | decimal 1.0–5.0 | 1.0 | `self-test.sh`, local only |
| `controller.turn_cap` | operator | int 10–200 | 50 | `controller.sh` |

Resolution, per tier:
- **plan:** the project file only. These values are read by `start`, `approve` and
  `plan-to-issues`. Replay, `controller_decide`, `packet` and `status` never read them from
  config. They read the issue's pin, or the plan block for `status`.
- **project:** default → project file. An operator file or env value for a project key is
  an error that names its source.
- **operator:** default → project file → operator file → env.
- **Under `CI=true`:** the operator file and env are ignored for `budget.*` keys, and each
  ignored value is reported once. `budget.wall.scale` is 1.0. This makes CI's budget
  policy a function of tracked files only.

**The safety floor has no keys.** Owner decision, 2026-11-26: it is split into fixed items
and one future opt-in.

| Item | Status |
|---|---|
| Merge to the default branch, `ship`, hold-clear | Human only. Fixed; no key, ever |
| Command-policy denies | Additions only. No key removes a deny |
| Secret scanning, integrity holds, replay rules for existing journals | Fixed; no key, ever |
| Push to the default branch, force-push, workflow-file writes | Denied to agents. Fixed; no key, ever |
| Push to the plan branch | Human only by default. Reserved for a future project-tier opt-in; **not built in this brief** (see *Out of scope*) |

A config file that names a floor item fails as an unknown key. `explain` names the tier
and says who may override it.

### C-2 Policy pin

- **Canonical form.** Three `key=value` pairs in the registry's order, all required, values
  validated by the registry. The plan block line and the issue marker carry the same text.
- **Capture.** `start` fills `policy:` from `config_pin` at the base. `brief_parse`
  validates it and adds `"policy"` to the spec JSON only when the line is present.
  Existing docs and their `spec:` hashes are unchanged.
- **Check at apply.** `plan-to-issues --doc`, before authentication or any mutation:
  - a plan block pin must equal `config_pin` at `APPROVED_REV`. Otherwise it dies:
    "plan pin differs from the project config at the approved revision".
  - a plan block with no pin, while the config at `APPROVED_REV` differs from the legacy
    pin, warns and proceeds with the legacy pin.
- **Immutability.** It runs next to the topology check (`plan-to-issues.sh:469-489`) and
  reads the marker of every indexed issue:
  - every indexed issue must carry the same pin (a missing marker counts as the legacy
    pin), and that pin must equal the doc's;
  - otherwise it dies before any label, create, edit or close:
    "changing plan <id> policy from <old> to <new> requires a new plan".
  - **Partial applies.** The pin of any issue that already exists binds the issues still to
    be created.
  - **Legacy issues.** The marker is added to legacy issues only when the doc's pin equals
    the legacy pin. In every other case a pin on an existing issue is preserved
    byte-for-byte, like `journal=`.
- **Reapproval.** `approve` adds `$old.policy==$new.policy` to its unchanged-ids check.
  A clarification may edit prose, never the pin.
- **Controller backstop.** `handoff_drift`'s per-issue report gains `policy`.
  `controller_check` requires every stamped issue's pin to equal `CT_SPEC.policy`, or the
  legacy pin when the spec has none, and exits 3 on a mismatch like any other stamp drift.
  This intentionally reuses the existing exit rather than adding a hold reason.

### C-3 Replay under the pin

- `journal_context` reads at most one exact policy marker line. Zero lines give the legacy
  pin. Two lines, or a malformed line, are an invalid stamp: exit 3, the same path as a
  missing plan stamp. It exports `JOURNAL_MAX_BOUNCES`, `JOURNAL_BLOCK_AT` and
  `JOURNAL_INFRA`.
- `journal_replay` passes `--argjson limit`. `successor` admits
  `bounces<limit` when `$bounces < $limit` and `bounces=limit` when `$bounces == $limit`.
- Every `workflow_successor` caller passes the issue's limit:
  `handoff.sh:109, 421` from `JOURNAL_MAX_BOUNCES`, and `controller_decide` from the
  report row.
- `controller_decide` escalates a bounce when `bounces >= max_bounces`.
- `status` takes the limit from the plan block's pin (legacy when absent) instead of
  parsing `workflow.tsv`.
- **Old `workflow.tsv`.** The validator still accepts the literal `bounces<2` /
  `bounces=2` pair as a deprecated fixed-limit form, so a locally modified file kept
  through an upgrade still loads. With that form, an issue whose pin is not
  `review.max_bounces=2` fails replay with exit 3: "workflow.tsv predates policy pins;
  take the upgrade candidate". `doctor` reports the deprecated form.

### C-4 Severity scale and blocking threshold

- **One scale:** `high > medium > low > nit`, the review contract's existing names and
  `sev:` labels. `P1`, `P2` and `P3` stay valid aliases for `high`, `medium` and `low`, so
  every recorded result still validates. The schema, `result-check` and
  `packet-findings.sh` accept all seven tokens. Rendering shows the canonical name.
- **Blocking threshold.** `review.block_at` names the lowest blocking severity.
  `judgment` (the legacy pin) means no check, as today. The shipped default, `medium`,
  matches the review contract: High and Medium block, Low and Nit do not.
- **Enforcement.** In `controller_decide`, next to the `bad claimed head` check
  (`controller.sh:540-541`), under a pin other than `judgment`:
  - `approve` with a finding at or above the threshold becomes `ask`:
    "reviewer approved with a blocking <severity> finding";
  - `bounce` with no finding at or above the threshold becomes `ask`:
    "reviewer bounced with no blocking finding".

  The controller never converts one verdict into the other. The human `resume` returns the
  step to `reviewing`.
- **Packet.** Under a pin other than `judgment`, the reviewer packet adds one line:
  "Blocking threshold: <x>. Bounce only for findings at or above it; report the rest in an
  approve." Approve bodies already carry their findings, so `comment` is today's
  disposition for below-threshold findings.
- Interactive `handoff approve|bounce` reads a prose body, so it is not checked. The review
  contract governs it, as today.

### C-5 Budget modes

- `config/test-budgets.tsv` holds `fixtures.fast`, `fixtures.full` and `fixtures.exported`
  (33 / 199 / 122). The raise history moves from `self-test.sh` comments into the file's
  comments. `self-test.sh` loads it with the same strictness as `load_wall_ceilings`.
- **Effective policy.** The context is `ci` when `CI=true`, else `local`:
  - wall mode is `budget.wall.mode.<context>`;
  - the wall limit is `ceil(ceiling × scale)`, with scale 1.0 in CI;
  - the fixture mode is `budget.fixtures.mode`.
- **`stop`** keeps today's failure text.
- **`warn`:**
  - prints `self-test warning: <budget> measured <n>, limit <m> (warn)`;
  - appends one row (UTC time, budget, measured, limit, mode, context) to this run's file
    under `<common>/agentic-flow/state/budget-overruns/`. Writes go to tmp + `mv`, and only
    the newest 20 files are kept. That lets concurrent runs proceed without a shared lock;
  - leaves the exit status unchanged;
  - adds an end-of-run line: `<n> budget overruns recorded as warnings`.
- In CI with wall mode `warn`, `self-test.sh` writes "wall time not enforced" to
  `$GITHUB_STEP_SUMMARY` when that is set.
- `doctor` lists every budget whose effective mode is `warn`, with its source, and the
  newest 10 overrun rows.
- **Reuse.** `verify_record_key` adds `budget_policy_sha256`: the SHA-256 of
  `config/test-wall-ceilings.tsv`, `config/test-budgets.tsv` and the effective
  `{context, wall_mode, wall_scale, fixtures_mode}`. A record made under another policy is
  stale, so a warn-green record never satisfies a stop gate. Every existing record goes
  stale once.
  - CI needs no key change. Its policy comes only from tracked files, which the App input
    key already hashes. A test pins that none of the three policy files matches the
    bookkeeping filter.

### C-6 Retry for pre-launch infrastructure failures (gated on the safety floor)

- **Scope.** It applies only at the three sites that fail before the intent record
  (`controller.sh:796, 801, 880`), so no station has started and no ledger chain exists.
  The post-intent site (`:940`) and every other reason stay `hold`.
- **Behaviour.** Under `andon.station-infrastructure=retry:N`, the controller retries
  instead of holding while all of these hold:
  - this invocation's consecutive pre-launch failures for `{issue, station}` are below N;
  - the plan worktree snapshot is clean (`recovery.pl snapshot`, `dirty=false`).

  A retry logs `station-infrastructure retry k/N: <cause>` to stderr, sleeps
  `min(30·2^(k−1), 300)` seconds (`AGENTIC_CONTROLLER_RETRY_S` overrides this in tests),
  updates the heartbeat, and ends the turn. The turn counts against the turn cap.
- **After N, or on a dirty worktree,** it raises today's hold, and the note adds
  "after k automatic retries".
- A station launch that returns metadata resets the count. A new invocation starts at
  zero, and the turn cap bounds the total.
- `fallback-agent` and `finish-step` are not built (see *Out of scope*).

## Threat model (one paragraph)

The new trust boundary is configuration that can loosen a gate. The project file is
committed and reviewed, but an executor could commit a looser `.agentic-flow/config` or a
higher budget in a step. Plan-pinned keys cannot move after approval: the pin is read from
the human-approved plan block and checked against the config **at the approved revision**,
then frozen on the issues. Project-tier keys, the budgets in particular, can move in a step
commit. So the reviewer packet lists any change to `.agentic-flow/config`,
`config/config-keys.tsv`, `config/test-budgets.tsv` or `config/test-wall-ceilings.tsv`
under "Policy files changed", and CI, the authority, reads only tracked files. Operator
files and env sit on the operator's machine. They can only relax local wall time and the
turn cap, which bounds work and is no safety control. Stations run under `env -i`, so env
overrides never reach them. Agents are denied `config set|unset` by the command policy.
**Mixed versions:** an older harness ignores the policy marker and replays with 2 bounces.
Transition markers carry the event and source state, not the destination, so the journal
itself stays valid and only an older reader's derived view differs. `plan-to-issues`
prints a reminder that every operator must run this version or later before a non-legacy
`review.max_bounces` is applied. Config values never hold secrets. The registry has no
secret-shaped key, and `config set` refuses a value matching the staged-secret patterns.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---|---|---|---|
| Project/operator config file | n/a | Exit 2 with `file:line`. The controller and `plan-to-issues` refuse before the lock or any mutation; `self-test` fails "invalid config" | — |
| Env override | n/a | Invalid value or wrong tier: exit 2 naming the variable | — |
| Issue policy marker | n/a | Duplicate or malformed: invalid stamp, exit 3 | — |
| `plan-to-issues` pin check | n/a | Mismatch: die before any mutation | A partial earlier apply binds the rest (C-2) |
| `git show <rev>:.agentic-flow/config` | n/a | Absent file means defaults; unreadable exits 5 | — |
| Overrun record write | n/a | Warn and continue; the budget result is unchanged | — |
| Pre-launch retry | Sleep bounded at 300 s | n/a | After N, hold as today |

Bounds: config files ≤ 64 KiB and ≤ 256 lines; ≤ 20 overrun files of ≤ 100 rows; retry
N ≤ 3 and each sleep ≤ 300 s; `review.max_bounces` 1–5; `controller.turn_cap` 10–200.

## Out of scope / What NOT to build in this pass
- Moving `.agentic-flow-assurance`, `-roles`, `-stack` or `-review-policy` into the new
  file. The setup and upgrade wizards (area D) migrate keys.
- Station agent keys and `key_cmd` / `key_env` references (area B, in the 1.0 brief).
- `notify.*` channels. The channel decision is still open.
- `review.nonblocking=follow-up-issue`. Below-threshold findings stay in the approve
  comment.
- `fallback-agent` (needs adapter capabilities, area B), `finish-step`, and the
  `budget-exceeded` reason (no cost budget exists yet).
- **Agent push to the plan branch.** The split floor reserves it (C-1). It needs its own
  brief because it touches three things:
  - the command policy: an opt-in narrows the push deny to the plan branch, while pushes to
    the default branch, force-pushes and workflow-file writes stay denied;
  - `ship` and close-out, which assume one human push after the close-out commit;
  - `doctor`, which must refuse the opt-in unless a server-side ruleset on the default
    branch requires a PR and review and blocks direct pushes. A pushed same-repo branch
    can also run workflows with repo secrets, which is why workflow writes stay denied.
- An explicit mid-plan policy transition (deferred by the analysis).
- Per-assurance bounce defaults.
- Modes for the role-bundle word ceilings. They are deterministic, scaffold-facing, and
  stay `stop`.
- A `budgets:` line in `agentic-flow status`. `doctor` reports warn budgets, and status
  output stays plan-focused.

## Open questions
- **Safety floor — decided by the owner (2026-11-26): option A with a split floor.**
  - Config can tighten but never loosen the floor. There is no key for any floor item and
    no override for integrity holds (C-1's table).
  - Merge to the default branch, `ship` and hold-clear stay human-only, permanently.
  - Agent push to the plan branch is moved off the fixed floor. It is reserved for a
    future, separately approved opt-in, and stays denied until that brief ships.
  - The bounded pre-launch retry (C-6) does not loosen the floor: no station has started
    and the same hold follows after N attempts. f-6 stays in the brief.
- **Override tiers — decided by the owner (2026-11-26): C-1 as drafted.**
  - Plan tier: `review.max_bounces`, `review.block_at` and
    `andon.station-infrastructure`, frozen at approval.
  - Project tier: packet word limit, fixture budget mode and CI wall-time mode, changed
    only by a reviewed commit.
  - Operator tier: turn cap, local wall-time mode and scale, on the operator's machine
    only.
  - Invocation flags shape a run and never set policy.
  - Rejected: moving `review.block_at` to the project tier (a step could be reviewed under
    different rules between bounces); dropping the plan tier; wider operator overrides.
- **Plan pinning — decided by the owner (2026-11-26): immutable once issues are stamped
  (C-2, C-3).**
  - The pin lives in the plan block and in an issue marker.
  - `plan-to-issues` refuses a changed pin before any mutation, and the controller checks
    it as a backstop.
  - Issues without a marker replay under the legacy pin.
  - Changing policy requires finishing or abandoning the plan and starting a new one.
  - Rejected: changeable until the first journal event (more API reads and another state
    to test); an explicit mid-plan transition (stays deferred); no pinning.
- **Severity names — decided by the owner (2026-11-26): `high|medium|low|nit`**, not the
  analysis's `critical|major|minor|nit`. The review contract and `sev:` labels already use
  them, so there is no third vocabulary. `P1`–`P3` stay as aliases.
- **Default threshold for new plans — decided by the owner (2026-11-26): `medium`.**
  - **Source:** the review contract, `templates/shared/review-contract.md:3-6`, mirrored in
    `.opencode/agent/code-reviewer.md:214-217`.
    - High: "Blocks merge".
    - Medium: "Requires a fix or explicit accepted-risk disposition".
    - Low and Nit: "Does not block".
  - **Accepted-risk path:** under `medium`, an approve that carries a Medium finding
    becomes an `ask`. The approver's `resume` note is that disposition, with the risk
    recorded in `docs/accepted_risks.md`. The reviewer gets the note in its packet and
    re-approves without the accepted finding.
  - Old plans keep `judgment` through the legacy pin.
- **Bounce limit scope — decided by the owner (2026-11-26):** one project default, pinned
  per plan. Per-assurance defaults are deferred.
- **CI wall-time mode — decided by the owner (2026-11-26): the shipped default is `warn`.**
  - Wall time depends on runner load, so a CI overrun is recorded and labelled "wall time
    not enforced" in the step summary instead of failing the build.
  - This changes today's behaviour: a CI wall-time overrun currently fails.
  - A project that wants enforcement sets `budget.wall.mode.ci=stop` in a reviewed commit.
- **This repository's own CI — decided by the owner (2026-11-26): `warn`, the default.**
  f-5 adds no `.agentic-flow/config` here; the scaffold runs under the same default its
  adopters get. Wall-time overruns in this repo's CI are recorded, not enforced.

---

# Part B — Implementation Brief

## Acceptance scenarios
- Given an issue with two policy markers or a malformed one, when it is replayed, then replay exits 3 and nothing is journaled.
- Given an issue without a marker, then replay, `handoff` and `controller_decide` escalate on the third bounce exactly as today.
- Given an issue pinned to `review.max_bounces=3`, then the third bounce returns to `executing` and the fourth escalates. `status` shows `bounces n/3`.
- Given a locally kept legacy `workflow.tsv`, then legacy-pin issues replay unchanged, and a `review.max_bounces=3` issue exits 3 naming the upgrade candidate.
- Given `AGENTIC_FLOW_PACKET_WORD_LIMIT` or an operator-file value for a project key, then `config` and every consumer exit 2 naming the source.
- Given an unknown key, a duplicate key or an out-of-range value in `.agentic-flow/config`, then `config list` exits 2 with `file:line`, and `run` refuses before taking the lock.
- Given `controller.turn_cap=12` in the operator file, then `config explain controller.turn_cap` names the operator file, and the controller stops at 12 turns.
- Given an agent hook context, then `config set` and `config unset` are denied.
- Given a doc whose plan block pin differs from `.agentic-flow/config` at the approved revision, then `plan-to-issues --apply` exits non-zero before any `gh` mutation (a `gh` sentinel records none).
- Given stamped issues pinned to `max_bounces=2` and a doc now pinned to `3`, then `plan-to-issues --apply` dies before any label, create, edit or close, including after a partial earlier apply.
- Given legacy issues and a doc whose pin equals the legacy pin, then the reapply adds the marker. Given any other pin, it dies.
- Given an existing doc without `policy:`, then its spec hash and issue bodies are byte-identical to before.
- Given a clarification that edits the pin, then `approve` refuses. Given one that edits only prose, it succeeds.
- Given a hand-edited marker that no longer matches the spec, then the controller exits 3 with the stamp-drift error.
- Given `review.block_at=medium`, then an approve with a `medium` (or `P2`) finding and a bounce with only `low` and `nit` findings each journal an `ask`. An approve with only `nit` findings is journaled as an approve.
- Given the legacy pin, then those same results journal as they do today.
- Given every stored result fixture using `P1`–`P3`, then all still validate.
- Given `budget.wall.mode.local=warn` and an overrun, then `self-test` exits 0, prints the warning, and records the row. `doctor` lists the budget and the row. Under `stop`, the same overrun fails with today's text.
- Given `CI=true` and no config file, when a wall ceiling is overrun, then `self-test` exits 0, records the overrun, and writes "wall time not enforced" to the step summary. With `budget.wall.mode.ci=stop`, the same overrun fails.
- Given `CI=true` and `AGENTIC_FLOW_BUDGET_WALL_MODE_LOCAL=warn`, then the CI mode applies, and the ignored value is reported once.
- Given a verify record made under `warn`, then a check under `stop` treats it as stale and reruns.
- Given `andon.station-infrastructure=retry:2` and a probe that fails twice and then succeeds, then the station launches with no hold. Given three failures, then one hold whose note says "after 2 automatic retries".
- Given a retry pin and a dirty worktree, or a failure after the intent record, then the controller holds at once.

## Invariants
- Without a `.agentic-flow/config` file and on legacy-pin issues, the controller, `handoff`, `packet`, `status` and `self-test` behave as today, with two exceptions. `verify` records are recomputed once. A CI wall-time overrun warns instead of failing (owner decision), unless the project sets `budget.wall.mode.ci=stop`.
- Replay never reads the active config. One issue body and one journal derive one state on every machine running this version.
- A pin never changes on an issue once it is written.
- The controller never converts an approve into a bounce or a bounce into an approve.
- No key loosens the safety floor. Integrity holds stay `hold`.
- Under `CI=true`, budget policy is a function of tracked files only.
- Bash 3.2; no new required tool.

```agentic-flow-plan
format: 2
id: config-surface
profile: strict
tracking: Plan: Config surface, plan-pinned policy and budget modes
branch: configurability-phase-2
steps: f-1 f-2 f-3 f-4 f-5 f-6
```

## Branch
Base: `main`. One branch and one PR for the whole brief: `configurability-phase-2`. Each
step lands as its own commit, closing its issue via `Fixes #N`.

## Definition of done (whole brief)
- Every step's DoD is met, and `make check` and `make test` are green.
- **Manual check:**
  - `agentic-flow config explain review.max_bounces` names the tier and source;
  - `start` writes the pin into a new plan;
  - `plan-to-issues --diff` shows the marker;
  - `status <plan>` shows the pinned bounce limit.
- These describe the new surface:
  - `ADOPTION.md`;
  - `config/stations/README.md`, for the packet limit and severity;
  - `templates/shared/review-contract.md` and `.opencode/agent/code-reviewer.md`, for the
    aliases and threshold;
  - the Stack-profile `make check` row in `CLAUDE.md` and `templates/harness/CLAUDE.md`,
    for warn mode;
  - `METHODOLOGY.md` §6, for the bounce limit.
- `config/payload.tsv` lists the new files, and the copy budgets are raised to measured
  values in the commit that adds them.

## Verification commands
```bash
make check                                  # per step
make test-one F=contracts                   # f-1, f-2, f-5
make test-one F=stations S=handoff          # f-1, f-4
make test-one F=plan-to-issues              # f-3
make test-one F=controller S=status         # f-1, f-3
make test-one F=controller S=andon          # f-4, f-6
make test-one F=stations S=verify           # f-5
make test                                   # end of brief
```

---

## F-1 — Replay each issue under its own policy pin
**Why first:** replay is the riskiest contract here, and the later steps write pins that it
must already read.

**Approach:**
- Implement C-3:
  - add the marker parser and legacy default in `journal_context`;
  - pass `limit` into `journal.jq`;
  - make `bounces<limit` / `bounces=limit` the only new tokens in `workflow.tsv` and the
    validator, keeping the deprecated literal pair;
  - add the `limit` argument to `workflow_successor` and every caller;
  - change `controller_decide:553`;
  - make `status` read the plan block pin.
- One marker-line regex is shared by bash and jq. Never match it loosely.

**Test:**
- Replay fixtures for: no marker; `max_bounces` 1 and 3; duplicate and malformed markers;
  a deprecated `workflow.tsv` with legacy and non-legacy pins.
- Handoff legality at the limit.
- `controller_decide` escalation at the pinned limit.
- The `status` limit display.
- Every existing journal fixture replays byte-identically.

**DoD:** legacy issues derive exactly today's states; pinned issues obey their own limit everywhere a successor is computed.
**Verify:** `make test-one F=stations S=handoff` and `make test-one F=controller S=status`
**Risks:**
- A caller left on the default `limit` of 2 would diverge silently. Grep for every
  `workflow_successor` and `bounces` use.
- `status.jq`'s `limits` parser must stop reading `workflow.tsv`.
**Red-first:** `scripts/self-test.sh --only stations --scenario handoff` — scripts/tests/stations.sh
**Commit:** `Replay each issue under its own bounce-limit pin`

---

## F-2 — Add the config registry, loader and `agentic-flow config`
**Why second:** pins, packet limits, the turn cap and budgets all resolve through it.

**Approach:**
- Add `config/config-keys.tsv` (C-1's rows) and `scripts/lib/config.sh` with
  `config_load`, `config_get` and `config_pin`, implementing C-1's grammar, bounds, tiers
  and CI rule.
- The operator path reuses `roles_operator_path`'s owner/repo derivation under
  `agentic-flow/config/`.
- Add `config list|get|explain|set|unset` to `scripts/agentic-flow` and its usage text.
- Add command-policy rows denying `config set` and `config unset` to agents, following the
  `approve` rows (wider prefix where a row cannot be expressed exactly), and regenerate.
- Wire the first consumers: `controller.turn_cap` (`controller.sh:1018`) and
  `packet.word_limit` (`packet.sh:85, 190`).
- Add the payload row for the registry.

**Test:**
- Unknown, duplicate and out-of-range keys.
- Oversize file.
- Env and operator values for project keys exit 2.
- `explain` sources for every layer.
- `set` preserves comments and writes atomically.
- The CI rule ignores and reports operator values.
- The denied `config set` probe.
- Turn cap 12 stops at 12.
- The packet limit from config.

**DoD:** every C-1 key resolves with its source; invalid config fails closed before the controller lock; agents cannot write config.
**Verify:** `make test-one F=contracts` and `make test-one F=controller S=status`
**Risks:**
- The loader must not run `gh` or the network.
- `env -i` stations must still load defaults without `HOME`.
**Red-first:** none
**Commit:** `Add the config registry, loader and agentic-flow config`

---

## F-3 — Capture the pin at approval and refuse to change it
**Why third:** with replay and the loader in place, this makes pins real and immutable.

**Approach:**
- Implement C-2:
  - `start` writes `policy:` from `config_pin`;
  - `brief_parse` validates it and emits `policy` only when present;
  - `plan-to-issues` checks the pin against the config at `APPROVED_REV`, then runs the
    immutability check over the index before any mutation, next to the topology check;
  - it writes the marker under the identity stamp for new and legacy-equal issues, and
    preserves existing markers byte-for-byte;
  - `approve` compares pins;
  - `handoff_drift` and `controller_check` compare pins.
- Print the mixed-version reminder for a non-legacy `max_bounces`.

**Test:**
- Mismatch at the approved revision.
- Changed pin over full and partial applies.
- Legacy add-only case.
- Byte-identical bodies and spec hash for a pinless doc.
- `approve` pin edit refused.
- Hand-edited marker leading to controller exit 3.
- A `gh` sentinel proving no mutation on every refusal.

**DoD:** a pin is written once, from the approved revision's config, and every later path that would change it refuses before mutating.
**Verify:** `make test-one F=plan-to-issues` and `make test-one F=controller S=status`
**Risks:**
- The adopted-issue prefix path (`plan-to-issues.sh:340-351`) must carry the marker inside
  the managed suffix.
- `migrate_approval_body` must not drop it.
**Red-first:** `scripts/self-test.sh --only plan-to-issues` — scripts/tests/plan-to-issues.sh
**Commit:** `Pin review policy at approval and refuse to change it`

---

## F-4 — Use one severity scale and enforce the pinned blocking threshold
**Why fourth:** it is the first gate that reads a pinned value other than the bounce limit.

**Approach:**
- Implement C-4: extend `result.schema.json`, `ledger.pl` `result-check` and
  `packet-findings.sh` to the seven tokens, with canonical rendering.
- Add the threshold checks in `controller_decide` beside `bad claimed head`, reading
  `block_at` from the issue's pin.
- Add the reviewer-packet threshold line.
- Update the review contract, the reviewer agent and the stations README for the aliases.

**Test:**
- Alias validation for every stored fixture.
- Approve with medium, approve with nit, and bounce with only low under `medium`.
- The same three under `judgment`.
- Packet line present only under a checked pin.

**DoD:** under a checked pin no inconsistent verdict is journaled as approve or bounce; legacy-pin behaviour is unchanged.
**Verify:** `make test-one F=stations S=handoff` and `make test-one F=controller S=andon`
**Risks:**
- An `ask` from the controller must reuse the existing diagnostic and escalation path,
  not a new hold reason.
**Red-first:** `scripts/self-test.sh --only controller --scenario andon` — scripts/tests/controller.sh
**Commit:** `Enforce the pinned blocking threshold on one severity scale`

---

## F-5 — Give test budgets a warn or stop mode
**Why fifth:** it is independent of pins, and it changes the Stop hook's failure surface,
so it lands after the replay work is stable.

**Approach:**
- Implement C-5:
  - add `config/test-budgets.tsv`, with its payload row and history comments;
  - add a strict loader;
  - change `check_wall_ceiling` and `assert_cost_budget` to the effective mode and limit;
  - add the overrun files and pruning;
  - add the CI step-summary label;
  - add the `doctor` section;
  - add `budget_policy_sha256` to `verify_record_key`.
- Remove the limit literals from `self-test.sh`.
- Raise the copy budgets to measured values, in the TSV.

**Test:**
- `warn` and `stop` for a wall overrun and a fixture overrun.
- Scale 2.0 doubles the limit locally and is ignored in CI.
- CI ignores and reports env.
- Concurrent runs both record.
- Pruning keeps 20 files.
- A warn-made verify record is stale under `stop`.
- None of the three policy files matches the bookkeeping filter.

**DoD:** every budget honours its mode, every warn is recorded and reported, and no warn-green result is reused under stop.
**Verify:** `make test-one F=contracts` and `make test-one F=stations S=verify`
**Risks:**
- `make check` runs in fixtures that copy the checkout; the overrun directory must
  resolve to the fixture's common dir, not the source's.
- See the `lint-before-push` memory for the copy budget.
**Red-first:** `scripts/self-test.sh --only contracts` — scripts/self-test.sh
**Commit:** `Add warn or stop modes for test budgets`

---

## F-6 — Retry pre-launch station failures when the pin allows it
**Why last:** it is the only andon override, and it is gated on the safety-floor decision.
It is last so it can be dropped without renumbering the other steps.

**Approach:**
- Implement C-6 at `controller.sh:796, 801, 880` through one helper that either schedules
  a retry or calls `controller_hold` with the "after k automatic retries" note.
- Keep the per-invocation counter in a `CT_` variable, reset on a launch that returns
  metadata.
- Record `retry` in the heartbeat's `phase` detail without changing the heartbeat schema
  version.

**Test:**
- Probe failing twice, then succeeding.
- Three failures leading to one hold.
- Dirty worktree leading to an immediate hold.
- A failure at `:940` leading to an immediate hold.
- Turns consumed and bounded by the cap.
- The `hold` pin unchanged.
- The backoff override keeps the `controller:andon` ceiling.

**DoD:** transient pre-launch failures recover without a human under `retry:N`; nothing after the intent record is retried.
**Verify:** `make test-one F=controller S=andon`
**Risks:**
- A retry must never run after an intent exists. Assert it from the ledger, not from the
  call site.
**Red-first:** `scripts/self-test.sh --only controller --scenario andon` — scripts/tests/controller.sh
**Commit:** `Retry pre-launch station failures under a pinned andon response`

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
