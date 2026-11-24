# CI/CD pipeline shape

The reference structure, extracted from a working two-workflow setup. Stack-agnostic: the
*shape* is the standard, the commands inside it come from the `Makefile`.

> With the CI scope included, adoption ships `ci.yml`, `deploy.yml`, and
> `release-native.yml` under `templates/ci/`. Activate a workflow by copying it into
> `.github/workflows/` and filling the `<ANGLE-BRACKET>` spots. See
> `templates/ci/README.md` for the activation steps.

**Three workflows, three different risk postures.**

| | `ci.yml` | `deploy.yml` | `release-native.yml` |
|---|---|---|---|
| Trigger | `pull_request` | `push` to release branches + `workflow_dispatch` | push of a `v*` tag + `workflow_dispatch` |
| Concurrency group | per PR number | per ref name | none — parallel releases of different tags are fine |
| `cancel-in-progress` | **`true`** — superseded runs are waste | **`false`** — finishing a deploy beats half-deploying | n/a |
| Permissions | `contents: read` (+ `pull-requests: read` for path filtering) | `contents: read` + only the write scope the registry push needs | `contents: write` — creating the release and uploading assets needs it |

`release-native.yml` only fits a stack that compiles to a standalone native binary (Go,
Rust, a bundled Node CLI, …); a service deployed via `deploy.yml` has nothing to attach
there and should not ship both.

### Rules for all workflows

- **Pin everything.** Third-party actions by **full commit SHA** with a `# vX.Y.Z` trailing
  comment; runners by version (`ubuntu-24.04`, never `ubuntu-latest`). A tag is mutable —
  a SHA is the only pin that resists a compromised action.
- **Enforce the pins with `scripts/check-action-pins.sh`.** Pins rot two ways and the check
  grades them differently. *Structure* — a tag pin, or a SHA with no version comment — is
  always fatal; it runs in `make check`. *Staleness* is only a warning there, because pins
  decay with the calendar rather than with edits, and failing the fast gate on a date would
  turn a repo red with no change to it (and, via the Stop hook, block agents from ending
  turns). Enforcement lives in a scheduled `--strict` run instead. `--online` resolves each
  pin against GitHub to prove it really is the version its comment claims and to report
  newer releases; `--stamp` records the re-verification date.
- **Least-privilege `permissions:` declared explicitly** at workflow level. Add a scope only
  where a step actually needs it, and comment *why* (e.g. path-filter actions call the Pulls
  API and fail with "Resource not accessible by integration" without `pull-requests: read`).
- **Steps stay thin — call `make` targets.** The Makefile is the one executable source of
  truth ([methodology](../../METHODOLOGY.md)); a CI step that inlines its own command sequence is a second source
  that will drift from what runs locally. Keep the YAML to checkout/setup/`make …`.
- **The workflow file is its own trigger.** Include `.github/workflows/<file>.yml` in every
  path filter, so editing CI re-runs everything it gates.
- **Ship the runbook with the workflow.** A trailing comment block listing one-time server
  setup and every required repository secret — the operational knowledge dies otherwise.

### `ci.yml` — job structure

```
changes ──┬─▶ app checks        (if changes.app and no reusable green result)
          ├─▶ docs checks       (if changes.docs)
          ├─▶ compose syntax    (if changes.docker)
          └─▶ <area N>          (if changes.<area>)
secrets-scan  (never filtered — always runs)
                    │
                    ▼
              ci-gate           needs: [everything], if: always()
```

1. **`changes`** outputs gate independently testable areas. The App filter runs App checks
   when any changed path falls outside its explicit bookkeeping list. The shipped list covers
   `docs/inprogress/**/*.md`, `docs/done/**/*.md`, `docs/backlog/**/*.md`,
   `docs/memory/**/*.md`, `docs/MEMORY.md`, `ROADMAP.md`, and `docs/agentic-flow-explained.html`.
   Keep payload files and App inputs outside these exclusions. The Docs job covers the
   bookkeeping paths and runs the docs-index and memory-index checks.
   When App is selected, `scripts/app-input-key.sh` hashes the tracked App entries (paths,
   modes, and object IDs) from the PR merge checkout using the same exclusions. A successful
   App job saves its run URL and attempt under that key. CI skips App only on an exact cache
   hit with a valid source run reference and reports that source in the run summary. A miss
   or a key, cache, or source-reference error runs App checks. The current head still needs
   a green CI gate and final approval.
