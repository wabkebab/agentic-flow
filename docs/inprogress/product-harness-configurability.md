<!-- TRIAGE (first pass · 2026-11-25) -->
> **Type:** Product Analysis · **Status:** 🟦 Proposal
> How an adopter configures, installs, observes, exposes and removes the harness: agent-agnostic stations, one config surface, setup/upgrade wizards, process status, CLI vs GUI, daemon vs scripts, repository visibility, uninstall, and warn-or-stop test budgets. Phase 1 is drafted as `feature-process-status.md`. Written against `0.20.0` (`c2f7e32`). Owner decisions pending.

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
   public later**. That choice defines how exposed the harness files and forge traffic are,
   including which internal files are kept out of the published tree.
8. A script removes the harness cleanly.

The owner's first list of settings: the agent per station (and key), bounces before
`needs-human`, which finding severities must be fixed (critical → nit), GitHub or GitLab,
and what constitutes an andon.

This analysis decides **what to build and in what order**. It has no implementation brief.
Each area becomes its own Feature doc (see *If approved → next docs*).

## Constraints & assumptions

- **Bash 3.2 + `jq`, few dependencies.** The format and the tooling have to fit the shell.
  A TOML/YAML parser is a new dependency.
- **Safety floor.** The human pushes, merges, ships and clears holds. The command-policy
  deny list, staged-secret scanning and journal integrity are not negotiable (METHODOLOGY §8).
  Config may tighten these; it must not loosen them.
- **Station isolation.** Stations run under `env -i`, with credentials withheld. Any key
  handling has to be explicit per station.
- **Breaking changes go in the 1.0 brief.** It already carries R-14b and R-22
  (role-neutral roles and labels), and `feature-role-signing.md` waits on it.
- **Payload membership lives in `config/payload.tsv` only.** Visibility and removal must
  read that manifest, not keep their own file lists.
- **Reversibility.** Most items are additive. Forge abstraction, label renames and
  visibility modes that move files out of the tree are the expensive-to-reverse ones.

---

## Current state

Much of this already exists in fragments. The work is mostly consolidation and exposing
hardcoded constants, not greenfield.

| Area | Today | Where |
|---|---|---|
| Agent per station | Configurable in 3 layers: defaults → project → operator (`~/.config/agentic-flow/roles/<owner>/<repo>.tsv`), via `agentic-flow roles set` | `config/roles.tsv`, `.agentic-flow-roles`, `scripts/lib/roles.sh` |
| Supported agents | Hand-coded per CLI (`claude`, `codex`, `opencode`): contract mode, sandbox, argv, output parsing, resume and limit enforcement | `scripts/lib/launch.sh:19-23, 349-390` |
| Bounce limit | Hardcoded at 2. The workflow validator only accepts the literals `bounces<2` and `bounces=2` | `config/workflow.tsv`, `scripts/lib/workflow.sh:46` |
| Finding severity | Result schema uses `P1/P2/P3`; the OpenCode reviewer contract uses `sev:nit`. Nothing configures "bounce only at or above X" | `config/stations/result.schema.json`, `.opencode/agent/code-reviewer.md:217` |
| Andon | About 12 hardcoded hold reasons; desktop notification only | `scripts/lib/controller.sh`, `scripts/lib/andon.sh` |
| Other knobs | 4 root dotfiles (`-assurance`, `-review-policy`, `-roles`, `-stack`), 3 TSVs, the env var `AGENTIC_CONTROLLER_LEASE`; hardcoded 50-turn cap and 3,000-word packet limit | repo root, `config/` |
| Forge | GitHub everywhere: `gh` in about 14 libraries, the journal in issue comments, labels as state, GitHub App identities, rulesets | `scripts/lib/*` |
| Install | `init.sh` prompts, with a flag for every prompt and no prompts when not in a terminal | `scripts/init.sh` |
| Upgrade | Writes `.agentic-new` candidates for manual merge; the version stamp is promoted by hand | `agentic-flow upgrade` |
| `status` | Reports the harness **install** (version, merge candidates, git-ignored payload), not the running process. Git-ignored payload is treated as needing action | `scripts/agentic-flow:466` |
| Runtime | `run` is a foreground loop with lock, lease, 50-turn cap and `--once`; recovers by replaying the ledger | `scripts/lib/controller.sh:902` |
| Visibility | Implicit: everything is committed. `publish-scan.sh` exists, but only as a one-off pre-publication audit | `scripts/publish-scan.sh`, `docs/reference/publish-scan.md` |
| Removal | None | — |

