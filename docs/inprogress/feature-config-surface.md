<!-- TRIAGE (first pass · 2026-11-26) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict (changes journal replay and the controller; project baseline is Standard)
> Phase 2 of [harness configurability](product-harness-configurability.md) (areas A, C and K): one validated config surface with override tiers, a per-plan policy pin that replay reads from each issue, one severity scale with an enforceable blocking threshold, warn-or-stop test budgets, and a bounded retry for pre-launch station failures. Draft 3, written against `0.21.0` (`97c6ebe`). Draft 2 (2026-11-26) answers the first review: `v=2` transition markers so older `handoff` writers cannot advance a non-default bounce limit; a verification key derived from the trees actually tested; pin checks that skip unstamped adoptions; a draft, apply and clarification rule for the pin; pin parsing moved into f-1; the policy-files packet section assigned to f-2; and per-attempt retry eligibility with a heartbeat `retry` field. Draft 3 answers the second review: a ` pin=v1` stamp token that makes 0.21.0's `plan-to-issues` (doc and JSON-spec paths) die before rewriting a pinned issue; a budget digest re-checked at the submit decision, so a restart cannot submit a stale warn-green verify; a pin check placed after discovery reads, with zero mutations asserted; an `approve --repin` path for unstamped plans; and f-5's red-first moved to a test-only file with a distinctive failure line. All three gating decisions are settled (2026-11-26): the split safety floor, C-1's override tiers, and pins immutable once issues are stamped. Every question under *Open questions* is now decided, including CI wall time defaulting to `warn` here and for adopters. Next: owner review and approval.

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
- Existing issues' identity stamps and `spec:` hashes stay byte-identical. The pin values
  live on a new line, and the spec JSON gains `policy` only when the plan block has one.
  Pinned issues add only a ` pin=v1` token to their stamp, which is the guard against
  older body writers (C-3).
- It reuses the topology marker's proven immutability pattern.

Cons:
- It adds one more marker line per issue. An older harness ignores it, so mixed versions
  diverge on non-legacy pins (see *Threat model*).

### Option B — Pin inside the identity stamp

Option A also touches `TRACK_STAMP_RE`, `STEP_STAMP_RE` and `journal_stamp`, but only to
accept one fixed token. Option B would put every pin value in the stamp, so each future pin
key would change the stamp grammar, and `migrate_approval_body`'s field surgery would have
to carry the values too. It is rejected: values belong on a versioned line of their own.

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
agentic-flow config init [--missing] [--print]     # commented template, rendered from the registry
  exit 0 ok · 2 usage or invalid value · 3 unknown key or wrong tier for the scope · 5 I/O
  set/unset/init write atomically, keep comments and order, and never stage or commit.
  set uncomments a key's template line in place; unset comments it back out at its default.
  init refuses an existing file; --missing appends only absent keys; --print writes stdout.
  Agents are denied set/unset by the command policy, like approve. init changes no
  effective value, so it is allowed.

Files (same grammar: '#' comments, blank lines, key=value; ≤ 64 KiB, ≤ 256 lines,
key ≤ 64 chars, value ≤ 256 chars; unknown or duplicate key = error with file:line)
  config/config-keys.tsv        registry: key, tier, type, default, summary   (payload, core)
  .agentic-flow/config          project file, committed; created by config init at adoption,
                                every key commented at its default; absent = all defaults
  ${XDG_CONFIG_HOME:-~/.config}/agentic-flow/config/<owner>/<repo>.conf     operator file
  AGENTIC_FLOW_<KEY>            env; KEY = upper(key) with '.' and '-' → '_'
  config/test-budgets.tsv       fixture copy limits (payload, core)

scripts/lib/config.sh
  config_load <root> [local|ci] -> CONFIG_JSON {<key>:{value,source,tier}}
  config_get <key>              -> value from CONFIG_JSON
  config_pin <root> [<rev>]     -> canonical pin text from the project file at <rev>

Plan block (format 2), written by start, compared by plan-to-issues and approve:
  policy: review.max_bounces=2 review.block_at=medium andon.station-infrastructure=hold

Issue marker (one per issue; absent = legacy pin, unless the stamp carries pin=v1):
  <!-- agentic-flow:policy:v1 review.max_bounces=2 review.block_at=medium andon.station-infrastructure=hold -->
Identity stamp of a pinned issue (token directly after spec:):
  <!-- agentic-flow:plan:<id> step:<id> spec:<hash> pin=v1 journal=v1 approved=<sha> -->
agentic-flow approve <doc> --by <login> [--repin]   # --repin: unstamped plans, pin = config_pin at HEAD
Legacy pin: review.max_bounces=2 review.block_at=judgment andon.station-infrastructure=hold

