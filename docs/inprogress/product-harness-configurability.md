<!-- TRIAGE (first pass · 2026-11-25) -->
> **Type:** Product Analysis · **Status:** ✅ Decided
> How an adopter configures, installs, observes, exposes and removes the harness: agent-agnostic stations, one config surface, setup/upgrade wizards, process status, CLI vs GUI, daemon vs scripts, repository visibility, uninstall, and warn-or-stop test budgets. Phase 1 (observability) is drafted as `feature-process-status.md`. Revision 2 (2026-11-25) answers the roadmap review: aligned Phase 1 interface, plan-pinned workflow policy, per-reason andon responses, policy-aware verification caches, replay-safe redaction, and an ownership-bounded uninstall. Revision 3 makes the pin immutable once issues are stamped and requires pristine provenance (the `accepted=` upstream hash) before uninstall deletes a file. Revision 4 makes `plan-to-issues` reject a changed pin before any issue mutation, and anchors re-export for older installs to the installed revision. Written against `0.20.0` (`c2f7e32`). Decided 2026-11-25: recommendation and build order accepted. The up-front decisions stay open until the brief each one gates. Next: Phase 1 (`feature-process-status.md`).

# Product Analysis — Harness configurability, visibility and lifecycle

## Goal / context

The owner wants the harness to be something an adopter *configures* rather than hand-edits.
These goals were stated on 2026-11-25:

1. Stations are agent-agnostic: the adopter picks the agent (and optionally its key) per station.
2. One `.env` or config file holds the tunable parameters.
3. Install and upgrade are interactive.
4. The state of a running plan is easy to see (today it is hard to know).
5. Decide CLI vs GUI.
6. Decide daemon vs scripts.
7. The adopter declares whether the repo is **public**, **private**, or **private first,
   public later**. That choice defines how exposed the harness files and forge traffic are.
8. A script removes the harness cleanly.
9. Wall-time ceilings and fixture counts can be configured as a warning or a flow-stopper.

The owner's first list of settings: the agent per station (and key), bounces before
`needs-human`, which finding severities must be fixed (critical → nit), GitHub or GitLab,
and what constitutes an andon.

This analysis decides **what to build and in what order**. It has no implementation brief.
Each area becomes its own Feature doc (see *If approved → next docs*).

## Constraints & assumptions

- **Bash 3.2 + `jq`, few dependencies.** The format and the tooling have to fit the shell.
- **Safety floor.** The human pushes, merges, ships and clears holds. The command-policy
  deny list, staged-secret scanning and journal integrity are not negotiable (METHODOLOGY §8).
- **Journal replay.** Workflow state is derived by replaying admitted journal events
  against the transition rules (`config/workflow.tsv`, `scripts/lib/workflow.sh`). Every
  reader must derive the same state from the same issue, today and after any upgrade.
- **Station isolation.** Stations run under `env -i`, with credentials withheld.
- **Breaking changes go in the 1.0 brief**, which already carries R-14b and R-22.
- **Payload membership lives in `config/payload.tsv` only.** Adopters record installed
  paths and hashes in `.agentic-flow-installation`.
- **Reversibility.** Forge abstraction, label renames, plan-pinned policy and visibility
  modes that move files out of the tree are the expensive-to-reverse items.

---

## Current state

