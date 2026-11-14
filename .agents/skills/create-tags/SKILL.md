---
name: create-tags
description: Create the workflow labels on the current GitHub repo with their standard colors. Use on adoption or when METHODOLOGY.md §6 requires missing labels.
---

# create-tags

Workflow states live in `METHODOLOGY.md` §6; run `scripts/create-tags.sh` to provision
the labels declared in `config/workflow.tsv` with their standard colors.

The deterministic GitHub calls live in `scripts/create-tags.sh`; this skill is only the
"when to run it" judgment.

## When to use
- **Adoption** — `scripts/init.sh` calls `scripts/create-tags.sh` for you at the end of
  scaffold setup, best-effort (skipped if `gh` isn't authenticated or there's no GitHub
  remote yet). Re-run it by hand once the repo exists on GitHub.
- **`plan-to-issues`** — checks whether any of the seven labels already exist before invoking
  this skill; if none exist, it runs `scripts/create-tags.sh`, if some already exist it
  assumes the repo was set up before and does nothing further. Don't reinvoke on every plan.

## Procedure
1. Confirm `gh auth status` is logged in and `gh repo view` resolves a repo.
2. Run `scripts/create-tags.sh` (optionally `--repo <owner/repo>` outside the current repo).
3. `gh label create` failing because a label already exists is expected, not an error — the
   script treats it that way.