workflow.tsv bounce requirements: findings,bounces<limit · findings,bounces=limit
workflow_successor <topology> <state> <event> <bounces> [<return>] [<limit>=2]
Transition marker: agentic-flow-transition: v=1 (limit 2) | v=2 (limit ≠ 2); replay admits
  only the issue's own version
agentic-flow config pin [--rev <rev>]          # canonical pin, for a draft's policy: line
verify_record_key: + budget_policy {context, green, red[]}, derived from <sha> / <red_base>
Reviewer packet: + "Policy files changed" (net diff, approved revision → submitted head)
Heartbeat: + retry:null|{issue, station, attempt, of, until}   (phase values unchanged)
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

**Commented template.** The project file is discoverable without reading code.
`config init` renders it from the registry, so the template cannot drift from
`config-keys.tsv`. There is no hand-maintained template file and no separate sync check.
Every key appears once, commented out at its default, so a fresh file changes no
effective value:

```
# agentic-flow project config. Commented keys use their defaults.
# Change one with: agentic-flow config set <key> <value>   then review and commit.
# Tiers: plan = frozen into each plan at approval · project = this file only ·
#        operator = may be overridden per machine (~/.config, AGENTIC_FLOW_*).
# Not configurable: merge, ship and hold-clear stay human-only; see C-1's floor table.

# review.max_bounces — bounces before a step escalates to a human
# tier: plan · range: 1–5 · default: 2
#review.max_bounces=2
```

- **Where it comes from.** `scripts/init.sh` runs `config init` at adoption. This repo
  commits the generated file in f-2. Existing adopters run `config init` once; `doctor`
  reports a missing project file as information, not a failure.
- **New keys later.** `config init --missing` appends commented entries for registry keys
  absent from the file and leaves every existing line untouched. `doctor` names the keys
  the file does not list.
- The upgrade wizard (area D) will run `--missing` automatically.

### C-2 Policy pin

- **Canonical form.** Three `key=value` pairs in the registry's order, all required, values
  validated by the registry. The plan block line and the issue marker carry the same text.
- **Parsing.** `brief_parse` accepts `policy:`, validates it against the version-1 form,
  and adds `"policy"` to the spec JSON only when the line is present. Existing docs and
  their `spec:` hashes are unchanged. This read-only parsing ships in f-1, so `status` and
  replay tests can read a pin before f-3 writes one.
- **The pin is a draft field until the first issue is stamped.**
  - `start` fills `policy:` from `config_pin` at the base.
  - `agentic-flow config pin` prints the canonical pin from the current project config.
    After merging `main` into a draft, the planner reruns it and updates the line before
    approval.
- **Check at apply.** `plan-to-issues --doc` classifies each indexed issue first:
  - **stamped:** its managed body carries an identity stamp;
  - **unstamped adoption:** a validated `--adopt` candidate with an empty managed body
    (`plan-to-issues.sh:475`). It has no pin yet and is never compared.

  Classification needs the existing, authenticated discovery reads: the bounded issue
  search and index (`plan-to-issues.sh:353-389`). The pin check therefore runs **after
  those reads and before any mutation**, meaning no label creation, issue create, edit,
  comment or close. Tests assert zero mutating `gh` calls; read calls are allowed. Which
  pin the doc must match depends on whether anything is stamped:
  - **First apply (no stamped issue).** The doc's pin must equal `config_pin` at
    `APPROVED_REV`, or it dies: "plan pin differs from the project config at the approved
    revision; run `agentic-flow config pin`, update `policy:`, commit, then
    `agentic-flow approve <doc> --by <login> --repin`". A pinless doc dies too: "new plans
    need a `policy:` line". There is no silent legacy fallback for a new plan.
  - **Later applies (any stamped issue).** The doc's pin must equal the stamped pin. The
    project config is **not** consulted, so a config change committed during a stamped plan
    never breaks a reapply.
- **Immutability.** It runs next to the topology check (`plan-to-issues.sh:469-489`) and
  covers **stamped issues only**:
  - every stamped issue must carry the same pin, and that pin must equal the doc's. A
    stamped issue with no marker carries the legacy pin;
  - otherwise it dies before any label, create, edit or close:
    "changing plan <id> policy from <old> to <new> requires a new plan".
  - **Partial applies and adoptions.** The stamped pin binds every issue still to be
    created and every unstamped adoption, which gets it on its first write. With no stamped
    issue, the doc's checked pin is written.
  - **Legacy issues.** A pinless doc applies only to a plan whose issues are already
    stamped (an in-flight legacy plan), and replays under the legacy pin. The marker is
    added to legacy issues only when the doc's pin equals the legacy pin. In every other
    case a pin on an existing issue is preserved byte-for-byte, like `journal=`.
