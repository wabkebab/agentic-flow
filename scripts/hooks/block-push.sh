#!/usr/bin/env bash
# PreToolUse hook: a human controls pushes and PR merges. Exit 2 blocks.
# shellcheck disable=SC2329
set -uo pipefail
# shellcheck source=scripts/lib/hook-command.sh
. "$(dirname "$0")/../lib/hook-command.sh"

maybe_push() {
  hook_maybe_protected "$1" push "${2:-}" || hook_maybe_protected "$1" commit "${2:-}"
}
# Preserve the fail-closed unparseable-commit control from issue #110. Literal
# commit heredocs now parse normally; substitutions in commits still block.

raw=$(head -c 65537)
if ! hook_read_command "$raw"; then
  if maybe_push "$raw" raw; then
    echo 'Blocked: could not parse a protected command.' >&2
    exit 2
  fi
  exit 0
fi
[ -n "$HOOK_COMMAND" ] || exit 0

check_push() {
  case "$HOOK_KIND:$HOOK_VERB" in
    ambiguous_git:push|ambiguous_gh:pr)
      echo 'Blocked: protected operation has an unsupported command prefix.' >&2
      return 2 ;;
  esac
  if [ "$HOOK_KIND" = git ] && [ "$HOOK_VERB" = push ]; then
    echo "Blocked: 'git push' is not allowed — the human controls all pushes and merges (METHODOLOGY.md §7)." >&2
    return 2
  fi
  if [ "$HOOK_KIND" = gh ] && [ "$HOOK_VERB" = pr ] &&
     [ "${HOOK_WORDS[HOOK_VERB_INDEX+1]:-}" = merge ]; then
    echo "Blocked: 'gh pr merge' is not allowed — the human merges PRs (METHODOLOGY.md §1)." >&2
    return 2
  fi
  return 0
}

hook_walk "$HOOK_COMMAND" check_push
status=$?
if [ "$status" -eq 1 ]; then
  if maybe_push "$HOOK_COMMAND"; then
    echo 'Blocked: could not parse a protected command.' >&2
    exit 2
  fi
  exit 0
fi
exit "$status"
