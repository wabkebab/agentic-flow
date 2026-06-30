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
<!-- Keep this list current: one line per active doc, newest first. -->

_None yet._
