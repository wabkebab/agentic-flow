<!-- TRIAGE (first pass · 2026-11-17) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> **Assurance:** Strict
> Phase 2b of `product-harness-factory-optimization.md` (P-1 to P-7, plus T-1, T-3 and T-4 moved in from Phase 3 on 2026-11-17): make controller-run stations fail before launch, not mid-step, make the remaining failures cheap to diagnose, and make this phase's own test iterations fast. Found by running Phase 2's controller on its own steps C-6 and C-7. Part A is the analysis; Part B is the implementation brief, awaiting approval. Runs after Phase 2 (merged, PR #149) and before Phase 3 (`feature-test-streamlining.md`).

# Feature — Station hardening

## Tracker
<!-- Filled in when the brief is approved and plan-to-issues runs. -->
- [ ] Brief drafted 2026-11-17; awaiting approval. Steps h-1 to h-8 are listed in Part B.

---

# Part A — Analysis

## Goal

Phase 2's controller ran its first real stations on C-6 and C-7. It hit nine launcher and ledger defects that 600+ seconds of offline tests did not catch, and all five approver `resume`s in C-7 were for launcher faults, not for questions about the step. Every later phase executes through this controller, so it has to be reliable first.

The same runs cost 10 minutes per controller-group test run, three to four times per commit. This phase is about to touch the controller again, so it takes the three cheapest, launcher-independent test-cost items from Phase 3 and does them first (decided 2026-11-17).

Success:

- a launcher defect is found by a probe in seconds, before a plan's first station runs;
- an infrastructure failure does not cost the approver a `resume`;
- a failed station's output survives for diagnosis;
- a retry never spends itself resuming a session the CLI already rejected;
- a step can verify the controller scenarios it touched in minutes, not 10, and a commit is verified once, not three or four times.

## Current state

References are to `main` at `3cb787d` (Phase 2 merged).

### Defects found by dogfooding

Every one passed the offline suite. The stub CLIs shared the launcher's assumptions: they accepted any `-c` key, any session id and only bare JSON.

| Commit | Defect | Cost |
|---|---|---|
| `e76282a` | Connector-disable keys were JSON-quoted, and Codex 0.169 takes quotes in a `-c` key literally ("invalid transport"). | Preflight refused every Codex launch |
| `efc36e0` | A linked worktree keeps its index and the shared objects and refs outside the `workspace-write` sandbox, so a station could edit files but never commit. | Andon, `resume` |
| `1d738bd` | Codex makes `.agents/` read-only beneath any writable root. It is writable only as a root of its own. | Andon, `resume` |
| `c5b3859` | `ulimit -f 65536` (32 MB) killed Codex with SIGXFSZ (exit 153), because its global state databases are larger. | Two andons; looked like "malformed result" |
| `75b390d` | A caller-chosen OpenCode session id loses the user's provider (free-tier 429), and a plain UUID is rejected outright. | Reviewer exit 1 |
| `d490771` | OpenCode only resumes ids it issued (`ses_…`), and the chain kept resuming a stale UUID. | Andon, `resume` |
| `fa49bef` | The same file-size cap killed OpenCode's standalone server (its database is 254 MB). | Hidden behind the session-id bugs |
| `8148e32` | The ledger accepted a `session` record only for Codex, so recording OpenCode's own id failed the launch. | Andon, `resume` |
| `c79f01a` | OpenCode cannot enforce an output schema. Its reviewer ends with prose plus JSON, and the parser required bare JSON. | A completed 893 s review recorded as malformed; andon, `resume` |

### Process defects seen in the same runs

- **Salvage blocks the plan branch.** A commit on the plan branch while a salvage is pending re-raises `worktree-changed-after-salvage` on every reconcile (`scripts/lib/controller.sh:267-280`). Clearing the hold does not re-baseline. The only way out was `reset --hard` and restarting the step.
- **Infrastructure faults escalate the step.** A launch that dies before the CLI starts (no tokens, under 5 s) is recorded as an invalid result (`station exit N`, `controller.sh:630`). `ledger.pl:341` counts every invalid result toward a cap of two, then renders an `ask` with `malformed station result`, which moves the step to `escalated` and needs the approver's `resume`.
- **Retries resume dead sessions.** `controller.sh:570-576` resumes any earlier session of the same CLI and profile path. It does not ask whether that attempt captured a session or used tokens, nor whether the launcher changed since.
- **Failed output is lost.** `launch_station` deletes the station's events and stderr with its scratch directory (`scripts/lib/launch.sh:307`), so diagnosing the parser fault needed a `PATH` shim that copied OpenCode's stdout.
- **Unexplained, not investigated:** every `run` prints `repaired #138: hold-projection`, often twice, so that repair is not sticking (`controller.sh:730`). `metrics` reports tokens as `n/a` although the ledger holds Codex usage (for example 1,193,961 input tokens). One lead: `usage_sum` (`ledger.pl:379-386`) returns unknown for the whole plan as soon as any run has no station record or a null field.

### What the controller already has (do not rebuild)

- Holds are free-form kebab-case reasons posted by `controller_hold` through `handoff hold --as approver`, and every hold already @-mentions `REVIEW_OWNER` and raises a desktop notification (`scripts/lib/andon.sh:6-7,113-118`). A new hold kind is a new reason string, not a new mechanism.
- `launch_preflight` runs the unattended checks without a model call. It is the place to add nothing: the probe is a separate command with real model calls.
- `verify-step` writes `<common>/agentic-flow/verify/<sha>.json` (`verify-step.sh:200-206`) and `packet.sh:91-105` already refuses a record whose sha, tree or verifier hash differs. The reuse key for T-1 is stricter, because that record names neither the step nor the commands it ran.

### Test cost, measured

From Phase 3's analysis (`feature-test-streamlining.md`, "Measured test cost"): the controller group grew from 32 s to 673 s across C-3 to C-6; a full `make test` takes 32 min 10 s; Phase 2's last fixes took 15 runs of the controller group at about 10 minutes each, six of them for one failing assertion. `scripts/tests/controller.sh` is 1,729 lines in five blocks, with about 83 `c4_run`/`c5_run` invocations. Nothing measures a scenario's time (T-3) and nothing selects one (T-4).

## Proposed approach

| ID | Change |
|---|---|
| T-3 | **Profile first** (moved from Phase 3). `AGENTIC_TEST_TIMING=1` reports seconds per top-level block, the slowest `c4_run`/`c5_run` calls by source line, and fixture-reset totals. It turns T-4's tag boundaries into a measured decision. |
| T-4 | **Scenario selection for the `controller` group** (moved from Phase 3, controller group only). `make test-one F=controller S=<tag>[,<tag>…]` runs tagged blocks. The tag vocabulary is fixed here: `launch`, `ledger`, `recovery`, `ship`, `andon`. T-3's profile may add tags, never rename these. The `stations` group's tags, the `tests/<group>.sh` split (R-15) and parallel shards stay in Phase 3. |
| P-1 | **Real-CLI probe.** `agentic-flow doctor --stations` launches each assigned CLI through the real launcher, sandbox, environment and limits with a fixed tiny prompt. It checks exit status, session capture, result parsing, and that the sandbox allows writes to the worktree, `.agents/` and the commit paths and denies writes to the verify and ledger directories where the CLI has an OS sandbox. `run` probes a station when its fingerprint changed since the last passing probe (decided 2026-11-17). Six of the nine defects would have failed it (quoted keys, commit paths, `.agents/`, both file-size caps, the OpenCode session id), and a seventh if it records its session through the ledger. Resume and verdict-format faults still need a real station run. |
| T-1 | **Verify once per commit** (moved from Phase 3, lands after P-1 because its threat model needs P-1's tested boundary). `verify-step` returns the stored record when it names the same commit, tree, step, red base, command list, verifier hash, signature source, harness version and tool versions and passed; `--force` re-runs. The reviewer reads the packet's record and re-runs only a narrower command it names (decided 2026-11-17). |
| P-2 | **Keep failed output.** On an invalid result, store bounded events and the stderr tail under the run's ledger directory and name the path in the andon comment. |
| P-3 | **Fresh session after a dead one.** If the previous attempt failed before launch (no session, no tokens, under 5 s), or the launcher fingerprint changed since the session started, the retry starts a fresh session instead of resuming. |
| P-4 | **Operator hold for infrastructure faults.** A pre-launch failure raises a `station-infrastructure` hold on the tracker instead of escalating the step. It does not count toward the invalid-result cap, and the existing owner mention applies (decided 2026-11-17). Clearing it retries without a journaled `resume`. A station's real question still escalates the step. |
| P-5 | **Salvage re-baseline.** `hold clear --rebaseline` records a fresh salvage snapshot on top of the new HEAD, so a fix committed to the plan branch does not force `reset --hard`. |
| P-6 | **Explicit verdict format for schema-less CLIs.** The OpenCode prompt states that the final message is only the result JSON. The parser stays lenient. |
| P-7 | **Investigate** the repeated `hold-projection` repair and the missing token totals in `metrics`, and fix or record each. |

**Ordering.** T-3 and T-4 first: they make every later step's iterations minutes, not 10. Then P-1, which turns the next launcher regression into a preflight failure and sets the boundary T-1 relies on. T-1 next, because from then on every commit is verified once. Then P-2 so anything P-1 misses can be diagnosed, P-3 and P-4 together (they share the launcher fingerprint P-1 introduces), P-5, and P-6 with P-7.

## Interface (before the implementation)

```
# T-3
AGENTIC_TEST_TIMING=1 scripts/self-test.sh --only controller
  stderr, after the run: seconds per top-level block; the 15 slowest c4_run/c5_run
  calls as "<seconds> <test-file>:<line>"; reset count and total seconds.
  unset: output byte-identical to today.

# T-4
make test-one F=controller [S=<tag>[,<tag>…]]
scripts/self-test.sh --only controller [--scenario <tag>[,<tag>…]]
  tags: launch ledger recovery ship andon     (every existing block carries exactly one)
  no --scenario: the whole group, as today
  unknown tag: exit 2, nothing runs;  selection that runs no block: self-test fails
  S= with any F other than controller: exit 2

# P-1
agentic-flow doctor --stations [--station executor|reviewer] [--json]
  per station: {station, cli, launched, exit, session_captured, result_parsed,
                writable: {worktree, agents, commit_paths},
                denied:   {verify_dir, ledger_dir},   # true | false | "unenforced"
                attempts: {<operation>: {ran, exit, error}},  # evidence from the probe script's log
                # a property passes only with an attempt entry AND the matching filesystem state;
                # a missing entry fails as "attempt not made", and a missing file never proves denial
                seconds, error}
  exit 0 all pass; 1 any fail; 6 a station is manual or unconfigured and was skipped
fingerprint(station) = sha256 over: scripts/lib/launch.sh, scripts/lib/station-output.jq,
  scripts/lib/station-config.pl, the profile file, the station's roles row, and the
  output of `<cli> --version`
<common>/agentic-flow/probe/<station>.json = {fingerprint, passed_at, seconds}   # last passing probe

# T-1
agentic-flow verify-step <sha> [--doc <doc> --step <id>] [--red-base <sha>] [--force] [--json]
  reuse: a passing record whose sha, tree, step id, red base, ordered command list,
         verifier digest, signature-source Makefile blob, harness version and tool
         versions all equal what this call would run → print it, exit 0, run
         nothing, say "reused"
  verifier digest = sha256 over scripts/lib/verify-step.sh AND scripts/lib/verify-record.sh
         (stored as verifier.implementation_sha256; packet computes it with the same function)
  passed: the record stores `passed`, and every command entry stores `role`
         (green | prepare | red-first). Green and prepare entries must exit 0. A red-first
         entry is an expected failure: it must exit nonzero with status `red` in `red_first`.
  --force: always run; overwrite the record
  one shared predicate (scripts/lib/verify-record.sh) is used by verify-step and by packet

# P-2
<ledger>/runs/<plan>/<issue>/<seq>/<station>/<chain>/<n>/
  events.tail (≤ 256 KiB, the last bytes), stderr.tail (≤ 64 KiB)   # invalid results only
  provider key values from the launch environment are redacted before writing

# P-3 / P-4
retry policy: resume only when the prior run captured a session, used tokens,
              and the fingerprint is unchanged; otherwise fresh
pre-launch failure: nonzero exit, no session, no tokens, under 5 s
                    → ledger station record with invalid_reason "pre-launch failure: …",
                      not counted toward the invalid-result cap, hold reason
                      station-infrastructure on the tracker, chain ended `held`

# P-5
agentic-flow hold clear <doc> <hold-id> [--rebaseline] [--note <text>]
  --rebaseline: the clear marker records it; the next reconcile saves a salvage ref of
                the current state and uses the new HEAD as the baseline
```

## Threat model

The probe runs real CLIs with the user's provider credentials, under the same isolation as a station, with a fixed prompt and no repository content. Since `efc36e0` the Codex sandbox can write the shared `objects`, `refs/heads` and `logs`. That is what a commit needs, and none of those directories holds verify records or the ledger. P-1 makes that boundary a tested property for the CLIs that have an OS sandbox (Codex, Claude): a station that can write the verify or ledger directory could forge evidence, and T-1's reuse relies on it. **OpenCode has no OS sandbox**, so the property cannot be tested for it; the probe reports `unenforced` rather than a pass. The residual is small under the controller's ordering. A record is keyed by commit and tree, the reviewer only ever sees a head that is already verified, and the executor, whose commits are the new heads, runs in a sandbox that denies the directory. A reviewer could not know a future head's sha. Step h-3 adds this exposure to the `opencode-station-network` accepted risk so it is on record. Stored output tails can contain whatever the station printed, so they stay in the git common directory, which is never pushed, and the provider key values are redacted.

T-1 turns a stored record into permission to skip a gate. The key therefore includes everything that decides the outcome (commit, tree, step, red base, command list, a digest of every verifier file, signature source, harness and tool versions), and only passing records are reused, where "passing" means green commands exited 0 and red-first commands failed as expected. A human can still edit a record by hand, as they can skip any local gate today. CI does not use local records and runs the full suite.

## Failure behavior

| External call | On timeout | On malformed response | On partial success |
|---|---|---|---|
| Station probe | That station fails the probe; reported, no state change | Result not parsed → probe fails with the bounded output tail | Per-station report; one failing station does not hide the others |
| Probe inside unattended `run` | Fails like a probe; raises the `station-infrastructure` hold, starts no station | Same | Stations already probed clean still run after the operator clears the hold |
| Station launch, pre-launch failure | Operator hold (P-4) | n/a | n/a |
| Station run, invalid result | Existing retry chain, now with P-3's fresh-session rule | Output tails stored (P-2) | Salvage as today |
| `verify-step` reuse lookup | n/a (local file) | Unreadable, oversized or mismatched record → run the full verification | n/a |
| Scenario selection | As the group | Unknown tag → exit 2, nothing runs | n/a |
| `hold clear --rebaseline` | n/a | A clear without the marker behaves as today | A crash after the clear posts and before the salvage is recorded replays on the next reconcile |

Bounds: probe prompt fixed, 120 s per CLI; stored tails 256 KiB events and 64 KiB stderr per invalid run; a record read is capped at 256 KiB (as `packet.sh` does today); a timing report lists 15 calls.

## Out of scope / What NOT to build in this pass

- The rest of test streamlining: T-2, T-5 to T-8, R-15, the `stations` group's scenario tags, parallel shards and wall-time ceilings stay in Phase 3.
- Cleanup items (Phase 4).
- Supporting new station CLIs.
- Unattended mode changes beyond the hold in P-4.
- Sharing verify records across machines or with CI.
- Changing what any test group asserts. T-3 and T-4 change how the controller group runs and is selected, not what it checks.

## Decisions

- **P-4 notifies like an andon** (owner, 2026-11-17). The operator hold @-mentions the owner on the tracker, as R-9 does, so an unattended run never stalls silently. This is the existing hold behavior, so it costs nothing new. It stays an operator hold, not a step escalation: clearing it needs `hold clear`, not the approver's `resume`.
- **P-1 runs only on change** (owner, 2026-11-17). `run` probes a station when its fingerprint differs from the last passing probe; `doctor --stations` forces a probe. Each probe makes real model calls, so it does not run before every station. The fingerprint includes the CLI's `--version`, because Codex 0.169's quoting change is what broke the first launches.
- **T-1: a doubting reviewer runs a narrower command** (owner, 2026-11-17). It names the command it runs, for example one scenario, and records it with its verdict. `--force` stays for a human or an executor who changed the environment; it is not the reviewer's tool.
- **T-3, T-1 and T-4 move into this phase** (owner, 2026-11-17). They are small and do not touch the launcher, and they cut this phase's own iteration cost. T-1 must follow P-1. T-4 covers the `controller` group only.
- **Controller runs of this brief record every human `resume` and its cause** in the close-out, as the measure of whether P-1 to P-4 worked (C-7 baseline: five).
- **An unattended preflight failure raises the same hold** (owner, 2026-11-17). `launch_preflight` failures returned exit 6 (`controller.sh:565`) and stopped the loop with no hold, so an unattended run stalled silently. P-4 now raises the `station-infrastructure` hold for them too. `run --once` keeps exit 6.
- **OpenCode's write exposure goes on record** (owner, 2026-11-17). Step h-3 adds one paragraph to `docs/accepted_risks.md#opencode-station-network` saying OpenCode can write the verify and ledger directories, and why that is acceptable under the controller's ordering.

## Open questions

- None open.

---

# Part B — Implementation Brief

> **Audience:** the implementing agent (Codex). Steps are ordered tests first, then the probe, then reuse, then the failure paths. One logical commit per step; do not bundle. Stage files by name. Why-first commit bodies. The brief carries intent, interface, invariants and acceptance scenarios; you choose files and functions.

```agentic-flow-plan
id: station-hardening
profile: strict
tracking: Plan: Station hardening
branch: phase-2b
steps: h-1 h-2 h-3 h-4 h-5 h-6 h-7 h-8
```

## Prerequisite

Phase 2 is merged and closed out (PR #149, `0.16.0`; the missing final-head approval is accepted risk C-8). `.agentic-flow-review-policy` says `identity-mode=distinct-account`, and `agentic-flow token <role> --check` passes for executor, reviewer and approver on the operator's machine. If the policy has changed, stop and tell the human. Do not run this brief under `single-operator`.

## Branch
Base: `main`. One branch and one PR for the whole brief: `phase-2b`. Each step is one commit with `Fixes #N`. Review fixes land as new commits; never amend after a handoff. The controller's worktree owns the branch; do not also check `phase-2b` out in another worktree.

## Word ceilings

| File | Ceiling | Enforced by |
|---|---|---|
| `CLAUDE.md` (root) | 1530 | `scripts/self-test.sh` (planner) |
| `AGENTS.md` (root) | 1090 | `scripts/self-test.sh` (executor) |
| `.agents/skills/review-execution/SKILL.md` | 1000 | `scripts/self-test.sh` (reviewer) |

Do not raise a ceiling. Only h-4 edits a contract: the reviewer skill, which is at 940 of 1000 words, so the edit must trim as much as it adds. A contract edit to `CLAUDE.md` or `AGENTS.md` would need the matching edit in `templates/harness/`; this brief makes none.

## Invariants (every step)
- Bash 3.2: no `mapfile`, no associative arrays, guard empty arrays under `set -u`.
- New payload files are declared in `config/payload.tsv` only. `scripts/lib/` is already one payload row.
- No literal placeholder or credential-shaped string in any file; build them with `printf`. This includes test fixtures and the redaction test.
- Every GitHub write goes through `handoff`, `plan-to-issues.sh`, `ship`, `final-approve` or the hold path. The controller never calls `gh issue edit`, `gh issue comment` or `git push`.
- The journal is the only authority. Labels, the state cache, the ledger and the probe state are never the reason for a transition.
- Hermetic tests: fake `gh` and fake `claude`/`codex`/`opencode` executables on `PATH`. No network and no real model call in `make test`. The probe is the only code that makes real model calls, and only from `doctor --stations` or from an unattended `run` whose fingerprint changed.
- A fake CLI must be strict where the real one is: reject quoted `-c` keys, unknown session ids and non-bare JSON where the real CLI does. A stub that accepts anything is how the nine defects passed.
- New and changed tests live in `scripts/tests/controller.sh` or `scripts/tests/stations.sh`, inside a block that carries a scenario tag (from h-2 on).

## Definition of done (whole brief)
- Every step's DoD is met.
- `make check`, `make test`, `make build` and `scripts/doctor.sh --check` are green here and in a fresh export.
- All 22 acceptance scenarios below pass as tests.
- The human has run `agentic-flow doctor --stations` once on the operator machine against the real Codex and OpenCode CLIs and it passed, or each failure is a recorded finding. The executor cannot do this: a station sandbox has no network.
- Steps h-3 to h-8 ran through `agentic-flow run`. The close-out lists every human `resume` and its cause (C-7 baseline: five, all launcher faults), and the controller-group wall time per step before (h-1's profile) and after (`S=` runs).

## Acceptance scenarios (written at Spec; the executor does not edit these)

**T-3 and T-4**
1. **Timing is off by default.** `scripts/self-test.sh --only controller` prints exactly what it printed before h-1. With `AGENTIC_TEST_TIMING=1` it also prints per-block seconds, the 15 slowest `c4_run`/`c5_run` calls with `file:line`, and the reset count and total seconds.
2. **Selection works.** With `--scenario <tag>`, each of `launch`, `ledger`, `recovery`, `ship` and `andon` runs only its own blocks, proved by a marker each block writes. A comma list runs the union. No `--scenario` runs every block. An unknown tag exits 2 and runs nothing. A selection that runs no block fails the run.
3. **Each tag stands alone.** Each tag passes alone in a fresh checkout; no block relies on state a different tag's block created.
4. **Make surface.** `make test-one F=controller S=launch` works, root and `templates/harness/Makefile` agree, the usage text names `S=`, and `make test-one F=hooks S=launch` exits 2.

**P-1**
5. **The probe catches the historical defects.** With strict stubs, the probe fails and names the cause for each of: a quoted `-c` key, a commit path outside the sandbox, a sandbox where objects and the worktree's Git directory are writable but the shared `refs/heads` is denied (the commit leaves the probe branch's ref where it was), a read-only `.agents/`, a file-size cap that makes the CLI exit 153, a caller-chosen OpenCode session id, an OpenCode session id the ledger rejects, and a Codex station whose `CODEX_HOME` is unset, holds an instruction file other than the empty `AGENTS.md`, or holds a copied rather than linked `auth.json`.
6. **Boundary property, with evidence.** A stub sandbox that lets the model write the verify or ledger directory fails the probe with `denied.verify_dir` or `denied.ledger_dir` false. A stub that returns valid result JSON but skips the forbidden writes (no attempt entry, no file) fails with "attempt not made", never as a pass. An attempt entry that claims denial with exit 0, or without a permission-class error, fails. The same holds for each allowed write: an entry without the file, or a file without an entry, fails. For OpenCode the report says `"unenforced"`, which is neither a pass nor a failure.
7. **Probe only on change.** After a pass, `run` does not probe again. Changing `launch.sh`, the profile, the roles row or the CLI's `--version` output makes the next unattended `run` probe. `doctor --stations` always probes. `run --once` never auto-probes.
8. **The probe leaves nothing behind.** The throwaway worktree and the temporary probe branch (its ref and reflog) are gone after a pass, after a failure and after a kill. HEAD, branches, status, the verify directory and the ledger are unchanged. Each property is decided from the attempt log together with the filesystem, never from the model's reply, and an absent file alone never proves a denial.
9. **A failed probe in unattended `run`** raises the `station-infrastructure` hold, starts no station and exits 10.

**T-1**
10. **Reuse.** A second `verify-step <sha> --doc <doc> --step <id>` for the same head runs no command (a logging fake `make` sees none), prints the stored record, says "reused" and exits 0. This holds for a step with red-first selectors: the record contains red-first entries with nonzero exits and status `red`, and it is reused. `--force` runs again and overwrites.
11. **No reuse when any key part differs:** another sha or tree, step, red base or command list; an edited `verify-step.sh`; an edited `verify-record.sh` alone (the helper-only change must invalidate the record, and packet must report it stale); a record whose red-first entry has status `invalid` or `green`, or whose green command exited nonzero; a changed Makefile blob at the signature source; another harness version or tool version; a record that did not pass; an unreadable, oversized or hand-corrupted record. Each runs the full verification.
12. **No gate skipping.** A record from `verify-step <sha>` with no `--step` (which ran only `make check`) is not reused for a call with `--step`.
13. **Controller and packet.** With a fresh record from an interactive run, `controller_verify` writes a `verify` ledger record marked reused and launches nothing. The reviewer packet carries the record through the same predicate and says "stale or invalid record; run verify-step" for a stale one.
14. **Contract.** The reviewer skill is at most 1000 words and says: read the packet's record first; re-run only a narrower command and name it. Every group's contract and sync checks pass.

**P-2**
15. **Failed output survives.** An invalid result stores `events.tail` (the last 256 KiB, not the first) and `stderr.tail` (at most 64 KiB) under the run's ledger directory. The andon comment names the path. A valid result stores none. Provider key values are redacted. A symlinked or escaping path is refused.

**P-3 and P-4**
16. **Retry rule.** A retry resumes only when the prior run captured a session and used tokens and the fingerprint is unchanged. A prior attempt that died before launch, or a changed fingerprint, starts a fresh session. Claude's and OpenCode's id rules are unchanged.
17. **Infrastructure fault.** A launch that exits nonzero with no session, no tokens and under 5 s writes a station record whose reason starts with `pre-launch failure`, raises the `station-infrastructure` hold with the owner mention, leaves the step in `executing` or `reviewing`, journals no `ask`, and does not count toward the cap of two. After `hold clear`, the next `run` starts a new chain with no `resume`.
18. **Real failures still escalate.** A station's own question, and two malformed results, escalate exactly as before.
19. **Unattended preflight failure** raises the same hold (decided 2026-11-17), and `run --once` keeps today's exit 6.

**P-5**
20. **Re-baseline.** With a commit on the plan branch during a pending salvage, `hold clear <doc> <id> --rebaseline` followed by `run` saves a salvage ref of the current state, raises no `worktree-changed-after-salvage`, and needs no `reset --hard`. Without the flag nothing changes. Only an authorized approver's marker counts, and a second controller on another machine reproduces the effect from the journal.

**P-6 and P-7**
21. **Verdict format.** The OpenCode prompt ends with an instruction that the final message is only the result JSON. Claude's and Codex's prompts are byte-identical to before. The parser still accepts prose followed by JSON, and fenced JSON.
22. **Investigation.** The repeated `hold-projection` repair and the missing token totals each end as a fix with a test, or as a finding in the commit body stating the cause.

## Verification commands
```bash
make check                          # per step; also run by the Stop hook
make test-one F=controller          # h-1, h-2 (whole group)
make test-one F=controller S=<tag>  # from h-2 on, the tags the step names
make test-one F=stations            # where a step names it
make test-one F=contracts           # h-4
make test                           # end of brief
make build
scripts/doctor.sh --check
```

**Station sandbox (decided 2026-11-17).** The executor's sandbox cannot run `ps`: `/bin/ps` is setuid and the sandbox refuses to execute it. Every test that runs `scripts/lib/recovery.pl` therefore fails there with `cannot read live process start time`, including each `make test-one F=controller` run and every `S=` tag, and it fails the same way on an unchanged tree. Do not weaken the sandbox, patch `recovery.pl` or skip the test to get around it, and do not stop to ask. Run `make check` and every other command this brief names that the sandbox allows. Write the controller-group edits and their tests, commit, and return `submitted`. State in the commit body which Verify commands you could not run in the sandbox. The controller runs the step's Verify line outside the sandbox after you submit, and a red result comes back to you once with its output tail.

---

## h-1 — Time every controller scenario
**Why first:** every later step iterates on the controller group at about 10 minutes a run. A profile turns h-2's tag boundaries into a measurement and shows where the time went.

**Approach:**
1. Add `AGENTIC_TEST_TIMING` to `scripts/self-test.sh` and wrap `c4_run`, `c5_run`, the fixture-reset functions and each top-level block of `scripts/tests/controller.sh` with a timer. The wrapper records seconds and the caller's source line (`BASH_SOURCE`/`BASH_LINENO`), and prints the report to stderr after the run, per the Interface.
2. Unset, the wrappers must add no output and no measurable cost. Keep timing out of stdout and out of `assert_cost_budget`'s event file.
3. Do not try to produce the profile: it needs the controller group, which the station sandbox cannot run. The human runs `AGENTIC_TEST_TIMING=1 make test-one F=controller` outside the sandbox after h-1 is verified and posts the report on this step's issue, naming the five blocks and their seconds. h-2 and Phase 3's ceilings both read it.

**Test:** scenario 1. Failure path first: with `AGENTIC_TEST_TIMING` unset, the group's output is byte-identical to a run on the previous commit; a non-numeric value is treated as unset.

**DoD:** scenario 1 passes, as verified by the controller outside the sandbox. A real profile from the operator's machine is posted on the step issue before h-2 starts.
**Verify:** `make test-one F=controller`
**Risks:** a wrapper that changes a function's exit status or `set -e` behavior (return the wrapped status, and keep the wrapper out of subshell-exit paths); timing noise from the clock source (use whole seconds, as the verifier does); a report that hides a failing run (print it from an EXIT path too).
**Red-first:** none
**Commit:** `Add an opt-in per-scenario timing report to the controller tests`

---

## h-2 — Select controller scenarios by tag
**Why second:** from here every step verifies only the scenarios it touched. The controller group is the one that grew 20× and the one this phase edits most.

**Approach:**
1. Give every block in `scripts/tests/controller.sh` exactly one tag. The existing structure maps onto the five: `ship` for `c6_tests` and `c6_visibility_tests`; `andon` for the C-3 block (questions, holds, clarification approval); `launch` for the first `controller_tests` (stations, roles, parsers, preflight, the upgrade and contract checks); `ledger` for `ledger_tests`; `recovery` for the second `controller_tests` (C-4 and C-5, including the integration block at the end). If h-1's profile shows the C-5 integration block dominating `recovery`, you may add a sixth tag `run` for it. Never rename the five.
2. Add `--scenario` to `scripts/self-test.sh` for the `controller` group only, validated like `--only`: an unknown tag exits 2 before anything runs. Wrap each tagged block in a guard like `should_run`. The group-wide wiring check (`GROUPS_RAN`) must keep failing when a block never executes in a whole-group run, and a selected run must fail if no selected block ran.
3. `make test-one F=<group> [S=<tags>]` in the root `Makefile` and `templates/harness/Makefile`, with `S=` valid only for `F=controller` (exit 2 otherwise), and the usage text updated in both. Update the check that compares the two Makefiles' call sites.
4. Two functions are both named `controller_tests` in the file and each is called right after its definition. Rename them to say what they cover (for example `launch_tests` and `recovery_tests`), so a tag maps to one name.
5. A block that depends on fixtures another block built must build its own, or be tagged together with it. Prove it with scenario 3.

**Test:** scenarios 2, 3 and 4. Failure path first: an unknown tag, an empty selection, and `S=` with a non-controller group.

**DoD:** scenarios 2 to 4 pass. `make test-one F=controller S=ship` (or the fastest tag) finishes in a fraction of the whole group, and the commit body says how long each tag takes from h-1's profile. Whole-group runs and CI still run every block.
**Verify:** `make test-one F=controller`
**Risks:** a tag that silently selects nothing and reports success; a block that passes only because an earlier block's state was left behind; selection applied to CI's full run (it must not be); the Makefile pair drifting; renaming the functions and missing the call-site check at the end of `self-test.sh`.
**Red-first:** none
**Commit:** `Select controller test scenarios by tag`

---

## h-3 — Probe the real station CLIs
**Why third:** the nine defects each cost a human `resume`, and the probe finds six or seven of them in seconds. T-1's threat model also needs the boundary this step tests.

**Approach:**
1. Add `agentic-flow doctor --stations` to the dispatcher in `scripts/agentic-flow`, backed by a new `scripts/lib/probe.sh`. `scripts/doctor.sh` stays an adoption report and does not gain model calls.
2. Share the launcher's code, never copy it. Factor `launch_station`'s argv, environment, ulimit and sandbox-root construction so the probe and a real launch use the same path, with a probe mode that swaps the prompt bundle for a fixed tiny prompt. A copy would drift, and the drift is how the defects hid.
3. The probe runs in a throwaway linked worktree of the real repository, checked out on a temporary named branch (for example `agentic-flow/probe/<station>-<nonce>`), so the sandbox roots and the denied directories are the real ones (`<common>/agentic-flow/verify` and `…/ledger`). It must be a named branch, not a detached HEAD: a detached commit writes objects and the worktree's own `HEAD` but never `<common>/refs/heads`, so it would pass while a station on the plan branch still could not commit (the `efc36e0` defect). The commit property passes only when the probe branch's ref in `refs/heads` has advanced to a new commit whose parent is the starting commit. The probe commits a fixed probe script into that worktree, and the fixed prompt asks the station only to run it. The script itself creates a file in the worktree and in `.agents/`, commits it, and tries to create a file in each denied directory, appending one line per attempt (operation, exit status, error text) to a log in the worktree. A property passes only when the log has the attempt and the filesystem agrees: an allowed operation needs exit 0 and its effect on disk; a denied one needs a nonzero exit with a permission-class error and the target absent. A missing log line fails as "attempt not made", so a station that skips a forbidden write can never pass by leaving no file. The probe never trusts the model's reply. This is a regression canary for the launcher and sandbox, not a test against a hostile station, which could write fake log lines. Remove the throwaway worktree, branch and any stray file on every exit path.
4. Session capture and result parsing go through `launch_session_record`, `station-output.jq` and the ledger's session record, so the probe fails for the same reasons a station would.
5. Add `launch_fingerprint` per the Interface, and the state file under `<common>/agentic-flow/probe/`. In an unattended `run`, probe a station whose fingerprint differs from its last passing probe before its first launch; `run --once` does not. A failed probe raises the `station-infrastructure` hold (the controller's hold path) and starts no station.
6. Report `denied` as `"unenforced"` for a CLI without an OS sandbox (OpenCode). Add one paragraph to `docs/accepted_risks.md#opencode-station-network` saying OpenCode can write the verify and ledger directories and why that is acceptable (Part A, Threat model). Add the `launch` tag to the new tests.
7. Make the stub CLIs strict (Invariants). Add one stub failure mode per historical defect.
8. Isolate a Codex station from the operator's global Codex files (decided 2026-11-17). Today a station keeps `HOME`, so the operator's `~/.codex/AGENTS.md` reaches it; one such file tells Codex to prefix every command with `rtk`, which the Git hooks cannot parse and refuse. Set `CODEX_HOME` in the launcher environment to `<common>/agentic-flow/codex-home/`, shared by the probe and a real launch. It holds only a copy of the installed `agentic-station.config.toml` (still checked against the station profile as today), an empty `AGENTS.md`, and a symlink `auth.json` to the operator's login. Never copy `auth.json`: a refreshed token would go stale. Keep the directory between runs, because Codex keeps its sessions there and `resume` needs them. A missing login target is a pre-launch failure that names the path. Add the directory's contents to `launch_fingerprint`.

**Test:** scenarios 5 to 9. Failure path first: each historical defect, the sandbox-escape stub, and a probe that times out at 120 s.

**DoD:** scenarios 5 to 9 pass. `agentic-flow doctor --stations --json` against the strict stubs reports every property. The accepted-risk entry carries the new paragraph. A Codex station sees no file from the operator's `~/.codex` except through the linked login.
**Verify:** `make test-one F=controller S=launch`
**Risks:** a station home that loses its sessions between runs and breaks `resume`; a copied login that goes stale; the symlink target missing or the home wiped without a clear failure; the station reading `~/.codex` by absolute path anyway (the strict stub must fail on it); the probe and a real launch diverging (one code path); a probe that leaves a worktree, branch or file when killed (trap on every exit, and a leftover-detection test); committing on a detached HEAD, which never exercises `refs/heads` (use a named branch and check its ref moved); a probe branch name that collides with a real branch (a nonce, and refuse if it exists); a probe that touches the real verify or ledger directory (it must only attempt, and the harness removes any file it finds); trusting the model's account of what it wrote, or reading an absent file as a denial (the attempt log is the evidence); real model calls leaking into `make test`; a fingerprint that misses the CLI version; probing before every station (change only); claiming a tested boundary for OpenCode.
**Red-first:** `scripts/self-test.sh --only controller --scenario launch` — scripts/self-test.sh scripts/tests/controller.sh
**Commit:** `Probe each station CLI through the real launcher before it runs a plan`

---

## h-4 — Verify once per commit
**Why fourth:** from here every commit is verified once, and it needs the boundary h-3 tests. A record is permission to skip a gate, so its key must cover everything that decides the result.

**Approach:**
1. Extract one freshness predicate into `scripts/lib/verify-record.sh` and use it from both `verify-step` and `packet.sh`, so the two cannot drift. `packet.sh` today checks only version, sha, tree, a hash of `verify-step.sh` alone and the signature-source types (`packet.sh:97-102`). The verifier digest must now cover `verify-step.sh` and `verify-record.sh`, computed by one function both callers use, because the new helper decides what counts as fresh. Store it in the existing `verifier.implementation_sha256` field; older records then fail the comparison and re-run.
2. The stored record names neither the step nor the commands it ran. Add the fields reuse needs (the step id, the red base, a hash of the ordered command list including red-first selectors and paths, the Makefile blob id at the signature source, a `passed` boolean, and a `role` on every command entry: `green`, `prepare` or `red-first`) without changing any field `packet.sh` reads, so older records stay readable and simply do not match. The verifier appends each red-first selector's run to `.commands` (`verify-step.sh:183`) and expects it to fail, so a rule of "every command exits 0" would reject every record that has red-first evidence.
3. In `verify-step`, after the step is selected and the command list is known and before any worktree is created, look up `<common>/agentic-flow/verify/<sha>.json`. Reuse only a record whose own contents show it passed: `passed` is true, every `green` and `prepare` entry exited 0, and every `red-first` entry exited nonzero with its `red_first` status `red` (not `invalid`, not `green`). The key must also equal the current call's. Anything else, including a read error or a record over 256 KiB, runs the full verification. `--force` skips the lookup.
4. `controller_verify` records reuse in its `verify` ledger record and launches nothing for a reused record.
5. Edit `.agents/skills/review-execution/SKILL.md` (lines 46-47 and 75; line 75 names `verify-step.sh` alone as the hash source and must say verifier digest) so the reviewer reads the packet's record first and re-runs only a narrower command it names and records, per the 2026-11-17 decision. Stay at or below 1000 words; trim as you add. Run the contract and sync checks.
6. Take `S` from the command line only (found in h-2's review). The `test-one` recipe's `origin S` check also matches an exported `S`, so with `S` exported `make test-one F=hooks` fails with "S= is valid only with F=controller" and `make test-one F=controller` silently runs one tag, not the group. Treat `S` as unset when its origin is `undefined` or `environment`, in the root `Makefile` and `templates/harness/Makefile` alike.

**Test:** scenarios 10 to 14, in `scripts/tests/stations.sh` (verify and packet) and the controller's verify path, plus an exported `S` against `F=hooks` and `F=controller`, and `S` on the command line, in the root and template Makefiles. Failure path first: each key part differing, a failed record, a corrupt record, an oversized one, and the record from a call without `--step`.

**DoD:** scenarios 10 to 14 pass. The reviewer skill is at most 1000 words. A second `verify-step` on an unchanged head runs nothing. An exported `S` changes neither `F=hooks` nor `F=controller`.
**Verify:** `make test-one F=stations`, `make test-one F=contracts`, and `make test-one F=controller S=recovery`
**Risks:** reusing a record made for a weaker call (scenario 12 is the guard); reusing a failed record and hiding a flaky pass; a key that misses the tree and treats an amended commit as verified; the verifier or its helper editing itself without invalidating records (the digest covers both files); rejecting a good record because red-first runs exit nonzero; packet and verify-step predicates drifting (one function); a stale record that blocks forever (`--force` and the full-run fallback); the skill edit pushing the reviewer bundle over its ceiling; the two Makefiles drifting on the `S` rule; a command-line `S` that stops working when the environment check is added.
**Red-first:** `scripts/self-test.sh --only stations` — scripts/self-test.sh scripts/tests/stations.sh
**Commit:** `Reuse a passing verify record for the same commit, tree, step and commands`

---

## h-5 — Keep a failed station's output
**Why fifth:** anything the probe misses has to be diagnosable from what the run left behind, not from a `PATH` shim written during the incident.

**Approach:**
1. After a station returns an invalid result, write bounded `events.tail` and `stderr.tail` into the run's ledger directory through a new `ledger.pl` helper, so the existing directory checks apply (no symlinks, ancestry cap, size caps).
2. Take the last 256 KiB of events and 64 KiB of stderr, not the first. Redact the exact values of the provider keys in the launch environment before writing. Write nothing for a valid result.
3. `launch_station` currently deletes its scratch directory before the caller sees it (`launch.sh:307`). Return the tails to the caller, or hand over the scratch files, without keeping a second copy on disk.
4. Make every andon comment self-explaining (the owner's rule of 2026-11-17: a `needs-human` ticket must say what failed without a trip into the ledger). Each comment states, in order: the cause in one line; the station, step, run id and head; the exit code, seconds and usage; for a red gate, every failing command with its exit code and the last 30 lines of its output; the last 20 lines of the station's `events.tail` and `stderr.tail` for an invalid result; the ledger paths that hold the full tails; and the exact `handoff <issue> resume` line that retries. Redact before posting, cap the whole comment at 4 KiB, and never post the full tails.
5. Keep the output a red gate needs for step 4. `verify-step` stores only an output hash per command today, so store a bounded tail (64 KiB, redacted) of each failing command's output in the verify record, beside the hash, without changing any field `packet.sh` reads.

**Test:** scenario 15, in the `ledger` and `recovery` tags. Failure path first: output over the caps, a redaction case built with `printf`, a symlinked run directory, and a valid result that must store nothing. Then each andon cause (timeout, invalid result, red gate, bounce limit) posts a comment with every item in step 4, under 4 KiB, with no unredacted key.

**DoD:** scenario 15 passes. A deliberately malformed station run leaves both tails. The andon comment for a timeout, an invalid result and a red gate each names the cause, the failing command or output excerpt, the ledger path and the resume line.
**Verify:** `make test-one F=controller S=ledger,recovery`
**Risks:** writing outside the ledger tree; unbounded tails; a provider key stored in the clear; a redaction that misses a value split across lines; keeping scratch files after the run; an andon comment that is too long or leaks a key (cap and redact); a comment that quotes so little that the owner must open the ledger anyway; a verify record that grows without bound.
**Red-first:** `scripts/self-test.sh --only controller --scenario ledger,recovery` — scripts/self-test.sh scripts/tests/controller.sh
**Commit:** `Keep bounded output from a station that returned an invalid result`

---

## h-6 — Stop retrying dead sessions and stop escalating infrastructure faults
**Why sixth:** these two remove the human cost of the faults h-3 and h-5 do not prevent, and both read the launcher fingerprint h-3 introduced.

**Approach:**
1. **P-3.** Record the fingerprint in the intent record. In the retry decision (`controller.sh:570-576`), resume only when the prior run captured a session, used tokens and the fingerprint is unchanged. Otherwise start fresh, with a session mode that names why (a dead attempt, or a changed launcher). Leave Claude's and OpenCode's id rules alone.
2. **P-4.** Classify a pre-launch failure (nonzero exit, no session, no tokens, under 5 s) when the station record is written (`controller.sh:630`). Record it with a reason that starts `pre-launch failure`, and make `ledger.pl`'s chain summary not count it toward the invalid-result cap (`ledger.pl:341`) and return a pending state for it. The controller then raises the `station-infrastructure` hold through `controller_hold`, which already ends the chain as `held` and mentions the owner.
3. After `hold clear`, a new `run` starts a new chain with the existing generation rules. Confirm against `ledger_generation` that no `resume` is needed, and say what you found in the commit body.
4. Per the 2026-11-17 decision, an unattended `launch_preflight` failure (`controller.sh:565`) raises the same hold. `run --once` keeps exit 6.
5. A station's own question, and two malformed results, escalate as before.

**Test:** scenarios 16 to 19. Failure path first: the pre-launch classification boundary (just under and just over 5 s, with and without tokens, with and without a session), and a launcher change between attempts.

**DoD:** scenarios 16 to 19 pass. A fixture plan whose launcher dies at start ends with a hold and an `executing` step, and recovers after `hold clear` with no `resume` in the journal.
**Verify:** `make test-one F=controller S=recovery,launch`
**Risks:** misclassifying a real station failure as infrastructure and hiding it behind a hold (all three parts of the test must hold; the hold's note carries the exit code, seconds and stderr tail so a human can tell); the hold never clearing; a chain left open so the next run double-launches; counting the fault toward the cap so the step still escalates; the ledger schema rejecting the new reason; changing resume behavior for Claude or OpenCode ids.
**Red-first:** `scripts/self-test.sh --only controller --scenario recovery,launch` — scripts/self-test.sh scripts/tests/controller.sh
**Commit:** `Retry with a fresh session after a dead one and hold on infrastructure faults`

---

## h-7 — Re-baseline a salvage after a fix on the plan branch
**Why seventh:** independent of the rest. It removes the only way out that cost a restarted step.

**Approach:**
1. Add `--rebaseline` to `hold clear` in the handoff argument parser (`handoff.sh:259-280`). The clear marker records it, using the existing marker grammar, so another machine's controller reads the same fact from the journal.
2. In `controller_holds`, import the flag with the clear. At the next reconcile (`controller.sh:267-280`), when a clear carried it, save a salvage ref of the current state and use the new HEAD as the baseline, instead of raising `worktree-changed-after-salvage`. Without the flag, behavior is unchanged.
3. Only an authorized approver's clear counts, as today. A crash between posting the clear and recording the salvage replays on the next reconcile and records one salvage, not two.
4. Update `hold clear` usage text and `docs/` where it is described.
5. Keep the red base of a resumed step (found on #154, 2026-11-17). After a `handoff resume`, the next executor chain's `base_head` is the previous attempt's head, and `controller_verify` passes it as `--red-base`. The red-first command then runs against code that already holds the step's tests, passes, and marks the record failed, so no fix on top of a green step can ever pass the gate. Pass the base of the step's first attempt (chain 0) as the red base for every later attempt of that step, and keep `base_head` for what the executor diffs against. Take it from the first `intent` record of the step in the ledger, never from the issue or the station's reply.

**Test:** scenario 20, in the `recovery` tag and the stations group's hold tests. Failure path first: an unauthorized clear carrying the flag, a replay after a crash, and a clear without the flag. Then a step that went green, was escalated and resumed: its second attempt's red-first runs against the first attempt's base and can fail, and a step with no earlier attempt is unchanged.

**DoD:** scenario 20 passes. A commit on the plan branch during a pending salvage no longer forces `reset --hard`. A resumed step is verified against the base of its first attempt.
**Verify:** `make test-one F=stations` and `make test-one F=controller S=recovery`
**Risks:** a flag that re-baselines over edits nobody saved (the salvage ref is saved first, always); an unauthorized marker honored; the flag lost when the clear is imported from the journal on another host; two salvages on a replay; the hold re-raised on the very next reconcile; a red base taken from anything but the ledger's first intent; a fix commit that passes only because the base already holds the tests (the original base is what keeps red-first honest); a resumed step whose first intent is missing or from another plan.
**Red-first:** `scripts/self-test.sh --only controller --scenario recovery` — scripts/self-test.sh scripts/tests/controller.sh
**Commit:** `Add hold clear --rebaseline so a fix on the plan branch survives a salvage`

---

## h-8 — State the verdict format and investigate two unexplained faults
**Why last:** both are independent and small, and the investigation benefits from h-5's kept output.

**Approach:**
1. **P-6.** For a CLI that cannot enforce an output schema (OpenCode), end the prompt `launch_bundle` builds with one explicit line: the final message is only the result JSON object, with no prose and no fences. Claude and Codex prompts stay byte-identical. Keep the parser lenient (`station-output.jq`).
2. **P-7a.** Find why `repaired #138: hold-projection` prints on every `run` (`controller.sh:730`). Fix it with a test, or record the cause in the commit body if it is intended.
3. **P-7b.** Find why `metrics` reports tokens as `n/a` when the ledger holds Codex usage. Check `usage_sum` and `breakdown` (`ledger.pl:379-393`) first: one run with no station record or a null field makes the whole plan unknown. Fix it so known usage is reported with a count of the runs that were unknown, or record why not.
4. **Summary cap** (decided 2026-11-17, from #154). The OpenCode reviewer approved h-4 twice with a 1513-character `summary`, and the controller refused both as "malformed station result" because the schema allows 1200. Raise the `summary` cap to 2000 characters in `result.schema.json` and in `controller_result_valid` (`controller.sh:514`), and in any other copy of the schema. Leave `question` and each finding's `text` at 1200. State the 2000 limit on the verdict-format line from step 1, so a station is told it. Keep the limit a hard failure: an over-length verdict is still refused, never truncated.
5. **Preflight hold detail** (h-6 review, P3, accepted 2026-11-17). The hold the controller raises when a launch fails before the station starts (`station-infrastructure`, note `Launch preflight failed before station start.`, `controller.sh:736`) carries no cause. Capture `launch_station`'s stderr on that branch and put the exit code, the seconds since launch start and the last 20 lines of stderr (redacted, the whole note capped at 4 KiB by truncation) in the hold note, as the probe-path hold already does with the captured preflight output. Keep the retry instruction as `hold clear`. Add no new hold reason.

**Test:** scenarios 21 and 22. Failure path first: prose followed by JSON, fenced JSON, a plan where one run has null usage, and a hold projection that is already correct. Then a summary of 2000 characters passes, one of 2001 is refused as malformed, and a `question` of 1201 is still refused. For step 5, a launch that fails after the probe passes (extend the cached-preflight test) raises a hold whose note holds the exit code, the seconds and the stderr tail, and a stderr over 4 KiB is truncated, not refused.

**DoD:** scenarios 21 and 22 pass, and the commit body states each P-7 outcome. A 2000-character summary is accepted and the limit is in the station's prompt. A pre-start launch failure's hold names the exit code, the seconds and the stderr tail.
**Verify:** `make test-one F=controller S=launch,ledger,recovery`
**Risks:** changing a prompt for the CLIs that enforce the schema; tightening the parser and rejecting a real reviewer message; a metrics change that reports a partial total as a complete one (show the unknown count); a "fix" to the repair that stops it repairing a real drift; raising the cap in the schema but not the validator (or the reverse), so a verdict the schema allows is still refused; truncating an over-length summary and hiding a lost finding; the new limit missing from a CLI's prompt; a stderr tail that leaks a provider key (redact first); an oversized stderr that aborts the hold again (truncate); the preflight hold gaining a new reason or changing how it is cleared.
**Red-first:** `scripts/self-test.sh --only controller --scenario launch,ledger,recovery` — scripts/self-test.sh scripts/tests/controller.sh
**Commit:** `State the verdict format for schema-less CLIs and fix the two unexplained controller faults`

---

# Close-out

Claude, on `phase-2b`, after the last approval, and before the human merges:

1. Close-out commits: `VERSION` 0.17.0 and a `CHANGELOG.md` entry with migration notes: `agentic-flow doctor --stations` and when `run` probes; the `station-infrastructure` hold and `hold clear --rebaseline`; `verify-step --force` and the reuse rule; `S=` on `make test-one` (copy the Makefile change by hand); `AGENTIC_TEST_TIMING`; the reviewer contract change.
2. Claude runs `make check && make test` on `phase-2b` at the close-out head (about 32 minutes; decided 2026-11-17), before any push or PR, and records the result and the head it ran on in the close-out commit message. Only a green run goes on to the next item. A red run is fixed or escalated to the human; nothing is pushed, and `ship` is not run, until it is green. CI then repeats it on the pushed head.
3. The human runs `agentic-flow ship docs/inprogress/feature-station-hardening.md`. Claude commits the staged prep. The human runs `ship` again. The CHANGELOG makes the delta non-bookkeeping, so `ship` exits 11 until the reviewer runs `agentic-flow final-approve` for the final head; then `ship` runs `finish`. **Do not merge before `ship` reports READY** (see accepted risk C-8).
4. The human runs `agentic-flow doctor --stations` once against the real CLIs and the result is recorded.
5. Update `product-harness-factory-optimization.md` (the Phase 2b and Phase 3 tables, and the next-docs list) and record the human `resume` count and the before and after controller-group times against the analysis's "Expected effect" table.

---

## Status / Implementation status
- **Evidence schema:** v2
- **Tracking issue:** url=https://github.com/wabkebab/agentic-flow/issues/150
- **Approval:** status=approved; by=wabkebab; at=2026-11-17; rev=67059ddf6b9b67fb0cad1631ad598c0a0ae2a42a
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
