# Adopt agentic-flow

Use `scripts/init.sh` from this scaffold repo to install the harness into a target project.
It wraps the low-level exporter, fills the project token, preserves existing files with
`.agentic-new` copies, and prints the doctor report when it finishes.

## Required Tools

- `bash`
- `make`
- `git`
- `jq`
- `gh`
- `git-claude`, unless the project opts out of Claude commits
- `git-codex`, unless the project is Claude-only or otherwise opts out of Codex execution
- `shellcheck` — `make test` fails without it
- `gitleaks` — one of the two layers in the staged-secret hook

## Usage

```bash
scripts/init.sh /path/to/target-project --name my-project --stack node --yes
```

Flags:

- `--name <kebab>`: required for non-interactive runs; fills `CLAUDE.md` and `AGENTS.md`.
- `--stack generic|node|python|go|rust`: renders Makefile recipes from `profiles/`.
  `none` is a compatibility alias for `generic`. Without an explicit flag, manifest
  detection proposes a profile; it never overrides an explicit choice.
- `--claude-only`: records the opt-out from the default Claude/Codex split.
- `--git-init`: runs `git init` when the target is not already inside a git repo.
- `--yes`: non-interactive mode. Missing required flags fail instead of being guessed.
- `--dry-run`: delegates to `scripts/export.sh --dry-run` and writes nothing.

When stdin is a TTY and `--yes` is absent, `init.sh` prompts for missing flags. Each prompt
names the flag it fills, so an interactive run teaches the scriptable form.

## Adopting into an existing project

Existing projects are the normal case. The harness is intentionally non-destructive:
existing files that differ are preserved and the incoming harness copy lands beside them as
`<file>.agentic-new` (or a suffixed variant when that name is occupied). Merge those by
hand, then run the verifier again.

Watch for blanket ignore rules before committing the harness. A rule like `.claude/` can
hide the exported hook configuration from git even though it exists on disk. Both
`scripts/doctor.sh --check` and `scripts/agentic-flow status` report manifest payload paths
that are git-ignored; fix the ignore rule or explicitly unignore the harness files before
you treat the adoption as complete.

## Verify

New adoptions receive a tracked `.agentic-flow-assurance` baseline of `standard`.
`scripts/assurance.sh status` reports the baseline and whether it came from the file or
the legacy default; `scripts/assurance.sh --check` validates it. Raise with
`scripts/assurance.sh set strict`. Lowering requires `--approved-by <human-identity>` and
`--reason <text>`, recorded in `.agentic-flow-assurance-audit` for review in the tracked
diff. The claimed approval is not authenticated by the CLI. Export and upgrade preserve
an adopter's baseline, including under `--force`. The assurance policy lives in
`METHODOLOGY.md` §2. Until F-10, issue creation retains the existing tracker-and-steps
shape regardless of baseline. CI checks do not vary with assurance state.

`scripts/doctor.sh` is the verifier. It reports required tools, agent adapters, stack
profile, unresolved merge candidates, active/pending scaffold versions, Make targets,
hook wiring, CI posture, and docs-index freshness.

Run this in the target before committing the harness:

```bash
scripts/doctor.sh --check
make check
```

`make test-one F=<group>` runs one focused harness group when the scaffold itself is under
change: `export`, `contracts`, `hooks`, `plan-to-issues`, `lifecycle`, or `upgrade`.
`make test` still runs the complete suite plus `shellcheck`.

Agent context is intentionally progressive. Executors start from `AGENTS.md`, the issue,
the linked brief step, `CLAUDE.md` Stack profile/Gotchas, and live call sites/tests.
Planner and close-out work starts from `CLAUDE.md` plus the relevant template, Tracker,
issue states, review verdicts, CI evidence, and lifecycle output. Load `METHODOLOGY.md` by
referenced section, not by default.

## Versioning

`.agentic-flow-version` in the target holds `<semver>+<sha>` — e.g. `0.9.0+661d9da`. The
semver half (from this repo's `VERSION`) is what you compare against release notes; the
`+sha` half pins the exact commit an update was cut from, for tooling that needs it exactly.
`doctor.sh` reports both halves split apart. Re-running `scripts/export.sh` against a target
already on an older stamp writes `.agentic-flow-candidate-version` and leaves `.agentic-new`
merge candidates until you resolve them by hand — see `METHODOLOGY.md`'s header for the bump
policy.

`.agentic-flow-source` records where upgrades come from:

```text
origin https://github.com/wabkebab/agentic-flow
ref main
```

Fresh adoptions get this automatically when the source scaffold has a git remote. Projects
adopted before this file existed must back-fill it once, replacing the URL/ref as needed:

```bash
printf 'origin https://github.com/wabkebab/agentic-flow\nref main\n' > .agentic-flow-source
```

The ref is opaque data. It is `main` today, and can be a tag later.

## Upgrading

Adopted projects receive `scripts/agentic-flow`:

```bash
scripts/agentic-flow status
scripts/agentic-flow diff
scripts/agentic-flow upgrade --yes
```

- `status` is offline and read-only. It reports the installed version, pending candidate
  version, unresolved `.agentic-new` files, stack profile, detected adapters, recorded
  source, and git-ignored payload paths.
- `diff` fetches the recorded source/ref into a temporary cache and reports what would
  create, overwrite, or land as a merge candidate. It writes nothing. Use
  `scripts/agentic-flow diff --ref <tag-or-branch>` for a one-off comparison without
  changing `.agentic-flow-source`.
- `upgrade` fetches the recorded source/ref and applies only files declared by
  `config/payload.tsv`. It follows the same `.agentic-new` policy as export: customized
  files are not silently overwritten, and `.agentic-flow-version` advances only when no
  merge candidates remain. Otherwise `.agentic-flow-candidate-version` records the pending
  standard version.

The pull-side upgrade path executes nothing from the fetched standard. If docs changed,
review the result and then run `scripts/docs-index.sh` yourself. After resolving any
`.agentic-new` files, rerun `scripts/agentic-flow upgrade --yes`; matching pending
candidates are reused rather than duplicated.

`upgrade` also records the source it last applied in `.agentic-flow-source-applied`. If the
origin in `.agentic-flow-source` later changes, upgrade stops until you inspect the change
and rerun with `--force`.

## CI

`templates/ci/ci.yml` is exported **inert** — adoption never activates a workflow on its
own. Copy it to `.github/workflows/ci.yml`, fill the `<ANGLE-BRACKET>` spots, and make
**`CI gate`** the only required status check in branch protection. `templates/ci/deploy.yml`
is the optional deploy counterpart; read its runbook comment before enabling it. See
`templates/ci/README.md` and `METHODOLOGY.md` §10.

Run `scripts/export.sh` from the source scaffold for low-level installs or update
candidates. It is intentionally source-only; adopted projects receive runtime checks and
profiles, not another installer.