- **Clarification.** `approve` stays offline and compares only the two doc revisions:
  - `$old.policy==$new.policy` passes;
  - adding a pin to a pinless approved doc passes, and `plan-to-issues` then applies the
    legacy-equality rule above;
  - any other pin edit is refused: "changed plan-pinned policy; re-plan required", unless
    `--repin` is given (below).

  A prose-only clarification therefore never changes the frozen pin, and its reapply
  compares against the stamped pin, not the current config.
- **Initial reapproval of an unstamped plan: `approve <doc> --by <login> --repin`.**
  This is the recovery path named by the first-apply refusal.
  - It accepts a changed `policy:` only when the new pin equals `config_pin` at `HEAD`.
    Every other clarification check (ids, profile, branch, steps) still applies.
  - It records a new approval revision, as any approval does.
  - `approve` is offline and cannot see whether issues are stamped, so it prints that
    `plan-to-issues` will refuse the new pin if any issue already carries one. That check
    then holds: with a stamped issue, the doc's pin must equal the stamped pin, so a
    `--repin` on a stamped plan dies before any mutation.
- **Controller backstop.** `handoff_drift`'s per-issue report gains `policy`.
  `controller_check` requires every stamped issue's pin to equal `CT_SPEC.policy`, or the
  legacy pin when the spec has none, and exits 3 on a mismatch like any other stamp drift.
  This intentionally reuses the existing exit rather than adding a hold reason.

### C-3 Replay under the pin

- `journal_context` reads at most one exact policy marker line. Zero lines give the legacy
  pin, unless the identity stamp carries `pin=v1`. Two lines, a malformed line, or a
  `pin=v1` stamp with no marker are an invalid stamp: exit 3, the same path as a missing
  plan stamp. It exports `JOURNAL_MAX_BOUNCES`, `JOURNAL_BLOCK_AT` and
  `JOURNAL_INFRA`.
- `journal_replay` passes `--argjson limit`. `successor` admits
  `bounces<limit` when `$bounces < $limit` and `bounces=limit` when `$bounces == $limit`.
- Every `workflow_successor` caller passes the issue's limit:
  `handoff.sh:109, 421` from `JOURNAL_MAX_BOUNCES`, and `controller_decide` from the
  report row.
- `controller_decide` escalates a bounce when `bounces >= max_bounces`.
- `status` takes the limit from the plan block's pin (legacy when absent) instead of
  parsing `workflow.tsv`.
