#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Enforces METHODOLOGY.md §7 "stage files by name" by
# blocking `git add -A` / `git add .` / `git add --all` / `git add :/` (also for the
# git-claude / git-codex wrappers). Reads the tool-call JSON on stdin.
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

# Match: (git|git-claude|git-codex) [-C <path>|-c <k=v>]... add ... <-A|--all|.|:/> as a
# standalone arg. The intervening-flag part matters: `git -C <path> add -A` and
# `git -c k=v add .` are everyday usage, not evasion, and a pattern requiring `add` to
# follow `git` immediately waved them straight through. Mirrors block-push.sh.
if printf '%s' "$cmd" | grep -Eq "$LEAD"'(git|git-claude|git-codex)([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|--?[A-Za-z][-A-Za-z0-9]*(=[^[:space:]]*)?))*[[:space:]]+add[[:space:]]+([^|;&]*[[:space:]])?(-A|--all|\.|:/)'"$TAIL"; then
  echo "Blocked: 'git add -A' / 'git add .' / 'git add --all' is not allowed (METHODOLOGY.md §7)." >&2
  echo "Stage specific files by name instead, e.g.:  git-claude add path/to/file" >&2
  exit 2
fi
exit 0
