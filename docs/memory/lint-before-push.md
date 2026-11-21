---
id: lint-before-push
type: trap
status: active
---
Neither `make check` nor `make ship-gate` runs everything that CI's `make test` runs. CI also
runs shellcheck (`scripts/shell-inventory.sh --lint`) and the source-layout fixture copy budget
(`self-test.sh` counts copies only when `scripts/export.sh` exists, so the exported gate skips
it).

**Why:** PR #185 passed the ship gate and then failed CI twice. First the copy count was 194
against a limit of 190. Then shellcheck raised SC2100 on `reason=plan-effect-pending` in
`controller.sh`, which `main` had without a warning. Each failure cost a push and a 30-minute
App run.

**How to apply:** before the first push of a plan, run `make test` in the source checkout, or at
least `scripts/shell-inventory.sh --lint`, and expect the copy budget to change if the plan adds
fixtures. Roadmap R-25 tracks folding both into the ship gate.
