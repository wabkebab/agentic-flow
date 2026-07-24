# docs/ — index & conventions

This directory holds the project's design, security, and product documents and tracks each
through its lifecycle. The full standard is in [`../METHODOLOGY.md`](../METHODOLOGY.md);
this is the quick reference.

## Layout

```
docs/
├── README.md            ← this file
├── accepted_risks.md    ← register of reviewed-and-accepted risks / declined features
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

A doc leaves `inprogress/` when its implementation steps are all shipped & verified, **or**
the user accepts the risk / declines the feature — in which case add an entry to
`accepted_risks.md` and link it before moving the doc.

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
| feature-opencode-reviewer-role | Feature | 🚧 In progress | inprogress |
<!-- END: generated index -->
