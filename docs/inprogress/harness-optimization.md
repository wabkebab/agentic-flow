<!-- TRIAGE (first pass · 2026-09-11) -->
> **Type:** Feature · **Status:** 🟦 Proposal
> Audit of the harness's correctness gates, duplicated contracts, and token/ceremony
> overhead, with a recommended fix order. Not an approved implementation brief.

# Harness optimization review

Reviewed `main` at `87d6ae9` on 2026-09-11. This is an audit and improvement proposal, not an approved implementation brief.

## Assessment

The harness has a useful structure, but several safeguards provide more confidence than their implementation supports. Prioritize correctness first, then reduce duplicated instructions and repeated validation.

The objectives are to make the harness more efficient and improve its quality.

## Most important findings

| Priority | Finding | Evidence and recommended change |
|---|---|---|
| High | Lifecycle checks accept rejected or unverified work. | A fixture containing “not approved” and “not approved by Codex” returned `READY`. Adding `--check --verify-evidence` reported `UNVERIFIED` but still exited 0. Use explicit status values and make strict verification fail on unresolved evidence. Location: `scripts/lifecycle-status.sh:134`. |
| High | CI evidence is not bound to the work being closed. | Verification checks only a run’s `conclusion`. A successful run from another repository, workflow, or commit can satisfy it. Validate the expected repository, workflow, and reviewed commit. Location: `scripts/lifecycle-status.sh:100`. |
| High | Issue identities can collide. | Reproduced: searching for `step-1` selects `step-10` because matching uses `contains()`. The spec validator also accepts an implicit `step-1` alongside an explicit `step-1`. This can update the wrong issue or create duplicate identities. Normalize IDs before validation and match complete stamps exactly. Location: `scripts/plan-to-issues.sh:122`. |
| High | Secret scanning can inspect the wrong repository. | A simulated `git -C <target> commit` passed while the target contained a staged synthetic secret. Running the scanner inside that target correctly blocked it. Resolve the commit’s actual repository/index, or enforce scanning at the Git commit boundary. Location: `scripts/hooks/scan-secrets.sh:48`. |
| High | Push protection misses ordinary command forms. | Reproduced: `git push` blocks, but `git push;`, `git -C "/tmp/a b" push`, and `git-opencode push` pass. The regex does not handle shell syntax reliably. Treat these hooks as guardrails and strengthen command normalization and platform permissions. Location: `scripts/hooks/block-push.sh:20`. |
| Medium | Reapplying a plan can corrupt workflow labels. | Existing steps receive the spec’s original `agent:codex,needs-execution` labels without removing their current reviewer labels. Separate initial labels from mutable workflow state. Location: `scripts/plan-to-issues.sh:255`. |
| Medium | Claude-only exports fail their own checks. | The export removes Codex adapters, but contract tests still require adapter parity; the exported contract test failed with “plan-to-issues adapter copies diverged.” Doctor also unconditionally requires Codex files. Make validation consume the same scope exclusions as export. Location: `scripts/doctor.sh:153`. |
| Medium | The review command contradicts the reviewer. | `/review` requests `block/fix/nit` and `BLOCK/LGTM`; the agent and skill require High/Medium/Low/Nit and approved/changes requested/pending. Make the command a thin entry point to one review contract. Location: `.opencode/command/review.md:28`. |
| Medium | Some tests can pass for the wrong reason. | `must_block()` accepts any nonzero exit, including a crashing hook; it should require exit 2. Separately, `make build` masks export failures with its final successful `echo`—reproduced using an export stub that exits 1. Locations: `scripts/self-test.sh:183`, `Makefile:28`. |

## Duplications, overlaps, and inactive code

- The Claude and Codex copies of `plan-to-issues` and `create-tags` are currently byte-identical: **877 words duplicated**. Maintain one source and generate the adapters. This saves maintenance immediately; it saves prompt tokens only where both copies would otherwise be loaded.
- The reviewer agent repeats standards, verification, severity, and handoff instructions from the review skill. This duplication has already produced the conflicting `/review` contract above.
- Root and template contracts intentionally overlap, but the sync checker compares only `##` headings. It cannot detect contradictory rules under matching headings. Generate shared contract regions while preserving project-specific sections.
- Manifest `merge-policy` values are validated but not used to select per-file application behavior. This is inactive configuration semantics rather than a large dead subsystem. Either implement the distinction or remove it.
- `scripts/agentic-flow` is omitted from both syntax and ShellCheck globs because it lacks `.sh`. Include executable scripts explicitly. Direct ShellCheck currently reports cross-file variable-use warnings; those warnings alone do not prove dead code.
- The two assurance proposals explicitly compete. Their historical measurements also describe issues already fixed in today’s tree. Reconcile them into one current proposal before implementation:
  - `docs/inprogress/feature-progressive-assurance-profiles.md`
  - `docs/inprogress/feature-adaptative-assurance-opus.md`

## Reducing token consumption

The strongest opportunities are reducing repeated context and repeated work.

1. **Measure actual role bundles.** Current sizes are 1,059 words for `AGENTS.md`, 1,412 for `CLAUDE.md`, 971 for the review skill, and another 828 for the reviewer agent. The 5,872-word methodology is already routed rather than required wholesale. Measure loaded files, tool output, repeated reads, and handoff count—not total repository prose.

2. **Keep entry-point instructions short.** Retain authority limits, essential engineering rules, verification requirements, and routing. Move examples, historical explanations, and detailed handoff procedures into task-specific references. Preserve concise safety rules even when a hook exists: the reproduced bypasses show why those rules still matter.

3. **Use one canonical review contract.** The agent and `/review` command should supply scope and runtime configuration, then reference that contract. This reduces both tokens and contradictory behavior.

4. **Make routine checks cheaper.** `--fast` currently runs every test group except export, including upgrade tests. Adoption fixtures also repeatedly run the harness suite. Separate inexpensive structural checks from behavioral regression suites, reuse immutable fixtures, and construct minimal test `PATH`s instead of scanning and symlinking every installed executable. Location: `scripts/self-test.sh:208`.

5. **Reduce ceremony according to risk.** Small, reversible changes should have a shorter brief and one review boundary. Multi-step or security-sensitive work should retain decomposition and independent review. Keep workflow choice separate from permission to push, merge, or publish.

6. **Record structured handoff evidence.** Store the reviewed range, verdict, verification, and CI identity in a stable schema. That lets the next role consume evidence without reconstructing state from prose and labels.

## Improving review safety

Replace “revert the change, run the test, restore” with an isolated temporary checkout. The current instruction conflicts with the reviewer’s read-only contract and risks disturbing ongoing work.

## Verification

- `make check` passed.
- `make test` passed.
- `make build` passed.
- `scripts/doctor.sh --check --scope repo --skip-make-check` passed with two warnings: no scaffold version stamp and a generic stack profile.
- Targeted probes reproduced the lifecycle, issue identity, cross-repository secret-scanning, push-guard, Claude-only export, and build failure-propagation defects described above.
- Direct `shellcheck scripts/agentic-flow` exited 1 with cross-file variable-use warnings; these are separate from the passing `make test` result, whose glob omits that executable.
- The audit did not change repository files or mutate GitHub issues. Probes used temporary local fixtures; no push or commit operation was executed by the hook simulations.

Passing baseline checks alongside these reproduced defects indicates that improving what the tests prove matters more than adding more checks.

## Recommended order

1. Fix false-green gates and issue identity handling.
2. Consolidate contracts and validators.
3. Measure and reduce routine costs.
4. Introduce one risk-based workflow design.