- **Writer compatibility.** An older harness must not be able to advance a journal whose
  bounce limit it would compute differently.
  - **Older doc readers fail closed.** Older `brief_parse` rejects the unknown `policy:`
    field (`brief.sh:64`). So older `run`, `packet`, `verify-step`, `approve`, `status`,
    `ship`, `close-out`, `lifecycle-status`, `plan-to-issues` and the session hook all
    refuse a pinned plan.
  - **Older `handoff` is the gap.** Its `submit`, `bounce`, `approve`, `ask`, `resume` and
    `hold` events read only the issue. With `max_bounces=3`, an older writer treats the
    third bounce as an escalation and posts a `resume` from `escalated`. The new reader
    derives `executing`, rejects that `resume`, and then rejects every later event, which
    no longer matches the expected seq.
  - **Guard: transition marker v2.** An issue whose pin has `review.max_bounces` ≠ 2 is a
    v2 journal.
    - New writers put `agentic-flow-transition: v=2; …` on it (`handoff.sh:88, 131,
      146`).
    - New replay admits only `v=2` markers on a v2 journal and only `v=1` elsewhere
      (`journal.jq:34` takes the expected version as an argument). A wrong-version marker
      is counted in `skipped` and changes nothing.
    - Older readers match only `v=1`, so they see a v2 journal at its initial state. An
      older writer can post at most an ignored comment and stale labels, which the
      controller's label repair corrects. It cannot advance or fork the journal.
  - **Issues with a bounce limit of 2 stay v1.** Older and newer writers compute the same
    successors, and `review.block_at` is a controller gate, not replay.
  - **Older issue-body writers: the 0.21.0 JSON-spec path.**
    - `plan-to-issues.sh <spec.json>` never parses the Markdown brief, so it is not stopped
      by the `policy:` field.
    - With the same plan id it would regenerate tracker and step bodies without the policy
      marker. The new reader would then select the legacy pin and skip the existing `v=2`
      transitions.
  - **Guard: a pin token in the identity stamp.** Every issue that carries a policy marker
    also carries ` pin=v1` in its identity stamp, directly after `spec:<hash>`.
    - 0.21.0's `TRACK_STAMP_RE` / `STEP_STAMP_RE` (`plan-to-issues.sh:358-359`) allow only
      `journal=`, `approved=` and `approved-by:` after `spec:`. 0.21.0's `plan-to-issues`
      therefore dies "malformed identity stamp on issue #N" (`:386`) while indexing, before
      label creation or any edit. That holds on both the doc and the JSON-spec paths.
    - New readers treat a stamp with `pin=v1` but no valid marker line as an invalid
      stamp: exit 3, never the legacy pin. Any writer that drops the marker fails loudly
      instead of silently relaxing the policy.
    - 0.21.0's `journal_stamp` keeps its permissive tail (`journal.sh:15`), so older
      `handoff` still reads the issue, and the `v=2` guard above applies.
    - Unpinned (legacy) issues keep byte-identical stamps.
  - **What an older client can still do.** Older replay skips a `v=2` submit and accepts a
    later `v=1` submit at the same seq. An older client can therefore operate on its own
    divergent view. That divergence never reaches newer readers, which skip every `v=1`
    marker on a `v=2` issue. Hold and hold-clear markers carry no transition version and
    mean the same to both versions. The cost is noise comments and stale labels, which the
    controller repairs.
  - `plan-to-issues` still prints the upgrade reminder for pinned plans, because older
    clients see `v=2` plans frozen and cannot rewrite any pinned issue.
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
- **Reuse: the key describes the policy the tests actually ran under.**
  - **The problem.** `verify-step` computes its key in the caller's checkout
    (`verify-step.sh:144`). It runs the green checks in a detached checkout at the
    submitted SHA (`:165`), and the red-first checks at `red_base` with test paths restored
    from the SHA (`:184-188`). A digest taken from the caller's files could label a
    warn-green run as stop-green.
  - **One derivation.** `verify_record_key` adds
    `budget_policy:{context, green:<sha256>, red:[<sha256>…]}` and derives it only from its
    own arguments:
    - `green` hashes the policy files as they are **in the `<sha>` tree**;
    - each `red[i]` hashes them as they are in the `<red_base>` tree, with any policy path
      listed in that red-first entry's `paths` taken from `<sha>`, mirroring the overlay;
    - each digest also covers the effective `{wall_mode, wall_scale, fixtures_mode}`. Those
      are resolved from that tree's `.agentic-flow/config` plus this machine's operator
      file and env, under the C-1 rules for `context`.
    - The policy files are `.agentic-flow/config`, `config/config-keys.tsv`,
      `config/test-budgets.tsv` and `config/test-wall-ceilings.tsv`, read with
      `git show <rev>:<path>`. A missing path counts as defaults.
    - The caller's checkout is never read.
  - `verify-step`, `controller_verify` and `packet` all reach freshness through
    `verify_record_key` and `verify_record_fresh`, so all three share this derivation.
  - **In-flight attempts: the policy is fixed at the submit decision, not at verify.** A
    crash after `controller_verify` records green leaves the ledger at `pending=decide`
    (`ledger.pl:530`). The submit gate checks only `status eq 'green'` (`ledger.pl:288`),
    and `controller_decide` checks only `.status` (`controller.sh:532`). A warn-green
    verify could therefore become a submit after the operator switched to `stop`.
    - The ledger's `verify` record gains an optional `budget_policy`: the green digest at
      verify time.
    - Before a `submit` decision, `controller_decide` recomputes the green digest for the
      same head through `verify_record_key`.
    - If it differs, or the record predates the field, `controller_decide` reruns
      `controller_verify` for the same run before deciding. The ledger already accepts a
      further `verify` record before any decision (`ledger.pl:286`), and the newest one
      decides.
    - A rerun that comes back red routes to `fix` as today.
  - A record made under another policy is stale, so a warn-green record never satisfies a
    stop gate. Every existing record goes stale once.
  - CI needs no key change. Its policy comes only from tracked files, which the App input
    key already hashes. A test pins that none of the four policy files matches the
    bookkeeping filter.

### C-6 Retry for pre-launch infrastructure failures (gated on the safety floor)

- **Scope.** It applies only at the three sites that fail before the intent record
  (`controller.sh:796, 801, 880`). The post-intent site (`:940`) and every other reason
  stay `hold`.
- **Eligibility is per launch attempt, not per chain.** The three sites also run during a
  replacement dispatch (`controller.sh:826-834`), where the chain already has a
  predecessor intent. That predecessor's run has ended with its own record, so it does not
  block a retry.
  - The rule is that **this attempt** has written no intent.
  - The helper captures the ledger's intent count for `{issue, station}` when dispatch
    begins, and refuses to retry if it has changed.
  - A retried replacement writes exactly one intent, with the same `replaces` and the
    next `nth`.
