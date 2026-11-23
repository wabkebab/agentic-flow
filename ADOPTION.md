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

In a Git checkout, `init.sh` sets `core.hooksPath` in the shared repository
configuration so the staged-secret scan runs in every worktree. If you used
the low-level exporter or ran `git init` after adoption, configure it before
committing:

```bash
git config --local core.hooksPath scripts/git-hooks
```

If you already use a custom hooks path, keep that setting and call
`scripts/git-hooks/pre-commit` from your existing pre-commit hook. Propagate
its exit status. For an intentional false-positive override, prefix the
commit with `AGENTIC_ALLOW_SECRET=1`.

For interactive Codex, install the native command policy and review the project
hooks with `/hooks` so Codex can run the attached Git-directory guard:

```bash
mkdir -p "${CODEX_HOME:-$HOME/.codex}/rules"
cp config/stations/command-policy.rules "${CODEX_HOME:-$HOME/.codex}/rules/agentic-flow.rules"
```

New adoptions receive a tracked `.agentic-flow-assurance` baseline of `standard`.
`scripts/assurance.sh status` reports the baseline and whether it came from the file or
the legacy default; `scripts/assurance.sh --check` validates it. Raise with
`scripts/assurance.sh set strict`. Lowering requires `--approved-by <human-identity>` and
`--reason <text>`, recorded in `.agentic-flow-assurance-audit` for review in the tracked
diff. The claimed approval is not authenticated by the CLI. Export and upgrade preserve
an adopter's baseline, including under `--force`. The assurance policy lives in
`METHODOLOGY.md` §2. Issue shape follows each spec's profile: Standard creates one work
issue, Strict creates a tracker plus step issues, and a spec without a profile keeps the
legacy tracker-and-steps shape. CI checks do not vary with assurance state.

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

[`config/test-wall-ceilings.tsv`](config/test-wall-ceilings.tsv) sets the
allowed seconds for each self-test group and each controller and stations tag.
A focused run checks the group ceiling. Adding `S=<tag>[,<tag>…]` checks only
the selected tags. The full suite checks each shard and sums the tag shard
durations for each tagged group's ceiling. `make check` requires a ceiling for
every group and tag. Set `AGENTIC_MEASURE_EVENTS` to an absolute output file to
capture group and tag seconds. Raising a ceiling requires review. Include a
fresh measurement and explain the headroom in the proposed change.

Agent context is intentionally progressive. Executors start from `AGENTS.md`, the issue,
the linked brief step, `CLAUDE.md` Stack profile/Gotchas, and live call sites/tests.
Planner and close-out work starts from `CLAUDE.md` plus the relevant template, Tracker,
issue states, review verdicts, CI evidence, and lifecycle output. Load `METHODOLOGY.md` by
referenced section, not by default.

States live in `METHODOLOGY.md` §6: executors use `brief`, `verify-step`, `handoff submit`;
reviewers use `packet`, `verify-step`, `handoff approve|bounce`; closers use `close-out prep|finish`.

## Controller setup

Set `owner=<human GitHub login>` in `.agentic-flow-review-policy` for andon.
Install the Codex station profile when Codex is assigned:

```bash
mkdir -p ~/.codex
cp config/stations/codex.config.toml ~/.codex/agentic-station.config.toml
```

Use `scripts/agentic-flow roles` to inspect effective assignments and their layers.
For example, `scripts/agentic-flow roles set reviewer claude --scope project` stages
that project choice; omit `--scope` for the operator layer, which overrides the project.
Use `roles manual reviewer` to work that station interactively with the Phase 1 commands;
`roles unset reviewer` removes the selected layer's override.

