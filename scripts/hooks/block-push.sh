#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Enforces METHODOLOGY.md §7 "never push — the human
# controls all pushes and merges" by blocking `git push` (also via the git-claude /
# git-codex wrappers, and with intervening -C/-c args) and `gh pr merge`.
# Reads the tool-call JSON on stdin.
# Exit 2 = block the call and show stderr to the agent; exit 0 = allow.
set -uo pipefail

# jq is the documented requirement and the clean path. Without it the guard used to exit 0,
# which is a silent allow (only exit 2 blocks) — so on a jq-less machine every push guard
# quietly disappeared behind a warning nobody reads. Degrade to scanning the raw payload
# instead: the command text is still in there, just JSON-quoted, so the patterns below also
# tolerate a leading/trailing `"`. Over-matching in this mode is the intended trade; a guard
# that vanishes when a tool is missing is worse than one that occasionally over-blocks.
raw=$(cat 2>/dev/null || true)
if command -v jq >/dev/null 2>&1; then
  cmd=$(printf '%s' "$raw" | jq -r '.tool_input.command // ""' 2>/dev/null) || cmd=""
else
  cmd=$raw
fi
[ -n "$cmd" ] || exit 0

# Match: (git|git-claude|git-codex) [-C <path>|-c <k=v>]... push
if printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|("])(git|git-claude|git-codex)([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+push([[:space:]"]|$)'; then
  echo "Blocked: 'git push' is not allowed — the human controls all pushes and merges (METHODOLOGY.md §7)." >&2
  exit 2
fi

if printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|("])gh[[:space:]]+pr[[:space:]]+merge([[:space:]"]|$)'; then
  echo "Blocked: 'gh pr merge' is not allowed — the human merges PRs (METHODOLOGY.md §1)." >&2
  exit 2
fi

exit 0
