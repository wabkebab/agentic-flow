---
id: timeout-exit-not-a-signal
type: trap
status: active
---
A command killed by a watchdog's TERM does not always exit with a signal status. GNU make
on Linux handles TERM, cleans up, and exits 2. A check that counts a timeout only from 137
or 143 records a real timeout as an ordinary failure.

**Why:** `verify-step` mapped only 137 and 143 to 124 when its watchdog had fired. On macOS
the `make` under test died by signal (143), so the timeout fixture always passed locally,
under load too. On the Linux CI runner the same fixture exited 2, and PR #174's
exported `make ship-gate` failed with `timeout not recorded` (run 44726328649). 146670e
fixed it: once the watchdog marker exists, any nonzero exit is a timeout, and only a
success is kept.

**How to apply:** decide "timed out" from the watchdog's own record (a marker file it
writes before it signals), not from the child's exit status. Keep a success that races the
deadline as a success. A timeout test that passes on macOS proves nothing about Linux
`make`; let CI's Linux run decide.
