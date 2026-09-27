---
description: Review a branch, PR, staged diff, or specific file changes against agentic-flow's engineering standards.
agent: code-reviewer
model: opencode-go/glm-5.2
---

Review the requested changes against this project's engineering standards
(AGENTS.md §"Engineering standards") and stack-specific rules.

$ARGUMENTS

Resolve the argument as follows:
- Empty → review the uncommitted working-tree diff vs the current branch's
  upstream (`git diff` + `git diff --staged`); if clean, fall back to the diff
  of the current branch vs its merge-base with its base branch.
- A PR number like `#42` or `42` → fetch that PR's diff
  (`gh pr diff <num>` or `gh pr view <num> --json files`) and review it.
- A branch name → diff that branch vs its merge-base with the current default
  branch.
- A file path (or space-separated list) → review the current uncommitted
  changes to those files (`git diff -- <files>`); if unchanged, review the
  last commit touching them.

Invoke `.agents/skills/review-execution/SKILL.md` through the `code-reviewer` agent for the resolved scope. That skill owns verification, finding severity, verdict terms, and structured issue comments. Keep the review read-only on the work under review.
