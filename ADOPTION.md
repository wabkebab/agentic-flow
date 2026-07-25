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

## Verify

`scripts/doctor.sh` is the verifier. It reports required tools, agent adapters, stack
profile, unresolved merge candidates, active/pending scaffold versions, Make targets,
hook wiring, CI posture, and docs-index freshness.

Run this in the target before committing the harness:

```bash
scripts/doctor.sh --check
make check
```

## Versioning

`.agentic-flow-version` in the target holds `<semver>+<sha>` — e.g. `0.9.0+661d9da`. The
semver half (from this repo's `VERSION`) is what you compare against release notes; the
`+sha` half pins the exact commit an update was cut from, for tooling that needs it exactly.
`doctor.sh` reports both halves split apart. Re-running `scripts/export.sh` against a target
already on an older stamp writes `.agentic-flow-candidate-version` and leaves `.agentic-new`
merge candidates until you resolve them by hand — see `METHODOLOGY.md`'s header for the bump
policy.

## CI

`templates/ci/ci.yml` is exported **inert** — adoption never activates a workflow on its
own. Copy it to `.github/workflows/ci.yml`, fill the `<ANGLE-BRACKET>` spots, and make
**`CI gate`** the only required status check in branch protection. `templates/ci/deploy.yml`
is the optional deploy counterpart; read its runbook comment before enabling it. See
`templates/ci/README.md` and `METHODOLOGY.md` §10.

Run `scripts/export.sh` from the source scaffold for low-level installs or update
candidates. It is intentionally source-only; adopted projects receive runtime checks and
profiles, not another installer.