---

## Areas and options

### A. Config surface

**Options**

1. **Status quo, documented.** Keep the dotfiles and TSVs and write a reference page.
   Cheap, but the problem stays.
2. **One file, flat dotted `key=value`.** For example `review.max_bounces=2`. Parses in Bash,
   is diff-friendly, and matches `.agentic-flow-review-policy`'s existing style.
3. **JSON.** Uses `jq`, which is already required, and holds nested data. People edit it
   badly and it can't carry comments.
4. **TOML/YAML.** The nicest to read, but needs a parser dependency.

**Recommended: Option 2**, layered the same way `roles` already is:

harness defaults → `.agentic-flow/config` (project, committed) →
`~/.config/agentic-flow/<owner>/<repo>.conf` (operator, never committed) →
`AGENTIC_FLOW_*` env vars → CLI flag.

The commands are `agentic-flow config list|get|set|explain <key>`. `explain` prints the
effective value and the layer that set it. Unknown keys and out-of-range values are errors,
never silently ignored. The existing dotfiles migrate into the file through the upgrade
wizard (area D).

**Secrets and `.env`.** Project config never holds secrets. The operator layer holds
*references* to secrets, for example
`station.executor.key_cmd=security find-generic-password -s flow-codex -w` or
`station.executor.key_env=FLOW_CODEX_KEY`. A gitignored `.env` is acceptable only as an
operator-layer source, and `doctor` warns when it is not ignored. Key presence already
changes behaviour: a set `ANTHROPIC_API_KEY` switches Claude's contract mode from
`overridden` to `excluded` (`launch.sh:22`). So keys are passed explicitly per station and
reported by `roles` and `doctor`, never inherited.

**Candidate keys**

| Key | Default | Notes |
|---|---|---|
| `station.<role>.agent`, `.model`, `.effort`, `.timeout_s`, `.budget_usd`, `.max_turns` | as today | Exists in `roles.tsv`; moves into the file |
| `station.<role>.key_cmd`, `.key_env` | — | New; operator layer only |
| `station.<role>.fallback` | — | A second agent for rate-limit or infrastructure failure |
| `review.max_bounces` | 2 | Range 1–5. Turns the `workflow.tsv` bounce requirement into a parameter |
| `review.block_at` | `major` | Findings at or above this severity bounce the step |
| `review.nonblocking` | `comment` | Below-threshold findings: `drop`, `comment` or `follow-up-issue` |
| `review.require_ci_green` | true | |
| `andon.<reason>` | `hold` | See area C |
| `andon.infra_retries` | 1 | |
| `controller.turn_cap`, `controller.lease_s` | 50, 21600 | Currently hardcoded or env-only |
| `packet.max_words` | 3000 | |
| `budget.plan_usd` | — | Hold when the plan's reported cost exceeds it |
| `notify.channels`, `notify.quiet_hours` | `desktop`, — | Add `ntfy`, a webhook, `issue-mention` |
| `repo.visibility` | `private` | See area I |
| `budget.<wall\|fixtures\|words>.mode[.local\|.ci]`, `budget.wall.scale` | see area K | `stop` or `warn`; values stay in reviewed data files |
| `forge` | `github` | Only accept a value once it works (area H) |
| `assurance`, `stack`, `identity.mode` | as today | Folded in from the dotfiles |

**Severity scale.** Use one scale, `critical > major > minor > nit`, with `P1/P2/P3` as
aliases for the first three. The station result schema and the reviewer contracts both
switch to it. Nits never block, whatever `block_at` is set to.

**Not configurable.** These are the floor: human push/merge/ship/hold-clear; removing
command-policy denies (adding is allowed); disabling secret scanning; integrity holds
(area C).

### B. Agent-agnostic stations

Per-station assignment already works. What is missing is a contract that lets a new agent
plug in without editing `launch.sh`.

**Options**

1. **Keep hand-coded CLIs** and add new ones on request. Cheap per CLI, but grows `launch.sh`.
2. **Adapter interface.** One file per agent, e.g. `scripts/adapters/<agent>.sh`, which
   implements:
   - `probe`: installed, authenticated, version
   - `render_policy`: native deny rules
   - `argv`: the command line
   - `parse`: map output to `result.schema.json`
   - `resume`: continue a session
   - `capabilities`: schema output, enforced budget, sandbox, network isolation