Before unattended `scripts/agentic-flow run <doc>`, the entry gate requires
`distinct-account`, working GitHub App tokens for executor, reviewer and approver,
and isolation preflight for each non-manual station. Install the profiles and configure
App identities below first. The gate also requires accepted risks for OpenCode and an
identical CLI/model pair. OpenCode has no OS network boundary: before using it unattended,
accept [opencode-station-network](docs/accepted_risks.md#opencode-station-network)
in the adopting project's risk register, or assign another CLI. Use supervised
`run <doc> --once` when the gate is not satisfied; it skips the entry gate and runs
one station. Answer andon, then run `ship <doc>` from the plan worktree when ready. For
a new PR, `ship` prepares and commits the close-out before its first push. If it stops
with a staged close-out, commit it before resuming `ship`. Merge after its gates pass.

For an identical effective CLI and model on both stations, add and approve this entry
in the project's `docs/accepted_risks.md` before unattended use:

```markdown
<a id="same-model-review"></a>
## Same-model review
**Status:** Accepted risk

Executor and reviewer use the same CLI and model, reducing independent model diversity.
Revisit when a suitable independent reviewer is available or review misses a defect.
```

The check compares CLI and model strings, not underlying models across different CLIs;
using different CLI/model strings does not prove independence.

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

The CI template includes carry-forward for green App checks. It reuses a result only
when the PR merge checkout has the same tracked App inputs and links the source run.
To extend the bookkeeping list, add negated path globs to `app` in the active workflow's
`changes` job path filter. Keep App inputs and payload files out of those globs. Extend
the Docs filter to cover the new paths and run any checks that can fail on those paths in
the Docs job. The App input key reads the same bookkeeping list from the active workflow.

Run `scripts/export.sh` from the source scaffold for low-level installs or update
candidates. It is intentionally source-only; adopted projects receive runtime checks and
profiles, not another installer.

Existing adopters must add reviewer, executor and approver login lines to
`.agentic-flow-review-policy`, including in single-operator mode. One login may
hold all three roles. Initialize new projects with `--owner-login <login>`;
otherwise init uses `gh api user --jq .login`.
For direct `scripts/export.sh` installs, replace the owner-login tokens in all
three policy role lines with GitHub logins before running doctor or the gates.

## GitHub App role identities (optional)

The `executor` implements steps and the `reviewer` reviews them. The `approver` is
the planner/closer identity, distinct from `--approved-by`, which names the human
who approved the plan. Switching to `distinct-account` is an adoption decision
that removes the `accepted-risk=` line from the policy.

1. Register three GitHub Apps, one per role. Disable webhooks if unused. Give each
   only repository permissions **Issues: write**, **Pull requests: write**,
   **Contents: read**, **Metadata: read**. Install each using **Only select
   repositories**, selecting the target repository. Record its numeric App ID,
   installation ID and bot login (`app-slug[bot]`).
2. Generate each App's RSA private key and store it in the workstation keychain,
   never in the repository or identity TSV. On macOS, use
   store a single-line base64 encoding through `security`'s stdin protocol:

   ```bash
   printf 'add-generic-password -U -s execute-key -a "%s" -w "%s"\n' \
     "$USER" "$(openssl base64 -A < /path/to/downloaded.pem)" | security -i
   ```

   On Linux, store the raw PEM with
   `secret-tool store --label="Executor App" service agentic-flow key-ref execute-key < /path/to/downloaded.pem`.
   Use separate key-ref names for reviewer and approver. Remove downloaded key
   files after confirming keychain access.
3. Create `${XDG_CONFIG_HOME:-$HOME/.config}/agentic-flow/identities/<owner>/<repo>.tsv`.
   Each row has five **tab-separated** fields, with no header (comments start `#`):
   `role`, `login`, `app-id`, `installation-id`, `key-ref`. For example, an executor
   row contains `executor`, `execute-app[bot]`, its numeric App ID, its numeric
   installation ID, and `execute-key`. Add one row for each role.
4. Put those canonical bot logins into their corresponding role lines in
   `.agentic-flow-review-policy`, preserving its workflow and identity-mode rules.
   `distinct-account` rejects a reviewer overlapping executor or approver. Run
   `scripts/agentic-flow token executor --check`, repeat for reviewer and approver,
   then run `scripts/doctor.sh --check` to check all roles.

Minting requires `openssl`, `curl`, `jq`, `git` and the platform keychain tool.
The request selects the repository and four permissions explicitly, following
[GitHub's installation-token interface](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app).
Every mint validates returned scope and expiry. `--check` prints no token; without
it, the command prints the token to stdout for an in-memory caller. The command
never persists keys, JWTs or tokens. Do not redirect them to files.

A missing role returns 6 (`no identity`). A configured identity that cannot mint
returns 5 and never falls back to ambient credentials. Only callers may use an
ambient login after exit 6, and only if it holds the role in the policy. Doctor
skips identity checks quietly when no operator file exists. `--scope repo` remains
portable and never reads the keychain or mints tokens.

REST comment authors use `slug[bot]`; GraphQL and `gh issue view --json comments`
can use `slug`. The hook reads REST user types and lifecycle requests GraphQL
`__typename`. Both share a normalizer that adds `[bot]` only for a typed Bot,
keeping a human with the same slug separate.
