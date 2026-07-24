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

Recommended: `gitleaks`. The staged-secret hook uses it when present and falls back to a
narrower built-in pattern set otherwise.

## Usage

```bash
scripts/init.sh /path/to/target-project --name my-project --stack none --yes
```

Flags:

- `--name <kebab>`: required for non-interactive runs; fills `CLAUDE.md` and `AGENTS.md`.
- `--stack none|node`: chooses Makefile recipes. `none` keeps the generic scaffold recipes;
  `node` writes npm-oriented recipes and prints a reminder to verify `package.json`.
- `--claude-only`: records the opt-out from the default Claude/Codex split.
- `--git-init`: runs `git init` when the target is not already inside a git repo.
- `--yes`: non-interactive mode. Missing required flags fail instead of being guessed.
- `--dry-run`: delegates to `scripts/export.sh --dry-run` and writes nothing.

When stdin is a TTY and `--yes` is absent, `init.sh` prompts for missing flags. Each prompt
names the flag it fills, so an interactive run teaches the scriptable form.

## Verify

`scripts/doctor.sh` is the verifier. It reports required tools, required files, hook wiring,
placeholder Make targets, the scaffold version stamp, and docs-index freshness.

Run this in the target before committing the harness:

```bash
scripts/doctor.sh --check
make check
```

## CI

`templates/ci/ci.yml` is exported **inert** — adoption never activates a workflow on its
own. Copy it to `.github/workflows/ci.yml`, fill the `<ANGLE-BRACKET>` spots, and make
**`CI gate`** the only required status check in branch protection. `templates/ci/deploy.yml`
is the optional deploy counterpart; read its runbook comment before enabling it. See
`templates/ci/README.md` and `METHODOLOGY.md` §10.

`scripts/export.sh` remains available as the low-level non-destructive copy operation for
manual or unusual adoptions.