3. **Option 2 plus a generic adapter.** Any command that reads a prompt file and writes
   result JSON.

**Recommended: Option 2**, with the generic adapter from Option 3 allowed only in the
accepted-risk tier. Capabilities drive posture. An agent whose `doctor --stations` probe
cannot show native refusals is assignable only with an accepted risk, which is how
`opencode-station-network` already works. Planner and closer roles (today
`agent:claude,needs-closing`) need the same treatment. That requires **R-22** (role-named
labels such as `role:executor`, and `git-<role>` signing wrappers), so this area belongs
in the 1.0 brief.

### C. Andon policy

Today's hold reasons split into two classes:

- **Integrity, always hold** (not configurable): `foreign-controller-host`,
  `ledger-body-hash-mismatch`, `ledger-invalid`, `station-changed-branch`,
  `unexplained-worktree-changes`, `worktree-changed-after-salvage`, `illegal-transition`,
  `unjournaled`.
- **Policy** (`hold` | `retry:N` | `fallback-agent` | `notify-only`):
  `station-infrastructure`, `turn-cap`, bounce limit reached, `findings-incomplete`, and a
  new `budget-exceeded`.

A station `ask` is always an andon. What is configurable is how it reaches the human
(`notify.channels`), which also covers the earlier idea of answering asks by replying on
the ticket.

### D. Interactive setup and upgrade

**Setup.** `agentic-flow setup` wraps `init.sh` and keeps its rules: a flag for every prompt,
no prompts when not in a terminal, and `--answers <file>` for repeatable setups. It:

- detects installed agent CLIs and their auth, and offers station assignments
- detects the forge from `git remote` and asks for visibility (area I)
- asks for the bounce limit, the blocking severity and notification channels
- writes the config, creates labels, wires `core.hooksPath`
- finishes with `doctor --check` and `doctor --stations`

**Upgrade.** The upgrade wizard is the bigger quality-of-life win. It:

- shows new, renamed and removed config keys and migrates them
- walks each `.agentic-new` candidate with keep / take / open in `$EDITOR` / defer
- promotes `.agentic-flow-candidate-version` automatically when nothing is pending, which
  removes a manual step adopters keep missing

Optional `gum` styling may be used when present, with plain `read` as the fallback.

### E. Process status

All the data already exists: ledger, journal, holds, `.metrics.json`, lock and lease. The
gap is a view that answers **"whose turn is it?"**

`agentic-flow status` becomes the process view. The current output moves to
`agentic-flow install-status` (or into `doctor`). Proposed output:

```
plan phase-4  (controller: alive, pid 4821, turn 12/50, lease 5h40m)
  s-1 approved        s-2 approved
  s-3 reviewing       opencode · 6m12s / 20m · bounce 1/2
  s-4 executing       codex · queued
  HOLD  #212 station-ask — "Which migration path?"  → you: answer on #212, then `hold clear …`
  cost $3.40 · first-pass yield 67%
```

It also supports `--watch` (ANSI redraw, no dependency) and `--json`. It needs a
controller heartbeat file so it can tell "running" from "dead with an unexpired lease".

### F. CLI vs GUI

| Option | Verdict |
|---|---|
| Web dashboard | **No.** It needs a server, auth and dependencies, and the forge's issue pages already serve as the remote UI |
| Full TUI (bubbletea etc.) | **No.** It breaks the Bash-only, few-dependencies model |
| Good CLI: `status --watch`, wizards, notifications | **Yes** |
| Static HTML report (`status --html`, like the explainer) | **Maybe later**, if a shareable snapshot is wanted |

Revisit a TUI only if the controller is ever rewritten in another language.

### G. Daemon vs scripts

| | Foreground script (today) | Detached script + service unit | Real daemon | CI-hosted controller |
|---|---|---|---|---|
| Pros | Simple, visible, easy to kill | Survives closing the terminal; cheap | Many plans/repos; event-driven | No laptop needed; logs for free |
| Cons | Tied to a terminal; stops on a hold and needs a manual restart | Still one plan per process | State, upgrades, health checks, auth: much more code | Secrets in CI, slow, runner cost; agent CLI login on runners |
| Effort | — | Small | Large | Large (Option 3 in the factory analysis) |

