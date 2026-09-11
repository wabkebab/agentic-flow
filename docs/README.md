# docs/ — index & conventions

This directory holds the project's design, security, and product documents and tracks each
through its lifecycle. The full standard is in [`../METHODOLOGY.md`](../METHODOLOGY.md);
this is the quick reference.

## Layout

```
docs/
├── README.md            ← this file
├── accepted_risks.md    ← register of reviewed-and-accepted risks / declined features
├── MEMORY.md            ← one-line index of durable traps (not exported)
├── memory/              ← one fact per file; read via the index above
├── backlog/             ← identified but not started
├── inprogress/          ← active (being written, executed, or reviewed)
├── done/                ← completed Feature / Product analyses
│   └── security/        ← completed Security reviews
└── templates/           ← copy these out; don't edit in place
    ├── security-review.md     (analysis + inlined implementation brief)
    ├── feature-analysis.md    (analysis + inlined implementation brief)
    ├── product-analysis.md    (decision record; no implementation brief)
    └── accepted-risk-entry.md (one block for accepted_risks.md)
```

## Document types

| Type | Template | Closes to |
|------|----------|-----------|
| **Security** | `templates/security-review.md` | `done/security/` |
| **Feature** | `templates/feature-analysis.md` | `done/` |
| **Product Analysis** | `templates/product-analysis.md` | `done/` |

## Naming

- `security-<topic>.md`, `feature-<topic>.md`, `product-<topic>.md` — kebab-case.
- No dates or model names in filenames — those go in the TRIAGE header.
- One topic per file.

## Lifecycle (quick version)

`backlog/` → `inprogress/` (plan → execute → review) → `done/` (or `done/security/`).

Those four are the **only** stages `scripts/docs-index.sh` accepts. A `.md` file anywhere
else under `docs/` — including `docs/` itself — fails the index build (and therefore
`make check`) rather than being listed under an invented stage. Non-Markdown files and
`README.md` / `accepted_risks.md` / `templates/` and the memory tree are skipped entirely.

A doc leaves `inprogress/` when its implementation steps are all shipped, independently
reviewed, and verified. The reviewer closes each step issue on approval, so closed steps
accumulate while the tracking issue stays open at `agent:claude + needs-closing`; close the
plan in one pass only after all steps qualify, CI evidence is recorded, and
`scripts/lifecycle-status.sh --check --verify-evidence` passes — then close the tracking
issue. If the user accepts the risk / declines the feature, add an entry to
`accepted_risks.md` and link it before moving the doc.

## memory/ — durable traps, indexed

`docs/memory/` holds one fact per file; `docs/MEMORY.md` is a one-line-per-entry index. The
split is the point: the index is cheap enough to read every session, so "is there anything
about X?" never means loading the corpus. Read an entry only when its index line looks
relevant.

The index is **not** shipped by `config/payload.tsv` — only the empty `docs/memory/` tree is.
An adopted project's memories are its own, and an upstream index would overwrite them on
`agentic-flow upgrade --force`.

Index line — `| Entry | Type | Description |`, where `Type` is `trap` or `fact` and the
description is the trap itself, not a title. A description that does not let a reader decide
relevance without opening the file is a broken index line.

```markdown
| `docs-index-stage-allowlist` | trap | `docs-index.sh:37` rejects any `.md` under `docs/`
outside the four declared stages, exit 2 — extend the skip list at `:30` first. |
```

Entry — frontmatter `id`, `type`, `status` (`active` or `superseded`, plus `superseded-by:`
when superseded), then the fact, then **Why** and **How to apply**. Cite `path:line` where one
exists; `make check` asserts those still resolve, which is what stops an entry rotting into a
confident lie.

What does **not** belong here: anything `docs/accepted_risks.md` already answers (a reviewed
decision *not* to act), and anything a single `grep` recovers. A memory earns its index line
by being expensive or dangerous to re-derive.

When an entry keeps proving itself, promote it — a `CLAUDE.md` Gotchas bullet if agents must
read it every turn, or a `make check` assertion if a machine can. Promotion is the goal;
an index that only grows is a cost centre.

## Current docs

This table is **generated** — run `scripts/docs-index.sh` to refresh it from each doc's
TRIAGE header. Don't edit between the markers by hand.

<!-- BEGIN: generated index — do not edit by hand (scripts/docs-index.sh) -->
| Doc | Type | Status | Stage |
|-----|------|--------|-------|
| feature-ci-as-authority | Feature | ✅ Done | done |
| feature-export-banner-leak | Feature | ✅ Done | done |
| feature-harness-integrity-and-lifecycle | Feature | ✅ Done | done |
| feature-init-and-template-split | Feature | ✅ Done | done |
| feature-opencode-reviewer-role | Feature | ✅ Done | done |
| feature-upgrade-surface | Feature | ✅ Done | done |
| context_optimization | Feature | 🚧 In progress | inprogress |
| feature-adaptative-assurance-opus | Feature | 🟦 Proposal | inprogress |
| feature-progressive-assurance-profiles | Feature | 🟦 Proposal | inprogress |
| harness-optimization | Feature | 🟦 Proposal | inprogress |
<!-- END: generated index -->
