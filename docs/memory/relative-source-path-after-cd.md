---
id: relative-source-path-after-cd
type: trap
status: active
---
A sourced library that builds paths from `${BASH_SOURCE[0]}` at call time breaks once the
caller changes directory, because `BASH_SOURCE` is relative when the caller sourced the file
by a relative path.

**Why:** e-1 of flow-ergonomics had `journal_jq` pass `jq -L "$(dirname "${BASH_SOURCE[0]}")"`.
The controller sources the library, then `cd`s into the plan worktree, so jq failed with
`module not found: journal-marker` (exit 5). Resolving at call time did not help, since
`BASH_SOURCE` is still relative then. The tool shell here is zsh, where `BASH_SOURCE` is
empty, so a by-hand check in that shell proved nothing.

**How to apply:** resolve the library directory once, when the file is sourced
(`DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)`), and use that variable afterwards.
Test with `cd /` after sourcing, and run checks under `bash -c`.
