Generated from `config/workflow.tsv`; edit the data, then run `scripts/render-shared.sh`.

| Topology | State | Labels | Issue status |
|---|---|---|---|
| step-strict | executing | agent:codex,needs-execution | open |
| step-strict | reviewing | agent:opencode,needs-review | open |
| step-strict | escalated | needs-human | open |
| step-strict | approved | - | closed |
| work-standard | executing | agent:codex,needs-execution | open |
| work-standard | reviewing | agent:opencode,needs-review | open |
| work-standard | escalated | needs-human | open |
| work-standard | closing | agent:claude,needs-closing | open |
| work-standard | closed | - | closed |
| tracker | open | plan | open |
| tracker | closing | plan,agent:claude,needs-closing | open |
| tracker | closed | plan | closed |

| Topology | Event | Role | From | To | Requires |
|---|---|---|---|---|---|
| step-strict | submit | executor | executing | reviewing | head,head≠last-bounced-head |
| step-strict | bounce | reviewer | reviewing | executing | findings,bounces<limit |
| step-strict | bounce | reviewer | reviewing | escalated | findings,bounces=limit |
| step-strict | ask | executor | executing | escalated | question |
| step-strict | ask | reviewer | reviewing | escalated | question |
| step-strict | resume | approver | escalated | executing | note,return=executing |
| step-strict | resume | approver | escalated | reviewing | note,return=reviewing |
| step-strict | approve | reviewer | reviewing | approved | head=submitted |
| work-standard | submit | executor | executing | reviewing | head,head≠last-bounced-head |
| work-standard | bounce | reviewer | reviewing | executing | findings,bounces<limit |
| work-standard | bounce | reviewer | reviewing | escalated | findings,bounces=limit |
| work-standard | ask | executor | executing | escalated | question |
| work-standard | ask | reviewer | reviewing | escalated | question |
| work-standard | resume | approver | escalated | executing | note,return=executing |
| work-standard | resume | approver | escalated | reviewing | note,return=reviewing |
| work-standard | approve | reviewer | reviewing | closing | head=submitted |
| work-standard | close | approver | closing | closed | lifecycle-ready |
| tracker | notify | reviewer | open | closing | all-steps-approved |
| tracker | close | approver | closing | closed | lifecycle-ready |
