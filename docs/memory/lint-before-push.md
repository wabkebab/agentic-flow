---
id: lint-before-push
type: trap
status: active
---
`make ship-gate` checks the fixture copy budget in a fresh export and runs
`scripts/shell-inventory.sh --lint` in the scaffold. CI's `make test` checks the source-layout
fixture copy budget and runs the same lint.

**Why:** PR #185 passed the ship gate and then failed CI twice. First the copy count was 194
against a limit of 190. Then shellcheck raised SC2100 on `reason=plan-effect-pending` in
`controller.sh`, which `main` had without a warning. Each failure cost a push and a 30-minute
App run.

**How to apply:** run `make test` in the source checkout at the end of a plan to catch copy
growth in source-only fixtures before CI.
