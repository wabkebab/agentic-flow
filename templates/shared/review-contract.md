Use one finding scale for Security reviews, step reviews, and ordinary diffs:

- **High** (`sev:high`) — common path is incorrect or a serious regression has no safe workaround. Blocks merge.
- **Medium** (`sev:med`) — real defect under a bounded condition, or required failure-path coverage is missing. Requires a fix or explicit accepted-risk disposition.
- **Low** (`sev:low`) — concrete, limited correctness or operability risk worth fixing before closure. Does not block.
- **Nit** (`sev:nit`) — wording, clarity, or tiny hygiene issue. Does not block.

Accepted/by-design is a disposition, not a severity. Record the acceptance against the finding and move material accepted risk to `docs/accepted_risks.md`.

The only verdicts are `approved`, `changes requested`, and `pending`. Use `approved` when no required findings remain and evidence covers the brief; use `changes requested` when code or tests need a fix; use `pending` when missing scope or evidence prevents a decision. Structured review comments encode `changes requested` as `status=changes-requested`.