2. **Per-area jobs** run when their change flag is true. App also requires a cache miss
   or an unusable cache result.
3. **`secrets-scan`** — scans the PR diff range (`base…head`) for **verified** leaked
   secrets. Never path-filtered: a leak can land in any file.
4. **The app job runs cheapest-first, fail-fast:** checkout → set up runtime *with dependency
   caching* → **install from the lockfile** (`npm ci`, `poetry install --sync`, …, never a
   resolving install) → audit production dependencies at a severity threshold → typecheck →
   lint → test → build. Give the build dummy CI env values so it never needs real secrets.
5. **`ci-gate`** — the single **required status check** in branch protection:

   ```yaml
   ci-gate:
     needs: [changes, secrets-scan, app, docs, compose-syntax]
     if: always()
     steps:
       - run: |
           for result in "${{ needs.secrets-scan.result }}" "${{ needs.app.result }}" "${{ needs.docs.result }}" …; do
             case "$result" in
               success|skipped) ;;
               *) echo "Upstream job ended in '$result'"; exit 1 ;;
             esac
           done
   ```

   **This job exists because path filtering and required checks conflict.** A skipped job
   never reports, so naming the per-area jobs directly as required checks would block every
   PR that legitimately skips one. The gate collapses them into one always-reporting status
   that treats `skipped` as pass and `cancelled`/`failure` as fail.

### `deploy.yml` — job structure

1. **Build & push an image**, tagged twice: a moving `latest` pointer *and* an immutable
   per-commit tag for rollback. Use registry/GHA layer caching.
2. **Deploy pulls by digest**, not by tag — the tag can be re-pointed between push and pull;
   the digest is what was actually built and tested.
3. **SSH properly:** an ssh-agent action for the key, and `known_hosts` populated from an
   `ssh-keyscan` output stored as a secret. Never `StrictHostKeyChecking=no`.
4. **Sync deploy assets through an explicit allowlist** (rsync `--include … --exclude='*'`).
   Operator-maintained state on the server — the runtime `.env`, TLS certs — must never be
   in the sync set.
5. **Wait for readiness, then verify from outside:** `up -d --wait --wait-timeout N`, then an
   external healthcheck against the public URL with bounded retries and backoff. Skip
   gracefully (don't fail) when the URL secret isn't configured.
6. **Gate optional stacks** (monitoring, workers) on their own path filter *or* a
   `workflow_dispatch` input, so routine app deploys don't restart them.

### `release-native.yml` — job structure

```
create-release ──┬─▶ build-linux    (matrix: target triples)
                  ├─▶ build-macos    (matrix: target triples)
                  └─▶ build-windows
```

1. **`create-release`** resolves the tag once — from the pushed ref, or from a
   `workflow_dispatch` input so a failed platform can be re-run without re-tagging — and
   creates the (draft-free) GitHub release every build job then uploads to. A hyphen in the
   tag (`v1.2.3-rc1`) marks it prerelease automatically via SemVer's own convention, so
   there is nothing separate to keep in sync.
2. **One job per OS**, matrixed over target triples within a job where cross-compilation
   supports it (e.g. Rust). Packaging genuinely differs per OS — archive format, binary
   extension, shell — which is why these are three explicit jobs, not one OS-matrixed job
   branching three ways internally.
3. **Each platform job**: checkout → native build (stack-specific, the fill-in block) →
   smoke-test the binary exists and is executable → package into an archive → upload it to
   the release created in step 1.
4. **No `ci-gate`-style aggregation job.** Unlike `ci.yml`, nothing here is a required
   status check gating a merge — a failed platform build fails its own job, visibly, and
   can be re-run individually via `workflow_dispatch` without re-running the others.

### Wiring it to the harness

CI green must mean the same thing as local green: the CI gate is `make check && make test`
(see the project’s Stack profile in `CLAUDE.md`), plus `scripts/docs-index.sh --check` where practical. If a
CI step needs a command that isn't a Make target, that's a signal the Makefile is incomplete
— add the target and call it, rather than growing logic in YAML.
