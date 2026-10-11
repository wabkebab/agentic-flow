#!/usr/bin/env bash
# PreToolUse hook: stage files by name. Exit 2 blocks broad add operations.
# shellcheck disable=SC2329
set -uo pipefail
# shellcheck source=scripts/lib/hook-command.sh
. "$(dirname "$0")/../lib/hook-command.sh"

raw=$(head -c 65537)
if ! hook_read_command "$raw"; then
  if hook_maybe_protected "$raw" add raw; then
    echo 'Blocked: could not parse a protected command.' >&2
    exit 2
  fi
  exit 0
fi
[ -n "$HOOK_COMMAND" ] || exit 0

check_add() {
  local i
  if [ "$HOOK_KIND:$HOOK_VERB" = ambiguous_git:add ]; then
    echo 'Blocked: protected operation has an unsupported command prefix.' >&2
    return 2
  fi
  [ "$HOOK_KIND" = git ] && [ "$HOOK_VERB" = add ] || return 0
  for ((i=HOOK_VERB_INDEX+1; i<${#HOOK_WORDS[@]}; i++)); do
    case "${HOOK_WORDS[i]}" in
      -A|--all|.|:/)
        echo "Blocked: 'git add -A' / 'git add .' / 'git add --all' is not allowed (METHODOLOGY.md §7)." >&2
        echo 'Stage specific files by name instead.' >&2
        return 2 ;;
    esac
  done
  return 0
}

hook_walk "$HOOK_COMMAND" check_add
status=$?
if [ "$status" -eq 1 ]; then
  if hook_maybe_protected "$HOOK_COMMAND" add; then
    echo 'Blocked: could not parse a protected command.' >&2
    exit 2
  fi
  exit 0
fi
exit "$status"
