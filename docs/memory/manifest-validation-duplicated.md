---
id: manifest-validation-duplicated
type: trap
status: active
---
The set of legal `merge-policy` values is hard-coded twice — `scripts/lib/payload-apply.sh:45`
and `scripts/doctor.sh:191` — and nothing asserts the two agree.

**Why:** export/upgrade validate through `payload-apply.sh`; `doctor.sh` validates
independently when it diagnoses an adoption. A value one accepts and the other rejects makes
`agentic-flow upgrade` succeed and `doctor.sh --check` fail on the same manifest.

**How to apply:** adding or renaming a policy means editing both. `make check` will not catch a
mismatch: `doctor.sh` only sees the live manifest inside the `export` self-test group, and that
group is excluded from `--fast` (`scripts/self-test.sh:220`). Only `make test` catches it.
