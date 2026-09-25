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

Run the gates that apply without mutating the tree:
`make check`, and `make test-one F=<relevant test>` if one is identifiable. Do
not let `make test` skip on a missing `shellcheck` — report it as red.

Report findings as `block` / `fix` / `nit` with `file:line` (diff-hunk line for
added code), each as Problem → why it matters → suggested direction (not
finished code). End with a one-line verdict: `BLOCK` / `fix N findings` /
`LGTM`. Follow `.opencode/agent/code-reviewer.md` for the exact structured
step verdict on the step issue and final PR-head approval on the document's
`Tracking issue`, including the Actions run `attempt=`. Post a new comment to
change a verdict, never edit an old one. Do not edit, stage, commit, or push.