| Area | Today | Where |
|---|---|---|
| Agent per station | Configurable in 3 layers: defaults → project → operator, via `agentic-flow roles set` | `config/roles.tsv`, `.agentic-flow-roles`, `scripts/lib/roles.sh` |
| Supported agents | Hand-coded per CLI (`claude`, `codex`, `opencode`) | `scripts/lib/launch.sh:19-23, 349-390` |
| Bounce limit | Hardcoded at 2; the validator only accepts `bounces<2` / `bounces=2` | `config/workflow.tsv`, `scripts/lib/workflow.sh:46` |
| Finding severity | Results use `P1/P2/P3`; the OpenCode reviewer contract uses `sev:nit` | `config/stations/result.schema.json`, `.opencode/agent/code-reviewer.md:217` |
| Andon | About 14 hardcoded hold reasons; desktop notification only | `scripts/lib/controller.sh`, `scripts/lib/andon.sh` |
| Other knobs | 4 root dotfiles, 3 TSVs, `AGENTIC_CONTROLLER_LEASE`; hardcoded turn cap (50), packet limit (3,000 words), fixture-copy limits | repo root, `config/`, `scripts/self-test.sh` |
| Verification reuse | `verify_record_key` binds sha, tree, doc, step, harness version, tool versions, command plan and verifier hash. It has no budget policy. CI reuses an earlier green app run from `actions/cache` | `scripts/lib/verify-record.sh:17-32`, `.github/workflows/ci.yml:72-90` |
| Forge | GitHub throughout | `scripts/lib/*` |
| Run marker | Journal comments carry `agentic-flow-run: run=<plan>/controller/<pid>-<epoch>; host=<12-hex fingerprint>`. The fingerprint drives foreign-controller detection | `scripts/lib/journal-comment.sh:19-23`, `scripts/lib/recovery.pl:92`, `controller.sh:104-120` |
| Install / upgrade | `init.sh` prompts with a flag for each prompt; upgrade leaves `.agentic-new` candidates | `scripts/init.sh`, `agentic-flow upgrade` |
| Hooks | `init.sh` sets `core.hooksPath` only when unset; a custom hooks path is kept and chains the scanner | `ADOPTION.md:54-66` |
| Plan cleanup | `clean` refuses dirty worktrees, the base branch and unmerged work | `scripts/lib/start.sh:301-345` |
| `status` | Install report only | `scripts/agentic-flow:466` |
| Runtime | Foreground loop with lock, lease, turn cap, `--once` | `scripts/lib/controller.sh:902` |
| Visibility | Implicit: everything committed; `publish-scan.sh` was used once | `scripts/publish-scan.sh` |
| Removal | None | — |

---

## Areas and options

### A. Config surface and who may override what

**Format.** Use flat dotted `key=value` in one committed project file,
`.agentic-flow/config`. It parses in Bash and matches `.agentic-flow-review-policy`.
JSON is hard to edit by hand, and TOML/YAML need a parser. The commands are
`agentic-flow config list|get|set|explain <key>`. `explain` names the effective value and
its source. Unknown keys and out-of-range values are errors.

**Override tiers.** Not every setting may vary by operator. Precedence applies *within* a
tier, never across tiers:

| Tier | Who sets it | Overridable by | Examples |
|---|---|---|---|
| **Floor** | The harness | Nobody | Human push/merge/ship/hold-clear; command-policy denies (only additions allowed); secret scanning; integrity holds; replay rules for existing journals |
| **Plan-pinned** | Project config, captured at approval and stamped on the issues | Nobody. Fixed once any issue is stamped; changing it requires a new plan | `review.max_bounces`, `review.block_at`, `review.nonblocking`, the andon response table (C), `assurance` |
| **Project** | Project config, committed and reviewed | Nobody locally | `forge`, `repo.visibility`, `identity.mode`, budget values and modes for CI (K), packet word limit, severity scale |
| **Operator** | Project default → operator file `~/.config/agentic-flow/<owner>/<repo>.conf` → `AGENTIC_FLOW_*` env | The operator, on their own machine | Station agent/model/effort/timeouts/key references, `notify.*`, `controller.turn_cap` (within 10–200), local budget mode and wall scale (K) |
| **Invocation** | CLI flags | Per run | Run shaping only: `--once`, `--detach`, `--wait-human`. Never policy |

**Plan pinning keeps journals replayable.**

- When a plan is approved, the effective plan-pinned settings are written into the plan
  block, for example `policy: max_bounces=2 block_at=major`, and so are covered by the
  approval revision.
- `plan-to-issues` copies them into each issue's journal stamp.
- Replay reads the limit from the issue's stamp, never from the active config. Two
  operators therefore derive the same state from the same issue.
- A stamp without a policy field replays with today's rules (`max_bounces=2`, P1–P3
  blocking). That implicit pin keeps every existing journal's behaviour.
