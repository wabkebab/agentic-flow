# CI workflow templates

Reference implementations of the pipeline shape in [`METHODOLOGY.md`](../../METHODOLOGY.md)
§10. Both ship **inert** — the scaffold exports them here, not into `.github/workflows/`,
so adopting the harness never activates CI or a deploy behind your back.

| File | Trigger | Activate by |
|------|---------|-------------|
| `ci.yml` | `pull_request` | `cp templates/ci/ci.yml .github/workflows/ci.yml` |
| `deploy.yml` | push to a release branch | `cp templates/ci/deploy.yml .github/workflows/deploy.yml` |

## Activating `ci.yml`

1. Copy it into `.github/workflows/`.
2. Fill the `<ANGLE-BRACKET>` spots: the path filters and your runtime setup block.
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

## Activating `deploy.yml`

This one deploys. Read it end to end first. Beyond the angle brackets you need the
repository secrets and the one-time server setup listed in its runbook comment — the
workflow deliberately does not create the runtime `.env`, TLS certs, or shared networks.

If your topology isn't "container image → compose stack over SSH", keep the structure —
build → push → **pull by digest** → wait for healthy → verify from outside — and swap
the mechanism underneath it.