- **Behaviour.** Under `andon.station-infrastructure=retry:N`, the controller retries
  instead of holding while all of these hold:
  - this invocation's consecutive pre-launch failures for `{issue, station}` are below N;
  - the plan worktree snapshot is clean (`recovery.pl snapshot`, `dirty=false`).

  A retry logs `station-infrastructure retry k/N: <cause>` to stderr, sleeps
  `min(30·2^(k−1), 300)` seconds (`AGENTIC_CONTROLLER_RETRY_S` overrides this in tests),
  and ends the turn. The turn counts against the turn cap.
- **Heartbeat.** There is no new `phase` value: the status reader allowlists phases
  (`status.jq:33-43`). The phase stays `reconciling`, and an optional
  `retry:null|{issue, station, attempt, of, until}` field is added. The f-6 status reader
  validates the field (a missing one reads as `null`) and renders `retry k/N until
  <time>`.
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
commit. So the reviewer packet (built in f-2) lists any change to `.agentic-flow/config`,
`config/config-keys.tsv`, `config/test-budgets.tsv` or `config/test-wall-ceilings.tsv`
under "Policy files changed". The range is the net diff from the approved revision, the
issue stamp's `approved=` (or its merge-base with the head when it is not an ancestor), to
the submitted head. Changes spread across several step commits are reported together; a
change reverted within the range is not. CI, the authority, reads only tracked files. Operator
files and env sit on the operator's machine. They can only relax local wall time and the
turn cap, which bounds work and is no safety control. Stations run under `env -i`, so env
overrides never reach them. Agents are denied `config set|unset` by the command policy.
**Mixed versions:** older doc readers refuse a pinned plan. Older `plan-to-issues`, on
either the doc or the JSON-spec path, dies on a pinned issue's `pin=v1` stamp before any
mutation. An older `handoff` cannot advance an issue with a non-default bounce limit,
because that journal uses `v=2` transition markers which older readers skip and newer
readers require. An older client's divergent view never reaches newer readers (C-3
*Writer compatibility*). Config values never hold secrets. The registry has no
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
  This repo's `.agentic-flow/config` (the f-2 template) leaves `budget.wall.mode.ci`
  commented, so the scaffold runs under the same default its adopters get. Wall-time
  overruns in this repo's CI are recorded, not enforced.

---

# Part B — Implementation Brief

