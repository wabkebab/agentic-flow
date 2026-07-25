---
name: review-execution
description: Independently review an executed branch, pull request, commit range, or implementation step against its approved Feature/Security implementation brief and the agentic-flow engineering contract. Use when a subagent must perform post-execution code review, validate Definition of Done and regression coverage, identify actionable defects with precise file:line evidence, or issue an approved/changes-requested/pending verdict before human merge.
---

# Review execution

Act as the independent reviewer in the plan → execute → review loop. Review and report;
do not implement fixes unless the user separately asks for them.

## Establish the review contract

1. Read this skill, the approved brief, the diff/range, changed code and affected callers,
   actual verification output, and `AGENTS.md` → Engineering standards. Read `CLAUDE.md`
   Stack profile/Gotchas or `METHODOLOGY.md` sections only when the diff or brief points
   there.
2. Locate and read the approved implementation brief under `docs/inprogress/`. Treat the
   document as design intent and its ordered steps, regression tests, Definition of Done,
   and verification commands as the acceptance contract.
3. Identify the exact base and head being reviewed. Prefer an explicit range from the user,
   brief, issue, or PR. Otherwise inspect the current branch and derive the merge base
   without changing branches.
4. Inspect the working tree separately from the committed range. State whether uncommitted
   changes were included or excluded. Never attribute unrelated pre-existing changes to the
   execution branch.
5. If the brief, base, or head remains ambiguous enough to change the verdict, stop with a
   pending verdict and name the missing input.

## Review the implementation

Review the complete range and each step commit. Check behavior against the brief, trace
changed code into callers and downstream consumers, and apply `AGENTS.md` Engineering
standards rather than restating them here. Pay special attention to failure paths,
migrations, persisted data, public APIs, configuration compatibility, and whether tests
reproduce the old failure with observable behavior.

Trace changed code into its callers and downstream consumers. Do not review only the diff
when the defect depends on surrounding invariants. Look for duplicated contract files or
generated/exported copies called out in project gotchas.

Do not report formatting, naming taste, or speculative refactors unless they cause a concrete
correctness, security, operability, or maintenance failure. A finding must be introduced by
the reviewed change, actionable, and supported by a reproducible path or direct code
evidence.

## Verify with evidence

Run the brief's exact per-step verification where practical. At minimum, inspect the tests
and run the project's relevant `make test-one F=...` and `make check`; run `make test` for
the completed brief when the environment supports it.

Record the commands and outcomes. Never describe a skipped, unavailable, or stale CI result
as passing. A tool/environment failure may make the verdict pending, but it is not itself a
code finding unless the branch caused it.

## Report findings

Lead with findings, ordered by severity:

- **High** — common path is incorrect or a serious regression has no safe workaround.
- **Medium** — real defect under a bounded condition, or required failure-path coverage is
  missing in a way that can hide one.
- **Low** — concrete, limited correctness or operability risk worth fixing before closure.
- **Nit** — wording, clarity, or tiny hygiene issue that does not block closure.

High blocks merge. Medium requires a fix or explicit accepted-risk disposition. Low and Nit
do not block closure unless the brief makes them mandatory. Accepted/by-design is a
disposition, not a severity.

For every finding include:

1. a short imperative title with severity;
2. the tightest changed `file:line` location that demonstrates the problem;
3. the triggering inputs or state;
4. the mechanism and user/security impact;
5. the minimal required change and regression evidence.

Do not dilute the report with compliments or non-actionable observations. When there are no
findings, say so explicitly.

After findings, include:

- **Verification:** commands run, results, and anything not run.
- **Brief coverage:** each step/DoD as met, unmet, or unverified.
- **Verdict:** `approved`, `changes requested`, or `pending`.
- **Residual risks:** only concrete unverified areas or accepted-risk links; otherwise
  `none`.

Use `approved` only when no required findings remain and the brief's DoD has credible
evidence. Use `changes requested` when a finding requires code or test changes. Use `pending`
when missing scope or evidence prevents an honest decision.

## Preserve reviewer independence

Keep the review read-only by default. Do not edit code or docs, stage, commit, push, merge,
post comments, change labels, close issues, or update the implementation status without
explicit authorization. The human owns merge and deployment.