**Recommended: scripts, plus `run --detach`.** It writes pid, log and heartbeat for
`status`. Ship launchd and systemd user-unit templates. Add `run --wait-human`, which polls
open holds with backoff and resumes once they are cleared or answered. That covers the one
real reason to want a daemon. The controller already rebuilds state from the ledger on
every turn, which is the property a daemon would otherwise provide.

### H. Forge: GitHub or GitLab

This is the largest item, bigger than the rest combined. GitHub-specific pieces include:
the journal (issue comments), holds, label-driven state, GitHub App identities, rulesets,
CI status, `ship`, `publish-scan`'s GitHub surface, and the command policy (`gh` denies).

**Options**

1. GitHub only, stated plainly.
2. Extract a forge interface with GitHub as its only implementation (non-breaking), then add
   GitLab later.
3. Build GitLab support directly.

**Recommended: Option 2, after 1.0**, unless the owner has a concrete GitLab adopter (see
*Decisions*). `forge=gitlab` is not accepted by config until it works end to end.

### I. Repository visibility and harness exposure

There are two separate exposure surfaces:

1. **The tree.** Harness files committed to the repo:
   - agent instructions: `CLAUDE.md`, `AGENTS.md`, `.claude/`, `.codex/`, `.opencode/`, `.agents/`
   - process docs: `METHODOLOGY.md`, `ADOPTION.md`, `docs/templates`, `docs/memory`, `docs/accepted_risks.md`
   - scripts and config: `scripts/`, `config/`, `profiles/`
   - identity data: `.agentic-flow-review-policy` with logins and bot names
2. **Forge traffic.** On a public repo, issue comments are public: journal markers, controller
   run hostnames, temp paths, agent summaries. This is where the real leaks were. This
   repo's own pre-publication scan found 114 run-host, 6 temp-directory and 9
   absolute-path findings in GitHub comments, and zero credentials in the tree. Git history
   adds personal emails and hostnames.

**Hiding files only goes so far:**

- `.gitignore` is itself committed, so it advertises the harness. `.git/info/exclude`
  doesn't, but it is per clone.
- Plan worktrees created by `agentic-flow start` are fresh checkouts. Ignored files are
  **absent there**, and stations read `CLAUDE.md` and `AGENTS.md` from the worktree.
  Hiding them needs a sync step: symlink or copy from one local source into each worktree.
- CI runs `make check`/`make test`, which need `scripts/`, `config/` and the `Makefile`
  targets. A fully hidden harness has no CI gate. That conflicts with the "CI as authority"
  decision (`feature-ci-as-authority.md`).
- Ignoring files later doesn't remove them from history. Going public after committing the
  harness means accepting history or rewriting it.
- `status` currently reports git-ignored payload as needing action, and adopters have been
  bitten by a blanket `.claude/` ignore. A hidden mode reverses that assumption, so it must
  be an explicit, declared mode, never an accident.

**Options**

1. **Committed (today).** Everything is in the tree. Simplest, CI works, and worktrees just
   work. Exposes the process and identity data on public repos.
2. **Tiered exposure by `repo.visibility`.** Payload rows in `config/payload.tsv` gain an
   exposure class: `required` (CI and gate: scripts, config, Makefile targets, CI
   workflow), `instructions` (agent contracts and skills), `process` (methodology, docs
   templates, memory), `identity` (review policy). Then:
   - `private`: all committed (as today).
   - `public`: `instructions`, `process` and `identity` are kept local through
     `.git/info/exclude` plus worktree sync. `required` stays committed. Forge-traffic
     hygiene is on: no hostnames, absolute paths or temp paths in comments, and noreply
     commit emails are checked.
   - `private-then-public`: commit everything, but with public-grade forge hygiene from
     day one. `publish-scan.sh --surface all` becomes a standing check, not a one-off.
     `agentic-flow publish prepare` lists what to exclude or strip, what history rewrite
     or acceptance is needed, and the forge comments to edit before the visibility flip.
3. **Overlay repo.** The harness lives in a separate private repo mounted beside the
   product repo. That is maximum isolation, but it breaks the single-checkout model,
   worktrees, CI and upgrade.