## Acceptance scenarios
- Given an issue with two policy markers or a malformed one, when it is replayed, then replay exits 3 and nothing is journaled.
- Given an issue without a marker, then replay, `handoff` and `controller_decide` escalate on the third bounce exactly as today.
- Given an issue pinned to `review.max_bounces=3`, then the third bounce returns to `executing` and the fourth escalates. `status` shows `bounces n/3`.
- Given a locally kept legacy `workflow.tsv`, then legacy-pin issues replay unchanged, and a `review.max_bounces=3` issue exits 3 naming the upgrade candidate.
- Given a `max_bounces=3` issue at two bounces, when 0.21.0-format `v=1` comments post a bounce and then a `resume` from `escalated`, then the new reader skips both, its state and seq are unchanged, and the next `v=2` handoff is admitted. A frozen copy of 0.21.0's transition regex matches none of the issue's `v=2` markers.
- Given a pinned tracker and step issues, when frozen copies of 0.21.0's `TRACK_STAMP_RE` and `STEP_STAMP_RE` index them through the JSON-spec path, then indexing dies "malformed identity stamp", with zero mutating `gh` calls and the bodies unchanged.
- Given a stamp with `pin=v1` whose marker line was removed, then replay exits 3 and never selects the legacy pin.
- Given a `v=2` issue, when an older client's `v=1` submit lands at the same seq as an existing `v=2` submit, then the new reader's state, seq and admitted events are unchanged.
- Given a doc with `policy:`, then `status` and replay read the pin in f-1, before any writer exists.
- Given `AGENTIC_FLOW_PACKET_WORD_LIMIT` or an operator-file value for a project key, then `config` and every consumer exit 2 naming the source.
- Given an unknown key, a duplicate key or an out-of-range value in `.agentic-flow/config`, then `config list` exits 2 with `file:line`, and `run` refuses before taking the lock.
- Given `controller.turn_cap=12` in the operator file, then `config explain controller.turn_cap` names the operator file, and the controller stops at 12 turns.
- Given an agent hook context, then `config set` and `config unset` are denied.
- Given a fresh adoption, then `.agentic-flow/config` lists every registry key commented at its default, and `config list` shows every source as `default`. Given an existing file, `config init` refuses, and `config init --missing` appends only the absent keys.
- Given no stamped issue and a doc pin that differs from `.agentic-flow/config` at the approved revision (for example, after `main` changed policy during drafting), then `plan-to-issues --apply` exits non-zero after its discovery reads, naming `config pin` and `approve --repin`. The `gh` sentinel records only read calls and zero mutating ones.
- Given that refusal, when the planner runs `config pin`, updates `policy:`, commits, and runs `approve --repin`, then the new approval is staged, and after its commit `plan-to-issues --apply` succeeds with the refreshed pin.
- Given `approve --repin` with a pin other than `config_pin` at `HEAD`, then `approve` refuses. Given `--repin` on a plan whose issues are already stamped, then `approve` passes with its warning and the next apply dies before any mutation.
- Given no stamped issue and a pinless doc, then the first apply refuses.
- Given stamped issues pinned to `max_bounces=2` and a doc now pinned to `3`, then `plan-to-issues --apply` dies before any label, create, edit or close, including after a partial earlier apply.
- Given stamped issues and a current project config that differs from their frozen pin, then a reapply of the unchanged doc succeeds against the stamped pin.
- Given an interrupted Strict adoption whose tracker is stamped with the doc's `medium` pin and whose remaining step is an unstamped `--adopt` candidate, then the reapply stamps the step with that pin. With the doc's pin changed, it dies before any mutation.
- Given legacy issues and a doc whose pin equals the legacy pin, then the reapply adds the marker. Given any other pin, it dies.
- Given an existing doc without `policy:` and already-stamped issues, then its spec hash and issue bodies are byte-identical to before.
- Given a clarification that edits the pin, then `approve` refuses. Given one that edits only prose, or adds a pin to a pinless approved doc, it succeeds. In the prose-only case, the reapply passes even though the project config changed after stamping.
- Given a hand-edited marker that no longer matches the spec, then the controller exits 3 with the stamp-drift error.
- Given `review.block_at=medium`, then an approve with a `medium` (or `P2`) finding and a bounce with only `low` and `nit` findings each journal an `ask`. An approve with only `nit` findings is journaled as an approve.
- Given the legacy pin, then those same results journal as they do today.
- Given every stored result fixture using `P1`–`P3`, then all still validate.
- Given `budget.wall.mode.local=warn` and an overrun, then `self-test` exits 0, prints the warning, and records the row. `doctor` lists the budget and the row. Under `stop`, the same overrun fails with today's text.
- Given `CI=true` and no config file, when a wall ceiling is overrun, then `self-test` exits 0, records the overrun, and writes "wall time not enforced" to the step summary. With `budget.wall.mode.ci=stop`, the same overrun fails.
- Given `CI=true` and `AGENTIC_FLOW_BUDGET_WALL_MODE_LOCAL=warn`, then the CI mode applies, and the ignored value is reported once.
- Given a verify record made under `warn`, then a check under `stop` treats it as stale and reruns.
- Given a controller that crashes at `after-verify` with a warn-green record, when the operator switches to `stop` and restarts, then `controller_decide` sees a different digest and reruns `controller_verify` before deciding. With an overrun the rerun is red and routes to `fix`; no `submit` is journaled from the warn-green record.
- Given a caller checkout with `budget.fixtures.mode=stop` and a submitted SHA that commits `warn`, then the record's `budget_policy.green` equals the digest of the SHA's tree, not the caller's. A red-first entry whose `paths` include a policy file takes that file from the SHA. `verify-step`, `controller_verify` and `packet` compute the same key.
- Given a step whose submitted commits change `.agentic-flow/config` in one commit and `config/test-budgets.tsv` in another, then the reviewer packet lists both under "Policy files changed". A change reverted within the range is not listed.
- Given `andon.station-infrastructure=retry:2` and a probe that fails twice and then succeeds, then the station launches with no hold. Given three failures, then one hold whose note says "after 2 automatic retries".
- Given a replacement dispatch whose chain has a predecessor intent, when the probe fails once and then succeeds, then exactly one new intent is written, with the predecessor's `replaces` and the next `nth`.
- Given a retry backoff, then the heartbeat keeps `phase: reconciling` with a `retry` object, and `status` renders it without marking the heartbeat invalid.
- Given a retry pin and a dirty worktree, or a failure after this attempt's intent record, then the controller holds at once.

