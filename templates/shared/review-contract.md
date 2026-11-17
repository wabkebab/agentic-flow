Use one finding scale for Security reviews, step reviews, and ordinary diffs:

- **High** (`sev:high`) — common path is incorrect or a serious regression has no safe workaround. Blocks merge.
- **Medium** (`sev:med`) — real defect under a bounded condition, or required failure-path coverage is missing. Requires a fix or explicit accepted-risk disposition.
- **Low** (`sev:low`) — concrete, limited correctness or operability risk worth fixing before closure. Does not block.
- **Nit** (`sev:nit`) — wording, clarity, or tiny hygiene issue. Does not block.

Accepted/by-design is a disposition. Record acceptance and move material risk to `docs/accepted_risks.md`.

Verdicts: `approved` when no required findings remain and evidence covers the brief; `changes requested` when fixes are needed; `pending` when missing scope or evidence prevents a decision. Structured review comments encode `changes requested` as `status=changes-requested`.

Controller reviewers return the station result JSON and never call `handoff`; the controller
verifies and journals the verdict. Interactively, use `packet <issue> --station reviewer`,
`verify-step <head> --doc <doc> --step <id>`,
and `handoff <issue> approve --as reviewer --head <sha40> --body-file <review-file>`
or `handoff <issue> bounce --as reviewer --body-file <findings-file>`; states live
in `METHODOLOGY.md` §6. Pending leaves state unchanged. Never edit accepted verdicts.

Reuse evidence only when `sha` and `tree` match the reviewed head and
`verifier.implementation_sha256` matches the current `verify-step.sh`; otherwise regenerate.
Inspect signature-source provenance and red-first output. Exit 0 is green; nonzero
with an assertion-signature match is red, except timeout 124 and interrupts 130/143,
which are invalid. Missing or mismatched signatures are invalid and prevent approval.
Prefer raw runners: make masks recipe failures as exit 2; Cargo assertions exit 101.

Handoff writes `agentic-flow-review: status=approved|changes-requested; step=<id>;
head=<sha40>; role=reviewer` compatibility markers. The journal selects accepted evidence;
edited accepted approval blocks verification. The API author proves the account;
`role=reviewer` attests the role, not independence in single-operator mode.
Final-head approval belongs on the document's Tracking issue (§2):
`agentic-flow-review: status=approved; pr=<number>; head=<sha40>;
run=https://github.com/<owner>/<repo>/actions/runs/<id>; attempt=<positive-integer>;
role=reviewer`. A new head or run attempt requires new approval.