- A config change affects only plans approved after it.
- **The pin is immutable once issues are stamped.** Replay reads one pin per issue, so a
  mid-plan change would have no boundary between events judged under the old rule and
  events judged under the new one.
  - **`plan-to-issues` is the first gate.** `--apply` rewrites existing issue bodies,
    stamps included (`gh issue edit --body`, `plan-to-issues.sh:409, 559, 606`). It must
    reject a changed pin **before any mutation**, using the same pattern as the existing
    topology-immutability check (`plan-to-issues.sh:323-345`):
    - read the pin from every discovered stamped issue;
    - require them all to agree with one another and with the doc's pin;
    - otherwise exit with nothing created, edited, labelled or closed.
  - **Partial applies.** The check covers a partial earlier apply. The pin of any issue
    that already exists binds the issues still to be created, so a rerun cannot finish a
    half-applied plan under a different pin.
  - **Legacy issues.** An issue with no policy field carries the implicit legacy pin. A
    doc may add an explicit pin to legacy issues only when it equals the legacy values,
    the same way `migrate_approval_body` adds `approved=` only for a matching revision.
  - **Controller backstop.** The controller's existing check that stamped issues match the
    approved plan (`controller_check`, `controller.sh:30-44`) also compares the pin and
    holds on a mismatch. It covers stamps edited outside `plan-to-issues`.
  - **Reapproval** that leaves plan-pinned values unchanged keeps working as today, for
    example to edit step prose. To run under a different policy, finish or abandon the
    plan and start a new one.
- **Deferred:** an explicit policy transition. That would be an approver-only journal
  event recording the new pin at a sequence number, with replay applying each event under
  the pin in force at its seq. Revisit only if mid-plan changes turn out to be a real
  need.
- `workflow.tsv` changes its `bounces<2` / `bounces=2` literals into one parameterised
  requirement, `bounces<limit` / `bounces=limit`. The validator still rejects anything else.

**Secrets.** Project config never holds secrets. The operator tier holds *references* to
them, for example `station.executor.key_cmd=security find-generic-password -s flow-codex -w`
or `station.executor.key_env=FLOW_CODEX_KEY`. A gitignored `.env` is acceptable only as an
operator-tier source, and `doctor` warns when it is not ignored. Keys are passed
explicitly per station and reported by `roles` and `doctor`, because key presence already
changes Claude's contract mode (`launch.sh:22`).

**Severity scale.** Use one scale, `critical > major > minor > nit`, with `P1/P2/P3` as
aliases. Nits never block.

### B. Agent-agnostic stations

**Options:** keep hand-coded CLIs; an adapter interface; or adapters plus a generic CLI
adapter.

**Recommended:** an adapter interface. Each `scripts/adapters/<agent>.sh` implements:
- `probe`, `render_policy`, `argv`, `parse`, `resume`;
- `capabilities`: schema output, enforced budget, sandbox, network isolation.

Capabilities drive posture. An agent that fails `doctor --stations` refusal probes is
assignable only with an accepted risk, as `opencode-station-network` is today. A generic
adapter exists only in that tier. This needs R-22 (role-named labels, `git-<role>`
wrappers), so it belongs in the 1.0 brief.

### C. Andon responses per reason

A shared menu of responses is unsafe, so each reason gets its own allowed responses and
continuation conditions. **No override ships until the safety-floor decision (see
*Decisions*) is made.** Until then every reason stays `hold`, as today.

| Reason | Allowed responses | Continuation condition |
|---|---|---|
| Integrity: `foreign-controller-host`, `ledger-body-hash-mismatch`, `ledger-invalid`, `ledger-too-large`, `station-changed-branch`, `unexplained-worktree-changes`, `worktree-changed-after-salvage`, `illegal-transition`, `unjournaled` | `hold` only | Human repair, then `hold clear` and a new invocation |
| `station-escalation` (a station `ask`) | `hold` only; the delivery channel is configurable | Approver `resume` with a decision note |
| `findings-incomplete` (the controller cannot deliver the full findings) | `hold` only | Human inspects; a bounce with partial findings would mislead the executor |
| `plan-effect-pending` | `hold` only | The pending human decision is recorded |
| `turn-cap` | `hold` only; the cap value is operator-tier (10–200) | A new invocation; the cap bounds one run |
| `station-infrastructure` | `hold`, `retry:N` (N ≤ 3), `fallback-agent` | `retry` only when no station result was recorded and the worktree is clean, with the same agent and a fresh session. `fallback-agent` only before the station started (probe or preflight failure), and only to an agent that passes its own refusal probe. It is recorded as a reassigned intent. After N attempts, `hold` |
| `budget-exceeded` (new, cost) | `hold`, `finish-step` | `finish-step` lets the in-flight station finish and holds before the next launch. It never starts new work |
| Bounce limit | Not an andon. A plan-pinned journal transition to `escalated` | Approver `resume` |

