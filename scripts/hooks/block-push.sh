#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Enforces METHODOLOGY.md §7 "never push — the human
# controls all pushes and merges" by blocking `git push` (also via the git-claude /
# git-codex wrappers, and with intervening -C/-c args) and `gh pr merge`.
# Reads the tool-call JSON on stdin.
# Exit 2 = block the call and show stderr to the agent; exit 0 = allow.
set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "Warning: jq not found; cannot inspect Bash command for blocked push patterns." >&2
  exit 0
fi

cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null) || cmd=""
[ -n "$cmd" ] || exit 0

# Match: (git|git-claude|git-codex) [-C <path>|-c <k=v>]... push
if printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|(])(git|git-claude|git-codex)([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+push([[:space:]]|$)'; then
  echo "Blocked: 'git push' is not allowed — the human controls all pushes and merges (METHODOLOGY.md §7)." >&2
  exit 2
fi

if printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|(])gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'; then
  echo "Blocked: 'gh pr merge' is not allowed — the human merges PRs (METHODOLOGY.md §1)." >&2
  exit 2
fi

exit 0
