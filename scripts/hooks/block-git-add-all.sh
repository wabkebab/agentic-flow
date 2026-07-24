#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Enforces METHODOLOGY.md §7 "stage files by name" by
# blocking `git add -A` / `git add .` / `git add --all` / `git add :/` (also for the
# git-claude / git-codex wrappers). Reads the tool-call JSON on stdin.
# Exit 2 = block the call and show stderr to the agent; exit 0 = allow.
set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "Warning: jq not found; cannot inspect Bash command for blocked git add patterns." >&2
  exit 0
fi

cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null) || cmd=""
[ -n "$cmd" ] || exit 0

# Match: (git|git-claude|git-codex) [-C <path>|-c <k=v>]... add ... <-A|--all|.|:/> as a
# standalone arg. The intervening-flag part matters: `git -C <path> add -A` and
# `git -c k=v add .` are everyday usage, not evasion, and a pattern requiring `add` to
# follow `git` immediately waved them straight through. Mirrors block-push.sh.
if printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|(])(git|git-claude|git-codex)([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+add[[:space:]]+([^|;&]*[[:space:]])?(-A|--all|\.|:/)([[:space:]]|$)'; then
  echo "Blocked: 'git add -A' / 'git add .' / 'git add --all' is not allowed (METHODOLOGY.md §7)." >&2
  echo "Stage specific files by name instead, e.g.:  git-claude add path/to/file" >&2
  exit 2
fi
exit 0