`notify-only` is not offered for any reason that stops work.

### D. Interactive setup and upgrade

**Setup.** `agentic-flow setup` wraps `init.sh` and keeps its rules: a flag for every
prompt, no prompts outside a terminal, and `--answers <file>` for repeatable setups. It:
- detects agent CLIs and their auth, and offers station assignments;
- detects the forge from `git remote`;
- asks for the visibility and the plan-pinned defaults;
- writes the config, creates labels, sets an unset `core.hooksPath`;
- finishes with `doctor --check` and `doctor --stations`.

**Upgrade.** The wizard:
- migrates config keys;
- walks each `.agentic-new` file (keep / take / open in `$EDITOR` / defer);
- promotes `.agentic-flow-candidate-version` when nothing is pending.

Optional `gum` styling may be used, with `read` as the fallback.

### E. Process status (Phase 1, aligned with `feature-process-status.md`)

The interface is the feature brief's:

- `agentic-flow status` keeps today's install report byte-identical and adds a bounded
  `plans:` summary. Its exit code stays tied to the install report.
- `agentic-flow status <plan-id|doc>` prints the offline plan view. It exits 10 when the
  human must act. It answers "whose turn is it?" with an executable command.

```
plan process-status  (controller: alive, pid 4821, turn 12/50; cache as of 14:02)
  f-1 approved        f-2 approved
  f-3 reviewing       opencode · 6m12s / 20m · bounce 1/2
  f-4 escalated       executor ask (seq 41) — "Which log cap applies?"
  next → you: write the decision, then
         agentic-flow handoff 212 resume --as approver --body-file decision.md   (returns to executing)
```

A station `ask` is an escalation, not a hold. It is answered by an approver `resume`.
Holds show `agentic-flow hold clear <doc> <hold-id>`. The view never recommends `ship`
from an incomplete snapshot. It takes `--watch` and `--json`.

### F. CLI vs GUI

**No GUI and no TUI library.** Build a good CLI: `status --watch`, the wizards and
notifications. A static HTML snapshot may come later. Revisit a TUI only if the controller
leaves Bash.

### G. Daemon vs scripts

| | Foreground script (today) | Detached script | Real daemon | CI-hosted controller |
|---|---|---|---|---|
| Pros | Simple, visible | Survives the terminal; cheap | Multi-plan; event-driven | No laptop needed |
| Cons | Tied to a terminal; exits on a hold | One plan per process | Much more code and state | Secrets in CI, runner cost, CLI logins |

**Recommended: scripts.** Phase 1 adds:
- `run --detach`, which returns only after the controller acknowledges it holds the lock,
  with a capped log;
- `run --wait-human`, which waits in-process only on stops a human answer resolves.

**launchd/systemd unit templates are explicitly deferred.** Revisit when an adopter needs
a controller to survive a reboot. `--detach` plus `--wait-human` covers the terminal and
the answer-wait cases.

### H. Forge: GitHub or GitLab

This is the largest item. **Recommended:** after 1.0, extract a forge interface with
GitHub as its only implementation, then add GitLab. Do this earlier only if there is a real
GitLab adopter. `forge=gitlab` is rejected until it works end to end.

### I. Repository visibility and harness exposure

There are two exposure surfaces: the **tree** (harness files) and **forge traffic**
(journal comments, which are public on a public repo). This repo's own scan found zero
credentials in the tree. GitHub comments held the run fingerprints the owner accepted, plus
6 temp-directory and 9 absolute-path findings.

**Redaction must not break replay or recovery.** Journal fields fall into two groups.

- **Required for replay and recovery, never redacted:**
  - transition markers: event, role, seq, head, return target, hold ids and clears;
  - the run marker's `run=` id and `host=` fingerprint, which the foreign-controller check
    depends on;
  - the step stamp and the ask/decision bodies the packet carries.
- **Redactable:**
  - free-text diagnostics: absolute paths, temp directories, raw hostnames, usernames;
  - stderr tails;
  - anything the publish scan flags outside the required fields.

The host fingerprint is already a truncated SHA-256 of the hostname and Git common dir,
not the hostname itself. Public mode keeps it and documents that it is a pseudonymous,
per-clone identifier.