**Recommended: Option 2.** The decisive dimension is that forge-traffic hygiene applies to
every non-private mode and costs little. Most of the real exposure is there, not in the
tree. Ship that part first, plus `private-then-public` (a standing scan and a
`publish prepare` checklist). The `public` hidden-files tier is the expensive part
(worktree sync, `status`/`doctor` changes, CI split), so build it second, and only if an
adopter actually wants the agent files out of a public tree. Option 3 is rejected.

### J. Removing the harness

`agentic-flow uninstall [--dry-run] [--keep-docs] [--force] [--yes]`. The default is a
dry run that prints the removal plan.

**What it removes, by category:**

| Category | Items | Handling |
|---|---|---|
| Pristine payload | Every `config/payload.tsv` destination identical to the installed version | Delete |
| Hand-merged contracts | `CLAUDE.md`, `AGENTS.md`, `Makefile` (adopters merge their own content into these) | Delete only when byte-identical to the exported pristine copy; otherwise leave and report. Long-term: add managed-region markers so only the harness region is removed |
| Stamps and state | `.agentic-flow-version`, `-source`, `-candidate-version`, `-assurance`, `-roles`, `-stack`, `-review-policy`, `.agentic-new*` candidates, generated station rules | Delete |
| Project knowledge | `docs/` plans, done docs, accepted risks, memory | **Keep by default.** `--keep-docs=false` removes only the empty skeleton and templates |
| Local Git state | `core.hooksPath`, plan worktrees and branches (reuse `clean`), ledger and codex-home under the Git common dir `agentic-flow/` | Remove, after confirmation |
| Operator machine | `~/.config/agentic-flow/…`, `~/.codex/agentic-station.config.toml`, installed Codex rules, keychain App keys | Print as a manual checklist; never touch automatically |
| Forge | Workflow labels, open tracker and step issues, GitHub Apps, the `main` ruleset requiring **CI gate**, the copied CI workflow | Print as a checklist. **Warn first if a ruleset requires the CI gate check**, since removing the workflow then blocks every merge |

**Safety:**

- Refuses while a controller lock is held, or while a plan is in progress, unless `--force`.
- Produces one removal commit with files staged by name, never pushed.
- Is verified by a self-test round trip: export into a fixture, uninstall, and the tree
  must match the pre-export state.

Removal reads the same manifest as export, which keeps the "payload membership lives in
`payload.tsv`" rule.

### K. Test and harness budgets: warn or stop

The owner asked on 2026-11-25 that wall-time ceilings and fixture counts be configurable
as either a **warning** or a **flow-stopper**. Today every budget is a hard failure, and
some are not configurable at all.

| Budget | Today | Where | Deterministic? |
|---|---|---|---|
| Wall-time ceilings per test group and tag | Values configurable in a TSV. Exceeding one fails `self-test` | `config/test-wall-ceilings.tsv`, `scripts/self-test.sh:287-330` | **No.** Depends on host load and speed |
| Fixture file/tree copies | Hardcoded: fast ≤ 33 files and 0 trees, full ≤ 194 files and ≤ 1 tree, exported full ≤ 117 files | `scripts/self-test.sh:338-353, 590-593` | Yes |
| Role-bundle word ceilings | Rounded baseline; exceeding it fails | `scripts/measure-harness.sh:93` | Yes |
| Packet word limit | Hardcoded 3,000 | `config/stations/README.md` | Yes |

Because `make check` runs in the Stop hook and in CI, a hard budget stops two things: an
agent cannot end its turn, and CI goes red. That is right for a deterministic regression,
such as a test that starts copying whole trees. It is wrong for a slow host. An adopter on
a loaded laptop or a slower CI runner gets red gates that no code change can fix, which is
the failure C-5 in the factory analysis describes.

**Options**

1. **Keep all budgets hard; tune the values.** Simple, but time budgets stay flaky off the
   reference host.
2. **Per-budget mode, `stop` or `warn`.** In `warn` mode the check prints the overrun,
   exits 0, and records it so it stays visible: in the verification record that reviewer
   packets reuse, and as a `notify-only` andon under the controller.
3. **Option 2 plus per-context modes and a time scale.** For example
   `budget.wall.mode.local=warn`, `budget.wall.mode.ci=stop`, and
   `budget.wall.scale=1.5` for slower runners, so ceilings stay meaningful without
   per-host edits.

**Recommended: Option 3**, with these defaults:

- `budget.fixtures.mode=stop`, `budget.words.mode=stop`. These budgets are deterministic,
  so an overrun is a real regression.