## Invariants
- With no effective project value (no `.agentic-flow/config`, or only the commented template) and on legacy-pin issues, the controller, `handoff`, `packet`, `status` and `self-test` behave as today, with two exceptions. `verify` records are recomputed once. A CI wall-time overrun warns instead of failing (owner decision), unless the project sets `budget.wall.mode.ci=stop`.
- Replay never reads the active config. One issue body and one journal derive one state on every machine running this version.
- A pin never changes on an issue once it is written, and no harness version, older or newer, can remove it without replay failing.
- A `submit` is journaled only from a green verification whose budget digest matches the policy in force at the decision.
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
make test-one F=stations S=packet           # f-2 (policy-files section)
make test-one F=plan-to-issues              # f-3
make test-one F=controller S=status         # f-1, f-3
make test-one F=controller S=andon          # f-4, f-6
make test-one F=stations S=verify           # f-5
make test-one F=controller S=recovery       # f-5 (restart at after-verify)
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
  - add the read-only `policy:` parsing to `brief_parse`, with version-1 pin validation
    (C-2 *Parsing*), and make `status` read the plan block pin through it;
  - add the transition-marker version rule (C-3 *Writer compatibility*): `v=2` on issues
    whose limit is not 2, written at `handoff.sh:88, 131, 146` and required by
    `journal.jq:34`;
  - accept the ` pin=v1` stamp token in `TRACK_STAMP_RE`, `STEP_STAMP_RE` and
    `journal_stamp`, and fail replay with exit 3 when the token is present but the marker
    is missing.
- One marker-line regex and one pin validator are shared by bash and jq. Never match
  either loosely.

**Test:**
- Replay fixtures for: no marker; `max_bounces` 1 and 3; duplicate and malformed markers;
  a deprecated `workflow.tsv` with legacy and non-legacy pins.
- Handoff legality at the limit.
- `controller_decide` escalation at the pinned limit.
- The `status` limit display from a hand-written `policy:` line.
- The old-writer / new-reader sequence, and the frozen 0.21.0 regex against `v=2`
  markers.
- An older client's `v=1` submit at the same seq as a `v=2` submit.
- A `pin=v1` stamp with its marker removed.
- Every existing journal fixture replays byte-identically.

**DoD:** legacy issues derive exactly today's states; pinned issues obey their own limit everywhere a successor is computed.
**Verify:** `make test-one F=stations S=handoff` and `make test-one F=controller S=status`
**Risks:**
- A caller left on the default `limit` of 2 would diverge silently. Grep for every
  `workflow_successor` and `bounces` use.
- `status.jq`'s `limits` parser must stop reading `workflow.tsv`.
- A v2 issue's own writers must never emit `v=1`. Derive the version from the issue's pin
  at every write site, not from a global.
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
- Add `config list|get|explain|set|unset|init` to `scripts/agentic-flow` and its usage
  text. `init` renders C-1's commented template from the registry.
- `scripts/init.sh` runs `config init` at adoption. Commit this repo's generated
  `.agentic-flow/config`. `doctor` reports a missing file and unlisted keys as information.
- Add command-policy rows denying `config set` and `config unset` to agents, following the
  `approve` rows (wider prefix where a row cannot be expressed exactly), and regenerate.
- Wire the first consumers: `controller.turn_cap` (`controller.sh:1018`) and
  `packet.word_limit` (`packet.sh:85, 190`).
- Add `config pin` (prints the canonical pin) for f-3's draft refresh.
- Add the reviewer packet's "Policy files changed" section (Threat model): the net diff of
  the four policy paths from the stamp's `approved=` revision (or its merge-base with the
  head) to the submitted head.
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
- `config init` output lists every registry key exactly once, commented out, and loads with
  every value sourced from `default`.
- `init` refuses an existing file. `--missing` appends only absent keys and leaves the
  existing bytes unchanged.
- `set` then `unset` round-trips the template line.
- An exported adoption has the file.
- Policy changes spread over several step commits are listed. A change reverted within
  the range is not. A non-ancestor approved revision falls back to the merge-base.

**DoD:** every C-1 key resolves with its source; invalid config fails closed before the controller lock; agents cannot change a value; new adoptions and this repo carry the commented template; reviewers see every policy-file change since approval.
**Verify:** `make test-one F=contracts`, `make test-one F=stations S=packet` and `make test-one F=controller S=status`
**Risks:**
- The loader must not run `gh` or the network.
- `env -i` stations must still load defaults without `HOME`.
**Red-first:** none
**Commit:** `Add the config registry, loader and agentic-flow config`

---

## F-3 — Capture the pin at approval and refuse to change it
**Why third:** with replay and the loader in place, this makes pins real and immutable.

**Approach:**
- Implement C-2's capture, apply and clarification rules (f-1 already parses the pin):
  - `start` writes `policy:` from `config_pin`;
  - `plan-to-issues` classifies indexed issues as stamped or unstamped adoptions;
  - on first apply it checks the doc's pin against the config at `APPROVED_REV`, and on
    later applies against the stamped pin;
  - it runs the stamped-only immutability check before any mutation, next to the
    topology check;
  - the pin check runs after the discovery reads and before any mutation;
  - it writes the marker, plus the stamp's ` pin=v1` token, for new issues, unstamped
    adoptions and legacy-equal issues, and preserves existing markers and tokens
    byte-for-byte (`migrate_approval_body` included);
  - `approve` applies the clarification rule, and `--repin` the initial-reapproval rule;
  - `handoff_drift` and `controller_check` compare pins.
