---
name: create-tags
description: Create the six agentic-flow workflow labels (agent:claude, agent:codex, agent:opencode, needs-review, needs-execution, needs-closing) on the current GitHub repo with their standard colors. Use on adoption, or whenever the label state machine in METHODOLOGY.md §6 needs these labels and they don't already exist.
---

# create-tags

Create the label set the step-issue state machine (`CLAUDE.md`, `METHODOLOGY.md` §6) runs
on, colored so the board reads at a glance:

| Label | Color |
|-------|-------|
| `agent:claude` | orange `#FFA500` |
| `agent:codex` | blue `#0052CC` |
| `agent:opencode` | black `#000000` |
| `needs-review` | orange `#FFA500` |
| `needs-execution` | yellow `#FBCA04` |
| `needs-closing` | purple `#5319E7` |

The deterministic GitHub calls live in `scripts/create-tags.sh`; this skill is only the
"when to run it" judgment.

## When to use
- **Adoption** — `scripts/init.sh` calls `scripts/create-tags.sh` for you at the end of
  scaffold setup, best-effort (skipped if `gh` isn't authenticated or there's no GitHub
  remote yet). Re-run it by hand once the repo exists on GitHub.
- **`plan-to-issues`** — checks whether any of the six labels already exist before invoking
  this skill; if none exist, it runs `scripts/create-tags.sh`, if some already exist it
  assumes the repo was set up before and does nothing further. Don't reinvoke on every plan.

## Procedure
1. Confirm `gh auth status` is logged in and `gh repo view` resolves a repo.
2. Run `scripts/create-tags.sh` (optionally `--repo <owner/repo>` outside the current repo).
3. `gh label create` failing because a label already exists is expected, not an error — the
   script treats it that way.
