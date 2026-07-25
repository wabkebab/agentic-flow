# CI workflow templates

Reference implementations of the pipeline shape in [`METHODOLOGY.md`](../../METHODOLOGY.md)
§10. Both ship **inert** — the scaffold exports them here, not into `.github/workflows/`,
so adopting the harness never activates CI or a deploy behind your back.

| File | Trigger | Activate by |
|------|---------|-------------|
| `ci.yml` | `pull_request` | `cp templates/ci/ci.yml .github/workflows/ci.yml` |
| `deploy.yml` | push to a release branch | `cp templates/ci/deploy.yml .github/workflows/deploy.yml` |
| `release-native.yml` | push of a `v*` tag | `cp templates/ci/release-native.yml .github/workflows/release-native.yml` |

## Activating `ci.yml`

1. Copy it into `.github/workflows/`.
2. Fill the path-filter `<ANGLE-BRACKET>` spots for your project. The runtime setup block
   is filled by `init.sh --stack <profile>` in the inert template before activation.
   Everything else works unmodified.
3. Confirm `make check`, `make test`, and `make build` are real recipes — the workflow
   calls Make targets so CI green means the same thing as local green.
4. Re-verify the pinned action SHAs against current releases (§9). A pin you inherited
   is not a version you chose.
5. Open a throwaway PR and let it run before making anything required.
6. In branch protection, make **`CI gate`** the required status check — and *only* that
   one. The per-area jobs skip on unrelated PRs, a skipped job never reports, and a
   required check that never reports blocks the PR forever.

Adding a job later means adding it to `ci-gate`'s `needs` **and** to the result loop
inside it. A job missing from the loop is a job nothing enforces.

### The `Repo-scope scaffold doctor` step

The `app` job runs `scripts/doctor.sh --check --scope repo --skip-make-check` right after
`make check`. It gates the *harness* invariants CI would otherwise never see — payload
files present, hooks wired, docs index derived, no unfilled placeholders left behind.

`--skip-make-check` exists only for this call site: doctor's last check is behavioural
(it shells out to `make check` to prove the recipe is actually green, not merely wired),
and the step above already did exactly that. Without the flag, every CI run paid for
`make check` twice. The flag is rejected outside `--scope repo`, so it cannot be used to
quietly drop the behavioural check from a full doctor run.

If your project is still mid-adoption, run `scripts/doctor.sh --check` locally and clear
its findings before you make `CI gate` a required check — otherwise this step is the one
that will fail.

## Keeping the pins honest

`scripts/check-action-pins.sh` scans `.github/workflows/` and `templates/ci/`:

```bash
scripts/check-action-pins.sh            # structure fatal, staleness warns — runs in `make check`
scripts/check-action-pins.sh --online   # resolve pins against GitHub, report newer releases
scripts/check-action-pins.sh --strict   # staleness fatal too — for a scheduled run
scripts/check-action-pins.sh --stamp    # record today as the re-verification date
```

A tag pin or a SHA with no `# vX.Y.Z` comment fails immediately. Staleness only warns in the
fast gate: pins decay with the calendar, not with your edits, so failing `make check` on a
date would turn the repo red without anyone touching it — and the Stop hook would start
blocking agents over it. Put the teeth in a scheduled workflow instead:

```yaml
name: Action pin audit
on:
  schedule:
    - cron: '0 6 * * 1'     # Monday morning
  workflow_dispatch:
permissions:
  contents: read
jobs:
  pins:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - run: scripts/check-action-pins.sh --strict --online
```

The re-verification workflow: run `--online`, bump anything it reports, confirm it comes
back clean, then `--stamp`.

## Activating `deploy.yml`

This one deploys. Read it end to end first. Beyond the angle brackets you need the
repository secrets and the one-time server setup listed in its runbook comment — the
workflow deliberately does not create the runtime `.env`, TLS certs, or shared networks.

If your topology isn't "container image → compose stack over SSH", keep the structure —
build → push → **pull by digest** → wait for healthy → verify from outside — and swap
the mechanism underneath it.

## Activating `release-native.yml`

Only fits a stack that compiles to a standalone native binary (Go, Rust, a bundled Node
CLI, …). Fill the `<ANGLE-BRACKET>` spots — target triples, artifact names, binary paths —
and each platform job's native-build block (marked the same way as `ci.yml`'s runtime-setup
block, but distinctly worded so `init.sh --stack <profile>` never auto-fills it; this one
you fill by hand). Drop whichever platform job your stack doesn't target.

Cut a release with `git tag v1.2.3 && git push origin v1.2.3`; a hyphen in the tag
(`v1.2.3-rc1`) marks it prerelease automatically. No repository secrets beyond the default
`GITHUB_TOKEN` are required. If you need an SBOM attached to the release, add a job that
generates one with your ecosystem's tool and uploads it the same way as a release archive —
none ships here since the tooling is stack-specific.