- `budget.wall.mode.local=warn`, so the Stop hook never traps an agent over machine load.
- `budget.wall.mode.ci=stop`, with `budget.wall.scale=1.0`. CI is the reference
  measurement.
- The fixture limits (33 / 194 / 117) move out of `self-test.sh` into a data file next to
  the wall-time ceilings, for example `config/test-budgets.tsv`. Each value keeps its own
  range check.

Guardrails:
- These are efficiency budgets, not part of the safety floor (area A), so switching to
  `warn` is allowed.
- The switch is never silent. `doctor` and `status` list every budget running in `warn`
  mode, and each overrun is recorded with the measured value and the limit.
- Changing a budget's *value* stays a reviewed file change, as it is today.
- Mode is the only thing configuration controls.
- This repository's own CI keeps every budget at `stop`.

---

## Recommendation

**Recommended:** build in this order, each as its own Feature doc.

1. **Status and observability** (E, G): process `status`, `--watch`, heartbeat,
   `run --detach`, `run --wait-human`. Low risk, highest day-to-day value, no breaking change.
2. **Config consolidation** (A, C, K): one file, `config` command, bounce limit, blocking
   severity, andon policy, notifications, cost budgets, warn/stop modes for test budgets,
   unified severity scale.
3. **Uninstall** (J): small, self-contained, and it forces the payload manifest to describe
   everything export writes. That also benefits upgrade.
4. **Setup and upgrade wizards** (D): depend on 2.
5. **Visibility, part 1** (I): `repo.visibility`, forge-traffic hygiene,
   `private-then-public` with a standing scan and `publish prepare`.
6. **Agent adapters + R-22** (B): fold into the 1.0 brief.
7. **Visibility, part 2** (I): the hidden-files `public` tier with worktree sync. Only on
   demand.
8. **Forge interface, then GitLab** (H): after 1.0.

The deciding factor is that items 1–3 cost little, break nothing, and remove the most
day-to-day friction. Items 6–8 are breaking or large and should wait for the 1.0 boundary.

**Defer:**

- GUI and TUI, until a non-Bash controller exists.
- A long-running daemon, unless `run --wait-human` proves insufficient.
- GitLab, until there is a real adopter.
- The hidden-files `public` tier, until an adopter asks to keep agent files out of a public
  tree.

## Decisions to make up front

- [ ] **Safety floor.** Accept "config can tighten, never loosen"? Or allow loosening some
      items behind an accepted risk?
- [ ] **Bounce limit scope.** One global value, or per assurance level (e.g. Strict 1,
      Standard 3)?
- [ ] **Below-threshold findings default.** `comment` (quiet) or `follow-up-issue`
      (traceable, noisier)?
- [ ] **GitLab.** A real near-term need (moves the forge interface before 1.0) or
      future-proofing (after 1.0)?
- [ ] **Notification channel** after desktop: ntfy, a Slack/Discord webhook, or an issue
      mention?
- [ ] **`status` naming.** The process view takes `status`, and today's output moves to
      `install-status`/`doctor`. That is a CLI behaviour change for adopters' scripts.
- [ ] **Visibility default.** `private` for new adoptions? And which files count as
      `instructions` versus `required` in a public tree?
- [ ] **Budget modes.** Accept area K's defaults (deterministic budgets stop; wall time
      warns locally and stops in CI)? Should adopters' CI also default to `stop`, or to
      `warn` until they calibrate their ceilings?
- [ ] **Uninstall and hand-merged contracts.** Leave-and-report now, or invest in
      managed-region markers in `CLAUDE.md`/`AGENTS.md`/`Makefile` first?

## If approved → next docs

- [ ] `docs/inprogress/feature-process-status.md` — areas E, G (phase 1; drafted 2026-11-25 on `configurability-phase-1`)
- [ ] `docs/inprogress/feature-config-surface.md` — areas A, C, K
- [ ] `docs/inprogress/feature-uninstall.md` — area J
- [ ] `docs/inprogress/feature-setup-upgrade-wizard.md` — area D
- [ ] `docs/inprogress/feature-visibility-modes.md` — area I (part 1; part 2 on demand)
- [ ] Area B folded into the 1.0 brief alongside R-14b and R-22
- [ ] `docs/backlog/feature-forge-interface.md` — area H

## Status

- **Decision:** pending.
- **Decided by:** —
