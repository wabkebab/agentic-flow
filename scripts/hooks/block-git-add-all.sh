#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Enforces METHODOLOGY.md §7 "stage files by name" by
# blocking `git add -A` / `git add .` / `git add --all` / `git add :/` (also for the
# git-claude / git-codex wrappers). Reads the tool-call JSON on stdin.
# Exit 2 = block the call and show stderr to the agent; exit 0 = allow.
set -uo pipefail

cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null) || cmd=""
[ -n "$cmd" ] || exit 0

# Match: (git|git-claude|git-codex) add  ... <-A | --all | . | :/> as a standalone arg.
if printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|(])(git|git-claude|git-codex)[[:space:]]+add[[:space:]]+([^|;&]*[[:space:]])?(-A|--all|\.|:/)([[:space:]]|$)'; then
  echo "Blocked: 'git add -A' / 'git add .' / 'git add --all' is not allowed (METHODOLOGY.md §7)." >&2
  echo "Stage specific files by name instead, e.g.:  git-claude add path/to/file" >&2
  exit 2
fi
exit 0
