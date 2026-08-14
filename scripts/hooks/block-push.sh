#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Enforces METHODOLOGY.md §7 "never push — the human
# controls all pushes and merges" by blocking `git push` (also via the git-claude /
# git-codex wrappers, and with intervening -C/-c args) and `gh pr merge`.
# Reads the tool-call JSON on stdin.
# Exit 2 = block the call and show stderr to the agent; exit 0 = allow.
set -uo pipefail

# jq is the documented requirement and the clean path. Without it the guard used to exit 0,
# which is a silent allow (only exit 2 blocks). Degrade to scanning the raw payload instead.
#
# The two modes need different delimiters, and conflating them is a live false positive: in
# the raw payload the command is JSON-quoted, so a double quote has to count as a boundary —
# in the extracted command it does not, and treating it as one blocks a command that merely
# mentions the string, e.g. rg for it in a doc. Keep the loose delimiters to the degraded path.
raw=$(cat 2>/dev/null || true)
if command -v jq >/dev/null 2>&1; then
  cmd=$(printf '%s' "$raw" | jq -r '.tool_input.command // ""' 2>/dev/null) || cmd=""
  LEAD='(^|[[:space:];&|(])'
  TAIL='([[:space:]]|$)'
else
  cmd=$raw
  LEAD='(^|[[:space:];&|("])'
  TAIL='([[:space:]"]|$)'
fi
[ -n "$cmd" ] || exit 0

# Match: (git|git-claude|git-codex) [-C <path>|-c <k=v>]... push
if printf '%s' "$cmd" | grep -Eq "$LEAD"'(git|git-claude|git-codex)([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|--?[A-Za-z][-A-Za-z0-9]*(=[^[:space:]]*)?))*[[:space:]]+push'"$TAIL"; then
  echo "Blocked: 'git push' is not allowed — the human controls all pushes and merges (METHODOLOGY.md §7)." >&2
  exit 2
fi

if printf '%s' "$cmd" | grep -Eq "$LEAD"'gh[[:space:]]+pr[[:space:]]+merge'"$TAIL"; then
  echo "Blocked: 'gh pr merge' is not allowed — the human merges PRs (METHODOLOGY.md §1)." >&2
  exit 2
fi

exit 0