**Hiding harness files has real costs:**
- `.gitignore` advertises the harness, while `.git/info/exclude` is per clone.
- Plan worktrees are fresh checkouts and would lack ignored files that stations read.
- CI needs `scripts/`, `config/` and the Makefile targets.
- Ignoring files later doesn't remove them from history.
- `status` currently treats git-ignored payload as needing action.

**Options:** 1) everything committed; 2) tiered exposure by `repo.visibility`; 3) a
separate overlay repo.

**Recommended: Option 2, in two parts.**

- **Part 1: diagnostic hygiene.** The `public` and `private-then-public` modes redact only
  the redactable fields at write time. `private-then-public` makes
  `publish-scan.sh --surface all` a standing check and adds `agentic-flow publish prepare`,
  a checklist of tree, history and comment actions before the visibility flip.
- **Part 2: a hidden-files tier, built on demand.** Payload rows get exposure classes
  (`required`, `instructions`, `process`, `identity`). **No class may be marked local-only
  until a clean clone with those files absent passes `make check`, `make test` and
  `agentic-flow ship` in CI.** That needs a worktree sync step that is itself validated.
  `status` and `doctor` must accept the declared mode instead of flagging it.

Option 3 is rejected.

### J. Removing the harness: only what it owns

`agentic-flow uninstall [--dry-run] [--keep-docs] [--purge-ledger] [--yes]`. The default
is a dry run.

- **Payload files: delete only on proof of pristine provenance.**
  - The installation record's `file=` hash cannot serve as that proof. It hashes the
    destination as it stood after the last successful apply
    (`payload-apply.sh:228-243`). A preserved local edit, a `kept` file or a hand-merged
    contract is recorded too, so matching it would delete adopter work.
  - A file is removed only when all of these hold:
    - it is listed in `.agentic-flow-installation`;
    - `.agentic-flow-upstream` has an `accepted=` hash for it with no pending `offered=`.
      `accepted=` is the hash of the harness source as shipped
      (`payload-apply.sh:584-600`);
    - its current bytes hash to that `accepted=` value.
  - **Fresh installs already have this provenance.** An export at `996c036` into an empty
    repository wrote an `accepted=` row for every one of the 138 installed paths in
    `.agentic-flow-upstream`. Export loads and writes that record in `export` mode, and
    `payload_apply_entry` records the source hash for `create`, `same` and `overwrite`.
    Uninstall depends on that behaviour, so a test pins it (below).
  - **Re-export for older installs** that predate `.agentic-flow-upstream` is anchored to
    the *installed revision*, the commit in `.agentic-flow-version` (for example
    `0.20.0+996c036`). It is never anchored to `.agentic-flow-source`'s `ref`, which can
    be a moving branch such as `main`. If the stamp has no commit, or the commit is
    unreachable, the file is kept.
  - Anything else is reported and kept: no upstream record and no reachable installed
    revision, a pending offer, or a hash mismatch. This keeps hand-merged `CLAUDE.md`,
    `AGENTS.md` and `Makefile` unless they are byte-identical to the shipped template.
- **Stamps.** Remove the harness's own stamps: `.agentic-flow-version`, `-source`,
  `-candidate-version`, `-installation`, `-upstream`, `-scopes-excluded`, and the
  project-owned `-assurance`, `-roles`, `-stack` and `-review-policy` after confirmation.
  Also remove `.agentic-new*` candidates.
- **Hooks.** Unset `core.hooksPath` only when it equals `scripts/git-hooks`, the path being
  removed. A custom hooks path is left untouched. A scanner call chained into a custom
  hook is reported for manual removal, never edited.
- **Plans.** Each plan worktree and branch goes through `clean`'s existing guards.
  Dirty worktrees, unmerged branches and the base branch are refused, **with no flag to
  override that**. Uninstall stops if any plan would be refused and names those plans.
- **Shared Git state.**
  - It removes `agentic-flow/state`, `logs`, `locks` (only with no live controller) and
    `codex-home`.
  - The ledger is kept unless `--purge-ledger` is given and no plan is open.
- **Docs.** Plans, done docs, accepted risks and memory are kept by default.
- **Outside the repo.** Operator files, keychain keys, labels, open issues, GitHub Apps,
  rulesets and the CI workflow are printed as a checklist. It warns first if a ruleset
  requires the **CI gate** check.