- Print the upgrade reminder for v2 plans.

**Test:**
- First-apply mismatch after a base policy change, and a pinless first apply.
- Changed pin over full and partial applies.
- A config change after stamping, followed by a successful reapply.
- An interrupted Strict adoption: stamped tracker, unstamped step.
- Legacy add-only case.
- Byte-identical bodies and spec hash for a pinless in-flight doc.
- `approve`: pin edit refused; prose-only and pin-added pass.
- The full recovery sequence: first apply refused, `config pin`, commit, `approve --repin`,
  commit, apply succeeds.
- `--repin` with a non-current pin is refused; `--repin` on a stamped plan dies at apply.
- Frozen 0.21.0 stamp regexes die on pinned issues through the JSON-spec path.
- Hand-edited marker leading to controller exit 3.
- A `gh` sentinel on every refusal: read calls allowed, zero mutating calls.

**DoD:** a pin is fixed by the first stamp, from the approved revision's config; every later path compares against the stamped pin and refuses a change before mutating.
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
  - add `budget_policy` to `verify_record_key`, derived only from its own arguments (the
    `<sha>` tree for green, and the overlaid `<red_base>` tree for each red-first entry),
    never from the caller's checkout;
  - add the optional `budget_policy` to the ledger's `verify` record (`ledger.pl:197`
    validation included), and make `controller_decide` rerun `controller_verify` when the
    digest at decision differs (C-5 *In-flight attempts*).
- **Red-first lives in a test-only file.** Restoring the new `scripts/self-test.sh` onto
  a base without `config/test-budgets.tsv` would fail its strict loader. That failure
  could match the broad `^self-test failed:` signature, or block valid red evidence.
  - The red-first entry therefore lists only `scripts/tests/contracts.sh`.
  - Its new test builds every budget and config file it needs inside its own fixture, and
    calls the base's own wall-ceiling check under a `warn` policy.
  - At the base it fails with the distinctive line
    `self-test failed: budget-mode: warn overrun still failed`.
  - The reviewer confirms that line in the record's red tail. A red caused by anything
    else is not valid evidence.
- Remove the limit literals from `self-test.sh`.
- Raise the copy budgets to measured values, in the TSV.

**Test:**
- `warn` and `stop` for a wall overrun and a fixture overrun.
- Scale 2.0 doubles the limit locally and is ignored in CI.
- CI ignores and reports env.
- Concurrent runs both record.
- Pruning keeps 20 files.
- A warn-made verify record is stale under `stop`.
- A caller checkout and a submitted SHA with deliberately different policies: the key
  follows the SHA. A red-first entry that overlays a policy file uses the overlaid copy.
  `verify-step`, `controller_verify` and `packet` agree.
- A restart at the `after-verify` fault after a switch from `warn` to `stop`: the
  controller reverifies before deciding, and no submit comes from the warn-green record.
- The red-first tail contains the distinctive `budget-mode:` line.
- None of the policy files matches the bookkeeping filter.

**DoD:** every budget honours its mode, every warn is recorded and reported, and no warn-green result is reused under stop.
**Verify:** `make test-one F=contracts`, `make test-one F=stations S=verify` and `make test-one F=controller S=recovery`
**Risks:**
- `make check` runs in fixtures that copy the checkout; the overrun directory must
  resolve to the fixture's common dir, not the source's.
- See the `lint-before-push` memory for the copy budget.
**Red-first:** `scripts/self-test.sh --only contracts` — scripts/tests/contracts.sh
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
- Eligibility is per launch attempt (C-6). Capture the ledger's intent count for
  `{issue, station}` at dispatch start, and refuse a retry if it has changed.
- Heartbeat: keep `phase: reconciling` and add the optional `retry` object. Update the
  `status.jq` heartbeat validator and renderer in this step.

**Test:**
- Probe failing twice, then succeeding.
- Three failures leading to one hold.
- A replacement dispatch with a predecessor intent: retry, then exactly one new intent
  with the right `replaces` and `nth`.
- A heartbeat carrying `retry` that `status` validates and renders.
- Dirty worktree leading to an immediate hold.
- A failure at `:940` leading to an immediate hold.
- Turns consumed and bounded by the cap.
- The `hold` pin unchanged.
- The backoff override keeps the `controller:andon` ceiling.

**DoD:** transient pre-launch failures recover without a human under `retry:N`; nothing after the intent record is retried.
**Verify:** `make test-one F=controller S=andon`
**Risks:**
- A retry must never run after **this attempt's** intent exists. A predecessor intent in
  a replacement chain is expected. Assert it from the ledger's intent count captured at
  dispatch start, not from the call site.
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
