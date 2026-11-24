---
id: library-sources-its-dependencies
type: trap
status: active
---
A library in `scripts/lib/` that calls a function from another library must source that library
itself. Do not rely on the caller having sourced it already.

**Why:** e-2 of flow-ergonomics made `andon.sh` count holds with `journal_jq`, but `andon.sh`
only sourced `ledger.sh` and `journal-comment.sh`. Every full-suite run sourced `journal.sh`
earlier, so it passed. The `controller/ledger` shard sources `andon.sh` on its own and failed
with `journal_jq: command not found`. It first showed up in the ship gate. 69d37bc made
`andon.sh` source `journal.sh`, as `handoff.sh` already does.

**How to apply:** when a library starts calling a function it does not define, add the
`. "$(dirname "${BASH_SOURCE[0]}")/<lib>.sh"` line in the same commit. A shard or `S=` tag run
alone is the test that catches a missing source. Related: [[relative-source-path-after-cd]].