- **Result.** One removal commit, staged by name, never pushed.

Required tests:

- **Upgraded fixture.** Start from an *upgraded* fixture that has a custom
  `core.hooksPath` with a chained scanner, and an unmerged plan branch with a dirty
  worktree. Uninstall must refuse while the plan exists. After the plan is cleaned, it must
  leave the custom hooks and the ledger in place.
- **Edit carried through an upgrade.** Edit a payload file locally, then complete an
  upgrade in which that path is unchanged upstream, so it is classified `kept`. The
  upgrade refreshes `.agentic-flow-installation` with the edited file's hash. Uninstall
  must keep that file.
- **Hand-merged contract.** Merge `CLAUDE.md` by hand through `upgrade --merged`.
  Uninstall must keep the merged file.
- **Pristine file.** A file byte-identical to its `accepted=` upstream content is removed.
- **Install → uninstall.** Export into an empty repository, then uninstall. Every pristine
  payload file and stamp is removed, and the tree matches its pre-export state apart from
  kept docs. This pins export's provenance recording.
- **Older install.** Remove `.agentic-flow-upstream` from a fixture. Re-export resolves
  the commit in `.agentic-flow-version`, not `ref main`. A fixture whose source ref has
  moved past the installed commit still removes only files identical to the installed
  revision.

### K. Test and harness budgets: warn or stop

| Budget | Today | Where | Deterministic? |
|---|---|---|---|
| Wall-time ceilings per group/tag | TSV values; overrun fails | `config/test-wall-ceilings.tsv`, `scripts/self-test.sh:287-330` | **No** (host load) |
| Fixture file/tree copies | Hardcoded 33 / 194 / 117 | `scripts/self-test.sh:338-353, 590-593` | Yes |
| Role-bundle word ceilings | Baseline; overrun fails | `scripts/measure-harness.sh:93` | Yes |
| Packet word limit | 3,000 | `config/stations/README.md` | Yes |

**Recommended:** each budget gets a mode, `stop` or `warn`, with a separate mode for local
runs and CI and a wall-time scale factor.

Defaults:
- fixtures and words: `stop`, because they are deterministic;
- wall time: `warn` locally, so the Stop hook never traps an agent over machine load, and
  `stop` in CI with scale 1.0;
- fixture limits move into a reviewed data file (`config/test-budgets.tsv`).

Tiers (A): budget values and CI modes are project-tier. The local mode and wall scale are
operator-tier. `warn` is never silent: `doctor` and `status` list every budget in `warn`,
and each overrun is recorded with its measured value and limit.

**Verification reuse must include the effective budget policy.** A warn-green result must
never satisfy a stop gate.

- `verify_record_key` gains `budget_policy_sha256`: a hash of the budget data files plus
  the effective modes and scale. A record made under another policy is stale.
- The CI cache key and the cached green marker carry the same hash. A hit is accepted only
  when it matches.
- **A CI cache hit does not newly satisfy a wall-time requirement.** It is accepted only
  when the cached run itself measured wall time under `stop` with the same policy hash,
  and the marker records that measurement. Otherwise CI runs the suite.
- When wall time runs as `warn` in CI, the result is labelled "wall time not enforced".

---

## Recommendation

**Recommended:** build in this order, each as its own Feature doc.

1. **Observability** (E, G): `feature-process-status.md`. It is first and independent of
   config.
2. **Config consolidation** (A, C, K): approve only after the owner signs off on A's
   tiers, plan pinning with the legacy implicit pin, C's per-reason table, and the
   safety-floor decision.
3. **Uninstall** (J).
4. **Setup and upgrade wizards** (D): depend on 2.
5. **Visibility, part 1** (I): redaction of redactable fields only, the standing scan,
   `publish prepare`.
6. **Agent adapters + R-22** (B): in the 1.0 brief.
7. **Visibility, part 2** (I): only on demand, after the clean-clone validation.
8. **Forge interface, then GitLab** (H): after 1.0.

The deciding factor is that observability is additive and needs no policy decisions.
Config changes what replay and gates mean, so it waits for its tier contract.

**Defer:**
- GUI and TUI.
- launchd/systemd units, and a daemon.
- GitLab.
- The hidden-files tier.
- Any andon override.

## Decisions to make up front

- [x] **Safety floor.** Accept that config can tighten but never loosen the floor? Until
      this is decided, no andon override from C ships.
      *Decided 2026-11-26: yes, with a split floor; agent push to the plan branch is
      reserved for a later opt-in brief. See `feature-config-surface.md` C-1.*
- [x] **Override tiers (A).** Accept the five tiers and the plan-pinned list, including
      `review.block_at`?
      *Decided 2026-11-26: yes, as `feature-config-surface.md` C-1.*
- [x] **Plan pinning.** *Decided 2026-11-26: yes, immutable once stamped
      (`feature-config-surface.md` C-2, C-3).* Accept the pin in the plan block and journal stamp, immutable once
      issues are stamped and enforced first by `plan-to-issues` before any mutation, with
      stampless journals replaying under the implicit legacy pin
      (2 bounces, P1–P3 blocking)? An explicit policy transition at a journal sequence
      boundary is deferred.
- [ ] **Bounce limit scope.** One project default, or a default per assurance level? Either
      way it is pinned per plan.
- [ ] **Below-threshold findings default.** `comment` or `follow-up-issue`?
- [ ] **GitLab.** A near-term need, or after 1.0?
- [ ] **Notification channel** after desktop: ntfy, a webhook, or an issue mention?
- [ ] **Visibility default** for new adoptions, and acceptance of the host fingerprint as a
      required, pseudonymous field in public mode.
- [ ] **Budget modes (K).** Accept the defaults and the policy-hash cache rule? Should
      adopters' CI start at `warn` until they calibrate their ceilings?
      *Partly decided 2026-11-26: CI wall time defaults to `warn`
      (`feature-config-surface.md` C-1). The other defaults are settled at that brief's
      approval.*
- [x] **Uninstall.** Accept removal only on pristine provenance (the `accepted=` upstream
      hash, or bytes re-exported from the installed revision for older installs) and the
      no-override plan guards?
      Invest in managed-region markers for hand-merged contracts later?
      *Decided 2026-11-27: yes, tightened by review to install-time ownership evidence
      plus pristine bytes, behind a fence and the no-override plan guards. Legacy paths
      are removable only through an explicit owner claim (`feature-uninstall.md` f-5).
      Managed-region markers stay deferred.*
      *Narrowed 2026-11-27 for v1, after the fourth review of `feature-uninstall.md`:
      uninstall stages the verified deletions and the adopter commits them, replacing
      J's "one removal commit". Shared Git state under the common dir, including the
      ledger, is reported with exact commands instead of removed, so `--purge-ledger`
      is dropped. Automatic commit and purge are follow-ups. After the fifth review, the
      adopter also runs `clean` for each plan before uninstall, which refuses while any
      plan is open, replacing J's in-uninstall plan cleanup.*

Settled by this revision:
- Phase 1 uses the feature brief's `status` interface. Service units are deferred.

## If approved → next docs

- [ ] `docs/inprogress/feature-process-status.md` — areas E, G (Phase 1; drafted 2026-11-25 on `configurability-phase-1`, revision 2)
- [ ] `docs/inprogress/feature-config-surface.md` — areas A, C, K (Phase 2; drafted 2026-11-26 on `configurability-phase-2`, draft 1)
- [ ] `docs/inprogress/feature-uninstall.md` — area J (Phase 3; drafted 2026-11-27 on `configurability-phase-3`, draft 10, stage-only v1)
- [ ] `docs/backlog/feature-uninstall-purge.md` — area J follow-up: automatic commit and shared Git state purge, only if adopters ask
- [ ] `docs/inprogress/feature-setup-upgrade-wizard.md` — area D
- [ ] `docs/inprogress/feature-visibility-modes.md` — area I (part 1; part 2 on demand)
- [ ] Area B folded into the 1.0 brief alongside R-14b and R-22
- [ ] `docs/backlog/feature-forge-interface.md` — area H

## Status

- **Decision:** accepted 2026-11-25: the recommendation and build order at revision 4
  (`83d6cd8`), approved by the human owner after four review rounds with every finding
  applied or answered with evidence. Phase 1's interface is settled (see *Settled by this
  revision*). The up-front decisions above stay open. Each must be settled before the
  feature brief that depends on it is approved. The safety floor, override tiers and plan
  pinning gate Phase 2 (`feature-config-surface.md`).
- **Decided by:** wabkebab (human owner).
